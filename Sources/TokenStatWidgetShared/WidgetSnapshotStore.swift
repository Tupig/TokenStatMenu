import Foundation
import Darwin

/// 通过 App Group 容器读写小组件共享快照。
///
/// 应用与扩展需要匹配的 `com.apple.security.application-groups` 授权。
/// 系统拒绝容器访问时直接返回错误，不改用私有目录。
public enum WidgetSnapshotStore {

    /// 应用与内嵌扩展共用的组名配置键。
    ///
    /// 构建时通过 `TOKENSTAT_WIDGET_GROUP` 替换占位符；未替换时不可用。
    public static let groupIdentifierKey = "TokenStatWidgetGroup"
    public static let fileName = "widget-snapshot-v1.json"
    public static let temporaryName = "widget-snapshot-v1.json.tmp"

    public enum StoreError: Error, Equatable {
        /// 未取得 App Group 容器，可能是签名或授权配置不正确。
        case unavailable
        /// 已有对象缺少当前进程持有的归属凭据，不予读取。
        case existingObject
        /// 路径组成或文件元数据不符合安全要求。
        case unsafeObject
        case ioFailure
    }

    /// 创建文件后记录的身份，用于后续写入时确认替换的是原文件。
    public struct Ownership: Equatable, Sendable {
        public let device: UInt64
        public let inode: UInt64
        public let size: Int64
        public let digest: String
    }

    // MARK: - 组名解析

    /// 从包内 Info.plist 读取组名，拒绝未展开的构建变量和占位符。
    public static func configuredGroup(bundle: Bundle = .main) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: groupIdentifierKey) as? String else {
            return nil
        }
        return acceptedGroup(raw)
    }

    /// 校验 App Group 名称，测试可在不访问容器的情况下检查非法包标识符。
    public static func acceptedGroup(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 128,
              !value.contains("$("), !value.contains(")"),
              !value.hasPrefix("UNRESOLVED"), !value.hasPrefix("FICTEAM") else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        // 普通包标识符不是 App Group，只接受本项目使用的 `group.` 前缀。
        guard value.hasPrefix("group.") else { return nil }
        return value
    }

    /// 解析组容器路径，系统未返回路径时为 nil。
    public static func containerURL(bundle: Bundle = .main) -> URL? {
        guard let group = configuredGroup(bundle: bundle) else { return nil }
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group),
            url.isFileURL else { return nil }
        return url
    }

    /// 当前进程是否能解析出 App Group 容器路径。
    public static func isAvailable(bundle: Bundle = .main) -> Bool {
        containerURL(bundle: bundle) != nil
    }

    // MARK: - 读取

    /// 接管上次运行留下的快照，使应用重启后仍能替换该文件。
    ///
    /// 文件须归当前用户所有、仅有一个硬链接且权限为 0600。
    /// 此检查仅建立后续替换凭据，不证明最初由哪个进程写入。
    /// - Returns: 传给 `write(replacing:)` 的文件身份，无法接管时返回 nil。
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

    /// 读取共享快照。文件不存在时返回 nil，小组件显示无数据。
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

    // MARK: - 写入

    /// 原子替换共享快照并返回文件身份。
    ///
    /// 通过临时文件与 `renameat` 避免读到半成品；缺少替换凭据时保留原文件。
    @discardableResult
    public static func write(_ data: Data,
                             replacing expected: Ownership? = nil,
                             bundle: Bundle = .main) throws -> Ownership {
        let dirfd = try openContainer(bundle: bundle)
        defer { close(dirfd) }
        return try write(data, replacing: expected, directory: dirfd)
    }

    /// 向已打开的目录写入。测试使用临时目录检查归属、权限和替换规则。
    static func write(_ data: Data, replacing expected: Ownership?,
                      directory dirfd: Int32) throws -> Ownership {
        guard !data.isEmpty, data.count <= WidgetSnapshotCodec.maximumBytes else {
            throw StoreError.unsafeObject
        }

        var existing = stat()
        let present = fstatat(dirfd, fileName, &existing, AT_SYMLINK_NOFOLLOW) == 0
        if present {
            // 没有归属凭据时，不打开、读取或替换已有对象。
            guard let expected else { throw StoreError.existingObject }
            try requireOwned(dirfd, expected: expected)
        } else if errno != ENOENT {
            throw StoreError.ioFailure
        } else if expected != nil {
            // 调用方要求替换的原文件已不存在。
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

    // MARK: - 容器

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

    /// 仅清理归当前用户所有的普通临时文件。
    /// 保留符号链接、多硬链接文件及其他用户的文件。
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
