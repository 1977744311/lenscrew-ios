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
    private(set) var glassesState: GlassesSessionState = .idle
    private(set) var displayState: GlassesKit.DisplayState = .stopped
    private(set) var sessions: [SessionState] = []
    private(set) var screen: GlassScreen = .sessionList
    private(set) var lastError: String?

    private let glasses = GlassesRuntime.makeSession()
    private let bridge = MockBridgeConnection()
    private let coordinator: CrewCoordinator

    var usingMockGlasses: Bool { GlassesRuntime.isMock }

    init() {
        coordinator = CrewCoordinator(bridge: bridge, glasses: glasses)
        observeGlasses()
        Task { await coordinator.run(glasses: glasses) }
    }

    func connectGlasses() async {
        do {
            try await glasses.start()
            try await glasses.attachDisplay()
            await coordinator.displayReattached()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    func disconnectGlasses() async {
        await glasses.detachDisplay()
        await glasses.stop()
    }

    /// bridge 传输层落地前，用脚本事件验证整条渲染链路
    func playDemoFeed() async {
        for event in DemoFeed.events() {
            await coordinator.ingest(event)
            try? await Task.sleep(for: .milliseconds(400))
            await refresh()
        }
    }

    private func refresh() async {
        sessions = await coordinator.sessions
        screen = await coordinator.screen
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
        Task { [glasses] in
            // 眼镜上的点击会改导航状态，手机端要跟着刷新
            for await _ in glasses.displayActions {
                await self.refresh()
            }
        }
    }
}
