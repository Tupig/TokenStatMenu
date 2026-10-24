import WidgetKit

struct DevEntry: TimelineEntry {
    let date: Date
    let snapshot: DevWidgetSnapshot?
}

struct DevProvider: TimelineProvider {
    var now: () -> Date = { Date() }
    var load: (Int64) -> (snapshot: DevWidgetSnapshot?, event: Data?) = {
        DevProbeSnapshotReader.read(nowMs: $0)
    }
    var record: (Data) -> Void = { DevProbeTelemetry.writeTerminalToOSLog($0) }

    func placeholder(in context: Context) -> DevEntry {
        DevEntry(date: now(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (DevEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DevEntry>) -> Void) {
        completion(timeline())
    }

    func timeline() -> Timeline<DevEntry> {
        let current = entry()
        let expired = DevWidgetRefreshPolicy.expiryDates(snapshot: current.snapshot, after: current.date)
            .map { DevEntry(date: $0, snapshot: nil) }
        return Timeline(entries: [current] + expired,
                        policy: .after(DevWidgetRefreshPolicy.nextRefresh(after: current.date)))
    }

    func entry() -> DevEntry {
        let date = now()
        let result = load(Int64(floor(date.timeIntervalSince1970 * 1000)))
        if let event = result.event { record(event) }
        return DevEntry(date: date, snapshot: result.snapshot)
    }
}
