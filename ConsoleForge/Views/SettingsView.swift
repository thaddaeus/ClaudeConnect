import SwiftUI
import AppKit
import AuthenticationServices

/// Settings tabs, persisted so the profile menu can deep-link to a specific tab
/// (e.g. "Account Settings…" jumps straight to the Account pane).
enum SettingsTab: String {
    case general
    case account

    /// UserDefaults key shared with anything that wants to preselect a tab.
    static let storageKey = "settingsSelectedTab"
}

struct SettingsView: View {
    @AppStorage(SettingsTab.storageKey) private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AccountSettingsView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(SettingsTab.account)
        }
        .frame(width: 540, height: 420)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage("claudeBinaryPath") private var claudeBinaryPath: String = ""
    @AppStorage(LinkPastingTerminalView.pasteLinksAsMarkdownKey)
    private var pasteLinksAsMarkdown = true
    @State private var detectedPath: String?

    var body: some View {
        Form {
            Section("Claude Binary") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Path to claude binary", text: $claudeBinaryPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") { selectBinary() }
                        Button("Auto-detect") { autoDetect() }
                    }

                    if claudeBinaryPath.isEmpty {
                        if let detected = detectedPath {
                            statusLine(.green, "checkmark.circle.fill", "Auto-detected: \(detected)")
                        } else {
                            statusLine(.orange, "exclamationmark.triangle.fill",
                                       "Claude binary not found. Set the path manually or install Claude Code.")
                        }
                    } else if FileManager.default.isExecutableFile(atPath: claudeBinaryPath) {
                        statusLine(.green, "checkmark.circle.fill", "Valid executable")
                    } else {
                        statusLine(.red, "xmark.circle.fill", "File not found or not executable")
                    }

                    Text("Leave blank to use auto-detection. Common locations: ~/.local/bin/claude, /usr/local/bin/claude, /opt/homebrew/bin/claude")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Pasting") {
                Toggle("Paste hyperlinks as Markdown links", isOn: $pasteLinksAsMarkdown)
                Text("When the clipboard holds rich text with hyperlinks (e.g. copied from Slack), paste [label](url) so the URL survives. Plain text and bare URLs paste unchanged. Turn off for raw paste.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear { detectedPath = ShellEnvironment.shared.claudePath }
    }

    private func statusLine(_ color: Color, _ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func selectBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the claude binary"
        if panel.runModal() == .OK, let url = panel.url {
            claudeBinaryPath = url.path
        }
    }

    private func autoDetect() {
        let env = ShellEnvironment.shared
        if let path = env.claudePath {
            claudeBinaryPath = path
            detectedPath = path
        }
    }
}

// MARK: - Account

/// Sign-in exists to attribute support requests to a GitHub identity. ConsoleForge
/// itself never requires an account.
///
/// To reach a session from your phone, use Claude Code's built-in Remote Control
/// (`/rc` in a session, or `claude --rc`) rather than anything ConsoleForge ships.
struct AccountSettingsView: View {
    @Environment(CompanionAuth.self) private var auth

    @State private var isSigningIn = false
    @State private var authError: String?

    var body: some View {
        Form {
            Section("Account") {
                if auth.isSignedIn {
                    LabeledContent("Signed in") {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            Text(auth.login.map { "@\($0)" } ?? "GitHub")
                        }
                    }
                    Button("Sign out", role: .destructive) {
                        auth.signOut()
                    }
                } else {
                    Button {
                        Task { await signIn() }
                    } label: {
                        if isSigningIn {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Sign in with GitHub", systemImage: "person.crop.circle")
                        }
                    }
                    .disabled(isSigningIn)
                    Text("Sign in to file bug reports and feature requests from inside the app, and to track their status. ConsoleForge itself never requires an account.")
                        .font(.caption2).foregroundStyle(.tertiary)
                    if let authError {
                        Label(authError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            Section("Using your phone") {
                Text("ConsoleForge no longer ships a phone companion. Claude Code has **Remote Control** built in — run `/rc` in a session (or start one with `claude --rc`) to drive it from the Claude mobile app, with push notifications when it needs you.")
                    .font(.callout)
                Text("Requires a Claude Pro, Max, Team, or Enterprise plan signed in with your claude.ai account.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }

    private func signIn() async {
        isSigningIn = true
        authError = nil
        defer { isSigningIn = false }
        do {
            try await auth.signIn()
        } catch let err as ASWebAuthenticationSessionError where err.code == .canceledLogin {
            // User dismissed the sheet — not an error worth surfacing.
        } catch {
            authError = error.localizedDescription
        }
    }
}
