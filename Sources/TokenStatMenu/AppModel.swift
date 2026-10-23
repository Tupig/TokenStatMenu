import AppKit
import Combine
import CoreFoundation
#if SWIFT_PACKAGE
@preconcurrency import TokenStatCore
import TokenStatWidgetShared
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
    var observeWorkspaceNotifications: Bool = false

    static var production: AppModelStartupDependencies {
        AppModelStartupDependencies(
            loadPreferences: { try ConfigStore.loadPreferences(at: AppPaths.configURL) },
            savePreferences: { try ConfigStore.savePreferences($0) },
            shouldStartBackgroundServices: { !CommandLine.arguments.contains("--disable-background-services") },
            observeWorkspaceNotifications: true)
    }
}

struct AppModelTimingDependencies {
    let wallNow: @Sendable () -> Date
    let monotonicNow: @Sendable () -> TimeInterval
    let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)

    init(wallNow: @escaping @Sendable () -> Date,
         monotonicNow: @escaping @Sendable () -> TimeInterval,
         schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)) {
        self.wallNow = wallNow
        self.monotonicNow = monotonicNow
        self.schedule = schedule
    }

    static var production: AppModelTimingDependencies {
        let clock = ContinuousClock()
        let origin = clock.now
        return AppModelTimingDependencies(
            wallNow: { Date() },
            monotonicNow: {
                let elapsed = origin.duration(to: clock.now).components
                return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            },
            schedule: { delay, operation in
                let work = DispatchWorkItem { MainActor.assumeIsolated { operation() } }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                return { work.cancel() }
            })
    }
}

/// 后台任务仅返回可显示的额度数据，不携带进程身份、URL、数据库路径、会话、令牌或响应正文。
/// 目标身份由后台任务在请求前后校验。
struct DirectQuotaTransportSnapshot: Sendable {
    let fiveHour: TokenHubWindowQuota?
    let sevenDay: TokenHubWindowQuota?
    let monthly: TokenHubMonthlyUsage?
    /// 重置券数量；接口失败时为 nil，不能当作 0。
    let resetVoucherCount: Int?
    let observedAt: Date

    func materializedSnapshot() -> TokenHubQuotaSnapshot {
        // 保留旧快照结构以兼容界面和测试；真实 PID 和可执行路径不跨 actor 边界。
        let sanitizedIdentity = TokenHubIdentity(pid: 0, bundleID: TokenHubTarget.bundleID,
                                                  executablePath: "sanitized")
        return TokenHubQuotaSnapshot(identity: sanitizedIdentity, fiveHour: fiveHour,
                                     sevenDay: sevenDay, monthly: monthly,
                                     resetVoucherCount: resetVoucherCount,
                                     observedAt: observedAt)
    }

    init(snapshot: TokenHubQuotaSnapshot) {
        fiveHour = snapshot.fiveHour; sevenDay = snapshot.sevenDay
        monthly = snapshot.monthly; resetVoucherCount = snapshot.resetVoucherCount
        observedAt = snapshot.observedAt
    }
}

/// 在主 actor 之外执行进程发现、设置与 SQLite 读取及认证请求，身份和凭据不离开此 actor。
private actor TokenHubDirectQuotaWorker {
    private let client = TokenHubDirectQuotaClient()

    func fetch(nowProvider: @Sendable () -> Date) async throws -> DirectQuotaTransportSnapshot {
        let observedAt = nowProvider()
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: TokenHubTarget.bundleID)
            .filter { !$0.isTerminated }
        guard !applications.isEmpty else { throw TokenHubQuotaFailure.noTarget }
        guard applications.count == 1, let app = applications.first,
              let executable = app.executableURL?.standardizedFileURL.path,
              let bundle = app.bundleIdentifier else {
            throw applications.count > 1 ? TokenHubQuotaFailure.multipleTargets : TokenHubQuotaFailure.identityChanged
        }
        let identity = TokenHubIdentity(pid: app.processIdentifier, bundleID: bundle, executablePath: executable)
        let snapshot = try await client.fetch(identity: identity, nowProvider: nowProvider,
                                              observationAt: observedAt)
        try Task.checkCancellation()
        // TokenHubDirectQuotaClient 在网络交换前后校验配置和数据库身份，不返回目标身份。
        return DirectQuotaTransportSnapshot(snapshot: snapshot)
    }
}

/// 将进程发现和认证 I/O 与生命周期处理分开，通过注入支持使用模拟数据的预览。
struct TokenHubDirectQuotaDependencies {
    let discoverTarget: () throws -> TokenHubIdentity
    let identityIsCurrent: (TokenHubIdentity) -> Bool
    let fetch: (TokenHubIdentity, Date) async throws -> TokenHubQuotaSnapshot
    /// 正式运行使用此后台闭包，其余三个 actor 隔离闭包仅保留为测试注入点。
    let workerFetch: (@Sendable (@Sendable () -> Date) async throws -> DirectQuotaTransportSnapshot)?

    init(discoverTarget: @escaping () throws -> TokenHubIdentity,
         identityIsCurrent: @escaping (TokenHubIdentity) -> Bool,
         fetch: @escaping (TokenHubIdentity, Date) async throws -> TokenHubQuotaSnapshot,
         workerFetch: (@Sendable (@Sendable () -> Date) async throws -> DirectQuotaTransportSnapshot)? = nil) {
        self.discoverTarget = discoverTarget
        self.identityIsCurrent = identityIsCurrent
        self.fetch = fetch
        self.workerFetch = workerFetch
    }

    static var production: TokenHubDirectQuotaDependencies {
        let worker = TokenHubDirectQuotaWorker()
        // 正式运行不执行这些兼容闭包，发现、设置读取和网络操作均由上述 actor 负责。
        return TokenHubDirectQuotaDependencies(discoverTarget: { throw TokenHubQuotaFailure.noTarget },
            identityIsCurrent: { _ in false },
            fetch: { _, _ in throw TokenHubDirectQuotaFailure.transportFailed },
            workerFetch: { nowProvider in try await worker.fetch(nowProvider: nowProvider) })
    }
}

