import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import type {
  AgentCapabilities,
  AgentQuotaSnapshot,
  AgentSession,
  ApprovalOption,
  ApprovalRequest,
  BridgeEvent,
  FileChangeSummary,
  PlanStep,
  QuotaWindow,
  TranscriptBlock,
  TranscriptBlockPatch,
} from "../src/protocol/events.ts";

/**
 * 跨语言契约测试的 TypeScript 半边。
 *
 * protocol/fixtures/bridge-events.json 是 bridge 与 iOS App 共用的黄金样本，
 * Swift 侧在 Tests/AgentProtocolTests/ContractFixtureTests.swift 里断言同一份文件。
 * 这里守两件事：
 *
 *   编译期 —— 下面的重建函数逐字段列出每个变体，契约加了字段而重建没跟上，tsc 直接报错；
 *             全可选的类型（patch）靠 Record<keyof T, true> 清单达到同样效果。
 *   运行期 —— fixture 过一遍重建再深比较，能同时抓出 fixture 少字段和多字段两种漂移。
 *
 * 少了这半边，"改一侧两边都红"就只是一句口号：Swift 侧再严也管不到 TS 侧漏加字段。
 */

const FIXTURE_PATH = join(
  import.meta.dirname,
  "..",
  "..",
  "protocol",
  "fixtures",
  "bridge-events.json",
);

const fixture = JSON.parse(readFileSync(FIXTURE_PATH, "utf8")) as BridgeEvent[];

// 键清单：契约给这些类型加字段时，这里不补就编译不过
const CAPABILITY_KEYS: Record<keyof AgentCapabilities, true> = {
  approvals: true,
  steering: true,
  interrupt: true,
  planMode: true,
  resume: true,
  streamingDeltas: true,
};

const PATCH_KEYS: Record<keyof TranscriptBlockPatch, true> = {
  appendText: true,
  replaceText: true,
  streaming: true,
  status: true,
  exitCode: true,
  cwd: true,
  summary: true,
  files: true,
  steps: true,
};

function rebuildCapabilities(value: AgentCapabilities): AgentCapabilities {
  return {
    approvals: value.approvals,
    steering: value.steering,
    interrupt: value.interrupt,
    planMode: value.planMode,
    resume: value.resume,
    streamingDeltas: value.streamingDeltas,
  };
}

function rebuildSession(value: AgentSession): AgentSession {
  return {
    id: value.id,
    agent: value.agent,
    nativeId: value.nativeId,
    workspaceRoot: value.workspaceRoot,
    title: value.title,
    model: value.model,
    status: value.status,
    capabilities: rebuildCapabilities(value.capabilities),
    modeId: value.modeId,
    modes: value.modes.map((mode) => ({
      id: mode.id,
      label: mode.label,
      detail: mode.detail,
    })),
    models: value.models.map((model) => ({
      id: model.id,
      label: model.label,
      reasoningEfforts: [...model.reasoningEfforts],
    })),
    reasoningEffort: value.reasoningEffort,
    createdAtMs: value.createdAtMs,
    updatedAtMs: value.updatedAtMs,
  };
}

function rebuildFile(value: FileChangeSummary): FileChangeSummary {
  return { path: value.path, added: value.added, removed: value.removed };
}

function rebuildStep(value: PlanStep): PlanStep {
  return { text: value.text, status: value.status };
}

function rebuildOption(value: ApprovalOption): ApprovalOption {
  return {
    id: value.id,
    label: value.label,
    kind: value.kind,
    scope: value.scope,
  };
}

function rebuildApproval(value: ApprovalRequest): ApprovalRequest {
  return {
    id: value.id,
    kind: value.kind,
    title: value.title,
    detail: value.detail,
    cwd: value.cwd,
    options: value.options.map(rebuildOption),
    requestedAtMs: value.requestedAtMs,
  };
}

function rebuildWindow(value: QuotaWindow): QuotaWindow {
  return {
    id: value.id,
    label: value.label,
    usedPercent: value.usedPercent,
    windowDurationMins: value.windowDurationMins,
    resetsAt: value.resetsAt,
  };
}

function rebuildQuota(value: AgentQuotaSnapshot): AgentQuotaSnapshot {
  return {
    agent: value.agent,
    planType: value.planType,
    windows: value.windows.map(rebuildWindow),
    capturedAtMs: value.capturedAtMs,
  };
}

function rebuildBlock(block: TranscriptBlock): TranscriptBlock {
  switch (block.kind) {
    case "userMessage":
      return {
        kind: "userMessage",
        id: block.id,
        text: block.text,
        imageCount: block.imageCount,
      };
    case "agentMessage":
      return {
        kind: "agentMessage",
        id: block.id,
        text: block.text,
        streaming: block.streaming,
      };
    case "reasoning":
      return {
        kind: "reasoning",
        id: block.id,
        text: block.text,
        streaming: block.streaming,
      };
    case "shellCommand":
      return {
        kind: "shellCommand",
        id: block.id,
        command: block.command,
        cwd: block.cwd,
        output: block.output,
        exitCode: block.exitCode,
        status: block.status,
      };
    case "fileChange":
      return {
        kind: "fileChange",
        id: block.id,
        files: block.files.map(rebuildFile),
        status: block.status,
      };
    case "toolCall":
      return {
        kind: "toolCall",
        id: block.id,
        source: block.source,
        tool: block.tool,
        summary: block.summary,
        output: block.output,
        status: block.status,
      };
    case "plan":
      return { kind: "plan", id: block.id, steps: block.steps.map(rebuildStep) };
    case "error":
      return { kind: "error", id: block.id, message: block.message };
  }
}

