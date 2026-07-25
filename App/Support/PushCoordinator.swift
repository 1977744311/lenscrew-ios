import AgentProtocol
import BridgeLink
import SwiftUI
import UIKit
import UserNotifications

/// 通知 category / action 的稳定标识。文件级 nonisolated 常量，
/// 非隔离的 delegate 回调可以直接比对，不用跨 actor 取。
private enum PushID {
    static let approvalCategory = "LENSCREW_APPROVAL"
    static let turnCategory = "LENSCREW_TURN"
    static let allowOnce = "LENSCREW_ALLOW_ONCE"
    static let deny = "LENSCREW_DENY"
}

/// 推送里 bridge 自定义的 `lenscrew` 字段。全部可选：bridge 版本可能比 App
/// 新或旧，缺什么走对应兜底，不 crash 也不猜。
struct LensCrewPushPayload: Sendable {
    var kind: String?
    var sessionId: String?
    var approvalId: String?
    var macDeviceId: String?
    var onceAllowOptionId: String?
    var denyOptionId: String?

    init?(userInfo: [AnyHashable: Any]) {
        guard let dict = userInfo["lenscrew"] as? [String: Any] else { return nil }
        kind = dict["kind"] as? String
        sessionId = dict["sessionId"] as? String
        approvalId = dict["approvalId"] as? String
        macDeviceId = dict["macDeviceId"] as? String
        onceAllowOptionId = dict["onceAllowOptionId"] as? String
        denyOptionId = dict["denyOptionId"] as? String
    }
}

/// SwiftUI @main 的 UIKit 挂点：只承接 APNs 注册回调并转发，不放业务
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // delegate 必须在启动完成前挂好，否则冷启动的通知 action 会丢
        PushCoordinator.shared.bootstrap()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushCoordinator.shared.deviceTokenReceived(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        // 模拟器与未签名构建走到这里是常态，静默；paired 主机拿不到 token 就不注册推送
    }
}

/// APNs 注册与可操作通知的总管：授权与 category 注册、device token 转发、
/// 锁屏 action 的后台裁决、点通知本体的深链。
@MainActor
final class PushCoordinator: NSObject {
    static let shared = PushCoordinator()

    private weak var model: CrewViewModel?
    /// 冷启动时通知回调可能先于 UI 就绪，深链和 token 先攒着等 attach 冲账。
    /// macDeviceId 留给 VM 映射成 hostID（映射不到落聚焦主机）。
    private var pendingRoute: (sessionID: String, macDeviceId: String?)?
    private var pendingTokenHex: String?

    private override init() {
        super.init()
    }

    func bootstrap() {
        UNUserNotificationCenter.current().delegate = self
    }

    func attach(_ model: CrewViewModel) {
        self.model = model
        // 开关已开（默认即开）就走注册：registerForRemoteNotifications 每次启动
        // 都要调一遍，token 可能被系统轮换
        if model.notifyOnApproval || model.notifyOnTurnCompleted {
            enableNotifications()
        }
        if let hex = pendingTokenHex {
            pendingTokenHex = nil
            model.updatePushToken(hex)
        }
        if let route = pendingRoute {
            pendingRoute = nil
            model.routeToSession(route.sessionID, macDeviceId: route.macDeviceId)
        }
    }

