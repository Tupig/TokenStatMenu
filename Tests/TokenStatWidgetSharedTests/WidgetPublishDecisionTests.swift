import Foundation
import XCTest
@testable import TokenStatMenu

/// The publish gate must be testable without an App Group or WidgetKit.
/// A missing channel returns before this decision, so these cases call it directly.
final class WidgetPublishDecisionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testChangedValuesWriteAndReload() {
        let decision = WidgetSnapshotPublisher.decidePublish(
            sameValues: false, lastWriteAt: nil, lastReloadAt: nil, now: start)
        XCTAssertTrue(decision.shouldWrite)
        XCTAssertTrue(decision.shouldReload)
    }

    func testUnchangedValuesInsideIntervalDoNothing() {
        let decision = WidgetSnapshotPublisher.decidePublish(
            sameValues: true, lastWriteAt: start, lastReloadAt: start,
            now: start.addingTimeInterval(59))
        XCTAssertFalse(decision.shouldWrite)
        XCTAssertFalse(decision.shouldReload)
    }

    func testUnchangedValuesAfterIntervalRefreshClockWithoutReload() {
        let decision = WidgetSnapshotPublisher.decidePublish(
            sameValues: true, lastWriteAt: start, lastReloadAt: start,
            now: start.addingTimeInterval(60))
        XCTAssertTrue(decision.shouldWrite)
        XCTAssertFalse(decision.shouldReload)
    }

    func testChangedValuesInsideReloadIntervalWriteWithoutAnotherReload() {
        let decision = WidgetSnapshotPublisher.decidePublish(
            sameValues: false, lastWriteAt: start, lastReloadAt: start,
            now: start.addingTimeInterval(30))
        XCTAssertTrue(decision.shouldWrite)
        XCTAssertFalse(decision.shouldReload)
    }
}
