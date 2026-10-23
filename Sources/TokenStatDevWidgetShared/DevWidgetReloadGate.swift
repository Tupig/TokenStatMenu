import Foundation

// Pure scheduling decision for the later host integration. The caller must
// supply a digest of the DTO projection excluding writtenAtMs and use a
// monotonic millisecond clock. This class performs no timer or WidgetCenter I/O.
final class DevWidgetReloadGate {
    private struct Pending {
        let firstAtMs: UInt64
        let deadlineMs: UInt64
        var digest: Data
        var generation: UInt64
    }

    private var pending: Pending?
    private var lastRequestAtMs: UInt64?
    private var lastRequestedDigest: Data?
    private var acceptedGeneration: UInt64 = 0
    private var cancelled = false

    var pendingCount: Int { pending == nil ? 0 : 1 }
    var nextDeadlineMs: UInt64? { pending?.deadlineMs }

    func offer(projectionDigest: Data, atMs now: UInt64,
               generation: UInt64) -> UInt64? {
        guard !cancelled, projectionDigest.count == 32,
              generation >= acceptedGeneration else { return nil }
        acceptedGeneration = generation
        if let pending {
            self.pending?.digest = projectionDigest
            self.pending?.generation = generation
            return pending.deadlineMs // Replacement never pushes the first deadline.
        }
        guard projectionDigest != lastRequestedDigest else { return nil }
        let coalesced = saturatedAdd(now, 1_000)
        let limited = lastRequestAtMs.map { saturatedAdd($0, 30_000) } ?? coalesced
        let deadline = max(coalesced, limited)
        pending = Pending(firstAtMs: now, deadlineMs: deadline,
                          digest: projectionDigest, generation: generation)
        return deadline
    }

    // Returns only the frozen Widget kind. The caller owns its single one-shot
    // timer and may call WidgetCenter.reloadTimelines only for this result.
    func fire(atMs now: UInt64, currentGeneration: UInt64) -> String? {
        guard let candidate = pending, now >= candidate.deadlineMs else { return nil }
        pending = nil
        guard candidate.generation == currentGeneration,
              candidate.digest != lastRequestedDigest else { return nil }
        lastRequestAtMs = now
        lastRequestedDigest = candidate.digest
        return DevWidgetIdentity.kind
    }

    func cancel(generation: UInt64) {
        acceptedGeneration = max(acceptedGeneration, generation)
        cancelled = true
        pending = nil
    }

    private func saturatedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}
