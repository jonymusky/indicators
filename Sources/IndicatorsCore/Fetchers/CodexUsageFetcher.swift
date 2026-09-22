import Foundation

/// Reads the Codex CLI session (`~/.codex/auth.json`) and asks ChatGPT for the plan's rate-limit windows.
public struct CodexUsageFetcher: Sendable {
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

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
        var accountID: String?
    }

    func loadCredentials() throws -> Credentials {
        var candidates: [URL] = []
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            candidates.append(URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json"))
        }
        candidates.append(home.appendingPathComponent(".codex/auth.json"))
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard let tokens = JSON.dict(obj["tokens"]), let token = JSON.string(tokens["access_token"]), !token.isEmpty else {
                throw CredentialError.missing("Codex is using an API key, not a ChatGPT login, so there are no plan limits to show.")
            }
            return Credentials(accessToken: token, accountID: JSON.string(tokens["account_id"]))
        }
        throw CredentialError.missing("Sign in to Codex CLI (`codex login`) to see plan limits.")
    }

    public func fetch() async throws -> LiveUsage {
        let creds = try loadCredentials()
        var headers = ["Authorization": "Bearer \(creds.accessToken)"]
        if let account = creds.accountID { headers["ChatGPT-Account-Id"] = account }
        let json = try await client.json("GET", Self.usageURL, headers: headers)
        guard let obj = json as? [String: Any] else { throw HTTPError.invalidResponse }
        return Self.parse(obj)
    }

    public static func parse(_ obj: [String: Any]) -> LiveUsage {
        var windows: [UsageWindow] = []
        if let rate = JSON.dict(obj["rate_limit"]) {
            for key in ["primary_window", "secondary_window"] {
                guard let w = JSON.dict(rate[key]), let pct = JSON.double(w["used_percent"]) else { continue }
                let seconds = JSON.int(w["limit_window_seconds"]) ?? 0
                windows.append(UsageWindow(label: WindowLabel.fromSeconds(seconds), percentUsed: pct, resetsAt: JSON.date(w["reset_at"])))
            }
        }
        var notes: [String] = []
        if let credits = JSON.dict(obj["credits"]), JSON.bool(credits["has_credits"]) == true,
           let balance = JSON.double(credits["balance"]) {
            notes.append(String(format: "Credits balance: $%.2f", balance))
        }
        let plan = JSON.string(obj["plan_type"]).map { Self.planName($0) }
        return LiveUsage(windows: windows, plan: plan, notes: notes)
    }

    static func planName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}
