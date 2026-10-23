import SwiftUI
import WidgetKit

/// 小组件视图：数据缺失时显示“未知”，不借用其他窗口的值或将过期数据当作当前值。
struct WidgetEntryView: View {
    let entry: WidgetEntry

    private var snapshot: WidgetQuotaSnapshot? { entry.snapshot }

    var body: some View {
        Group {
            if !entry.channelAvailable {
                unavailableNotice
            } else if let snapshot {
                content(snapshot)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(4)
    }

    private var unavailableNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("共享通道不可用")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("需要签名与 App Group")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("尚未获取数据")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("打开 TokenStatMenu 后自动更新")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    /// 三组额度在方形小组件内均匀分布，避免全部挤在顶部。
    private func content(_ snapshot: WidgetQuotaSnapshot) -> some View {
        // 边界时间线负责推进；渲染若延迟，仍按实际时间拒绝过期数据。
        let now = max(entry.date, Date.now)
        let five = snapshot.currentWindow(snapshot.fiveHour, at: now)
        let seven = snapshot.currentWindow(snapshot.sevenDay, at: now)
        let monthly = snapshot.currentMonthly(at: now)
        return VStack(alignment: .leading, spacing: 0) {
            quotaLine("5 小时", five)
            Spacer(minLength: 6)
            quotaLine("7 天", seven)
            Spacer(minLength: 6)
            monthlyLine(monthly)
            Spacer(minLength: 6)
            voucherLine(snapshot.currentResetVoucherCount(at: now))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 标题、剩余百分比、已用进度条；下方左侧为窗口最大额度，右侧为重置时间。
    private func quotaLine(_ label: String,
                           _ window: WidgetQuotaSnapshot.Window?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                Spacer(minLength: 2)
                if let window {
                    Text("剩余 \(percentText(window.remainingPercent))%")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                } else {
                    Text("未知")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            quotaBar(window?.usedPercent)
            HStack(spacing: 2) {
                Text(windowLimit(window))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 2)
                Text(resetText(window?.resetsAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }

    /// 月度只显示已用金额，不显示进度条。
    private func monthlyLine(_ monthly: WidgetQuotaSnapshot.Monthly?) -> some View {
        HStack(spacing: 2) {
            Text("月度用量")
                .font(.system(size: 10, weight: .medium))
            Spacer(minLength: 2)
            if let monthly {
                Text("\(monthly.sourceSymbol)\(monthlyAmountText(monthly.usedAmount))")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else {
                Text("未知")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func voucherLine(_ count: Int?) -> some View {
        HStack(spacing: 2) {
            Text("重置券")
                .font(.system(size: 10, weight: .medium))
            Spacer(minLength: 2)
            Text(count.map { "\($0) 张" } ?? "未知")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
        }
    }

    /// 进度条下方只显示窗口最大额度；已用比例已在上方文字和进度条中表达。
    private func windowLimit(_ window: WidgetQuotaSnapshot.Window?) -> String {
        guard let limit = window?.limitAmount else { return "额度未知" }
        if let symbol = window?.sourceSymbol {
            return "\(symbol)\(amountText(limit))"
        }
        return amountText(limit)
    }

    private func resetText(_ date: Date?) -> String {
        guard let date else { return "重置未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return "重置 \(formatter.string(from: date))"
    }

    private func quotaBar(_ used: Double?) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.blue.opacity(0.15))
                if let used {
                    Capsule()
                        .fill(Color.blue)
                        .frame(width: proxy.size.width * min(100, max(0, used)) / 100)
                }
            }
        }
        .frame(height: 4)
    }

    private func percentText(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    // MARK: - 格式化

    private func amountText(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// 月度金额与面板一致：千分位、两位小数。
    private func monthlyAmountText(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}
