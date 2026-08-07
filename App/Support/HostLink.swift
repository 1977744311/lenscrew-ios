import AgentProtocol
import BridgeLink
import Foundation
import GlassRenderer
import GlassesKit
import LensCrewCore
import SwiftUI

/// 复合会话键。会话 id 只在单台 Mac 的 bridge 内唯一（两台 Mac 都会有 s-1），
/// App 层一律用 (hostID, sessionID) 寻址：导航、审批裁决、发消息都按它路由，
/// 绝不拿裸 sessionID 当全局键。
struct SessionKey: Hashable, Sendable {
    let hostID: UUID
    let sessionID: String
}

/// 一台主机的连接单元：config → tap + coordinator + 快照 + 泵，自成生命周期。
/// 多台主机各持一个、互不干扰——某台断线/失败只体现在它自己的 linkState 上。
/// 连接逻辑从单连接时代的 CrewViewModel 原样搬来；VM 只负责聚合与路由。
@MainActor
@Observable
final class HostLink: Identifiable {
    let hostID: UUID

    private(set) var linkState: BridgeLinkState = .disconnected
    private(set) var sessions: [SessionState] = []
    private(set) var glassScreen: GlassScreen = .sessionList
    /// /health 往返毫秒数；每台直连主机各测各的，连不上为 nil
    private(set) var latencyMs: Int?
    /// paired 主机实际走的链路（直连/中继）；manual 主机或未连接为 nil
    private(set) var linkPath: HostLinkPath?
    /// sessionID → 轮次分隔线（按到达顺序）；键在本主机命名空间内，不会撞号
    private(set) var turnMarkers: [String: [TurnMarker]] = [:]
    /// 本主机的账号级额度，按 agent 各留最新一份（目前只有 codex 有通道）。
    /// bridge 在接入时会补发缓存快照，断线重连后立即恢复，无需本地持久化
    private(set) var quota: [AgentKind: AgentQuotaSnapshot] = [:]
    /// 旁路侧信道回主线程发布次数（应 ≪ sideChannelEventsSeen；测试/对照用）
    private(set) var sideChannelMainActorHops = 0
    /// 旁路见过的 raw 事件数（含不发布的 delta）
    private(set) var sideChannelEventsSeen = 0
    /// VM 按 hostID 路由动作时直接取用；断开为 nil
    private(set) var coordinator: CrewCoordinator?

    private let store: HostStore
    /// UI 测试夹具注入的内存连接；非 nil 时 connect() 直接用它，跳过真实网络
    private let fixtureConnection: (any BridgeConnecting)?
    /// 本主机的眼镜出口：聚焦走真机，失焦落私有 Mock
    private let glassesGate: FocusRoutedGlassesSession
    private var connection: BridgeConnectionTap?
    /// 本主机为 paired 时的安全连接（registerPush 只有它有）
    private var secureConnection: SecureBridgeConnection?
    private var pumps: [Task<Void, Never>] = []
    private var autoPresentApprovals: Bool
    /// 防止 connectAll 与手动重连并发进场，叠出两套泵
    private var connecting = false
    /// 错误上抛给 VM 的全局错误面；传 nil 表示连接成功、清掉旧错误
    private let reportError: @MainActor (String?) -> Void
    /// 连接（重）建立时向 VM 取一次推送注册参数；token 未到手时为 nil
    private let pushRegistration: @MainActor () -> (tokenHex: String, alerts: PushAlertsEnabled)?

    nonisolated var id: UUID { hostID }

    var isConnected: Bool {
        if case .connected = linkState { return true }
        return false
    }

    init(
        hostID: UUID,
        store: HostStore,
        realGlasses: any GlassesSessionProviding,
        focused: Bool,
        autoPresentApprovals: Bool,
        fixtureConnection: (any BridgeConnecting)? = nil,
        reportError: @escaping @MainActor (String?) -> Void,
        pushRegistration: @escaping @MainActor () -> (tokenHex: String, alerts: PushAlertsEnabled)?
    ) {
        self.hostID = hostID
        self.store = store
        self.fixtureConnection = fixtureConnection
        self.glassesGate = FocusRoutedGlassesSession(real: realGlasses, focused: focused)
        self.autoPresentApprovals = autoPresentApprovals
        self.reportError = reportError
        self.pushRegistration = pushRegistration
    }

