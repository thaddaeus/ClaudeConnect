import Foundation

/// Which build of ConsoleForge this process is.
///
/// Production and beta are installed side by side (`/Applications/ConsoleForge.app`
/// and `/Applications/ConsoleForge Beta.app`) and must never share on-disk state.
/// A separate bundle identifier alone is NOT enough: everything below used to
/// hardcode the literal string "ConsoleForge", so a beta would still have written
/// into production's tree — stomping the real tab list, racing for the same
/// `commands/` directory (so the wrong app opens a spawned tab), and interleaving
/// `events/`.
///
/// The channel is decided by the bundle identifier that each build script stamps
/// into Info.plist. Anything that is not *exactly* the production id — the beta
/// bundle, a future per-worktree build, or an unbundled `swift run` (nil
/// identifier) — counts as non-production, so a stray dev run can never write
/// into the real install's state.
enum AppChannel {
    /// Production's bundle id. Stamped by `scripts/build.sh`; never change it —
    /// it is the LaunchServices/Keychain identity every existing install carries.
    static let productionBundleID = "com.thaddaeus.ConsoleForge"

    static let isProduction: Bool = Bundle.main.bundleIdentifier == productionBundleID

    /// Application Support subdirectory name for this channel.
    ///
    /// Production's is the historical literal "ConsoleForge" and must stay that
    /// way — every existing install reads that exact path, so renaming it would
    /// silently orphan the user's sessions.
    static var supportDirectoryName: String {
        isProduction ? "ConsoleForge" : "ConsoleForge Beta"
    }

    /// Keychain service namespace. Diverged per channel so a beta build can
    /// neither read nor overwrite production's credential items.
    static var keychainService: String {
        isProduction ? productionBundleID : "\(productionBundleID).beta"
    }

    /// `~/Library/Application Support/<channel dir>[/subpath]`, created on demand.
    static func supportDirectory(_ subpath: String? = nil) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        var dir = appSupport.appendingPathComponent(supportDirectoryName, isDirectory: true)
        if let subpath {
            dir.appendPathComponent(subpath, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
