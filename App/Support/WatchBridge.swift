import AgentProtocol
import Combine
import Foundation
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
    /// 表盘复杂功能的推送预算（系统约 50 次/天）：只在腕上可见的数字变了才花，
    /// 且除新审批外两次转移至少间隔 15 分钟
    private var lastComplicationFingerprint: String?
    private var lastComplicationAt: Date = .distantPast
    private static let complicationMinInterval: TimeInterval = 15 * 60
    /// Combine 订阅：VM 变更 → 轻 debounce 后重建快照
    private var observation: AnyCancellable?

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

    /// 订阅 CrewViewModel.objectWillChange：轻 debounce 后重读聚合态并推送；
    /// pushIfChanged 去重，抖动不放大。
    private func observeAndPush() {
        guard let model else { return }
        observation = model.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.repushCurrent()
            }
        repushCurrent()
    }

    /// 激活完成/换表等时机的重推：只把当前状态再送一遍
    private func repushCurrent() {
        guard let model else { return }
        pushIfChanged(
            Self.buildSnapshot(
                approvals: model.pendingApprovalItems, sessions: model.aggregatedSessions,
                quotas: model.hostQuotas, connectedHosts: model.connectedHostCount
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
        let hasNewApproval = !ids.subtracting(lastApprovalIDs).isEmpty
        if hasNewApproval, session.isReachable {
            session.sendMessage(
                [WatchWire.snapshotKey: data], replyHandler: nil, errorHandler: nil
            )
        }
        pushComplicationIfWorthIt(snapshot, data: data, hasNewApproval: hasNewApproval)
        lastPushed = snapshot
        lastApprovalIDs = ids
    }

    /// applicationContext 只在手表 App 醒着时被消费；表盘上的数字要靠
    /// transferCurrentComplicationUserInfo 在后台唤起小组件刷新。
    /// 预算有限：指纹没变不花、变了但非新审批且距上次不足 15 分钟也不花。
    private func pushComplicationIfWorthIt(
        _ snapshot: WatchSnapshot, data: Data, hasNewApproval: Bool
    ) {
        let session = WCSession.default
        let fingerprint = Self.complicationFingerprint(snapshot)
        guard fingerprint != lastComplicationFingerprint else { return }
        let now = Date()
        guard
            hasNewApproval
                || now.timeIntervalSince(lastComplicationAt) >= Self.complicationMinInterval
        else { return }
        guard session.remainingComplicationUserInfoTransfers > 0 else { return }
        session.transferCurrentComplicationUserInfo([WatchWire.snapshotKey: data])
        lastComplicationFingerprint = fingerprint
        lastComplicationAt = now
    }

    /// 腕上可见数字的指纹：待批数、运行数、连接主机数、各额度窗口剩余（5% 一档）。
    /// internal 而非 private：纯映射，LensCrewAppTests 直接断言分档行为。
    static func complicationFingerprint(_ snapshot: WatchSnapshot) -> String {
        let running = snapshot.sessions.filter { $0.status == .running }.count
        let quotaPart = snapshot.quotas
            .map { entry in
                let windows = entry.windows
                    .map { window in
                        let remaining = max(0, min(100, 100 - window.usedPercent))
                        return "\(window.id):\(remaining / 5)"
                    }
                    .joined(separator: ",")
                return "\(entry.id)[\(windows)]"
            }
            .joined(separator: ";")
        return "a\(snapshot.approvals.count)|r\(running)|h\(snapshot.connectedHosts)|\(quotaPart)"
    }

    /// VM 聚合态 → 手表 DTO：只带腕上要渲染的字段，长文本按 WatchWire 上限截断。
    /// internal 而非 private：纯映射，LensCrewAppTests 直接对它做裁剪断言。
    static func buildSnapshot(
        approvals: [PendingApprovalItem], sessions: [AggregatedSession],
        quotas: [HostQuota] = [], connectedHosts: Int = 0
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
            },
            quotas: quotas.prefix(WatchWire.maxQuotaEntries).map { item in
                WatchQuotaDTO(
                    hostID: item.hostID, hostName: item.hostName,
                    agent: item.quota.agent, planType: item.quota.planType,
                    windows: Array(item.quota.windows.prefix(WatchWire.maxQuotaWindows)),
                    capturedAtMs: item.quota.capturedAtMs
                )
            },
            connectedHosts: connectedHosts
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
