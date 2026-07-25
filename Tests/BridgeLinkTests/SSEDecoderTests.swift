import AgentProtocol
import Foundation
import Testing

@testable import BridgeLink

@Suite("SSE 解码")
struct SSEDecoderTests {

    private func drain(_ lines: [String]) -> [String] {
        var decoder = SSEDecoder()
        return lines.compactMap { decoder.feed(line: $0) }
    }

    @Test("空行收帧")
    func emitsFrameOnBlankLine() {
        #expect(drain(["data: {\"a\":1}", ""]) == ["{\"a\":1}"])
    }

    @Test("多行 data 拼成一帧")
    func joinsMultilineData() {
        #expect(drain(["data: a", "data: b", ""]) == ["a\nb"])
    }

    @Test("忽略心跳注释和非 data 字段")
    func ignoresCommentsAndOtherFields() {
        #expect(drain([": keep-alive", "id: 7", "event: x", "data: v", ""]) == ["v"])
    }

    @Test("连续多帧各自独立")
    func decodesConsecutiveFrames() {
        #expect(drain(["data: one", "", "data: two", ""]) == ["one", "two"])
    }

    @Test("多余的空行不产出空帧")
    func skipsEmptyFrames() {
        #expect(drain(["", "", "data: x", "", ""]) == ["x"])
    }

    @Test("解出来的帧能直接喂给事件解码器")
    func framesDecodeIntoBridgeEvents() throws {
        let payload =
            "{\"type\":\"sessionStatus\",\"seq\":2,\"sessionId\":\"s\",\"status\":\"running\"}"
        let frames = drain(["data: " + payload, ""])
        let event = try JSONDecoder().decode(
            BridgeEvent.self, from: Data(try #require(frames.first).utf8)
        )
        #expect(event == .sessionStatus(seq: 2, sessionID: "s", status: .running))
    }
}
