import Foundation

@Observable
class UpdateChecker {
    var updateAvailable = false
    var latestVersion = ""
    var downloadURL = ""

    private static let repo = "thaddaeus/ConsoleForge"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    func checkForUpdates() {
        // Don't check in dev builds (swift run)
        guard currentVersion != "dev" else { return }

        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let data = data, error == nil else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let htmlURL = json["html_url"] as? String else { return }

            let latest = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            guard let current = self?.currentVersion, latest != current,
                  Self.isNewer(latest, than: current) else { return }

            DispatchQueue.main.async {
                self?.latestVersion = latest
                self?.downloadURL = htmlURL
                self?.updateAvailable = true
            }
        }.resume()
    }

    private static func isNewer(_ a: String, than b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(aParts.count, bParts.count) {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
    }
}
