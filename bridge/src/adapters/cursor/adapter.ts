import { spawn, type ChildProcess } from "node:child_process";
import type {
  AgentCapabilities,
  AgentKind,
  SessionModeOption,
} from "../../protocol/events.ts";
import type {
  AdapterEvent,
  AdapterEventSink,
  AdapterStartOptions,
  AgentAdapter,
} from "../types.ts";
import { CursorAcpNormalizer } from "./acpNormalizer.ts";
import { CursorPrintNormalizer } from "./printNormalizer.ts";
import type { AcpInitializeResult, AcpWireMessage, CursorPrintMessage, JsonRpcId } from "./protocol.ts";

/**
 * 驱动路径。两条路径的差别不是「快慢」而是「能不能审批」，所以由它决定 capabilities。
 * acp 为默认；print 只在 acp 拉不起来时降级用。
 */
export type CursorDrive = "acp" | "print";

/**
 * 2026-07-25 实测得到的能力表。逐项理由：
 *
 * approvals  acp=true：session/request_permission 真的会打到客户端，答复后命令才执行。
 *            print=false：需要审批的 shell 调用根本不问客户端，直接以 result.rejected 收场。
 * steering   两条都 false：ACP 一轮 prompt 未结束时能否再发 prompt 没有实测，
 *            宁可少报也不虚报；print 是一次性进程，更没有插话可言。
 * interrupt  acp=true：session/cancel 以「通知」发出后，session/prompt 立刻以
 *            stopReason:"cancelled" 返回（实测）。注意它只能是通知——发成请求会被
 *            回 -32601 Method not found。print=true 靠 SIGINT 掐子进程。
 * planMode   acp=true：session/set_mode {modeId:"plan"} 实测返回 {}；
 *            print=true：CLI 有 --mode plan。
 * resume     acp=true：新进程里 session/load 一个历史会话成功，并以 user_message_chunk /
 *            tool_call / agent_message_chunk 重放历史（实测）；start 时会再用 agent
 *            自陈的 loadSession 覆盖一次。print=true：CLI 有 --resume <chatId>。
 * streamingDeltas
 *            acp=true：agent_message_chunk 是逐字增量（实测）。
 *            print=false：不加 --stream-partial-output 时整段才给一次；加了之后
 *            CLI 会在增量之后把整段重发一遍，按增量消费就会重复整段回复，
 *            所以我们不开那个 flag，也就没有 token 级增量。
 */
const ACP_CAPABILITIES: AgentCapabilities = {
  approvals: true,
  steering: false,
  interrupt: true,
  planMode: true,
  resume: true,
  streamingDeltas: true,
};

const PRINT_CAPABILITIES: AgentCapabilities = {
  approvals: false,
  steering: false,
  interrupt: true,
  planMode: true,
  resume: true,
  streamingDeltas: false,
};

/**
 * 启动前的静态模式表（2026.07.23 实测录制的 session/new 自陈值）。
 * acp 路径下 session/new 会重新自陈一遍（经 modesResolved 覆盖），
 * 上游加档时运行时数据自动跟上，这份表只服务"会话建立前 UI 要展示什么"。
 */
const CURSOR_MODES: SessionModeOption[] = [
  { id: "agent", label: "Agent · 全能力", detail: "读写与工具全开，需要审批的命令仍先问你" },
  { id: "plan", label: "计划 · 只读", detail: "只读规划，先设计后动手" },
  { id: "ask", label: "问答 · 不动手", detail: "只答问题，不编辑不执行" },
];
const CURSOR_DEFAULT_MODE = "agent";

export interface CursorAdapterOptions {
  emit: AdapterEventSink;
  drive?: CursorDrive;
  /** 可执行文件名；cursor-agent 与 agent 是同一个二进制 */
  binary?: string;
  now?: () => number;
}

export class CursorAdapter implements AgentAdapter {
  readonly kind: AgentKind = "cursor";
  readonly defaultModeId: string = CURSOR_DEFAULT_MODE;

  readonly #emit: AdapterEventSink;
  readonly #drive: CursorDrive;
  readonly #binary: string;
  readonly #now: () => number;

  #capabilities: AgentCapabilities;
  #modes: SessionModeOption[] = CURSOR_MODES;
  #modeId: string = CURSOR_DEFAULT_MODE;
  #startOptions: AdapterStartOptions | null = null;
  #child: ChildProcess | null = null;
  #stdoutBuffer = "";
  #acpNormalizer: CursorAcpNormalizer | null = null;
  #printNormalizer = new CursorPrintNormalizer();
  #nativeId: string | null = null;
  #closing = false;
  #printInterrupted = false;

