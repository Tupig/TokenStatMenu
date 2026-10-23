import Foundation

/// The single projection shared between the menu-bar app and its WidgetKit
/// extension. Only fields that both processes may display are represented;
/// account identity, credentials and raw session text never enter this type.
///
/// Every value is optional because a missing source must stay visibly unknown.
/// Publishing does not treat absence as zero and does not substitute another
/// window or a historical snapshot.
public struct WidgetQuotaSnapshot: Equatable, Sendable {

    /// A rolling or fixed quota window as the menu bar currently presents it.
    public struct Window: Equatable, Sendable {
        /// Remaining share of the window, 0...100.
        public let remainingPercent: Double
        /// Window reset instant, when the source supplied one.
        public let resetsAt: Date?

        public init(remainingPercent: Double, resetsAt: Date?) {
            self.remainingPercent = remainingPercent
            self.resetsAt = resetsAt
        }
    }

    /// Monthly usage. `limitAmount` stays nil when the source omits a cap, so
    /// the widget shows "unknown" instead of inventing a percentage.
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

    /// Local Codex accounting subtotals for the current scan scope.
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

    /// Fixed schema identity. A decoder that does not recognise this value
    /// must reject the payload rather than guess at its meaning.
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

    /// Hub figures are only current while the snapshot is inside its own
    /// validity interval and the window has not reset.
    ///
    /// A `writtenAt` that is still in the future means the wall clock moved
    /// backwards since the write. That is not corruption, so it degrades to
    /// "not current" here rather than failing the whole decode: the `local`
    /// subtotals do not depend on absolute time and stay readable.
    public func hubIsCurrent(at now: Date) -> Bool {
        guard hubState == .ready, let validUntil, let observedAt else { return false }
        guard observedAt <= writtenAt, writtenAt <= now, now <= validUntil else { return false }
        return true
    }

    /// A window is displayable only while the hub evidence is current and its
    /// reported reset instant is still in the future.
    public func currentWindow(_ window: Window?, at now: Date) -> Window? {
        guard hubIsCurrent(at: now), let window else { return nil }
        if let resetsAt = window.resetsAt, resetsAt <= now { return nil }
        return window
    }

    /// Monthly usage follows the same freshness rule as the windows. An expired
    /// or reset hub must not keep showing the last percentage.
    public func currentMonthly(at now: Date) -> Monthly? {
        hubIsCurrent(at: now) ? monthly : nil
    }
}
