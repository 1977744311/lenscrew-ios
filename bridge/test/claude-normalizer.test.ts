import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";

import type { AdapterEvent } from "../src/adapters/types.ts";
import { ClaudeNormalizer } from "../src/adapters/claude/normalizer.ts";
import type { ClaudeMessage } from "../src/adapters/claude/protocol.ts";
import type { TranscriptBlock } from "../src/protocol/events.ts";

const FIXTURE = join(import.meta.dirname, "..", "..", "protocol", "fixtures", "claude-turn.jsonl");

/** 固定时钟，让 approvalRequested.requestedAtMs 可断言 */
const FIXED_NOW = 1_700_000_000_000;

/**
 * fixture 里存了三段真实会话，用 system/init 切开：
 *   0 Bash 审批放行 + 子 agent + 正常收尾
 *   1 Write 审批拒绝
 *   2 OAuth 过期导致的鉴权失败
 */
function loadSessions(): ClaudeMessage[][] {
  const sessions: ClaudeMessage[][] = [];
  for (const line of readFileSync(FIXTURE, "utf8").split("\n")) {
    if (line.trim().length === 0) continue;
    const message = JSON.parse(line) as ClaudeMessage;
    if (message.type === "system" && (message as { subtype?: string }).subtype === "init") {
      sessions.push([]);
    }
    sessions[sessions.length - 1]?.push(message);
  }
  return sessions;
}

function run(session: ClaudeMessage[]): AdapterEvent[] {
  const normalizer = new ClaudeNormalizer({ now: () => FIXED_NOW });
  return session.flatMap((message) => normalizer.normalize(message));
}

function appended(events: AdapterEvent[]): TranscriptBlock[] {
  return events.flatMap((e) => (e.type === "blockAppended" ? [e.block] : []));
}

function patchesFor(events: AdapterEvent[], blockId: string) {
  return events.flatMap((e) =>
    e.type === "blockUpdated" && e.blockId === blockId ? [e.patch] : [],
  );
}

function blockOfKind<K extends TranscriptBlock["kind"]>(
  events: AdapterEvent[],
  kind: K,
): Extract<TranscriptBlock, { kind: K }> {
  const found = appended(events).find((b) => b.kind === kind);
  assert.ok(found, `事件流里没有 ${kind} 块`);
  return found as Extract<TranscriptBlock, { kind: K }>;
}

const sessions = loadSessions();

test("fixture 切出三段会话", () => {
  assert.equal(sessions.length, 3);
});

test("init 给出原生会话 id、模型和运行态", () => {
  const events = run(sessions[0] ?? []);
  assert.deepEqual(events.slice(0, 3), [
    { type: "nativeIdAssigned", nativeId: "aaaaaaaa-0000-4000-8000-000000000001" },
    { type: "modelResolved", model: "claude-fable-5" },
    { type: "status", status: "running" },
  ]);
});

test("回放的用户消息只上屏一次，且不与工具结果混淆", () => {
  const events = run(sessions[0] ?? []);
  const userBlocks = appended(events).filter((b) => b.kind === "userMessage");
  assert.equal(userBlocks.length, 1);
  assert.equal(
    userBlocks[0]?.kind === "userMessage" ? userBlocks[0].text : "",
    "Run the shell command: echo lenscrew-probe. Then reply with the command output.",
  );
});

test("文本消息：流式增量追加，assistant 整块帧收口", () => {
  const events = run(sessions[0] ?? []);
  const block = blockOfKind(events, "agentMessage");
  assert.equal(block.text, "");
  assert.equal(block.streaming, true);

  const patches = patchesFor(events, block.id);
  assert.deepEqual(
    patches.filter((p) => p.appendText !== undefined).map((p) => p.appendText),
    ["我来运行这个", "命令。"],
  );
  const last = patches.at(-1);
  assert.deepEqual(last, { replaceText: "我来运行这个命令。", streaming: false });
});

test("thinking 块折成 reasoning，不与 agentMessage 混淆", () => {
  const events = run(sessions[0] ?? []);
  const block = blockOfKind(events, "reasoning");
  const patches = patchesFor(events, block.id);
  assert.deepEqual(patches.at(-1), {
    replaceText: "用户要我跑一个 shell 命令。我先调用 Bash 工具。",
    streaming: false,
  });
});

test("Bash 工具调用折成 shellCommand，命令由整块帧回填", () => {
  const events = run(sessions[0] ?? []);
  const block = blockOfKind(events, "shellCommand");
  assert.equal(block.cwd, "/private/tmp/lenscrew/ws");
  assert.equal(block.status, "running");
  assert.equal(block.exitCode, null);

  const patches = patchesFor(events, block.id);
  assert.equal(patches[0]?.replaceText, "curl -sS https://example.com/lenscrew-probe");
});

test("tool_result 回灌 shellCommand 的输出与终态", () => {
  const events = run(sessions[0] ?? []);
  const block = blockOfKind(events, "shellCommand");
  const settled = patchesFor(events, block.id).find((p) => p.status !== undefined);
  assert.ok(settled);
  assert.equal(settled.status, "ok");
  assert.match(settled.appendText ?? "", /Example Domain/);
});

