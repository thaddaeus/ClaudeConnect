import AppKit
import SwiftUI

/// Console and network output from the in-app browser, as a slot section.
///
/// This is the answer to "how does the console see what the browser is doing": it is a
/// panel in the same layout, not a WebKit window somewhere else, and everything in it
/// is also on disk at `log.fileURL` so a session can read it directly.
struct WebConsoleSectionView: View {
    let log: WebConsoleLog

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case console = "Console"
        case network = "Network"
        case errors = "Errors"
        var id: String { rawValue }
    }

    @State private var filter: Filter = .all
    @State private var follow = true
    @State private var copiedPath = false

    private var visible: [WebConsoleEntry] {
        log.entries.filter { entry in
            switch filter {
            case .all: true
            case .console: entry.kind == .console
            case .network: entry.kind == .network
            case .errors: entry.isFailure
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            transcript
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 230)

            Spacer(minLength: 4)

            Toggle(isOn: $follow) {
                Image(systemName: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help("Follow new output")

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(log.transcript, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy the whole transcript")

            // The path is the point: hand it to a session and it can read the log
            // itself rather than you relaying it.
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(log.fileURL.path, forType: .string)
                copiedPath = true
                Task { try? await Task.sleep(for: .seconds(2)); copiedPath = false }
            } label: {
                Image(systemName: copiedPath ? "checkmark" : "terminal")
            }
            .help("Copy the log file path — paste it to a session so it can read this itself")

            Button {
                log.clear()
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { entry in
                        row(entry)
                            .id(entry.id)
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: log.entries.count) { _, _ in
                guard follow, let last = visible.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            .overlay {
                if visible.isEmpty { emptyState }
            }
        }
    }

    private func row(_ entry: WebConsoleEntry) -> some View {
        Text(entry.line)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(color(for: entry))
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(for entry: WebConsoleEntry) -> Color {
        if entry.isFailure { return .red }
        if entry.level == "warn" { return .orange }
        if entry.kind == .network { return .secondary }
        return .primary
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(log.entries.isEmpty ? "No output yet" : "Nothing matches this filter")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if log.entries.isEmpty {
                Text("console.* calls, errors and fetch/XHR requests from the Safari panel land here.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
    }
}
