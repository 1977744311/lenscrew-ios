import AgentProtocol
import Foundation
import Testing

@testable import LensCrew

/// 证明旁路侧信道不会对高频 blockUpdated / 无用量 turn 逐条要求主线程发布。
@Suite("SideChannelDigest hop reduction")
struct SideChannelDigestTests {

    private func block(_ id: String) -> TranscriptBlock {
        .agentMessage(id: id, text: "x", streaming: true)
    }

    @Test("流式 block 风暴：N 条事件 → 0 次发布")
    func streamingDeltasDoNotPublish() {
        var digest = SideChannelDigest()
        for i in 1...200 {
            let event: BridgeEvent =
                i % 2 == 0
                ? .blockAppended(seq: i, sessionID: "s-1", block: block("b-\(i)"))
                : .blockUpdated(
                    seq: i, sessionID: "s-1", blockID: "b-1",
                    patch: TranscriptBlockPatch(appendText: "delta \(i)", streaming: true)
                )
            #expect(digest.ingest(event) == false)
        }
        #expect(digest.eventsSeen == 200)
        #expect(digest.publishCount == 0)
        #expect(digest.turnMarkers.isEmpty)
        #expect(digest.quota.isEmpty)
    }

    @Test("有用量的 turnCompleted 与 quotaUpdated 才发布；重复 seq 不二次发布")
    func turnAndQuotaPublishOnce() {
        var digest = SideChannelDigest()
        #expect(digest.ingest(.blockAppended(seq: 1, sessionID: "s-1", block: block("b-1"))) == false)

        #expect(
            digest.ingest(
                .turnCompleted(
                    seq: 2, sessionID: "s-1",
                    inputTokens: 10, outputTokens: 3, cachedInputTokens: 2, stopReason: nil
                )
            ) == true
        )
        #expect(digest.publishCount == 1)
        #expect(digest.turnMarkers["s-1"]?.count == 1)

        // 重放同 seq：不二次发布
        #expect(
            digest.ingest(
                .turnCompleted(
                    seq: 2, sessionID: "s-1",
                    inputTokens: 10, outputTokens: 3, cachedInputTokens: 2, stopReason: nil
                )
            ) == false
        )
        #expect(digest.publishCount == 1)

        // 无用量：不发布
        #expect(
            digest.ingest(
                .turnCompleted(
                    seq: 3, sessionID: "s-1",
                    inputTokens: nil, outputTokens: nil, cachedInputTokens: nil, stopReason: nil
                )
            ) == false
        )

        let quota = AgentQuotaSnapshot(
            agent: .codex, planType: "pro",
            windows: [], capturedAtMs: 1
        )
        #expect(digest.ingest(.quotaUpdated(seq: 0, quota: quota)) == true)
        #expect(digest.publishCount == 2)
        #expect(digest.quota[.codex]?.planType == "pro")

        // 200 次噪声 + 上述事件：发布次数仍是 2
        for i in 100..<300 {
            _ = digest.ingest(
                .blockUpdated(
                    seq: i, sessionID: "s-1", blockID: "b-1",
                    patch: TranscriptBlockPatch(appendText: "n\(i)", streaming: true)
                )
            )
        }
        #expect(digest.publishCount == 2)
        #expect(digest.eventsSeen >= 200)
        #expect(digest.publishCount * 50 < digest.eventsSeen)
    }
}
