import AgentProtocol
import BridgeLink
import Foundation
import GlassRenderer
import GlassesKit
import LensCrewCore
import SwiftUI

/// 轮次分隔线的数据：turnCompleted 带回的用量，锚定在当时的最后一个块之后。
/// 时长拿不到（事件里没有起点），所以只显示 tokens 与缓存命中，不编数字。
struct TurnMarker: Identifiable, Equatable {
    let id: String
    let afterBlockID: String
    let inputTokens: Int?
    let outputTokens: Int?
    let cachedInputTokens: Int?

    var totalTokens: Int? {
        if inputTokens == nil && outputTokens == nil { return nil }
        return (inputTokens ?? 0) + (outputTokens ?? 0)
    }

    /// 缓存命中率，两个字段都有才算，否则整段省略
    var cacheHitPercent: Int? {
        guard let cached = cachedInputTokens, let input = inputTokens, input > 0 else {
            return nil
        }
        return Int((Double(cached) / Double(input) * 100).rounded())
    }
}

/// 聚合列表用的轻量投影：一条会话 + 它的主机归属。
/// Watch 转发聚合会话列表时也照这个形状取数。
struct AggregatedSession: Identifiable, Sendable {
    let hostID: UUID
    let hostName: String
    let state: SessionState

    var key: SessionKey { SessionKey(hostID: hostID, sessionID: state.session.id) }
    var id: SessionKey { key }
}

/// 一台主机上一个 agent 的账号额度投影；Watch 转发额度时也照这个形状取数
struct HostQuota: Identifiable, Sendable {
    let hostID: UUID
    let hostName: String
    let quota: AgentQuotaSnapshot

    var id: String { "\(hostID.uuidString)#\(quota.agent.rawValue)" }
}

/// 跨主机合并后的待审批条目。approval.id 也可能跨主机撞号，id 里必须掺 hostID。
struct PendingApprovalItem: Identifiable, Sendable {
    let hostID: UUID
    let hostName: String
    let session: AgentSession
    let approval: ApprovalRequest

    var key: SessionKey { SessionKey(hostID: hostID, sessionID: session.id) }
    var id: String { "\(hostID.uuidString)#\(approval.id)" }
}

/// 全 App 唯一 VM。多主机形态：每台已配置主机一条 HostLink（tap + coordinator +
/// 快照），本类只做聚合（会话列表/审批队列）、按 (hostID, sessionID) 路由动作、
/// 管理眼镜聚焦与偏好。单主机时退化成从前的单连接行为。
@MainActor
@Observable
final class CrewViewModel {
    let hosts: HostStore

    /// 每台已配置主机一条连接单元；key = 主机 UUID
    private(set) var links: [UUID: HostLink] = [:]
    /// 驱动真实眼镜的主机。默认 = active 主机；点进某会话时跟随到它所属的主机
    private(set) var focusedHostID: UUID?
    private(set) var glassesState: GlassesSessionState = .idle
    private(set) var displayState: GlassesKit.DisplayState = .stopped
    private(set) var lastError: String?
    /// 通知深链的目的地；RootView 观察它完成导航后清掉
    private(set) var pendingSessionRoute: SessionKey?

    // 偏好：落 UserDefaults，键名见 PrefKeys
    private(set) var autoPresentApprovals: Bool
    private(set) var notifyOnApproval: Bool
    private(set) var notifyOnTurnCompleted: Bool

    /// 唯一的真实眼镜会话（真机或 Mock），只有聚焦主机的网关会把渲染送进来
    private let glasses = GlassesRuntime.makeSession()
    /// APNs device token（hex），注册回调到达后缓存，各主机连接建立/开关变化时重发
    private var apnsTokenHex: String?

    var usingMockGlasses: Bool { GlassesRuntime.isMock }
    var glassesMounted: Bool { displayState == .started }

    func link(for id: UUID) -> HostLink? { links[id] }

    var focusedLink: HostLink? { focusedHostID.flatMap { links[$0] } }

    private var activeLink: HostLink? { hosts.activeHostID.flatMap { links[$0] } }

    /// active 主机的连接面（Home 主机 chip 沿用原语义）
    var linkState: BridgeLinkState { activeLink?.linkState ?? .disconnected }
    var latencyMs: Int? { activeLink?.latencyMs }
    var linkPath: HostLinkPath? { activeLink?.linkPath }

