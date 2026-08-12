import AppKit
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

    init(initialURL: String?, log: WebConsoleLog) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        // Instrument the page so its console and network activity land in the Web
        // Output panel — and in a file a session can read. This, not the Web Inspector,
        // is how the console sees what the in-app browser is doing: WebKit's inspector
        // cannot be hosted in a slot and its output is unreachable from here.
        configuration.userContentController.addUserScript(WebConsoleScript.userScript())
        configuration.userContentController.add(WebConsoleBridge(log: log),
                                                name: WebConsoleScript.messageHandlerName)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        // Kept because acceptance criterion 7 asks for it, and it costs nothing: it
        // exposes the view to Safari ▸ Develop for the rare deep dive. It is NOT the
        // primary path — the Web Output panel is, because that is the one the console
        // can actually see. Do not try WebKit's private developer-extras preference to
        // get a right-click "Inspect Element": clicking it makes WebKit dock an
        // inspector INSIDE the web view, which a third-party host cannot render, and
        // the panel goes half-dead.
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

    /// Hand the current page to Safari. Web Inspector for an embedded WKWebView is
    /// only reachable from Safari's Develop menu, so this is the shortest path to real
    /// dev tools. Targets Safari specifically, not the default browser, for that reason.
    func openInSafari() {
        guard let url = webView.url ?? Self.normalizedURL(addressText) else { return }
        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            NSWorkspace.shared.open([url], withApplicationAt: safari,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
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

            // Escape hatch for the rare case the Web Output panel is not enough and you
            // want the full Web Inspector. Not the primary path.
            Button(action: model.openInSafari) {
                Image(systemName: "safari")
            }
            .disabled(model.currentURL == nil)
            .help("Open this page in Safari for the full Web Inspector")
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
