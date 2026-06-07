import Foundation

/// Companion alert/snapshot state for a tab. Mirrors the spec §5.1 `state` field.
/// `bell`, `settled`, and `exited` are notify-worthy; the rest are snapshot-only.
enum CompanionState: String, Codable {
    case bell      // Claude rang the terminal bell (turn done / prompt / question)
    case settled   // a background tab streamed output, then went quiet for settleSeconds
    case exited    // the tab's process terminated (tab still open, showing the exit)
    case active    // focused tab receiving output
    case output    // background tab has unread output
    case idle      // no notable state
    case closed    // the tab was closed — remove it from the companion snapshot

    /// Whether this state is ever a candidate to push a notification (vs. snapshot-only).
    /// The actual decision also depends on the user's alert prefs (see CompanionService).
    var isAlertCandidate: Bool {
        switch self {
        case .bell, .settled, .exited: true
        case .active, .output, .idle, .closed: false
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

/// A question/prompt a session is currently blocked on, lifted as structured data
/// from the Claude transcript (never scraped from the terminal). `kind` is
/// `"question"` for an explicit multiple-choice question (AskUserQuestion tool) or
/// `"permission"` for a pending tool-approval prompt (Bash/Edit/etc.).
struct CompanionQuestion: Codable, Equatable, Sendable {
    let kind: String
    let title: String
    let options: [String]
}

/// One event in the `POST /v1/events` batch payload (spec §5.1).
///
/// `lastPrompt`/`lastResponse`/`question` are Phase-1 content fields, populated
/// from the session transcript on content-worthy states when the user has opted in
/// (CompanionSettings.includeContent). All optional so older relays/clients and
/// content-disabled events stay valid.
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
    /// True when this event carries an authoritative content read (the transcript
    /// was consulted). The relay only applies `lastPrompt`/`lastResponse`/`question`
    /// — including clearing a now-resolved question — when this is true; otherwise it
    /// preserves the tab's prior content so frequent content-less updates (e.g.
    /// `.output`) don't wipe what the phone is showing.
    let contentIncluded: Bool
    var lastPrompt: String?
    var lastResponse: String?
    var question: CompanionQuestion?
}

/// The envelope POSTed to `/v1/events` — a batch so the offline queue can flush
/// several events at once (spec §5.1).
///
/// `openTabIds` is the authoritative set of tab ids currently open on this device
/// at send time. The backend reconciles its snapshot against it (pruning anything
/// no longer open), so the companion self-heals stale tabs even if a `.closed`
/// event was missed (e.g. an app crash).
struct CompanionEventBatch: Codable {
    let v: Int
    let deviceId: String
    let events: [CompanionEvent]
    let openTabIds: [String]
}
