import Foundation

/// Decides what a spoken utterance means.
///
/// The grammar is deliberately tiny. Everything that isn't recognised as a command is
/// dictation, because guessing wrong in that direction merely types a sentence Claude
/// can read, whereas an over-eager command vocabulary silently swallows things the user
/// meant to say.
///
/// Every utterance must open with the wake phrase. With the mic permanently open that
/// is the only thing separating "talking to Claude" from "talking to someone in the
/// room", so it is checked before anything else.
enum VoiceCommandRouter {

    enum Command: Equatable {
        /// Switch to the tab whose name best matches.
        case switchToTab(name: String)
        case nextTab
        case previousTab
        /// One-based, as spoken ("tab three").
        case tabIndex(Int)
        /// Stop speaking and clear the queue.
        case stopSpeaking
        /// Interrupt the running turn (Escape into the PTY).
        case interrupt
        /// Stop listening until re-enabled from the UI.
        case mute
        /// Type this into the active tab.
        case dictate(String)
    }

    /// Parse an utterance, or return nil if it doesn't begin with the wake phrase.
    static func parse(_ utterance: String, wakePhrase: String) -> Command? {
        guard let body = stripWakePhrase(from: utterance, wakePhrase: wakePhrase) else { return nil }
        let normalized = normalize(body)
        guard !normalized.isEmpty else { return nil }

        // Speech control.
        if ["stop", "stop talking", "quiet", "be quiet", "shut up", "shush", "hush"].contains(normalized) {
            return .stopSpeaking
        }
        if ["interrupt", "cancel that", "escape", "stop the turn"].contains(normalized) {
            return .interrupt
        }
        if ["mute", "stop listening", "go to sleep", "sleep"].contains(normalized) {
            return .mute
        }

        // Tab navigation.
        if ["next tab", "next session"].contains(normalized) { return .nextTab }
        if ["previous tab", "previous session", "last tab", "back a tab"].contains(normalized) {
            return .previousTab
        }
        if let index = tabIndex(from: normalized) { return .tabIndex(index) }
        for prefix in ["switch to ", "go to ", "open tab ", "focus "] {
            if normalized.hasPrefix(prefix) {
                let name = String(normalized.dropFirst(prefix.count))
                    .replacingOccurrences(of: "^the |^tab ", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return .switchToTab(name: name) }
            }
        }

        // Everything else is something to say to Claude. Dictate the ORIGINAL body, not
        // the normalized form — Claude wants the punctuation and casing.
        return .dictate(body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Wake phrase

    /// The utterance with its leading wake phrase removed, or nil if it isn't there.
    ///
    /// Matching is fuzzy on purpose: transcription of a short phrase is unreliable
    /// ("hey forge" arrives as "hey forge,", "hay forge", "hey, Forge"). The comparison
    /// is against the normalized head of the utterance, and a filler word between the
    /// phrase and the command ("hey forge, please …") is tolerated.
    static func stripWakePhrase(from utterance: String, wakePhrase: String) -> String? {
        let wake = normalize(wakePhrase)
        guard !wake.isEmpty else { return utterance }

        let normalizedUtterance = normalize(utterance)
        let wakeWords = wake.split(separator: " ").map(String.init)
        let words = normalizedUtterance.split(separator: " ").map(String.init)
        guard words.count >= wakeWords.count else { return nil }

        for (index, expected) in wakeWords.enumerated() {
            guard isCloseEnough(words[index], expected) else { return nil }
        }

        // Map back onto the ORIGINAL string so casing/punctuation survive for dictation.
        var remaining = utterance.trimmingCharacters(in: .whitespaces)
        for _ in wakeWords {
            remaining = dropLeadingWord(from: remaining)
        }
        // Leading only — trimming both ends would eat the sentence's final punctuation,
        // which Claude wants.
        let leading = CharacterSet(charactersIn: " ,.:;!?-–—")
        while let first = remaining.unicodeScalars.first, leading.contains(first) {
            remaining = String(remaining.dropFirst())
        }
        // "hey forge, please run the tests" → drop the courtesy filler.
        for filler in ["please ", "can you ", "could you ", "would you "] {
            if remaining.lowercased().hasPrefix(filler) {
                remaining = String(remaining.dropFirst(filler.count))
                break
            }
        }
        return remaining
    }

    private static func dropLeadingWord(from text: String) -> String {
        guard let space = text.firstIndex(of: " ") else { return "" }
        return String(text[text.index(after: space)...]).trimmingCharacters(in: .whitespaces)
    }

    /// Fuzzy only where fuzziness is safe.
    ///
    /// Short words ("hey") are both the most often mis-transcribed and the least
    /// discriminating, so they get a one-edit allowance. Words of five characters or
    /// more are the ones carrying the phrase's identity and must match exactly —
    /// otherwise "forge" accepts "forget", and "hey, forget about it" said to someone
    /// in the room types itself into a live session. A false negative costs a repeat;
    /// a false positive talks to Claude on your behalf.
    private static func isCloseEnough(_ candidate: String, _ expected: String) -> Bool {
        if candidate == expected { return true }
        guard (3...4).contains(expected.count) else { return false }
        return editDistance(candidate, expected) <= 1
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    // MARK: - Helpers

    /// Lowercased, punctuation-stripped, single-spaced — the form commands match on.
    static func normalize(_ text: String) -> String {
        let stripped = text.lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == " ") ? ch : " "
        }
        return String(stripped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    private static let spokenNumbers = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]

    private static func tabIndex(from normalized: String) -> Int? {
        guard normalized.hasPrefix("tab ") else { return nil }
        let rest = String(normalized.dropFirst(4))
        if let n = Int(rest), (1...9).contains(n) { return n }
        return spokenNumbers[rest]
    }

    /// Best open-tab match for a spoken name. Prefers an exact normalized match, then a
    /// prefix, then a substring — nil rather than a wrong guess when nothing is close.
    static func bestTabMatch(for spoken: String, among names: [(id: UUID, name: String)]) -> UUID? {
        let target = normalize(spoken)
        guard !target.isEmpty else { return nil }
        let candidates = names.map { (id: $0.id, normalized: normalize($0.name)) }

        if let exact = candidates.first(where: { $0.normalized == target }) { return exact.id }
        if let prefix = candidates.first(where: { $0.normalized.hasPrefix(target) }) { return prefix.id }
        if let contains = candidates.first(where: { $0.normalized.contains(target) }) { return contains.id }
        // Spoken names get mangled; allow a small edit distance on the whole name.
        if let fuzzy = candidates
            .map({ (id: $0.id, distance: editDistance($0.normalized, target)) })
            .filter({ $0.distance <= max(1, target.count / 4) })
            .min(by: { $0.distance < $1.distance }) {
            return fuzzy.id
        }
        return nil
    }
}
