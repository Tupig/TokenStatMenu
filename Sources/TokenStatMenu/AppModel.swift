import AppKit
import Combine
import CoreFoundation
#if SWIFT_PACKAGE
@preconcurrency import TokenStatCore
#endif

struct SpeedPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

struct SeasunPreferences: Equatable {
    var refreshSeconds: TimeInterval = 60
    var tokenHubCompatibilityReadEnabled = true

    var normalized: SeasunPreferences {
        SeasunPreferences(refreshSeconds: refreshSeconds.isFinite && (15...3600).contains(refreshSeconds) ? refreshSeconds : 60,
                          tokenHubCompatibilityReadEnabled: tokenHubCompatibilityReadEnabled)
    }

    init(refreshSeconds: TimeInterval = 60, tokenHubCompatibilityReadEnabled: Bool = true) {
        self.refreshSeconds = refreshSeconds
        self.tokenHubCompatibilityReadEnabled = tokenHubCompatibilityReadEnabled
    }

    static func decode(_ data: Data?) -> SeasunPreferences {
        guard let data,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let values = root as? [String: Any] else { return SeasunPreferences() }

        let refresh: TimeInterval
        if let number = values["refreshSeconds"] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
           (15...3600).contains(number.doubleValue) {
            refresh = number.doubleValue
        } else { refresh = 60 }

        let compatibility: Bool
        if let current = values["tokenHubCompatibilityReadEnabled"] {
            compatibility = Self.boolean(current) ?? true
        } else {
            compatibility = Self.boolean(values["tokenHubAutomaticReadingEnabled"]) ?? true
        }
        return SeasunPreferences(refreshSeconds: refresh,
                                 tokenHubCompatibilityReadEnabled: compatibility)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

struct AppModelStartupDependencies {
    let loadPreferences: @MainActor () throws -> Data?
    let savePreferences: @MainActor (SeasunPreferences) throws -> Void
    let shouldStartBackgroundServices: @MainActor () -> Bool

    static var production: AppModelStartupDependencies {
        AppModelStartupDependencies(
            loadPreferences: { try ConfigStore.loadPreferences(at: AppPaths.configURL) },
            savePreferences: { try ConfigStore.savePreferences($0) },
            shouldStartBackgroundServices: { !CommandLine.arguments.contains("--disable-background-services") })
    }
}

/// The only direct-quota value allowed to cross the worker boundary.  It
/// deliberately contains no process identity, URL, database path, session,
/// bearer token, or response body.  The worker validates the target identity
/// before and after the request and returns only these displayable facts.
struct DirectQuotaTransportSnapshot: Sendable {
    let fiveHour: TokenHubWindowQuota?
    let sevenDay: TokenHubWindowQuota?
    let monthly: TokenHubMonthlyUsage?
    let observedAt: Date

    func materializedSnapshot() -> TokenHubQuotaSnapshot {
        // The model keeps the historical snapshot shape for compatibility with
        // synthetic tests. Production never exposes the real PID or executable
        // path; worker-side identity checks already completed this transaction.
        // Keep the legacy snapshot shape for UI/tests, but never carry the
        // worker's real PID or executable path across the actor boundary.
        let sanitizedIdentity = TokenHubIdentity(pid: 0, bundleID: TokenHubTarget.bundleID,
                                                  executablePath: "sanitized")
        return TokenHubQuotaSnapshot(identity: sanitizedIdentity, fiveHour: fiveHour,
                                     sevenDay: sevenDay, monthly: monthly,
                                     observedAt: observedAt)
    }

    init(snapshot: TokenHubQuotaSnapshot) {
        fiveHour = snapshot.fiveHour; sevenDay = snapshot.sevenDay
        monthly = snapshot.monthly; observedAt = snapshot.observedAt
    }
}

/// Owns process discovery, settings/SQLite reads and the authenticated direct
/// fetch away from the main actor. No identity or credential leaves this actor.
private actor TokenHubDirectQuotaWorker {
    private let client = TokenHubDirectQuotaClient()

    func fetch(now: Date) async throws -> DirectQuotaTransportSnapshot {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: TokenHubTarget.bundleID)
            .filter { !$0.isTerminated }
        guard !applications.isEmpty else { throw TokenHubQuotaFailure.noTarget }
        guard applications.count == 1, let app = applications.first,
              let executable = app.executableURL?.standardizedFileURL.path,
              let bundle = app.bundleIdentifier else {
            throw applications.count > 1 ? TokenHubQuotaFailure.multipleTargets : TokenHubQuotaFailure.identityChanged
        }
        let identity = TokenHubIdentity(pid: app.processIdentifier, bundleID: bundle, executablePath: executable)
        let snapshot = try await client.fetch(identity: identity, now: now)
        try Task.checkCancellation()
        // TokenHubDirectQuotaClient revalidates its settings/database identity
        // around the network exchange. Do not return the target identity.
        return DirectQuotaTransportSnapshot(snapshot: snapshot)
    }
}

/// Keep external process discovery and authenticated I/O outside lifecycle
/// handling. Explicit injection also lets previews exercise the direct path
/// using entirely synthetic identities and responses.
struct TokenHubDirectQuotaDependencies {
    let discoverTarget: () throws -> TokenHubIdentity
    let identityIsCurrent: (TokenHubIdentity) -> Bool
    let fetch: (TokenHubIdentity, Date) async throws -> TokenHubQuotaSnapshot
    /// Production uses this worker closure. The three actor-isolated closures
    /// remain as a compatibility seam for synthetic tests only.
    let workerFetch: (@Sendable (Date) async throws -> DirectQuotaTransportSnapshot)?

    init(discoverTarget: @escaping () throws -> TokenHubIdentity,
         identityIsCurrent: @escaping (TokenHubIdentity) -> Bool,
         fetch: @escaping (TokenHubIdentity, Date) async throws -> TokenHubQuotaSnapshot,
         workerFetch: (@Sendable (Date) async throws -> DirectQuotaTransportSnapshot)? = nil) {
        self.discoverTarget = discoverTarget
        self.identityIsCurrent = identityIsCurrent
        self.fetch = fetch
        self.workerFetch = workerFetch
    }

