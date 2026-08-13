import Foundation
import AppKit

/// Chrome instances owned by a tab — task 9736 Phase C, criterion 14.
///
/// A SOFT ATTACH, never a pixel embed. Chrome is not drawn inside a slot: it runs as
/// its own application window and what ConsoleForge owns is its LIFETIME. That was the
/// decision from the start and the reason is that embedding means CEF, which is a
/// hundred-megabyte dependency and a second browser engine to keep patched, to gain a
/// rectangle. The win here is unified ownership: a browser that belongs to a tab, dies
/// with it, and cannot leak into the next piece of work.
///
/// **Ownership is real, not nominal.** Chrome is spawned as a CHILD PROCESS of this app
/// (`Process`, launching the binary directly) rather than handed to `open`, which would
/// detach it into launchd and leave us with nothing to terminate. Each instance gets its
/// own `--user-data-dir`, so it is a genuinely separate browser — separate cookies,
/// separate logins, separate session — and it never touches the user's real Chrome
/// profile.
///
/// **Each instance also gets `--remote-debugging-port`**, and the port is published to
/// `…/ConsoleForge[ Beta]/chrome/<tabID>.json`. That file is the whole point of the port:
/// a session can read it and point the chrome-devtools MCP at ITS OWN browser instead of
/// whatever Chrome happens to be running. CDP console/network capture inside the app is a
/// later escalation; this is the cheap half of it and it costs one flag.
@MainActor
@Observable
final class ManagedChrome {
    static let shared = ManagedChrome()

    struct Instance: Identifiable, Equatable {
        let tabID: UUID
        let pid: Int32
        let port: Int
        let profile: URL
        var url: String
        let startedAt: Date
        var id: UUID { tabID }
    }

    private(set) var instances: [UUID: Instance] = [:]
    /// Retained so the child stays ours to terminate. Keyed by tab, dropped on exit.
    @ObservationIgnored private var processes: [UUID: Process] = [:]

    private init() {}

    // MARK: - Where things live

    /// Chrome, if it is installed. Canary and Chromium are accepted so a machine without
    /// stable Chrome is not silently dead — the menu item disables itself instead.
    static let binary: String? = {
        let candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    var isAvailable: Bool { Self.binary != nil }

    private static var profilesDirectory: URL {
        AppChannel.supportDirectory().appendingPathComponent("chrome-profiles")
    }

    private static var metadataDirectory: URL {
        AppChannel.supportDirectory().appendingPathComponent("chrome")
    }

    /// Where a session can read its own browser's debugging port.
    static func metadataURL(for tabID: UUID) -> URL {
        metadataDirectory.appendingPathComponent("\(tabID.uuidString).json")
    }

    private static func profileURL(for tabID: UUID) -> URL {
        profilesDirectory.appendingPathComponent(tabID.uuidString)
    }

    // MARK: - Reads

    func isRunning(_ tabID: UUID) -> Bool { instances[tabID] != nil }
    func instance(for tabID: UUID) -> Instance? { instances[tabID] }
    var runningCount: Int { instances.count }

    // MARK: - Launch

    /// Launch (or, if this tab already owns one, reuse) a Chrome bound to `tabID`.
    ///
    /// Launching the binary a second time with the SAME `--user-data-dir` does not start a
    /// second browser: Chrome routes the URL to the instance already owning that profile
    /// and raises its window. So "open" and "focus" and "navigate" are all one code path,
    /// and the handoff process exits immediately on its own.
    @discardableResult
    func open(tabID: UUID, url: String = "about:blank") -> Instance? {
        guard let binary = Self.binary else { return nil }
        let target = Self.normalize(url)

        if var existing = instances[tabID] {
            handOff(binary: binary, profile: existing.profile, url: target)
            existing.url = target
            instances[tabID] = existing
            writeMetadata(existing)
            return existing
        }

        let profile = Self.profileURL(for: tabID)
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        guard let port = Self.freePort() else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "--user-data-dir=\(profile.path)",
            "--remote-debugging-port=\(port)",
            // Without this, a CDP client connecting from a non-null origin is rejected —
            // which is every client worth attaching, including the DevTools MCP.
            "--remote-allow-origins=*",
            "--no-first-run",
            "--no-default-browser-check",
            "--no-service-autorun",
            "--new-window",
            target,
        ]
        // Chrome is noisy on stderr and none of it is ours to surface.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            print("ManagedChrome: launch failed — \(error)")
            return nil
        }

        let instance = Instance(tabID: tabID, pid: process.processIdentifier, port: port,
                                profile: profile, url: target, startedAt: Date())
        processes[tabID] = process
        instances[tabID] = instance
        writeMetadata(instance)

