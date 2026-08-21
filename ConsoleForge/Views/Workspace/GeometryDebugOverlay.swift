import AppKit
import SwiftUI

/// Beta-only HUD showing the terminal geometry chain live: container px → SwiftTerm
/// grid → PTY winsize, plus the recent event log including every REJECTED size.
///
/// Never built in production — `WorkspaceView` gates it on `GeometryTrace.isEnabled`,
/// which is `!AppChannel.isProduction`, the same switch the beta support directory and
/// Keychain namespace use.
struct GeometryDebugOverlay: View {
    @Bindable var trace: GeometryTrace
    let resolved: ResolvedWorkspaceLayout
    let layout: LayoutStore
    /// The window's backing scale. Since SwiftTerm v1.16.0 the cell width snaps to the
    /// nearest DEVICE pixel, so the grid this HUD grades against is a function of the
    /// display the window is on — reading it from the environment is what keeps the
    /// mismatch warning a real signal rather than a per-display false alarm.
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider()
            chain
            Divider()
            slotTable
            Divider()
            log
        }
        .padding(10)
        .frame(width: 460, height: 340, alignment: .topLeading)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.7), lineWidth: 1)
        }
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "ruler")
            Text("Geometry — BETA ONLY")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(trace.transcript, forType: .string)
            }
            if let url = trace.fileURL {
                Button("Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
                .help("Copy \(url.path) — hand it to a session to read the trace")
            }
            Button("Clear") { trace.clear() }
            Button {
                trace.isOverlayVisible = false
            } label: { Image(systemName: "xmark") }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10, design: .monospaced))
    }

    /// The chain that matters. If container cols and grid cols disagree, the terminal
    /// is rendering at a width the layout did not ask for — that is the bug class this
    /// HUD exists to make visible.
    private var chain: some View {
        let containerCols = TerminalMetrics.columns(forWidth: trace.container.width,
                                                    scale: displayScale)
        let mismatch = trace.grid.cols > 0 && containerCols != trace.grid.cols
        return VStack(alignment: .leading, spacing: 2) {
            line("container", "\(Int(trace.container.width))×\(Int(trace.container.height)) px  →  \(containerCols) cols")
            line("SwiftTerm", "\(trace.grid.cols)×\(trace.grid.rows) cols×rows", warn: mismatch)
            line("cell", String(format: "%.2f × %.2f pt @%.0fx",
                                TerminalMetrics.cellWidth(scale: displayScale),
                                TerminalMetrics.cellHeight(scale: displayScale),
                                displayScale))
            if mismatch {
                Text("⚠︎ container and grid disagree — a reflow is pending or was missed")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var slotTable: some View {
        VStack(alignment: .leading, spacing: 1) {
            line("stripe", "\(Int(resolved.railStripeWidth)) pt reserved")
            ForEach(SlotID.allCases.filter { layout[$0].section != nil }) { id in
                let slot = layout[id]
                let rect = resolved.tiled[id] ?? resolved.floating[id]
                let state = resolved.parked[id] != nil ? "collapsed"
                    : (slot.isFloating ? "floating" : "tiled")
                let geom = rect.map { "\(Int($0.width))×\(Int($0.height)) @\(Int($0.minX)),\(Int($0.minY))" }
                    ?? "parked"
                let column = layout.column(id.column)
                let size = slot.isFloating
                    ? "float \(Int(slot.floatingFraction * 100))%"
                    : (column.isPinned ? "col pin \(Int(column.pinnedFraction * 100))%" : "col flex")
                line(id.rawValue, "\(slot.section?.title ?? "—")  \(state)  \(size)  \(geom)")
            }
        }
    }

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(trace.events.suffix(80)) { event in
                        Text(event.line)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(event.stage == "rejected" ? .orange : .white.opacity(0.85))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(event.id)
                    }
                }
            }
            .onChange(of: trace.events.count) { _, _ in
                if let last = trace.events.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func line(_ label: String, _ value: String, warn: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(warn ? .orange : .white)
        }
    }
}
