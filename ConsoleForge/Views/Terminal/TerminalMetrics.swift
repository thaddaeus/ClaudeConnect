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

    /// Width of one cell, ROUNDED UP to a whole point.
    ///
    /// The rounding is not cosmetic: SwiftTerm lays its grid out on integral cells, so
    /// Menlo 11pt's 6.6226pt advance becomes a 7pt cell. Using the raw advance made the
    /// column arithmetic optimistic by ~5%, and the geometry trace proved it — a
    /// container the layout engine had sized for "80 columns" reported a 75-column grid.
    /// Every floor derived from this was therefore short of what it promised.
    static let cellWidth: CGFloat = {
        let font = NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return ("W" as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }()

    static let cellHeight: CGFloat = {
        let font = NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return (font.ascender - font.descender + font.leading).rounded(.up)
    }()

    /// Slack for SwiftTerm's own insets so the promised columns genuinely fit rather
    /// than landing a cell short.
    ///
    /// 17, not 16. The original 16 was calibrated against two grids (544px → 75 cols,
    /// 781px → 109 cols) and both happen to sit mid-cell, where a one-pixel error is
    /// invisible. It only shows when `width - chrome` lands EXACTLY on a cell boundary:
    /// at 744px, 744−16 = 728 = 7×104, so this reported 104 while SwiftTerm's real grid
    /// was 103 — and likewise 583px → 81 against a real 80. Against all eight widths the
    /// geometry trace has now recorded, 16 misses those two and 17 matches every one.
    ///
    /// The error direction mattered for the fix being safe to make: 17 reports FEWER
    /// columns and makes `minimumWidth` one pixel WIDER, so both moves are conservative —
    /// the arithmetic can only over-reserve space, never promise a terminal more columns
    /// than it is about to get. Left wrong, the in-app HUD flags a container/grid
    /// disagreement at those exact widths, which is a false alarm in the one instrument
    /// that exists to catch the real thing.
    static let chrome: CGFloat = 17

    /// Columns a terminal area of `width` points renders. Used for the live
    /// `cols × rows` readout while a slot splitter is being dragged — the only
    /// dimension a terminal user actually thinks in.
    static func columns(forWidth width: CGFloat) -> Int {
        max(0, Int((width - chrome) / cellWidth))
    }

    static func rows(forHeight height: CGFloat) -> Int {
        max(0, Int(height / cellHeight))
    }

    /// Narrowest the console may be rendered: 80 columns, plus ONE CELL OF SLACK.
    ///
    /// The slack is not padding-by-feel. `columns(forWidth:)` tracks SwiftTerm exactly
    /// at most widths but runs a single column optimistic at some (1528pt predicts 216,
    /// SwiftTerm reports 215 — measured, not guessed). Asking for 81 cells' worth means
    /// the floor delivers a true 80 even when the estimate is high by one, which is the
    /// whole promise: below 80, output written to wrap at 80 wraps mid-word.
    static var minimumWidth: CGFloat {
        (cellWidth * CGFloat(standardColumns + 1)).rounded(.up) + chrome
    }

    static var minimumHeight: CGFloat {
        (cellHeight * CGFloat(standardRows)).rounded(.up)
    }

    /// Absolute floor for a REFLOW — far below the 80-column layout floor, because
    /// this is not a preference, it is a corruption guard.
    ///
    /// Reflowing SwiftTerm to a couple of columns destroys the buffer model
    /// permanently (tasks 9543 / 9487): every wrapped line is re-broken at that width
    /// and widening again does not put it back. A geometry this small is never
    /// something the user asked for — it is a container mid-collapse, mid-transition,
    /// or a slot the layout engine starved. The right response is to IGNORE it and
    /// keep the last good size, not to faithfully apply it.
    static let minimumReflowColumns = 20
    static let minimumReflowRows = 4

    /// Whether a container size is worth reflowing the terminal to.
    static func isUsable(_ size: CGSize) -> Bool {
        columns(forWidth: size.width) >= minimumReflowColumns
            && rows(forHeight: size.height) >= minimumReflowRows
    }
}
