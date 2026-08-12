import Foundation
import WebKit

/// Instruments the page so the app can see what the page sees.
///
/// WKWebView exposes no CDP and its Web Inspector cannot be embedded, so the only way
/// to get console and network output into ConsoleForge is to patch them in the page
/// itself, at document start, before any app code runs.
///
/// What this reaches, honestly:
/// - `console.*`, uncaught errors and unhandled promise rejections: all of it.
/// - `fetch` and `XMLHttpRequest`: method, URL, status and duration. That is every
///   request the *application* makes, which is the interesting part.
/// - Subresource loads the browser issues itself — images, CSS, fonts, scripts,
///   beacons, and anything before this script runs — are NOT visible. There is no hook
///   for them from inside the page. Full request capture needs a real debugging
///   protocol, which is what task 9736's Phase C (managed Chrome with
///   `--remote-debugging-port`) is for.
enum WebConsoleScript {
    static let messageHandlerName = "consoleForgeWeb"

    static func userScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private static let source = """
    (function () {
      if (window.__consoleForgeInstalled) { return; }
      window.__consoleForgeInstalled = true;

      var post = function (payload) {
        try { window.webkit.messageHandlers.\(messageHandlerName).postMessage(payload); } catch (e) {}
      };

      var fmt = function (a) {
        if (typeof a === 'string') { return a; }
        if (a instanceof Error) { return a.stack || (a.name + ': ' + a.message); }
        try { return JSON.stringify(a); } catch (e) { return String(a); }
      };

      ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
        var original = console[level] ? console[level].bind(console) : null;
        console[level] = function () {
          var args = Array.prototype.slice.call(arguments);
          post({ kind: 'console', level: level, text: args.map(fmt).join(' ') });
          if (original) { original.apply(console, args); }
        };
      });

      window.addEventListener('error', function (e) {
        post({ kind: 'console', level: 'error',
               text: e.message + ' (' + (e.filename || '') + ':' + (e.lineno || 0) + ')' });
      });

      window.addEventListener('unhandledrejection', function (e) {
        post({ kind: 'console', level: 'error', text: 'Unhandled rejection: ' + fmt(e.reason) });
      });

      var originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = function (input, init) {
          var started = Date.now();
          var url = (input && input.url) ? input.url : String(input);
          var method = (init && init.method) || (input && input.method) || 'GET';
          return originalFetch.apply(this, arguments).then(function (response) {
            post({ kind: 'network', method: method, url: url,
                   status: response.status, ms: Date.now() - started });
            return response;
          }).catch(function (err) {
            post({ kind: 'network', method: method, url: url,
                   status: 0, ms: Date.now() - started, error: String(err) });
            throw err;
          });
        };
      }

      var XHR = window.XMLHttpRequest;
      if (XHR && XHR.prototype) {
        var open = XHR.prototype.open;
        var send = XHR.prototype.send;
        XHR.prototype.open = function (method, url) {
          this.__consoleForge = { method: method, url: url };
          return open.apply(this, arguments);
        };
        XHR.prototype.send = function () {
          var started = Date.now();
          var info = this.__consoleForge || {};
          var self = this;
          this.addEventListener('loadend', function () {
            post({ kind: 'network', method: info.method || 'GET', url: info.url || '',
                   status: self.status, ms: Date.now() - started });
          });
          return send.apply(this, arguments);
        };
      }
    })();
    """
}

/// Receives the instrumented page's messages. Held by the web view's content
/// controller, so it keeps only a weak reference back to the log's owner chain.
final class WebConsoleBridge: NSObject, WKScriptMessageHandler {
    private weak var log: WebConsoleLog?

    init(log: WebConsoleLog) {
        self.log = log
        super.init()
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated {
            guard let log else { return }
            let kind: WebConsoleEntry.Kind = (body["kind"] as? String) == "network" ? .network : .console
            log.append(WebConsoleEntry(
                kind: kind,
                timestamp: Date(),
                level: body["level"] as? String,
                text: body["text"] as? String,
                method: body["method"] as? String,
                url: body["url"] as? String,
                status: body["status"] as? Int,
                milliseconds: body["ms"] as? Int,
                error: body["error"] as? String
            ))
        }
    }
}