        // The user can quit Chrome themselves; when they do, forget it rather than
        // leaving a tab claiming to own a browser that is gone.
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.forget(tabID) }
        }
        return instance
    }

    /// Second launch against a live profile: Chrome hands the URL to the running instance
    /// and this process exits by itself. Not retained — it is a messenger, not a browser.
    private func handOff(binary: String, profile: URL, url: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["--user-data-dir=\(profile.path)", url]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: - Terminate

    /// Criterion 14's second half. SIGTERM first so Chrome writes its profile out
    /// cleanly, then SIGKILL if it is still there — a browser that refuses to close must
    /// not outlive the tab that owns it, which is the entire promise being made here.
    func terminate(_ tabID: UUID) {
        guard let instance = instances[tabID] else { return }
        let process = processes[tabID]
        process?.terminationHandler = nil          // we are the ones ending it
        if process?.isRunning == true {
            process?.terminate()
        } else if instance.pid > 0 {
            kill(instance.pid, SIGTERM)
        }
        let pid = instance.pid
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            if Self.isAlive(pid, profile: instance.profile) { kill(pid, SIGKILL) }
        }
        forget(tabID)
    }

    func terminateAll() {
        for tabID in Array(instances.keys) { terminate(tabID) }
    }

    /// Terminate synchronously, for app teardown — there is no run loop left to await a
    /// grace period on, so SIGTERM goes out and we do not linger.
    func terminateAllNow() {
        for (tabID, instance) in instances {
            processes[tabID]?.terminationHandler = nil
            if instance.pid > 0 { kill(instance.pid, SIGTERM) }
            try? FileManager.default.removeItem(at: Self.metadataURL(for: tabID))
        }
        instances.removeAll()
        processes.removeAll()
    }

    private func forget(_ tabID: UUID) {
        processes.removeValue(forKey: tabID)
        instances.removeValue(forKey: tabID)
        try? FileManager.default.removeItem(at: Self.metadataURL(for: tabID))
    }

    // MARK: - Orphans

    /// Kill Chromes left behind by a previous run, at startup.
    ///
    /// A child process is not killed by its parent dying: if ConsoleForge is force-quit or
    /// crashes, its Chromes are reparented to launchd and keep running, and "the browser
    /// dies with the tab" quietly stops being true. The metadata files are what make this
    /// recoverable — each records a pid.
    ///
    /// A recorded pid is NOT trusted on its own: pids are recycled, and killing a stale
    /// number could hit anything. Each one is verified to still be a Chrome running
    /// against OUR profile directory before a signal is sent.
    func reapOrphans() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.metadataDirectory, withIntermediateDirectories: true)
        guard let files = try? fm.contentsOfDirectory(at: Self.metadataDirectory,
                                                      includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            defer { try? fm.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let meta = try? JSONDecoder().decode(Metadata.self, from: data) else { continue }
            let profile = URL(fileURLWithPath: meta.profileDir)
            if Self.isAlive(meta.pid, profile: profile) {
                print("ManagedChrome: reaping orphaned Chrome pid \(meta.pid) from a previous run")
                kill(meta.pid, SIGTERM)
            }
        }
    }

    /// Is `pid` alive AND actually a Chrome running against `profile`? Both halves matter:
    /// the first alone would be a pid-reuse hazard.
    private static func isAlive(_ pid: Int32, profile: URL) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", "\(pid)", "-o", "command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return out.contains(profile.path)
    }

    // MARK: - Metadata

    private struct Metadata: Codable {
        let tabID: String
        let pid: Int32
        let port: Int
        let profileDir: String
        let url: String
        let startedAt: Date
        /// So a reader knows which app owns it without guessing from the path.
        let appSupport: String
    }

    private func writeMetadata(_ instance: Instance) {
        let meta = Metadata(tabID: instance.tabID.uuidString, pid: instance.pid,
                            port: instance.port, profileDir: instance.profile.path,
                            url: instance.url, startedAt: instance.startedAt,
                            appSupport: AppChannel.supportDirectory().path)
        try? FileManager.default.createDirectory(at: Self.metadataDirectory,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: Self.metadataURL(for: instance.tabID), options: .atomic)
    }

    // MARK: - Helpers

    /// Ask the kernel for a free port by binding to 0 and reading back what it gave us.
    /// There is a race between closing this and Chrome binding it; it is the standard one
    /// and the window is microseconds.
    private static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard got == 0 else { return nil }
        return Int(UInt16(bigEndian: out.sin_port))
    }

    /// Accept what a person would type. A bare host or path is not a valid URL to Chrome
    /// and it would silently open a search instead.
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "about:blank" }
        if trimmed.contains("://") || trimmed.hasPrefix("about:") { return trimmed }
        if trimmed.hasPrefix("/") { return "file://\(trimmed)" }
        if trimmed.contains(" ") || !trimmed.contains(".") { return trimmed }
        return "https://\(trimmed)"
    }
}
