import Foundation
import SwiftUI

struct SessionStoreData: Codable {
    var sessions: [SessionConfiguration] = []
    var folders: [SessionFolder] = []
    var openTabIDs: [UUID] = []
    var activeTabID: UUID?
}

@Observable
class SessionStore {
    var sessions: [SessionConfiguration] = []
    var folders: [SessionFolder] = []
    var openTabIDs: [UUID] = []
    var activeTabID: UUID?

    var editingSessionID: UUID?
    /// IDs of ephemeral sessions that were restored from a previous run.
    /// These get `--continue` to resume the Claude session.
    private(set) var resumingSessionIDs: Set<UUID> = []
    private var configLoaded = false
    private var saveTask: Task<Void, Never>?

    private static var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ConsoleForge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }

    init() {
        load()
        if folders.isEmpty {
            folders = [SessionFolder(name: "Sessions")]
        }
        configLoaded = true
    }

    func load() {
        let url = Self.storageURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(SessionStoreData.self, from: data)
            sessions = decoded.sessions
            folders = decoded.folders
            let sessionIDs = Set(decoded.sessions.map(\.id))
            openTabIDs = decoded.openTabIDs.filter { sessionIDs.contains($0) }
            activeTabID = decoded.activeTabID.flatMap { sessionIDs.contains($0) ? $0 : nil }
                ?? openTabIDs.last

            // Mark ephemeral sessions that were open — they'll resume with --continue
            for session in sessions where session.isEphemeral {
                if openTabIDs.contains(session.id) {
                    resumingSessionIDs.insert(session.id)
                }
            }
        } catch {
            print("Failed to load sessions: \(error)")
        }
    }

    func save() {
        // Don't save if we haven't loaded yet (prevents overwriting with empty data)
        guard configLoaded else { return }

        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let storeData = SessionStoreData(
                sessions: sessions,
                folders: folders,
                openTabIDs: openTabIDs,
                activeTabID: activeTabID
            )
            do {
                let data = try JSONEncoder().encode(storeData)
                let url = Self.storageURL
                try data.write(to: url, options: .atomic)
            } catch {
                print("Failed to save sessions: \(error)")
            }
        }
    }

    // MARK: - Session CRUD

    func addSession(_ config: SessionConfiguration? = nil) -> SessionConfiguration {
        var session = config ?? SessionConfiguration()
        if session.folderID == nil {
            session.folderID = folders.first?.id
        }
        session.tabColorHex = Self.defaultColors[sessions.count % Self.defaultColors.count]
        sessions.append(session)
        save()
        return session
    }

    func updateSession(_ config: SessionConfiguration) {
        if let idx = sessions.firstIndex(where: { $0.id == config.id }) {
            sessions[idx] = config
            save()
        }
    }

    func deleteSession(id: UUID) {
        sessions.removeAll { $0.id == id }
        openTabIDs.removeAll { $0 == id }
        if activeTabID == id {
            activeTabID = openTabIDs.last
        }
        save()
    }

    func duplicateSession(id: UUID) {
        guard let original = sessions.first(where: { $0.id == id }) else { return }
        var copy = original
        copy.id = UUID()
        copy.name = "\(original.name) (Copy)"
        sessions.append(copy)
        save()
    }

    func sessionsInFolder(_ folderID: UUID?) -> [SessionConfiguration] {
        sessions.filter { $0.folderID == folderID && !$0.isEphemeral }
    }

    // MARK: - Folder CRUD

    func addFolder(name: String) {
        folders.append(SessionFolder(name: name))
        save()
    }

    func deleteFolder(id: UUID) {
        guard id != folders.first?.id else { return }
        let defaultID = folders.first?.id
        for i in sessions.indices where sessions[i].folderID == id {
            sessions[i].folderID = defaultID
        }
        folders.removeAll { $0.id == id }
        save()
    }

    func renameFolder(id: UUID, name: String) {
        if let idx = folders.firstIndex(where: { $0.id == id }) {
            folders[idx].name = name
            save()
        }
    }

    func toggleFolder(id: UUID) {
        if let idx = folders.firstIndex(where: { $0.id == id }) {
            folders[idx].isExpanded.toggle()
        }
    }

    // MARK: - Tab Management

    func openTab(sessionID: UUID) {
        if !openTabIDs.contains(sessionID) {
            openTabIDs.append(sessionID)
        }
        activeTabID = sessionID
        save()
    }

    /// Open an ephemeral tab — persisted to disk but hidden from sidebar.
    func openEphemeralTab(_ config: SessionConfiguration) {
        var session = config
        session.isEphemeral = true
        sessions.append(session)
        if !openTabIDs.contains(session.id) {
            openTabIDs.append(session.id)
        }
        activeTabID = session.id
        save()
    }

    /// Save an ephemeral tab as a permanent session (promotes to sidebar).
    func saveEphemeralSession(id: UUID) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].isEphemeral = false
            if sessions[idx].folderID == nil {
                sessions[idx].folderID = folders.first?.id
            }
            save()
        }
    }

    func closeTab(sessionID: UUID) {
        openTabIDs.removeAll { $0 == sessionID }
        // Remove ephemeral sessions when their tab is closed
        if let idx = sessions.firstIndex(where: { $0.id == sessionID && $0.isEphemeral }) {
            sessions.remove(at: idx)
        }
        resumingSessionIDs.remove(sessionID)
        if activeTabID == sessionID {
            activeTabID = openTabIDs.last
        }
        save()
    }

    func switchToTab(sessionID: UUID) {
        activeTabID = sessionID
    }

    func switchTabByIndex(_ index: Int) {
        guard index >= 0 && index < openTabIDs.count else { return }
        activeTabID = openTabIDs[index]
    }

    func nextTab() {
        guard let current = activeTabID,
              let idx = openTabIDs.firstIndex(of: current) else { return }
        let next = (idx + 1) % openTabIDs.count
        activeTabID = openTabIDs[next]
    }

    func previousTab() {
        guard let current = activeTabID,
              let idx = openTabIDs.firstIndex(of: current) else { return }
        let prev = (idx - 1 + openTabIDs.count) % openTabIDs.count
        activeTabID = openTabIDs[prev]
    }

    // MARK: - Helpers

    func session(for id: UUID) -> SessionConfiguration? {
        sessions.first { $0.id == id }
    }

    func isEphemeral(_ id: UUID) -> Bool {
        sessions.first { $0.id == id }?.isEphemeral ?? false
    }

    static let defaultColors = [
        "#007AFF", "#FF2D55", "#5856D6", "#FF9500",
        "#34C759", "#AF52DE", "#00C7BE", "#FF6482"
    ]
}
