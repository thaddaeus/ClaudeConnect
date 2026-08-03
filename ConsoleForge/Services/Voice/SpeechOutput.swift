import AVFoundation
import Foundation

/// Speaks Claude's replies.
///
/// A single `AVSpeechSynthesizer` with its own queue, plus the sanitizer that makes the
/// difference between "readable" and "listenable": Claude writes for a screen — fenced
/// code, absolute paths, backticks, bullet glyphs, tables — and read literally that is
/// minutes of noise. `spoken(from:)` keeps the prose and summarises the rest.
@MainActor
@Observable
final class SpeechOutput: NSObject {

    /// True while an utterance is being spoken (drives the panel indicator, and later
    /// the mic's echo handling).
    private(set) var isSpeaking = false
    /// The text currently being spoken, for the panel.
    private(set) var currentText: String?

    /// Voice identifier (`AVSpeechSynthesisVoice.identifier`); nil uses the system default.
    var voiceIdentifier: String? {
        didSet { UserDefaults.standard.set(voiceIdentifier, forKey: Self.voiceKey) }
    }
    /// Speaking rate, in `AVSpeechUtterance`'s min…max range.
    var rate: Float {
        didSet { UserDefaults.standard.set(rate, forKey: Self.rateKey) }
    }

    private static let voiceKey = "VoiceOutputVoiceIdentifier"
    private static let rateKey = "VoiceOutputRate"

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        let defaults = UserDefaults.standard
        voiceIdentifier = defaults.string(forKey: Self.voiceKey)
        let savedRate = defaults.float(forKey: Self.rateKey)
        // Default slightly above Apple's default — Claude's replies are long.
        rate = savedRate > 0 ? savedRate : AVSpeechUtteranceDefaultSpeechRate * 1.08
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Speak

    func speak(_ raw: String) {
        let text = Self.spoken(from: raw)
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    /// Stop the current utterance and drop everything queued behind it.
    func stopAll() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        currentText = nil
    }

    /// Skip to the next queued utterance, finishing this one at a word boundary.
    func skipCurrent() {
        synthesizer.stopSpeaking(at: .word)
    }

    /// Voices offered in Settings, best quality first.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { lhs, rhs in
                if lhs.quality.rawValue != rhs.quality.rawValue {
                    return lhs.quality.rawValue > rhs.quality.rawValue
                }
                return lhs.name < rhs.name
            }
    }

    // MARK: - Sanitizer

    /// Turn a markdown-shaped assistant message into something worth hearing.
    ///
    /// The rules are all about what a listener can't use: a fenced code block read aloud
    /// is unusable and unskippable, so it becomes its line count; a 60-character absolute
    /// path is nine seconds of directory names, so it becomes its filename. Prose is left
    /// alone.
    static func spoken(from raw: String) -> String {
        var text = raw

        // Fenced code blocks → "code block, N lines". Done first so nothing inside a
        // fence is mistaken for prose.
        text = replaceFencedCode(in: text)

        // Inline `code` → just the contents, without the backticks.
        text = text.replacingOccurrences(of: "`([^`\n]+)`", with: "$1", options: .regularExpression)

        // Absolute/relative paths with at least one separator → final component.
        text = text.replacingOccurrences(
            of: "(?<![\\w/])~?/?(?:[\\w.@-]+/){1,}([\\w.@-]+)",
            with: "$1", options: .regularExpression)

        // Markdown emphasis, headings, list bullets, blockquotes, table pipes.
        text = text.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?<!\\w)\\*([^*\n]+)\\*", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: [.regularExpression])
        text = text.replacingOccurrences(of: "(?m)^\\s{0,8}[-*+]\\s+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s{0,8}>\\s?", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*\\|.*\\|\\s*$", with: "", options: .regularExpression)

        // Markdown links → the link text, not the URL.
        text = text.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)

        // Bare URLs are unlistenable.
        text = text.replacingOccurrences(of: "https?://\\S+", with: "a link", options: .regularExpression)

        // Emoji and box-drawing survive markdown stripping but not speech synthesis.
        text = text.unicodeScalars.filter { scalar in
            !(0x1F000...0x1FAFF).contains(scalar.value)
                && !(0x2500...0x27BF).contains(scalar.value)
                && !(0xFE00...0xFE0F).contains(scalar.value)
        }.reduce(into: "") { $0.unicodeScalars.append($1) }

        // Collapse the whitespace the substitutions left behind.
        text = text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replace ``` fences with a spoken summary of their size.
    private static func replaceFencedCode(in text: String) -> String {
        var result: [String] = []
        var fenceLines: [String] = []
        var inFence = false
        var language: String?

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inFence {
                    let count = fenceLines.count
                    let label = language.map { "\($0) code block" } ?? "code block"
                    result.append(count == 1 ? "\(label), one line."
                                             : "\(label), \(count) lines.")
                    fenceLines = []
                    language = nil
                    inFence = false
                } else {
                    inFence = true
                    let tag = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                }
                continue
            }
            if inFence { fenceLines.append(line) } else { result.append(line) }
        }

        // Unterminated fence — the turn is still streaming. Summarise what's there.
        if inFence {
            let label = language.map { "\($0) code block" } ?? "code block"
            result.append("\(label), \(fenceLines.count) lines.")
        }
        return result.joined(separator: "\n")
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechOutput: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            isSpeaking = true
            currentText = utterance.speechString
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            isSpeaking = synthesizer.isSpeaking
            if !synthesizer.isSpeaking { currentText = nil }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            isSpeaking = synthesizer.isSpeaking
            if !synthesizer.isSpeaking { currentText = nil }
        }
    }
}
