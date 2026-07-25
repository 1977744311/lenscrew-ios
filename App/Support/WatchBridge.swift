import AgentProtocol
import Foundation
import Observation
import WatchConnectivity

/// iPhone 侧的手表中转。手表不直连 bridge/relay、不持任何密钥，本类是唯一通路：
/// - 出向：观察 CrewViewModel 的聚合审批队列与会话列表，折叠成 WatchSnapshot——
///   updateApplicationContext 存最新一瞥（只留最后一份、省电），出现新审批时补一发
///   sendMessage 求即时（失败无所谓，context 已兜底）；
/// - 入向：接手表回传的裁决/听写/中断，按 (hostID, sessionID) 路由回 VM 的对应方法。
@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()

    private weak var model: CrewViewModel?
    private var lastPushed: WatchSnapshot?
    private var lastApprovalIDs: Set<String> = []
    private var activated = false

    private override init() {
        super.init()
    }

    /// RootView 启动时挂上（与 PushCoordinator.attach 同处）；重复调用无效果
    func attach(_ model: CrewViewModel) {
        guard self.model == nil, WCSession.isSupported() else { return }
        self.model = model
        WCSession.default.delegate = self
        WCSession.default.activate()
        observeAndPush()
    }

    // MARK: - 出向：快照

    /// 读一次快照并注册观察。@Observable 的 onChange 是 willSet 时刻的一次性回调，
    /// 回到 MainActor 下一拍重读新值、重新挂钩；pushIfChanged 去重，抖动不放大。
    private func observeAndPush() {
        guard let model else { return }
        let snapshot = withObservationTracking {
            Self.buildSnapshot(
                approvals: model.pendingApprovalItems, sessions: model.aggregatedSessions
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeAndPush() }
        }
        pushIfChanged(snapshot)
    }

    /// 激活完成/换表等时机的重推：只把当前状态再送一遍，不重复注册观察
    private func repushCurrent() {
        guard let model else { return }
        pushIfChanged(
            Self.buildSnapshot(
                approvals: model.pendingApprovalItems, sessions: model.aggregatedSessions
            )
        )
    }

    private func pushIfChanged(_ snapshot: WatchSnapshot) {
        guard activated else { return }
        let session = WCSession.default
        guard session.isPaired, session.isWatchAppInstalled else { return }
        guard snapshot != lastPushed, let data = try? WatchWire.encode(snapshot) else { return }
        try? session.updateApplicationContext([WatchWire.snapshotKey: data])
        let ids = Set(snapshot.approvals.map(\.id))
        if !ids.subtracting(lastApprovalIDs).isEmpty, session.isReachable {
            session.sendMessage(
                [WatchWire.snapshotKey: data], replyHandler: nil, errorHandler: nil
            )
        }
        lastPushed = snapshot
        lastApprovalIDs = ids
    }

    /// VM 聚合态 → 手表 DTO：只带腕上要渲染的字段，长文本按 WatchWire 上限截断
    private static func buildSnapshot(
        approvals: [PendingApprovalItem], sessions: [AggregatedSession]
    ) -> WatchSnapshot {
        WatchSnapshot(
            approvals: approvals.prefix(WatchWire.maxApprovals).map { item in
                var approval = item.approval
                approval.detail = WatchWire.clip(approval.detail, max: WatchWire.maxDetailChars)
                return WatchApprovalDTO(
                    hostID: item.hostID, hostName: item.hostName,
                    sessionID: item.session.id, sessionTitle: item.session.title,
                    agent: item.session.agent, approval: approval
                )
            },
            sessions: sessions.prefix(WatchWire.maxSessions).map { item in
                WatchSessionDTO(
                    hostID: item.hostID, hostName: item.hostName,
                    sessionID: item.state.session.id, title: item.state.session.title,
                    agent: item.state.session.agent, status: item.state.session.status,
                    updatedAtMs: item.state.session.updatedAtMs,
                    recentLines: item.state.blocks.suffix(WatchWire.maxRecentLines).map {
                        let preview = blockPreview($0)
                        return WatchTranscriptLine(
                            text: WatchWire.clip(preview.text, max: WatchWire.maxLineChars),
                            mono: preview.mono
                        )
                    }
                )
            }
        )
    }

    // MARK: - 入向：动作

    private func handle(actionData: Data) async {
        guard let model, let action = WatchWire.decodeAction(actionData) else { return }
        switch action {
        case let .resolve(hostID, _, approvalID, optionID):
            guard
                let item = model.pendingApprovalItems.first(where: {
                    $0.hostID == hostID && $0.approval.id == approvalID
                })
            else {
                // 已在别处（手机/眼镜/推送）裁决过：重推快照让手表把卡撤下来
                lastPushed = nil
                repushCurrent()
                return
            }
            await model.resolve(approval: item.approval, in: item.key, optionID: optionID)
        case let .sendText(hostID, sessionID, text):
            await model.send(text, to: SessionKey(hostID: hostID, sessionID: sessionID))
        case let .interrupt(hostID, sessionID):
            await model.interrupt(SessionKey(hostID: hostID, sessionID: sessionID))
        }
    }
}

// MARK: - WCSessionDelegate（回调在后台队列：先收敛成 Sendable 的 Data 再过 MainActor 边界）

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let ok = activationState == .activated
        Task { @MainActor in
            self.activated = ok
            guard ok else { return }
            // 激活前的推送都被 guard 挡掉了，这里强制补送一份当前快照
            self.lastPushed = nil
            self.repushCurrent()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// 用户换表后需要重新激活，随后 activationDidComplete 会重推快照
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// 手表侧刚装上 App / 配对状态变化时补第一份快照
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.lastPushed = nil
            self.repushCurrent()
        }
    }

    nonisolated func session(
        _ session: WCSession, didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let data = message[WatchWire.actionKey] as? Data
        // 回执只表示「已收到」；执行结果以快照更新体现（审批从队列里消失）
        replyHandler(["ok": data != nil])
        guard let data else { return }
        Task { @MainActor in await self.handle(actionData: data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[WatchWire.actionKey] as? Data else { return }
        Task { @MainActor in await self.handle(actionData: data) }
    }

    /// 手表不可达时段排队的动作走 transferUserInfo 到这里
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[WatchWire.actionKey] as? Data else { return }
        Task { @MainActor in await self.handle(actionData: data) }
    }
}
