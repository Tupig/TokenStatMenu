import Foundation
import CoreFoundation
import Darwin
import CryptoKit

public enum LocalCacheInput: Equatable, Sendable {
    case value(Int)
    case notReported
    case invalid
}

public enum LocalCacheAggregateState: Equatable, Sendable {
    case complete
    case partial
    case missing
    case invalid
}

public struct LocalCacheCoverage: Equatable, Sendable {
    public let state: LocalCacheAggregateState
    public let baseRows: Int
    public let cacheKnownRows: Int
    public let cacheMissingRows: Int
    public let cacheInvalidRows: Int
    public let cachedInputTokens: Int?
    public let uncachedInputTokens: Int?
    public let matchedInputTokens: Int?
    public let matchedCachedInputTokens: Int?
    public let hitRate: Double?

    public init(state: LocalCacheAggregateState = .missing, baseRows: Int = 0,
                cacheKnownRows: Int = 0, cacheMissingRows: Int = 0,
                cacheInvalidRows: Int = 0, cachedInputTokens: Int? = nil,
                uncachedInputTokens: Int? = nil, matchedInputTokens: Int? = nil,
                matchedCachedInputTokens: Int? = nil, hitRate: Double? = nil) {
        self.state = state; self.baseRows = baseRows; self.cacheKnownRows = cacheKnownRows
        self.cacheMissingRows = cacheMissingRows; self.cacheInvalidRows = cacheInvalidRows
        self.cachedInputTokens = cachedInputTokens; self.uncachedInputTokens = uncachedInputTokens
        self.matchedInputTokens = matchedInputTokens; self.matchedCachedInputTokens = matchedCachedInputTokens
        self.hitRate = hitRate
    }
}

public struct LocalCodexUsageDetail: Equatable, Sendable {
    public let input: Int?
    public let output: Int?
    public let total: Int?
    public let cache: LocalCacheInput
    public var uncachedInput: Int? {
        guard let input, case .value(let cached) = cache, cached >= 0, cached <= input else { return nil }
        return input - cached
    }

    public init(input: Int?, output: Int?, total: Int?, cache: LocalCacheInput = .notReported) {
        self.input = input; self.output = output; self.total = total; self.cache = cache
    }
}

public enum LocalThreadLineage: Equatable, Sendable {
    case root
    case subagent
    case fork
    case unknown
}

public enum LocalCodexSourceKind: Equatable, Sendable {
    case codexSessions
}

public struct LocalCodexTurnDetail: Equatable, Sendable {
    public let opaqueKey: UInt64
    public let ordinal: Int
    public let usage: LocalCodexUsageDetail
    public let durationSeconds: Double?
    public let completedAt: Date
    public var outputTPS: Double? {
        guard let durationSeconds, durationSeconds > 0, durationSeconds.isFinite,
              let output = usage.output else { return nil }
        return Double(output) / durationSeconds
    }

    public init(opaqueKey: UInt64, ordinal: Int, usage: LocalCodexUsageDetail,
                durationSeconds: Double?, completedAt: Date) {
        self.opaqueKey = opaqueKey; self.ordinal = ordinal; self.usage = usage
        self.durationSeconds = durationSeconds; self.completedAt = completedAt
    }
}

public struct LocalCodexThreadDetail: Equatable, Sendable {
    public let opaqueKey: UInt64
    public let ordinal: Int
    public let kind: LocalThreadLineage
    public let usage: LocalCodexUsageDetail
    public let turns: [LocalCodexTurnDetail]

    public init(opaqueKey: UInt64, ordinal: Int, kind: LocalThreadLineage,
                usage: LocalCodexUsageDetail, turns: [LocalCodexTurnDetail]) {
        self.opaqueKey = opaqueKey; self.ordinal = ordinal; self.kind = kind
        self.usage = usage; self.turns = turns
    }
}

public struct LocalCodexSnapshot: Equatable, Sendable {
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
    public let readAt: Date?
    public let details: [LocalCodexThreadDetail]
    public let cacheCoverage: LocalCacheCoverage
    public let detailLimited: Bool
    /// 五小时和七天窗口的最近上报时间。合并扫描时按此时间成对选取窗口，避免混用记录。
    public let quotaDate: Date?
    public var hasCompleteAccounting: Bool {
        knownThreadCount > 0 && unknownThreadCount == 0 && unidentifiedFileCount == 0 && !isLimited
    }

    public init(input: Int, output: Int, total: Int, sessionCount: Int, filesScanned: Int,
                isLimited: Bool, latestEventAt: Date?, fiveHour: WindowQuota?, sevenDay: WindowQuota?,
                knownThreadCount: Int = 0, unknownThreadCount: Int = 0, unidentifiedFileCount: Int = 0,
                subagentCount: Int = 0, forkCount: Int = 0, lastTurn: LocalTurnSummary? = nil,
                liveTurn: LocalLiveTurnSummary? = nil, readAt: Date? = nil,
                details: [LocalCodexThreadDetail] = [], cacheCoverage: LocalCacheCoverage = LocalCacheCoverage(),
                detailLimited: Bool = false, quotaDate: Date? = nil) {
        self.input = input; self.output = output; self.total = total; self.sessionCount = sessionCount
        self.filesScanned = filesScanned; self.isLimited = isLimited; self.latestEventAt = latestEventAt
        self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.lastTurn = lastTurn; self.liveTurn = liveTurn
        self.knownThreadCount = knownThreadCount; self.unknownThreadCount = unknownThreadCount
        self.unidentifiedFileCount = unidentifiedFileCount; self.subagentCount = subagentCount; self.forkCount = forkCount
        self.readAt = readAt; self.details = details; self.cacheCoverage = cacheCoverage; self.detailLimited = detailLimited
        self.quotaDate = quotaDate
    }
}

public struct LocalTurnSummary: Equatable, Sendable {
    public let outputTokens: Int
    public let durationSeconds: Double
    public let completedAt: Date
    public var outputTPS: Double { Double(outputTokens) / durationSeconds }
    public init(outputTokens: Int, durationSeconds: Double, completedAt: Date) {
        self.outputTokens = outputTokens; self.durationSeconds = durationSeconds; self.completedAt = completedAt
    }
}

/// 根据活跃 Codex 任务最近两次累计 `token_count` 事件计算短时速率。
/// 记录停止更新后即过期，与已完成轮次的均速分开保存。
public struct LocalLiveTurnSummary: Equatable, Sendable {
    public let inputTPS: Double
    public let outputTPS: Double
    public let observedAt: Date