    static var production: TokenHubDirectQuotaDependencies {
        let worker = TokenHubDirectQuotaWorker()
        // These compatibility closures are intentionally inert in production;
        // all discovery/settings/network work is owned by the actor above.
        return TokenHubDirectQuotaDependencies(discoverTarget: { throw TokenHubQuotaFailure.noTarget },
            identityIsCurrent: { _ in false },
            fetch: { _, _ in throw TokenHubDirectQuotaFailure.transportFailed },
            workerFetch: { now in try await worker.fetch(now: now) })
    }
}

/// Owns the non-Sendable mutable cache on one checked executor. Only numeric
/// value snapshots cross back to the main actor; no cache reference escapes.
actor LocalCodexScanWorker {
    struct Result: Sendable {
        let snapshot: LocalCodexSnapshot
        let diagnostics: LocalCodexUsageReader.Cache.Diagnostics
    }

    private var cache = LocalCodexUsageReader.Cache()
    private var cacheGeneration: Int?

    func scan(directory: URL, now: Date, generation: Int,
              routeContext: LocalCodexRouteContext?) throws -> Result {
        // This method has no suspension point while the cache is in use:
        // actor isolation serializes complete reads, including invalidation.
        if cacheGeneration != generation {
            cache = LocalCodexUsageReader.Cache()
            cacheGeneration = generation
        }
        let snapshot = try LocalCodexUsageReader.scan(directory: directory, now: now,
                                                       cache: cache, routeContext: routeContext)
        return Result(snapshot: snapshot, diagnostics: cache.diagnostics)
    }

    /// Production discovery stays inside the same worker as file scanning so
    /// session paths and route origins never cross back through the main actor.
    func scanDefault(now: Date, generation: Int) throws -> Result {
        let directory = LocalCodexUsageReader.defaultSessionsDirectory()
        let routeContext = AppModel.seasunRouteContext()
        return try scan(directory: directory, now: now, generation: generation, routeContext: routeContext)
    }
}

/// Resolve the same permitted inputs on the main actor, then run bounded file
/// I/O in the cache owner. Injection replaces external I/O in lifecycle checks.
struct LocalCodexScanDependencies {
    struct Inputs: Sendable {
        let directory: URL
        let routeContext: LocalCodexRouteContext
    }
    /// Legacy injected seams are optional so production can expose only the
    /// worker-owned `scanDefault` path. Keeping these seams available for
    /// synthetic tests does not make a real sessions URL cross the actor
    /// boundary in the production configuration.
    let resolveInputs: (@MainActor () -> (directory: URL, routeContext: LocalCodexRouteContext))?
    let scan: (@Sendable (URL, Date, Int, LocalCodexRouteContext) async throws -> LocalCodexScanWorker.Result)?
    let scanDefault: (@Sendable (Date, Int) async throws -> LocalCodexScanWorker.Result)?

    init(resolveInputs: @escaping @MainActor () -> (directory: URL, routeContext: LocalCodexRouteContext),
         scan: @escaping @Sendable (URL, Date, Int, LocalCodexRouteContext) async throws -> LocalCodexScanWorker.Result,
         scanDefault: (@Sendable (Date, Int) async throws -> LocalCodexScanWorker.Result)? = nil) {
        self.resolveInputs = resolveInputs
        self.scan = scan
        self.scanDefault = scanDefault
    }

    private init(resolveInputs: (@MainActor () -> (directory: URL, routeContext: LocalCodexRouteContext))?,
                 scan: (@Sendable (URL, Date, Int, LocalCodexRouteContext) async throws -> LocalCodexScanWorker.Result)?,
                 scanDefault: (@Sendable (Date, Int) async throws -> LocalCodexScanWorker.Result)?) {
        self.resolveInputs = resolveInputs
        self.scan = scan
        self.scanDefault = scanDefault
    }

    @MainActor static var production: LocalCodexScanDependencies {
        let worker = LocalCodexScanWorker()
        // Do not retain a production closure that resolves the real sessions
        // URL on the main actor. Discovery and route reading remain inside the
        // same worker that owns the cache and performs the bounded file scan.
        return LocalCodexScanDependencies(resolveInputs: nil, scan: nil,
            scanDefault: { now, generation in try await worker.scanDefault(now: now, generation: generation) })
    }
}

struct BackgroundServiceResources: Equatable, Encodable {
    let timerCount: Int
    let workspaceObserverCount: Int
    let localScanQueuedCount: Int
    let axRefreshScheduledCount: Int
    let axScanInFlightCount: Int
}

/// A model-captured time used by one refresh request. Capturing this before a
/// delayed work item is enqueued keeps local/direct workers from consulting
/// independent wall clocks after the scheduling delay.
private struct RefreshObservationContext: Sendable, Equatable {
    let observationNow: Date
}

/// Clock-derived presentation changes are distinct from new measurements.
/// Comparing these cheap booleans keeps the half-second menu cadence without
/// formatting dates or invalidating every SwiftUI view when nothing changed.
struct PresentationTimeState: Equatable {
    struct Window: Equatable {
        let futureObservation: Bool
        let fresh: Bool
        let resetPassed: Bool
    }
    let localLive: Bool
    let tokenHubFresh: Bool
    let monthlyFresh: Bool
    let fiveHour: Window?
    let sevenDay: Window?
}

@MainActor final class AppModel: ObservableObject {
    // Explicit launch-only flag: fixtures never masquerade as enterprise measurements.
    let isTestFixture = CommandLine.arguments.contains("--test-fixture")
    private let isPreview: Bool
    private let startup: AppModelStartupDependencies
    private let directQuota: TokenHubDirectQuotaDependencies
    private let tokenHubAXSource: TokenHubAXSource
    private let usesDirectQuotaSource: Bool
    private(set) var backgroundServicesStarted = false
    private(set) var permissionPromptRequested = false
    @Published private(set) var preferences = SeasunPreferences() {
        didSet { capturePresentationTimeBaseline() }
    }
    @Published var config = AppConfiguration() {
        didSet {
            if oldValue.dataSource != config.dataSource {
                history.removeAll(keepingCapacity: true)
                lastHistorySampleAt = .distantPast
            }
            capturePresentationTimeBaseline()
        }
    }
    @Published var stats = MetricsSnapshot()
    @Published var localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0, filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil, knownThreadCount: 0, unknownThreadCount: 0, unidentifiedFileCount: 0, subagentCount: 0, forkCount: 0) {
        didSet { capturePresentationTimeBaseline() }
    }
    @Published var quota: QuotaSnapshot? {
        didSet { capturePresentationTimeBaseline() }
    }
    @Published var fiveHourQuota: WindowQuota? {
        didSet { capturePresentationTimeBaseline() }
    }
    @Published var sevenDayQuota: WindowQuota? {
        didSet { capturePresentationTimeBaseline() }
    }
    @Published var quotaError = "Token Hub 界面快照数据未知"
    @Published var sourceReadinessText = "企业后台直接来源未接通"
    @Published var message = ""
    @Published var history: [SpeedPoint] = []
    @Published var quotaLoading = false
    @Published private(set) var tokenHubQuotaSnapshot: TokenHubQuotaSnapshot? {
        didSet { capturePresentationTimeBaseline() }
    }
    @Published private(set) var tokenHubQuotaStatus: TokenHubQuotaStatus = .targetNotRunning {
        didSet { capturePresentationTimeBaseline() }
    }
    @Published private(set) var tokenHubQuotaFailure: TokenHubQuotaFailure?
    @Published private(set) var tokenHubDirectFailure: TokenHubDirectQuotaFailure?
    private(set) var tokenHubQuotaIsDirect = false
    var tokenHubAutomaticReadingEnabled: Bool {
        get { preferences.tokenHubCompatibilityReadEnabled }
        set { preferences.tokenHubCompatibilityReadEnabled = newValue }
    }
    var tokenHubPermissionProvider: TokenHubPermissionProviding = TokenHubNativePermissionProvider()
    var tokenHubNow: () -> Date = Date.init
    @Published var panelVisible = false
    let engine = MetricsEngine()
    private var timer: Timer?
    private var localScan: DispatchWorkItem?
    private var localScanRunning = false
    private var tokenHubRefreshWork: DispatchWorkItem?
    private var tokenHubScanInFlight = false
    private var tokenHubDirectScanInFlight = false
    private var tokenHubWorkspaceObservers: [NSObjectProtocol] = []
    private var lastTokenHubPermissionCheck = Date.distantPast
    private var cachedTokenHubPermission = false
    private let localScanning: LocalCodexScanDependencies
    private var localRefreshScheduler = LocalRefreshScheduler()
    private var isShuttingDown = false
    private var generation = 0
    private var tokenHubGeneration: UInt64 = 0
    private var tokenHubAXGeneration: UInt64 = 0
    private var lastPresentationTimeState: PresentationTimeState?
    private var lastHistorySampleAt = Date.distantPast
    var onTick: (() -> Void)?