    /// 任一主机在线即可用（聚合列表非空、能发动作的先决条件）
    var isConnected: Bool {
        links.values.contains { $0.isConnected }
    }

    /// 眼镜屏快照取聚焦主机的；预览组装也要用同一台主机的会话解引用
    var glassScreen: GlassScreen { focusedLink?.glassScreen ?? .sessionList }
    var focusedSessions: [SessionState] { focusedLink?.sessions ?? [] }

    // MARK: - 聚合

    /// 全部主机的会话打平后按最近活动统一排序；主机顺序不影响结果
    var aggregatedSessions: [AggregatedSession] {
        hosts.hosts
            .flatMap { host in
                (links[host.id]?.sessions ?? []).map {
                    AggregatedSession(hostID: host.id, hostName: host.name, state: $0)
                }
            }
            .sorted { $0.state.session.updatedAtMs > $1.state.session.updatedAtMs }
    }

    /// 跨全部主机汇总的待审批，按请求时间倒序——最新的最该先看到。
    /// Watch 转发审批队列时也照这个形状取数。
    var pendingApprovalItems: [PendingApprovalItem] {
        hosts.hosts
            .flatMap { host in
                (links[host.id]?.sessions ?? []).flatMap { state in
                    state.pendingApprovals.map {
                        PendingApprovalItem(
                            hostID: host.id, hostName: host.name,
                            session: state.session, approval: $0
                        )
                    }
                }
            }
            .sorted { $0.approval.requestedAtMs > $1.approval.requestedAtMs }
    }

    /// 全部主机的账号额度打平；主机名升序、agent 名次序稳定，供手表快照直接消费
    var hostQuotas: [HostQuota] {
        hosts.hosts
            .flatMap { host in
                (links[host.id]?.quota ?? [:]).values.map {
                    HostQuota(hostID: host.id, hostName: host.name, quota: $0)
                }
            }
            .sorted {
                ($0.hostName, $0.quota.agent.rawValue) < ($1.hostName, $1.quota.agent.rawValue)
            }
    }

    /// 已连接主机数；手表小组件的"主机状态"模块消费
    var connectedHostCount: Int {
        links.values.filter(\.isConnected).count
    }

    func sessionState(for key: SessionKey) -> SessionState? {
        links[key.hostID]?.sessions.first { $0.session.id == key.sessionID }
    }

    func turnMarkers(for key: SessionKey) -> [TurnMarker] {
        links[key.hostID]?.turnMarkers[key.sessionID] ?? []
    }

    /// 会话当前模式（含 label 的完整档位）；bridge 快照是权威，跨设备/重启都不丢
    func sessionMode(for key: SessionKey) -> SessionModeOption? {
        guard let session = sessionState(for: key)?.session,
              let modeId = session.modeId
        else { return nil }
        return session.modes.first { $0.id == modeId }
            ?? SessionModeOption(id: modeId, label: modeId, detail: "")
    }

    func hostName(for id: UUID) -> String {
        hosts.hosts.first { $0.id == id }?.name ?? ""
    }

    init() {
        // UI 测试夹具启动时换独立 suite 的 store（预置假主机）；正常启动走 standard
        hosts = UITestFixture.isActive ? UITestFixture.makeHostStore() : HostStore()
        let defaults = UserDefaults.standard
        autoPresentApprovals =
            defaults.object(forKey: PrefKeys.autoPresentApprovals) as? Bool ?? true
        notifyOnApproval = defaults.object(forKey: PrefKeys.notifyApproval) as? Bool ?? true
        notifyOnTurnCompleted =
            defaults.object(forKey: PrefKeys.notifyTurnCompleted) as? Bool ?? true
        observeGlasses()
    }

    // MARK: - bridge

    /// 启动/整体重连入口：所有已配置主机各起一条连接，一台连不上不拖累其他台
    func connectAll() async {
        guard !hosts.hosts.isEmpty else {
            lastError = "先在设置里添加一台电脑"
            return
        }
        if focusedHostID == nil { focusedHostID = hosts.activeHostID }
        // 并发各连各的（Task 继承 MainActor，网络等待时会让出主线程）
        let attempts = hosts.hosts.map { host in
            Task { await self.connectHost(host.id) }
        }
        for attempt in attempts {
            await attempt.value
        }
    }

    /// 单台主机（重）连；连接单元不存在就创建
    func connectHost(_ id: UUID) async {
        guard hosts.hosts.contains(where: { $0.id == id }) else { return }
        if focusedHostID == nil { focusedHostID = hosts.activeHostID ?? id }
        await ensureLink(id).connect()
    }

