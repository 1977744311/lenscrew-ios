import AgentProtocol
import Foundation
import Testing

@testable import BridgeLink

/// secure 通道的真进程 e2e：起 bridge/test/e2e-server.ts（真 HTTP + /e2ee 端点 +
/// SecureGateway + ScriptedAdapter），Swift 侧 SecureBridgeConnection 先走
/// qr_bootstrap 首配握手，在加密信封里跑完 建会话 → 流式回复 → 审批 → 放行 →
/// 轮次完成，再换新连接凭学到的 TrustedMac 走 trusted_reconnect。
/// 明文 HTTP/SSE 链路的 e2e 在 LensCrewCoreTests/EndToEndTests.swift，这里专验加密链路；
/// 不拉真 agent CLI——验的是握手与信封收发，不是模型输出。
private final class SecureBridgeProcess {
    private let process = Process()
    let port: Int
    let pairing: PairingPayload

    init() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BridgeLinkTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根
        let script = root.appendingPathComponent("bridge/test/e2e-server.ts")

        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path, "--port", "0", "--token", "e2e-token"]
        process.currentDirectoryURL = root.appendingPathComponent("bridge")
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        guard let startup = Self.readStartup(from: output) else {
            process.terminate()
            throw SecureBridgeProcessError.didNotBecomeReady
        }
        port = startup.port
        pairing = startup.pairing
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    /// e2e-server 就绪时依次打 `PAIR <json>` 与 `READY <端口>`，两行都到手才算起来
    private static func readStartup(
        from pipe: Pipe
    ) -> (port: Int, pairing: PairingPayload)? {
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            buffer.append(chunk)
            guard let text = String(data: buffer, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n")
            guard
                let pairLine = lines.first(where: { $0.hasPrefix("PAIR ") }),
                let readyLine = lines.first(where: { $0.hasPrefix("READY ") }),
                let port = Int(
                    readyLine.dropFirst("READY ".count)
                        .trimmingCharacters(in: .whitespaces)
                ),
                let pairing = try? JSONDecoder().decode(
                    PairingPayload.self,
                    from: Data(pairLine.dropFirst("PAIR ".count).utf8)
                )
            else { continue }
            return (port, pairing)
        }
        return nil
    }
}

private enum SecureBridgeProcessError: Error {
    case didNotBecomeReady
}

private actor EventLog {
    private(set) var events: [BridgeEvent] = []

    func append(_ event: BridgeEvent) { events.append(event) }

    func contains(_ predicate: @Sendable (BridgeEvent) -> Bool) -> Bool {
        events.contains(where: predicate)
    }

    var firstSessionID: String? {
        for event in events {
            if case let .sessionCreated(_, session) = event { return session.id }
        }
        return nil
    }

    var firstApproval: ApprovalRequest? {
        for event in events {
            if case let .approvalRequested(_, _, approval) = event { return approval }
        }
        return nil
    }

    /// 放行后 ScriptedAdapter 把 shell 块补成 ok/exit 0，这一步走到才算全链路
    var sawShellSuccess: Bool {
        events.contains { event in
            if case let .blockUpdated(_, _, _, patch) = event {
                return patch.status == .ok && patch.exitCode == 0
            }
            return false
        }
    }
}

private func waitUntil(
    timeout: Duration = .seconds(20),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(40))
    }
    return await condition()
}

// 串行 + 时限：每个用例起一个 bridge 进程，失败模式多半是「挂住」而非断言不过
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SecureEndToEndTests {

    @Test("qr_bootstrap 握手后在加密信封里跑通建会话、审批、放行与轮次完成")
    func drivesFullStackOverSecureChannel() async throws {
        let bridge = try SecureBridgeProcess()
        defer { bridge.stop() }

        let phone = PhoneIdentity()
        let phoneDeviceId = "phone-e2e-\(UUID().uuidString)"
        let connection = SecureBridgeConnection(
            endpoint: SecureBridgeEndpoint(
                transport: .direct(baseURL: bridge.baseURL),
                phoneDeviceId: phoneDeviceId,
                phoneIdentity: phone,
                pairing: bridge.pairing
            )
        )
        let log = EventLog()
        let collector = Task {
            for await event in connection.events { await log.append(event) }
        }
        defer { collector.cancel() }

        try await connection.connect()
        // 验签通过才学到信任记录——之后 trusted_reconnect 的信任根
        let trusted = try #require(connection.currentTrustedMac)
        #expect(trusted.macDeviceId == bridge.pairing.macDeviceId)
        #expect(trusted.macIdentityPublicKey == bridge.pairing.macIdentityPublicKey)
        #expect(trusted.displayName == "E2E Mac")

        try await connection.send(
            .createSession(
                agent: .codex, workspaceRoot: "/tmp/lenscrew-e2e", model: nil, mode: .default
            )
        )
        #expect(
            await waitUntil({ await log.firstSessionID != nil }),
            "加密信封里没有收到 sessionCreated"
        )
        let sessionID = try #require(await log.firstSessionID)

        try await connection.send(.sendMessage(sessionID: sessionID, text: "这一步需要审批"))
        #expect(
            await waitUntil({ await log.firstApproval != nil }),
            "没有收到审批请求"
        )
        let approval = try #require(await log.firstApproval)
        #expect(approval.options.contains { $0.kind == .allow && $0.scope == .once })

        try await connection.send(
            .resolveApproval(sessionID: sessionID, approvalID: approval.id, optionID: "accept")
        )
        #expect(
            await waitUntil({
                await log.contains { event in
                    if case .turnCompleted = event { return true }
                    return false
                }
            }),
            "放行后 turn 没有结束"
        )
        #expect(await log.sawShellSuccess, "批准后命令没有按预期执行完")

        await connection.disconnect()

        // 二维码一次性：换一条新连接，不带 pairing、只凭学到的 TrustedMac 重连
        let reconnect = SecureBridgeConnection(
            endpoint: SecureBridgeEndpoint(
                transport: .direct(baseURL: bridge.baseURL),
                phoneDeviceId: phoneDeviceId,
                phoneIdentity: phone,
                trustedMac: trusted
            )
        )
        try await reconnect.connect()
        // send 会等加密信道上的 reply，不抛即 bridge 受理
        try await reconnect.send(.listSessions)
        await reconnect.disconnect()
    }

    @Test("身份公钥对不上时 qr_bootstrap 握手失败，不会静默连上")
    func rejectsTamperedMacIdentity() async throws {
        let bridge = try SecureBridgeProcess()
        defer { bridge.stop() }

        // 篡改二维码里的 mac 身份公钥：serverHello 回显对不上就必须失败
        var tampered = bridge.pairing
        tampered.macIdentityPublicKey = Data(repeating: 7, count: 32).base64EncodedString()

        let connection = SecureBridgeConnection(
            endpoint: SecureBridgeEndpoint(
                transport: .direct(baseURL: bridge.baseURL),
                phoneDeviceId: "phone-e2e-\(UUID().uuidString)",
                phoneIdentity: PhoneIdentity(),
                pairing: tampered
            )
        )
        // 身份校验在 serverHello 一到就发生，首次握手失败即抛，不用等超时
        await #expect(throws: BridgeLinkError.self) {
            try await connection.connect()
        }
        await connection.disconnect()
    }
}
