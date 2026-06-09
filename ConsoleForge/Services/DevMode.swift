import Foundation

/// Dev-only behaviors gate on this. It is true ONLY when the app was launched by
/// `scripts/dev.sh`, which passes `--dev-hotswap`. A normal Finder/Dock launch
/// (i.e. prod) never carries that argument, so prod follows the app's normal
/// restore behavior and these shims stay out of shipped use.
enum DevMode {
    /// Launched via the dev hot-swap script.
    static let isHotSwap = ProcessInfo.processInfo.arguments.contains("--dev-hotswap")
}