    private func ensureLink(_ id: UUID) -> HostLink {
        if let existing = links[id] { return existing }
        let link = HostLink(
            hostID: id,
            store: hosts,
            realGlasses: glasses,
            focused: id == focusedHostID,
            autoPresentApprovals: autoPresentApprovals,
            fixtureConnection: UITestFixture.isActive ? UITestFixture.makeConnection() : nil,
            reportError: { [weak self] message in
                self?.reportHostError(message, hostID: id)
            },
            pushRegistration: { [weak self] in
                guard let self, let token = self.apnsTokenHex else { return nil }
                return (
                    token,
                    PushAlertsEnabled(
                        approvals: self.notifyOnApproval, turns: self.notifyOnTurnCompleted
                    )
                )
            }
        )
        links[id] = link
        return link
    }

    /// 多台主机并存时连接错误要能归属到主机；单台时保持原文案
    private func reportHostError(_ message: String?, hostID: UUID) {
        guard let message else {
            lastError = nil
            return
        }
        lastError = hosts.hosts.count > 1 ? "\(hostName(for: hostID))：\(message)" : message
    }

    /// 切主机 = 换 active + 眼镜聚焦跟过去。连接是常驻的，断着才补连。
    func switchHost(to id: UUID) async {
        guard hosts.hosts.contains(where: { $0.id == id }) else { return }
        hosts.setActive(id)
        await focusHost(id)
        if links[id]?.isConnected != true {
            await connectHost(id)
        }
    }

    /// 删除主机：先彻底停它的连接单元（泵、眼镜网关订阅），再删配置。
    /// 删的是聚焦/active 主机就落到下一台（有的话）并确保它在线。
    func removeHost(_ id: UUID) async {
        if let link = links.removeValue(forKey: id) {
            await link.shutdown()
        }
        hosts.remove(id)
        if focusedHostID == id {
            focusedHostID = hosts.activeHostID
            await applyFocus()
        }
        if let next = hosts.activeHostID, links[next] == nil {
            await connectHost(next)
        }
    }

    /// 改口令后若这台主机有连接单元，立即用新口令重连
    func updateToken(_ token: String, for id: UUID) async {
        hosts.setToken(token, for: id)
        if links[id] != nil {
            await connectHost(id)
        }
    }

    // MARK: - 眼镜聚焦

    /// 把真实眼镜交给某台主机：其余主机的网关全部退回各自的 Mock。
    /// 用户点进某会话时调用，眼镜「跟随」到正在看的会话所在的 Mac。
    func focusHost(_ id: UUID) async {
        guard hosts.hosts.contains(where: { $0.id == id }) else { return }
        guard focusedHostID != id else { return }
        focusedHostID = id
        await applyFocus()
    }

    private func applyFocus() async {
        // 先让出真机再交给新主机，避免两个 coordinator 同时往真机发帧
        for (hostID, link) in links where hostID != focusedHostID {
            await link.setFocused(false)
        }
        if let focused = focusedLink {
            await focused.setFocused(true)
        }
    }

    // MARK: - 扫码配对

    /// qr_bootstrap 首配：用二维码 payload 建临时连接完成握手（验签通过才算数），
    /// 把学到的 TrustedMac 持久化成 paired 主机、切成 active 并纳入多连接。
    /// 之后的每次连接（包括冷启动）都凭 Keychain 里的公钥走 trusted_reconnect，
    /// 二维码一次性。其余主机的连接不受影响。
    func pair(with payload: PairingPayload) async throws {
        let phone = PhonePairingIdentity.shared
        var transports: [SecureBridgeEndpoint.Transport] = []
        if let lan = payload.lan, let url = URL(string: "http://\(lan.host):\(lan.port)") {
            transports.append(.direct(baseURL: url))
        }
        if let relay = payload.relay, let url = URL(string: relay) {
            transports.append(.relay(relayURL: url, roomId: payload.macDeviceId))
        }
        guard !transports.isEmpty else {
            throw PairingFlowError(message: "二维码里没有可连接的地址，在 Mac 上重新生成一个")
        }

        var failure = "无法连接到这台 Mac"
        for transport in transports {
            let connection = SecureBridgeConnection(
                endpoint: SecureBridgeEndpoint(
                    transport: transport,
                    phoneDeviceId: phone.deviceId,
                    phoneIdentity: phone.identity,
                    pairing: payload
                )
            )
            do {
                try await connection.connectCapped(seconds: 15)
            } catch {
                failure = humanizeSecureError(describeBridgeError(error))
                await connection.disconnect()
                continue
            }
            guard let trusted = connection.currentTrustedMac else {
                await connection.disconnect()
                failure = "握手完成但没拿到 Mac 身份，重试一次"
                continue
            }
            // 配对握手只为换信任记录，正式通道走 trusted_reconnect 重建
            await connection.disconnect()

            let config = hosts.addPaired(
                macDeviceId: trusted.macDeviceId,
                macIdentityPublicKey: trusted.macIdentityPublicKey,
                name: trusted.displayName,
                lanHost: payload.lan?.host,
                lanPort: payload.lan?.port,
                relay: payload.relay
            )
            // 重复扫同一台 Mac 会原地刷新配置，旧连接要用新地址重建
            if let existing = links[config.id] {
                await existing.disconnect()
            }
            hosts.setActive(config.id)
            await focusHost(config.id)
            await connectHost(config.id)
            return
        }
        throw PairingFlowError(message: failure)
    }

