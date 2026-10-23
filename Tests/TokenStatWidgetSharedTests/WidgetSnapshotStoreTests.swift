import Darwin
import Foundation
import XCTest
@testable import TokenStatWidgetShared

/// Degradation coverage for the shared App Group channel.
///
/// A real App Group needs a matching entitlement from a real signing identity.
/// An ad-hoc signed development build has none, so every entry point must fail
/// closed instead of inventing a fallback directory or returning a fake value.
final class WidgetSnapshotStoreTests: XCTestCase {

    /// In a test bundle `TokenStatWidgetGroup` is absent, so the configured
    /// group is nil and the container must be reported unavailable. This is the
    /// same path an ad-hoc signed app takes at runtime.
    func testContainerIsUnavailableWithoutConfiguredGroup() {
        XCTAssertNil(WidgetSnapshotStore.configuredGroup())
        XCTAssertFalse(WidgetSnapshotStore.isAvailable())
    }

    func testReadFailsClosedWhenContainerIsUnavailable() {
        XCTAssertThrowsError(try WidgetSnapshotStore.read()) { error in
            XCTAssertEqual(error as? WidgetSnapshotStore.StoreError,
                           WidgetSnapshotStore.StoreError.unavailable)
        }
    }

    func testWriteFailsClosedWhenContainerIsUnavailable() {
        let snapshot = WidgetQuotaSnapshot(writtenAt: Date(), observedAt: nil,
            validUntil: nil, hubSource: .none, hubState: .unavailable,
            fiveHour: nil, sevenDay: nil, monthly: nil, local: nil)
        XCTAssertThrowsError(try WidgetSnapshotStore.write(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? WidgetSnapshotStore.StoreError,
                           WidgetSnapshotStore.StoreError.unavailable)
        }
    }

    func testClaimExistingIsNilWhenContainerIsUnavailable() {
        XCTAssertNil(WidgetSnapshotStore.claimExisting())
    }

    func testAcceptedGroupRequiresGroupPrefix() {
        XCTAssertEqual(WidgetSnapshotStore.acceptedGroup(" group.tokenstat.menu "),
                       "group.tokenstat.menu")
        XCTAssertNil(WidgetSnapshotStore.acceptedGroup(""))
        XCTAssertNil(WidgetSnapshotStore.acceptedGroup("$(TOKENSTAT_WIDGET_GROUP)"))
        XCTAssertNil(WidgetSnapshotStore.acceptedGroup("com.seasun.tokenhub.desktop"))
        XCTAssertNil(WidgetSnapshotStore.acceptedGroup(String(repeating: "a", count: 129)))
    }

    func testDirectoryWriteCreatesThenReplacesOnlyOwnedBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstat-widget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dirfd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(dirfd, 0)
        defer { close(dirfd) }

        let first = Data("{\"schemaVersion\":1}".utf8)
        let owned = try WidgetSnapshotStore.write(first, replacing: nil, directory: dirfd)
        XCTAssertThrowsError(try WidgetSnapshotStore.write(Data("second".utf8), replacing: nil, directory: dirfd)) { error in
            XCTAssertEqual(error as? WidgetSnapshotStore.StoreError, .existingObject)
        }
        let second = Data("{\"schemaVersion\":1,\"next\":2}".utf8)
        let replaced = try WidgetSnapshotStore.write(second, replacing: owned, directory: dirfd)
        XCTAssertNotEqual(replaced.inode, owned.inode)
        let written = try Data(contentsOf: root.appendingPathComponent("widget-snapshot-v1.json"))
        XCTAssertEqual(written, second)
        var metadata = stat()
        XCTAssertEqual(stat(root.appendingPathComponent("widget-snapshot-v1.json").path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
    }

    func testStaleTemporaryFileDoesNotBlockTheNextWrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstat-widget-tmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent("widget-snapshot-v1.json.tmp")
        try Data("partial".utf8).write(to: stale)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stale.path)
        let dirfd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(dirfd) }
        let owned = try WidgetSnapshotStore.write(Data("complete".utf8), replacing: nil, directory: dirfd)
        XCTAssertGreaterThan(owned.size, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }
}