/** patch 全字段可选，漏字段编译不出错，所以只拷贝出现过的键，靠键清单和未知键检查兜底 */
function rebuildPatch(patch: TranscriptBlockPatch): TranscriptBlockPatch {
  const rebuilt: TranscriptBlockPatch = {};
  if (patch.appendText !== undefined) rebuilt.appendText = patch.appendText;
  if (patch.replaceText !== undefined) rebuilt.replaceText = patch.replaceText;
  if (patch.streaming !== undefined) rebuilt.streaming = patch.streaming;
  if (patch.status !== undefined) rebuilt.status = patch.status;
  if (patch.exitCode !== undefined) rebuilt.exitCode = patch.exitCode;
  if (patch.cwd !== undefined) rebuilt.cwd = patch.cwd;
  if (patch.summary !== undefined) rebuilt.summary = patch.summary;
  if (patch.files !== undefined) rebuilt.files = patch.files.map(rebuildFile);
  if (patch.steps !== undefined) rebuilt.steps = patch.steps.map(rebuildStep);
  return rebuilt;
}

function rebuildEvent(event: BridgeEvent): BridgeEvent {
  switch (event.type) {
    case "sessionCreated":
      return { type: "sessionCreated", seq: event.seq, session: rebuildSession(event.session) };
    case "sessionUpdated":
      return { type: "sessionUpdated", seq: event.seq, session: rebuildSession(event.session) };
    case "sessionStatus":
      return {
        type: "sessionStatus",
        seq: event.seq,
        sessionId: event.sessionId,
        status: event.status,
      };
    case "sessionClosed":
      return {
        type: "sessionClosed",
        seq: event.seq,
        sessionId: event.sessionId,
        reason: event.reason,
      };
    case "blockAppended":
      return {
        type: "blockAppended",
        seq: event.seq,
        sessionId: event.sessionId,
        block: rebuildBlock(event.block),
      };
    case "blockUpdated":
      return {
        type: "blockUpdated",
        seq: event.seq,
        sessionId: event.sessionId,
        blockId: event.blockId,
        patch: rebuildPatch(event.patch),
      };
    case "approvalRequested":
      return {
        type: "approvalRequested",
        seq: event.seq,
        sessionId: event.sessionId,
        approval: rebuildApproval(event.approval),
      };
    case "approvalSettled":
      return {
        type: "approvalSettled",
        seq: event.seq,
        sessionId: event.sessionId,
        approvalId: event.approvalId,
        optionId: event.optionId,
        outcome: event.outcome,
      };
    case "turnCompleted":
      return {
        type: "turnCompleted",
        seq: event.seq,
        sessionId: event.sessionId,
        inputTokens: event.inputTokens,
        outputTokens: event.outputTokens,
        cachedInputTokens: event.cachedInputTokens,
        stopReason: event.stopReason,
      };
    case "bridgeError":
      return {
        type: "bridgeError",
        seq: event.seq,
        sessionId: event.sessionId,
        message: event.message,
        fatal: event.fatal,
      };
    case "quotaUpdated":
      return { type: "quotaUpdated", seq: event.seq, quota: rebuildQuota(event.quota) };
  }
}

test("fixture 每条事件的字段集与契约完全一致", () => {
  assert.ok(fixture.length > 0);
  for (const event of fixture) {
    assert.deepStrictEqual(
      rebuildEvent(event),
      event,
      `事件 ${event.type} seq ${event.seq} 的字段集与契约不一致`,
    );
  }
});

test("fixture 里的 patch 不带契约之外的键", () => {
  const allowed = new Set(Object.keys(PATCH_KEYS));
  for (const event of fixture) {
    if (event.type !== "blockUpdated") continue;
    for (const key of Object.keys(event.patch)) {
      assert.ok(allowed.has(key), `patch 出现契约之外的键 ${key}（seq ${event.seq}）`);
    }
  }
});

test("fixture 里的 capabilities 不带契约之外的键", () => {
  const allowed = new Set(Object.keys(CAPABILITY_KEYS));
  for (const event of fixture) {
    if (event.type !== "sessionCreated" && event.type !== "sessionUpdated") continue;
    for (const key of Object.keys(event.session.capabilities)) {
      assert.ok(allowed.has(key), `capabilities 出现契约之外的键 ${key}`);
    }
  }
});

/** 与 Swift 侧同名断言成对存在：任一侧发现覆盖缺口，两边都该补 */
test("fixture 覆盖全部十一种事件", () => {
  const types = new Set(fixture.map((event) => event.type));
  assert.deepStrictEqual(
    [...types].sort(),
    [
      "approvalRequested",
      "approvalSettled",
      "blockAppended",
      "blockUpdated",
      "bridgeError",
      "quotaUpdated",
      "sessionClosed",
      "sessionCreated",
      "sessionStatus",
      "sessionUpdated",
      "turnCompleted",
    ],
  );
});

test("fixture 覆盖全部八类流水块", () => {
  const kinds = new Set(
    fixture
      .filter((event) => event.type === "blockAppended")
      .map((event) => event.block.kind),
  );
  assert.deepStrictEqual(
    [...kinds].sort(),
    [
      "agentMessage",
      "error",
      "fileChange",
      "plan",
      "reasoning",
      "shellCommand",
      "toolCall",
      "userMessage",
    ],
  );
});

test("fixture 覆盖审批裁决的三档作用范围", () => {
  const scopes = new Set(
    fixture
      .filter((event) => event.type === "approvalRequested")
      .flatMap((event) => event.approval.options.map((option) => option.scope)),
  );
  assert.deepStrictEqual([...scopes].sort(), ["once", "persistent", "session"]);
});
