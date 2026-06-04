import Foundation
import Observation

/// Support categories surfaced in the Help menu + report form (spec §8).
enum SupportCategory: String, CaseIterable, Identifiable {
    case bug
    case help
    case feature

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bug: "Report a Bug"
        case .help: "Get Help"
        case .feature: "Feature Request"
        }
    }

    var symbol: String {
        switch self {
        case .bug: "ant"
        case .help: "questionmark.circle"
        case .feature: "lightbulb"
        }
    }
}

/// Result of a successful `/v1/support` POST.
struct SupportTicket: Decodable {
    let issueNumber: Int
    let url: String
}

/// One of the caller's own requests, from `/v1/support/mine`.
struct ReporterIssue: Decodable, Identifiable {
    let issueNumber: Int
    let title: String
    let state: String
    let category: String
    let updatedAt: String

    var id: Int { issueNumber }
    var isOpen: Bool { state.lowercased() == "open" }
}

/// Collects a support request (category/title/body + opt-in diagnostics) and talks
/// to the backend's `/v1/support*` endpoints using the login-minted **session
/// token** (spec §8). Sign-in (CompanionAuth) is a prerequisite — without a session
/// token there is no authenticated identity to attribute the request to.
@MainActor
@Observable
final class SupportReporter {
    @ObservationIgnored private nonisolated(unsafe) let settings: CompanionSettings
    @ObservationIgnored private let iso = ISO8601DateFormatter()

    nonisolated init(settings: CompanionSettings) {
        self.settings = settings
    }

    /// True once the user has signed in (and therefore has a session token).
    var isSignedIn: Bool { settings.login != nil }

    // MARK: - Submit

    func submit(category: SupportCategory, title: String, body: String,
                includeDiagnostics: Bool) async throws -> SupportTicket {
        let url = try endpoint("/v1/support")
        let token = try sessionToken()

        var payload: [String: Any] = [
            "category": category.rawValue,
            "title": title,
            "body": body,
        ]
        if includeDiagnostics { payload["diagnostics"] = Self.diagnostics() }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        guard let http else { throw CompanionError.badResponse }
        if http.statusCode == 503 { throw CompanionError.supportUnavailable }
        guard (200..<300).contains(http.statusCode) else {
            throw CompanionError.relayStatus(http.statusCode)
        }
        return try JSONDecoder().decode(SupportTicket.self, from: data)
    }

    // MARK: - My requests

    func fetchMine() async throws -> [ReporterIssue] {
        let url = try endpoint("/v1/support/mine")
        let token = try sessionToken()

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CompanionError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw CompanionError.relayStatus(http.statusCode)
        }
        struct Envelope: Decodable { let requests: [ReporterIssue] }
        return try JSONDecoder().decode(Envelope.self, from: data).requests
    }

    /// Human-readable "x ago" for a request's ISO-8601 `updatedAt`.
    func relativeUpdated(_ issue: ReporterIssue) -> String {
        guard let date = iso.date(from: issue.updatedAt) else { return "" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Diagnostics

    /// Non-sensitive environment facts attached when the user opts in. App + macOS
    /// version only — no paths, no secrets, so there's nothing to scrub here. Any
    /// future free-text field (e.g. a log tail) must be passed through `scrub` first.
    static func diagnostics() -> [String: String] {
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return ["appVersion": appVersion, "os": "macOS \(os)"]
    }

    /// Redact a home-dir path and token-like strings before they leave the Mac.
    /// Available for any opt-in free-text diagnostics added later.
    static func scrub(_ text: String) -> String {
        var out = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        // Collapse long token-like runs (32+ url-safe chars) to a placeholder.
        if let re = try? NSRegularExpression(pattern: "[A-Za-z0-9_-]{32,}") {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "‹redacted›")
        }
        return out
    }

    // MARK: - Helpers

    private func sessionToken() throws -> String {
        guard let token = KeychainStore.read(account: CompanionKeychain.sessionToken), !token.isEmpty else {
            throw CompanionError.notSignedIn
        }
        return token
    }

    private func endpoint(_ path: String) throws -> URL {
        var s = settings.relayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty, let url = URL(string: s + path) else { throw CompanionError.noRelayURL }
        return url
    }
}
