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

    /// Backing scale to assume when no window is in hand. A window's own
    /// `backingScaleFactor` is always preferable — this is the fallback for the
    /// mount path, where the view may not have joined a window yet.
    static var defaultScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }

    /// The unsnapped advance of the widest ASCII glyph, measured exactly the way
    /// SwiftTerm measures it (`AppleTerminalView.computeFontDimensions` takes the
    /// advancement of the "W" glyph on macOS). Menlo 11 → 6.62255859375pt.
    private static let rawCellWidth: CGFloat = {
        let font = TerminalMetrics.font
        return font.advancement(forGlyph: font.glyph(withName: "W")).width
    }()

    private static let rawCellHeight: CGFloat = {
        let font = TerminalMetrics.font
        return (font.ascender - font.descender + font.leading).rounded(.up)
    }()

    /// Width of one cell on a display of the given backing scale.
    ///
    /// The snapping is not cosmetic and it is not ours to choose: SwiftTerm lays its
    /// grid out on cells snapped to the DEVICE pixel grid, and this has to reproduce
    /// that arithmetic or every floor derived from it is a promise about a grid that
    /// does not exist. The geometry trace caught exactly that once — a container the
    /// layout engine had sized for "80 columns" reported a 75-column grid.
    ///
    /// Since SwiftTerm v1.16.0 the snap is to the NEAREST device pixel rather than
    /// always up, which makes the cell backing-scale dependent for the first time:
    /// Menlo 11's 6.6226pt advance is a 6.5pt cell at 2x and a 7.0pt cell at 1x.
    /// Callers holding a view must pass `window?.backingScaleFactor`; a value from
    /// the wrong display is off by ~7%, which is a whole column every fourteen.
    static func cellWidth(scale: CGFloat) -> CGFloat {
        max(1, (rawCellWidth * scale).rounded() / scale)
    }

    /// Height of one cell. SwiftTerm still rounds this UP to the device pixel, so it
    /// is 13pt for Menlo 11 at both 1x and 2x — the parameter exists so the two
    /// halves of the cell keep being derived the same way if that changes.
    static func cellHeight(scale: CGFloat) -> CGFloat {
        max(1, (rawCellHeight * scale).rounded(.up) / scale)
    }

    /// The WIDEST a cell can be across the displays this app can be shown on (1x).
    ///
    /// For a floor handed to the layout engine — which is scale-free, a pure value
    /// type over fractions — this is the only safe choice: reserving space for the
    /// widest cell can only over-deliver columns on a Retina display, never promise
    /// a terminal more columns than it is about to get.
    static let widestCellWidth = cellWidth(scale: 1)

    /// Slack for SwiftTerm's own chrome so the promised columns genuinely fit rather
    /// than landing a cell short.
    ///
    /// SwiftTerm computes `cols = Int(getEffectiveWidth(size) / cellWidth)`, and its
    /// effective width is the view's width less the reserved scroller. 17pt is that
    /// scroller plus our own inset, and it is a POINT offset — independent of the
    /// cell size, so it survived the v1.16.0 cell-width change unchanged.
    ///
    /// 17, not 16. The original 16 was calibrated against two grids (544px → 75 cols,
    /// 781px → 109 cols) and both happen to sit mid-cell, where a one-pixel error is
    /// invisible. It only shows when `width - chrome` lands EXACTLY on a cell boundary:
    /// at 744px, 744−16 = 728 = 7×104, so this reported 104 while SwiftTerm's real grid
    /// was 103 — and likewise 583px → 81 against a real 80. Against all eight widths the
    /// geometry trace had recorded at the time, 16 missed those two and 17 matched
    /// every one.
    static let chrome: CGFloat = 17

    /// Columns a terminal area of `width` points renders. Used for the live
    /// `cols × rows` readout while a slot splitter is being dragged — the only
    /// dimension a terminal user actually thinks in — and by the geometry HUD, which
    /// grades this against SwiftTerm's real grid.
    static func columns(forWidth width: CGFloat, scale: CGFloat = defaultScale) -> Int {
        max(0, Int((width - chrome) / cellWidth(scale: scale)))
    }

    static func rows(forHeight height: CGFloat, scale: CGFloat = defaultScale) -> Int {
        max(0, Int(height / cellHeight(scale: scale)))
    }

    /// Narrowest the console may be rendered: 80 columns, plus ONE CELL OF SLACK.
    ///
    /// The slack is not padding-by-feel. `columns(forWidth:)` tracks SwiftTerm exactly
    /// at most widths but runs a single column optimistic at some (1528pt predicts 216,
    /// SwiftTerm reports 215 — measured, not guessed). Asking for 81 cells' worth means
    /// the floor delivers a true 80 even when the estimate is high by one, which is the
    /// whole promise: below 80, output written to wrap at 80 wraps mid-word.
    ///
    /// Built from `widestCellWidth`, so this is the same 584pt on every display it was
    /// before SwiftTerm made the cell scale-dependent; on a 2x display it now buys
    /// ~87 columns rather than exactly 81. Over-reserving is the harmless direction.
    static var minimumWidth: CGFloat {
        (widestCellWidth * CGFloat(standardColumns + 1)).rounded(.up) + chrome
    }

    static var minimumHeight: CGFloat {
        (cellHeight(scale: 1) * CGFloat(standardRows)).rounded(.up)
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
    static func isUsable(_ size: CGSize, scale: CGFloat = defaultScale) -> Bool {
        columns(forWidth: size.width, scale: scale) >= minimumReflowColumns
            && rows(forHeight: size.height, scale: scale) >= minimumReflowRows
    }
}
