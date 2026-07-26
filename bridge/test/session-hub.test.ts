import test from "node:test";
import { tmpdir } from "node:os";
import assert from "node:assert/strict";

import { SessionHub, type SessionPersistence } from "../src/session/hub.ts";
import type {
  AdapterEvent,
  AdapterStartOptions,
  AgentAdapter,
  AdapterEventSink,
} from "../src/adapters/types.ts";
import type {
  AgentCapabilities,
  BridgeEvent,
  SessionModeOption,
} from "../src/protocol/events.ts";
import type { PersistedSession } from "../src/state/sessionStore.ts";

const fullCapabilities: AgentCapabilities = {
  approvals: true,
  steering: true,
  interrupt: true,
  planMode: true,
  resume: true,
  streamingDeltas: true,
};

const fakeModes: SessionModeOption[] = [
  { id: "default", label: "默认", detail: "每步审批" },
  { id: "full", label: "完全放行", detail: "不问审批" },
];

/** 只记录调用、不起进程的假 adapter */
class FakeAdapter implements AgentAdapter {
  readonly kind = "codex" as const;
  capabilities: AgentCapabilities;
  readonly modes: SessionModeOption[] = fakeModes;
  readonly defaultModeId: string = "default";
  currentModeId: string = "default";
  readonly sink: AdapterEventSink;
  readonly calls: string[] = [];
  startOptions: AdapterStartOptions | null = null;

  constructor(sink: AdapterEventSink, capabilities: AgentCapabilities = fullCapabilities) {
    this.sink = sink;
    this.capabilities = capabilities;
  }

  async start(options: AdapterStartOptions): Promise<void> {
    this.startOptions = options;
    this.calls.push("start");
    // 恢复失败路径的注入口：resume 一个标记为坏的 nativeId 就抛
    if (options.resumeNativeId === "native-broken") {
      throw new Error("rollout 不存在");
    }
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
  async setMode(modeId: string): Promise<void> {
    this.calls.push(`setMode:${modeId}`);
    this.currentModeId = modeId;
    this.sink({ type: "modeResolved", modeId });
  }
  async setModel(modelId: string): Promise<void> {
    this.calls.push(`setModel:${modelId}`);
    this.sink({ type: "modelResolved", model: modelId });
  }
  async setReasoningEffort(effort: string): Promise<void> {
    this.calls.push(`setEffort:${effort}`);
    this.sink({ type: "reasoningEffortResolved", effort });
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
    workspaceRoot: tmpdir(),
    model: null,
    modeId: null,
    reasoningEffort: null,
  });
}

test("工作目录不存在时给人话错误，不去拉起 adapter", async () => {
  const { hub, events, adapters } = makeHub();
  await hub.handle({
    type: "createSession",
    agent: "codex",
    workspaceRoot: "/no/such/dir-lenscrew-test",
    model: null,
    modeId: null,
    reasoningEffort: null,
  });

  const failure = events.find((event) => event.type === "bridgeError");
  assert.ok(failure?.type === "bridgeError");
  assert.match(failure.message, /工作目录不存在/);
  assert.equal(failure.fatal, true);
  // spawn cwd 不存在会报误导性的 "spawn <命令> ENOENT"，必须拦在 start 之前
  assert.ok(!adapters[0]!.calls.includes("start"));
});

/** 数组顶替文件的持久化，测试直接断言内容 */
function memoryPersistence(initial: PersistedSession[] = []): {
  persistence: SessionPersistence;
  saved: () => PersistedSession[];
} {
  let stored = initial;
  return {
    persistence: {
      load: () => stored,
      save: (sessions) => {
        stored = sessions;
      },
    },
    saved: () => stored,
  };
}

