import Foundation

// Globally installed agent skills (the skills.sh ecosystem): what is installed, for which agents,
// whether the source repo moved on, and update/remove through the `skills` CLI.

public enum SkillKind: String, Codable, Sendable {
    /// Installed by the `skills` CLI and recorded in `~/.agents/.skill-lock.json`.
    case managed
    /// Lives in `~/.agents/skills` but the lock file does not know it.
    case untracked
    /// A plain folder or a symlink into one of your own repos.
    case local
}

public enum SkillUpdateStatus: String, Codable, Sendable {
    case unknown, upToDate, available
}

public struct InstalledSkill: Identifiable, Codable, Sendable, Equatable {
    public var id: String { name }
    public var name: String
    public var description: String?
    public var kind: SkillKind
    /// Resolved folder that holds SKILL.md (symlinks followed).
    public var path: String
    /// Agent display names whose global skills folder exposes this skill.
    public var agents: [String]
    public var source: String?
    public var sourceType: String?
    public var sourceURL: String?
    public var skillPath: String?
    public var ref: String?
    public var folderHash: String?
    public var installedAt: Date?
    public var updatedAt: Date?
    public var update: SkillUpdateStatus = .unknown

    /// `https://github.com/owner/repo/tree/<ref>/<folder>` for GitHub sources.
    public var webURL: URL? {
        guard sourceType == "github", let source, !source.isEmpty else { return nil }
        let folder = skillPath.map(SkillsScanner.folder(ofSkillPath:)) ?? ""
        let base = "https://github.com/\(source)"
        return URL(string: folder.isEmpty ? base : "\(base)/tree/\(ref ?? "HEAD")/\(folder)")
    }
}

public struct SkillsScanner: Sendable {
    /// Global skill folders of agents that read `SKILL.md` directories, relative to the home folder.
    public static let agentFolders: [(name: String, path: String)] = [
        ("Universal", ".agents/skills"),
        ("Claude Code", ".claude/skills"),
        ("Cursor", ".cursor/skills"),
        ("Codex", ".codex/skills"),
        ("OpenCode", ".config/opencode/skills"),
        ("Gemini CLI", ".gemini/skills"),
        ("Windsurf", ".codeium/windsurf/skills"),
        ("GitHub Copilot", ".copilot/skills"),
    ]

    public var home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public var canonicalFolder: URL { home.appendingPathComponent(".agents/skills") }
    public var lockURL: URL { home.appendingPathComponent(".agents/.skill-lock.json") }

    struct LockEntry {
        var source, sourceType, sourceURL, skillPath, ref, folderHash: String?
        var installedAt, updatedAt: Date?
    }

