import SwiftUI
import WidgetKit

private struct DevEntry: TimelineEntry {
    let date: Date
    let snapshot: DevWidgetSnapshot?
}

private struct DevProvider: TimelineProvider {
    func placeholder(in context: Context) -> DevEntry {
        DevEntry(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (DevEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DevEntry>) -> Void) {
        let current = entry()
        completion(Timeline(entries: [current], policy: .after(current.date.addingTimeInterval(300))))
    }

    private func entry() -> DevEntry {
        let now = Date()
        let milliseconds = Int64(floor(now.timeIntervalSince1970 * 1000))
        let audit = DevProbeAudit()
        let ioAudit = DevProbeIOAudit()
        func record(_ code: Int32, reason: String,
                    sample: Int? = nil, payloadMatched: Bool = false) {
            if let event = DevProbeController.terminalEvent(actor: "appex", sample: sample,
                                                            exitCode: code, reason: reason,
                                                            counts: audit.snapshot(), io: ioAudit.snapshot(),
                                                            nowMs: milliseconds, pid: getpid(),
                                                            payloadMatched: payloadMatched) {
                DevProbeTelemetry.writeTerminalToOSLog(event)
            }
        }
        // 查找容器前，扩展先检查自身的组授权是否完全匹配。
        if let reason = DevGroupGuard.currentReason() {
            record(77, reason: reason)
            return DevEntry(date: now, snapshot: nil)
        }
        do {
            let bytes = try DevWidgetSnapshotStore.read(io: ioAudit)
            guard let snapshot = DevWidgetSnapshot.decode(bytes, nowMs: milliseconds) else {
                record(78, reason: "invalidSchema")
                return DevEntry(date: now, snapshot: nil)
            }
            let identifiedSample: Int?
            switch snapshot.remainingPercent {
            case Decimal(string: "87.66"): identifiedSample = 1
            case Decimal(string: "43.22"): identifiedSample = 2
            default: identifiedSample = nil
            }
            record(0, reason: "none", sample: identifiedSample,
                   payloadMatched: identifiedSample != nil)
            return DevEntry(date: now, snapshot: snapshot)
        } catch DevWidgetSnapshotStore.StoreError.unavailable {
            record(74, reason: "containerUnavailable")
        } catch DevWidgetSnapshotStore.StoreError.unsafeObject {
            record(74, reason: "unsafeExistingObject")
        } catch {
            record(74, reason: "ioFailure")
        }
        return DevEntry(date: now, snapshot: nil)
    }
}

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
