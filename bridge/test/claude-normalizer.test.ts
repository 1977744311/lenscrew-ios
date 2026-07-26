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

test("init 给出原生会话 id、模型、权限档和运行态", () => {
  const events = run(sessions[0] ?? []);
  assert.deepEqual(events.slice(0, 4), [
    { type: "nativeIdAssigned", nativeId: "aaaaaaaa-0000-4000-8000-000000000001" },
    { type: "modelResolved", model: "claude-fable-5" },
    // 录制时 CLI 以 --permission-mode manual 启动，init 回显 "default"
    { type: "modeResolved", modeId: "default" },
    { type: "status", status: "running" },
  ]);
});

test("set_permission_mode 后的 system/status 回显新档", () => {
  const normalizer = new ClaudeNormalizer({ now: () => 1785000000000 });
  const events = normalizer.normalize({
    type: "system",
    subtype: "status",
    permissionMode: "acceptEdits",
  } as ClaudeMessage);
  assert.deepEqual(events, [{ type: "modeResolved", modeId: "acceptEdits" }]);
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

  // CLI 给了 permission_suggestions，所以持久放行这一档才允许出现；
  // 眼镜端只认 kind+scope，两者必须和 adapter 实际回送的裁决对得上
  assert.deepEqual(
    approval.approval.options.map((o) => ({ id: o.id, kind: o.kind, scope: o.scope })),
    [
      { id: "allow", kind: "allow", scope: "once" },
      { id: "allowAlways", kind: "allow", scope: "persistent" },
      { id: "deny", kind: "deny", scope: "once" },
      { id: "abort", kind: "abort", scope: "once" },
    ],
  );
  // label 仍要填运行时原文，但不参与逻辑判断
  assert.ok(approval.approval.options.every((o) => o.label.length > 0));

  // 审批期间会话必须显式转成 awaitingApproval，否则手机端不会弹卡
  const index = events.indexOf(approval);
  assert.deepEqual(events[index + 1], { type: "status", status: "awaitingApproval" });
});

test("子 agent 消息折进父 Task 块的摘要，不另起顶层块", () => {
  const events = run(sessions[0] ?? []);
  const task = blockOfKind(events, "toolCall");
  assert.equal(task.tool, "Task");
  assert.equal(task.source, null);
  assert.equal(task.output, "");

  const patches = patchesFor(events, task.id);
  // 摘要走 summary，不能占用 appendText/replaceText——那两个对 toolCall 打的是 output
  assert.deepEqual(patches.at(-1), { summary: "子 agent 勘察完毕：仓库里没有可疑文件。" });
  assert.equal(
    patches.some((p) => p.replaceText !== undefined),
    false,
  );

  // Task 自己的 tool_result 正文进 output，与子 agent 摘要各占一个字段、互不覆盖
  const settled = patches.find((p) => p.status !== undefined);
  assert.equal(settled?.status, "ok");
  assert.match(settled?.appendText ?? "", /Async agent launched successfully/);

  // 子 agent 那条 assistant 帧没有变成独立的 agentMessage
  const agentTexts = appended(events).filter((b) => b.kind === "agentMessage");
  assert.equal(agentTexts.length, 2);
});

test("MCP 工具的返回值落进 toolCall.output，不在边界上丢掉", () => {
  const normalizer = new ClaudeNormalizer({ now: () => FIXED_NOW });
  const events = [
    ...normalizer.normalize({
      type: "assistant",
      message: {
        content: [
          {
            type: "tool_use",
            id: "toolu_mcp_out",
            name: "mcp__notion__search",
            input: { description: "查一下会议纪要" },
          },
        ],
      },
      parent_tool_use_id: null,
    } as ClaudeMessage),
    ...normalizer.normalize({
      type: "user",
      message: {
        content: [
          {
            type: "tool_result",
            tool_use_id: "toolu_mcp_out",
            content: [{ type: "text", text: "找到 3 条纪要" }],
          },
        ],
      },
      parent_tool_use_id: null,
    } as ClaudeMessage),
  ];

  const block = blockOfKind(events, "toolCall");
  assert.deepEqual(patchesFor(events, block.id).at(-1), {
    appendText: "找到 3 条纪要",
    status: "ok",
  });
});