    private static let historyDuration: TimeInterval = 10 * 60
    private static let historyCapacity = 1_200

    var isSeasunOnly: Bool { true }
    var tokenHubQuotaReadingEnabled: Bool { usesDirectQuotaSource || tokenHubAutomaticReadingEnabled }
    var userFacingStatus: String {
        if tokenHubQuotaIsDirect, tokenHubQuotaStatus == .connected {
            return "Seasun Token Hub 企业额度已自动读取；5 小时和 7 天重置时间来自后台响应。"
        }
        if let failure = tokenHubDirectFailure {
            return "Seasun Token Hub 企业后台直接来源：\(directFailureText(failure))。"
        }
        return "Seasun Token Hub 企业后台直接来源：尚未连接；额度、重置时间、月度用量和实时速度均未知。"
    }
    var sourceStatus: String { "unknown" }
    var activityIsLive: Bool {
        config.dataSource == "localCodex" ? freshLocalLiveTurn != nil : stats.active > 0
    }
    var backgroundServiceResources: BackgroundServiceResources {
        BackgroundServiceResources(timerCount: timer == nil ? 0 : 1,
            workspaceObserverCount: tokenHubWorkspaceObservers.count,
            localScanQueuedCount: localScan == nil || localScan!.isCancelled ? 0 : 1,
            axRefreshScheduledCount: tokenHubRefreshWork == nil || tokenHubRefreshWork!.isCancelled ? 0 : 1,
            axScanInFlightCount: tokenHubScanInFlight ? 1 : 0)
    }

    init(preview: Bool = false, startup: AppModelStartupDependencies = .production,
         directQuota: TokenHubDirectQuotaDependencies? = nil,
         localScanning: LocalCodexScanDependencies? = nil,
         tokenHubAXSource: TokenHubAXSource? = nil) {
        isPreview = preview
        self.startup = startup
        self.directQuota = directQuota ?? .production
        self.tokenHubAXSource = tokenHubAXSource ?? .production
        self.localScanning = localScanning ?? .production
        usesDirectQuotaSource = directQuota != nil || !(preview || CommandLine.arguments.contains("--test-fixture"))
        if preview {
            sourceReadinessText = "模拟预览 · 无配置读取、无自动服务"
            return
        }
        do {
            preferences = SeasunPreferences.decode(try startup.loadPreferences()).normalized
        } catch {
            message = "无法读取本地偏好设置；当前使用安全默认值。"
        }
        applyPreferencesToPresentationConfig()
        if startup.shouldStartBackgroundServices() {
            backgroundServicesStarted = true
            startBackgroundServices()
        }
    }
    func shutdown() {
        isShuttingDown = true; backgroundServicesStarted = false
        generation += 1; _ = localRefreshScheduler.invalidate()
        timer?.invalidate(); timer = nil; localScan?.cancel(); localScan = nil
        tokenHubGeneration &+= 1
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        for observer in tokenHubWorkspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        tokenHubWorkspaceObservers.removeAll()
        tokenHubQuotaSnapshot = nil; tokenHubQuotaStatus = .disabled; tokenHubQuotaFailure = nil
        tokenHubDirectFailure = nil; tokenHubQuotaIsDirect = false; tokenHubDirectScanInFlight = false
    }
    func tick() {
        // The formal local-history mode never consumes proxy engine metrics.
        // Publishing its identical empty snapshot would redraw a hidden or
        // open dashboard twice a second. Legacy proxy previews keep sampling.
        if config.dataSource != "localCodex" { stats = engine.snapshot() }
        let now = tokenHubNow()
        var publishedTransition = false
        // Check presence first: creating a date formatter for an absent quota
        // was otherwise part of every idle menu tick.
        if let quota, quota.month != QuotaSnapshot.currentMonth(at: now) {
            self.quota = nil; quotaError = "已跨月，等待本月用量"
            publishedTransition = true
        }
        if tokenHubQuotaStatus == .connected, freshTokenHubQuota(at: now) == nil {
            tokenHubQuotaStatus = .stale
            publishedTransition = true
        }
        if backgroundServicesStarted { pollTokenHubPermissionIfDue() }
        updateLocalHistory(at: now)
        let timeState = presentationTimeState
        if let previous = lastPresentationTimeState, previous != timeState, !publishedTransition {
            objectWillChange.send()
        }
        lastPresentationTimeState = timeState
        onTick?()
    }

