import type {
  AgentKind,
  AgentQuotaSnapshot,
  AgentSession,
  BridgeEvent,
  ClientCommand,
  QuotaWindow,
  SessionMode,
} from "../protocol/events.ts";
import type { AdapterEvent, AgentAdapter } from "../adapters/types.ts";

export type AdapterFactory = (
  kind: AgentKind,
  sink: (event: AdapterEvent) => void,
) => AgentAdapter;
export type BridgeEventListener = (event: BridgeEvent) => void;

/**
 * 每个会话保留的事件上限。会话开久了流水会很长，无上限就是内存泄漏；
 * 客户端请求的 fromSeq 早于窗口时走整表重建（见 subscribe）。
 */
const MAX_RETAINED_EVENTS = 5000;

/**
 * 事件里必须放会话的拷贝而不是 record 里那个活对象：
 * 会话元数据是原地改的，共用引用会让已经发出去、以及留在重放窗口里的旧事件
 * 跟着变成最新状态——那样事件日志就在谎报历史。
 */
function snapshot(session: AgentSession): AgentSession {
  return { ...session, capabilities: { ...session.capabilities } };
}

/** 主桶 "codex" 的窗口排最前，其余按 id 字典序；顺序稳定合并去重才可比 */
function sortQuotaWindows(windows: QuotaWindow[]): QuotaWindow[] {
  return windows.sort((a, b) => {
    const limitA = a.id.split("/")[0] ?? "";
    const limitB = b.id.split("/")[0] ?? "";
    if (limitA !== limitB) {
      if (limitA === "codex") return -1;
      if (limitB === "codex") return 1;
      return limitA < limitB ? -1 : 1;
    }
    return a.id < b.id ? -1 : 1;
  });
}

/** 只比内容不比 capturedAtMs：数字没变就不值得再广播一轮 */
function sameQuotaContent(a: AgentQuotaSnapshot, b: AgentQuotaSnapshot): boolean {
  return (
    JSON.stringify({ planType: a.planType, windows: a.windows }) ===
    JSON.stringify({ planType: b.planType, windows: b.windows })
  );
}

interface SessionRecord {
  session: AgentSession;
  adapter: AgentAdapter;
  /** 已分配的最大 seq */
  seq: number;
  /** 保留窗口，按 seq 递增 */
  log: BridgeEvent[];
}

/**
 * 会话总线：给事件编号、留一段可重放的窗口、把客户端指令派到对应 adapter。
 *
 * seq 在这里统一分配而不是由 adapter 各自维护，是为了让 adapter 的 normalizer
 * 保持纯函数、能直接对着 fixture 断言。
 */
export class SessionHub {
  readonly #makeAdapter: AdapterFactory;
  readonly #sessions = new Map<string, SessionRecord>();
  readonly #listeners = new Set<BridgeEventListener>();
  /** 账号级额度缓存，按 agent 各留最新一份；会话关了它也得活着 */
  readonly #quota = new Map<AgentKind, AgentQuotaSnapshot>();
  #nextSessionOrdinal = 1;

  constructor(makeAdapter: AdapterFactory) {
    this.#makeAdapter = makeAdapter;
  }

