import Foundation

/// A log file on disk with the attributes used to detect changes.
public struct ScannedFile: Sendable, Equatable {
    public var url: URL
    public var modifiedAt: Date
    public var size: Int

    public init(url: URL, modifiedAt: Date, size: Int) {
        self.url = url
        self.modifiedAt = modifiedAt
        self.size = size
    }
}

public enum LogFiles {
    /// Recursively lists files under `root` with one of `extensions`, optionally only those modified after a date.
    public static func enumerate(root: URL, extensions: Set<String>, modifiedAfter: Date? = nil) -> [ScannedFile] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [ScannedFile] = []
        for case let url as URL in enumerator {
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let mtime = values.contentModificationDate ?? .distantPast
            if let modifiedAfter, mtime < modifiedAfter { continue }
            result.append(ScannedFile(url: url, modifiedAt: mtime, size: values.fileSize ?? 0))
        }
        return result
    }
}

/// Iterates a file line by line without decoding the whole file as a String.
public struct LineReader {
    private let data: Data

    public init(url: URL) throws {
        data = try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    public init(data: Data) { self.data = data }

    /// Calls `body` with each line; the line must contain every needle in `needles` to be visited.
    public func forEachLine(containing needles: [String] = [], _ body: (Data) throws -> Void) rethrows {
        let needleData = needles.map { Data($0.utf8) }
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            if end > start {
                let line = data.subdata(in: start..<end)
                var matches = true
                for needle in needleData where line.range(of: needle) == nil {
                    matches = false
                    break
                }
                if matches { try body(line) }
            }
            start = end == data.endIndex ? end : data.index(after: end)
        }
    }
}

/// What a parser extracted from one file.
public struct ParsedFile: Codable, Sendable, Equatable {
    public var events: [UsageEvent]
    public var rateLimits: LocalRateLimits?

    public init(events: [UsageEvent] = [], rateLimits: LocalRateLimits? = nil) {
        self.events = events
        self.rateLimits = rateLimits
    }
}

/// Rate-limit information some CLIs write into their own logs.
public struct LocalRateLimits: Codable, Sendable, Equatable {
    public var windows: [UsageWindow]
    public var plan: String?
    public var observedAt: Date

    public init(windows: [UsageWindow], plan: String? = nil, observedAt: Date) {
        self.windows = windows
        self.plan = plan
        self.observedAt = observedAt
    }
}

public protocol LocalLogParser: Sendable {
    var provider: Provider { get }
    var fileExtensions: Set<String> { get }
    /// Directories to scan; missing ones are skipped.
    func roots(environment: [String: String], home: URL) -> [URL]
    func parse(file: URL) throws -> ParsedFile
}

/// Persistent per-file parse results so that unchanged files are never re-read.
public final class ParseCache: @unchecked Sendable {
    public struct Entry: Codable, Sendable {
        public var modifiedAt: Date
        public var size: Int
        public var parsed: ParsedFile
    }

    private var entries: [String: Entry]
    private let fileURL: URL?
    private let lock = NSLock()

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    public func entry(for file: ScannedFile) -> ParsedFile? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[file.url.path], e.modifiedAt == file.modifiedAt, e.size == file.size else { return nil }
        return e.parsed
    }

    public func store(_ parsed: ParsedFile, for file: ScannedFile) {
        lock.lock(); defer { lock.unlock() }
        entries[file.url.path] = Entry(modifiedAt: file.modifiedAt, size: file.size, parsed: parsed)
    }

    /// Drops entries for files that no longer exist in `keep` and writes the cache to disk.
    public func prune(keeping keep: [ScannedFile]) {
        lock.lock(); defer { lock.unlock() }
        let paths = Set(keep.map(\.url.path))
        entries = entries.filter { paths.contains($0.key) }
    }

    public func save() {
        guard let fileURL else { return }
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Cache is an optimization only.
        }
    }
}

