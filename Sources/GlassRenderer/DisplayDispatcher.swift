import Foundation
import GlassesKit

/// 发送决策。DAT 的 send 是整屏替换、内容走蓝牙序列化，
/// 所以重复内容不发、窗口内的连续更新合并成一次尾沿发送。
public enum DisplayDecision: Sendable, Equatable {
    case send
    /// 内容与上一屏一致，发了也是同一幅画面
    case skipDuplicate
    /// 距上次发送不足节流窗口；调用方应在这个时刻重试最新内容
    case deferUntil(TimeInterval)
}

/// 节流与去重的纯逻辑。时间由外部传入，测试不需要真的等。
public struct DisplayThrottle: Sendable, Equatable {
    public var minimumInterval: TimeInterval
    private var lastSentJSON: String?
    private var lastSentAt: TimeInterval?

    public init(minimumInterval: TimeInterval = 1.0) {
        self.minimumInterval = minimumInterval
    }

    /// - Parameter immediate: 绕过节流窗口。节流是为了省流式刷新的蓝牙带宽，
    ///   而审批卡是 agent 卡住等人的信号，压一秒才上屏没有道理。去重仍然生效。
    public mutating func decide(
        canonicalJSON: String, now: TimeInterval, immediate: Bool = false
    ) -> DisplayDecision {
        if canonicalJSON == lastSentJSON { return .skipDuplicate }
        if !immediate, let lastSentAt {
            let earliest = lastSentAt + minimumInterval
            if now < earliest { return .deferUntil(earliest) }
        }
        lastSentJSON = canonicalJSON
        lastSentAt = now
        return .send
    }

    /// 断连后重挂 display：眼镜屏已经是空的，去重基准必须一并作废，
    /// 否则重连后第一屏会被当成重复内容吞掉。
    public mutating func invalidate() {
        lastSentJSON = nil
    }
}

/// 把布局树按节流策略送上眼镜。
public actor DisplayDispatcher {
    private let session: any GlassesSessionProviding
    private var throttle: DisplayThrottle
    private var pending: String?
    private var flushTask: Task<Void, Never>?

    public init(
        session: any GlassesSessionProviding, minimumInterval: TimeInterval = 1.0
    ) {
        self.session = session
        self.throttle = DisplayThrottle(minimumInterval: minimumInterval)
    }

    public func submit(_ node: GlassNode, immediate: Bool = false) async throws {
        let json = try GlassNodeEncoder.canonicalJSON(node)
        try await submit(canonicalJSON: json, immediate: immediate)
    }

    /// 断连重挂后调用，让下一屏必定重发
    public func invalidateCache() {
        throttle.invalidate()
    }

    private func submit(canonicalJSON json: String, immediate: Bool = false) async throws {
        switch throttle.decide(
            canonicalJSON: json, now: Date().timeIntervalSince1970, immediate: immediate
        ) {
        case .skipDuplicate:
            return
        case .send:
            pending = nil
            try await session.sendDisplayPayload(DisplayPayload(canonicalJSON: json))
        case let .deferUntil(deadline):
            // 尾沿合并：窗口内只保留最新一屏，到点再发一次
            pending = json
            scheduleFlush(at: deadline)
        }
    }

    private func scheduleFlush(at deadline: TimeInterval) {
        guard flushTask == nil else { return }
        let delay = max(deadline - Date().timeIntervalSince1970, 0)
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.flush()
        }
    }

    private func flush() async {
        flushTask = nil
        guard let json = pending else { return }
        pending = nil
        try? await submit(canonicalJSON: json)
    }
}