/// 在单一执行器中管理非 Sendable 可变缓存，仅向主 actor 返回数值快照，不传递缓存引用。
actor LocalCodexScanWorker {
    struct Result: Sendable {
        let snapshot: LocalCodexSnapshot
        let diagnostics: LocalCodexUsageReader.Cache.Diagnostics
    }

    private var cache = LocalCodexUsageReader.Cache()
    private var archiveCache = LocalCodexUsageReader.Cache()
    private var cacheGeneration: Int?

    func invalidate(generation: Int) {
        if let cacheGeneration, generation <= cacheGeneration { return }
        cache = LocalCodexUsageReader.Cache()
        archiveCache = LocalCodexUsageReader.Cache()
        cacheGeneration = generation
    }

    private func prepareCache(for generation: Int) throws {
        if let cacheGeneration, generation < cacheGeneration { throw CancellationError() }
        if cacheGeneration != generation {
            cache = LocalCodexUsageReader.Cache()
            archiveCache = LocalCodexUsageReader.Cache()
            cacheGeneration = generation
        }
    }

    func scan(directory: URL, now: Date, generation: Int,
              routeContext: LocalCodexRouteContext?) throws -> Result {
        try scan(directory: directory, nowProvider: { now }, generation: generation,
                  routeContext: routeContext)
    }

    func scan(directory: URL, nowProvider: @Sendable () -> Date, generation: Int,
              routeContext: LocalCodexRouteContext?) throws -> Result {
        try prepareCache(for: generation)
        // 使用缓存期间无挂起点，actor 隔离保证读取和失效处理串行执行。
        let now = nowProvider()
        let snapshot = try LocalCodexUsageReader.scan(directory: directory, now: now,
                                                       cache: cache, routeContext: routeContext)
        return Result(snapshot: snapshot, diagnostics: cache.diagnostics)
    }

    /// 发现与扫描在同一后台任务中执行，会话路径和路由源站不传回主 actor。
    func scanDefault(nowProvider: @Sendable () -> Date, generation: Int) throws -> Result {
        try prepareCache(for: generation)
        let now = nowProvider()
        let directory = LocalCodexUsageReader.defaultSessionsDirectory()
        let routeContext = AppModel.seasunRouteContext()
        let snapshot = try LocalCodexUsageReader.scanCodexHome(sessions: directory, now: now,
                                                               cache: cache, archiveCache: archiveCache,
                                                               routeContext: routeContext)
        return Result(snapshot: snapshot, diagnostics: cache.diagnostics)
    }

    func scanInjected(directory: URL, nowProvider: @Sendable () -> Date, generation: Int,
                      routeContext: LocalCodexRouteContext,
                      operation: @Sendable (URL, Date, Int, LocalCodexRouteContext) async throws -> Result) async throws -> Result {
        let now = nowProvider()
        return try await operation(directory, now, generation, routeContext)
    }
}

/// 在主 actor 解析允许的输入，由缓存持有者限量读取文件；生命周期测试通过注入替代外部 I/O。
struct LocalCodexScanDependencies {
    /// 旧测试注入点可选；正式运行仅使用后台 `scanDefault`，真实会话 URL 不跨 actor 边界。
    let resolveInputs: (@MainActor () -> (directory: URL, routeContext: LocalCodexRouteContext))?
    let scan: (@Sendable (URL, Date, Int, LocalCodexRouteContext) async throws -> LocalCodexScanWorker.Result)?
    let scanDefault: (@Sendable (@Sendable () -> Date, Int) async throws -> LocalCodexScanWorker.Result)?
    let invalidate: (@Sendable (Int) async -> Void)?

    init(resolveInputs: @escaping @MainActor () -> (directory: URL, routeContext: LocalCodexRouteContext),
         scan: @escaping @Sendable (URL, Date, Int, LocalCodexRouteContext) async throws -> LocalCodexScanWorker.Result,
         scanDefault: (@Sendable (@Sendable () -> Date, Int) async throws -> LocalCodexScanWorker.Result)? = nil,
         invalidate: (@Sendable (Int) async -> Void)? = nil) {
        self.resolveInputs = resolveInputs
        self.scan = scan
        self.scanDefault = scanDefault
        self.invalidate = invalidate
    }

    private init(resolveInputs: (@MainActor () -> (directory: URL, routeContext: LocalCodexRouteContext))?,
                 scan: (@Sendable (URL, Date, Int, LocalCodexRouteContext) async throws -> LocalCodexScanWorker.Result)?,
                 scanDefault: (@Sendable (@Sendable () -> Date, Int) async throws -> LocalCodexScanWorker.Result)?,
                 invalidate: (@Sendable (Int) async -> Void)?) {
        self.resolveInputs = resolveInputs
        self.scan = scan
        self.scanDefault = scanDefault
        self.invalidate = invalidate
    }

    @MainActor static var production: LocalCodexScanDependencies {
        let worker = LocalCodexScanWorker()
        // 不在主 actor 解析真实会话 URL，发现和路由读取留在持有缓存的扫描任务中。
        return LocalCodexScanDependencies(resolveInputs: nil, scan: nil,
            scanDefault: { nowProvider, generation in try await worker.scanDefault(nowProvider: nowProvider, generation: generation) },
            invalidate: { generation in await worker.invalidate(generation: generation) })
    }
}

struct BackgroundServiceResources: Equatable, Encodable {
    let timerCount: Int
    let workspaceObserverCount: Int
    let localScanQueuedCount: Int
    let axRefreshScheduledCount: Int
    let axScanInFlightCount: Int
}

/// 将时钟引起的显示变化与新数据分开，用布尔值维持半秒刷新，避免重复格式化日期和重绘视图。
struct PresentationTimeState: Equatable {
    struct Window: Equatable {
        let futureObservation: Bool
        let fresh: Bool
        let resetPassed: Bool
        let resetAt: Date?
    }
    let localLive: Bool
    let tokenHubFresh: Bool
    let monthlyFresh: Bool
    let fiveHour: Window?
    let sevenDay: Window?
}

/// 按同一时刻计算 Token Hub 的显示状态，使菜单、诊断和卡片一致，避免重复格式化日期和 Decimal。
struct TokenHubQuotaPresentation: Equatable, Sendable {
    enum AlertLevel: Equatable, Sendable { case none, warning, critical }

    struct WindowProjection: Equatable, Sendable {
        let futureObservation: Bool
        let fresh: Bool
        let resetPassed: Bool
        let resetAt: Date?
    }

    let snapshot: TokenHubQuotaSnapshot?
    let futureObservation: Bool
    let snapshotFresh: Bool
    let fiveHourCurrent: TokenHubWindowQuota?
    let sevenDayCurrent: TokenHubWindowQuota?
    let monthlyCurrent: TokenHubMonthlyUsage?
    let fiveHour: WindowProjection?
    let sevenDay: WindowProjection?
    let menuAlertLevel: AlertLevel

