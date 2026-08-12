import Foundation
import SwiftUI

struct SessionStoreData: Codable {
    var sessions: [SessionConfiguration] = []
    var folders: [SessionFolder] = []
    var openTabIDs: [UUID] = []
    var activeTabID: UUID?
    /// The document strip's own selection. Optional, so a `sessions.json` written before
    /// Phase B decodes without it.
    var activeDocumentTabID: UUID?
}

@Observable
class SessionStore {
    var sessions: [SessionConfiguration] = []
    var folders: [SessionFolder] = []
    /// Every open tab, BOTH kinds, in one flat list. Each strip filters this down to its
    /// own `ViewKind` (see `tabIDs(_:)`) and the two orders are independent — a reorder
    /// inside one strip provably cannot disturb the other, because `TabStripModel` only
    /// ever writes back into the positions that kind already held.
    var openTabIDs: [UUID] = []
    /// The CONSOLE strip's selection. Kept as `activeTabID` — the name and the JSON key
    /// both predate Phase B and half the app reads it — but it is now guaranteed to name
    /// a `.terminal` tab, which is what keeps document tabs off the PTY paths.
    var activeTabID: UUID?
    /// The DOCUMENT strip's selection. Separate from `activeTabID` on purpose: clicking a
    /// document tab must not unmount the console's terminal view.
    var activeDocumentTabID: UUID?
    /// Which strip the user last picked a tab in. Drives ⌘W, next/previous and ⌘1–9, so
    /// those act on the strip you are actually looking at. Not persisted — every launch
    /// starts on the console.
    private(set) var focusedKind: ViewKind = .terminal

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
            // Each strip's selection has to be a tab OF THAT KIND. A file written by a
            // pre-Phase-B build can name a terminal tab in `activeTabID` and nothing
            // else, which is exactly the fallback below.
            activeTabID = decoded.activeTabID.flatMap { isTerminal($0) && sessionIDs.contains($0) ? $0 : nil }
                ?? tabIDs(.terminal).last
            activeDocumentTabID = decoded.activeDocumentTabID
                .flatMap { !isTerminal($0) && sessionIDs.contains($0) ? $0 : nil }
                ?? tabIDs(.document).last

