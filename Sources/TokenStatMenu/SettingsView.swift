import SwiftUI
#if SWIFT_PACKAGE
import TokenStatCore
#endif

@MainActor struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ValueState private var draft: AppConfiguration
    @ValueState private var apiKey: String
    @ValueState private var quotaKey: String
    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.config)
        let keys = model.credentials()
        _apiKey = State(initialValue: keys.0); _quotaKey = State(initialValue: keys.1)
    }
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("用量来源", selection: $draft.dataSource) {
                    Text("本地 Codex 记录").tag("localCodex")
                    Text("本机代理与企业接口").tag("proxy")
                }.pickerStyle(.segmented)
                if draft.dataSource == "proxy" {
                    discoverySection
                    upstreamSection
                    priceSection
                    quotaSection
                } else {
                    Text("从 ~/.codex/sessions 读取有限范围的历史用量统计，不连接本机代理，不读取密钥。切换到代理模式可恢复企业接口配置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                otherSection
                HStack {
                    Button("保存并应用") { _ = model.apply(draft, upstreamKey: apiKey, quotaKey: quotaKey) }.buttonStyle(.borderedProminent)
                    Button("重新加载 plist") { model.reload(); draft = model.config }
                }
                Text(model.isTestFixture ? "配置：隔离模拟配置" : "配置：\(AppPaths.configURL.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(16)
        }
        .textFieldStyle(.roundedBorder)
        .onChange(of: draft.endpoint) { _ in apiKey = "" }
        .onChange(of: draft.usageURL) { _ in quotaKey = "" }
    }
    private var discoverySection: some View {
        GroupBox("本机网关 · 自动发现") {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.discoveryStatus).font(.caption).foregroundStyle(.secondary)
                ForEach(model.gateways) { gateway in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(gateway.provider + (gateway.isActive ? " · Codex 当前配置" : "")).font(.caption).bold()
                            Spacer()
                            Button("填入") {
                                if draft.endpoint != gateway.endpoint {
                                    // Do not accidentally send old credentials to a newly chosen host.
                                    apiKey = ""; quotaKey = ""; draft.usageURL = ""
                                }
                                draft.endpoint = gateway.endpoint; draft.model = gateway.model
                                model.message = "已填入网关地址；请自行配置认证后保存。发现地址不代表已经接入流量。"
                            }
                        }
                        Text(gateway.endpoint).font(.caption2).textSelection(.enabled)
                        Text(gateway.source).font(.caption2).foregroundStyle(.secondary)
                    }
                    Divider()
                }
                Button(model.discovering ? "扫描中…" : "重新扫描") { model.discoverGateways() }.disabled(model.discovering)
                Text("只在本机识别地址、模型与提供方；不读取其他应用的密钥、Cookie 或认证文件。不会修改 Codex 配置，也不会联网探测。更换地址时清空待保存的旧密钥，避免误发。")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(6)
        }
    }
    private var upstreamSection: some View {
        GroupBox("API 与本机代理") {
            VStack(alignment: .leading, spacing: 8) {
                field("上游完整 Endpoint", text: $draft.endpoint)
                Text("例如 https://企业网关/v1/chat/completions；Ollama 可使用 http://127.0.0.1:11434/api/chat")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("上游 API Key（保存在钥匙串）").font(.caption)
                SecureField("Ollama 本机可留空", text: $apiKey)
                field("模型覆盖（留空沿用请求中的 model）", text: $draft.model)
                HStack { Text("本机端口"); TextField("18765", value: $draft.port, format: .number.grouping(.never)).frame(width: 100) }.font(.caption)
                Toggle("Chat 流请求附带 include_usage", isOn: $draft.includeUsage)
                Toggle("允许远程私网 HTTP（密钥将明文传输）", isOn: $draft.allowInsecureHTTP)
                Text("客户端 Base URL 指向本机，客户端 API Key 使用“复制本机令牌”的值。企业 Key 只填在上方。")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(6)
        }
    }
    private var priceSection: some View {
        GroupBox("自定义价格") {
            VStack(alignment: .leading, spacing: 8) {
                number("输入 USD / 百万 Token", value: $draft.inputPrice)
                number("输出 USD / 百万 Token", value: $draft.outputPrice)
                Picker("显示币种", selection: $draft.currency) { Text("USD").tag("USD"); Text("CNY").tag("CNY") }.pickerStyle(.segmented)
                number("1 USD = CNY（手填汇率）", value: $draft.usdToCNY)
            }.padding(6)
        }
    }
    private var quotaSection: some View {
        GroupBox("企业额度接口 · 月度 / 5 小时 / 7 天") {
            VStack(alignment: .leading, spacing: 8) {
                field("用量 GET URL（可留空）", text: $draft.usageURL)
                Text("用量接口 Bearer Key（独立于推理 Key）").font(.caption)
                SecureField("可留空；不自动复用上游密钥", text: $quotaKey)
                field("已用 Token 字段路径", text: $draft.usedPath)
                field("总配额字段路径（可留空）", text: $draft.limitPath)
                field("月份字段路径（yyyy-MM；留空信任接口本月语义）", text: $draft.periodPath)
                number("手动月度 Token 上限（0 = 接口值）", value: $draft.monthlyLimit)
                number("刷新秒数（15–3600）", value: $draft.refreshSeconds)
                Divider()
                field("5 小时已用百分比字段（0–100）", text: $draft.fiveHourUsedPercentPath)
                field("5 小时重置时间字段", text: $draft.fiveHourResetPath)
                field("7 天已用百分比字段（0–100）", text: $draft.sevenDayUsedPercentPath)
                field("7 天重置时间字段", text: $draft.sevenDayResetPath)
                Text("重置时间支持 Unix 秒或 ISO 8601。缺少窗口时显示未提供；不会从月度配额或本机 Token 推算。也可接收带明确窗口时长的 Codex rateLimits 格式。")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("月度已用量、总配额和手动月度上限必须使用 Token 数量，不能填金额或积分；窗口字段使用 0–100 的百分比。手动配额不会推算全企业已用量。达到 80% 黄色、95% 红色，仅改变菜单栏颜色。")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(6)
        }
    }
    private var otherSection: some View {
        GroupBox("历史与日志") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("显示近 10 分钟速度图", isOn: $draft.historyEnabled)
                Toggle("记录脱敏请求统计日志", isOn: $draft.loggingEnabled)
                Text("不记录提示词、回答或密钥。日志只保留当前与上一份，每份约 10MB；本次启动统计不会从日志恢复。")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("导出日志") { model.exportLogs() }
            }.padding(6)
        }
    }
    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(label).font(.caption); TextField(label, text: text).labelsHidden() }
    }
    private func number(_ label: String, value: Binding<Double>) -> some View {
        HStack { Text(label); Spacer(); TextField(label, value: value, format: .number).labelsHidden().frame(width: 110) }.font(.caption)
    }
}
