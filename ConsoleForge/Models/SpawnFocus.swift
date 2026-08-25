import Foundation

/// Who gets focus when a tab is spawned from OUTSIDE the UI — the `consoleforge-tab`
/// path, where a running session opens a tab rather than the user asking for one.
///
/// Two outcomes, and conflating them is what task 990034 got wrong. Its fix (#28)
/// computed one flag — "are you on the tab that spawned this" — and drove BOTH the tab
/// selection and `NSApp.activate(ignoringOtherApps:)` from it. But "the parent is the
/// active tab" says nothing about whether you are looking at ConsoleForge at all: a hub
/// sitting on the active tab while you work in another app satisfied it perfectly, so
/// every spoke it launched yanked the whole app to the foreground. The reported symptom
/// after #28 shipped was exactly that — a hub opened a spoke and kicked the user out of
/// another application.
///
/// So the app-level answer needs the term the tab-level one does not have: is
/// ConsoleForge ALREADY frontmost. That makes activation a no-op by construction, which
/// is the point — a background app must never take the screen. It stays modelled rather
/// than deleted so the rule is stated where the next caller will read it, instead of
/// being an absence someone re-fills.
///
/// Selecting the tab is deliberately NOT gated on frontmost-ness: it moves a selection
/// inside a window you are not looking at, costs nothing while you are away, and leaves
/// the tab you asked for in front when you come back.
struct SpawnFocus: Equatable {

    /// Move the console strip's selection to the newly spawned tab.
    let selectsTab: Bool

    /// Pull ConsoleForge in front of whatever else is on screen.
    let activatesApp: Bool

    /// - Parameters:
    ///   - parentTabID: the resolved spawning tab, or nil when there is no live parent
    ///     (never had one, or it died and resolution left it nil) — such a tab has no
    ///     "tab you are on" to follow, so it opens in the background.
    ///   - activeTabID: the console strip's current selection.
    ///   - appIsFrontmost: `NSApp.isActive` — whether ConsoleForge is the active
    ///     application right now.
    init(parentTabID: UUID?, activeTabID: UUID?, appIsFrontmost: Bool) {
        selectsTab = parentTabID != nil && activeTabID == parentTabID
        activatesApp = selectsTab && appIsFrontmost
    }
}
