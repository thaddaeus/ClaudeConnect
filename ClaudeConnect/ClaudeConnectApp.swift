import SwiftUI
import AppKit

/// Ensures the app runs as a proper GUI application with dock icon and keyboard focus,
/// even when launched via `swift run` (which starts as a CLI process).
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Eagerly resolve shell environment before SwiftUI creates any views
        _ = ShellEnvironment.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct ClaudeConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var store = SessionStore()
    @State private var commandWatcher = CommandWatcher()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .task {
                    commandWatcher.onCommand = { command in
                        handleCommand(command)
                    }
                    commandWatcher.start()
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

        Window("Edit Session", id: "session-editor") {
            SessionEditorWindow()
                .environment(store)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 520, height: 700)
        .windowResizability(.contentSize)
    }

    private func handleCommand(_ command: TabCommand) {
        var config = SessionConfiguration()
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

        let session = store.addSession(config)
        store.openTab(sessionID: session.id)

        // Bring ClaudeConnect to the front
        NSApp.activate(ignoringOtherApps: true)
    }
}
