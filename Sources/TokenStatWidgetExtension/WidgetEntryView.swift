import SwiftUI
import WidgetKit

/// 小组件视图：数据缺失时显示“未知”，不借用其他窗口的值或将过期数据当作当前值。
struct WidgetEntryView: View {
    let entry: WidgetEntry

    private var snapshot: WidgetQuotaSnapshot? { entry.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !entry.channelAvailable {
                unavailableNotice
            } else if let snapshot {
                content(snapshot)
            } else {
                Text("尚未获取数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("打开 TokenStatMenu 后自动更新")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(2)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Token")
                .font(.caption.bold())
            Spacer(minLength: 0)
            if let snapshot {
                Text(snapshot.hubIsCurrent(at: .now) ? "实时" : "已过期")
                    .font(.caption2)
                    .foregroundStyle(snapshot.hubIsCurrent(at: .now) ? .secondary : .tertiary)
            }
        }
    }

    private var unavailableNotice: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("共享通道不可用")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("需要签名与 App Group")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func content(_ snapshot: WidgetQuotaSnapshot) -> some View {
        // 渲染时判断有效期；`entry.date` 在时间线创建时固定，不能反映后续重置。
        let five = snapshot.currentWindow(snapshot.fiveHour, at: .now)
        let seven = snapshot.currentWindow(snapshot.sevenDay, at: .now)
        let monthly = snapshot.currentMonthly(at: .now)
        smallBody(five: five, seven: seven, monthly: monthly,
                  vouchers: snapshot.resetVoucherCount)
    }

    private func smallBody(five: WidgetQuotaSnapshot.Window?,
                           seven: WidgetQuotaSnapshot.Window?,
                           monthly: WidgetQuotaSnapshot.Monthly?,
                           vouchers: Int?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            compactQuotaRow("5h", five)
            compactQuotaRow("7d", seven)
            HStack(spacing: 6) {
                Text("月度")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                if let monthly {
                    Text("\(monthly.sourceSymbol)\(amountText(monthly.usedAmount))")
                        .font(.caption.bold())
                        .monospacedDigit()
                } else {
                    Text("未知")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 6) {
                Text("重置券")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                if let vouchers {
                    Text("\(vouchers) 张")
                        .font(.caption.bold())
                        .monospacedDigit()
                } else {
                    Text("未知")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func compactQuotaRow(_ label: String,
                                 _ window: WidgetQuotaSnapshot.Window?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            if let window {
                quotaBar(usedPercent(window))
                    .frame(width: 58)
                Spacer(minLength: 2)
                Text(usedText(window))
                    .font(.caption.bold())
                    .monospacedDigit()
            } else {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 58, height: 6)
                Spacer(minLength: 2)
                Text("未知")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func quotaBar(_ used: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(quotaTint(used))
                    .frame(width: proxy.size.width * min(100, max(0, used)) / 100)
            }
        }
        .frame(height: 6)
    }

    private func quotaTint(_ used: Double) -> Color {
        if used >= 90 { return .red }
        if used >= 70 { return .orange }
        return .green
    }

    private func usedPercent(_ window: WidgetQuotaSnapshot.Window) -> Double {
        min(100, max(0, 100 - window.remainingPercent))
    }

    private func usedText(_ window: WidgetQuotaSnapshot.Window) -> String {
        String(format: "%.1f%%", usedPercent(window))
    }

    // MARK: - 格式化

    private func amountText(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}
