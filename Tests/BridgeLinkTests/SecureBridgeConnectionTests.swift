import AgentProtocol
import Foundation
import Testing

@testable import BridgeLink

// SecureBridgeConnection 的进程内传输测试：URLProtocol stub 模拟
// /e2ee/stream + /e2ee/send（及 relay 的 /v1/rooms/*）。不连真 bridge——
// 与 node 进程的 e2e 是后续任务。每个测试用唯一虚拟主机名注册，
// swift-testing 并行跑也互不串扰。

// MARK: - URLProtocol stub

final class E2EEStubProtocol: URLProtocol, @unchecked Sendable {
    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var servers: [String: E2EEStubServer] = [:]

        func register(_ server: E2EEStubServer, hostname: String) {
            lock.withLock { servers[hostname] = server }
        }

        func unregister(hostname: String) {
            lock.withLock { servers[hostname] = nil }
        }

        func server(for hostname: String) -> E2EEStubServer? {
            lock.withLock { servers[hostname] }
        }
    }

    static let registry = Registry()

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return registry.server(for: host) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
            let server = Self.registry.server(for: host)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        if request.httpMethod == "GET", url.path.hasSuffix("/stream") {
            server.openStream(self, url: url)
        } else if request.httpMethod == "POST", url.path.hasSuffix("/send") {
            let (status, body) = server.handleSend(body: requestBody(), url: url)
            respond(status: status, body: body, url: url)
        } else {
            respond(status: 404, body: Data("{\"error\":\"not found\"}".utf8), url: url)
        }
    }

    override func stopLoading() {
        guard let host = request.url?.host,
            let server = Self.registry.server(for: host)
        else { return }
        server.streamClosed(self)
    }

    private func respond(status: Int, body: Data, url: URL) {
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLProtocol 拿不到 httpBody（URLSession 会转成流），必须读 httpBodyStream
    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }
}

/// 一台虚拟 bridge/relay：把 /send 的帧喂给 FakeMacHost，回帧写进当前 SSE 流
final class E2EEStubServer: @unchecked Sendable {
    let host: FakeMacHost
    let hostname: String
    var baseURL: URL { URL(string: "http://\(hostname)")! }

    private let lock = NSLock()
    private var streamProtocol: E2EEStubProtocol?
    private(set) var streamOpenCount = 0
    private(set) var streamURLs: [URL] = []
    private(set) var sendURLs: [URL] = []

    init(host: FakeMacHost = FakeMacHost()) {
        self.host = host
        self.hostname = "stub-\(UUID().uuidString.lowercased())"
        E2EEStubProtocol.registry.register(self, hostname: hostname)
    }

    func unregister() {
        E2EEStubProtocol.registry.unregister(hostname: hostname)
    }

    // MARK: URLProtocol 入口

    func openStream(_ proto: E2EEStubProtocol, url: URL) {
        // 先登记再回响应：响应一到连接就会 POST clientHello，
        // 晚登记会把 serverHello 推进已被顶替的旧流
        let previous = lock.withLock { () -> E2EEStubProtocol? in
            let previous = streamProtocol
            streamProtocol = proto
            streamOpenCount += 1
            streamURLs.append(url)
            return previous
        }
        if let previous {
            previous.client?.urlProtocolDidFinishLoading(previous)
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        proto.client?.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
        proto.client?.urlProtocol(proto, didLoad: Data(": connected\n\n".utf8))
    }

    func handleSend(body: Data, url: URL) -> (Int, Data) {
        lock.withLock { sendURLs.append(url) }
        guard let frame = try? JSONDecoder().decode(SecureFrame.self, from: body),
            let responses = try? host.handleFrame(frame)
        else {
            return (400, Data("{\"error\":\"bad frame\"}".utf8))
        }
        for response in responses {
            push(response)
        }
        // 直连端点的应答形态：帧一律走 stream 下行，这里只确认收到
        return (202, Data("{\"ok\":true}".utf8))
    }

    func streamClosed(_ proto: E2EEStubProtocol) {
        lock.withLock {
            if streamProtocol === proto { streamProtocol = nil }
        }
    }

    // MARK: 测试驱动

    func push(_ frame: SecureFrame) {
        guard let data = try? JSONEncoder().encode(frame) else { return }
        pushRaw("data: \(String(decoding: data, as: UTF8.self))\n\n")
    }

    func pushRelayMeta(_ json: String) {
        pushRaw("event: relay\ndata: \(json)\n\n")
    }

    func pushRaw(_ text: String) {
        let proto = lock.withLock { streamProtocol }
        guard let proto else { return }
        proto.client?.urlProtocol(proto, didLoad: Data(text.utf8))
    }

    /// 服务端正常关流（模拟 bridge 退出/网络断开）
    func finishStream() {
        let proto = lock.withLock { () -> E2EEStubProtocol? in
            let proto = streamProtocol
            streamProtocol = nil
            return proto
        }
        guard let proto else { return }
        proto.client?.urlProtocolDidFinishLoading(proto)
    }
}

// MARK: - 明文应答策略

/// 默认 mac 行为：cmd 一律 ok（可附带事件），push-register 只记录不应答
private func autoReply(events: String? = nil) -> @Sendable (String) -> [String] {
    { plaintext in
        guard let object = try? JSONSerialization.jsonObject(with: Data(plaintext.utf8)),
            let message = object as? [String: Any],
            message["t"] as? String == "cmd",
            let id = message["id"] as? Int
        else { return [] }
        if let events {
            return ["{\"t\":\"reply\",\"id\":\(id),\"ok\":true,\"events\":[\(events)]}"]
        }
        return ["{\"t\":\"reply\",\"id\":\(id),\"ok\":true}"]
    }
}

// MARK: - 测试

@Suite("SecureBridgeConnection 走安全通道")
struct SecureBridgeConnectionTests {
    private let phoneDeviceId = "22222222-2222-4222-8222-222222222222"