    func readLock() -> [String: LockEntry] {
        guard let data = try? Data(contentsOf: lockURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skills = obj["skills"] as? [String: Any] else { return [:] }
        var out: [String: LockEntry] = [:]
        for (name, value) in skills {
            guard let e = value as? [String: Any] else { continue }
            out[name] = LockEntry(source: JSON.string(e["source"]), sourceType: JSON.string(e["sourceType"]),
                                  sourceURL: JSON.string(e["sourceUrl"]), skillPath: JSON.string(e["skillPath"]),
                                  ref: JSON.string(e["ref"]), folderHash: JSON.string(e["skillFolderHash"]),
                                  installedAt: JSON.date(e["installedAt"]), updatedAt: JSON.date(e["updatedAt"]))
        }
        return out
    }

    public func scan() -> [InstalledSkill] {
        let fm = FileManager.default
        let lock = readLock()
        let canonical = canonicalFolder.resolvingSymlinksInPath().standardizedFileURL.path
        var byName: [String: InstalledSkill] = [:]
        var order: [String] = []

        for agent in Self.agentFolders {
            let folder = home.appendingPathComponent(agent.path)
            guard let children = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for child in children.sorted() where !child.hasPrefix(".") {
                let entry = folder.appendingPathComponent(child)
                let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue,
                      Self.hasSkillFile(resolved) else { continue }
                if var existing = byName[child] {
                    if !existing.agents.contains(agent.name) { existing.agents.append(agent.name) }
                    byName[child] = existing
                    continue
                }
                let kind: SkillKind = lock[child] != nil ? .managed
                    : resolved.path.hasPrefix(canonical + "/") ? .untracked : .local
                var skill = InstalledSkill(name: child, description: Self.description(in: resolved), kind: kind,
                                           path: resolved.path, agents: [agent.name])
                if let e = lock[child] { Self.apply(e, to: &skill) }
                byName[child] = skill
                order.append(child)
            }
        }
        // Lock entries whose folders are gone still show up, so they can be removed or reinstalled.
        for (name, e) in lock where byName[name] == nil {
            var skill = InstalledSkill(name: name, description: nil, kind: .managed,
                                       path: canonicalFolder.appendingPathComponent(name).path, agents: [])
            Self.apply(e, to: &skill)
            byName[name] = skill
            order.append(name)
        }
        return order.compactMap { byName[$0] }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func apply(_ e: LockEntry, to skill: inout InstalledSkill) {
        skill.source = e.source
        skill.sourceType = e.sourceType
        skill.sourceURL = e.sourceURL
        skill.skillPath = e.skillPath
        skill.ref = e.ref
        skill.folderHash = e.folderHash
        skill.installedAt = e.installedAt
        skill.updatedAt = e.updatedAt
    }

    static func hasSkillFile(_ folder: URL) -> Bool {
        ["SKILL.md", "skill.md", "Skill.md"].contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// `description:` from the SKILL.md YAML front matter (single line, quotes stripped).
    static func description(in folder: URL) -> String? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8) else { return nil }
        return frontMatterValue("description", in: text)
    }

    static func frontMatterValue(_ key: String, in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var index = 1
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            index += 1
            // Only top-level keys (no indentation).
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), trimmed.hasPrefix(key + ":") else { continue }
            var value = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            // Block scalars (`>`, `>-`, `|`, `|-`…): the value is the following indented lines.
            if let first = value.first, first == ">" || first == "|", value.count <= 2 {
                var parts: [String] = []
                while index < lines.count, lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t") || lines[index].isEmpty {
                    let part = lines[index].trimmingCharacters(in: .whitespaces)
                    if !part.isEmpty { parts.append(part) }
                    index += 1
                }
                value = parts.joined(separator: " ")
            } else if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The lock's `skillPath` points at SKILL.md; the folder hash covers its directory ("" = repo root).
    public static func folder(ofSkillPath skillPath: String) -> String {
        var folder = skillPath.replacingOccurrences(of: "\\", with: "/")
        if folder.lowercased().hasSuffix("skill.md") { folder.removeLast(8) }
        while folder.hasSuffix("/") { folder.removeLast() }
        return folder
    }
}

/// Compares each managed skill's recorded folder hash with the current git tree of its source repo, the same
/// check `npx skills update` runs. One GitHub request per repo; results are cached for a few hours.
public struct SkillUpdateChecker: Sendable {
    public var client: HTTPClient
    public var cacheURL: URL
    public var maxAge: TimeInterval

    public init(client: HTTPClient = HTTPClient(), cacheURL: URL = AppPaths.supportDirectory.appendingPathComponent("skills-updates.json"),
                maxAge: TimeInterval = 6 * 3600) {
        self.client = client
        self.cacheURL = cacheURL
        self.maxAge = maxAge
    }

    struct Cache: Codable {
        var checkedAt: Date
        /// "owner/repo@ref" → folder path → tree sha ("" = root).
        var trees: [String: [String: String]]
    }

    /// Repo tree as folder path → sha, root under "".
    static func folders(fromTree obj: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        if let root = JSON.string(obj["sha"]) { out[""] = root }
        for case let entry as [String: Any] in (obj["tree"] as? [Any]) ?? [] where JSON.string(entry["type"]) == "tree" {
            if let path = JSON.string(entry["path"]), let sha = JSON.string(entry["sha"]) { out[path] = sha }
        }
        return out
    }

    public static func status(for skill: InstalledSkill, folders: [String: String]?) -> SkillUpdateStatus {
        guard let folders, let hash = skill.folderHash, !hash.isEmpty, let skillPath = skill.skillPath,
              let current = folders[SkillsScanner.folder(ofSkillPath: skillPath)] else { return .unknown }
        return current == hash ? .upToDate : .available
    }

    static var token: String? {
        let env = ProcessInfo.processInfo.environment
        return [env["GITHUB_TOKEN"], env["GH_TOKEN"]].compactMap { $0 }.first { !$0.isEmpty }
    }