test("can_use_tool 变成带选项的审批请求", () => {
  const events = run(sessions[0] ?? []);
  const approval = events.find((e) => e.type === "approvalRequested");
  assert.ok(approval && approval.type === "approvalRequested");

  assert.equal(approval.approval.kind, "shellCommand");
  assert.equal(approval.approval.detail, "curl -sS https://example.com/lenscrew-probe");
  assert.equal(approval.approval.cwd, "/private/tmp/lenscrew/ws");
  assert.equal(approval.approval.requestedAtMs, FIXED_NOW);
  assert.ok(approval.approval.title.length <= 48);
  assert.deepEqual(
    approval.approval.options.map((o) => o.kind),
    ["allow", "allowAlways", "deny", "abort"],
  );

  // 审批期间会话必须显式转成 awaitingApproval，否则手机端不会弹卡
  const index = events.indexOf(approval);
  assert.deepEqual(events[index + 1], { type: "status", status: "awaitingApproval" });
});

test("子 agent 消息折进父 Task 块的摘要，不另起顶层块", () => {
  const events = run(sessions[0] ?? []);
  const task = blockOfKind(events, "toolCall");
  assert.equal(task.tool, "Task");
  assert.equal(task.source, null);

  const patches = patchesFor(events, task.id);
  assert.equal(patches.at(-1)?.replaceText, "子 agent 勘察完毕：仓库里没有可疑文件。");

  // 子 agent 那条 assistant 帧没有变成独立的 agentMessage
  const agentTexts = appended(events).filter((b) => b.kind === "agentMessage");
  assert.equal(agentTexts.length, 2);
});

test("result 给出 token 统计并把会话置回 idle", () => {
  const events = run(sessions[0] ?? []);
  const completed = events.find((e) => e.type === "turnCompleted");
  assert.deepEqual(completed, {
    type: "turnCompleted",
    inputTokens: 3702,
    outputTokens: 139,
  });
  assert.deepEqual(events.at(-1), { type: "status", status: "idle" });
});

test("Write 折成 fileChange，审批被拒后落 failed", () => {
  const events = run(sessions[1] ?? []);
  const block = blockOfKind(events, "fileChange");
  assert.deepEqual(block.files, []);

  const patches = patchesFor(events, block.id);
  assert.deepEqual(patches[0]?.files, [
    { path: "/tmp/lenscrew/ws/probe.txt", added: 0, removed: 0 },
  ]);
  assert.deepEqual(patches.at(-1), { status: "failed" });

  const approval = events.find((e) => e.type === "approvalRequested");
  assert.ok(approval && approval.type === "approvalRequested");
  assert.equal(approval.approval.kind, "fileChange");
});

test("认证失败：api_retry 非致命，OAuth 过期致命且不重复报", () => {
  const events = run(sessions[2] ?? []);
  const errors = events.filter((e) => e.type === "error");
  assert.equal(errors.length, 2);

  assert.equal(errors[0]?.type === "error" ? errors[0].fatal : true, false);
  assert.match(errors[0]?.type === "error" ? errors[0].message : "", /重试 1\/10 401/);

  assert.deepEqual(errors[1], {
    type: "error",
    message: "Failed to authenticate: OAuth session expired and could not be refreshed",
    fatal: true,
  });

  // result 的 is_error 复述同一句，不能再报一遍，也不能重复置 error 态
  assert.equal(events.filter((e) => e.type === "status" && e.status === "error").length, 1);

  // 即便失败也要给 turnCompleted，否则客户端的转圈停不下来
  assert.deepEqual(events.at(-1), {
    type: "turnCompleted",
    inputTokens: 0,
    outputTokens: 0,
  });
});

test("未开 --include-partial-messages 时整块帧直接成块", () => {
  const normalizer = new ClaudeNormalizer({ now: () => FIXED_NOW });
  const events = normalizer.normalize({
    type: "assistant",
    message: { content: [{ type: "text", text: "没有增量也要能上屏" }] },
    parent_tool_use_id: null,
  } as ClaudeMessage);

  assert.deepEqual(events, [
    {
      type: "blockAppended",
      block: {
        kind: "agentMessage",
        id: "claude-blk-1",
        text: "没有增量也要能上屏",
        streaming: false,
      },
    },
  ]);
});

test("MCP 工具的来源从 mcp__<server>__<tool> 里取", () => {
  const normalizer = new ClaudeNormalizer({ now: () => FIXED_NOW });
  const events = normalizer.normalize({
    type: "assistant",
    message: {
      content: [
        {
          type: "tool_use",
          id: "toolu_mcp_1",
          name: "mcp__notion__search",
          input: { description: "查一下会议纪要" },
        },
      ],
    },
    parent_tool_use_id: null,
  } as ClaudeMessage);

  const block = blockOfKind(events, "toolCall");
  assert.equal(block.source, "notion");
  assert.equal(block.tool, "mcp__notion__search");
  assert.equal(block.summary, "查一下会议纪要");
});
