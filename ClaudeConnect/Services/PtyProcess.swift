import Foundation

/// Launches a process with a PTY using posix_spawn instead of forkpty.
/// This avoids the "multi-threaded process forked" crash with hardened runtime.
class PtyProcess {
    let masterFd: Int32
    let pid: pid_t
    private var io: DispatchIO?
    private var processMonitor: DispatchSourceProcess?
    private let queue = DispatchQueue(label: "com.thaddaeus.claudeconnect.pty")
    var onData: ((Data) -> Void)?
    var onExit: ((Int32?) -> Void)?

    init(executable: String, args: [String], environment: [String]?, workingDirectory: String?) throws {
        var master: Int32 = 0
        var slave: Int32 = 0

        // Create PTY pair (no fork involved)
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw PtyError.openptyFailed
        }

        self.masterFd = master

        // Set up posix_spawn attributes
        var spawnAttr: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttr)
        // Create new session (like setsid in child after fork)
        let flags: Int16 = Int16(POSIX_SPAWN_SETSID)
        posix_spawnattr_setflags(&spawnAttr, flags)

        // Set up file actions: map slave PTY to stdin/stdout/stderr
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, slave)
        posix_spawn_file_actions_addclose(&fileActions, master)

        // Change directory if specified
        if let dir = workingDirectory {
            posix_spawn_file_actions_addchdir_np(&fileActions, dir)
        }

        // Build argv
        let argv: [String] = [executable] + args
        let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]

        // Build envp
        let envStrings = environment ?? ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let cEnvp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]

        // Spawn
        var childPid: pid_t = 0
        let spawnResult = posix_spawn(&childPid, executable, &fileActions, &spawnAttr, cArgv, cEnvp)

        // Clean up C strings
        for ptr in cArgv { free(ptr) }
        for ptr in cEnvp { free(ptr) }
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&spawnAttr)

        // Close slave in parent
        close(slave)

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

        // Read from master PTY — cleanup handler closes the fd when DispatchIO is done
        io = DispatchIO(type: .stream, fileDescriptor: master, queue: queue) { fd in
            close(fd)
        }
        io?.setLimit(lowWater: 1)
        io?.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
            if let data = data, !data.isEmpty {
                let bytes = Data(data)
                self?.onData?(bytes)
            }
            if done || error != 0 {
                // PTY closed
            }
        }
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            let dispatchData = DispatchData(bytes: UnsafeRawBufferPointer(start: baseAddress, count: buffer.count))
            io?.write(offset: 0, data: dispatchData, queue: queue) { _, _, _ in }
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
        // DispatchIO.close() triggers the cleanup handler which closes masterFd
        // Do NOT close masterFd here — that races with DispatchIO and causes EV_VANISHED
        io?.close()
    }

    enum PtyError: Error {
        case openptyFailed
        case spawnFailed(errno: Int32)
    }
}
