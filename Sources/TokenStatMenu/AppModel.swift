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
    @Published var config = AppConfiguration()
    @Published var stats = MetricsSnapshot()
    @Published var localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0, filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil)
    @Published var quota: QuotaSnapshot?
    @Published var fiveHourQuota: WindowQuota?
    @Published var sevenDayQuota: WindowQuota?
    @Published var quotaError = "未配置企业用量接口"
    @Published var proxyStatus = "启动中"
    @Published var message = ""
    @Published var history: [SpeedPoint] = []
    @Published var quotaLoading = false
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
    private let localScanQueue = DispatchQueue(label: "TokenStatMenu.localCodexScan", qos: .utility)
    private var localCache = LocalCodexUsageReader.Cache()
    private var localRefreshScheduler = LocalRefreshScheduler()
    private var proxyWasStarted = false
    private var isShuttingDown = false
    private var generation = 0
    private var lastHistory = Date.distantPast
    private(set) var localKey = ""
    private var apiKey = ""
    private var usageKey = ""
    var onTick: (() -> Void)?

    init(preview: Bool = false) {
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
    func shutdown() { isShuttingDown = true; generation += 1; _ = localRefreshScheduler.invalidate(); timer?.invalidate(); quotaLoop?.cancel(); quotaFetch?.cancel(); localScan?.cancel(); if proxyWasStarted { proxy.stop() } }
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
        onTick?()
    }
    var freshQuota: QuotaSnapshot? {
        guard let quota, quota.month == QuotaSnapshot.currentMonth(), Date().timeIntervalSince(quota.fetchedAt) < max(120, config.refreshSeconds * 2) else { return nil }
        return quota
    }
    var currencyFactor: Double { config.currency == "CNY" ? config.usdToCNY : 1 }
    var currencySymbol: String { config.currency == "CNY" ? "¥" : "$" }
    var hasRequestData: Bool { config.dataSource == "localCodex" ? localSnapshot.sessionCount > 0 : stats.requests > 0 }
    var dataNotice: String {
        if isTestFixture { return "模拟测试 · 以下速度、Token、费用和配额均非企业真实数据" }
        if config.dataSource == "localCodex" { return "本地 Codex 会话记录 · 历史累计用量，不代表企业总量或实时用量；账号与组织归属未核验" }
        return hasRequestData ? "本次启动 · 仅统计经过本机代理的请求" : "未采集到请求数据 · 尚未观测到客户端流量"
    }
    var title: String {
        if config.dataSource == "localCodex" {
            let rate = localSnapshot.lastTurn.map { String(format: "%.1ftok/s", $0.outputTPS) } ?? "—"
            let total = localSnapshot.sessionCount > 0 ? formatCompactCount(localSnapshot.total) : "—"
            return (isTestFixture ? "测试 " : "") + "上轮均:\(rate) · Σ\(total) · \(localSnapshot.sessionCount)会话"
        }
        let value = !hasRequestData ? "T:—" : stats.active > 0
            ? String(format: "T:≈%.1ftok/s", stats.outputTPS) : "T:0.0tok/s"
        let total = stats.requests > 0 ? formatCompactCount(stats.total) : "—"
        return (isTestFixture ? "测试 " : "") + "\(value) · Σ\(total) · 请求\(stats.requests)"
    }
    var menuTooltip: String {
        guard config.dataSource == "localCodex" else { return "\(dataNotice) · \(proxyStatus)" }
        let turn = localSnapshot.lastTurn.map { String(format: "上轮记录均速：%.1f tok/s（完成于 %@）", $0.outputTPS, $0.completedAt.formatted()) } ?? "上轮记录均速：未知"
        let range = localSnapshot.latestEventAt.map { "最新记录：\($0.formatted())" } ?? "记录时间：未知"
        let coverage = "扫描上限：最多32个会话文件、每文件尾部256KiB、总计8MiB；" + (localSnapshot.isLimited ? "本次达到上限，记录可能不完整" : "本次已检查 \(localSnapshot.filesScanned) 个会话文件，\(localSnapshot.sessionCount) 个含有效累计用量")
        return "本地 Codex 历史累计：\(formatCount(localSnapshot.total)) tokens · \(localSnapshot.sessionCount)会话\n\(coverage)；\(range)\n\(turn)；含工具、网络和等待；不是模型瞬时生成速度\n5 小时额度：\(quotaDescription(fiveHourQuota))\n7 天额度：\(quotaDescription(sevenDayQuota))"
    }
    private func quotaDescription(_ quota: WindowQuota?) -> String {
        guard let quota else { return "未提供" }
        let status = WindowQuotaCard.presentation(for: quota, refreshSeconds: config.refreshSeconds).statusLabel
        let reset = quota.resetsAt.map { "，原重置时间 \($0.formatted())" } ?? "，重置时间未知"
        return "\(status)，上游已用 \(String(format: "%.1f", quota.usedPercent))%\(reset)"
    }
    private func formatCount(_ value: Int) -> String { value.formatted(.number) }
    private func formatCompactCount(_ value: Int) -> String { value.formatted(.number.notation(.compactName)) }
    var alertColor: NSColor {
        let windows = [fiveHourQuota, sevenDayQuota].compactMap { $0 }
            .filter { $0.isFresh(refreshSeconds: config.refreshSeconds) }.map { $0.usedPercent / 100 }
        guard let ratio = (windows + [freshQuota?.fraction].compactMap { $0 }).max() else { return .labelColor }
        return ratio >= 0.95 ? .systemRed : ratio >= 0.8 ? .systemYellow : .labelColor
    }
    func credentials() -> (String, String) { (apiKey, usageKey) }
    func apply(_ newConfig: AppConfiguration, upstreamKey: String, quotaKey: String) -> Bool {
        guard stats.active == 0 else { message = "请求进行中，请等待完成后再修改代理配置"; return false }
        do {
            var savedConfig = newConfig
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
        generation += 1; quotaLoop?.cancel(); quotaFetch?.cancel(); quotaFetch = nil; quotaLoading = false
        _ = localRefreshScheduler.invalidate()
        localCache = LocalCodexUsageReader.Cache()
        localScan?.cancel(); localScan = nil
        quota = nil; quotaError = config.usageURL.isEmpty ? "未配置企业用量接口，已用量未知" : "等待企业接口"
        fiveHourQuota = nil; sevenDayQuota = nil
        if config.dataSource == "localCodex" {
            if proxyWasStarted { proxy.stop(); proxyWasStarted = false }
            proxyStatus = "本地模式 · 未启动代理"
            quota = nil; quotaError = "本地会话记录不提供月度企业配额"
            scheduleLocalScan(immediate: true); return
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
                                self.localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0, filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil)
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
