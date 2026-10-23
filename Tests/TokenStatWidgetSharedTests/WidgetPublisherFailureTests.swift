import Foundation
import XCTest
@testable import TokenStatMenu
@testable import TokenStatWidgetShared

/// Failure-path coverage for the publisher. The App Group and WidgetKit are
/// replaced by closures so these cases run in an unsigned test process.
@MainActor
final class WidgetPublisherFailureTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testFailedWriteRetriesOnlyAfterTheInterval() {
        var now = start
        var attempts = 0
        var reloads = 0
        let publisher = WidgetSnapshotPublisher(
            now: { now },
            channelAvailable: { true },
            claim: { nil },
            write: { _, _ in
                attempts += 1
                throw WidgetSnapshotStore.StoreError.ioFailure
            },
            reload: { reloads += 1 })
        let value = snapshot(50)

        XCTAssertFalse(publisher.publish(value))
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(publisher.lastPublishSucceeded)

        now = start.addingTimeInterval(30)
        XCTAssertFalse(publisher.publish(value))
        XCTAssertEqual(attempts, 1, "an identical failed payload waits for the retry interval")

        now = start.addingTimeInterval(60)
        XCTAssertFalse(publisher.publish(value))
        XCTAssertEqual(attempts, 2, "the interval expiry retries the same payload")
        XCTAssertEqual(reloads, 0, "a failed write never asks WidgetKit to reload")
    }

    func testFailedWriteRetriesImmediatelyWhenValuesChange() {
        var now = start
        var attempts = 0
        let publisher = WidgetSnapshotPublisher(
            now: { now },
            channelAvailable: { true },
            claim: { nil },
            write: { _, _ in
                attempts += 1
                throw WidgetSnapshotStore.StoreError.ioFailure
            },
            reload: {})

        XCTAssertFalse(publisher.publish(snapshot(50)))
        XCTAssertEqual(attempts, 1)
        now = start.addingTimeInterval(30)
        XCTAssertFalse(publisher.publish(snapshot(40)))
        XCTAssertEqual(attempts, 2, "changed values are not throttled by a previous failure")
    }

    func testResetOwnershipForgetsTheFailedAttempt() {
        var now = start
        var attempts = 0
        let publisher = WidgetSnapshotPublisher(
            now: { now },
            channelAvailable: { true },
            claim: { nil },
            write: { _, _ in
                attempts += 1
                throw WidgetSnapshotStore.StoreError.ioFailure
            },
            reload: {})
        let value = snapshot(50)

        XCTAssertFalse(publisher.publish(value))
        XCTAssertFalse(publisher.publish(value))
        XCTAssertEqual(attempts, 1)
        publisher.resetOwnership()
        XCTAssertFalse(publisher.publish(value))
        XCTAssertEqual(attempts, 2, "reset drops the failed payload and retries immediately")
    }

    func testRecoveredWriteReloadsEvenWhenValuesAreUnchanged() {
        var now = start
        var attempts = 0
        var reloads = 0
        let publisher = WidgetSnapshotPublisher(
            now: { now },
            channelAvailable: { true },
            claim: { nil },
            write: { _, _ in
                attempts += 1
                if attempts == 1 { throw WidgetSnapshotStore.StoreError.ioFailure }
                return WidgetSnapshotStore.Ownership(
                    device: 1, inode: UInt64(attempts), size: 1, digest: "synthetic")
            },
            reload: { reloads += 1 })
        let value = snapshot(50)

        XCTAssertFalse(publisher.publish(value))
        now = start.addingTimeInterval(60)
        XCTAssertTrue(publisher.publish(value))
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(publisher.lastPublishSucceeded)
        XCTAssertEqual(reloads, 1, "a recovered write must refresh the widget")
        publisher.resetOwnership()
        XCTAssertFalse(publisher.lastPublishSucceeded, "reset cannot retain success from an earlier channel")
    }

    func testFailureReclaimsTheCurrentFileBeforeRetrying() {
        var now = start
        var claims = 0
        var attempts = 0
        var sawOwnership: [Bool] = []
        let owned = WidgetSnapshotStore.Ownership(
            device: 1, inode: 2, size: 3, digest: "synthetic")
        let publisher = WidgetSnapshotPublisher(
            now: { now },
            channelAvailable: { true },
            claim: { claims += 1; return owned },
            write: { _, ownership in
                attempts += 1
                sawOwnership.append(ownership != nil)
                if attempts == 1 { throw WidgetSnapshotStore.StoreError.ioFailure }
                return owned
            },
            reload: {})
        let value = snapshot(50)

        XCTAssertFalse(publisher.publish(value))
        XCTAssertEqual(claims, 1)
        now = start.addingTimeInterval(60)
        XCTAssertTrue(publisher.publish(value))
        XCTAssertEqual(claims, 2, "a failed write drops the inode proof and claims again")
        XCTAssertEqual(sawOwnership, [true, true])
    }

    func testThrottledReloadIsDeliveredOnALaterTick() {
        var now = start
        var reloads = 0
        let owned = WidgetSnapshotStore.Ownership(
            device: 1, inode: 1, size: 1, digest: "synthetic")
        let publisher = WidgetSnapshotPublisher(
            now: { now },
            channelAvailable: { true },
            claim: { nil },
            write: { _, _ in owned },
            reload: { reloads += 1 })

        XCTAssertTrue(publisher.publish(snapshot(50)))
        XCTAssertEqual(reloads, 1)
        now = start.addingTimeInterval(30)
        XCTAssertTrue(publisher.publish(snapshot(40)))
        XCTAssertEqual(reloads, 1, "a changed value inside the gate only queues a reload")
        now = start.addingTimeInterval(60)
        XCTAssertFalse(publisher.publish(snapshot(40)))
        XCTAssertEqual(reloads, 2, "the queued reload is delivered when the gate opens")
    }

    func testUnavailableChannelNeverCallsWriteOrReload() {
        var attempts = 0
        var reloads = 0
        let publisher = WidgetSnapshotPublisher(
            now: { self.start },
            channelAvailable: { false },
            claim: { nil },
            write: { _, _ in
                attempts += 1
                throw WidgetSnapshotStore.StoreError.unavailable
            },
            reload: { reloads += 1 })

        XCTAssertFalse(publisher.publish(snapshot(50)))
        XCTAssertFalse(publisher.isChannelAvailable)
        XCTAssertTrue(publisher.channelUnavailable)
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(reloads, 0)
    }

    func testDiagnosticStateTracksFailuresRecoveryAndReset() {
        var available = true
        let owned = WidgetSnapshotStore.Ownership(device: 1, inode: 1, size: 1, digest: "synthetic")
        let publisher = WidgetSnapshotPublisher(now: { self.start },
            channelAvailable: { available }, claim: { nil }, write: { _, _ in owned }, reload: {})
        XCTAssertTrue(publisher.publish(snapshot(50)))
        XCTAssertTrue(publisher.lastPublishSucceeded)
        XCTAssertFalse(publisher.publish(snapshot(.nan)))
        XCTAssertFalse(publisher.lastPublishSucceeded)
        XCTAssertTrue(publisher.publish(snapshot(40)))
        available = false
        XCTAssertFalse(publisher.publish(snapshot(40)))
        XCTAssertFalse(publisher.lastPublishSucceeded)
        XCTAssertTrue(publisher.channelUnavailable)
        available = true
        XCTAssertTrue(publisher.publish(snapshot(30)))
        XCTAssertTrue(publisher.lastPublishSucceeded)
        XCTAssertFalse(publisher.channelUnavailable)
        available = false
        XCTAssertFalse(publisher.publish(snapshot(30)))
        publisher.resetOwnership()
        XCTAssertFalse(publisher.lastPublishSucceeded)
        XCTAssertFalse(publisher.channelUnavailable)
    }

    private func snapshot(_ percent: Double) -> WidgetQuotaSnapshot {
        WidgetQuotaSnapshot(
            writtenAt: start, observedAt: start,
            validUntil: start.addingTimeInterval(300),
            hubSource: .direct, hubState: .ready,
            fiveHour: WidgetQuotaSnapshot.Window(remainingPercent: percent, resetsAt: nil),
            sevenDay: nil, monthly: nil, local: nil)
    }
}
