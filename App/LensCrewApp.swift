import AgentProtocol
import BridgeLink
import GlassRenderer
import GlassesKit
import LensCrewCore
import SwiftUI

@main
struct LensCrewApp: App {
    var body: some Scene {
        WindowGroup {
            HomeScreen(model: CrewViewModel())
        }
    }
}

@MainActor
@Observable
final class CrewViewModel {
    var settings = BridgeSettings.load()

    private(set) var linkState: BridgeLinkState = .disconnected
    private(set) var sessions: [SessionState] = []
    private(set) var glassScreen: GlassScreen = .sessionList
    private(set) var glassesState: GlassesSessionState = .idle
    private(set) var displayState: GlassesKit.DisplayState = .stopped
    private(set) var lastError: String?

    private let glasses = GlassesRuntime.makeSession()
    private var connection: HTTPBridgeConnection?
    private var coordinator: CrewCoordinator?
    private var pumps: [Task<Void, Never>] = []

    var usingMockGlasses: Bool { GlassesRuntime.isMock }

    var isConnected: Bool {
        if case .connected = linkState { return true }
        return false
    }

    init() {
        observeGlasses()
    }

    // MARK: - bridge

    func connect() async {
        guard let baseURL = settings.baseURL, settings.isComplete else {
            lastError = "先把主机、端口和口令填完整"
            return
        }
        await disconnect()
        settings.save()

        let connection = HTTPBridgeConnection(
            endpoint: BridgeEndpoint(baseURL: baseURL, token: settings.token)
        )
        let coordinator = CrewCoordinator(bridge: connection, glasses: glasses)
        self.connection = connection
        self.coordinator = coordinator

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
        pumps.append(Task { [glasses] in await coordinator.run(glasses: glasses) })

        do {
            try await connection.connect()
            // 已经在跑的会话要拉回来，否则手机重启后看不到 Mac 上的现场
            try await connection.send(.listSessions)
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
        linkState = .disconnected
    }

    // MARK: - 会话

    func createSession(agent: AgentKind, workspaceRoot: String) async {
        await run {
            try await $0.createSession(agent: agent, workspaceRoot: workspaceRoot)
            await MainActor.run { self.settings.remember(root: workspaceRoot) }
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

    // MARK: - 内部

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
}
