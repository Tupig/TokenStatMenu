import Foundation
import Network

/// Public local API: POST supported inference routes, GET /health, authenticated GET /tokenstat/status.
/// No CONNECT, TLS interception, global proxy settings, or enterprise credential discovery.
public final class ProxyServer {
    private let queue = DispatchQueue(label: "TokenStatMenu.proxy", qos: .utility)
    private var listener: NWListener?
    private var peers: [UUID: ProxyPeer] = [:]
    private let engine: MetricsEngine
    public var onStatus: ((String) -> Void)?
    public var onRecord: ((RequestRecord) -> Void)?
    public init(engine: MetricsEngine) { self.engine = engine }
    public func start(config: AppConfiguration, apiKey: String, localKey: String) {
        queue.async { [self] in
            stopOnQueue()
            do {
                _ = try config.validated()
                guard !localKey.isEmpty else { throw StatError.message("缺少本机访问令牌") }
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(config.port))!)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready: self.onStatus?("监听 127.0.0.1:\(config.port)")
                    case .failed: self.onStatus?("监听失败：端口被占用或网络不可用"); self.stopOnQueue()
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    guard self.peers.count < 32 else { connection.cancel(); return }
                    let id = UUID()
                    let peer = ProxyPeer(connection: connection, queue: self.queue, config: config,
                        apiKey: apiKey, localKey: localKey, engine: self.engine,
                        onRecord: { [weak self] in self?.onRecord?($0) },
                        onClose: { [weak self] in self?.peers.removeValue(forKey: id) })
                    self.peers[id] = peer; peer.start()
                }
                listener.start(queue: queue)
            } catch { onStatus?(error.localizedDescription) }
        }
    }
    public func stop() { queue.async { self.stopOnQueue(); self.onStatus?("已停止") } }
    private func stopOnQueue() {
        listener?.cancel(); listener = nil
        let current = Array(peers.values)
        for peer in current { peer.close(reason: "代理停止") }
        peers.removeAll()
    }
}

