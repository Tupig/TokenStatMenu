import Foundation
import WidgetKit
#if SWIFT_PACKAGE
import TokenStatWidgetShared
#endif

/// 将当前显示数据发布到 App Group，供内嵌小组件读取。
///
/// 通道缺失、值未变或写入失败不影响菜单栏；来源缺失时发布为未知。
@MainActor
public final class WidgetSnapshotPublisher {

    private var ownership: WidgetSnapshotStore.Ownership?
    private var lastPayload: Data?
    private var lastWriteAt: Date?
    private var lastReloadAt: Date?
    /// 写入失败后丢弃 inode 凭据，下次替换前重新接管当前文件。
    private var needsClaim = true
    private var lastWriteFailed = false
    /// 仅实际成功写入后置为 true，不把容器路径存在当作发布成功。
    public private(set) var lastPublishSucceeded = false
    /// 暂受 60 秒间隔限制的重载，后续刷新时补发，不因写入完成而丢失。
    private var pendingReload = false
    private let now: @MainActor () -> Date
    private let channelAvailable: @MainActor () -> Bool
    private let claim: @MainActor () -> WidgetSnapshotStore.Ownership?
    private let write: @MainActor (Data, WidgetSnapshotStore.Ownership?) throws -> WidgetSnapshotStore.Ownership
    private let reload: @MainActor () -> Void

    /// `reloadAllTimelines()` 的最短调用间隔，避免频繁请求耗尽 WidgetKit 重载预算。
    nonisolated static let minimumReloadInterval: TimeInterval = 60

    public init(now: @escaping @MainActor () -> Date = { Date() }) {
        self.now = now
        self.channelAvailable = { WidgetSnapshotStore.isAvailable() }
        self.claim = { WidgetSnapshotStore.claimExisting() }
        self.write = { try WidgetSnapshotStore.write($0, replacing: $1) }
        self.reload = { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// 测试注入点：替换容器、WidgetKit 和写入操作，保留相同的决策路径。
    init(now: @escaping @MainActor () -> Date,
         channelAvailable: @escaping @MainActor () -> Bool,
         claim: @escaping @MainActor () -> WidgetSnapshotStore.Ownership?,
         write: @escaping @MainActor (Data, WidgetSnapshotStore.Ownership?) throws -> WidgetSnapshotStore.Ownership,
         reload: @escaping @MainActor () -> Void) {
        self.now = now
        self.channelAvailable = channelAvailable
        self.claim = claim
        self.write = write
        self.reload = reload
    }

    /// 当前是否能解析出 App Group 通道；写入仍可能因权限失败。
    public var isChannelAvailable: Bool {
        channelAvailable()
    }

    /// 发现通道缺失后置为 true，调用方可据此提示一次，避免每次刷新都提示。
    public private(set) var channelUnavailable: Bool {
        get { channelReportedUnavailable }
        set { channelReportedUnavailable = newValue }
    }

    private var channelReportedUnavailable = false

    /// 发布快照，显示值未变且仍在刷新周期内时跳过写入。
    ///
    /// 根据显示值而非写入时间决定是否更新；`writtenAt` 每次都会变化，不能直接比较原始字节。
    /// - Returns: 数据写入容器成功时返回 true。
    @discardableResult
    public func publish(_ snapshot: WidgetQuotaSnapshot) -> Bool {
        guard channelAvailable() else {
            channelReportedUnavailable = true
            lastPublishSucceeded = false
            return false
        }
        guard let data = try? WidgetSnapshotCodec.encode(snapshot) else {
            lastPublishSucceeded = false
            return false
        }
        let identity = Self.displayIdentity(of: data)
        if ownership == nil, needsClaim {
            ownership = claim()
            needsClaim = false
        }
        let sameValues = identity == lastPayload.map(Self.displayIdentity)
        let decision = Self.decidePublish(sameValues: sameValues,
                                          lastWriteAt: lastWriteAt,
                                          lastReloadAt: lastReloadAt,
                                          now: now(),
                                          recoveringFromFailure: lastWriteFailed)
        guard decision.shouldWrite else {
            // 即使后续数值未变化，也需补发先前被限流的重载。
            if pendingReload { reloadTimelinesIfAllowed() }
            return false
        }
        do {
            ownership = try write(data, ownership)
            lastPayload = data
            lastWriteAt = now()
            let recovering = lastWriteFailed
            lastWriteFailed = false
            lastPublishSucceeded = true
            channelReportedUnavailable = false
            if !sameValues || recovering { pendingReload = true }
            if decision.shouldReload || pendingReload { reloadTimelinesIfAllowed() }
            return true
        } catch {
            // inode 凭据已失效，但保留本次数值和计时，使相同值等待重试间隔，变化时仍立即写入。
            // 下次尝试前须重新接管文件。
            ownership = nil
            needsClaim = true
            lastPayload = data
            lastWriteAt = now()
            lastWriteFailed = true
            lastPublishSucceeded = false
            return false
        }
    }

    struct PublishDecision: Equatable {
        var shouldWrite: Bool
        var shouldReload: Bool
    }

    /// 纯写入决策，不访问 WidgetKit 或 App Group。
    ///
    /// 数值未变时每分钟更新写入时间，以区分空闲与进程退出。
    /// 值变化或失败恢复后请求重载，调用间隔不小于 `minimumReloadInterval`。
    nonisolated static func decidePublish(sameValues: Bool,
                                          lastWriteAt: Date?,
                                          lastReloadAt: Date?,
                                          now: Date,
                                          recoveringFromFailure: Bool = false,
                                          minimumInterval: TimeInterval = minimumReloadInterval) -> PublishDecision {
        let writeDue = lastWriteAt.map { now.timeIntervalSince($0) >= minimumInterval } ?? true
        let reloadDue = lastReloadAt.map { now.timeIntervalSince($0) >= minimumInterval } ?? true
        let shouldWrite = !sameValues || writeDue
        let needsReload = !sameValues || recoveringFromFailure
        return PublishDecision(shouldWrite: shouldWrite,
                               shouldReload: shouldWrite && needsReload && reloadDue)
    }

    /// 移除 `writtenAtMs` 后的字节；空闲刷新时仅此字段变化。
    nonisolated static func displayIdentity(of data: Data) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }
        object.removeValue(forKey: "writtenAtMs")
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? data
    }

    /// 每个 `minimumReloadInterval` 内最多请求一次重载，扩展另有五分钟时间线刷新。
    private func reloadTimelinesIfAllowed() {
        let current = now()
        if let lastReloadAt, current.timeIntervalSince(lastReloadAt) < Self.minimumReloadInterval {
            return
        }
        lastReloadAt = current
        pendingReload = false
        reload()
    }

    /// 清除内存中的文件身份，使下次发布重新读取容器。
    public func resetOwnership() {
        ownership = nil
        lastPayload = nil
        lastWriteAt = nil
        needsClaim = true
        lastWriteFailed = false
        pendingReload = false
        lastPublishSucceeded = false
        channelReportedUnavailable = false
    }
}
