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

    /// Stable per-install identifier. Generated once and never changes.
    let deviceId: String

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Booleans default to false from UserDefaults; seed sensible defaults on
        // first launch (before any value has been written).
        if defaults.object(forKey: Keys.alertOnBell) == nil { defaults.set(true, forKey: Keys.alertOnBell) }
        if defaults.object(forKey: Keys.alertOnSettled) == nil { defaults.set(true, forKey: Keys.alertOnSettled) }
        if defaults.object(forKey: Keys.alertOnExit) == nil { defaults.set(true, forKey: Keys.alertOnExit) }
        if defaults.object(forKey: Keys.settleSeconds) == nil { defaults.set(3.0, forKey: Keys.settleSeconds) }

        companionEnabled = defaults.bool(forKey: Keys.enabled)
        relayBaseURL = defaults.string(forKey: Keys.relayBaseURL) ?? ""
        alertOnBell = defaults.bool(forKey: Keys.alertOnBell)
        alertOnSettled = defaults.bool(forKey: Keys.alertOnSettled)
        alertOnExit = defaults.bool(forKey: Keys.alertOnExit)
        settleSeconds = defaults.double(forKey: Keys.settleSeconds)

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
        static let deviceId = "companion.deviceId"
    }
}
