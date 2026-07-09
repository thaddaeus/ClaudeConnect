import Foundation
import Observation

/// Account preferences, backed by UserDefaults so they persist and are observable
/// by both the Settings UI and `SupportReporter`. Tokens are secrets and live in
/// the Keychain (see `CompanionAuth`), never here.
///
/// The `companion.` key prefix is retained deliberately: these are live UserDefaults
/// keys on existing installs, and renaming them would silently reset users' state.
@Observable
final class CompanionSettings {
    var relayBaseURL: String { didSet { defaults.set(relayBaseURL, forKey: Keys.relayBaseURL) } }
    /// GitHub login of the signed-in user, or nil. Written by CompanionAuth.
    var login: String? { didSet { defaults.set(login, forKey: Keys.login) } }

    /// Stable per-install identifier. Generated once and never changes.
    let deviceId: String

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored static let defaultRelayURL = "https://app.consoleforge.us"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Default the backend to the deployed Worker (the URL is effectively fixed;
        // kept overridable for dev).
        if defaults.object(forKey: Keys.relayBaseURL) == nil {
            defaults.set(Self.defaultRelayURL, forKey: Keys.relayBaseURL)
        }

        relayBaseURL = defaults.string(forKey: Keys.relayBaseURL) ?? Self.defaultRelayURL
        login = defaults.string(forKey: Keys.login)

        if let existing = defaults.string(forKey: Keys.deviceId) {
            deviceId = existing
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: Keys.deviceId)
            deviceId = generated
        }
    }

    private enum Keys {
        static let relayBaseURL = "companion.relayBaseURL"
        static let deviceId = "companion.deviceId"
        static let login = "companion.login"
    }
}
