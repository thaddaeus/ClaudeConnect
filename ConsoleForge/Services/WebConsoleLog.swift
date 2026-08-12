import Foundation

/// One captured line from the in-app browser: a `console.*` call, an uncaught error,
/// or a completed request.
struct WebConsoleEntry: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case console, network }

    var id = UUID()
    var kind: Kind
    var timestamp: Date
    /// log / info / warn / error / debug, for `.console`.
    var level: String?
    var text: String?
    /// `.network` only.
    var method: String?
    var url: String?
    var status: Int?
    var milliseconds: Int?
    var error: String?

    var isFailure: Bool {
        if kind == .network { return (status ?? 0) == 0 || (status ?? 0) >= 400 }
        return level == "error"
    }

    /// One line, the shape you would want pasted into a terminal.
    var line: String {
        let stamp = WebConsoleEntry.stampFormatter.string(from: timestamp)
        switch kind {
        case .console:
            return "\(stamp) [\(level ?? "log")] \(text ?? "")"
        case .network:
            let code = status.map(String.init) ?? "—"
            let ms = milliseconds.map { "\($0)ms" } ?? ""
            let suffix = error.map { " \($0)" } ?? ""
            return "\(stamp) [net] \(method ?? "GET") \(code) \(ms) \(url ?? "")\(suffix)"
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// Console and network output captured from the in-app browser.
///
/// This is the whole reason the browser is *in* the tool. Web Inspector cannot be
/// hosted in a slot (WebKit owns its window) and driving it from Safari puts the
/// output somewhere neither this app nor the agent in the console can reach. So the
/// page is instrumented directly instead — see `WebConsoleScript` — and everything it
/// reports lands here: in a panel you can read, and in a JSONL file the console can
/// `tail`, which is what makes it usable from a session rather than only by eye.
@MainActor
@Observable
final class WebConsoleLog {
    private(set) var entries: [WebConsoleEntry] = []
    /// Ring-buffer bound. A chatty page must not grow the process without limit.
    private let limit = 2000

    /// Where the live log is mirrored, so a session can read it:
    /// `~/Library/Application Support/ConsoleForge[ Beta]/web-console/session.jsonl`
    let fileURL: URL

    @ObservationIgnored private var handle: FileHandle?

    init() {
        fileURL = AppChannel.supportDirectory("web-console").appendingPathComponent("session.jsonl")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
    }

    deinit { try? handle?.close() }

    func append(_ entry: WebConsoleEntry) {
        entries.append(entry)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        write(entry)
    }

    func clear() {
        entries.removeAll()
        try? handle?.truncate(atOffset: 0)
        try? handle?.seek(toOffset: 0)
    }

    var transcript: String {
        entries.map(\.line).joined(separator: "\n")
    }

    /// Appended as JSONL rather than the pretty line, so the console side can filter
    /// with `jq` instead of parsing text back apart.
    private func write(_ entry: WebConsoleEntry) {
        guard let handle,
              var data = try? JSONEncoder().encode(entry) else { return }
        data.append(0x0A)
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
