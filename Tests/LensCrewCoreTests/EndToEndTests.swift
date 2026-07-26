import AgentProtocol
import BridgeLink
import Foundation
import GlassRenderer
import GlassesKit
import Testing

@testable import LensCrewCore

/// 全链路测试：真的起一个 bridge 进程，走真 HTTP + 真 SSE，
/// 一路验到眼镜屏上出现审批卡。
///
/// 之前所有测试都停在各自模块边界内，谁也没证明这些零件接得上——
/// 这里要抓的就是那类只在拼装时才暴露的问题（分帧、鉴权、编解码对不上）。
/// agent 运行时换成 bridge/test/e2e-server.ts 里的脚本 adapter：
/// 真拉起三个 agent 会让测试慢、花钱、依赖登录状态，而这里验的是链路不是模型。
private final class BridgeProcess {
    private let process = Process()
    let port: Int
    let token = "e2e-token"

    init() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LensCrewCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根
        let script = root.appendingPathComponent("bridge/test/e2e-server.ts")

        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path, "--port", "0", "--token", token]
        process.currentDirectoryURL = root.appendingPathComponent("bridge")
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        // 端口交给内核分配，避免并行测试抢同一个端口
        guard let boundPort = BridgeProcess.readPort(from: output) else {
            process.terminate()
            throw BridgeProcessError.didNotBecomeReady
        }
        port = boundPort
    }

    var endpoint: BridgeEndpoint {
        BridgeEndpoint(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: token
        )
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    private static func readPort(from pipe: Pipe) -> Int? {
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
            guard let text = String(data: buffer, encoding: .utf8),
                  let line = text.split(separator: "\n").first(where: {
                      $0.hasPrefix("READY ")
                  })
            else { continue }
            return Int(line.dropFirst("READY ".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

private enum BridgeProcessError: Error {
    case didNotBecomeReady
}

private actor EventLog {
    private(set) var events: [BridgeEvent] = []
    func append(_ event: BridgeEvent) { events.append(event) }
    func contains(_ predicate: @Sendable (BridgeEvent) -> Bool) -> Bool {
        events.contains(where: predicate)
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

/// 测试自备仓库用的 git 调用，与被测代码无共享
private func runGit(in root: URL, _ arguments: String...) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = root
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw BridgeProcessError.didNotBecomeReady
    }
}

// 串行跑：每个用例都要起一个 bridge 进程。加时限是因为这里的失败模式多半是"挂住"
// 而不是"断言不过"，没有时限就会拖死整个测试轮次。
@Suite(.serialized, .timeLimit(.minutes(2)))
struct EndToEndTests {

    @Test("真 HTTP/SSE 上跑通建会话、流式回复、审批、命令执行")
    func drivesFullStackOverHTTP() async throws {
        let bridge = try BridgeProcess()
        defer { bridge.stop() }

        let connection = HTTPBridgeConnection(endpoint: bridge.endpoint)
        let log = EventLog()
        let collector = Task {
            for await event in connection.events { await log.append(event) }
        }
        defer { collector.cancel() }

        try await connection.connect()

        try await connection.send(
            .createSession(
                agent: .codex, workspaceRoot: "/tmp",
                model: nil, modeID: nil, reasoningEffort: nil
            )
        )
        #expect(
            await waitUntil({ await log.contains { $0.type == .sessionCreated } }),
            "没有收到 sessionCreated"
        )

        // capabilities 要到 start() 之后才确定，所以必然还有一条快照刷新
        #expect(
            await waitUntil({ await log.contains { $0.type == .sessionUpdated } }),
            "没有收到 sessionUpdated 快照"
        )

        try await connection.send(
            .sendMessage(sessionID: "s-1", text: "这一步需要审批")
        )
        #expect(
            await waitUntil({ await log.contains { $0.type == .approvalRequested } }),
            "没有收到审批请求"
        )

        try await connection.send(
            .resolveApproval(sessionID: "s-1", approvalID: "ap-2", optionID: "accept")
        )
        #expect(
            await waitUntil({ await log.contains { $0.type == .turnCompleted } }),
            "审批放行后 turn 没有结束"
        )

        // 把真实事件序列喂进客户端状态机，验证收到的东西是自洽的
        var store = CrewStore()
        for event in await log.events {
            let outcome = store.apply(event)
            #expect(
                outcome == .applied || outcome == .duplicate,
                "事件 seq \(event.seq) 落库失败: \(outcome)"
            )
        }
        let state = try #require(store.sessions["s-1"])
        #expect(state.pendingApprovals.isEmpty)
        #expect(
            state.blocks.contains {
                if case let .agentMessage(_, text, _) = $0 {
                    return text == "收到：这一步需要审批"
                }
                return false
            },
            "两片增量没有合并成完整回复"
        )
        #expect(
            state.blocks.contains {
                if case let .shellCommand(_, _, _, output, exitCode, status) = $0 {
                    return output == "lenscrew\n" && exitCode == 0 && status == .ok
                }
                return false
            },
            "批准后命令没有按预期执行完"
        )

        await connection.disconnect()
    }

    @Test("冷接入客户端靠 subscribe(fromSeq:1) 拉回既有会话的完整流水")
    func coldAttachReplaysExistingTranscript() async throws {
        let bridge = try BridgeProcess()
        defer { bridge.stop() }

        // 第一个客户端建会话并跑完一轮，然后离场
        let first = HTTPBridgeConnection(endpoint: bridge.endpoint)
        let firstLog = EventLog()
        let firstCollector = Task {
            for await event in first.events { await firstLog.append(event) }
        }
        try await first.connect()
        try await first.send(
            .createSession(
                agent: .codex, workspaceRoot: "/tmp",
                model: nil, modeID: nil, reasoningEffort: nil
            )
        )
        try await first.send(.sendMessage(sessionID: "s-1", text: "你好"))
        #expect(
            await waitUntil({ await firstLog.contains { $0.type == .turnCompleted } }),
            "首个客户端没等到轮次完成"
        )
        firstCollector.cancel()
        await first.disconnect()

        // 冷接入客户端：接入只有 seq-0 元数据快照，按 coordinator 的策略回发
        // subscribe(fromSeq:1)，断言历史 block 真的回来了且能在 store 里重建
        let second = HTTPBridgeConnection(endpoint: bridge.endpoint)
        let secondLog = EventLog()
        let secondCollector = Task {
            for await event in second.events { await secondLog.append(event) }
        }
        defer { secondCollector.cancel() }
        try await second.connect()
        #expect(
            await waitUntil({ await secondLog.contains { $0.type == .sessionCreated } }),
            "冷接入没收到 seq-0 快照"
        )
        try await second.send(.subscribe(sessionID: "s-1", fromSeq: 1))
        #expect(
            await waitUntil({
                await secondLog.contains {
                    if case let .blockAppended(_, _, block) = $0,
                       case .agentMessage = block { return true }
                    return false
                }
            }),
            "重放窗口没把历史 agentMessage 送回冷客户端"
        )

        var store = CrewStore()
        for event in await secondLog.events {
            let outcome = store.apply(event)
            #expect(
                outcome == .applied || outcome == .duplicate,
                "冷接入事件 seq \(event.seq) 落库失败: \(outcome)"
            )
        }
        let state = try #require(store.sessions["s-1"])
        #expect(!state.blocks.isEmpty, "重放后 store 里流水仍为空")

        // 回归：listSessions 只能广播 seq-0 快照。曾经它 emit 真 seq 的
        // sessionCreated——客户端会重建会话（清空流水）且因 seq != 0
        // 不再补拉，冷接入拉回的历史当场丢光
        let countBefore = await secondLog.events.count
        try await second.send(.listSessions)
        #expect(
            await waitUntil({ await secondLog.events.count > countBefore }),
            "listSessions 没有触发快照广播"
        )
        for event in await secondLog.events.dropFirst(countBefore) {
            if case let .sessionCreated(seq, _) = event {
                #expect(seq == 0, "listSessions 广播的快照 seq 必须为 0，实际 \(seq)")
            }
        }

        await second.disconnect()
    }

    @Test("审批到达时眼镜屏真的收到了审批卡")
    func pushesApprovalCardToGlasses() async throws {
        let bridge = try BridgeProcess()
        defer { bridge.stop() }

        let connection = HTTPBridgeConnection(endpoint: bridge.endpoint)
        let glasses = MockGlassesSession()
        try await glasses.start()
        try await glasses.attachDisplay()

        let coordinator = CrewCoordinator(bridge: connection, glasses: glasses)
        let pump = Task { await coordinator.run(glasses: glasses) }
        defer { pump.cancel() }

        try await connection.connect()
        try await connection.send(
            .createSession(
                agent: .codex, workspaceRoot: "/tmp",
                model: nil, modeID: nil, reasoningEffort: nil
            )
        )
        #expect(await waitUntil({ await !coordinator.sessions.isEmpty }))

        try await connection.send(
            .sendMessage(sessionID: "s-1", text: "这一步需要审批")
        )
        let reachedCard = await waitUntil {
            if case .approval = await coordinator.screen { return true }
            return false
        }
        #expect(reachedCard, "眼镜没有切到审批卡")

        // 审批卡必须绕过节流直接上屏，且三档作用范围都要能按到
        let sent = await waitUntil {
            await glasses.sentPayloads.contains { $0.canonicalJSON.contains("approve:accept") }
        }
        #expect(sent, "审批卡没有推到眼镜")
        let payload = try #require(
            await glasses.sentPayloads.last { $0.canonicalJSON.contains("approve:") }
        ).canonicalJSON
        #expect(payload.contains("approve:acceptForSession"))
        #expect(payload.contains("approve:decline"))

        await connection.disconnect()
    }

    /// 这个 bug 只在拼装时出现，两侧单独看都没问题：URLSession 要等到第一个 body
    /// 字节才把响应交给调用方，而新客户端接进来时往往没有历史可补发，
    /// 第一个字节就成了 15 秒后的心跳——审批卡会整整晚一个心跳周期才上眼镜。
    /// 服务端开流时写一行注释序幕解决；这里卡 3 秒，谁把序幕删了立刻会红。
    @Test("建流到收到第一个事件是毫秒级，不会被心跳周期拖住")
    func deliversFirstEventWithoutWaitingForHeartbeat() async throws {
        let bridge = try BridgeProcess()
        defer { bridge.stop() }

        let connection = HTTPBridgeConnection(endpoint: bridge.endpoint)
        let log = EventLog()
        let collector = Task {
            for await event in connection.events { await log.append(event) }
        }
        defer { collector.cancel() }

        let start = ContinuousClock.now
        try await connection.connect()
        try await connection.send(
            .createSession(
                agent: .codex, workspaceRoot: "/tmp",
                model: nil, modeID: nil, reasoningEffort: nil
            )
        )
        #expect(await waitUntil(timeout: .seconds(10)) { await !log.events.isEmpty })
        let elapsed = start.duration(to: .now)
        #expect(elapsed < .seconds(3), "首个事件用了 \(elapsed)，八成又在等心跳")

        await connection.disconnect()
    }

    @Test("会话模式随快照下发，切换后 sessionUpdated 回推新档")
    func switchesSessionModeOverHTTP() async throws {
        let bridge = try BridgeProcess()
        defer { bridge.stop() }

        let connection = HTTPBridgeConnection(endpoint: bridge.endpoint)
        let log = EventLog()
        let collector = Task {
            for await event in connection.events { await log.append(event) }
        }
        defer { collector.cancel() }

        try await connection.connect()
        try await connection.send(
            .createSession(
                agent: .codex, workspaceRoot: "/tmp",
                model: nil, modeID: nil, reasoningEffort: nil
            )
        )
        #expect(
            await waitUntil({
                await log.contains { event in
                    if case let .sessionCreated(_, session) = event {
                        return session.modeId == "default" && !session.modes.isEmpty
                    }
                    return false
                }
            }),
            "sessionCreated 快照没带默认模式与档位清单"
        )

        try await connection.send(.setSessionMode(sessionID: "s-1", modeID: "full"))
        #expect(
            await waitUntil({
                await log.contains { event in
                    if case let .sessionUpdated(_, session) = event {
                        return session.modeId == "full"
                    }
                    return false
                }
            }),
            "切换模式后没有收到携带新档的 sessionUpdated"
        )
    }

    @Test("真 HTTP 上 git 面板拿到真实仓库的状态并执行暂存")
    func servesGitPanelOverHTTP() async throws {
        let bridge = try BridgeProcess()
        defer { bridge.stop() }

        // 一次性真仓库：一个已提交文件 + 一处工作区修改 + 一个 untracked 文件
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lenscrew-git-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(in: root, "init", "-b", "main")
        try runGit(in: root, "config", "user.name", "Tester")
        try runGit(in: root, "config", "user.email", "tester@example.com")
        try runGit(in: root, "config", "commit.gpgsign", "false")
        try Data("# demo\n".utf8).write(to: root.appendingPathComponent("README.md"))
        try runGit(in: root, "add", "-A")
        try runGit(in: root, "commit", "-m", "initial")
        try Data("# demo changed\n".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data("loose\n".utf8).write(to: root.appendingPathComponent("loose.txt"))

        let connection = HTTPBridgeConnection(endpoint: bridge.endpoint)
        try await connection.connect()

        let outcome = try await connection.git(.status(root: root.path))
        guard case let .status(status) = outcome else {
            Issue.record("status 请求没有返回 status 载荷：\(outcome)")
            return
        }
        #expect(status.branch == "main")
        #expect(status.staged.isEmpty)
        #expect(
            status.unstaged.map(\.path).sorted() == ["README.md", "loose.txt"],
            "工作区改动没有如实列出"
        )

        // 写操作走同一条链路：全部暂存后 staged/unstaged 应当互换
        _ = try await connection.git(.stage(root: root.path, paths: []))
        let staged = try await connection.git(.status(root: root.path))
        guard case let .status(after) = staged else {
            Issue.record("暂存后的 status 请求没有返回 status 载荷")
            return
        }
        #expect(after.staged.map(\.path).sorted() == ["README.md", "loose.txt"])
        #expect(after.unstaged.isEmpty)

        // 失败路径：非 git 目录的错误信息原样透传给调用方
        await #expect(throws: BridgeLinkError.self) {
            _ = try await connection.git(
                .status(root: FileManager.default.temporaryDirectory.path))
        }

        await connection.disconnect()
    }

    @Test("bridge 没起来时 connect 立刻给出可行动的错误，而不是静默重试")
    func failsFastWhenBridgeIsAbsent() async throws {
        let connection = HTTPBridgeConnection(
            endpoint: BridgeEndpoint(
                baseURL: URL(string: "http://127.0.0.1:1")!, token: "x"
            )
        )
        await #expect(throws: BridgeLinkError.self) {
            try await connection.connect()
        }
    }

    @Test("口令不对时连接就失败，不会看起来连上了却收不到东西")
    func rejectsWrongToken() async throws {
        let bridge = try BridgeProcess()
        defer { bridge.stop() }

        let connection = HTTPBridgeConnection(
            endpoint: BridgeEndpoint(baseURL: bridge.endpoint.baseURL, token: "wrong")
        )
        // /health 不鉴权，所以探活会过；connect 必须等到事件流真的建立才算数，
        // 401 发生在那一步——否则用户会看到"已连接"却一条事件都没有
        await #expect(throws: BridgeLinkError.self) {
            try await connection.connect()
        }
        await connection.disconnect()
    }
}

extension BridgeEvent {
    fileprivate enum Discriminator: Equatable {
        case sessionCreated, sessionUpdated, sessionStatus, sessionClosed
        case blockAppended, blockUpdated, approvalRequested, approvalSettled
        case turnCompleted, bridgeError, quotaUpdated
    }

    fileprivate var type: Discriminator {
        switch self {
        case .sessionCreated: return .sessionCreated
        case .sessionUpdated: return .sessionUpdated
        case .sessionStatus: return .sessionStatus
        case .sessionClosed: return .sessionClosed
        case .blockAppended: return .blockAppended
        case .blockUpdated: return .blockUpdated
        case .approvalRequested: return .approvalRequested
        case .approvalSettled: return .approvalSettled
        case .turnCompleted: return .turnCompleted
        case .bridgeError: return .bridgeError
        case .quotaUpdated: return .quotaUpdated
        }
    }
}
