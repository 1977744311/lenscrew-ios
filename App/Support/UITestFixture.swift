import AgentProtocol
import BridgeLink
import Foundation

/// UI 自动化的确定性夹具，只在启动参数含 `-uitest-fixture` 时生效：
/// - CrewViewModel 换用独立 UserDefaults suite 的 HostStore，并预置一台假 active 主机
///   （跳过「添加电脑」空态；口令传空串即不写 Keychain）；
/// - 每条 HostLink 换用内存脚本连接（FixtureBridgeConnection），完全不碰网络；
/// - RootView 跳过 PushCoordinator 挂载，避免系统通知授权弹窗打断 XCUITest。
/// 正常启动 isActive 为 false，所有分支走原路径，零行为影响。
@MainActor
enum UITestFixture {
    static let launchArgument = "-uitest-fixture"

    /// 默认由启动参数决定；LensCrewAppTests 的聚合用例会临时置 true 复用同一夹具路径
    static var isActive = ProcessInfo.processInfo.arguments.contains(launchArgument)

    private static var connectionOrdinal = 0

    /// 独立 suite 且创建时先清空：UI 测试不在 standard 落任何持久状态
    static func makeHostStore() -> HostStore {
        let suiteName = "dev.steven.LensCrew.uitest-fixture"
        // 常量 suite 名必然有效；仅夹具路径可达，失败宁可崩也不静默回落 standard
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = HostStore(defaults: defaults)
        store.add(name: "夹具 Mac", host: "fixture.invalid", port: 4311, token: "")
        return store
    }

    static func makeConnection() -> any BridgeConnecting {
        connectionOrdinal += 1
        return FixtureBridgeConnection(ordinal: connectionOrdinal)
    }
}

/// 内存版 BridgeConnecting：收到 listSessions 时发出脚本化的
/// 1 个会话 + 几个块 + 1 条 shell 审批；resolveApproval 时结清审批并完成轮次。
/// seq 对该会话严格 +1——CrewStore 有断档检测，乱给会触发 subscribe 补齐。
/// ordinal 给多实例（多主机）场景错开时间戳，聚合排序才有确定的可断言顺序；
/// 会话 id 恒为 s-fixture，两台主机各持同名会话正好验证复合键不撞号。
final class FixtureBridgeConnection: BridgeConnecting, @unchecked Sendable {
    static let sessionID = "s-fixture"
    static let approvalID = "ap-fixture"
    static let shellBlockID = "b-fixture-shell"
    static let shellCommand = "npm test"
    static let approvalTitle = "运行 shell 命令"
    /// 固定基准（2024-01-01 UTC），叠 ordinal 分钟差
    static let baseMs: Int64 = 1_704_067_200_000

    let events: AsyncStream<BridgeEvent>
    let linkStates: AsyncStream<BridgeLinkState>
    private let eventContinuation: AsyncStream<BridgeEvent>.Continuation
    private let stateContinuation: AsyncStream<BridgeLinkState>.Continuation

    private let lock = NSLock()
    private var listed = false
    private var resolved = false
    private let ordinal: Int

    init(ordinal: Int) {
        self.ordinal = ordinal
        var capturedEvents: AsyncStream<BridgeEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { capturedEvents = $0 }
        eventContinuation = capturedEvents
        var capturedStates: AsyncStream<BridgeLinkState>.Continuation!
        linkStates = AsyncStream(bufferingPolicy: .unbounded) { capturedStates = $0 }
        stateContinuation = capturedStates
    }

    var sessionUpdatedAtMs: Int64 { Self.baseMs + Int64(ordinal) * 60_000 }
    var approvalRequestedAtMs: Int64 { sessionUpdatedAtMs + 500 }

    func connect() async throws {
        stateContinuation.yield(.connected)
    }

    func disconnect() async {
        stateContinuation.yield(.disconnected)
    }

    func send(_ command: ClientCommand) async throws {
        switch command {
        case .listSessions:
            let script = lock.withLock { () -> [BridgeEvent] in
                guard !listed else { return [] }
                listed = true
                return initialScript()
            }
            for event in script { eventContinuation.yield(event) }

        case let .resolveApproval(_, approvalID, optionID) where approvalID == Self.approvalID:
            let script = lock.withLock { () -> [BridgeEvent] in
                guard !resolved else { return [] }
                resolved = true
                return resolutionScript(optionID: optionID)
            }
            for event in script { eventContinuation.yield(event) }

        default:
            break
        }
    }

    // MARK: - 脚本

    private func initialScript() -> [BridgeEvent] {
        let session = AgentSession(
            id: Self.sessionID, agent: .codex, nativeId: nil,
            workspaceRoot: "/tmp/lenscrew-demo", title: "修复登录页",
            model: "scripted", status: .running,
            capabilities: AgentCapabilities(
                approvals: true, steering: true, interrupt: true,
                planMode: true, resume: true, streamingDeltas: true
            ),
            createdAtMs: Self.baseMs, updatedAtMs: sessionUpdatedAtMs
        )
        let approval = ApprovalRequest(
            id: Self.approvalID, kind: .shellCommand, title: Self.approvalTitle,
            detail: Self.shellCommand, cwd: "/tmp/lenscrew-demo",
            options: [
                ApprovalOption(id: "accept", label: "批准", kind: .allow, scope: .once),
                ApprovalOption(
                    id: "acceptForSession", label: "本会话都批", kind: .allow, scope: .session
                ),
                ApprovalOption(id: "decline", label: "拒绝", kind: .deny, scope: .once),
            ],
            requestedAtMs: approvalRequestedAtMs
        )
        return [
            .sessionCreated(seq: 1, session: session),
            .blockAppended(
                seq: 2, sessionID: Self.sessionID,
                block: .userMessage(id: "b-fixture-user", text: "帮我跑一遍测试", imageCount: 0)
            ),
            .blockAppended(
                seq: 3, sessionID: Self.sessionID,
                block: .agentMessage(
                    id: "b-fixture-agent", text: "好的，先跑单测确认基线。", streaming: false
                )
            ),
            .blockAppended(
                seq: 4, sessionID: Self.sessionID,
                block: .shellCommand(
                    id: Self.shellBlockID, command: Self.shellCommand,
                    cwd: "/tmp/lenscrew-demo", output: "", exitCode: nil, status: .pending
                )
            ),
            .approvalRequested(seq: 5, sessionID: Self.sessionID, approval: approval),
        ]
    }

    private func resolutionScript(optionID: String) -> [BridgeEvent] {
        let allowed = optionID != "decline"
        return [
            .approvalSettled(
                seq: 6, sessionID: Self.sessionID, approvalID: Self.approvalID,
                optionID: optionID, outcome: .resolved
            ),
            .blockUpdated(
                seq: 7, sessionID: Self.sessionID, blockID: Self.shellBlockID,
                patch: TranscriptBlockPatch(
                    appendText: allowed ? "tests passed\n" : nil,
                    status: allowed ? .ok : .rejected,
                    exitCode: allowed ? 0 : nil
                )
            ),
            .turnCompleted(
                seq: 8, sessionID: Self.sessionID, inputTokens: 1200, outputTokens: 300,
                cachedInputTokens: 900, stopReason: .completed
            ),
        ]
    }
}
