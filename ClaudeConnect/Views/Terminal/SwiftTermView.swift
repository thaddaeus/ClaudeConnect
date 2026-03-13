import SwiftUI
import SwiftTerm

struct SwiftTermView: NSViewRepresentable {
    let configuration: SessionConfiguration
    let isActive: Bool
    var onProcessTerminated: ((Int32?) -> Void)?

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        // Configure appearance - match Terminal.app default (Menlo 11pt)
        let fontSize: CGFloat = 11
        terminalView.font = NSFont(name: "MenloRegular", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminalView.nativeBackgroundColor = DefaultTheme.background
        terminalView.nativeForegroundColor = DefaultTheme.foreground
        terminalView.optionAsMetaKey = true

        // Set the delegate
        terminalView.processDelegate = context.coordinator

        // Start the Claude process
        let params = ClaudeProcessBuilder.build(from: configuration)
        terminalView.startProcess(
            executable: params.executable,
            args: params.args,
            environment: params.environment,
            execName: nil,
            currentDirectory: params.workingDirectory
        )

        return terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // When this terminal becomes the active tab, give it focus
        if isActive {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTerminated: onProcessTerminated)
    }

    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onTerminated: ((Int32?) -> Void)?

        init(onTerminated: ((Int32?) -> Void)?) {
            self.onTerminated = onTerminated
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
            // Terminal handles this internally
        }

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            // Could update tab title
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // Optional: track current directory
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async { [weak self] in
                self?.onTerminated?(exitCode)
            }
        }
    }
}

// MARK: - Theme

enum DefaultTheme {
    static let background = NSColor(red: 0.10, green: 0.11, blue: 0.15, alpha: 1.0)
    static let foreground = NSColor(red: 0.75, green: 0.79, blue: 0.96, alpha: 1.0)
}