  onEvent(listener: BridgeEventListener): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  listSessions(): AgentSession[] {
    return [...this.#sessions.values()].map((record) => record.session);
  }

  /** 新客户端接入时补发用；顺序无约定 */
  latestQuota(): AgentQuotaSnapshot[] {
    return [...this.#quota.values()];
  }

  /**
   * 并入一份（可能稀疏的）额度快照并在内容变化时广播。
   * 入口有两个：会话 adapter 的 quotaUpdated 事件、无会话时的定期探针。
   * codex 的 updated 通知只带单桶，按窗口 id 与既有缓存合并成全量。
   */
  ingestQuota(incoming: AgentQuotaSnapshot): void {
    const previous = this.#quota.get(incoming.agent);
    const byId = new Map<string, QuotaWindow>();
    for (const window of previous?.windows ?? []) byId.set(window.id, window);
    for (const window of incoming.windows) byId.set(window.id, { ...window });
    const merged: AgentQuotaSnapshot = {
      agent: incoming.agent,
      planType: incoming.planType ?? previous?.planType ?? null,
      windows: sortQuotaWindows([...byId.values()]),
      capturedAtMs: incoming.capturedAtMs,
    };
    // 内容没变只刷新缓存时间戳（新客户端该知道数据仍然新鲜），不再广播
    this.#quota.set(incoming.agent, merged);
    if (previous !== undefined && sameQuotaContent(previous, merged)) return;
    const event: BridgeEvent = { type: "quotaUpdated", seq: 0, quota: merged };
    for (const listener of this.#listeners) listener(event);
  }

  async handle(command: ClientCommand): Promise<void> {
    switch (command.type) {
      case "listSessions":
        for (const record of this.#sessions.values()) {
          this.#emit(record, { type: "sessionCreated", session: record.session });
        }
        return;

      case "createSession":
        await this.#open(
          command.agent,
          command.workspaceRoot,
          command.model,
          command.mode,
          null,
        );
        return;

      case "resumeSession":
        await this.#open(
          command.agent,
          command.workspaceRoot,
          null,
          "default",
          command.nativeId,
        );
        return;

      case "sendMessage":
        await this.#require(command.sessionId).adapter.sendMessage(command.text);
        return;

      case "interrupt":
        await this.#require(command.sessionId).adapter.interrupt();
        return;

      case "resolveApproval": {
        const record = this.#require(command.sessionId);
        if (!record.session.capabilities.approvals) {
          // 静默吞掉会让手机端以为批准生效了，必须显式报错
          throw new Error(
            `${record.session.agent} 当前驱动方式不支持审批回送`,
          );
        }
        await record.adapter.resolveApproval(command.approvalId, command.optionId);
        return;
      }

      case "closeSession": {
        const record = this.#require(command.sessionId);
        await record.adapter.close();
        this.#emit(record, { type: "status", status: "ended" });
        this.#sessions.delete(command.sessionId);
        return;
      }

      case "subscribe":
        return;
    }
  }

  /**
   * 重放窗口内的事件。fromSeq 早于窗口起点时，先补一条携带当前会话快照的
   * sessionCreated（seq 落在窗口起点前一位），客户端据此重建后再连续应用窗口，
   * 这样不会留下永远补不齐的断档。
   */
  replay(sessionId: string, fromSeq: number): BridgeEvent[] {
    const record = this.#sessions.get(sessionId);
    if (!record) return [];
    const oldest = record.log[0]?.seq ?? record.seq + 1;
    if (fromSeq >= oldest) {
      return record.log.filter((event) => event.seq >= fromSeq);
    }
    return [
      { type: "sessionCreated", seq: oldest - 1, session: record.session },
      ...record.log,
    ];
  }

  async closeAll(): Promise<void> {
    await Promise.allSettled(
      [...this.#sessions.values()].map((record) => record.adapter.close()),
    );
    this.#sessions.clear();
  }

  // MARK: - 内部

  async #open(
    agent: AgentKind,
    workspaceRoot: string,
    model: string | null,
    mode: SessionMode,
    resumeNativeId: string | null,
  ): Promise<void> {
    // 先定 id 再造 adapter：sink 要按 id 回查记录，而记录要用 adapter 的 capabilities。
    // sink 是惰性查表的，adapter 构造时记录还不存在也无妨。
    const id = `s-${this.#nextSessionOrdinal++}`;
    const adapter = this.#makeAdapter(agent, this.sinkFor(id));
    const now = Date.now();
    const record: SessionRecord = {
      adapter,
      seq: 0,
      log: [],
      session: {
        id,
        agent,
        nativeId: resumeNativeId,
        workspaceRoot,
        title: workspaceRoot.split("/").pop() ?? workspaceRoot,
        model,
        status: "starting",
        capabilities: adapter.capabilities,
        createdAtMs: now,
        updatedAtMs: now,
      },
    };
    this.#sessions.set(id, record);
    this.#emit(record, { type: "sessionCreated", session: record.session });

    try {
      await adapter.start({ workspaceRoot, model, mode, resumeNativeId });
      // sessionCreated 必须早于 start()，否则启动期间的事件没有会话可归属；
      // 但真实能力要 start() 之后才确定，所以这里补一次快照修正它。
      this.#emit(record, { type: "capabilitiesResolved" });
    } catch (error) {
      this.#emit(record, {
        type: "error",
        message: error instanceof Error ? error.message : String(error),
        fatal: true,
      });
    }
  }

  #require(sessionId: string): SessionRecord {
    const record = this.#sessions.get(sessionId);
    if (!record) throw new Error(`未知会话 ${sessionId}`);
    return record;
  }

  /** adapter 事件 + sessionCreated 的统一出口：编号、记录、扇出 */
  #emit(
    record: SessionRecord,
    event: AdapterEvent | { type: "sessionCreated"; session: AgentSession },
  ): void {
    // 账号级事件走 host 级缓存，不编号、不进会话日志、不碰会话元数据
    if (event.type === "quotaUpdated") {
      this.ingestQuota(event.quota);
      return;
    }

    record.session.updatedAtMs = Date.now();

    // 元数据变更改完就走 sessionUpdated 快照，不各自开一种事件：
    // 客户端只需要"会话元数据换了一份"，不关心是哪一项换的。
    if (
      event.type === "nativeIdAssigned" ||
      event.type === "modelResolved" ||
      event.type === "titleResolved" ||
      event.type === "capabilitiesResolved"
    ) {
      if (event.type === "nativeIdAssigned") record.session.nativeId = event.nativeId;
      if (event.type === "modelResolved") record.session.model = event.model;
      if (event.type === "titleResolved") record.session.title = event.title;
      record.session.capabilities = record.adapter.capabilities;
      this.#publish(record, {
        type: "sessionUpdated",
        seq: ++record.seq,
        session: snapshot(record.session),
      });
      return;
    }

    const seq = ++record.seq;
    const sessionId = record.session.id;

    let bridgeEvent: BridgeEvent;
    switch (event.type) {
      case "sessionCreated":
        bridgeEvent = { type: "sessionCreated", seq, session: snapshot(event.session) };
        break;
      case "status":
        record.session.status = event.status;
        bridgeEvent = { type: "sessionStatus", seq, sessionId, status: event.status };
        break;
      case "blockAppended":
        bridgeEvent = { type: "blockAppended", seq, sessionId, block: event.block };
        break;
      case "blockUpdated":
        bridgeEvent = {
          type: "blockUpdated",
          seq,
          sessionId,
          blockId: event.blockId,
          patch: event.patch,
        };
        break;
      case "approvalRequested":
        record.session.status = "awaitingApproval";
        bridgeEvent = {
          type: "approvalRequested",
          seq,
          sessionId,
          approval: event.approval,
        };
        break;
      case "approvalSettled":
        bridgeEvent = {
          type: "approvalSettled",
          seq,
          sessionId,
          approvalId: event.approvalId,
          optionId: event.optionId,
          outcome: event.outcome,
        };
        break;
      case "turnCompleted":
        bridgeEvent = {
          type: "turnCompleted",
          seq,
          sessionId,
          inputTokens: event.inputTokens,
          outputTokens: event.outputTokens,
          cachedInputTokens: event.cachedInputTokens,
          stopReason: event.stopReason,
        };
        break;
      case "error":
        bridgeEvent = {
          type: "bridgeError",
          seq,
          sessionId,
          message: event.message,
          fatal: event.fatal,
        };
        break;
    }

    this.#publish(record, bridgeEvent);
  }

  #publish(record: SessionRecord, event: BridgeEvent): void {
    record.log.push(event);
    if (record.log.length > MAX_RETAINED_EVENTS) {
      record.log.splice(0, record.log.length - MAX_RETAINED_EVENTS);
    }
    for (const listener of this.#listeners) listener(event);
  }

  /** adapter 构造时把这个交给它当 sink */
  sinkFor(sessionId: string): (event: AdapterEvent) => void {
    return (event) => {
      const record = this.#sessions.get(sessionId);
      if (record) this.#emit(record, event);
    };
  }
}
