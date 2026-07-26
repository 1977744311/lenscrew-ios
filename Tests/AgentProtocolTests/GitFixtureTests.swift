import Foundation
import Testing

@testable import AgentProtocol

/// git 面板契约测试的 Swift 半边。
/// protocol/fixtures/git-panel.json 是 TS 与 Swift 共用的黄金样本，
/// TS 侧在 bridge/test/git-fixture.test.ts 断言同一份文件。
private func fixtureURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AgentProtocolTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // 仓库根
        .appendingPathComponent("protocol/fixtures/git-panel.json")
}

private func loadFixture() throws -> (requests: [[String: Any]], outcomes: [[String: Any]]) {
    let data = try Data(contentsOf: fixtureURL())
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return (
        requests: try #require(object["requests"] as? [[String: Any]]),
        outcomes: try #require(object["outcomes"] as? [[String: Any]])
    )
}

@Suite("git 面板契约 fixture 往返")
struct GitFixtureTests {

    @Test("每条请求都能解码并原样编回")
    func roundTripsEveryRequest() throws {
        let fixture = try loadFixture()
        #expect(!fixture.requests.isEmpty)
        for raw in fixture.requests {
            let originalData = try JSONSerialization.data(withJSONObject: raw)
            let request = try JSONDecoder().decode(GitRequest.self, from: originalData)
            let reencoded = try JSONEncoder().encode(request)
            let reencodedObject = try #require(
                JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
            )
            #expect(
                NSDictionary(dictionary: reencodedObject) == NSDictionary(dictionary: raw),
                "请求 \(raw["op"] ?? "?") 往返后不一致"
            )
        }
    }

    @Test("每条应答都能解码并原样编回")
    func roundTripsEveryOutcome() throws {
        let fixture = try loadFixture()
        #expect(!fixture.outcomes.isEmpty)
        for raw in fixture.outcomes {
            let originalData = try JSONSerialization.data(withJSONObject: raw)
            let outcome = try JSONDecoder().decode(GitOutcome.self, from: originalData)
            let reencoded = try JSONEncoder().encode(outcome)
            let reencodedObject = try #require(
                JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
            )
            #expect(
                NSDictionary(dictionary: reencodedObject) == NSDictionary(dictionary: raw),
                "应答 \(raw["kind"] ?? "?") 往返后不一致"
            )
        }
    }

    /// 与 TS 侧同名断言成对存在：任一侧发现覆盖缺口，两边都该补
    @Test("fixture 覆盖了全部十三种请求")
    func coversEveryRequestOp() throws {
        let fixture = try loadFixture()
        let ops = Set(fixture.requests.compactMap { $0["op"] as? String })
        let expected: Set<String> = [
            "status", "diff", "log", "branches", "stage", "unstage", "discard",
            "commit", "push", "pull", "checkout", "stash", "stashPop",
        ]
        #expect(ops == expected)
    }

    @Test("fixture 覆盖了全部五种应答")
    func coversEveryOutcomeKind() throws {
        let fixture = try loadFixture()
        let kinds = Set(fixture.outcomes.compactMap { $0["kind"] as? String })
        #expect(kinds == ["status", "diff", "log", "branches", "done"])
    }

    /// 可空字段的 null 形态必须在 fixture 里出现过，否则手写 encode 漏了
    /// encodeNil 也发现不了
    @Test("fixture 覆盖可空字段的两种形态")
    func coversNullableShapes() throws {
        let fixture = try loadFixture()
        let statuses = fixture.outcomes.compactMap { $0["status"] as? [String: Any] }
        #expect(statuses.contains { $0["branch"] is NSNull })
        #expect(statuses.contains { $0["branch"] is String })
        #expect(statuses.contains { $0["ahead"] is NSNull })
        #expect(statuses.contains { ($0["ahead"] as? Int) != nil })

        let changes = statuses.flatMap {
            (($0["staged"] as? [[String: Any]]) ?? []) + (($0["unstaged"] as? [[String: Any]]) ?? [])
        }
        #expect(changes.contains { $0["oldPath"] is NSNull })
        #expect(changes.contains { $0["oldPath"] is String })
        #expect(changes.contains { ($0["code"] as? String) == "?" })

        let branchOutcomes = fixture.outcomes.filter { ($0["kind"] as? String) == "branches" }
        #expect(branchOutcomes.contains { $0["current"] is NSNull })
        #expect(branchOutcomes.contains { $0["current"] is String })

        let diffRequests = fixture.requests.filter { ($0["op"] as? String) == "diff" }
        #expect(diffRequests.contains { $0["path"] is NSNull })
        #expect(diffRequests.contains { $0["path"] is String })
    }
}