  /**
   * adapter 自己也要记一份「发出去的请求」：normalizer 那份是为了翻译事件，
   * 这份是为了 await 握手结果（sessionId、agentCapabilities）。
   */
  readonly #pendingRequests = new Map<
    string,
    { resolve: (value: unknown) => void; reject: (error: Error) => void }
  >();
  /** 审批 id -> agent 那条请求的原始 JSON-RPC id，答复时要原样带回 */
  readonly #pendingApprovals = new Map<string, JsonRpcId>();
  #requestSeq = 0;

  constructor(options: CursorAdapterOptions) {
    this.#emit = options.emit;
    this.#drive = options.drive ?? "acp";
    this.#binary = options.binary ?? "cursor-agent";
    this.#now = options.now ?? (() => Date.now());
    this.#capabilities = this.#drive === "acp" ? { ...ACP_CAPABILITIES } : { ...PRINT_CAPABILITIES };
  }

  get capabilities(): AgentCapabilities {
    return this.#capabilities;
  }

  get modes(): SessionModeOption[] {
    return this.#modes;
  }

  get currentModeId(): string {
    return this.#modeId;
  }

  async start(options: AdapterStartOptions): Promise<void> {
    this.#startOptions = options;
    this.#nativeId = options.resumeNativeId;
    this.#modeId = this.#validateMode(options.modeId ?? CURSOR_DEFAULT_MODE);
    this.#emit({ type: "status", status: "starting" });
    if (this.#drive === "print") {
      // -p 是一轮一个进程，这里没有常驻进程可拉起
      this.#emit({ type: "status", status: "idle" });
      return;
    }
    await this.#startAcp(options);
  }

