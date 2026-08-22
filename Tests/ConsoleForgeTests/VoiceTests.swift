import XCTest
@testable import ConsoleForge

/// Tier 1 coverage for the pure half of voice.
///
/// None of this needs a microphone or macOS 26 — `SpeechOutput.spoken` and
/// `VoiceCommandRouter.parse` are static functions over strings. They went untested
/// anyway, which is why every bug below shipped once already.
@MainActor
final class VoiceTests: XCTestCase {

    // MARK: - Speech out

    /// Shipped in v0.8.0. The heading pattern used `.regularExpression` WITHOUT `(?m)`,
    /// so `^` anchored to the whole message: only the FIRST heading was stripped and
    /// every later `###` was read aloud as "hash hash hash".
    func testEveryHeadingIsStrippedNotJustTheFirst() {
        let spoken = SpeechOutput.spoken(from: "# One\nbody\n## Two\nmore\n### Three")
        XCTAssertFalse(spoken.contains("#"), "no heading marker may survive: \(spoken)")
        XCTAssertTrue(spoken.contains("One") && spoken.contains("Two") && spoken.contains("Three"))
    }

    /// Shipped in v0.8.0. A newline is whitespace to AVSpeechSynthesizer, not a pause, so
    /// stripping markdown markers destroyed the only sentence boundaries and a bullet list
    /// spoke as one breathless run-on.
    func testStructurallySeparateLinesGetSentenceBoundaries() {
        let spoken = SpeechOutput.spoken(from: "- alpha\n- beta\n- gamma")
        let terminators = spoken.filter { ".!?".contains($0) }.count
        XCTAssertGreaterThanOrEqual(terminators, 3,
            "each list item is self-contained and must terminate: \(spoken)")
    }

    /// The deliberate limitation, pinned so nobody "fixes" it by accident: a hard-wrapped
    /// sentence is structurally identical to two short lines, and splitting it invents a
    /// pause that isn't in the text.
    func testAHardWrappedSentenceIsNotSplit() {
        let spoken = SpeechOutput.spoken(from: "the quick brown fox\njumps over the dog")
        XCTAssertFalse(spoken.contains("fox."), "a wrapped line must not gain a full stop: \(spoken)")
    }

    // MARK: - Wake phrase

    /// The asymmetry that matters: a false negative costs a repeat, a false positive
    /// types your room conversation into a live session.
    func testAWakePhraseMustBeSpokenToTriggerAnything() {
        XCTAssertNil(VoiceCommandRouter.parse("next tab", wakePhrase: "console forge"),
                     "no wake phrase, no command")
    }

    /// Caught by the router harness before release: "hey forget about it" matched, because
    /// "forget" is edit-distance 1 from "forge". Fuzzy matching is now limited to 3–4
    /// character words; 5+ must be exact.
    func testANearMissOnALongWordDoesNotWake() {
        XCTAssertNil(VoiceCommandRouter.parse("hey forget about it, next tab", wakePhrase: "console forge"),
                     "'forget' must not fuzzy-match 'forge'")
    }

    func testWakePhraseIsStrippedAndTheCommandSurvives() {
        XCTAssertEqual(VoiceCommandRouter.parse("console forge next tab", wakePhrase: "console forge"),
                       .nextTab)
    }

    /// Stripping used to trim both ends, eating the sentence's final punctuation.
    func testStrippingTheWakePhraseKeepsTheRestIntact() {
        let body = VoiceCommandRouter.stripWakePhrase(from: "console forge what changed?",
                                                      wakePhrase: "console forge")
        XCTAssertEqual(body, "what changed?", "the trailing '?' is part of the utterance")
    }

    // MARK: - Transcript targeting

    /// Task 9883: a pinned id must resolve to THAT file or nil — never the
    /// newest-in-directory fallback, which bound 6 of 24 tabs to another tab's transcript
    /// and left brand-new tabs permanently silent. Still unfixed for the blocked-dot
    /// probe, which is task 990038.
    func testAPinnedSessionIdNeverFallsBackToTheNewestTranscript() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cf-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // An unrelated, newer transcript sitting in the same project directory.
        try "{}".write(to: dir.appendingPathComponent("\(UUID().uuidString).jsonl"),
                       atomically: true, encoding: .utf8)

        let pinned = UUID()
        let url = ClaudeTranscript.url(workingDirectory: dir.path, claudeSessionID: pinned)

        if let url {
            XCTAssertTrue(url.lastPathComponent.contains(pinned.uuidString),
                          "resolved to \(url.lastPathComponent) — that is another tab's transcript")
        }
    }
}