private final class ProxyPeer: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    let connection: NWConnection
    let queue: DispatchQueue
    let config: AppConfiguration
    let apiKey: String
    let localKey: String
    let engine: MetricsEngine
    let onRecord: (RequestRecord) -> Void
    let onClose: () -> Void
    var decoder = HTTPDecoder()
    var parser: StreamParser?
    var nonstream = Data()
    var session: URLSession?
    var task: URLSessionDataTask?
    var requestID: UUID?
    var status = 0
    var streaming = false
    var sawTerminal = false
    var streamFailed = false
    var parseFailed = false
    var closed = false
    var finishWhenDrained = false
    var sending = false
    var writes: [Data] = []
    var queuedBytes = 0
    var suspended = false
    var headerDeadline: DispatchWorkItem?

    init(connection: NWConnection, queue: DispatchQueue, config: AppConfiguration, apiKey: String,
         localKey: String, engine: MetricsEngine, onRecord: @escaping (RequestRecord) -> Void, onClose: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.config = config; self.apiKey = apiKey
        self.localKey = localKey; self.engine = engine; self.onRecord = onRecord; self.onClose = onClose
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close(reason: "调用方连接中断") }
        }
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { [weak self] in self?.close(reason: "请求接收超时") }
        headerDeadline = deadline; queue.asyncAfter(deadline: .now() + 30, execute: deadline)
        receiveRequest()
    }
    func receiveRequest() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            do {
                if let request = try self.decoder.feed(data ?? Data()) {
                    self.headerDeadline?.cancel(); self.headerDeadline = nil
                    self.handle(request)
                    self.decoder = HTTPDecoder() // Release the buffered request after forwarding it.
                    // Observe a client disconnect while URLSession is still producing data.
                    self.observeDisconnect(); return
                }
                if complete || error != nil { self.close(reason: "请求不完整") }
                else { self.receiveRequest() }
            } catch { self.respond(400, message: error.localizedDescription) }
        }
    }
    func observeDisconnect() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, complete, error in
            guard let self, !self.closed else { return }
            if error != nil { self.close(reason: "调用方断开") }
            // A clean TCP write-half-close is legal. Sending detects full-close failure.
            else if !complete { self.observeDisconnect() }
        }
    }
    func handle(_ request: LocalRequest) {
        if request.method == "GET", request.path == "/health" { respond(200, message: "TokenStatMenu running"); return }
        guard request.headers["authorization"] == "Bearer \(localKey)" else { respond(401, message: "需要 TokenStatMenu 本机访问令牌"); return }
        if request.method == "GET", request.path == "/tokenstat/status" {
            respondData(200, data: (try? JSONEncoder().encode(engine.snapshot())) ?? Data("{}".utf8)); return
        }
        guard request.method == "POST" else { respond(405, message: "仅支持 POST 推理请求"); return }
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else { respond(415, message: "需要 application/json"); return }
        do {
            let upstream = try config.upstreamURL(for: request.path)
            guard var object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { throw StatError.message("请求正文必须是 JSON 对象") }
            if !config.model.isEmpty { object["model"] = config.model }
            guard let model = object["model"] as? String, !model.isEmpty else { throw StatError.message("请求或设置中需要模型名称") }
            streaming = object["stream"] as? Bool ?? request.path.hasPrefix("/api/")
            if streaming, request.path == "/v1/chat/completions", config.includeUsage {
                var options = object["stream_options"] as? [String: Any] ?? [:]
                options["include_usage"] = true; object["stream_options"] = options
            }
            var outbound = URLRequest(url: upstream)
            outbound.httpMethod = "POST"; outbound.httpBody = try JSONSerialization.data(withJSONObject: object)
            outbound.setValue("application/json", forHTTPHeaderField: "Content-Type")
            outbound.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if !apiKey.isEmpty { outbound.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            outbound.setValue(streaming ? "text/event-stream, application/x-ndjson, application/json" : "application/json", forHTTPHeaderField: "Accept")
            requestID = engine.begin(model: model, input: TokenEstimator.input(object), config: config)
            let settings = URLSessionConfiguration.ephemeral
            settings.urlCache = nil; settings.httpCookieStorage = nil
            settings.timeoutIntervalForRequest = 120; settings.timeoutIntervalForResource = 3600
            let operations = OperationQueue(); operations.maxConcurrentOperationCount = 1; operations.underlyingQueue = queue
            session = URLSession(configuration: settings, delegate: self, delegateQueue: operations)
            task = session!.dataTask(with: outbound); task!.resume()
        } catch { respond(400, message: error.localizedDescription) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward a bearer token to a redirected host.
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !closed, let response = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        status = response.statusCode
        let type = response.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
        if streaming, (200..<300).contains(status) {
            if type.contains("text/event-stream") { parser = StreamParser(format: .sse) }
            else if type.contains("ndjson") || type.contains("jsonl") { parser = StreamParser(format: .ndjson) }
        }
        // Only forward safe response headers. URLSession may already have decompressed the body.
        let safeType = type.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        enqueue(Data("HTTP/1.1 \(status) Response\r\nContent-Type: \(safeType)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8))
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !closed else { return }
        if let id = requestID { engine.firstByte(id) }
        if (200..<300).contains(status), !parseFailed {
            do {
                if parser != nil { for frame in try parser!.feed(data) { try observe(frame, streaming: true) } }
                else {
                    guard nonstream.count + data.count <= 8_388_608 else { throw StatError.message("非流式响应超过统计上限") }
                    nonstream.append(data)
                }
            } catch { parseFailed = true }
        }
        var chunk = Data(String(data.count, radix: 16).utf8); chunk.append(Data("\r\n".utf8)); chunk.append(data); chunk.append(Data("\r\n".utf8)); enqueue(chunk)
    }
    func observe(_ data: Data, streaming: Bool) throws {
        let observation = try UsageDecoder.decode(data, streaming: streaming)
        if let id = requestID { engine.observe(id, observation) }
        sawTerminal = sawTerminal || observation.terminal
        streamFailed = streamFailed || observation.failed
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !closed else { return }
        if !parseFailed, (200..<300).contains(status) {
            do {
                if parser != nil { for frame in try parser!.feed(Data(), eof: true) { try observe(frame, streaming: true) } }
                else if !nonstream.isEmpty { try observe(nonstream, streaming: false) }
                else { parseFailed = true }
            } catch { parseFailed = true }
        }
        let success = error == nil && (200..<300).contains(status) && !parseFailed && !streamFailed && (parser == nil || sawTerminal)
        let reason = success ? nil : (error != nil ? "传输失败或取消" : "HTTP \(status) / 流未完成或统计解析失败")
        if let id = requestID, let record = engine.finish(id, success: success, error: reason) { onRecord(record) }
        requestID = nil
        if status == 0 { respond(502, message: "上游连接失败，请检查 Endpoint 和网络") }
        else if error != nil { close(reason: "上游传输失败") } // Leave chunk framing incomplete: caller must see transport failure.
        else { enqueue(Data("0\r\n\r\n".utf8)); finishWhenDrained = true; drain() }
        session.finishTasksAndInvalidate(); self.session = nil
    }
    func respond(_ code: Int, message: String) {
        let data = (try? JSONSerialization.data(withJSONObject: ["message": message])) ?? Data()
        respondData(code, data: data)
    }
    func respondData(_ code: Int, data: Data) {
        headerDeadline?.cancel()
        var response = Data("HTTP/1.1 \(code) Response\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(data); enqueue(response); finishWhenDrained = true; drain()
    }
    func enqueue(_ data: Data) {
        guard !closed else { return }
        queuedBytes += data.count
        guard queuedBytes <= 4_194_304 else { close(reason: "调用方读取过慢"); return }
        writes.append(data)
        if queuedBytes > 262_144, !suspended, let task { task.suspend(); suspended = true }
        drain()
    }
    func drain() {
        guard !closed, !sending else { return }
        if writes.isEmpty { if finishWhenDrained { close(reason: nil) }; return }
        sending = true
        let bytes = writes.removeFirst()
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            self.sending = false; self.queuedBytes -= bytes.count
            if error != nil { self.close(reason: "调用方断开"); return }
            if self.suspended, self.queuedBytes < 65_536 { self.task?.resume(); self.suspended = false }
            self.drain()
        })
    }
    func close(reason: String?) {
        guard !closed else { return }; closed = true
        headerDeadline?.cancel(); headerDeadline = nil
        task?.cancel(); session?.invalidateAndCancel(); session = nil
        if let id = requestID, let record = engine.finish(id, success: false, error: reason ?? "连接关闭") { onRecord(record) }
        requestID = nil; connection.cancel(); writes.removeAll(); onClose()
    }
}
