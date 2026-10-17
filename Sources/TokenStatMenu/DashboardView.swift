import SwiftUI
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
                        TokenHubQuotaCard(snapshot: model.freshTokenHubQuota(at: Date()), status: model.tokenHubQuotaStatusText,
                            enabled: model.tokenHubAutomaticReadingEnabled, refreshSeconds: model.preferences.refreshSeconds,
                            directSource: model.tokenHubQuotaIsDirect)
                        Text(model.userFacingStatus)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        localUsageCard
                        HStack(alignment: .top, spacing: 10) {
                            WindowQuotaCard(title: "5 小时额度", quota: model.fiveHourQuota,
                                color: PanelPalette.blue, refreshSeconds: model.config.refreshSeconds, source: model.quotaSource)
                            WindowQuotaCard(title: "7 天额度", quota: model.sevenDayQuota,
                                color: PanelPalette.violet, refreshSeconds: model.config.refreshSeconds, source: model.quotaSource)
                        }
                        localQuotaCard
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
                Text(settings ? "Seasun Token Hub · 偏好设置" : "Seasun Token Hub · 后台直接来源未接通")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { settings.toggle() } label: {
                Image(systemName: settings ? "chart.bar.xaxis" : "slider.horizontal.3")
                    .frame(width: 28, height: 28)
            }.buttonStyle(.borderless).foregroundStyle(.secondary).help(settings ? "返回概览" : "偏好设置")
                .accessibilityLabel(settings ? "返回概览" : "偏好设置")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").frame(width: 24, height: 28)
            }.buttonStyle(.borderless).foregroundStyle(.secondary).help("退出 TokenStatMenu").accessibilityLabel("退出")
        }.padding(16)
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
    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(model.stats.active > 0 ? Color.green : Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
            Text(model.message.isEmpty ? model.sourceReadinessText : model.message)
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
}
