import Foundation
#if SWIFT_PACKAGE
import TokenStatCore
#endif

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum QuotaClient {
    static func fetch(config: AppConfiguration, key: String) async throws -> QuotaSnapshot {
        let url = try config.checkedURL(config.usageURL)
        var request = URLRequest(url: url); request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 15; settings.timeoutIntervalForResource = 20
        settings.urlCache = nil; settings.httpCookieStorage = nil
        let session = URLSession(configuration: settings, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StatError.message("企业用量接口返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw StatError.message("企业用量响应超过 1MB") }
            data.append(byte)
        }
        return try QuotaSnapshot.parse(data, config: config)
    }
}
