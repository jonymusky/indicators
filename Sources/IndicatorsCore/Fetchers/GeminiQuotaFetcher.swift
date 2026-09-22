import Foundation

/// Asks Google's Cloud Code endpoint for Gemini CLI quota buckets, using the CLI's own OAuth session
/// (`~/.gemini/oauth_creds.json`). Users who authenticate Gemini CLI with an API key have no quota buckets.
public struct GeminiQuotaFetcher: Sendable {
    public static let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    public var client: HTTPClient
    public var home: URL
    public var environment: [String: String]

    public init(client: HTTPClient = HTTPClient(), home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.client = client
        self.home = home
        self.environment = environment
    }

    struct Credentials {
        var accessToken: String
        var refreshToken: String?
        var expiry: Date?
    }

    func loadCredentials() throws -> Credentials {
        let url = home.appendingPathComponent(".gemini/oauth_creds.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = JSON.string(obj["access_token"]) else {
            throw CredentialError.missing("Gemini CLI is not signed in with Google (`gemini` → Login with Google), so quota buckets are unavailable.")
        }
        return Credentials(accessToken: token, refreshToken: JSON.string(obj["refresh_token"]), expiry: JSON.date(obj["expiry_date"]))
    }

    public func fetch() async throws -> LiveUsage {
        var creds = try loadCredentials()
        if let expiry = creds.expiry, expiry < Date().addingTimeInterval(60) {
            if let refreshed = try? await refresh(creds) {
                creds = refreshed
            } else {
                throw CredentialError.expired("Gemini CLI session expired. Run `gemini` once to refresh it.")
            }
        }
        let project = try? loadProjectID()
        let body = try JSONSerialization.data(withJSONObject: project.map { ["project": $0] } ?? [:])
        let json = try await client.json("POST", Self.quotaURL, headers: ["Authorization": "Bearer \(creds.accessToken)"], body: body)
        guard let obj = json as? [String: Any] else { throw HTTPError.invalidResponse }
        return Self.parse(obj)
    }

    func loadProjectID() throws -> String? {
        if let env = environment["GOOGLE_CLOUD_PROJECT"], !env.isEmpty { return env }
        let url = home.appendingPathComponent(".gemini/google_accounts.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return JSON.string(obj["project"]) ?? JSON.string(obj["projectId"])
    }

    /// Refreshes the token with the client id/secret that ship inside the Gemini CLI package.
    func refresh(_ creds: Credentials) async throws -> Credentials {
        guard let refreshToken = creds.refreshToken else { throw CredentialError.expired("No refresh token") }
        guard let (id, secret) = Self.clientCredentials(environment: environment) else {
            throw CredentialError.expired("Gemini OAuth client id not found")
        }
        var body = URLComponents()
        body.queryItems = [
            .init(name: "client_id", value: id), .init(name: "client_secret", value: secret),
            .init(name: "refresh_token", value: refreshToken), .init(name: "grant_type", value: "refresh_token"),
        ]
        let data = Data((body.percentEncodedQuery ?? "").utf8)
        let json = try await client.json("POST", Self.tokenURL, headers: ["Content-Type": "application/x-www-form-urlencoded"], body: data)
        guard let obj = json as? [String: Any], let token = JSON.string(obj["access_token"]) else { throw HTTPError.invalidResponse }
        let expires = JSON.double(obj["expires_in"]).map { Date().addingTimeInterval($0) }
        return Credentials(accessToken: token, refreshToken: refreshToken, expiry: expires)
    }

    static func clientCredentials(environment: [String: String]) -> (String, String)? {
        if let id = environment["GEMINI_OAUTH_CLIENT_ID"], let secret = environment["GEMINI_OAUTH_CLIENT_SECRET"], !id.isEmpty, !secret.isEmpty {
            return (id, secret)
        }
        // Locate the installed CLI and scan its bundled oauth2.js for the constants.
        var candidates: [URL] = []
        if let path = environment["GEMINI_OAUTH2_JS_PATH"] { candidates.append(URL(fileURLWithPath: path)) }
        let searchRoots = ["/opt/homebrew/lib/node_modules/@google/gemini-cli", "/usr/local/lib/node_modules/@google/gemini-cli",
                           "/opt/homebrew/opt/gemini-cli/libexec/lib/node_modules/@google/gemini-cli"]
        for root in searchRoots {
            candidates.append(URL(fileURLWithPath: root).appendingPathComponent("node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"))
        }
        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let id = firstMatch(#"OAUTH_CLIENT_ID\s*=\s*['"]([^'"]+)['"]"#, in: text),
               let secret = firstMatch(#"OAUTH_CLIENT_SECRET\s*=\s*['"]([^'"]+)['"]"#, in: text) {
                return (id, secret)
            }
        }
        return nil
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Quota buckets carry `remainingFraction` per model; the lowest remaining fraction per model wins.
    public static func parse(_ obj: [String: Any]) -> LiveUsage {
        var perModel: [String: (fraction: Double, reset: Date?)] = [:]
        func visit(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let fraction = JSON.double(dict["remainingFraction"]) {
                    let model = JSON.string(dict["modelId"]) ?? JSON.string(dict["model"]) ?? "Gemini"
                    let reset = JSON.date(dict["resetTime"])
                    if let existing = perModel[model], existing.fraction <= fraction { return }
                    perModel[model] = (fraction, reset)
                    return
                }
                for v in dict.values { visit(v) }
            } else if let array = value as? [Any] {
                for v in array { visit(v) }
            }
        }
        visit(obj)
        let windows = perModel.keys.sorted().map { model in
            let entry = perModel[model]!
            return UsageWindow(label: model, percentUsed: (1 - entry.fraction) * 100, resetsAt: entry.reset)
        }
        var notes: [String] = []
        if windows.isEmpty { notes.append("Google returned no quota buckets for this account.") }
        return LiveUsage(windows: windows, notes: notes)
    }
}
