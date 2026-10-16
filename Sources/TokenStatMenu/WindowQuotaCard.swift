import SwiftUI
#if SWIFT_PACKAGE
import TokenStatCore
#endif

struct WindowQuotaPresentation: Equatable {
    let isFresh: Bool
    let usedPercent: Double?
    let resetsAt: Date?
    let statusLabel: String
}

struct WindowQuotaCard: View {
    let title: String
    let quota: WindowQuota?
    let color: Color
    let refreshSeconds: Double
    static func presentation(for quota: WindowQuota?, at now: Date = Date(), refreshSeconds: Double) -> WindowQuotaPresentation {
        guard let quota else { return WindowQuotaPresentation(isFresh: false, usedPercent: nil, resetsAt: nil, statusLabel: "未提供") }
        if quota.fetchedAt > now { return WindowQuotaPresentation(isFresh: false, usedPercent: quota.usedPercent, resetsAt: quota.resetsAt, statusLabel: "异常时间戳") }
        let fresh = quota.isFresh(at: now, refreshSeconds: refreshSeconds)
        let staleLabel = quota.resetsAt.map { $0 <= now } == true ? "历史额度 · 已过期" : "历史额度"
        return WindowQuotaPresentation(isFresh: fresh, usedPercent: quota.usedPercent, resetsAt: quota.resetsAt,
            statusLabel: fresh ? "当前额度" : staleLabel)
    }
    var body: some View {
        let presentation = Self.presentation(for: quota, refreshSeconds: refreshSeconds)
        let fresh = presentation.isFresh
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(fresh ? String(format: "%.1f%%", quota!.remainingPercent) : "—")
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(fresh ? color : .secondary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    if fresh { Text("剩余").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                GeometryReader { geometry in
                    Capsule().fill(color.opacity(0.12))
                    if fresh, let quota {
                        Capsule().fill(color).frame(width: geometry.size.width * quota.remainingPercent / 100)
                    }
                }.frame(height: 5)
                if let used = presentation.usedPercent {
                    Text(String(format: "上游已用 %.1f%%", used))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if !fresh { Text(presentation.statusLabel + " · 等待刷新").foregroundStyle(.orange) }
                    if let reset = presentation.resetsAt {
                        Text((fresh ? "重置于 " : "原重置时间 ") + reset.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                            .foregroundStyle(.secondary)
                    } else if fresh { Text("重置时间未提供").foregroundStyle(.secondary) }
                } else {
                    Text(presentation.statusLabel).foregroundStyle(.secondary)
                    Text("重置时间未知").foregroundStyle(.secondary)
                }
            }.font(.system(size: 9)).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label(title, systemImage: "clock") }
    }
}
