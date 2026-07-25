import AgentProtocol
import BridgeLink
import Foundation

/// 给 bridge 连接包一层旁路：事件原样转发给协调层，同时复制一份给 UI。
///
/// 需要它是因为 turnCompleted 的用量（tokens）不进 CrewStore 的流水，
/// 而 AsyncStream 只允许单消费者——直接让 VM 和 coordinator 抢同一条流，
/// 事件会被随机瓜分。App 层包一层就能拿到用量做轮次分隔线，不用改库层契约。
final class BridgeConnectionTap: BridgeConnecting, @unchecked Sendable {
    private let base: any BridgeConnecting
    /// 协调层消费的主流
    let events: AsyncStream<BridgeEvent>
    /// UI 消费的旁路副本
    let tapped: AsyncStream<BridgeEvent>
    var linkStates: AsyncStream<BridgeLinkState> { base.linkStates }
    private let pump: Task<Void, Never>

    init(wrapping base: any BridgeConnecting) {
        self.base = base

        var capturedMain: AsyncStream<BridgeEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { capturedMain = $0 }
        var capturedTap: AsyncStream<BridgeEvent>.Continuation!
        tapped = AsyncStream(bufferingPolicy: .unbounded) { capturedTap = $0 }

        let main = capturedMain!
        let tap = capturedTap!
        pump = Task {
            for await event in base.events {
                main.yield(event)
                tap.yield(event)
            }
            main.finish()
            tap.finish()
        }
    }

    func connect() async throws { try await base.connect() }

    func disconnect() async {
        pump.cancel()
        await base.disconnect()
    }

    func send(_ command: ClientCommand) async throws { try await base.send(command) }
}
