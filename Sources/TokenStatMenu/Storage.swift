import Foundation
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
    static func loadPreferences(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    static func savePreferences(_ preferences: SeasunPreferences, at url: URL) throws {
        let normalized = preferences.normalized
        let value: [String: Any] = [
            "refreshSeconds": normalized.refreshSeconds,
            "tokenHubCompatibilityReadEnabled": normalized.tokenHubCompatibilityReadEnabled
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func savePreferences(_ preferences: SeasunPreferences) throws {
        try savePreferences(preferences, at: AppPaths.configURL)
    }
}

/// Historical identity helper retained for a pure regression test; it performs no Keychain I/O.
enum KeychainStore {
    static func accountName(_ purpose: String, validatedURL: String) throws -> String {
        guard ["upstream", "usage"].contains(purpose),
              let url = URL(string: validatedURL), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              ["https", "http"].contains(url.scheme ?? "") else { throw StatError.message("无效密钥绑定 URL") }
        let digest = SHA256.hash(data: Data(validatedURL.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(purpose)-\(digest)"
    }
}
