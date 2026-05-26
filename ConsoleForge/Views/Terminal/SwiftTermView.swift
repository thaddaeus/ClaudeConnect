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
        // Recover from view/buffer desync after the view stops drawing for a while
        // (display sleep, window occluded). On wake/un-occlusion, mark all rows dirty
        // and force a redraw so the rendered surface re-syncs to the SwiftTerm model.
        context.coordinator.installRepaintObservers(for: terminalView)

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
                // Strip kitty keyboard protocol push/set sequences (CSI > N u, CSI = N u)
                // as a safety net — even if the query response was suppressed, some apps
                // enable kitty mode directly without querying first.
                let filtered = Self.stripKittyKeyboardEnable(data)
                DispatchQueue.main.async {
                    let bytes = ArraySlice(filtered)
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

        // While hidden, the SwiftTerm buffer keeps receiving PTY data but AppKit
        // doesn't draw the view — incremental dirty-row tracking gets consumed by
        // no-op draws, so on un-hide only rows dirtied after un-hide get repainted,
        // leaving stale content (Claude's TUI status line is the worst offender).
        // Force a full repaint from the buffer model on hidden→visible transitions.
        if isActive && !context.coordinator.wasActive {
            Self.forceFullRepaint(nsView)
        }
        context.coordinator.wasActive = isActive

        // When this terminal becomes the active tab, give it focus
        if isActive {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }

        // Size sync is handled by the sizeChanged delegate. DO NOT call
        // setWindowSize here — updateNSView fires on every SwiftUI state change
        // (activity tracker updates on each PTY data chunk), which would spam
        // ioctl(TIOCSWINSZ) and trigger hundreds of SIGWINCH per second.
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.removeRepaintObservers()
    }

    static func forceFullRepaint(_ terminalView: TerminalView) {
        let terminal = terminalView.getTerminal()
        let lastRow = max(0, terminal.rows - 1)
        terminal.refresh(startRow: 0, endRow: lastRow)
        terminalView.needsDisplay = true
    }

    /// Strips kitty keyboard protocol push (CSI > N u) and set (CSI = N u)
    /// sequences from PTY output so SwiftTerm never enters kitty keyboard mode.
    /// Arrow keys then use legacy escape sequences that Claude CLI understands.
    private static func stripKittyKeyboardEnable(_ data: Data) -> Data {
        // Fast path: most data chunks contain no ESC at all
        guard data.contains(0x1b) else { return data }

        var result = Data()
        result.reserveCapacity(data.count)
        var i = data.startIndex

        while i < data.endIndex {
            if data[i] == 0x1b,                          // ESC
               i + 2 < data.endIndex,
               data[i + 1] == 0x5b,                      // [
               (data[i + 2] == 0x3e || data[i + 2] == 0x3d) // > or =
            {
                // Scan past digits and semicolons (CSI parameters)
                var j = i + 3
                while j < data.endIndex &&
                      ((data[j] >= 0x30 && data[j] <= 0x39) || data[j] == 0x3b) {
                    j += 1
                }
                if j < data.endIndex && data[j] == 0x75 { // final byte 'u'
                    i = j + 1  // skip the entire sequence
                    continue
                }
            }
            result.append(data[i])
            i += 1
        }
        return result
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTerminated: onProcessTerminated)
    }

    class Coordinator: NSObject, TerminalViewDelegate {
        let onTerminated: ((Int32?) -> Void)?
        var onBell: (() -> Void)?
        var process: PtyProcess?
        var wasActive: Bool = false
        private weak var observedTerminalView: TerminalView?
        private var wakeObserver: NSObjectProtocol?
        private var occlusionObserver: NSObjectProtocol?

        init(onTerminated: ((Int32?) -> Void)?) {
            self.onTerminated = onTerminated
        }

        func installRepaintObservers(for terminalView: TerminalView) {
            observedTerminalView = terminalView
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let view = self?.observedTerminalView, !view.isHidden else { return }
                SwiftTermView.forceFullRepaint(view)
            }
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let view = self?.observedTerminalView,
                      !view.isHidden,
                      let window = notification.object as? NSWindow,
                      window === view.window,
                      window.occlusionState.contains(.visible) else { return }
                SwiftTermView.forceFullRepaint(view)
            }
        }

        func removeRepaintObservers() {
            if let obs = wakeObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(obs)
            }
            if let obs = occlusionObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            wakeObserver = nil
            occlusionObserver = nil
            observedTerminalView = nil
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
            // Suppress kitty keyboard protocol query responses (ESC [ ? N u)
            // so apps don't discover kitty support and enable it — Claude CLI's
            // option picker doesn't handle kitty key sequences, causing arrow
            // keys to display as raw text like [57419u instead of navigating.
            if Self.isKittyKeyboardQueryResponse(data) {
                return
            }
            process?.write(Data(data))
        }

        /// Detects kitty keyboard protocol query response: ESC [ ? <digits> u
        private static func isKittyKeyboardQueryResponse(_ data: ArraySlice<UInt8>) -> Bool {
            guard data.count >= 5 else { return false }
            let bytes = Array(data)
            guard bytes[0] == 0x1b,  // ESC
                  bytes[1] == 0x5b,  // [
                  bytes[2] == 0x3f,  // ?
                  bytes.last == 0x75 // u
            else { return false }
            // Everything between ? and u must be digits
            for i in 3..<(bytes.count - 1) {
                if bytes[i] < 0x30 || bytes[i] > 0x39 { return false }
            }
            return true
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
