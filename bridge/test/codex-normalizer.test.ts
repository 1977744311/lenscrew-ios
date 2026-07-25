// protocol/fixtures/codex-turn.jsonl 是**实测录制**，不是手写的。
//
// 录制方式：2026-07-25 用本机 codex-cli 0.144.4 真实拉起 `codex app-server`
// （cwd=/tmp/lenscrew-probe/ws，approvalPolicy=untrusted，sandbox=read-only），
// 走完 initialize → initialized → thread/start → turn/start，逐行录下 stdout 的原始
// JSON-RPC 消息。文件由两段真实录制拼成，段内一字未改：
//
//   第 1..93 行  thread 019f9979-1615-…：一整轮成功的 turn。含 agentMessage 流式增量、
//                commandExecution 的 requestApproval（我们回 accept）、
//                serverRequest/resolved、29 条 outputDelta、exitCode=0 的 item/completed。
//   第 94..109 行 thread 019f9978-0d76-…：同样方式录的另一次会话里，故意用不存在的 model
//                发起 turn 得到的真实 error 通知 + turn/completed(status=failed)。
//                单独录是因为跑成功轮那次进程在第二轮前先被硬超时收掉了。
//
// 录制里保留了 codex 自带的噪音通知（mcpServer/startupStatus/updated、
// account/rateLimits/updated、warning 等），正好用来验证归一器把它们丢干净。
// 事后做过一次脱敏（家目录路径、主机名、installationId、账号套餐与额度换成占位值），
// 除此之外与 stdout 原样一致；消息结构、时间戳和 token 数字都没动过。
//
// 另有少量手工构造的消息（本文件末尾「手工构造」小节，依据同版本 generate-ts 类型写成、
// 未经实测），只用于覆盖这次录不到的分支：fileChange、mcpToolCall、计划、旧版审批通道。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

import type { AdapterEvent } from "../src/adapters/types.ts";
import { CodexNormalizer } from "../src/adapters/codex/normalizer.ts";
import type { CodexIncomingMessage } from "../src/adapters/codex/protocol.ts";

const FIXTURE = path.join(
  import.meta.dirname,
  "..",
  "..",
  "protocol",
  "fixtures",
  "codex-turn.jsonl",
);

const SHELL_ITEM_ID = "call_QP2e7cDt61oUvbg6IQ1Jqbi7";

function loadFixture(): CodexIncomingMessage[] {
  return readFileSync(FIXTURE, "utf8")
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line) as CodexIncomingMessage);
}

/**
 * 重放整份录制。approveWith 模拟 adapter 收到 approvalRequested 后的裁决回送——
 * 不调 buildApprovalResponse 的话归一器无从得知裁决结果，
 * serverRequest/resolved 只能报 cancelled。
 */
function replay(
  messages: CodexIncomingMessage[],
  approveWith: string | null = "accept",
): AdapterEvent[] {
  const normalizer = new CodexNormalizer({ now: () => 0 });
  const events: AdapterEvent[] = [];
  for (const message of messages) {
    for (const event of normalizer.normalize(message)) {
      events.push(event);
      if (event.type === "approvalRequested" && approveWith !== null) {
        normalizer.buildApprovalResponse(event.approval.id, approveWith);
      }
    }
  }
  return events;
}

function blockAppends(events: AdapterEvent[]) {
  return events.filter((event) => event.type === "blockAppended");
}

function updatesFor(events: AdapterEvent[], blockId: string) {
  return events.filter(
    (event) => event.type === "blockUpdated" && event.blockId === blockId,
  );
}

test("会话开场：nativeId 与状态流转", () => {
  const events = replay(loadFixture());

  assert.deepEqual(events[0], {
    type: "nativeIdAssigned",
    nativeId: "019f9979-1615-7710-ad35-6d1ea229b398",
  });

  const statuses = events
    .filter((event) => event.type === "status")
    .map((event) => event.status);
  // 连续同值状态必须被去重：thread/status/changed 后紧跟 turn/started 是常态
  assert.deepEqual(statuses, [
    "running",
    "awaitingApproval",
    "running",
    "idle",
    "running",
    "error",
  ]);
});

