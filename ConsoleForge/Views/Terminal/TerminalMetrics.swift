import AppKit

/// The terminal's font and the grid geometry that follows from it. Single source of
/// truth so the layout engine's minimum console width and the font a session is
/// actually rendered in can never drift apart.
enum TerminalMetrics {
    /// Terminal.app's default.
    static let fontName = "Menlo"
    static let fontSize: CGFloat = 11

    /// The classic terminal width. The VT100 inherited 80 columns from the 80-column
    /// punch card, and it is still what man pages, `--help` output and TUIs assume —
    /// below it, output that was written to wrap at 80 starts wrapping mid-word
    /// instead. This is the floor the console slot is allowed to shrink to.
    static let standardColumns = 80
    /// The matching VT100 row count, used as the height floor.
    static let standardRows = 24

    static var font: NSFont {
        NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// Advance width of one cell. Measured rather than hardcoded so changing
    /// `fontSize` moves the minimum with it. Menlo 11pt ≈ 6.62pt.
    static let cellWidth: CGFloat = {
        let font = NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return ("W" as NSString).size(withAttributes: [.font: font]).width
    }()

    static let cellHeight: CGFloat = {
        let font = NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return font.ascender - font.descender + font.leading
    }()

    /// Slack for SwiftTerm's own insets and scroller so 80 columns genuinely fit
    /// rather than landing one cell short.
    static let chrome: CGFloat = 14

    /// Columns a terminal area of `width` points renders. Used for the live
    /// `cols × rows` readout while a slot splitter is being dragged — the only
    /// dimension a terminal user actually thinks in.
    static func columns(forWidth width: CGFloat) -> Int {
        max(0, Int((width - chrome) / cellWidth))
    }

    static func rows(forHeight height: CGFloat) -> Int {
        max(0, Int(height / cellHeight))
    }

    /// Narrowest the console may be rendered: 80 columns. ≈544pt at Menlo 11pt.
    /// Below this the console slot collapses to a rail instead of shrinking further.
    static var minimumWidth: CGFloat {
        (cellWidth * CGFloat(standardColumns)).rounded(.up) + chrome
    }

    static var minimumHeight: CGFloat {
        (cellHeight * CGFloat(standardRows)).rounded(.up)
    }
}
