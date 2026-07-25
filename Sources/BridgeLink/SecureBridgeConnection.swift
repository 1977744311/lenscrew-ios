import AgentProtocol
import Foundation

/// 配对成功后需要长期记住的 mac 身份。macIdentityPublicKey 是 trusted_reconnect
/// 的信任根；Keychain 持久化由后续任务接，这里只在内存里维护。
public struct TrustedMac: Sendable, Equatable {
    public var macDeviceId: String
    public var macIdentityPublicKey: String
    public var displayName: String

    public init(macDeviceId: String, macIdentityPublicKey: String, displayName: String) {
        self.macDeviceId = macDeviceId
        self.macIdentityPublicKey = macIdentityPublicKey
        self.displayName = displayName
    }
}

/// push-register 帧的 alertsEnabled 字段（bridge 侧按整体开关兜底，字段名不能漂）
public struct PushAlertsEnabled: Sendable, Equatable, Codable {
    public var approvals: Bool
    public var turns: Bool

    private enum CodingKeys: String, CodingKey {
        case approvals, turns
    }

    public init(approvals: Bool, turns: Bool) {
        self.approvals = approvals
        self.turns = turns
    }
}

/// E2EE 连接的全部构造材料。pairing 非空 = 走 qr_bootstrap（扫码首连），
/// 否则用 trustedMac 走 trusted_reconnect；两者都空无法握手，connect() 会直接报错。
public struct SecureBridgeEndpoint: Sendable {
    public enum Transport: Sendable, Equatable {
        case direct(baseURL: URL)
        /// roomId 约定为 macDeviceId
        case relay(relayURL: URL, roomId: String)
    }

    public var transport: Transport
    /// 本机稳定设备标识（重装不换），也是直连 /e2ee/stream 的路由键
    public var phoneDeviceId: String
    public var phoneIdentity: PhoneIdentity
    public var trustedMac: TrustedMac?
    public var pairing: PairingPayload?

    public init(
        transport: Transport,
        phoneDeviceId: String,
        phoneIdentity: PhoneIdentity,
        trustedMac: TrustedMac? = nil,
        pairing: PairingPayload? = nil
    ) {
        self.transport = transport
        self.phoneDeviceId = phoneDeviceId
        self.phoneIdentity = phoneIdentity
        self.trustedMac = trustedMac
        self.pairing = pairing
    }
}

/// 走 E2EE 安全通道的 BridgeConnecting 实现：SSE 下行帧 + 每帧一 POST 上行，
/// 帧内容全部过 SecurePhoneSession 加解密。结构与 HTTPBridgeConnection 同款：
/// @unchecked Sendable + NSLock，事件流 unbounded 单消费者。
public final class SecureBridgeConnection: BridgeConnecting, @unchecked Sendable {
    private let endpoint: SecureBridgeEndpoint
    /// 上行 POST 用正常超时，发不出去要立刻报错
    private let controlSession: URLSession
    /// 事件流是长连接，请求超时放宽到远大于 15s 心跳间隔
    private let streamSession: URLSession

    public let events: AsyncStream<BridgeEvent>
    public let linkStates: AsyncStream<BridgeLinkState>
    private let eventContinuation: AsyncStream<BridgeEvent>.Continuation
    private let stateContinuation: AsyncStream<BridgeLinkState>.Continuation

    private let lock = NSLock()
    private var streamTask: Task<Void, Never>?
    /// connect() 等第一次握手 established 落定，之后的重连成败与它无关
    private var readyContinuation: CheckedContinuation<Void, any Error>?
    private var session: SecurePhoneSession?
    /// 信任记录：初值取 endpoint.trustedMac，qr_bootstrap 成功后学到。
    /// 一旦非空，后续（重）握手一律 trusted_reconnect。
    private var trust: TrustedMac?
    /// cmd 的 id → 等 reply 的调用方。reply 走下行流异步回来，不是 POST 的响应
    private var pendingReplies: [Int: CheckedContinuation<ChannelReply, any Error>] = [:]
    private var nextCommandId = 0
    /// 本次流尝试是否完成过握手，runStream 据此把退避重置回起点
    private var establishedThisAttempt = false

