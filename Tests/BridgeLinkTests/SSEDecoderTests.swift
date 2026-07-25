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

    @Test("一条 data 行即一帧，不等空行")
    func emitsFrameOnEachDataLine() {
        #expect(drain(["data: {\"a\":1}"]) == ["{\"a\":1}"])
    }

    /// 实测 AsyncLineSequence 会吞掉空行，照 SSE 规范等空行分帧就永远等不到；
    /// bridge 因此保证每个事件恒定写成一行 data。
    @Test("连续 data 行各自成帧，中间有没有空行都一样")
    func treatsEachDataLineIndependently() {
        #expect(drain(["data: a", "data: b"]) == ["a", "b"])
        #expect(drain(["data: a", "", "data: b", ""]) == ["a", "b"])
    }

    @Test("忽略心跳注释和非 data 字段")
    func ignoresCommentsAndOtherFields() {
        #expect(drain([": keep-alive", "id: 7", "event: x", "data: v"]) == ["v"])
    }

    @Test("空行不产出空帧")
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