test("agentMessage：started → 逐字 delta → completed 定稿", () => {
  const events = replay(loadFixture());

  const appended = blockAppends(events).find(
    (event) => event.block.kind === "agentMessage",
  );
  assert.ok(appended, "应当有 agentMessage block");
  assert.equal(appended.block.kind, "agentMessage");
  if (appended.block.kind !== "agentMessage") return;
  assert.equal(appended.block.text, "");
  assert.equal(appended.block.streaming, true);

  const updates = updatesFor(events, appended.block.id);
  const deltas = updates.filter(
    (event) => event.type === "blockUpdated" && event.patch.appendText !== undefined,
  );
  assert.ok(deltas.length >= 5, "录制里这条消息有 15 个增量");
  for (const delta of deltas) {
    if (delta.type !== "blockUpdated") continue;
    assert.equal(delta.patch.streaming, true);
    assert.equal(delta.patch.replaceText, undefined, "appendText 与 replaceText 互斥");
  }

  const streamed = deltas
    .map((event) => (event.type === "blockUpdated" ? event.patch.appendText ?? "" : ""))
    .join("");
  const last = updates.at(-1);
  assert.ok(last && last.type === "blockUpdated");
  assert.equal(last.patch.streaming, false);
  assert.equal(last.patch.replaceText, "正在按原命令运行，并直接统计它的输出行数。");
  assert.equal(streamed, last.patch.replaceText, "增量拼接应当等于最终文本");
});

test("shellCommand：started → outputDelta → completed 带 exitCode", () => {
  const events = replay(loadFixture());

  const appended = blockAppends(events).find(
    (event) => event.block.kind === "shellCommand",
  );
  assert.ok(appended);
  if (appended.block.kind !== "shellCommand") return;
  assert.equal(appended.block.id, SHELL_ITEM_ID);
  assert.equal(appended.block.status, "running");
  assert.equal(appended.block.exitCode, null);
  assert.equal(appended.block.cwd, "/tmp/lenscrew-probe/ws");
  assert.match(appended.block.command, /python3/);

  const updates = updatesFor(events, SHELL_ITEM_ID);
  const deltas = updates.filter(
    (event) => event.type === "blockUpdated" && event.patch.appendText !== undefined,
  );
  assert.equal(deltas.length, 33, "录制里 33 条 outputDelta");
  for (const delta of deltas) {
    if (delta.type !== "blockUpdated") continue;
    // 命令输出不是"模型在打字"，不该带 streaming 语义
    assert.equal(delta.patch.streaming, undefined);
  }

  const final = updates.at(-1);
  assert.ok(final && final.type === "blockUpdated");
  assert.equal(final.patch.status, "ok");
  assert.equal(final.patch.exitCode, 0);
  // aggregatedOutput 是权威全量，含 outputDelta 没推过的 stderr，所以整体替换
  assert.ok(final.patch.replaceText?.includes("probe line 29"));
  assert.ok(
    final.patch.replaceText?.includes("cannot create temp file"),
    "整体替换才能补回只出现在 aggregatedOutput 里的 stderr",
  );
});

test("审批：请求带真实可选裁决，裁决回送后 settled 报出选项", () => {
  const events = replay(loadFixture());

  const requested = events.find((event) => event.type === "approvalRequested");
  assert.ok(requested && requested.type === "approvalRequested");
  const approval = requested.approval;
  assert.equal(approval.id, "0");
  assert.equal(approval.kind, "shellCommand");
  assert.equal(approval.cwd, "/tmp/lenscrew-probe/ws");
  assert.equal(approval.requestedAtMs, 1784986299010, "用协议给的 startedAtMs，不要 Date.now");
  assert.ok(approval.title.length <= 60, "眼镜屏一行要放得下");

  // 前三项来自线上 availableDecisions，decline 是我们补的兜底
  assert.deepEqual(approval.options, [
    { id: "accept", label: "accept", kind: "allow", scope: "once" },
    {
      id: "acceptWithExecpolicyAmendment",
      label: "acceptWithExecpolicyAmendment",
      kind: "allow",
      scope: "persistent",
    },
    { id: "cancel", label: "cancel", kind: "abort", scope: "once" },
    { id: "decline", label: "decline", kind: "deny", scope: "once" },
  ]);

  const settled = events.find((event) => event.type === "approvalSettled");
  assert.ok(settled && settled.type === "approvalSettled");
  assert.equal(settled.approvalId, "0");
  assert.equal(settled.optionId, "accept");
  assert.equal(settled.outcome, "resolved");
});

