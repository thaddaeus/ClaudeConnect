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
        let extraPaths = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            Bundle.main.resourcePath,  // app bundle Resources (consoleforge-tab)
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

    func setWindowSize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        var size = winsize()
        size.ws_col = UInt16(cols)
        size.ws_row = UInt16(rows)
        _ = ioctl(masterFd, TIOCSWINSZ, &size)
    }

    func terminate() {
        kill(pid, SIGHUP)
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
