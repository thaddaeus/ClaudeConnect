import AppKit
import SwiftTerm

/// `TerminalView` that upgrades paste: when the clipboard carries rich text whose
/// hyperlinks have a display label different from their URL (e.g. a Slack
/// hyperlink), the pasted text becomes `[label](url)` markdown so both halves
/// survive the PTY's plain byte stream. Anything else — plain text, bare URLs,
/// rich text without links — falls through to stock SwiftTerm paste.
///
/// Markdown injection is deliberate: SwiftTerm's OSC 8 support is output-side
/// rendering only; pasting OSC 8 would inject raw escape bytes into the running
/// program's input.
final class LinkPastingTerminalView: TerminalView {
    /// UserDefaults key for the Settings toggle. Defaults to enabled.
    static let pasteLinksAsMarkdownKey = "pasteLinksAsMarkdown"

    override func paste(_ sender: Any) {
        let enabled = UserDefaults.standard
            .object(forKey: Self.pasteLinksAsMarkdownKey) as? Bool ?? true
        guard enabled,
              let converted = Self.markdownFromPasteboard(NSPasteboard.general) else {
            super.paste(sender)
            return
        }
        sendAsPaste(converted)
    }

    /// Mirrors SwiftTerm's internal paste path (`insertText(..., isPaste: true)`),
    /// which is inaccessible from a subclass: wrap in bracketed-paste markers when
    /// the running app requested them, so multi-line pastes stay atomic.
    private func sendAsPaste(_ text: String) {
        if terminal.bracketedPasteMode {
            send(data: EscapeSequences.bracketedPasteStart[0...])
            send(txt: text)
            send(data: EscapeSequences.bracketedPasteEnd[0...])
        } else {
            send(txt: text)
        }
    }

    // MARK: - Conversion

    /// Markdown rendering of the pasteboard's rich-text flavor, or nil when
    /// conversion shouldn't apply: no rich flavor, no `.link` runs, or every link's
    /// label already IS its URL (a bare URL pasted from a rich source).
    static func markdownFromPasteboard(_ pasteboard: NSPasteboard) -> String? {
        guard let attributed = pasteboard.readObjects(forClasses: [NSAttributedString.self])?
            .first as? NSAttributedString, attributed.length > 0
        else { return nil }

        var result = ""
        var convertedAny = false
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.link, in: full) { value, range, _ in
            // Rich sources (Slack HTML) use non-breaking spaces; the PTY wants plain.
            let runText = attributed.attributedSubstring(from: range).string
                .replacingOccurrences(of: "\u{00A0}", with: " ")
            guard let url = linkString(from: value) else {
                result += runText
                return
            }
            // Keep whitespace around the label outside the brackets.
            let label = runText.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty || isSameLink(label: label, url: url) {
                result += runText
            } else {
                let lead = runText.prefix(while: { $0.isWhitespace })
                let trail = runText.reversed().prefix(while: { $0.isWhitespace }).reversed()
                result += "\(lead)[\(escapeLabel(label))](\(escapeURL(url)))\(String(trail))"
                convertedAny = true
            }
        }
        return convertedAny ? result : nil
    }

    private static func linkString(from value: Any?) -> String? {
        switch value {
        case let url as URL: return url.absoluteString
        case let str as String: return str
        default: return nil
        }
    }

    /// True when the visible label is just a rendering of the URL itself
    /// (`example.com/x` shown for `https://example.com/x`) — converting those
    /// would gain nothing over pasting the URL.
    private static func isSameLink(label: String, url: String) -> Bool {
        func normalize(_ s: String) -> String {
            var s = s.lowercased()
            for scheme in ["https://", "http://"] where s.hasPrefix(scheme) {
                s.removeFirst(scheme.count)
            }
            if s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return normalize(label) == normalize(url)
    }

    private static func escapeLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func escapeURL(_ url: String) -> String {
        url
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }
}
