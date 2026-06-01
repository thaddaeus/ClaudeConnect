import SwiftUI
import AppKit
import AuthenticationServices

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            CompanionSettingsView()
                .tabItem { Label("Companion", systemImage: "iphone.gen3") }
        }
        .frame(width: 540, height: 560)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage("claudeBinaryPath") private var claudeBinaryPath: String = ""
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

// MARK: - Companion

struct CompanionSettingsView: View {
    @Environment(CompanionSettings.self) private var settings
    @Environment(CompanionService.self) private var service
    @Environment(CompanionAuth.self) private var auth

    @State private var isSigningIn = false
    @State private var authError: String?

    var body: some View {
        @Bindable var settings = settings

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
                        service.reset()
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
                    Text("The companion is a cloud feature — sign in to enable phone alerts. ConsoleForge itself never requires an account.")
                        .font(.caption2).foregroundStyle(.tertiary)
                    if let authError {
                        Label(authError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            Section("Companion") {
                Toggle("Enable phone companion", isOn: $settings.companionEnabled)
                    .disabled(!auth.isSignedIn)
            }

            Section("Your phone") {
                Text("On your phone, open the companion and **sign in with the same GitHub account** — it'll show this Mac's tabs automatically.")
                    .font(.callout)
                Link(displayURL, destination: URL(string: settings.relayBaseURL) ?? URL(string: "https://example.com")!)
                    .font(.caption)
                Text("Add it to your Home Screen (Share → Add to Home Screen) so alerts work when it's closed.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .disabled(!auth.isSignedIn)

            Section("Alerts") {
                Toggle("Bell — turn finished / prompt", isOn: $settings.alertOnBell)
                Toggle("Settled — background tab went quiet", isOn: $settings.alertOnSettled)
                Toggle("Exited — process terminated", isOn: $settings.alertOnExit)
                Stepper(value: $settings.settleSeconds, in: 0...30, step: 1) {
                    Text("Settle delay: \(settleLabel)")
                }
                .disabled(!settings.alertOnSettled)
                Text("How long a background tab must be quiet before it counts as \u{201C}settled.\u{201D} 0 disables the settled alert.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .disabled(!auth.isSignedIn || !settings.companionEnabled)

            Section("Connection") {
                LabeledContent("Last sent", value: lastSentLabel)
                LabeledContent("Queued events", value: "\(service.queuedCount)")
                if let err = service.lastError {
                    LabeledContent("Last error") { Text(err).foregroundStyle(.orange) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var settleLabel: String {
        settings.settleSeconds <= 0 ? "off" : "\(Int(settings.settleSeconds))s"
    }

    private var displayURL: String {
        settings.relayBaseURL.replacingOccurrences(of: "https://", with: "")
    }

    private var lastSentLabel: String {
        guard let date = service.lastSuccessfulPost else { return "never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
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
