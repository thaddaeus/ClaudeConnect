import Foundation

/// Launches a process with a PTY using posix_spawn instead of forkpty.
/// This avoids the "multi-threaded process forked" crash with hardened runtime.
class PtyProcess {
    let masterFd: Int32
    let pid: pid_t
    private var readSource: DispatchSourceRead?
    private var processMonitor: DispatchSourceProcess?
    private let queue = DispatchQueue(label: "com.thaddaeus.consoleforge.pty")
    var onData: ((Data) -> Void)?
    var onExit: ((Int32?) -> Void)?

    init(executable: String, args: [String], environment: [String]?, workingDirectory: String?) throws {
        var master: Int32 = 0
        var slave: Int32 = 0

        // Create PTY pair (no fork involved)
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw PtyError.openptyFailed
        }

        // Get slave device path before closing — needed to reopen in child
        // so that the open() after setsid sets it as the controlling terminal.
        guard let slaveName = ptsname(master) else {
            close(master)
            close(slave)
            throw PtyError.openptyFailed
        }
        let slaveDevicePath = String(cString: slaveName)

        self.masterFd = master

        // Set up posix_spawn attributes
        var spawnAttr: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttr)
        // Create new session (like setsid in child after fork)
        let flags: Int16 = Int16(POSIX_SPAWN_SETSID)
        posix_spawnattr_setflags(&spawnAttr, flags)

        // Set up file actions: reopen slave PTY by path after setsid to set controlling terminal.
        // On macOS/BSD, dup2'ing an inherited fd does NOT set the controlling terminal —
        // only open() on a terminal device after setsid does.
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addclose(&fileActions, master)
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, slaveDevicePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fileActions, STDIN_FILENO, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, STDIN_FILENO, STDERR_FILENO)

        // Change directory if specified
        if let dir = workingDirectory {
            posix_spawn_file_actions_addchdir_np(&fileActions, dir)
        }

        // Build argv
        let argv: [String] = [executable] + args
        let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]

        // Build envp — ensure TERM and PATH are set for proper terminal emulation.
        // macOS GUI apps have a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin).
        // Augment it with directories where claude and consoleforge-tab live.
        var envStrings = environment ?? ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        if !envStrings.contains(where: { $0.hasPrefix("TERM=") }) {
            envStrings.append("TERM=xterm-256color")
        }
        // Prepend user tool directories to PATH so the login shell finds them immediately
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // OUR OWN Resources go FIRST. The bundle ships consoleforge-tab and
        // consoleforge-chrome-mcp, and this app must run the copies it was built,
        // signed and notarized with — not whatever else on the machine answers to
        // those names. With ~/.local/bin ahead of us, a developer symlink pointing
        // at a working tree silently replaced the shipped CLI in every session,
        // including production's, and the app then executed whatever that tree
        // happened to be mid-edit. It also defeated the channel split: beta and
        // production both resolved the same foreign file, so neither ran its own
        // code. Resources is channel-correct by construction — beta's bundle
        // contains beta's script — so ordering it first is what makes
        // "beta cannot disturb production" true for the CLI as well.
        //
        // Safe to shadow with: this directory holds nothing but ConsoleForge's own
        // tools. It is deliberately NOT ahead of the user's PATH for anything else —
        // claude, git and the rest still resolve from ~/.local/bin and homebrew below.
        let extraPaths = [
            Bundle.main.resourcePath,  // app bundle Resources (consoleforge-tab)
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ].compactMap { $0 }
        if let pathIdx = envStrings.firstIndex(where: { $0.hasPrefix("PATH=") }) {
            let existing = String(envStrings[pathIdx].dropFirst(5))
            envStrings[pathIdx] = "PATH=" + (extraPaths + [existing]).joined(separator: ":")
        } else {
            envStrings.append("PATH=" + (extraPaths + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":"))
        }
        let cEnvp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]

        // Close slave in parent BEFORE spawn — this is critical!
        // The child will reopen it by path via addopen. If the parent still holds the slave
        // open at spawn time, the kernel sees TS_ISOPEN and won't set it as the controlling
        // terminal when the child opens it.
        close(slave)

        // Spawn
        var childPid: pid_t = 0
        let spawnResult = posix_spawn(&childPid, executable, &fileActions, &spawnAttr, cArgv, cEnvp)

        // Clean up C strings
        for ptr in cArgv { free(ptr) }
        for ptr in cEnvp { free(ptr) }
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&spawnAttr)

        guard spawnResult == 0 else {
            close(master)
            throw PtyError.spawnFailed(errno: spawnResult)
        }

        self.pid = childPid

        // Monitor child process exit
        processMonitor = DispatchSource.makeProcessSource(identifier: childPid, eventMask: .exit, queue: queue)
        processMonitor?.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(childPid, &status, 0)
            // WIFEXITED/WEXITSTATUS are macros unavailable in Swift — inline them
            let wstatus = status & 0x7f
            let exitCode: Int32? = (wstatus == 0) ? ((status >> 8) & 0xff) : nil
            DispatchQueue.main.async {
                self?.onExit?(exitCode)
            }
        }
        processMonitor?.resume()

        // Read from master PTY using a dispatch source for throughput.
        // We use raw read(2)/write(2) instead of DispatchIO to avoid fd guard
        // conflicts — DispatchIO guards the fd, which crashes if another dispatch
        // source also operates on it.
        let readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        readSource.setEventHandler { [weak self] in
            let bufSize = 8192
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            let n = read(master, buf, bufSize)
            if n > 0 {
                let data = Data(bytes: buf, count: n)
                self?.onData?(data)
            }
            buf.deallocate()
            if n <= 0 {
                // PTY closed or error
                readSource.cancel()
            }
        }
        readSource.setCancelHandler {
            close(master)
        }
        readSource.resume()
        self.readSource = readSource
    }

    func write(_ data: Data) {
        let copy = data
        queue.async { [weak self] in
            guard let fd = self?.masterFd else { return }
            copy.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var written = 0
                while written < buffer.count {
                    let n = Darwin.write(fd, base + written, buffer.count - written)
                    if n <= 0 { break }
                    written += n
                }
            }
        }
    }

    private var lastCols: Int = 0
    private var lastRows: Int = 0

    func setWindowSize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        // Skip redundant TIOCSWINSZ calls. (The kernel only raises SIGWINCH when
        // the winsize actually changes, so duplicates are pure ioctl noise.)
        guard cols != lastCols || rows != lastRows else { return }
        lastCols = cols
        lastRows = rows
        var size = winsize()
        size.ws_col = UInt16(cols)
        size.ws_row = UInt16(rows)
        _ = ioctl(masterFd, TIOCSWINSZ, &size)
    }

    /// Re-deliver SIGWINCH to the PTY's foreground process group without changing
    /// the winsize. The kernel only raises SIGWINCH on an actual size change, so a
    /// child that missed or raced the signal during an animated window transition
    /// never repaints its idle TUI — this nudges it. A child that already handled
    /// the resize treats it as a no-op (node emits 'resize' only when dimensions
    /// changed), and a child with no WINCH handler ignores it (default disposition),
    /// so this is safe to send unconditionally. No input bytes touch the PTY.
    func nudgeWinch() {
        let pgrp = tcgetpgrp(masterFd)
        if pgrp > 0 {
            killpg(pgrp, SIGWINCH)
        } else {
            kill(pid, SIGWINCH)
        }
    }

    /// Coax the child into a FULL re-render even when the real dimensions didn't
    /// change: briefly shrink the winsize by one row, then restore it after a short
    /// gap. The kernel raises SIGWINCH only on an actual change and node-based TUIs
    /// (incl. Claude's renderer) re-render only then, so a same-size nudge alone can be
    /// a no-op — the jiggle guarantees two real changes ending at the correct size,
    /// repainting the whole live region over any corruption. The gap keeps the two
    /// ioctls from collapsing into a single SIGWINCH. No input bytes touch the PTY.
    func jiggleWindowSize() {
        let cols = lastCols, rows = lastRows
        guard cols > 0, rows > 1 else { nudgeWinch(); return }
        setWindowSize(cols: cols, rows: rows - 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.setWindowSize(cols: cols, rows: rows)
        }
    }

    /// End the session's process for good.
    ///
    /// A single SIGHUP was not enough, and the failure was silent: the Claude CLI
    /// installs handlers for both SIGHUP and SIGTERM and keeps running under either —
    /// measured, not assumed. So closing a tab left its `claude` alive forever, and
    /// because the CLI registers itself BY NAME for peer messaging, a closed-and-
    /// reopened tab left two live processes answering to the same name. Messages then
    /// went to whichever one the registry resolved first, which is how a spoke's
    /// completion report reached the wrong hub (IDEA Base 990003).
    ///
    /// So: escalate, and signal the GROUP rather than the one pid. The child is a
    /// session leader (POSIX_SPAWN_SETSID at spawn), so its process-group id equals its
    /// pid and `kill(-pid,)` reaches everything it started — the MCP server and the
    /// browser under it — instead of orphaning them one level down.
    ///
    /// Closing the master is part of the teardown, not a side effect: it hangs up the
    /// slave, which is the polite way to end a process that is blocked reading its
    /// terminal. SIGKILL is the floor, not the plan.
    func terminate() {
        signalGroup(SIGHUP)
        // Hang up the terminal as well as signalling it.
        readSource?.cancel()   // cancel handler closes masterFd
        readSource = nil
        PtyProcess.escalate(pid: pid)
    }

    /// Escalate and reap, captured on the PID ALONE.
    ///
    /// Deliberately static and self-free: the session object is usually released the
    /// moment its tab closes, so anything written as `[weak self]` here simply does not
    /// run — which is how the first version of this fix ended the process but left a
    /// zombie behind for every tab ever closed. The work outlives the object because it
    /// never refers to it.
    private static func escalate(pid: pid_t) {
        reapQueue.asyncAfter(deadline: .now() + 1.0) {
            if reap(pid) { return }
            if kill(-pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
            reapQueue.asyncAfter(deadline: .now() + 2.0) {
                if reap(pid) { return }
                print("PtyProcess: pid \(pid) ignored SIGHUP and SIGTERM — sending SIGKILL")
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
                reapQueue.asyncAfter(deadline: .now() + 0.5) { _ = reap(pid) }
            }
        }
    }

    /// Collect the child if it has exited. Returns true once it is gone for good —
    /// reaped here, reaped by processMonitor, or never ours to begin with.
    @discardableResult
    private static func reap(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        if r == pid { return true }           // we collected it
        if r < 0 { return true }              // ECHILD: already reaped elsewhere
        return !isRunning(pid)                // r == 0: still alive, or already a zombie
    }

    private static let reapQueue = DispatchQueue(label: "com.thaddaeus.consoleforge.pty.reap")

    /// Signal the child's whole process group, falling back to the bare pid if the
    /// group is gone (which happens if the child died and was reaped between calls).
    private func signalGroup(_ sig: Int32) {
        if kill(-pid, sig) != 0 { kill(pid, sig) }
    }

    /// Alive AND not a zombie. `kill(_:0)` alone answers true for a defunct process,
    /// which would make the escalation give up exactly when it still has work to do.
    private static func isRunning(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat != SZOMB
    }

    deinit {
        processMonitor?.cancel()
        // Cancelling the read source triggers its cancel handler, which closes masterFd
        readSource?.cancel()
    }

    enum PtyError: Error {
        case openptyFailed
        case spawnFailed(errno: Int32)
    }
}