test("会话路由表随 nativeId 落盘，关会话即从持久化删除", async () => {
  const { persistence, saved } = memoryPersistence();
  const adapters: FakeAdapter[] = [];
  const hub = new SessionHub((_kind, sink) => {
    const adapter = new FakeAdapter(sink);
    adapters.push(adapter);
    return adapter;
  }, persistence);

  await hub.handle({
    type: "createSession",
    agent: "codex",
    workspaceRoot: tmpdir(),
    model: null,
    modeId: "full",
    reasoningEffort: null,
  });
  // nativeId 还没到手，无从续接，不落盘
  assert.deepEqual(saved(), []);

  adapters[0]!.sink({ type: "nativeIdAssigned", nativeId: "thread-1" });
  assert.equal(saved().length, 1);
  assert.equal(saved()[0]!.nativeId, "thread-1");
  assert.equal(saved()[0]!.workspaceRoot, tmpdir());
  assert.equal(saved()[0]!.modeId, "full");

  await hub.handle({ type: "closeSession", sessionId: "s-1" });
  assert.deepEqual(saved(), []);
});

test("restorePersisted 逐条续接，失败的条目清除且不留僵尸会话", async () => {
  const { persistence, saved } = memoryPersistence([
    {
      agent: "codex",
      nativeId: "native-good",
      workspaceRoot: tmpdir(),
      model: null,
      modeId: "full",
      updatedAtMs: 1,
    },
    {
      agent: "codex",
      nativeId: "native-broken",
      workspaceRoot: tmpdir(),
      model: null,
      modeId: null,
      updatedAtMs: 2,
    },
  ]);
  const adapters: FakeAdapter[] = [];
  const hub = new SessionHub((_kind, sink) => {
    const adapter = new FakeAdapter(sink);
    adapters.push(adapter);
    return adapter;
  }, persistence);

  await hub.restorePersisted();

  // 成功的续上：resume 参数原样传给 adapter，模式还原
  const sessions = hub.listSessions();
  assert.equal(sessions.length, 1);
  assert.equal(sessions[0]!.nativeId, "native-good");
  assert.equal(sessions[0]!.modeId, "full");
  assert.equal(adapters[0]!.startOptions?.resumeNativeId, "native-good");
  assert.equal(adapters[0]!.startOptions?.modeId, "full");

  // 失败的不留僵尸，持久化里也只剩活着的
  assert.equal(saved().length, 1);
  assert.equal(saved()[0]!.nativeId, "native-good");
});

test("setSessionMode 派发到 adapter，回显后快照携带新模式", async () => {
  const { hub, events, adapters } = makeHub();
  await openSession(hub);
  const created = events.find((event) => event.type === "sessionCreated");
  assert.ok(created?.type === "sessionCreated");
  assert.equal(created.session.modeId, "default");
  assert.deepEqual(
    created.session.modes.map((mode) => mode.id),
    ["default", "full"],
  );

  await hub.handle({ type: "setSessionMode", sessionId: "s-1", modeId: "full" });
  assert.ok(adapters[0]!.calls.includes("setMode:full"));
  const updated = events.filter((event) => event.type === "sessionUpdated").at(-1);
  assert.ok(updated?.type === "sessionUpdated");
  assert.equal(updated.session.modeId, "full");
});

