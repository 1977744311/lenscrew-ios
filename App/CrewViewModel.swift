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
        guard let baseURL = host.baseURL, !host.host.isEmpty else {
            lastError = "主机地址无效，去设置里改一下"
            return
        }
        let token = hosts.token(for: host.id)
        guard !token.isEmpty else {
            lastError = "这台电脑还没填访问口令"
            return
        }
        await disconnect()

        let connection = BridgeConnectionTap(
            wrapping: HTTPBridgeConnection(
                endpoint: BridgeEndpoint(baseURL: baseURL, token: token)
            )
        )
        let coordinator = CrewCoordinator(bridge: connection, glasses: glasses)
        self.connection = connection
        self.coordinator = coordinator
        await coordinator.setAutoPresentApprovals(autoPresentApprovals)

        pumps.append(
            Task { [weak self] in
                for await state in connection.linkStates {
                    await MainActor.run { self?.linkState = state }
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

        do {
            try await connection.connect()
            // 已经在跑的会话要拉回来，否则手机重启后看不到 Mac 上的现场
            try await connection.send(.listSessions)
            hosts.markConnected(host.id)
            startHealthLoop(baseURL: baseURL)
            lastError = nil
        } catch {
            lastError = describe(error)
        }
    }

    func disconnect() async {
        for pump in pumps { pump.cancel() }
        pumps = []
        await connection?.disconnect()
        connection = nil
        coordinator = nil
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
    }

    func setNotifyOnTurnCompleted(_ enabled: Bool) {
        notifyOnTurnCompleted = enabled
        UserDefaults.standard.set(enabled, forKey: PrefKeys.notifyTurnCompleted)
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
