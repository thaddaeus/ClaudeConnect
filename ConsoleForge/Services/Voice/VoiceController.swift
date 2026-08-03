import Foundation
import Observation

/// Orchestrates the voice channel: what gets spoken, and (from phase 2) what gets heard.
///
/// Owns the pieces and the policy; the panel is a pure view of this object's state. Only
/// the **active** tab is audible — retargeting follows `SessionStore.activeTabID`, so what
/// you hear is always what you're looking at.
@MainActor
@Observable
final class VoiceController {

    /// One line in the panel's rolling exchange log.
    struct Exchange: Identifiable {
        enum Speaker { case user, assistant, system }
        let id = UUID()
        let speaker: Speaker
        /// Tab name for assistant lines, so the log stays readable across a retarget.
        let source: String
        let text: String
        let at: Date
    }

    /// Master switch. Persisted; when off nothing is spoken and (phase 2) the mic is closed.
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            guard isEnabled != oldValue else { return }
            if isEnabled { retargetToActiveTab() } else { shutDown() }
        }
    }

    /// Whether the panel is showing. Persisted separately from `isEnabled` so voice can
    /// keep running with the panel collapsed.
    var isPanelVisible: Bool {
        didSet { UserDefaults.standard.set(isPanelVisible, forKey: Self.panelKey) }
    }

    let speech = SpeechOutput()

    private(set) var exchanges: [Exchange] = []
    /// Name of the tab currently being listened to, for the panel's target line.
    private(set) var targetTabName: String?

    private static let enabledKey = "VoiceEnabled"
    private static let panelKey = "VoicePanelVisible"
    private static let maxExchanges = 60

    private let tailer = TranscriptTailer()
    /// Set by the app so the controller can resolve the active tab without owning a
    /// `SessionStore` reference (mirrors how `TabActivityTracker` takes its lookup).
    @ObservationIgnored var activeTab: (() -> (id: UUID, name: String, workingDirectory: String, claudeSessionID: UUID?)?)?

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        // Default the panel visible, so enabling voice shows something.
        isPanelVisible = defaults.object(forKey: Self.panelKey) as? Bool ?? true

        tailer.onMessage = { [weak self] message in
            self?.handleAssistantMessage(message)
        }
    }

    // MARK: - Targeting

    /// Point the tailer at whatever tab is active now. Called on launch and whenever
    /// `SessionStore.activeTabID` changes.
    func retargetToActiveTab() {
        guard isEnabled else { return }
        guard let tab = activeTab?() else {
            tailer.stop()
            targetTabName = nil
            return
        }
        guard tab.id != tailer.targetTabID else { return }

        // A retarget mid-turn would otherwise finish speaking the old tab's sentence.
        speech.stopAll()
        tailer.retarget(tabID: tab.id,
                        workingDirectory: tab.workingDirectory,
                        claudeSessionID: tab.claudeSessionID)
        targetTabName = tab.name
        append(.system, source: tab.name, text: "Listening to \(tab.name)")
    }

    private func shutDown() {
        tailer.stop()
        speech.stopAll()
        targetTabName = nil
    }

    // MARK: - Speech out

    private func handleAssistantMessage(_ message: ClaudeTranscript.AssistantMessage) {
        guard isEnabled else { return }
        append(.assistant, source: targetTabName ?? "session", text: message.text)
        speech.speak(message.text)
    }

    /// Stop speaking and clear the queue (the "stop" command, and the panel's button).
    func stopSpeaking() {
        speech.stopAll()
    }

    // MARK: - Log

    func append(_ speaker: Exchange.Speaker, source: String, text: String) {
        exchanges.append(Exchange(speaker: speaker, source: source, text: text, at: Date()))
        if exchanges.count > Self.maxExchanges {
            exchanges.removeFirst(exchanges.count - Self.maxExchanges)
        }
    }

    func clearLog() {
        exchanges.removeAll()
    }
}
