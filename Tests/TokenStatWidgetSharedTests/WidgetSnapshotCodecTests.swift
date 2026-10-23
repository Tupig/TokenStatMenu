import Foundation
import XCTest
@testable import TokenStatMenu
@testable import TokenStatWidgetShared

/// Wire-format coverage for the shared widget snapshot.
///
/// The app and the extension exchange bytes through the App Group container, so
/// a decoder that is either too strict or too loose produces silent
/// disagreement. These tests pin both directions: every accepted payload must
/// round trip to identical values, and every malformed shape must be rejected
/// rather than half-parsed into a plausible-looking number.
final class WidgetSnapshotCodecTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Round trips

    func testVoucherProjectionAndScheduledExpiryBoundaries() {
        for state in [WidgetQuotaSnapshot.HubState.ready, .stale, .unavailable, .disabled, .invalid] {
            for count: Int? in [nil, 0, 3] {
                let snapshot = WidgetQuotaSnapshot(writtenAt: now, observedAt: now,
                    validUntil: now.addingTimeInterval(120), hubSource: .direct, hubState: state,
                    fiveHour: .init(remainingPercent: 50, resetsAt: now.addingTimeInterval(60)),
                    sevenDay: .init(remainingPercent: 70, resetsAt: now.addingTimeInterval(60)),
                    monthly: nil, local: nil, resetVoucherCount: count)
                XCTAssertEqual(snapshot.currentResetVoucherCount(at: now), state == .ready ? count : nil)
                XCTAssertEqual(snapshot.currentResetVoucherCount(at: now.addingTimeInterval(120)), state == .ready ? count : nil)
                XCTAssertNil(snapshot.currentResetVoucherCount(at: now.addingTimeInterval(120.001)))
                XCTAssertNil(snapshot.currentResetVoucherCount(at: now.addingTimeInterval(-1)))
                let dates = snapshot.timelineDates(after: now)
                XCTAssertEqual(dates.count, 2, "重复重置边界只生成一个条目")
                XCTAssertNil(snapshot.currentWindow(snapshot.fiveHour, at: dates[0]))
                XCTAssertNil(snapshot.currentResetVoucherCount(at: dates[1]))
                XCTAssertTrue(snapshot.timelineDates(after: dates[1]).isEmpty)
            }
        }
    }

    func testRoundTripKeepsEveryPresentField() throws {
        let snapshot = WidgetQuotaSnapshot(
            writtenAt: now,
            observedAt: now.addingTimeInterval(-30),
            validUntil: now.addingTimeInterval(150),
            hubSource: .direct,
            hubState: .ready,
            fiveHour: WidgetQuotaSnapshot.Window(remainingPercent: 87.66,
                                                 resetsAt: now.addingTimeInterval(3_600),
                                                 usedAmount: 61.7, limitAmount: 500,
                                                 sourceSymbol: "$"),
            sevenDay: WidgetQuotaSnapshot.Window(remainingPercent: 43.22, resetsAt: nil),
            monthly: WidgetQuotaSnapshot.Monthly(usedAmount: 12.34, limitAmount: 100,
                                                 sourceSymbol: "$"),
            local: WidgetQuotaSnapshot.Local(inputTokens: 10, outputTokens: 20,
                                             totalTokens: 30, knownThreads: 2,
                                             unknownThreads: 1, isLimited: false),
            resetVoucherCount: 3)
        let decoded = try WidgetSnapshotCodec.decode(try WidgetSnapshotCodec.encode(snapshot),
                                                     now: now)
        XCTAssertEqual(decoded.writtenAt, snapshot.writtenAt)
        XCTAssertEqual(decoded.observedAt, snapshot.observedAt)
        XCTAssertEqual(decoded.validUntil, snapshot.validUntil)
        XCTAssertEqual(decoded.hubSource, .direct)
        XCTAssertEqual(decoded.hubState, .ready)
        XCTAssertEqual(decoded.fiveHour?.remainingPercent, 87.66)
        XCTAssertEqual(decoded.fiveHour?.usedAmount, 61.7)
        XCTAssertEqual(decoded.fiveHour?.limitAmount, 500)
        XCTAssertEqual(decoded.fiveHour?.sourceSymbol, "$")
        XCTAssertEqual(decoded.fiveHour?.usedPercent ?? -1, 12.34, accuracy: 0.001)
        XCTAssertEqual(decoded.sevenDay?.remainingPercent, 43.22)
        XCTAssertNil(decoded.sevenDay?.resetsAt)
        XCTAssertNil(decoded.sevenDay?.usedAmount)
        XCTAssertEqual(decoded.monthly?.usedAmount, 12.34)
        XCTAssertEqual(decoded.monthly?.limitAmount, 100)
        XCTAssertEqual(decoded.monthly?.sourceSymbol, "$")
        XCTAssertEqual(decoded.local?.totalTokens, 30)
        XCTAssertEqual(decoded.local?.unknownThreads, 1)
        XCTAssertFalse(decoded.local?.isLimited ?? true)
        XCTAssertEqual(decoded.resetVoucherCount, 3)
    }

    /// 1.1.5 及更早的快照没有券字段；升级瞬间必须解码为未知，而不是整份快照失败。
    func testDecodeAcceptsPayloadWithoutResetVoucherCount() throws {
        let decoded = try WidgetSnapshotCodec.decode(Data(validPayload(replacing: "\"local\":null",
                                                                       with: "\"local\":null").utf8), now: now)
        XCTAssertNil(decoded.resetVoucherCount)
    }

    func testResetVoucherCountRejectsOutOfRangeAndNonIntegerValues() {
        for count in [-1, 1_000_001] {
            let snapshot = WidgetQuotaSnapshot(
                writtenAt: now, observedAt: nil, validUntil: nil,
                hubSource: .none, hubState: .unavailable,
                fiveHour: nil, sevenDay: nil, monthly: nil, local: nil,
                resetVoucherCount: count)
            XCTAssertThrowsError(try WidgetSnapshotCodec.encode(snapshot)) { error in
                XCTAssertEqual(error as? WidgetSnapshotCodec.CodecError,
                               .outOfRange("resetVoucherCount"))
            }
        }
        for literal in ["-1", "1000001", "1.5", "\"2\"", "true"] {
            let payload = validPayload(replacing: "\"local\":null",
                                       with: "\"local\":null,\"resetVoucherCount\":\(literal)")
            XCTAssertThrowsError(try WidgetSnapshotCodec.decode(Data(payload.utf8), now: now),
                                 "resetVoucherCount \(literal) must be rejected")
        }
    }

    /// A missing source must decode as nil, never as zero.
    func testRoundTripKeepsEveryFieldExplicitlyNull() throws {
        let snapshot = WidgetQuotaSnapshot(
            writtenAt: now, observedAt: nil, validUntil: nil,
            hubSource: .none, hubState: .unavailable,
            fiveHour: nil, sevenDay: nil, monthly: nil, local: nil)
        let decoded = try WidgetSnapshotCodec.decode(try WidgetSnapshotCodec.encode(snapshot),
                                                     now: now)
        XCTAssertNil(decoded.observedAt)
        XCTAssertNil(decoded.validUntil)
        XCTAssertNil(decoded.fiveHour)
        XCTAssertNil(decoded.sevenDay)
        XCTAssertNil(decoded.monthly)
        XCTAssertNil(decoded.local)
        XCTAssertEqual(decoded.hubSource, .none)
        XCTAssertEqual(decoded.hubState, .unavailable)
    }

    func testEncodeIsDeterministicForIdenticalInput() throws {
        let first = WidgetQuotaSnapshot(writtenAt: now, observedAt: now,
            validUntil: now.addingTimeInterval(120), hubSource: .compatibility,
            hubState: .stale, fiveHour: nil, sevenDay: nil, monthly: nil, local: nil)
        let second = first
        XCTAssertEqual(try WidgetSnapshotCodec.encode(first),
                       try WidgetSnapshotCodec.encode(second))
    }

    /// `writtenAtMs` is the payload field that changes on every tick. The skip
    /// gate in the publisher relies on it being excluded from identity, so this
    /// documents that two ticks with the same values differ only in that field.
    func testDisplayIdentityIgnoresWrittenAt() throws {
        let earlier = WidgetQuotaSnapshot(writtenAt: now, observedAt: now,
            validUntil: nil, hubSource: .direct, hubState: .ready,
            fiveHour: WidgetQuotaSnapshot.Window(remainingPercent: 40, resetsAt: nil),
            sevenDay: nil, monthly: nil, local: nil)
        let later = WidgetQuotaSnapshot(writtenAt: now.addingTimeInterval(30),
            observedAt: now, validUntil: nil, hubSource: .direct, hubState: .ready,
            fiveHour: WidgetQuotaSnapshot.Window(remainingPercent: 40, resetsAt: nil),
            sevenDay: nil, monthly: nil, local: nil)
        let changed = WidgetQuotaSnapshot(writtenAt: now.addingTimeInterval(30),
            observedAt: now, validUntil: nil, hubSource: .direct, hubState: .ready,
            fiveHour: WidgetQuotaSnapshot.Window(remainingPercent: 10, resetsAt: nil),
            sevenDay: nil, monthly: nil, local: nil)
        let first = try WidgetSnapshotCodec.encode(earlier)
        let second = try WidgetSnapshotCodec.encode(later)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(WidgetSnapshotPublisher.displayIdentity(of: first),
                       WidgetSnapshotPublisher.displayIdentity(of: second))
        XCTAssertNotEqual(WidgetSnapshotPublisher.displayIdentity(of: first),
                          WidgetSnapshotPublisher.displayIdentity(of: try WidgetSnapshotCodec.encode(changed)))
    }

    func testDifferentWrittenAtProducesDifferentBytes() throws {
        let earlier = WidgetQuotaSnapshot(writtenAt: now, observedAt: now,
            validUntil: nil, hubSource: .none, hubState: .unavailable,
            fiveHour: nil, sevenDay: nil, monthly: nil, local: nil)
        let later = WidgetQuotaSnapshot(writtenAt: now.addingTimeInterval(0.5),
            observedAt: now, validUntil: nil, hubSource: .none,
            hubState: .unavailable, fiveHour: nil, sevenDay: nil,
            monthly: nil, local: nil)
        XCTAssertNotEqual(try WidgetSnapshotCodec.encode(earlier),
                          try WidgetSnapshotCodec.encode(later))
    }

    // MARK: - Encoding acceptance

    func testEncodeAcceptsBoundaryValues() throws {
        let zero = WidgetQuotaSnapshot(writtenAt: now, observedAt: now,
            validUntil: now, hubSource: .direct, hubState: .ready,
            fiveHour: WidgetQuotaSnapshot.Window(remainingPercent: 0, resetsAt: nil),
            sevenDay: WidgetQuotaSnapshot.Window(remainingPercent: 100, resetsAt: nil),
            monthly: WidgetQuotaSnapshot.Monthly(usedAmount: 0, limitAmount: nil,
                                                 sourceSymbol: ""),
            local: WidgetQuotaSnapshot.Local(inputTokens: 0, outputTokens: 0,
                totalTokens: 0, knownThreads: 0, unknownThreads: 0,
                isLimited: true))
        let data = try WidgetSnapshotCodec.encode(zero)
        XCTAssertLessThanOrEqual(data.count, WidgetSnapshotCodec.maximumBytes)
        let decoded = try WidgetSnapshotCodec.decode(data, now: now)
        XCTAssertEqual(decoded.fiveHour?.remainingPercent, 0)
        XCTAssertEqual(decoded.sevenDay?.remainingPercent, 100)
        XCTAssertEqual(decoded.local?.isLimited, true)
    }

    func testEncodeRejectsOutOfRangePercent() {
        let tooHigh = WidgetQuotaSnapshot(writtenAt: now, observedAt: nil,
            validUntil: nil, hubSource: .none, hubState: .unavailable,
            fiveHour: WidgetQuotaSnapshot.Window(remainingPercent: 100.001, resetsAt: nil),
            sevenDay: nil, monthly: nil, local: nil)
        XCTAssertThrowsError(try WidgetSnapshotCodec.encode(tooHigh))

        let negative = WidgetQuotaSnapshot(writtenAt: now, observedAt: nil,
            validUntil: nil, hubSource: .none, hubState: .unavailable,
            fiveHour: WidgetQuotaSnapshot.Window(remainingPercent: -0.001, resetsAt: nil),
            sevenDay: nil, monthly: nil, local: nil)
        XCTAssertThrowsError(try WidgetSnapshotCodec.encode(negative))

        let nan = WidgetQuotaSnapshot(writtenAt: now, observedAt: nil,
            validUntil: nil, hubSource: .none, hubState: .unavailable,
            fiveHour: WidgetQuotaSnapshot.Window(remainingPercent: .nan, resetsAt: nil),
            sevenDay: nil, monthly: nil, local: nil)
        XCTAssertThrowsError(try WidgetSnapshotCodec.encode(nan))
    }

    func testEncodeRejectsSymbolTooLong() {
        // The symbol is rendered inside the widget's bounded area, so an
        // over-long value is a payload error rather than a layout problem.
        // (`.infinity` amounts are rejected by `validate` before serialising.)
        // A pre-image date is likewise rejected: it would encode as a negative
        // millisecond value that this decoder refuses.
        let badAmount = WidgetQuotaSnapshot(writtenAt: now, observedAt: nil,
            validUntil: nil, hubSource: .none, hubState: .unavailable,
            fiveHour: nil, sevenDay: nil,
            monthly: WidgetQuotaSnapshot.Monthly(usedAmount: .infinity, limitAmount: nil,
                                                 sourceSymbol: "$"),
            local: nil)
        XCTAssertThrowsError(try WidgetSnapshotCodec.encode(badAmount)) { error in
            XCTAssertEqual(error as? WidgetSnapshotCodec.CodecError,
                           .outOfRange("monthly.usedAmount"))
        }

        let longSymbol = WidgetQuotaSnapshot(writtenAt: now, observedAt: nil,
            validUntil: nil, hubSource: .none, hubState: .unavailable,
            fiveHour: nil, sevenDay: nil,
            monthly: WidgetQuotaSnapshot.Monthly(usedAmount: 1, limitAmount: nil,
                                                 sourceSymbol: "TOOLONG"),
            local: nil)
        XCTAssertThrowsError(try WidgetSnapshotCodec.encode(longSymbol)) { error in
            XCTAssertEqual(error as? WidgetSnapshotCodec.CodecError,
                           .outOfRange("monthly.sourceSymbol"))
        }
    }

    func testDecodeAcceptsFractionalTimestamp() throws {
        let payload = validPayload(replacing: "\"writtenAtMs\":1800000000000",
                                   with: "\"writtenAtMs\":1.5")
        XCTAssertThrowsError(try WidgetSnapshotCodec.decode(Data(payload.utf8), now: now))
    }

    // MARK: - Decoding rejection

    func testDecodeRejectsNonObjectRootAndEmptyPayload() {
        XCTAssertThrowsError(try WidgetSnapshotCodec.decode(Data("[]".utf8), now: now))
        XCTAssertThrowsError(try WidgetSnapshotCodec.decode(Data(), now: now))
    }

    func testDecodeRejectsMalformedMonthlyAndLocalObjects() {
        let extraMonthly = validPayload(replacing: "\"monthly\":null",
                                        with: "{\"usedAmount\":1,\"limitAmount\":null,\"sourceSymbol\":\"$\",\"extra\":1}")
        XCTAssertThrowsError(try WidgetSnapshotCodec.decode(Data(extraMonthly.utf8), now: now))
        let missingLocal = validPayload(replacing: "\"local\":null",
                                        with: "{\"inputTokens\":1,\"outputTokens\":1,\"totalTokens\":2,\"knownThreads\":1,\"unknownThreads\":0}")
        XCTAssertThrowsError(try WidgetSnapshotCodec.decode(Data(missingLocal.utf8), now: now))
        let numericBool = validPayload(replacing: "\"local\":null",
                                       with: "{\"inputTokens\":1,\"outputTokens\":1,\"totalTokens\":2,\"knownThreads\":1,\"unknownThreads\":0,\"isLimited\":1}")
        XCTAssertThrowsError(try WidgetSnapshotCodec.decode(Data(numericBool.utf8), now: now))
    }

    func testDecodeRejectsUnexpectedAndMissingKeys() {
        let extra = validPayload(replacing: "\"local\":null", with: "\"local\":null,\"extra\":1")
        XCTAssertThrowsError(try WidgetSnapshotCodec.decode(Data(extra.utf8), now: now))
        let missing = validPayload(replacing: ",\"local\":null", with: "")
        XCTAssertThrowsError(try WidgetSnapshotCodec.decode(Data(missing.utf8), now: now))
    }

    func testDecodeRejectsWrongSchemaVersion() {
        for literal in ["1.5", "2", "\"1\"", "true", "-1"] {
            let payload = validPayload(replacing: "\"schemaVersion\":1",
                                       with: "\"schemaVersion\":\(literal)")
            XCTAssertThrowsError(try WidgetSnapshotCodec.decode(Data(payload.utf8), now: now),
                                 "schemaVersion \(literal) must be rejected")
        }
    }

    func testDecodeRejectsOutOfRangePercentAndWindows() {
        let cases = ["-1", "100.001", "1e9"]
        for literal in cases {
            let payload = validPayload(replacing: "\"fiveHour\":null",
                with: "{\"remainingPercent\":\(literal),\"resetsAtMs\":null}")
            XCTAssertThrowsError(try WidgetSnapshotCodec.decode(Data(payload.utf8), now: now),
                                 "remainingPercent \(literal) must be rejected")
        }
        let unexpectedKey = validPayload(replacing: "\"fiveHour\":null",
            with: "{\"remainingPercent\":50,\"resetsAtMs\":null,\"extra\":1}")
        XCTAssertThrowsError(try WidgetSnapshotCodec.decode(Data(unexpectedKey.utf8), now: now))
        let missingKey = validPayload(replacing: "\"fiveHour\":null",
            with: "{\"remainingPercent\":50}")
        XCTAssertThrowsError(try WidgetSnapshotCodec.decode(Data(missingKey.utf8), now: now))
    }

    func testDecodeRejectsInvalidTimestamps() {
        let negative = validPayload(replacing: "\"writtenAtMs\":1800000000000",
                                    with: "\"writtenAtMs\":-1")
        XCTAssertThrowsError(try WidgetSnapshotCodec.decode(Data(negative.utf8), now: now))
        let tooLarge = validPayload(replacing: "\"writtenAtMs\":1800000000000",
                                    with: "\"writtenAtMs\":253402300800000")
        XCTAssertThrowsError(try WidgetSnapshotCodec.decode(Data(tooLarge.utf8), now: now))
    }

    /// Fractional milliseconds are accepted: the wire format stores an
    /// integer value, but a fractional literal is still a well-formed number.
    /// A wall clock that moved backwards must not make the file unreadable:
    /// it degrades to "not current", and `local` subtotals stay available.
    func testFutureWrittenAtDecodesButIsNotCurrent() throws {
        let later = now.addingTimeInterval(60)
        let snapshot = WidgetQuotaSnapshot(
            writtenAt: later,
            observedAt: later,
            validUntil: later.addingTimeInterval(120),
            hubSource: .direct,
            hubState: .ready,
            fiveHour: WidgetQuotaSnapshot.Window(remainingPercent: 50, resetsAt: nil),
            sevenDay: nil,
            monthly: nil,
            local: WidgetQuotaSnapshot.Local(inputTokens: 5, outputTokens: 5,
                totalTokens: 10, knownThreads: 1, unknownThreads: 0,
                isLimited: false))
        let decoded = try WidgetSnapshotCodec.decode(try WidgetSnapshotCodec.encode(snapshot),
                                                     now: now)
        XCTAssertFalse(decoded.hubIsCurrent(at: now))
        XCTAssertNil(decoded.currentWindow(decoded.fiveHour, at: now))
        // The local subtotal carries no absolute-time dependency, so it stays.
        XCTAssertEqual(decoded.local?.totalTokens, 10)
        XCTAssertNil(decoded.currentMonthly(at: now))
    }

    func testHubExpiredDropsWindowsAndMonthlyButKeepsLocal() {
        let snapshot = WidgetQuotaSnapshot(
            writtenAt: now.addingTimeInterval(-30),
            observedAt: now.addingTimeInterval(-30),
            validUntil: now.addingTimeInterval(-1),
            hubSource: .direct, hubState: .ready,
            fiveHour: WidgetQuotaSnapshot.Window(remainingPercent: 40, resetsAt: nil),
            sevenDay: nil,
            monthly: WidgetQuotaSnapshot.Monthly(usedAmount: 2, limitAmount: 10, sourceSymbol: "$"),
            local: WidgetQuotaSnapshot.Local(inputTokens: 1, outputTokens: 1,
                totalTokens: 2, knownThreads: 1, unknownThreads: 0, isLimited: false))
        XCTAssertFalse(snapshot.hubIsCurrent(at: now))
        XCTAssertNil(snapshot.currentWindow(snapshot.fiveHour, at: now))
        XCTAssertNil(snapshot.currentMonthly(at: now))
        XCTAssertEqual(snapshot.local?.totalTokens, 2)
    }

    func testResetWindowIsUnknownWhileUnresetWindowStays() {
        let snapshot = WidgetQuotaSnapshot(
            writtenAt: now, observedAt: now, validUntil: now.addingTimeInterval(60),
            hubSource: .direct, hubState: .ready,
            fiveHour: WidgetQuotaSnapshot.Window(remainingPercent: 20,
                                                 resetsAt: now.addingTimeInterval(-1)),
            sevenDay: WidgetQuotaSnapshot.Window(remainingPercent: 80, resetsAt: nil),
            monthly: nil, local: nil)
        XCTAssertNil(snapshot.currentWindow(snapshot.fiveHour, at: now))
        XCTAssertEqual(snapshot.currentWindow(snapshot.sevenDay, at: now)?.remainingPercent, 80)
        let exactReset = WidgetQuotaSnapshot.Window(remainingPercent: 20, resetsAt: now)
        XCTAssertNil(snapshot.currentWindow(exactReset, at: now))
    }

    func testDecodeAcceptsUtcEpochZero() throws {
        let payload = validPayload(replacing: "\"writtenAtMs\":1800000000000",
                                   with: "\"writtenAtMs\":0")
        let decoded = try WidgetSnapshotCodec.decode(Data(payload.utf8), now: now)
        XCTAssertEqual(decoded.writtenAt, Date(timeIntervalSince1970: 0))
    }

    /// 旧版快照的窗口只有剩余比例和重置时间；升级瞬间必须解码为未知金额。
    func testDecodeAcceptsWindowWithoutAmountFields() throws {
        let payload = validPayload(replacing: "\"fiveHour\":null",
            with: "\"fiveHour\":{\"remainingPercent\":50,\"resetsAtMs\":null}")
        let decoded = try WidgetSnapshotCodec.decode(Data(payload.utf8), now: now)
        XCTAssertEqual(decoded.fiveHour?.remainingPercent, 50)
        XCTAssertNil(decoded.fiveHour?.usedAmount)
        XCTAssertNil(decoded.fiveHour?.limitAmount)
        XCTAssertNil(decoded.fiveHour?.sourceSymbol)
    }

    func testWindowAmountsRejectInvalidValues() {
        let negative = WidgetQuotaSnapshot(
            writtenAt: now, observedAt: nil, validUntil: nil,
            hubSource: .none, hubState: .unavailable,
            fiveHour: WidgetQuotaSnapshot.Window(remainingPercent: 50, resetsAt: nil,
                                                 usedAmount: -1, limitAmount: 500,
                                                 sourceSymbol: "$"),
            sevenDay: nil, monthly: nil, local: nil)
        XCTAssertThrowsError(try WidgetSnapshotCodec.encode(negative)) { error in
            XCTAssertEqual(error as? WidgetSnapshotCodec.CodecError,
                           .outOfRange("fiveHour.usedAmount"))
        }

        let longSymbol = WidgetQuotaSnapshot(
            writtenAt: now, observedAt: nil, validUntil: nil,
            hubSource: .none, hubState: .unavailable,
            fiveHour: WidgetQuotaSnapshot.Window(remainingPercent: 50, resetsAt: nil,
                                                 usedAmount: 1, limitAmount: 500,
                                                 sourceSymbol: "TOOLONG"),
            sevenDay: nil, monthly: nil, local: nil)
        XCTAssertThrowsError(try WidgetSnapshotCodec.encode(longSymbol)) { error in
            XCTAssertEqual(error as? WidgetSnapshotCodec.CodecError,
                           .outOfRange("fiveHour.sourceSymbol"))
        }

        for literal in ["-1", "\"1\"", "true"] {
            let payload = validPayload(replacing: "\"fiveHour\":null",
                with: "\"fiveHour\":{\"remainingPercent\":50,\"resetsAtMs\":null,\"usedAmount\":\(literal)}")
            XCTAssertThrowsError(try WidgetSnapshotCodec.decode(Data(payload.utf8), now: now),
                                 "usedAmount \(literal) must be rejected")
        }
        let longSymbolPayload = validPayload(replacing: "\"fiveHour\":null",
            with: "\"fiveHour\":{\"remainingPercent\":50,\"resetsAtMs\":null,\"sourceSymbol\":\"TOOLONG\"}")
        XCTAssertThrowsError(try WidgetSnapshotCodec.decode(Data(longSymbolPayload.utf8), now: now))
    }
}

// MARK: - Fixtures

private func validPayload(replacing original: String, with replacement: String) -> String {
    let base = """
    {"schemaVersion":1,"writtenAtMs":1800000000000,"observedAtMs":null,
     "validUntilMs":null,"hubSource":"none","hubState":"unavailable",
     "fiveHour":null,"sevenDay":null,"monthly":null,"local":null}
    """
    return base.replacingOccurrences(of: original, with: replacement)
}
