import SwiftUI
import WidgetKit

/// One decoded timeline entry. A nil snapshot means "no shared channel or no
/// data", which the views must render as unknown rather than as zero.
struct WidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetQuotaSnapshot?
    let channelAvailable: Bool
}

/// Reads the App Group snapshot. The read performs no network access and no
/// preference lookup; it only decodes the last payload the app published.
struct WidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(date: .now, snapshot: nil, channelAvailable: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let entry = currentEntry()
        // Refresh in five minutes; the app also asks WidgetKit to reload right
        // after it publishes a new snapshot.
        let next = Date().addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(next)))
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
        .description("显示 Token 用量、5 小时与 7 天额度剩余。未获取到的值显示为未知。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct TokenStatWidgetBundle: WidgetBundle {
    var body: some Widget {
        TokenStatWidget()
    }
}
