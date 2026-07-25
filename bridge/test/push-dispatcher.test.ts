import test from "node:test";
import assert from "node:assert/strict";

import { createPushDispatcher, truncateForAlert } from "../src/push/pushDispatcher.ts";
import type { PushTokenRegistry } from "../src/push/pushDispatcher.ts";
import type { ApprovalOption, BridgeEvent, TurnStopReason } from "../src/protocol/events.ts";

function makeRegistry(): PushTokenRegistry {
  return {
    "phone-a": {
      deviceToken: "tok-a",
      environment: "production",
      alertsEnabled: { approvals: true, turns: true },
    },
    "phone-b": {
      deviceToken: "tok-b",
      environment: "sandbox",
      alertsEnabled: { approvals: false, turns: true },
    },
  };
}

function approvalEvent(
  approvalId: string,
  detail = "npm install left-pad",
  options: ApprovalOption[] = [],
): BridgeEvent {
  return {
    type: "approvalRequested",
    seq: 7,
    sessionId: "session-1",
    approval: {
      id: approvalId,
      kind: "shellCommand",
      title: "运行 shell 命令",
      detail,
      cwd: null,
      options,
      requestedAtMs: 0,
    },
  };
}

function lenscrewDict(pushes: ReturnType<PushDispatcher["dispatch"]>): Record<string, unknown> {
  return pushes[0]!.payload["lenscrew"] as Record<string, unknown>;
}

type PushDispatcher = ReturnType<typeof createPushDispatcher>;

test("approvalRequested:只发给 alertsEnabled.approvals 的 token,payload 逐字段符合约定", () => {
  const dispatcher = createPushDispatcher();
  const pushes = dispatcher.dispatch(approvalEvent("appr-1"), makeRegistry());
  assert.equal(pushes.length, 1);
  assert.deepEqual(pushes[0], {
    phoneDeviceId: "phone-a",
    deviceToken: "tok-a",
    environment: "production",
    payload: {
      aps: {
        alert: { title: "运行 shell 命令", body: "npm install left-pad" },
        sound: "default",
        "thread-id": "session-1",
        "interruption-level": "time-sensitive",
        category: "LENSCREW_APPROVAL",
      },
      lenscrew: { kind: "approval", sessionId: "session-1", approvalId: "appr-1" },
    },
  });
});

test("approvalRequested:同一 approvalId 幂等只发一次,新 id 正常发", () => {
  const dispatcher = createPushDispatcher();
  const registry = makeRegistry();
  assert.equal(dispatcher.dispatch(approvalEvent("appr-1"), registry).length, 1);
  assert.equal(dispatcher.dispatch(approvalEvent("appr-1"), registry).length, 0);
  assert.equal(dispatcher.dispatch(approvalEvent("appr-2"), registry).length, 1);
});

test("approvalRequested:lenscrew 带 macDeviceId 与裁决 optionId(allow+once 优先,deny 取首个)", () => {
  const dispatcher = createPushDispatcher();
  const options: ApprovalOption[] = [
    { id: "acceptForSession", label: "本会话都批", kind: "allow", scope: "session" },
    { id: "accept", label: "批准", kind: "allow", scope: "once" },
    { id: "decline", label: "拒绝", kind: "deny", scope: "once" },
    { id: "declineAlways", label: "永久拒绝", kind: "deny", scope: "persistent" },
  ];
  const pushes = dispatcher.dispatch(approvalEvent("appr-opt", "npm test", options), makeRegistry(), {
    macDeviceId: "mac-1",
  });
  assert.deepEqual(lenscrewDict(pushes), {
    kind: "approval",
    sessionId: "session-1",
    approvalId: "appr-opt",
    macDeviceId: "mac-1",
    onceAllowOptionId: "accept",
    denyOptionId: "decline",
  });
});

test("approvalRequested:没有 once 档时 onceAllowOptionId 退化取任意 allow", () => {
  const dispatcher = createPushDispatcher();
  const options: ApprovalOption[] = [
    { id: "acceptForSession", label: "本会话都批", kind: "allow", scope: "session" },
  ];
  const dict = lenscrewDict(
    dispatcher.dispatch(approvalEvent("appr-fallback", "npm test", options), makeRegistry(), {
      macDeviceId: "mac-1",
    }),
  );
  assert.equal(dict["onceAllowOptionId"], "acceptForSession");
  assert.ok(!("denyOptionId" in dict), "没有 deny 档时 denyOptionId 必须缺席");
});

test("approvalRequested:没有 allow 档时 onceAllowOptionId 缺席,deny 照常携带", () => {
  const dispatcher = createPushDispatcher();
  const options: ApprovalOption[] = [
    { id: "decline", label: "拒绝", kind: "deny", scope: "once" },
  ];
  const dict = lenscrewDict(
    dispatcher.dispatch(approvalEvent("appr-deny-only", "npm test", options), makeRegistry(), {
      macDeviceId: "mac-1",
    }),
  );
  assert.ok(!("onceAllowOptionId" in dict), "没有 allow 档时 onceAllowOptionId 必须缺席");
  assert.equal(dict["denyOptionId"], "decline");
});