    func fetchFolders(source: String, ref: String?) async -> [String: String]? {
        var headers = ["Accept": "application/vnd.github+json"]
        if let token = Self.token { headers["Authorization"] = "Bearer \(token)" }
        for branch in ref.map({ [$0] }) ?? ["HEAD", "main", "master"] {
            let escaped = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
            guard let url = URL(string: "https://api.github.com/repos/\(source)/git/trees/\(escaped)?recursive=1") else { continue }
            do {
                if let obj = try await client.json("GET", url, headers: headers) as? [String: Any] {
                    return Self.folders(fromTree: obj)
                }
            } catch HTTPError.status(let code, _) where code == 404 || code == 422 {
                continue
            } catch {
                return nil // rate limit or network: leave it unknown
            }
        }
        return nil
    }

    /// Returns the skills with `update` filled in. `force` ignores the cache.
    public func check(_ skills: [InstalledSkill], force: Bool = false, now: Date = Date()) async -> [InstalledSkill] {
        let checkable = skills.filter { $0.kind == .managed && $0.sourceType == "github" && ($0.source ?? "").contains("/") }
        let keys = Set(checkable.map { "\($0.source!)@\($0.ref ?? "")" })
        var cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder.iso.decode(Cache.self, from: $0) }
        if force || cache == nil || now.timeIntervalSince(cache!.checkedAt) > maxAge || !keys.isSubset(of: Set(cache!.trees.keys)) {
            var trees: [String: [String: String]] = [:]
            await withTaskGroup(of: (String, [String: String]?).self) { group in
                for key in keys {
                    let parts = key.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
                    let source = String(parts[0]), ref = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
                    group.addTask { (key, await fetchFolders(source: source, ref: ref)) }
                }
                for await (key, folders) in group { if let folders { trees[key] = folders } }
            }
            // Keep older answers for repos that failed this time (rate limits).
            for (key, value) in cache?.trees ?? [:] where trees[key] == nil { trees[key] = value }
            cache = Cache(checkedAt: now, trees: trees)
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder.iso.encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
        }
        return skills.map { skill in
            var s = skill
            if s.kind == .managed, let source = s.source {
                s.update = Self.status(for: s, folders: cache?.trees["\(source)@\(s.ref ?? "")"])
            }
            return s
        }
    }

    /// Drops the cache so the next check asks GitHub again (after an update or removal).
    public func invalidate() { try? FileManager.default.removeItem(at: cacheURL) }
}

extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    public static let isoPretty: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
}

/// Runs the `skills` CLI (`npx -y skills …`) for update, remove and add. GUI apps do not inherit the shell PATH,
/// so npx is looked up in nvm, Homebrew and Volta folders, falling back to an interactive login zsh.
public enum SkillsCLI {
    public struct Result: Sendable {
        public var status: Int32
        public var output: String
        public var ok: Bool { status == 0 }
    }

    public static func updateArguments(_ names: [String]) -> [String] { ["update"] + names + ["--global", "--yes"] }
    public static func removeArguments(_ names: [String]) -> [String] { ["remove"] + names + ["--global", "--agent", "*", "--yes"] }
    public static func addArguments(_ source: String) -> [String] { ["add", source, "--global", "--yes"] }

    /// Highest installed nvm node first, then Homebrew, /usr/local and Volta.
    public static func npxCandidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var out: [URL] = []
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm.path) {
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                out.append(nvm.appendingPathComponent(v).appendingPathComponent("bin/npx"))
            }
        }
        out += ["/opt/homebrew/bin/npx", "/usr/local/bin/npx"].map(URL.init(fileURLWithPath:))
        out.append(home.appendingPathComponent(".volta/bin/npx"))
        return out.filter { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func run(_ arguments: [String], timeout: TimeInterval = 300) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(arguments, timeout: timeout))
            }
        }
    }

    static func runBlocking(_ arguments: [String], timeout: TimeInterval) -> Result {
        let process = Process()
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        env["FORCE_COLOR"] = "0"
        env["DISABLE_TELEMETRY"] = "1"
        if let npx = npxCandidates().first {
            process.executableURL = npx
            process.arguments = ["-y", "skills"] + arguments
            env["PATH"] = npx.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-ilc", (["npx", "-y", "skills"] + arguments).map(shellQuote).joined(separator: " ")]
        }
        process.environment = env
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            return Result(status: -1, output: "Could not start npx: \(error.localizedDescription). Install Node.js to manage skills.")
        }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        return Result(status: process.terminationStatus, output: stripANSI(String(decoding: data, as: UTF8.self)))
    }

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}
