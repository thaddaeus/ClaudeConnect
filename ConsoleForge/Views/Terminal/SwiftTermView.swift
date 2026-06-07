import SwiftUI
import SwiftTerm
import QuartzCore

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
        //
        // Crucially, defer the repaint to the NEXT runloop tick. Setting isHidden
        // = false above doesn't take effect until AppKit commits this update pass,
        // so a synchronous forceFullRepaint here lands on a still-suspended,
        // layer-backed view and is a no-op — leaving incremental setNeedsDisplay
        // updates (live typing/output) un-composited until a real event (e.g. a
        // mouse click) wakes compositing. Dispatching async runs the repaint after
        // the un-hide is committed, reproducing the click's effect programmatically.
        if isActive && !context.coordinator.wasActive {
            DispatchQueue.main.async { [weak nsView] in
                guard let nsView, !nsView.isHidden else { return }
                Self.forceFullRepaint(nsView)
            }
        }
        context.coordinator.wasActive = isActive

        // Drive a per-frame display flush on the ACTIVE tab. SwiftTerm only sets
        // needsDisplay (via setNeedsDisplay) when fed data; in our hidden-sibling
        // ZStack hosting AppKit doesn't auto-flush that invalidation until an
        // event (click) forces a window display pass — so live typing/output
        // stalls until clicked. A CADisplayLink calling displayIfNeeded() each
        // frame reproduces that flush continuously, in sync with the screen.
        // Only the single active tab runs a link, and the system auto-suspends
        // it when the view's window is off-screen, so it's cheap.
        if isActive {
            context.coordinator.startDisplayFlush(for: nsView)
        }
        context.coordinator.displayLink?.isPaused = !isActive

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
        // Setting needsDisplay alone relies on AppKit auto-flushing the
        // invalidation at the next window display cycle — which doesn't happen
        // for our hidden-sibling ZStack hosting until an AppKit event fires.
        // Force the flush now so the repaint is immediate (mimics a click).
        terminalView.displayIfNeeded()
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
        var displayLink: CADisplayLink?
        private weak var observedTerminalView: TerminalView?
        private var wakeObserver: NSObjectProtocol?
        private var occlusionObserver: NSObjectProtocol?
        private var fullScreenEnterObserver: NSObjectProtocol?
        private var fullScreenExitObserver: NSObjectProtocol?

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

            // Entering/leaving native fullscreen resizes the window — SwiftTerm
            // reflows its buffer to the new cols/rows, but the rendered surface
            // can keep the old layout, stranding the cursor over stale output
            // rows instead of the prompt. Force a full repaint once the
            // transition has committed (next tick), plus a short safety repaint
            // after the resize animation settles.
            let repaintOnFullScreen: (Notification) -> Void = { [weak self] notification in
                guard let self,
                      let view = self.observedTerminalView,
                      let window = notification.object as? NSWindow,
                      window === view.window else { return }
                self.repaintAfterTransition()
            }
            fullScreenEnterObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: nil,
                queue: .main,
                using: repaintOnFullScreen
            )
            fullScreenExitObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: nil,
                queue: .main,
                using: repaintOnFullScreen
            )
        }

        /// Repaint the rendered surface from the SwiftTerm buffer model after a
        /// window-geometry transition. Runs on the next runloop tick (so the new
        /// layout is committed) and again after the fullscreen resize animation
        /// settles, guarding that the view is still visible each time.
        private func repaintAfterTransition() {
            DispatchQueue.main.async { [weak self] in
                self?.forceRepaintIfVisible()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.forceRepaintIfVisible()
            }
        }

        private func forceRepaintIfVisible() {
            guard let view = observedTerminalView, !view.isHidden else { return }
            SwiftTermView.forceFullRepaint(view)
        }

        /// Create (once) a CADisplayLink bound to the active terminal's display
        /// that flushes any pending SwiftTerm invalidation every frame. The link
        /// needs the view in a window; this is called from updateNSView, which
        /// fires repeatedly, so it retries until the window exists. The system
        /// suspends the link automatically when the window is off-screen.
        func startDisplayFlush(for view: TerminalView) {
            guard displayLink == nil, view.window != nil else { return }
            let link = view.displayLink(target: self, selector: #selector(flushPendingDisplay))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func flushPendingDisplay() {
            guard let view = observedTerminalView, !view.isHidden else { return }
            // No-op when nothing is dirty; flushes the pending dirty region
            // otherwise — the same effect a mouse click has, every frame.
            view.displayIfNeeded()
        }

        func removeRepaintObservers() {
            displayLink?.invalidate()
            displayLink = nil
            if let obs = wakeObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(obs)
            }
            if let obs = occlusionObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            if let obs = fullScreenEnterObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            if let obs = fullScreenExitObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            wakeObserver = nil
            occlusionObserver = nil
            fullScreenEnterObserver = nil
            fullScreenExitObserver = nil
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