    private func makeConnection(
        _ server: E2EEStubServer,
        transport: SecureBridgeEndpoint.Transport? = nil,
        trustedMac: TrustedMac? = nil,
        pairing: PairingPayload? = nil
    ) -> SecureBridgeConnection {
        SecureBridgeConnection(
            endpoint: SecureBridgeEndpoint(
                transport: transport ?? .direct(baseURL: server.baseURL),
                phoneDeviceId: phoneDeviceId,
                phoneIdentity: PhoneIdentity(),
                trustedMac: trustedMac,
                pairing: pairing
            ),
            protocolClasses: [E2EEStubProtocol.self]
        )
    }

    @Test("直连 qr_bootstrap：握手建立、cmd/reply 往返、事件下发、reply.events 回灌")
    func directHandshakeAndRoundTrip() async throws {
        let server = E2EEStubServer()
        defer { server.unregister() }
        server.host.onPlaintext = autoReply(
            events: "{\"type\":\"sessionStatus\",\"seq\":2,\"sessionId\":\"s\",\"status\":\"running\"}")

        let connection = makeConnection(server, pairing: server.host.pairingPayload())
        let states = StreamRecorder(connection.linkStates)
        let events = StreamRecorder(connection.events)

        try await connection.connect()
        try await states.waitUntil { $0.contains(.connected) }
        // 直连 URL 形态：/e2ee/stream?device=<phoneDeviceId>
        let streamURL = try #require(server.streamURLs.first)
        #expect(streamURL.path == "/e2ee/stream")
        #expect(streamURL.query == "device=\(phoneDeviceId)")
        #expect(server.sendURLs.allSatisfy { $0.path == "/e2ee/send" })

        // cmd → reply（ok）+ reply.events 回灌 events 流
        try await connection.send(.listSessions)
        try await events.waitUntil {
            $0.contains(.sessionStatus(seq: 2, sessionID: "s", status: .running))
        }
        let sentCmd = try #require(server.host.receivedPlaintexts.first)
        #expect(sentCmd.contains("\"t\":\"cmd\"") && sentCmd.contains("\"listSessions\""))

        // mac 主动推送 {t:"event"}
        server.push(
            try server.host.sealToPhone(
                phoneDeviceId,
                plaintext:
                    "{\"t\":\"event\",\"data\":{\"type\":\"sessionStatus\",\"seq\":3,\"sessionId\":\"s\",\"status\":\"idle\"}}"
            ))
        try await events.waitUntil {
            $0.contains(.sessionStatus(seq: 3, sessionID: "s", status: .idle))
        }

        // qr_bootstrap 成功后学到信任记录，供后续任务写 Keychain
        let trust = try #require(connection.currentTrustedMac)
        #expect(trust.macDeviceId == server.host.macDeviceId)
        #expect(trust.macIdentityPublicKey == server.host.identityPublicKeyBase64)
        #expect(trust.displayName == server.host.displayName)

        await connection.disconnect()
        try await states.waitUntil { $0.last == .disconnected }
    }

