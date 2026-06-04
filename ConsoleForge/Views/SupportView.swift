import SwiftUI
import AppKit
import AuthenticationServices

/// Panes of the Support window, persisted so the Help menu can deep-link
/// ("My Requests…" jumps straight to the list).
enum SupportPane: String {
    case new
    case mine

    static let storageKey = "supportSelectedPane"
    /// Category to preselect when the Help menu opens the "New Request" pane.
    static let categoryKey = "supportDefaultCategory"
}

/// Help-menu entries that open the Support window, deep-linked to a pane/category.
/// `openWindow(id:)` fires reliably from a menu action (unlike Settings-scene routes),
/// and a `Commands` struct can read `@Environment(\.openWindow)` where the App can't.
struct SupportCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Report a Bug…") { open(.new, category: .bug) }
            Button("Get Help…") { open(.new, category: .help) }
            Button("Request a Feature…") { open(.new, category: .feature) }
            Divider()
            Button("My Requests…") { open(.mine, category: nil) }
        }
    }

    private func open(_ pane: SupportPane, category: SupportCategory?) {
        UserDefaults.standard.set(pane.rawValue, forKey: SupportPane.storageKey)
        if let category {
            UserDefaults.standard.set(category.rawValue, forKey: SupportPane.categoryKey)
        }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "support")
    }
}

/// The Support window (Help → Report a Bug / Get Help / My Requests). Sends
/// requests through `SupportReporter`; requires GitHub sign-in for the session
/// token. Issues are private — status is surfaced here, never on GitHub.
struct SupportView: View {
    @Environment(SupportReporter.self) private var reporter
    @Environment(CompanionAuth.self) private var auth
    @AppStorage(SupportPane.storageKey) private var pane: SupportPane = .new

    var body: some View {
        VStack(spacing: 0) {
            if auth.isSignedIn {
                Picker("", selection: $pane) {
                    Text("New Request").tag(SupportPane.new)
                    Text("My Requests").tag(SupportPane.mine)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(12)

                Divider()

                switch pane {
                case .new: NewRequestForm()
                case .mine: MyRequestsList()
                }
            } else {
                SignInPrompt()
            }
        }
        .frame(minWidth: 480, minHeight: 520)
    }
}

// MARK: - New request

private struct NewRequestForm: View {
    @Environment(SupportReporter.self) private var reporter

    @AppStorage(SupportPane.categoryKey) private var categoryRaw: String = SupportCategory.bug.rawValue
    @State private var title = ""
    @State private var details = ""
    @State private var includeDiagnostics = true
    @State private var isSubmitting = false
    @State private var result: SupportTicket?
    @State private var error: String?

    private var category: SupportCategory {
        SupportCategory(rawValue: categoryRaw) ?? .bug
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: Binding(
                    get: { category },
                    set: { categoryRaw = $0.rawValue }
                )) {
                    ForEach(SupportCategory.allCases) { c in
                        Label(c.label, systemImage: c.symbol).tag(c)
                    }
                }
                TextField("Title", text: $title, prompt: Text("Brief summary"))
            }

            Section("Details") {
                TextEditor(text: $details)
                    .frame(minHeight: 140)
                    .font(.body)
                Text(category == .bug
                     ? "What happened, what you expected, and steps to reproduce."
                     : "Describe what you need help with or the feature you'd like.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Section {
                Toggle("Attach diagnostics", isOn: $includeDiagnostics)
                Text("Includes app version (\(appVersion)) and your macOS version — no paths or secrets.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            if let result {
                Section {
                    Label("Sent — request #\(result.issueNumber). We'll follow up here.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        if isSubmitting { ProgressView().controlSize(.small) }
                        Text(isSubmitting ? "Sending…" : "Send")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private func submit() async {
        isSubmitting = true
        error = nil
        result = nil
        defer { isSubmitting = false }
        do {
            let ticket = try await reporter.submit(
                category: category,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                body: details.trimmingCharacters(in: .whitespacesAndNewlines),
                includeDiagnostics: includeDiagnostics
            )
            result = ticket
            title = ""
            details = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - My requests

private struct MyRequestsList: View {
    @Environment(SupportReporter.self) private var reporter

    @State private var issues: [ReporterIssue] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        content
        .overlay(alignment: .topTrailing) {
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .padding(8)
            .disabled(isLoading)
        }
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if isLoading && issues.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView("Couldn't load requests", systemImage: "wifi.exclamationmark",
                                   description: Text(error))
        } else if issues.isEmpty {
            ContentUnavailableView("No requests yet", systemImage: "tray",
                                   description: Text("Reports you send appear here with their status."))
        } else {
            List(issues) { issue in
                HStack(spacing: 10) {
                    Image(systemName: issue.isOpen ? "circle.dotted" : "checkmark.circle.fill")
                        .foregroundStyle(issue.isOpen ? Color.secondary : Color.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title).lineLimit(2)
                        Text("\(issue.category.capitalized) · #\(issue.issueNumber) · \(reporter.relativeUpdated(issue))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(issue.isOpen ? "Open" : "Closed")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(issue.isOpen ? .blue : .secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            issues = try await reporter.fetchMine()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Signed out

private struct SignInPrompt: View {
    @Environment(CompanionAuth.self) private var auth
    @State private var isSigningIn = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lifepreserver")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Sign in to send support requests")
                .font(.headline)
            Text("Support uses your GitHub sign-in to keep your requests private and let us follow up. ConsoleForge itself never requires an account.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button {
                Task { await signIn() }
            } label: {
                if isSigningIn {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Sign in with GitHub", systemImage: "person.crop.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSigningIn)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func signIn() async {
        isSigningIn = true
        error = nil
        defer { isSigningIn = false }
        do {
            try await auth.signIn()
        } catch let err as ASWebAuthenticationSessionError where err.code == .canceledLogin {
            // dismissed — ignore
        } catch {
            self.error = error.localizedDescription
        }
    }
}