test("审批：本地没裁决就被 resolved，算 cancelled 而不是 resolved", () => {
  const events = replay(loadFixture(), null);
  const settled = events.find((event) => event.type === "approvalSettled");
  assert.ok(settled && settled.type === "approvalSettled");
  assert.equal(settled.optionId, null);
  assert.equal(settled.outcome, "cancelled");
});

test("审批：optionId 翻回 app-server 认的裁决体", () => {
  const normalizer = new CodexNormalizer({ now: () => 0 });
  const request = loadFixture().find(
    (message) => message.method === "item/commandExecution/requestApproval",
  );
  assert.ok(request);
  normalizer.normalize(request);

  assert.deepEqual(normalizer.buildApprovalResponse("0", "accept"), {
    requestId: 0,
    result: { decision: "accept" },
  });
  // 带 execpolicy 修订的裁决必须把服务端提的那份原样带回去
  const amended = normalizer.buildApprovalResponse("0", "acceptWithExecpolicyAmendment");
  assert.deepEqual(amended?.result, {
    decision: {
      acceptWithExecpolicyAmendment: {
        execpolicy_amendment: [
          "python3",
          "-u",
          "-c",
          "import time\nfor i in range(30): print('probe line %d' % i); time.sleep(0.08)",
        ],
      },
    },
  });
  // v2 通道绝不能出现旧版 ReviewDecision 的取值
  assert.equal(normalizer.buildApprovalResponse("0", "approved"), null);
  assert.equal(normalizer.buildApprovalResponse("404", "accept"), null);
});

test("error 通知：既进流水也报事件，但不算致命", () => {
  const events = replay(loadFixture());

  const errorBlock = blockAppends(events).find(
    (event) => event.block.kind === "error",
  );
  assert.ok(errorBlock);
  if (errorBlock.block.kind !== "error") return;
  assert.match(errorBlock.block.message, /lenscrew-nonexistent-model-9/);

  const errorEvent = events.find((event) => event.type === "error");
  assert.ok(errorEvent && errorEvent.type === "error");
  assert.equal(errorEvent.fatal, false, "turn 失败不等于会话死了");
  assert.equal(errorEvent.message, errorBlock.block.message);
});

test("turn/completed 带上最近一次 token 用量与缓存命中", () => {
  const events = replay(loadFixture());
  const completed = events.filter((event) => event.type === "turnCompleted");
  assert.equal(completed.length, 2);

  // 一轮里 tokenUsage 会推好几次，要取最后一次而不是第一次
  const first = completed[0];
  assert.ok(first && first.type === "turnCompleted");
  assert.equal(first.inputTokens, 24682);
  assert.equal(first.outputTokens, 102);
  // 24682 个 input 里 23296 是缓存命中——不单列出来算成本会差一个数量级
  assert.equal(first.cachedInputTokens, 23296);
  assert.equal(first.stopReason, "completed");

  // 失败的那轮压根没推过 tokenUsage，不能把上一轮的数字漏过来
  const second = completed[1];
  assert.ok(second && second.type === "turnCompleted");
  assert.equal(second.inputTokens, null);
  assert.equal(second.outputTokens, null);
  assert.equal(second.cachedInputTokens, null);
  assert.equal(second.stopReason, "failed");
});