    /// Keep one bounded point per half-second for ten minutes. Only fresh local
    /// estimates enter this series; stale or unknown values create no fake
    /// zero-speed samples and mode switches cannot leak proxy observations.
    private func updateLocalHistory(at now: Date) {
        guard panelVisible, config.dataSource == "localCodex", let live = freshLocalLiveTurn,
              now.timeIntervalSince(lastHistorySampleAt) >= 0.5 else { return }
        lastHistorySampleAt = now
        let point = SpeedPoint(date: now, value: live.outputTPS)
        let cutoff = now.addingTimeInterval(-Self.historyDuration)
        history = (history + [point]).filter { $0.date >= cutoff }
        if history.count > Self.historyCapacity { history.removeFirst(history.count - Self.historyCapacity) }
    }
    var freshQuota: QuotaSnapshot? {
        let now = tokenHubNow()
        guard let quota, quota.month == QuotaSnapshot.currentMonth(at: now),
              quota.fetchedAt <= now,
              now.timeIntervalSince(quota.fetchedAt) < max(120, config.refreshSeconds * 2) else { return nil }
        return quota
    }
    /// A measurement can arrive and expire between timer ticks. Remember
    /// its time state after the input mutation, since SwiftUI may render that
    /// intervening published value even if the previous tick had no live data.
    private func capturePresentationTimeBaseline() {
        lastPresentationTimeState = presentationTimeState
    }
    var presentationTimeState: PresentationTimeState {
        let now = tokenHubNow()
        func window(_ value: WindowQuota?) -> PresentationTimeState.Window? {
            value.map { PresentationTimeState.Window(futureObservation: $0.fetchedAt > now,
                fresh: $0.isFresh(at: now, refreshSeconds: config.refreshSeconds),
                resetPassed: $0.resetsAt.map { $0 <= now } ?? false) }
        }
        return PresentationTimeState(localLive: freshLocalLiveTurn != nil,
            tokenHubFresh: freshTokenHubQuota(at: now) != nil, monthlyFresh: freshQuota != nil,
            fiveHour: window(fiveHourQuota), sevenDay: window(sevenDayQuota))
    }
    var currencyFactor: Double { config.currency == "CNY" ? config.usdToCNY : 1 }
    var currencySymbol: String { config.currency == "CNY" ? "¥" : "$" }
    var quotaSource: QuotaSource { isPreview && config.dataSource != "localCodex" ? .enterprise : .localCodex }
    var hasRequestData: Bool { quotaSource == .localCodex ? localSnapshot.knownThreadCount > 0 : stats.requests > 0 }
    var dataNotice: String {
        if isTestFixture { return "模拟测试 · 以下速度、Token、费用和配额均非企业真实数据" }
        if !isPreview {
            if tokenHubQuotaIsDirect, tokenHubQuotaStatus == .connected {
                return "企业额度已自动读取 Token Hub 后台；本地 Codex 历史记录与企业额度分开统计。"
            }
            if tokenHubDirectFailure != nil, tokenHubQuotaSnapshot == nil {
                return "企业后台直接来源暂不可用：\(tokenHubQuotaStatusText)"
            }
            return "企业后台直接来源尚未连接；本地 Codex 历史记录与 Token Hub 额度分别展示。"
        }
        if config.dataSource == "localCodex" { return "当前配置关联的本机 Codex 记录，历史路由未核验；当前扫描范围记录小计，实时速度为活动事件短窗口估算" }
        return hasRequestData ? "本次启动 · 仅统计经过本机代理的请求" : "未采集到请求数据 · 尚未观测到客户端流量"
    }
    /// Presentation checks freshness on every menu update, even if the local
    /// file scan stalls. A future or invalid observation is never called live.
    var freshLocalLiveTurn: LocalLiveTurnSummary? {
        let now = tokenHubNow()
        guard let live = localSnapshot.liveTurn,
              live.observedAt <= now, now.timeIntervalSince(live.observedAt) <= 15,
              live.inputTPS.isFinite, live.outputTPS.isFinite,
              live.inputTPS >= 0, live.outputTPS >= 0 else { return nil }
        return live
    }
    var title: String {
        if config.dataSource == "localCodex" {
            let rate: String
            if let live = freshLocalLiveTurn {
                rate = String(format: "实时≈%.1ftok/s", live.outputTPS)
            } else if let turn = localSnapshot.lastTurn {
                rate = String(format: "上轮均:%.1ftok/s", turn.outputTPS)
            } else {
                rate = "上轮均:—"
            }
            let uncertainty = localSnapshot.unknownThreadCount + localSnapshot.unidentifiedFileCount
            let total = localSnapshot.hasCompleteAccounting ? "Σ\(formatCompactCount(localSnapshot.total))"
                : localSnapshot.knownThreadCount > 0 ? "小计\(formatCompactCount(localSnapshot.total)) · 未核验\(uncertainty)" : "Σ— · 未核验\(uncertainty)"
            let sessions = localSnapshot.hasCompleteAccounting ? " · \(localSnapshot.sessionCount)顶层对话" : ""
            let quotaSuffix = tokenHubMenuSuffix
            return (isTestFixture ? "测试 " : "") + "\(rate) · \(total)\(sessions)\(quotaSuffix)"
        }
        let value = !hasRequestData ? "T:—" : stats.active > 0
            ? String(format: "T:≈%.1ftok/s", stats.outputTPS) : "T:0.0tok/s"
        let total = stats.requests > 0 ? formatCompactCount(stats.total) : "—"
        return (isTestFixture ? "测试 " : "") + "\(value) · Σ\(total) · 请求\(stats.requests)"
    }
    var menuTooltip: String {
        if isPreview && config.dataSource != "localCodex" {
            return "\(dataNotice) · \(sourceReadinessText)\n5 小时额度：\(quotaDescription(fiveHourQuota, source: .enterprise))\n7 天额度：\(quotaDescription(sevenDayQuota, source: .enterprise))"
        }
        let live = freshLocalLiveTurn.map { String(format: "实时估算：输入 %.1f · 输出 %.1f tok/s（观测于 %@）", $0.inputTPS, $0.outputTPS, $0.observedAt.formatted()) } ?? "实时估算：未知（无新鲜活动 token_count）"
        let turn = localSnapshot.lastTurn.map { String(format: "上轮记录均速：%.1f tok/s（完成于 %@）", $0.outputTPS, $0.completedAt.formatted()) } ?? "上轮记录均速：未知"
        let range = localSnapshot.latestEventAt.map { "最新记录：\($0.formatted())" } ?? "记录时间：未知"
        let coverage = "扫描范围最多32个物理文件；不是全部对话；每文件头64KiB与尾256KiB，总计10MiB；" + (localSnapshot.isLimited ? "本次达到扫描上限" : "本次安全检查 \(localSnapshot.filesScanned) 个物理文件")
        let input = localSnapshot.knownThreadCount > 0 ? formatCount(localSnapshot.input) : "未知"
        let output = localSnapshot.knownThreadCount > 0 ? formatCount(localSnapshot.output) : "未知"
        let amountLabel = localSnapshot.hasCompleteAccounting ? "本次扫描记录量" : "已核验记录小计"
        let total = localSnapshot.knownThreadCount > 0 ? formatCount(localSnapshot.total) : "未知"
        let hub = tokenHubTooltipDetail
        return "\(userFacingStatus)\n当前配置关联的本机 Codex 记录，历史路由未核验；当前扫描范围：输入 \(input) · 输出 \(output) · 总计 \(total) tokens（\(amountLabel) \(total) tokens）\n\(accountingDetail)\n\(coverage)；\(range)\n\(live)；\(turn)；实时值是最近活动 token_count 的短窗口估算；上轮均速含工具、网络和等待，不是模型瞬时生成速度\n\(hub)\n5 小时额度：\(quotaDescription(fiveHourQuota, source: .localCodex))\n7 天额度：\(quotaDescription(sevenDayQuota, source: .localCodex))"
    }
    private var tokenHubMenuSuffix: String {
        guard let snapshot = freshTokenHubQuota(at: tokenHubNow()) else { return "" }
        let windows = [snapshot.fiveHour.map { "5h剩 \(percentText($0.remainingPercent))" },
                       snapshot.sevenDay.map { "7d剩 \(percentText($0.remainingPercent))" }].compactMap { $0 }
        return windows.isEmpty ? "" : " · Hub \(windows.joined(separator: " / "))"
    }
    var menuTitleContainsTokenHubSuffix: Bool { !tokenHubMenuSuffix.isEmpty }
    var tokenHubPermissionGrantedForDiagnostics: Bool { cachedTokenHubPermission }
    var tokenHubPermissionRequiredForDiagnostics: Bool { tokenHubQuotaStatus == .permissionRequired }
    private var tokenHubTooltipDetail: String {
        let snapshot = freshTokenHubQuota(at: tokenHubNow())
        let five = snapshot?.fiveHour.map { "界面显示剩余 \(percentText($0.remainingPercent))（5 小时）" } ?? "5 小时未知"
        let seven = snapshot?.sevenDay.map { "界面显示剩余 \(percentText($0.remainingPercent))（7 天）" } ?? "7 天未知"
        let source = tokenHubQuotaIsDirect ? "Token Hub 后台直接响应" : "Token Hub 界面快照"
        let timing = tokenHubQuotaIsDirect ? "后台响应已提供" : "后台更新时间未提供"
        let currency = tokenHubQuotaIsDirect ? "币种来自后台响应" : "币种未核验"
        return "\(source)：\(five) · \(seven)；\(tokenHubQuotaStatusText)；\(timing)；\(currency)"
    }
    private func percentText(_ value: Decimal) -> String {
        TwoDecimalPercentFormatter.string(value)
    }
    var tokenHubQuotaStatusText: String {
        if tokenHubQuotaIsDirect, tokenHubQuotaStatus == .connected { return "企业后台已直接读取" }
        if tokenHubQuotaSnapshot == nil, let failure = tokenHubDirectFailure { return directFailureText(failure) }
        return switch tokenHubQuotaStatus {
        case .disabled: "自动读取已关闭"
        case .permissionRequired: "未授权辅助功能"
        case .targetNotRunning: "Token Hub 未运行"
        case .ambiguousTarget: "检测到多个 Token Hub 进程"
        case .quotaGroupUnavailable: "找不到用量和限额页"
        case .unsupportedLayout: "用量页面布局暂不支持"
        case .accessFailed: "辅助功能读取失败"
        case .stale: "界面快照已过期"
        case .connected: "界面快照已读取"
        }
    }
    private func directFailureText(_ failure: TokenHubDirectQuotaFailure) -> String {
        switch failure {
        case .credentialExpired: "Token Hub 会话已过期"
        case .identityChanged: "Token Hub 进程在读取期间发生变化"
        case .connectionUnavailable, .connectionMalformed, .databaseUnsafe: "Token Hub 连接配置不可用"
        case .sessionUnavailable: "Token Hub 本机登录态不可用"
        case .exchangeFailed, .redirectMissing, .accessTokenMissing: "Token Hub 登录态交换失败"
        case .endpointRejected: "Token Hub 地址不在受信范围"
        case .httpStatus(let status) where status == 401 || status == 403: "Token Hub 会话未获授权"
        case .httpStatus: "Token Hub 后台暂时不可用"
        case .responseTooLarge, .malformedResponse, .noRecognizedWindows: "Token Hub 返回数据无法核验"
        case .duplicateWindow, .duplicateMonthly: "Token Hub 返回了重复额度窗口"
        case .transportFailed: "Token Hub 网络请求失败"
        }
    }
    private var accountingDetail: String {
        "已核验线程 \(localSnapshot.knownThreadCount) · 未核验线程 \(localSnapshot.unknownThreadCount) · 未识别文件 \(localSnapshot.unidentifiedFileCount) · 子代理 \(localSnapshot.subagentCount) · 分叉 \(localSnapshot.forkCount) · 顶层对话 \(localSnapshot.sessionCount)"
    }
    private func quotaDescription(_ quota: WindowQuota?, source: QuotaSource) -> String {
        let presentation = WindowQuotaCard.presentation(for: quota, at: tokenHubNow(), refreshSeconds: config.refreshSeconds, source: source)
        guard let usedPercent = presentation.usedPercent else { return "\(presentation.sourceLabel) · \(presentation.statusLabel)" }
        let resetLabel = source == .localCodex || !presentation.isFresh ? "原重置时间" : "重置时间"
        let reset = presentation.resetsAt.map { "，\(resetLabel) \($0.formatted())" } ?? "，重置时间未知"
        let recorded = presentation.recordedAt.map { "，记录于 \($0.formatted())" } ?? ""
        return "\(presentation.sourceLabel) · \(presentation.statusLabel)，上游已用 \(TwoDecimalPercentFormatter.string(usedPercent))\(reset)\(recorded)"
    }
    private func formatCount(_ value: Int) -> String { value.formatted(.number) }
    private func formatCompactCount(_ value: Int) -> String { value.formatted(.number.notation(.compactName)) }
    var alertColor: NSColor {
        if tokenHubQuotaIsDirect, let snapshot = freshTokenHubQuota(at: tokenHubNow()) {
            let windows = [snapshot.fiveHour?.usedPercent, snapshot.sevenDay?.usedPercent].compactMap { $0 }
            guard let used = windows.max() else { return .labelColor }
            if used >= Decimal(string: "95")! { return .systemRed }
            if used >= Decimal(string: "80")! { return .systemYellow }
            return .labelColor
        }
        guard quotaSource == .enterprise else { return .labelColor }
        let windows = (quotaSource == .enterprise ? [fiveHourQuota, sevenDayQuota].compactMap { $0 } : [])
            .filter { $0.isFresh(at: tokenHubNow(), refreshSeconds: config.refreshSeconds) }.map { $0.usedPercent / 100 }
        guard let ratio = (windows + [freshQuota?.fraction].compactMap { $0 }).max() else { return .labelColor }
        return ratio >= 0.95 ? .systemRed : ratio >= 0.8 ? .systemYellow : .labelColor
    }
    /// Kept for the synthetic legacy core-state regression only; never used by the formal Settings path.
    static func configurationForApplying(_ draft: AppConfiguration,
                                         automaticReadingEnabled: Bool) -> AppConfiguration {
        var configuration = draft
        configuration.tokenHubAutomaticReadingEnabled = automaticReadingEnabled
        return configuration
    }

