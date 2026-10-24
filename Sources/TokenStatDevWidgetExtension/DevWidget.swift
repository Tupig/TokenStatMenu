import SwiftUI
import WidgetKit

private struct DevWidgetView: View {
    let entry: DevEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("合成检查").font(.headline)
            Text("5 小时")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let value = entry.snapshot?.remainingPercent,
               entry.snapshot?.hubVisible == true {
                Text("剩余 \(percentText(value))")
                    .font(.title3.bold())
                if let reset = entry.snapshot?.resetAtMs {
                    Text("重置：\(Date(timeIntervalSince1970: Double(reset) / 1000), format: .dateTime.month().day().hour().minute())")
                        .font(.caption2)
                }
            } else {
                Text("额度未知").font(.title3.bold())
            }
            Text(family == .systemMedium ? "7 天、月度与本机记录：未知" : "7 天：未知")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let observed = entry.snapshot?.observedAtMs {
                Text("来源：合成 · 截至 \(Date(timeIntervalSince1970: Double(observed) / 1000), format: .dateTime.hour().minute().second())")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("暂无有效快照").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .widgetURL(URL(string: DevWidgetIdentity.route))
    }

    private func percentText(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        guard let text = formatter.string(from: NSDecimalNumber(decimal: value)) else { return "未知" }
        return text + "%"
    }
}

private struct DevWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: DevWidgetIdentity.kind, provider: DevProvider()) { entry in
            DevWidgetView(entry: entry)
        }
        .configurationDisplayName("TokenStatMenu 合成自测")
        .description("验证本机小组件的合成快照读取。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct DevWidgetBundle: WidgetBundle {
    var body: some Widget { DevWidget() }
}
