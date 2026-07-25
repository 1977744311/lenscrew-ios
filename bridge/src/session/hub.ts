import type {
  AgentKind,
  AgentSession,
  BridgeEvent,
  ClientCommand,
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
    record.session.updatedAtMs = Date.now();

    // 只改会话元数据、不上线的事件必须在编号之前返回：
    // 白吃一个 seq 会在客户端看来就是一次永远补不齐的断档。
    if (event.type === "nativeIdAssigned") {
      record.session.nativeId = event.nativeId;
      return;
    }
    if (event.type === "modelResolved") {
      record.session.model = event.model;
      return;
    }

    const seq = ++record.seq;
    const sessionId = record.session.id;

    let bridgeEvent: BridgeEvent;
    switch (event.type) {
      case "sessionCreated":
        bridgeEvent = { type: "sessionCreated", seq, session: event.session };
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

    record.log.push(bridgeEvent);
    if (record.log.length > MAX_RETAINED_EVENTS) {
      record.log.splice(0, record.log.length - MAX_RETAINED_EVENTS);
    }
    for (const listener of this.#listeners) listener(bridgeEvent);
  }

  /** adapter 构造时把这个交给它当 sink */
  sinkFor(sessionId: string): (event: AdapterEvent) => void {
    return (event) => {
      const record = this.#sessions.get(sessionId);
      if (record) this.#emit(record, event);
    };
  }
}
