import AppKit
import Combine
#if SWIFT_PACKAGE
import TokenStatCore
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
    @Published var quota: QuotaSnapshot?
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
    private var generation = 0
    private var lastHistory = Date.distantPast
    private(set) var localKey = ""
    private var apiKey = ""
    private var usageKey = ""
    var onTick: (() -> Void)?

    init(preview: Bool = false) {
        // Offline view rendering must never touch local configuration or credentials.
        if preview { proxyStatus = "模拟预览 · 无网络、无本机配置"; discoveryStatus = "离线预览"; return }
        proxy.onStatus = { [weak self] status in Task { @MainActor in self?.proxyStatus = status } }
        proxy.onRecord = { [weak self] record in
            Task { @MainActor in if self?.config.loggingEnabled == true { self?.logger.append(record) } }
        }
        logger.onError = { [weak self] error in Task { @MainActor in self?.message = error } }
        do {
            config = try ConfigStore.load()
            localKey = try KeychainStore.localToken()
            apiKey = try KeychainStore.resolve("upstream", environment: "TOKENSTAT_API_KEY")
            usageKey = try KeychainStore.resolve("usage", environment: "TOKENSTAT_USAGE_KEY")
            startServices()
        } catch { message = error.localizedDescription; proxyStatus = "未启动：检查设置" }
        // A single 2Hz main timer updates menu text. Network callbacks never redraw the UI.
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        timer?.tolerance = 0.1
        RunLoop.main.add(timer!, forMode: .common)
        discoverGateways()
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
    func shutdown() { timer?.invalidate(); quotaLoop?.cancel(); quotaFetch?.cancel(); proxy.stop() }
    func tick() {
        stats = engine.snapshot()
        let now = Date()
        if config.historyEnabled, now.timeIntervalSince(lastHistory) >= 1 {
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
    var hasRequestData: Bool { stats.requests > 0 }
    var dataNotice: String {
        if isTestFixture { return "模拟测试 · 以下速度、Token、费用和配额均非企业真实数据" }
        return hasRequestData ? "本次启动 · 仅统计经过本机代理的请求" : "未采集到请求数据 · 尚未观测到客户端流量"
    }
    var title: String {
        let value = !hasRequestData ? "T:—" : stats.active > 0
            ? String(format: "T:≈%.1ftok/s", stats.outputTPS) : "T:0.0tok/s"
        return (isTestFixture ? "测试 " : "") + value
    }
    var alertColor: NSColor {
        guard let ratio = freshQuota?.fraction else { return .labelColor }
        return ratio >= 0.95 ? .systemRed : ratio >= 0.8 ? .systemYellow : .labelColor
    }
    func credentials() -> (String, String) { (apiKey, usageKey) }
    func apply(_ newConfig: AppConfiguration, upstreamKey: String, quotaKey: String) -> Bool {
        guard stats.active == 0 else { message = "请求进行中，请等待完成后再修改代理配置"; return false }
        do {
            _ = try newConfig.validated()
            try KeychainStore.write("upstream", value: upstreamKey)
            try KeychainStore.write("usage", value: quotaKey)
            if localKey.isEmpty { localKey = try KeychainStore.localToken() }
            try ConfigStore.save(newConfig)
            config = newConfig; apiKey = upstreamKey; usageKey = quotaKey
            if !config.historyEnabled { history.removeAll() }
            message = "设置已保存"; startServices(); return true
        } catch { message = error.localizedDescription; return false }
    }
    func reload() {
        guard stats.active == 0 else { message = "请求进行中，暂不能重新加载"; return }
        do { config = try ConfigStore.load(); message = "配置已重新加载"; startServices() }
        catch { message = error.localizedDescription }
    }
    private func startServices() {
        generation += 1; quotaLoop?.cancel(); quotaFetch?.cancel(); quotaFetch = nil; quotaLoading = false
        quota = nil; quotaError = config.usageURL.isEmpty ? "未配置企业用量接口，已用量未知" : "等待企业接口"
        proxy.start(config: config, apiKey: apiKey, localKey: localKey)
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
    func refreshQuota() {
        guard !config.usageURL.isEmpty, !quotaLoading else { return }
        quotaLoading = true
        let config = config, key = usageKey, version = generation
        quotaFetch = Task { [weak self] in
            defer { if self?.generation == version { self?.quotaLoading = false } }
            do {
                let result = try await QuotaClient.fetch(config: config, key: key)
                guard !Task.isCancelled, self?.generation == version else { return }
                self?.quota = result; self?.quotaError = ""
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
