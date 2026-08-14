import SwiftUI
import AppKit
import Sparkle

/// Ensures the app runs as a proper GUI application with dock icon and keyboard focus,
/// even when launched via `swift run` (which starts as a CLI process).
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Held for the app's lifetime to opt out of App Nap. Without it, macOS
    /// throttles the CoreAnimation redraw cycle for windows it deems idle —
    /// PTY output keeps marking the terminal view dirty via setNeedsDisplay,
    /// but the automatic display flush is suspended, so live output/typing is
    /// invisible until a mouse click forces a synchronous displayIfNeeded.
    /// A terminal multiplexer hosting live subprocesses is doing genuine
    /// user-initiated work and must not be napped while running.
    private var activityToken: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    /// Displays present at the last screen-change event. Used to tell a real
    /// display *disconnect* (the only case the fullscreen recovery is for) from
    /// other screen-parameter changes — entering fullscreen creates a Space and
    /// switching Spaces both fire didChangeScreenParametersNotification, but
    /// neither removes a display.
    private var knownDisplayIDs: Set<CGDirectDisplayID> = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Hosting live terminal sessions")

        // Recover from a fullscreen window stranded on a disconnected display.
        knownDisplayIDs = currentDisplayIDs()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refitWindowsAfterScreenChange()
        }

        // Delay activation to ensure windows are ready (swift run needs this)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A child process is NOT killed by its parent exiting — it is reparented to
        // launchd and keeps running. Without this, quitting ConsoleForge would strand
        // every managed Chrome, and "the browser dies with the tab" would be true only
        // while the app happened to be alive. Synchronous: there is no run loop left to
        // await a grace period on.
        MainActor.assumeIsolated { ManagedChrome.shared.terminateAllNow() }
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
            screenObserver = nil
        }
    }

    /// When a display is connected/removed, a native-fullscreen window can be left
    /// at the old display's size — clipping content on the smaller screen with no
    /// way to resize (fullscreen windows aren't user-resizable), so only a relaunch
    /// recovered it. Drop such a window out of fullscreen so it restores to a
    /// correctly-sized window; constrain any plain window that ended up oversized
    /// or off-screen. Deferred a tick because screen geometry settles after the
    /// notification.
    private func refitWindowsAfterScreenChange() {
        DispatchQueue.main.async {
            let screens = NSScreen.screens
            // Did this event remove a display? Only then is the fullscreen recovery
            // warranted. Entering fullscreen (creates a Space) and switching Spaces
            // both fire this notification with no display removed — recovering then
            // would toggle a still-animating fullscreen window back out, collapsing it
            // to its old size on the main desktop. Compare before any early `continue`
            // so the snapshot updates on every event.
            let current = self.currentDisplayIDs()
            let displaysRemoved = !self.knownDisplayIDs.subtracting(current).isEmpty
            self.knownDisplayIDs = current

            for window in NSApp.windows where window.isVisible {
                if window.styleMask.contains(.fullScreen) {
                    // A native-fullscreen window is stranded only when its display was
                    // disconnected, leaving it at the old (oversized) size with no
                    // screen matching its frame. Require an actual display removal so
                    // fullscreen-enter / Space-switch events don't trip this. Do NOT
                    // judge it against window.screen: mid-transition that is nil and
                    // falls back to the built-in screen, so a legitimately-moved window
                    // looked "mismatched" and got toggled out onto the main screen.
                    guard displaysRemoved else { continue }
                    let f = window.frame
                    let fillsAScreen = screens.contains { s in
                        abs(f.width - s.frame.width) < 1 && abs(f.height - s.frame.height) < 1
                    }
                    if !fillsAScreen {
                        window.toggleFullScreen(nil)
                    }
                    continue
                }

                guard let screen = window.screen ?? NSScreen.main else { continue }
                let vf = screen.visibleFrame
                var f = window.frame
                guard f.width > vf.width || f.height > vf.height || !vf.intersects(f) else { continue }
                f.size.width = min(f.width, vf.width)
                f.size.height = min(f.height, vf.height)
                f.origin.x = max(vf.minX, min(f.origin.x, vf.maxX - f.width))
                f.origin.y = max(vf.minY, min(f.origin.y, vf.maxY - f.height))
                window.setFrame(f, display: true, animate: false)
            }
        }
    }

    /// The set of currently-connected displays, by stable display id. Used to
    /// detect a disconnect (a shrinking set) vs. other screen-parameter changes.
    private func currentDisplayIDs() -> Set<CGDirectDisplayID> {
        Set(NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        })
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Re-activate on every focus gain to ensure proper keyboard handling
        // when launched as a CLI process via swift run
        NSApp.setActivationPolicy(.regular)
    }
}

