import AppKit
import SwiftTerm
import QuartzCore

/// Owns a single terminal: its `TerminalView`, the backing `PtyProcess`, and the
/// repaint machinery. The terminal is retained here for the lifetime of the tab,
/// independent of the view hierarchy — SwiftTerm's PTY read loop is a dispatch
/// source on its own queue, so the process keeps running and the buffer keeps
/// updating even while the `TerminalView` is removed from its superview.
///
/// Only the *active* session's `terminalView` is mounted into the window (see
/// `TerminalHostView`); inactive sessions keep running detached.
@MainActor
final class TerminalSession: NSObject, TerminalViewDelegate {
    let sessionID: UUID
    let terminalView: TerminalView
    private(set) var process: PtyProcess?

    var onOutputReceived: (() -> Void)?
    var onBellReceived: (() -> Void)?
    var onProcessTerminated: ((Int32?) -> Void)?

    private var displayLink: CADisplayLink?
    private weak var observedTerminalView: TerminalView?
    private var wakeObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    private var fullScreenEnterObserver: NSObjectProtocol?
    private var fullScreenExitObserver: NSObjectProtocol?

    init(sessionID: UUID, configuration: SessionConfiguration, resume: Bool = false,
         initialSize: CGSize = CGSize(width: 800, height: 600)) {
        self.sessionID = sessionID
        // Birth the view at the REAL terminal-area size, never a placeholder. A
        // session created at a stale size (e.g. an 800×600 default) and only resized
        // to the real area on first mount forces SwiftTerm to reflow whatever already
        // accumulated in the buffer — and that reflow corrupts the buffer model
        // permanently (restored/--resume tabs flood resumed history at the wrong width
        // before they're ever mounted). Sizing correctly up front makes mount a pure
        // re-parent with no reflow. Falls back to 800×600 only if no size is known yet.
        let frame = (initialSize.width > 1 && initialSize.height > 1)
            ? NSRect(origin: .zero, size: initialSize)
            : NSRect(x: 0, y: 0, width: 800, height: 600)
        let terminalView = LinkPastingTerminalView(frame: frame)
        self.terminalView = terminalView
        super.init()

        // Recover from view/buffer desync after the view stops drawing for a while
        // (display sleep, window occluded). On wake/un-occlusion, mark all rows dirty
        // and force a redraw so the rendered surface re-syncs to the SwiftTerm model.
        installRepaintObservers(for: terminalView)

        // Configure appearance - match Terminal.app default (Menlo 11pt)
        let fontSize: CGFloat = 11
        terminalView.font = NSFont(name: "Menlo", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminalView.nativeBackgroundColor = DefaultTheme.background
        terminalView.nativeForegroundColor = DefaultTheme.foreground
        terminalView.optionAsMetaKey = true

        // Set the delegate
        terminalView.terminalDelegate = self

        // Start the Claude process via posix_spawn (no fork)
        let params = ClaudeProcessBuilder.build(from: configuration, tabID: configuration.id, resume: resume)
        do {
            let process = try PtyProcess(
                executable: params.executable,
                args: params.args,
                environment: params.environment,
                workingDirectory: params.workingDirectory
            )

            // Wire PTY output to terminal display
            process.onData = { [weak self, weak terminalView] data in
                // Detect bell character (0x07) — Claude sends this on permission prompts
                let hasBell = data.contains(0x07)
                // Strip kitty keyboard protocol push/set sequences (CSI > N u, CSI = N u)
                // as a safety net — even if the query response was suppressed, some apps
                // enable kitty mode directly without querying first.
                let filtered = Self.stripKittyKeyboardEnable(data)
                DispatchQueue.main.async {
                    let bytes = ArraySlice(filtered)
                    terminalView?.feed(byteArray: bytes)
                    self?.onOutputReceived?()
                    if hasBell {
                        self?.onBellReceived?()
                    }
                }
            }

            process.onExit = { [weak self] exitCode in
                self?.onProcessTerminated?(exitCode)
            }

            self.process = process

            // Set initial window size (may still be the placeholder frame;
            // the real size arrives via sizeChanged once SwiftUI lays out the view)
            let terminal = terminalView.getTerminal()
            process.setWindowSize(cols: terminal.cols, rows: terminal.rows)
        } catch {
            print("Failed to start process: \(error)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.onProcessTerminated?(-1)
            }
        }
    }

    // MARK: - Mount / unmount lifecycle

    /// Called when this session's view becomes the active mounted child. Force one
    /// clean repaint from the buffer model, start the per-frame display-flush link,
    /// and take first responder so keyboard input reaches this terminal.
    func mount() {
        // One clean full repaint so the surface matches the buffer model after
        // having been detached (or first mount).
        terminalView.getTerminal().updateFullScreen()
        terminalView.needsDisplay = true
        terminalView.displayIfNeeded()

        startDisplayFlush(for: terminalView)
        displayLink?.isPaused = false

        // Focus on the next runloop tick — the view may not yet be in a window
        // when updateNSView adds it.
        DispatchQueue.main.async { [weak terminalView] in
            terminalView?.window?.makeFirstResponder(terminalView)
        }
    }

    /// Called when this session's view is swapped out (no longer active).
    func unmount() {
        displayLink?.isPaused = true
    }

    /// Keep a (possibly detached) terminal sized to the live terminal area. Detached
    /// views aren't in the hierarchy, so AppKit autoresizing never fires for them;
    /// without this they'd stay at their birth size and reflow in one big jump on the
    /// next mount. Resizing in lockstep means every reflow is a small incremental one
    /// on an already-correct buffer (exactly what the active tab survives), never the
    /// corrupting placeholder→real jump. Setting the frame drives SwiftTerm's
    /// `setFrameSize` → terminal resize → `sizeChanged` → PTY `setWindowSize`.
    func resize(to size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        guard terminalView.frame.size != size else { return }
        terminalView.frame = NSRect(origin: terminalView.frame.origin, size: size)
    }

    /// Type text into this session's PTY as if the user had pasted it, optionally
    /// submitting with a carriage return. Used by the voice channel.
    ///
    /// The text is wrapped in bracketed paste (`ESC[200~ … ESC[201~`) rather than sent
    /// raw: Claude's TUI treats a bare newline mid-text as "submit", so a dictated
    /// sentence containing one would fire the prompt half-written. Inside a bracketed
    /// paste the whole payload arrives as literal input, and only the trailing `\r`
    /// submits. Any stray ESC in the payload is dropped — it would terminate the paste
    /// early and let the remainder run as control sequences.
    func sendText(_ text: String, submit: Bool = true) {
        guard let process, !text.isEmpty else { return }
        let sanitized = text.replacingOccurrences(of: "\u{1b}", with: "")
        var payload = "\u{1b}[200~" + sanitized + "\u{1b}[201~"
        if submit { payload += "\r" }
        process.write(Data(payload.utf8))
    }

    /// Send a single control byte (e.g. `0x1b` for Escape, which interrupts Claude).
    func sendControl(_ byte: UInt8) {
        process?.write(Data([byte]))
    }

    /// Ask the child to repaint its TUI at the current geometry by re-delivering
    /// SIGWINCH (no winsize change, no input bytes). Used after a coalesced resize
    /// settles so an idle Claude redraws its prompt/status instead of staying
    /// garbled until the next output. See `PtyProcess.nudgeWinch`.
    func nudgeRedraw() {
        process?.nudgeWinch()
    }

    /// Force the child to fully regenerate its TUI even when the grid dimensions are
    /// unchanged, by briefly jiggling the PTY winsize (a bare same-size SIGWINCH is
    /// swallowed by renderers that only redraw on an actual dimension change). Used by
    /// sleep/wake + display-reconfiguration recovery to overwrite a corrupted/stale
    /// live region. No input bytes touch the PTY. See `PtyProcess.jiggleWindowSize`.
    func forceRedraw() {
        process?.jiggleWindowSize()
    }

    /// Tear down the session permanently: stop the display link, remove observers,
    /// and terminate the backing process.
    func shutdown() {
        displayLink?.invalidate()
        displayLink = nil
        removeRepaintObservers()
        process?.terminate()
    }

    // MARK: - Repaint

    /// Repaint the rendered surface from the SwiftTerm buffer model. Uses
    /// `updateFullScreen()` — the canonical full-dirty call — so every row is
    /// re-rendered, then forces an immediate flush.
    func forceFullRepaint() {
        terminalView.getTerminal().updateFullScreen()
        terminalView.needsDisplay = true
        terminalView.displayIfNeeded()
    }

    private func installRepaintObservers(for terminalView: TerminalView) {
        observedTerminalView = terminalView
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.forceRepaintIfInWindow()
            }
        }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let view = self.observedTerminalView,
                      view.window != nil,
                      let window = notification.object as? NSWindow,
                      window === view.window,
                      window.occlusionState.contains(.visible) else { return }
                self.forceFullRepaint()
            }
        }

        // Entering/leaving native fullscreen resizes the window — SwiftTerm
        // reflows its buffer to the new cols/rows, but the rendered surface
        // can keep the old layout, stranding the cursor over stale output
        // rows instead of the prompt. Force a full repaint once the
        // transition has committed (next tick), plus a short safety repaint
        // after the resize animation settles.
        let repaintOnFullScreen: @Sendable (Notification) -> Void = { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let view = self.observedTerminalView,
                      let window = notification.object as? NSWindow,
                      window === view.window else { return }
                self.repaintAfterTransition()
            }
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

    /// Repaint after a window-geometry transition: once on the next runloop tick
    /// (so the new layout is committed) and again after the resize animation settles.
    private func repaintAfterTransition() {
        DispatchQueue.main.async { [weak self] in
            self?.forceRepaintIfInWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.forceRepaintIfInWindow()
        }
    }

    private func forceRepaintIfInWindow() {
        guard let view = observedTerminalView, view.window != nil else { return }
        forceFullRepaint()
    }

    /// Create (once) a CADisplayLink bound to the terminal's display that flushes
    /// any pending SwiftTerm invalidation every frame — insurance against AppKit
    /// not auto-flushing `needsDisplay` until an event fires. Needs the view in a
    /// window; called from `mount()`, which retries on the next update if the
    /// window isn't ready yet. The system suspends the link when off-screen.
    private func startDisplayFlush(for view: TerminalView) {
        guard displayLink == nil, view.window != nil else { return }
        let link = view.displayLink(target: self, selector: #selector(flushPendingDisplay))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func flushPendingDisplay() {
        guard let view = observedTerminalView, view.window != nil else { return }
        // No-op when nothing is dirty; flushes the pending dirty region otherwise.
        view.displayIfNeeded()
    }

    private func removeRepaintObservers() {
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

    // MARK: - TerminalViewDelegate
    //
    // `TerminalViewDelegate` is a nonisolated protocol, but this type is
    // `@MainActor`. SwiftTerm always invokes these callbacks on the main thread
    // (they fire from `feed`/key handling, which we drive on the main queue), so
    // each method is declared `nonisolated` and hops onto the main actor via
    // `MainActor.assumeIsolated` to touch our isolated state. This keeps the
    // class `@MainActor` (per spec) while satisfying the nonisolated requirement.

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            process?.setWindowSize(cols: newCols, rows: newRows)
            if CFDebug.geometry {
                let f = terminalView.frame.size
                print("[geom] sizeChanged session=\(sessionID.uuidString.prefix(8)) view=\(Int(f.width))×\(Int(f.height)) → grid=\(newCols)×\(newRows) (pushed to PTY)")
            }
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        // Could update tab title
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Optional: track current directory
    }

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Suppress kitty keyboard protocol query responses (ESC [ ? N u)
        // so apps don't discover kitty support and enable it — Claude CLI's
        // option picker doesn't handle kitty key sequences, causing arrow
        // keys to display as raw text like [57419u instead of navigating.
        if Self.isKittyKeyboardQueryResponse(data) {
            return
        }
        let payload = Data(data)
        MainActor.assumeIsolated {
            process?.write(payload)
        }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {
        // Scroll position changed
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
        }
    }

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        // Selection range changed
    }

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func bell(source: TerminalView) {
        NSSound.beep()
        MainActor.assumeIsolated {
            onBellReceived?()
        }
    }

    // MARK: - Kitty keyboard protocol helpers

    /// Strips kitty keyboard protocol push (CSI > N u) and set (CSI = N u)
    /// sequences from PTY output so SwiftTerm never enters kitty keyboard mode.
    /// Arrow keys then use legacy escape sequences that Claude CLI understands.
    nonisolated static func stripKittyKeyboardEnable(_ data: Data) -> Data {
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

    /// Detects kitty keyboard protocol query response: ESC [ ? <digits> u
    nonisolated static func isKittyKeyboardQueryResponse(_ data: ArraySlice<UInt8>) -> Bool {
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
}

// MARK: - Theme

enum DefaultTheme {
    static let background = NSColor(red: 0.10, green: 0.11, blue: 0.15, alpha: 1.0)
    static let foreground = NSColor(red: 0.75, green: 0.79, blue: 0.96, alpha: 1.0)
}
