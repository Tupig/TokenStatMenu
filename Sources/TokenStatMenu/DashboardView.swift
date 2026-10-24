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
    private let initialDetailedMetricsExpanded: Bool
    private let panelSize: CGSize
    private let quitAction: @MainActor () -> Void
    init(model: AppModel, settings: Bool = false, localHistoryExpanded: Bool = false,
         detailedMetricsExpanded: Bool = false, panelSize: CGSize = PanelMetrics.size,
         quitAction: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        self.model = model
        _settings = State(initialValue: settings)
        initialLocalHistoryExpanded = localHistoryExpanded
        initialDetailedMetricsExpanded = detailedMetricsExpanded
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
            localUsageCard
            LocalDetailsDisclosure(initiallyExpanded: initialDetailedMetricsExpanded) {
                localDetailedMetricsCard
            }
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
            Image(systemName: "waveform.path")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(PanelPalette.gradient, in: RoundedRectangle(cornerRadius: 9))
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
    private var localUsageCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                metric("输入 Token", localCount(model.localSnapshot.input))
                metric("输出 Token", localCount(model.localSnapshot.output))
                metric("总 Token", model.localSnapshot.knownThreadCount > 0 ? count(model.localSnapshot.total) : "未知")
                metric("线程", "\(model.localSnapshot.knownThreadCount)")
                metric("其他线程", "\(model.localSnapshot.unknownThreadCount)")
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
                Text("汇总与当前配置关联的本机 Codex 记录；无法核算的记录不计入合计。实时值来自活动 token_count 的短窗口估算，事件停止推进时会变为未知；上轮均速含工具、网络和等待。\(model.localSnapshot.isLimited ? "已达到扫描范围限制。" : "")")
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
        } label: { Label("本地 Codex 历史", systemImage: "clock") }
    }
    private var localDetailedMetricsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                metric("缓存读取", model.localCacheReadout)
                metric("未缓存输入", model.localUncachedInputReadout)
                metric("命中率", model.localCacheHitRateReadout)
                metric("缓存覆盖", model.localCacheCoverageReadout)
                metric("线程轮次明细", model.localSnapshot.detailLimited
                    ? "已达到展示上限" : "当前扫描候选范围")
                if let matched = model.localMatchedCacheReadout {
                    Text(matched).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(model.localReadAtReadout)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                metric("模型调用用时", "未知（来源未提供）")
                metric("平均 TTFT", "未知（来源未提供）")
                metric("decode TPS", "未知（来源未提供）")

                ForEach(model.localSnapshot.details, id: \.opaqueKey) { thread in
                    Divider().padding(.vertical, 3)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("线程 \(thread.ordinal) · \(lineageName(thread.kind))")
                            .font(.system(size: 11, weight: .semibold))
                        metric("输入 Token", localOptionalCount(thread.usage.input))
                        metric("输出 Token", localOptionalCount(thread.usage.output))
                        metric("总计 Token", localOptionalCount(thread.usage.total))
                        metric("缓存读取", localCacheInput(thread.usage.cache))
                        metric("未缓存输入", localOptionalCount(thread.usage.uncachedInput))
                        ForEach(thread.turns, id: \.opaqueKey) { turn in
                            Divider().padding(.vertical, 2)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("轮次 \(turn.ordinal)")
                                    .font(.system(size: 11, weight: .medium))
                                metric("输入 Token", localOptionalCount(turn.usage.input))
                                metric("输出 Token", localOptionalCount(turn.usage.output))
                                metric("总计 Token", localOptionalCount(turn.usage.total))
                                metric("缓存读取", localCacheInput(turn.usage.cache))
                                metric("未缓存输入", localOptionalCount(turn.usage.uncachedInput))
                                metric("整轮用时", localDuration(turn.durationSeconds))
                                metric("整轮均速", localRate(turn.outputTPS))
                                metric("完成时间", turn.completedAt.formatted(date: .abbreviated, time: .shortened))
                            }
                            .padding(.leading, 10)
                        }
                    }
                }
                Text("完整轮次只表示整轮记录均速；没有模型调用、TTFT 或 decode 的来源事件时，这些指标保持未知。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } label: {
            Label("本次缓存与线程汇总", systemImage: "number")
        }
    }
    private func localOptionalCount(_ value: Int?) -> String {
        value.map { count($0) } ?? "未知（无完整数值来源）"
    }
    private func localCacheInput(_ value: LocalCacheInput) -> String {
        switch value {
        case .value(let count): return "\(self.count(count)) tokens"
        case .notReported: return "未知（来源未提供）"
        case .invalid: return "未知（来源值无效）"
        }
    }
    private func localDuration(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "未知（来源未提供）" }
        return String(format: "%.2f 秒", value)
    }
    private func localRate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "未知（来源未提供）" }
        return String(format: "%.1f tok/s", value)
    }
    private func lineageName(_ kind: LocalThreadLineage) -> String {
        switch kind {
        case .root: return "顶层对话"
        case .subagent: return "子代理"
        case .fork: return "分叉"
        case .unknown: return "类型未知"
        }
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

/// 明细按需展开，仅改变视图状态，不触发扫描或修改快照。
private struct LocalDetailsDisclosure<Content: View>: View {
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
            Label("缓存与线程轮次明细", systemImage: "list.bullet.rectangle")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .accessibilityHint("展开本次扫描的本地缓存与完整轮次明细")
    }
}

private struct SpeedHistorySparkline: View {
    let points: [SpeedPoint]

    var body: some View {
        GeometryReader { proxy in
            let values = points.lazy.map(\.value)
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
