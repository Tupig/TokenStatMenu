import SwiftUI
#if SWIFT_PACKAGE
import TokenStatCore
#endif

enum TokenHubDecimalFormatter {
    static func string(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}

@MainActor struct TokenHubQuotaCard: View {
    let snapshot: TokenHubQuotaSnapshot?
    let status: String
    let enabled: Bool
    let refreshSeconds: Double
    let directSource: Bool
    init(snapshot: TokenHubQuotaSnapshot?, status: String, enabled: Bool, refreshSeconds: Double,
         directSource: Bool = false) {
        self.snapshot = snapshot; self.status = status; self.enabled = enabled
        self.refreshSeconds = refreshSeconds; self.directSource = directSource
    }
    var emptyStateText: String { enabled ? status : "自动读取已关闭" }
    static func resetLabel(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == "未知" ? "重置时间未知" : "重置 \(text)"
    }
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                Text(directSource
                    ? "只读后台额度；仅向 Hub 既有来源交换会话，短期令牌仅存内存。与本机 Token 统计和费用分开。"
                    : "仅读取 Token Hub 界面显示；账号与组织未核验，币种未核验。与本机 Token 统计、企业 API 配额和费用分开。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Text(directSource ? "本次后台读取时间已记录。" : "Token Hub 后台更新时间未提供。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                if let snapshot {
                    if let window = snapshot.fiveHour { row("5 小时", window.usedPercent, window.usedAmount, window.limitAmount, window.sourceSymbol, window.resetDisplay) }
                    else { unknownWindowRow("5 小时") }
                    if let window = snapshot.sevenDay { row("7 天", window.usedPercent, window.usedAmount, window.limitAmount, window.sourceSymbol, window.resetDisplay) }
                    else { unknownWindowRow("7 天") }
                    if let monthly = snapshot.monthly {
                        monthlyRow(monthly)
                    }
                    Text("\(directSource ? "后台读取" : "界面读取")于 \(snapshot.observedAt.formatted(.dateTime.hour().minute()))；快照有效期 \(Int(max(120, refreshSeconds * 2))) 秒")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    Text(emptyStateText).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label(directSource ? "Token Hub 企业额度" : "Token Hub 界面额度快照", systemImage: "window.ceiling") }
    }
    private func monthlyRow(_ monthly: TokenHubMonthlyUsage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("月度").fontWeight(.medium)
                Spacer(minLength: 0)
                if let usedPercent = monthly.usedPercent {
                    Text("已用 \(TwoDecimalPercentFormatter.string(usedPercent))")
                        .fontWeight(.semibold).monospacedDigit()
                } else {
                    Text("已用").fontWeight(.semibold)
                }
            }
            if let limit = monthly.limitAmount, let usedPercent = monthly.usedPercent {
                let usedFraction = min(1, max(0, NSDecimalNumber(decimal: usedPercent / 100).doubleValue))
                GeometryReader { geometry in
                    Capsule().fill(PanelPalette.blue.opacity(0.12))
                    Capsule().fill(PanelPalette.blue)
                        .frame(width: geometry.size.width * usedFraction)
                }
                .frame(height: 5)
                HStack {
                    Text("\(monthly.sourceSymbol)\(amount(monthly.usedAmount)) / \(monthly.sourceSymbol)\(amount(limit))")
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    if let remaining = monthly.remainingAmount {
                        Text("剩余 \(monthly.sourceSymbol)\(amount(remaining))")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            } else {
                Text("已用 \(monthly.sourceSymbol)\(amount(monthly.usedAmount)) · 后台未提供月度总额，剩余与进度未知")
                    .foregroundStyle(.secondary)
            }
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
                Capsule().fill(PanelPalette.blue)
                    .frame(width: geometry.size.width * usedFraction)
            }
            .frame(height: 5)
            HStack {
                Text("\(directSource ? "后台已用" : "界面已用") \(TwoDecimalPercentFormatter.string(usedPercent)) · \(symbol)\(amount(used)) / \(symbol)\(amount(limit))")
                    .monospacedDigit()
                Spacer(minLength: 0)
                Text(Self.resetLabel(reset)).foregroundStyle(.secondary)
            }
        }.font(.system(size: 10))
    }
    private func amount(_ value: Decimal) -> String { TokenHubDecimalFormatter.string(value) }
}
