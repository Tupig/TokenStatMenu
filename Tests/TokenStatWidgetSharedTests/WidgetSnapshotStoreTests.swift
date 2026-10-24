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

    func testFIFOAndOtherUnsafeReadObjectsFailWithoutBlocking() throws {
        for kind in ["missing", "fifo", "directory", "symlink", "empty", "mode", "hardlink", "large", "malformed"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let path = root.appendingPathComponent(WidgetSnapshotStore.fileName)
            switch kind {
            case "missing": break
            case "fifo": XCTAssertEqual(mkfifo(path.path, 0o600), 0)
            case "directory": try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            case "symlink": XCTAssertEqual(symlink("missing-target", path.path), 0)
            default:
                let bytes = kind == "empty" ? Data() : Data(repeating: 65, count: kind == "large" ? WidgetSnapshotCodec.maximumBytes + 1 : 5)
                try bytes.write(to: path)
                XCTAssertEqual(chmod(path.path, kind == "mode" ? 0o644 : 0o600), 0)
                if kind == "hardlink" { XCTAssertEqual(link(path.path, root.appendingPathComponent("alias").path), 0) }
            }
            let dirfd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            defer { close(dirfd) }
            let start = Date()
            XCTAssertNil(try? WidgetSnapshotStore.read(directory: dirfd), kind)
            if kind != "malformed" { XCTAssertNil(WidgetSnapshotStore.claimExisting(directory: dirfd), kind) }
            XCTAssertLessThan(Date().timeIntervalSince(start), 1, "无写端 FIFO 不得阻塞")
        }
    }

    func testMetadataRejectsWrongOwnerWithoutPrivilegedIO() {
        var metadata = stat()
        metadata.st_mode = mode_t(S_IFREG | 0o600)
        metadata.st_uid = getuid(); metadata.st_nlink = 1; metadata.st_size = 5
        XCTAssertTrue(WidgetSnapshotStore.isSafeMetadata(metadata, maximumBytes: 10))
        metadata.st_uid = getuid() == 0 ? 1 : 0
        XCTAssertFalse(WidgetSnapshotStore.isSafeMetadata(metadata, maximumBytes: 10))
        metadata.st_uid = getuid(); metadata.st_nlink = 2
        XCTAssertFalse(WidgetSnapshotStore.isSafeMetadata(metadata, maximumBytes: 10))
        metadata.st_nlink = 1; metadata.st_mode = mode_t(S_IFREG | 0o644)
        XCTAssertFalse(WidgetSnapshotStore.isSafeMetadata(metadata, maximumBytes: 10))
    }

    func testRestartClaimReplacesSafeFileAndRejectsUnsafeObjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dirfd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(dirfd) }
        XCTAssertNil(WidgetSnapshotStore.claimExisting(directory: dirfd))
        let first = try WidgetSnapshotStore.write(Data("first".utf8), replacing: nil, directory: dirfd)
        let claimed = try XCTUnwrap(WidgetSnapshotStore.claimExisting(directory: dirfd))
        XCTAssertEqual(claimed, first)
        let second = try WidgetSnapshotStore.write(Data("second".utf8), replacing: claimed, directory: dirfd)
        XCTAssertEqual(WidgetSnapshotStore.claimExisting(directory: dirfd), second)
        let path = root.appendingPathComponent("widget-snapshot-v1.json")
        XCTAssertEqual(chmod(path.path, 0o644), 0)
        XCTAssertNil(WidgetSnapshotStore.claimExisting(directory: dirfd))
        XCTAssertEqual(chmod(path.path, 0o600), 0)
        XCTAssertEqual(link(path.path, root.appendingPathComponent("alias").path), 0)
        XCTAssertNil(WidgetSnapshotStore.claimExisting(directory: dirfd))
    }

    func testReplacementRejectsChangedModeLinksIdentityAndBytes() throws {
        for mutation in ["mode", "hardlink", "inode", "bytes", "missing"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let dirfd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(dirfd, 0)
            defer { close(dirfd) }
            let path = root.appendingPathComponent("widget-snapshot-v1.json")
            let first = Data("first".utf8)
            let owned = try WidgetSnapshotStore.write(first, replacing: nil, directory: dirfd)
            switch mutation {
            case "mode": XCTAssertEqual(chmod(path.path, 0o644), 0)
            case "hardlink": XCTAssertEqual(link(path.path, root.appendingPathComponent("alias").path), 0)
            case "inode":
                let other = root.appendingPathComponent("other")
                try first.write(to: other)
                XCTAssertEqual(chmod(other.path, 0o600), 0)
                XCTAssertEqual(rename(other.path, path.path), 0)
            case "bytes":
                let fd = open(path.path, O_WRONLY | O_NOFOLLOW)
                XCTAssertGreaterThanOrEqual(fd, 0)
                defer { close(fd) }
                let changed = Array("other".utf8)
                XCTAssertEqual(changed.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }, 5)
            default: XCTAssertEqual(unlink(path.path), 0)
            }
            let before = try? Data(contentsOf: path)
            XCTAssertThrowsError(try WidgetSnapshotStore.write(Data("new".utf8), replacing: owned, directory: dirfd), mutation)
            XCTAssertEqual(try? Data(contentsOf: path), before, "拒绝不能覆盖对象：\(mutation)")
        }
    }

    func testUnsafeTemporaryLinksArePreservedAndBlockWrite() throws {
        for hardlink in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("target")
            let temporary = root.appendingPathComponent("widget-snapshot-v1.json.tmp")
            try Data("keep".utf8).write(to: target)
            if hardlink { XCTAssertEqual(link(target.path, temporary.path), 0) }
            else { XCTAssertEqual(symlink(target.path, temporary.path), 0) }
            let dirfd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            defer { close(dirfd) }
            XCTAssertThrowsError(try WidgetSnapshotStore.write(Data("new".utf8), replacing: nil, directory: dirfd))
            XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
            var metadata = stat()
            XCTAssertEqual(lstat(temporary.path, &metadata), 0)
        }
    }

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

    func testAcceptedGroupSupportsRegisteredAndMacOSTeamFormats() {
        XCTAssertEqual(WidgetSnapshotStore.acceptedGroup(" group.tokenstat.menu "),
                       "group.tokenstat.menu")
        XCTAssertNil(WidgetSnapshotStore.acceptedGroup(""))
        XCTAssertNil(WidgetSnapshotStore.acceptedGroup("$(TOKENSTAT_WIDGET_GROUP)"))
        XCTAssertNil(WidgetSnapshotStore.acceptedGroup("com.seasun.tokenhub.desktop"))
        XCTAssertEqual(WidgetSnapshotStore.acceptedGroup("AB12CD34EF.com.example.TokenStatMenu"),
                       "AB12CD34EF.com.example.TokenStatMenu")
        for invalid in ["group.", "group.a..b", "group.a/../b", "group.-a", "group.a-", "group.a.-b", "group.a-.b", "FICTEAM123.example",
                        "ab12cd34ef.example", "AB12CD34E.example", "AB12CD34EF."] {
            XCTAssertNil(WidgetSnapshotStore.acceptedGroup(invalid), invalid)
        }
        XCTAssertNil(WidgetSnapshotStore.acceptedGroup(String(repeating: "a", count: 129)))
    }

    func testAcceptedGroupLengthBoundaryHasOtherwiseValidShape() {
        for prefix in ["group.", "AB12CD34EF."] {
            let accepted = prefix + String(repeating: "a", count: 128 - prefix.count)
            XCTAssertEqual(accepted.count, 128)
            XCTAssertEqual(WidgetSnapshotStore.acceptedGroup(accepted), accepted)
            XCTAssertNil(WidgetSnapshotStore.acceptedGroup(accepted + "a"),
                         "129字符仍有合法前缀和分段，必须仅因长度拒绝")
        }
        // UNRESOLVED 本身是10位大写字母，形状可通过Team前缀校验，
        // 必须由明确的构建占位符门禁拒绝，不能用非法前缀冒充覆盖。
        XCTAssertNil(WidgetSnapshotStore.acceptedGroup("UNRESOLVED.example"))
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
