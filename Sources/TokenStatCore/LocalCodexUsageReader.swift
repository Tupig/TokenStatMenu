import Foundation
import CoreFoundation
import Darwin
import CryptoKit

public struct LocalCodexSnapshot: Equatable {
    public let input: Int
    public let output: Int
    public let total: Int
    public let sessionCount: Int
    public let filesScanned: Int
    public let isLimited: Bool
    public let latestEventAt: Date?
    public let fiveHour: WindowQuota?
    public let sevenDay: WindowQuota?
    public let lastTurn: LocalTurnSummary?
    public let liveTurn: LocalLiveTurnSummary?
    public let knownThreadCount: Int
    public let unknownThreadCount: Int
    public let unidentifiedFileCount: Int
    public let subagentCount: Int
    public let forkCount: Int
    public var hasCompleteAccounting: Bool {
        knownThreadCount > 0 && unknownThreadCount == 0 && unidentifiedFileCount == 0 && !isLimited
    }

    public init(input: Int, output: Int, total: Int, sessionCount: Int, filesScanned: Int,
                isLimited: Bool, latestEventAt: Date?, fiveHour: WindowQuota?, sevenDay: WindowQuota?,
                knownThreadCount: Int = 0, unknownThreadCount: Int = 0, unidentifiedFileCount: Int = 0,
                subagentCount: Int = 0, forkCount: Int = 0, lastTurn: LocalTurnSummary? = nil,
                liveTurn: LocalLiveTurnSummary? = nil) {
        self.input = input; self.output = output; self.total = total; self.sessionCount = sessionCount
        self.filesScanned = filesScanned; self.isLimited = isLimited; self.latestEventAt = latestEventAt
        self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.lastTurn = lastTurn; self.liveTurn = liveTurn
        self.knownThreadCount = knownThreadCount; self.unknownThreadCount = unknownThreadCount
        self.unidentifiedFileCount = unidentifiedFileCount; self.subagentCount = subagentCount; self.forkCount = forkCount
    }
}

public struct LocalTurnSummary: Equatable {
    public let outputTokens: Int
    public let durationSeconds: Double
    public let completedAt: Date
    public var outputTPS: Double { Double(outputTokens) / durationSeconds }
    public init(outputTokens: Int, durationSeconds: Double, completedAt: Date) {
        self.outputTokens = outputTokens; self.durationSeconds = durationSeconds; self.completedAt = completedAt
    }
}

/// A short-lived estimate derived from two recent cumulative `token_count`
/// events while a Codex task is still active. It expires quickly when the
/// rollout stops advancing and is kept separate from completed-turn averages.
public struct LocalLiveTurnSummary: Equatable {
    public let inputTPS: Double
    public let outputTPS: Double
    public let observedAt: Date

    public init(inputTPS: Double, outputTPS: Double, observedAt: Date) {
        self.inputTPS = inputTPS; self.outputTPS = outputTPS; self.observedAt = observedAt
    }
}

/// A verified association between the active Codex provider and Seasun Token
/// Hub. The origin is proved by the caller and is not retained in public state.
public struct LocalCodexRouteContext: Equatable, Sendable {
    public let provider: String?
    public let isVerified: Bool
    fileprivate let fingerprint: String

    public static let unverified = LocalCodexRouteContext(provider: nil, isVerified: false,
        fingerprint: "unverified")

    public static func verified(provider: String, origin: String) -> LocalCodexRouteContext {
        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOrigin = origin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedProvider.isEmpty, !normalizedOrigin.isEmpty,
              normalizedOrigin.hasPrefix("https://") else { return .unverified }
        return LocalCodexRouteContext(provider: normalizedProvider, isVerified: true,
            fingerprint: "verified|\(normalizedProvider)|\(normalizedOrigin)")
    }

    fileprivate init(provider: String?, isVerified: Bool, fingerprint: String) {
        self.provider = provider; self.isVerified = isVerified; self.fingerprint = fingerprint
    }

    fileprivate func accepts(_ modelProvider: String?) -> Bool {
        guard isVerified, let provider, let modelProvider else { return false }
        return provider == modelProvider
    }
}

/// Completion-relative, generation-aware schedule for local usage scans.
public struct LocalRefreshScheduler {
    private(set) public var generation = 0
    private var inFlight: Int?
    private var nextDue = Date.distantPast
    public init() {}
    public mutating func begin(now: Date) -> Int? {
        guard inFlight == nil, now >= nextDue else { return nil }
        inFlight = generation
        return generation
    }
    @discardableResult public mutating func complete(generation token: Int, now: Date) -> Bool {
        guard inFlight == token, generation == token else { return false }
        inFlight = nil; nextDue = now.addingTimeInterval(5)
        return true
    }
    @discardableResult public mutating func invalidate() -> Int {
        generation += 1; inFlight = nil; nextDue = .distantPast
        return generation
    }
}

