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

/// 全 App 唯一 VM：连接生命周期、会话快照、眼镜状态、偏好。
@MainActor
@Observable
final class CrewViewModel {
    let hosts = HostStore()

    private(set) var linkState: BridgeLinkState = .disconnected
    private(set) var sessions: [SessionState] = []
    private(set) var glassScreen: GlassScreen = .sessionList
    private(set) var glassesState: GlassesSessionState = .idle
    private(set) var displayState: GlassesKit.DisplayState = .stopped
    private(set) var lastError: String?
    /// /health 往返毫秒数，Home 顶部主机 chip 用；连不上为 nil
    private(set) var latencyMs: Int?
    /// paired 主机实际走的链路（直连/中继）；manual 主机或未连接为 nil
    private(set) var linkPath: HostLinkPath?
    /// 通知深链的目的地（sessionID）；RootView 观察它完成导航后清掉
    private(set) var pendingSessionRoute: String?
    /// sessionID → 轮次分隔线（按到达顺序）
    private(set) var turnMarkers: [String: [TurnMarker]] = [:]
    /// 本机发起创建的会话的模式；listSessions 拉回的旧会话拿不到，不硬猜
    private(set) var sessionModes: [String: SessionMode] = [:]

    // 偏好：落 UserDefaults，键名见 PrefKeys
    private(set) var autoPresentApprovals: Bool
    private(set) var notifyOnApproval: Bool
    private(set) var notifyOnTurnCompleted: Bool

    private let glasses = GlassesRuntime.makeSession()
    private var connection: BridgeConnectionTap?
    private var coordinator: CrewCoordinator?
    /// 当前 paired 主机的安全连接（registerPush 只有它有）；manual 连接时为 nil
    private var secureConnection: SecureBridgeConnection?
    /// APNs device token（hex），注册回调到达后缓存，连接建立/开关变化时重发
    private var apnsTokenHex: String?
    private var pumps: [Task<Void, Never>] = []
    /// 等待与 sessionCreated 配对的创建模式（FIFO，见 digest）
    private var pendingModes: [SessionMode] = []
    /// 旁路流里看到的每个会话最后一个块，turnCompleted 锚点用
    private var lastBlockID: [String: String] = [:]

    var usingMockGlasses: Bool { GlassesRuntime.isMock }

    var isConnected: Bool {
        if case .connected = linkState { return true }
        return false
    }

    var glassesMounted: Bool { displayState == .started }

    /// 跨会话汇总的待审批，按请求时间倒序——最新的最该先看到
    var pendingApprovalItems: [(session: AgentSession, approval: ApprovalRequest)] {
        sessions
            .flatMap { state in state.pendingApprovals.map { (state.session, $0) } }
            .sorted { $0.1.requestedAtMs > $1.1.requestedAtMs }
    }

    init() {
        let defaults = UserDefaults.standard
        autoPresentApprovals =
            defaults.object(forKey: PrefKeys.autoPresentApprovals) as? Bool ?? true
        notifyOnApproval = defaults.object(forKey: PrefKeys.notifyApproval) as? Bool ?? true
        notifyOnTurnCompleted =
            defaults.object(forKey: PrefKeys.notifyTurnCompleted) as? Bool ?? true
        observeGlasses()
    }

    // MARK: - bridge

    func connect() async {
        guard let host = hosts.active else {
            lastError = "先在设置里添加一台电脑"
            return
        }
        await disconnect()
        if host.isPaired {
            await connectPaired(host)
        } else {
            await connectManual(host)
        }
    }

    /// manual 主机：口令 + 明文 HTTP，行为与改造前完全一致
    private func connectManual(_ host: BridgeHostConfig) async {
        guard let baseURL = host.baseURL, !host.host.isEmpty else {
            lastError = "主机地址无效，去设置里改一下"
            return
        }
        let token = hosts.token(for: host.id)
        guard !token.isEmpty else {
            lastError = "这台电脑还没填访问口令"
            return
        }
        do {
            try await start(
                base: HTTPBridgeConnection(
                    endpoint: BridgeEndpoint(baseURL: baseURL, token: token)
                ),
                host: host
            )
            startHealthLoop(baseURL: baseURL)
        } catch {
            lastError = describe(error)
        }
    }

    /// paired 主机：LAN 直连优先，失败且有 relay 再走中继；两条都不通把失败挂到
    /// linkState 上展示。trustedMac 公钥来自 Keychain，走 trusted_reconnect。
    private func connectPaired(_ host: BridgeHostConfig) async {
        guard let publicKey = hosts.macIdentityPublicKey(for: host.id) else {
            lastError = "配对记录不完整（缺 Mac 身份公钥），删除这台电脑后重新扫码"
            return
        }
        let attempts = host.pairedEndpoints(macIdentityPublicKey: publicKey)
        guard !attempts.isEmpty else {
            lastError = "这台电脑没有可用的连接方式，重新扫码配对一次"
            return
        }
        var failure = "无法连接"
        for attempt in attempts {
            let secure = SecureBridgeConnection(endpoint: attempt.endpoint)
            do {
                try await start(base: secure, host: host, capSeconds: 15)
                secureConnection = secure
                linkPath = attempt.path
                // /health 是 bridge 的直连端点，relay 上没有，延迟计量只在直连时有
                if case let .direct(baseURL) = attempt.endpoint.transport {
                    startHealthLoop(baseURL: baseURL)
                }
                await sendPushRegistration()
                return
            } catch {
                failure = humanizeSecureError(describe(error))
                await disconnect()
            }
        }
        lastError = failure
        linkState = .failed(failure)
    }

