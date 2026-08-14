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

    /// A tab can own TWO browsers, and which one you get is the whole design.
    ///
    /// `.headless` is the agent's workhorse: no window ever exists, so it cannot steal
    /// focus mid-keystroke — which was the actual complaint, not visual clutter.
    /// `.windowed` is materialised only when a human needs to look at something or sign
    /// in, and takes focus because that is precisely what was asked for.
    ///
    /// They are SEPARATE PROFILES because two Chromes cannot share a `--user-data-dir`
    /// (single-instance lock). That is a real seam: a login done in the window is not
    /// visible to the headless one. The resolution is that both expose a debugging port,
    /// so after signing in, the agent simply drives the windowed browser instead of
    /// copying cookies between them or swapping processes and losing page state.
    enum Mode: String, Codable, CaseIterable, Sendable {
        case headless
        case windowed

        var title: String { self == .headless ? "Agent Browser" : "Browser Window" }
        var profileComponent: String { self == .headless ? "headless" : "window" }
    }

    struct Instance: Identifiable, Equatable {
        let tabID: UUID
        let mode: Mode
        let pid: Int32
        let port: Int
        let profile: URL
        var url: String
        let startedAt: Date
        var id: String { "\(tabID.uuidString)-\(mode.rawValue)" }
    }

    struct Key: Hashable {
        let tabID: UUID
        let mode: Mode
    }

    private(set) var instances: [Key: Instance] = [:]
    /// Retained so the child stays ours to terminate. Dropped on exit.
    @ObservationIgnored private var processes: [Key: Process] = [:]

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

    /// `<tabID>/<mode>` — the per-tab directory is the unit the pruner reclaims, so both
    /// of a tab's profiles go away together when its session does.
    private static func profileURL(for tabID: UUID, mode: Mode) -> URL {
        profilesDirectory
            .appendingPathComponent(tabID.uuidString)
            .appendingPathComponent(mode.profileComponent)
    }

    // MARK: - Reads

    func isRunning(_ tabID: UUID, _ mode: Mode) -> Bool { instances[Key(tabID: tabID, mode: mode)] != nil }
    /// Anything at all running for this tab — what the tab bar's indicator asks.
    func isRunning(_ tabID: UUID) -> Bool { Mode.allCases.contains { isRunning(tabID, $0) } }
    func instance(for tabID: UUID, mode: Mode) -> Instance? { instances[Key(tabID: tabID, mode: mode)] }
    func modes(for tabID: UUID) -> [Mode] { Mode.allCases.filter { isRunning(tabID, $0) } }
    var runningCount: Int { instances.count }

    // MARK: - Launch

    /// Launch (or, if this tab already owns one, reuse) a Chrome bound to `tabID`.
    ///
    /// Launching the binary a second time with the SAME `--user-data-dir` does not start a
    /// second browser: Chrome routes the URL to the instance already owning that profile
    /// and raises its window. So "open" and "focus" and "navigate" are all one code path,
    /// and the handoff process exits immediately on its own.
    @discardableResult
    func open(tabID: UUID, mode: Mode = .headless, url: String = "about:blank") -> Instance? {
        guard let binary = Self.binary else { return nil }
        let key = Key(tabID: tabID, mode: mode)
        let target = Self.normalize(url)

        if var existing = instances[key] {
            // Same profile, second launch: Chrome hands the URL to the running instance
            // and raises its window. For headless there is no window to raise, so this is
            // just a navigation.
            handOff(binary: binary, profile: existing.profile, url: target)
            existing.url = target
            instances[key] = existing
            writeMetadata(for: tabID)
            return existing
        }

        let profile = Self.profileURL(for: tabID, mode: mode)
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        guard let port = Self.freePort() else { return nil }

        var args = [
            "--user-data-dir=\(profile.path)",
            "--remote-debugging-port=\(port)",
            // Without this, a CDP client connecting from a non-null origin is rejected —
            // which is every client worth attaching, including the DevTools MCP.
            "--remote-allow-origins=*",
            "--no-first-run",
            "--no-default-browser-check",
            "--no-service-autorun",
            // Local Network Access, on by default in Chrome 138+, gates a page's access to
            // LAN and VPN addresses behind a per-site grant. Every managed browser starts
            // on a FRESH --user-data-dir, so nothing the user allowed in their everyday
            // Chrome carries over and each new one begins gated — which is why a dev
            // server that resolves fine elsewhere fails here. The sub-checks are listed
            // explicitly because disabling the umbrella does not cover the WebSocket,
            // WebTransport and WebRTC paths, and a dev server reached over a socket would
            // still have failed.
            //
            // Scoped and deliberate: these profiles exist to reach the user's own
            // development machines, they are isolated per tab, and they are thrown away
            // with the tab. This is NOT applied to any browser the user already had.
            "--disable-features=LocalNetworkAccessChecks,LocalNetworkAccessChecksWebSockets," +
            "LocalNetworkAccessChecksWebTransport,LocalNetworkAccessChecksWebRTC",
        ]
        if mode == .headless {
            // The point of the mode: no window is ever created, so nothing can take focus
            // away from what the user is typing into. Screenshots and the full protocol
            // still work — headless renders for real.
            args.append("--headless=new")
        } else {
            args.append("--new-window")
        }
        args.append(target)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        // Chrome is noisy on stderr and none of it is ours to surface.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            print("ManagedChrome: launch failed — \(error)")
            return nil
        }

        let instance = Instance(tabID: tabID, mode: mode, pid: process.processIdentifier,
                                port: port, profile: profile, url: target, startedAt: Date())
        processes[key] = process
        instances[key] = instance
        writeMetadata(for: tabID)

        // The user can quit Chrome themselves; when they do, forget it rather than
        // leaving a tab claiming to own a browser that is gone.
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.forget(key) }
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

    // MARK: - Wiring a session to its own browser

    /// Where a tab's private MCP config lives.
    static func mcpConfigURL(for tabID: UUID) -> URL {
        metadataDirectory.appendingPathComponent("\(tabID.uuidString)-mcp.json")
    }

    /// Write the per-tab MCP config. Starts NOTHING.
    ///
    /// The config names a wrapper script rather than a port, so the browser is started on
    /// FIRST USE instead of at session launch. A headless Chrome is 100-200MB; one per tab
    /// at launch is fine for four tabs and indefensible for the fifteen a real day
    /// involves. Claude Code starts an MCP server lazily, the first time one of its tools
    /// is called, so the wrapper runs exactly when a browser is actually wanted — see
    /// scripts/consoleforge-chrome-mcp.
    ///
    /// The server is deliberately named `chrome-devtools`, the same as the global entry,
    /// so it SHADOWS it for this session rather than adding a second one.
    ///
    /// Returns the config path for `claude --mcp-config`, or nil if Chrome is not
    /// installed or the wrapper is missing — in which case the session launches exactly
    /// as it always did.
    func writeSessionMCPConfig(tabID: UUID) -> String? {
        guard Self.binary != nil, let wrapper = Self.wrapperPath else { return nil }
        let config: [String: Any] = [
            "mcpServers": [
                "chrome-devtools": [
                    "type": "stdio",
                    "command": wrapper,
                    "args": [String](),
                ]
            ]
        ]
        let url = Self.mcpConfigURL(for: tabID)
        try? FileManager.default.createDirectory(at: Self.metadataDirectory,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: config,
                                                     options: [.prettyPrinted, .sortedKeys]),
              (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url.path
    }

    /// The wrapper ships in the app bundle; the repo copy is the fallback for `swift run`.
    static let wrapperPath: String? = {
        var candidates: [String] = []
        if let res = Bundle.main.resourcePath {
            candidates.append(res + "/consoleforge-chrome-mcp")
        }
        candidates.append(FileManager.default.currentDirectoryPath + "/scripts/consoleforge-chrome-mcp")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Start the headless browser if it is not already up. Called when the wrapper asks,
    /// i.e. the moment a session first reaches for a browser.
    func ensureHeadless(tabID: UUID) {
        guard !isRunning(tabID, .headless) else { return }
        open(tabID: tabID, mode: .headless)
    }

    // MARK: - Terminate

    /// Criterion 14's second half. SIGTERM first so Chrome writes its profile out
    /// cleanly, then SIGKILL if it is still there — a browser that refuses to close must
    /// not outlive the tab that owns it, which is the entire promise being made here.
    func terminate(_ tabID: UUID, _ mode: Mode) {
        let key = Key(tabID: tabID, mode: mode)
        guard let instance = instances[key] else { return }
        let process = processes[key]
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
        forget(key)
    }

    /// BOTH of a tab's browsers. This is what the tab-close path calls — criterion 14
    /// says the tab owns its browser, and it owns every one of them.
    func terminate(_ tabID: UUID) {
        for mode in Mode.allCases { terminate(tabID, mode) }
    }

    func terminateAll() {
        for key in Array(instances.keys) { terminate(key.tabID, key.mode) }
    }

    /// Terminate synchronously, for app teardown — there is no run loop left to await a
    /// grace period on, so SIGTERM goes out and we do not linger.
    func terminateAllNow() {
        for (key, instance) in instances {
            processes[key]?.terminationHandler = nil
            if instance.pid > 0 { kill(instance.pid, SIGTERM) }
        }
        for tabID in Set(instances.keys.map(\.tabID)) {
            try? FileManager.default.removeItem(at: Self.metadataURL(for: tabID))
        }
        instances.removeAll()
        processes.removeAll()
    }

    private func forget(_ key: Key) {
        processes.removeValue(forKey: key)
        instances.removeValue(forKey: key)
        writeMetadata(for: key.tabID)
        if !Mode.allCases.contains(where: { instances[Key(tabID: key.tabID, mode: $0)] != nil }) {
            try? FileManager.default.removeItem(at: Self.mcpConfigURL(for: key.tabID))
        }
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
            for entry in meta.browsers {
                let profile = URL(fileURLWithPath: entry.profileDir)
                if Self.isAlive(entry.pid, profile: profile) {
                    print("ManagedChrome: reaping orphaned \(entry.mode) Chrome pid \(entry.pid)")
                    kill(entry.pid, SIGTERM)
                }
            }
        }
    }

    /// Delete profile directories whose session no longer exists.
    ///
    /// A profile is a real browser profile — cookies, logins, history — so it lives
    /// exactly as long as the session it belongs to, and not one launch longer. A saved
    /// session keeps its UUID across close and reopen, so its profile survives and you
    /// stay logged in; an EPHEMERAL tab is deleted from the store when it closes, and its
    /// profile then belongs to nobody. Without this they accumulate silently: five
    /// throwaway tabs during the Phase C test run left 81 MB behind.
    ///
    /// Deliberately keyed on "the session is gone", not "the tab is closed" — deleting a
    /// saved session's browser state every time its tab closed would log the user out of
    /// everything, repeatedly, for no reason they could see.
    func pruneProfiles(knownSessionIDs: Set<UUID>) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Self.profilesDirectory,
                                                     includingPropertiesForKeys: nil) else { return }
        // `instances` only knows about browsers WE started. This runs right after
        // reapOrphans(), which merely SIGTERMs a stranded Chrome from a previous run and
        // does not wait — so without this the directory could be deleted out from under a
        // browser still writing its profile out. One `ps` for the whole sweep.
        let commands = Self.runningCommandLines()
        for dir in dirs {
            // Only ever touch directories that are named like one of ours, and never one
            // whose browser is live right now.
            guard let id = UUID(uuidString: dir.lastPathComponent),
                  !knownSessionIDs.contains(id),
                  Mode.allCases.allSatisfy({ instances[Key(tabID: id, mode: $0)] == nil }),
                  // The tab directory holds BOTH profiles, so check for either in use.
                  !commands.contains("--user-data-dir=\(dir.path)") else { continue }
            try? fm.removeItem(at: dir)
            print("ManagedChrome: pruned orphaned profile for \(id.uuidString)")
        }
    }

    /// Every running process's command line, in one shot, so the prune can tell a dead
    /// profile from one a shutting-down browser still has open.
    private static func runningCommandLines() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-eo", "command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return out
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

    /// One file per TAB listing every browser it owns, so a session can read its own
    /// ports without knowing how many browsers exist or which mode it wants first.
    struct Metadata: Codable {
        struct Entry: Codable {
            let mode: String
            let pid: Int32
            let port: Int
            /// Ready to hand to `chrome-devtools-mcp --browserUrl`.
            let browserUrl: String
            let profileDir: String
            let url: String
            let startedAt: Date
        }
        let tabID: String
        let appSupport: String
        let browsers: [Entry]
    }

    private func writeMetadata(for tabID: UUID) {
        let mine = Mode.allCases.compactMap { instances[Key(tabID: tabID, mode: $0)] }
        let url = Self.metadataURL(for: tabID)
        guard !mine.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let meta = Metadata(
            tabID: tabID.uuidString,
            appSupport: AppChannel.supportDirectory().path,
            browsers: mine.map {
                .init(mode: $0.mode.rawValue, pid: $0.pid, port: $0.port,
                      browserUrl: "http://127.0.0.1:\($0.port)",
                      profileDir: $0.profile.path, url: $0.url, startedAt: $0.startedAt)
            })
        try? FileManager.default.createDirectory(at: Self.metadataDirectory,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: url, options: .atomic)
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
