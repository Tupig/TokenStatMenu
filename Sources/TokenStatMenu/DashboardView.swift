import SwiftUI
#if SWIFT_PACKAGE
import TokenStatCore
#endif

// SDK 同时提供 State 宏时，显式选择属性包装器。
typealias ValueState<Value> = SwiftUI.State<Value>

@MainActor struct DashboardView: View {
    @ObservedObject var model: AppModel
    @ValueState private var settings = false
    private let initialLocalHistoryExpanded: Bool
    private let panelSize: CGSize
    private let quitAction: @MainActor () -> Void
    init(model: AppModel, settings: Bool = false, localHistoryExpanded: Bool = false,
         panelSize: CGSize = PanelMetrics.size,
         quitAction: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        self.model = model
        _settings = State(initialValue: settings)
        initialLocalHistoryExpanded = localHistoryExpanded
        self.panelSize = panelSize
        self.quitAction = quitAction
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
                    overviewContent
                }
            }
            footer
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .background(.regularMaterial)
        .background(PanelPalette.gradient.opacity(0.09))
        .groupBoxStyle(PanelCardStyle())
        .tint(PanelPalette.blue)
    }
    /// 与完整渲染测试共用实际卡片样式和内边距，不在 ScrollView 外重建一份布局。
    var overviewContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            tokenHubCard
            Text(model.userFacingStatus)
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if model.quotaSource == .localCodex {
                // 正式界面隐藏本地历史额度，仅供显式开启的离线预览与回归测试使用。
                if initialLocalHistoryExpanded {
                    LocalHistoryDisclosure(initiallyExpanded: true) {
                        localQuotaCard
                    }
                }
            } else {
                // 通用企业分支仅供模拟预览，正式界面不显示本地历史额度。
                HStack(alignment: .top, spacing: 10) {
                    WindowQuotaCard(title: "5 小时额度", quota: model.fiveHourQuota,
                        color: PanelPalette.blue, refreshSeconds: model.config.refreshSeconds, source: model.quotaSource)
                    WindowQuotaCard(title: "7 天额度", quota: model.sevenDayQuota,
                        color: PanelPalette.violet, refreshSeconds: model.config.refreshSeconds, source: model.quotaSource)
                }
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
        .groupBoxStyle(PanelCardStyle())
        .tint(PanelPalette.blue)
    }
    var tokenHubCard: TokenHubQuotaCard {
        let now = model.tokenHubNow()
        let projection = model.quotaPresentation(at: now)
        return TokenHubQuotaCard(presentation: projection, status: model.tokenHubQuotaStatusText,
            enabled: model.tokenHubQuotaReadingEnabled, refreshSeconds: model.preferences.refreshSeconds,
            directSource: model.tokenHubQuotaIsDirect)
    }
    private var header: some View {
        HStack(spacing: 10) {
            TokenStatMark()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("TokenStatMenu").font(.system(size: 15, weight: .bold, design: .rounded))
                Text(settings ? "Seasun Token Hub · 偏好设置" : "Seasun Token Hub · \(model.tokenHubQuotaIsDirect && model.freshTokenHubQuota(at: model.tokenHubNow()) != nil ? "后台额度已连接" : "后台额度等待连接")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { settings.toggle() } label: {
                Image(systemName: settings ? "chart.bar.xaxis" : "slider.horizontal.3")
                    .frame(width: HeaderActionMetrics.actionSize, height: HeaderActionMetrics.actionSize)
            }.buttonStyle(NeutralHeaderActionButtonStyle()).help(settings ? "返回概览" : "偏好设置")
                .accessibilityLabel(settings ? "返回概览" : "偏好设置")
            Button { quitAction() } label: {
                Image(systemName: "power").frame(width: HeaderActionMetrics.actionSize, height: HeaderActionMetrics.actionSize)
            }.buttonStyle(NeutralHeaderActionButtonStyle()).help("退出 TokenStatMenu").accessibilityLabel("退出")
        }.padding(14)
    }
    private var localQuotaCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                historyWindow("5 小时历史", quota: model.fiveHourQuota)
                historyWindow("7 天历史", quota: model.sevenDayQuota)
                Text("本地记录额度始终只是历史参考，不论事件是否新鲜；不代表当前企业剩余额度，也不触发企业额度告警。保留源记录的已用比例、记录时间和原重置时间。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if let at = model.fiveHourQuota?.fetchedAt ?? model.sevenDayQuota?.fetchedAt { Text("额度事件时间：\(at.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        } label: { Label("本地 Codex 历史", systemImage: "clock") }
    }
    private func historyWindow(_ title: String, quota: WindowQuota?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .medium))
            Text(localQuotaDescription(quota))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
    private func localQuotaDescription(_ quota: WindowQuota?) -> String {
        let state = WindowQuotaCard.presentation(for: quota, refreshSeconds: model.config.refreshSeconds, source: .localCodex)
        guard let percent = state.usedPercent else { return state.statusLabel }
        let reset = state.resetsAt.map { " · \($0.formatted(date: .abbreviated, time: .shortened))重置" } ?? " · 重置时间未知"
        let recorded = state.recordedAt.map { " · 记录于 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        return "\(state.sourceLabel) · \(state.statusLabel) · 上游已用 \(TwoDecimalPercentFormatter.string(percent))\(recorded)\(reset)"
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(model.activityIsLive ? Color.green : Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
            Text(model.message.isEmpty ? model.sourceReadinessText : model.message)
                .lineLimit(2).font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(.horizontal, 16).padding(.vertical, 9)
    }
}

/// 展开状态由已挂载视图持有，不进入模型或偏好设置，也便于独立托管概览进行渲染测试。
private struct LocalHistoryDisclosure<Content: View>: View {
    @ValueState private var expanded: Bool
    private let content: Content

    init(initiallyExpanded: Bool, @ViewBuilder content: () -> Content) {
        _expanded = SwiftUI.State(initialValue: initiallyExpanded)
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content.padding(.top, 8)
        } label: {
            Label("本地历史额度（非企业当前额度）", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .accessibilityHint("只显示本地历史记录，不代表企业当前剩余额度")
    }
}