    /// 两种形态共用的接线：包旁路、起协调器与泵、握手、拉存量会话。
    /// capSeconds 给安全连接的首次握手加上限——LAN 地址不可达时不能陪系统
    /// TCP 超时耗完，否则 relay 兜底迟迟接不了手。
    private func start(
        base: any BridgeConnecting, host: BridgeHostConfig, capSeconds: Double? = nil
    ) async throws {
        let connection = BridgeConnectionTap(wrapping: base)
        let coordinator = CrewCoordinator(bridge: connection, glasses: glasses)
        self.connection = connection
        self.coordinator = coordinator
        await coordinator.setAutoPresentApprovals(autoPresentApprovals)

        pumps.append(
            Task { [weak self] in
                for await state in connection.linkStates {
                    await MainActor.run { self?.absorb(linkState: state) }
                }
            }
        )
        pumps.append(
            Task { [weak self] in
                for await snapshot in coordinator.snapshots {
                    await MainActor.run {
                        self?.sessions = snapshot.sessions
                        self?.glassScreen = snapshot.glassScreen
                    }
                }
            }
        )
        pumps.append(
            Task { [weak self] in
                for await event in connection.tapped {
                    await MainActor.run { self?.digest(event) }
                }
            }
        )
        pumps.append(Task { [glasses] in await coordinator.run(glasses: glasses) })

        if let capSeconds, let secure = base as? SecureBridgeConnection {
            try await secure.connectCapped(seconds: capSeconds)
        } else {
            try await connection.connect()
        }
        // 已经在跑的会话要拉回来，否则手机重启后看不到 Mac 上的现场
        try await connection.send(.listSessions)
        hosts.markConnected(host.id)
        lastError = nil
    }

    /// linkStates 泵的落点：paired 连接每次（重）建立都把推送注册补发一遍——
    /// SecureBridgeConnection 内部断线重连不会重走 connect()，只有这里能看到
    private func absorb(linkState state: BridgeLinkState) {
        linkState = state
        if case .connected = state, secureConnection != nil {
            Task { await self.sendPushRegistration() }
        }
    }

    func disconnect() async {
        for pump in pumps { pump.cancel() }
        pumps = []
        await connection?.disconnect()
        connection = nil
        coordinator = nil
        secureConnection = nil
        linkPath = nil
        sessions = []
        turnMarkers = [:]
        sessionModes = [:]
        pendingModes = []
        lastBlockID = [:]
        latencyMs = nil
        linkState = .disconnected
    }

    /// 切主机 = 断当前连接 → 切 active → 用新配置重连
    func switchHost(to id: UUID) async {
        guard id != hosts.activeHostID else { return }
        await disconnect()
        hosts.setActive(id)
        await connect()
    }

    /// 删除主机；删的是 active 就顺带断开并落到下一台（有的话）
    func removeHost(_ id: UUID) async {
        let wasActive = id == hosts.activeHostID
        if wasActive { await disconnect() }
        hosts.remove(id)
        if wasActive, hosts.active != nil { await connect() }
    }

    /// 改口令后若正连着这台主机，立即用新口令重连
    func updateToken(_ token: String, for id: UUID) async {
        hosts.setToken(token, for: id)
        if id == hosts.activeHostID, isConnected {
            await disconnect()
            await connect()
        }
    }

    // MARK: - 扫码配对