    static func project(snapshot: TokenHubQuotaSnapshot?, now: Date,
                        refreshSeconds: TimeInterval) -> TokenHubQuotaPresentation {
        guard let snapshot else {
            return TokenHubQuotaPresentation(snapshot: nil, futureObservation: false, snapshotFresh: false,
                fiveHourCurrent: nil, sevenDayCurrent: nil, monthlyCurrent: nil,
                fiveHour: nil, sevenDay: nil, menuAlertLevel: .none)
        }
        let future = snapshot.observedAt > now
        let fresh = !future && now.timeIntervalSince(snapshot.observedAt) <= max(120, refreshSeconds * 2)
        func window(_ value: TokenHubWindowQuota?) -> WindowProjection? {
            value.map { raw in
                WindowProjection(futureObservation: future, fresh: fresh,
                    resetPassed: raw.resetAt.map { $0 <= now } ?? false, resetAt: raw.resetAt)
            }
        }
        let fiveProjection = window(snapshot.fiveHour)
        let sevenProjection = window(snapshot.sevenDay)
        let fiveCurrent = fresh && fiveProjection?.resetPassed != true ? snapshot.fiveHour : nil
        let sevenCurrent = fresh && sevenProjection?.resetPassed != true ? snapshot.sevenDay : nil
        let monthly = fresh ? snapshot.monthly : nil
        let highest = [fiveCurrent?.usedPercent, sevenCurrent?.usedPercent].compactMap { $0 }.max()
        let alert: AlertLevel
        if let highest, highest >= Decimal(95) { alert = .critical }
        else if let highest, highest >= Decimal(80) { alert = .warning }
        else { alert = .none }
        return TokenHubQuotaPresentation(snapshot: snapshot, futureObservation: future, snapshotFresh: fresh,
            fiveHourCurrent: fiveCurrent, sevenDayCurrent: sevenCurrent, monthlyCurrent: monthly,
            fiveHour: fiveProjection, sevenDay: sevenProjection, menuAlertLevel: alert)
    }
}

@MainActor final class AppModel: ObservableObject {
    // 仅启动时显式设置，测试数据不作为企业实测数据。
    let isTestFixture = CommandLine.arguments.contains("--test-fixture")
    private let isPreview: Bool
    private let startup: AppModelStartupDependencies
    private let timing: AppModelTimingDependencies
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
                if !history.isEmpty { history.removeAll(keepingCapacity: true) }
                lastHistorySampleMonotonic = nil
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
    var tokenHubPermissionProvider: TokenHubPermissionProviding
    private var legacyTokenHubNow: (() -> Date)?
    var tokenHubNow: () -> Date {
        get { legacyTokenHubNow ?? timing.wallNow }
        set { legacyTokenHubNow = newValue }
    }
    @Published var panelVisible = false
    let engine = MetricsEngine()
    private var timer: Timer?
    private var localScan: (@MainActor () -> Void)?
    private var localScanRunning = false
    private var localScanTicket: UInt64 = 0
    private var localScanRunTicket: UInt64?
    private var localScanDeferredGeneration: Int?
    private var tokenHubRefreshWork: (@MainActor () -> Void)?
    private var tokenHubRefreshTicket: UInt64 = 0
    private var tokenHubScanInFlight = false
    private var tokenHubDirectScanInFlight = false
    private var tokenHubWorkspaceObservers: [NSObjectProtocol] = []
    private var lastTokenHubPermissionCheck = Date.distantPast
    private var cachedTokenHubPermission = false
    private let localScanning: LocalCodexScanDependencies
    private let localInjectedWorker = LocalCodexScanWorker()
    private var localRefreshScheduler = LocalRefreshScheduler()
    private var isShuttingDown = false
    private var generation = 0
    private var tokenHubGeneration: UInt64 = 0
    private var tokenHubAXGeneration: UInt64 = 0
    private var lastPresentationTimeState: PresentationTimeState?
    private var lastHistorySampleMonotonic: TimeInterval?
    /// 将显示数据发布到内嵌小组件的 App Group。
    private let widgetPublisher = WidgetSnapshotPublisher()
    /// 只跳过首次读取尚未结束的空状态；后续失败必须发布未知。
    private(set) var hasCompletedInitialQuotaRead = false
    var shouldPublishWidgetState: Bool {
        tokenHubQuotaSnapshot != nil || hasCompletedInitialQuotaRead
    }
    var widgetSnapshotPublished: Bool { widgetPublisher.lastPublishSucceeded }
    var widgetChannelUnavailable: Bool { widgetPublisher.channelUnavailable }
    var onTick: (() -> Void)?