    private static let initialBackoff: Duration = .milliseconds(250)
    private static let maxBackoff: Duration = .seconds(10)
    /// clientHello 可能石沉大海（mac 不在场、bridge 重启丢路由）。SSE 心跳每 15s
    /// 会唤醒行循环，借它检查死线，超时就断开重试而不是永远挂着。
    private static let handshakeTimeout: Duration = .seconds(30)

    public convenience init(endpoint: SecureBridgeEndpoint) {
        self.init(endpoint: endpoint, protocolClasses: nil)
    }

    /// protocolClasses 仅供测试注入 URLProtocol stub，生产路径走 convenience init
    init(endpoint: SecureBridgeEndpoint, protocolClasses: [AnyClass]?) {
        self.endpoint = endpoint
        self.trust = endpoint.trustedMac

        let control = URLSessionConfiguration.ephemeral
        control.timeoutIntervalForRequest = 10
        control.timeoutIntervalForResource = 30
        // 不等网络就绪：连不上就是连不上，挂着等只会把失败变成没有尽头的转圈
        control.waitsForConnectivity = false

        let stream = URLSessionConfiguration.ephemeral
        stream.timeoutIntervalForRequest = 120
        stream.timeoutIntervalForResource = 60 * 60 * 24
        stream.waitsForConnectivity = false

        if let protocolClasses {
            control.protocolClasses = protocolClasses
            stream.protocolClasses = protocolClasses
        }
        controlSession = URLSession(configuration: control)
        streamSession = URLSession(configuration: stream)

        var capturedEvents: AsyncStream<BridgeEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { capturedEvents = $0 }
        eventContinuation = capturedEvents

        var capturedStates: AsyncStream<BridgeLinkState>.Continuation!
        linkStates = AsyncStream(bufferingPolicy: .unbounded) { capturedStates = $0 }
        stateContinuation = capturedStates
    }

    /// 学到的信任记录。qr_bootstrap 成功后非空，后续任务把它写进 Keychain，
    /// 冷启动即可直接 trusted_reconnect 而不用重新扫码。
    public var currentTrustedMac: TrustedMac? {
        lock.withLock { trust }
    }

    // MARK: - BridgeConnecting