    // MARK: - 推送注册

    /// APNs 注册回调送来的 device token（hex）。到达即向每台主机各报一份。
    func updatePushToken(_ hex: String) {
        guard hex != apnsTokenHex else { return }
        apnsTokenHex = hex
        broadcastPushRegistration()
    }

    /// token 同一个，每台 paired 主机各自注册（manual 主机在 link 内静默跳过）
    private func broadcastPushRegistration() {
        for link in links.values {
            Task { await link.sendPushRegistration() }
        }
    }

    // MARK: - 通知深链

    /// 通知 payload 的 macDeviceId 能映射到已配置主机就路由到那台；映射不到落聚焦主机
    func routeToSession(_ sessionID: String, macDeviceId: String?) {
        let hostID =
            macDeviceId.flatMap { mac in
                hosts.hosts.first { $0.macDeviceId == mac }?.id
            } ?? focusedHostID ?? hosts.activeHostID
        guard let hostID else { return }
        pendingSessionRoute = SessionKey(hostID: hostID, sessionID: sessionID)
    }

    func clearSessionRoute() {
        pendingSessionRoute = nil
    }

    // MARK: - 会话（按主机路由）

    func createSession(
        agent: AgentKind, workspaceRoot: String, modeID: String?, modelID: String?,
        reasoningEffort: String?, on hostID: UUID
    ) async {
        let sent = await run(on: hostID) {
            try await $0.createSession(
                agent: agent, workspaceRoot: workspaceRoot, model: modelID, modeID: modeID,
                reasoningEffort: reasoningEffort
            )
        }
        if sent {
            hosts.remember(root: workspaceRoot)
        }
    }

    /// 会话中切换模式；成功与否都以 bridge 回推的 sessionUpdated 刷新 chip
    func setSessionMode(_ key: SessionKey, modeID: String) async {
        await run(on: key.hostID) {
            try await $0.setSessionMode(key.sessionID, modeID: modeID)
        }
    }

    /// 会话中切换模型；生效以 bridge 回推的 sessionUpdated 为准
    func setSessionModel(_ key: SessionKey, modelID: String) async {
        await run(on: key.hostID) {
            try await $0.setSessionModel(key.sessionID, modelID: modelID)
        }
    }

    /// 切换推理档（仅 codex 有档位）
    func setSessionReasoningEffort(_ key: SessionKey, effort: String) async {
        await run(on: key.hostID) {
            try await $0.setSessionReasoningEffort(key.sessionID, effort: effort)
        }
    }

    func send(_ text: String, to key: SessionKey) async {
        await run(on: key.hostID) { try await $0.sendMessage(text, to: key.sessionID) }
    }

    func interrupt(_ key: SessionKey) async {
        await run(on: key.hostID) { try await $0.interrupt(key.sessionID) }
    }

    func resolve(approval: ApprovalRequest, in key: SessionKey, optionID: String) async {
        await run(on: key.hostID) {
            try await $0.resolveApproval(
                sessionID: key.sessionID, approvalID: approval.id, optionID: optionID
            )
        }
    }

    // MARK: - git 面板（按主机路由）

