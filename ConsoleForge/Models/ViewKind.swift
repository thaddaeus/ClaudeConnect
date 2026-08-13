import Foundation

/// What a tab actually IS.
///
/// "Session" used to mean "thing with a PTY" everywhere in the app — `PtyProcess`
/// launch, `ClaudeProcessBuilder`, `autoStart`, resume, the voice transcript binding,
/// `PendingPromptProbe`. A document tab is a file on disk, not a process, and must reach
/// none of those paths (task 9736 criterion 11). This discriminator is what every one of
/// them now filters on; `SessionStore.terminalTabIDs` is the single place that filtering
/// is expressed.
///
/// It also decides which TAB STRIP a tab belongs to: one strip per kind, each filtering
/// `openTabIDs` down to its own. Raw values are `sessions.json` keys — never rename them.
///
/// Deliberately in its own file with only Foundation imported, so the strip-order
/// harness can compile it alongside `TabStripModel` without dragging in SwiftUI, AppKit
/// or the layout engine.
enum ViewKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A Claude CLI session with a live PTY. Everything that existed before Phase B.
    case terminal
    /// A read-only file, shown in the Documents section. No process, ever.
    case document

    var id: String { rawValue }
    var isTerminal: Bool { self == .terminal }
}
