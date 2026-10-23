import SwiftUI
import WidgetKit

/// Widget presentation. Every value falls back to an explicit "未知" state:
/// the widget never shows 0%, never borrows another window's number and never
/// presents stale hub data as current.
struct WidgetEntryView: View {
    let entry: WidgetEntry
    @Environment(\.widgetFamily) private var family

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
        // Evaluate freshness at render time. `entry.date` is frozen when the
        // timeline is built and can stay "current" long after the window reset.
        let five = snapshot.currentWindow(snapshot.fiveHour, at: .now)
        let seven = snapshot.currentWindow(snapshot.sevenDay, at: .now)
        if family == .systemSmall {
            smallBody(snapshot, five: five, seven: seven)
        } else {
            mediumBody(snapshot, five: five, seven: seven)
        }
    }

    private func smallBody(_ snapshot: WidgetQuotaSnapshot,
                           five: WidgetQuotaSnapshot.Window?,
                           seven: WidgetQuotaSnapshot.Window?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            quotaRow("5h", five)
            quotaRow("7d", seven)
            monthlySummary(snapshot.currentMonthly(at: .now))
            Spacer(minLength: 0)
            localSummary(snapshot.local)
        }
    }

    private func mediumBody(_ snapshot: WidgetQuotaSnapshot,
                            five: WidgetQuotaSnapshot.Window?,
                            seven: WidgetQuotaSnapshot.Window?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                quotaRow("5 小时", five)
                quotaRow("7 天", seven)
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                localSummary(snapshot.local)
                monthlySummary(snapshot.currentMonthly(at: .now))
            }
        }
    }

    @ViewBuilder
    private func quotaRow(_ label: String, _ window: WidgetQuotaSnapshot.Window?) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            if let window {
                Text(percentText(window.remainingPercent))
                    .font(.caption.bold())
                    .monospacedDigit()
                Text("剩")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("未知")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func localSummary(_ local: WidgetQuotaSnapshot.Local?) -> some View {
        if let local {
            VStack(alignment: .leading, spacing: 1) {
                Text("本机合计")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(tokenText(local.totalTokens))
                    .font(.caption.bold())
                    .monospacedDigit()
                if local.unknownThreads > 0 || local.isLimited {
                    Text(local.isLimited ? "已到扫描上限" : "部分线程未核算")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            Text("本机合计未知")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func monthlySummary(_ monthly: WidgetQuotaSnapshot.Monthly?) -> some View {
        if let monthly, let percent = monthly.usedPercent {
            VStack(alignment: .leading, spacing: 1) {
                Text("本月已用")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(percentText(percent))%")
                    .font(.caption.bold())
                    .monospacedDigit()
            }
        } else if let monthly {
            VStack(alignment: .leading, spacing: 1) {
                Text("本月已用")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(monthly.sourceSymbol)\(amountText(monthly.usedAmount))")
                    .font(.caption.bold())
                    .monospacedDigit()
            }
        } else {
            Text("本月未知")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Formatting

    private func percentText(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func amountText(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    private func tokenText(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
