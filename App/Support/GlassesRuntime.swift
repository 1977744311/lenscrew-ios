import AgentProtocol
import BridgeLink
import Foundation
import GlassesKit

/// 眼镜会话的来源：真机上用 DAT，模拟器上用 Mock。
/// 判断放在这一处，其余代码只认 GlassesSessionProviding。
enum GlassesRuntime {
    static func makeSession() -> any GlassesSessionProviding {
        #if targetEnvironment(simulator)
        return MockGlassesSession()
        #elseif canImport(MWDATCore) && canImport(MWDATDisplay)
        return DATGlassesSessionAdapter()
        #else
        return MockGlassesSession()
        #endif
    }

    static var isMock: Bool {
        #if targetEnvironment(simulator)
        return true
        #elseif canImport(MWDATCore) && canImport(MWDATDisplay)
        return false
        #else
        return true
        #endif
    }
}

/// 真实 bridge 传输（SSE + POST）尚未落地，这段脚本让整条
/// 「事件 → 状态机 → 分页 → 眼镜」链路能在真机上先跑通并肉眼验证。
/// bridge 接上后删掉。
enum DemoFeed {
    private static let capabilities = AgentCapabilities(
        approvals: true, steering: true, interrupt: true,
        planMode: true, resume: true, streamingDeltas: true
    )

    static func events() -> [BridgeEvent] {
        let session = AgentSession(
            id: "demo", agent: .codex, nativeId: "thread_demo",
            workspaceRoot: "/Users/dev/project", title: "修登录 500",
            model: "gpt-5-codex", status: .running, capabilities: capabilities,
            createdAtMs: 0, updatedAtMs: 0
        )
        return [
            .sessionCreated(seq: 1, session: session),
            .blockAppended(
                seq: 2, sessionID: "demo",
                block: .userMessage(
                    id: "u1", text: "帮我看看登录为什么返回 500", imageCount: 0
                )
            ),
            .blockAppended(
                seq: 3, sessionID: "demo",
                block: .agentMessage(
                    id: "a1", text: "先看服务端日志，再跑一遍相关测试。", streaming: false
                )
            ),
            .blockAppended(
                seq: 4, sessionID: "demo",
                block: .shellCommand(
                    id: "c1", command: "npm test -- auth", cwd: "/Users/dev/project",
                    output: "", exitCode: nil, status: .pending
                )
            ),
            .approvalRequested(
                seq: 5, sessionID: "demo",
                approval: ApprovalRequest(
                    id: "ap1", kind: .shellCommand, title: "运行 npm test -- auth",
                    detail: "npm test -- auth\n工作目录 /Users/dev/project",
                    cwd: "/Users/dev/project",
                    options: [
                        .init(id: "approved", label: "批准", kind: .allow),
                        .init(id: "approved_for_session", label: "本会话都批", kind: .allowAlways),
                        .init(id: "denied", label: "拒绝", kind: .deny),
                    ],
                    requestedAtMs: 0
                )
            ),
        ]
    }
}
