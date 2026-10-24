import SwiftUI
#if SWIFT_PACKAGE
import TokenStatCore
#endif

enum TokenHubDecimalFormatter {
    /// 金额统一保留最多两位小数，整数不补零；千分位便于阅读。
    static func string(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value))
            ?? NSDecimalNumber(decimal: value).stringValue
    }
}

@MainActor struct TokenHubQuotaCard: View {
    let snapshot: TokenHubQuotaSnapshot?
    let presentation: TokenHubQuotaPresentation
    let status: String
    let enabled: Bool
    let refreshSeconds: Double
    let directSource: Bool
    init(snapshot: TokenHubQuotaSnapshot?, status: String, enabled: Bool, refreshSeconds: Double,
         directSource: Bool = false) {
        let projection = TokenHubQuotaPresentation.project(snapshot: snapshot,
            now: snapshot?.observedAt ?? .distantPast, refreshSeconds: refreshSeconds)
        self.snapshot = Self.currentSnapshot(projection)
        self.presentation = projection
        self.status = status; self.enabled = enabled
        self.refreshSeconds = refreshSeconds; self.directSource = directSource
    }
    init(presentation: TokenHubQuotaPresentation, status: String, enabled: Bool, refreshSeconds: Double,
         directSource: Bool = false) {
        self.snapshot = Self.currentSnapshot(presentation); self.presentation = presentation
        self.status = status; self.enabled = enabled; self.refreshSeconds = refreshSeconds
        self.directSource = directSource
    }
    private static func currentSnapshot(_ presentation: TokenHubQuotaPresentation) -> TokenHubQuotaSnapshot? {
        guard presentation.snapshotFresh, let raw = presentation.snapshot,
              presentation.fiveHourCurrent != nil || presentation.sevenDayCurrent != nil
                || presentation.monthlyCurrent != nil else { return nil }
        return TokenHubQuotaSnapshot(identity: raw.identity, fiveHour: presentation.fiveHourCurrent,
            sevenDay: presentation.sevenDayCurrent, monthly: presentation.monthlyCurrent,
            resetVoucherCount: raw.resetVoucherCount, observedAt: raw.observedAt)
    }
    var emptyStateText: String { enabled ? status : "自动读取已关闭" }
    static func resetLabel(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == "未知" ? "重置时间未知" : "重置 \(text)"
    }
    var body: some View {
        let rawSnapshot = presentation.snapshot
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                Text(directSource
                    ? "只读后台额度；仅向 Hub 既有来源交换会话，短期令牌仅存内存。与本机 Token 统计和费用分开。"
                    : "仅读取 Token Hub 界面显示；账号、组织与币种来源待确认。与本机 Token 统计、企业 API 配额和费用分开。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Text(directSource ? "本次后台读取时间已记录。" : "Token Hub 后台更新时间未提供。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                if let snapshot = rawSnapshot {
                    if let window = snapshot.fiveHour { projectedRow("5 小时", window, state: presentation.fiveHour) }
                    else { unknownWindowRow("5 小时") }
                    if let window = snapshot.sevenDay { projectedRow("7 天", window, state: presentation.sevenDay) }
                    else { unknownWindowRow("7 天") }
                    if let monthly = snapshot.monthly { monthlyRow(monthly, isCurrent: presentation.monthlyCurrent != nil) }
                    else { unknownWindowRow("月度用量") }
                    voucherRow(presentation.snapshotFresh ? snapshot.resetVoucherCount : nil)
                    Text("\(directSource ? "后台读取" : "界面读取")于 \(snapshot.observedAt.formatted(.dateTime.hour().minute()))；快照有效期 \(Int(max(120, refreshSeconds * 2))) 秒")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    Text(emptyStateText).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label(directSource ? "Token Hub 企业额度" : "Token Hub 界面额度快照", systemImage: "window.ceiling") }
    }
    private func monthlyRow(_ monthly: TokenHubMonthlyUsage, isCurrent: Bool) -> some View {
        HStack(spacing: 6) {
            Text("月度用量").fontWeight(.medium)
            Spacer(minLength: 0)
            if presentation.futureObservation {
                Text("时间异常 · 当前用量未知")
                    .fontWeight(.semibold).foregroundStyle(.secondary)
            } else if isCurrent {
                Text("\(monthly.sourceSymbol)\(monthlyAmount(monthly.usedAmount))")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
            } else {
                Text("历史已用 \(monthly.sourceSymbol)\(monthlyAmount(monthly.usedAmount))")
                    .fontWeight(.semibold).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10))
    }
    private func voucherRow(_ count: Int?) -> some View {
        HStack(spacing: 6) {
            Text("重置券").fontWeight(.medium)
            Spacer(minLength: 0)
            Text(count.map { "\($0) 张" } ?? "未知")
                .fontWeight(.semibold).monospacedDigit()
                .foregroundStyle(count == nil ? Color.secondary : Color.primary)
        }
        .font(.system(size: 10))
    }
    private func unknownWindowRow(_ title: String) -> some View {
        HStack {
            Text(title).fontWeight(.medium)
            Spacer(minLength: 0)
            Text("未知").foregroundStyle(.secondary)
        }
        .font(.system(size: 10))
    }
    private func row(_ title: String, _ usedPercent: Decimal, _ used: Decimal, _ limit: Decimal, _ symbol: String, _ reset: String) -> some View {
        let remainingPercent = Decimal(100) - usedPercent
        let usedFraction = min(1, max(0, NSDecimalNumber(decimal: usedPercent / 100).doubleValue))
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer(minLength: 0)
            Text("剩余 \(TwoDecimalPercentFormatter.string(remainingPercent))")
                .fontWeight(.semibold).monospacedDigit()
            }
            GeometryReader { geometry in
                Capsule().fill(PanelPalette.blue.opacity(0.12))
                Capsule().fill(barColor(for: usedPercent))
                    .frame(width: geometry.size.width * usedFraction)
            }
            .frame(height: 5)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(directSource ? "后台已用" : "界面已用") \(TwoDecimalPercentFormatter.string(usedPercent))")
                        .monospacedDigit()
                    Text("\(symbol)\(amount(used)) / \(symbol)\(amount(limit))")
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                Text(Self.resetLabel(reset)).foregroundStyle(.secondary)
            }
        }.font(.system(size: 10))
    }
    private func projectedRow(_ title: String, _ window: TokenHubWindowQuota,
                              state: TokenHubQuotaPresentation.WindowProjection?) -> some View {
        if presentation.futureObservation {
            return AnyView(unknownWindowRow("\(title) · 时间异常，当前数据未知"))
        }
        guard presentation.snapshotFresh, let state, !state.resetPassed else {
            return AnyView(historyRow(title, window, stale: !presentation.snapshotFresh))
        }
        return AnyView(row(title, window.usedPercent, window.usedAmount, window.limitAmount,
            window.sourceSymbol, window.resetDisplay))
    }
    private func historyRow(_ title: String, _ window: TokenHubWindowQuota, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer(minLength: 0)
                Text(stale ? "历史已用 \(TwoDecimalPercentFormatter.string(window.usedPercent)) · 快照过期"
                           : "周期已重置 · 历史已用 \(TwoDecimalPercentFormatter.string(window.usedPercent))")
                    .fontWeight(.semibold).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(directSource ? "后台已用" : "界面已用") \(TwoDecimalPercentFormatter.string(window.usedPercent))")
                        .monospacedDigit()
                    Text("\(window.sourceSymbol)\(amount(window.usedAmount)) / \(window.sourceSymbol)\(amount(window.limitAmount))")
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                Text(Self.resetLabel(window.resetDisplay)).foregroundStyle(.secondary)
            }
        }.font(.system(size: 10))
    }
    private func barColor(for usedPercent: Decimal) -> Color {
        guard directSource else { return PanelPalette.blue }
        if usedPercent >= Decimal(95) { return Color(nsColor: .systemRed) }
        if usedPercent >= Decimal(80) { return Color(nsColor: .systemYellow) }
        return PanelPalette.blue
    }
    private func amount(_ value: Decimal) -> String { TokenHubDecimalFormatter.string(value) }

    /// 月度用量只展示已花金额：千分位、两位小数，不显示进度或上限。
    private func monthlyAmount(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value))
            ?? NSDecimalNumber(decimal: value).stringValue
    }
}
