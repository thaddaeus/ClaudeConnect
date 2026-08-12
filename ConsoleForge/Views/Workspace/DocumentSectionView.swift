import SwiftUI
import AppKit

/// The Documents section: its OWN tab strip plus a read-only view of whichever document
/// that strip has selected.
///
/// The strip is the point of Phase B. It filters `openTabIDs` to `.document` tabs, keeps
/// its own selection (`activeDocumentTabID`), and enforces group contiguity inside itself
/// — none of which the console strip can see. Each document tab carries `parentTabID`
/// pointing at the console tab it was opened from and renders that parent's colour across
/// its top, the same affordance a spawned worktree tab has had all along.
///
/// Nothing here goes near a PTY. A document tab is a file; `SessionStore.resolveLaunch`
/// refuses it outright (task 9736 criterion 11).
struct DocumentSectionView: View {
    @Environment(SessionStore.self) private var store
    @Environment(LayoutStore.self) private var layout

    var body: some View {
        VStack(spacing: 0) {
            if !store.documentTabIDs.isEmpty {
                DocumentTabBar()
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // `dropDestination` rather than `onDrop(of:)`: its handler is MainActor-isolated,
        // so the store and the layout are never captured across a concurrency boundary
        // the way an NSItemProvider completion block would.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            for url in files { DocumentOpener.open(path: url.path, store: store, layout: layout) }
            return !files.isEmpty
        }
    }

    @ViewBuilder
    private var content: some View {
        if let id = store.activeDocumentTabID,
           let session = store.session(for: id),
           let path = session.documentPath {
            // Keyed by path so switching tabs re-runs the load rather than showing the
            // previous document's text under the new tab's name.
            DocumentViewer(path: path)
                .id(path)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("No documents open")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Drop a file here, or open one — it becomes a tab\nparented to the console tab you opened it from.")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
            Button("Open File…") { DocumentOpener.present(store: store, layout: layout) }
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Opening

/// The one place a document tab is created, so every entry point (menu, drop, the empty
/// state's button) parents it the same way.
@MainActor
enum DocumentOpener {
    /// Open `path` as a document tab parented to the ACTIVE CONSOLE TAB. That parent is
    /// the whole relationship criterion 9 asks for: the file was opened while working in
    /// that session, and it renders under that session's colour.
    static func open(path: String, store: SessionStore, layout: LayoutStore) {
        // Raise the strip first: a tab opened behind a closed or collapsed panel is live
        // but unreachable.
        layout.revealStrip(for: .document)
        store.openDocumentTab(path: path, parentTabID: store.activeTabID)
    }

    /// A file picker rooted at the active console tab's working directory — the directory
    /// the session is actually working in is nearly always the one you want.
    static func present(store: SessionStore, layout: LayoutStore) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Open a file to view alongside the console"
        if let cwd = store.activeTabID.flatMap({ store.session(for: $0)?.workingDirectory }) {
            panel.directoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
        }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            open(path: url.path, store: store, layout: layout)
        }
    }
}

// MARK: - Tab strip

/// The Documents section's tab strip. Deliberately its own view rather than a
/// parameterised `TerminalTabBar`: the console strip carries activity dots, a voice
/// toggle and terminated state, none of which a file has.
struct DocumentTabBar: View {
    @Environment(SessionStore.self) private var store
    @Environment(LayoutStore.self) private var layout
    @State private var hoveredTabID: UUID?
    @State private var draggingTabID: UUID?
    @State private var dropTargetTabID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(store.documentTabIDs, id: \.self) { tabID in
                        if let session = store.session(for: tabID) {
                            tabButton(session: session, isActive: store.activeDocumentTabID == tabID)
                                .onDrag {
                                    draggingTabID = tabID
                                    return NSItemProvider(object: tabID.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: TabDropDelegate(
                                    tabID: tabID,
                                    store: store,
                                    draggingTabID: $draggingTabID,
                                    dropTargetTabID: $dropTargetTabID
                                ))
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            Button {
                DocumentOpener.present(store: store, layout: layout)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .help("Open a file…")
        }
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    /// The parent console tab's colour, when that tab is still open. This is the
    /// cross-strip link: the parent lives in the console strip, the child here.
    private func groupParentColor(for session: SessionConfiguration) -> Color? {
        guard let pid = session.parentTabID,
              store.openTabIDs.contains(pid),
              let parent = store.session(for: pid) else { return nil }
        return parent.tabColor
    }

    private func groupHasFocus(parentID: UUID) -> Bool {
        guard let focusedID = store.focusedTabID else { return false }
        if focusedID == parentID { return true }
        return store.session(for: focusedID)?.parentTabID == parentID
    }

    /// Last member of its group WITHIN THIS STRIP — the console strip is irrelevant here,
    /// which is exactly what per-strip contiguity means.
    private func isLastInGroup(_ session: SessionConfiguration) -> Bool {
        let strip = store.documentTabIDs
        guard let pid = session.parentTabID,
              let idx = strip.firstIndex(of: session.id) else { return false }
        let nextIdx = idx + 1
        guard nextIdx < strip.count else { return true }
        return store.session(for: strip[nextIdx])?.parentTabID != pid
    }

    private func tabButton(session: SessionConfiguration, isActive: Bool) -> some View {
        let isHovered = hoveredTabID == session.id
        let parentColor = groupParentColor(for: session)
        let capsGroup = parentColor != nil && isLastInGroup(session)
        let missing = session.documentPath.map { !FileManager.default.fileExists(atPath: $0) } ?? true
        return HStack(spacing: 6) {
            Image(systemName: missing ? "questionmark.square.dashed" : "doc.text")
                .font(.caption2)
                .foregroundStyle(missing ? Color.orange : Color.secondary)

            Text(session.name)
                .font(.system(size: 12))
                .lineLimit(1)

            Button {
                store.closeTab(sessionID: session.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isActive || isHovered ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isActive
                ? Color(nsColor: .selectedControlColor).opacity(0.3)
                : (isHovered ? Color.primary.opacity(0.06) : .clear)
        )
        .overlay(alignment: .leading) {
            if dropTargetTabID == session.id {
                Rectangle().fill(Color.accentColor).frame(width: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            // Same two-layer treatment the console strip uses: the tab's own identity
            // outline, shifted down to make room for the parent's stripe above it.
            TabIdentityOutline(cornerRadius: 4,
                               topInset: parentColor != nil ? 1.5 : 0,
                               trailingInset: capsGroup ? 1.5 : 0,
                               includeLeading: parentColor == nil)
                .stroke(session.tabColor.opacity(isActive ? 1 : 0.4),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            if let parentColor, let pid = session.parentTabID {
                TabGroupStripe(cornerRadius: 4, capTrailing: capsGroup)
                    .stroke(parentColor.opacity(groupHasFocus(parentID: pid) ? 1 : 0.4),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .butt))
            }
        }
        .opacity(draggingTabID == session.id ? 0.4 : 1)
        .contentShape(Rectangle())
        .onHover { hovering in hoveredTabID = hovering ? session.id : nil }
        .onTapGesture { store.focusTab(session.id) }
        .help(helpText(for: session))
        .contextMenu {
            if let path = session.documentPath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
                Divider()
            }
            Button(role: .destructive) {
                store.closeTab(sessionID: session.id)
            } label: {
                Label("Close Tab", systemImage: "xmark")
            }
        }
    }

    private func helpText(for session: SessionConfiguration) -> String {
        var lines = [session.documentPath ?? session.name]
        if let pid = session.parentTabID, let parent = store.session(for: pid),
           store.openTabIDs.contains(pid) {
            lines.append("Opened from \(parent.name)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Viewer

/// A read-only view of one file.
///
/// Read-only by decision, not omission (Tadd, 2026-08-12): Phase B's criteria are about
/// tabs, parenting and the view-kind discriminator, so the section shows a document and
/// does not edit it. There is no save path, no dirty state and no file watcher — the
/// toolbar's Reload is how you pick up an external change.
struct DocumentViewer: View {
    let path: String
    @State private var load: DocumentLoad = .loading
    /// Bumped on every (re)load so `ReadOnlyTextView` can tell "same document, new
    /// content" from "same content, parent re-rendered" without comparing megabytes of
    /// string on every SwiftUI update pass.
    @State private var revision = 0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            body(for: load)
        }
        .task(id: path) { await reload() }
    }

    /// Reading and decoding happens OFF the main actor: at `DocumentLoad.maxBytes` this is
    /// megabytes of I/O plus a full scan for the line count, and doing that inline would
    /// stall the window — including the terminal beside it.
    private func reload() async {
        let target = path
        let result = await Task.detached(priority: .userInitiated) {
            DocumentLoad.read(target)
        }.value
        guard target == path else { return }
        load = result
        revision += 1
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Text((path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(.secondary)
                .help(path)

            Spacer(minLength: 4)

            if case .text(_, let lines, let truncated) = load {
                Text(truncated ? "first \(lines) lines" : "\(lines) lines")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reload from disk — this viewer does not watch the file")

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func body(for load: DocumentLoad) -> some View {
        switch load {
        case .loading:
            notice("Loading…", symbol: "hourglass", tint: .secondary)
        case .text(let text, _, _):
            ReadOnlyTextView(text: text, revision: revision)
        case .missing:
            notice("This file is no longer on disk.\n\(path)", symbol: "questionmark.square.dashed", tint: .orange)
        case .binary(let bytes):
            notice("Not a text file — \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) of binary data.",
                   symbol: "doc.badge.gearshape", tint: .secondary)
        case .failed(let message):
            notice(message, symbol: "exclamationmark.triangle", tint: .orange)
        }
    }

    private func notice(_ text: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// The outcome of reading one file off disk.
enum DocumentLoad: Equatable, Sendable {
    case loading
    /// Decoded text, its line count, and whether it was cut short at `maxBytes`.
    case text(String, lines: Int, truncated: Bool)
    case binary(bytes: Int)
    case missing
    case failed(String)

    /// Files bigger than this are shown truncated. A viewer that stalls the UI loading a
    /// 200 MB log is worse than one that says it only read the first slice.
    static let maxBytes = 4 * 1024 * 1024

    static func read(_ path: String) -> DocumentLoad {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let truncated = data.count > maxBytes
            let slice = truncated ? data.prefix(maxBytes) : data[...]
            // A NUL byte in the first block is the cheap, reliable binary test — it never
            // appears in UTF-8 text and appears almost immediately in object files,
            // images and archives.
            if slice.prefix(8192).contains(0) { return .binary(bytes: data.count) }
            guard let text = String(data: slice, encoding: .utf8)
                    ?? String(data: slice, encoding: .isoLatin1) else {
                return .binary(bytes: data.count)
            }
            return .text(text, lines: text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }, truncated: truncated)
        } catch {
            return .failed("Could not read this file.\n\(error.localizedDescription)")
        }
    }
}

/// A non-editable `NSTextView` in a scroll view.
///
/// AppKit rather than SwiftUI `Text` because a document can be tens of thousands of
/// lines: `NSTextView` scrolls, selects and ⌘F-finds all of it without laying out every
/// line up front. Nothing here touches a terminal view's frame — the two writers of one
/// of those are still `TerminalSession.resize` and `TerminalHostView`'s mount (task 9736
/// criterion 13).
struct ReadOnlyTextView: NSViewRepresentable {
    let text: String
    /// Changes only when the document is (re)loaded. `updateNSView` runs on every parent
    /// re-render — a tab hover, a splitter drag — and diffing the strings there would be
    /// an O(file size) comparison each time.
    let revision: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var appliedRevision: Int?
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // No wrapping: source and logs are written to a width, and rewrapping them makes
        // them harder to read, not easier. The horizontal scroller handles the overflow.
        textView.isHorizontallyResizable = true
        let unbounded = CGFloat.greatestFiniteMagnitude
        textView.maxSize = NSSize(width: unbounded, height: unbounded)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: unbounded, height: unbounded)
        textView.string = text
        context.coordinator.appliedRevision = revision
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.appliedRevision != revision,
              let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.appliedRevision = revision
        textView.string = text
    }
}
