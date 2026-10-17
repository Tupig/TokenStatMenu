import AppKit
import Combine
#if SWIFT_PACKAGE
@preconcurrency import TokenStatCore
#endif
import UniformTypeIdentifiers

struct SpeedPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

@MainActor final class AppModel: ObservableObject {
    // Explicit launch-only flag: fixtures never masquerade as enterprise measurements.
    let isTestFixture = CommandLine.arguments.contains("--test-fixture")
    private let isPreview: Bool
    @Published var config = AppConfiguration()
    @Published var stats = MetricsSnapshot()
    @Published var localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0, filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil, knownThreadCount: 0, unknownThreadCount: 0, unidentifiedFileCount: 0, subagentCount: 0, forkCount: 0)
    @Published var quota: QuotaSnapshot?
    @Published var fiveHourQuota: WindowQuota?
    @Published var sevenDayQuota: WindowQuota?
    @Published var quotaError = "未配置企业用量接口"
    @Published var proxyStatus = "启动中"
    @Published var message = ""
    @Published var history: [SpeedPoint] = []
    @Published var quotaLoading = false
    @Published private(set) var tokenHubQuotaSnapshot: TokenHubQuotaSnapshot?
    @Published private(set) var tokenHubQuotaStatus: TokenHubQuotaStatus = .targetNotRunning
    @Published private(set) var tokenHubQuotaFailure: TokenHubQuotaFailure?
    @Published var tokenHubAutomaticReadingEnabled = true
    var tokenHubScanner: TokenHubQuotaScanning = TokenHubAXReader()
    var tokenHubPermissionProvider: TokenHubPermissionProviding = TokenHubNativePermissionProvider()
    var tokenHubNow: () -> Date = Date.init
    @Published var panelVisible = false
    @Published var gateways: [GatewayCandidate] = []
    @Published var discoveryStatus = "正在读取本机网关配置…"
    @Published var discovering = false
    let engine = MetricsEngine()
    private lazy var proxy = ProxyServer(engine: engine)
    private let logger = StatLogger()
    private var timer: Timer?
    private var quotaLoop: Task<Void, Never>?
    private var quotaFetch: Task<Void, Never>?
    private var localScan: DispatchWorkItem?
    private var localScanRunning = false
    private let tokenHubQueue = DispatchQueue(label: "TokenStatMenu.tokenHubAX", qos: .utility)
    private var tokenHubRefreshWork: DispatchWorkItem?
    private var tokenHubScanInFlight = false
    private var tokenHubWorkspaceObservers: [NSObjectProtocol] = []
    private var lastTokenHubPermissionCheck = Date.distantPast
    private var cachedTokenHubPermission = false
    private let localScanQueue = DispatchQueue(label: "TokenStatMenu.localCodexScan", qos: .utility)
    private var localCache = LocalCodexUsageReader.Cache()
    private var localRefreshScheduler = LocalRefreshScheduler()
    private var proxyWasStarted = false
    private var isShuttingDown = false
    private var generation = 0
    private var tokenHubGeneration: UInt64 = 0
    private var lastHistory = Date.distantPast
    private(set) var localKey = ""
    private var apiKey = ""
    private var usageKey = ""
    var onTick: (() -> Void)?

    init(preview: Bool = false) {
        isPreview = preview
        // Offline view rendering must never touch local configuration or credentials.
        if preview { proxyStatus = "模拟预览 · 无网络、无本机配置"; discoveryStatus = "离线预览"; return }
        logger.onError = { [weak self] error in Task { @MainActor in self?.message = error } }
        do {
            config = try ConfigStore.load()
            if config.dataSource == "proxy" {
                localKey = try KeychainStore.localToken()
                apiKey = try KeychainStore.resolve("upstream", environment: "TOKENSTAT_API_KEY", validatedURL: config.endpoint)
                usageKey = config.usageURL.isEmpty ? "" : try KeychainStore.resolve("usage", environment: "TOKENSTAT_USAGE_KEY", validatedURL: config.usageURL)
            }
            startServices()
        } catch { message = error.localizedDescription; proxyStatus = "未启动：检查设置" }
        installTokenHubWorkspaceObservers()
        // A single 2Hz main timer updates menu text. Network callbacks never redraw the UI.
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        timer?.tolerance = 0.1
        RunLoop.main.add(timer!, forMode: .common)
        if config.dataSource == "proxy" { discoverGateways() }
    }
    /// One bounded scan at startup or on explicit refresh. Never polls the filesystem.
    func discoverGateways() {
        guard !discovering else { return }
        if CommandLine.arguments.contains("--disable-discovery") { discoveryStatus = "本次启动已停用自动发现"; return }
        discovering = true
        let process = ProcessInfo.processInfo.environment
        let allowed = ["OPENAI_BASE_URL", "OPENAI_MODEL", "OLLAMA_HOST"]
        let environment = Dictionary(uniqueKeysWithValues: allowed.compactMap { name in process[name].map { (name, $0) } })
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let override = process["CODEX_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        let directory = override ?? home
        let source = override == nil ? "~/.codex/config.toml" : "$CODEX_HOME/config.toml"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let results = GatewayDiscovery.readCodexConfig(at: directory.appendingPathComponent("config.toml"), source: source)
                + GatewayDiscovery.environmentCandidates(environment)
            Task { @MainActor in
                guard let self else { return }
                self.gateways = results; self.discovering = false
                self.discoveryStatus = results.isEmpty ? "未发现可用网关，可手动填写" : "已发现 \(results.count) 个配置 · 未读取认证信息"
            }
        }
    }
    func shutdown() {
        isShuttingDown = true; generation += 1; _ = localRefreshScheduler.invalidate()
        timer?.invalidate(); quotaLoop?.cancel(); quotaFetch?.cancel(); localScan?.cancel()
        tokenHubGeneration &+= 1
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        for observer in tokenHubWorkspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        tokenHubWorkspaceObservers.removeAll()
        tokenHubQuotaSnapshot = nil; tokenHubQuotaStatus = .disabled; tokenHubQuotaFailure = nil
        if proxyWasStarted { proxy.stop() }
    }
    func tick() {
        stats = engine.snapshot()
        let now = Date()
        if config.dataSource == "proxy", config.historyEnabled, now.timeIntervalSince(lastHistory) >= 1 {
            history.append(SpeedPoint(date: now, value: stats.outputTPS))
            history.removeAll { now.timeIntervalSince($0.date) > 600 }
            if history.count > 600 { history.removeFirst(history.count - 600) }
            lastHistory = now
        }
        if quota?.month != QuotaSnapshot.currentMonth(), quota != nil { quota = nil; quotaError = "已跨月，等待本月用量" }
        if tokenHubQuotaStatus == .connected, freshTokenHubQuota(at: now) == nil { tokenHubQuotaStatus = .stale }
        pollTokenHubPermissionIfDue()
        onTick?()
    }
    var freshQuota: QuotaSnapshot? {
        guard let quota, quota.month == QuotaSnapshot.currentMonth(), Date().timeIntervalSince(quota.fetchedAt) < max(120, config.refreshSeconds * 2) else { return nil }
        return quota
    }
    var currencyFactor: Double { config.currency == "CNY" ? config.usdToCNY : 1 }
    var currencySymbol: String { config.currency == "CNY" ? "¥" : "$" }
    var quotaSource: QuotaSource { config.dataSource == "localCodex" ? .localCodex : .enterprise }
    var hasRequestData: Bool { config.dataSource == "localCodex" ? localSnapshot.knownThreadCount > 0 : stats.requests > 0 }
    var dataNotice: String {
        if isTestFixture { return "模拟测试 · 以下速度、Token、费用和配额均非企业真实数据" }
        if config.dataSource == "localCodex" { return "本地 Codex 当前扫描范围记录小计 · 不代表账单或实时用量；账号与组织归属未核验" }
        return hasRequestData ? "本次启动 · 仅统计经过本机代理的请求" : "未采集到请求数据 · 尚未观测到客户端流量"
    }
    var title: String {
        if config.dataSource == "localCodex" {
            let rate = localSnapshot.lastTurn.map { String(format: "%.1ftok/s", $0.outputTPS) } ?? "—"
            let uncertainty = localSnapshot.unknownThreadCount + localSnapshot.unidentifiedFileCount
            let total = localSnapshot.hasCompleteAccounting ? "Σ\(formatCompactCount(localSnapshot.total))"
                : localSnapshot.knownThreadCount > 0 ? "小计\(formatCompactCount(localSnapshot.total)) · 未核验\(uncertainty)" : "Σ— · 未核验\(uncertainty)"
            let sessions = localSnapshot.hasCompleteAccounting ? " · \(localSnapshot.sessionCount)顶层对话" : ""
            let quotaSuffix = tokenHubMenuSuffix
            return (isTestFixture ? "测试 " : "") + "上轮均:\(rate) · \(total)\(sessions)\(quotaSuffix)"
        }
        let value = !hasRequestData ? "T:—" : stats.active > 0
            ? String(format: "T:≈%.1ftok/s", stats.outputTPS) : "T:0.0tok/s"
        let total = stats.requests > 0 ? formatCompactCount(stats.total) : "—"
        return (isTestFixture ? "测试 " : "") + "\(value) · Σ\(total) · 请求\(stats.requests)"
    }
    var menuTooltip: String {
        guard config.dataSource == "localCodex" else {
            return "\(dataNotice) · \(proxyStatus)\n5 小时额度：\(quotaDescription(fiveHourQuota, source: .enterprise))\n7 天额度：\(quotaDescription(sevenDayQuota, source: .enterprise))"
        }
        let turn = localSnapshot.lastTurn.map { String(format: "上轮记录均速：%.1f tok/s（完成于 %@）", $0.outputTPS, $0.completedAt.formatted()) } ?? "上轮记录均速：未知"
        let range = localSnapshot.latestEventAt.map { "最新记录：\($0.formatted())" } ?? "记录时间：未知"
        let coverage = "扫描范围最多32个物理文件；不是全部对话；每文件头64KiB与尾256KiB，总计10MiB；" + (localSnapshot.isLimited ? "本次达到扫描上限" : "本次安全检查 \(localSnapshot.filesScanned) 个物理文件")
        let input = localSnapshot.knownThreadCount > 0 ? formatCount(localSnapshot.input) : "未知"
        let output = localSnapshot.knownThreadCount > 0 ? formatCount(localSnapshot.output) : "未知"
        let amountLabel = localSnapshot.hasCompleteAccounting ? "本次扫描记录量" : "已核验记录小计"
        let total = localSnapshot.knownThreadCount > 0 ? formatCount(localSnapshot.total) : "未知"
        let hub = tokenHubTooltipDetail
        return "本地 Codex 当前扫描范围记录：输入 \(input) · 输出 \(output) · 总计 \(total) tokens（\(amountLabel) \(total) tokens）\n\(accountingDetail)\n\(coverage)；\(range)\n\(turn)；含工具、网络和等待；不是模型瞬时生成速度\n\(hub)\n5 小时额度：\(quotaDescription(fiveHourQuota, source: .localCodex))\n7 天额度：\(quotaDescription(sevenDayQuota, source: .localCodex))"
    }
    private var tokenHubMenuSuffix: String {
        guard let snapshot = freshTokenHubQuota(at: Date()) else { return "" }
        let windows = [snapshot.fiveHour.map { "5h剩 \(percentText($0.remainingPercent))%" },
                       snapshot.sevenDay.map { "7d剩 \(percentText($0.remainingPercent))%" }].compactMap { $0 }
        return windows.isEmpty ? "" : " · Hub \(windows.joined(separator: " / "))"
    }
    var menuTitleContainsTokenHubSuffix: Bool { !tokenHubMenuSuffix.isEmpty }
    var tokenHubPermissionGrantedForDiagnostics: Bool { cachedTokenHubPermission }
    var tokenHubPermissionRequiredForDiagnostics: Bool { tokenHubQuotaStatus == .permissionRequired }
    private var tokenHubTooltipDetail: String {
        let snapshot = freshTokenHubQuota(at: Date())
        let five = snapshot?.fiveHour.map { "界面显示剩余 \(percentText($0.remainingPercent))%（5 小时）" } ?? "5 小时未知"
        let seven = snapshot?.sevenDay.map { "界面显示剩余 \(percentText($0.remainingPercent))%（7 天）" } ?? "7 天未知"
        return "Token Hub 界面快照：\(five) · \(seven)；\(tokenHubQuotaStatusText)；后台更新时间未提供；币种未核验"
    }
    private func percentText(_ value: Decimal) -> String {
        TokenHubDecimalFormatter.string(value)
    }
    var tokenHubQuotaStatusText: String {
        switch tokenHubQuotaStatus {
        case .disabled: "自动读取已关闭"
        case .permissionRequired: "未授权辅助功能"
        case .targetNotRunning: "Token Hub 未运行"
        case .ambiguousTarget: "检测到多个 Token Hub 进程"
        case .quotaGroupUnavailable: "找不到用量和限额页"
        case .unsupportedLayout: "用量页面布局暂不支持"
        case .accessFailed: "辅助功能读取失败"
        case .stale: "界面快照已过期"
        case .connected: "已连接"
        }
    }
    private var accountingDetail: String {
        "已核验线程 \(localSnapshot.knownThreadCount) · 未核验线程 \(localSnapshot.unknownThreadCount) · 未识别文件 \(localSnapshot.unidentifiedFileCount) · 子代理 \(localSnapshot.subagentCount) · 分叉 \(localSnapshot.forkCount) · 顶层对话 \(localSnapshot.sessionCount)"
    }
    private func quotaDescription(_ quota: WindowQuota?, source: QuotaSource) -> String {
        let presentation = WindowQuotaCard.presentation(for: quota, refreshSeconds: config.refreshSeconds, source: source)
        guard let usedPercent = presentation.usedPercent else { return "\(presentation.sourceLabel) · \(presentation.statusLabel)" }
        let resetLabel = source == .localCodex || !presentation.isFresh ? "原重置时间" : "重置时间"
        let reset = presentation.resetsAt.map { "，\(resetLabel) \($0.formatted())" } ?? "，重置时间未知"
        let recorded = presentation.recordedAt.map { "，记录于 \($0.formatted())" } ?? ""
        return "\(presentation.sourceLabel) · \(presentation.statusLabel)，上游已用 \(String(format: "%.1f", usedPercent))%\(reset)\(recorded)"
    }
    private func formatCount(_ value: Int) -> String { value.formatted(.number) }
    private func formatCompactCount(_ value: Int) -> String { value.formatted(.number.notation(.compactName)) }
    var alertColor: NSColor {
        guard quotaSource == .enterprise else { return .labelColor }
        let windows = (quotaSource == .enterprise ? [fiveHourQuota, sevenDayQuota].compactMap { $0 } : [])
            .filter { $0.isFresh(refreshSeconds: config.refreshSeconds) }.map { $0.usedPercent / 100 }
        guard let ratio = (windows + [freshQuota?.fraction].compactMap { $0 }).max() else { return .labelColor }
        return ratio >= 0.95 ? .systemRed : ratio >= 0.8 ? .systemYellow : .labelColor
    }
    func credentials() -> (String, String) { (apiKey, usageKey) }
    static func configurationForApplying(_ draft: AppConfiguration,
                                         automaticReadingEnabled: Bool) -> AppConfiguration {
        var configuration = draft
        configuration.tokenHubAutomaticReadingEnabled = automaticReadingEnabled
        return configuration
    }
    func apply(_ newConfig: AppConfiguration, upstreamKey: String, quotaKey: String) -> Bool {
        guard stats.active == 0 else { message = "请求进行中，请等待完成后再修改代理配置"; return false }
        do {
            var savedConfig = Self.configurationForApplying(newConfig,
                automaticReadingEnabled: tokenHubAutomaticReadingEnabled)
            if newConfig.dataSource == "localCodex" {
                savedConfig.endpoint = config.endpoint; savedConfig.usageURL = config.usageURL
            }
            _ = try savedConfig.validated()
            if savedConfig.dataSource == "proxy" {
                let old = config
                let resolvedAPI = upstreamKey.isEmpty ? (savedConfig.endpoint == old.endpoint && !apiKey.isEmpty ? apiKey : try KeychainStore.read("upstream", validatedURL: savedConfig.endpoint)) : upstreamKey
                let resolvedUsage = quotaKey.isEmpty && !savedConfig.usageURL.isEmpty ? (savedConfig.usageURL == old.usageURL && !usageKey.isEmpty ? usageKey : try KeychainStore.read("usage", validatedURL: savedConfig.usageURL)) : quotaKey
                try KeychainStore.write("upstream", validatedURL: savedConfig.endpoint, value: resolvedAPI)
                if !savedConfig.usageURL.isEmpty { try KeychainStore.write("usage", validatedURL: savedConfig.usageURL, value: resolvedUsage) }
                if localKey.isEmpty { localKey = try KeychainStore.localToken() }
                apiKey = resolvedAPI; usageKey = resolvedUsage
            }
            try ConfigStore.save(savedConfig)
            config = savedConfig
            if !config.historyEnabled { history.removeAll() }
            message = "设置已保存"; startServices(); return true
        } catch { message = error.localizedDescription; return false }
    }
    func reload() {
        guard stats.active == 0 else { message = "请求进行中，暂不能重新加载"; return }
        do {
            let loaded = try ConfigStore.load()
            if loaded.dataSource == "proxy" {
                localKey = try KeychainStore.localToken()
                apiKey = try KeychainStore.resolve("upstream", environment: "TOKENSTAT_API_KEY", validatedURL: loaded.endpoint)
                usageKey = loaded.usageURL.isEmpty ? "" : try KeychainStore.resolve("usage", environment: "TOKENSTAT_USAGE_KEY", validatedURL: loaded.usageURL)
            } else { apiKey = ""; usageKey = ""; localKey = "" }
            config = loaded; message = "配置已重新加载"; startServices()
        }
        catch { message = error.localizedDescription }
    }
    private func startServices() {
        generation += 1; tokenHubGeneration &+= 1; quotaLoop?.cancel(); quotaFetch?.cancel(); quotaFetch = nil; quotaLoading = false
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        tokenHubQuotaSnapshot = nil; tokenHubQuotaFailure = nil
        tokenHubAutomaticReadingEnabled = config.tokenHubAutomaticReadingEnabled
        tokenHubQuotaStatus = config.dataSource == "localCodex" && tokenHubAutomaticReadingEnabled ? .targetNotRunning : .disabled
        lastTokenHubPermissionCheck = .distantPast; cachedTokenHubPermission = false
        _ = localRefreshScheduler.invalidate()
        localCache = LocalCodexUsageReader.Cache()
        localScan?.cancel(); localScan = nil
        resetQuotaState()
        if config.dataSource == "localCodex" {
            if proxyWasStarted { proxy.stop(); proxyWasStarted = false }
            proxyStatus = "本地模式 · 未启动代理"
            scheduleLocalScan(immediate: true)
            if tokenHubAutomaticReadingEnabled { scheduleTokenHubRefresh(after: 0) }
            return
        }
        proxy.onStatus = { [weak self] status in Task { @MainActor in self?.proxyStatus = status } }
        proxy.onRecord = { [weak self] record in Task { @MainActor in if self?.config.loggingEnabled == true { self?.logger.append(record) } } }
        proxy.start(config: config, apiKey: apiKey, localKey: localKey)
        proxyWasStarted = true
        if !config.usageURL.isEmpty {
            quotaLoop = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.refreshQuota()
                    do { try await Task.sleep(nanoseconds: UInt64(self.config.refreshSeconds * 1e9)) }
                    catch { return }
                }
            }
        }
    }
    /// Clears quota values at a source transition without performing I/O.
    func resetQuotaState() {
        quota = nil
        fiveHourQuota = nil
        sevenDayQuota = nil
        quotaLoading = false
        quotaError = quotaSource == .localCodex ? "本地会话记录不提供月度企业配额"
            : (config.usageURL.isEmpty ? "未配置企业用量接口，已用量未知" : "等待企业接口")
    }
    private func scheduleLocalScan(immediate: Bool = false) {
        localScan?.cancel()
        let version = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isShuttingDown, self.generation == version,
                      self.config.dataSource == "localCodex" else { return }
                guard !self.localScanRunning else { return }
                guard let scanGeneration = self.localRefreshScheduler.begin(now: Date()) else {
                    self.scheduleLocalScan(immediate: false); return
                }
                self.localScanRunning = true
                let directory = LocalCodexUsageReader.defaultSessionsDirectory()
                let cache = self.localCache
                self.localScanQueue.async {
                    let result = try? LocalCodexUsageReader.scan(directory: directory, now: Date(), cache: cache)
                    Task { @MainActor in
                        self.localScanRunning = false
                        guard self.generation == version, self.localRefreshScheduler.complete(generation: scanGeneration, now: Date()) else {
                            if self.config.dataSource == "localCodex", !self.isShuttingDown { self.scheduleLocalScan(immediate: true) }
                            return
                        }
                        if self.config.dataSource == "localCodex" {
                            if let result {
                                self.localSnapshot = result; self.fiveHourQuota = result.fiveHour; self.sevenDayQuota = result.sevenDay
                                self.quotaError = result.latestEventAt == nil ? "未发现有效本地用量记录" : "额度来自 Codex 会话事件，可能已过期"
                            } else {
                                self.localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0, filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil, knownThreadCount: 0, unknownThreadCount: 0, unidentifiedFileCount: 0, subagentCount: 0, forkCount: 0)
                                self.fiveHourQuota = nil; self.sevenDayQuota = nil; self.quotaError = "本地会话记录暂时无法读取"
                            }
                        }
                        if self.config.dataSource == "localCodex" { self.scheduleLocalScan() }
                    }
                }
            }
        }
        localScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 5), execute: work)
    }
    func refreshTokenHubQuota() {
        guard !isShuttingDown else { return }
        guard !isFixtureUsingNativeTokenHubReader else { return }
        guard config.dataSource == "localCodex", tokenHubAutomaticReadingEnabled else {
            invalidateTokenHubQuota(status: .disabled); tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
            return
        }
        checkTokenHubPermissionIfDue(scheduleIfGranted: false)
        guard cachedTokenHubPermission else { invalidateTokenHubQuota(status: .permissionRequired); return }
        guard !tokenHubScanInFlight else { return }
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        tokenHubScanInFlight = true
        let version = tokenHubGeneration, mode: TokenHubRunMode = .localCodex
        let now = tokenHubNow(), interval = config.refreshSeconds
        let scanner = tokenHubScanner
        let permission = cachedTokenHubPermission
        tokenHubQueue.async { [weak self] in
            let result = scanner.scan(now: now, monotonicNow: { ProcessInfo.processInfo.systemUptime },
                                      permissionTrusted: permission, refreshSeconds: interval,
                                      mode: mode, generation: version)
            Task { @MainActor in
                guard let self else { return }
                self.tokenHubScanInFlight = false
                guard !self.isShuttingDown, self.tokenHubGeneration == version,
                      self.config.dataSource == "localCodex", self.tokenHubAutomaticReadingEnabled,
                      self.cachedTokenHubPermission else {
                    if !self.isShuttingDown, self.config.dataSource == "localCodex",
                       self.tokenHubAutomaticReadingEnabled, self.cachedTokenHubPermission {
                        self.scheduleTokenHubRefresh(after: 0)
                    }
                    return
                }
                self.applyTokenHubQuotaResult(result, generation: version, mode: mode, now: self.tokenHubNow())
                self.scheduleTokenHubRefresh(after: self.config.refreshSeconds)
            }
        }
    }

    func setTokenHubAutomaticReadingEnabled(_ enabled: Bool) {
        guard tokenHubAutomaticReadingEnabled != enabled else { return }
        tokenHubAutomaticReadingEnabled = enabled
        tokenHubGeneration &+= 1
        config.tokenHubAutomaticReadingEnabled = enabled
        if !isPreview { try? ConfigStore.save(config) }
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        if enabled && config.dataSource == "localCodex" && !isShuttingDown {
            tokenHubQuotaStatus = .targetNotRunning; tokenHubQuotaFailure = nil
            lastTokenHubPermissionCheck = .distantPast
            scheduleTokenHubRefresh(after: 0)
        } else { invalidateTokenHubQuota(status: .disabled) }
    }

    func requestTokenHubAccessibilityAccess() {
        guard !isPreview, !isTestFixture, config.dataSource == "localCodex", tokenHubAutomaticReadingEnabled, !isShuttingDown else { return }
        tokenHubPermissionProvider.requestOnceAndOpenSystemSettings()
        lastTokenHubPermissionCheck = .distantPast
        checkTokenHubPermissionIfDue(scheduleIfGranted: false)
        if cachedTokenHubPermission { refreshTokenHubQuota() }
        else { invalidateTokenHubQuota(status: .permissionRequired) }
    }

    func invalidateTokenHubQuota(status: TokenHubQuotaStatus) {
        tokenHubGeneration &+= 1
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        tokenHubQuotaSnapshot = nil; tokenHubQuotaFailure = nil; tokenHubQuotaStatus = status
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
        guard config.dataSource == "localCodex", tokenHubAutomaticReadingEnabled,
              tokenHubQuotaStatus == .connected, let snapshot = tokenHubQuotaSnapshot,
              snapshot.observedAt <= now,
              now.timeIntervalSince(snapshot.observedAt) <= max(120, config.refreshSeconds * 2) else { return nil }
        return snapshot
    }

    private func checkTokenHubPermissionIfDue(scheduleIfGranted: Bool = true) {
        let now = tokenHubNow()
        guard now.timeIntervalSince(lastTokenHubPermissionCheck) >= 2 else { return }
        let old = cachedTokenHubPermission
        cachedTokenHubPermission = tokenHubPermissionProvider.isTrusted()
        lastTokenHubPermissionCheck = now
        if old && !cachedTokenHubPermission { invalidateTokenHubQuota(status: .permissionRequired) }
        if scheduleIfGranted && !old && cachedTokenHubPermission && config.dataSource == "localCodex" && tokenHubAutomaticReadingEnabled {
            scheduleTokenHubRefresh(after: 0)
        }
    }

    private func pollTokenHubPermissionIfDue() {
        guard config.dataSource == "localCodex", tokenHubAutomaticReadingEnabled, !isShuttingDown,
              !isFixtureUsingNativeTokenHubReader else { return }
        checkTokenHubPermissionIfDue()
    }

    private func scheduleTokenHubRefresh(after seconds: TimeInterval) {
        guard config.dataSource == "localCodex", tokenHubAutomaticReadingEnabled,
              !isShuttingDown, !tokenHubScanInFlight, !isFixtureUsingNativeTokenHubReader else { return }
        tokenHubRefreshWork?.cancel()
        let version = tokenHubGeneration
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.isShuttingDown, self.tokenHubGeneration == version,
                      self.config.dataSource == "localCodex", self.tokenHubAutomaticReadingEnabled else { return }
                self.refreshTokenHubQuota()
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
            scannerIsNative: tokenHubScanner is TokenHubAXReader)
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
        guard bundleIdentifier == TokenHubTarget.bundleID, !isShuttingDown else { return }
        invalidateTokenHubQuota(status: config.dataSource == "localCodex" ? .targetNotRunning : .disabled)
    }

    /// Metadata-only lifecycle seam; a launch never makes an old snapshot current.
    func tokenHubApplicationDidLaunch(bundleIdentifier: String) {
        guard bundleIdentifier == TokenHubTarget.bundleID, !isShuttingDown else { return }
        invalidateTokenHubQuota(status: config.dataSource == "localCodex" && tokenHubAutomaticReadingEnabled
            ? .targetNotRunning : .disabled)
        guard config.dataSource == "localCodex", tokenHubAutomaticReadingEnabled,
              !isFixtureUsingNativeTokenHubReader else { return }
        checkTokenHubPermissionIfDue(scheduleIfGranted: false)
        guard cachedTokenHubPermission else {
            tokenHubQuotaStatus = .permissionRequired
            return
        }
        scheduleTokenHubRefresh(after: 0)
    }

    func refreshQuota() {
        guard config.dataSource == "proxy", !config.usageURL.isEmpty, !quotaLoading else { return }
        quotaLoading = true
        let config = config, key = usageKey, version = generation
        quotaFetch = Task { [weak self] in
            defer { if self?.generation == version { self?.quotaLoading = false } }
            do {
                let result = try await QuotaClient.fetch(config: config, key: key)
                guard !Task.isCancelled, self?.generation == version else { return }
                self?.quota = result.monthly; self?.quotaError = result.monthlyMessage
                self?.fiveHourQuota = result.fiveHour; self?.sevenDayQuota = result.sevenDay
            } catch {
                guard !Task.isCancelled, self?.generation == version else { return }
                self?.quotaError = (error as? StatError)?.localizedDescription ?? "企业用量请求失败：检查网络、URL 和认证"
            }
        }
    }
    func copyConnection() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://127.0.0.1:\(config.port)/v1", forType: .string)
        message = "已复制本机 Base URL"
    }
    func copyKey() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(localKey, forType: .string)
        message = "已复制本机访问令牌（仅供客户端连接本机代理）"
    }
    func exportLogs() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "TokenStatMenu-statistics.jsonl"
        panel.allowedContentTypes = [.json, .data]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.logger.export(to: url) { error in
                Task { @MainActor in self?.message = error ?? "统计日志已导出" }
            }
        }
    }
}