test("setSessionModel 派发到 adapter，回显与清单都进快照", async () => {
  const { hub, events, adapters } = makeHub();
  await openSession(hub);

  // 运行时自陈的模型清单进会话快照
  adapters[0]!.sink({
    type: "modelsResolved",
    models: [
      { id: "m-fast", label: "Fast", reasoningEfforts: [] },
      { id: "m-max", label: "Max", reasoningEfforts: ["low", "high"] },
    ],
  });
  await hub.handle({ type: "setSessionModel", sessionId: "s-1", modelId: "m-max" });
  assert.ok(adapters[0]!.calls.includes("setModel:m-max"));

  const updated = events.filter((event) => event.type === "sessionUpdated").at(-1);
  assert.ok(updated?.type === "sessionUpdated");
  assert.equal(updated.session.model, "m-max");
  assert.deepEqual(
    updated.session.models.map((option) => option.id),
    ["m-fast", "m-max"],
  );
});

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
    adapter.start = async (options: AdapterStartOptions) => {
      await originalStart(options);
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
  assert.equal(hub.listSessions()[0]!.title, tmpdir().split("/").pop());
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

test("关闭会话后从列表移除，并广播 sessionClosed 让客户端撤掉这行", async () => {
  const { hub, events, adapters } = makeHub();
  await openSession(hub);
  await hub.handle({ type: "closeSession", sessionId: "s-1" });
  assert.deepEqual(hub.listSessions(), []);
  assert.ok(adapters[0]!.calls.includes("close"));
  const closed = events.find((event) => event.type === "sessionClosed");
  assert.ok(closed?.type === "sessionClosed");
  assert.equal(closed.sessionId, "s-1");
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

function windowOf(id: string, usedPercent: number) {
  return { id, label: null, usedPercent, windowDurationMins: 10080, resetsAt: 1785640649 };
}

test("额度事件不占会话 seq，广播 seq 恒为 0 且可供接入补发", async () => {
  const { hub, events, adapters } = makeHub();
  await openSession(hub);
  const before = hub.listSessions()[0]!.updatedAtMs;

  adapters[0]!.sink({
    type: "quotaUpdated",
    quota: {
      agent: "codex",
      planType: "pro",
      windows: [windowOf("codex/primary", 37)],
      capturedAtMs: 100,
    },
  });
  adapters[0]!.sink({
    type: "blockAppended",
    block: { kind: "agentMessage", id: "b1", text: "你好", streaming: true },
  });

  const quota = events.find((event) => event.type === "quotaUpdated");
  assert.ok(quota && quota.type === "quotaUpdated");
  assert.equal(quota.seq, 0);
  // 会话 seq 没有被额度事件占号：sessionCreated=1、capabilitiesResolved=2、status=3，block 应是 4
  const block = events.find((event) => event.type === "blockAppended");
  assert.ok(block && block.type === "blockAppended");
  assert.equal(block.seq, 4);
  // 账号级事件不该动会话元数据
  assert.equal(hub.listSessions()[0]!.updatedAtMs >= before, true);
  assert.deepEqual(hub.latestQuota(), [
    {
      agent: "codex",
      planType: "pro",
      windows: [windowOf("codex/primary", 37)],
      capturedAtMs: 100,
    },
  ]);
});

test("稀疏更新按窗口 id 合并进缓存，主桶窗口排最前", () => {
  const { hub, events } = makeHub();
  hub.ingestQuota({
    agent: "codex",
    planType: "pro",
    windows: [windowOf("codex/primary", 10), windowOf("codex_bengalfox/primary", 5)],
    capturedAtMs: 100,
  });
  // updated 通知只带模型桶：合并后主桶数字保留、模型桶更新
  hub.ingestQuota({
    agent: "codex",
    planType: null,
    windows: [windowOf("codex_bengalfox/primary", 30)],
    capturedAtMs: 200,
  });

  const merged = hub.latestQuota()[0]!;
  assert.equal(merged.planType, "pro");
  assert.deepEqual(
    merged.windows.map((window) => [window.id, window.usedPercent]),
    [
      ["codex/primary", 10],
      ["codex_bengalfox/primary", 30],
    ],
  );
  assert.equal(merged.capturedAtMs, 200);
  assert.equal(events.filter((event) => event.type === "quotaUpdated").length, 2);
});

test("内容没变只刷新缓存时间戳，不再广播", () => {
  const { hub, events } = makeHub();
  const snapshot = {
    agent: "codex" as const,
    planType: "pro",
    windows: [windowOf("codex/primary", 37)],
    capturedAtMs: 100,
  };
  hub.ingestQuota(snapshot);
  hub.ingestQuota({ ...snapshot, capturedAtMs: 999 });

  assert.equal(events.filter((event) => event.type === "quotaUpdated").length, 1);
  // 新客户端接入补发时应拿到最新的采集时间，而不是被去重丢掉
  assert.equal(hub.latestQuota()[0]!.capturedAtMs, 999);
});
