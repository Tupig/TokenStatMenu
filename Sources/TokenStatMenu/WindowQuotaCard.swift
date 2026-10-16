import SwiftUI
#if SWIFT_PACKAGE
import TokenStatCore
#endif

struct WindowQuotaCard: View {
    let title: String
    let quota: WindowQuota?
    let color: Color
    let refreshSeconds: Double
    var body: some View {
        let fresh = quota?.isFresh(refreshSeconds: refreshSeconds) == true
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
                if let quota {
                    Text(String(format: "上游已用 %.1f%%", quota.usedPercent))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if !fresh {
                        Text("已过期 · 等待刷新").foregroundStyle(.orange)
                    } else if let reset = quota.resetsAt {
                        Text(reset.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()) + " 重置")
                            .foregroundStyle(.secondary)
                    } else { Text("重置时间未提供").foregroundStyle(.secondary) }
                } else {
                    Text("接口未提供 / 字段未匹配").foregroundStyle(.secondary)
                    Text("重置时间未知").foregroundStyle(.secondary)
                }
            }.font(.system(size: 9)).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label(title, systemImage: "clock") }
    }
}
