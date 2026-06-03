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
            // SettingsLink does NOT fire when nested inside a Menu's content —
            // the menu dismisses and swallows its action — and a
            // .simultaneousGesture on a native menu item never fires either.
            // Use a plain Button: preselect the Companion tab, then open the
            // Settings scene via showSettingsWindow: dispatched async so the
            // menu closes first. This is the reliable path on macOS 14+.
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

    /// Preselect the Companion tab, then open the SwiftUI `Settings` scene.
    /// Dispatched async so the enclosing menu finishes dismissing before the
    /// window is asked to come forward; `showSettingsWindow:` is the macOS 13+
    /// selector for the Settings scene action.
    private func openCompanionSettings() {
        UserDefaults.standard.set(SettingsTab.companion.rawValue, forKey: SettingsTab.storageKey)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
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
