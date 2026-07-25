import AgentProtocol
import SwiftUI
import WatchConnectivity
import WidgetKit

/// 手表 App 入口。定位是「腕上审批器 + 一瞥」：不引 BridgeLink、不做加密、不连网，
/// 全部数据经 WatchConnectivity 由 iPhone 中转（对端见 App/Support/WatchBridge.swift）。
@main
struct LensCrewWatchApp: App {
    @State private var link = WatchLink()

    var body: some Scene {
        WindowGroup {
            WatchRootView(link: link)
                .task { link.activate() }
        }
    }
}

/// 手表内导航：W2 列表是根，审批队列与会话详情压栈
enum WatchRoute: Hashable {
    case approvals
    /// 关联 WatchSessionDTO.id（hostID#sessionID 复合键，跨主机不撞号）
    case session(String)
}

struct WatchRootView: View {
    let link: WatchLink

    var body: some View {
        NavigationStack {
            WatchSessionListView(link: link)
                .navigationDestination(for: WatchRoute.self) { route in
                    switch route {
                    case .approvals:
                        WatchApprovalView(link: link)
                    case let .session(id):
                        WatchSessionDetailView(link: link, sessionID: id)
                    }
                }
        }
    }
}

/// 手表侧 WC 客户端：收 iPhone 推的快照驱动三屏渲染，把动作回传 iPhone。
/// 手表不知道 bridge 的存在，动作能否送达以快照的后续变化为准。
@MainActor
@Observable
final class WatchLink: NSObject {
    /// 最新一瞥快照；applicationContext 语义，只有最新一份有意义
    private(set) var snapshot: WatchSnapshot = .empty
    /// 至少收到过一次快照——区分「还没同步」与「确实没有会话」
    private(set) var hasSynced = false
    /// 已回传待确认的审批（DTO 复合 id）；确认以它从快照里消失为准
    private(set) var submittedApprovalIDs: Set<String> = []

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - 动作（全部经 iPhone 路由）

    func resolve(_ item: WatchApprovalDTO, optionID: String) {
        submittedApprovalIDs.insert(item.id)
        submit(
            .resolve(
                hostID: item.hostID, sessionID: item.sessionID,
                approvalID: item.approval.id, optionID: optionID
            )
        )
    }

    func sendText(_ text: String, to session: WatchSessionDTO) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        submit(.sendText(hostID: session.hostID, sessionID: session.sessionID, text: trimmed))
    }

    func interrupt(_ session: WatchSessionDTO) {
        submit(.interrupt(hostID: session.hostID, sessionID: session.sessionID))
    }

    /// sendMessage 即时且能在后台唤醒 iPhone App；失败或不可达时
    /// transferUserInfo 排队兜底（链路恢复后由系统代投）。
    private func submit(_ action: WatchAction) {
        guard let data = try? WatchWire.encode(action) else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(
                [WatchWire.actionKey: data], replyHandler: { _ in },
                errorHandler: { _ in
                    _ = WCSession.default.transferUserInfo([WatchWire.actionKey: data])
                }
            )
        } else {
            _ = session.transferUserInfo([WatchWire.actionKey: data])
        }
    }

    // MARK: - 快照落地

    fileprivate func apply(snapshotData: Data) {
        guard let snapshot = WatchWire.decodeSnapshot(snapshotData) else { return }
        self.snapshot = snapshot
        hasSynced = true
        // 从队列里消失的审批 = iPhone 已确认裁决，清掉在途标记
        submittedApprovalIDs.formIntersection(snapshot.approvals.map(\.id))
        refreshGlanceWidget(snapshot)
    }

    /// Smart Stack 小组件的数据随每份快照落盘刷新（widget 时间线策略是 .never）
    private func refreshGlanceWidget(_ snapshot: WatchSnapshot) {
        WatchGlanceStore.save(
            WatchGlanceStore.Glance(
                pendingApprovals: snapshot.approvals.count,
                running: snapshot.sessions.count { $0.status == .running },
                headline: snapshot.approvals.first.map {
                    "\($0.approval.title) · \($0.sessionTitle)"
                }
            )
        )
        WidgetCenter.shared.reloadTimelines(ofKind: WatchGlanceStore.widgetKind)
    }
}

// MARK: - WCSessionDelegate（回调在后台队列：先收敛成 Sendable 的 Data 再过 MainActor 边界）

extension WatchLink: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        // 上次运行留下的 applicationContext 立即可用，不必等 iPhone 在线
        guard let data = session.receivedApplicationContext[WatchWire.snapshotKey] as? Data
        else { return }
        Task { @MainActor in self.apply(snapshotData: data) }
    }

    nonisolated func session(
        _ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let data = applicationContext[WatchWire.snapshotKey] as? Data else { return }
        Task { @MainActor in self.apply(snapshotData: data) }
    }

    /// iPhone 有新审批时补发的即时消息，载荷与 context 同构
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[WatchWire.snapshotKey] as? Data else { return }
        Task { @MainActor in self.apply(snapshotData: data) }
    }
}
