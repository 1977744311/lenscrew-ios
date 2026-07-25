import test from "node:test";
import assert from "node:assert/strict";

import { SessionHub } from "../src/session/hub.ts";
import type { AdapterEvent, AgentAdapter, AdapterEventSink } from "../src/adapters/types.ts";
import type { AgentCapabilities, BridgeEvent } from "../src/protocol/events.ts";

const fullCapabilities: AgentCapabilities = {
  approvals: true,
  steering: true,
  interrupt: true,
  planMode: true,
  resume: true,
  streamingDeltas: true,
};

/** 只记录调用、不起进程的假 adapter */
class FakeAdapter implements AgentAdapter {
  readonly kind = "codex" as const;
  capabilities: AgentCapabilities;
  readonly sink: AdapterEventSink;
  readonly calls: string[] = [];

  constructor(sink: AdapterEventSink, capabilities: AgentCapabilities = fullCapabilities) {
    this.sink = sink;
    this.capabilities = capabilities;
  }

  async start(): Promise<void> {
    this.calls.push("start");
    this.sink({ type: "status", status: "running" });
  }
  async sendMessage(text: string): Promise<void> {
    this.calls.push(`send:${text}`);
  }
  async interrupt(): Promise<void> {
    this.calls.push("interrupt");
  }
  async resolveApproval(approvalId: string, optionId: string): Promise<void> {
    this.calls.push(`approve:${approvalId}:${optionId}`);
  }
  async close(): Promise<void> {
    this.calls.push("close");
  }
}

function makeHub(capabilities: AgentCapabilities = fullCapabilities): {
  hub: SessionHub;
  events: BridgeEvent[];
  adapters: FakeAdapter[];
} {
  const adapters: FakeAdapter[] = [];
  const hub = new SessionHub((_kind, sink) => {
    const adapter = new FakeAdapter(sink, capabilities);
    adapters.push(adapter);
    return adapter;
  });
  const events: BridgeEvent[] = [];
  hub.onEvent((event) => events.push(event));
  return { hub, events, adapters };
}

async function openSession(hub: SessionHub): Promise<void> {
  await hub.handle({
    type: "createSession",
    agent: "codex",
    workspaceRoot: "/Users/dev/project",
    model: null,
    mode: "default",
  });
}

test("seq 在会话内连续递增，不留空洞", async () => {
  const { hub, events, adapters } = makeHub();
  await openSession(hub);
  const adapter = adapters[0]!;
  adapter.sink({
    type: "blockAppended",
    block: { kind: "agentMessage", id: "b1", text: "你好", streaming: true },
  });
  adapter.sink({
    type: "blockUpdated",
    blockId: "b1",
    patch: { appendText: "，世界", streaming: false },
  });

  // 建会话本身产出 sessionCreated、status、以及 start() 之后的能力快照
  assert.deepEqual(
    events.map((event) => event.seq),
    [1, 2, 3, 4, 5],
  );
});

/** seq 出洞就是客户端眼里一次永远补不齐的断档 */
test("元数据变更走 sessionUpdated 快照，seq 依然没有洞", async () => {
  const { hub, events, adapters } = makeHub();
  await openSession(hub);
  const adapter = adapters[0]!;
  adapter.sink({ type: "nativeIdAssigned", nativeId: "thread_abc" });
  adapter.sink({ type: "modelResolved", model: "gpt-5-codex" });
  adapter.sink({ type: "titleResolved", title: "修登录 500" });

  const seqs = events.map((event) => event.seq);
  assert.deepEqual(seqs, [...seqs.keys()].map((index) => index + 1));

  const updates = events.filter((event) => event.type === "sessionUpdated");
  assert.equal(updates.length, 4, "start 的能力快照 + 三次元数据变更");

  const session = hub.listSessions()[0]!;
  assert.equal(session.nativeId, "thread_abc");
  assert.equal(session.model, "gpt-5-codex");
  assert.equal(session.title, "修登录 500");
});

/** 几个 adapter 的真实能力要 start() 之后才确定，客户端据此决定显不显示审批 UI */
test("start 之后补一次快照，把修正后的 capabilities 发出去", async () => {
  const adapters: FakeAdapter[] = [];
  const hub = new SessionHub((_kind, sink) => {
    // 建会话时自称不支持审批，start() 之后才发现支持
    const adapter = new FakeAdapter(sink, { ...fullCapabilities, approvals: false });
    const originalStart = adapter.start.bind(adapter);
    adapter.start = async () => {
      await originalStart();
      adapter.capabilities = { ...adapter.capabilities, approvals: true };
    };
    adapters.push(adapter);
    return adapter;
  });
  const events: BridgeEvent[] = [];
  hub.onEvent((event) => events.push(event));
  await openSession(hub);

  const created = events.find((event) => event.type === "sessionCreated");
  assert.ok(created && created.type === "sessionCreated");
  assert.equal(created.session.capabilities.approvals, false);

  const updated = events.findLast((event) => event.type === "sessionUpdated");
  assert.ok(updated && updated.type === "sessionUpdated");
  assert.equal(updated.session.capabilities.approvals, true);
  assert.equal(hub.listSessions()[0]!.capabilities.approvals, true);
});

