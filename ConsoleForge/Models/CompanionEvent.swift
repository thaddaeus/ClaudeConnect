import Foundation

/// Companion alert/snapshot state for a tab. Mirrors the spec §5.1 `state` field.
/// `bell`, `settled`, and `exited` are notify-worthy; the rest are snapshot-only.
enum CompanionState: String, Codable {
    case bell      // Claude rang the terminal bell (turn done / prompt / question)
    case settled   // a background tab streamed output, then went quiet for settleSeconds
    case exited    // the tab's process terminated
    case active    // focused tab receiving output
    case output    // background tab has unread output
    case idle      // no notable state

    /// Whether this state is ever a candidate to push a notification (vs. snapshot-only).
    /// The actual decision also depends on the user's alert prefs (see CompanionService).
    var isAlertCandidate: Bool {
        switch self {
        case .bell, .settled, .exited: true
        case .active, .output, .idle: false
        }
    }
}

/// Lightweight signal emitted by `TabActivityTracker` on a state transition.
/// Carries only the dynamic bits the tracker knows about — tab metadata
/// (name, color, icon, working dir) is merged in by the wiring layer, which
/// has access to the `SessionStore`. Keeps the tracker free of networking and
/// store dependencies.
struct CompanionSignal {
    let tabId: UUID
    let state: CompanionState
    let exitCode: Int32?

    init(tabId: UUID, state: CompanionState, exitCode: Int32? = nil) {
        self.tabId = tabId
        self.state = state
        self.exitCode = exitCode
    }
}

/// One event in the `POST /v1/events` batch payload (spec §5.1).
struct CompanionEvent: Codable {
    let tabId: String
    let name: String
    let colorHex: String
    let icon: String
    let workingDirectory: String
    let state: CompanionState
    let exitCode: Int32?
    let notify: Bool
    let ts: String
}

/// The envelope POSTed to `/v1/events` — a batch so the offline queue can flush
/// several events at once (spec §5.1).
struct CompanionEventBatch: Codable {
    let v: Int
    let deviceId: String
    let events: [CompanionEvent]
}
