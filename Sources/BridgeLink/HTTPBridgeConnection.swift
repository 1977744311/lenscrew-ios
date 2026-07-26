import AgentProtocol
import Foundation

/// 连接状态。手机端必须能明确告诉用户"连上了没有"——
/// 把失败混进 BridgeEvent 流会需要伪造 seq，那会污染断档检测。
public enum BridgeLinkState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

/// 与 bridge 的真实连接：SSE 下行，POST 上行。
///
/// 下行不用 WebSocket 是因为 bridge 要保持零第三方依赖（node:http 原生发 SSE），
/// 而 iOS 这侧 `URLSession.bytes(for:).lines` 正好是逐行 AsyncSequence，成本很低。
public final class HTTPBridgeConnection: BridgeConnecting, @unchecked Sendable {
    private let endpoint: BridgeEndpoint
    /// 控制请求（/health、/command）用正常超时，连不上要立刻报错
    private let controlSession: URLSession
    /// 事件流是长连接，请求超时必须关掉，否则默认 60 秒会把 SSE 掐断
    private let streamSession: URLSession

    public let events: AsyncStream<BridgeEvent>
    public let linkStates: AsyncStream<BridgeLinkState>
    private let eventContinuation: AsyncStream<BridgeEvent>.Continuation
    private let stateContinuation: AsyncStream<BridgeLinkState>.Continuation

    private let lock = NSLock()
    private var streamTask: Task<Void, Never>?
    /// connect() 等它落定。不等的话，紧接着发出的指令会在事件流建立之前就被
    /// 服务端播出去，那些事件没有订阅者，客户端就永远看不到。
    private var readyContinuation: CheckedContinuation<Void, any Error>?

    /// 重连退避上限。眼镜端会话被系统抢占后可能反复断连，
    /// 退避封顶在 10 秒，既不打爆 Mac 也不至于让人等太久。
    private static let maxBackoff: Duration = .seconds(10)

    public init(endpoint: BridgeEndpoint) {
        self.endpoint = endpoint

        let control = URLSessionConfiguration.ephemeral
        control.timeoutIntervalForRequest = 10
        control.timeoutIntervalForResource = 30
        // 不等网络就绪：bridge 在同一局域网，连不上就是连不上，
        // 让它挂着等只会把"bridge 没起来"变成一次没有尽头的转圈
        control.waitsForConnectivity = false
        controlSession = URLSession(configuration: control)

        let stream = URLSessionConfiguration.ephemeral
        // 这是"多久没收到字节才算断"，不是连接寿命。服务端每 15 秒发一次心跳注释，
        // 所以 120 秒足够宽松；填 .infinity 不是合法秒数，会让请求直接失败。
        stream.timeoutIntervalForRequest = 120
        stream.timeoutIntervalForResource = 60 * 60 * 24
        stream.waitsForConnectivity = false
        streamSession = URLSession(configuration: stream)

        var capturedEvents: AsyncStream<BridgeEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { capturedEvents = $0 }
        eventContinuation = capturedEvents

        var capturedStates: AsyncStream<BridgeLinkState>.Continuation!
        linkStates = AsyncStream(bufferingPolicy: .unbounded) { capturedStates = $0 }
        stateContinuation = capturedStates
    }

