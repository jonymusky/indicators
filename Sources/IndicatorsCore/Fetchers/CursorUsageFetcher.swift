import Foundation
import SQLite3
import CommonCrypto

/// Reads the Cursor editor's session from its local state database and asks cursor.com for the
/// plan's request usage. Read-only; the token is used in memory for one request.
public struct CursorUsageFetcher: Sendable {
    public static let usageURL = URL(string: "https://cursor.com/api/usage")!
    public static let summaryURL = URL(string: "https://cursor.com/api/usage-summary")!

    public var client: HTTPClient
    public var home: URL

    public init(client: HTTPClient = HTTPClient(), home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.client = client
        self.home = home
    }

    public var databaseURL: URL {
        home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    public static func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Cursor").path)
    }

    struct Credentials {
        var token: String
        var userID: String
        var membership: String?
    }

    func loadCredentials() throws -> Credentials {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw CredentialError.missing("Cursor is not installed.")
        }
        guard let stored = Self.readItem(key: "cursorAuth/accessToken", from: databaseURL), !stored.isEmpty else {
            throw CredentialError.missing("Cursor is not signed in.")
        }
        var token = stored
        // Cursor 3.x encrypts the session at rest with Electron safeStorage, keyed from the login keychain.
        if Self.isSafeStorage(stored) {
            guard let password = KeychainCLI.read(service: "Cursor Safe Storage") else {
                throw CredentialError.missing("Cursor encrypts its session: allow Indicators to read \"Cursor Safe Storage\" in the Keychain prompt.")
            }
            guard let plain = Self.decryptSafeStorage(stored, password: password), !plain.isEmpty else {
                throw CredentialError.missing("Could not decrypt the Cursor session. Sign out and in again in Cursor.")
            }
            token = plain
        }
        let authID = Self.readItem(key: "cursorAuth/stripeMembershipAuthId", from: databaseURL)
        guard let userID = Self.userID(fromJWT: token) ?? authID.flatMap(Self.userID(fromAuthID:)) else {
            throw CredentialError.missing("Cursor session token is not in the expected format.")
        }
        let membership = Self.readItem(key: "cursorAuth/stripeMembershipType", from: databaseURL)
        return Credentials(token: token, userID: userID, membership: membership)
    }

    static let safeStoragePrefix = "cursor-safe-storage:"

    static func isSafeStorage(_ value: String) -> Bool { value.hasPrefix(safeStoragePrefix) }

    /// `cursor-safe-storage:v1:<base64>` where the payload is Chromium's macOS safeStorage blob:
    /// `"v10"` + AES-128-CBC(PKCS7), key = PBKDF2-SHA1(keychain password, "saltysalt", 1003 rounds), IV = 16 spaces.
    static func decryptSafeStorage(_ value: String, password: String) -> String? {
        guard let encoded = value.split(separator: ":").last,
              var blob = Data(base64Encoded: String(encoded)) else { return nil }
        if blob.starts(with: Array("v10".utf8)) || blob.starts(with: Array("v11".utf8)) { blob = blob.dropFirst(3) }
        guard !blob.isEmpty, blob.count % kCCBlockSizeAES128 == 0 else { return nil }

        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let derived = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                                           salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                           &key, key.count)
        guard derived == kCCSuccess else { return nil }

        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        let input = [UInt8](blob)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var written = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, input, input.count, &output, output.count, &written)
        guard status == kCCSuccess else { return nil }
        return String(bytes: output.prefix(written), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `google-oauth2|user_123` → `user_123`.
    static func userID(fromAuthID authID: String) -> String? {
        guard let last = authID.split(separator: "|").last, !last.isEmpty else { return nil }
        return String(last)
    }

    /// `SELECT value FROM ItemTable WHERE key = ?` on Cursor's SQLite state store, opened read-only.
    static func readItem(key: String, from url: URL) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?", -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    /// The JWT subject looks like `auth0|user_123`; the cookie wants the part after the pipe.
    static func userID(fromJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = JSON.string(obj["sub"]) else { return nil }
        return sub.split(separator: "|").last.map(String.init)
    }

    public func fetch() async throws -> LiveUsage {
        let creds = try loadCredentials()
        let cookie = "WorkosCursorSessionToken=\(creds.userID)%3A%3A\(creds.token)"
        let headers = ["Cookie": cookie, "Origin": "https://cursor.com", "Referer": "https://cursor.com/dashboard"]
        // Newer plans (usage-based) report through usage-summary; request-capped plans through the legacy endpoint.
        var summary: LiveUsage?
        if let json = try? await client.json("GET", Self.summaryURL, headers: headers), let obj = json as? [String: Any] {
            Self.debugKeys(obj, label: "usage-summary")
            let parsed = Self.parseSummary(obj)
            if !parsed.windows.isEmpty || parsed.plan != nil { summary = parsed }
        }
        var components = URLComponents(url: Self.usageURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "user", value: creds.userID)]
        let json = try await client.json("GET", components.url!, headers: headers)
        guard let obj = json as? [String: Any] else { throw HTTPError.invalidResponse }
        Self.debugKeys(obj, label: "usage")
        let legacy = Self.parse(obj)
        var result = legacy
        if var summary {
            summary.windows += legacy.windows
            if summary.windows.isEmpty { summary.notes = legacy.notes }
            result = summary
        }
        if result.plan == nil, let m = creds.membership, !m.isEmpty { result.plan = m.prefix(1).uppercased() + m.dropFirst() }
        return result
    }

    /// `INDICATORS_DEBUG_KEYS=1` prints the key tree of vendor responses (never values) to stderr.
    static func debugKeys(_ obj: [String: Any], label: String) {
        guard ProcessInfo.processInfo.environment["INDICATORS_DEBUG_KEYS"] == "1" else { return }
        func walk(_ value: Any, _ prefix: String, _ out: inout [String]) {
            if let dict = value as? [String: Any] {
                for (k, v) in dict.sorted(by: { $0.key < $1.key }) { walk(v, prefix.isEmpty ? k : prefix + "." + k, &out) }
            } else if let array = value as? [Any] {
                out.append(prefix + "[\(array.count)]")
                if let first = array.first { walk(first, prefix + "[]", &out) }
            } else {
                let type = value is NSNumber ? "number" : value is String ? "string" : value is NSNull ? "null" : "other"
                out.append(prefix + ": " + type)
            }
        }
        var lines: [String] = []
        walk(obj, "", &lines)
        FileHandle.standardError.write(Data(("[\(label)]\n" + lines.joined(separator: "\n") + "\n").utf8))
    }

    /// `/api/usage-summary` (usage-based plans):
    /// `individualUsage.plan.{used, limit, remaining, totalPercentUsed}` in cents, `individualUsage.onDemand.{used, limit, enabled}`,
    /// `billingCycleEnd`, `membershipType`, `isUnlimited`.
    public static func parseSummary(_ obj: [String: Any]) -> LiveUsage {
        var windows: [UsageWindow] = []
        let cycleEnd = JSON.date(obj["billingCycleEnd"])
        let individual = JSON.dict(obj["individualUsage"])
        func dollars(_ cents: Double) -> String {
            cents.truncatingRemainder(dividingBy: 100) == 0 ? String(format: "$%.0f", cents / 100) : String(format: "$%.2f", cents / 100)
        }
        if let plan = JSON.dict(individual?["plan"]) {
            let used = JSON.double(plan["used"]) ?? 0
            let limit = JSON.double(plan["limit"]) ?? 0
            let percent = JSON.double(plan["totalPercentUsed"]) ?? (limit > 0 ? used / limit * 100 : 0)
            let label = limit > 0 ? "Plan usage (\(dollars(used)) of \(dollars(limit)))" : "Plan usage"
            windows.append(UsageWindow(label: label, percentUsed: percent, resetsAt: cycleEnd))
            // Cursor splits the pool between Auto and explicitly chosen (API-priced) models.
            if limit > 0, let auto = JSON.double(plan["autoPercentUsed"]) {
                windows.append(UsageWindow(label: "Auto", percentUsed: auto, resetsAt: cycleEnd))
            }
            if limit > 0, let api = JSON.double(plan["apiPercentUsed"]) {
                windows.append(UsageWindow(label: "Named models", percentUsed: api, resetsAt: cycleEnd))
            }
        }
        if let onDemand = JSON.dict(individual?["onDemand"]), (JSON.int(onDemand["enabled"]) ?? 0) != 0 || (JSON.double(onDemand["used"]) ?? 0) > 0 {
            let used = JSON.double(onDemand["used"]) ?? 0
            if let limit = JSON.double(onDemand["limit"]), limit > 0 {
                windows.append(UsageWindow(label: "On-demand (\(dollars(used)) of \(dollars(limit)))", percentUsed: used / limit * 100, resetsAt: cycleEnd))
            } else if used > 0 {
                windows.append(UsageWindow(label: "On-demand spend \(dollars(used)) (no limit)", percentUsed: 0, resetsAt: cycleEnd))
            }
        }
        var plan: String?
        if let p = JSON.string(obj["membershipType"]), !p.isEmpty { plan = p.prefix(1).uppercased() + p.dropFirst() }
        if (JSON.int(obj["isUnlimited"]) ?? 0) != 0 { plan = (plan ?? "Plan") + " · unlimited" }
        return LiveUsage(windows: windows, plan: plan)
    }

    /// `{"gpt-4": {"numRequests": 123, "maxRequestUsage": 500, ...}, "startOfMonth": "..."}`
    public static func parse(_ obj: [String: Any]) -> LiveUsage {
        var windows: [UsageWindow] = []
        let cycleStart = JSON.date(obj["startOfMonth"])
        let resets = cycleStart.flatMap { Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: $0) }
        let labels: [(String, String)] = [("gpt-4", "Premium requests"), ("gpt-4-32k", "Premium (32k)"), ("gpt-3.5-turbo", "Basic requests")]
        for (key, label) in labels {
            guard let bucket = JSON.dict(obj[key]), let used = JSON.int(bucket["numRequests"]) else { continue }
            if let max = JSON.int(bucket["maxTokenUsage"]), max > 0, let tokens = JSON.int(bucket["numTokens"]) {
                windows.append(UsageWindow(label: "\(label) tokens", percentUsed: Double(tokens) / Double(max) * 100, resetsAt: resets))
            }
            if let max = JSON.int(bucket["maxRequestUsage"]), max > 0 {
                windows.append(UsageWindow(label: "\(label) (\(used)/\(max))", percentUsed: Double(used) / Double(max) * 100, resetsAt: resets))
            } else if used > 0 && key == "gpt-4" {
                windows.append(UsageWindow(label: "\(label) (\(used), no cap)", percentUsed: 0, resetsAt: resets))
            }
        }
        var notes: [String] = []
        if windows.isEmpty { notes.append("Cursor returned no request quotas; usage-based plans report spend on cursor.com/dashboard.") }
        return LiveUsage(windows: windows, plan: nil, notes: notes)
    }
}
