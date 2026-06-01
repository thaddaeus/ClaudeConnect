import Foundation
import Observation

/// Errors surfaced to the Settings UI (e.g. when pairing).
enum CompanionError: LocalizedError {
    case noRelayURL
    case tokenUnavailable
    case relayStatus(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noRelayURL: "Set a relay URL first."
        case .tokenUnavailable: "Could not access the device token in the Keychain."
        case .relayStatus(let code): "Relay returned HTTP \(code)."
        case .badResponse: "Unexpected response from the relay."
        }
    }
}

/// Result of a pairing request (spec §6).
struct PairingCode {
    let code: String
    let expiresAt: Date?
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
    @ObservationIgnored private let tokenAccount = "companion.deviceToken"
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
        guard let token = ensureDeviceToken() else { return }

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

    /// Request a short-lived pairing code from the relay (spec §6).
    func pair() async throws -> PairingCode {
        guard let base = normalizedBaseURL(), let url = URL(string: base + "/v1/pair") else {
            throw CompanionError.noRelayURL
        }
        guard let token = ensureDeviceToken() else { throw CompanionError.tokenUnavailable }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(["deviceId": settings.deviceId])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CompanionError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw CompanionError.relayStatus(http.statusCode) }

        let decoded = try JSONDecoder().decode(PairResponse.self, from: data)
        let expires = decoded.expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        return PairingCode(code: decoded.code, expiresAt: expires)
    }

    private struct PairResponse: Decodable {
        let code: String
        let expiresAt: String?
    }

    // MARK: - Token & URL helpers

    /// Reads the device token from the Keychain, generating + persisting one on
    /// first use. The token is the bearer secret on `/v1/events` and `/v1/pair`.
    private func ensureDeviceToken() -> String? {
        if let existing = KeychainStore.read(account: tokenAccount) { return existing }
        guard let token = Self.randomToken() else { return nil }
        return KeychainStore.write(token, account: tokenAccount) ? token : nil
    }

    /// Drops the device token (called when the user disables the companion), so a
    /// re-enable starts a fresh trust-on-first-use registration.
    func resetDeviceToken() {
        KeychainStore.delete(account: tokenAccount)
        queue.removeAll()
        queuedCount = 0
        lastError = nil
        lastSuccessfulPost = nil
    }

    private static func randomToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return Data(bytes).base64EncodedString()
    }

    /// Trims a trailing slash and rejects an empty URL.
    private func normalizedBaseURL() -> String? {
        var s = settings.relayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? nil : s
    }
}
