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

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Hosting live terminal sessions")

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
    @State private var showFDAPrompt = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(activityTracker)
                .environment(updateChecker)
                .task {
                    commandWatcher.onCommand = { command in
                        handleCommand(command)
                    }
                    commandWatcher.start()
                    updateChecker.checkForUpdates()
                    TabEventWriter.cleanupStaleEvents()

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
        }

        Settings {
            SettingsView()
        }

        Window("Edit Session", id: "session-editor") {
            SessionEditorWindow()
                .environment(store)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 520, height: 700)
        .windowResizability(.contentSize)
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
        // Close by tab ID (used by --close-self)
        if let tabIDStr = command.tabID, let tabID = UUID(uuidString: tabIDStr) {
            activityTracker.removeTab(tabID: tabID)
            store.closeTab(sessionID: tabID, reason: .selfClose)
            return
        }
        // Close by name (used by --close --name)
        if let name = command.name {
            if let session = store.sessions.first(where: {
                $0.name == name && store.openTabIDs.contains($0.id)
            }) {
                activityTracker.removeTab(tabID: session.id)
                store.closeTab(sessionID: session.id, reason: .selfClose)
            }
        }
    }
}
