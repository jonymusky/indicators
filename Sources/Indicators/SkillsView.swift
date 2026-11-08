import SwiftUI
import AppKit
import IndicatorsCore

enum SkillsFilter: String, CaseIterable, Hashable {
    case all = "All", updates = "Updates", managed = "skills.sh", local = "Local", discover = "Discover"
}

@MainActor
final class SkillsModel: ObservableObject {
    @Published var skills: [InstalledSkill] = []
    @Published var loading = false
    @Published var checkedAt: Date?
    /// Skill names with a running command; "*" while updating everything or adding.
    @Published var busy: Set<String> = []
    @Published var log = ""
    @Published var logIsError = false
    @Published var query = ""
    @Published var filter: SkillsFilter = .all
    @Published var addSource = ""
    @Published var pendingRemoval: InstalledSkill?
    @Published var discover: [DirectorySkill] = []
    @Published var discoverLoading = false
    @Published var discoverError: String?
    private var searchTask: Task<Void, Never>?

    var onChange: (() -> Void)?

    var updatesAvailable: [InstalledSkill] { skills.filter { $0.update == .available } }

    var visible: [InstalledSkill] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return skills.filter { skill in
            switch filter {
            case .all: break
            case .updates: guard skill.update == .available else { return false }
            case .managed: guard skill.kind != .local else { return false }
            case .local: guard skill.kind == .local else { return false }
            case .discover: return false
            }
            guard !q.isEmpty else { return true }
            return skill.name.lowercased().contains(q) || (skill.source ?? "").lowercased().contains(q)
                || (skill.description ?? "").lowercased().contains(q)
        }
    }

    func load(force: Bool = false) async {
        loading = true
        let scanned = await Task.detached(priority: .userInitiated) { SkillsScanner().scan() }.value
        skills = scanned
        skills = await SkillUpdateChecker().check(scanned, force: force)
        checkedAt = Date()
        loading = false
        onChange?()
    }

    var installedNames: Set<String> { Set(skills.map(\.name)) }

    /// Debounced skills.sh search for the Discover tab.
    func scheduleSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard filter == .discover, q.count >= 2 else {
            if q.isEmpty { discover = []; discoverError = nil }
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.discoverLoading = true
            do {
                let results = try await SkillsDirectory().search(q)
                guard !Task.isCancelled else { return }
                self.discover = results
                self.discoverError = nil
            } catch {
                if !Task.isCancelled { self.discoverError = "skills.sh search failed: \(error.localizedDescription)" }
            }
            self.discoverLoading = false
        }
    }

    func install(_ skill: DirectorySkill) async {
        await run(SkillsCLI.addArguments(skill.source, skill: skill.skillId), busyKeys: [skill.id], title: "Installing \(skill.name)")
    }

    func update(_ names: [String]) async {
        await run(SkillsCLI.updateArguments(names), busyKeys: names.isEmpty ? ["*"] : names,
                  title: names.isEmpty ? "Updating all skills" : "Updating \(names.joined(separator: ", "))")
    }

    func remove(_ skill: InstalledSkill) async {
        await run(SkillsCLI.removeArguments([skill.name]), busyKeys: [skill.name], title: "Removing \(skill.name)")
    }

    func add() async {
        let source = addSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        await run(SkillsCLI.addArguments(source), busyKeys: ["*"], title: "Adding \(source)")
        if !logIsError { addSource = "" }
    }

    private func run(_ arguments: [String], busyKeys: [String], title: String) async {
        busy.formUnion(busyKeys)
        log = "\(title)…\n$ npx skills \(arguments.joined(separator: " "))"
        logIsError = false
        let result = await SkillsCLI.run(arguments)
        busy.subtract(busyKeys)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        log = "$ npx skills \(arguments.joined(separator: " "))\n" + (output.isEmpty ? (result.ok ? "Done." : "Failed (exit \(result.status)).") : output)
        logIsError = !result.ok
        await load()
    }
}

