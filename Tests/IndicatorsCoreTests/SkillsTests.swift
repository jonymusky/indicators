import XCTest
@testable import IndicatorsCore

final class SkillsTests: XCTestCase {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
        let fm = FileManager.default
        func skill(_ dir: URL, _ name: String, _ frontMatter: String) throws {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try "---\nname: \(name)\n\(frontMatter)\n---\n# Body\n".write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        let canonical = home.appendingPathComponent(".agents/skills")
        try skill(canonical.appendingPathComponent("turborepo"), "turborepo", "description: Turbo things")
        try skill(canonical.appendingPathComponent("stray"), "stray", "description: \"Quoted\"")
        try skill(home.appendingPathComponent("repo/mine"), "mine", "description: >-\n  Folded line one\n  and two\nlicense: MIT")
        let claude = home.appendingPathComponent(".claude/skills")
        try fm.createDirectory(at: claude, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: claude.appendingPathComponent("turborepo").path, withDestinationPath: "../../.agents/skills/turborepo")
        try fm.createSymbolicLink(atPath: claude.appendingPathComponent("mine").path, withDestinationPath: home.appendingPathComponent("repo/mine").path)
        try fm.createDirectory(at: claude.appendingPathComponent("synced/abc"), withIntermediateDirectories: true) // not a skill
        let lock = """
        {"version":3,"skills":{
          "turborepo":{"source":"vercel/turborepo","sourceType":"github","sourceUrl":"https://github.com/vercel/turborepo.git",
                       "skillPath":"skills/turborepo/SKILL.md","skillFolderHash":"aaa","installedAt":"2026-01-24T01:32:58.966Z","updatedAt":"2026-10-31T15:23:52.048Z"},
          "gone":{"source":"o/r","sourceType":"github","skillPath":"SKILL.md","skillFolderHash":"root1"}}}
        """
        try lock.write(to: home.appendingPathComponent(".agents/.skill-lock.json"), atomically: true, encoding: .utf8)
        return home
    }

    func testScanClassifiesSkills() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let skills = SkillsScanner(home: home).scan()
        let byName = Dictionary(uniqueKeysWithValues: skills.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["turborepo", "stray", "mine", "gone"])
        XCTAssertEqual(byName["turborepo"]?.kind, .managed)
        XCTAssertEqual(byName["turborepo"]?.agents, ["Universal", "Claude Code"])
        XCTAssertEqual(byName["turborepo"]?.source, "vercel/turborepo")
        XCTAssertEqual(byName["turborepo"]?.description, "Turbo things")
        XCTAssertEqual(byName["stray"]?.kind, .untracked)
        XCTAssertEqual(byName["stray"]?.description, "Quoted")
        XCTAssertEqual(byName["mine"]?.kind, .local)
        XCTAssertEqual(byName["mine"]?.description, "Folded line one and two")
        XCTAssertEqual(byName["gone"]?.agents, [])
        XCTAssertEqual(byName["turborepo"]?.webURL?.absoluteString, "https://github.com/vercel/turborepo/tree/HEAD/skills/turborepo")
    }

    func testFolderHashComparison() {
        XCTAssertEqual(SkillsScanner.folder(ofSkillPath: "skills/turborepo/SKILL.md"), "skills/turborepo")
        XCTAssertEqual(SkillsScanner.folder(ofSkillPath: "SKILL.md"), "")
        let tree: [String: Any] = ["sha": "root2", "tree": [
            ["path": "skills/turborepo", "type": "tree", "sha": "bbb"],
            ["path": "skills/turborepo/SKILL.md", "type": "blob", "sha": "ccc"],
        ]]
        let folders = SkillUpdateChecker.folders(fromTree: tree)
        var skill = InstalledSkill(name: "turborepo", kind: .managed, path: "/x", agents: [])
        skill.skillPath = "skills/turborepo/SKILL.md"
        skill.folderHash = "aaa"
        XCTAssertEqual(SkillUpdateChecker.status(for: skill, folders: folders), .available)
        skill.folderHash = "bbb"
        XCTAssertEqual(SkillUpdateChecker.status(for: skill, folders: folders), .upToDate)
        skill.skillPath = "SKILL.md"
        skill.folderHash = "root2"
        XCTAssertEqual(SkillUpdateChecker.status(for: skill, folders: folders), .upToDate)
        skill.folderHash = ""
        XCTAssertEqual(SkillUpdateChecker.status(for: skill, folders: folders), .unknown)
        XCTAssertEqual(SkillUpdateChecker.status(for: skill, folders: nil), .unknown)
    }

    func testDirectorySearchParsing() throws {
        let json = """
        {"query":"react","skills":[
          {"id":"a/b/small","source":"a/b","skillId":"small","name":"small","installs":10},
          {"id":"vercel-labs/agent-skills/vercel-react-best-practices","source":"vercel-labs/agent-skills","skillId":"vercel-react-best-practices","name":"vercel-react-best-practices","installs":880329},
          {"id":"broken","source":"nosplash","skillId":"x","name":"x","installs":1}]}
        """
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let results = SkillsDirectory.parse(obj)
        XCTAssertEqual(results.map(\.skillId), ["vercel-react-best-practices", "small"])
        XCTAssertEqual(results.first?.installs, 880329)
    }

    func testCLIArguments() {
        XCTAssertEqual(SkillsCLI.addArguments("a/b", skill: "c"), ["add", "a/b", "--skill", "c", "--global", "--yes"])
        XCTAssertEqual(SkillsCLI.addArguments("a/b"), ["add", "a/b", "--global", "--yes"])
        XCTAssertEqual(SkillsCLI.updateArguments(["a"]), ["update", "a", "--global", "--yes"])
        XCTAssertEqual(SkillsCLI.removeArguments(["a"]), ["remove", "a", "--global", "--agent", "*", "--yes"])
        XCTAssertEqual(SkillsCLI.shellQuote("it's"), "'it'\\''s'")
    }
}