/// Turns raw events into the report the UI shows.
public enum UsageAggregator {
    public static func report(events: [UsageEvent], catalog: PricingCatalog, now: Date = Date(),
                              calendar: Calendar = .current, filesScanned: Int = 0) -> LocalUsageReport {
        var seen = Set<String>()
        var perDayModel: [String: [String: TokenUsage]] = [:]
        var lastActivity: Date?
        for event in events {
            if let key = event.dedupKey {
                if seen.contains(key) { continue }
                seen.insert(key)
            }
            if event.usage.isEmpty { continue }
            let day = calendar.dayKey(for: event.timestamp)
            perDayModel[day, default: [:]][event.model, default: TokenUsage()] += event.usage
            if lastActivity == nil || event.timestamp > lastActivity! { lastActivity = event.timestamp }
        }

        let todayKey = calendar.dayKey(for: now)
        let startOfToday = calendar.startOfDay(for: now)
        let sevenDays = calendar.date(byAdding: .day, value: -6, to: startOfToday)!
        let thirtyDays = calendar.date(byAdding: .day, value: -29, to: startOfToday)!
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!

        var costToday = 0.0, cost7 = 0.0, cost30 = 0.0, costMTD = 0.0
        var today: [ModelUsage] = []
        var tokensToday = TokenUsage()
        var unpriced = Set<String>()

        for (day, models) in perDayModel {
            guard let dayDate = date(fromDayKey: day, calendar: calendar) else { continue }
            var dayCost = 0.0
            for (model, usage) in models {
                let cost: Double
                if let c = catalog.cost(model: model, usage: usage) {
                    cost = c
                } else {
                    cost = 0
                    unpriced.insert(model)
                }
                dayCost += cost
                if day == todayKey {
                    today.append(ModelUsage(model: model, usage: usage, cost: cost))
                    tokensToday += usage
                }
            }
            if day == todayKey { costToday += dayCost }
            if dayDate >= sevenDays { cost7 += dayCost }
            if dayDate >= thirtyDays { cost30 += dayCost }
            if dayDate >= monthStart { costMTD += dayCost }
        }

        today.sort { $0.cost > $1.cost }
        return LocalUsageReport(today: today, costToday: costToday, costLast7Days: cost7, costLast30Days: cost30,
                                costMonthToDate: costMTD, tokensToday: tokensToday, lastActivity: lastActivity,
                                filesScanned: filesScanned, unpricedModels: unpriced.sorted())
    }

    static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// Scans a parser's roots, using the cache, and returns the aggregated report plus the freshest local rate limits.
public struct LocalUsageService: Sendable {
    public var parser: LocalLogParser
    public var cache: ParseCache
    public var lookbackDays: Int

    public init(parser: LocalLogParser, cache: ParseCache, lookbackDays: Int = 35) {
        self.parser = parser
        self.cache = cache
        self.lookbackDays = lookbackDays
    }

    public struct Result: Sendable {
        public var report: LocalUsageReport
        public var rateLimits: LocalRateLimits?
        public var rootsFound: [URL]
    }

    public func run(catalog: PricingCatalog, now: Date = Date(), environment: [String: String] = ProcessInfo.processInfo.environment,
                    home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Result {
        let cutoff = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: now)
        let roots = parser.roots(environment: environment, home: home).filter { FileManager.default.fileExists(atPath: $0.path) }
        var files: [ScannedFile] = []
        for root in roots {
            files += LogFiles.enumerate(root: root, extensions: parser.fileExtensions, modifiedAfter: cutoff)
        }
        var events: [UsageEvent] = []
        var latestLimits: LocalRateLimits?
        for file in files {
            let parsed: ParsedFile
            if let cached = cache.entry(for: file) {
                parsed = cached
            } else {
                parsed = (try? parser.parse(file: file.url)) ?? ParsedFile()
                cache.store(parsed, for: file)
            }
            events += parsed.events
            if let limits = parsed.rateLimits, latestLimits == nil || limits.observedAt > latestLimits!.observedAt {
                latestLimits = limits
            }
        }
        cache.prune(keeping: files)
        cache.save()
        let report = UsageAggregator.report(events: events, catalog: catalog, now: now, filesScanned: files.count)
        return Result(report: report, rateLimits: latestLimits, rootsFound: roots)
    }
}