    public init(inputTPS: Double, outputTPS: Double, observedAt: Date) {
        self.inputTPS = inputTPS; self.outputTPS = outputTPS; self.observedAt = observedAt
    }
}

/// 当前 Codex 提供商与 Seasun Token Hub 的关联。
/// 源站由调用方验证，不保留在公开状态中。
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

/// 本地扫描调度：按上次完成时间计时，用代次区分已失效的扫描。
public struct LocalRefreshScheduler {
    private(set) public var generation = 0
    private var inFlight: Int?
    private var nextDueMonotonic: TimeInterval = -.infinity
    private var legacyNextDue: Date = .distantPast
    public init() {}
    public mutating func begin(now: Date) -> Int? {
        guard inFlight == nil, now >= legacyNextDue else { return nil }
        inFlight = generation
        return generation
    }
    @discardableResult public mutating func complete(generation token: Int, now: Date) -> Bool {
        guard inFlight == token, generation == token else { return false }
        inFlight = nil; legacyNextDue = now.addingTimeInterval(5)
        return true
    }
    public mutating func begin(monotonicNow: TimeInterval) -> Int? {
        guard monotonicNow.isFinite, inFlight == nil, monotonicNow >= nextDueMonotonic else { return nil }
        inFlight = generation
        return generation
    }
    @discardableResult public mutating func complete(generation token: Int, monotonicNow: TimeInterval) -> Bool {
        guard monotonicNow.isFinite, inFlight == token, generation == token else { return false }
        inFlight = nil
        nextDueMonotonic = monotonicNow + 5
        return true
    }
    @discardableResult public mutating func invalidate() -> Int {
        generation += 1; inFlight = nil
        nextDueMonotonic = -.infinity; legacyNextDue = .distantPast
        return generation
    }
}

