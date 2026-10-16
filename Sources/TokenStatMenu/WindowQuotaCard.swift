import SwiftUI
#if SWIFT_PACKAGE
import TokenStatCore
#endif

enum QuotaSource: Equatable {
    case localCodex
    case enterprise
}

struct WindowQuotaPresentation: Equatable {
    let sourceLabel: String
    let isFresh: Bool
    let usedPercent: Double?
    let resetsAt: Date?
    let recordedAt: Date?
    let statusLabel: String
}

struct WindowQuotaCard: View {
    let title: String
    let quota: WindowQuota?
    let color: Color
    let refreshSeconds: Double
    let source: QuotaSource
    static func presentation(for quota: WindowQuota?, at now: Date = Date(), refreshSeconds: Double,
                             source: QuotaSource = .enterprise) -> WindowQuotaPresentation {
        let sourceLabel = source == .localCodex ? "本地 Codex 历史快照 · 账号/组织未核验" : "已配置企业用量接口数据"
        guard let quota else {
            return WindowQuotaPresentation(sourceLabel: sourceLabel, isFresh: false, usedPercent: nil,
                resetsAt: nil, recordedAt: nil, statusLabel: source == .localCodex ? "本地历史额度未提供" : "企业额度未提供")
        }
        if source == .localCodex {
            let resetStatus: String
            if let reset = quota.resetsAt { resetStatus = reset <= now ? " · 重置已过期" : "" }
            else { resetStatus = " · 重置时间未知" }
            return WindowQuotaPresentation(sourceLabel: sourceLabel, isFresh: false, usedPercent: quota.usedPercent,
                resetsAt: quota.resetsAt, recordedAt: quota.fetchedAt,
                statusLabel: quota.fetchedAt > now ? "本地历史参考 · 异常时间戳" : "本地历史参考\(resetStatus)")
        }
        if quota.fetchedAt > now {
            return WindowQuotaPresentation(sourceLabel: sourceLabel, isFresh: false, usedPercent: quota.usedPercent,
                resetsAt: quota.resetsAt, recordedAt: quota.fetchedAt, statusLabel: "企业额度异常时间戳")
        }
        let fresh = quota.isFresh(at: now, refreshSeconds: refreshSeconds)
        let staleLabel: String
        if quota.resetsAt.map({ $0 <= now }) == true { staleLabel = "企业历史额度 · 已过期" }
        else { staleLabel = "企业历史额度" }
        return WindowQuotaPresentation(sourceLabel: sourceLabel, isFresh: fresh, usedPercent: quota.usedPercent,
            resetsAt: quota.resetsAt, recordedAt: quota.fetchedAt, statusLabel: fresh ? "企业当前额度" : staleLabel)
    }
    var body: some View {
        let presentation = Self.presentation(for: quota, refreshSeconds: refreshSeconds, source: source)
        let fresh = presentation.isFresh
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(source == .localCodex ? presentation.usedPercent.map { String(format: "%.1f%%", $0) } ?? "—"
                        : fresh ? String(format: "%.1f%%", quota!.remainingPercent) : "—")
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(fresh ? color : .secondary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    if source == .localCodex, presentation.usedPercent != nil {
                        Text("历史已用").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else if fresh { Text("剩余").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                Text(presentation.sourceLabel)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                if source == .enterprise {
                    GeometryReader { geometry in
                        Capsule().fill(color.opacity(0.12))
                        if fresh, let quota {
                            Capsule().fill(color).frame(width: geometry.size.width * quota.remainingPercent / 100)
                        }
                    }.frame(height: 5)
                }
                if let used = presentation.usedPercent {
                    Text(String(format: "上游已用 %.1f%%", used))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if !fresh {
                        Text(presentation.statusLabel + (source == .enterprise ? " · 等待刷新" : ""))
                            .foregroundStyle(source == .enterprise ? .orange : .secondary)
                    }
                    if let recordedAt = presentation.recordedAt {
                        Text("记录于 " + recordedAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                            .foregroundStyle(.secondary)
                    }
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
