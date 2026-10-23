import Foundation
import WidgetKit
#if SWIFT_PACKAGE
import TokenStatWidgetShared
#endif

/// Publishes the current presentation values to the shared App Group container
/// so the embedded widget can render them.
///
/// Publishing is best effort and never blocks the menu bar: a missing channel,
/// unchanged values or a rejected write all leave existing app behaviour
/// untouched. It never fabricates a value: absent sources publish as unknown.
@MainActor
public final class WidgetSnapshotPublisher {

    private var ownership: WidgetSnapshotStore.Ownership?
    private var lastPayload: Data?
    private var lastWriteAt: Date?
    private var lastReloadAt: Date?
    /// A failed write drops the inode proof, so the next attempt must claim the
    /// current file again before it may replace it.
    private var needsClaim = true
    private var lastWriteFailed = false
    /// A reload that was due while the 60-second gate was still closed. It is
    /// retried on later ticks instead of being dropped after the write landed.
    private var pendingReload = false
    private let now: @MainActor () -> Date
    private let channelAvailable: @MainActor () -> Bool
    private let claim: @MainActor () -> WidgetSnapshotStore.Ownership?
    private let write: @MainActor (Data, WidgetSnapshotStore.Ownership?) throws -> WidgetSnapshotStore.Ownership
    private let reload: @MainActor () -> Void

    /// Shortest gap between `reloadAllTimelines()` calls. WidgetKit enforces a
    /// daily reload budget, so one reload per half-second tick would exhaust it
    /// within a minute and later requests would be dropped without notice.
    nonisolated static let minimumReloadInterval: TimeInterval = 60

    public init(now: @escaping @MainActor () -> Date = { Date() }) {
        self.now = now
        self.channelAvailable = { WidgetSnapshotStore.isAvailable() }
        self.claim = { WidgetSnapshotStore.claimExisting() }
        self.write = { try WidgetSnapshotStore.write($0, replacing: $1) }
        self.reload = { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// Test seam: replaces the container, WidgetKit and write side effects
    /// while keeping the production decision path identical.
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

    /// True when a real App Group channel exists. Under an ad-hoc signature this
    /// is false and the publisher becomes a no-op.
    public var isChannelAvailable: Bool {
        channelAvailable()
    }

    /// True once the channel was found missing, so callers can surface a single
    /// honest notice instead of retrying silently on every tick.
    public private(set) var channelUnavailable: Bool {
        get { channelReportedUnavailable }
        set { channelReportedUnavailable = newValue }
    }

    private var channelReportedUnavailable = false

    /// Publishes the snapshot, skipping the write while the displayed values are
    /// unchanged and inside the current refresh horizon.
    ///
    /// Displayed values, not the write clock, decide whether a write is needed.
    /// `writtenAt` advances on every tick, so comparing the raw bytes would
    /// never skip and would exhaust WidgetKit's reload budget.
    /// - Returns: true when new bytes reached the container.
    @discardableResult
    public func publish(_ snapshot: WidgetQuotaSnapshot) -> Bool {
        guard channelAvailable() else {
            channelReportedUnavailable = true
            return false
        }
        guard let data = try? WidgetSnapshotCodec.encode(snapshot) else { return false }
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
            // A reload that was throttled earlier must not be lost just
            // because no further value change arrives.
            if pendingReload { reloadTimelinesIfAllowed() }
            return false
        }
        do {
            ownership = try write(data, ownership)
            lastPayload = data
            lastWriteAt = now()
            let recovering = lastWriteFailed
            lastWriteFailed = false
            if !sameValues || recovering { pendingReload = true }
            if decision.shouldReload || pendingReload { reloadTimelinesIfAllowed() }
            return true
        } catch {
            // The inode proof is stale, but the attempted values and the retry
            // clock are not. Keeping the attempted payload lets the next
            // identical tick wait for the interval instead of retrying on every
            // half-second tick; a real value change still writes immediately.
            // The next attempt must claim the current file before replacing it.
            ownership = nil
            needsClaim = true
            lastPayload = data
            lastWriteAt = now()
            lastWriteFailed = true
            return false
        }
    }

    struct PublishDecision: Equatable {
        var shouldWrite: Bool
        var shouldReload: Bool
    }

    /// Decides a write without touching WidgetKit or the App Group.
    ///
    /// Unchanged values still refresh the written-at clock once a minute so the
    /// widget can tell a live idle snapshot from a process that exited. A reload
    /// is requested when the displayed values changed, or when a retry finally
    /// succeeds after a failure, and at most once per `minimumReloadInterval`.
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

    /// Bytes with `writtenAtMs` removed. That field is the only one that moves
    /// on an idle tick.
    nonisolated static func displayIdentity(of data: Data) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }
        object.removeValue(forKey: "writtenAtMs")
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? data
    }

    /// Asks WidgetKit for a reload at most once per `minimumReloadInterval`.
    /// The extension keeps its own five-minute timeline, so a dropped request
    /// never leaves the widget stale for long.
    private func reloadTimelinesIfAllowed() {
        let current = now()
        if let lastReloadAt, current.timeIntervalSince(lastReloadAt) < Self.minimumReloadInterval {
            return
        }
        lastReloadAt = current
        pendingReload = false
        reload()
    }

    /// Drops the in-memory identity so the next publish re-reads the container.
    public func resetOwnership() {
        ownership = nil
        lastPayload = nil
        lastWriteAt = nil
        needsClaim = true
        lastWriteFailed = false
        pendingReload = false
    }
}
