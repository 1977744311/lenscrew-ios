// 真实 Meta Wearables DAT SDK (0.8.0) → GlassesSessionProviding 适配。
// 只随 App target 编译，不参与 swift build；整文件由 canImport 守护。
//
// ── 0.8.0 真实 API 与契约的差距（对照 MWDATDisplay/MWDATCore 的 swiftinterface 逐条核过）──
//  · 没有独立的设备选择调用：AutoDeviceSelector 注入 createSession(deviceSelector:)，
//    会话自行等待设备；活跃设备经 selector.activeDeviceStream() 跟随，热观测随之重挂。
//  · session/display 的 start·stop 都是同步的，状态经 stateStream()/statePublisher 回流；
//    只有 display.send / clearDisplay 是 async throws。事件走 Announcer.listen（token 取消），
//    这里统一桥成 AsyncStream。
//  · send 只收 DisplayableView（FlexBox / VideoPlayer），非 FlexBox 根节点要包一层 FlexBox。
//    契约的 gap → spacing、padding(Int) → EdgeInsets(all:)；FlexBox.onClick 只读，可点用 .onTap。
//  · captouch：SDK 没有全局手势流，组件 onTap 归一成 .tap + displayActions(actionID) 两条流。
//    back 手势没有独立回调——L0 上 back 直接结束 display 会话，只能用
//    「display 意外 stopped 但 session 仍 started」这个启发式合成 .backOnRoot（待真机核验）。
//  · ThermalLevel SDK 有 8 档，契约 4 档，按区间归并。
//  · 图标名与 0.8.0 的 116 项目录一一对应，无近似替换。
#if canImport(MWDATCore) && canImport(MWDATDisplay)
import Foundation
import GlassRenderer
import GlassesKit
import MWDATCore
import MWDATDisplay

