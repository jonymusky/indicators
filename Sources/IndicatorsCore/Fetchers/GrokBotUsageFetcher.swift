import Foundation

/// Grok Bot is built by Cursor (bundle `com.anysphere.sand`) and bills its usage pool through Cursor's
/// Connect API. Its signed-in accounts live in `sand-secrets.json`, each token encrypted with Electron
/// safeStorage keyed from the "Grok Bot Safe Storage" keychain item. Read-only; the token stays in memory.
public struct GrokBotUsageFetcher: Sendable {
    public static let statusURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!
    static let keychainServices = ["Grok Bot Safe Storage", "Sand Safe Storage"]

    public var client: HTTPClient
    public var home: URL

    public init(client: HTTPClient = HTTPClient(), home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.client = client
        self.home = home
    }

    public var secretsURL: URL {
        home.appendingPathComponent("Library/Application Support/Grok Bot/sand-secrets.json")
    }

    public static func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Grok Bot").path)
    }

    /// `{"cursor-accounts": "{\"active\": id, \"accounts\": {id: {\"cursor-access-token\": \"djEw…\"}}}"}` → encrypted token.
    static func activeEncryptedToken(secrets: [String: Any]) -> String? {
        let accountsValue = secrets["cursor-accounts"]
        let accounts: [String: Any]? = (accountsValue as? [String: Any])
            ?? (accountsValue as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        guard let accounts, let byID = accounts["accounts"] as? [String: Any] else { return nil }
        let entry = (JSON.string(accounts["active"]).flatMap { byID[$0] } ?? byID.values.first) as? [String: Any]
        return JSON.string(entry?["cursor-access-token"])
    }

    func loadToken() throws -> String {
        guard let data = try? Data(contentsOf: secretsURL),
              let secrets = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.missing("Grok Bot is not signed in.")
        }
        guard let encrypted = Self.activeEncryptedToken(secrets: secrets), !encrypted.isEmpty else {
            throw CredentialError.missing("Grok Bot is not signed in.")
        }
        guard let password = Self.keychainServices.lazy.compactMap({ KeychainCLI.read(service: $0) }).first else {
            throw CredentialError.missing("Allow Indicators to read \"Grok Bot Safe Storage\" in the Keychain prompt to see Grok Bot usage.")
        }
        guard let token = CursorUsageFetcher.decryptSafeStorage(encrypted, password: password), !token.isEmpty else {
            throw CredentialError.missing("Could not decrypt the Grok Bot session. Sign out and in again in Grok Bot.")
        }
        return token
    }

    public func fetch() async throws -> LiveUsage {
        let token = try loadToken()
        let headers = ["Authorization": "Bearer \(token)", "Connect-Protocol-Version": "1"]
        let json = try await client.json("POST", Self.statusURL, headers: headers, body: Data("{}".utf8))
        guard let obj = json as? [String: Any] else { throw HTTPError.invalidResponse }
        CursorUsageFetcher.debugKeys(obj, label: "grok-bot-usage")
        return Self.parse(obj)
    }

    static func flag(_ value: Any?) -> Bool { JSON.bool(value) ?? ((JSON.int(value) ?? 0) != 0) }

    /// `GetSandUsageStatusResponse`: `usagePercent`, `nextResetTimestampUtc`, `grokPlanLabel`, `includedLimitZero`,
    /// `usesPooledEnterpriseAllowance`.
    public static func parse(_ obj: [String: Any]) -> LiveUsage {
        let plan = JSON.string(obj["grokPlanLabel"]).flatMap { $0.isEmpty ? nil : $0 }
        if flag(obj["usesPooledEnterpriseAllowance"]) {
            return LiveUsage(windows: [], plan: plan, notes: ["Grok Bot uses a pooled team allowance; see the team dashboard."])
        }
        if flag(obj["includedLimitZero"]) {
            return LiveUsage(windows: [], plan: plan, notes: ["This Grok Bot account has no included usage."])
        }
        guard let percent = JSON.double(obj["usagePercent"]) else { return LiveUsage(windows: [], plan: plan) }
        let window = UsageWindow(label: "Grok Bot", percentUsed: max(percent, 0), resetsAt: JSON.date(obj["nextResetTimestampUtc"]))
        return LiveUsage(windows: [window], plan: plan)
    }
}
