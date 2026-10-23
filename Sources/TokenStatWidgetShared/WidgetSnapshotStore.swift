import Foundation
import Darwin

/// App Group container access for the shared widget snapshot.
///
/// The container is only reachable when both processes carry a matching
/// `com.apple.security.application-groups` entitlement from a real signing
/// identity. Under an ad-hoc signature the system refuses the container, so
/// every entry point reports `.unavailable` instead of falling back to a
/// user-private directory. That keeps a development build honest: it can build
/// and run, but it cannot pretend the shared channel works.
public enum WidgetSnapshotStore {

    /// Group name shared by the app and its embedded extension.
    ///
    /// The distribution build replaces this placeholder through the
    /// `TOKENSTAT_WIDGET_GROUP` build setting; a bundle that still carries the
    /// placeholder has no usable channel.
    public static let groupIdentifierKey = "TokenStatWidgetGroup"
    public static let fileName = "widget-snapshot-v1.json"
    public static let temporaryName = "widget-snapshot-v1.json.tmp"

    public enum StoreError: Error, Equatable {
        /// No App Group container: unsigned, ad-hoc signed, or wrong entitlement.
        case unavailable
        /// A pre-existing object this process did not author; it is never read.
        case existingObject
        /// A path component or file metadata violated the accepted shape.
        case unsafeObject
        case ioFailure
    }

    /// A file identity frozen after this process created it, so a later write
    /// can prove it is replacing its own previous output.
    public struct Ownership: Equatable, Sendable {
        public let device: UInt64
        public let inode: UInt64
        public let size: Int64
        public let digest: String
    }

    // MARK: - Group resolution