test("result 给出 token 统计并把会话置回 idle", () => {
  const events = run(sessions[0] ?? []);
  const completed = events.find((e) => e.type === "turnCompleted");
  assert.deepEqual(completed, {
    type: "turnCompleted",
    inputTokens: 3702,
    outputTokens: 139,
    // 这段是打到本地 mock 端点录的，没有 prompt cache 命中，所以是 0 而不是 null
    cachedInputTokens: 0,
    stopReason: "completed",
  });
  assert.deepEqual(events.at(-1), { type: "status", status: "idle" });
});

test("cache_read_input_tokens 原样进 cachedInputTokens，缺字段才是 null", () => {
  const withCache = new ClaudeNormalizer({ now: () => FIXED_NOW }).normalize({
    type: "result",
    subtype: "success",
    is_error: false,
    stop_reason: "end_turn",
    terminal_reason: "completed",
    usage: { input_tokens: 24682, output_tokens: 51, cache_read_input_tokens: 23296 },
  } as ClaudeMessage);
  assert.deepEqual(withCache[0], {
    type: "turnCompleted",
    inputTokens: 24682,
    outputTokens: 51,
    cachedInputTokens: 23296,
    stopReason: "completed",
  });

  const noUsage = new ClaudeNormalizer({ now: () => FIXED_NOW }).normalize({
    type: "result",
    subtype: "success",
    is_error: false,
  } as ClaudeMessage);
  assert.deepEqual(noUsage[0], {
    type: "turnCompleted",
    inputTokens: null,
    outputTokens: null,
    cachedInputTokens: null,
    stopReason: null,
  });
});

test("stopReason 映射：映不出来给 null 而不是猜一个", () => {
  const stopReasonOf = (result: Record<string, unknown>) => {
    const events = new ClaudeNormalizer({ now: () => FIXED_NOW }).normalize({
      subtype: "success",
      is_error: false,
      ...result,
      type: "result",
    } as ClaudeMessage);
    const completed = events.find((e) => e.type === "turnCompleted");
    return completed?.type === "turnCompleted" ? completed.stopReason : undefined;
  };

  assert.equal(stopReasonOf({ stop_reason: "max_tokens" }), "maxTokens");
  assert.equal(stopReasonOf({ stop_reason: "refusal" }), "refused");
  assert.equal(stopReasonOf({ terminal_reason: "interrupted", is_error: true }), "interrupted");
  assert.equal(stopReasonOf({ is_error: true, terminal_reason: "api_error" }), "failed");
  // CLI 认得但契约没有对应档位的收尾原因，宁可空着
  assert.equal(stopReasonOf({ terminal_reason: "turn_setup_failed" }), null);
  assert.equal(stopReasonOf({ stop_reason: "stop_sequence" }), null);
});

test("Write 折成 fileChange，审批被拒后落 failed", () => {
  const events = run(sessions[1] ?? []);
  const block = blockOfKind(events, "fileChange");
  assert.deepEqual(block.files, []);

  const patches = patchesFor(events, block.id);
  // Claude 的 tool_use 给不出增删行数，必须是 null——填 0 客户端会显示误导性的 "+0 −0"
  assert.deepEqual(patches[0]?.files, [
    { path: "/tmp/lenscrew/ws/probe.txt", added: null, removed: null },
  ]);
  // fileChange 没有主文本位，被拒的结果只能落 status
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

  // 即便失败也要给 turnCompleted，否则客户端的转圈停不下来。
  // 这一轮 stop_reason 是正常的 "stop_sequence"，只有 is_error 能判出 failed
  assert.deepEqual(events.at(-1), {
    type: "turnCompleted",
    inputTokens: 0,
    outputTokens: 0,
    cachedInputTokens: 0,
    stopReason: "failed",
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