    func savePreferences(_ newPreferences: SeasunPreferences) -> Bool {
        let normalized = newPreferences.normalized
        do {
            try startup.savePreferences(normalized)
        } catch {
            message = "偏好设置保存失败；当前设置保持不变。"
            return false
        }
        preferences = normalized
        applyPreferencesToPresentationConfig()
        message = "偏好设置已保存。"
        restartBackgroundServicesIfPermitted()
        return true
    }

    func reload() {
        do {
            let loaded = try startup.loadPreferences()
            preferences = SeasunPreferences.decode(loaded).normalized
            applyPreferencesToPresentationConfig()
            message = "偏好设置已重新加载。"
            restartBackgroundServicesIfPermitted()
        }
        catch { message = "偏好设置重新加载失败；当前设置保持不变。" }
    }

    private func applyPreferencesToPresentationConfig() {
        // This compatibility projection exists for the local-history views and synthetic tests.
        // No integration field is loaded from the old plist or used to activate an app service.
        var safe = AppConfiguration()
        safe.dataSource = "localCodex"
        safe.refreshSeconds = preferences.refreshSeconds
        safe.tokenHubAutomaticReadingEnabled = preferences.tokenHubCompatibilityReadEnabled
        config = safe
        tokenHubQuotaStatus = tokenHubQuotaReadingEnabled ? .targetNotRunning : .disabled
    }

    private func restartBackgroundServicesIfPermitted() {
        guard !isPreview, !isShuttingDown else { return }
        guard startup.shouldStartBackgroundServices() else {
            stopBackgroundServices()
            return
        }
        backgroundServicesStarted = true
        startBackgroundServices()
    }