test("会话标题取工作目录名", async () => {
  const { hub } = makeHub();
  await openSession(hub);
  assert.equal(hub.listSessions()[0]!.title, "project");
});

test("重放只给 fromSeq 之后的事件", async () => {
  const { hub, adapters } = makeHub();
  await openSession(hub);
  const adapter = adapters[0]!;
  for (let index = 0; index < 5; index += 1) {
    adapter.sink({
      type: "blockAppended",
      block: {
        kind: "agentMessage",
        id: `b${index}`,
        text: `${index}`,
        streaming: false,
      },
    });
  }
  const highest = hub.replay("s-1", 0).at(-1)!.seq;
  const replayed = hub.replay("s-1", highest - 2);
  assert.deepEqual(
    replayed.map((event) => event.seq),
    [highest - 2, highest - 1, highest],
  );
});

test("请求早于保留窗口时补一条会话快照，客户端可以整表重建", async () => {
  const { hub } = makeHub();
  await openSession(hub);
  const replayed = hub.replay("s-1", 0);
  assert.equal(replayed[0]?.type, "sessionCreated");
  // 快照的 seq 必须紧接窗口起点之前，后面的事件才是连续的
  const seqs = replayed.map((event) => event.seq);
  for (let index = 1; index < seqs.length; index += 1) {
    assert.equal(seqs[index], seqs[index - 1]! + 1);
  }
});

test("未知会话重放返回空而不是抛错", () => {
  const { hub } = makeHub();
  assert.deepEqual(hub.replay("nope", 0), []);
});

/** 静默吞掉会让手机端以为批准生效了 */
test("adapter 不支持审批时，回送裁决必须报错", async () => {
  const { hub } = makeHub({ ...fullCapabilities, approvals: false });
  await openSession(hub);
  await assert.rejects(
    hub.handle({
      type: "resolveApproval",
      sessionId: "s-1",
      approvalId: "a1",
      optionId: "approved",
    }),
    /不支持审批回送/,
  );
});

test("审批请求把会话置为待审批", async () => {
  const { hub, adapters } = makeHub();
  await openSession(hub);
  adapters[0]!.sink({
    type: "approvalRequested",
    approval: {
      id: "a1",
      kind: "shellCommand",
      title: "运行 ls",
      detail: "ls",
      cwd: null,
      options: [
        { id: "accept", label: "Approve", kind: "allow", scope: "once" },
      ],
      requestedAtMs: 0,
    },
  });
  assert.equal(hub.listSessions()[0]!.status, "awaitingApproval");
});

test("指令派发到对应 adapter", async () => {
  const { hub, adapters } = makeHub();
  await openSession(hub);
  await hub.handle({ type: "sendMessage", sessionId: "s-1", text: "继续" });
  await hub.handle({ type: "interrupt", sessionId: "s-1" });
  assert.deepEqual(adapters[0]!.calls, ["start", "send:继续", "interrupt"]);
});

test("未知会话的指令报错而不是静默丢弃", async () => {
  const { hub } = makeHub();
  await assert.rejects(
    hub.handle({ type: "sendMessage", sessionId: "ghost", text: "x" }),
    /未知会话/,
  );
});

test("关闭会话后从列表移除", async () => {
  const { hub, adapters } = makeHub();
  await openSession(hub);
  await hub.handle({ type: "closeSession", sessionId: "s-1" });
  assert.deepEqual(hub.listSessions(), []);
  assert.ok(adapters[0]!.calls.includes("close"));
});

test("adapter 启动失败作为致命错误上报，而不是让会话僵在启动中", async () => {
  const events: BridgeEvent[] = [];
  const hub = new SessionHub((_kind, sink) => {
    const adapter = new FakeAdapter(sink);
    adapter.start = async () => {
      throw new Error("codex app-server 未安装");
    };
    return adapter;
  });
  hub.onEvent((event) => events.push(event));
  await openSession(hub);

  const failure = events.find((event) => event.type === "bridgeError");
  assert.ok(failure && failure.type === "bridgeError");
  assert.equal(failure.fatal, true);
  assert.match(failure.message, /未安装/);
});