public actor DATGlassesSessionAdapter: GlassesSessionProviding {

    private let sessionBus = StreamBroadcaster<GlassesSessionState>(replaysLatest: true)
    private let displayBus = StreamBroadcaster<GlassesKit.DisplayState>(replaysLatest: true)
    private let thermalBus = StreamBroadcaster<GlassesKit.ThermalLevel>(replaysLatest: true)
    private let faultBus = StreamBroadcaster<GlassesFault>()
    private let captouchBus = StreamBroadcaster<CaptouchGesture>()
    private let actionBus = StreamBroadcaster<String>()

    private var deviceSelector: AutoDeviceSelector?
    private var session: DeviceSession?
    private var display: MWDATDisplay.Display?

    private var observationTasks: [Task<Void, Never>] = []
    private var thermalTask: Task<Void, Never>?
    private var displayTask: Task<Void, Never>?

    private var lastKnownSessionState: GlassesSessionState = .idle
    private var lastKnownDisplayState: GlassesKit.DisplayState = .stopped
    private var displayDetachRequested = false

    public init() {}

    public nonisolated var sessionStates: AsyncStream<GlassesSessionState> {
        sessionBus.subscribe()
    }
    public nonisolated var displayStates: AsyncStream<GlassesKit.DisplayState> {
        displayBus.subscribe()
    }
    public nonisolated var thermal: AsyncStream<GlassesKit.ThermalLevel> {
        thermalBus.subscribe()
    }
    public nonisolated var faults: AsyncStream<GlassesFault> { faultBus.subscribe() }
    public nonisolated var captouch: AsyncStream<CaptouchGesture> { captouchBus.subscribe() }
    public nonisolated var displayActions: AsyncStream<String> { actionBus.subscribe() }

    // MARK: - 生命周期

    public func start() async throws {
        guard session == nil else { return }
        do {
            try Wearables.configure()
        } catch WearablesError.alreadyConfigured {
            // 重复初始化视为已就绪
        } catch {
            throw GlassesSessionError.underlying(String(describing: error))
        }
        let selector = AutoDeviceSelector(wearables: Wearables.shared) { candidate in
            candidate.supportsDisplay()
        }
        deviceSelector = selector
        do {
            let session = try Wearables.shared.createSession(deviceSelector: selector)
            self.session = session
            try session.start()
            observeSession(session)
            observeThermal(following: selector)
        } catch {
            session = nil
            throw mapSessionError(error)
        }
    }

    public func stop() async {
        stopDisplayObservation()
        thermalTask?.cancel()
        thermalTask = nil
        for task in observationTasks { task.cancel() }
        observationTasks = []
        display?.stop()
        display = nil
        session?.stop()
        session = nil
        deviceSelector = nil
        publishSession(.stopped)
    }

    // MARK: - Display

    public func attachDisplay() async throws {
        guard let session else { throw GlassesSessionError.sessionNotStarted }
        guard display == nil else { return }
        displayDetachRequested = false
        do {
            // 一个 session 同时只能挂一个 display capability
            let display = try session.addDisplay()
            self.display = display
            observeDisplay(display)
            display.start()
        } catch {
            display = nil
            throw mapSessionError(error)
        }
    }

    public func detachDisplay() async {
        displayDetachRequested = true
        stopDisplayObservation()
        if let display {
            publishDisplay(.stopping)
            display.stop()
        }
        display = nil
        publishDisplay(.stopped)
    }

    public func sendDisplayPayload(_ payload: DisplayPayload) async throws {
        guard let display else { throw GlassesSessionError.displayNotAttached }
        let node: GlassNode
        do {
            node = try JSONDecoder().decode(
                GlassNode.self, from: Data(payload.canonicalJSON.utf8)
            )
        } catch {
            throw GlassesSessionError.rendering("payload 解码失败: \(error)")
        }
        let root = translate(node)
        let rootBox = root as? MWDATDisplay.FlexBox ?? MWDATDisplay.FlexBox { root }
        do {
            // 整屏替换；20s 变暗 / 25s 休眠不结束会话，唤醒后可复用旧内容
            try await display.send(rootBox)
        } catch {
            throw mapDisplayError(error)
        }
    }

    public func clearDisplay() async throws {
        guard let display else { throw GlassesSessionError.displayNotAttached }
        do {
            try await display.clearDisplay()
        } catch {
            throw mapDisplayError(error)
        }
    }

    // MARK: - GlassNode → MWDATDisplay

    private func translate(_ node: GlassNode) -> any MWDATDisplay.ViewComponent {
        switch node {
        case let .flexBox(props, children):
            let translated = children.map { translate($0) }
            var box = MWDATDisplay.FlexBox(
                direction: translateDirection(props.direction),
                spacing: CGFloat(props.gap),
                alignment: translateAlignment(props.alignment),
                crossAlignment: translateAlignment(props.crossAlignment),
                padding: MWDATDisplay.EdgeInsets(all: CGFloat(props.padding))
            ) {
                for child in translated { child }
            }
            if let actionID = props.actionID {
                box = box.onTap(makeTapHandler(actionID: actionID))
            }
            return box

        case let .text(content, style, color):
            return MWDATDisplay.Text(
                content,
                style: translateTextStyle(style),
                color: translateTextColor(color)
            )

        case let .button(label, style, actionID):
            return MWDATDisplay.Button(
                label: label,
                style: translateButtonStyle(style),
                onClick: makeTapHandler(actionID: actionID)
            )

        case let .icon(name):
            return MWDATDisplay.Icon(name: translateIcon(name), style: .outline)
        }
    }

    /// 任何点击都归一成 captouch .tap（契约手势流）+ actionID（补充流）
    private func makeTapHandler(actionID: String) -> @Sendable () -> Void {
        let captouchBus = self.captouchBus
        let actionBus = self.actionBus
        return {
            captouchBus.send(.tap)
            actionBus.send(actionID)
        }
    }

    private func translateDirection(_ direction: GlassDirection) -> MWDATDisplay.Direction {
        switch direction {
        case .column: return .column
        case .row: return .row
        }
    }

    private func translateAlignment(_ alignment: GlassAlignment) -> MWDATDisplay.Alignment {
        switch alignment {
        case .start: return .start
        case .center: return .center
        case .end: return .end
        case .stretch: return .stretch
        }
    }

    private func translateTextStyle(_ style: GlassTextStyle) -> MWDATDisplay.TextStyle {
        switch style {
        case .heading: return .heading
        case .body: return .body
        case .meta: return .meta
        }
    }

    private func translateTextColor(_ color: GlassTextColor) -> MWDATDisplay.TextColor {
        switch color {
        case .primary: return .primary
        case .secondary: return .secondary
        }
    }

    private func translateButtonStyle(_ style: GlassButtonStyle) -> MWDATDisplay.ButtonStyle {
        switch style {
        case .primary: return .primary
        case .secondary: return .secondary
        case .outline: return .outline
        }
    }

    private func translateIcon(_ name: GlassIconName) -> MWDATDisplay.IconName {
        switch name {
        case .checkmarkCircle: return .checkmarkCircle
        case .x: return .x
        case .exclamationTriangle: return .exclamationTriangle
        case .exclamationCircle: return .exclamationCircle
        case .arrowLeft: return .arrowLeft
        case .arrowRight: return .arrowRight
        case .twoArrowsClockwise: return .twoArrowsClockwise
        case .code: return .code
        case .pencilSquare: return .pencilSquare
        case .gear: return .gear
        case .bell: return .bell
        case .clock: return .clock
        }
    }

    // MARK: - SDK 观察

    /// Announcer（listen/token 回调）→ AsyncStream；流终止时异步取消订阅
    private func makeStream<T: Sendable>(from announcer: any Announcer<T>) -> AsyncStream<T> {
        AsyncStream { continuation in
            let token = announcer.listen { value in
                continuation.yield(value)
            }
            continuation.onTermination = { _ in
                Task { await token.cancel() }
            }
        }
    }

    private func observeSession(_ session: DeviceSession) {
        let states = session.stateStream()
        observationTasks.append(Task { [weak self] in
            for await state in states {
                await self?.handleSessionState(state)
            }
        })
        let errors = session.errorStream()
        observationTasks.append(Task { [weak self] in
            for await error in errors {
                await self?.handleSessionError(error)
            }
        })
    }

    /// 设备健康挂在设备标识符上，AutoDeviceSelector 换设备时要跟随重挂
    private func observeThermal(following selector: AutoDeviceSelector) {
        let deviceIDs = selector.activeDeviceStream()
        observationTasks.append(Task { [weak self] in
            for await deviceID in deviceIDs {
                await self?.restartThermalObservation(deviceID)
            }
        })
    }

    private func restartThermalObservation(_ deviceID: DeviceIdentifier?) {
        thermalTask?.cancel()
        thermalTask = nil
        guard let deviceID else { return }
        let states = Wearables.shared.deviceStateStream(for: deviceID)
        thermalTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                await self.publishThermal(self.mapThermal(state.thermalLevel))
            }
        }
    }

    private func observeDisplay(_ display: MWDATDisplay.Display) {
        let states = makeStream(from: display.statePublisher)
        displayTask = Task { [weak self] in
            for await state in states {
                await self?.handleDisplayState(state)
            }
        }
    }

    private func stopDisplayObservation() {
        displayTask?.cancel()
        displayTask = nil
    }

    // MARK: - 状态处理

    private func handleSessionState(_ state: DeviceSessionState) {
        let mapped = mapSessionState(state)
        publishSession(mapped)
        if mapped == .paused {
            faultBus.send(.systemInterrupted)
        }
        if mapped == .stopped, lastKnownSessionState == .started {
            faultBus.send(.bluetoothLost)
        }
        lastKnownSessionState = mapped
    }

    private func handleDisplayState(_ state: MWDATDisplay.DisplayState) {
        let mapped = mapDisplayState(state)
        // TODO(真机核验)：back 在 L0 结束 display 会话且无独立回调，
        // 以「非主动 detach、session 仍 started 时 display 走向 stopped」合成 backOnRoot
        if mapped == .stopped, !displayDetachRequested,
           lastKnownSessionState == .started, lastKnownDisplayState == .started {
            captouchBus.send(.backOnRoot)
        }
        lastKnownDisplayState = mapped
        publishDisplay(mapped)
    }

    private func handleSessionError(_ error: DeviceSessionError) {
        guard let fault = mapSessionFault(error) else { return }
        faultBus.send(fault)
    }

    private func publishSession(_ state: GlassesSessionState) { sessionBus.send(state) }
    private func publishDisplay(_ state: GlassesKit.DisplayState) { displayBus.send(state) }
    private func publishThermal(_ level: GlassesKit.ThermalLevel) { thermalBus.send(level) }

    // MARK: - 映射

    private func mapSessionState(_ state: DeviceSessionState) -> GlassesSessionState {
        switch state {
        case .idle: return .idle
        case .starting: return .starting
        case .started: return .started
        case .paused: return .paused
        case .stopping: return .stopping
        case .stopped: return .stopped
        }
    }

    private func mapDisplayState(
        _ state: MWDATDisplay.DisplayState
    ) -> GlassesKit.DisplayState {
        switch state {
        case .stopped: return .stopped
        case .starting: return .starting
        case .started: return .started
        case .stopping: return .stopping
        }
    }

    /// SDK 8 档 → 契约 4 档
    private func mapThermal(_ level: MWDATCore.ThermalLevel) -> GlassesKit.ThermalLevel {
        switch level {
        case .unknown, .none: return .normal
        case .light, .moderate: return .warm
        case .severe: return .hot
        case .critical, .emergency, .shutdown: return .critical
        }
    }

    /// API 使用类错误（session*/capability*）不是运行时故障，返回 nil 不上报
    private func mapSessionFault(_ error: DeviceSessionError) -> GlassesFault? {
        switch error {
        case .thermalCritical, .thermalEmergency:
            return .thermal(.critical)
        case .batteryCritical, .peakPowerShutdown:
            return .batteryCritical
        case .datAppOnTheGlassesUpdateRequired, .dwaUnavailable:
            return .datAppUpdateRequired
        case .noEligibleDevice, .unexpectedError:
            return .bluetoothLost
        case .sessionAlreadyStopped, .sessionAlreadyExists, .sessionIdle,
             .capabilityAlreadyActive, .capabilityNotFound:
            return nil
        }
    }

    private func mapDisplayError(_ error: any Error) -> GlassesSessionError {
        if let displayError = error as? MWDATDisplay.DisplayError {
            switch displayError {
            case .deviceDisconnected, .connectionNotAvailable, .deviceNotFound:
                return .notConnected
            case .invalidVideoURL:
                return .rendering("invalidVideoURL")
            case let .displayError(message):
                return .rendering(message)
            @unknown default:
                return .underlying(String(describing: displayError))
            }
        }
        return .underlying(String(describing: error))
    }

    private func mapSessionError(_ error: any Error) -> GlassesSessionError {
        if let sessionError = error as? DeviceSessionError {
            switch sessionError {
            case .noEligibleDevice:
                return .notConnected
            case .sessionIdle, .sessionAlreadyStopped:
                return .sessionNotStarted
            default:
                return .underlying(String(describing: sessionError))
            }
        }
        return .underlying(String(describing: error))
    }
}
#endif
