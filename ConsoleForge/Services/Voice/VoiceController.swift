import Foundation
import Observation

/// Orchestrates the voice channel: what gets spoken, what gets heard, and what a heard
/// utterance is allowed to do.
///
/// Owns the pieces and the policy; the panel is a pure view of this object's state. Only
/// the **active** tab is audible and addressable — retargeting follows
/// `SessionStore.activeTabID`, so what you hear is always what you're looking at.
///
/// `VoiceEngine` is `@available(macOS 26, *)` (it needs `SpeechAnalyzer`), but this type
/// is not: the panel, the settings, and speech-out all work on macOS 14. The engine is
/// therefore held as an untyped reference behind gated accessors, and `micStatus` carries
/// `.unsupported` on older systems.
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

    // MARK: - Settings

    /// Master switch. Persisted; when off nothing is spoken and the mic is closed.
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            guard isEnabled != oldValue else { return }
            if isEnabled {
                retargetToActiveTab()
                if isMicEnabled { startListening() }
            } else {
                shutDown()
            }
        }
    }

    /// Whether the panel is showing. Persisted separately from `isEnabled` so voice can
    /// keep running with the panel collapsed.
    var isPanelVisible: Bool {
        didSet { UserDefaults.standard.set(isPanelVisible, forKey: Self.panelKey) }
    }

    /// Whether the mic should be open. Separate from `isEnabled` so speech-out can run
    /// without listening — the safe half of the feature on its own.
    var isMicEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMicEnabled, forKey: Self.micKey)
            guard isMicEnabled != oldValue else { return }
            if isMicEnabled && isEnabled { startListening() } else { stopListening() }
        }
    }

    /// Utterances must open with this to be acted on.
    var wakePhrase: String {
        didSet { UserDefaults.standard.set(wakePhrase, forKey: Self.wakeKey) }
    }

    /// When on, a dictated sentence waits for "send" (or the panel's button) instead of
    /// going straight into the session. Off by default — the wake phrase is the gate.
    var confirmBeforeSending: Bool {
        didSet { UserDefaults.standard.set(confirmBeforeSending, forKey: Self.confirmKey) }
    }

    static let defaultWakePhrase = "hey forge"

    private static let enabledKey = "VoiceEnabled"
    private static let panelKey = "VoicePanelVisible"
    private static let micKey = "VoiceMicEnabled"
    private static let wakeKey = "VoiceWakePhrase"
    private static let confirmKey = "VoiceConfirmBeforeSending"
    private static let maxExchanges = 60

    // MARK: - State

    let speech = SpeechOutput()

    private(set) var exchanges: [Exchange] = []
    /// Name of the tab currently being listened to, for the panel's target line.
    private(set) var targetTabName: String?
    private(set) var micStatus: VoiceMicStatus = .off
    /// Live transcription, shown under the meter while you speak.
    private(set) var caption: String = ""
    private(set) var inputLevel: Float = 0
    /// Dictation awaiting confirmation, when `confirmBeforeSending` is on.
    private(set) var pendingDictation: String?

    private let tailer = TranscriptTailer()
    /// `VoiceEngine` when running on macOS 26+. Untyped so this class stays ungated.
    private var engineStorage: AnyObject?

    /// Set by the app so the controller can resolve tabs without owning a `SessionStore`
    /// reference (mirrors how `TabActivityTracker` takes its lookup).
    @ObservationIgnored var activeTab: (() -> (id: UUID, name: String, workingDirectory: String, claudeSessionID: UUID?)?)?
    /// Open tabs in bar order, for "switch to <name>" and "tab <n>".
    @ObservationIgnored var openTabs: (() -> [(id: UUID, name: String)])?
    /// Tab navigation, wired to `SessionStore`.
    @ObservationIgnored var switchToTab: ((UUID) -> Void)?
    @ObservationIgnored var goToNextTab: (() -> Void)?
    @ObservationIgnored var goToPreviousTab: (() -> Void)?
    /// Types text into a tab's PTY, wired to `TerminalSessionManager`.
    @ObservationIgnored var sendToTab: ((UUID, String) -> Void)?
    /// Sends a control byte to a tab's PTY (Escape, to interrupt a turn).
    @ObservationIgnored var sendControlToTab: ((UUID, UInt8) -> Void)?

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        isPanelVisible = defaults.object(forKey: Self.panelKey) as? Bool ?? true
        isMicEnabled = defaults.object(forKey: Self.micKey) as? Bool ?? false
        wakePhrase = defaults.string(forKey: Self.wakeKey) ?? Self.defaultWakePhrase
        confirmBeforeSending = defaults.bool(forKey: Self.confirmKey)

        if #unavailable(macOS 26.0) {
            micStatus = .unsupported
        }

        tailer.onMessage = { [weak self] message in
            self?.handleAssistantMessage(message)
        }
    }

    var isMicSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
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
        stopListening()
        tailer.stop()
        speech.stopAll()
        targetTabName = nil
        pendingDictation = nil
        caption = ""
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

    // MARK: - Speech in

    func startListening() {
        guard isEnabled, isMicEnabled else { return }
        guard #available(macOS 26.0, *) else {
            micStatus = .unsupported
            return
        }
        guard engineStorage == nil else { return }

        let engine = VoiceEngine()
        engine.onStatus = { [weak self] status in self?.micStatus = status }
        engine.onCaption = { [weak self] text in self?.caption = text }
        engine.onLevel = { [weak self] level in self?.inputLevel = level }
        engine.onUtterance = { [weak self] utterance in self?.handleUtterance(utterance) }
        engineStorage = engine
        Task { await engine.start() }
    }

    func stopListening() {
        guard #available(macOS 26.0, *), let engine = engineStorage as? VoiceEngine else {
            engineStorage = nil
            return
        }
        engine.stop()
        engineStorage = nil
        caption = ""
        inputLevel = 0
        micStatus = isMicSupported ? .off : .unsupported
    }

    /// A finished utterance from the mic. Everything routes through here.
    private func handleUtterance(_ utterance: String) {
        // A pending confirmation gets first refusal: "send" / "cancel" answer it, and
        // they must not be mistaken for a fresh command or dictated as text.
        if let pending = pendingDictation {
            let answer = VoiceCommandRouter.normalize(
                VoiceCommandRouter.stripWakePhrase(from: utterance, wakePhrase: wakePhrase) ?? utterance)
            if ["send", "send it", "go", "yes", "confirm"].contains(answer) {
                pendingDictation = nil
                deliverDictation(pending)
                return
            }
            if ["cancel", "no", "discard", "never mind", "nevermind"].contains(answer) {
                pendingDictation = nil
                append(.system, source: "voice", text: "Discarded.")
                return
            }
            // Anything else replaces the pending text rather than answering it.
            pendingDictation = nil
        }

        guard let command = VoiceCommandRouter.parse(utterance, wakePhrase: wakePhrase) else {
            // No wake phrase — this was talk in the room, not to the session.
            return
        }
        append(.user, source: "you", text: utterance)
        perform(command)
    }

    private func perform(_ command: VoiceCommandRouter.Command) {
        switch command {
        case .stopSpeaking:
            speech.stopAll()

        case .mute:
            isMicEnabled = false
            append(.system, source: "voice", text: "Mic off. Turn it back on in the panel.")

        case .interrupt:
            guard let tab = activeTab?() else { return }
            sendControlToTab?(tab.id, 0x1b)   // Escape
            speech.stopAll()
            append(.system, source: "voice", text: "Interrupted \(tab.name).")

        case .nextTab:
            goToNextTab?()

        case .previousTab:
            goToPreviousTab?()

        case .tabIndex(let index):
            let tabs = openTabs?() ?? []
            guard index >= 1, index <= tabs.count else {
                append(.system, source: "voice", text: "There is no tab \(index).")
                return
            }
            switchToTab?(tabs[index - 1].id)

        case .switchToTab(let name):
            let tabs = openTabs?() ?? []
            guard let match = VoiceCommandRouter.bestTabMatch(for: name, among: tabs) else {
                append(.system, source: "voice", text: "No open tab matches \"\(name)\".")
                return
            }
            switchToTab?(match)

        case .dictate(let text):
            if confirmBeforeSending {
                pendingDictation = text
                append(.system, source: "voice", text: "Say \"send\" to submit, or \"cancel\".")
            } else {
                deliverDictation(text)
            }
        }
    }

    /// Confirm and submit whatever is waiting (the panel's Send button).
    func confirmPendingDictation() {
        guard let pending = pendingDictation else { return }
        pendingDictation = nil
        deliverDictation(pending)
    }

    func cancelPendingDictation() {
        pendingDictation = nil
    }

    private func deliverDictation(_ text: String) {
        guard let tab = activeTab?() else {
            append(.system, source: "voice", text: "No active tab to send to.")
            return
        }
        sendToTab?(tab.id, text)
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