    /// Reads the configured group from the bundle's Info.plist. Only a plain
    /// Team-prefixed or `group.` name is accepted; build variables that never
    /// resolved, and placeholders, are rejected.
    public static func configuredGroup(bundle: Bundle = .main) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: groupIdentifierKey) as? String else {
            return nil
        }
        return acceptedGroup(raw)
    }

    /// The only accepted App Group spelling. Exposed so tests can reject a
    /// third-party bundle identifier without touching a real container.
    public static func acceptedGroup(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 128,
              !value.contains("$("), !value.contains(")"),
              !value.hasPrefix("UNRESOLVED"), !value.hasPrefix("FICTEAM") else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        // A bare dotted name such as another app's bundle identifier is not an
        // App Group. Accept only the `group.` form this project publishes.
        guard value.hasPrefix("group.") else { return nil }
        return value
    }

    /// Resolves the group container, or nil when the system denies it.
    public static func containerURL(bundle: Bundle = .main) -> URL? {
        guard let group = configuredGroup(bundle: bundle) else { return nil }
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group),
            url.isFileURL else { return nil }
        return url
    }

    /// True when a real App Group channel is available in this process.
    public static func isAvailable(bundle: Bundle = .main) -> Bool {
        containerURL(bundle: bundle) != nil
    }

    // MARK: - Reading

    /// Claims an existing file written by an earlier run, so a restart can keep
    /// replacing it instead of failing forever on the "unknown pre-existing
    /// object" guard.
    ///
    /// The claim only succeeds after the same safety checks a read performs:
    /// owned by this user, a single link, and mode 0600. It never reads or
    /// rewrites a file that fails them, and it proves nothing about who wrote
    /// it before this process; it only establishes the identity needed to
    /// replace it going forward.
    /// - Returns: the identity to pass to `write(replacing:)`, or nil when no
    ///   claimable file is present.
    public static func claimExisting(bundle: Bundle = .main) -> Ownership? {
        guard let url = containerURL(bundle: bundle) else { return nil }
        var metadata = stat()
        let path = url.appendingPathComponent(fileName, isDirectory: false).path
        guard lstat(path, &metadata) == 0 else { return nil }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o777 == 0o600,
              metadata.st_size > 0,
              metadata.st_size <= WidgetSnapshotCodec.maximumBytes else { return nil }
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
        var after = stat()
        guard lstat(path, &after) == 0,
              after.st_dev == metadata.st_dev,
              after.st_ino == metadata.st_ino,
              after.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec,
              after.st_size == metadata.st_size else { return nil }
        return Ownership(device: UInt64(metadata.st_dev),
                         inode: UInt64(metadata.st_ino),
                         size: Int64(metadata.st_size),
                         digest: digest(data))
    }

    /// Reads the shared snapshot. A missing file is reported as `nil` so the
    /// widget can show "no data" rather than an error.
    public static func read(bundle: Bundle = .main) throws -> WidgetQuotaSnapshot? {
        let dirfd = try openContainer(bundle: bundle)
        defer { close(dirfd) }
        var metadata = stat()
        guard fstatat(dirfd, fileName, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw StoreError.ioFailure
        }
        let fd = openat(dirfd, fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.unsafeObject }
        defer { close(fd) }
        try requireSafe(fd, maximumBytes: WidgetSnapshotCodec.maximumBytes)
        let data = try readAll(fd, maximumBytes: WidgetSnapshotCodec.maximumBytes)
        return try? WidgetSnapshotCodec.decode(data)
    }

    // MARK: - Writing

    /// Atomically replaces the shared snapshot and returns its frozen identity.
    ///
    /// The write is a temporary file plus `renameat`, so a reader never sees a
    /// half-written payload. An existing file that this process cannot prove it
    /// authored is left untouched.
    @discardableResult
    public static func write(_ data: Data,
                             replacing expected: Ownership? = nil,
                             bundle: Bundle = .main) throws -> Ownership {
        let dirfd = try openContainer(bundle: bundle)
        defer { close(dirfd) }
        return try write(data, replacing: expected, directory: dirfd)
    }

    /// Writes into an already opened directory. Tests use a temporary directory
    /// so the ownership, mode and replacement rules can run without an App Group.
    static func write(_ data: Data, replacing expected: Ownership?,
                      directory dirfd: Int32) throws -> Ownership {
        guard !data.isEmpty, data.count <= WidgetSnapshotCodec.maximumBytes else {
            throw StoreError.unsafeObject
        }

        var existing = stat()
        let present = fstatat(dirfd, fileName, &existing, AT_SYMLINK_NOFOLLOW) == 0
        if present {
            // Without an ownership proof we do not open, read or replace an
            // object of unknown origin.
            guard let expected else { throw StoreError.existingObject }
            try requireOwned(dirfd, expected: expected)
        } else if errno != ENOENT {
            throw StoreError.ioFailure
        } else if expected != nil {
            // The caller promised to replace its own file, but it is gone.
            throw StoreError.existingObject
        }

        let temporary = try writeTemporary(data, dirfd: dirfd)
        var moved = false
        do {
            try requireTemporary(temporary, dirfd: dirfd)
            if present {
                guard let expected else { throw StoreError.existingObject }
                try requireOwned(dirfd, expected: expected)
                guard renameat(dirfd, temporaryName, dirfd, fileName) == 0 else {
                    throw StoreError.ioFailure
                }
            } else {
                guard renameatx_np(dirfd, temporaryName, dirfd, fileName,
                                    UInt32(RENAME_EXCL)) == 0 else {
                    throw StoreError.existingObject
                }
            }
            moved = true
            guard fsync(dirfd) == 0 else { throw StoreError.ioFailure }
            close(temporary.fd)
            return temporary.ownership
        } catch {
            defer { close(temporary.fd) }
            if !moved { try? removeTemporary(temporary, dirfd: dirfd) }
            throw error
        }
    }

    // MARK: - Container

    private static func openContainer(bundle: Bundle) throws -> Int32 {
        guard let url = containerURL(bundle: bundle) else { throw StoreError.unavailable }
        let components = url.standardizedFileURL.pathComponents
        guard components.first == "/", components.count > 1 else { throw StoreError.unsafeObject }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw StoreError.ioFailure }
        do {
            for component in components.dropFirst() {
                guard !component.isEmpty, component != ".", component != "..",
                      !component.contains("/") else { throw StoreError.unsafeObject }
                let next = openat(current, component,
                                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw StoreError.unsafeObject }
                close(current)
                current = next
            }
            var info = stat()
            guard fstat(current, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  info.st_uid == getuid() else {
                throw StoreError.unsafeObject
            }
            return current
        } catch {
            close(current)
            throw error
        }
    }

    private struct Pending {
        let fd: Int32
        let ownership: Ownership
    }

    private static func writeTemporary(_ data: Data, dirfd: Int32) throws -> Pending {
        discardStaleTemporary(dirfd)
        let fd = openat(dirfd, temporaryName,
                        O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.existingObject }
        var handedOff = false
        defer { if !handedOff { close(fd) } }
        do {
            try requireSafe(fd, maximumBytes: WidgetSnapshotCodec.maximumBytes, allowEmpty: true)
            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                }
                guard written > 0 else { throw StoreError.ioFailure }
                offset += written
            }
            guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else { throw StoreError.ioFailure }
            var metadata = stat()
            guard fstat(fd, &metadata) == 0 else { throw StoreError.ioFailure }
            let ownership = Ownership(device: UInt64(metadata.st_dev),
                                      inode: UInt64(metadata.st_ino),
                                      size: Int64(metadata.st_size),
                                      digest: digest(data))
            handedOff = true
            return Pending(fd: fd, ownership: ownership)
        }
    }

    private static func requireTemporary(_ pending: Pending, dirfd: Int32) throws {
        var byFD = stat()
        guard fstat(pending.fd, &byFD) == 0,
              UInt64(byFD.st_dev) == pending.ownership.device,
              UInt64(byFD.st_ino) == pending.ownership.inode,
              Int64(byFD.st_size) == pending.ownership.size,
              byFD.st_nlink == 1,
              byFD.st_mode & 0o777 == 0o600 else { throw StoreError.unsafeObject }
        var byName = stat()
        guard fstatat(dirfd, temporaryName, &byName, AT_SYMLINK_NOFOLLOW) == 0,
              UInt64(byName.st_ino) == pending.ownership.inode,
              Int64(byName.st_size) == pending.ownership.size else {
            throw StoreError.unsafeObject
        }
    }

    private static func removeTemporary(_ pending: Pending, dirfd: Int32) throws {
        try requireTemporary(pending, dirfd: dirfd)
        guard unlinkat(dirfd, temporaryName, 0) == 0 else { throw StoreError.existingObject }
    }

    /// Proves the named file is the object the caller previously authored,
    /// without reading an unknown pre-existing payload.
    /// Removes a leftover temporary file only when it is a regular file this
    /// user owns. A symlink, hard link or foreign owner is left untouched.
    private static func discardStaleTemporary(_ dirfd: Int32) {
        var metadata = stat()
        guard fstatat(dirfd, temporaryName, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1 else { return }
        unlinkat(dirfd, temporaryName, 0)
    }

    private static func requireOwned(_ dirfd: Int32, expected: Ownership) throws {
        var metadata = stat()
        guard fstatat(dirfd, fileName, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              UInt64(metadata.st_dev) == expected.device,
              UInt64(metadata.st_ino) == expected.inode,
              Int64(metadata.st_size) == expected.size else { throw StoreError.existingObject }
        let fd = openat(dirfd, fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.existingObject }
        defer { close(fd) }
        let data = try readAll(fd, maximumBytes: WidgetSnapshotCodec.maximumBytes)
        guard digest(data) == expected.digest else { throw StoreError.existingObject }
    }

    private static func requireSafe(_ fd: Int32, maximumBytes: Int,
                                    allowEmpty: Bool = false) throws {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o777 == 0o600,
              metadata.st_size >= 0,
              metadata.st_size <= maximumBytes,
              allowEmpty || metadata.st_size > 0 else { throw StoreError.unsafeObject }
    }

    private static func readAll(_ fd: Int32, maximumBytes: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: maximumBytes)
        var offset = 0
        while offset < maximumBytes {
            let count = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: offset), maximumBytes - offset)
            }
            if count == 0 { break }
            guard count > 0 else { throw StoreError.ioFailure }
            offset += count
        }
        return Data(bytes.prefix(offset))
    }

    private static func digest(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