    @Test("断流后自动重连并以 trusted_reconnect 重新握手")
    func reconnectsWithTrustedHandshake() async throws {
        let server = E2EEStubServer()
        defer { server.unregister() }
        server.host.onPlaintext = autoReply()

        let connection = makeConnection(server, pairing: server.host.pairingPayload())
        let states = StreamRecorder(connection.linkStates)

        try await connection.connect()
        try await states.waitUntil { $0.contains(.connected) }
        #expect(server.streamOpenCount == 1)

        server.finishStream()
        // 重连即重新握手：第二条流 + 第二次 connected
        try await eventually { server.streamOpenCount == 2 }
        try await states.waitUntil { $0.filter { $0 == .connected }.count == 2 }
        #expect(server.host.seenHandshakeModes == [.qrBootstrap, .trustedReconnect])

        // 新会话（新纪元、新密钥）下往返依旧
        try await connection.send(.listSessions)
        #expect(server.host.receivedPlaintexts.count == 1)

        await connection.disconnect()
    }

    @Test("trustedMac 直接首连即 trusted_reconnect，无需二维码")
    func connectsWithTrustedMacOnly() async throws {
        let server = E2EEStubServer()
        defer { server.unregister() }
        let identity = PhoneIdentity()
        server.host.trustPhone(
            deviceId: phoneDeviceId, identityPublicKey: identity.publicKeyRawBase64)

        let connection = SecureBridgeConnection(
            endpoint: SecureBridgeEndpoint(
                transport: .direct(baseURL: server.baseURL),
                phoneDeviceId: phoneDeviceId,
                phoneIdentity: identity,
                trustedMac: TrustedMac(
                    macDeviceId: server.host.macDeviceId,
                    macIdentityPublicKey: server.host.identityPublicKeyBase64,
                    displayName: server.host.displayName
                )
            ),
            protocolClasses: [E2EEStubProtocol.self]
        )
        let states = StreamRecorder(connection.linkStates)
        try await connection.connect()
        try await states.waitUntil { $0.contains(.connected) }
        #expect(server.host.seenHandshakeModes == [.trustedReconnect])
        await connection.disconnect()
    }

    @Test("relay 传输：URL 形态、peer down 触发重连重握手、忽略其余 relay 元数据")
    func relayTransportAndPeerDown() async throws {
        let server = E2EEStubServer()
        defer { server.unregister() }
        server.host.onPlaintext = autoReply()
        let roomId = server.host.macDeviceId

        let connection = makeConnection(
            server,
            transport: .relay(relayURL: server.baseURL, roomId: roomId),
            pairing: server.host.pairingPayload(relay: server.baseURL.absoluteString)
        )
        let states = StreamRecorder(connection.linkStates)
        try await connection.connect()
        try await states.waitUntil { $0.contains(.connected) }

        let streamURL = try #require(server.streamURLs.first)
        #expect(streamURL.path == "/v1/rooms/\(roomId)/stream")
        #expect(streamURL.query == "role=phone")
        let sendURL = try #require(server.sendURLs.first)
        #expect(sendURL.path == "/v1/rooms/\(roomId)/send")
        #expect(sendURL.query == "role=phone")

        // peer up 元数据只忽略，不影响会话
        server.pushRelayMeta("{\"peer\":\"up\"}")
        try await connection.send(.listSessions)

        // peer down → 会话作废 → 退避重连 → trusted_reconnect
        server.pushRelayMeta("{\"peer\":\"down\"}")
        try await eventually { server.streamOpenCount == 2 }
        try await states.waitUntil { $0.filter { $0 == .connected }.count == 2 }
        #expect(server.host.seenHandshakeModes == [.qrBootstrap, .trustedReconnect])

        await connection.disconnect()
    }

    @Test("registerPush 发送 push-register 信封，字段与协议一致")
    func registersPushToken() async throws {
        let server = E2EEStubServer()
        defer { server.unregister() }

        let connection = makeConnection(server, pairing: server.host.pairingPayload())
        let states = StreamRecorder(connection.linkStates)
        try await connection.connect()
        try await states.waitUntil { $0.contains(.connected) }

        try await connection.registerPush(
            deviceToken: "token-abc", environment: "sandbox",
            alertsEnabled: PushAlertsEnabled(approvals: true, turns: false)
        )
        try await eventually { !server.host.receivedPlaintexts.isEmpty }
        let plaintext = try #require(server.host.receivedPlaintexts.last)
        let message = try #require(
            try JSONSerialization.jsonObject(with: Data(plaintext.utf8)) as? [String: Any])
        #expect(message["t"] as? String == "push-register")
        #expect(message["deviceToken"] as? String == "token-abc")
        #expect(message["environment"] as? String == "sandbox")
        let alerts = try #require(message["alertsEnabled"] as? [String: Any])
        #expect(alerts["approvals"] as? Bool == true)
        #expect(alerts["turns"] as? Bool == false)

