import SwiftUI
import WidgetKit
#if SWIFT_PACKAGE
import TokenStatWidgetShared
#endif

/// 系统扩展与离线渲染测试使用同一个条目，不复制视图实现。
struct WidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetQuotaSnapshot?
    let channelAvailable: Bool
}

/// 小组件视图：数据缺失时显示“未知”，不借用其他窗口的值或将过期数据当作当前值。
struct WidgetEntryView: View {
    let entry: WidgetEntry
    @Environment(\.displayScale) private var displayScale

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
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("尚未获取数据")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("打开 TokenStatMenu 后自动更新")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    /// 三组额度在方形小组件内均匀分布，避免全部挤在顶部。
    private func content(_ snapshot: WidgetQuotaSnapshot) -> some View {
        // 边界时间线负责推进；渲染若延迟，仍按实际时间拒绝过期数据。
        let now = max(entry.date, Date.now)
        let fiveState = snapshot.currentState(.fiveHour, at: now)
        let sevenState = snapshot.currentState(.sevenDay, at: now)
        let monthlyState = snapshot.currentState(.monthly, at: now)
        let five = snapshot.currentWindow(snapshot.fiveHour, field: .fiveHour, at: now)
        let seven = snapshot.currentWindow(snapshot.sevenDay, field: .sevenDay, at: now)
        let monthly = snapshot.currentMonthly(at: now, field: .monthly)
        return VStack(alignment: .leading, spacing: 0) {
            if five != nil || fiveState != nil {
                quotaLine("5 小时", five, state: fiveState)
                Spacer(minLength: 6)
            }
            quotaLine("7 天", seven, state: sevenState)
            Spacer(minLength: 6)
            monthlyLine(monthly, state: monthlyState)
            Spacer(minLength: 6)
            voucherLine(snapshot.currentResetVoucherCount(at: now))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 标题、剩余百分比、已用进度条；下方左侧为窗口最大额度，右侧为重置时间。
    private func quotaLine(_ label: String,
                           _ window: WidgetQuotaSnapshot.Window?,
                           state: WidgetQuotaValueState?) -> some View {
        let barValue: Double?
        if case .unlimited? = state {
            barValue = nil
        } else {
            barValue = window?.usedPercent
        }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                Spacer(minLength: 2)
                if case .unlimited? = state {
                    Text("不限额")
                        .font(.system(size: 10, weight: .semibold))
                } else if case .exceeded? = state {
                    let actualPercent = window?.displayedUsedPercent
                    Text(actualPercent.map { "已超限 \(percentText($0))%" } ?? "已超限")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                } else if let window {
                    Text("剩余 \(percentText(window.remainingPercent))%")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                } else {
                    Text("未知")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            quotaBar(barValue)
            HStack(spacing: 2) {
            Text(windowLimit(window, state: state))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 2)
                Text(resetText(state?.resetAt ?? window?.resetsAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.top, 2 / displayScale)
        }
    }

    /// 月度只显示已用金额，不显示进度条。
    private func monthlyLine(_ monthly: WidgetQuotaSnapshot.Monthly?,
                             state: WidgetQuotaValueState?) -> some View {
        HStack(spacing: 2) {
            Text("月度用量")
                .font(.system(size: 10, weight: .medium))
            Spacer(minLength: 2)
            if let monthly {
                let amount = formattedAmount(monthly.sourceSymbol, monthly.usedAmount, fixed: true)
                if case .exceeded? = state {
                    Text("已超限 \(amount)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else if case .unlimited? = state {
                    Text("不限额")
                        .font(.system(size: 10, weight: .semibold))
                } else {
                    Text(amount)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            } else if case .unlimited? = state {
                Text("不限额")
                    .font(.system(size: 10, weight: .semibold))
            } else if case .exceeded? = state {
                Text("已超限")
                    .font(.system(size: 10, weight: .semibold))
            } else {
                Text("未知")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // 同一个 Text 同时供实际视图和精确文案契约使用，不提供独立测试文案。
    var voucherTitle: Text { Text("重置券") }

    private func voucherLine(_ count: Int?) -> some View {
        HStack(spacing: 2) {
            voucherTitle
                .font(.system(size: 10, weight: .medium))
            Spacer(minLength: 2)
            Text(count.map { "\($0) 张" } ?? "未知")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
        }
    }

    /// 进度条下方只显示窗口最大额度；已用比例已在上方文字和进度条中表达。
    private func windowLimit(_ window: WidgetQuotaSnapshot.Window?,
                             state: WidgetQuotaValueState?) -> String {
        if case .unlimited? = state { return "不设上限" }
        guard let limit = window?.limitAmount else { return "额度未知" }
        if let symbol = window?.sourceSymbol {
            return formattedAmount(symbol, limit, fixed: symbol == "🪙")
        }
        return amountText(limit)
    }

    /// 新版积分使用固定符号、空格和两位小数；旧 AX 美元格式保持原样。
    private func formattedAmount(_ symbol: String, _ value: Double, fixed: Bool) -> String {
        if symbol == "🪙" { return "🪙 \(coinAmountText(value))" }
        let amount = fixed ? monthlyAmountText(value) : amountText(value)
        return "\(symbol)\(amount)"
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
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// 月度金额与面板一致：千分位、两位小数。
    private func monthlyAmountText(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// 与 Token Hub `Intl.NumberFormat(en-US, {min/maxFractionDigits: 2})` 对齐，正数 halfExpand。
    private func coinAmountText(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}