/// 限量读取 Codex 用量记录；无法判断的身份与派生关系保持未知。
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

    private struct Candidate { let name: String; let modified: Date; let signature: FileSignature }
    fileprivate struct Record {
        let date: Date; let input: Int; let output: Int; let total: Int
        let five: WindowQuota?; let seven: WindowQuota?; let isRate: Bool
        let cache: LocalCacheInput
        init(date: Date, input: Int, output: Int, total: Int, five: WindowQuota?, seven: WindowQuota?,
             isRate: Bool, cache: LocalCacheInput = .notReported) {
            self.date = date; self.input = input; self.output = output; self.total = total
            self.five = five; self.seven = seven; self.isRate = isRate; self.cache = cache
        }
    }
    fileprivate struct FileSignature: Hashable {
        let device: UInt64; let inode: UInt64; let size: Int64
        let mtimeSec: Int64; let mtimeNSec: Int64; let ctimeSec: Int64; let ctimeNSec: Int64
        init(_ st: stat) {
            device = UInt64(st.st_dev); inode = UInt64(st.st_ino); size = Int64(st.st_size)
            mtimeSec = Int64(st.st_mtimespec.tv_sec); mtimeNSec = Int64(st.st_mtimespec.tv_nsec)
            ctimeSec = Int64(st.st_ctimespec.tv_sec); ctimeNSec = Int64(st.st_ctimespec.tv_nsec)
        }
    }
    /// 文件的物理身份。硬链接的设备和 inode 不变，大小和时间戳可在扫描间发生变化。
    private struct FileIdentity: Hashable {
        let device: UInt64; let inode: UInt64
        init(_ st: stat) { device = UInt64(st.st_dev); inode = UInt64(st.st_ino) }
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
    fileprivate struct TurnEvidence {
        let completedAt: Date; let outputTokens: Int; let durationSeconds: Double
        let input: Int?; let output: Int; let total: Int; let cache: LocalCacheInput
        let sourceOrdinal: Int; let stableKey: String
    }
    fileprivate struct FileSummary {
        let identity: String?; let lineage: Lineage; let isFork: Bool; let sourceKnownTop: Bool
        let contribution: Record?; let rate: Record?; let quotaDate: Date?; let turnEvidence: [TurnEvidence]
        let turn: LocalTurnSummary?; let turnEvidenceTruncated: Bool
        let live: LocalLiveTurnSummary?
        let latestEventAt: Date?; let tailLimited: Bool; let headComplete: Bool; let hasFutureTurn: Bool
        let contentHash: String?; let signature: FileSignature
    }
    private struct DetailCandidate {
        let summary: FileSummary
        let sourceOrder: Int
    }
    private struct TurnCandidate {
        let detailIndex: Int
        let evidence: TurnEvidence
        let sourceOrder: Int
        let threadIdentity: String
    }

    fileprivate enum OpaqueIdentity: Hashable {
        case thread(String)
        case turn(thread: String, key: String)
    }

    fileprivate struct OpaqueMap {
        var values: [OpaqueIdentity: UInt64] = [:]
        var next: UInt64 = 1

        mutating func key(for identity: OpaqueIdentity) -> UInt64 {
            if let existing = values[identity] { return existing }
            let allocated = next == 0 ? 1 : next
            values[identity] = allocated
            next = allocated == UInt64.max ? 1 : allocated + 1
            return allocated
        }

        mutating func retain(_ identities: Set<OpaqueIdentity>) {
            values = values.filter { identities.contains($0.key) }
        }

        mutating func clear() {
            values.removeAll(keepingCapacity: false)
        }
    }
    fileprivate struct CachedFileSummary { let summary: FileSummary; let evaluatedAt: Date }
    public final class Cache {
        public struct Diagnostics: Equatable, Sendable {
            public fileprivate(set) var bytesRead = 0; public fileprivate(set) var parsedFiles = 0
            public fileprivate(set) var cacheHits = 0; public fileprivate(set) var safeOpens = 0
        }
        public private(set) var diagnostics = Diagnostics()
        public var entryCount: Int { entries.count }
        fileprivate var entries: [FileSignature: CachedFileSummary] = [:]
        fileprivate var rootIdentity: FileSignature?
        fileprivate var routeFingerprint: String?
        fileprivate var lastScanAt: Date?
        fileprivate var opaqueMap = OpaqueMap()
        fileprivate var beforePostReadValidation: (() -> Void)?
        public init() {}
        init(beforePostReadValidation: @escaping () -> Void) { self.beforePostReadValidation = beforePostReadValidation }
        fileprivate func resetDiagnostics() { diagnostics = Diagnostics() }
        fileprivate func opened() { diagnostics.safeOpens += 1 }
        fileprivate func hit() { diagnostics.cacheHits += 1 }
        fileprivate func read(_ count: Int) { diagnostics.bytesRead += count }
        fileprivate func parsed() { diagnostics.parsedFiles += 1 }
        fileprivate func clearOpaqueState() { opaqueMap.clear() }
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
        try scanDirectory(directory: directory, now: now, cache: cache, routeContext: routeContext).snapshot
    }

    /// 读取活跃会话目录及同级的 `archived_sessions` 归档目录。
    ///
    /// 已归档记录可能不再位于 `sessions/`，因此两个目录都需要扫描。
    /// 归档目录可选，缺失时不报错，也不据此认定用量为零。
    public static func scanCodexHome(sessions directory: URL, now: Date = Date(), cache: Cache? = nil,
                                     archiveCache: Cache? = nil,
                                     routeContext: LocalCodexRouteContext? = nil) throws -> LocalCodexSnapshot {
        let active = try scanDirectory(directory: directory, now: now, cache: cache,
                                       routeContext: routeContext)
        let archive = directory.deletingLastPathComponent().appendingPathComponent("archived_sessions", isDirectory: true)
        var archiveIsDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: archive.path, isDirectory: &archiveIsDirectory),
              archiveIsDirectory.boolValue else { return active.snapshot }
        // 按物理文件和逻辑线程排除归档副本，避免硬链接或复制文件重复计数。
        // 归档使用独立缓存，未变化时不重复读取。
        let archived = try scanDirectory(directory: archive, now: now, cache: archiveCache,
                                         routeContext: routeContext,
                                         excluding: active.identities,
                                         excludingThreads: active.threadIdentities)
        return merge(active.snapshot, archived.snapshot)
    }

    /// 合并两个同级目录的扫描结果。
    ///
    /// 主目录的 `opaqueKey` 保持不变，归档键移入不重叠的高位范围，保持 SwiftUI 身份稳定。
    /// 不按用量数值合并明细：不同会话可能恰好有相同用量。
    static func merge(_ primary: LocalCodexSnapshot, _ extra: LocalCodexSnapshot) -> LocalCodexSnapshot {
        // 键由较小的计数器分配，偏移后两组键不重叠，无需每次刷新都重新编号。
        let extraKeyOffset: UInt64 = 1 << 32
        func shifted(_ detail: LocalCodexThreadDetail) -> LocalCodexThreadDetail {
            assert(detail.opaqueKey < extraKeyOffset, "active directory keys must stay below the archive offset")
            let turns = detail.turns.map { turn in
                assert(turn.opaqueKey < extraKeyOffset, "active turn keys must stay below the archive offset")
                return LocalCodexTurnDetail(opaqueKey: turn.opaqueKey &+ extraKeyOffset,
                    ordinal: turn.ordinal, usage: turn.usage,
                    durationSeconds: turn.durationSeconds, completedAt: turn.completedAt)
            }
            return LocalCodexThreadDetail(opaqueKey: detail.opaqueKey &+ extraKeyOffset,
                ordinal: detail.ordinal + primary.details.count, kind: detail.kind,
                usage: detail.usage, turns: turns)
        }
        var details = primary.details
        details.append(contentsOf: extra.details.map(shifted))
        var overflowLimited = false
        func add(_ left: Int, _ right: Int) -> Int {
            let (sum, overflow) = left.addingReportingOverflow(right)
            if overflow { overflowLimited = true }
            return overflow ? Int.max : sum
        }
        let latest = [primary.latestEventAt, extra.latestEventAt].compactMap { $0 }.max()
        // 多个会话的实时速率相加，最旧分量过期时整体过期，与单目录扫描一致。
        let live: LocalLiveTurnSummary? = {
            switch (primary.liveTurn, extra.liveTurn) {
            case let (p?, e?):
                return LocalLiveTurnSummary(inputTPS: p.inputTPS + e.inputTPS,
                    outputTPS: p.outputTPS + e.outputTPS,
                    observedAt: min(p.observedAt, e.observedAt))
            case let (p?, nil): return p
            case let (nil, e?): return e
            case (nil, nil): return nil
            }
        }()
        let turn = [primary.lastTurn, extra.lastTurn].compactMap { $0 }.max { $0.completedAt < $1.completedAt }
        // 限额窗口成对保留，整条选取较新的记录。
        let rateWinner: LocalCodexSnapshot = {
            switch (primary.quotaDate, extra.quotaDate) {
            case let (p?, e?): return p >= e ? primary : extra
            case (nil, .some): return extra
            case (.some, nil), (nil, nil): return primary
            }
        }()
        return LocalCodexSnapshot(
            input: add(primary.input, extra.input),
            output: add(primary.output, extra.output),
            total: add(primary.total, extra.total),
            sessionCount: add(primary.sessionCount, extra.sessionCount),
            filesScanned: add(primary.filesScanned, extra.filesScanned),
            isLimited: primary.isLimited || extra.isLimited || overflowLimited,
            latestEventAt: latest,
            fiveHour: rateWinner.fiveHour,
            sevenDay: rateWinner.sevenDay,
            knownThreadCount: add(primary.knownThreadCount, extra.knownThreadCount),
            unknownThreadCount: add(primary.unknownThreadCount, extra.unknownThreadCount),
            unidentifiedFileCount: add(primary.unidentifiedFileCount, extra.unidentifiedFileCount),
            subagentCount: add(primary.subagentCount, extra.subagentCount),
            forkCount: add(primary.forkCount, extra.forkCount),
            lastTurn: turn,
            liveTurn: live,
            readAt: primary.readAt ?? extra.readAt,
            details: details,
            cacheCoverage: aggregateCacheCoverage(details.map(\.usage)),
            detailLimited: primary.detailLimited || extra.detailLimited)
    }

    /// 扫描一个目录并返回实际使用的文件身份。
    ///
    /// `excluding` 用于跳过活跃目录已读取的文件，避免同一硬链接被计入两次。
    private static func scanDirectory(directory: URL, now: Date, cache: Cache?,
                                      routeContext: LocalCodexRouteContext?,
                                      excluding: Set<FileIdentity> = [],
                                      excludingThreads: Set<String> = []) throws
        -> (snapshot: LocalCodexSnapshot, identities: Set<FileIdentity>, threadIdentities: Set<String>) {
        cache?.resetDiagnostics()
        func empty(limited: Bool = false) -> (snapshot: LocalCodexSnapshot, identities: Set<FileIdentity>, threadIdentities: Set<String>) {
            (LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0, filesScanned: 0, isLimited: limited, latestEventAt: nil, fiveHour: nil, sevenDay: nil, readAt: now), [], [])
        }
        var ephemeralOpaqueMap = OpaqueMap()
        if let cache {
            if let previous = cache.lastScanAt, now < previous {
                cache.entries.removeAll(); cache.rootIdentity = nil; cache.clearOpaqueState()
            }
            cache.lastScanAt = now
        }
        if let cache, cache.routeFingerprint != routeContext?.fingerprint {
            cache.entries.removeAll(); cache.clearOpaqueState(); cache.routeFingerprint = routeContext?.fingerprint
        }
        var st = stat()
        guard lstat(directory.path, &st) == 0 else { cache?.entries.removeAll(); cache?.rootIdentity = nil; cache?.clearOpaqueState(); return empty() }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { cache?.entries.removeAll(); cache?.rootIdentity = nil; cache?.clearOpaqueState(); return empty() }
        let rootFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        // 目录存在但打不开表示读取不完整，不能按空目录处理。
        guard rootFD >= 0 else { cache?.entries.removeAll(); cache?.rootIdentity = nil; cache?.clearOpaqueState(); return empty(limited: true) }
        defer { close(rootFD) }
        var opened = stat()
        guard fstat(rootFD, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFDIR else { cache?.entries.removeAll(); cache?.rootIdentity = nil; cache?.clearOpaqueState(); return empty(limited: true) }
        let rootSignature = FileSignature(opened)
        if cache?.rootIdentity != rootSignature { cache?.entries.removeAll(); cache?.clearOpaqueState(); cache?.rootIdentity = rootSignature }

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
                let identity = FileIdentity(fst)
                // 同级目录已读取该 inode，不重复计数。
                if excluding.contains(identity) { continue }
                candidates.append(Candidate(name: name,
                    modified: Date(timeIntervalSince1970: Double(fst.st_mtimespec.tv_sec)),
                    signature: FileSignature(fst)))
            }
            closedir(listing)
        }
        if entries >= maxEntries { limited = true; discoveryLimited = true }
        candidates.sort { $0.modified == $1.modified ? $0.name < $1.name : $0.modified > $1.modified }
        if candidates.count > maxFiles { candidates = Array(candidates.prefix(maxFiles)); limited = true; discoveryLimited = true }

        var usedBytes = 0, filesScanned = 0, unidentified = 0, unsafeCandidate = false, coverageLimited = false
        var summaries: [FileSummary] = [], liveSignatures = Set<FileSignature>()
        // 仅排除已纳入摘要的文件；预算不足或读取失败时，归档副本仍可参与扫描。
        var usedIdentities = Set<FileIdentity>()
        for candidate in candidates {
            let fd = openRelative(rootFD, candidate.name); guard fd >= 0 else { unsafeCandidate = true; continue }
            defer { close(fd) }
            cache?.opened()
            var fst = stat(); guard fstat(fd, &fst) == 0, (fst.st_mode & S_IFMT) == S_IFREG, fst.st_size >= 0 else { unsafeCandidate = true; continue }
            guard isContained(fd: fd, rootFD: rootFD) else { unsafeCandidate = true; continue }
            let signature = FileSignature(fst)
            // 目录项可能在发现和打开之间被替换，按实际打开的 inode 重新检查。
            if excluding.contains(FileIdentity(fst)) { continue }
            liveSignatures.insert(signature)
            if let cache, let old = cache.entries.keys.first(where: { $0.device == signature.device && $0.inode == signature.inode && $0 != signature }) {
                let timestampChanged = old.mtimeSec != signature.mtimeSec || old.mtimeNSec != signature.mtimeNSec || old.ctimeSec != signature.ctimeSec || old.ctimeNSec != signature.ctimeNSec
                if timestampChanged {
                    cache.entries = cache.entries.filter { $0.key.device != signature.device || $0.key.inode != signature.inode }
                    cache.clearOpaqueState()
                }
            }
            if fst.st_size < 0 { unsafeCandidate = true; continue }
            // 时钟回拨后，旧结果可能落在未来，需重新解析而非复用缓存。
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
                    rate: cachedSummary.rate, quotaDate: cachedSummary.quotaDate,
                    turnEvidence: cachedSummary.hasFutureTurn ? [] : cachedSummary.turnEvidence,
                    turn: cachedSummary.hasFutureTurn ? nil : cachedSummary.turn,
                    turnEvidenceTruncated: cachedSummary.turnEvidenceTruncated, live: cachedLive,
                    latestEventAt: cachedSummary.latestEventAt,
                    tailLimited: cachedSummary.tailLimited, headComplete: cachedSummary.headComplete,
                    hasFutureTurn: cachedSummary.hasFutureTurn, contentHash: cachedSummary.contentHash, signature: cachedSummary.signature)
                summaries.append(refreshed); filesScanned += 1
                usedIdentities.insert(FileIdentity(fst))
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
            var after = stat(); guard fstat(fd, &after) == 0, FileSignature(after) == signature else { cache?.entries.removeValue(forKey: signature); cache?.clearOpaqueState(); unsafeCandidate = true; continue }
            cache?.parsed()
            let parsed = parseFile(bytes: bytes, size: size, now: now, signature: signature,
                                   routeContext: routeContext)
            // 同级目录已纳入同一逻辑线程，跳过 inode 不同的副本。
            if let threadID = parsed.identity, excludingThreads.contains(threadID) { continue }
            filesScanned += 1
            if parsed.identity == nil { unidentified += 1 }
            if parsed.tailLimited || !parsed.headComplete { limited = true; coverageLimited = true }
            summaries.append(parsed)
            usedIdentities.insert(FileIdentity(fst))
            if let cache, parsed.identity != nil, !parsed.hasFutureTurn {
                cache.entries[signature] = CachedFileSummary(summary: parsed, evaluatedAt: now)
                if cache.entries.count > maxFiles { cache.entries.removeValue(forKey: cache.entries.keys.first!) }
            } else {
                // 即使文件未变化，也需随时间推进重新判断未来的生命周期或计数器事件。
                cache?.entries.removeValue(forKey: signature)
            }
        }
        if let cache {
            let hadStaleEntry = cache.entries.keys.contains { !liveSignatures.contains($0) }
            cache.entries = cache.entries.filter { liveSignatures.contains($0.key) }
            if hadStaleEntry { cache.clearOpaqueState() }
        }
        _ = discoveryLimited

        // 相同 inode 是同一物理文件；相同 ID 仅在全部字节一致时才视为同一逻辑线程。
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
        var latestEvent: Date?
        var liveInputTPS = 0.0, liveOutputTPS = 0.0, latestLiveAt: Date?
        var detailCandidates: [DetailCandidate] = []
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
            if let sourceOrder = summaries.firstIndex(where: { $0.signature == summary.signature }) {
                // 身份可确认但派生关系未知时仍显示明细；基础用量未知，完整轮次可独立显示。
                detailCandidates.append(DetailCandidate(summary: summary, sourceOrder: sourceOrder))
            }
            if let event = summary.latestEventAt, latestEvent == nil || event > latestEvent! { latestEvent = event }
            if let live = summary.live, live.observedAt <= now {
                liveInputTPS += live.inputTPS; liveOutputTPS += live.outputTPS
                // 汇总按最旧分量的时间过期，新会话不能延长旧速率的有效期。
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
        let finalQuotaDate = quotaWinner?.0
        let liveTurn = latestLiveAt.map { LocalLiveTurnSummary(inputTPS: liveInputTPS,
            outputTPS: liveOutputTPS, observedAt: $0) }
        var opaqueMap = cache?.opaqueMap ?? ephemeralOpaqueMap
        var retainedOpaqueIdentities = Set<OpaqueIdentity>()
        var details: [LocalCodexThreadDetail] = []
        var turnCandidates: [TurnCandidate] = []
        var detailLimited = false
        func canonicalThreadKey(_ candidate: DetailCandidate) -> String {
            candidate.summary.identity ?? candidate.summary.contentHash ?? ""
        }
        func newer(_ lhs: TurnEvidence, _ lhsThread: String, _ rhs: TurnEvidence, _ rhsThread: String) -> Bool {
            if lhs.completedAt != rhs.completedAt { return lhs.completedAt > rhs.completedAt }
            if lhs.sourceOrdinal != rhs.sourceOrdinal { return lhs.sourceOrdinal > rhs.sourceOrdinal }
            if lhsThread != rhsThread { return lhsThread < rhsThread }
            return lhs.stableKey < rhs.stableKey
        }
        detailCandidates.sort {
            switch ($0.summary.turn, $1.summary.turn) {
            case let (lhs?, rhs?):
                if lhs.completedAt != rhs.completedAt { return lhs.completedAt > rhs.completedAt }
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
            let lhsKey = canonicalThreadKey($0), rhsKey = canonicalThreadKey($1)
            if lhsKey != rhsKey { return lhsKey < rhsKey }
            return $0.sourceOrder < $1.sourceOrder
        }
        for (detailIndex, candidate) in detailCandidates.enumerated() {
            let summary = candidate.summary
            guard let identity = summary.identity else { continue }
            let threadKey = opaqueMap.key(for: .thread(identity))
            retainedOpaqueIdentities.insert(.thread(identity))
            let usage = summary.contribution.map {
                LocalCodexUsageDetail(input: $0.input, output: $0.output, total: $0.total, cache: $0.cache)
            } ?? LocalCodexUsageDetail(input: nil, output: nil, total: nil, cache: .notReported)
            if summary.turnEvidenceTruncated { detailLimited = true }
            for evidence in summary.turnEvidence where evidence.completedAt <= now {
                turnCandidates.append(TurnCandidate(detailIndex: detailIndex, evidence: evidence,
                    sourceOrder: candidate.sourceOrder, threadIdentity: identity))
            }
            details.append(LocalCodexThreadDetail(opaqueKey: threadKey, ordinal: detailIndex + 1,
                kind: publicLineage(summary.lineage), usage: usage, turns: []))
        }
        if turnCandidates.count > 128 { detailLimited = true }
        let newestFirstTurns = turnCandidates.sorted {
            newer($0.evidence, $0.threadIdentity, $1.evidence, $1.threadIdentity)
        }
        let visibleTurns = newestFirstTurns.count > 128 ? Array(newestFirstTurns.prefix(128)) : newestFirstTurns
        var visibleByDetail: [[TurnCandidate]] = Array(repeating: [], count: details.count)
        for candidate in visibleTurns {
            let turnIdentity = OpaqueIdentity.turn(thread: candidate.threadIdentity, key: candidate.evidence.stableKey)
            _ = opaqueMap.key(for: turnIdentity)
            retainedOpaqueIdentities.insert(turnIdentity)
            visibleByDetail[candidate.detailIndex].append(candidate)
        }
        for index in details.indices {
            let old = details[index]
            let ordered = visibleByDetail[index].sorted {
                if $0.evidence.completedAt != $1.evidence.completedAt {
                    return $0.evidence.completedAt < $1.evidence.completedAt
                }
                if $0.evidence.sourceOrdinal != $1.evidence.sourceOrdinal {
                    return $0.evidence.sourceOrdinal < $1.evidence.sourceOrdinal
                }
                return $0.evidence.stableKey < $1.evidence.stableKey
            }
            let numbered = ordered.enumerated().map { offset, candidate in
                let turnIdentity = OpaqueIdentity.turn(thread: candidate.threadIdentity, key: candidate.evidence.stableKey)
                let turnKey = opaqueMap.key(for: turnIdentity)
                let usage = LocalCodexUsageDetail(input: candidate.evidence.input,
                    output: candidate.evidence.output, total: candidate.evidence.total, cache: candidate.evidence.cache)
                return LocalCodexTurnDetail(opaqueKey: turnKey, ordinal: offset + 1,
                    usage: usage, durationSeconds: candidate.evidence.durationSeconds,
                    completedAt: candidate.evidence.completedAt)
            }
            details[index] = LocalCodexThreadDetail(opaqueKey: old.opaqueKey, ordinal: old.ordinal,
                kind: old.kind, usage: old.usage,
                turns: numbered)
        }
        let reorderedDetailIndices = details.indices.sorted {
            let lhsHasVisibleTurns = !visibleByDetail[$0].isEmpty
            let rhsHasVisibleTurns = !visibleByDetail[$1].isEmpty
            if lhsHasVisibleTurns != rhsHasVisibleTurns { return lhsHasVisibleTurns }
            if lhsHasVisibleTurns { return $0 < $1 }
            let lhsIdentity = canonicalThreadKey(detailCandidates[$0])
            let rhsIdentity = canonicalThreadKey(detailCandidates[$1])
            if lhsIdentity != rhsIdentity { return lhsIdentity < rhsIdentity }
            return $0 < $1
        }
        let currentDetails = details
        details = reorderedDetailIndices.enumerated().map { ordinal, index in
            let detail = currentDetails[index]
            return LocalCodexThreadDetail(opaqueKey: detail.opaqueKey, ordinal: ordinal + 1,
                kind: detail.kind, usage: detail.usage, turns: detail.turns)
        }
        let latestTurnEvidence = detailCandidates.compactMap { candidate -> (TurnEvidence, String)? in
            guard let identity = candidate.summary.identity else { return nil }
            return candidate.summary.turnEvidence.filter { $0.completedAt <= now }
                .map { ($0, identity) }.max { !newer($0.0, $0.1, $1.0, $1.1) }
        }.max { !newer($0.0, $0.1, $1.0, $1.1) }?.0
        let latestTurn = latestTurnEvidence.map {
            LocalTurnSummary(outputTokens: $0.outputTokens, durationSeconds: $0.durationSeconds,
                completedAt: $0.completedAt)
        }
        opaqueMap.retain(retainedOpaqueIdentities)
        if let cache { cache.opaqueMap = opaqueMap } else { ephemeralOpaqueMap = opaqueMap }
        let cacheCoverage = aggregateCacheCoverage(details.map(\.usage))
        let threadIdentities = Set(summaries.compactMap(\.identity))
        return (LocalCodexSnapshot(input: input, output: output, total: total, sessionCount: topLevelCount,
            filesScanned: filesScanned, isLimited: limited || unsafeCandidate || coverageLimited, latestEventAt: latestEvent,
            fiveHour: finalRate?.five, sevenDay: finalRate?.seven, knownThreadCount: known.count,
            unknownThreadCount: unknownThreads, unidentifiedFileCount: unidentifiedCount,
            subagentCount: subagentCount, forkCount: forkCount, lastTurn: latestTurn, liveTurn: liveTurn,
            readAt: now, details: details, cacheCoverage: cacheCoverage, detailLimited: detailLimited,
            quotaDate: finalQuotaDate),
            usedIdentities, threadIdentities)
    }

    private static func publicLineage(_ lineage: Lineage) -> LocalThreadLineage {
        switch lineage {
        case .root: return .root
        case .subagent: return .subagent
        case .fork: return .fork
        case .unknown: return .unknown
        }
    }

    private static func aggregateCacheCoverage(_ usages: [LocalCodexUsageDetail]) -> LocalCacheCoverage {
        let base = usages.filter { $0.input != nil }
        var known = 0, missing = 0, invalid = 0
        var cached = 0, matchedInput = 0, matchedCached = 0
        for usage in base {
            switch usage.cache {
            case .value(let value):
                if let input = usage.input, value <= input {
                    let cacheSum = cached.addingReportingOverflow(value)
                    let matchInput = matchedInput.addingReportingOverflow(input)
                    let matchCache = matchedCached.addingReportingOverflow(value)
                    if cacheSum.overflow || matchInput.overflow || matchCache.overflow {
                        invalid += 1
                    } else {
                        known += 1
                        cached = cacheSum.partialValue; matchedInput = matchInput.partialValue; matchedCached = matchCache.partialValue
                    }
                } else { invalid += 1 }
            case .notReported: missing += 1
            case .invalid: invalid += 1
            }
        }
        let baseRows = base.count
        let state: LocalCacheAggregateState
        if baseRows == 0 { state = invalid > 0 ? .invalid : .missing }
        else if invalid == 0 && missing == 0 && known == baseRows { state = .complete }
        else if known > 0 { state = .partial }
        else if invalid > 0 { state = .invalid }
        else { state = .missing }
        guard state == .complete else {
            return LocalCacheCoverage(state: state, baseRows: baseRows, cacheKnownRows: known,
                cacheMissingRows: missing, cacheInvalidRows: invalid,
                matchedInputTokens: known > 0 ? matchedInput : nil,
                matchedCachedInputTokens: known > 0 ? matchedCached : nil)
        }
        var totalInput = 0
        for input in base.compactMap(\.input) {
            let sum = totalInput.addingReportingOverflow(input)
            if sum.overflow {
                return LocalCacheCoverage(state: .invalid, baseRows: baseRows, cacheKnownRows: known,
                    cacheMissingRows: missing, cacheInvalidRows: invalid + 1,
                    matchedInputTokens: matchedInput, matchedCachedInputTokens: matchedCached)
            }
            totalInput = sum.partialValue
        }
        let uncached = totalInput - cached
        let rate: Double? = matchedInput > 0 ? Double(matchedCached) / Double(matchedInput) : nil
        return LocalCacheCoverage(state: state, baseRows: baseRows, cacheKnownRows: known,
            cacheMissingRows: missing, cacheInvalidRows: invalid, cachedInputTokens: cached,
            uncachedInputTokens: uncached, matchedInputTokens: matchedInput,
            matchedCachedInputTokens: matchedCached, hitRate: rate)
    }

    private static func parseFile(bytes: Data, size: Int, now: Date, signature: FileSignature,
                                 routeContext: LocalCodexRouteContext?) -> FileSummary {
        let headLength = min(size, headLimit), tailLength = max(0, bytes.count - headLength)
        let head = bytes.prefix(headLength), tail = tailLength > 0 ? bytes.suffix(tailLength) : Data()
        let tailLimited = size > headLimit + tailLimit
        let wholeFileRead = size <= headLimit + tailLimit
        let headComplete = wholeFileRead || size <= headLimit || head.last == 10
        // `endsAtFileEnd` 表示读到 EOF，不要求文件以换行结尾。
        // 完整读取时末尾非空片段可作为记录，解析器负责判断 JSON 是否有效。
        let headLines = wholeFileRead ? completeLines(Data(bytes), startsAtFileStart: true, endsAtFileEnd: size <= bytes.count) : completeLines(Data(head), startsAtFileStart: true, endsAtFileEnd: false)
        let tailLines = !wholeFileRead && tailLength > 0 ? completeLines(Data(tail), startsAtFileStart: false, endsAtFileEnd: true) : []
        let headSlots = headLines.enumerated().map { parseLine($0.element, fallbackOrdinal: $0.offset) }
        let physicalRecordCountHead = headLines.count
        let tailOrdinalBase = size > headLimit + tailLimit ? -1 : physicalRecordCountHead
        let tailSlots = tailLines.enumerated().map { parseLine($0.element, fallbackOrdinal: tailOrdinalBase < 0 ? -1 : tailOrdinalBase + $0.offset) }
        let continuousRead = wholeFileRead
        let finalLineWithoutLF: Data.SubSequence? = bytes.last == 10 ? nil :
            bytes[(bytes.lastIndex(of: 10).map { bytes.index(after: $0) } ?? bytes.startIndex)...]
        // 末行没有 LF 但 JSON 有效时仍是完整记录；格式错误的片段则中断连续性。
        let hasIncompleteTailFragment: Bool = {
            guard let finalLineWithoutLF else { return false }
            return parseLine(finalLineWithoutLF, fallbackOrdinal: -1) == nil
        }()
        let identity: String?
        let firstPhysicalLine = completeLines(Data(bytes.prefix(headLength)), startsAtFileStart: true, endsAtFileEnd: size <= headLength).first
        if let first = firstPhysicalLine, !first.isEmpty, let object = try? JSONSerialization.jsonObject(with: Data(first)),
           let root = object as? [String: Any], root["type"] as? String == "session_meta",
           let id = (root["payload"] as? [String: Any])?["id"] as? String, let normalized = normalizeUUID(id) { identity = normalized }
        else { identity = nil }
        guard let identity else {
            return FileSummary(identity: nil, lineage: .unknown, isFork: false, sourceKnownTop: false, contribution: nil, rate: nil,
                quotaDate: nil, turnEvidence: [], turn: nil, turnEvidenceTruncated: false,
                live: nil, latestEventAt: nil, tailLimited: tailLimited, headComplete: headComplete, hasFutureTurn: false,
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
        let decoded = (wholeFileRead ? mappedHeadSlots : mappedHeadSlots + mappedTailSlots).compactMap { $0 }
        guard let firstMetaLine = firstPhysicalLine else { return FileSummary(identity: nil, lineage: .unknown, isFork: false, sourceKnownTop: false, contribution: nil, rate: nil, quotaDate: nil, turnEvidence: [], turn: nil, turnEvidenceTruncated: false, live: nil, latestEventAt: nil, tailLimited: tailLimited, headComplete: headComplete, hasFutureTurn: false, contentHash: bytes.fullContentHashIfComplete(fileSize: size), signature: signature) }
        let metadata = (try? JSONSerialization.jsonObject(with: Data(firstMetaLine))) as? [String: Any]
        let payload = metadata?["payload"] as? [String: Any] ?? [:]
        if let routeContext, !routeContext.accepts(payload["model_provider"] as? String) {
            return FileSummary(identity: nil, lineage: .unknown, isFork: false, sourceKnownTop: false,
                contribution: nil, rate: nil, quotaDate: nil, turnEvidence: [],
                turn: nil, turnEvidenceTruncated: false, live: nil, latestEventAt: nil,
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
        let forkHasCompleteLines = wholeFileRead && mappedHeadSlots.allSatisfy { $0 != nil } && !hasIncompleteTailFragment
        var contribution: Record? = nil
        if lineage == .root {
            if let lastToken, let usage = lastToken.usage,
               validCumulativeSequence(cumulativeTokenEvents, now: now), !hasFutureCounter,
               !hasIncompleteTailFragment, !hasBadLineAfterLatestCounter,
               (wholeFileRead || latestCounterInTail) {
                let cache = cacheChainState(cumulativeTokenEvents.compactMap(\.usage))
                contribution = Record(date: usage.date, input: usage.input, output: usage.output, total: usage.total,
                    five: usage.five, seven: usage.seven, isRate: usage.isRate, cache: cache)
            }
        } else if (lineage == .subagent || lineage == .fork), !hasHistoryBase, !hasFutureCounter, headComplete, !tailLimited,
                  continuousRead, forkHasCompleteLines, let delta = forkContribution(payload: payload, events: decoded) { contribution = delta }
        let rateEvents = tokenEvents.map { ($0.date, $0.quotaUpdate) }
        let resolvedQuota = resolveRate(rateEvents, now: now)
        let rate = resolvedQuota.record
        let turnSegments = observedLineSegments.flatMap { parsedSegments($0) }
        let allTurnEvidence = turnSegments.flatMap { completedTurnEvidence(in: $0, now: now) }
        let turnEvidenceTruncated = allTurnEvidence.count > 16
        let turnEvidence = allTurnEvidence.sorted {
            if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
            if $0.sourceOrdinal != $1.sourceOrdinal { return $0.sourceOrdinal > $1.sourceOrdinal }
            return $0.stableKey < $1.stableKey
        }.prefix(16).sorted {
            if $0.completedAt != $1.completedAt { return $0.completedAt < $1.completedAt }
            if $0.sourceOrdinal != $1.sourceOrdinal { return $0.sourceOrdinal < $1.sourceOrdinal }
            return $0.stableKey < $1.stableKey
        }
        let turn = allTurnEvidence.sorted {
            if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
            if $0.sourceOrdinal != $1.sourceOrdinal { return $0.sourceOrdinal > $1.sourceOrdinal }
            return $0.stableKey < $1.stableKey
        }.first.map { LocalTurnSummary(outputTokens: $0.outputTokens, durationSeconds: $0.durationSeconds, completedAt: $0.completedAt) }
        // 活跃任务的生命周期事件须位于末尾连续片段，不跨越损坏记录、未读中段或残缺尾部。
        let live: LocalLiveTurnSummary?
        if !hasIncompleteTailFragment, let finalSlots = observedLineSegments.last,
           finalSlots.last.flatMap({ $0 }) != nil,
           let finalSegment = parsedSegments(finalSlots).last {
            live = liveTurn(in: finalSegment, now: now)
        } else { live = nil }
        let latestUsageDate = validCounters.last?.date
        return FileSummary(identity: identity, lineage: lineage, isFork: isFork, sourceKnownTop: sourceKnownTop,
            contribution: contribution, rate: rate, quotaDate: resolvedQuota.date,
            turnEvidence: Array(turnEvidence), turn: turn, turnEvidenceTruncated: turnEvidenceTruncated,
            live: live, latestEventAt: latestUsageDate,
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
        // 序号从零开始，用于确认直到最后一次计数器事件的记录均已读取。
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
        let cache = cacheDeltaState(baseline: baseline, records: after.compactMap(\.usage))
        return Record(date: final.date, input: i, output: o, total: t, five: nil, seven: nil,
                      isRate: false, cache: cache)
    }

    private static func parseLine(_ line: Data.SubSequence, fallbackOrdinal: Int) -> ParsedEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)), let root = object as? [String: Any],
              let type = root["type"] as? String else { return nil }
        let payload = root["payload"] as? [String: Any] ?? [:]
        let parsedDate = parseDate(root["timestamp"])
        let date = parsedDate ?? .distantPast
        // 无效的事件封装与损坏 JSON 一样会中断连续性，避免遗漏生命周期边界。
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
            usage = Record(date: date, input: i, output: o, total: t, five: nil, seven: nil,
                           isRate: false, cache: cacheInput(cumulative["cached_input_tokens"], input: i))
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
        let invalidLifecycleTimestamp = ["task_started", "task_complete", "turn_aborted", "token_count"].contains(eventType) && parsedDate == nil
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
        // 末尾 LF 产生空的终止片段；非空末片段只有读到 EOF 时才算完整。
        // 头部未读到 EOF 时，只保留以换行结尾的记录。
        if let last = lines.last, last.isEmpty || !endsAtFileEnd { lines.removeLast() }
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

    /// 根据未结束任务和两次单调累计计数推导短时速率，尾部缺失或过期时为未知。
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
                    // 保留所有未结束任务的 ID，不能因关闭一个重叠任务就认定另一个可独立归因。
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
                // 先验证所有计数器再保留最后一对，避免正常尾部掩盖此前的重置。
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

    private static func completedTurnEvidence(in events: [ParsedEvent], now: Date) -> [TurnEvidence] {
        var result: [TurnEvidence] = []
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
            // 标识符复用或轮次重叠时无法明确 token 归属。
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
                  baseline.date <= start.date, let baselineUsage = baseline.usage,
                  let baselineTotal = baseline.totalTokens, let baselineOutput = baseline.outputTokens else { continue }
            let inTurn = events[(startIndex + 1)..<endIndex].filter { $0.type == "token_count" && $0.hasCumulativePayload }
            guard !inTurn.isEmpty, inTurn.allSatisfy({ !$0.invalidLifecycleTimestamp && $0.usage != nil && $0.totalTokens != nil && $0.outputTokens != nil }) else { continue }
            let totals = inTurn.compactMap(\.totalTokens), outputs = inTurn.compactMap(\.outputTokens)
            guard let lastTotal = totals.last, lastTotal >= baselineTotal, totals.first! >= baselineTotal,
                  let lastOutput = outputs.last, lastOutput >= baselineOutput, outputs.first! >= baselineOutput,
                  zip(totals, totals.dropFirst()).allSatisfy({ $0 <= $1 }),
                  zip(outputs, outputs.dropFirst()).allSatisfy({ $0 <= $1 }) else { continue }
            let duration = complete.duration ?? complete.date.timeIntervalSince(start.date) * 1000
            guard duration.isFinite, duration >= 100 else { continue }
            guard complete.date <= now else { continue }
            let usages = inTurn.compactMap(\.usage)
            let inputValues = [baselineUsage.input] + usages.map(\.input)
            let inputIsKnown = isMonotonic(inputValues)
            let inputDelta: Int? = inputIsKnown ? lastInputDelta(baseline: baselineUsage, final: usages.last!) : nil
            let cache = cacheDeltaState(baseline: baselineUsage, records: usages)
            result.append(TurnEvidence(completedAt: complete.date, outputTokens: lastOutput - baselineOutput,
                durationSeconds: duration / 1000, input: inputDelta,
                output: lastOutput - baselineOutput, total: lastTotal - baselineTotal,
                cache: cache, sourceOrdinal: start.rawOrdinal,
                stableKey: "\(id)|\(start.rawOrdinal)"))
        }
        return result
    }

    private static func lastInputDelta(baseline: Record, final: Record) -> Int? {
        let delta = final.input - baseline.input
        return delta >= 0 ? delta : nil
    }

    private static func completedTurns(in events: [ParsedEvent], now: Date) -> LocalTurnSummary? {
        completedTurnEvidence(in: events, now: now)
            .map { LocalTurnSummary(outputTokens: $0.outputTokens, durationSeconds: $0.durationSeconds, completedAt: $0.completedAt) }
            .max(by: { $0.completedAt < $1.completedAt })
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
    /// 发布根线程的最终计数前先校验累计记录。时间戳相同时以 JSONL 顺序为准。
    /// 时间逆序、未来或无效的生命周期时间、计数器重置、总量小于 input+output 均判为未知。
    private static func validCumulativeSequence(_ events: [ParsedEvent], now: Date) -> Bool {
        guard !events.isEmpty else { return false }
        var previousDate: Date?
        var previous: Record?
        for event in events {
            guard event.hasCumulativePayload, let usage = event.usage,
                  !event.invalidLifecycleTimestamp, usage.date <= now else { return false }
            if let previousDate, usage.date < previousDate { return false }
            if let previous,
               usage.input < previous.input || usage.output < previous.output || usage.total < previous.total {
                return false
            }
            let (minimumTotal, overflow) = usage.input.addingReportingOverflow(usage.output)
            guard !overflow, usage.total >= minimumTotal else { return false }
            previousDate = usage.date
            previous = usage
        }
        return true
    }
    private static func isMonotonic(_ values: [Int]) -> Bool { zip(values, values.dropFirst()).allSatisfy { $0 <= $1 } }
    private static func cacheInput(_ value: Any?, input: Int) -> LocalCacheInput {
        guard let value, !(value is NSNull) else { return .notReported }
        guard let cached = integer(value), cached <= input else { return .invalid }
        return .value(cached)
    }

    /// 缓存计数独立于输入、输出和总量链校验，缺失值中断缓存链但不按零处理。
    /// 无效值优先于缺失值，避免较早的缺失掩盖后续错误。
    private static func cacheChainState(_ records: [Record]) -> LocalCacheInput {
        var previous: (input: Int, cached: Int)?
        var final: Int?
        var sawMissing = false
        var sawInvalid = false
        for record in records {
            switch record.cache {
            case .notReported:
                sawMissing = true
            case .invalid:
                sawInvalid = true
            case .value(let cached):
                final = cached
                if cached > record.input { sawInvalid = true }
                if let previous {
                    let inputDelta = record.input - previous.input
                    let cacheDelta = cached - previous.cached
                    if inputDelta < 0 || cacheDelta < 0 || cacheDelta > inputDelta { sawInvalid = true }
                }
                previous = (record.input, cached)
            }
        }
        if sawInvalid { return .invalid }
        if sawMissing || final == nil { return .notReported }
        return .value(final!)
    }

    private static func cacheDeltaState(baseline: Record?, records: [Record]) -> LocalCacheInput {
        guard let baseline else { return .notReported }
        let chain = cacheChainState([baseline] + records)
        guard case .value(let final) = chain, case .value(let initial) = baseline.cache else { return chain }
        let delta = final - initial
        let inputDelta = records.last.map { $0.input - baseline.input } ?? 0
        guard delta >= 0, inputDelta >= 0, delta <= inputDelta else { return .invalid }
        return .value(delta)
    }

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
