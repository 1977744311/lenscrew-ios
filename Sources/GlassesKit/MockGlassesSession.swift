import Foundation

/// 无 SDK、无真机时的假会话。
/// 真机验证要等 Meta Wearables Developer Center 注册 + 眼镜固件到位，
/// 在那之前整条渲染链路靠它跑通并留下可断言的发送记录。
public actor MockGlassesSession: GlassesSessionProviding {
    private let sessionBus = StreamBroadcaster<GlassesSessionState>(replaysLatest: true)
    private let displayBus = StreamBroadcaster<DisplayState>(replaysLatest: true)
    private let thermalBus = StreamBroadcaster<ThermalLevel>(replaysLatest: true)
    private let faultBus = StreamBroadcaster<GlassesFault>()
    private let captouchBus = StreamBroadcaster<CaptouchGesture>()
    private let actionBus = StreamBroadcaster<String>()

    private var started = false
    private var displayAttached = false
    private(set) public var sentPayloads: [DisplayPayload] = []
    private(set) public var clearCount = 0

    public init() {}

    public nonisolated var sessionStates: AsyncStream<GlassesSessionState> {
        sessionBus.subscribe()
    }
    public nonisolated var displayStates: AsyncStream<DisplayState> { displayBus.subscribe() }
    public nonisolated var thermal: AsyncStream<ThermalLevel> { thermalBus.subscribe() }
    public nonisolated var faults: AsyncStream<GlassesFault> { faultBus.subscribe() }
    public nonisolated var captouch: AsyncStream<CaptouchGesture> { captouchBus.subscribe() }
    public nonisolated var displayActions: AsyncStream<String> { actionBus.subscribe() }

    public func start() async throws {
        started = true
        sessionBus.send(.starting)
        sessionBus.send(.started)
    }

    public func stop() async {
        displayAttached = false
        started = false
        displayBus.send(.stopped)
        sessionBus.send(.stopped)
    }

    public func attachDisplay() async throws {
        guard started else { throw GlassesSessionError.sessionNotStarted }
        displayAttached = true
        displayBus.send(.starting)
        displayBus.send(.started)
    }

    public func detachDisplay() async {
        displayAttached = false
        displayBus.send(.stopped)
    }

    public func sendDisplayPayload(_ payload: DisplayPayload) async throws {
        guard displayAttached else { throw GlassesSessionError.displayNotAttached }
        sentPayloads.append(payload)
    }

    public func clearDisplay() async throws {
        guard displayAttached else { throw GlassesSessionError.displayNotAttached }
        clearCount += 1
    }

    // MARK: - 测试注入

    /// 模拟眼镜上点了某个可点区域
    public func simulateTap(actionID: String) {
        captouchBus.send(.tap)
        actionBus.send(actionID)
    }

    public func simulateFault(_ fault: GlassesFault) {
        faultBus.send(fault)
    }

    public func simulateThermal(_ level: ThermalLevel) {
        thermalBus.send(level)
    }
}
