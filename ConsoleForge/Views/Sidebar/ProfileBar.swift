import SwiftUI
import AppKit
import AuthenticationServices

/// Pinned to the bottom of the sidebar. Signed out it's a "Sign in with GitHub"
/// pill that kicks off the OAuth flow; signed in it shows the GitHub avatar +
/// @username and opens a menu (Companion Settings…, open on phone, sign out).
///
/// This is the discoverable home for companion sign-in — the same flow also
/// lives in Settings → Companion, but nobody goes looking there for it.
struct ProfileBar: View {
    @Environment(CompanionAuth.self) private var auth
    @Environment(CompanionService.self) private var service
    @Environment(CompanionSettings.self) private var settings
    // The only API that opens the SwiftUI Settings scene on macOS 14+. The
    // legacy `showSettingsWindow:` selector was removed in Sonoma (it logs an
    // error and does nothing), and `SettingsLink` is swallowed inside a Menu.
    // This action is resolved in ProfileBar's environment (the main window
    // scene), so it fires correctly when called imperatively from the menu.
    @Environment(\.openSettings) private var openSettings

    @State private var isSigningIn = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Group {
                if auth.isSignedIn {
                    signedInChip
                } else {
                    signInButton
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    // MARK: - Signed in

    private var signedInChip: some View {
        Menu {
            Button {
                openCompanionSettings()
            } label: {
                Label("Companion Settings…", systemImage: "gearshape")
            }

            if let url = URL(string: settings.relayBaseURL) {
                Link(destination: url) {
                    Label("Open companion on phone", systemImage: "iphone.gen3")
                }
            }

            Divider()

            Button(role: .destructive) {
                auth.signOut()
                service.reset()
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            HStack(spacing: 8) {
                avatar
                VStack(alignment: .leading, spacing: 1) {
                    Text(auth.login.map { "@\($0)" } ?? "GitHub")
                        .font(.callout).fontWeight(.medium)
                        .lineLimit(1)
                    Text("Companion connected")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    /// Preselect the Companion tab, then open the SwiftUI `Settings` scene via
    /// the `openSettings` environment action — the supported path on macOS 14+.
    /// `SettingsView` reads the selected tab from `@AppStorage`, so setting the
    /// default first lands the window on the Companion tab.
    private func openCompanionSettings() {
        UserDefaults.standard.set(SettingsTab.companion.rawValue, forKey: SettingsTab.storageKey)
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    @ViewBuilder
    private var avatar: some View {
        // GitHub serves a public avatar at /<login>.png — no token required.
        let url = auth.login.flatMap { URL(string: "https://github.com/\($0).png?size=48") }
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill")
                .resizable().scaledToFit()
                .foregroundStyle(.secondary)
        }
        .frame(width: 18, height: 18)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Signed out

    private var signInButton: some View {
        Button {
            Task { await signIn() }
        } label: {
            HStack(spacing: 8) {
                if isSigningIn {
                    ProgressView().controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.body)
                }
                Text(isSigningIn ? "Signing in…" : "Sign in with GitHub")
                    .font(.callout)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSigningIn)
        .help("Sign in to enable phone alerts. ConsoleForge itself never requires an account.")
    }

    private func signIn() async {
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await auth.signIn()
        } catch let err as ASWebAuthenticationSessionError where err.code == .canceledLogin {
            // User dismissed the sheet — not an error worth surfacing.
        } catch {
            // Surface detail in Settings → Companion; keep the sidebar quiet.
            NSSound.beep()
        }
    }
}