    /// qr_bootstrap 首配：用二维码 payload 建临时连接完成握手（验签通过才算数），
    /// 把学到的 TrustedMac 持久化成 paired 主机并切换过去。之后的每次连接
    /// （包括冷启动）都凭 Keychain 里的公钥走 trusted_reconnect，二维码一次性。
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
                failure = humanizeSecureError(describe(error))
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
            await disconnect()
            hosts.setActive(config.id)
            await connect()
            return
        }
        throw PairingFlowError(message: failure)
    }

    // MARK: - 推送注册

    /// APNs 注册回调送来的 device token（hex）。到达即尝试上报。
    func updatePushToken(_ hex: String) {
        guard hex != apnsTokenHex else { return }
        apnsTokenHex = hex
        Task { await self.sendPushRegistration() }
    }

    /// 幂等重发：token 到达、开关变化、连接（重）建立都整体发一次。
    /// manual 主机没有 registerPush 通道（secureConnection 为 nil），静默跳过。
    private func sendPushRegistration() async {
        guard let secureConnection, isConnected, let apnsTokenHex else { return }
        #if DEBUG
            let environment = "development"
        #else
            let environment = "production"
        #endif
        try? await secureConnection.registerPush(
            deviceToken: apnsTokenHex,
            environment: environment,
            alertsEnabled: PushAlertsEnabled(
                approvals: notifyOnApproval, turns: notifyOnTurnCompleted
            )
        )
    }

    // MARK: - 通知深链

    func routeToSession(_ sessionID: String) {
        pendingSessionRoute = sessionID
    }

    func clearSessionRoute() {
        pendingSessionRoute = nil
    }

    // MARK: - 会话

    func createSession(
        agent: AgentKind, workspaceRoot: String, mode: SessionMode
    ) async {
        await run {
            try await $0.createSession(agent: agent, workspaceRoot: workspaceRoot, mode: mode)
            await MainActor.run {
                self.hosts.remember(root: workspaceRoot)
                self.pendingModes.append(mode)
            }
        }
    }

    func send(_ text: String, to sessionID: String) async {
        await run { try await $0.sendMessage(text, to: sessionID) }
    }

    func interrupt(_ sessionID: String) async {
        await run { try await $0.interrupt(sessionID) }
    }

    func resolve(approval: ApprovalRequest, in sessionID: String, optionID: String) async {
        await run {
            try await $0.resolveApproval(
                sessionID: sessionID, approvalID: approval.id, optionID: optionID
            )
        }
    }

    // MARK: - 眼镜

    func connectGlasses() async {
        do {
            try await glasses.start()
            try await glasses.attachDisplay()
            await coordinator?.displayReattached()
            lastError = nil
        } catch {
            lastError = describe(error)
        }
    }

    func disconnectGlasses() async {
        await glasses.detachDisplay()
        await glasses.stop()
    }

    // MARK: - 偏好

    func setAutoPresentApprovals(_ enabled: Bool) {
        autoPresentApprovals = enabled
        UserDefaults.standard.set(enabled, forKey: PrefKeys.autoPresentApprovals)
        Task { [coordinator] in await coordinator?.setAutoPresentApprovals(enabled) }
    }

    func setNotifyOnApproval(_ enabled: Bool) {
        notifyOnApproval = enabled
        UserDefaults.standard.set(enabled, forKey: PrefKeys.notifyApproval)
        if enabled { PushCoordinator.shared.enableNotifications() }
        Task { await self.sendPushRegistration() }
    }

    func setNotifyOnTurnCompleted(_ enabled: Bool) {
        notifyOnTurnCompleted = enabled
        UserDefaults.standard.set(enabled, forKey: PrefKeys.notifyTurnCompleted)
        if enabled { PushCoordinator.shared.enableNotifications() }
        Task { await self.sendPushRegistration() }
    }

    // MARK: - 内部

    /// 旁路事件消化：只取协调层不外露的信息（轮次用量、创建模式配对），
    /// 会话状态本身仍以 coordinator 的快照为准，两边不重复建状态机。
    private func digest(_ event: BridgeEvent) {
        switch event {
        case let .sessionCreated(_, session):
            if !pendingModes.isEmpty {
                sessionModes[session.id] = pendingModes.removeFirst()
            }

        case let .blockAppended(_, sessionID, block):
            lastBlockID[sessionID] = block.id

        case let .turnCompleted(seq, sessionID, input, output, cached, _):
            // 没有任何用量就不加分隔线——mockup 的 42s/98% 是示意，拿不到不编
            guard input != nil || output != nil else { return }
            guard let anchor = lastBlockID[sessionID] else { return }
            let marker = TurnMarker(
                id: "turn-\(sessionID)-\(seq)", afterBlockID: anchor,
                inputTokens: input, outputTokens: output, cachedInputTokens: cached
            )
            // 断线重连会重放事件，同 seq 的分隔线只收一次
            guard turnMarkers[sessionID]?.contains(where: { $0.id == marker.id }) != true
            else { return }
            turnMarkers[sessionID, default: []].append(marker)

        default:
            break
        }
    }

    /// 每 10 秒探一次 /health 量延迟。无鉴权端点，只做 RTT 计量。
    private func startHealthLoop(baseURL: URL) {
        pumps.append(
            Task { [weak self] in
                while !Task.isCancelled {
                    let ms = await Self.measureHealth(baseURL: baseURL)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self?.latencyMs = ms }
                    try? await Task.sleep(for: .seconds(10))
                }
            }
        )
    }

    private nonisolated static func measureHealth(baseURL: URL) async -> Int? {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 5
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let elapsed = start.duration(to: clock.now)
            let ms = Int(elapsed.components.seconds) * 1000
                + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            return max(ms, 1)
        } catch {
            return nil
        }
    }

    private func run(
        _ body: @escaping @Sendable (CrewCoordinator) async throws -> Void
    ) async {
        guard let coordinator else {
            lastError = "还没连上 bridge"
            return
        }
        do {
            try await body(coordinator)
            lastError = nil
        } catch {
            lastError = describe(error)
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

    private func describe(_ error: any Error) -> String {
        if let linkError = error as? BridgeLinkError {
            switch linkError {
            case .notConnected: return "连接已断开"
            case let .transport(message): return message
            case let .decoding(message): return "解析失败：\(message)"
            }
        }
        return String(describing: error)
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