        await connection.disconnect()
    }

    @Test("reply ok=false 让 send 抛错并带上 bridge 的错误信息")
    func sendSurfacesReplyError() async throws {
        let server = E2EEStubServer()
        defer { server.unregister() }
        server.host.onPlaintext = { plaintext in
            guard let object = try? JSONSerialization.jsonObject(with: Data(plaintext.utf8)),
                let message = object as? [String: Any],
                let id = message["id"] as? Int
            else { return [] }
            return ["{\"t\":\"reply\",\"id\":\(id),\"ok\":false,\"error\":\"boom\"}"]
        }

        let connection = makeConnection(server, pairing: server.host.pairingPayload())
        let states = StreamRecorder(connection.linkStates)
        try await connection.connect()
        try await states.waitUntil { $0.contains(.connected) }

        await #expect(throws: BridgeLinkError.transport("boom")) {
            try await connection.send(.listSessions)
        }
        await connection.disconnect()
    }

    @Test("未连接时 send 直接 notConnected，不静默排队")
    func sendRequiresEstablishedSession() async throws {
        let server = E2EEStubServer()
        defer { server.unregister() }
        let connection = makeConnection(server, pairing: server.host.pairingPayload())
        await #expect(throws: BridgeLinkError.notConnected) {
            try await connection.send(.listSessions)
        }
    }

    @Test("git 请求走 {t:\"git\"} 信封，reply 附带的结果载荷完整解出")
    func gitRoundTripOverSecureChannel() async throws {
        let server = E2EEStubServer()
        defer { server.unregister() }
        server.host.onPlaintext = { plaintext in
            guard let object = try? JSONSerialization.jsonObject(with: Data(plaintext.utf8)),
                let message = object as? [String: Any],
                message["t"] as? String == "git",
                let id = message["id"] as? Int
            else { return [] }
            let git = """
                {"kind":"status","status":{"branch":"main","upstream":null,"ahead":null,\
                "behind":null,"staged":[],"unstaged":[{"path":"README.md","code":"M",\
                "oldPath":null}],"stashCount":0}}
                """
            return ["{\"t\":\"reply\",\"id\":\(id),\"ok\":true,\"git\":\(git)}"]
        }

        let connection = makeConnection(server, pairing: server.host.pairingPayload())
        let states = StreamRecorder(connection.linkStates)
        try await connection.connect()
        try await states.waitUntil { $0.contains(.connected) }

        let outcome = try await connection.git(.status(root: "/tmp/repo"))
        #expect(
            outcome
                == .status(
                    GitStatusSummary(
                        branch: "main", upstream: nil, ahead: nil, behind: nil,
                        staged: [],
                        unstaged: [GitFileChange(path: "README.md", code: "M", oldPath: nil)],
                        stashCount: 0
                    )))

        // 上行信封的线上格式：{t:"git", id, data:{op, root}}
        let plaintext = try #require(server.host.receivedPlaintexts.last)
        let message = try #require(
            try JSONSerialization.jsonObject(with: Data(plaintext.utf8)) as? [String: Any])
        #expect(message["t"] as? String == "git")
        let data = try #require(message["data"] as? [String: Any])
        #expect(data["op"] as? String == "status")
        #expect(data["root"] as? String == "/tmp/repo")

        await connection.disconnect()
    }

    @Test("git 失败的 reply 抛 transport 错误并透传 git 的 stderr")
    func gitSurfacesFailureMessage() async throws {
        let server = E2EEStubServer()
        defer { server.unregister() }
        server.host.onPlaintext = { plaintext in
            guard let object = try? JSONSerialization.jsonObject(with: Data(plaintext.utf8)),
                let message = object as? [String: Any],
                let id = message["id"] as? Int
            else { return [] }
            return [
                "{\"t\":\"reply\",\"id\":\(id),\"ok\":false,\"error\":\"Not possible to fast-forward\"}"
            ]
        }

        let connection = makeConnection(server, pairing: server.host.pairingPayload())
        let states = StreamRecorder(connection.linkStates)
        try await connection.connect()
        try await states.waitUntil { $0.contains(.connected) }

        await #expect(throws: BridgeLinkError.transport("Not possible to fast-forward")) {
            _ = try await connection.git(.pull(root: "/tmp/repo"))
        }
        await connection.disconnect()
    }

    @Test("既无 pairing 也无 trustedMac 时 connect 直接报错")
    func connectRequiresTrustMaterial() async throws {
        let server = E2EEStubServer()
        defer { server.unregister() }
        let connection = makeConnection(server)
        await #expect(throws: BridgeLinkError.self) {
            try await connection.connect()
        }
    }
}
