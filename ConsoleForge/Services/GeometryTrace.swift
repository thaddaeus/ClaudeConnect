import Foundation
import SwiftUI

/// Beta-only geometry instrumentation.
///
/// The terminal's size is the most fragile thing in this app — a reflow at a wrong
/// width corrupts the SwiftTerm buffer permanently — and "it flashed and re-wrapped"
/// is impossible to debug by eye. This records the full chain, container px → SwiftTerm
/// grid → PTY winsize, with every rejected and coalesced size in between.
///
/// **Never runs in production.** Gated on `AppChannel.isProduction` exactly like the
/// beta's support directory and Keychain namespace, so a shipping build carries no
/// buffer, no file handle and no HUD. `record` compiles to an immediate return there.
@MainActor
@Observable
final class GeometryTrace {
    static let shared = GeometryTrace()

    /// Beta (and unbundled `swift run`) only.
    static let isEnabled = !AppChannel.isProduction

    struct Event: Identifiable, Codable {
        var id = UUID()
        var at: Date
        /// setSize / applied / rejected / grid / resync / park
        var stage: String
        var detail: String

        var line: String {
            "\(Event.stamp.string(from: at))  \(stage.padding(toLength: 9, withPad: " ", startingAt: 0)) \(detail)"
        }
        static let stamp: DateFormatter = {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
        }()
    }

    private(set) var events: [Event] = []
    /// Toggled from the beta-only Layout ▸ Geometry Debug item (⌘⇧D).
    var isOverlayVisible = false
    /// Latest known chain, for the HUD's top line.
    private(set) var container: CGSize = .zero
    private(set) var grid: (cols: Int, rows: Int) = (0, 0)
    private(set) var pty: (cols: Int, rows: Int) = (0, 0)

    private let limit = 400
    @ObservationIgnored private var handle: FileHandle?

    private init() {
        guard Self.isEnabled else { return }
        let url = AppChannel.supportDirectory("debug").appendingPathComponent("geometry.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        fileURL = url
    }

    private(set) var fileURL: URL?

    func record(_ stage: String, _ detail: String) {
        guard Self.isEnabled else { return }
        let event = Event(at: Date(), stage: stage, detail: detail)
        events.append(event)
        if events.count > limit { events.removeFirst(events.count - limit) }
        if let handle, var data = try? JSONEncoder().encode(event) {
            data.append(0x0A)
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    func noteContainer(_ size: CGSize) {
        guard Self.isEnabled else { return }
        container = size
    }

    func noteGrid(cols: Int, rows: Int) {
        guard Self.isEnabled else { return }
        grid = (cols, rows)
    }

    func notePTY(cols: Int, rows: Int) {
        guard Self.isEnabled else { return }
        pty = (cols, rows)
    }

    func clear() {
        events.removeAll()
        try? handle?.truncate(atOffset: 0)
        try? handle?.seek(toOffset: 0)
    }

    var transcript: String { events.map(\.line).joined(separator: "\n") }
}

/// Non-isolated shim so `TerminalSession`'s `sizeChanged` delegate callback — which
/// arrives off the main actor — can record without restructuring.
func recordGeometry(_ stage: String, _ detail: String) {
    guard GeometryTrace.isEnabled else { return }
    Task { @MainActor in GeometryTrace.shared.record(stage, detail) }
}
