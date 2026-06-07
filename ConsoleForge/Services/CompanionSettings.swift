import Foundation
import Observation

/// User-facing companion preferences, backed by UserDefaults so they persist and
/// are observable by both the Settings UI and `CompanionService`. The device token
/// is a secret and lives in the Keychain (see `CompanionService`), never here.
@Observable
final class CompanionSettings {
    var companionEnabled: Bool { didSet { defaults.set(companionEnabled, forKey: Keys.enabled) } }
    var relayBaseURL: String { didSet { defaults.set(relayBaseURL, forKey: Keys.relayBaseURL) } }
    var alertOnBell: Bool { didSet { defaults.set(alertOnBell, forKey: Keys.alertOnBell) } }
    var alertOnSettled: Bool { didSet { defaults.set(alertOnSettled, forKey: Keys.alertOnSettled) } }
    var alertOnExit: Bool { didSet { defaults.set(alertOnExit, forKey: Keys.alertOnExit) } }
    var settleSeconds: Double { didSet { defaults.set(settleSeconds, forKey: Keys.settleSeconds) } }
    /// Whether to read the session transcript and include the last prompt/response
    /// and any blocking question (with its options) in companion events. This sends
    /// conversation content off-device to the relay/phone, so it's user-gated.
    var includeContent: Bool { didSet { defaults.set(includeContent, forKey: Keys.includeContent) } }
    /// GitHub login of the signed-in user, or nil. Written by CompanionAuth.
    var login: String? { didSet { defaults.set(login, forKey: Keys.login) } }

    /// Stable per-install identifier. Generated once and never changes.
    let deviceId: String

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored static let defaultRelayURL = "https://app.consoleforge.us"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Booleans default to false from UserDefaults; seed sensible defaults on
        // first launch (before any value has been written).
        if defaults.object(forKey: Keys.alertOnBell) == nil { defaults.set(true, forKey: Keys.alertOnBell) }
        if defaults.object(forKey: Keys.alertOnSettled) == nil { defaults.set(true, forKey: Keys.alertOnSettled) }
        if defaults.object(forKey: Keys.alertOnExit) == nil { defaults.set(true, forKey: Keys.alertOnExit) }
        if defaults.object(forKey: Keys.settleSeconds) == nil { defaults.set(3.0, forKey: Keys.settleSeconds) }
        if defaults.object(forKey: Keys.includeContent) == nil { defaults.set(true, forKey: Keys.includeContent) }
        // Default the relay to the deployed backend (the URL is effectively fixed;
        // kept overridable for dev).
        if defaults.object(forKey: Keys.relayBaseURL) == nil {
            defaults.set(Self.defaultRelayURL, forKey: Keys.relayBaseURL)
        }

        companionEnabled = defaults.bool(forKey: Keys.enabled)
        relayBaseURL = defaults.string(forKey: Keys.relayBaseURL) ?? Self.defaultRelayURL
        alertOnBell = defaults.bool(forKey: Keys.alertOnBell)
        alertOnSettled = defaults.bool(forKey: Keys.alertOnSettled)
        alertOnExit = defaults.bool(forKey: Keys.alertOnExit)
        settleSeconds = defaults.double(forKey: Keys.settleSeconds)
        includeContent = defaults.bool(forKey: Keys.includeContent)
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
        static let enabled = "companion.enabled"
        static let relayBaseURL = "companion.relayBaseURL"
        static let alertOnBell = "companion.alertOnBell"
        static let alertOnSettled = "companion.alertOnSettled"
        static let alertOnExit = "companion.alertOnExit"
        static let settleSeconds = "companion.settleSeconds"
        static let includeContent = "companion.includeContent"
        static let deviceId = "companion.deviceId"
        static let login = "companion.login"
    }
}
