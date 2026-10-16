import SwiftUI
import Charts
#if SWIFT_PACKAGE
import TokenStatCore
#endif

// Select the property wrapper explicitly for SDKs that also expose a State macro.
typealias ValueState<Value> = SwiftUI.State<Value>

@MainActor struct DashboardView: View {
    @ObservedObject var model: AppModel
    @ValueState private var settings = false
    init(model: AppModel, settings: Bool = false) {
        self.model = model
        _settings = State(initialValue: settings)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isTestFixture || model.config.dataSource == "localCodex" || !model.hasRequestData {
                HStack(spacing: 7) {
                    Image(systemName: model.isTestFixture ? "testtube.2" : "info.circle")
                    Text(model.dataNotice).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10))
                .foregroundStyle(model.isTestFixture ? Color.orange : Color.secondary)
                .padding(.horizontal, 16).padding(.bottom, 10)
            }
            if settings { SettingsView(model: model) }
            else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.config.dataSource == "localCodex" { localUsageCard } else { liveCard }
                        HStack(alignment: .top, spacing: 10) {
                            WindowQuotaCard(title: "5 小时额度", quota: model.fiveHourQuota,
                                color: PanelPalette.blue, refreshSeconds: model.config.refreshSeconds, source: model.quotaSource)
                            WindowQuotaCard(title: "7 天额度", quota: model.sevenDayQuota,
                                color: PanelPalette.violet, refreshSeconds: model.config.refreshSeconds, source: model.quotaSource)
                        }
                        if model.config.dataSource == "localCodex" { localQuotaCard } else { sessionCard; quotaCard }
                        if model.config.dataSource == "proxy", model.config.historyEnabled, model.panelVisible { historyCard }
                        if model.config.dataSource == "proxy" { costCard; requestCard; connectionCard }
                    }.padding(.horizontal, 16).padding(.bottom, 14)
                }
            }
            footer
        }
        .frame(width: 460, height: 700)
        .background(.regularMaterial)
        .background(PanelPalette.gradient.opacity(0.09))
        .groupBoxStyle(PanelCardStyle())
        .tint(PanelPalette.blue)
    }
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(PanelPalette.gradient, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("TokenStatMenu").font(.system(size: 16, weight: .bold, design: .rounded))
                Text(settings ? "本机网关与偏好设置" : (model.config.dataSource == "localCodex" ? "本地 Codex · 历史记录" : "实时用量 · 本次启动"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { settings.toggle() } label: {
                Image(systemName: settings ? "chart.bar.xaxis" : "slider.horizontal.3")
                    .frame(width: 28, height: 28)
            }.buttonStyle(.borderless).foregroundStyle(.secondary).help(settings ? "返回概览" : "连接与设置")
                .accessibilityLabel(settings ? "返回概览" : "连接与设置")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").frame(width: 24, height: 28)
            }.buttonStyle(.borderless).foregroundStyle(.secondary).help("退出 TokenStatMenu").accessibilityLabel("退出")
        }.padding(16)
    }
    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("实时输出", systemImage: "bolt.horizontal.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(PanelPalette.blue)
                Spacer()
                StatusPill(label: model.stats.active > 0 ? "\(model.stats.active) 个请求进行中" : model.hasRequestData ? "当前空闲" : "等待接入",
                    color: model.stats.active > 0 ? .green : PanelPalette.violet)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(!model.hasRequestData ? "—" : model.stats.active > 0 ? String(format: "≈%.1f", model.stats.outputTPS) : "0.0")
                    .font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("tok/s").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("输入 / 首输出等待").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(model.stats.active > 0 ? String(format: "≈%.1f", model.stats.inputWaitTPS) : "—")
                        .font(.system(size: 19, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("tok/s · 推算").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            Text("输出为 5 秒窗口文本估算；输入比值含网络与排队时间。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let rate = model.stats.last?.serverOutputTPS {
                metric("上次 Ollama 服务端平均输出", String(format: "%.1f tok/s", rate))
            }
            if let rate = model.stats.last?.serverInputTPS {
                metric("上次 Ollama 服务端平均输入", String(format: "%.1f tok/s", rate))
            }
        }
        .padding(16)
        .background(PanelPalette.gradient.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(PanelPalette.blue.opacity(0.22)))
    }
    private var localUsageCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                metric("已核验小计 · 输入 Token", localCount(model.localSnapshot.input))
                metric("已核验小计 · 输出 Token", localCount(model.localSnapshot.output))
                metric(model.localSnapshot.hasCompleteAccounting ? "本次扫描记录量 · Token" : "已核验记录小计 · 总 Token",
                    model.localSnapshot.knownThreadCount > 0 ? count(model.localSnapshot.total) : "未知")
                metric("已核验线程", "\(model.localSnapshot.knownThreadCount)")
                metric("未核验线程", "\(model.localSnapshot.unknownThreadCount)")
                metric("未识别物理文件", "\(model.localSnapshot.unidentifiedFileCount)")
                metric("已识别顶层对话", "\(model.localSnapshot.sessionCount)")
                metric("已识别子代理 / 分叉", "\(model.localSnapshot.subagentCount) / \(model.localSnapshot.forkCount)")
                metric("最近用量事件", model.localSnapshot.latestEventAt?.formatted(date: .abbreviated, time: .shortened) ?? "未发现")
                if let turn = model.localSnapshot.lastTurn {
                    metric("上轮记录均速", String(format: "%.1f tok/s", turn.outputTPS))
                    metric("上轮完成时间", turn.completedAt.formatted(date: .abbreviated, time: .shortened))
                } else {
                    metric("上轮记录均速", "未知")
                }
                Text("仅汇总本次扫描中可核算的记录，未核验项不计入小计。顶层对话数不包含子代理和分叉；这里不是完整历史或企业账单。上轮均速含工具、网络和等待，不是模型瞬时生成速度。\(model.localSnapshot.isLimited ? "已达到扫描范围限制。" : "")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } label: { Label("本地记录用量", systemImage: "doc.text.magnifyingglass") }
    }
    private var localQuotaCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                metric("5 小时额度", localQuotaDescription(model.fiveHourQuota))
                metric("7 天额度", localQuotaDescription(model.sevenDayQuota))
                Text("本地记录额度始终只是历史参考，不论事件是否新鲜；不代表当前企业剩余额度，也不触发企业额度告警。保留源记录的已用比例、记录时间和原重置时间。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if let at = model.fiveHourQuota?.fetchedAt ?? model.sevenDayQuota?.fetchedAt { Text("额度事件时间：\(at.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        } label: { Label("本地额度快照", systemImage: "chart.bar") }
    }
    private func localQuotaDescription(_ quota: WindowQuota?) -> String {
        let state = WindowQuotaCard.presentation(for: quota, refreshSeconds: model.config.refreshSeconds, source: .localCodex)
        guard let percent = state.usedPercent else { return state.statusLabel }
        let reset = state.resetsAt.map { " · \($0.formatted(date: .abbreviated, time: .shortened))重置" } ?? " · 重置时间未知"
        let recorded = state.recordedAt.map { " · 记录于 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        return "\(state.sourceLabel) · \(state.statusLabel) · 上游已用 \(String(format: "%.1f", percent))%\(recorded)\(reset)"
    }
    private var sessionCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    tokenTile("总 TOKEN", value: model.stats.total, color: .primary)
                    Divider().frame(height: 40)
                    tokenTile("输入", value: model.stats.input, color: PanelPalette.blue)
                    tokenTile("输出", value: model.stats.output, color: PanelPalette.violet)
                }
                Text(!model.hasRequestData ? "尚无请求数据；这里不代表企业总用量。" : model.stats.estimatedRequests > 0 ? "含 \(model.stats.estimatedRequests) 个请求估算，最终 usage 到达后校正。" : "累计值已由上游 usage 确认。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } label: { Label("本次启动累计", systemImage: "square.stack.3d.up") }
    }
    private func tokenTile(_ label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            Text(measuredCount(value)).font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(color).monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                .textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var quotaCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 18) {
                    QuotaRing(fraction: model.quota?.fraction)
                    VStack(spacing: 7) {
                        metric("已消耗", model.quota.map { count($0.used) } ?? "未知")
                        metric("月度配额", model.quota?.limit.map(count) ?? (model.config.monthlyLimit > 0 ? count(model.config.monthlyLimit) : "未设置"))
                        metric("剩余配额", model.quota?.remaining.map(count) ?? "未知")
                        if let fraction = model.quota?.fraction {
                            ProgressView(value: min(1, max(0, fraction)))
                                .tint(fraction >= 0.95 ? .red : fraction >= 0.8 ? .yellow : PanelPalette.blue)
                        }
                    }
                }
                HStack {
                    if let quota = model.quota {
                        Text(model.freshQuota == nil ? "数据已过期" : "更新于 \(quota.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    } else { Text("配置用量接口后显示企业配额") }
                    Spacer()
                    Button { model.refreshQuota() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).disabled(model.quotaLoading || model.config.usageURL.isEmpty)
                        .help("刷新企业用量").accessibilityLabel("刷新企业用量")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                if !model.quotaError.isEmpty, !model.config.usageURL.isEmpty {
                    Text(model.quotaError).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        } label: { HStack { Label("企业配额", systemImage: "chart.donut"); Spacer(); Text(QuotaSnapshot.currentMonth()).font(.system(size: 10)) } }
    }
    private var costCard: some View {
        GroupBox {
            VStack(spacing: 8) {
                metric("输入 / 百万 Token", model.config.inputPrice > 0 ? money(model.config.inputPrice * model.currencyFactor) : "未设置 / 免费")
                metric("输出 / 百万 Token", model.config.outputPrice > 0 ? money(model.config.outputPrice * model.currencyFactor) : "未设置 / 免费")
                metric("累计费用", !model.hasRequestData ? "—" : money(model.stats.costUSD * model.currencyFactor))
                Text("按自定义单价估算，非企业账单；零单价不代表实际免费。缓存不另行折扣。\(model.config.currency == "CNY" ? "USD→CNY 汇率 \(model.config.usdToCNY)（手填）。" : "")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } label: { Label("费用估算 · \(model.config.currency)", systemImage: "creditcard") }
    }
    private var requestCard: some View {
        GroupBox {
            VStack(spacing: 8) {
                metric("总请求 / 失败", "\(model.stats.requests) / \(model.stats.failures)")
                metric("平均首响应字节延迟", model.stats.averageFirstByteMS.map { String(format: "%.0f ms", $0) } ?? "—")
                metric("平均完整请求耗时", model.stats.averageDurationMS.map { String(format: "%.0f ms", $0) } ?? "—")
                if let last = model.stats.last {
                    metric("上次请求", "\(last.success ? "完成" : "失败") · \(last.exact ? "usage" : "估算")")
                    if let error = last.error { Text(error).font(.system(size: 10)).foregroundStyle(.orange) }
                }
            }
        } label: { Label("请求与响应", systemImage: "arrow.left.arrow.right") }
    }
    private var historyCard: some View {
        GroupBox {
            Chart(model.history) { point in
                AreaMark(x: .value("时间", point.date), y: .value("tok/s", point.value))
                    .foregroundStyle(LinearGradient(colors: [PanelPalette.blue.opacity(0.22), PanelPalette.violet.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("时间", point.date), y: .value("tok/s", point.value))
                    .foregroundStyle(PanelPalette.blue).lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartYScale(domain: 0...max(1, (model.history.map(\.value).max() ?? 1) * 1.1))
            .frame(height: 96)
            .accessibilityLabel("近十分钟输出 token 估算速度曲线")
        } label: { Label("近 10 分钟 · 输出估算 tok/s", systemImage: "waveform.path.ecg") }
    }
    private var connectionCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Text("仅统计经过本机代理的请求，不自动接管其他应用。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    Button("复制 Base URL") { model.copyConnection() }
                    Button("复制本机令牌") { model.copyKey() }
                    Spacer()
                    Button { model.exportLogs() } label: { Image(systemName: "square.and.arrow.up") }
                        .help("导出统计日志").accessibilityLabel("导出统计日志")
                }.controlSize(.small)
            }
        } label: { Label("本机连接", systemImage: "network") }
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(model.stats.active > 0 ? Color.green : Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
            Text(model.message.isEmpty ? model.proxyStatus : model.message)
                .lineLimit(2).font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(.horizontal, 16).padding(.vertical, 9)
    }
    private func metric(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).fontWeight(.medium).monospacedDigit().textSelection(.enabled) }.font(.system(size: 11))
    }
    private func count(_ n: Int) -> String { n.formatted() }
    private func localCount(_ n: Int) -> String { model.localSnapshot.knownThreadCount == 0 ? "—" : count(n) }
    private func count(_ n: Double) -> String { n.formatted(.number.precision(.fractionLength(0))) }
    private func measuredCount(_ n: Int) -> String {
        guard model.hasRequestData else { return "—" }
        return (model.stats.estimatedRequests > 0 ? "≈" : "") + count(n)
    }
    private func money(_ n: Double) -> String { model.currencySymbol + String(format: "%.6f", n) }
}