    /// 请求-应答直达对应主机；错误抛给面板自行展示，不进全局错误条——
    /// push 被拒这类失败是面板内的业务结果，不是连接故障
    func git(_ request: GitRequest, on hostID: UUID) async throws -> GitOutcome {
        guard let link = links[hostID] else { throw BridgeLinkError.notConnected }
        return try await link.git(request)
    }

    // MARK: - 眼镜

    func connectGlasses() async {
        do {
            try await glasses.start()
            try await glasses.attachDisplay()
            await focusedLink?.coordinator?.displayReattached()
            lastError = nil
        } catch {
            lastError = describeBridgeError(error)
        }
    }

    func disconnectGlasses() async {
        await glasses.detachDisplay()
        await glasses.stop()
    }

    // MARK: - 偏好

    /// 自动亮屏对聚焦主机的 coordinator 生效；直接同步到全部主机，
    /// 切聚焦时无需再补一遍
    func setAutoPresentApprovals(_ enabled: Bool) {
        autoPresentApprovals = enabled
        UserDefaults.standard.set(enabled, forKey: PrefKeys.autoPresentApprovals)
        for link in links.values {
            link.setAutoPresentApprovals(enabled)
        }
    }

    func setNotifyOnApproval(_ enabled: Bool) {
        notifyOnApproval = enabled
        UserDefaults.standard.set(enabled, forKey: PrefKeys.notifyApproval)
        if enabled { PushCoordinator.shared.enableNotifications() }
        broadcastPushRegistration()
    }

    func setNotifyOnTurnCompleted(_ enabled: Bool) {
        notifyOnTurnCompleted = enabled
        UserDefaults.standard.set(enabled, forKey: PrefKeys.notifyTurnCompleted)
        if enabled { PushCoordinator.shared.enableNotifications() }
        broadcastPushRegistration()
    }

    // MARK: - 内部

    @discardableResult
    private func run(
        on hostID: UUID, _ body: @escaping @Sendable (CrewCoordinator) async throws -> Void
    ) async -> Bool {
        guard let coordinator = links[hostID]?.coordinator else {
            lastError = "还没连上 bridge"
            return false
        }
        do {
            try await body(coordinator)
            lastError = nil
            return true
        } catch {
            lastError = describeBridgeError(error)
            return false
        }
    }

    private func observeGlasses() {
        Task { [glasses] in
            for await state in glasses.sessionStates {
                await MainActor.run { self.glassesState = state }
            }
        }
        Task { [glasses] in
            for await state in glasses.displayStates {
                await MainActor.run { self.displayState = state }
            }
        }
        Task { [glasses] in
            for await fault in glasses.faults {
                await MainActor.run { self.lastError = String(describing: fault) }
            }
        }
    }

    private enum PrefKeys {
        static let autoPresentApprovals = "glasses.autoPresentApprovals"
        static let notifyApproval = "notify.approvalPush"
        static let notifyTurnCompleted = "notify.turnCompletedPush"
    }
}

/// 配对流程的用户可读失败；PairingScanView 直接展示 message
struct PairingFlowError: Error {
    let message: String
}

/// 安全通道的失败翻成能行动的人话。SecureBridgeConnection 只给 transport 字符串
/// （错误码嵌在文案里），所以靠码名匹配；没认出来的原样透传。
func humanizeSecureError(_ raw: String) -> String {
    if raw.contains("pairing_expired") {
        return "二维码已过期，在 Mac 上运行 lenscrew qr 重新生成"
    }
    if raw.contains("phone_identity_changed") {
        return "Mac 记录的手机身份对不上，在 Mac 上移除这台手机后重新扫码"
    }
    if raw.contains("phone_not_trusted") {
        return "Mac 还不信任这台手机，重新扫码配对"
    }
    if raw.contains("invalid_signature") {
        return "身份校验失败，在 Mac 上重新生成二维码再试"
    }
    if raw.contains("protocol_mismatch") {
        return "App 与 Mac 端协议版本不一致，两边都升级后重试"
    }
    return raw
}

extension SecureBridgeConnection {
    /// connect() 自身不设上限：LAN 地址在蜂窝网/换网后可能要陪系统 TCP 超时耗完，
    /// 盖个盖子让 relay 兜底及时接手。超时用 disconnect() 掐断挂着的握手，
    /// connect() 随之抛出。（15s 边界上握手刚好完成时有微小的误杀窗口，可重连恢复。）
    func connectCapped(seconds: Double) async throws {
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.disconnect()
        }
        defer { watchdog.cancel() }
        try await connect()
    }
}