    private func startBackgroundServices() {
        guard !isPreview, !isShuttingDown, backgroundServicesStarted else { return }
        stopBackgroundResources()
        generation += 1; tokenHubGeneration &+= 1
        history.removeAll(keepingCapacity: true)
        lastHistorySampleAt = .distantPast
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        tokenHubQuotaSnapshot = nil; tokenHubQuotaFailure = nil
        tokenHubDirectFailure = nil; tokenHubQuotaIsDirect = false; tokenHubDirectScanInFlight = false
        tokenHubQuotaStatus = tokenHubQuotaReadingEnabled ? .targetNotRunning : .disabled
        lastTokenHubPermissionCheck = .distantPast; cachedTokenHubPermission = false
        _ = localRefreshScheduler.invalidate()
        localScan?.cancel(); localScan = nil
        localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0,
            filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
            knownThreadCount: 0, unknownThreadCount: 0, unidentifiedFileCount: 0,
            subagentCount: 0, forkCount: 0)
        resetQuotaState()
        let observationNow = tokenHubNow()
        scheduleLocalScan(immediate: true, observationNow: observationNow)
        if tokenHubQuotaReadingEnabled { scheduleTokenHubRefresh(after: 0, observationNow: observationNow) }
        installTokenHubWorkspaceObservers()
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        timer?.tolerance = 0.1
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func stopBackgroundResources() {
        timer?.invalidate(); timer = nil
        localScan?.cancel(); localScan = nil
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        for observer in tokenHubWorkspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        tokenHubWorkspaceObservers.removeAll()
    }