  async sendMessage(text: string): Promise<void> {
    const options = this.#requireStarted();
    if (this.#drive === "print") {
      this.#startPrintTurn(options, text);
      return;
    }
    const sessionId = this.#requireSessionId();
    // 这个请求要到整轮结束才 resolve，不能 await，否则 sendMessage 会挂到 turn 结束
    void this.#request("session/prompt", {
      sessionId,
      prompt: [{ type: "text", text }],
    }).catch((error: unknown) => {
      this.#emit({ type: "error", message: describe(error), fatal: false });
    });
  }

  async interrupt(): Promise<void> {
    if (this.#drive === "print") {
      if (this.#child === null) return;
      // [实测] -p 被 SIGINT 打断后一行 result 都不吐，直接以 130 退出。
      // turnCompleted 只能由这里补，否则会话永远停在 running
      this.#printInterrupted = true;
      this.#child.kill("SIGINT");
      return;
    }
    const sessionId = this.#nativeId;
    if (sessionId === null) return;
    // [实测] session/cancel 只认通知形态；带 id 发成请求会被回 -32601
    this.#send({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId } });
  }

  async resolveApproval(approvalId: string, optionId: string): Promise<void> {
    if (this.#drive === "print") {
      // 契约明令不许静默吞掉：-p 路径下手机端根本没有可生效的批准
      throw new Error(
        "cursor -p 驱动没有审批通道，需要审批的命令会被 CLI 直接拒绝；请改用 acp 驱动",
      );
    }
    const requestId = this.#pendingApprovals.get(approvalId);
    if (requestId === undefined) {
      throw new Error(`未知的审批 id：${approvalId}`);
    }
    this.#pendingApprovals.delete(approvalId);
    this.#send({
      jsonrpc: "2.0",
      id: requestId,
      result: { outcome: { outcome: "selected", optionId } },
    });
  }

  async setMode(modeId: string): Promise<void> {
    const valid = this.#validateMode(modeId);
    if (this.#drive === "print") {
      // -p 一轮一进程：记住档位，下一轮 argv 生效；没有回显通道，这里自己发
      this.#modeId = valid;
      this.#emit({ type: "modeResolved", modeId: valid });
      return;
    }
    const sessionId = this.#requireSessionId();
    // [实测] 成功前 agent 先推 current_mode_update，normalizer 消费它发权威回显；
    // 无效 modeId 的错误信息自带合法取值清单，原样透传即可
    await this.#request("session/set_mode", { sessionId, modeId: valid });
    this.#modeId = valid;
  }

  #validateMode(modeId: string): string {
    if (!this.#modes.some((mode) => mode.id === modeId)) {
      const valid = this.#modes.map((mode) => mode.id).join(", ");
      throw new Error(`未知的 cursor 模式 ${modeId}（可用：${valid}）`);
    }
    return modeId;
  }

  async close(): Promise<void> {
    this.#closing = true;
    const child = this.#child;
    this.#child = null;
    if (child !== null) {
      child.stdin?.end();
      child.kill("SIGTERM");
    }
    this.#failPending("adapter 已关闭");
    this.#pendingApprovals.clear();
    this.#emit({ type: "status", status: "ended" });
  }

  // MARK: - ACP

  async #startAcp(options: AdapterStartOptions): Promise<void> {
    this.#acpNormalizer = new CursorAcpNormalizer({
      cwd: options.workspaceRoot,
      now: this.#now,
    });
    this.#spawn(["acp"], options.workspaceRoot, (line) => this.#onAcpLine(line));

    const init = (await this.#request("initialize", {
      protocolVersion: 1,
      // 我们不实现 fs/* 和 terminal/*，据实报 false，agent 就会走它自己的工具
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
      clientInfo: { name: "lenscrew-bridge", version: "0.0.1" },
    })) as AcpInitializeResult;
    // capabilities 是运行时自陈：resume 以 agent 自己说的 loadSession 为准
    this.#capabilities = {
      ...this.#capabilities,
      resume: init.agentCapabilities?.loadSession ?? false,
    };

    const resumeNativeId = options.resumeNativeId;
    if (resumeNativeId !== null) {
      await this.#request("session/load", {
        sessionId: resumeNativeId,
        cwd: options.workspaceRoot,
        mcpServers: [],
      });
      // [实测] session/load 的响应不回 sessionId，normalizer 无从得知，这里补一条
      this.#emit({ type: "nativeIdAssigned", nativeId: resumeNativeId });
    } else {
      const created = (await this.#request("session/new", {
        cwd: options.workspaceRoot,
        mcpServers: [],
      })) as { sessionId?: string };
      this.#nativeId = created.sessionId ?? null;
    }

    const sessionId = this.#requireSessionId();
    if (this.#modeId !== CURSOR_DEFAULT_MODE) {
      await this.#request("session/set_mode", { sessionId, modeId: this.#modeId });
    }
    if (options.model !== null) {
      // [实测] cursor 要的键是 configId，ACP schema 里写的是 optionId；以实测为准
      await this.#request("session/set_config_option", {
        sessionId,
        configId: "model",
        value: options.model,
      });
    }
  }

  #onAcpLine(line: string): void {
    let message: AcpWireMessage;
    try {
      message = JSON.parse(line) as AcpWireMessage;
    } catch {
      this.#emit({ type: "error", message: `无法解析 ACP 报文：${line.slice(0, 200)}`, fatal: false });
      return;
    }

    // 审批 id 与 normalizer 那边同源，都是 JSON-RPC 请求 id 的字符串形式
    if (message.method === "session/request_permission" && message.id !== undefined) {
      this.#pendingApprovals.set(String(message.id), message.id);
    }

    this.#emitAll(this.#acpNormalizer?.normalize(message) ?? []);

    if (message.method !== undefined) {
      this.#answerAgentRequest(message);
      return;
    }
    this.#settleRequest(message);
  }

  /** agent 发来的、我们不实现的请求要显式回错，否则它会一直等 */
  #answerAgentRequest(message: AcpWireMessage): void {
    const id = message.id;
    if (id === undefined || message.method === "session/request_permission") return;
    this.#send({
      jsonrpc: "2.0",
      id,
      error: { code: -32601, message: `lenscrew 未实现 ${message.method ?? "该方法"}` },
    });
  }

  #settleRequest(message: AcpWireMessage): void {
    const id = message.id;
    if (id === undefined) return;
    const pending = this.#pendingRequests.get(String(id));
    if (pending === undefined) return;
    this.#pendingRequests.delete(String(id));
    if (message.error !== undefined) {
      pending.reject(new Error(`${message.error.message}（code ${message.error.code}）`));
      return;
    }
    pending.resolve(message.result);
  }

  #request(method: string, params: unknown): Promise<unknown> {
    this.#requestSeq += 1;
    // id 用 "lc-" 前缀占住一个命名空间，与 agent 自己从 0 开始的数字 id 隔开，
    // 否则「agent 对我们请求的响应」和「我们对审批的答复」会同号，无法区分方向
    const id = `lc-${this.#requestSeq}`;
    return new Promise<unknown>((resolve, reject) => {
      this.#pendingRequests.set(id, { resolve, reject });
      this.#send({ jsonrpc: "2.0", id, method, params });
    });
  }

  #send(message: AcpWireMessage): void {
    const stdin = this.#child?.stdin;
    if (stdin === null || stdin === undefined) {
      this.#emit({ type: "error", message: "cursor-agent 进程不可写，会话可能已退出", fatal: true });
      return;
    }
    stdin.write(`${JSON.stringify(message)}\n`);
    // 自己发出去的报文也要过一遍 normalizer：userMessage 块和 approvalSettled
    // 只能从这一侧看出来，理由见 acpNormalizer.ts
    this.#emitAll(this.#acpNormalizer?.normalize(message) ?? []);
  }

  // MARK: - print

  #startPrintTurn(options: AdapterStartOptions, text: string): void {
    const args = ["-p", "--output-format", "stream-json"];
    if (options.model !== null) args.push("--model", options.model);
    // -p 的 --mode 只认 plan/ask，agent 档就是不带 flag 的缺省行为
    if (this.#modeId === "plan" || this.#modeId === "ask") {
      args.push("--mode", this.#modeId);
    }
    if (this.#nativeId !== null) args.push("--resume", this.#nativeId);
    args.push(text);
    this.#spawn(args, options.workspaceRoot, (line) => this.#onPrintLine(line));
  }

  #onPrintLine(line: string): void {
    let message: CursorPrintMessage;
    try {
      message = JSON.parse(line) as CursorPrintMessage;
    } catch {
      this.#emit({ type: "error", message: `无法解析 -p 报文：${line.slice(0, 200)}`, fatal: false });
      return;
    }
    this.#emitAll(this.#printNormalizer.normalize(message));
  }

  // MARK: - 进程与分帧

  #spawn(args: string[], cwd: string, onLine: (line: string) => void): void {
    const child = spawn(this.#binary, args, { cwd, stdio: ["pipe", "pipe", "pipe"] });
    this.#child = child;
    this.#stdoutBuffer = "";

    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => {
      this.#stdoutBuffer += chunk;
      let index = this.#stdoutBuffer.indexOf("\n");
      while (index >= 0) {
        const line = this.#stdoutBuffer.slice(0, index).trim();
        this.#stdoutBuffer = this.#stdoutBuffer.slice(index + 1);
        if (line !== "") onLine(line);
        index = this.#stdoutBuffer.indexOf("\n");
      }
    });

    let stderrTail = "";
    child.stderr?.setEncoding("utf8");
    child.stderr?.on("data", (chunk: string) => {
      stderrTail = `${stderrTail}${chunk}`.slice(-2000);
    });

    child.on("error", (error) => {
      // 二进制不存在时只有 error 没有 exit，不在这里退掉 start() 就会一直挂着
      this.#failPending(`拉起 ${this.#binary} 失败：${error.message}`);
      this.#emit({ type: "error", message: `拉起 ${this.#binary} 失败：${error.message}`, fatal: true });
    });

    child.on("exit", (code) => {
      if (this.#child === child) this.#child = null;
      this.#failPending(`cursor-agent 已退出（code ${code ?? "null"}）`);
      if (this.#closing) return;
      if (this.#printInterrupted) {
        this.#printInterrupted = false;
        // 130 是我们自己发的 SIGINT 打出来的，不是故障
        this.#emitAll([
          {
            type: "turnCompleted",
            inputTokens: null,
            outputTokens: null,
            cachedInputTokens: null,
            stopReason: "interrupted",
          },
          { type: "status", status: "idle" },
        ]);
        return;
      }
      if (code !== 0 && code !== null) {
        this.#emit({
          type: "error",
          message: `cursor-agent 退出码 ${code}${stderrTail === "" ? "" : `：${stderrTail.trim()}`}`,
          // acp 是常驻进程，退了这个会话就没了；-p 每轮一个进程，退出属正常收尾
          fatal: this.#drive === "acp",
        });
      }
      if (this.#drive === "acp") this.#emit({ type: "status", status: "ended" });
    });
  }

  #failPending(reason: string): void {
    for (const pending of this.#pendingRequests.values()) {
      pending.reject(new Error(reason));
    }
    this.#pendingRequests.clear();
  }

  #emitAll(events: AdapterEvent[]): void {
    for (const event of events) {
      // -p 路径的原生会话 id 只在每轮 init 里露一次，续接下一轮要靠它
      if (event.type === "nativeIdAssigned") this.#nativeId = event.nativeId;
      // 运行时自陈/回显的模式同步进 adapter 本地状态，setMode 校验用最新表
      if (event.type === "modesResolved") this.#modes = event.modes;
      if (event.type === "modeResolved") this.#modeId = event.modeId;
      this.#emit(event);
    }
  }

  #requireStarted(): AdapterStartOptions {
    const options = this.#startOptions;
    if (options === null) throw new Error("adapter 尚未 start");
    return options;
  }

  #requireSessionId(): string {
    const sessionId = this.#nativeId;
    if (sessionId === null) throw new Error("ACP 会话尚未建立");
    return sessionId;
  }
}

const describe = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);