test("噪音通知一条都不产生事件", () => {
  const normalizer = new CodexNormalizer({ now: () => 0 });
  const noise = loadFixture().filter((message) =>
    [
      "mcpServer/startupStatus/updated",
      "account/rateLimits/updated",
      "remoteControl/status/changed",
      "warning",
    ].includes(message.method ?? ""),
  );
  assert.ok(noise.length >= 10, "录制里确实有这些噪音");
  for (const message of noise) {
    assert.deepEqual(normalizer.normalize(message), []);
  }
  // 我们自己发出去的请求的响应由 adapter 配对，归一器不该插手
  const responses = loadFixture().filter((message) => message.method === undefined);
  for (const message of responses) {
    assert.deepEqual(normalizer.normalize(message), []);
  }
});

test("userMessage 在 started 时就是终态，completed 不再产生补丁", () => {
  const events = replay(loadFixture());
  const user = blockAppends(events).find((event) => event.block.kind === "userMessage");
  assert.ok(user);
  if (user.block.kind !== "userMessage") return;
  assert.equal(user.block.imageCount, 0);
  assert.match(user.block.text, /^请只做一件事/);
  assert.deepEqual(updatesFor(events, user.block.id), []);
});

// MARK: - 手工构造（依据 codex-cli 0.144.4 的 generate-ts 类型写成，未经实测）

test("裁决的 scope 分三档，session 与 persistent 不能混为一谈", () => {
  const normalizer = new CodexNormalizer({ now: () => 0 });
  const events = normalizer.normalize({
    method: "item/commandExecution/requestApproval",
    id: 5,
    params: {
      threadId: "t",
      turnId: "u",
      itemId: "i",
      startedAtMs: 1,
      command: "curl https://example.com",
      cwd: "/repo",
      availableDecisions: [
        "accept",
        "acceptForSession",
        { acceptWithExecpolicyAmendment: { execpolicy_amendment: ["curl"] } },
        {
          applyNetworkPolicyAmendment: {
            network_policy_amendment: { host: "example.com", action: "allow" },
          },
        },
        "decline",
        "cancel",
      ],
    },
  });
  const event = events[0];
  assert.ok(event && event.type === "approvalRequested");

  const byId = new Map(
    event.approval.options.map((option) => [option.id, option] as const),
  );
  assert.deepEqual(
    [...byId.keys()],
    [
      "accept",
      "acceptForSession",
      "acceptWithExecpolicyAmendment",
      "applyNetworkPolicyAmendment",
      "decline",
      "cancel",
    ],
  );

  // 全是"批准"，差别只在作用范围上——眼镜端要靠 scope 而不是 label 区分
  assert.equal(byId.get("accept")?.kind, "allow");
  assert.equal(byId.get("accept")?.scope, "once");
  assert.equal(byId.get("acceptForSession")?.kind, "allow");
  assert.equal(byId.get("acceptForSession")?.scope, "session");
  assert.equal(byId.get("acceptWithExecpolicyAmendment")?.kind, "allow");
  assert.equal(byId.get("acceptWithExecpolicyAmendment")?.scope, "persistent");
  assert.equal(byId.get("applyNetworkPolicyAmendment")?.scope, "persistent");
  assert.notEqual(
    byId.get("acceptForSession")?.scope,
    byId.get("acceptWithExecpolicyAmendment")?.scope,
    "execpolicy 修订会落盘跨会话生效，和只管本会话的 acceptForSession 不是一回事",
  );

  assert.equal(byId.get("decline")?.kind, "deny");
  assert.equal(byId.get("decline")?.scope, "once");
  assert.equal(byId.get("cancel")?.kind, "abort");
  assert.equal(byId.get("cancel")?.scope, "once");
});

test("认不出的裁决不给选项，但兜底的 decline/cancel 必须还在", () => {
  const normalizer = new CodexNormalizer({ now: () => 0 });
  const events = normalizer.normalize({
    method: "item/commandExecution/requestApproval",
    id: 6,
    params: {
      threadId: "t",
      turnId: "u",
      itemId: "i",
      startedAtMs: 1,
      command: "ls",
      cwd: "/repo",
      availableDecisions: ["accept", "acceptWithTeleportation"],
    },
  });
  const event = events[0];
  assert.ok(event && event.type === "approvalRequested");
  assert.deepEqual(
    event.approval.options.map((option) => option.id),
    ["accept", "decline", "cancel"],
    "猜不出 scope 的新裁决宁可不显示，也不能画成一个作用域错误的按钮",
  );
});

