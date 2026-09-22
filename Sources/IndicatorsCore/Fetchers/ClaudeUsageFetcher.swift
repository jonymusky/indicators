import Foundation
import Security

/// Reads the Claude Code OAuth session (macOS Keychain or `~/.claude/.credentials.json`) and asks Anthropic
/// for the subscription's rate-limit windows. Nothing is written; the token is never stored by this app.
public struct ClaudeUsageFetcher: Sendable {
    public static let keychainService = "Claude Code-credentials"
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public struct Credentials: Sendable {
        public var accessToken: String
        public var expiresAt: Date?
        public var subscriptionType: String?
        public var rateLimitTier: String?
    }

    public var client: HTTPClient
    public var home: URL

    public init(client: HTTPClient = HTTPClient(), home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.client = client
        self.home = home
    }

    public func loadCredentials() throws -> Credentials {
        let data: Data
        if let keychain = Self.readKeychain() {
            data = keychain
        } else {
            let file = home.appendingPathComponent(".claude/.credentials.json")
            guard let fileData = try? Data(contentsOf: file) else {
                throw CredentialError.missing("Sign in to Claude Code (`claude`) to see subscription limits.")
            }
            data = fileData
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = JSON.dict(obj["claudeAiOauth"]),
              let token = JSON.string(oauth["accessToken"]), !token.isEmpty else {
            throw CredentialError.missing("Claude Code credentials found but no OAuth session. Run `claude` and sign in.")
        }
        return Credentials(accessToken: token, expiresAt: JSON.date(oauth["expiresAt"]),
                           subscriptionType: JSON.string(oauth["subscriptionType"]),
                           rateLimitTier: JSON.string(oauth["rateLimitTier"]))
    }

    /// Reads the Keychain item. The `security` CLI is tried first because Claude Code creates the item
    /// through it, so it is already on the item's access list and no permission dialog appears; the
    /// Security framework is the fallback (macOS then asks once to allow this app).
    static func readKeychain() -> Data? {
        if let data = readKeychainViaCLI(), !data.isEmpty { return data }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    static func readKeychainViaCLI() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        // `security -w` prints the raw value followed by a newline.
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Data(trimmed.utf8)
    }

    public func fetch() async throws -> LiveUsage {
        let creds = try loadCredentials()
        if let exp = creds.expiresAt, exp < Date() {
            throw CredentialError.expired("Claude Code session expired. Open `claude` once to refresh it.")
        }
        let headers = [
            "Authorization": "Bearer \(creds.accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "anthropic-version": "2023-06-01",
        ]
        let json = try await client.json("GET", Self.usageURL, headers: headers)
        guard let obj = json as? [String: Any] else { throw HTTPError.invalidResponse }
        var usage = Self.parse(obj)
        usage.plan = Self.planName(creds.subscriptionType)
        return usage
    }

    static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    /// Understands both the named windows (`five_hour`, `seven_day`, ...) and the newer `limits` array.
    public static func parse(_ obj: [String: Any]) -> LiveUsage {
        var windows: [UsageWindow] = []
        var notes: [String] = []
        let named: [(String, String)] = [
            ("five_hour", "5h session"), ("seven_day", "Weekly"), ("seven_day_opus", "Weekly · Opus"),
            ("seven_day_sonnet", "Weekly · Sonnet"), ("seven_day_oauth_apps", "Weekly · apps"),
        ]
        for (key, label) in named {
            guard let w = JSON.dict(obj[key]), let pct = JSON.double(w["utilization"]) else { continue }
            windows.append(UsageWindow(label: label, percentUsed: pct, resetsAt: JSON.date(w["resets_at"])))
        }
        if windows.isEmpty, let limits = JSON.array(obj["limits"]) {
            for case let limit as [String: Any] in limits {
                guard let pct = JSON.double(limit["percent"]) else { continue }
                let kind = JSON.string(limit["kind"]) ?? "limit"
                let label: String
                switch kind {
                case "session": label = "5h session"
                case "weekly_all": label = "Weekly"
                case "weekly_scoped": label = "Weekly · " + (JSON.string(limit["scope"]) ?? "scoped")
                default: label = kind.replacingOccurrences(of: "_", with: " ").capitalized
                }
                windows.append(UsageWindow(label: label, percentUsed: pct, resetsAt: JSON.date(limit["resets_at"])))
            }
        }
        if let extra = JSON.dict(obj["extra_usage"]), JSON.bool(extra["is_enabled"]) == true,
           let used = JSON.double(extra["used_credits"]), let limit = JSON.double(extra["monthly_limit"]), limit > 0 {
            windows.append(UsageWindow(label: "Extra usage ($\(Int(used)) of $\(Int(limit)))", percentUsed: used / limit * 100))
        }
        if windows.isEmpty { notes.append("Anthropic returned no rate-limit windows.") }
        return LiveUsage(windows: windows, notes: notes)
    }
}
