import Foundation
import XCTest
import TokenStatWidgetShared

/// B3 boundary cases for the closed v2 state wire shape. These use synthetic
/// bytes only and do not depend on WidgetKit, App Group storage, or a baseline.
final class WidgetQuotaStateStrictnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testV2AcceptsNullAndIntegerStateResetsWithExactFieldAssociation() throws {
        let states = #"{"fiveHour":{"kind":"unlimited","resetsAtMs":0},"sevenDay":{"kind":"exceeded","resetsAtMs":1800000001000},"monthly":null}"#
        let snapshot = try WidgetSnapshotCodec.decode(payload(states: states), now: now)
        XCTAssertEqual(snapshot.states[.fiveHour], .unlimited(resetAt: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(snapshot.states[.sevenDay], .exceeded(resetAt: now.addingTimeInterval(1)))
        XCTAssertNil(snapshot.states[.monthly])
    }

    func testV2RejectsUnknownVersionAndWrongRootValueTypes() {
        for version in ["3", "1.5", "\"2\"", "true", "-1"] {
            XCTAssertThrowsError(try WidgetSnapshotCodec.decode(
                payload(states: nullStates, version: version), now: now),
                "unsupported schema version must fail closed: \(version)")
        }
        for states in ["null", "[]", "\"bad\"", "0", "true"] {
            XCTAssertThrowsError(try WidgetSnapshotCodec.decode(payload(states: states), now: now),
                                 "states root must be a closed object: \(states)")
        }
        for field in ["hubSource", "hubState"] {
            let value = field == "hubSource" ? "0" : "true"
            let root = String(decoding: payload(states: nullStates), as: UTF8.self)
            let data = root.replacingOccurrences(
                of: "\"\(field)\":\"\(field == "hubSource" ? "direct" : "ready")\"",
                with: "\"\(field)\":\(value)")
            XCTAssertThrowsError(try WidgetSnapshotCodec.decode(Data(data.utf8), now: now),
                                 "root \(field) does not coerce bool/number values")
        }
    }

    func testV2RejectsMissingExtraAndMalformedStateEntries() {
        let invalidStateObjects = [
            #"{"fiveHour":null,"sevenDay":null}"#,
            #"{"fiveHour":null,"sevenDay":null,"monthly":null,"other":null}"#,
            #"{"fiveHour":0,"sevenDay":null,"monthly":null}"#,
            #"{"fiveHour":"unlimited","sevenDay":null,"monthly":null}"#,
            #"{"fiveHour":{"resetsAtMs":null},"sevenDay":null,"monthly":null}"#,
            #"{"fiveHour":{"kind":"unlimited"},"sevenDay":null,"monthly":null}"#,
            #"{"fiveHour":{"kind":true,"resetsAtMs":null},"sevenDay":null,"monthly":null}"#,
            #"{"fiveHour":{"kind":"unknown","resetsAtMs":null},"sevenDay":null,"monthly":null}"#,
            #"{"fiveHour":{"kind":"unlimited","resetsAtMs":null,"extra":1},"sevenDay":null,"monthly":null}"#,
        ]
        for states in invalidStateObjects {
            XCTAssertThrowsError(try WidgetSnapshotCodec.decode(payload(states: states), now: now), states)
        }
        for timestamp in ["true", "1.5", "\"1800000000000\"", "-1", "253402300800000"] {
            let states = #"{"fiveHour":{"kind":"exceeded","resetsAtMs":__VALUE__},"sevenDay":null,"monthly":null}"#
                .replacingOccurrences(of: "__VALUE__", with: timestamp)
            XCTAssertThrowsError(try WidgetSnapshotCodec.decode(payload(states: states), now: now),
                                 "invalid state reset milliseconds reject: \(timestamp)")
        }
    }

    func testV2RejectsUnlimitedNumericConflictAndMismatchedResetClocks() {
        let unlimited = #"{"fiveHour":{"kind":"unlimited","resetsAtMs":null},"sevenDay":null,"monthly":null}"#
        let numeric = #"{"remainingPercent":50,"resetsAtMs":null}"#
        XCTAssertThrowsError(try WidgetSnapshotCodec.decode(
            payload(states: unlimited, fiveHour: numeric), now: now),
            "unlimited cannot coexist with a numeric value")

        let exceeded = #"{"fiveHour":null,"sevenDay":{"kind":"exceeded","resetsAtMs":1800000001000},"monthly":null}"#
        let mismatchedWindow = #"{"remainingPercent":0,"resetsAtMs":1800000002000,"usedAmount":120,"limitAmount":100,"sourceSymbol":"🪙"}"#
        XCTAssertThrowsError(try WidgetSnapshotCodec.decode(
            payload(states: exceeded, sevenDay: mismatchedWindow), now: now),
            "state and numeric window must share a reset boundary")
    }

    func testB5MonthlyResetWireIsOptionalTypedAndStateConsistent() throws {
        let monthly = #"{"usedAmount":25.5,"limitAmount":100,"sourceSymbol":"🪙","resetsAtMs":1800000060000}"#
        let matchingStates = #"{"fiveHour":null,"sevenDay":null,"monthly":{"kind":"exceeded","resetsAtMs":1800000060000}}"#
        XCTAssertNoThrow(try WidgetSnapshotCodec.decode(
            payload(states: matchingStates, monthly: monthly), now: now),
            "matching monthly numeric and state resets are valid")

        let mismatchedStates = #"{"fiveHour":null,"sevenDay":null,"monthly":{"kind":"exceeded","resetsAtMs":1800000061000}}"#
        XCTAssertThrowsError(try WidgetSnapshotCodec.decode(
            payload(states: mismatchedStates, monthly: monthly), now: now),
            "monthly numeric and state reset disagreement fails closed")

        for value in ["true", "1.5", "\"later\"", "-1", "253402300800000"] {
            let wire = #"{"usedAmount":25.5,"limitAmount":100,"sourceSymbol":"🪙","resetsAtMs":__VALUE__}"#
                .replacingOccurrences(of: "__VALUE__", with: value)
            XCTAssertThrowsError(try WidgetSnapshotCodec.decode(
                payload(states: nullStates, monthly: wire), now: now),
                "monthly reset must be an integer finite timestamp: \(value)")
        }

        let extraKey = #"{"usedAmount":25.5,"limitAmount":100,"sourceSymbol":"🪙","resetsAtMs":null,"extra":1}"#
        XCTAssertThrowsError(try WidgetSnapshotCodec.decode(
            payload(states: nullStates, monthly: extraKey), now: now),
            "v2 monthly remains a closed object when reset is added")
        let nullReset = #"{"usedAmount":25.5,"limitAmount":100,"sourceSymbol":"🪙","resetsAtMs":null}"#
        XCTAssertNil(try WidgetSnapshotCodec.decode(
            payload(states: nullStates, monthly: nullReset), now: now).monthly?.resetsAt,
            "explicit null monthly reset is unknown")

        let v1WithNewKey = Data("""
        {"schemaVersion":1,"writtenAtMs":1800000000000,"observedAtMs":null,
         "validUntilMs":null,"hubSource":"direct","hubState":"ready",
         "fiveHour":null,"sevenDay":null,
         "monthly":{\"usedAmount\":25.5,\"limitAmount\":100,\"sourceSymbol\":\"🪙\",\"resetsAtMs\":1800000060000},
         "local":null}
        """.utf8)
        XCTAssertThrowsError(try WidgetSnapshotCodec.decode(v1WithNewKey, now: now),
            "legacy v1 does not accept a v2-only monthly reset member")
    }

    private var nullStates: String {
        #"{"fiveHour":null,"sevenDay":null,"monthly":null}"#
    }

    private func payload(states: String, version: String = "2",
                         fiveHour: String = "null", sevenDay: String = "null",
                         monthly: String = "null") -> Data {
        Data("""
        {"schemaVersion":\(version),"writtenAtMs":1800000000000,
         "observedAtMs":1800000000000,"validUntilMs":1800000120000,
         "hubSource":"direct","hubState":"ready",
         "fiveHour":\(fiveHour),"sevenDay":\(sevenDay),"monthly":\(monthly),"local":null,
         "resetVoucherCount":null,"states":\(states)}
        """.utf8)
    }
}
