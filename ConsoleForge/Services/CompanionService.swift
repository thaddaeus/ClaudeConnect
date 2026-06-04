import Foundation
import Observation

/// Errors surfaced to the Settings UI (sign-in / relay failures).
enum CompanionError: LocalizedError {
    case noRelayURL
    case relayStatus(Int)
    case badResponse
    case notSignedIn
    case supportUnavailable

    var errorDescription: String? {
        switch self {
        case .noRelayURL: "No relay URL configured."
        case .relayStatus(let code): "Relay returned HTTP \(code)."
        case .badResponse: "Unexpected response from the relay."
        case .notSignedIn: "Sign in with GitHub first."
        case .supportUnavailable: "Support isn’t available yet — please try again later."
        }
    }
}

/// Builds companion events from tracker signals + tab metadata, holds the device
/// token (Keychain), and POSTs batches to the relay with a bounded offline queue
/// that survives network outages and coalesces redundant snapshot updates.
@MainActor
@Observable
final class CompanionService {
    /// Observable connection status for the Settings UI.
    private(set) var queuedCount: Int = 0
    private(set) var lastSuccessfulPost: Date?
    private(set) var lastError: String?

    // Set once in the nonisolated init before any concurrency; only read thereafter.
    @ObservationIgnored private nonisolated(unsafe) let settings: CompanionSettings
    @ObservationIgnored private var queue: [QueuedEvent] = []
    @ObservationIgnored private var isFlushing = false
    @ObservationIgnored private var nextSeq: UInt64 = 0
    @ObservationIgnored private let maxQueue = 50
    @ObservationIgnored private let iso = ISO8601DateFormatter()

    private struct QueuedEvent {
        let id: UInt64
        let event: CompanionEvent
    }

    nonisolated init(settings: CompanionSettings) {
        self.settings = settings
    }

    // MARK: - Ingest

    /// Build an event from a tracker signal + (optional) tab metadata, decide
    /// whether it should notify, enqueue it, and kick a flush.
    func report(_ signal: CompanionSignal, config: SessionConfiguration?) {
        guard settings.companionEnabled else { return }
        let event = CompanionEvent(
            tabId: signal.tabId.uuidString,
            name: config?.name ?? "Session",
            colorHex: config?.tabColorHex ?? "#007AFF",
            icon: config?.tabIconName ?? "terminal",
            workingDirectory: config?.workingDirectory ?? "",
            state: signal.state,
            exitCode: signal.exitCode,
            notify: shouldNotify(signal.state),
            ts: iso.string(from: Date())
        )
        enqueue(event)
    }

    private func shouldNotify(_ state: CompanionState) -> Bool {
        switch state {
        case .bell: settings.alertOnBell
        case .settled: settings.alertOnSettled
        case .exited: settings.alertOnExit
        case .active, .output, .idle: false
        }
    }

    private func enqueue(_ event: CompanionEvent) {
        // Coalesce: a fresh snapshot-only update (active/output/idle) supersedes any
        // earlier still-queued snapshot for the same tab. Alert events (bell/settled/
        // exited) are always kept distinct so none are lost.
        if !event.state.isAlertCandidate {
            queue.removeAll { !$0.event.state.isAlertCandidate && $0.event.tabId == event.tabId }
        }
        queue.append(QueuedEvent(id: nextSeq, event: event))
        nextSeq &+= 1
        if queue.count > maxQueue {
            queue.removeFirst(queue.count - maxQueue)
        }
        queuedCount = queue.count
        Task { await flush() }
    }

    // MARK: - Network

    /// POST whatever is queued. Keeps the queue intact on failure (offline-safe);
    /// removes exactly the flushed items by id on success, so events appended during
    /// the in-flight request survive.
    func flush() async {
        guard settings.companionEnabled, !isFlushing, !queue.isEmpty else { return }
        guard let base = normalizedBaseURL() else { return }
        guard let url = URL(string: base + "/v1/events") else { return }
        guard let token = deviceToken() else { return } // not signed in yet

        isFlushing = true
        defer { isFlushing = false }

        let inFlight = queue
        let payload = CompanionEventBatch(v: 1, deviceId: settings.deviceId, events: inFlight.map(\.event))

        do {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONEncoder().encode(payload)

            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                lastError = CompanionError.badResponse.localizedDescription
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                lastError = CompanionError.relayStatus(http.statusCode).localizedDescription
                return  // keep queue for retry
            }
            let flushedIDs = Set(inFlight.map(\.id))
            queue.removeAll { flushedIDs.contains($0.id) }
            queuedCount = queue.count
            lastSuccessfulPost = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription  // keep queue for retry
        }
    }

    // MARK: - Token & URL helpers

    /// The login-minted device token from the Keychain (written by CompanionAuth on
    /// sign-in). Nil until the user signs in, which is when the poster goes live.
    private func deviceToken() -> String? {
        KeychainStore.read(account: CompanionKeychain.deviceToken)
    }

    /// Clears the offline queue + connection status (e.g. on sign-out / disable).
    func reset() {
        queue.removeAll()
        queuedCount = 0
        lastError = nil
        lastSuccessfulPost = nil
    }

    /// Trims a trailing slash and rejects an empty URL.
    private func normalizedBaseURL() -> String? {
        var s = settings.relayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? nil : s
    }
}