test("mcpToolCall 的返回正文落到 toolCall.output，不再被丢掉", () => {
  const normalizer = new CodexNormalizer({ now: () => 0 });
  const base = {
    type: "mcpToolCall",
    id: "mcp_1",
    server: "notion",
    tool: "search",
    result: null,
    error: null,
  };

  const started = normalizer.normalize({
    method: "item/started",
    params: { item: { ...base, status: "inProgress" }, threadId: "t", turnId: "u" },
  });
  const appended = started[0];
  assert.ok(appended && appended.type === "blockAppended");
  assert.equal(appended.block.kind, "toolCall");
  if (appended.block.kind !== "toolCall") return;
  assert.equal(appended.block.summary, "notion / search");
  assert.equal(appended.block.output, "", "started 时 result 还是 null");

  const completed = normalizer.normalize({
    method: "item/completed",
    params: {
      item: {
        ...base,
        status: "completed",
        result: {
          content: [
            { type: "text", text: "第一段结果" },
            { type: "text", text: "第二段结果" },
          ],
          structuredContent: null,
        },
      },
      threadId: "t",
      turnId: "u",
    },
  });
  const patch = completed[0];
  assert.ok(patch && patch.type === "blockUpdated");
  // 契约规定 toolCall 的主文本是 output，所以正文走 replaceText
  assert.equal(patch.patch.replaceText, "第一段结果\n第二段结果");
  assert.equal(patch.patch.status, "ok");
});

test("MCP 工具报错时把错误正文放进 output", () => {
  const normalizer = new CodexNormalizer({ now: () => 0 });
  const item = {
    type: "mcpToolCall",
    id: "mcp_2",
    server: "notion",
    tool: "search",
    status: "failed",
    result: null,
    error: { message: "rate limited" },
  };
  const events = normalizer.normalize({
    method: "item/started",
    params: { item, threadId: "t", turnId: "u" },
  });
  const appended = events[0];
  assert.ok(appended && appended.type === "blockAppended");
  if (appended.block.kind !== "toolCall") return;
  assert.equal(appended.block.output, "rate limited");
  assert.equal(appended.block.status, "failed");
});

test("plan 文本走 output，摘要走 summary", () => {
  const normalizer = new CodexNormalizer({ now: () => 0 });
  const text = "先读契约\n再写归一器\n最后补测试";
  const events = normalizer.normalize({
    method: "item/completed",
    params: { item: { type: "plan", id: "p1", text }, threadId: "t", turnId: "u" },
  });
  const appended = events[0];
  assert.ok(appended && appended.type === "blockAppended");
  if (appended.block.kind !== "toolCall") return;
  assert.equal(appended.block.output, text);
  assert.equal(appended.block.summary, "先读契约");
});

test("thread/name/updated 翻成 titleResolved，没名字就不发", () => {
  const normalizer = new CodexNormalizer({ now: () => 0 });
  assert.deepEqual(
    normalizer.normalize({
      method: "thread/name/updated",
      params: { threadId: "t", threadName: "给眼镜端接三个 agent" },
    }),
    [{ type: "titleResolved", title: "给眼镜端接三个 agent" }],
  );
  assert.deepEqual(
    normalizer.normalize({
      method: "thread/name/updated",
      params: { threadId: "t" },
    }),
    [],
  );
});

test("算不出增删行数时报 null 而不是 0", () => {
  const normalizer = new CodexNormalizer({ now: () => 0 });
  const events = normalizer.normalize({
    method: "item/started",
    params: {
      item: {
        type: "fileChange",
        id: "patch_2",
        status: "inProgress",
        changes: [{ path: "bin/blob", kind: { type: "add" }, diff: "" }],
      },
      threadId: "t",
      turnId: "u",
    },
  });
  const appended = events[0];
  assert.ok(appended && appended.type === "blockAppended");
  if (appended.block.kind !== "fileChange") return;
  // 填 0 会让客户端显示 "+0 −0"，那是在撒谎
  assert.deepEqual(appended.block.files, [
    { path: "bin/blob", added: null, removed: null },
  ]);
});

