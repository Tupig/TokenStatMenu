import SwiftUI
import WidgetKit

/// 已解码的时间线条目。快照为 nil 表示通道或数据缺失，视图显示未知而非零。
struct WidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetQuotaSnapshot?
    let channelAvailable: Bool
}

/// 读取应用最近发布的 App Group 快照，不访问网络或偏好设置。
struct WidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(date: .now, snapshot: nil, channelAvailable: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let entry = currentEntry()
        // 到期条目只做失效投影；不把旧快照重新当成当前数据。
        let boundaries = entry.snapshot?.timelineDates(after: entry.date) ?? []
        let entries = [entry] + boundaries.map {
            WidgetEntry(date: $0, snapshot: entry.snapshot, channelAvailable: entry.channelAvailable)
        }
        completion(Timeline(entries: entries, policy: .after(entry.date.addingTimeInterval(300))))
    }

    private func currentEntry() -> WidgetEntry {
        let available = WidgetSnapshotStore.isAvailable()
        let snapshot = (try? WidgetSnapshotStore.read()) ?? nil
        return WidgetEntry(date: .now, snapshot: snapshot, channelAvailable: available)
    }
}

struct TokenStatWidget: Widget {
    let kind = "TokenStatMenuWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WidgetProvider()) { entry in
            if #available(macOS 14.0, *) {
                WidgetEntryView(entry: entry)
                    .containerBackground(.background, for: .widget)
            } else {
                WidgetEntryView(entry: entry)
                    .padding()
            }
        }
        .configurationDisplayName("Token 与额度")
        .description("显示 5 小时限额、7 天限额、月度用量与可用重置券。未获取到的值显示为未知。")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct TokenStatWidgetBundle: WidgetBundle {
    var body: some Widget {
        TokenStatWidget()
    }
}
