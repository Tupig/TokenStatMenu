import Foundation

public struct LocalRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
}

/// One HTTP/1.1 request per connection. Responses advertise Connection: close.
/// Content-Length and chunked request bodies are supported; ambiguous framing is rejected.
public struct HTTPDecoder {
    private var buffer = Data()
    private var head: (String, String, [String: String])?
    private var body = Data()
    private var chunkLength: Int?
    private var trailers = false
    public init() {}
    public mutating func feed(_ data: Data) throws -> LocalRequest? {
        buffer.append(data)
        guard buffer.count + body.count <= 8_454_144 else { throw StatError.message("请求超过 8MB") }
        if head == nil {
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 65_536 { throw StatError.message("请求头超过 64KB") }; return nil
            }
            guard range.lowerBound <= 65_536,
                  let text = String(data: buffer[..<range.lowerBound], encoding: .utf8) else { throw StatError.message("无效 HTTP 请求头") }
            let lines = text.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0", first[1].hasPrefix("/"), !first[1].hasPrefix("//") else { throw StatError.message("只支持 HTTP/1.x origin-form") }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw StatError.message("无效 HTTP header") }
                let key = String(line[..<colon]).lowercased()
                guard headers[key] == nil else { throw StatError.message("拒绝重复请求头") }
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["expect"] == nil else { throw StatError.message("请禁用 Expect 请求头") }
            if headers["content-length"] != nil && headers["transfer-encoding"] != nil { throw StatError.message("不能同时使用 Content-Length 和 Transfer-Encoding") }
            if let te = headers["transfer-encoding"], te.lowercased() != "chunked" { throw StatError.message("不支持的 Transfer-Encoding") }
            head = (String(first[0]), String(first[1]), headers)
            buffer.removeSubrange(..<range.upperBound)
        }
        guard let (method, path, headers) = head else { return nil }
        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            while true {
                if trailers {
                    if buffer.starts(with: Data("\r\n".utf8)) { return LocalRequest(method: method, path: path, headers: headers, body: body) }
                    if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { return LocalRequest(method: method, path: path, headers: headers, body: body) }
                    guard buffer.count < 65_536 else { throw StatError.message("Trailer 过大") }; return nil
                }
                if chunkLength == nil {
                    guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else { return nil }
                    let text = String(decoding: buffer[..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";", maxSplits: 1).first ?? ""
                    guard let length = Int(text, radix: 16), length >= 0, length <= 8_388_608 - body.count else { throw StatError.message("无效 chunk 长度") }
                    buffer.removeSubrange(..<lineEnd.upperBound)
                    if length == 0 { trailers = true; continue }
                    chunkLength = length
                }
                let n = chunkLength!
                guard buffer.count >= n + 2 else { return nil }
                let end = buffer.index(buffer.startIndex, offsetBy: n)
                guard buffer[end] == 13, buffer[buffer.index(after: end)] == 10 else { throw StatError.message("无效 chunk 结束符") }
                body.append(buffer.prefix(n)); buffer.removeFirst(n + 2); chunkLength = nil
            }
        }
        let rawLength = headers["content-length"] ?? "0"
        guard let length = Int(rawLength), length >= 0, length <= 8_388_608 else { throw StatError.message("无效 Content-Length") }
        guard buffer.count >= length else { return nil }
        return LocalRequest(method: method, path: path, headers: headers, body: Data(buffer.prefix(length)))
    }
}