/**
 * codex 把上下文超限表达成 failed + codexErrorInfo，归成 failed 就把它藏起来了：
 * "上下文满了"该去压缩或开新会话，"出错了"该去看错误，是两种处置。
 */
test("上下文超限归到 maxTokens，其余 failed 保持 failed", () => {
  const normalizer = new CodexNormalizer({ now: () => 0 });
  const stopReasonOf = (error: unknown) => {
    const events = normalizer.normalize({
      method: "turn/completed",
      params: { threadId: "t", turn: { id: "u", status: "failed", error } },
    });
    const completed = events[0];
    assert.ok(completed && completed.type === "turnCompleted");
    return completed.stopReason;
  };

  assert.equal(
    stopReasonOf({ message: "context window exceeded", codexErrorInfo: "contextWindowExceeded" }),
    "maxTokens",
  );
  // 配额用尽不是模型的 token 上限，不能混进来
  assert.equal(
    stopReasonOf({ message: "usage limit", codexErrorInfo: "usageLimitExceeded" }),
    "failed",
  );
  assert.equal(stopReasonOf(null), "failed");
});

test("turn 被中断时 stopReason 是 interrupted", () => {
  const normalizer = new CodexNormalizer({ now: () => 0 });
  const events = normalizer.normalize({
    method: "turn/completed",
    params: { threadId: "t", turn: { id: "u", status: "interrupted" } },
  });
  assert.deepEqual(events, [
    {
      type: "turnCompleted",
      inputTokens: null,
      outputTokens: null,
      cachedInputTokens: null,
      stopReason: "interrupted",
    },
  ]);
});

test("fileChange 折叠成 fileChange block 并按 diff 统计增删", () => {
  const normalizer = new CodexNormalizer({ now: () => 0 });
  const item = {
    type: "fileChange",
    id: "patch_1",
    status: "inProgress",
    changes: [
      {
        path: "src/a.ts",
        kind: { type: "update", move_path: null },
        diff: "--- a/src/a.ts\n+++ b/src/a.ts\n-old\n+new\n+extra\n",
      },
    ],
  };
  const appended = normalizer.normalize({
    method: "item/started",
    params: { item, threadId: "t", turnId: "u" },
  });
  assert.deepEqual(appended, [
    {
      type: "blockAppended",
      block: {
        kind: "fileChange",
        id: "patch_1",
        files: [{ path: "src/a.ts", added: 2, removed: 1 }],
        status: "running",
      },
    },
  ]);

  const declined = normalizer.normalize({
    method: "item/completed",
    params: { item: { ...item, status: "declined" }, threadId: "t", turnId: "u" },
  });
  assert.equal(declined.length, 1);
  const patch = declined[0];
  assert.ok(patch && patch.type === "blockUpdated");
  assert.equal(patch.patch.status, "rejected");
});

test("契约里没有的 ThreadItem 类型一律落到 toolCall 兜底", () => {
  const normalizer = new CodexNormalizer({ now: () => 0 });
  const cases: Array<[Record<string, unknown>, string, string | null]> = [
    [
      { type: "mcpToolCall", id: "m1", server: "notion", tool: "search", status: "inProgress" },
      "search",
      "notion",
    ],
    [{ type: "webSearch", id: "w1", query: "lenscrew" }, "webSearch", null],
    [{ type: "sleep", id: "s1", durationMs: 100 }, "sleep", null],
    [{ type: "contextCompaction", id: "c1" }, "contextCompaction", null],
  ];
  for (const [item, tool, source] of cases) {
    const events = normalizer.normalize({
      method: "item/started",
      params: { item, threadId: "t", turnId: "u" },
    });
    assert.equal(events.length, 1);
    const event = events[0];
    assert.ok(event && event.type === "blockAppended");
    assert.equal(event.block.kind, "toolCall", `${String(item["type"])} 应当兜底成 toolCall`);
    if (event.block.kind !== "toolCall") continue;
    assert.equal(event.block.tool, tool);
    assert.equal(event.block.source, source);
    assert.equal(typeof event.block.output, "string", "output 是必填字段");
  }
});

