import SwiftUI
#if SWIFT_PACKAGE
import TokenStatCore
#endif

// Select the property wrapper explicitly for SDKs that also expose a State macro.
typealias ValueState<Value> = SwiftUI.State<Value>

@MainActor struct DashboardView: View {
    @ObservedObject var model: AppModel
    @ValueState private var settings = false
    private let initialLocalHistoryExpanded: Bool
    init(model: AppModel, settings: Bool = false, localHistoryExpanded: Bool = false) {
        self.model = model
        _settings = State(initialValue: settings)
        initialLocalHistoryExpanded = localHistoryExpanded
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
        .frame(width: 460, height: 700)
        .background(.regularMaterial)
        .background(PanelPalette.gradient.opacity(0.09))
        .groupBoxStyle(PanelCardStyle())
        .tint(PanelPalette.blue)
    }
    /// Shared with full-content rendering checks, including the actual card
    /// styles and insets rather than a reconstruction outside the ScrollView.
    var overviewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            tokenHubCard
            Text(model.userFacingStatus)
                .font(.system(size: 10)).foregroundStyle(.secondary)
            localUsageCard
            if model.quotaSource == .localCodex {
                LocalHistoryDisclosure(initiallyExpanded: initialLocalHistoryExpanded) {
                    localQuotaCard
                }
            } else {
                // The generic enterprise branch is available to synthetic
                // previews only; production local history has its own section.
                HStack(alignment: .top, spacing: 10) {
                    WindowQuotaCard(title: "5 小时额度", quota: model.fiveHourQuota,
                        color: PanelPalette.blue, refreshSeconds: model.config.refreshSeconds, source: model.quotaSource)
                    WindowQuotaCard(title: "7 天额度", quota: model.sevenDayQuota,
                        color: PanelPalette.violet, refreshSeconds: model.config.refreshSeconds, source: model.quotaSource)
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .groupBoxStyle(PanelCardStyle())
        .tint(PanelPalette.blue)
    }
    var tokenHubCard: TokenHubQuotaCard {
        TokenHubQuotaCard(snapshot: model.freshTokenHubQuota(at: model.tokenHubNow()), status: model.tokenHubQuotaStatusText,
            enabled: model.tokenHubQuotaReadingEnabled, refreshSeconds: model.preferences.refreshSeconds,
            directSource: model.tokenHubQuotaIsDirect)
    }
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(PanelPalette.gradient, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("TokenStatMenu").font(.system(size: 16, weight: .bold, design: .rounded))
                Text(settings ? "Seasun Token Hub · 偏好设置" : "Seasun Token Hub · \(model.tokenHubQuotaIsDirect && model.freshTokenHubQuota(at: model.tokenHubNow()) != nil ? "后台额度已连接" : "后台额度等待连接")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { settings.toggle() } label: {
                Image(systemName: settings ? "chart.bar.xaxis" : "slider.horizontal.3")
                    .frame(width: HeaderActionMetrics.actionSize, height: HeaderActionMetrics.actionSize)
            }.buttonStyle(NeutralHeaderActionButtonStyle()).help(settings ? "返回概览" : "偏好设置")
                .accessibilityLabel(settings ? "返回概览" : "偏好设置")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").frame(width: HeaderActionMetrics.actionSize, height: HeaderActionMetrics.actionSize)
            }.buttonStyle(NeutralHeaderActionButtonStyle()).help("退出 TokenStatMenu").accessibilityLabel("退出")
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
                if let live = model.freshLocalLiveTurn {
                    metric("实时估算 · 输入 tok/s", String(format: "%.1f", live.inputTPS))
                    metric("实时估算 · 输出 tok/s", String(format: "%.1f", live.outputTPS))
                    metric("实时观测时间", live.observedAt.formatted(date: .abbreviated, time: .shortened))
                } else {
                    metric("实时估算 · 输出 tok/s", "未知")
                }
                if !model.history.isEmpty {
                    SpeedHistorySparkline(points: model.history)
                        .frame(height: 42)
                        .accessibilityLabel("最近十分钟输出 token 每秒变化")
                }
                if let turn = model.localSnapshot.lastTurn {
                    metric("上轮记录均速", String(format: "%.1f tok/s", turn.outputTPS))
                    metric("上轮完成时间", turn.completedAt.formatted(date: .abbreviated, time: .shortened))
                } else {
                    metric("上轮记录均速", "未知")
                }
                Text("汇总与当前配置关联的本机 Codex 记录；历史路由未核验，无法核算的记录不计入小计。实时值来自活动 token_count 的短窗口估算，事件停止推进时会变为未知；上轮均速含工具、网络和等待。\(model.localSnapshot.isLimited ? "已达到扫描范围限制。" : "")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } label: { Label("本地记录用量", systemImage: "doc.text.magnifyingglass") }
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
        } label: { Label("本地 Codex 历史 · 账号/组织未核验", systemImage: "clock") }
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
    private func metric(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).fontWeight(.medium).monospacedDigit().textSelection(.enabled) }.font(.system(size: 11))
    }
    private func count(_ n: Int) -> String { n.formatted() }
    private func localCount(_ n: Int) -> String { model.localSnapshot.knownThreadCount == 0 ? "—" : count(n) }
    private func count(_ n: Double) -> String { n.formatted(.number.precision(.fractionLength(0))) }
}

/// Expansion belongs to this installed view, never to the model or preferences.
/// Keeping the State here also lets a detached overview be hosted for rendering
/// without accessing a State projection on an uninstalled DashboardView value.
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

private struct SpeedHistorySparkline: View {
    let points: [SpeedPoint]

    var body: some View {
        GeometryReader { proxy in
            let values = points.map(\.value)
            let maximum = max(values.max() ?? 1, 1)
            let minimum = values.min() ?? 0
            let span = max(maximum - minimum, 1)
            Path { path in
                for (index, point) in points.enumerated() {
                    let x = points.count <= 1 ? 0 : proxy.size.width * CGFloat(index) / CGFloat(points.count - 1)
                    let y = proxy.size.height * (1 - CGFloat((point.value - minimum) / span))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(PanelPalette.blue, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .overlay(alignment: .topLeading) {
                Text("近 10 分钟 · 输出 tok/s")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
    }
}