    /// 先探 /health 再开流：探活失败能立刻给出可行动的错误
    /// （口令错、端口不对、bridge 没起），而流循环里的失败只能靠重试兜。
    public func connect() async throws {
        stateContinuation.yield(.connecting)
        do {
            try await checkHealth()
        } catch {
            let message = describe(error)
            stateContinuation.yield(.failed(message))
            throw BridgeLinkError.transport(message)
        }

        do {
            try await withCheckedThrowingContinuation { continuation in
                // 先挂好信号再起任务，否则流建立得够快时这个信号会丢
                lock.withLock { readyContinuation = continuation }
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.runStream()
                }
                let previous = lock.withLock {
                    let previous = streamTask
                    streamTask = task
                    return previous
                }
                previous?.cancel()
            }
        } catch {
            let message = describe(error)
            stateContinuation.yield(.failed(message))
            throw BridgeLinkError.transport(message)
        }
    }

    public func disconnect() async {
        let task = lock.withLock {
            let task = streamTask
            streamTask = nil
            return task
        }
        task?.cancel()
        settleReady(.failure(BridgeLinkError.notConnected))
        stateContinuation.yield(.disconnected)
    }

    public func send(_ command: ClientCommand) async throws {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("command"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(command)
        request.timeoutInterval = 30

        let (data, response) = try await controlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BridgeLinkError.transport("响应不是 HTTP")
        }
        guard http.statusCode == 200 else {
            throw BridgeLinkError.transport("HTTP \(http.statusCode)")
        }

        // subscribe 的补齐结果由 POST 直接返回，不走 SSE——
        // 只补给发起补齐的这个客户端，不打扰其他订阅者
        if case .subscribe = command {
            let reply = try JSONDecoder().decode(SubscribeReply.self, from: data)
            for event in reply.events { eventContinuation.yield(event) }
        }
    }

    public func git(_ request: GitRequest) async throws -> GitOutcome {
        var urlRequest = URLRequest(url: endpoint.baseURL.appendingPathComponent("git"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        // push/pull 在 bridge 侧上限 120s；controlSession 的 resource 上限只有 30s，
        // 会把长操作掐断，所以这里走没有 resource 上限的流会话
        urlRequest.timeoutInterval = 150

        let (data, response) = try await streamSession.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw BridgeLinkError.transport("响应不是 HTTP")
        }
        guard http.statusCode == 200 else {
            throw BridgeLinkError.transport("HTTP \(http.statusCode)")
        }
        let reply: GitReply
        do {
            reply = try JSONDecoder().decode(GitReply.self, from: data)
        } catch {
            throw BridgeLinkError.decoding("git 应答解析失败")
        }
        guard reply.ok else {
            throw BridgeLinkError.transport(reply.error ?? "bridge 拒绝了 git 请求")
        }
        guard let outcome = reply.git else {
            throw BridgeLinkError.decoding("git 应答缺少结果载荷")
        }
        return outcome
    }

    // MARK: - 内部

    private struct SubscribeReply: Decodable {
        let events: [BridgeEvent]
    }

    private struct GitReply: Decodable {
        let ok: Bool
        let git: GitOutcome?
        let error: String?
    }

    private func checkHealth() async throws {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 5
        let (_, response) = try await controlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BridgeLinkError.transport("bridge 未响应 /health")
        }
    }

    private func runStream() async {
        var backoff: Duration = .milliseconds(250)
        while !Task.isCancelled {
            do {
                try await consumeStream()
                // 服务端正常关流（bridge 退出），仍然按断线重试
                backoff = .milliseconds(250)
            } catch is CancellationError {
                return
            } catch {
                stateContinuation.yield(.failed(describe(error)))
                // 首次连接失败要立刻告诉 connect()，否则调用方要一直等重连
                settleReady(.failure(error))
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, Self.maxBackoff)
        }
    }

    private func consumeStream() async throws {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("events"))
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await streamSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BridgeLinkError.transport("事件流 HTTP \(code)")
        }
        stateContinuation.yield(.connected)
        settleReady(.success(()))

        var decoder = SSEDecoder()
        let jsonDecoder = JSONDecoder()
        for try await line in bytes.lines {
            guard let payload = decoder.feed(line: line) else { continue }
            do {
                eventContinuation.yield(
                    try jsonDecoder.decode(BridgeEvent.self, from: Data(payload.utf8))
                )
            } catch {
                // bridge 可能比 App 新，多出来的事件类型不该把整条流打断
                continue
            }
        }
    }

    /// 只落定一次：后续重连的成败与 connect() 的返回值无关
    private func settleReady(_ result: Result<Void, any Error>) {
        let continuation = lock.withLock {
            let continuation = readyContinuation
            readyContinuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    private func describe(_ error: any Error) -> String {
        if let linkError = error as? BridgeLinkError, case let .transport(message) = linkError {
            return message
        }
        return (error as NSError).localizedDescription
    }
}
