import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import type { ClientCommand } from "../src/protocol/events.ts";

/**
 * 跨语言契约测试的 TypeScript 半边（ClientCommand）。
 *
 * protocol/fixtures/client-commands.json 与
 * Tests/AgentProtocolTests/ContractFixtureTests.swift 共用。
 * 编译期靠重建函数字段清单抓漏加字段；运行期深比较抓 fixture 漂移。
 */

const FIXTURE_PATH = join(
  import.meta.dirname,
  "..",
  "..",
  "protocol",
  "fixtures",
  "client-commands.json",
);

const fixture = JSON.parse(readFileSync(FIXTURE_PATH, "utf8")) as ClientCommand[];

function rebuildCommand(command: ClientCommand): ClientCommand {
  switch (command.type) {
    case "listSessions":
      return { type: "listSessions" };
    case "createSession":
      return {
        type: "createSession",
        agent: command.agent,
        workspaceRoot: command.workspaceRoot,
        model: command.model,
        modeId: command.modeId,
        reasoningEffort: command.reasoningEffort,
      };
    case "resumeSession":
      return {
        type: "resumeSession",
        agent: command.agent,
        nativeId: command.nativeId,
        workspaceRoot: command.workspaceRoot,
      };
    case "sendMessage":
      return {
        type: "sendMessage",
        sessionId: command.sessionId,
        text: command.text,
      };
    case "interrupt":
      return { type: "interrupt", sessionId: command.sessionId };
    case "resolveApproval":
      return {
        type: "resolveApproval",
        sessionId: command.sessionId,
        approvalId: command.approvalId,
        optionId: command.optionId,
      };
    case "setSessionMode":
      return {
        type: "setSessionMode",
        sessionId: command.sessionId,
        modeId: command.modeId,
      };
    case "setSessionModel":
      return {
        type: "setSessionModel",
        sessionId: command.sessionId,
        modelId: command.modelId,
      };
    case "setSessionReasoningEffort":
      return {
        type: "setSessionReasoningEffort",
        sessionId: command.sessionId,
        effort: command.effort,
      };
    case "closeSession":
      return { type: "closeSession", sessionId: command.sessionId };
    case "subscribe":
      return {
        type: "subscribe",
        sessionId: command.sessionId,
        fromSeq: command.fromSeq,
      };
  }
}

test("fixture 每条指令的字段集与契约完全一致", () => {
  assert.ok(fixture.length > 0);
  for (const command of fixture) {
    assert.deepStrictEqual(
      rebuildCommand(command),
      command,
      `指令 ${command.type} 的字段集与契约不一致`,
    );
  }
});

/** 与 Swift 侧同名断言成对存在：任一侧发现覆盖缺口，两边都该补 */
test("fixture 覆盖全部十一种 ClientCommand", () => {
  const types = new Set(fixture.map((command) => command.type));
  assert.deepStrictEqual(
    [...types].sort(),
    [
      "closeSession",
      "createSession",
      "interrupt",
      "listSessions",
      "resolveApproval",
      "resumeSession",
      "sendMessage",
      "setSessionMode",
      "setSessionModel",
      "setSessionReasoningEffort",
      "subscribe",
    ],
  );
});

test("createSession 的可空字段以 null 键出现（与 events honesty 一致）", () => {
  const creates = fixture.filter((command) => command.type === "createSession");
  assert.ok(creates.length >= 2);
  const withNulls = creates.find(
    (command) =>
      command.type === "createSession" &&
      command.model === null &&
      command.modeId === null &&
      command.reasoningEffort === null,
  );
  assert.ok(withNulls !== undefined, "缺一条 model/modeId/reasoningEffort 全 null 的 createSession");
  const withValues = creates.find(
    (command) =>
      command.type === "createSession" &&
      command.model !== null &&
      command.modeId !== null &&
      command.reasoningEffort !== null,
  );
  assert.ok(withValues !== undefined, "缺一条可空字段全有值的 createSession");
});
