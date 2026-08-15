import AppKit
import Foundation
import WebKit

/// Lets a session drive the in-app browser section — navigate it, read from it,
/// scroll it, screenshot it.
///
/// WHY THIS EXISTS AT APP SCOPE. `BrowserModel` is owned by `WorkspaceView`'s
/// `@State`, which is the right home for it: the web view has to survive every slot
/// move, so it belongs to the thing that outlives the moves. But a command arriving
/// on the file bus has no view tree to reach into. This is the same hoist
/// `TerminalSessionManager` needed for the voice work — the model stays where it is,
/// and registers itself here so the outside world has a door.
///
/// The registration is a WEAK reference on purpose. The browser section closing must
/// still release the web view; if this held it strongly, closing the panel would look
/// like it worked while the page kept living behind it.
///
/// THE BUS IS FIRE-AND-FORGET, AND EVAL IS NOT. Every other verb the CLI has (open a
/// tab, close a tab, open a browser window) is a one-way drop: write a JSON file, the
/// app picks it up, done. `--browser-eval` has to hand a VALUE back, so this adds a
/// response half — the command carries a `requestID`, and the answer is written to
/// `responses/<requestID>.json` for the CLI to pick up. Replies are written for every
/// verb, not just eval, so a session can tell "it worked" from "no browser is open"
/// rather than guessing from silence.
@MainActor
@Observable
final class BrowserControl {
    static let shared = BrowserControl()

    /// The live browser section, or nil when the section is closed.
    @ObservationIgnored private weak var model: BrowserModel?

    private init() {}

    /// `responses/` beside `commands/`, so the channel split covers replies too — a
    /// beta session must never read production's answer to its own request id.
    static var responsesDirectory: URL {
        AppChannel.supportDirectory("responses")
    }

    func register(_ model: BrowserModel?) {
        self.model = model
    }

    var isOpen: Bool { model != nil }

    // MARK: - Command handling

    func handle(_ command: TabCommand) {
        let requestID = command.requestID
        guard let model else {
            reply(requestID, ["ok": false,
                              "error": "The browser section is not open. Open it in the app "
                                     + "(Layout ▸ Safari, ⌘⇧B) and run this again."])
            return
        }

        switch command.action {
        case "browser-navigate":
            guard let url = command.url, !url.isEmpty else {
                reply(requestID, ["ok": false, "error": "browser-navigate needs a URL"])
                return
            }
            model.load(url)
            // Answer once the page commits, not the instant the load starts — a session
            // that navigates and immediately evals would otherwise read the OLD page.
            waitForLoad(model) { [weak self] in
                self?.reply(requestID, ["ok": true, "url": model.currentURL ?? url])
            }

        case "browser-eval":
            guard let script = command.script, !script.isEmpty else {
                reply(requestID, ["ok": false, "error": "browser-eval needs a script"])
                return
            }
            evaluate(model, script) { [weak self] payload in
                self?.reply(requestID, payload)
            }

        case "browser-scroll":
            // Expressed in JS rather than by poking the scroll view: the page may
            // scroll an inner element, and window.scrollBy honours whatever the
            // document actually does.
            let js: String
            if let to = command.scrollTo {
                js = "window.scrollTo({top: \(to), behavior: 'instant'}); window.scrollY"
            } else {
                let by = command.scrollBy ?? 0
                js = "window.scrollBy({top: \(by), behavior: 'instant'}); window.scrollY"
            }
            evaluate(model, js) { [weak self] payload in
                var payload = payload
                payload["scrollY"] = payload.removeValue(forKey: "value")
                self?.reply(requestID, payload)
            }

        case "browser-screenshot":
            screenshot(model, to: command.path) { [weak self] payload in
                self?.reply(requestID, payload)
            }

        default:
            reply(requestID, ["ok": false, "error": "unknown browser action \(command.action)"])
        }
    }

    // MARK: - Verbs

    private func evaluate(_ model: BrowserModel, _ script: String,
                          then finish: @escaping ([String: Any]) -> Void) {
        model.webView.evaluateJavaScript(script) { value, error in
            MainActor.assumeIsolated {
                if let error {
                    // A thrown page error is a RESULT, not a transport failure — the
                    // session asked a question and this is the answer. Reported with
                    // ok:false so a script can branch, and the message kept verbatim.
                    finish(["ok": false, "error": Self.describe(error)])
                    return
                }
                finish(["ok": true, "value": Self.jsonSafe(value)])
            }
        }
    }

    private func screenshot(_ model: BrowserModel, to path: String?,
                           then finish: @escaping ([String: Any]) -> Void) {
        let config = WKSnapshotConfiguration()
        // Full width at the view's current size. Height follows the view, not the
        // document — a full-page capture would need scroll stitching, which is a
        // different feature and not what "show me the panel" means.
        config.afterScreenUpdates = true
        model.webView.takeSnapshot(with: config) { image, error in
            MainActor.assumeIsolated {
                if let error {
                    finish(["ok": false, "error": Self.describe(error)])
                    return
                }
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    finish(["ok": false, "error": "could not encode the snapshot as PNG"])
                    return
                }
                // Default under the channel's support dir so screenshots do not litter
                // whatever directory the session happens to be sitting in.
                let target: URL
                if let path, !path.isEmpty {
                    target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                } else {
                    target = AppChannel.supportDirectory("screenshots")
                        .appendingPathComponent("\(UUID().uuidString).png")
                }
                do {
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try png.write(to: target)
                    finish(["ok": true, "path": target.path,
                            "width": Int(image.size.width), "height": Int(image.size.height)])
                } catch {
                    finish(["ok": false, "error": Self.describe(error)])
                }
            }
        }
    }

    /// Poll `isLoading` rather than installing a navigation delegate: `BrowserModel`
    /// does not own one, and taking `WKNavigationDelegate` here would silently steal it
    /// from any future owner. Bounded so a page that never finishes still answers.
    private func waitForLoad(_ model: BrowserModel, then finish: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(30)
        func poll() {
            if !model.webView.isLoading || Date() >= deadline {
                finish()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { poll() } }
        }
        // One hop first: isLoading is not yet true on the turn load() was called.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { poll() } }
    }

    // MARK: - Replies

    private func reply(_ requestID: String?, _ payload: [String: Any]) {
        guard let requestID, !requestID.isEmpty else { return }
        let url = Self.responsesDirectory.appendingPathComponent("\(requestID).json")
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        // Write beside the target and move into place, so a CLI polling the directory
        // can never read a half-written file and decode it as a malformed reply.
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(requestID).partial")
        try? data.write(to: temp)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: temp, to: url)
    }

    /// `evaluateJavaScript` hands back Obj-C bridged values; anything that is not
    /// JSON-representable becomes its description rather than failing the whole reply.
    private static func jsonSafe(_ value: Any?) -> Any {
        guard let value, !(value is NSNull) else { return NSNull() }
        if JSONSerialization.isValidJSONObject([value]) { return value }
        return String(describing: value)
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        // WKWebView puts the page's own exception text here; it is far more useful to a
        // session than the generic "A JavaScript exception occurred".
        if let detail = ns.userInfo["WKJavaScriptExceptionMessage"] as? String { return detail }
        return ns.localizedDescription
    }
}
