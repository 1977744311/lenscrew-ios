#!/usr/bin/env node
// 端到端测试用的 bridge 服务入口：HTTP、SSE、会话总线全是真的，
// 只有 agent 运行时换成脚本化的假 adapter——真拉起三个 agent 会让测试变慢、
// 花钱、还依赖登录状态，而这里要验的是传输层和事件链路，不是模型输出。
//
// 由 Tests/LensCrewCoreTests/EndToEndTests.swift 与 BridgeLinkTests 的 secure e2e 拉起。
// 就绪后往 stdout 依次打一行 PAIR <配对payload> 和一行 READY <端口>：
// 明文链路只消费 READY；secure e2e 用 PAIR 构造 qr_bootstrap 握手材料。
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { SessionHub } from "../src/session/hub.ts";
import { createBridgeServer } from "../src/transport/server.ts";
import { SecureGateway } from "../src/secure/secureGateway.ts";
import { loadOrCreateIdentity } from "../src/state/stateDir.ts";
import type { AdapterEventSink, AgentAdapter } from "../src/adapters/types.ts";
import type { AgentCapabilities } from "../src/protocol/events.ts";

const CAPABILITIES: AgentCapabilities = {
  approvals: true,
  steering: true,
  interrupt: true,
  planMode: true,
  resume: true,
  streamingDeltas: true,
};

/** 提示词里出现这个词就走审批分支，测试据此驱动审批链路 */
const APPROVAL_TRIGGER = "需要审批";

class ScriptedAdapter implements AgentAdapter {
  readonly kind = "codex" as const;
  readonly capabilities = CAPABILITIES;
  readonly #sink: AdapterEventSink;
  #blockOrdinal = 0;
  #pendingApprovalId: string | null = null;

  constructor(sink: AdapterEventSink) {
    this.#sink = sink;
  }

  async start(): Promise<void> {
    this.#sink({ type: "nativeIdAssigned", nativeId: "thread-e2e" });
    this.#sink({ type: "modelResolved", model: "scripted" });
    this.#sink({ type: "status", status: "idle" });
  }

  async sendMessage(text: string): Promise<void> {
    const userId = this.#nextId();
    this.#sink({
      type: "blockAppended",
      block: { kind: "userMessage", id: userId, text, imageCount: 0 },
    });
    this.#sink({ type: "status", status: "running" });

    const replyId = this.#nextId();
    this.#sink({
      type: "blockAppended",
      block: { kind: "agentMessage", id: replyId, text: "", streaming: true },
    });
    // 拆成两片增量，好让客户端的增量合并逻辑真的被走到
    this.#sink({
      type: "blockUpdated",
      blockId: replyId,
      patch: { appendText: "收到：" },
    });
    this.#sink({
      type: "blockUpdated",
      blockId: replyId,
      patch: { appendText: text, streaming: false },
    });

    if (!text.includes(APPROVAL_TRIGGER)) {
      this.#finishTurn();
      return;
    }

    const approvalId = `ap-${this.#blockOrdinal}`;
    this.#pendingApprovalId = approvalId;
    this.#sink({
      type: "approvalRequested",
      approval: {
        id: approvalId,
        kind: "shellCommand",
        title: "运行 echo lenscrew",
        detail: "echo lenscrew",
        cwd: "/tmp",
        options: [
          { id: "accept", label: "批准", kind: "allow", scope: "once" },
          {
            id: "acceptForSession",
            label: "本会话都批",
            kind: "allow",
            scope: "session",
          },
          { id: "decline", label: "拒绝", kind: "deny", scope: "once" },
        ],
        requestedAtMs: 0,
      },
    });
  }

  async interrupt(): Promise<void> {
    this.#sink({
      type: "turnCompleted",
      inputTokens: null,
      outputTokens: null,
      cachedInputTokens: null,
      stopReason: "interrupted",
    });
    this.#sink({ type: "status", status: "idle" });
  }

  async resolveApproval(approvalId: string, optionId: string): Promise<void> {
    if (this.#pendingApprovalId !== approvalId) {
      throw new Error(`未知审批 ${approvalId}`);
    }
    this.#pendingApprovalId = null;
    this.#sink({
      type: "approvalSettled",
      approvalId,
      optionId,
      outcome: "resolved",
    });

    const allowed = optionId !== "decline";
    const commandId = this.#nextId();
    this.#sink({
      type: "blockAppended",
      block: {
        kind: "shellCommand",
        id: commandId,
        command: "echo lenscrew",
        cwd: "/tmp",
        output: "",
        exitCode: null,
        status: allowed ? "running" : "rejected",
      },
    });
    if (allowed) {
      this.#sink({
        type: "blockUpdated",
        blockId: commandId,
        patch: { appendText: "lenscrew\n", status: "ok", exitCode: 0 },
      });
    }
    this.#finishTurn();
  }

  async close(): Promise<void> {
    this.#sink({ type: "status", status: "ended" });
  }

  #finishTurn(): void {
    this.#sink({
      type: "turnCompleted",
      inputTokens: 100,
      outputTokens: 20,
      cachedInputTokens: 80,
      stopReason: "completed",
    });
    this.#sink({ type: "status", status: "idle" });
  }

  #nextId(): string {
    this.#blockOrdinal += 1;
    return `b-${this.#blockOrdinal}`;
  }
}

function argValue(flag: string, fallback: string): string {
  const index = process.argv.indexOf(flag);
  return index >= 0 ? (process.argv[index + 1] ?? fallback) : fallback;
}

const port = Number(argValue("--port", "0"));
const token = argValue("--token", "e2e-token");

const hub = new SessionHub((_kind, sink) => new ScriptedAdapter(sink));

// secure e2e 用的 E2EE 网关：身份/信任表落一次性临时目录，配对窗口常开——
// 这是测试服务器，Swift 侧每次都要能走 qr_bootstrap 首配
const stateDir = mkdtempSync(join(tmpdir(), "lenscrew-e2e-secure-"));
const identity = loadOrCreateIdentity(stateDir);
const gateway = new SecureGateway({
  hub,
  identity,
  stateDir,
  displayName: "E2E Mac",
  pairingWindow: { isOpen: () => true, expiresAtMs: () => Date.now() + 300_000 },
});

const server = createBridgeServer({ hub, token, host: "127.0.0.1", port, gateway });

server.listen(port, "127.0.0.1", () => {
  const address = server.address();
  const boundPort = typeof address === "object" && address !== null ? address.port : port;
  const pairPayload = {
    v: 1,
    kind: "lenscrew-pair",
    macDeviceId: identity.macDeviceId,
    macIdentityPublicKey: identity.identityPublicKey,
    displayName: "E2E Mac",
    expiresAtMs: Date.now() + 300_000,
    lan: { host: "127.0.0.1", port: boundPort },
  };
  process.stdout.write(`PAIR ${JSON.stringify(pairPayload)}\n`);
  process.stdout.write(`READY ${boundPort}\n`);
});

const shutdown = (): void => {
  gateway.close();
  server.close();
  void hub.closeAll().then(() => process.exit(0));
};
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