    public func connect() async throws {
        stateContinuation.yield(.connecting)
        guard endpoint.pairing != nil || endpoint.trustedMac != nil else {
            let message = "缺少配对 payload 或已信任的 Mac 记录，无法发起 E2EE 握手"
            stateContinuation.yield(.failed(message))
            throw BridgeLinkError.transport(message)
        }
        do {
            try await withCheckedThrowingContinuation { continuation in
                // 先挂好信号再起任务，否则握手完成得够快时这个信号会丢
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
        failPendingReplies(BridgeLinkError.notConnected)
        lock.withLock { session = nil }
        stateContinuation.yield(.disconnected)
    }

    public func send(_ command: ClientCommand) async throws {
        let (id, envelope) = try lock.withLock { () -> (Int, EncryptedEnvelope) in
            guard let session, session.phase == .established else {
                throw BridgeLinkError.notConnected
            }
            nextCommandId += 1
            let plaintext = try encodeJSONLine(ChannelCmdMessage(id: nextCommandId, data: command))
            return (nextCommandId, try session.seal(plaintext))
        }

        // 先登记再 POST：mac 的 reply 走下行流，可能比 POST 响应先到
        let reply: ChannelReply = try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pendingReplies[id] = continuation }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.postFrame(.encryptedEnvelope(envelope))
                } catch {
                    self.settlePendingReply(id: id, result: .failure(error))
                }
            }
        }
        guard reply.ok else {
            throw BridgeLinkError.transport(reply.error ?? "bridge 拒绝了指令")
        }
    }

    /// 发 push-register 信封。注册 UI/AppDelegate 接线是后续任务，这里只留发送口。
    /// 协议上没有应答帧，送达即成功。
    public func registerPush(
        deviceToken: String, environment: String, alertsEnabled: PushAlertsEnabled
    ) async throws {
        let envelope = try lock.withLock { () -> EncryptedEnvelope in
            guard let session, session.phase == .established else {
                throw BridgeLinkError.notConnected
            }
            let message = ChannelPushRegisterMessage(
                deviceToken: deviceToken, environment: environment, alertsEnabled: alertsEnabled)
            return try session.seal(try encodeJSONLine(message))
        }
        try await postFrame(.encryptedEnvelope(envelope))
    }

    // MARK: - 流循环

    private func runStream() async {
        var backoff = Self.initialBackoff
        while !Task.isCancelled {
            do {
                try await consumeStream()
            } catch is CancellationError {
                return
            } catch {
                // disconnect() 取消任务时 URLSession 抛的是 URLError(.cancelled) 而不是
                // CancellationError，此时不能再往 .disconnected 后面补一条 .failed
                if Task.isCancelled { return }
                stateContinuation.yield(.failed(describe(error)))
                // 首次握手失败要立刻告诉 connect()，否则调用方要一直等重连
                settleReady(.failure(error))
            }
            // 握手成功过就把退避拉回起点：长会话之后的闪断不该按累计失败惩罚
            if lock.withLock({ establishedThisAttempt }) {
                backoff = Self.initialBackoff
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, Self.maxBackoff)
        }
    }

    /// 一次完整的连接尝试：开 SSE → clientHello → 握手 → 信封收发，
    /// 任何失败抛出后由 runStream 退避重试；每次尝试都是全新会话（重连即重新握手）。
    private func consumeStream() async throws {
        lock.withLock { establishedThisAttempt = false }
        let context = try handshakeContext()
        let session = try SecurePhoneSession(
            mode: context.mode,
            roomId: roomId(macDeviceId: context.macDeviceId),
            phoneDeviceId: endpoint.phoneDeviceId,
            identity: endpoint.phoneIdentity,
            macDeviceId: context.macDeviceId,
            macIdentityPublicKey: context.macIdentityPublicKey
        )
        lock.withLock { self.session = session }
        defer {
            lock.withLock { if self.session === session { self.session = nil } }
            // 会话没了 reply 就永远不会来，挂着的 send() 必须立刻失败
            failPendingReplies(BridgeLinkError.notConnected)
        }

        var request = URLRequest(url: streamURL(roomId: session.roomId))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await streamSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BridgeLinkError.transport("E2EE 事件流 HTTP \(code)")
        }

        // 下行流就绪才发 clientHello：serverHello 走流回来，流没建好会丢帧
        let hello = try lock.withLock { try session.makeClientHello() }
        // relay 的 send 会回 delivered=false 表示 mac 不在场，届时等 peer up 再补发
        var helloDelivered = try await postFrame(.clientHello(hello))

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.handshakeTimeout)

        var decoder = SSEDecoder()
        let jsonDecoder = JSONDecoder()
        var pendingEventName: String?
        for try await line in bytes.lines {
            if lock.withLock({ !establishedThisAttempt }), clock.now > deadline {
                throw BridgeLinkError.transport("E2EE 握手超时")
            }
            // SSEDecoder 只认 data 行；event 名要自己记，才能把 relay 元数据帧
            // 与安全帧分开（event 名只对紧随其后的 data 行生效）
            if line.hasPrefix("event:") {
                pendingEventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let payload = decoder.feed(line: line) else { continue }
            let eventName = pendingEventName
            pendingEventName = nil

            if eventName == "relay" {
                struct RelayMeta: Decodable {
                    let peer: String?
                }
                let meta = try? jsonDecoder.decode(RelayMeta.self, from: Data(payload.utf8))
                if meta?.peer == "down" {
                    // mac 掉线，本会话作废；抛出让退避循环重连重握手
                    throw BridgeLinkError.transport("relay 对端已离线")
                }
                if meta?.peer == "up", lock.withLock({ !establishedThisAttempt }), !helloDelivered {
                    // mac 刚上线而 hello 未曾送达：立刻补发，不必干等握手死线
                    helloDelivered = try await postFrame(.clientHello(hello))
                }
                continue
            }

            guard let frame = try? jsonDecoder.decode(SecureFrame.self, from: Data(payload.utf8))
            else {
                // bridge 可能比 App 新，未知帧类型不该把整条流打断
                continue
            }
            try await handleFrame(frame, session: session)
        }
    }

    private func handleFrame(_ frame: SecureFrame, session: SecurePhoneSession) async throws {
        switch frame {
        case let .serverHello(hello):
            let auth = try lock.withLock { try session.handleServerHello(hello) }
            try await postFrame(.clientAuth(auth))

        case let .secureReady(ready):
            try lock.withLock { try session.handleSecureReady(ready) }
            lock.withLock {
                establishedThisAttempt = true
                if trust == nil, let pairing = endpoint.pairing {
                    // 验签通过才算配对完成，这时才把 mac 记为信任（镜像 mac 侧写信任表的时机）
                    trust = TrustedMac(
                        macDeviceId: pairing.macDeviceId,
                        macIdentityPublicKey: pairing.macIdentityPublicKey,
                        displayName: session.macDisplayName ?? pairing.displayName
                    )
                }
            }
            stateContinuation.yield(.connected)
            settleReady(.success(()))

        case let .secureError(error):
            _ = lock.withLock { session.handleSecureError(error) }
            throw BridgeLinkError.transport("安全通道错误 \(error.code.rawValue): \(error.message)")

        case let .encryptedEnvelope(envelope):
            // 重放帧返回 nil 静默丢弃；解密失败抛出，会话作废走重握手
            if let plaintext = try lock.withLock({ try session.open(envelope) }) {
                dispatchChannelMessage(plaintext)
            }

        case .clientHello, .clientAuth:
            break  // 上行帧不该出现在下行流，忽略
        }
    }

    // MARK: - 通道内明文协议（与 bridge/src/secure/secureGateway.ts 对齐）

    private struct ChannelReply {
        let ok: Bool
        let error: String?
    }

    private struct ChannelCmdMessage: Encodable {
        let id: Int
        let data: ClientCommand

        private enum CodingKeys: String, CodingKey {
            case t, id, data
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("cmd", forKey: .t)
            try container.encode(id, forKey: .id)
            try container.encode(data, forKey: .data)
        }
    }

    private struct ChannelPushRegisterMessage: Encodable {
        let deviceToken: String
        let environment: String
        let alertsEnabled: PushAlertsEnabled

        private enum CodingKeys: String, CodingKey {
            case t, deviceToken, environment, alertsEnabled
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("push-register", forKey: .t)
            try container.encode(deviceToken, forKey: .deviceToken)
            try container.encode(environment, forKey: .environment)
            try container.encode(alertsEnabled, forKey: .alertsEnabled)
        }
    }

    /// 单个事件解码失败不拖垮整条 reply/整帧：bridge 可能比 App 新
    private struct LenientBridgeEvent: Decodable {
        let event: BridgeEvent?

        init(from decoder: any Decoder) {
            event = try? BridgeEvent(from: decoder)
        }
    }

    private struct ChannelProbe: Decodable {
        let t: String
    }

    private struct ChannelReplyMessage: Decodable {
        let id: Int
        let ok: Bool
        let error: String?
        let events: [LenientBridgeEvent]?
    }

    private struct ChannelEventMessage: Decodable {
        let data: LenientBridgeEvent
    }

    private func dispatchChannelMessage(_ plaintext: String) {
        let data = Data(plaintext.utf8)
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(ChannelProbe.self, from: data) else { return }
        switch probe.t {
        case "reply":
            guard let reply = try? decoder.decode(ChannelReplyMessage.self, from: data) else {
                return
            }
            // reply 附带的事件（subscribe 补齐）按 SubscribeReply 语义回灌 events 流
            for lenient in reply.events ?? [] {
                if let event = lenient.event { eventContinuation.yield(event) }
            }
            settlePendingReply(
                id: reply.id, result: .success(ChannelReply(ok: reply.ok, error: reply.error)))
        case "event":
            guard let message = try? decoder.decode(ChannelEventMessage.self, from: data),
                let event = message.data.event
            else { return }
            eventContinuation.yield(event)
        default:
            break  // 未来的明文消息类型，忽略
        }
    }

    // MARK: - 上行 POST 与 URL

    /// 一帧一 POST。返回 relay 的 delivered 标记（直连/无字段视为已送达）。
    @discardableResult
    private func postFrame(_ frame: SecureFrame) async throws -> Bool {
        var request = URLRequest(url: sendURL())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(frame)
        request.timeoutInterval = 30

        let (data, response) = try await controlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BridgeLinkError.transport("响应不是 HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BridgeLinkError.transport("HTTP \(http.statusCode)")
        }
        struct SendReceipt: Decodable {
            let delivered: Bool?
        }
        return (try? JSONDecoder().decode(SendReceipt.self, from: data))?.delivered ?? true
    }

    private struct HandshakeContext {
        let mode: HandshakeMode
        let macDeviceId: String
        let macIdentityPublicKey: String
    }

    private func handshakeContext() throws -> HandshakeContext {
        // 有信任记录（初始给定或 qr_bootstrap 学到）就走 trusted_reconnect：
        // 二维码是一次性的，配对完成后的一切重连都凭身份公钥
        if let trust = lock.withLock({ trust }) {
            return HandshakeContext(
                mode: .trustedReconnect,
                macDeviceId: trust.macDeviceId,
                macIdentityPublicKey: trust.macIdentityPublicKey
            )
        }
        guard let pairing = endpoint.pairing else {
            throw BridgeLinkError.transport("缺少配对 payload 或已信任的 Mac 记录，无法发起 E2EE 握手")
        }
        return HandshakeContext(
            mode: .qrBootstrap,
            macDeviceId: pairing.macDeviceId,
            macIdentityPublicKey: pairing.macIdentityPublicKey
        )
    }

    private func roomId(macDeviceId: String) -> String {
        switch endpoint.transport {
        case .direct:
            // 直连没有独立房间概念，与 relay 的约定保持一致取 macDeviceId
            return macDeviceId
        case let .relay(_, roomId):
            return roomId
        }
    }

    private func streamURL(roomId: String) -> URL {
        switch endpoint.transport {
        case let .direct(baseURL):
            return appending(
                to: baseURL, pathComponents: ["e2ee", "stream"],
                query: [URLQueryItem(name: "device", value: endpoint.phoneDeviceId)]
            )
        case let .relay(relayURL, _):
            return appending(
                to: relayURL, pathComponents: ["v1", "rooms", roomId, "stream"],
                query: [URLQueryItem(name: "role", value: "phone")]
            )
        }
    }

    private func sendURL() -> URL {
        switch endpoint.transport {
        case let .direct(baseURL):
            return appending(to: baseURL, pathComponents: ["e2ee", "send"], query: [])
        case let .relay(relayURL, roomId):
            return appending(
                to: relayURL, pathComponents: ["v1", "rooms", roomId, "send"],
                query: [URLQueryItem(name: "role", value: "phone")]
            )
        }
    }

    private func appending(to base: URL, pathComponents: [String], query: [URLQueryItem]) -> URL {
        var url = base
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        guard !query.isEmpty,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.queryItems = query
        return components.url ?? url
    }

    // MARK: - 内部状态收尾

    /// 只落定一次：后续重连的成败与 connect() 的返回值无关
    private func settleReady(_ result: Result<Void, any Error>) {
        let continuation = lock.withLock {
            let continuation = readyContinuation
            readyContinuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    private func settlePendingReply(id: Int, result: Result<ChannelReply, any Error>) {
        let continuation = lock.withLock {
            let continuation = pendingReplies[id]
            pendingReplies[id] = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    private func failPendingReplies(_ error: any Error) {
        let continuations = lock.withLock {
            let continuations = Array(pendingReplies.values)
            pendingReplies.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func encodeJSONLine(_ value: some Encodable) throws -> String {
        // JSONEncoder 默认输出不含换行，满足 relay「帧必须单行」的约束
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func describe(_ error: any Error) -> String {
        if let linkError = error as? BridgeLinkError, case let .transport(message) = linkError {
            return message
        }
        return (error as NSError).localizedDescription
    }
}