    private func stopBackgroundServices() {
        backgroundServicesStarted = false
        generation += 1; tokenHubGeneration &+= 1
        _ = localRefreshScheduler.invalidate()
        stopBackgroundResources()
        tokenHubQuotaSnapshot = nil; tokenHubQuotaFailure = nil
        tokenHubDirectFailure = nil; tokenHubQuotaIsDirect = false; tokenHubDirectScanInFlight = false
        tokenHubQuotaStatus = tokenHubQuotaReadingEnabled ? .targetNotRunning : .disabled
    }
    /// Clears quota values at a source transition without performing I/O.
    func resetQuotaState() {
        quota = nil
        fiveHourQuota = nil
        sevenDayQuota = nil
        quotaLoading = false
        quotaError = "Token Hub 界面快照数据未知"
    }
    private func scheduleLocalScan(immediate: Bool = false, observationNow scheduledObservationNow: Date? = nil) {
        guard backgroundServicesStarted else { return }
        let context = RefreshObservationContext(observationNow: scheduledObservationNow ?? tokenHubNow())
        localScan?.cancel()
        let version = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isShuttingDown, self.backgroundServicesStarted, self.generation == version,
                      self.config.dataSource == "localCodex" else { return }
                guard !self.localScanRunning else { return }
                guard let scanGeneration = self.localRefreshScheduler.begin(now: Date()) else {
                    self.scheduleLocalScan(immediate: false); return
                }
                self.localScanRunning = true
                let observationNow = context.observationNow
                // Production discovers the path and route inside the scan
                // worker. Injected legacy seams remain available for tests.
                let result: LocalCodexScanWorker.Result?
                if let scanDefault = self.localScanning.scanDefault {
                    result = try? await scanDefault(observationNow, version)
                } else {
                    if let resolveInputs = self.localScanning.resolveInputs,
                       let scan = self.localScanning.scan {
                        let inputs = resolveInputs()
                        result = try? await scan(inputs.directory, observationNow,
                                                version, inputs.routeContext)
                    } else {
                        result = nil
                    }
                }
                self.localScanRunning = false
                guard self.generation == version, self.localRefreshScheduler.complete(generation: scanGeneration, now: Date()) else {
                    if self.config.dataSource == "localCodex", self.backgroundServicesStarted, !self.isShuttingDown { self.scheduleLocalScan(immediate: true) }
                    return
                }
                if self.config.dataSource == "localCodex" {
                    if let snapshot = result?.snapshot {
                        self.localSnapshot = snapshot; self.fiveHourQuota = snapshot.fiveHour; self.sevenDayQuota = snapshot.sevenDay
                        self.quotaError = snapshot.latestEventAt == nil ? "未发现有效本地用量记录" : "额度来自 Codex 会话事件，可能已过期"
                    } else {
                        self.localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0, filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil, knownThreadCount: 0, unknownThreadCount: 0, unidentifiedFileCount: 0, subagentCount: 0, forkCount: 0)
                        self.fiveHourQuota = nil; self.sevenDayQuota = nil; self.quotaError = "本地会话记录暂时无法读取"
                    }
                }
                if self.config.dataSource == "localCodex", self.backgroundServicesStarted { self.scheduleLocalScan() }
            }
        }
        localScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 5), execute: work)
    }

    /// Associates the current Codex provider with this local Token Hub's
    /// configured origin. Historical rollout routes are not independently
    /// verifiable from the current provider name and configuration alone.
    nonisolated fileprivate static func seasunRouteContext() -> LocalCodexRouteContext {
        let configURL = LocalCodexUsageReader.defaultConfigURL()
        guard let active = GatewayDiscovery.activeCodexProvider(at: configURL),
              let connectionURLs = try? TokenHubConnectionDiscovery.readDefaultConnectionBaseURLs(),
              let activeOrigin = GatewayDiscovery.originKey(active.origin),
              connectionURLs.compactMap({ GatewayDiscovery.originKey($0) }).contains(activeOrigin) else {
            return .unverified
        }
        return .verified(provider: active.provider, origin: activeOrigin)
    }
    /// Production refresh first uses Token Hub's own read-only connection and
    /// in-memory SSO exchange. Preview and synthetic tests retain the
    /// bounded AX scanner path without touching real local credentials.
    func refreshTokenHubQuota(observationNow: Date? = nil) {
        guard !isShuttingDown else { return }
        guard config.dataSource == "localCodex", tokenHubQuotaReadingEnabled else {
            invalidateTokenHubQuota(status: .disabled); tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
            return
        }
        if !usesDirectQuotaSource {
            refreshTokenHubQuotaUsingAccessibility()
            return
        }
        if tokenHubAutomaticReadingEnabled { checkTokenHubPermissionIfDue(scheduleIfGranted: false) }
        guard !tokenHubDirectScanInFlight else { return }

        let version = tokenHubGeneration
        let now = observationNow ?? tokenHubNow()
        let source = directQuota
        let interval = config.refreshSeconds
        // Production resolves the target, reads settings and performs the
        // direct request inside its worker actor. Only the sanitized DTO
        // returns to this main-actor model.
        if let workerFetch = source.workerFetch {
            tokenHubDirectScanInFlight = true
            Task { [weak self] in
                let result: Result<DirectQuotaTransportSnapshot, Error>
                do { result = .success(try await workerFetch(now)) }
                catch { result = .failure(error) }
                guard let self else { return }
                guard !self.isShuttingDown, self.tokenHubGeneration == version else { return }
                self.tokenHubDirectScanInFlight = false
                guard self.config.dataSource == "localCodex", self.tokenHubQuotaReadingEnabled else { return }
                switch result {
                case .success(let transport):
                    self.tokenHubQuotaSnapshot = transport.materializedSnapshot()
                    self.tokenHubStatusConnected(interval: interval)
                case .failure(let error):
                    self.tokenHubStatusFailed(error, interval: interval)
                }
            }
            return
        }

        // Compatibility path for injected synthetic tests. Production never
        // reaches this branch, so its discovery and settings reads stay off
        // the main actor.
        let identity: TokenHubIdentity
        do { identity = try directQuota.discoverTarget() }
        catch {
            tokenHubDirectScanInFlight = false
            tokenHubQuotaSnapshot = nil; tokenHubQuotaIsDirect = false
            tokenHubDirectFailure = nil
            tokenHubQuotaStatus = (error as? TokenHubQuotaFailure) == .noTarget ? .targetNotRunning : .ambiguousTarget
            sourceReadinessText = tokenHubQuotaStatus == .targetNotRunning ? "Token Hub 未运行" : "检测到多个 Token Hub 进程"
            scheduleTokenHubRefresh(after: config.refreshSeconds)
            return
        }
        tokenHubDirectScanInFlight = true
        Task { [weak self] in
            let result: Result<TokenHubQuotaSnapshot, Error>
            do { result = .success(try await source.fetch(identity, now)) }
            catch { result = .failure(error) }
            guard let self else { return }
            // Invalidation already released the old generation. Its late
            // completion must not unlock a newer generation's active request.
            guard !self.isShuttingDown, self.tokenHubGeneration == version else { return }
            self.tokenHubDirectScanInFlight = false
            guard self.config.dataSource == "localCodex", self.tokenHubQuotaReadingEnabled else { return }
            switch result {
            case .success(let snapshot):
                guard source.identityIsCurrent(identity) else {
                    self.tokenHubQuotaSnapshot = nil
                    self.tokenHubQuotaIsDirect = false
                    self.tokenHubDirectFailure = .identityChanged
                    self.tokenHubQuotaStatus = .accessFailed
                    self.tokenHubQuotaFailure = nil
                    self.sourceReadinessText = "企业后台直接来源：\(self.directFailureText(.identityChanged))"
                    self.scheduleTokenHubRefresh(after: interval)
                    return
                }
                self.tokenHubQuotaSnapshot = snapshot
                self.tokenHubStatusConnected(interval: interval)
            case .failure(let error):
                self.tokenHubStatusFailed(error, interval: interval)
            }
        }
    }

    private func tokenHubStatusConnected(interval: TimeInterval) {
        tokenHubQuotaStatus = .connected
        tokenHubQuotaFailure = nil
        tokenHubDirectFailure = nil
        tokenHubQuotaIsDirect = true
        sourceReadinessText = "企业额度已自动读取 Token Hub 后台"
        scheduleTokenHubRefresh(after: interval)
    }

    private func tokenHubStatusFailed(_ error: Error, interval: TimeInterval) {
        let failure = (error as? TokenHubDirectQuotaFailure) ?? .transportFailed
        tokenHubQuotaSnapshot = nil
        tokenHubQuotaIsDirect = false
        tokenHubDirectFailure = failure
        if let targetFailure = error as? TokenHubQuotaFailure, targetFailure == .noTarget {
            tokenHubDirectFailure = nil
            tokenHubQuotaStatus = .targetNotRunning
            sourceReadinessText = "Token Hub 未运行"
            scheduleTokenHubRefresh(after: interval)
            return
        }
        if let targetFailure = error as? TokenHubQuotaFailure, targetFailure == .multipleTargets {
            tokenHubDirectFailure = nil
            tokenHubQuotaStatus = .ambiguousTarget
            sourceReadinessText = "检测到多个 Token Hub 进程"
            scheduleTokenHubRefresh(after: interval)
            return
        }
        tokenHubQuotaStatus = .accessFailed
        tokenHubQuotaFailure = nil
        sourceReadinessText = "企业后台直接来源：\(directFailureText(failure))"
        // AX is an optional compatibility fallback only when the user has
        // already granted trust; it never gates direct reading.
        if tokenHubAutomaticReadingEnabled, cachedTokenHubPermission, !isFixtureUsingNativeTokenHubReader {
            refreshTokenHubQuotaUsingAccessibility()
        } else {
            scheduleTokenHubRefresh(after: interval)
        }
    }

    private func refreshTokenHubQuotaUsingAccessibility() {
        guard !isShuttingDown else { return }
        guard !isFixtureUsingNativeTokenHubReader else { return }
        guard config.dataSource == "localCodex", tokenHubAutomaticReadingEnabled else {
            invalidateTokenHubQuota(status: .disabled); tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
            return
        }
        checkTokenHubPermissionIfDue(scheduleIfGranted: false)
        guard cachedTokenHubPermission else {
            invalidateAccessibilityQuota(status: .permissionRequired)
            // Trust can be revoked while the direct request is in flight.
            // Its optional fallback must not cancel the unattended retry loop.
            if usesDirectQuotaSource { scheduleTokenHubRefresh(after: config.refreshSeconds) }
            return
        }
        guard !tokenHubScanInFlight else { return }
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        tokenHubScanInFlight = true
        let version = tokenHubGeneration, axVersion = tokenHubAXGeneration, mode: TokenHubRunMode = .localCodex
        let now = tokenHubNow(), interval = config.refreshSeconds
        let source = tokenHubAXSource
        let request = TokenHubAXRequest(now: now, permissionTrusted: cachedTokenHubPermission,
            refreshSeconds: interval, mode: mode, generation: version)
        Task(priority: .utility) { [weak self] in
            // The main actor only awaits a value. Native traversal runs as one
            // non-suspending operation on its private worker actor.
            let result = await source.scan(request)
            guard let self else { return }
            self.tokenHubScanInFlight = false
            guard !self.isShuttingDown, self.tokenHubGeneration == version, self.tokenHubAXGeneration == axVersion,
                  self.config.dataSource == "localCodex", self.tokenHubAutomaticReadingEnabled,
                  self.cachedTokenHubPermission, !self.tokenHubQuotaIsDirect else {
                if !self.isShuttingDown, self.config.dataSource == "localCodex",
                   self.tokenHubQuotaReadingEnabled {
                    self.scheduleTokenHubRefresh(after: self.tokenHubQuotaIsDirect ? interval : 0)
                }
                return
            }
            self.applyTokenHubQuotaResult(result, generation: version, mode: mode, now: now)
            self.scheduleTokenHubRefresh(after: self.config.refreshSeconds)
        }
    }

    func setTokenHubAutomaticReadingEnabled(_ enabled: Bool) {
        guard tokenHubAutomaticReadingEnabled != enabled else { return }
        preferences.tokenHubCompatibilityReadEnabled = enabled
        tokenHubAXGeneration &+= 1
        config.tokenHubAutomaticReadingEnabled = enabled
        if usesDirectQuotaSource {
            // This preference controls only AX compatibility; it cannot turn
            // off the unattended enterprise source or discard its snapshot.
            if !tokenHubQuotaIsDirect {
                tokenHubQuotaSnapshot = nil; tokenHubQuotaFailure = nil
                tokenHubQuotaStatus = .targetNotRunning
            }
            if config.dataSource == "localCodex", !isShuttingDown, backgroundServicesStarted || isPreview {
                scheduleTokenHubRefresh(after: 0)
            }
            return
        }
        tokenHubGeneration &+= 1
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        if enabled && config.dataSource == "localCodex" && !isShuttingDown && (backgroundServicesStarted || isPreview) {
            tokenHubQuotaStatus = .targetNotRunning; tokenHubQuotaFailure = nil
            lastTokenHubPermissionCheck = .distantPast
            scheduleTokenHubRefresh(after: 0)
        } else { invalidateTokenHubQuota(status: .disabled) }
    }

    func requestTokenHubAccessibilityAccess() {
        guard !isPreview, !isTestFixture, config.dataSource == "localCodex", tokenHubAutomaticReadingEnabled, !isShuttingDown else { return }
        permissionPromptRequested = true
        tokenHubPermissionProvider.requestOnceAndOpenSystemSettings()
        lastTokenHubPermissionCheck = .distantPast
        checkTokenHubPermissionIfDue(scheduleIfGranted: false)
        if cachedTokenHubPermission { refreshTokenHubQuota() }
        else { invalidateAccessibilityQuota(status: .permissionRequired) }
    }

    private func invalidateAccessibilityQuota(status: TokenHubQuotaStatus) {
        tokenHubAXGeneration &+= 1
        if !usesDirectQuotaSource {
            invalidateTokenHubQuota(status: status)
        } else if !tokenHubQuotaIsDirect, !tokenHubDirectScanInFlight {
            tokenHubQuotaSnapshot = nil; tokenHubQuotaFailure = nil
            // Keep a direct failure (if any) visible; missing AX trust is not
            // a failure of the automatic source.
            if tokenHubDirectFailure == nil { tokenHubQuotaStatus = .targetNotRunning }
        }
    }

    func invalidateTokenHubQuota(status: TokenHubQuotaStatus) {
        tokenHubGeneration &+= 1
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        tokenHubQuotaSnapshot = nil; tokenHubQuotaFailure = nil; tokenHubDirectFailure = nil
        tokenHubQuotaIsDirect = false; tokenHubDirectScanInFlight = false; tokenHubQuotaStatus = status
    }

    func applyTokenHubQuotaResult(_ result: TokenHubQuotaResult, generation resultGeneration: UInt64,
                                  mode: TokenHubRunMode, now: Date) {
        guard !isShuttingDown, tokenHubGeneration == resultGeneration, cachedTokenHubPermission,
              config.dataSource == "localCodex", mode == .localCodex,
              tokenHubAutomaticReadingEnabled else { return }
        if result.status == .connected, let snapshot = result.snapshot {
            if let previous = tokenHubQuotaSnapshot, previous.identity != snapshot.identity {
                tokenHubQuotaSnapshot = nil
            }
            tokenHubQuotaSnapshot = snapshot
            tokenHubQuotaIsDirect = false
            tokenHubQuotaStatus = snapshot.observedAt > now || now.timeIntervalSince(snapshot.observedAt) > max(120, config.refreshSeconds * 2)
                ? .stale : .connected
            tokenHubQuotaFailure = nil
        } else {
            tokenHubQuotaSnapshot = nil
            tokenHubQuotaStatus = result.status
            tokenHubQuotaFailure = result.failure
        }
    }

    func freshTokenHubQuota(at now: Date) -> TokenHubQuotaSnapshot? {
        guard config.dataSource == "localCodex", tokenHubQuotaReadingEnabled,
              tokenHubQuotaStatus == .connected, let snapshot = tokenHubQuotaSnapshot,
              snapshot.observedAt <= now,
              now.timeIntervalSince(snapshot.observedAt) <= max(120, config.refreshSeconds * 2) else { return nil }
        return snapshot
    }

    private func checkTokenHubPermissionIfDue(scheduleIfGranted: Bool = true) {
        guard backgroundServicesStarted || isPreview else { return }
        let now = tokenHubNow()
        guard now.timeIntervalSince(lastTokenHubPermissionCheck) >= 2 else { return }
        let old = cachedTokenHubPermission
        cachedTokenHubPermission = tokenHubPermissionProvider.isTrusted()
        lastTokenHubPermissionCheck = now
        if old && !cachedTokenHubPermission { invalidateAccessibilityQuota(status: .permissionRequired) }
        if scheduleIfGranted && !old && cachedTokenHubPermission && config.dataSource == "localCodex" && tokenHubAutomaticReadingEnabled {
            scheduleTokenHubRefresh(after: 0)
        }
    }

    private func pollTokenHubPermissionIfDue() {
        guard backgroundServicesStarted, config.dataSource == "localCodex", tokenHubAutomaticReadingEnabled, !isShuttingDown,
              !isFixtureUsingNativeTokenHubReader else { return }
        checkTokenHubPermissionIfDue()
    }

    private func scheduleTokenHubRefresh(after seconds: TimeInterval, observationNow scheduledObservationNow: Date? = nil) {
        guard (backgroundServicesStarted || isPreview), config.dataSource == "localCodex", tokenHubQuotaReadingEnabled,
              !isShuttingDown, (usesDirectQuotaSource || !tokenHubScanInFlight), !isFixtureUsingNativeTokenHubReader else { return }
        let context = RefreshObservationContext(observationNow: scheduledObservationNow ?? tokenHubNow())
        tokenHubRefreshWork?.cancel()
        let version = tokenHubGeneration
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.isShuttingDown, self.tokenHubGeneration == version,
                      self.config.dataSource == "localCodex", self.tokenHubQuotaReadingEnabled else { return }
                self.refreshTokenHubQuota(observationNow: context.observationNow)
            }
        }
        tokenHubRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds), execute: work)
    }

    static func shouldSuppressNativeTokenHubRead(isTestFixture: Bool, scannerIsNative: Bool) -> Bool {
        isTestFixture && scannerIsNative
    }
    var isFixtureUsingNativeTokenHubReader: Bool {
        Self.shouldSuppressNativeTokenHubRead(isTestFixture: isTestFixture,
            scannerIsNative: tokenHubAXSource.kind == .native)
    }

    private func installTokenHubWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier else { return }
                Task { @MainActor in
                    if name == NSWorkspace.didLaunchApplicationNotification {
                        self?.tokenHubApplicationDidLaunch(bundleIdentifier: bundleID)
                    } else {
                        self?.tokenHubApplicationDidTerminate(bundleIdentifier: bundleID)
                    }
                }
            }
            tokenHubWorkspaceObservers.append(observer)
        }
    }

    /// Metadata-only lifecycle seam; no AX values or target contents are read here.
    func tokenHubApplicationDidTerminate(bundleIdentifier: String) {
        guard isPreview || backgroundServicesStarted else { return }
        guard bundleIdentifier == TokenHubTarget.bundleID, !isShuttingDown else { return }
        invalidateTokenHubQuota(status: config.dataSource == "localCodex" ? .targetNotRunning : .disabled)
    }

    /// Metadata-only lifecycle seam; a launch never makes an old snapshot current.
    func tokenHubApplicationDidLaunch(bundleIdentifier: String) {
        guard isPreview || backgroundServicesStarted else { return }
        guard bundleIdentifier == TokenHubTarget.bundleID, !isShuttingDown else { return }
        invalidateTokenHubQuota(status: config.dataSource == "localCodex" && tokenHubQuotaReadingEnabled
            ? .targetNotRunning : .disabled)
        guard config.dataSource == "localCodex", tokenHubQuotaReadingEnabled,
              !isFixtureUsingNativeTokenHubReader else { return }
        if usesDirectQuotaSource {
            scheduleTokenHubRefresh(after: 0)
            return
        }
        checkTokenHubPermissionIfDue(scheduleIfGranted: false)
        guard cachedTokenHubPermission else {
            tokenHubQuotaStatus = .permissionRequired
            return
        }
        scheduleTokenHubRefresh(after: 0)
    }

}