    /// 任一通知开关打开时调用。已授权时 requestAuthorization 立即返回，重复调用幂等。
    func enableNotifications() {
        let center = UNUserNotificationCenter.current()
        let allow = UNNotificationAction(
            identifier: PushID.allowOnce, title: "允许一次",
            options: [.authenticationRequired]
        )
        let deny = UNNotificationAction(
            identifier: PushID.deny, title: "拒绝", options: [.destructive]
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: PushID.approvalCategory, actions: [allow, deny],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: PushID.turnCategory, actions: [], intentIdentifiers: []
            ),
        ])
        Task {
            let granted =
                (try? await center.requestAuthorization(options: [.alert, .sound, .badge]))
                ?? false
            guard granted else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func deviceTokenReceived(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        if let model {
            model.updatePushToken(hex)
        } else {
            pendingTokenHex = hex
        }
    }

    // MARK: - 通知响应

    /// 点通知本体：深链到对应会话页。审批卡靠会话页/首页的现有机制露出，
    /// 不在这里硬造弹卡路径。
    fileprivate func routeFromTap(payload: LensCrewPushPayload) {
        guard let sessionId = payload.sessionId else { return }
        route(sessionId, macDeviceId: payload.macDeviceId)
    }

    /// 锁屏 action 的后台裁决：独立短连接直达目标主机，不碰主连接的状态机——
    /// 主 App 此刻多半没连着，等它连上再裁决就错过了后台时间窗。
    fileprivate func resolveFromAction(payload: LensCrewPushPayload, optionId: String?) async {
        guard let sessionId = payload.sessionId else { return }
        guard let approvalId = payload.approvalId, let optionId else {
            // optionId/approvalId 缺席（bridge 版本差）→ 深链兜底，进 App 手动裁决
            route(sessionId, macDeviceId: payload.macDeviceId)
            return
        }
        let store = model?.hosts ?? HostStore()
        let host =
            payload.macDeviceId.flatMap { mac in
                store.hosts.first { $0.macDeviceId == mac }
            } ?? store.active
        guard let host, host.isPaired,
            let publicKey = store.macIdentityPublicKey(for: host.id)
        else {
            // manual 主机没有 E2EE 通道，深链兜底
            route(sessionId, macDeviceId: payload.macDeviceId)
            return
        }
        let endpoints = host.pairedEndpoints(macIdentityPublicKey: publicKey).map(\.endpoint)

        // 系统给 action 处理的时间很短，beginBackgroundTask 保命到裁决送达
        let application = UIApplication.shared
        let bgTask = application.beginBackgroundTask(withName: "lenscrew.approval-action")
        let delivered = await PushApprovalResolver.resolve(
            endpoints: endpoints, sessionID: sessionId, approvalID: approvalId,
            optionID: optionId
        )
        if bgTask != .invalid {
            application.endBackgroundTask(bgTask)
        }
        if !delivered {
            // 没送达就把人引到会话页补救，而不是让裁决无声蒸发
            route(sessionId, macDeviceId: payload.macDeviceId)
        }
    }

    private func route(_ sessionID: String, macDeviceId: String?) {
        if let model {
            model.routeToSession(sessionID, macDeviceId: macDeviceId)
        } else {
            pendingRoute = (sessionID, macDeviceId)
        }
    }
}

extension PushCoordinator: UNUserNotificationCenterDelegate {
    /// 前台也照常横幅 + 声音：审批本来就要立刻被看见
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        // 在非隔离上下文里先把 userInfo 收敛成 Sendable，再过 MainActor 边界
        guard
            let payload = LensCrewPushPayload(
                userInfo: response.notification.request.content.userInfo
            )
        else { return }
        switch response.actionIdentifier {
        case PushID.allowOnce:
            await PushCoordinator.shared.resolveFromAction(
                payload: payload, optionId: payload.onceAllowOptionId
            )
        case PushID.deny:
            await PushCoordinator.shared.resolveFromAction(
                payload: payload, optionId: payload.denyOptionId
            )
        case UNNotificationDefaultActionIdentifier:
            await PushCoordinator.shared.routeFromTap(payload: payload)
        default:
            break
        }
    }
}

/// 通知 action 的一次性裁决管道：连上 → resolveApproval → 等 approvalSettled
/// （最多 3s）→ 断开。端点按 direct → relay 依次试。
private enum PushApprovalResolver {
    static func resolve(
        endpoints: [SecureBridgeEndpoint], sessionID: String, approvalID: String,
        optionID: String
    ) async -> Bool {
        for endpoint in endpoints {
            let connection = SecureBridgeConnection(endpoint: endpoint)
            do {
                try await connection.connectCapped(seconds: 10)
                try await connection.send(
                    .resolveApproval(
                        sessionID: sessionID, approvalID: approvalID, optionID: optionID
                    )
                )
            } catch {
                await connection.disconnect()
                continue
            }
            // reply ok 已表示 bridge 受理；approvalSettled 只是回执，最多等 3s 不硬赖。
            // events 是 unbounded 缓冲，send 之后再开始消费也不会丢帧。
            _ = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await event in connection.events {
                        if case let .approvalSettled(_, sid, aid, _, _) = event,
                            sid == sessionID, aid == approvalID {
                            return true
                        }
                    }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(3))
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            await connection.disconnect()
            return true
        }
        return false
    }
}