/// Reads bounded Codex usage records; unknown identity or lineage stays unknown.
public enum LocalCodexUsageReader {
    private static let maxEntries = 5_000
    private static let maxFiles = 32
    private static let headLimit = 64 * 1024
    private static let tailLimit = 256 * 1024
    private static let byteLimit = 10 * 1024 * 1024
    private static let maxIdentityBytes = 128
    private static let isoFormatter = ISO8601DateFormatter()
    private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }()
    private static let uuidPattern = try! NSRegularExpression(pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

    private struct Candidate { let name: String; let modified: Date }
    fileprivate struct Record { let date: Date; let input: Int; let output: Int; let total: Int; let five: WindowQuota?; let seven: WindowQuota?; let isRate: Bool }
    fileprivate struct FileSignature: Hashable {
        let device: UInt64; let inode: UInt64; let size: Int64
        let mtimeSec: Int64; let mtimeNSec: Int64; let ctimeSec: Int64; let ctimeNSec: Int64
        init(_ st: stat) {
            device = UInt64(st.st_dev); inode = UInt64(st.st_ino); size = Int64(st.st_size)
            mtimeSec = Int64(st.st_mtimespec.tv_sec); mtimeNSec = Int64(st.st_mtimespec.tv_nsec)
            ctimeSec = Int64(st.st_ctimespec.tv_sec); ctimeNSec = Int64(st.st_ctimespec.tv_nsec)
        }
    }
    fileprivate struct ParsedEvent {
        let date: Date; let type: String; let turnID: String?; let duration: Double?
        let totalTokens: Int?; let outputTokens: Int?; let hasCumulativePayload: Bool
        let usage: Record?; let rate: Record?; let quotaUpdate: QuotaUpdate; let threadID: String?
        let rawOrdinal: Int; let ownSettingsMatch: Bool; let invalidLifecycleTimestamp: Bool
    }
    fileprivate enum QuotaUpdate { case unchanged, replace(Record), clear }
    private enum QuotaState { case absent, value(Record) }
    fileprivate enum Lineage { case root, subagent, fork, unknown }
    fileprivate struct FileSummary {
        let identity: String?; let lineage: Lineage; let isFork: Bool; let sourceKnownTop: Bool
        let contribution: Record?; let rate: Record?; let quotaDate: Date?; let turn: LocalTurnSummary?
        let live: LocalLiveTurnSummary?
        let latestEventAt: Date?; let tailLimited: Bool; let headComplete: Bool; let hasFutureTurn: Bool
        let contentHash: String?; let signature: FileSignature
    }
    fileprivate struct CachedFileSummary { let summary: FileSummary; let evaluatedAt: Date }
    public final class Cache {
        public struct Diagnostics: Equatable {
            public fileprivate(set) var bytesRead = 0; public fileprivate(set) var parsedFiles = 0
            public fileprivate(set) var cacheHits = 0; public fileprivate(set) var safeOpens = 0
        }
        public private(set) var diagnostics = Diagnostics()
        public var entryCount: Int { entries.count }
        fileprivate var entries: [FileSignature: CachedFileSummary] = [:]
        fileprivate var rootIdentity: FileSignature?
        fileprivate var routeFingerprint: String?
        fileprivate var beforePostReadValidation: (() -> Void)?
        public init() {}
        init(beforePostReadValidation: @escaping () -> Void) { self.beforePostReadValidation = beforePostReadValidation }
        fileprivate func resetDiagnostics() { diagnostics = Diagnostics() }
        fileprivate func opened() { diagnostics.safeOpens += 1 }
        fileprivate func hit() { diagnostics.cacheHits += 1 }
        fileprivate func read(_ count: Int) { diagnostics.bytesRead += count }
        fileprivate func parsed() { diagnostics.parsedFiles += 1 }
    }

    public static func defaultSessionsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let configured = environment["CODEX_HOME"], configured.hasPrefix("/") { return URL(fileURLWithPath: configured).appendingPathComponent("sessions") }
        return home.appendingPathComponent(".codex").appendingPathComponent("sessions")
    }
    public static func defaultConfigURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let configured = environment["CODEX_HOME"], configured.hasPrefix("/") {
            return URL(fileURLWithPath: configured).appendingPathComponent("config.toml")
        }
        return home.appendingPathComponent(".codex").appendingPathComponent("config.toml")
    }
    public static func scan(directory: URL, now: Date = Date()) throws -> LocalCodexSnapshot { try scan(directory: directory, now: now, cache: nil) }
    public static func scan(directory: URL, now: Date = Date(),
                            routeContext: LocalCodexRouteContext?) throws -> LocalCodexSnapshot {
        try scan(directory: directory, now: now, cache: nil, routeContext: routeContext)
    }

    public static func scan(directory: URL, now: Date = Date(), cache: Cache?,
                            routeContext: LocalCodexRouteContext? = nil) throws -> LocalCodexSnapshot {
        cache?.resetDiagnostics()
        func empty() -> LocalCodexSnapshot { LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0, filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil) }
        if let cache, cache.routeFingerprint != routeContext?.fingerprint {
            cache.entries.removeAll(); cache.routeFingerprint = routeContext?.fingerprint
        }
        var st = stat()
        guard lstat(directory.path, &st) == 0 else { cache?.entries.removeAll(); cache?.rootIdentity = nil; return empty() }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { cache?.entries.removeAll(); cache?.rootIdentity = nil; return empty() }
        let rootFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { cache?.entries.removeAll(); cache?.rootIdentity = nil; return empty() }
        defer { close(rootFD) }
        var opened = stat()
        guard fstat(rootFD, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFDIR else { cache?.entries.removeAll(); cache?.rootIdentity = nil; return empty() }
        let rootSignature = FileSignature(opened)
        if cache?.rootIdentity != rootSignature { cache?.entries.removeAll(); cache?.rootIdentity = rootSignature }

        var candidates: [Candidate] = [], directories = [""]
        var discoveryLimited = false
        var entries = 0, limited = false
        while let relative = directories.first, entries < maxEntries {
            directories.removeFirst()
            let dfd = relative.isEmpty ? dup(rootFD) : openDirectoryRelative(rootFD, relative)
            guard dfd >= 0, let listing = fdopendir(dfd) else { if dfd >= 0 { close(dfd) }; continue }
            while entries < maxEntries, let item = readdir(listing) {
                let leaf = withUnsafePointer(to: &item.pointee.d_name) { ptr in ptr.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) } }
                if leaf == "." || leaf == ".." { continue }
                entries += 1
                let name = relative.isEmpty ? leaf : relative + "/" + leaf
                var fst = stat(); guard fstatat(dfd, leaf, &fst, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                if (fst.st_mode & S_IFMT) == S_IFDIR { directories.append(name); continue }
                guard (fst.st_mode & S_IFMT) == S_IFREG, name.lowercased().hasSuffix(".jsonl") else { continue }
                candidates.append(Candidate(name: name, modified: Date(timeIntervalSince1970: Double(fst.st_mtimespec.tv_sec))))
            }
            closedir(listing)
        }
        if entries >= maxEntries { limited = true; discoveryLimited = true }
        candidates.sort { $0.modified == $1.modified ? $0.name < $1.name : $0.modified > $1.modified }
        if candidates.count > maxFiles { candidates = Array(candidates.prefix(maxFiles)); limited = true; discoveryLimited = true }

        var usedBytes = 0, filesScanned = 0, unidentified = 0, unsafeCandidate = false, coverageLimited = false
        var summaries: [FileSummary] = [], liveSignatures = Set<FileSignature>()
        for candidate in candidates {
            let fd = openRelative(rootFD, candidate.name); guard fd >= 0 else { unsafeCandidate = true; continue }
            defer { close(fd) }
            cache?.opened()
            var fst = stat(); guard fstat(fd, &fst) == 0, (fst.st_mode & S_IFMT) == S_IFREG, fst.st_size >= 0 else { unsafeCandidate = true; continue }
            guard isContained(fd: fd, rootFD: rootFD) else { unsafeCandidate = true; continue }
            let signature = FileSignature(fst); liveSignatures.insert(signature)
            if let cache, let old = cache.entries.keys.first(where: { $0.device == signature.device && $0.inode == signature.inode && $0 != signature }) {
                let timestampChanged = old.mtimeSec != signature.mtimeSec || old.mtimeNSec != signature.mtimeNSec || old.ctimeSec != signature.ctimeSec || old.ctimeNSec != signature.ctimeNSec
                if timestampChanged { cache.entries = cache.entries.filter { $0.key.device != signature.device || $0.key.inode != signature.inode } }
            }
            if fst.st_size < 0 { unsafeCandidate = true; continue }
            // A clock rollback can turn previously current evidence into future
            // evidence. Reparse it rather than reusing a time-dependent result.
            if let cached = cache?.entries[signature], now >= cached.evaluatedAt {
                cache?.hit()
                let cachedSummary = cached.summary
                let cachedLive: LocalLiveTurnSummary? = cachedSummary.live.flatMap { live in
                    guard live.observedAt <= now, now.timeIntervalSince(live.observedAt) <= 15 else { return nil }
                    return live
                }
                let refreshed = FileSummary(identity: cachedSummary.identity, lineage: cachedSummary.lineage,
                    isFork: cachedSummary.isFork,
                    sourceKnownTop: cachedSummary.sourceKnownTop, contribution: cachedSummary.contribution,
                    rate: cachedSummary.rate,
                    quotaDate: cachedSummary.quotaDate, turn: cachedSummary.hasFutureTurn ? nil : cachedSummary.turn, live: cachedLive, latestEventAt: cachedSummary.latestEventAt,
                    tailLimited: cachedSummary.tailLimited, headComplete: cachedSummary.headComplete,
                    hasFutureTurn: cachedSummary.hasFutureTurn, contentHash: cachedSummary.contentHash, signature: cachedSummary.signature)
                summaries.append(refreshed); filesScanned += 1
                if cached.summary.tailLimited || !cached.summary.headComplete { limited = true; coverageLimited = true }
                if cached.summary.hasFutureTurn { cache?.entries.removeValue(forKey: signature); unsafeCandidate = true }
                let cachedSize = Int(fst.st_size)
                let cacheCost = min(cachedSize, headLimit) + max(0, min(tailLimit, cachedSize - headLimit))
                if usedBytes + cacheCost > byteLimit { limited = true; coverageLimited = true; continue }
                usedBytes += cacheCost
                continue
            }
        let size = Int(fst.st_size), headCount = min(size, headLimit)
            let tailCount = size > headLimit ? min(tailLimit, size - headCount) : 0
        let amount = headCount + tailCount
            if amount == 0 { unidentified += 1; filesScanned += 1; continue }
            guard amount > 0, usedBytes + amount <= byteLimit else { limited = true; coverageLimited = true; break }
            usedBytes += amount
            var bytes = Data(count: amount)
            let readCount: Int = bytes.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                let h = pread(fd, base, headCount, 0); guard h == headCount else { return max(0, h) }
                if tailCount > 0 { return h + max(0, pread(fd, base.advanced(by: headCount), tailCount, off_t(size - tailCount))) }
                return h
            }
            guard readCount == amount else { cache?.read(readCount); unidentified += 1; limited = true; unsafeCandidate = true; continue }
            bytes.count = readCount; cache?.read(readCount)
            cache?.beforePostReadValidation?()
            var after = stat(); guard fstat(fd, &after) == 0, FileSignature(after) == signature else { cache?.entries.removeValue(forKey: signature); unsafeCandidate = true; continue }
            cache?.parsed()
            let parsed = parseFile(bytes: bytes, size: size, now: now, signature: signature,
                                   routeContext: routeContext)
            filesScanned += 1
            if parsed.identity == nil { unidentified += 1 }
            if parsed.tailLimited || !parsed.headComplete { limited = true; coverageLimited = true }
            summaries.append(parsed)
            if let cache, parsed.identity != nil, !parsed.hasFutureTurn {
                cache.entries[signature] = CachedFileSummary(summary: parsed, evaluatedAt: now)
                if cache.entries.count > maxFiles { cache.entries.removeValue(forKey: cache.entries.keys.first!) }
            } else {
                // Future lifecycle/counter evidence must be rejudged as time
                // catches up, including when the file itself remains unchanged.
                cache?.entries.removeValue(forKey: signature)
            }
        }
        if let cache { cache.entries = cache.entries.filter { liveSignatures.contains($0.key) } }
        _ = discoveryLimited

        // Same inode is one physical history. Same ID is one logical thread only if whole bytes match.
        var physicalSeen = Set<FileSignature>()
        summaries = summaries.filter { physicalSeen.insert($0.signature).inserted }
        let allRates = summaries.compactMap { summary -> (Date, Record?)? in summary.quotaDate.map { ($0, summary.rate) } }
        let quotaWinner = allRates.enumerated().reduce(nil as (offset: Int, element: (Date, Record?))?) { best, current in
            guard let best else { return (current.offset, current.element) }
            return current.element.0 >= best.element.0 ? (current.offset, current.element) : best
        }?.element
        var grouped: [String: [FileSummary]] = [:]
        let unidentifiedCount = unidentified
        for summary in summaries {
            guard let identity = summary.identity else { continue }
            grouped[identity, default: []].append(summary)
        }
        var known: [Record] = [], unknownThreads = 0, topLevelCount = 0, subagentCount = 0, forkCount = 0
        var latestTurn: LocalTurnSummary?, latestEvent: Date?
        var liveInputTPS = 0.0, liveOutputTPS = 0.0, latestLiveAt: Date?
        for (_, variants) in grouped {
            let hashes = variants.compactMap(\.contentHash)
            guard variants.count == 1 || hashes.count == variants.count && Set(hashes).count == 1,
                  variants.allSatisfy({ $0.lineage == variants[0].lineage && $0.isFork == variants[0].isFork }) else { unknownThreads += 1; continue }
            let summary = variants[0]
            if summary.lineage == .unknown { unknownThreads += 1 }
            else {
                if summary.sourceKnownTop && summary.lineage == .root { topLevelCount += 1 }
                if summary.lineage == .subagent { subagentCount += 1 }
                if summary.isFork { forkCount += 1 }
                if let contribution = summary.contribution { known.append(contribution) } else { unknownThreads += 1 }
            }
            if let turn = summary.turn, turn.completedAt <= now, latestTurn == nil || turn.completedAt > latestTurn!.completedAt { latestTurn = turn }
            if let event = summary.latestEventAt, latestEvent == nil || event > latestEvent! { latestEvent = event }
            if let live = summary.live, live.observedAt <= now {
                liveInputTPS += live.inputTPS; liveOutputTPS += live.outputTPS
                // The aggregate expires when its oldest included component
                // expires; a newer session cannot extend an older one's rate.
                if latestLiveAt == nil || live.observedAt < latestLiveAt! { latestLiveAt = live.observedAt }
            }
        }
        var input = 0, output = 0, total = 0
        for record in known {
            let (i, io) = input.addingReportingOverflow(record.input), (o, oo) = output.addingReportingOverflow(record.output), (t, ot) = total.addingReportingOverflow(record.total)
            guard !io && !oo && !ot else { throw StatError.message("本地用量汇总超出可表示范围") }
            input = i; output = o; total = t
        }
        let finalRate = quotaWinner?.1
        let liveTurn = latestLiveAt.map { LocalLiveTurnSummary(inputTPS: liveInputTPS,
            outputTPS: liveOutputTPS, observedAt: $0) }
        return LocalCodexSnapshot(input: input, output: output, total: total, sessionCount: topLevelCount,
            filesScanned: filesScanned, isLimited: limited || unsafeCandidate || coverageLimited, latestEventAt: latestEvent,
            fiveHour: finalRate?.five, sevenDay: finalRate?.seven, knownThreadCount: known.count,
            unknownThreadCount: unknownThreads, unidentifiedFileCount: unidentifiedCount,
            subagentCount: subagentCount, forkCount: forkCount, lastTurn: latestTurn, liveTurn: liveTurn)
    }

    private static func parseFile(bytes: Data, size: Int, now: Date, signature: FileSignature,
                                 routeContext: LocalCodexRouteContext?) -> FileSummary {
        let headLength = min(size, headLimit), tailLength = max(0, bytes.count - headLength)
        let head = bytes.prefix(headLength), tail = tailLength > 0 ? bytes.suffix(tailLength) : Data()
        let tailLimited = size > headLimit + tailLimit
        let wholeFileRead = size <= headLimit + tailLimit
        let headComplete = wholeFileRead || size <= headLimit || head.last == 10
        let headLines = wholeFileRead ? completeLines(Data(bytes), startsAtFileStart: true, endsAtFileEnd: size <= bytes.count && bytes.last == 10) : completeLines(Data(head), startsAtFileStart: true, endsAtFileEnd: false)
        let tailLines = !wholeFileRead && tailLength > 0 ? completeLines(Data(tail), startsAtFileStart: false, endsAtFileEnd: true) : []
        let headSlots = headLines.enumerated().map { parseLine($0.element, fallbackOrdinal: $0.offset) }
        let decodedHead = headSlots.compactMap { $0 }
        let physicalRecordCountHead = headLines.count
        let tailOrdinalBase = size > headLimit + tailLimit ? -1 : physicalRecordCountHead
        let tailSlots = tailLines.enumerated().map { parseLine($0.element, fallbackOrdinal: tailOrdinalBase < 0 ? -1 : tailOrdinalBase + $0.offset) }
        let decodedTail = tailSlots.compactMap { $0 }
        var decoded = tailLength > 0 ? decodedHead + decodedTail : decodedHead
        let continuousRead = wholeFileRead
        let incompleteTail = bytes.last != 10
            ? Data(bytes[(bytes.lastIndex(of: 10).map { bytes.index(after: $0) } ?? bytes.startIndex)...])
            : Data()
        let hasIncompleteTailFragment = !incompleteTail.isEmpty
        let identity: String?
        let firstPhysicalLine = completeLines(Data(bytes.prefix(headLength)), startsAtFileStart: true, endsAtFileEnd: size <= headLength).first
        if let first = firstPhysicalLine, !first.isEmpty, let object = try? JSONSerialization.jsonObject(with: Data(first)),
           let root = object as? [String: Any], root["type"] as? String == "session_meta",
           let id = (root["payload"] as? [String: Any])?["id"] as? String, let normalized = normalizeUUID(id) { identity = normalized }
        else { identity = nil }
        guard let identity else {
            return FileSummary(identity: nil, lineage: .unknown, isFork: false, sourceKnownTop: false, contribution: nil, rate: nil,
                quotaDate: nil, turn: nil, live: nil, latestEventAt: nil, tailLimited: tailLimited, headComplete: headComplete, hasFutureTurn: false,
                contentHash: bytes.fullContentHashIfComplete(fileSize: size), signature: signature)
        }
        func remap(_ event: ParsedEvent) -> ParsedEvent {
            ParsedEvent(date: event.date, type: event.type, turnID: event.turnID, duration: event.duration,
                totalTokens: event.totalTokens, outputTokens: event.outputTokens, hasCumulativePayload: event.hasCumulativePayload,
                usage: event.usage, rate: event.rate, quotaUpdate: event.quotaUpdate, threadID: event.threadID,
                rawOrdinal: event.rawOrdinal, ownSettingsMatch: event.type == "thread_settings_applied" && event.threadID == identity,
                invalidLifecycleTimestamp: event.invalidLifecycleTimestamp)
        }
        let mappedHeadSlots = headSlots.map { $0.map(remap) }
        let mappedTailSlots = tailSlots.map { $0.map(remap) }
        decoded = (wholeFileRead ? mappedHeadSlots : mappedHeadSlots + mappedTailSlots).compactMap { $0 }
        guard let firstMetaLine = firstPhysicalLine else { return FileSummary(identity: nil, lineage: .unknown, isFork: false, sourceKnownTop: false, contribution: nil, rate: nil, quotaDate: nil, turn: nil, live: nil, latestEventAt: nil, tailLimited: tailLimited, headComplete: headComplete, hasFutureTurn: false, contentHash: bytes.fullContentHashIfComplete(fileSize: size), signature: signature) }
        let metadata = (try? JSONSerialization.jsonObject(with: Data(firstMetaLine))) as? [String: Any]
        let payload = metadata?["payload"] as? [String: Any] ?? [:]
        if let routeContext, !routeContext.accepts(payload["model_provider"] as? String) {
            return FileSummary(identity: nil, lineage: .unknown, isFork: false, sourceKnownTop: false,
                contribution: nil, rate: nil, quotaDate: nil, turn: nil, live: nil, latestEventAt: nil,
                tailLimited: tailLimited, headComplete: headComplete, hasFutureTurn: false,
                contentHash: bytes.fullContentHashIfComplete(fileSize: size), signature: signature)
        }
        let (source, sourceSubagentKind) = sessionSource(payload["source"])
        let threadSource = payload["thread_source"] as? String
        let sourceIsRootString = payload["source"] as? String == source && isTopRootSource(source)
        let subagent = isKnownSubagent(source: source, subagentKind: sourceSubagentKind, threadSource: threadSource, payload: payload)
        let parentMarkers = ["forked_from_id", "parent_thread_id", "history_base"].contains { payload[$0] != nil && !(payload[$0] is NSNull) }
        let hasHistoryStart = payload["subagent_history_start_ordinal"] != nil && !(payload["subagent_history_start_ordinal"] is NSNull)
        let hasUnresolvedSubagentMarker = !subagent && (
            payload["subagent"] != nil ||
            (payload["thread_source"] != nil && payload["thread_source"] as? String != "user")
                || ["agent_nickname", "agent_role", "agent_path"].contains { payload[$0] != nil }
        )
        let malformedLineage = hasMalformedLineage(payload)
        let hasHistoryBase = payload["history_base"] != nil && !(payload["history_base"] is NSNull)
        let inheritsHistory = parentMarkers || hasHistoryStart
        let sourceKnown = sourceIsRootString || subagent
        let lineage: Lineage = malformedLineage || hasUnresolvedSubagentMarker || !sourceKnown
            ? .unknown : (subagent ? .subagent : (inheritsHistory ? .fork : .root))
        let isFork = !malformedLineage && (parentMarkers || hasHistoryStart)
        let sourceKnownTop = sourceIsRootString && !subagent && !inheritsHistory
        let tokenEvents = decoded.filter { $0.type == "token_count" }
        let cumulativeTokenEvents = tokenEvents.filter(\.hasCumulativePayload)
        let validCounters = cumulativeTokenEvents.filter { $0.usage != nil }
        let hasFutureCounter = cumulativeTokenEvents.contains { $0.date > now }
        let lastToken = cumulativeTokenEvents.last
        let observedLineSegments = wholeFileRead ? [mappedHeadSlots] : [mappedHeadSlots, mappedTailSlots]
        let latestCounterSegment = observedLineSegments.lastIndex(where: { $0.contains(where: { $0?.hasCumulativePayload == true }) })
        let hasBadLineAfterLatestCounter: Bool = {
            guard let segmentIndex = latestCounterSegment, let lineIndex = observedLineSegments[segmentIndex].lastIndex(where: { $0?.hasCumulativePayload == true }) else { return false }
            return observedLineSegments[segmentIndex].dropFirst(lineIndex + 1).contains(where: { $0 == nil })
        }()
        let latestCounterInTail = !wholeFileRead && !mappedTailSlots.isEmpty && mappedTailSlots.contains(where: { $0?.hasCumulativePayload == true })
        let forkHasCompleteLines = wholeFileRead && mappedHeadSlots.allSatisfy { $0 != nil } && incompleteTail.isEmpty
        var contribution: Record? = nil
        if lineage == .root {
            if let lastToken, let usage = lastToken.usage,
               !cumulativeTokenEvents.contains(where: \.invalidLifecycleTimestamp), !hasFutureCounter, !hasIncompleteTailFragment,
               !hasBadLineAfterLatestCounter, (wholeFileRead || latestCounterInTail) { contribution = usage }
        } else if (lineage == .subagent || lineage == .fork), !hasHistoryBase, !hasFutureCounter, headComplete, !tailLimited,
                  continuousRead, forkHasCompleteLines, let delta = forkContribution(payload: payload, events: decoded) { contribution = delta }
        let rateEvents = tokenEvents.map { ($0.date, $0.quotaUpdate) }
        let resolvedQuota = resolveRate(rateEvents, now: now)
        let rate = resolvedQuota.record
        let turnSegments = observedLineSegments.flatMap { parsedSegments($0) }
        let turn = turnSegments.compactMap { completedTurns(in: $0, now: now) }.max(by: { $0.completedAt < $1.completedAt })
        // Live lifecycle evidence must be in the final continuous segment. A
        // corrupt record, unread middle, or incomplete tail cannot be bridged.
        let live: LocalLiveTurnSummary?
        if !hasIncompleteTailFragment, let finalSlots = observedLineSegments.last,
           finalSlots.last.flatMap({ $0 }) != nil,
           let finalSegment = parsedSegments(finalSlots).last {
            live = liveTurn(in: finalSegment, now: now)
        } else { live = nil }
        let latestUsageDate = validCounters.last?.date
        return FileSummary(identity: identity, lineage: lineage, isFork: isFork, sourceKnownTop: sourceKnownTop,
            contribution: contribution, rate: rate, quotaDate: resolvedQuota.date, turn: turn, live: live, latestEventAt: latestUsageDate,
            tailLimited: tailLimited, headComplete: headComplete,
            hasFutureTurn: decoded.contains(where: { ["task_started", "task_complete", "turn_aborted", "token_count"].contains($0.type) && $0.date > now }),
            contentHash: bytes.fullContentHashIfComplete(fileSize: size), signature: signature)
    }

    private static func forkContribution(payload: [String: Any], events: [ParsedEvent]) -> Record? {
        let explicit = uint(payload["subagent_history_start_ordinal"])
        let settings = events.filter(\.ownSettingsMatch)
        let inferred = settings.first?.rawOrdinal
        if let explicit, let inferred, explicit != UInt64(inferred) { return nil }
        let boundary: Int
        if let explicit, explicit <= UInt64(Int.max) { boundary = Int(explicit) }
        else if payload["subagent_history_start_ordinal"] != nil && !(payload["subagent_history_start_ordinal"] is NSNull) { return nil }
        else if let inferred { boundary = inferred }
        else { return nil }
        // Ordinals are zero-based record positions. Ensure every record through final counter was read.
        guard boundary >= 0, events.contains(where: { $0.rawOrdinal == boundary }), events.allSatisfy({ $0.rawOrdinal >= 0 }) else { return nil }
        let before = events.filter { $0.rawOrdinal >= 0 && $0.rawOrdinal < boundary && $0.type == "token_count" && $0.hasCumulativePayload }
        let after = events.filter { $0.rawOrdinal >= boundary && $0.type == "token_count" && $0.hasCumulativePayload }
        guard let baseline = before.last?.usage, let final = after.last?.usage,
              after.allSatisfy({ $0.usage != nil }) else { return nil }
        let history = events.filter { $0.rawOrdinal >= 0 && $0.rawOrdinal < boundary && $0.type == "token_count" && $0.hasCumulativePayload }
        guard history.allSatisfy({ $0.usage != nil }) else { return nil }
        let sequence = history.compactMap(\.usage) + after.compactMap(\.usage)
        guard isMonotonic(sequence.map(\.input)), isMonotonic(sequence.map(\.output)), isMonotonic(sequence.map(\.total)) else { return nil }
        let i = final.input - baseline.input, o = final.output - baseline.output, t = final.total - baseline.total
        guard i >= 0, o >= 0, t >= 0 else { return nil }
        return Record(date: final.date, input: i, output: o, total: t, five: nil, seven: nil, isRate: false)
    }

    private static func parseLine(_ line: Data.SubSequence, fallbackOrdinal: Int) -> ParsedEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)), let root = object as? [String: Any],
              let type = root["type"] as? String else { return nil }
        let payload = root["payload"] as? [String: Any] ?? [:]
        let date = parseDate(root["timestamp"]) ?? .distantPast
        // A malformed event envelope is a continuity barrier, just like broken
        // JSON; otherwise it could silently hide a lifecycle boundary.
        if type == "event_msg" {
            guard let kind = payload["type"] as? String, !kind.isEmpty else { return nil }
        }
        let eventType = type == "event_msg" ? (payload["type"] as? String ?? "") : type
        var usage: Record?, rate: Record?
        let info = payload["info"] as? [String: Any]
        let cumulativePresent = info?.keys.contains("total_token_usage") == true
        let cumulative = info?["total_token_usage"] as? [String: Any]
        if eventType == "token_count", let cumulative,
           let i = integer(cumulative["input_tokens"]), let o = integer(cumulative["output_tokens"]), let t = integer(cumulative["total_tokens"]) {
            usage = Record(date: date, input: i, output: o, total: t, five: nil, seven: nil, isRate: false)
        }
        let quota = eventType == "token_count" ? quotaUpdate(payload["rate_limits"], at: date) : .unchanged
        if case .replace(let r) = quota { rate = r }
        let duration: Double?
        if payload.keys.contains("duration_ms") {
            if let n = payload["duration_ms"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue >= 0 { duration = n.doubleValue }
            else { duration = .nan }
        } else { duration = nil }
        let ownID = normalizeUUID((payload["id"] as? String) ?? "")
        let eventThread = normalizeUUID((payload["thread_id"] as? String) ?? "")
        let invalidLifecycleTimestamp = ["task_started", "task_complete", "turn_aborted", "token_count"].contains(eventType) && parseDate(root["timestamp"]) == nil
        return ParsedEvent(date: date, type: eventType, turnID: payload["turn_id"] as? String,
            duration: duration, totalTokens: usage?.total, outputTokens: usage?.output,
            hasCumulativePayload: cumulativePresent, usage: usage, rate: rate, quotaUpdate: quota,
            threadID: eventThread, rawOrdinal: fallbackOrdinal,
            ownSettingsMatch: eventType == "thread_settings_applied" && ownID != nil && eventThread == ownID,
            invalidLifecycleTimestamp: invalidLifecycleTimestamp)
    }

    private static func completeLines(_ data: Data, startsAtFileStart: Bool, endsAtFileEnd: Bool) -> [Data.SubSequence] {
        guard !data.isEmpty else { return [] }
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if !startsAtFileStart { lines.removeFirst() }
        lines.removeLast()
        _ = endsAtFileEnd
        return lines
    }

    private static func parsedSegments(_ slots: [ParsedEvent?]) -> [[ParsedEvent]] {
        var segments: [[ParsedEvent]] = [], current: [ParsedEvent] = []
        for slot in slots {
            if let event = slot { current.append(event) }
            else if !current.isEmpty { segments.append(current); current.removeAll(keepingCapacity: true) }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// Derive a short-lived output/input rate only from a still-open task and
    /// two monotonic cumulative counters. A missing or stale tail is unknown.
    private static func liveTurn(in events: [ParsedEvent], now: Date) -> LocalLiveTurnSummary? {
        let freshnessLimit: TimeInterval = 15
        var activeID: String?
        var openIDs: [String: Int] = [:], seenIDs = Set<String>()
        var ambiguous = false
        var lastDate: Date?
        var counters: [Record] = []
        for event in events {
            let validTime = !event.invalidLifecycleTimestamp && event.date <= now
            switch event.type {
            case "task_started":
                let id = event.turnID ?? ""
                let unique = seenIDs.insert(id).inserted
                if openIDs.isEmpty {
                    activeID = id.isEmpty ? nil : id
                    ambiguous = id.isEmpty || !unique || !validTime
                    lastDate = event.date
                    counters.removeAll(keepingCapacity: true)
                } else {
                    // Keep all open IDs so closing one overlapping task cannot
                    // make the other task appear independently attributable.
                    ambiguous = true
                }
                openIDs[id, default: 0] += 1
            case "task_complete", "turn_aborted":
                if !validTime || lastDate.map({ event.date < $0 }) == true { ambiguous = true }
                if let id = event.turnID, let count = openIDs[id] {
                    if count == 1 { openIDs.removeValue(forKey: id) } else { openIDs[id] = count - 1 }
                } else if event.turnID == nil, event.type == "turn_aborted" {
                    openIDs.removeAll()
                } else { ambiguous = true }
                if openIDs.isEmpty {
                    activeID = nil; lastDate = nil
                    counters.removeAll(keepingCapacity: true)
                }
            case "token_count":
                guard activeID != nil else { continue }
                if !validTime || lastDate.map({ event.date < $0 }) == true { ambiguous = true }
                lastDate = event.date
                guard event.hasCumulativePayload else { continue }
                guard let usage = event.usage else { ambiguous = true; continue }
                if let previous = counters.last,
                   usage.input < previous.input || usage.output < previous.output || usage.total < previous.total {
                    ambiguous = true
                }
                // Keep just the last pair after validating every observed
                // counter, so a prior reset cannot be hidden by two good ones.
                if counters.count == 2 { counters.removeFirst() }
                counters.append(usage)
            default: break
            }
        }
        guard activeID != nil, !ambiguous, openIDs.count == 1,
              let latest = counters.last, let previous = counters.dropLast().last,
              now.timeIntervalSince(latest.date) <= freshnessLimit else { return nil }
        let elapsed = latest.date.timeIntervalSince(previous.date)
        guard elapsed > 0 else { return nil }
        return LocalLiveTurnSummary(inputTPS: Double(latest.input - previous.input) / elapsed,
            outputTPS: Double(latest.output - previous.output) / elapsed,
            observedAt: latest.date)
    }

    private static func quotaUpdate(_ value: Any?, at date: Date) -> QuotaUpdate {
        guard let value else { return .unchanged }
        guard !(value is NSNull), let object = value as? [String: Any] else { return .unchanged }
        if object.isEmpty { return .clear }
        guard object.keys.contains("primary") || object.keys.contains("secondary") else { return .unchanged }
        var windows: [WindowQuota] = []
        for key in ["primary", "secondary"] {
            guard let slot = object[key], !(slot is NSNull) else { continue }
            guard let item = slot as? [String: Any], let percent = number(item["used_percent"]), (0...100).contains(percent) else { return .unchanged }
            let duration: Int?
            if let raw = item["window_minutes"], !(raw is NSNull) { guard let n = integer(raw), n > 0 else { return .unchanged }; duration = n } else { duration = nil }
            let reset: Date?
            if let raw = item["resets_at"], !(raw is NSNull) { guard let seconds = integer(raw), let value = Double(exactly: seconds), value <= 253402300799 else { return .unchanged }; reset = Date(timeIntervalSince1970: value) } else { reset = nil }
            windows.append(WindowQuota(minutes: duration ?? 0, usedPercent: percent, resetsAt: reset, fetchedAt: date))
        }
        if windows.count == 2, windows[0].minutes > 0, windows[1].minutes > 0, windows[0].minutes == windows[1].minutes { return .unchanged }
        let five = windows.filter { $0.minutes == 300 }.only
        let seven = windows.filter { $0.minutes == 10080 }.only
        let record = Record(date: date, input: 0, output: 0, total: 0, five: five, seven: seven, isRate: true)
        return .replace(record)
    }

    private static func resolveRate(_ updates: [(Date, QuotaUpdate)], now: Date) -> (record: Record?, date: Date?) {
        var state = QuotaState.absent
        var latestDate: Date?
        for (date, update) in updates.enumerated().sorted(by: { lhs, rhs in lhs.element.0 == rhs.element.0 ? lhs.offset < rhs.offset : lhs.element.0 < rhs.element.0 }).map(\.element) {
            switch update {
            case .unchanged: break
            case .clear: state = .absent; latestDate = date
            case .replace(let record): state = .value(record); latestDate = date
            }
        }
        if case .value(let value) = state { return (value, latestDate) }
        return (nil, latestDate)
    }

    private static func completedTurns(in events: [ParsedEvent], now: Date) -> LocalTurnSummary? {
        var result: [LocalTurnSummary] = []
        for (startIndex, start) in events.enumerated() where start.type == "task_started" {
            guard let id = start.turnID, !id.isEmpty else { continue }
            var activeIDs: [String] = []
            for event in events[..<startIndex] {
                if event.type == "task_started", let activeID = event.turnID { activeIDs.append(activeID) }
                if event.type == "task_complete", let completedID = event.turnID,
                   let index = activeIDs.lastIndex(of: completedID) { activeIDs.remove(at: index) }
                if event.type == "turn_aborted" {
                    if let abortedID = event.turnID, let index = activeIDs.lastIndex(of: abortedID) { activeIDs.remove(at: index) }
                    else if event.turnID == nil { activeIDs.removeAll() }
                }
            }
            guard activeIDs.isEmpty else { continue }
            let completes = events.enumerated().filter { $0.element.type == "task_complete" && $0.element.turnID == id && $0.offset > startIndex }
            guard let (endIndex, complete) = completes.first else { continue }
            // Reused identifiers and overlapping turns make token attribution ambiguous.
            guard !events.enumerated().contains(where: { $0.offset > startIndex && $0.offset < endIndex && $0.element.type == "task_started" }) else { continue }
            guard !events.enumerated().contains(where: { $0.offset > startIndex && $0.offset < endIndex && $0.element.type == "task_complete" && $0.element.turnID != id }) else { continue }
            guard !events[startIndex..<endIndex].contains(where: { $0.type == "turn_aborted" && ($0.turnID == nil || $0.turnID == id) }) else { continue }
            guard !events[startIndex...endIndex].contains(where: \.invalidLifecycleTimestamp) else { continue }
            let intervalDates = events[startIndex...endIndex].map(\.date)
            guard zip(intervalDates, intervalDates.dropFirst()).allSatisfy({ $0 <= $1 }) else { continue }
            let earlierStarts = events[..<startIndex].filter { $0.type == "task_started" && $0.turnID == id }
            guard earlierStarts.isEmpty else { continue }
            guard !events.enumerated().contains(where: { $0.offset > endIndex && $0.element.type == "task_started" && $0.element.turnID == id }) else { continue }
            var durationMS: Double?
            if let duration = complete.duration { durationMS = duration }
            else { durationMS = complete.date.timeIntervalSince(start.date) * 1000 }
            guard let durationMS, durationMS.isFinite, durationMS >= 100 else { continue }
            let baselineEvents = events[..<startIndex].filter {
                $0.type == "token_count" && $0.hasCumulativePayload
            }
            guard let baseline = baselineEvents.last, !baseline.invalidLifecycleTimestamp,
                  baseline.date <= start.date, let baselineTotal = baseline.totalTokens,
                  let baselineOutput = baseline.outputTokens else { continue }
            let inTurn = events[(startIndex + 1)..<endIndex].filter { $0.type == "token_count" && $0.hasCumulativePayload }
            guard !inTurn.isEmpty, inTurn.allSatisfy({ !$0.invalidLifecycleTimestamp && $0.totalTokens != nil && $0.outputTokens != nil }) else { continue }
            let totals = inTurn.compactMap(\.totalTokens), outputs = inTurn.compactMap(\.outputTokens)
            guard let lastTotal = totals.last, lastTotal >= baselineTotal, totals.first! >= baselineTotal,
                  let lastOutput = outputs.last, lastOutput >= baselineOutput, outputs.first! >= baselineOutput,
                  zip(totals, totals.dropFirst()).allSatisfy({ $0 <= $1 }),
                  zip(outputs, outputs.dropFirst()).allSatisfy({ $0 <= $1 }) else { continue }
            let duration = complete.duration ?? complete.date.timeIntervalSince(start.date) * 1000
            guard duration.isFinite, duration >= 100 else { continue }
            let summary = LocalTurnSummary(outputTokens: lastOutput - baselineOutput,
                durationSeconds: duration / 1000, completedAt: complete.date)
            if complete.date <= now { result.append(summary) }
        }
        return result.max(by: { $0.completedAt < $1.completedAt })
    }

    private static func sessionSource(_ raw: Any?) -> (String?, String?) {
        guard let raw else { return (nil, nil) }
        if let value = raw as? String { return (value, nil) }
        guard let object = raw as? [String: Any], object.count == 1,
              let nested = object["subagent"] else { return ("<invalid>", nil) }
        if let kind = nested as? String, ["review", "compact", "memory_consolidation"].contains(kind) {
            return ("subagent_\(kind)", kind)
        }
        if let value = nested as? [String: Any], value.count == 1, let details = value["thread_spawn"] as? [String: Any],
           validThreadSpawn(details) { return ("subagent_thread_spawn", "thread_spawn") }
        return ("<invalid>", nil)
    }
    private static func isKnownSubagent(source: String?, subagentKind: String?, threadSource: String?, payload: [String: Any]) -> Bool {
        _ = source; _ = threadSource; _ = payload
        return ["review", "compact", "memory_consolidation", "thread_spawn"].contains(subagentKind ?? "")
    }
    private static func validThreadSpawn(_ object: [String: Any]) -> Bool {
        guard let parent = object["parent_thread_id"] as? String, normalizeUUID(parent) != nil,
              let depth = object["depth"] as? NSNumber, CFGetTypeID(depth) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: depth.objCType)), Int32(depth.stringValue) != nil else { return false }
        return true
    }
    private static func hasMalformedLineage(_ payload: [String: Any]) -> Bool {
        if payload["subagent"] != nil { return true }
        for key in ["forked_from_id", "parent_thread_id"] where payload[key] != nil && !(payload[key] is NSNull) {
            guard let value = payload[key] as? String, normalizeUUID(value) != nil else { return true }
        }
        if let raw = payload["subagent_history_start_ordinal"], !(raw is NSNull), uint(raw) == nil { return true }
        if let raw = payload["history_base"], !(raw is NSNull) {
            guard let base = raw as? [String: Any], let id = base["thread_id"] as? String,
                  normalizeUUID(id) != nil, uint(base["end_ordinal_exclusive"]) != nil,
                  uint(base["end_byte_offset"]) != nil else { return true }
        }
        if payload["source"] != nil, sessionSource(payload["source"]).0 == "<invalid>" { return true }
        return false
    }
    private static func isTopRootSource(_ source: String?) -> Bool { ["cli", "vscode", "exec", "mcp"].contains(source ?? "") }
    private static func normalizeUUID(_ value: String) -> String? {
        guard value.utf8.count <= maxIdentityBytes else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard uuidPattern.firstMatch(in: value, range: range) != nil, UUID(uuidString: value) != nil else { return nil }
        return value.lowercased()
    }
    private static func uint(_ value: Any?) -> UInt64? {
        guard let n = integer(value), let u = UInt64(exactly: n) else { return nil }; return u
    }
    private static func isMonotonic(_ values: [Int]) -> Bool { zip(values, values.dropFirst()).allSatisfy { $0 <= $1 } }
    private static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue >= 0 else { return nil }
        let decimal = n.decimalValue
        var rounded = Decimal()
        var copy = decimal
        NSDecimalRound(&rounded, &copy, 0, .plain)
        guard rounded == decimal else { return nil }
        let type = String(cString: n.objCType)
        guard let result = Int(n.stringValue), result >= 0 else { return nil }
        if ["f", "d"].contains(type), Double(result) != n.doubleValue { return nil }
        return result
    }
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }; return n.doubleValue
    }
    private static func parseDate(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        return fractionalISOFormatter.date(from: raw) ?? isoFormatter.date(from: raw)
    }
    private static func window(_ value: Any?, minutes: Int, now: Date, at date: Date) -> WindowQuota? {
        guard let object = value as? [String: Any], integer(object["window_minutes"]) == minutes,
              let percent = number(object["used_percent"]), (0...100).contains(percent) else { return nil }
        let reset = integer(object["resets_at"]).flatMap { Date(timeIntervalSince1970: Double($0)) }
        _ = now
        return WindowQuota(minutes: minutes, usedPercent: percent, resetsAt: reset, fetchedAt: date)
    }
    private static func completedTurns(in events: [ParsedEvent]) -> [LocalTurnSummary] { completedTurns(in: events, now: .distantFuture).map { [$0] } ?? [] }
    private static func openRelative(_ rootFD: Int32, _ path: String) -> Int32 {
        let parts = path.split(separator: "/").map(String.init); guard let leaf = parts.last else { return -1 }
        var current = dup(rootFD); guard current >= 0 else { return -1 }
        for component in parts.dropLast() {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW); close(current)
            guard next >= 0 else { return -1 }; current = next
        }
        let fd = openat(current, leaf, O_RDONLY | O_NOFOLLOW); close(current); return fd
    }
    private static func openDirectoryRelative(_ rootFD: Int32, _ path: String) -> Int32 {
        let parts = path.split(separator: "/").map(String.init); var current = dup(rootFD); guard current >= 0 else { return -1 }
        for component in parts { let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW); close(current); guard next >= 0 else { return -1 }; current = next }
        return current
    }
    private static func isContained(fd: Int32, rootFD: Int32) -> Bool {
        var pathBuffer = [CChar](repeating: 0, count: Int(PATH_MAX)); var rootBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let p = fcntl(fd, F_GETPATH, &pathBuffer), r = fcntl(rootFD, F_GETPATH, &rootBuffer)
        guard p == 0, r == 0 else { return false }
        let path = String(cString: pathBuffer), root = String(cString: rootBuffer)
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

private extension Data {
    func fullContentHashIfComplete(fileSize: Int) -> String? {
        guard count == fileSize else { return nil }
        return SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
private extension Array { var only: Element? { count == 1 ? first : nil } }
