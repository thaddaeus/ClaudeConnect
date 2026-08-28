import Foundation

/// A session's name is its ADDRESS, not a display label.
///
/// `SendMessage` resolves peers BY NAME — a session GUID is rejected, and `ListAgents`
/// `[ref]` values are session-scoped, so they do not resolve inside another session's
/// prompt. ConsoleForge passed the tab name straight to `claude --name` with no
/// uniqueness check, and the comment there called it "purely a display label".
///
/// INCIDENT 2026-08-19 (task 990003): three live sessions answered to "Hub" — two
/// BuyingBuddy processes plus the IDEA Base orchestrator. A spoke sent its completion
/// report to the wrong hub, and the right one never learned its spoke had finished. A
/// wrong-but-live address is worse than no address, because nothing errors.
///
/// So a name is claimed against the LIVE peers only. Historical rows must not reserve a
/// name forever — that would make the hub un-addressable after its first run — which is
/// why liveness is verified rather than assumed.
/// NOT SOLVED HERE — task 990003 criterion 3, renaming a tab propagating to the live peer
/// name. The CLI exposes `-n, --name` at LAUNCH only; there is no rename verb for a running
/// session, and writing the harness's own `~/.claude/sessions/<pid>.json` behind its back
/// would be state we do not own. So a rename takes effect on the tab's next launch, and
/// until then the peer answers to the name it started with. Left visibly open rather than
/// papered over, because a rename that silently does not move the address is exactly the
/// class of surprise this file exists to remove.
///
/// ALSO OUT OF REACH: the duplicate `bfg:hub` rows that show as `Remote Control · offline`
/// in ListAgents come from the ACCOUNT-level session registry, not from
/// `~/.claude/sessions`. ConsoleForge cannot prune those. What this does guarantee is that
/// no two LIVE peers share an address, which is the case that misroutes messages.
enum SessionNameRegistry {

    /// The harness's own peer registry — the same source `ListAgents` reads.
    static var sessionsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/sessions")
    }

    /// One row of that registry, reduced to what addressing depends on.
    struct Row {
        var name: String
        var pid: Int
        var procStart: String
        var socketPath: String
    }

    // MARK: - Pure logic (unit-tested; no disk, no ps)

    /// `ps -o lstart=` prints LOCAL time while the registry writes `procStart` in UTC, so
    /// the two strings never match literally. Rather than hard-code that offset — and
    /// break on the next harness version that changes its mind — a match under EITHER
    /// reading counts. A recycled pid is off by hours or days, never by a timezone.
    static func epochCandidates(_ stamp: String) -> [TimeInterval] {
        let normalized = stamp.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !normalized.isEmpty else { return [] }
        var out: [TimeInterval] = []
        for zone in [TimeZone(identifier: "UTC"), TimeZone.current] {
            guard let zone else { continue }
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            df.timeZone = zone
            if let d = df.date(from: normalized) { out.append(d.timeIntervalSince1970) }
        }
        return out
    }

    /// Whether a registry row's `procStart` describes the process `ps` is reporting.
    ///
    /// `kill -0` alone is NOT enough: pids get recycled, and a stale row whose pid now
    /// belongs to an unrelated process reads as live. Observed on a long-closed HomeHVAC
    /// session resolving as a valid address.
    static func procStartsAgree(rowStart: String, psStart: String) -> Bool {
        let want = epochCandidates(rowStart), got = epochCandidates(psStart)
        guard !want.isEmpty, !got.isEmpty else { return false }
        for a in want where got.contains(where: { abs($0 - a) <= 2 }) { return true }
        return false
    }

    /// The name to actually launch with, given the names live peers already hold.
    ///
    /// Returns `desired` untouched when it is free — that matters as much as the
    /// suffixing does, because spokes address the hub by a name they were told in
    /// advance. Renaming every launch would be "unique" and useless.
    static func uniqueName(for desired: String, takenBy taken: Set<String>) -> String {
        let trimmed = desired.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, taken.contains(trimmed) else { return trimmed }
        var n = 2
        while taken.contains("\(trimmed)-\(n)") { n += 1 }
        return "\(trimmed)-\(n)"
    }

    /// Rows that are still running AND still addressable, given a pid -> ps start map.
    /// Anything unverifiable is DROPPED rather than guessed at: a name wrongly treated as
    /// taken only costs a suffix, while one wrongly treated as free costs a misrouted
    /// message.
    static func liveRows(_ rows: [Row],
                         psStarts: [Int: String],
                         socketExists: (String) -> Bool) -> [Row] {
        rows.filter { row in
            guard !row.socketPath.isEmpty, socketExists(row.socketPath) else { return false }
            guard let seen = psStarts[row.pid] else { return false }
            return procStartsAgree(rowStart: row.procStart, psStart: seen)
        }
    }

    // MARK: - The impure edges

    static func readRows() -> [Row] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDirectory,
                                                      includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  o["sessionId"] != nil,
                  let name = o["name"] as? String,
                  let pid = o["pid"] as? Int else { return nil }
            return Row(name: name,
                       pid: pid,
                       procStart: o["procStart"] as? String ?? "",
                       socketPath: o["messagingSocketPath"] as? String ?? "")
        }
    }

    /// pid -> start time as `ps` prints it, with ZOMBIES SKIPPED.
    ///
    /// A killed session lingers as `<defunct>` until its parent reaps it, and ConsoleForge
    /// does not always reap (observed 2026-08-19 on an orphaned tab process). A zombie
    /// still answers `ps -p`, so without the state check its name blocks that name forever.
    static func psStarts(for pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty else { return [:] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "pid=,state=,lstart=", "-p", pids.map(String.init).joined(separator: ",")]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var out: [Int: String] = [:]
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            let parts = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard parts.count == 3, let pid = Int(parts[0]), !parts[1].hasPrefix("Z") else { continue }
            out[pid] = String(parts[2])
        }
        return out
    }

    /// Names held by peers that are live right now.
    static func liveNames() -> Set<String> {
        let rows = readRows()
        let live = liveRows(rows,
                            psStarts: psStarts(for: rows.map(\.pid)),
                            socketExists: { FileManager.default.fileExists(atPath: $0) })
        return Set(live.map(\.name))
    }

    /// What a tab should launch as. Excludes the row for `ownPID` so a relaunch does not
    /// collide with the process it is replacing.
    static func resolveName(for desired: String, excluding ownPID: Int? = nil) -> String {
        var taken = liveNames()
        if let ownPID, let mine = readRows().first(where: { $0.pid == ownPID }) {
            taken.remove(mine.name)
        }
        return uniqueName(for: desired, takenBy: taken)
    }
}
