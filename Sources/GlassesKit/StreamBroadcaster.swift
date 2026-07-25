// AsyncStream 多订阅广播器。
// 契约的各状态流属性是 `{ get }`，而 AsyncStream 是单消费者类型——
// 每次属性访问返回一条独立订阅流，由本类型统一扇出。
// Mock 与真实 DAT 适配器（App 层）共用。
import Foundation

public final class StreamBroadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var latest: Element?
    private var finished = false
    private let replaysLatest: Bool

    /// - Parameter replaysLatest: 状态类流传 true——新订阅者立即收到最近一次值；
    ///   事件类流（fault / captouch / action）传 false。
    public init(replaysLatest: Bool = false) {
        self.replaysLatest = replaysLatest
    }

    public func subscribe() -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            lock.lock()
            if finished {
                lock.unlock()
                continuation.finish()
                return
            }
            continuations[id] = continuation
            let replay = replaysLatest ? latest : nil
            lock.unlock()

            if let replay { continuation.yield(replay) }
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
        }
    }

    public func send(_ value: Element) {
        lock.lock()
        latest = value
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets { continuation.yield(value) }
    }

    public func finish() {
        lock.lock()
        finished = true
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets { continuation.finish() }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