@main
struct ConsoleForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var store = SessionStore()
    @State private var activityTracker = TabActivityTracker()
    /// Owns the live `TerminalSession` per open tab. Held at app scope (not inside
    /// `TerminalContainerView`) because the voice channel needs to reach a tab's PTY,
    /// and because a session manager should outlive any one view's lifetime.
    @State private var terminalManager = TerminalSessionManager()
    /// The window's slot layout (which section sits where, and how each slot sizes
    /// itself). Held at app scope so the menu-bar Layout menu can drive it too.
    @State private var layoutStore = LayoutStore()
    /// Chrome instances owned by tabs (Phase C). A singleton because the app delegate
    /// has to reach it at terminate, and there is exactly one per app.
    @State private var chrome = ManagedChrome.shared
    @State private var voice = VoiceController()
    @State private var commandWatcher = CommandWatcher()
    @State private var companionSettings: CompanionSettings
    @State private var companionAuth: CompanionAuth
    @State private var supportReporter: SupportReporter
    @State private var showFDAPrompt = false

    /// Sparkle updater. Held as a plain `let` (must outlive view churn, not @State).
    /// `startingUpdater:` starts scheduled background checks immediately; cadence
    /// and automatic-check policy come from Info.plist (SUScheduledCheckInterval,
    /// SUEnableAutomaticChecks).
    ///
    /// Non-production builds never start it. A beta that checked the production
    /// feed would "update" itself to the shipping release and overwrite the very
    /// build under test — and with no SUFeedURL in the beta Info.plist, starting
    /// the updater would just raise an error alert on every launch. The menu item
    /// is hidden to match (see `.commands`).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: AppChannel.isProduction, updaterDelegate: nil, userDriverDelegate: nil)

    init() {
        // CompanionAuth + SupportReporter must share the same CompanionSettings
        // instance the UI binds to, so settings (backend URL, login) changes are
        // seen everywhere.
        let settings = CompanionSettings()
        _companionSettings = State(initialValue: settings)
        _companionAuth = State(initialValue: CompanionAuth(settings: settings))
        _supportReporter = State(initialValue: SupportReporter(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(activityTracker)
                .environment(terminalManager)
                .environment(layoutStore)
                .environment(chrome)
                .environment(voice)
                .environment(companionAuth)
                .environment(supportReporter)
                .task {
                    commandWatcher.onCommand = { command in
                        handleCommand(command)
                    }
                    commandWatcher.start()
                    TabEventWriter.cleanupStaleEvents()

                    // Lets a bell be checked against that session's transcript, so the
                    // amber "needs input" dot only lights when something is genuinely
                    // pending. The tracker takes the lookup as a closure rather than a
                    // SessionStore dependency.
                    activityTracker.workingDirectory = { tabID in
                        store.session(for: tabID)?.workingDirectory
                    }

                    // Every close path funnels through store.closeTab; clean up the
                    // tracker from here so UI, menu, and CLI closes are all covered
                    // by one wire.
                    store.onTabClosed = { tabID in
                        activityTracker.removeTab(tabID: tabID)
                        // Criterion 14's second half. Every close path funnels through
                        // store.closeTab, so this one wire covers the tab bar, the menu,
                        // the CLI and a process exit.
                        ManagedChrome.shared.terminate(tabID)
                    }

                    // Chromes stranded by a previous run (force-quit, crash) are killed
                    // here — see ManagedChrome.reapOrphans.
                    ManagedChrome.shared.reapOrphans()
                    // …and reclaim profile directories whose session is gone entirely.
                    ManagedChrome.shared.pruneProfiles(
                        knownSessionIDs: Set(store.sessions.map(\.id)))

                    // The voice channel follows the ACTIVE tab: what you hear is what
                    // you're looking at. Resolving it through a closure keeps
                    // VoiceController free of a SessionStore dependency, the same shape
                    // TabActivityTracker uses for its working-directory lookup.
                    voice.activeTab = {
                        guard let id = store.activeTabID,
                              let session = store.session(for: id) else { return nil }
                        return (id: id,
                                name: session.name,
                                workingDirectory: session.workingDirectory,
                                claudeSessionID: session.claudeSessionID)
                    }
                    // Console tabs only — the voice channel speaks to a PTY, and a
                    // document tab has none (task 9736 criterion 11).
                    voice.openTabs = {
                        store.terminalTabIDs.compactMap { id in
                            store.session(for: id).map { (id: id, name: $0.name) }
                        }
                    }
                    voice.switchToTab = { store.switchToTab(sessionID: $0) }
                    voice.goToNextTab = { store.nextTab() }
                    voice.goToPreviousTab = { store.previousTab() }
                    // Spoken input reaches a session the same way typing does — through
                    // the live TerminalSession's PTY.
                    voice.sendToTab = { tabID, text in
                        terminalManager.session(for: tabID)?.sendText(text)
                    }
                    voice.sendControlToTab = { tabID, byte in
                        terminalManager.session(for: tabID)?.sendControl(byte)
                    }
                    voice.retargetToActiveTab()
                    if voice.isEnabled && voice.isMicEnabled {
                        voice.startListening()
                    }

                    // Prompt for Full Disk Access on first launch, or if not yet granted
                    if !hasFullDiskAccess() {
                        let dismissed = UserDefaults.standard.bool(forKey: "fdaPromptDismissed")
                        if !dismissed {
                            showFDAPrompt = true
                        }
                    }
                }
                .sheet(isPresented: $showFDAPrompt) {
                    FullDiskAccessView {
                        UserDefaults.standard.set(true, forKey: "fdaPromptDismissed")
                        showFDAPrompt = false
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1200, height: 800)
        .commands {
            // "Check for Updates…" under the app menu, right after the About item.
            // Production only — beta has no feed to check and must never replace
            // itself with the shipping release.
            CommandGroup(after: .appInfo) {
                if AppChannel.isProduction {
                    CheckForUpdatesView(updater: updaterController.updater)
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    let session = store.addSession()
                    store.editingSessionID = session.id
                }
                .keyboardShortcut("n")

                Button("New Folder") {
                    store.addFolder(name: "New Folder")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                // The explicit way to make a CHILD from the UI. Plain ⌘N stays an
                // independent session: `parentTabID` means "this tab came from that one",
                // and attaching it to whatever happened to be focused would demote it to
                // "these were open at the same time" — and colour most of the strip.
                Button("New Tab in Group") {
                    if let active = store.activeTabID { store.openChildTab(of: active) }
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(store.activeTabID == nil)
            }

            CommandGroup(after: .newItem) {
                Button("Open Document\u{2026}") {
                    // Raise the strip first, so the panel's result lands somewhere the
                    // user can already see.
                    layoutStore.revealStrip(for: .document)
                    DocumentOpener.present(store: store, layout: layoutStore)
                }
                .keyboardShortcut("o")

                Divider()

                Button("Close Tab") {
                    // Closes whichever strip you last picked a tab in, and asks first if
                    // that tab has parented document children (task 9736 criterion 12).
                    store.requestCloseFocusedTab()
                }
                .keyboardShortcut("w")
                .disabled(store.focusedTabID == nil)

                Divider()

                Button("Next Tab") {
                    store.nextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Previous Tab") {
                    store.previousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Divider()

                ForEach(0..<9, id: \.self) { index in
                    Button("Tab \(index + 1)") {
                        store.switchTabByIndex(index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    .disabled(index >= store.focusedStripCount)
                }
            }

            LayoutCommands(layout: layoutStore, store: store, chrome: chrome)

            SupportCommands()
        }

        Settings {
            SettingsView()
                .environment(companionAuth)
                .environment(voice)
        }

        Window("Edit Session", id: "session-editor") {
            SessionEditorWindow()
                .environment(store)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 520, height: 700)
        .windowResizability(.contentSize)

        // Account settings as a plain window — opening the macOS Settings
        // scene from the profile Menu is unreliable (SwiftUI swallows it). This
        // is opened via `openWindow(id:)` from ProfileBar.
        Window("Account Settings", id: "account-settings") {
            AccountSettingsView()
                .frame(width: 540, height: 420)
                .environment(companionAuth)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 540, height: 420)
        .windowResizability(.contentSize)

        // Support window (Help → Report a Bug / Get Help / My Requests). A plain
        // Window opened via `openWindow(id:)` from the Help menu — same reliable
        // route as Account Settings.
        Window("Support", id: "support") {
            SupportView()
                .environment(companionAuth)
                .environment(supportReporter)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 520, height: 600)
    }

    private func handleCommand(_ command: TabCommand) {
        switch command.action {
        case "close-tab":
            handleCloseTab(command)
        case "browser-window":
            handleBrowserWindow(command)
        default:
            handleOpenTab(command)
        }
    }

    private func handleOpenTab(_ command: TabCommand) {
        var config = SessionConfiguration()
        // Use the CLI-provided tab ID so callers can reference it for --wait-for-close
        if let tabIDStr = command.tabID, let tabID = UUID(uuidString: tabIDStr) {
            config.id = tabID
        }
        config.name = command.name ?? "Dynamic Session"
        config.workingDirectory = command.workingDirectory ?? "~"
        if let model = command.model { config.model = model }
        if let mode = command.permissionMode {
            config.permissionMode = SessionConfiguration.PermissionMode(rawValue: mode)
        }
        if let effort = command.effort { config.effortLevel = effort }
        if let prompt = command.systemPrompt { config.systemPrompt = prompt }
        if let prompt = command.appendSystemPrompt { config.appendSystemPrompt = prompt }
        if let prompt = command.initialPrompt { config.initialPrompt = prompt }
        if let mcp = command.mcpConfigPath { config.mcpConfigPath = mcp }
        if let flags = command.additionalFlags { config.additionalFlags = flags.joined(separator: "\n") }
        if let color = command.tabColor { config.tabColorHex = color }
        if let cont = command.continueSession { config.continueSession = cont }
        // Group under the spawning tab when the CLI ran inside one and that tab is
        // still open (stale ids from dead environments are ignored).
        if let parentStr = command.parentTabID,
           let parentID = UUID(uuidString: parentStr),
           store.openTabIDs.contains(parentID),
           store.isTerminal(parentID) {
            config.parentTabID = parentID
        }

        store.openEphemeralTab(config)

        // Bring ConsoleForge to the front
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A session asking for a real browser WINDOW — the one thing it cannot do for
    /// itself. Its own browser is headless by design, so when it hits a sign-in wall, or
    /// wants a human to look at something, this is how it produces something to look at.
    /// Owned by the requesting tab like any other, so it still dies with it.
    private func handleBrowserWindow(_ command: TabCommand) {
        guard let idString = command.tabID, let tabID = UUID(uuidString: idString),
              store.openTabIDs.contains(tabID) else { return }
        chrome.open(tabID: tabID, mode: .windowed, url: command.url ?? "about:blank")
    }

    private func handleCloseTab(_ command: TabCommand) {
        // Close by tab ID (used by --close-self). Tracker cleanup + companion
        // notification happen via store.onTabClosed, so don't duplicate them here.
        if let tabIDStr = command.tabID, let tabID = UUID(uuidString: tabIDStr) {
            store.closeTab(sessionID: tabID, reason: .selfClose)
            return
        }
        // Close by name (used by --close --name)
        if let name = command.name {
            // `consoleforge-tab --close --name` addresses CONSOLE tabs: the CLI's whole
            // vocabulary is sessions with a process.
            if let session = store.sessions.first(where: {
                $0.name == name && $0.isTerminal && store.openTabIDs.contains($0.id)
            }) {
                store.closeTab(sessionID: session.id, reason: .selfClose)
            }
        }
    }
}
