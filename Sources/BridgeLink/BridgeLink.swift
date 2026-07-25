import AgentProtocol
import Foundation

/// bridge 端点。M0 只做同一局域网/Tailscale 内的直连，
/// 端到端加密与二维码配对是下一步——在那之前 token 只是防误连，不是安全边界。
public struct BridgeEndpoint: Sendable, Equatable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}

public enum BridgeLinkError: Error, Sendable, Equatable {
    case notConnected
    case transport(String)
    case decoding(String)
}

/// 与 bridge 的连接抽象。真实实现走 SSE 下行 + POST 上行；
/// 抽掉是为了让协调层能对着 Mock 跑，不需要真的拉起三个 agent。
public protocol BridgeConnecting: Sendable {
    var events: AsyncStream<BridgeEvent> { get }
    func send(_ command: ClientCommand) async throws
    func connect() async throws
    func disconnect() async
}

/// SSE 帧解码。
///
/// 下行选 SSE 而不是 WebSocket，是因为 bridge 要保持零第三方依赖——
/// Node 内置 http 就能发 SSE，而 WebSocket 服务端得自己写帧解析或引包。
/// iOS 侧 URLSession.bytes(for:).lines 正好是逐行的 AsyncSequence，代价很低。
public struct SSEDecoder: Sendable {
    private var dataLines: [String] = []

    public init() {}

    /// 逐行喂入，返回完成的一帧数据（空行代表帧结束）。
    /// 注释行（以 `:` 开头的心跳）和非 data 字段一律忽略。
    public mutating func feed(line: String) -> String? {
        if line.isEmpty {
            defer { dataLines.removeAll() }
            return dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
        }
        if line.hasPrefix(":") { return nil }
        guard let separator = line.firstIndex(of: ":") else { return nil }
        let field = String(line[line.startIndex..<separator])
        guard field == "data" else { return nil }
        var value = String(line[line.index(after: separator)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        dataLines.append(value)
        return nil
    }
}

/// 测试与无 bridge 开发用的假连接
public final class MockBridgeConnection: BridgeConnecting, @unchecked Sendable {
    private let continuation: AsyncStream<BridgeEvent>.Continuation
    public let events: AsyncStream<BridgeEvent>
    private let lock = NSLock()
    private var sentCommands: [ClientCommand] = []

    public init() {
        var capturedContinuation: AsyncStream<BridgeEvent>.Continuation!
        events = AsyncStream { capturedContinuation = $0 }
        continuation = capturedContinuation
    }

    public func connect() async throws {}
    public func disconnect() async { continuation.finish() }

    public func send(_ command: ClientCommand) async throws {
        lock.withLock { sentCommands.append(command) }
    }

    public var commands: [ClientCommand] {
        lock.withLock { sentCommands }
    }

    public func emit(_ event: BridgeEvent) {
        continuation.yield(event)
    }
}
