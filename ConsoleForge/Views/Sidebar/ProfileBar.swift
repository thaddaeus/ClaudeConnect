import SwiftUI
import AppKit
import AuthenticationServices

/// Pinned to the bottom of the sidebar. Signed out it's a "Sign in with GitHub"
/// pill that kicks off the OAuth flow; signed in it shows the GitHub avatar +
/// @username and opens a menu (Account Settings…, sign out).
///
/// This is the discoverable home for sign-in — the same flow also lives in
/// Settings → Account, but nobody goes looking there for it.
struct ProfileBar: View {
    @Environment(CompanionAuth.self) private var auth
    // Account settings live in their OWN plain Window, not the macOS Settings
    // scene. Every route into the Settings scene from a Menu is swallowed by
    // SwiftUI: `showSettingsWindow:` was removed in Sonoma, and both
    // `SettingsLink` and `openSettings()` silently no-op when invoked from a
    // Menu button action (it runs in the menu's dismissal context). `openWindow`
    // has none of that — it fires reliably from here.
    @Environment(\.openWindow) private var openWindow

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
                openAccountSettings()
            } label: {
                Label("Account Settings…", systemImage: "gearshape")
            }

            Divider()

            Button(role: .destructive) {
                auth.signOut()
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
                    Text("Signed in")
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

    /// Open the dedicated Account settings window. `openWindow(id:)` works
    /// reliably from a Menu action, unlike anything that targets the Settings
    /// scene. `activate` brings the app forward in case the menu was triggered
    /// while another app held focus.
    private func openAccountSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "account-settings")
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
        .help("Sign in to file bug reports and feature requests from inside the app. ConsoleForge itself never requires an account.")
    }

    private func signIn() async {
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await auth.signIn()
        } catch let err as ASWebAuthenticationSessionError where err.code == .canceledLogin {
            // User dismissed the sheet — not an error worth surfacing.
        } catch {
            // Surface detail in Settings → Account; keep the sidebar quiet.
            NSSound.beep()
        }
    }
}
