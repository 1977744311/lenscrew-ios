import Foundation
import Testing

@testable import AgentProtocol

/// 跨语言契约测试。
///
/// protocol/fixtures/bridge-events.json 是 bridge（TypeScript）与 App（Swift）
/// 共用的黄金样本：TS 侧按它断言自己产出的线上格式，Swift 侧按它断言自己能解出来
/// 并原样编回去。谁先改了线上格式而没同步另一侧，这里就会红。
private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AgentProtocolTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // 仓库根
        .appendingPathComponent("protocol/fixtures/\(name)")
}

@Suite("契约 fixture 往返")
struct ContractFixtureTests {

    @Test("bridge-events.json 每条事件都能解码并原样编回")
    func roundTripsEveryEvent() throws {
        let data = try Data(contentsOf: fixtureURL("bridge-events.json"))
        let rawEvents = try #require(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        #expect(!rawEvents.isEmpty)

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        for raw in rawEvents {
            let originalData = try JSONSerialization.data(withJSONObject: raw)
            let event = try decoder.decode(BridgeEvent.self, from: originalData)
            let reencoded = try encoder.encode(event)
            let reencodedObject = try #require(
                JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
            )
            #expect(
                NSDictionary(dictionary: reencodedObject) == NSDictionary(dictionary: raw),
                "事件 \(raw["type"] ?? "?") seq \(raw["seq"] ?? "?") 往返后不一致"
            )
        }
    }

    @Test("fixture 覆盖了全部九种事件")
    func coversEveryEventType() throws {
        let data = try Data(contentsOf: fixtureURL("bridge-events.json"))
        let rawEvents = try #require(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        let types = Set(rawEvents.compactMap { $0["type"] as? String })
        let expected: Set<String> = [
            "sessionCreated", "sessionStatus", "sessionClosed", "blockAppended",
            "blockUpdated", "approvalRequested", "approvalSettled", "turnCompleted",
            "bridgeError",
        ]
        #expect(types == expected)
    }

    @Test("fixture 覆盖了全部八类流水块")
    func coversEveryBlockKind() throws {
        let data = try Data(contentsOf: fixtureURL("bridge-events.json"))
        let rawEvents = try #require(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        let kinds = Set(
            rawEvents.compactMap { ($0["block"] as? [String: Any])?["kind"] as? String }
        )
        let expected: Set<String> = [
            "userMessage", "agentMessage", "reasoning", "shellCommand",
            "fileChange", "toolCall", "plan", "error",
        ]
        #expect(kinds == expected)
    }

    @Test("客户端指令的线上格式")
    func encodesClientCommands() throws {
        let encoder = JSONEncoder()
        let command = ClientCommand.resolveApproval(
            sessionID: "s-001", approvalID: "a-1", optionID: "approved"
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: try encoder.encode(command))
                as? [String: Any]
        )
        #expect(object["type"] as? String == "resolveApproval")
        #expect(object["sessionId"] as? String == "s-001")
        #expect(object["approvalId"] as? String == "a-1")
        #expect(object["optionId"] as? String == "approved")

        let decoded = try JSONDecoder().decode(
            ClientCommand.self, from: try encoder.encode(command)
        )
        #expect(decoded == command)
    }

    @Test("增量补丁按 kind 各取所需，不匹配的字段忽略")
    func appliesPatchesPerKind() {
        let message = TranscriptBlock.agentMessage(id: "b", text: "你好", streaming: true)
        let updated = message.applying(
            TranscriptBlockPatch(appendText: "，世界", streaming: false)
        )
        #expect(updated == .agentMessage(id: "b", text: "你好，世界", streaming: false))

        let shell = TranscriptBlock.shellCommand(
            id: "c", command: "ls", cwd: nil, output: "a\n",
            exitCode: nil, status: .running
        )
        let finished = shell.applying(
            TranscriptBlockPatch(appendText: "b\n", status: .ok, exitCode: 0)
        )
        #expect(
            finished == .shellCommand(
                id: "c", command: "ls", cwd: nil, output: "a\nb\n",
                exitCode: 0, status: .ok
            )
        )

        // steps 只对 plan 有意义，喂给 shell 应当被忽略而不是崩掉
        #expect(shell.applying(TranscriptBlockPatch(steps: [])) == shell)
    }
}
