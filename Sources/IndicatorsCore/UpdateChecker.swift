import Foundation

/// Looks up the latest GitHub release (public API, no token) and compares it with the running version.
public struct UpdateChecker: Sendable {
    public static let latestURL = URL(string: "https://api.github.com/repos/jonymusky/indicators/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/jonymusky/indicators/releases/latest")!

    public struct Release: Sendable, Equatable, Codable {
        public var version: String
        public var url: URL
        public var notes: String?
        public var publishedAt: Date?
    }

    public var client: HTTPClient

    public init(client: HTTPClient = HTTPClient()) { self.client = client }

    public func latest() async throws -> Release {
        let json = try await client.json("GET", Self.latestURL, headers: ["Accept": "application/vnd.github+json"])
        guard let obj = json as? [String: Any], let tag = JSON.string(obj["tag_name"]) else { throw HTTPError.invalidResponse }
        let url = JSON.string(obj["html_url"]).flatMap(URL.init(string:)) ?? Self.releasesPage
        return Release(version: Self.normalize(tag), url: url, notes: JSON.string(obj["body"]), publishedAt: JSON.date(obj["published_at"]))
    }

    /// "v0.2.0" → "0.2.0"
    public static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// Semantic comparison of dotted versions; missing components count as 0, pre-release suffixes are ignored.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: "-").first.map(String.init)?.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 } ?? []
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// True when the app was installed through the Homebrew cask (upgrade should go through brew).
    public static func installedViaHomebrew(appPath: String = Bundle.main.bundlePath) -> Bool {
        let caskrooms = ["/opt/homebrew/Caskroom/indicators", "/usr/local/Caskroom/indicators"]
        if caskrooms.contains(where: { FileManager.default.fileExists(atPath: $0) }) { return true }
        return appPath.contains("/Caskroom/")
    }
}
