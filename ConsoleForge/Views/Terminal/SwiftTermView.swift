import SwiftUI
import SwiftTerm

struct SwiftTermView: NSViewRepresentable {
    let configuration: SessionConfiguration
    let isActive: Bool
    var onProcessTerminated: ((Int32?) -> Void)?
    var onOutputReceived: (() -> Void)?
    var onBellReceived: (() -> Void)?

    func makeNSView(context: Context) -> TerminalView {
        let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        // Configure appearance - match Terminal.app default (Menlo 11pt)
        let fontSize: CGFloat = 11
        terminalView.font = NSFont(name: "Menlo", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminalView.nativeBackgroundColor = DefaultTheme.background
        terminalView.nativeForegroundColor = DefaultTheme.foreground
        terminalView.optionAsMetaKey = true

        // Set the delegate
        terminalView.terminalDelegate = context.coordinator

        // Start the Claude process via posix_spawn (no fork)
        let params = ClaudeProcessBuilder.build(from: configuration, tabID: configuration.id)
        do {
            let process = try PtyProcess(
                executable: params.executable,
                args: params.args,
                environment: params.environment,
                workingDirectory: params.workingDirectory
            )

            // Wire PTY output to terminal display
            let onOutput = onOutputReceived
            let onBell = onBellReceived
            process.onData = { [weak terminalView] data in
                // Detect bell character (0x07) — Claude sends this on permission prompts
                let hasBell = data.contains(0x07)
                DispatchQueue.main.async {
                    let bytes = ArraySlice(data)
                    terminalView?.feed(byteArray: bytes)
                    onOutput?()
                    if hasBell {
                        onBell?()
                    }
                }
            }

            let onTerminated = onProcessTerminated
            process.onExit = { exitCode in
                onTerminated?(exitCode)
            }

            // Assign process to coordinator first so sizeChanged events aren't missed
            context.coordinator.process = process

            // Set initial window size (may still be the placeholder frame;
            // the real size arrives via sizeChanged once SwiftUI lays out the view)
            let terminal = terminalView.getTerminal()
            process.setWindowSize(cols: terminal.cols, rows: terminal.rows)
        } catch {
            print("Failed to start process: \(error)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.onProcessTerminated?(-1)
            }
        }

        return terminalView
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // Hide inactive tabs at the AppKit layer so CoreAnimation excludes them
        // from the Metal render pipeline entirely. Using opacity(0) alone keeps
        // the CALayer in the render tree, which can trigger Metal shader compilation
        // and hit a macOS CoreAnimation bug (COREANIMATION Code 6) on long-running sessions.
        nsView.isHidden = !isActive

        // When this terminal becomes the active tab, give it focus
        if isActive {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }

        // Sync PTY size on every update — catches layout changes that happened
        // before the process was assigned to the coordinator
        let terminal = nsView.getTerminal()
        context.coordinator.process?.setWindowSize(cols: terminal.cols, rows: terminal.rows)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTerminated: onProcessTerminated)
    }

    class Coordinator: NSObject, TerminalViewDelegate {
        let onTerminated: ((Int32?) -> Void)?
        var onBell: (() -> Void)?
        var process: PtyProcess?

        init(onTerminated: ((Int32?) -> Void)?) {
            self.onTerminated = onTerminated
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            process?.setWindowSize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            // Could update tab title
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // Optional: track current directory
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // User typed something — send to PTY
            process?.write(Data(data))
        }

        func scrolled(source: TerminalView, position: Double) {
            // Scroll position changed
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let str = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(str, forType: .string)
            }
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
            // Selection range changed
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        }

        func bell(source: TerminalView) {
            NSSound.beep()
            onBell?()
        }
    }
}

// MARK: - Theme

enum DefaultTheme {
    static let background = NSColor(red: 0.10, green: 0.11, blue: 0.15, alpha: 1.0)
    static let foreground = NSColor(red: 0.75, green: 0.79, blue: 0.96, alpha: 1.0)
}
