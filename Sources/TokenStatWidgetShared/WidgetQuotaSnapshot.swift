import Foundation

/// 菜单栏应用与 WidgetKit 扩展共用的显示数据，不包含账号身份、凭据或会话原文。
///
/// 可选值缺失时显示未知，不用零、其他窗口或历史快照补齐。
public struct WidgetQuotaSnapshot: Equatable, Sendable {

    /// 菜单栏当前显示的滚动或固定额度窗口。
    public struct Window: Equatable, Sendable {
        /// 窗口剩余比例，范围为 0...100。
        public let remainingPercent: Double
        /// 来源提供的窗口重置时间。
        public let resetsAt: Date?

        public init(remainingPercent: Double, resetsAt: Date?) {
            self.remainingPercent = remainingPercent
            self.resetsAt = resetsAt
        }
    }

    /// 月度用量。来源未提供上限时，`limitAmount` 为 nil，小组件不计算百分比。
    public struct Monthly: Equatable, Sendable {
        public let usedAmount: Double
        public let limitAmount: Double?
        public let sourceSymbol: String

        public init(usedAmount: Double, limitAmount: Double?, sourceSymbol: String) {
            self.usedAmount = usedAmount
            self.limitAmount = limitAmount
            self.sourceSymbol = sourceSymbol
        }

        public var remainingAmount: Double? {
            limitAmount.map { max(0, $0 - usedAmount) }
        }

        public var usedPercent: Double? {
            guard let limitAmount, limitAmount > 0 else { return nil }
            return min(100, max(0, usedAmount / limitAmount * 100))
        }
    }

    /// 当前扫描范围内可计算的本地 Codex 用量。
    public struct Local: Equatable, Sendable {
        public let inputTokens: Int
        public let outputTokens: Int
        public let totalTokens: Int
        public let knownThreads: Int
        public let unknownThreads: Int
        public let isLimited: Bool

        public init(inputTokens: Int, outputTokens: Int, totalTokens: Int,
                    knownThreads: Int, unknownThreads: Int, isLimited: Bool) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.totalTokens = totalTokens
            self.knownThreads = knownThreads
            self.unknownThreads = unknownThreads
            self.isLimited = isLimited
        }
    }

    public enum HubSource: String, Equatable, Sendable {
        case none, direct, compatibility
    }

    public enum HubState: String, Equatable, Sendable {
        case ready, unavailable, disabled, stale, invalid
    }

    /// 固定的协议版本；解码器拒绝不支持的版本。
    public static let schemaVersion = 1

    public let writtenAt: Date
    public let observedAt: Date?
    public let validUntil: Date?
    public let hubSource: HubSource
    public let hubState: HubState
    public let fiveHour: Window?
    public let sevenDay: Window?
    public let monthly: Monthly?
    public let local: Local?

    public init(writtenAt: Date, observedAt: Date?, validUntil: Date?,
                hubSource: HubSource, hubState: HubState,
                fiveHour: Window?, sevenDay: Window?, monthly: Monthly?, local: Local?) {
        self.writtenAt = writtenAt
        self.observedAt = observedAt
        self.validUntil = validUntil
        self.hubSource = hubSource
        self.hubState = hubState
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.monthly = monthly
        self.local = local
    }

    /// 快照仍在有效期内且窗口尚未重置时，Hub 数据才有效。
    ///
    /// `writtenAt` 晚于当前时间时按时钟回拨处理，Hub 数据失效；
    /// 不依赖绝对时间的 `local` 用量仍可读取。
    public func hubIsCurrent(at now: Date) -> Bool {
        guard hubState == .ready, let validUntil, let observedAt else { return false }
        guard observedAt <= writtenAt, writtenAt <= now, now <= validUntil else { return false }
        return true
    }

    /// 仅显示仍有效且尚未到重置时间的窗口。
    public func currentWindow(_ window: Window?, at now: Date) -> Window? {
        guard hubIsCurrent(at: now), let window else { return nil }
        if let resetsAt = window.resetsAt, resetsAt <= now { return nil }
        return window
    }

    /// 月度用量采用相同的有效期规则，过期或重置后不再显示旧百分比。
    public func currentMonthly(at now: Date) -> Monthly? {
        hubIsCurrent(at: now) ? monthly : nil
    }
}
