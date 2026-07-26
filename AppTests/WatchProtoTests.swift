import AgentProtocol
import Foundation
import Testing

@testable import LensCrew

private let capabilities = AgentCapabilities(
    approvals: true, steering: true, interrupt: true,
    planMode: true, resume: true, streamingDeltas: true
)

private func makeSnapshot(hostA: UUID, hostB: UUID) -> WatchSnapshot {
    WatchSnapshot(
        approvals: [
            WatchApprovalDTO(
                hostID: hostA, hostName: "书房 Mac", sessionID: "s-1",
                sessionTitle: "修复登录页", agent: .codex,
                approval: ApprovalRequest(
                    id: "ap-1", kind: .shellCommand, title: "运行 shell 命令",
                    detail: "npm test", cwd: "/tmp/x",
                    options: [
                        ApprovalOption(id: "accept", label: "批准", kind: .allow, scope: .once),
                        ApprovalOption(id: "decline", label: "拒绝", kind: .deny, scope: .once),
                    ],
                    requestedAtMs: 42
                )
            )
        ],
        sessions: [
            WatchSessionDTO(
                hostID: hostB, hostName: "客厅 Mac", sessionID: "s-1", title: "重构支付",
                agent: .claude, status: .running, updatedAtMs: 99,
                recentLines: [
                    WatchTranscriptLine(text: "$ npm test", mono: true),
                    WatchTranscriptLine(text: "思考完成", mono: false),
                ]
            )
        ],
        quotas: [
            WatchQuotaDTO(
                hostID: hostA, hostName: "书房 Mac", agent: .codex, planType: "pro",
                windows: [
                    QuotaWindow(
                        id: "codex/primary", label: nil, usedPercent: 18,
                        windowDurationMins: 10_080, resetsAt: 1_785_640_649
                    )
                ],
                capturedAtMs: 1_785_027_600_000
            )
        ],
        connectedHosts: 2
    )
}

@Suite("WatchProto")
struct WatchProtoTests {

    @Test("WatchSnapshot 编解码往返逐字段等值")
    func snapshotRoundTrip() throws {
        let snapshot = makeSnapshot(hostA: UUID(), hostB: UUID())
        let data = try WatchWire.encode(snapshot)
        let decoded = try #require(WatchWire.decodeSnapshot(data))
        #expect(decoded == snapshot)
        // 复合 id 同构性顺带校验
        #expect(decoded.approvals[0].id.hasSuffix("#ap-1"))
        #expect(decoded.sessions[0].id.hasSuffix("#s-1"))
        #expect(decoded.quotas[0].id.hasSuffix("#codex"))
        #expect(decoded.connectedHosts == 2)
    }

    @Test("升级前的旧快照缺额度字段也能解，按空值兜底")
    func decodesLegacySnapshotWithoutQuota() throws {
        // 模拟 applicationContext 里压着的旧版载荷：只有 approvals/sessions 两键
        let legacy = """
            {"approvals": [], "sessions": []}
            """
        let decoded = try #require(WatchWire.decodeSnapshot(Data(legacy.utf8)))
        #expect(decoded.quotas.isEmpty)
        #expect(decoded.connectedHosts == 0)
    }

    @Test("坏载荷解码返回 nil，不抛也不崩")
    func decodeRejectsGarbage() {
        #expect(WatchWire.decodeSnapshot(Data("not json".utf8)) == nil)
        #expect(WatchWire.decodeAction(Data([0xFF, 0x00])) == nil)
        #expect(WatchWire.decodeAction(Data("{\"unknown\":1}".utf8)) == nil)
    }

    @Test("WatchAction 三种动作编解码往返")
    func actionRoundTrip() throws {
        let host = UUID()
        let actions: [WatchAction] = [
            .resolve(hostID: host, sessionID: "s-1", approvalID: "ap-1", optionID: "accept"),
            .sendText(hostID: host, sessionID: "s-1", text: "继续，跳过失败用例"),
            .interrupt(hostID: host, sessionID: "s-1"),
        ]
        for action in actions {
            let data = try WatchWire.encode(action)
            #expect(WatchWire.decodeAction(data) == action)
        }
    }

    @Test("clip 边界：恰到上限不动，超一字截断补省略号，Character 级不劈字符")
    func clipBoundaries() {
        let exact = String(repeating: "字", count: 10)
        #expect(WatchWire.clip(exact, max: 10) == exact, "等于上限原样返回")

        let over = exact + "尾"
        let clipped = WatchWire.clip(over, max: 10)
        #expect(clipped == exact + "…")
        #expect(clipped.count == 11)

        // String.prefix 按 Character 截，emoji（多标量）不被劈开
        let emoji = String(repeating: "👨‍👩‍👧‍👦", count: 5)
        #expect(WatchWire.clip(emoji, max: 3) == String(repeating: "👨‍👩‍👧‍👦", count: 3) + "…")
        #expect(WatchWire.clip("", max: 5) == "")
    }

    @Test("multiHost 判定取审批与会话的主机并集")
    func multiHostDetection() {
        let hostA = UUID()
        let hostB = UUID()
        #expect(!WatchSnapshot.empty.multiHost)

        var snapshot = makeSnapshot(hostA: hostA, hostB: hostA)
        #expect(!snapshot.multiHost, "同一台主机不算多台")

        snapshot = makeSnapshot(hostA: hostA, hostB: hostB)
        #expect(snapshot.multiHost, "审批与会话各占一台即算多台")
    }
}
