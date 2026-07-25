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
    /// 连接状态单独成流，不混进 BridgeEvent——那样得为传输层失败伪造 seq，
    /// 会把客户端的断档检测搅乱。
    var linkStates: AsyncStream<BridgeLinkState> { get }
    func send(_ command: ClientCommand) async throws
    func connect() async throws
    func disconnect() async
}

/// SSE 帧解码。
///
/// 下行选 SSE 而不是 WebSocket，是因为 bridge 要保持零第三方依赖——
/// Node 内置 http 就能发 SSE，而 WebSocket 服务端得自己写帧解析或引包。
/// iOS 侧 `URLSession.bytes(for:).lines` 正好是逐行的 AsyncSequence，代价很低。
///
/// **一条 `data:` 行就是一帧**，不等空行。SSE 规范用空行分帧，但实测
/// `AsyncLineSequence` 会把空行直接吞掉（写入 "data: one\n\ndata: two\n" 只产出
/// 两行 data，中间的空行不出现），照规范等空行就永远等不到帧结束。
/// bridge 侧每个事件恒定写成一行 `data: <JSON.stringify(event)>`，JSON 里不会有裸换行，
/// 所以这个前提是成立的——两侧要一起改。空行仍然被当作帧边界处理，
/// 以便换成保留空行的传输时不至于失效。
public struct SSEDecoder: Sendable {
    public init() {}

    /// 逐行喂入，返回解出的一帧数据。
    /// 注释行（以 `:` 开头的心跳）、空行和非 data 字段一律返回 nil。
    public mutating func feed(line: String) -> String? {
        if line.isEmpty || line.hasPrefix(":") { return nil }
        guard let separator = line.firstIndex(of: ":") else { return nil }
        guard line[line.startIndex..<separator] == "data" else { return nil }
        var value = String(line[line.index(after: separator)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        return value.isEmpty ? nil : value
    }
}

/// 测试与无 bridge 开发用的假连接
public final class MockBridgeConnection: BridgeConnecting, @unchecked Sendable {
    private let continuation: AsyncStream<BridgeEvent>.Continuation
    private let stateContinuation: AsyncStream<BridgeLinkState>.Continuation
    public let events: AsyncStream<BridgeEvent>
    public let linkStates: AsyncStream<BridgeLinkState>
    private let lock = NSLock()
    private var sentCommands: [ClientCommand] = []

    public init() {
        var capturedContinuation: AsyncStream<BridgeEvent>.Continuation!
        events = AsyncStream { capturedContinuation = $0 }
        continuation = capturedContinuation

        var capturedStates: AsyncStream<BridgeLinkState>.Continuation!
        linkStates = AsyncStream { capturedStates = $0 }
        stateContinuation = capturedStates
    }

    public func connect() async throws { stateContinuation.yield(.connected) }
    public func disconnect() async {
        stateContinuation.yield(.disconnected)
        continuation.finish()
    }

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
