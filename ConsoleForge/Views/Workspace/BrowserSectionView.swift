import SwiftUI
import WebKit

/// Owns one live `WKWebView` for the browser section. Held by the section view's
/// `@State` so the web view survives every slot move, pin, and float toggle — the
/// section is rendered exactly once in the workspace ZStack and only reframed, the
/// same keep-alive shape the terminals use.
@MainActor
@Observable
final class BrowserModel {
    let webView: WKWebView

    var addressText: String = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    /// The committed URL, mirrored out so the workspace can persist it.
    var currentURL: String?

    @ObservationIgnored private var observers: [NSKeyValueObservation] = []

    init(initialURL: String?) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Developer extras must be on the configuration BEFORE the web view is built
        // from it — see the note below on the two inspector switches.
        if WKPreferences.instancesRespond(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
            configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        // Web Inspector takes TWO different switches, and only together do they give a
        // usable dev surface rather than a viewer.
        //
        // `isInspectable` (macOS 13.3+) is the SUPPORTED opt-in, but all it does is
        // expose the view to Safari ▸ Develop ▸ <this Mac> ▸ ConsoleForge. It
        // deliberately adds no "Inspect Element" to the web view's own context menu —
        // see webkit.org/blog/13936.
        //
        // The context-menu item comes from WebKit's private developer-extras
        // preference. ConsoleForge ships via Developer ID, not the App Store, so a
        // private preference is a reasonable trade for right-click-to-inspect. Guarded
        // on the setter actually existing: an unknown KVC key raises an Objective-C
        // exception that Swift cannot catch, so an unguarded `setValue` would turn a
        // future WebKit removal into a hard crash instead of a missing menu item.
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true

        // WKWebView delivers these on the main thread, so the `@Observable` writes
        // stay main-actor isolated.
        observers = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let text = view.url?.absoluteString
                    self.currentURL = text
                    if let text { self.addressText = text }
                }
            },
        ]

        if let initialURL, !initialURL.isEmpty {
            addressText = initialURL
            load(initialURL)
        }
    }

    deinit {
        observers.forEach { $0.invalidate() }
    }

    func load(_ text: String) {
        guard let url = Self.normalizedURL(text) else { return }
        addressText = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func submitAddress() { load(addressText) }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() {
        if webView.url == nil { load(addressText) } else { webView.reload() }
    }

    /// Bare hosts and paths get https://. Anything that isn't parseable as a URL is
    /// left alone rather than turned into a search — there is no search provider here.
    static func normalizedURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: "https://\(trimmed)")
    }
}

struct BrowserSectionView: View {
    @Bindable var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            Divider()
            WebViewHost(webView: model.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var addressBar: some View {
        HStack(spacing: 6) {
            Button(action: model.goBack) {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoBack)

            Button(action: model.goForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(!model.canGoForward)

            Button(action: model.reload) {
                Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
            }

            TextField("Enter a URL", text: $model.addressText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit { model.submitAddress() }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// Hosts the model's long-lived `WKWebView`. `makeNSView` hands back the *same*
/// instance every time, so a slot move re-parents the live page instead of reloading it.
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView.autoresizingMask = [.width, .height]
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
