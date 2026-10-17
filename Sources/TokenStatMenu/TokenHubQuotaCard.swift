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
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                Text(directSource
                    ? "只读 Token Hub 后台额度响应；不写入会话、不上传凭据。与本机 Token 统计和费用分开。"
                    : "仅读取 Token Hub 界面显示；账号与组织未核验，币种未核验。与本机 Token 统计、企业 API 配额和费用分开。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Text(directSource ? "Token Hub 后台响应时间已随本次刷新记录。" : "Token Hub 后台更新时间未提供。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                if let snapshot {
                    if let window = snapshot.fiveHour { row("5 小时", window.usedPercent, window.usedAmount, window.limitAmount, window.sourceSymbol, window.resetDisplay) }
                    if let window = snapshot.sevenDay { row("7 天", window.usedPercent, window.usedAmount, window.limitAmount, window.sourceSymbol, window.resetDisplay) }
                    if let monthly = snapshot.monthly {
                        HStack { Text("月度已用"); Spacer(); Text("\(monthly.sourceSymbol)\(amount(monthly.usedAmount))").monospacedDigit() }
                            .font(.system(size: 10))
                    }
                    Text("\(directSource ? "后台读取" : "界面读取")于 \(snapshot.observedAt.formatted(.dateTime.hour().minute()))；快照有效期 \(Int(max(120, refreshSeconds * 2))) 秒")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    Text(enabled ? status : "自动读取已关闭").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label(directSource ? "Token Hub 企业额度" : "Token Hub 界面额度快照", systemImage: "window.ceiling") }
    }
    private func row(_ title: String, _ usedPercent: Decimal, _ used: Decimal, _ limit: Decimal, _ symbol: String, _ reset: String) -> some View {
        let remainingPercent = Decimal(100) - usedPercent
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer(minLength: 0)
            Text("剩余 \(TokenHubDecimalFormatter.string(remainingPercent))%")
                .fontWeight(.semibold).monospacedDigit()
            }
            HStack {
                Text("界面已用 \(TokenHubDecimalFormatter.string(usedPercent))% · \(symbol)\(amount(used)) / \(symbol)\(amount(limit))")
                    .monospacedDigit()
                Spacer(minLength: 0)
                Text("重置 \(reset)").foregroundStyle(.secondary)
            }
        }.font(.system(size: 10))
    }
    private func amount(_ value: Decimal) -> String { TokenHubDecimalFormatter.string(value) }
}
