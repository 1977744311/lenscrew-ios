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

    @Test("fixture 覆盖了全部十一种事件")
    func coversEveryEventType() throws {
        let data = try Data(contentsOf: fixtureURL("bridge-events.json"))
        let rawEvents = try #require(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        let types = Set(rawEvents.compactMap { $0["type"] as? String })
        let expected: Set<String> = [
            "sessionCreated", "sessionUpdated", "sessionStatus", "sessionClosed",
            "blockAppended", "blockUpdated", "approvalRequested", "approvalSettled",
            "turnCompleted", "bridgeError", "quotaUpdated",
        ]
        #expect(types == expected)
    }

    /// 三档作用范围是安全语义：眼镜上"就这一次"和"永久放行"必须能被区分开，
    /// fixture 里必须三档都在，否则客户端很容易只按 kind 处理就上线了。
    @Test("fixture 覆盖了审批的三档作用范围")
    func coversEveryApprovalScope() throws {
        let data = try Data(contentsOf: fixtureURL("bridge-events.json"))
        let rawEvents = try #require(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        let options = rawEvents
            .compactMap { ($0["approval"] as? [String: Any])?["options"] as? [[String: Any]] }
            .flatMap { $0 }
        #expect(Set(options.compactMap { $0["scope"] as? String }) == ["once", "session", "persistent"])
        #expect(Set(options.compactMap { $0["kind"] as? String }) == ["allow", "deny", "abort"])
    }

    /// 行数增删拿不到时必须是 null，填 0 会被读成"改了但没变化"
    @Test("fileChange 允许行数为空")
    func allowsUnknownDiffStats() throws {
        let data = try Data(contentsOf: fixtureURL("bridge-events.json"))
        let rawEvents = try #require(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        let files = rawEvents
            .compactMap { ($0["block"] as? [String: Any])?["files"] as? [[String: Any]] }
            .flatMap { $0 }
        #expect(files.contains { $0["added"] is NSNull })
        #expect(files.contains { ($0["added"] as? Int) != nil })
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

    @Test("client-commands.json 每条指令都能解码并原样编回")
    func roundTripsEveryClientCommand() throws {
        let data = try Data(contentsOf: fixtureURL("client-commands.json"))
        let rawCommands = try #require(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        #expect(!rawCommands.isEmpty)

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        for raw in rawCommands {
            let originalData = try JSONSerialization.data(withJSONObject: raw)
            let command = try decoder.decode(ClientCommand.self, from: originalData)
            let reencoded = try encoder.encode(command)
            let reencodedObject = try #require(
                JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
            )
            #expect(
                NSDictionary(dictionary: reencodedObject) == NSDictionary(dictionary: raw),
                "指令 \(raw["type"] ?? "?") 往返后不一致"
            )
        }
    }

    @Test("fixture 覆盖了全部十一种 ClientCommand")
    func coversEveryClientCommandType() throws {
        let data = try Data(contentsOf: fixtureURL("client-commands.json"))
        let rawCommands = try #require(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        let types = Set(rawCommands.compactMap { $0["type"] as? String })
        let expected: Set<String> = [
            "listSessions", "createSession", "resumeSession", "sendMessage",
            "interrupt", "resolveApproval", "setSessionMode", "setSessionModel",
            "setSessionReasoningEffort", "closeSession", "subscribe",
        ]
        #expect(types == expected)
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

    @Test("创建与切换模式指令的线上格式")
    func encodesModeCommands() throws {
        let encoder = JSONEncoder()
        // createSession 的 modeId 是 `string | null`，键必须始终存在
        let create = ClientCommand.createSession(
            agent: .codex, workspaceRoot: "/tmp/ws", model: nil, modeID: "auto",
            reasoningEffort: "xhigh"
        )
        let createObject = try #require(
            JSONSerialization.jsonObject(with: try encoder.encode(create)) as? [String: Any]
        )
        #expect(createObject["type"] as? String == "createSession")
        #expect(createObject["modeId"] as? String == "auto")
        #expect(createObject["reasoningEffort"] as? String == "xhigh")
        #expect(createObject["model"] is NSNull)

        let setMode = ClientCommand.setSessionMode(sessionID: "s-001", modeID: "full")
        let setObject = try #require(
            JSONSerialization.jsonObject(with: try encoder.encode(setMode)) as? [String: Any]
        )
        #expect(setObject["type"] as? String == "setSessionMode")
        #expect(setObject["sessionId"] as? String == "s-001")
        #expect(setObject["modeId"] as? String == "full")

        let setModel = ClientCommand.setSessionModel(
            sessionID: "s-001", modelID: "gpt-5.6-terra"
        )
        let modelObject = try #require(
            JSONSerialization.jsonObject(with: try encoder.encode(setModel)) as? [String: Any]
        )
        #expect(modelObject["type"] as? String == "setSessionModel")
        #expect(modelObject["sessionId"] as? String == "s-001")
        #expect(modelObject["modelId"] as? String == "gpt-5.6-terra")

        for command in [create, setMode, setModel] {
            let decoded = try JSONDecoder().decode(
                ClientCommand.self, from: try encoder.encode(command)
            )
            #expect(decoded == command)
        }
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
