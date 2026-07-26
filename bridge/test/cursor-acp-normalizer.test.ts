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
    // session/new 自陈可用模式与当前模式，两条都要出——UI 的模式切换菜单靠它
    "modesResolved",
    "modeResolved",
    // 可用模型清单同样自陈，模型切换菜单靠它
    "modelsResolved",
    "status:idle",
    // 用户消息是从我们发出的 session/prompt 造的：cursor 不回显
    "blockAppended:userMessage",
    "status:running",
    "titleResolved",
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

test("session/new 的响应带出运行时自陈的模式清单与当前模式", () => {
  const events = runFixture();
  assert.deepEqual(events[2], {
    type: "modesResolved",
    modes: [
      {
        id: "agent",
        label: "Agent",
        detail: "Full agent capabilities with tool access",
      },
      {
        id: "plan",
        label: "Plan",
        detail: "Read-only mode for planning and designing before implementation",
      },
      {
        id: "ask",
        label: "Ask",
        detail: "Q&A mode - no edits or command execution",
      },
    ],
  });
  assert.deepEqual(events[3], { type: "modeResolved", modeId: "agent" });
});

test("current_mode_update 通知回显新模式", () => {
  const normalizer = new CursorAcpNormalizer({ cwd: WORKSPACE, now: () => 1785000000000 });
  const events = normalizer.normalize({
    jsonrpc: "2.0",
    method: "session/update",
    params: {
      sessionId: "3c95dd9c-dbd0-4c0b-9cb4-9db1d81713f8",
      update: { sessionUpdate: "current_mode_update", currentModeId: "ask" },
    },
  } as AcpWireMessage);
  assert.deepEqual(events, [{ type: "modeResolved", modeId: "ask" }]);
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
        { id: "allow-once", label: "Allow once", kind: "allow", scope: "once" },
        { id: "allow-always", label: "Allow always", kind: "allow", scope: "persistent" },
        { id: "reject-once", label: "Reject", kind: "deny", scope: "once" },
      ],
      requestedAtMs: FIXED_NOW,
    },
  });
});

test("四档 ACP 权限选项各自落到正确的 kind + scope", () => {
  // cursor 实测只给三档，reject_always 没在录像里出现过，但 ACP 规范里有，
  // 而且它正是「以后都拒」——scope 丢了就等于把永久拒绝降级成一次性拒绝
  const normalizer = new CursorAcpNormalizer({ cwd: WORKSPACE, now: () => FIXED_NOW });
  const events = normalizer.normalize({
    jsonrpc: "2.0",
    id: 7,
    method: "session/request_permission",
    params: {
      sessionId: "s",
      toolCall: { toolCallId: "t1", title: "rm -rf build", kind: "execute" },
      options: [
        { optionId: "a1", name: "Allow once", kind: "allow_once" },
        { optionId: "a2", name: "Allow always", kind: "allow_always" },
        { optionId: "r1", name: "Reject", kind: "reject_once" },
        { optionId: "r2", name: "Reject always", kind: "reject_always" },
      ],
    },
  });
  const approval = events.find((event) => event.type === "approvalRequested");
  assert.deepEqual(approval?.type === "approvalRequested" ? approval.approval.options : [], [
    { id: "a1", label: "Allow once", kind: "allow", scope: "once" },
    { id: "a2", label: "Allow always", kind: "allow", scope: "persistent" },
    { id: "r1", label: "Reject", kind: "deny", scope: "once" },
    { id: "r2", label: "Reject always", kind: "deny", scope: "persistent" },
  ]);
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
    cachedInputTokens: null,
    stopReason: "completed",
  });
  assert.deepEqual(events.at(-1), { type: "status", status: "idle" });
});

test("session_info_update 产出 titleResolved，标题不再丢失", () => {
  const resolved = runFixture().filter((event) => event.type === "titleResolved");
  assert.deepEqual(resolved, [{ type: "titleResolved", title: "Shell Command Echo" }]);
});

test("清空标题的 session_info_update 不发事件", () => {
  const normalizer = new CursorAcpNormalizer();
  const events = normalizer.normalize({
    jsonrpc: "2.0",
    method: "session/update",
    params: { sessionId: "s", update: { sessionUpdate: "session_info_update", title: null } },
  });
  assert.deepEqual(events, []);
});

/** 走一遍 prompt 请求→响应，取出那条 turnCompleted */
const turnOf = (response: Record<string, unknown>): AdapterEvent | undefined => {
  const normalizer = new CursorAcpNormalizer();
  normalizer.normalize({
    jsonrpc: "2.0",
    id: "lc-1",
    method: "session/prompt",
    params: { sessionId: "s", prompt: [{ type: "text", text: "hi" }] },
  });
  return normalizer
    .normalize({ jsonrpc: "2.0", id: "lc-1", ...response })
    .find((event) => event.type === "turnCompleted");
};

test("ACP 的 stopReason 逐档映射到契约的 TurnStopReason", () => {
  const stopReasonOf = (acp: string | undefined): unknown => {
    const event = turnOf({ result: acp === undefined ? {} : { stopReason: acp } });
    return event?.type === "turnCompleted" ? event.stopReason : "没有 turnCompleted";
  };
  assert.equal(stopReasonOf("end_turn"), "completed");
  assert.equal(stopReasonOf("cancelled"), "interrupted");
  assert.equal(stopReasonOf("max_tokens"), "maxTokens");
  assert.equal(stopReasonOf("refusal"), "refused");
  assert.equal(stopReasonOf("max_turn_requests"), "failed");
  // 运行时没给就是没给，不许瞎猜成 completed
  assert.equal(stopReasonOf(undefined), null);
});

test("prompt 直接报错时也要收一条 stopReason failed 的 turnCompleted", () => {
  const event = turnOf({ error: { code: -32603, message: "Internal error" } });
  assert.deepEqual(event, {
    type: "turnCompleted",
    inputTokens: null,
    outputTokens: null,
    cachedInputTokens: null,
    stopReason: "failed",
  });
});
