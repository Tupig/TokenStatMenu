import Darwin
import CryptoKit
import Foundation

// The development candidate never searches for another container or file.
enum DevWidgetSnapshotStore {
    enum StoreError: Error { case unavailable, existingObject, unsafeObject, ioFailure }

    // Only an independently frozen, previously owned file may be replaced.
    // This value is not inferred by reading an arbitrary pre-existing object.
    struct Ownership: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let digest: String
    }

    private struct Pending {
        let fd: Int32
        let ownership: Ownership
    }

    static func read(io: DevProbeIOAudit = DevProbeIOAudit()) throws -> Data {
        let dirfd = try openContainerDirectory(io: io)
        defer { close(dirfd) }
        try checkDirectory(dirfd)
        io.enteringSnapshotRead()
        let fd = openat(dirfd, DevWidgetIdentity.file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.ioFailure }
        defer { close(fd) }
        let read = try safeRead(fd)
        try requireName(DevWidgetIdentity.file, matches: read.ownership, directory: dirfd)
        return read.data
    }

    // First-generation, no-clobber write only. A later authorized system
    // driver must freeze ownership before any second-generation replacement.
    @discardableResult
    static func writeIfAbsent(_ data: Data,
                              io: DevProbeIOAudit = DevProbeIOAudit()) throws -> Ownership {
        guard data.count > 0, data.count <= 8192 else { throw StoreError.unsafeObject }
        let dirfd = try openContainerDirectory(io: io)
        defer { close(dirfd) }
        return try writeIfAbsent(data, directory: dirfd, io: io)
    }

    // Directory variants let tests exercise the two-generation handoff in a
    // private temporary directory. Production callers always use the container
    // entry point above, so the App Group lookup stays on the real path.
    @discardableResult
    static func writeIfAbsent(_ data: Data, directory dirfd: Int32,
                              io: DevProbeIOAudit = DevProbeIOAudit()) throws -> Ownership {
        guard data.count > 0, data.count <= 8192 else { throw StoreError.unsafeObject }
        try checkDirectory(dirfd)
        var existing = stat()
        guard fstatat(dirfd, DevWidgetIdentity.file, &existing, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT else { throw StoreError.existingObject }
        let pending = try writeTemporary(data, directory: dirfd, io: io)
        var moved = false
        do {
            try checkDirectory(dirfd)
            try validatePending(pending, directory: dirfd)
            guard fstatat(dirfd, DevWidgetIdentity.file, &existing, AT_SYMLINK_NOFOLLOW) != 0,
                  errno == ENOENT else { throw StoreError.existingObject }
            guard renameatx_np(dirfd, DevWidgetIdentity.temporaryFile,
                               dirfd, DevWidgetIdentity.file, UInt32(RENAME_EXCL)) == 0
            else { throw StoreError.existingObject }
            moved = true
            guard fsync(dirfd) == 0 else { throw StoreError.ioFailure }
            close(pending.fd)
            return pending.ownership
        } catch {
            defer { close(pending.fd) }
            // After a rename, there is no owned temporary name to clean up.
            // A failed directory sync leaves the final state uncertain.
            guard !moved else { throw StoreError.existingObject }
            try cleanupPending(pending, directory: dirfd)
            throw error
        }
    }

    // Claims a snapshot this user can safely replace. The proof is the same
    // metadata and byte validation a read performs; it does not claim to know
    // which process wrote the file.
    static func claimExisting(io: DevProbeIOAudit = DevProbeIOAudit()) throws -> Ownership? {
        let dirfd = try openContainerDirectory(io: io)
        defer { close(dirfd) }
        return try claimExisting(directory: dirfd, io: io)
    }

    static func claimExisting(directory dirfd: Int32,
                              io: DevProbeIOAudit = DevProbeIOAudit()) throws -> Ownership? {
        try checkDirectory(dirfd)
        var metadata = stat()
        guard fstatat(dirfd, DevWidgetIdentity.file, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw StoreError.ioFailure
        }
        io.enteringSnapshotRead()
        let fd = openat(dirfd, DevWidgetIdentity.file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.ioFailure }
        defer { close(fd) }
        let read = try safeRead(fd)
        try requireName(DevWidgetIdentity.file, matches: read.ownership, directory: dirfd)
        return read.ownership
    }

    // One container lookup for the whole first-or-second generation decision.
    // Two separate entry points would trip the host's single-lookup audit even
    // though only one file operation is intended.
    @discardableResult
    static func writeFirstOrReplace(_ data: Data,
                                    io: DevProbeIOAudit = DevProbeIOAudit()) throws -> Ownership {
        guard data.count > 0, data.count <= 8192 else { throw StoreError.unsafeObject }
        let dirfd = try openContainerDirectory(io: io)
        defer { close(dirfd) }
        return try writeFirstOrReplace(data, directory: dirfd, io: io)
    }

    @discardableResult
    static func writeFirstOrReplace(_ data: Data, directory dirfd: Int32,
                                    io: DevProbeIOAudit = DevProbeIOAudit()) throws -> Ownership {
        if let existing = try claimExisting(directory: dirfd, io: io) {
            return try replaceIfOwned(data, expected: existing, directory: dirfd, io: io)
        }
        return try writeIfAbsent(data, directory: dirfd, io: io)
    }

    static func replaceIfOwned(_ data: Data, expected: Ownership,
                               io: DevProbeIOAudit = DevProbeIOAudit()) throws -> Ownership {
        guard data.count > 0, data.count <= 8192 else { throw StoreError.unsafeObject }
        let dirfd = try openContainerDirectory(io: io)
        defer { close(dirfd) }
        return try replaceIfOwned(data, expected: expected, directory: dirfd, io: io)
    }

    static func replaceIfOwned(_ data: Data, expected: Ownership, directory dirfd: Int32,
                               io: DevProbeIOAudit = DevProbeIOAudit()) throws -> Ownership {
        guard data.count > 0, data.count <= 8192 else { throw StoreError.unsafeObject }
        try checkDirectory(dirfd)
        try checkExisting(expected, directory: dirfd)
        let pending = try writeTemporary(data, directory: dirfd, io: io)
        var moved = false
        do {
            try checkDirectory(dirfd)
            try validatePending(pending, directory: dirfd)
            try checkExisting(expected, directory: dirfd)
            guard renameat(dirfd, DevWidgetIdentity.temporaryFile,
                           dirfd, DevWidgetIdentity.file) == 0 else { throw StoreError.ioFailure }
            moved = true
            guard fsync(dirfd) == 0 else { throw StoreError.ioFailure }
            close(pending.fd)
            return pending.ownership
        } catch {
            defer { close(pending.fd) }
            guard !moved else { throw StoreError.existingObject }
            try cleanupPending(pending, directory: dirfd)
            throw error
        }
    }

    private static func checkExisting(_ expected: Ownership, directory: Int32) throws {
        // A manifest-provided identity must match metadata before opening or
        // reading any pre-existing bytes. Unknown objects remain untouched.
        try requireName(DevWidgetIdentity.file, matches: expected, directory: directory)
        let fd = openat(directory, DevWidgetIdentity.file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.existingObject }
        defer { close(fd) }
        try requireFD(fd, matches: expected)
        let current = try safeRead(fd)
        guard current.ownership == expected else { throw StoreError.existingObject }
        try requireName(DevWidgetIdentity.file, matches: expected, directory: directory)
    }

    private static func writeTemporary(_ data: Data, directory: Int32,
                                       io: DevProbeIOAudit) throws -> Pending {
        io.enteringSnapshotWrite()
        let fd = openat(directory, DevWidgetIdentity.temporaryFile,
                        O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.existingObject }
        var metadata = stat()
        var pending: Pending?
        var handedOff = false
        defer { if !handedOff { close(fd) } }
        do {
            guard fstat(fd, &metadata) == 0,
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  metadata.st_nlink == 1, metadata.st_uid == getuid() else {
                throw StoreError.unsafeObject
            }
            pending = Pending(fd: fd, ownership: Ownership(
                device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino),
                size: Int64(data.count), digest: digest(data)))
            var offset = 0
            while offset < data.count {
                let count = data.withUnsafeBytes { raw in
                    Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                }
                guard count > 0 else { throw StoreError.ioFailure }
                offset += count
            }
            guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else { throw StoreError.ioFailure }
            try validatePending(pending!, directory: directory)
            handedOff = true
            return pending!
        } catch {
            // A partially written or changed temporary file is preserved.
            // Never unlink solely because this process still holds its FD.
            guard let pending else { throw StoreError.existingObject }
            try cleanupPending(pending, directory: directory)
            throw error
        }
    }

    private static func cleanupPending(_ pending: Pending, directory: Int32) throws {
        // Deletion requires the complete owned after-image, including mode,
        // exact size and hash. A changed name or byte is a fixed conflict.
        do {
            try validatePending(pending, directory: directory)
            guard unlinkat(directory, DevWidgetIdentity.temporaryFile, 0) == 0 else {
                throw StoreError.existingObject
            }
        } catch {
            throw StoreError.existingObject
        }
    }

    private static func validatePending(_ pending: Pending, directory: Int32) throws {
        try requireFD(pending.fd, matches: pending.ownership)
        try requireName(DevWidgetIdentity.temporaryFile, matches: pending.ownership, directory: directory)
        guard lseek(pending.fd, 0, SEEK_SET) == 0 else { throw StoreError.ioFailure }
        let read = try safeRead(pending.fd)
        guard read.ownership == pending.ownership else { throw StoreError.unsafeObject }
        try requireName(DevWidgetIdentity.temporaryFile, matches: pending.ownership, directory: directory)
    }

    private static func requireFD(_ fd: Int32, matches expected: Ownership) throws {
        try requireFD(fd, matchesIdentity: expected, includingSize: true)
    }

    private static func requireFD(_ fd: Int32, matchesIdentity expected: Ownership,
                                  includingSize: Bool = false, requireMode: Bool = true) throws {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, safeMetadata(metadata, matches: expected,
                                                      includingSize: includingSize,
                                                      requireMode: requireMode) else {
            throw StoreError.unsafeObject
        }
    }

    private static func requireName(_ name: String, matches expected: Ownership,
                                    directory: Int32) throws {
        try requireName(name, matchesIdentity: expected, directory: directory, includingSize: true)
    }

    private static func requireName(_ name: String, matchesIdentity expected: Ownership,
                                    directory: Int32, includingSize: Bool = false,
                                    requireMode: Bool = true) throws {
        var metadata = stat()
        guard fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              safeMetadata(metadata, matches: expected, includingSize: includingSize,
                           requireMode: requireMode) else {
            throw StoreError.existingObject
        }
    }

    private static func safeMetadata(_ metadata: stat, matches expected: Ownership,
                                     includingSize: Bool, requireMode: Bool) -> Bool {
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && metadata.st_uid == getuid()
            && metadata.st_nlink == 1
            && (!requireMode || metadata.st_mode & 0o777 == 0o600)
            && UInt64(metadata.st_dev) == expected.device
            && UInt64(metadata.st_ino) == expected.inode
            && (!includingSize || metadata.st_size == expected.size)
    }

    private static func safeRead(_ fd: Int32) throws -> (data: Data, ownership: Ownership) {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_nlink == 1, metadata.st_uid == getuid(),
              metadata.st_mode & 0o777 == 0o600,
              metadata.st_size > 0, metadata.st_size <= 8192
        else { throw StoreError.unsafeObject }
        var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size))
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            }
            guard count > 0 else { throw StoreError.ioFailure }
            offset += count
        }
        var after = stat()
        guard fstat(fd, &after) == 0,
              sameSafeMetadata(metadata, after) else { throw StoreError.unsafeObject }
        let data = Data(bytes)
        return (data, Ownership(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino),
                                size: Int64(metadata.st_size), digest: digest(data)))
    }

    private static func sameSafeMetadata(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev && before.st_ino == after.st_ino
            && before.st_mode == after.st_mode
            && before.st_uid == after.st_uid && before.st_gid == after.st_gid
            && before.st_nlink == after.st_nlink && before.st_size == after.st_size
            && before.st_flags == after.st_flags && before.st_gen == after.st_gen
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func openContainerDirectory(io: DevProbeIOAudit) throws -> Int32 {
        // This is the real logical lookup entry; subsequent failures may not
        // be recorded as a snapshot read or write.
        io.enteringContainerLookup()
        guard let group = DevWidgetIdentity.group(),
              let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
              url.isFileURL else { throw StoreError.unavailable }
        let components = url.standardizedFileURL.pathComponents
        guard components.first == "/", components.count > 1 else { throw StoreError.unsafeObject }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw StoreError.ioFailure }
        do {
            for component in components.dropFirst() {
                guard !component.isEmpty, component != ".", component != "..",
                      !component.contains("/") else { throw StoreError.unsafeObject }
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw StoreError.unsafeObject }
                close(current)
                current = next
            }
            try checkDirectory(current)
            return current
        } catch {
            close(current)
            throw error
        }
    }

    private static func checkDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == getuid() else { throw StoreError.unsafeObject }
    }
}
