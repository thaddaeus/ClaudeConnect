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
    /// Notified (with the closed tab's id) after any tab is closed, from the single
    /// `closeTab` chokepoint — so every close path (UI, menu, CLI) cleans up the
    /// activity tracker. Set by the app.
    @ObservationIgnored var onTabClosed: ((UUID) -> Void)?
    /// IDs of ephemeral sessions that were restored from a previous run.
    /// These get `--continue` to resume the Claude session.
    private(set) var resumingSessionIDs: Set<UUID> = []
    private var configLoaded = false
    private var saveTask: Task<Void, Never>?

    private static var storageURL: URL {
        AppChannel.supportDirectory().appendingPathComponent("sessions.json")
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

            // Mark restored open tabs to resume their prior Claude session. In prod
            // only ephemeral tabs resume; under dev hot-swap every open tab resumes
            // so a build relaunch continues each tab's conversation. Resume is keyed
            // to each tab's own Claude session id (see SessionConfiguration.claudeSessionID
            // and ClaudeProcessBuilder), so tabs sharing a working directory never
            // collide — unlike `--continue`, which would interleave them.
            for session in sessions where openTabIDs.contains(session.id) {
                if session.isEphemeral || DevMode.isHotSwap {
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

    /// Resolve a tab's launch: ensure it owns a Claude session id and report
    /// whether this launch should resume (re-attach to) it. A fresh launch is
    /// pinned to a NEW id (so `--session-id` never collides with an existing
    /// session); a restored tab keeps its id and resumes it. Either way two tabs
    /// in the same working directory own distinct ids and never interleave.
    /// `resumingSessionIDs` is one-shot — consumed here so a later relaunch of the
    /// same tab (e.g. Restart) starts fresh.
    func resolveLaunch(for id: UUID) -> (config: SessionConfiguration, resume: Bool)? {
        guard var config = session(for: id) else { return nil }
        let wantsResume = resumingSessionIDs.contains(id)
        resumingSessionIDs.remove(id)

        // The explicit user "Continue previous session" toggle owns the resume
        // semantics (`--continue`); don't pin a ConsoleForge session id there.
        if config.continueSession {
            return (config, false)
        }
        if wantsResume, config.claudeSessionID != nil {
            // Resuming an existing conversation — don't re-fire the initial prompt.
            config.initialPrompt = nil
            return (config, true)
        }
        config.claudeSessionID = UUID()
        updateSession(config)
        return (config, false)
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

    func moveSession(id: UUID, toFolder folderID: UUID) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].folderID = folderID
            save()
        }
    }

    /// Reorder a session within (or into) a folder by placing it before a target session.
    func reorderSession(id: UUID, toFolder folderID: UUID, before targetID: UUID?) {
        guard let srcIdx = sessions.firstIndex(where: { $0.id == id }) else { return }
        var session = sessions.remove(at: srcIdx)
        session.folderID = folderID

        if let targetID,
           let targetIdx = sessions.firstIndex(where: { $0.id == targetID }) {
            sessions.insert(session, at: targetIdx)
        } else {
            sessions.append(session)
        }
        save()
    }

    // MARK: - Tab Management

    func openTab(sessionID: UUID) {
        if !openTabIDs.contains(sessionID) {
            let idx = session(for: sessionID).map { insertionIndex(for: $0) } ?? openTabIDs.count
            openTabIDs.insert(sessionID, at: idx)
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
            openTabIDs.insert(session.id, at: insertionIndex(for: session))
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

    func closeTab(sessionID: UUID, reason: TabEventWriter.CloseReason = .manual, exitCode: Int32? = nil) {
        let tabName = sessions.first(where: { $0.id == sessionID })?.name ?? "Unknown"
        TabEventWriter.emitClose(tabID: sessionID, tabName: tabName, reason: reason, exitCode: exitCode)

        // Children of a closing parent stay open and simply leave the group.
        for i in sessions.indices where sessions[i].parentTabID == sessionID {
            sessions[i].parentTabID = nil
        }
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
        // openTabIDs is now up to date — notify after removal so listeners see the
        // post-close state.
        onTabClosed?(sessionID)
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

    func moveTab(id: UUID, before targetID: UUID?) {
        guard openTabIDs.contains(id) else { return }
        // A parent moves with its children as one block.
        let block = [id] + childTabs(of: id)
        // Dropping a group onto itself is a no-op.
        if let targetID, block.contains(targetID) { return }

        openTabIDs.removeAll { block.contains($0) }

        var insertAt = openTabIDs.count
        if let targetID, var targetIdx = openTabIDs.firstIndex(of: targetID) {
            // Don't split a foreign group: dropping onto one of its children places
            // the moved block before the whole group instead.
            if let targetParent = groupParent(of: targetID),
               session(for: id)?.parentTabID != targetParent,
               let parentIdx = openTabIDs.firstIndex(of: targetParent) {
                targetIdx = parentIdx
            }
            insertAt = targetIdx
        }
        openTabIDs.insert(contentsOf: block, at: insertAt)

        // A child that landed outside its parent's contiguous run leaves the group.
        if let pid = groupParent(of: id),
           let parentIdx = openTabIDs.firstIndex(of: pid),
           let myIdx = openTabIDs.firstIndex(of: id) {
            var runEnd = parentIdx + 1
            while runEnd < openTabIDs.count,
                  session(for: openTabIDs[runEnd])?.parentTabID == pid {
                runEnd += 1
            }
            if !(myIdx > parentIdx && myIdx < runEnd) {
                ungroupTab(id)
            }
        }
        save()
    }

    func previousTab() {
        guard let current = activeTabID,
              let idx = openTabIDs.firstIndex(of: current) else { return }
        let prev = (idx - 1 + openTabIDs.count) % openTabIDs.count
        activeTabID = openTabIDs[prev]
    }

    // MARK: - Tab Groups

    /// Open tabs whose sessions name `parentID` as their group parent, in tab order.
    func childTabs(of parentID: UUID) -> [UUID] {
        openTabIDs.filter { session(for: $0)?.parentTabID == parentID }
    }

    /// The group parent of an open tab, when that parent is itself still open.
    func groupParent(of id: UUID) -> UUID? {
        guard let pid = session(for: id)?.parentTabID, openTabIDs.contains(pid) else { return nil }
        return pid
    }

    private func ungroupTab(_ id: UUID) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].parentTabID = nil
        }
    }

    /// Where a newly opened tab goes: directly after its group parent's existing
    /// children (keeping the group contiguous), or at the end when ungrouped.
    private func insertionIndex(for config: SessionConfiguration) -> Int {
        guard let pid = config.parentTabID, let parentIdx = openTabIDs.firstIndex(of: pid) else {
            return openTabIDs.count
        }
        var idx = parentIdx + 1
        while idx < openTabIDs.count, session(for: openTabIDs[idx])?.parentTabID == pid {
            idx += 1
        }
        return idx
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
