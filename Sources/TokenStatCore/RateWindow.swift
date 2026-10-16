import Foundation

public struct RateWindow {
    // 100ms buckets cap memory to ~51 entries, regardless of SSE chunk frequency.
    private var buckets: [Int: Double] = [:]
    public init() {}
    public mutating func add(tokens: Double, at time: Double) {
        guard tokens.isFinite, tokens > 0 else { return }
        buckets[Int(floor(time * 10)), default: 0] += tokens
        prune(at: time)
    }
    public mutating func rate(at time: Double) -> Double {
        prune(at: time)
        return buckets.values.reduce(0, +) / 5
    }
    private mutating func prune(at time: Double) {
        let cutoff = Int(floor((time - 5) * 10))
        buckets = buckets.filter { $0.key > cutoff }
    }
}
