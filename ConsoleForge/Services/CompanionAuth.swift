import AppKit
import AuthenticationServices
import Foundation
import Observation

/// Keychain account names written by the auth service on sign-in. The `companion.`
/// prefix is a live account name in users' Keychains — renaming it would orphan the
/// stored tokens and silently sign everyone out.
enum CompanionKeychain {
    static let deviceToken = "companion.deviceToken"
    static let sessionToken = "companion.sessionToken"
}

/// Errors surfaced to the account + support UI (sign-in / backend failures).
enum CompanionError: LocalizedError {
    case noRelayURL
    case relayStatus(Int)
    case badResponse
    case notSignedIn
    case supportUnavailable

    var errorDescription: String? {
        switch self {
        case .noRelayURL: "No backend URL configured."
        case .relayStatus(let code): "Backend returned HTTP \(code)."
        case .badResponse: "Unexpected response from the backend."
        case .notSignedIn: "Sign in with GitHub first."
        case .supportUnavailable: "Support isn’t available yet — please try again later."
        }
    }
}

/// Drives GitHub sign-in (spec §7). Runs the OAuth flow via
/// ASWebAuthenticationSession; the Worker performs the code→token exchange and
/// redirects back to `consoleforge://auth/callback#device=…&session=…&login=…`.
/// We store the login-minted device + session tokens in the Keychain; support
/// requests authenticate with the session token, never the OAuth token.
///
/// Sign-in exists solely to attribute support requests to a GitHub identity —
/// ConsoleForge itself never requires an account.
@MainActor
@Observable
final class CompanionAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// GitHub login of the signed-in user, or nil. Backed by the observable
    /// CompanionSettings so this type holds no duplicate state of its own.
    var login: String? { settings.login }
    /// Signed in iff we have an identity (we always set login + tokens together).
    var isSignedIn: Bool { settings.login != nil }

    // Set once in the nonisolated init before any concurrency; only read thereafter.
    @ObservationIgnored private nonisolated(unsafe) let settings: CompanionSettings
    @ObservationIgnored private var session: ASWebAuthenticationSession?

    nonisolated init(settings: CompanionSettings) {
        self.settings = settings
        super.init()
    }

    /// Run the GitHub OAuth flow and persist the minted tokens.
    func signIn() async throws {
        guard let base = normalizedRelayURL() else { throw CompanionError.noRelayURL }
        guard let startURL = URL(string: "\(base)/v1/auth/start?platform=mac&deviceId=\(settings.deviceId)") else {
            throw CompanionError.noRelayURL
        }

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: startURL,
                callbackURLScheme: "consoleforge"
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: CompanionError.badResponse)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: CompanionError.badResponse)
            }
        }

        let params = Self.parseFragment(callbackURL)
        guard let device = params["device"], !device.isEmpty else { throw CompanionError.badResponse }
        KeychainStore.write(device, account: CompanionKeychain.deviceToken)
        if let session = params["session"], !session.isEmpty {
            KeychainStore.write(session, account: CompanionKeychain.sessionToken)
        }
        // Setting settings.login flips isSignedIn/login (computed) and drives the UI.
        settings.login = params["login"]
    }

    /// Forget the signed-in identity and all minted tokens.
    func signOut() {
        KeychainStore.delete(account: CompanionKeychain.deviceToken)
        KeychainStore.delete(account: CompanionKeychain.sessionToken)
        settings.login = nil
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApplication.shared.keyWindow
                ?? NSApplication.shared.windows.first
                ?? ASPresentationAnchor()
        }
    }

    // MARK: - Helpers

    private func normalizedRelayURL() -> String? {
        var s = settings.relayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? nil : s
    }

    /// Parse `device=…&session=…&login=…` out of the callback URL fragment.
    private static func parseFragment(_ url: URL) -> [String: String] {
        let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment ?? ""
        var out: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0])
            let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            out[key] = value
        }
        return out
    }
}