test("approvalRequested:context 没给 macDeviceId、options 为空时三个字段全缺席", () => {
  const dispatcher = createPushDispatcher();
  const dict = lenscrewDict(dispatcher.dispatch(approvalEvent("appr-bare"), makeRegistry()));
  assert.deepEqual(dict, { kind: "approval", sessionId: "session-1", approvalId: "appr-bare" });
});

test("approval detail 超长时 body 截 160 字符", () => {
  const dispatcher = createPushDispatcher();
  const pushes = dispatcher.dispatch(approvalEvent("appr-long", "长".repeat(300)), makeRegistry());
  const aps = pushes[0]!.payload["aps"] as { alert: { body: string } };
  assert.equal(aps.alert.body, "长".repeat(160));
});

test("turnCompleted:stopReason 逐一映射,发给 alertsEnabled.turns 的 token", () => {
  const cases: readonly (readonly [TurnStopReason, string])[] = [
    ["completed", "轮次完成"],
    ["interrupted", "已中断"],
    ["maxTokens", "达到 token 上限"],
    ["refused", "被拒绝"],
    ["failed", "轮次失败"],
  ];
  for (const [stopReason, body] of cases) {
    const dispatcher = createPushDispatcher();
    const event: BridgeEvent = {
      type: "turnCompleted",
      seq: 9,
      sessionId: "session-2",
      inputTokens: null,
      outputTokens: null,
      cachedInputTokens: null,
      stopReason,
    };
    const pushes = dispatcher.dispatch(event, makeRegistry());
    assert.equal(pushes.length, 2, "两台手机都开了 turns");
    assert.deepEqual(pushes[0]!.payload, {
      aps: { alert: { title: "轮次结束", body }, category: "LENSCREW_TURN" },
      lenscrew: { kind: "turn", sessionId: "session-2", stopReason },
    });
  }
});

test("turnCompleted:stopReason null 回落「轮次结束」;传入 sessionTitle 时作标题", () => {
  const dispatcher = createPushDispatcher();
  const event: BridgeEvent = {
    type: "turnCompleted",
    seq: 10,
    sessionId: "session-2",
    inputTokens: 100,
    outputTokens: 50,
    cachedInputTokens: 0,
    stopReason: null,
  };
  const pushes = dispatcher.dispatch(event, makeRegistry(), { sessionTitle: "修复登录页" });
  const aps = pushes[0]!.payload["aps"] as { alert: { title: string; body: string } };
  assert.equal(aps.alert.title, "修复登录页");
  assert.equal(aps.alert.body, "轮次结束");
});

test("bridgeError:fatal 才推,且无视开关发给全部 token", () => {
  const dispatcher = createPushDispatcher();
  const fatal: BridgeEvent = {
    type: "bridgeError",
    seq: 11,
    sessionId: null,
    message: "e".repeat(300),
    fatal: true,
  };
  const pushes = dispatcher.dispatch(fatal, makeRegistry());
  assert.equal(pushes.length, 2, "approvals=false 的手机也要收到致命错误");
  assert.deepEqual(pushes[1]!.payload, {
    aps: { alert: { title: "bridge 出错", body: "e".repeat(160) } },
    lenscrew: { kind: "bridgeError", sessionId: null },
  });

  const nonFatal: BridgeEvent = { ...fatal, fatal: false };
  assert.equal(dispatcher.dispatch(nonFatal, makeRegistry()).length, 0);
});

test("markTokenGone:410 后该 token 从所有后续分发中剔除", () => {
  const dispatcher = createPushDispatcher();
  const registry = makeRegistry();
  dispatcher.markTokenGone("tok-b");
  const event: BridgeEvent = {
    type: "turnCompleted",
    seq: 12,
    sessionId: "session-3",
    inputTokens: null,
    outputTokens: null,
    cachedInputTokens: null,
    stopReason: "completed",
  };
  const pushes = dispatcher.dispatch(event, registry);
  assert.deepEqual(pushes.map((p) => p.deviceToken), ["tok-a"]);
});

test("无关事件不产生推送", () => {
  const dispatcher = createPushDispatcher();
  const event: BridgeEvent = {
    type: "sessionStatus",
    seq: 13,
    sessionId: "session-1",
    status: "running",
  };
  assert.deepEqual(dispatcher.dispatch(event, makeRegistry()), []);
});

test("truncateForAlert:按码点截断,不劈开代理对", () => {
  assert.equal(truncateForAlert("短文本"), "短文本");
  const emoji = "😀".repeat(200);
  const truncated = truncateForAlert(emoji);
  assert.equal([...truncated].length, 160);
  assert.equal(truncated, "😀".repeat(160));
});