            // Mark restored open tabs to resume their prior Claude session. In prod
            // only ephemeral tabs resume; under dev hot-swap every open tab resumes
            // so a build relaunch continues each tab's conversation. Resume is keyed
            // to each tab's own Claude session id (see SessionConfiguration.claudeSessionID
            // and ClaudeProcessBuilder), so tabs sharing a working directory never
            // collide — unlike `--continue`, which would interleave them.
            // `.isTerminal` first: resuming is a PTY concept, and a restored document tab
            // must never be handed to `--resume`.
            for session in sessions where session.isTerminal && openTabIDs.contains(session.id) {
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
                activeTabID: activeTabID,
                activeDocumentTabID: activeDocumentTabID
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
        // The last gate before `ClaudeProcessBuilder` and `PtyProcess`. Callers already
        // filter to `terminalTabIDs`; this makes a launch structurally impossible for a
        // document tab even if a future caller forgets (task 9736 criterion 11).
        guard config.isTerminal else { return nil }
        let wantsResume = resumingSessionIDs.contains(id)
        resumingSessionIDs.remove(id)

        // The explicit user "Continue previous session" toggle owns the resume
        // semantics (`--continue`); don't pin a ConsoleForge session id there.
        if config.continueSession {
            return (config, false)
        }
        // Only resume a session Claude actually wrote. A tab that was closed before its
        // first turn has a pinned id but no transcript, and `--resume <missing-id>`
        // does not fail cleanly — the CLI falls back to another session in the same
        // working directory and floods that conversation's history into the tab. On a
        // shared cwd like `~` that is someone else's multi-megabyte transcript, which
        // is both wrong and, if the terminal is mid-resize when it lands, a reflow
        // storm. No transcript means this is a fresh launch, not a resume.
        if wantsResume, let sid = config.claudeSessionID,
           ClaudeTranscript.url(workingDirectory: config.workingDirectory, claudeSessionID: sid) != nil {
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
        let kind = viewKind(of: id)
        sessions.removeAll { $0.id == id }
        openTabIDs.removeAll { $0 == id }
        if activeTabID(in: kind) == id {
            setActiveTab(tabIDs(kind).last, in: kind)
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

    /// The sidebar lists launchable sessions only — never document tabs, which are a
    /// file someone opened rather than a configuration to run.
    func sessionsInFolder(_ folderID: UUID?) -> [SessionConfiguration] {
        sessions.filter { $0.folderID == folderID && !$0.isEphemeral && $0.isTerminal }
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

    // MARK: - Strips

    /// The open tabs of one kind, in strip order. Each tab strip renders exactly this.
    func tabIDs(_ kind: ViewKind) -> [UUID] {
        openTabIDs.filter { viewKind(of: $0) == kind }
    }

    /// The console strip. THE list every PTY path must use — session reconcile, resume,
    /// the voice channel, the terminated-overlay bookkeeping. `openTabIDs` is no longer
    /// a safe stand-in for it (task 9736 criterion 11).
    var terminalTabIDs: [UUID] { tabIDs(.terminal) }
    var documentTabIDs: [UUID] { tabIDs(.document) }

    func viewKind(of id: UUID) -> ViewKind {
        session(for: id)?.viewKind ?? .terminal
    }

    func isTerminal(_ id: UUID) -> Bool { viewKind(of: id).isTerminal }

    /// Which tab is selected in a given strip.
    func activeTabID(in kind: ViewKind) -> UUID? {
        kind.isTerminal ? activeTabID : activeDocumentTabID
    }

    private func setActiveTab(_ id: UUID?, in kind: ViewKind) {
        if kind.isTerminal { activeTabID = id } else { activeDocumentTabID = id }
    }

    /// A snapshot of the open tabs as pure ids + kinds + parents, for `TabStripModel`.
    /// Rebuilt per call: the tab count is small, and a cached copy is one more thing to
    /// keep in sync with `sessions`.
    private var stripModel: TabStripModel {
        var kinds: [UUID: ViewKind] = [:]
        var parents: [UUID: UUID] = [:]
        for session in sessions {
            kinds[session.id] = session.viewKind
            if let pid = session.parentTabID { parents[session.id] = pid }
        }
        return TabStripModel(open: openTabIDs, kinds: kinds, parents: parents)
    }

    // MARK: - Tab Management

    func openTab(sessionID: UUID) {
        if !openTabIDs.contains(sessionID) {
            let idx = session(for: sessionID).map { insertionIndex(for: $0) } ?? openTabIDs.count
            openTabIDs.insert(sessionID, at: idx)
        }
        focusTab(sessionID)
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
        focusTab(session.id)
        save()
    }

    /// Open a read-only document tab, parented to `parentTabID` (normally the console tab
    /// the user opened it from). Re-focuses an existing tab for the same file rather than
    /// stacking duplicates.
    @discardableResult
    func openDocumentTab(path: String, parentTabID: UUID?) -> UUID {
        let resolved = (path as NSString).expandingTildeInPath
        if let existing = documentTabIDs.first(where: { session(for: $0)?.documentPath == resolved }) {
            focusTab(existing)
            save()
            return existing
        }
        let config = SessionConfiguration.document(path: resolved, parentTabID: parentTabID)
        openEphemeralTab(config)
        return config.id
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

    /// A close the user has to answer first, because the tab has parented children in
    /// ANOTHER strip that would otherwise be silently orphaned.
    struct PendingClose: Identifiable, Equatable {
        var tabID: UUID
        var tabName: String
        /// The non-terminal children at risk. Terminal children are not listed — they
        /// keep their existing silent-orphan behaviour (criterion 12).
        var children: [UUID]
        var childNames: [String]
        var reason: TabEventWriter.CloseReason
        var id: UUID { tabID }
    }

    /// Set when a close needs an answer; the UI presents it and calls `resolvePendingClose`.
    var pendingClose: PendingClose?

    /// The close every USER-initiated path goes through (tab ✕, context menu, ⌘W).
    ///
    /// A parent must not close out from under its children. When the tab has parented
    /// DOCUMENT children this raises `pendingClose` instead of closing, and the UI asks.
    /// Existing terminal worktree-tab grouping is deliberately untouched: a console tab
    /// whose children are also console tabs still closes immediately and orphans them,
    /// exactly as before (task 9736 criterion 12). Non-interactive callers — the CLI's
    /// `--close-self`, a process exit — call `closeTab` directly and never prompt.
    func requestCloseTab(sessionID: UUID, reason: TabEventWriter.CloseReason = .manual) {
        let children = childTabs(of: sessionID).filter { !isTerminal($0) }
        guard !children.isEmpty else {
            closeTab(sessionID: sessionID, reason: reason)
            return
        }
        pendingClose = PendingClose(
            tabID: sessionID,
            tabName: session(for: sessionID)?.name ?? "this tab",
            children: children,
            childNames: children.compactMap { session(for: $0)?.name },
            reason: reason
        )
    }

    /// Answer a `pendingClose`. `closeChildren` closes the children first, then the
    /// parent; otherwise the children stay open and simply leave the group.
    func resolvePendingClose(closeChildren: Bool) {
        guard let pending = pendingClose else { return }
        pendingClose = nil
        if closeChildren {
            for child in pending.children {
                closeTab(sessionID: child, reason: pending.reason)
            }
        }
        closeTab(sessionID: pending.tabID, reason: pending.reason)
    }

    func cancelPendingClose() {
        pendingClose = nil
    }

    func closeTab(sessionID: UUID, reason: TabEventWriter.CloseReason = .manual, exitCode: Int32? = nil) {
        let kind = viewKind(of: sessionID)
        // The events/ bus is the console's: `consoleforge-tab --wait-for-close` waits on a
        // process. A document tab has none, so it emits nothing.
        if kind.isTerminal {
            let tabName = sessions.first(where: { $0.id == sessionID })?.name ?? "Unknown"
            TabEventWriter.emitClose(tabID: sessionID, tabName: tabName, reason: reason, exitCode: exitCode)
        }

        // Children of a closing parent stay open and simply leave the group. Document
        // children only reach this having been kept deliberately (see
        // `requestCloseTab`) or through a non-interactive close.
        for i in sessions.indices where sessions[i].parentTabID == sessionID {
            sessions[i].parentTabID = nil
        }
        openTabIDs.removeAll { $0 == sessionID }
        // Remove ephemeral sessions when their tab is closed
        if let idx = sessions.firstIndex(where: { $0.id == sessionID && $0.isEphemeral }) {
            sessions.remove(at: idx)
        }
        resumingSessionIDs.remove(sessionID)
        if pendingClose?.tabID == sessionID { pendingClose = nil }
        // Selection falls back WITHIN the strip that lost a tab — closing a document must
        // not move the console's selection, and vice versa.
        if activeTabID(in: kind) == sessionID {
            setActiveTab(tabIDs(kind).last, in: kind)
        }
        if focusedKind == kind && activeTabID(in: kind) == nil {
            focusedKind = .terminal
        }
        save()
        // openTabIDs is now up to date — notify after removal so listeners see the
        // post-close state.
        onTabClosed?(sessionID)
    }

    /// Close whatever tab the focused strip has selected (⌘W), asking first if it has
    /// document children.
    func requestCloseFocusedTab() {
        guard let id = activeTabID(in: focusedKind) else { return }
        requestCloseTab(sessionID: id)
    }

    func switchToTab(sessionID: UUID) {
        focusTab(sessionID)
    }

    /// Select a tab in its OWN strip and make that strip the keyboard target. Selecting a
    /// document never touches `activeTabID`, so the console's terminal view stays mounted
    /// and unresized.
    func focusTab(_ sessionID: UUID) {
        let kind = viewKind(of: sessionID)
        setActiveTab(sessionID, in: kind)
        focusedKind = kind
    }

    func switchTabByIndex(_ index: Int) {
        let strip = tabIDs(focusedKind)
        guard index >= 0 && index < strip.count else { return }
        setActiveTab(strip[index], in: focusedKind)
    }

    /// How many tabs the keyboard shortcuts currently address (⌘1–9 enablement).
    var focusedStripCount: Int { tabIDs(focusedKind).count }

    /// The one tab the user last picked, across both strips. Each strip keeps its own
    /// selection highlighted; this is what the GROUP affordance follows, so a console tab
    /// whose document child is focused reads as the group's anchor even though the child
    /// is in another strip.
    var focusedTabID: UUID? { activeTabID(in: focusedKind) }

    func nextTab() {
        cycleTab(by: 1)
    }

    func previousTab() {
        cycleTab(by: -1)
    }

    /// Next/previous stays INSIDE the focused strip — cycling from the last document into
    /// the first console tab would silently move the terminal selection.
    private func cycleTab(by delta: Int) {
        let strip = tabIDs(focusedKind)
        guard !strip.isEmpty,
              let current = activeTabID(in: focusedKind),
              let idx = strip.firstIndex(of: current) else { return }
        let next = (idx + delta + strip.count) % strip.count
        setActiveTab(strip[next], in: focusedKind)
    }

    func moveTab(id: UUID, before targetID: UUID?) {
        var model = stripModel
        let ungrouped = model.move(id, before: targetID)
        openTabIDs = model.open
        // A child dragged outside its group's contiguous run in ITS OWN STRIP leaves the
        // group. Contiguity is per strip: with a parent in the console strip and children
        // in the document strip there is no run spanning both, so the old flat-list scan
        // could not have held (task 9736 criterion 10).
        for id in ungrouped { ungroupTab(id) }
        save()
    }

    // MARK: - Tab Groups

    /// Open tabs whose sessions name `parentID` as their group parent, in tab order.
    /// Spans BOTH strips — a console tab's children can be console tabs, document tabs,
    /// or both.
    func childTabs(of parentID: UUID) -> [UUID] {
        openTabIDs.filter { session(for: $0)?.parentTabID == parentID }
    }

    /// This tab's children that live in `kind`'s strip.
    func childTabs(of parentID: UUID, in kind: ViewKind) -> [UUID] {
        childTabs(of: parentID).filter { viewKind(of: $0) == kind }
    }

    /// The group parent of an open tab, when that parent is itself still open. The parent
    /// may be in the other strip — that is the whole point of Phase B's parenting.
    func groupParent(of id: UUID) -> UUID? {
        guard let pid = session(for: id)?.parentTabID, openTabIDs.contains(pid) else { return nil }
        return pid
    }

    private func ungroupTab(_ id: UUID) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].parentTabID = nil
        }
    }

    /// Where a newly opened tab goes, as an index into the flat `openTabIDs`.
    /// Arithmetic in `TabStripModel`.
    private func insertionIndex(for config: SessionConfiguration) -> Int {
        stripModel.insertionIndex(kind: config.viewKind, parent: config.parentTabID)
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