    // MARK: - 连接生命周期

    func connect() async {
        guard !connecting else { return }
        connecting = true
        defer { connecting = false }

        guard let host = store.hosts.first(where: { $0.id == hostID }) else { return }
        await disconnect()
        await glassesGate.activate()
        if let fixtureConnection {
            // UI 测试夹具：网络换成内存脚本，泵/协调器等接线与生产完全一致
            do {
                try await start(base: fixtureConnection, host: host)
            } catch {
                reportError(describeBridgeError(error))
            }
            return
        }
        if host.isPaired {
            await connectPaired(host)
        } else {
            await connectManual(host)
        }
    }

    /// manual 主机：口令 + 明文 HTTP，行为与单连接时代完全一致
    private func connectManual(_ host: BridgeHostConfig) async {
        guard let baseURL = host.baseURL, !host.host.isEmpty else {
            reportError("主机地址无效，去设置里改一下")
            return
        }
        let token = store.token(for: host.id)
        guard !token.isEmpty else {
            reportError("这台电脑还没填访问口令")
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
            reportError(describeBridgeError(error))
        }
    }

    /// paired 主机：LAN 直连优先，失败且有 relay 再走中继；两条都不通把失败挂到
    /// linkState 上展示。trustedMac 公钥来自 Keychain，走 trusted_reconnect。
    private func connectPaired(_ host: BridgeHostConfig) async {
        guard let publicKey = store.macIdentityPublicKey(for: host.id) else {
            reportError("配对记录不完整（缺 Mac 身份公钥），删除这台电脑后重新扫码")
            return
        }
        let attempts = host.pairedEndpoints(macIdentityPublicKey: publicKey)
        guard !attempts.isEmpty else {
            reportError("这台电脑没有可用的连接方式，重新扫码配对一次")
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
                failure = humanizeSecureError(describeBridgeError(error))
                await disconnect()
            }
        }
        reportError(failure)
        linkState = .failed(failure)
    }

    /// 两种形态共用的接线：包旁路、起协调器与泵、握手、拉存量会话。
    /// capSeconds 给安全连接的首次握手加上限——LAN 地址不可达时不能陪系统
    /// TCP 超时耗完，否则 relay 兜底迟迟接不了手。
    private func start(
        base: any BridgeConnecting, host: BridgeHostConfig, capSeconds: Double? = nil
    ) async throws {
        let connection = BridgeConnectionTap(wrapping: base)
        let coordinator = CrewCoordinator(bridge: connection, glasses: glassesGate)
        self.connection = connection
        self.coordinator = coordinator
        await coordinator.setAutoPresentApprovals(autoPresentApprovals)

        // 低频流：直接在 MainActor 上落 UI 状态（Task 从本方法继承隔离）
        pumps.append(
            Task { [weak self] in
                for await state in connection.linkStates {
                    self?.absorb(linkState: state)
                }
            }
        )
        // 会话/眼镜屏：coordinator 已在 actor 内消化 raw 事件，这里只收聚合快照
        pumps.append(
            Task { [weak self] in
                for await snapshot in coordinator.snapshots {
                    guard let self else { return }
                    self.sessions = snapshot.sessions
                    self.glassScreen = snapshot.glassScreen
                }
            }
        )
        pumps.append(
            Task { [weak self] in
                for await message in coordinator.hostErrors {
                    self?.reportError(message)
                }
            }
        )
        // 旁路侧信道（轮次分隔线 / 额度）：离主线程消化，仅变更时 hop 一次回主线程。
        // 流式 blockUpdated 风暴不再逐条 MainActor.run（见 SideChannelDigest / hops 计数）。
        pumps.append(
            Task.detached { [weak self, tapped = connection.tapped] in
                var digest = SideChannelDigest()
                for await event in tapped {
                    let changed = digest.ingest(event)
                    guard changed else { continue }
                    let markers = digest.turnMarkers
                    let quota = digest.quota
                    let hops = digest.publishCount
                    let seen = digest.eventsSeen
                    await MainActor.run {
                        guard let self else { return }
                        self.turnMarkers = markers
                        self.quota = quota
                        self.sideChannelMainActorHops = hops
                        self.sideChannelEventsSeen = seen
                    }
                }
            }
        )
        pumps.append(Task { [glassesGate] in await coordinator.run(glasses: glassesGate) })

        if let capSeconds, let secure = base as? SecureBridgeConnection {
            try await secure.connectCapped(seconds: capSeconds)
        } else {
            try await connection.connect()
        }
        // 已在跑的会话不用主动拉：SSE 与 E2EE 通道在接入时都会补发
        // seq-0 快照，客户端拿到快照自会补拉重放窗口
        store.markConnected(host.id)
        reportError(nil)
    }

    /// linkStates 泵的落点：paired 连接每次（重）建立都把推送注册补发一遍——
    /// SecureBridgeConnection 内部断线重连不会重走 connect()，只有这里能看到
    private func absorb(linkState state: BridgeLinkState) {
        linkState = state
        if case .connected = state {
            // 内部自动重连成功不经 start()，挂在全局错误条上的旧连接错误在此清掉
            reportError(nil)
            if secureConnection != nil {
                Task { await self.sendPushRegistration() }
            }
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
        glassScreen = .sessionList
        turnMarkers = [:]
        quota = [:]
        sideChannelMainActorHops = 0
        sideChannelEventsSeen = 0
        latencyMs = nil
        linkState = .disconnected
    }

    /// 彻底下线（删除主机时用）：连接之外还要停掉眼镜网关的转发泵，不留订阅泄漏
    func shutdown() async {
        await disconnect()
        await glassesGate.shutdown()
    }

    // MARK: - 眼镜聚焦

    func setFocused(_ focused: Bool) async {
        await glassesGate.setFocused(focused)
        // 重获焦点时真机屏上还是别台主机的画面，去重基准必须作废并整屏重发
        if focused {
            await coordinator?.displayReattached()
        }
    }

    // MARK: - 偏好与推送

    func setAutoPresentApprovals(_ enabled: Bool) {
        autoPresentApprovals = enabled
        Task { [coordinator] in await coordinator?.setAutoPresentApprovals(enabled) }
    }

    /// git 面板的请求出口：直接走本主机连接的请求-应答通道，不经会话协调层
    func git(_ request: GitRequest) async throws -> GitOutcome {
        guard let connection else { throw BridgeLinkError.notConnected }
        return try await connection.git(request)
    }

    /// 幂等重发：token 到达、开关变化、连接（重）建立都整体发一次。
    /// manual 主机没有 registerPush 通道（secureConnection 为 nil），静默跳过。
    func sendPushRegistration() async {
        guard let secureConnection, isConnected, let info = pushRegistration() else { return }
        #if DEBUG
            let environment = "development"
        #else
            let environment = "production"
        #endif
        try? await secureConnection.registerPush(
            deviceToken: info.tokenHex,
            environment: environment,
            alertsEnabled: info.alerts
        )
    }

    // MARK: - 健康探测

    /// 每 10 秒探一次 /health 量延迟。无鉴权端点，只做 RTT 计量。
    private func startHealthLoop(baseURL: URL) {
        pumps.append(
            Task.detached { [weak self] in
                while !Task.isCancelled {
                    let ms = await HostLink.measureHealth(baseURL: baseURL)
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
}

/// 旁路侧信道纯消化：轮次分隔线与额度不进 CrewStore，由 BridgeConnectionTap 副本喂入。
/// 离主线程跑；仅 `ingest` 返回 true 时才回主线程发布——相对「每条 raw event hop」
/// 在流式 delta 风暴下数量级下降（见 `publishCount` vs `eventsSeen`）。
struct SideChannelDigest: Sendable {
    var lastBlockID: [String: String] = [:]
    var turnMarkers: [String: [TurnMarker]] = [:]
    var quota: [AgentKind: AgentQuotaSnapshot] = [:]
    private(set) var eventsSeen = 0
    private(set) var publishCount = 0

    /// - returns: 是否产生了应对 UI 发布的变更
    mutating func ingest(_ event: BridgeEvent) -> Bool {
        eventsSeen += 1
        switch event {
        case let .blockAppended(_, sessionID, block):
            lastBlockID[sessionID] = block.id
            return false

        case let .turnCompleted(seq, sessionID, input, output, cached, _):
            // 没有任何用量就不加分隔线——mockup 的 42s/98% 是示意，拿不到不编
            guard input != nil || output != nil else { return false }
            guard let anchor = lastBlockID[sessionID] else { return false }
            let marker = TurnMarker(
                id: "turn-\(sessionID)-\(seq)", afterBlockID: anchor,
                inputTokens: input, outputTokens: output, cachedInputTokens: cached
            )
            // 断线重连会重放事件，同 seq 的分隔线只收一次
            guard turnMarkers[sessionID]?.contains(where: { $0.id == marker.id }) != true
            else { return false }
            turnMarkers[sessionID, default: []].append(marker)
            publishCount += 1
            return true

        case let .quotaUpdated(_, snapshot):
            quota[snapshot.agent] = snapshot
            publishCount += 1
            return true

        default:
            return false
        }
    }
}

/// bridge 层错误翻成用户可读文案；连接与动作两侧共用
func describeBridgeError(_ error: any Error) -> String {
    if let linkError = error as? BridgeLinkError {
        switch linkError {
        case .notConnected: return "连接已断开"
        case let .transport(message): return message
        case let .decoding(message): return "解析失败：\(message)"
        }
    }
    return String(describing: error)
}

/// 每台主机的眼镜出口。物理眼镜只有一块：聚焦主机的渲染与点击走真机，
/// 其余主机各自落到私有的 MockGlassesSession，谁都抢不了真机。
/// 切聚焦只翻路由开关——coordinator 和它的导航/去重状态原地不动，
/// 不用为换焦点重建连接或重放事件。
actor FocusRoutedGlassesSession: GlassesSessionProviding {
    private let real: any GlassesSessionProviding
    private let mock = MockGlassesSession()
    private var focused: Bool
    /// coordinator.run 消费的点击流：真机点击只送给聚焦主机
    private let actionBus = StreamBroadcaster<String>()
    private var forwardTask: Task<Void, Never>?

    init(real: any GlassesSessionProviding, focused: Bool) {
        self.real = real
        self.focused = focused
    }

    /// 幂等：首次连接时启动真机点击的转发泵。
    /// 不放 init 里是因为 actor init 不能安全地把 self 交给逃逸任务。
    func activate() {
        guard forwardTask == nil else { return }
        forwardTask = Task { [weak self, real] in
            for await actionID in real.displayActions {
                guard let self else { return }
                await self.forward(actionID)
            }
        }
    }

    func shutdown() {
        forwardTask?.cancel()
        forwardTask = nil
        actionBus.finish()
    }

    func setFocused(_ focused: Bool) {
        self.focused = focused
    }

    private func forward(_ actionID: String) {
        guard focused else { return }
        actionBus.send(actionID)
    }

    private var target: any GlassesSessionProviding { focused ? real : mock }

    // MARK: - GlassesSessionProviding

    nonisolated var displayActions: AsyncStream<String> { actionBus.subscribe() }
    // 状态类流没有 per-host 消费者（VM 直接观察真机会话），给 Mock 的惰性流即可
    nonisolated var sessionStates: AsyncStream<GlassesSessionState> { mock.sessionStates }
    nonisolated var displayStates: AsyncStream<DisplayState> { mock.displayStates }
    nonisolated var thermal: AsyncStream<ThermalLevel> { mock.thermal }
    nonisolated var faults: AsyncStream<GlassesFault> { mock.faults }
    nonisolated var captouch: AsyncStream<CaptouchGesture> { mock.captouch }

    func start() async throws { try await target.start() }
    func stop() async { await target.stop() }
    func attachDisplay() async throws { try await target.attachDisplay() }
    func detachDisplay() async { await target.detachDisplay() }

    /// 失焦时的发送落在私有 Mock 上（未挂载会抛，coordinator 会吞掉），
    /// 真机画面完全归聚焦主机所有
    func sendDisplayPayload(_ payload: DisplayPayload) async throws {
        try await target.sendDisplayPayload(payload)
    }

    func clearDisplay() async throws { try await target.clearDisplay() }
}
