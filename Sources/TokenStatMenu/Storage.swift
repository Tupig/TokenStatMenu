import Foundation
import Security
import CryptoKit
#if SWIFT_PACKAGE
import TokenStatCore
#endif

enum AppPaths {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TokenStatMenu")
    static var configURL: URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--config"), args.indices.contains(i + 1) { return URL(fileURLWithPath: args[i + 1]) }
        return support.appendingPathComponent("config.plist")
    }
    static var logs: URL { configURL.deletingLastPathComponent().appendingPathComponent("Logs") }
}

enum ConfigStore {
    static func load() throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: AppPaths.configURL.path) else { return AppConfiguration() }
        let loaded = try PropertyListSerialization.propertyList(from: Data(contentsOf: AppPaths.configURL), format: nil)
        guard let values = loaded as? [String: Any] else { throw StatError.message("配置必须是 plist 字典") }
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        return try PropertyListDecoder().decode(AppConfiguration.self, from: data).validated()
    }
    static func save(_ config: AppConfiguration) throws {
        _ = try config.validated()
        try FileManager.default.createDirectory(at: AppPaths.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .xml
        try encoder.encode(config).write(to: AppPaths.configURL, options: .atomic)
    }
}

enum KeychainStore {
    private static let service = "com.tupig.TokenStatMenu"
    static func accountName(_ purpose: String, validatedURL: String) throws -> String {
        guard ["upstream", "usage"].contains(purpose),
              let url = URL(string: validatedURL), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              ["https", "http"].contains(url.scheme ?? "") else { throw StatError.message("无效密钥绑定 URL") }
        let digest = SHA256.hash(data: Data(validatedURL.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(purpose)-\(digest)"
    }
    static func read(_ name: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: name, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw StatError.message("无法读取 TokenStatMenu 钥匙串（\(status)）")
        }
        return text
    }
    static func write(_ name: String, value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StatError.message("无法保存 TokenStatMenu 钥匙串（\(status)）") }
    }
    static func read(_ purpose: String, validatedURL: String) throws -> String {
        try read(try accountName(purpose, validatedURL: validatedURL))
    }
    static func write(_ purpose: String, validatedURL: String, value: String) throws {
        try write(try accountName(purpose, validatedURL: validatedURL), value: value)
    }
    static func resolve(_ purpose: String, environment: String, validatedURL: String) throws -> String {
        if let value = ProcessInfo.processInfo.environment[environment] { return value }
        return try read(purpose, validatedURL: validatedURL)
    }
    static func localToken() throws -> String {
        if let value = ProcessInfo.processInfo.environment["TOKENSTAT_LOCAL_KEY"], !value.isEmpty { return value }
        let existing = try read("local")
        if !existing.isEmpty { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw StatError.message("本机令牌生成失败") }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        try write("local", value: value); return value
    }
}

final class StatLogger {
    private let queue = DispatchQueue(label: "TokenStatMenu.log", qos: .utility)
    var onError: ((String) -> Void)?
    func append(_ record: RequestRecord) {
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: AppPaths.logs, withIntermediateDirectories: true)
                let url = AppPaths.logs.appendingPathComponent("requests.jsonl")
                let previous = AppPaths.logs.appendingPathComponent("requests.previous.jsonl")
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 10_000_000 {
                    if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                    try FileManager.default.moveItem(at: url, to: previous)
                }
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                var data = try encoder.encode(record); data.append(10)
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data)
            } catch { onError?("统计日志写入失败") }
        }
    }
    func export(to url: URL, completion: @escaping (String?) -> Void) {
        queue.async {
            do {
                var result = Data()
                for name in ["requests.previous.jsonl", "requests.jsonl"] {
                    let path = AppPaths.logs.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: path.path) { result.append(try Data(contentsOf: path)) }
                }
                try result.write(to: url, options: .atomic); completion(nil)
            } catch { completion("导出失败：无法读写所选文件") }
        }
    }
}
