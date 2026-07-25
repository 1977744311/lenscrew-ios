import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { CursorAcpNormalizer } from "../src/adapters/cursor/acpNormalizer.ts";
import type { AcpWireMessage } from "../src/adapters/cursor/protocol.ts";
import type { AdapterEvent } from "../src/adapters/types.ts";

const FIXTURE = new URL("../../protocol/fixtures/cursor-acp-turn.jsonl", import.meta.url);

/** fixture 录的是往返两个方向的原始 JSON-RPC，normalizer 也正是这么吃的 */
const WORKSPACE = "/tmp/lenscrew-probe/ws";
const FIXED_NOW = 1784986400000;

const TOOL_CALL_ID =
  "call_wTZR7fl1tjUFDdyV21DVHIJC\nfc_06733bc84b6d0d2e016a64bb533ad081938fbedb9b4aa30db6";

const runFixture = (): AdapterEvent[] => {
  const normalizer = new CursorAcpNormalizer({ cwd: WORKSPACE, now: () => FIXED_NOW });
  return readFileSync(FIXTURE, "utf8")
    .split("\n")
    .filter((line) => line.trim() !== "")
    .flatMap((line) => normalizer.normalize(JSON.parse(line) as AcpWireMessage));
};

const summarize = (event: AdapterEvent): string => {
  switch (event.type) {
    case "blockAppended":
      return `blockAppended:${event.block.kind}`;
    case "blockUpdated":
      return `blockUpdated:${Object.keys(event.patch).join("+")}`;
    case "status":
      return `status:${event.status}`;
    default:
      return event.type;
  }
};

const shapeOf = (events: AdapterEvent[]): string[] => {
  const shape: string[] = [];
  let run = 0;
  let previous = "";
  for (const event of events) {
    const current = summarize(event);
    if (current === previous) {
      run += 1;
      shape[shape.length - 1] = `${current} ×${run}`;
      continue;
    }
    previous = current;
    run = 1;
    shape.push(current);
  }
  return shape;
};

test("acp 整轮往返归一成契约事件序列", () => {
  assert.deepEqual(shapeOf(runFixture()), [
    "nativeIdAssigned",
    "modelResolved",
    "status:idle",
    // 用户消息是从我们发出的 session/prompt 造的：cursor 不回显
    "blockAppended:userMessage",
    "status:running",
    "blockAppended:agentMessage",
    "blockUpdated:appendText ×17",
    // 工具调用插进来，先把正在流的文本块收尾
    "blockUpdated:streaming",
    "blockAppended:shellCommand",
    "blockUpdated:status",
    "approvalRequested",
    "approvalSettled",
    "blockUpdated:appendText+exitCode+status",
    "blockAppended:agentMessage",
    "blockUpdated:appendText ×5",
    "blockUpdated:streaming",
    "turnCompleted",
    "status:idle",
  ]);
});

test("session/new 的响应带出原生会话 id 和当前模型", () => {
  const events = runFixture();
  assert.deepEqual(events[0], {
    type: "nativeIdAssigned",
    nativeId: "3c95dd9c-dbd0-4c0b-9cb4-9db1d81713f8",
  });
  assert.deepEqual(events[1], {
    type: "modelResolved",
    model: "gpt-5.4-mini[reasoning=medium]",
  });
});

test("session/request_permission 映射成 approvalRequested，选项照 ACP 给的三项映射", () => {
  const approval = runFixture().find((event) => event.type === "approvalRequested");
  assert.deepEqual(approval, {
    type: "approvalRequested",
    approval: {
      // 审批 id 就是那条请求的 JSON-RPC id；同一时刻不可能有两条同号的待答请求
      id: "0",
      kind: "shellCommand",
      title: "`echo lenscrew-probe`",
      // 请求本身只带一句拒绝理由，命令要从同 toolCallId 的 tool_call 更新里补
      detail: "echo lenscrew-probe\nNot in allowlist: echo",
      // ACP 的 tool_call 不带工作目录，用会话 cwd
      cwd: WORKSPACE,
      options: [
        { id: "allow-once", label: "Allow once", kind: "allow" },
        { id: "allow-always", label: "Allow always", kind: "allowAlways" },
        { id: "reject-once", label: "Reject", kind: "deny" },
      ],
      requestedAtMs: FIXED_NOW,
    },
  });
});

test("我们对审批请求的答复本身翻译成 approvalSettled", () => {
  const settled = runFixture().find((event) => event.type === "approvalSettled");
  assert.deepEqual(settled, {
    type: "approvalSettled",
    approvalId: "0",
    optionId: "allow-once",
    outcome: "resolved",
  });
});

test("shell 块走 pending → running → ok，并带回退出码和输出", () => {
  const events = runFixture();
  const appended = events.find(
    (event) => event.type === "blockAppended" && event.block.kind === "shellCommand",
  );
  assert.deepEqual(appended, {
    type: "blockAppended",
    block: {
      kind: "shellCommand",
      id: TOOL_CALL_ID,
      command: "echo lenscrew-probe",
      cwd: WORKSPACE,
      output: "",
      exitCode: null,
      status: "pending",
    },
  });
  const updates = events.filter(
    (event) => event.type === "blockUpdated" && event.blockId === TOOL_CALL_ID,
  );
  assert.deepEqual(updates, [
    { type: "blockUpdated", blockId: TOOL_CALL_ID, patch: { status: "running" } },
    {
      type: "blockUpdated",
      blockId: TOOL_CALL_ID,
      patch: { appendText: "lenscrew-probe\n", exitCode: 0, status: "ok" },
    },
  ]);
});

test("逐字增量累积进同一个消息块，工具调用之后另起一块", () => {
  const events = runFixture();
  const messageBlocks = events.filter(
    (event) => event.type === "blockAppended" && event.block.kind === "agentMessage",
  );
  assert.equal(messageBlocks.length, 2);

  const textOf = (blockId: string): string =>
    events.reduce((text, event) => {
      if (event.type === "blockAppended" && event.block.kind === "agentMessage" && event.block.id === blockId) {
        return text + event.block.text;
      }
      if (event.type === "blockUpdated" && event.blockId === blockId) {
        return text + (event.patch.appendText ?? "");
      }
      return text;
    }, "");

  assert.equal(textOf("message-2"), "我先直接执行你指定的命令，并把原始输出原样返回。");
  assert.equal(textOf("message-3"), "`lenscrew-probe`");
});

test("prompt 响应只有 stopReason，token 用量只能是 null", () => {
  const events = runFixture();
  assert.deepEqual(events.at(-2), {
    type: "turnCompleted",
    inputTokens: null,
    outputTokens: null,
  });
  assert.deepEqual(events.at(-1), { type: "status", status: "idle" });
});