test("turn/plan/updated 建一次 plan block，之后只打补丁", () => {
  const normalizer = new CodexNormalizer({ now: () => 0 });
  const params = {
    threadId: "t",
    turnId: "u1",
    plan: [
      { step: "读契约", status: "completed" },
      { step: "写归一器", status: "inProgress" },
      { step: "跑测试", status: "pending" },
    ],
  };
  const first = normalizer.normalize({ method: "turn/plan/updated", params });
  assert.deepEqual(first, [
    {
      type: "blockAppended",
      block: {
        kind: "plan",
        id: "plan:u1",
        steps: [
          { text: "读契约", status: "done" },
          { text: "写归一器", status: "running" },
          { text: "跑测试", status: "pending" },
        ],
      },
    },
  ]);

  const second = normalizer.normalize({ method: "turn/plan/updated", params });
  assert.equal(second.length, 1);
  assert.equal(second[0]?.type, "blockUpdated");
});

test("旧版 execCommandApproval 走 ReviewDecision，不和 v2 混", () => {
  const normalizer = new CodexNormalizer({ now: () => 1234 });
  const events = normalizer.normalize({
    method: "execCommandApproval",
    id: "legacy-7",
    params: {
      conversationId: "t",
      callId: "c1",
      command: ["rm", "-rf", "build"],
      cwd: "/repo",
      reason: "清理构建产物",
    },
  });
  assert.equal(events.length, 1);
  const event = events[0];
  assert.ok(event && event.type === "approvalRequested");
  assert.equal(event.approval.title, "rm -rf build");
  assert.equal(event.approval.requestedAtMs, 1234, "旧版通道没有 startedAtMs，用注入的时钟兜底");
  assert.deepEqual(
    event.approval.options.map((option) => option.id),
    ["approved", "approved_for_session", "denied", "abort"],
  );
  assert.deepEqual(normalizer.buildApprovalResponse("legacy-7", "denied"), {
    requestId: "legacy-7",
    result: { decision: "denied" },
  });
  assert.equal(normalizer.buildApprovalResponse("legacy-7", "decline"), null);
});

test("permissions 审批的应答体没有 decision 字段", () => {
  const normalizer = new CodexNormalizer({ now: () => 0 });
  const events = normalizer.normalize({
    method: "item/permissions/requestApproval",
    id: 9,
    params: {
      threadId: "t",
      turnId: "u",
      itemId: "i",
      cwd: "/repo",
      reason: "需要访问 npm registry",
      permissions: { network: { allowAll: true }, fileSystem: null },
    },
  });
  const event = events[0];
  assert.ok(event && event.type === "approvalRequested");
  assert.equal(event.approval.kind, "permission");
  assert.deepEqual(normalizer.buildApprovalResponse("9", "acceptForSession"), {
    requestId: 9,
    result: {
      permissions: { network: { allowAll: true }, fileSystem: null },
      scope: "session",
    },
  });
});

test("item/started 缺失时 item/completed 直接补一条 blockAppended", () => {
  const normalizer = new CodexNormalizer({ now: () => 0 });
  const events = normalizer.normalize({
    method: "item/completed",
    params: {
      item: {
        type: "agentMessage",
        id: "orphan",
        text: "断线重连后补齐的消息",
      },
      threadId: "t",
      turnId: "u",
    },
  });
  assert.equal(events.length, 1);
  const event = events[0];
  assert.ok(event && event.type === "blockAppended");
  assert.equal(event.block.kind, "agentMessage");
  if (event.block.kind !== "agentMessage") return;
  assert.equal(event.block.streaming, false);
  assert.equal(event.block.text, "断线重连后补齐的消息");
});

test("孤儿 delta 不产生事件", () => {
  const normalizer = new CodexNormalizer({ now: () => 0 });
  assert.deepEqual(
    normalizer.normalize({
      method: "item/agentMessage/delta",
      params: { threadId: "t", turnId: "u", itemId: "never-started", delta: "x" },
    }),
    [],
  );
});
