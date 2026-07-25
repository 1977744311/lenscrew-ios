// GlassesKit 契约 —— Meta Wearables DAT SDK 的唯一抽象边界。
// 真实适配器在 App/Adapters/GlassesDAT/（canImport(MWDATCore) 守护）；
// 本库内提供 MockGlassesSession，让无 SDK、无真机时也能开发与测试。
//
// 与 lenslive-ios 的同名模块同源，但这里只要 display：LensCrew 不用眼镜相机。
import Foundation

public enum GlassesSessionState: Sendable, Equatable {
    case idle, starting, started, paused, stopping, stopped
}

public enum DisplayState: Sendable, Equatable {
    case stopped, starting, started, stopping
}

public enum ThermalLevel: Sendable, Equatable, Comparable {
    case normal, warm, hot, critical
}

public enum GlassesFault: Sendable, Equatable {
    case bluetoothLost
    case thermal(ThermalLevel)
    case batteryCritical
    /// 来电等系统优先事件抢占会话
    case systemInterrupted
    case capabilityDenied
    case datAppUpdateRequired
}

/// DAT 0.8.0 没有全局手势流：任何点击都归一成 tap，
/// 具体点了哪个区域走 `displayActions` 的 actionID。
/// back 手势在 L0 根视图上直接结束 display 会话，SDK 无独立回调。
public enum CaptouchGesture: Sendable, Equatable {
    case tap
    case backOnRoot
}

public enum GlassesSessionError: Error, Sendable, Equatable {
    case sessionNotStarted
    case displayNotAttached
    case notConnected
    case rendering(String)
    case underlying(String)
}

/// 布局负载：GlassRenderer 的序列化产物。
/// canonicalJSON 同时用作快照测试基准和整屏去重依据——
/// DAT 的 send 是整屏替换，重复内容重发只会白耗蓝牙带宽。
public struct DisplayPayload: Sendable, Equatable {
    public var canonicalJSON: String
    public init(canonicalJSON: String) { self.canonicalJSON = canonicalJSON }
}

public protocol GlassesSessionProviding: Sendable {
    var sessionStates: AsyncStream<GlassesSessionState> { get }
    var displayStates: AsyncStream<DisplayState> { get }
    var thermal: AsyncStream<ThermalLevel> { get }
    var faults: AsyncStream<GlassesFault> { get }
    var captouch: AsyncStream<CaptouchGesture> { get }
    /// 组件 onTap 携带的 actionID；契约外补充，因为 SDK 的手势流不带点击区域信息
    var displayActions: AsyncStream<String> { get }

    func start() async throws
    func stop() async
    func attachDisplay() async throws
    func detachDisplay() async
    /// 整屏替换语义
    func sendDisplayPayload(_ payload: DisplayPayload) async throws
    func clearDisplay() async throws
}
