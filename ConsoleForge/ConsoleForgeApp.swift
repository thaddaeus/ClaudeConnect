import SwiftUI
import AppKit

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

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Hosting live terminal sessions")

        // Recover from a fullscreen window stranded on a disconnected display.
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
            for window in NSApp.windows where window.isVisible {
                if window.styleMask.contains(.fullScreen) {
                    // A native-fullscreen window is fine as long as it still fills
                    // *some* connected display. It's stranded only when its frame
                    // matches no screen — i.e. its display was disconnected, leaving
                    // it at the old (oversized) size. Do NOT judge it against
                    // window.screen: mid-transition (e.g. moving fullscreen to another
                    // display) that is nil and falls back to the built-in screen, so a
                    // legitimately-moved window looked "mismatched" and got toggled out
                    // onto the main screen.
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
    @State private var commandWatcher = CommandWatcher()
    @State private var updateChecker = UpdateChecker()
    @State private var companionSettings: CompanionSettings
    @State private var companionService: CompanionService
    @State private var companionAuth: CompanionAuth
    @State private var supportReporter: SupportReporter
    @State private var showFDAPrompt = false

    init() {
        // CompanionService + CompanionAuth + SupportReporter must share the same
        // CompanionSettings instance the UI binds to, so settings (relay URL, login)
        // changes are seen everywhere.
        let settings = CompanionSettings()
        _companionSettings = State(initialValue: settings)
        _companionService = State(initialValue: CompanionService(settings: settings))
        _companionAuth = State(initialValue: CompanionAuth(settings: settings))
        _supportReporter = State(initialValue: SupportReporter(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(activityTracker)
                .environment(updateChecker)
                .environment(companionSettings)
                .environment(companionService)
                .environment(companionAuth)
                .environment(supportReporter)
                .task {
                    commandWatcher.onCommand = { command in
                        handleCommand(command)
                    }
                    commandWatcher.start()
                    updateChecker.checkForUpdates()
                    TabEventWriter.cleanupStaleEvents()

                    // Forward tab activity transitions to the companion poster,
                    // enriching each signal with the tab's metadata from the store.
                    // emit() always fires on the main thread, so assuming main-actor
                    // isolation here is safe and lets us call the @MainActor service.
                    activityTracker.settleSeconds = companionSettings.settleSeconds
                    activityTracker.onCompanionEvent = { signal in
                        MainActor.assumeIsolated {
                            companionService.report(
                                signal,
                                config: store.session(for: signal.tabId),
                                openTabIds: store.openTabIDs.map(\.uuidString)
                            )
                        }
                    }

                    // Every close path funnels through store.closeTab; clean up the
                    // tracker (which emits `.closed` to the companion) from here so
                    // UI, menu, and CLI closes are all covered by one wire.
                    store.onTabClosed = { tabID in
                        activityTracker.removeTab(tabID: tabID)
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
                .onChange(of: companionSettings.settleSeconds) { _, newValue in
                    activityTracker.settleSeconds = newValue
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1200, height: 800)
        .commands {
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
            }

            CommandGroup(after: .newItem) {
                Divider()

                Button("Close Tab") {
                    if let active = store.activeTabID {
                        store.closeTab(sessionID: active)
                    }
                }
                .keyboardShortcut("w")
                .disabled(store.activeTabID == nil)

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
                    .disabled(index >= store.openTabIDs.count)
                }
            }

            SupportCommands()
        }

        Settings {
            SettingsView()
                .environment(companionSettings)
                .environment(companionService)
                .environment(companionAuth)
        }

        Window("Edit Session", id: "session-editor") {
            SessionEditorWindow()
                .environment(store)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 520, height: 700)
        .windowResizability(.contentSize)

        // Companion settings as a plain window — opening the macOS Settings
        // scene from the profile Menu is unreliable (SwiftUI swallows it). This
        // is opened via `openWindow(id:)` from ProfileBar.
        Window("Companion Settings", id: "companion-settings") {
            CompanionSettingsView()
                .frame(width: 540, height: 560)
                .environment(companionSettings)
                .environment(companionService)
                .environment(companionAuth)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 540, height: 560)
        .windowResizability(.contentSize)

        // Support window (Help → Report a Bug / Get Help / My Requests). A plain
        // Window opened via `openWindow(id:)` from the Help menu — same reliable
        // route as Companion Settings.
        Window("Support", id: "support") {
            SupportView()
                .environment(companionSettings)
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

        store.openEphemeralTab(config)

        // Bring ConsoleForge to the front
        NSApp.activate(ignoringOtherApps: true)
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
            if let session = store.sessions.first(where: {
                $0.name == name && store.openTabIDs.contains($0.id)
            }) {
                store.closeTab(sessionID: session.id, reason: .selfClose)
            }
        }
    }
}
