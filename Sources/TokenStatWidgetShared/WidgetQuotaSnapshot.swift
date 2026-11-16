import Foundation

/// 有状态映射的固定展示字段；raw value 也是 schema v2 的 wire key。
public enum WidgetQuotaField: String, CaseIterable, Equatable, Sendable {
    case fiveHour
    case sevenDay
    case monthly
}

/// 不限和已超限是来源状态，不用虚构的额度数值表示。
public enum WidgetQuotaValueState: Equatable, Sendable {
    case unlimited(resetAt: Date?)
    case exceeded(resetAt: Date?)

    public var resetAt: Date? {
        switch self {
        case .unlimited(let resetAt), .exceeded(let resetAt): return resetAt
        }
    }

    public var kind: String {
        switch self {
        case .unlimited: return "unlimited"
        case .exceeded: return "exceeded"
        }
    }
}

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
        /// 后台已用金额；旧快照或来源缺失时为 nil。
        public let usedAmount: Double?
        /// 后台窗口上限金额；旧快照或来源缺失时为 nil。
        public let limitAmount: Double?
        /// 来源货币符号，例如 `$`。
        public let sourceSymbol: String?

        public init(remainingPercent: Double, resetsAt: Date?,
                    usedAmount: Double? = nil, limitAmount: Double? = nil,
                    sourceSymbol: String? = nil) {
            self.remainingPercent = remainingPercent
            self.resetsAt = resetsAt
            self.usedAmount = usedAmount
            self.limitAmount = limitAmount
            self.sourceSymbol = sourceSymbol
        }

        /// 已用比例；由剩余比例反推，与面板进度条一致。
        public var usedPercent: Double {
            min(100, max(0, 100 - remainingPercent))
        }

        /// 文本保留真实超额比例；只在进度条中使用已夹紧的 `usedPercent`。
        public var displayedUsedPercent: Double? {
            guard let usedAmount, let limitAmount, limitAmount > 0 else { return nil }
            let value = usedAmount / limitAmount * 100
            return value.isFinite ? value : nil
        }
    }

    /// 月度用量。来源未提供上限时，`limitAmount` 为 nil，小组件不计算百分比。
    public struct Monthly: Equatable, Sendable {
        public let usedAmount: Double
        public let limitAmount: Double?
        public let sourceSymbol: String
        /// 月度周期的来源 reset；缺失时保持未知，不借用其它窗口时间。
        public let resetsAt: Date?

        public init(usedAmount: Double, limitAmount: Double?, sourceSymbol: String,
                    resetsAt: Date? = nil) {
            self.usedAmount = usedAmount
            self.limitAmount = limitAmount
            self.sourceSymbol = sourceSymbol
            self.resetsAt = resetsAt
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
    public static let schemaVersion = 2

    public let writtenAt: Date
    public let observedAt: Date?
    public let validUntil: Date?
    public let hubSource: HubSource
    public let hubState: HubState
    public let fiveHour: Window?
    public let sevenDay: Window?
    public let monthly: Monthly?
    public let local: Local?
    /// 可用重置券数量；来源未提供时为 nil。
    public let resetVoucherCount: Int?
    /// 每个额度字段的显式异常状态；v1 快照升级时为空。
    public let states: [WidgetQuotaField: WidgetQuotaValueState]

    public init(writtenAt: Date, observedAt: Date?, validUntil: Date?,
                hubSource: HubSource, hubState: HubState,
                fiveHour: Window?, sevenDay: Window?, monthly: Monthly?, local: Local?,
                resetVoucherCount: Int? = nil,
                states: [WidgetQuotaField: WidgetQuotaValueState] = [:]) {
        self.writtenAt = writtenAt
        self.observedAt = observedAt
        self.validUntil = validUntil
        self.hubSource = hubSource
        self.hubState = hubState
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.monthly = monthly
        self.local = local
        self.resetVoucherCount = resetVoucherCount
        self.states = states
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

    /// 新协议按明确字段关联状态，避免两个数值相同的窗口被结构体相等误判。
    public func currentWindow(_ window: Window?, field: WidgetQuotaField, at now: Date) -> Window? {
        guard hubIsCurrent(at: now) else { return nil }
        guard let state = states[field] else { return currentWindow(window, at: now) }
        if let stateReset = state.resetAt, let numericReset = window?.resetsAt,
           stateReset != numericReset { return nil }
        if let resetAt = state.resetAt ?? window?.resetsAt, resetAt <= now { return nil }
        // state 到期或 unlimited 冲突时，不允许共存 numeric 复活。
        if case .unlimited = state { return nil }
        guard let window else { return nil }
        if let numericReset = window.resetsAt, numericReset <= now { return nil }
        return window
    }

    /// 仅返回当前快照中尚未到自身 reset 的状态。
    public func currentState(_ field: WidgetQuotaField, at now: Date) -> WidgetQuotaValueState? {
        guard hubIsCurrent(at: now), let state = states[field] else { return nil }
        let numericReset: Date?
        switch field {
        case .fiveHour: numericReset = fiveHour?.resetsAt
        case .sevenDay: numericReset = sevenDay?.resetsAt
        case .monthly: numericReset = monthly?.resetsAt
        }
        if let stateReset = state.resetAt, let numericReset, stateReset != numericReset { return nil }
        if let resetAt = state.resetAt ?? numericReset, resetAt <= now { return nil }
        if case .unlimited = state {
            switch field {
            case .fiveHour where fiveHour != nil: return nil
            case .sevenDay where sevenDay != nil: return nil
            case .monthly where monthly != nil: return nil
            default: break
            }
        }
        return state
    }

    /// 月度用量采用相同的有效期规则，过期或重置后不再显示旧百分比。
    public func currentMonthly(at now: Date) -> Monthly? {
        currentMonthly(at: now, field: .monthly)
    }

    public func currentMonthly(at now: Date, field: WidgetQuotaField) -> Monthly? {
        guard hubIsCurrent(at: now) else { return nil }
        let state = states[field]
        if let stateReset = state?.resetAt, let numericReset = monthly?.resetsAt,
           stateReset != numericReset { return nil }
        if let resetAt = state?.resetAt ?? monthly?.resetsAt, resetAt <= now { return nil }
        if case .unlimited? = state { return nil }
        return monthly
    }

    /// 券数与额度使用同一有效期，零是有效值，失效不能退回旧数量。
    public func currentResetVoucherCount(at now: Date) -> Int? {
        hubIsCurrent(at: now) ? resetVoucherCount : nil
    }

    /// 提前安排窗口重置及快照到期的条目，不依赖 App 持续运行。
    public func timelineDates(after now: Date) -> [Date] {
        let expiry = validUntil.map { $0.addingTimeInterval(0.001) }
        let stateResets = states.values.map(\.resetAt)
        let dates = [fiveHour?.resetsAt, sevenDay?.resetsAt, monthly?.resetsAt, expiry] + stateResets
        return Array(Set(dates.compactMap { $0 }.filter { $0 > now })).sorted()
    }
}