    private static let historyDuration: TimeInterval = 10 * 60
    private static let historyCapacity = 1_200
    private static let localCachePercentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfUp
        return formatter
    }()

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
            localScanQueuedCount: localScan == nil ? 0 : 1,
            axRefreshScheduledCount: tokenHubRefreshWork == nil ? 0 : 1,
            axScanInFlightCount: tokenHubScanInFlight ? 1 : 0)
    }

    init(preview: Bool = false, startup: AppModelStartupDependencies = .production,
         timing: AppModelTimingDependencies = .production,
         directQuota: TokenHubDirectQuotaDependencies? = nil,
         localScanning: LocalCodexScanDependencies? = nil,
         tokenHubPermissionProvider: TokenHubPermissionProviding? = nil,
         tokenHubAXSource: TokenHubAXSource? = nil) {
        isPreview = preview
        self.startup = startup
        self.timing = timing
        self.directQuota = directQuota ?? .production
        self.tokenHubAXSource = tokenHubAXSource ?? .production
        self.localScanning = localScanning ?? .production
        self.tokenHubPermissionProvider = tokenHubPermissionProvider ?? TokenHubNativePermissionProvider()
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
        localScanDeferredGeneration = nil
        generation += 1; _ = localRefreshScheduler.invalidate()
        invalidateLocalWorker(generation: generation)
        clearLocalSnapshot()
        lastHistorySampleMonotonic = nil
        timer?.invalidate(); timer = nil; cancelLocalScanSchedule()
        tokenHubGeneration &+= 1
        cancelTokenHubSchedule()
        for observer in tokenHubWorkspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        tokenHubWorkspaceObservers.removeAll()
        tokenHubQuotaSnapshot = nil; tokenHubQuotaStatus = .disabled; tokenHubQuotaFailure = nil
        tokenHubDirectFailure = nil; tokenHubQuotaIsDirect = false; tokenHubDirectScanInFlight = false
    }
    func tick() {
        let now = tokenHubNow()
        updateLocalHistory(at: now, monotonicNow: timing.monotonicNow())
        // 本地历史模式不使用代理指标，跳过相同空快照，避免每秒重绘两次；旧代理预览仍采样。
        if config.dataSource != "localCodex" { stats = engine.snapshot() }
        var publishedTransition = false
        // 先检查额度是否存在，避免空闲刷新为缺失额度创建日期格式化器。
        if let quota, quota.month != QuotaSnapshot.currentMonth(at: now) {
            self.quota = nil
            publishedTransition = true
        }
        if tokenHubQuotaStatus == .connected,
           !TokenHubQuotaPresentation.project(snapshot: tokenHubQuotaSnapshot, now: now,
                refreshSeconds: config.refreshSeconds).snapshotFresh {
            tokenHubQuotaStatus = .stale
            publishedTransition = true
        }
        if backgroundServicesStarted { pollTokenHubPermissionIfDue() }
        let timeState = presentationTimeState(at: now, quotaPresentation: quotaPresentation(at: now))
        if let previous = lastPresentationTimeState, previous != timeState, !publishedTransition {
            objectWillChange.send()
        }
        lastPresentationTimeState = timeState
        publishWidgetSnapshot(at: now)
        onTick?()
    }

    /// 将菜单栏当前显示的值映射到共享快照。
    ///
    /// 过期、重置或缺失的窗口同样输出为未知，使小组件与菜单一致。
    private func publishWidgetSnapshot(at now: Date) {
        // 预览和测试不发布快照，避免模拟数值出现在真实系统界面。
        guard !isPreview, !isTestFixture else { return }
        let presentation = quotaPresentation(at: now)
        guard shouldPublishWidgetState else { return }
        let source: WidgetQuotaSnapshot.HubSource
        if tokenHubQuotaIsDirect, tokenHubQuotaStatus == .connected || tokenHubQuotaStatus == .stale {
            source = .direct
        } else if tokenHubQuotaSnapshot != nil {
            source = .compatibility
        } else {
            source = .none
        }
        var state: WidgetQuotaSnapshot.HubState = .unavailable
        switch tokenHubQuotaStatus {
        case .connected: state = .ready
        case .stale: state = .stale
        case .disabled: state = .disabled
        case .unsupportedLayout, .accessFailed, .quotaGroupUnavailable,
             .permissionRequired, .targetNotRunning, .ambiguousTarget: state = .unavailable
        }
        if presentation.snapshot == nil { state = .unavailable }

        // 过期或重置时 `fiveHourCurrent` 已为 nil，直接映射，无需再次判断有效期。
        func window(_ quota: TokenHubWindowQuota?) -> WidgetQuotaSnapshot.Window? {
            guard let quota else { return nil }
            let percent = NSDecimalNumber(decimal: quota.remainingPercent).doubleValue
            guard percent.isFinite, (0...100).contains(percent) else { return nil }
            let used = NSDecimalNumber(decimal: quota.usedAmount).doubleValue
            let limit = NSDecimalNumber(decimal: quota.limitAmount).doubleValue
            return WidgetQuotaSnapshot.Window(
                remainingPercent: percent, resetsAt: quota.resetAt,
                usedAmount: used.isFinite && used >= 0 ? used : nil,
                limitAmount: limit.isFinite && limit >= 0 ? limit : nil,
                sourceSymbol: quota.sourceSymbol.count <= 4 ? quota.sourceSymbol : nil)
        }

        let monthly = presentation.monthlyCurrent.map { usage in
            WidgetQuotaSnapshot.Monthly(
                usedAmount: NSDecimalNumber(decimal: usage.usedAmount).doubleValue,
                limitAmount: usage.limitAmount.map { NSDecimalNumber(decimal: $0).doubleValue },
                sourceSymbol: usage.sourceSymbol)
        }
        let local: WidgetQuotaSnapshot.Local? = {
            let snapshot = localSnapshot
            guard snapshot.filesScanned > 0 || snapshot.total > 0 else { return nil }
            return WidgetQuotaSnapshot.Local(
                inputTokens: snapshot.input, outputTokens: snapshot.output,
                totalTokens: snapshot.total, knownThreads: snapshot.knownThreadCount,
                unknownThreads: snapshot.unknownThreadCount, isLimited: snapshot.isLimited)
        }()
        let observedAt = tokenHubQuotaSnapshot?.observedAt
        let published = WidgetQuotaSnapshot(
            writtenAt: now, observedAt: observedAt,
            validUntil: observedAt.map { $0.addingTimeInterval(max(120, config.refreshSeconds * 2)) },
            hubSource: source, hubState: state,
            fiveHour: window(presentation.fiveHourCurrent),
            sevenDay: window(presentation.sevenDayCurrent),
            monthly: monthly, local: local,
            resetVoucherCount: presentation.snapshotFresh ? presentation.snapshot?.resetVoucherCount : nil)
        widgetPublisher.publish(published)
    }

    /// 每次刷新只保留最近十分钟闭区间内的样本，界面隐藏或无法采样时也清理。
    /// 追加样本另由单调时间限频。
    private func updateLocalHistory(at now: Date, monotonicNow: TimeInterval) {
        var retained = retainedHistory(at: now)
        defer { publishHistoryIfChanged(retained) }

        guard panelVisible, config.dataSource == "localCodex",
              let live = freshLocalLiveTurn(at: now),
              live.outputTPS.isFinite, live.outputTPS >= 0,
              monotonicNow.isFinite else { return }
        if let lastHistorySampleMonotonic,
           monotonicNow - lastHistorySampleMonotonic < 0.5 { return }

        lastHistorySampleMonotonic = monotonicNow
        retained.append(SpeedPoint(date: now, value: live.outputTPS))
        if retained.count > Self.historyCapacity {
            retained.removeFirst(retained.count - Self.historyCapacity)
        }
    }

    private func retainedHistory(at now: Date) -> [SpeedPoint] {
        let cutoff = now.addingTimeInterval(-Self.historyDuration)
        var retained = history.filter { point in
            point.date >= cutoff && point.date <= now
        }
        if retained.count > Self.historyCapacity {
            retained.removeFirst(retained.count - Self.historyCapacity)
        }
        return retained
    }

    private func publishHistoryIfChanged(_ updated: [SpeedPoint]) {
        guard updated.count != history.count || zip(updated, history).contains(where: { pair in
            pair.0.id != pair.1.id || pair.0.date != pair.1.date
                || pair.0.value.bitPattern != pair.1.value.bitPattern
        }) else { return }
        history = updated
    }

    /// 面板可能在两次定时器回调之间打开，首次绘图前先清除过期和未来样本。
    func pruneHistoryBeforePanelDisplay() {
        let now = tokenHubNow()
        publishHistoryIfChanged(retainedHistory(at: now))
    }
    var freshQuota: QuotaSnapshot? { freshQuota(at: tokenHubNow()) }
    func freshQuota(at now: Date) -> QuotaSnapshot? {
        guard let quota, quota.month == QuotaSnapshot.currentMonth(at: now),
              quota.fetchedAt <= now,
              now.timeIntervalSince(quota.fetchedAt) < max(120, config.refreshSeconds * 2) else { return nil }
        return quota
    }
    /// 数据可能在定时器回调间到达并过期，输入变化后需保存时间状态，以匹配 SwiftUI 实际显示的值。
    private func capturePresentationTimeBaseline() {
        lastPresentationTimeState = presentationTimeState
    }
    var presentationTimeState: PresentationTimeState {
        let now = tokenHubNow()
        return presentationTimeState(at: now, quotaPresentation: quotaPresentation(at: now))
    }
    func presentationTimeState(at now: Date, quotaPresentation: TokenHubQuotaPresentation) -> PresentationTimeState {
        func window(_ value: WindowQuota?) -> PresentationTimeState.Window? {
            value.map { PresentationTimeState.Window(futureObservation: $0.fetchedAt > now,
                fresh: $0.isFresh(at: now, refreshSeconds: config.refreshSeconds),
                resetPassed: $0.resetsAt.map { $0 <= now } ?? false, resetAt: $0.resetsAt) }
        }
        let fiveHourState = quotaPresentation.fiveHour.map {
            PresentationTimeState.Window(futureObservation: $0.futureObservation, fresh: $0.fresh,
                resetPassed: $0.resetPassed, resetAt: $0.resetAt)
        }
        let sevenDayState = quotaPresentation.sevenDay.map {
            PresentationTimeState.Window(futureObservation: $0.futureObservation, fresh: $0.fresh,
                resetPassed: $0.resetPassed, resetAt: $0.resetAt)
        }
        return PresentationTimeState(localLive: freshLocalLiveTurn(at: now) != nil,
            tokenHubFresh: quotaPresentation.snapshotFresh, monthlyFresh: freshQuota(at: now) != nil,
            fiveHour: tokenHubQuotaIsDirect ? fiveHourState : window(fiveHourQuota),
            sevenDay: tokenHubQuotaIsDirect ? sevenDayState : window(sevenDayQuota))
    }
    var quotaPresentation: TokenHubQuotaPresentation { quotaPresentation(at: tokenHubNow()) }
    func quotaPresentation(at now: Date) -> TokenHubQuotaPresentation {
        let projected = TokenHubQuotaPresentation.project(snapshot: tokenHubQuotaSnapshot, now: now,
            refreshSeconds: config.refreshSeconds)
        let sourceEligible = config.dataSource == "localCodex" && tokenHubQuotaReadingEnabled
            && tokenHubQuotaStatus == .connected
        guard !sourceEligible, projected.snapshot != nil else { return projected }
        func historical(_ state: TokenHubQuotaPresentation.WindowProjection?) -> TokenHubQuotaPresentation.WindowProjection? {
            state.map { .init(futureObservation: $0.futureObservation, fresh: false,
                resetPassed: $0.resetPassed, resetAt: $0.resetAt) }
        }
        return TokenHubQuotaPresentation(snapshot: projected.snapshot,
            futureObservation: projected.futureObservation, snapshotFresh: false,
            fiveHourCurrent: nil, sevenDayCurrent: nil, monthlyCurrent: nil,
            fiveHour: historical(projected.fiveHour), sevenDay: historical(projected.sevenDay),
            menuAlertLevel: .none)
    }
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
        if config.dataSource == "localCodex" { return "当前配置关联的本机 Codex 记录，当前扫描范围记录合计，实时速度为活动事件短窗口估算" }
        return hasRequestData ? "本次启动 · 仅统计经过本机代理的请求" : "未采集到请求数据 · 尚未观测到客户端流量"
    }
    /// 每次菜单更新都检查有效期，不依赖文件扫描进度；未来或无效的观测不作为实时数据。
    var freshLocalLiveTurn: LocalLiveTurnSummary? { freshLocalLiveTurn(at: tokenHubNow()) }
    func freshLocalLiveTurn(at now: Date) -> LocalLiveTurnSummary? {
        guard let live = localSnapshot.liveTurn,
              live.observedAt <= now, now.timeIntervalSince(live.observedAt) <= 15,
              live.inputTPS.isFinite, live.outputTPS.isFinite,
              live.inputTPS >= 0, live.outputTPS >= 0 else { return nil }
        return live
    }
    var title: String {
        let now = tokenHubNow()
        return title(at: now, quotaPresentation: quotaPresentation(at: now))
    }
    /// 菜单栏只显示三个额度数字：5 小时已用、7 天已用、月度用量。
    func title(at now: Date, quotaPresentation: TokenHubQuotaPresentation) -> String {
        let five = quotaPresentation.fiveHourCurrent.map { menuPercent($0.usedPercent) } ?? "—"
        let seven = quotaPresentation.sevenDayCurrent.map { menuPercent($0.usedPercent) } ?? "—"
        let monthly = quotaPresentation.monthlyCurrent.map {
            "\($0.sourceSymbol)\(menuAmount($0.usedAmount))"
        } ?? "—"
        return (isTestFixture ? "测试 " : "") + "\(five) | \(seven) | \(monthly)"
    }

    private func menuPercent(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value).doubleValue
        guard number.isFinite else { return "—" }
        return String(format: "%.2f%%", min(100, max(0, number)))
    }

    private func menuAmount(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }
    var menuTooltip: String {
        let now = tokenHubNow()
        return menuTooltip(at: now, quotaPresentation: quotaPresentation(at: now))
    }
    func menuTooltip(at now: Date, quotaPresentation: TokenHubQuotaPresentation) -> String {
        if isPreview && config.dataSource != "localCodex" {
            return "\(dataNotice) · \(sourceReadinessText)\n5 小时额度：\(quotaDescription(fiveHourQuota, source: .enterprise))\n7 天额度：\(quotaDescription(sevenDayQuota, source: .enterprise))"
        }
        let live = freshLocalLiveTurn(at: now).map { String(format: "实时估算：输入 %.1f · 输出 %.1f tok/s（观测于 %@）", $0.inputTPS, $0.outputTPS, $0.observedAt.formatted()) } ?? "实时估算：未知（无新鲜活动 token_count）"
        let turn = localSnapshot.lastTurn.map { String(format: "上轮记录均速：%.1f tok/s（完成于 %@）", $0.outputTPS, $0.completedAt.formatted()) } ?? "上轮记录均速：未知"
        let range = localSnapshot.latestEventAt.map { "最新记录：\($0.formatted())" } ?? "记录时间：未知"
        let coverage = "扫描范围最多32个物理文件；不是全部对话；每文件头64KiB与尾256KiB，总计10MiB；" + (localSnapshot.isLimited ? "本次达到扫描上限" : "本次安全检查 \(localSnapshot.filesScanned) 个物理文件")
        let input = localSnapshot.knownThreadCount > 0 ? formatCount(localSnapshot.input) : "未知"
        let output = localSnapshot.knownThreadCount > 0 ? formatCount(localSnapshot.output) : "未知"
        let amountLabel = localSnapshot.hasCompleteAccounting ? "本次扫描记录量" : "本次记录合计"
        let total = localSnapshot.knownThreadCount > 0 ? formatCount(localSnapshot.total) : "未知"
        let hub = tokenHubTooltipDetail(quotaPresentation)
        return "\(userFacingStatus)\n当前配置关联的本机 Codex 记录；当前扫描范围：输入 \(input) · 输出 \(output) · 总计 \(total) tokens（\(amountLabel) \(total) tokens）\n\(accountingDetail)\n\(coverage)；\(range)\n\(localDetailedMetricsTooltip)\n\(live)；\(turn)；实时值是最近活动 token_count 的短窗口估算；上轮均速含工具、网络和等待，不是模型瞬时生成速度\n\(hub)\n5 小时额度：\(quotaDescription(fiveHourQuota, source: .localCodex))\n7 天额度：\(quotaDescription(sevenDayQuota, source: .localCodex))"
    }
    var localCacheReadout: String {
        guard localSnapshot.cacheCoverage.state == .complete,
              let value = localSnapshot.cacheCoverage.cachedInputTokens else {
            return "未知（\(localCacheUnknownReason)）"
        }
        return "\(formatCount(value)) tokens"
    }
    var localUncachedInputReadout: String {
        guard localSnapshot.cacheCoverage.state == .complete,
              let value = localSnapshot.cacheCoverage.uncachedInputTokens else {
            return "未知（\(localCacheUnknownReason)）"
        }
        return "\(formatCount(value)) tokens"
    }
    var localCacheHitRateReadout: String {
        let coverage = localSnapshot.cacheCoverage
        guard coverage.state == .complete else { return "未知（\(localCacheUnknownReason)）" }
        guard let input = coverage.matchedInputTokens,
              let cached = coverage.matchedCachedInputTokens,
              input >= 0, cached >= 0, cached <= input else {
            return "未知（来源覆盖不完整）"
        }
        guard input > 0 else { return "未知（输入总计为 0，比例不适用）" }
        if cached == input { return "100.00%" }
        let percent = Decimal(cached) * Decimal(100) / Decimal(input)
        let rendered = Self.localCachePercentFormatter.string(from: NSDecimalNumber(decimal: percent)) ?? "未知（比例不可用）"
        // 未满的比例不能因舍入而显示为全满。
        return rendered == "100.00" ? "99.99%" : "\(rendered)%"
    }
    var localCacheCoverageReadout: String {
        let coverage = localSnapshot.cacheCoverage
        let rows = "\(coverage.cacheKnownRows)/\(coverage.baseRows) 行"
        switch coverage.state {
        case .complete: return "\(rows) 完整"
        case .partial: return "\(rows) 部分覆盖"
        case .missing: return "\(rows) 来源未提供"
        case .invalid: return "\(rows) 来源值无效"
        }
    }
    var localMatchedCacheReadout: String? {
        let coverage = localSnapshot.cacheCoverage
        guard coverage.state == .partial,
              let input = coverage.matchedInputTokens,
              let cached = coverage.matchedCachedInputTokens else { return nil }
        return "同覆盖匹配合计：缓存读取 \(formatCount(cached)) / 输入 \(formatCount(input)) tokens"
    }
    var localReadAtReadout: String {
        localSnapshot.readAt.map { "本次扫描/核对时间：\($0.formatted())" }
            ?? "本次扫描/核对时间：未知"
    }
    private var localCacheUnknownReason: String {
        switch localSnapshot.cacheCoverage.state {
        case .complete: return "来源未提供"
        case .partial: return "覆盖不完整，存在未提供或无效项"
        case .missing: return "来源未提供（字段缺失）"
        case .invalid: return "来源值无效（字段非法）"
        }
    }
    private var localDetailedMetricsTooltip: String {
        var lines = [
            "缓存读取：\(localCacheReadout)",
            "未缓存输入：\(localUncachedInputReadout)",
            "命中率：\(localCacheHitRateReadout)",
            "缓存覆盖：\(localCacheCoverageReadout)",
            "线程轮次明细：\(localSnapshot.detailLimited ? "已达到展示上限" : "当前扫描候选范围")",
            localReadAtReadout,
            "模型调用用时：未知（来源未提供）",
            "平均 TTFT：未知（来源未提供）",
            "decode TPS：未知（来源未提供）"
        ]
        if let matched = localMatchedCacheReadout { lines.insert(matched, at: 4) }
        return lines.joined(separator: "\n")
    }
    private func tokenHubMenuSuffix(_ presentation: TokenHubQuotaPresentation) -> String {
        let windows = [presentation.fiveHourCurrent.map { "5h剩 \(percentText($0.remainingPercent))" },
                       presentation.sevenDayCurrent.map { "7d剩 \(percentText($0.remainingPercent))" }].compactMap { $0 }
        return windows.isEmpty ? "" : " · Hub \(windows.joined(separator: " / "))"
    }
    private var tokenHubMenuSuffix: String { tokenHubMenuSuffix(quotaPresentation) }
    var menuTitleContainsTokenHubSuffix: Bool { !tokenHubMenuSuffix.isEmpty }
    var tokenHubPermissionGrantedForDiagnostics: Bool { cachedTokenHubPermission }
    private func tokenHubTooltipDetail(_ presentation: TokenHubQuotaPresentation) -> String {
        let five = presentation.fiveHourCurrent.map { "界面显示剩余 \(percentText($0.remainingPercent))（5 小时）" } ?? "5 小时未知"
        let seven = presentation.sevenDayCurrent.map { "界面显示剩余 \(percentText($0.remainingPercent))（7 天）" } ?? "7 天未知"
        let source = tokenHubQuotaIsDirect ? "Token Hub 后台直接响应" : "Token Hub 界面快照"
        let timing = tokenHubQuotaIsDirect ? "后台响应已提供" : "后台更新时间未提供"
        let currency = tokenHubQuotaIsDirect ? "币种来自后台响应" : "币种来源待确认"
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
        case .loginRejected: "Token Hub 登录验证未通过，请在 Hub 中确认登录状态"
        case .exchangeRejected: "Token Hub 服务端拒绝登录交换"
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
        "线程 \(localSnapshot.knownThreadCount) · 其他线程 \(localSnapshot.unknownThreadCount) · 未识别文件 \(localSnapshot.unidentifiedFileCount) · 子代理 \(localSnapshot.subagentCount) · 分叉 \(localSnapshot.forkCount) · 顶层对话 \(localSnapshot.sessionCount)"
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
    var alertColor: NSColor { alertColor(for: quotaPresentation) }
    func alertColor(for quotaPresentation: TokenHubQuotaPresentation) -> NSColor {
        if tokenHubQuotaIsDirect {
            switch quotaPresentation.menuAlertLevel {
            case .none: return .labelColor
            case .warning: return .systemYellow
            case .critical: return .systemRed
            }
        }
        guard quotaSource == .enterprise else { return .labelColor }
        let windows = [fiveHourQuota, sevenDayQuota].compactMap { $0 }
            .filter { $0.isFresh(at: tokenHubNow(), refreshSeconds: config.refreshSeconds) }.map { $0.usedPercent / 100 }
        guard let ratio = (windows + [freshQuota?.fraction].compactMap { $0 }).max() else { return .labelColor }
        return ratio >= 0.95 ? .systemRed : ratio >= 0.8 ? .systemYellow : .labelColor
    }
    /// 仅供旧核心状态的模拟回归测试使用，正式设置流程不调用。
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
        // 兼容本地历史视图和测试，不从旧 plist 加载集成字段或据此启用服务。
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
        localScanDeferredGeneration = nil
        generation += 1; tokenHubGeneration &+= 1
        invalidateLocalWorker(generation: generation)
        if !history.isEmpty { history.removeAll(keepingCapacity: true) }
        lastHistorySampleMonotonic = nil
        cancelTokenHubSchedule()
        tokenHubQuotaSnapshot = nil; tokenHubQuotaFailure = nil
        tokenHubDirectFailure = nil; tokenHubQuotaIsDirect = false; tokenHubDirectScanInFlight = false
        tokenHubQuotaStatus = tokenHubQuotaReadingEnabled ? .targetNotRunning : .disabled
        lastTokenHubPermissionCheck = .distantPast; cachedTokenHubPermission = false
        _ = localRefreshScheduler.invalidate()
        cancelLocalScanSchedule()
        clearLocalSnapshot()
        resetQuotaState()
        scheduleLocalScan(immediate: true)
        if tokenHubQuotaReadingEnabled { scheduleTokenHubRefresh(after: 0) }
        installTokenHubWorkspaceObservers()
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        timer?.tolerance = 0.1
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func stopBackgroundResources() {
        timer?.invalidate(); timer = nil
        cancelLocalScanSchedule()
        cancelTokenHubSchedule()
        for observer in tokenHubWorkspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        tokenHubWorkspaceObservers.removeAll()
    }

    private func stopBackgroundServices() {
        backgroundServicesStarted = false
        generation += 1; tokenHubGeneration &+= 1
        invalidateLocalWorker(generation: generation)
        clearLocalSnapshot()
        _ = localRefreshScheduler.invalidate()
        stopBackgroundResources()
        tokenHubQuotaSnapshot = nil; tokenHubQuotaFailure = nil
        tokenHubDirectFailure = nil; tokenHubQuotaIsDirect = false; tokenHubDirectScanInFlight = false
        tokenHubQuotaStatus = tokenHubQuotaReadingEnabled ? .targetNotRunning : .disabled
    }
    private func invalidateLocalWorker(generation token: Int) {
        guard let invalidate = localScanning.invalidate else { return }
        Task { await invalidate(token) }
    }
    private func clearLocalSnapshot() {
        localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0,
            filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
            knownThreadCount: 0, unknownThreadCount: 0, unidentifiedFileCount: 0,
            subagentCount: 0, forkCount: 0)
        fiveHourQuota = nil; sevenDayQuota = nil
    }
    /// 切换来源时清空额度，不执行 I/O。
    func resetQuotaState() {
        quota = nil
        fiveHourQuota = nil
        sevenDayQuota = nil
        quotaLoading = false
    }
    private func cancelLocalScanSchedule() {
        localScanTicket &+= 1
        localScan?(); localScan = nil
    }

    private func cancelTokenHubSchedule() {
        tokenHubRefreshTicket &+= 1
        tokenHubRefreshWork?(); tokenHubRefreshWork = nil
    }

    private func scheduleLocalScan(immediate: Bool = false) {
        guard backgroundServicesStarted else { return }
        cancelLocalScanSchedule()
        let version = generation
        let ticket = localScanTicket
        localScan = timing.schedule(immediate ? 0 : 5) { [weak self] in
            guard let self, self.localScanTicket == ticket else { return }
            self.localScan = nil
            Task { @MainActor in
            guard self.localScanTicket == ticket, !self.isShuttingDown,
                  self.backgroundServicesStarted, self.generation == version,
                  self.config.dataSource == "localCodex" else { return }
            guard !self.localScanRunning else {
                self.localScanDeferredGeneration = version
                return
            }
            let monoNow = self.timing.monotonicNow()
            guard let scanGeneration = self.localRefreshScheduler.begin(monotonicNow: monoNow) else {
                self.scheduleLocalScan(immediate: false)
                return
            }
            self.localScanRunning = true
            self.localScanRunTicket = ticket
            let nowProvider = self.timing.wallNow
            let result: LocalCodexScanWorker.Result?
            if let scanDefault = self.localScanning.scanDefault {
                result = try? await scanDefault(nowProvider, version)
            } else if let resolveInputs = self.localScanning.resolveInputs,
                      let scan = self.localScanning.scan {
                let inputs = resolveInputs()
                result = try? await self.localInjectedWorker.scanInjected(
                    directory: inputs.directory, nowProvider: nowProvider, generation: version,
                    routeContext: inputs.routeContext, operation: scan)
            } else {
                result = nil
            }
            if self.localScanRunTicket == ticket {
                self.localScanRunning = false
                self.localScanRunTicket = nil
            }
            guard self.generation == version,
                  self.localRefreshScheduler.complete(generation: scanGeneration,
                                                      monotonicNow: self.timing.monotonicNow()) else {
                if let deferred = self.localScanDeferredGeneration,
                   deferred == self.generation, self.localScan == nil,
                   self.backgroundServicesStarted, !self.isShuttingDown,
                   self.config.dataSource == "localCodex" {
                    self.localScanDeferredGeneration = nil
                    self.scheduleLocalScan(immediate: true)
                }
                return
            }
            self.localScanDeferredGeneration = nil
            if self.config.dataSource == "localCodex" {
                if let snapshot = result?.snapshot {
                    self.localSnapshot = snapshot; self.fiveHourQuota = snapshot.fiveHour; self.sevenDayQuota = snapshot.sevenDay
                } else {
                    self.localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0, filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil, knownThreadCount: 0, unknownThreadCount: 0, unidentifiedFileCount: 0, subagentCount: 0, forkCount: 0)
                    self.fiveHourQuota = nil; self.sevenDayQuota = nil
                }
            }
            if self.config.dataSource == "localCodex", self.backgroundServicesStarted { self.scheduleLocalScan() }
            }
        }
    }

    /// 关联当前 Codex provider 与本机 Token Hub 的源站配置。
    /// 仅凭当前配置无法确认历史会话的实际路由。
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
    /// 正式刷新优先只读 Hub 连接并在内存中交换 SSO 令牌。
    /// 预览和模拟测试使用限量 AX 扫描，不接触真实凭据。
    func refreshTokenHubQuota(observationNow: Date? = nil) {
        guard !isShuttingDown else { return }
        guard config.dataSource == "localCodex", tokenHubQuotaReadingEnabled else {
            invalidateTokenHubQuota(status: .disabled); cancelTokenHubSchedule()
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
        // 在后台 actor 解析目标、读取配置并请求接口，仅将脱敏数据传回主 actor。
        if let workerFetch = source.workerFetch {
            tokenHubDirectScanInFlight = true
            let nowProvider = timing.wallNow
            Task { [weak self] in
                let result: Result<DirectQuotaTransportSnapshot, Error>
                do { result = .success(try await workerFetch(nowProvider)) }
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

        // 此兼容分支只供注入式模拟测试使用；正式发现和配置读取不在主 actor 执行。
        let identity: TokenHubIdentity
        do { identity = try directQuota.discoverTarget() }
        catch {
            hasCompletedInitialQuotaRead = true
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
            // 旧代次已释放，迟到的完成回调不能解锁新代次的活动请求。
            guard !self.isShuttingDown, self.tokenHubGeneration == version else { return }
            self.tokenHubDirectScanInFlight = false
            guard self.config.dataSource == "localCodex", self.tokenHubQuotaReadingEnabled else { return }
            switch result {
            case .success(let snapshot):
                guard source.identityIsCurrent(identity) else {
                    self.hasCompletedInitialQuotaRead = true
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
        hasCompletedInitialQuotaRead = true
        tokenHubQuotaStatus = .connected
        tokenHubQuotaFailure = nil
        tokenHubDirectFailure = nil
        tokenHubQuotaIsDirect = true
        sourceReadinessText = "企业额度已自动读取 Token Hub 后台"
        scheduleTokenHubRefresh(after: interval)
    }

    private func tokenHubStatusFailed(_ error: Error, interval: TimeInterval) {
        hasCompletedInitialQuotaRead = true
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
        // 已有授权时才使用 AX 兼容回退，不影响后台直读。
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
            invalidateTokenHubQuota(status: .disabled); cancelTokenHubSchedule()
            return
        }
        checkTokenHubPermissionIfDue(scheduleIfGranted: false)
        guard cachedTokenHubPermission else {
            invalidateAccessibilityQuota(status: .permissionRequired)
            // 请求期间授权可能被撤销，可选回退不能取消自动重试。
            if usesDirectQuotaSource { scheduleTokenHubRefresh(after: config.refreshSeconds) }
            return
        }
        guard !tokenHubScanInFlight else { return }
        cancelTokenHubSchedule()
        tokenHubScanInFlight = true
        let version = tokenHubGeneration, axVersion = tokenHubAXGeneration, mode: TokenHubRunMode = .localCodex
        let now = tokenHubNow(), interval = config.refreshSeconds
        let source = tokenHubAXSource
        let request = TokenHubAXRequest(now: now, permissionTrusted: cachedTokenHubPermission,
            refreshSeconds: interval, mode: mode, generation: version)
        Task(priority: .utility) { [weak self] in
            // 主 actor 仅等待返回值，原生遍历在私有后台 actor 中同步执行，不中途挂起。
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
            // 此偏好只控制 AX 兼容读取，不关闭自动企业来源或丢弃其快照。
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
        cancelTokenHubSchedule()
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
            // 保留后台直读错误；缺少 AX 授权不代表自动来源失败。
            if tokenHubDirectFailure == nil { tokenHubQuotaStatus = .targetNotRunning }
        }
    }

    func invalidateTokenHubQuota(status: TokenHubQuotaStatus) {
        hasCompletedInitialQuotaRead = true
        tokenHubGeneration &+= 1
        cancelTokenHubSchedule()
        tokenHubQuotaSnapshot = nil; tokenHubQuotaFailure = nil; tokenHubDirectFailure = nil
        tokenHubQuotaIsDirect = false; tokenHubDirectScanInFlight = false; tokenHubQuotaStatus = status
    }

    func applyTokenHubQuotaResult(_ result: TokenHubQuotaResult, generation resultGeneration: UInt64,
                                  mode: TokenHubRunMode, now: Date) {
        guard !isShuttingDown, tokenHubGeneration == resultGeneration, cachedTokenHubPermission,
              config.dataSource == "localCodex", mode == .localCodex,
              tokenHubAutomaticReadingEnabled else { return }
        hasCompletedInitialQuotaRead = true
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
              tokenHubQuotaStatus == .connected, let snapshot = tokenHubQuotaSnapshot else { return nil }
        let presentation = TokenHubQuotaPresentation.project(snapshot: snapshot, now: now,
            refreshSeconds: config.refreshSeconds)
        guard presentation.snapshotFresh,
              presentation.fiveHourCurrent != nil || presentation.sevenDayCurrent != nil || presentation.monthlyCurrent != nil else { return nil }
        return TokenHubQuotaSnapshot(identity: snapshot.identity, fiveHour: presentation.fiveHourCurrent,
            sevenDay: presentation.sevenDayCurrent, monthly: presentation.monthlyCurrent,
            observedAt: snapshot.observedAt)
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

    private func scheduleTokenHubRefresh(after seconds: TimeInterval, observationNow _: Date? = nil) {
        guard (backgroundServicesStarted || isPreview), config.dataSource == "localCodex", tokenHubQuotaReadingEnabled,
              !isShuttingDown, (usesDirectQuotaSource || !tokenHubScanInFlight), !isFixtureUsingNativeTokenHubReader else { return }
        cancelTokenHubSchedule()
        let version = tokenHubGeneration
        let ticket = tokenHubRefreshTicket
        tokenHubRefreshWork = timing.schedule(max(0, seconds)) { [weak self] in
            guard let self, self.tokenHubRefreshTicket == ticket else { return }
            self.tokenHubRefreshWork = nil
            guard !self.isShuttingDown, self.tokenHubGeneration == version,
                  self.config.dataSource == "localCodex", self.tokenHubQuotaReadingEnabled else { return }
            self.refreshTokenHubQuota()
        }
    }

    static func shouldSuppressNativeTokenHubRead(isTestFixture: Bool, scannerIsNative: Bool) -> Bool {
        isTestFixture && scannerIsNative
    }
    var isFixtureUsingNativeTokenHubReader: Bool {
        Self.shouldSuppressNativeTokenHubRead(isTestFixture: isTestFixture,
            scannerIsNative: tokenHubAXSource.kind == .native)
    }

    private func installTokenHubWorkspaceObservers() {
        guard startup.observeWorkspaceNotifications else { return }
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

    /// 生命周期接入点，仅处理元数据，不读取 AX 值或目标内容。
    func tokenHubApplicationDidTerminate(bundleIdentifier: String) {
        guard isPreview || backgroundServicesStarted else { return }
        guard bundleIdentifier == TokenHubTarget.bundleID, !isShuttingDown else { return }
        invalidateTokenHubQuota(status: config.dataSource == "localCodex" ? .targetNotRunning : .disabled)
    }

    /// 生命周期接入点，仅处理元数据；启动不使旧快照重新有效。
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
