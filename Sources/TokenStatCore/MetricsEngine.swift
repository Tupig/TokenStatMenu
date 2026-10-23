import Foundation

public struct RequestRecord: Codable {
    public var id: String
    public var date: Date
    public var model: String
    public var input: Int
    public var output: Int
    public var exact: Bool
    public var success: Bool
    public var durationMS: Double
    public var firstByteMS: Double?
    public var inputWaitTPS: Double?
    public var serverInputTPS: Double?
    public var serverOutputTPS: Double?
    public var costUSD: Double
    public var error: String?
}

public struct MetricsSnapshot: Codable {
    public var input = 0
    public var output = 0
    public var total: Int { input + output }
    public var requests = 0
    public var failures = 0
    public var active = 0
    public var estimatedRequests = 0
    public var outputTPS = 0.0
    public var inputWaitTPS = 0.0
    public var averageFirstByteMS: Double?
    public var averageDurationMS: Double?
    public var costUSD = 0.0
    public var last: RequestRecord?
    public init() {}
}

/// 所有请求的变更都由一把短锁保护。锁内不进行任何 I/O。
public final class MetricsEngine {
    private struct Active {
        var start: Double
        var date: Date
        var model: String
        var input: Int
        var output = 0
        var outputUnits = 0.0
        var window = RateWindow()
        var usage: TokenUsage?
        var firstByte: Double?
        var firstOutput: Double?
        var inputPrice: Double
        var outputPrice: Double
        var serverInputTPS: Double?
        var serverOutputTPS: Double?
        var count: TokenUsage { usage ?? TokenUsage(input: input, output: output) }
        var cost: Double { (Double(count.input) * inputPrice + Double(count.output) * outputPrice) / 1e6 }
    }
    private let lock = NSLock()
    private var active: [UUID: Active] = [:]
    private var completed = MetricsSnapshot()
    private var durationSum = 0.0
    private var byteSum = 0.0
    private var byteCount = 0
    private var finishedCount = 0
    public init() {}

    @discardableResult public func begin(model: String, input: Int, config: AppConfiguration, now: Double = ProcessInfo.processInfo.systemUptime) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID()
        active[id] = Active(start: now, date: Date(), model: model, input: input, inputPrice: config.inputPrice, outputPrice: config.outputPrice)
        completed.requests += 1
        return id
    }
    public func firstByte(_ id: UUID, now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        if active[id]?.firstByte == nil { active[id]?.firstByte = now }
    }
    public func observe(_ id: UUID, _ observation: Observation, now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard var r = active[id] else { return }
        if !observation.output.isEmpty {
            if r.firstOutput == nil { r.firstOutput = now }
            r.outputUnits += TokenEstimator.units(observation.output)
            let newCount = Int(ceil(r.outputUnits))
            r.window.add(tokens: Double(max(0, newCount - r.output)), at: now)
            r.output = newCount
        }
        // 替换累计用量；不要累加，也不要制造速度尖峰。
        if let usage = observation.usage { r.usage = usage }
        r.serverInputTPS = observation.serverInputTPS ?? r.serverInputTPS
        r.serverOutputTPS = observation.serverOutputTPS ?? r.serverOutputTPS
        active[id] = r
    }
    @discardableResult public func finish(_ id: UUID, success: Bool, error: String? = nil, now: Double = ProcessInfo.processInfo.systemUptime) -> RequestRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let r = active.removeValue(forKey: id) else { return nil } // 恰好一次，即使发生取消竞争。
        let elapsed = max(0, now - r.start) * 1000
        let first = r.firstByte.map { max(0, $0 - r.start) * 1000 }
        let inputRate = r.firstOutput.map { Double(r.count.input) / max(0.001, $0 - r.start) }
        let record = RequestRecord(id: id.uuidString, date: r.date, model: r.model, input: r.count.input,
            output: r.count.output, exact: r.usage != nil, success: success, durationMS: elapsed,
            firstByteMS: first, inputWaitTPS: inputRate, serverInputTPS: r.serverInputTPS,
            serverOutputTPS: r.serverOutputTPS, costUSD: r.cost, error: error)
        completed.input += r.count.input; completed.output += r.count.output
        completed.costUSD += r.cost; completed.failures += success ? 0 : 1
        completed.estimatedRequests += r.usage == nil ? 1 : 0
        finishedCount += 1; durationSum += elapsed
        if let first { byteSum += first; byteCount += 1 }
        completed.last = record
        return record
    }
    public func snapshot(now: Double = ProcessInfo.processInfo.systemUptime) -> MetricsSnapshot {
        lock.lock(); defer { lock.unlock() }
        var s = completed
        s.active = active.count
        // 窗口属于请求：一个已完成的请求不能放大一个新请求。
        for (id, var r) in active {
            s.outputTPS += r.window.rate(at: now)
            s.input += r.count.input; s.output += r.count.output; s.costUSD += r.cost
            s.estimatedRequests += r.usage == nil ? 1 : 0
            s.inputWaitTPS += Double(r.count.input) / max(0.5, (r.firstOutput ?? now) - r.start)
            active[id] = r
        }
        s.averageFirstByteMS = byteCount > 0 ? byteSum / Double(byteCount) : nil
        s.averageDurationMS = finishedCount > 0 ? durationSum / Double(finishedCount) : nil
        return s
    }
}