struct SkillsView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var model = SkillsModel()
    @StateObject private var showLog = ViewState(false)

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            if !model.log.isEmpty {
                Divider()
                logPanel
            }
            Divider()
            addBar
        }
        .frame(minWidth: 640, minHeight: 480)
        .task {
            model.onChange = { [weak store] in Task { await store?.refreshSkillUpdateCount() } }
            // Debug aids for screenshots: INDICATORS_SKILLS_FILTER picks a tab ("skills.sh", "Updates"…),
            // INDICATORS_SKILLS_QUERY opens the Discover tab with that search.
            if let f = ProcessInfo.processInfo.environment["INDICATORS_SKILLS_FILTER"], let filter = SkillsFilter(rawValue: f) {
                model.filter = filter
            }
            if let q = ProcessInfo.processInfo.environment["INDICATORS_SKILLS_QUERY"] {
                model.filter = .discover
                model.query = q
            }
            await model.load()
        }
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
        .onChange(of: model.query) { _, _ in model.scheduleSearch() }
        .onChange(of: model.filter) { _, _ in model.scheduleSearch() }
        .confirmationDialog(
            "Remove \(model.pendingRemoval?.name ?? "")?",
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
            presenting: model.pendingRemoval
        ) { skill in
            Button("Remove from all agents", role: .destructive) { Task { await model.remove(skill) } }
            Button("Cancel", role: .cancel) {}
        } message: { skill in
            Text("Runs `npx skills remove \(skill.name) --global`. Its folder is deleted from \(skill.agents.isEmpty ? "the agents" : skill.agents.joined(separator: ", ")).")
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Skills").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if model.loading {
                    ProgressView().controlSize(.small).frame(width: 20)
                } else {
                    Button { Task { await model.load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Check GitHub for updates")
                }
                if !model.updatesAvailable.isEmpty {
                    Button("Update all") { Task { await model.update([]) } }
                        .fixedSize()
                        .disabled(!model.busy.isEmpty)
                }
            }
            HStack(spacing: 10) {
                Picker("", selection: $model.filter) {
                    ForEach(SkillsFilter.allCases, id: \.self) { f in
                        Text(f == .updates && !model.updatesAvailable.isEmpty ? "Updates (\(model.updatesAvailable.count))" : f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField(model.filter == .discover ? "Search skills.sh" : "Search", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var summary: String {
        let managed = model.skills.filter { $0.kind != .local }.count
        let local = model.skills.count - managed
        var parts = ["\(model.skills.count) installed", "\(managed) from skills.sh", "\(local) local"]
        if let at = model.checkedAt { parts.append("checked \(Format.relative(at))") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if model.filter == .discover {
            discoverContent
        } else if model.skills.isEmpty && model.loading {
            VStack { Spacer(); ProgressView(); Spacer() }.frame(maxWidth: .infinity)
        } else if model.visible.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: "puzzlepiece.extension").font(.largeTitle).foregroundStyle(.secondary)
                Text(model.skills.isEmpty ? "No global skills installed" : "Nothing matches").foregroundStyle(.secondary)
                if model.skills.isEmpty {
                    Text("Add one below, e.g. vercel-labs/agent-skills, or browse skills.sh.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(model.visible) { skill in
                SkillRow(skill: skill, busy: model.busy.contains(skill.name) || model.busy.contains("*"),
                         onUpdate: { Task { await model.update([skill.name]) } },
                         onRemove: { model.pendingRemoval = skill })
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var discoverContent: some View {
        let q = model.query.trimmingCharacters(in: .whitespaces)
        if q.count < 2 {
            placeholder("magnifyingglass", "Search the skills.sh directory", "Type at least two characters, e.g. “react”, “testing”, “stripe”.")
        } else if let error = model.discoverError {
            placeholder("exclamationmark.triangle", "Search failed", error)
        } else if model.discover.isEmpty {
            if model.discoverLoading {
                VStack { Spacer(); ProgressView(); Spacer() }.frame(maxWidth: .infinity)
            } else {
                placeholder("puzzlepiece.extension", "No skills found for “\(q)”", "Try another word, or paste owner/repo below.")
            }
        } else {
            List(model.discover) { skill in
                DirectoryRow(skill: skill, installed: model.installedNames.contains(skill.skillId),
                             busy: model.busy.contains(skill.id) || model.busy.contains("*")) {
                    Task { await model.install(skill) }
                }
            }
            .listStyle(.inset)
        }
    }

    private func placeholder(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).foregroundStyle(.secondary)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: model.logIsError ? "exclamationmark.triangle.fill" : "terminal")
                    .foregroundStyle(model.logIsError ? .orange : .secondary)
                Text(model.log.split(separator: "\n").first.map(String.init) ?? "").font(.caption.monospaced()).lineLimit(1)
                Spacer()
                Button(showLog.value ? "Hide output" : "Show output") { showLog.value.toggle() }
                    .buttonStyle(.borderless).font(.caption)
                Button { model.log = "" } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).font(.caption)
            }
            if showLog.value || model.logIsError {
                ScrollView {
                    Text(model.log).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var addBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle").foregroundStyle(.secondary)
            TextField("owner/repo or URL (installs globally for your agents)", text: $model.addSource)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.add() } }
            Button("Add") { Task { await model.add() } }
                .disabled(model.addSource.trimmingCharacters(in: .whitespaces).isEmpty || !model.busy.isEmpty)
            if model.busy.contains("*") { ProgressView().controlSize(.small) }
            Button("Browse skills.sh") { NSWorkspace.shared.open(URL(string: "https://skills.sh")!) }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct SkillRow: View {
    let skill: InstalledSkill
    let busy: Bool
    let onUpdate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.name).font(.system(.body, weight: .semibold))
                    badge
                }
                if let description = skill.description {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(meta).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView().controlSize(.small)
            } else if skill.update == .available {
                Button("Update", action: onUpdate).controlSize(.small)
            }
            Menu {
                if skill.kind != .local {
                    Button("Update", action: onUpdate)
                }
                if let url = skill.webURL {
                    Button("Open source on GitHub") { NSWorkspace.shared.open(url) }
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.path)])
                }
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(skill.path, forType: .string)
                }
                if skill.kind != .local {
                    Divider()
                    Button("Remove…", role: .destructive, action: onRemove)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(busy)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var badge: some View {
        switch (skill.kind, skill.update) {
        case (.managed, .available): tag("Update available", .orange)
        case (.managed, .upToDate): tag("Up to date", .green)
        case (.managed, .unknown): tag("skills.sh", .secondary)
        case (.untracked, _): tag("Not in lock", .secondary)
        case (.local, _): tag("Local", .blue)
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var meta: String {
        var parts: [String] = []
        if let source = skill.source { parts.append(source) } else { parts.append((skill.path as NSString).abbreviatingWithTildeInPath) }
        if !skill.agents.isEmpty { parts.append(skill.agents.joined(separator: ", ")) }
        if let updated = skill.updatedAt ?? skill.installedAt { parts.append("updated \(Format.relative(updated))") }
        return parts.joined(separator: " · ")
    }
}

struct DirectoryRow: View {
    let skill: DirectorySkill
    let installed: Bool
    let busy: Bool
    let onInstall: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.name).font(.system(.body, weight: .semibold))
                Text("\(skill.source) · \(Self.installs(skill.installs)) installs").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            } else if installed {
                Text("Installed").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Install", action: onInstall).controlSize(.small)
            }
            Button {
                NSWorkspace.shared.open(URL(string: "https://skills.sh/\(skill.id)")!)
            } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.borderless)
                .help("Open on skills.sh")
        }
        .padding(.vertical, 4)
    }

    static func installs(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fK", Double(n) / 1_000)
        default: return "\(n)"
        }
    }
}
