// 驱动本机 `codex app-server` 的 adapter：进程生命周期、stdio 分帧、请求应答配对，
// 以及把审批裁决翻回 app-server 认的裁决体。协议翻译全部委托给 CodexNormalizer。

import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";

import type {
  AgentCapabilities,
  AgentKind,
  SessionModeOption,
} from "../../protocol/events.ts";
import type {
  AdapterEventSink,
  AdapterStartOptions,
  AgentAdapter,
} from "../types.ts";
import { CodexNormalizer } from "./normalizer.ts";
import {
  isCodexServerRequestMethod,
  type CodexAskForApproval,
  type CodexIncomingMessage,
  type CodexRequestId,
  type CodexSandboxMode,
  type CodexThreadResumeParams,
  type CodexThreadStartParams,
  type CodexTurnInterruptParams,
  type CodexTurnSandboxPolicy,
  type CodexTurnStartParams,
  type CodexTurnSteerParams,
} from "./protocol.ts";

/** thread 级 sandbox 是字符串、turn 级是对象，两个 API 的形态不一致 */
function turnSandboxPolicy(sandbox: CodexSandboxMode): CodexTurnSandboxPolicy {
  switch (sandbox) {
    case "read-only":
      return { type: "readOnly" };
    case "danger-full-access":
      return { type: "dangerFullAccess" };
    case "workspace-write":
      return { type: "workspaceWrite" };
  }
}

export interface CodexAdapterOptions {
  sink: AdapterEventSink;
  /** codex 可执行文件；默认走 PATH */
  command?: string;
  /** 进程退出前等待优雅关闭的毫秒数 */
  shutdownGraceMs?: number;
}

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
}

/**
 * 实测能力（codex-cli 0.144.4，2026-07-25）：
 *   approvals       server→client 的 item/*\/requestApproval，我们应答后命令才执行
 *   steering        turn/steer 可在 turn 运行中追加输入，需带 expectedTurnId
 *   interrupt       turn/interrupt
 *   planMode        没有一等公民的 plan 模式，用 read-only sandbox + 不询问审批等价实现
 *   resume          thread/resume 按 threadId 续接
 *   streamingDeltas item/agentMessage/delta、item/commandExecution/outputDelta 等
 */
const CODEX_CAPABILITIES: AgentCapabilities = {
  approvals: true,
  steering: true,
  interrupt: true,
  planMode: true,
  resume: true,
  streamingDeltas: true,
};

/**
 * 四档模式，对齐 ChatGPT Codex 的 Read only / Auto / Full access，
 * 外加保留"每步审批"这一最保守档（也是历史默认行为）。
 * 各档位翻译成 approvalPolicy × sandbox 的组合，见 #policyFor。
 */
const CODEX_MODES: SessionModeOption[] = [
  { id: "plan", label: "计划 · 只读", detail: "只读沙箱，能读能想，不改文件不执行" },
  { id: "default", label: "默认 · 每步审批", detail: "每条命令先问过你再执行" },
  { id: "auto", label: "自动 · 按需审批", detail: "工作区内自动干活，越界操作才来问" },
  { id: "full", label: "完全放行", detail: "不问审批、全盘可写——只给完全信任的仓库" },
];
const CODEX_DEFAULT_MODE = "default";

/** 保留最近若干行 stderr，进程猝死时用来给出可读原因 */
const STDERR_TAIL_LINES = 20;

export class CodexAdapter implements AgentAdapter {
  readonly kind: AgentKind = "codex";
  readonly capabilities: AgentCapabilities = CODEX_CAPABILITIES;
  readonly modes: SessionModeOption[] = CODEX_MODES;
  readonly defaultModeId: string = CODEX_DEFAULT_MODE;

  readonly #sink: AdapterEventSink;
  readonly #command: string;
  readonly #shutdownGraceMs: number;
  readonly #normalizer = new CodexNormalizer();
  readonly #pending = new Map<string, PendingRequest>();
  readonly #stderrTail: string[] = [];

  #child: ChildProcessWithoutNullStreams | null = null;
  #stdoutBuffer = "";
  #nextRequestId = 1;
  #threadId: string | null = null;
  #modeId: string = CODEX_DEFAULT_MODE;
  #closing = false;

  constructor(options: CodexAdapterOptions) {
    this.#sink = options.sink;
    this.#command = options.command ?? "codex";
    this.#shutdownGraceMs = options.shutdownGraceMs ?? 2000;
  }

  get currentModeId(): string {
    return this.#modeId;
  }

  async start(options: AdapterStartOptions): Promise<void> {
    if (this.#child) throw new Error("codex adapter 已经启动过");
    this.#sink({ type: "status", status: "starting" });

    const child = spawn(this.#command, ["app-server"], {
      cwd: options.workspaceRoot,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.#child = child;

    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => this.#onStdout(chunk));
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => this.#onStderr(chunk));
    child.on("error", (error: Error) => this.#onProcessGone(error.message));
    child.on("exit", (code, signal) =>
      this.#onProcessGone(`codex app-server 退出（code=${code} signal=${signal}）`),
    );

    await this.#request("initialize", {
      clientInfo: { name: "lenscrew", title: "LensCrew", version: "0.0.1" },
      capabilities: null,
    });
    // initialize 之后必须发这条通知，否则 app-server 不会开始推送会话通知
    this.#notify("initialized");

    // 账号额度主动拉一次：updated 通知只在 turn 期间才来，不拉的话
    // 会话一开手机上额度就是空的。fire-and-forget——旧版 codex 没有
    // 这个方法，失败只代表额度不可用，不能拖垮会话启动。
    void this.#request("account/rateLimits/read", {})
      .then((result) => {
        for (const event of this.#normalizer.normalizeRateLimitsRead(result)) {
          this.#sink(event);
        }
      })
      .catch(() => {});

    this.#modeId = this.#validateMode(options.modeId ?? CODEX_DEFAULT_MODE);
    const { approvalPolicy, sandbox } = this.#policyFor(this.#modeId);
    if (options.resumeNativeId !== null) {
      const params: CodexThreadResumeParams = {
        threadId: options.resumeNativeId,
        cwd: options.workspaceRoot,
        approvalPolicy,
        sandbox,
      };
      if (options.model !== null) params.model = options.model;
      const result = (await this.#request("thread/resume", params)) as {
        thread?: {
          id?: string;
          turns?: Array<{ items?: unknown[] }>;
        };
      };
      this.#threadId = result.thread?.id ?? options.resumeNativeId;
      // [实测 2026-07-26] resume 响应的 thread.turns[].items 携带完整历史，
      // 形态与 item/completed 通知一致——合成同名消息喂 normalizer 即可回放，
      // 它对没见过 started 的 item 会直接补 blockAppended，不需要新的翻译路径
      for (const turn of result.thread?.turns ?? []) {
        for (const item of turn.items ?? []) {
          const events = this.#normalizer.normalize({
            jsonrpc: "2.0",
            method: "item/completed",
            params: { item },
          } as CodexIncomingMessage);
          for (const event of events) this.#sink(event);
        }
      }
    } else {
      const params: CodexThreadStartParams = {
        cwd: options.workspaceRoot,
        approvalPolicy,
        sandbox,
      };
      if (options.model !== null) params.model = options.model;
      const result = (await this.#request("thread/start", params)) as {
        thread?: { id?: string };
      };
      this.#threadId = result.thread?.id ?? null;
    }

    if (this.#threadId === null) {
      throw new Error("codex 没有返回 threadId");
    }
    if (options.model !== null) {
      this.#sink({ type: "modelResolved", model: options.model });
    }
  }

  /**
   * 契约要求"被接收即返回"，这里等的 turn/start 响应正好就是接收回执：
   * 实测它在 turn 真正开跑之前就返回了 { turn: { status: "inProgress" } }，
   * 整轮的产出全部走通知推送，不占用这个 Promise。
   */
  async sendMessage(text: string): Promise<void> {
    const threadId = this.#requireThreadId();
    const input = [{ type: "text" as const, text, text_elements: [] }];
    const activeTurnId = this.#normalizer.currentTurnId;

    // turn 还在跑就用 steer 插话，直接再发 turn/start 会被 app-server 拒绝
    if (activeTurnId !== null) {
      const params: CodexTurnSteerParams = {
        threadId,
        expectedTurnId: activeTurnId,
        input,
      };
      await this.#request("turn/steer", params);
      return;
    }

    // 每轮都带当前档位（幂等）：这是 codex 官方的模式切换通道——
    // turn 级 policy 的语义是 "override for this turn and subsequent turns"
    const { approvalPolicy, sandbox } = this.#policyFor(this.#modeId);
    const params: CodexTurnStartParams = {
      threadId,
      input,
      approvalPolicy,
      sandboxPolicy: turnSandboxPolicy(sandbox),
    };
    await this.#request("turn/start", params);
  }

  /**
   * codex 没有独立的"改模式"请求：切换记在 adapter 上，下一轮 turn/start
   * 随 policy 生效。运行中的 turn 沿用旧档（steer 不带 policy）。
   */
  async setMode(modeId: string): Promise<void> {
    this.#modeId = this.#validateMode(modeId);
    this.#sink({ type: "modeResolved", modeId: this.#modeId });
  }

  async interrupt(): Promise<void> {
    const threadId = this.#requireThreadId();
    const turnId = this.#normalizer.currentTurnId;
    if (turnId === null) return;
    const params: CodexTurnInterruptParams = { threadId, turnId };
    await this.#request("turn/interrupt", params);
  }

  async resolveApproval(approvalId: string, optionId: string): Promise<void> {
    const response = this.#normalizer.buildApprovalResponse(approvalId, optionId);
    if (!response) {
      // 宁可抛错也不能静默吞：手机端会以为批准已经生效
      throw new Error(`未知的审批裁决：approvalId=${approvalId} optionId=${optionId}`);
    }
    this.#write({ jsonrpc: "2.0", id: response.requestId, result: response.result });
  }

  async close(): Promise<void> {
    this.#closing = true;
    const child = this.#child;
    if (!child) return;
    this.#child = null;

    child.kill("SIGTERM");
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        child.kill("SIGKILL");
        resolve();
      }, this.#shutdownGraceMs);
      child.once("exit", () => {
        clearTimeout(timer);
        resolve();
      });
    });
    this.#failPending(new Error("codex adapter 已关闭"));
  }

  /** 档位 → approvalPolicy × sandbox。plan 靠只读沙箱 + 不询问实现：读得到、写不了 */
  #policyFor(modeId: string): {
    approvalPolicy: CodexAskForApproval;
    sandbox: CodexSandboxMode;
  } {
    switch (modeId) {
      case "plan":
        return { approvalPolicy: "never", sandbox: "read-only" };
      case "auto":
        return { approvalPolicy: "on-request", sandbox: "workspace-write" };
      case "full":
        return { approvalPolicy: "never", sandbox: "danger-full-access" };
      default:
        return { approvalPolicy: "untrusted", sandbox: "workspace-write" };
    }
  }

  #validateMode(modeId: string): string {
    if (!CODEX_MODES.some((mode) => mode.id === modeId)) {
      const valid = CODEX_MODES.map((mode) => mode.id).join(", ");
      throw new Error(`未知的 codex 模式 ${modeId}（可用：${valid}）`);
    }
    return modeId;
  }

  #requireThreadId(): string {
    if (this.#threadId === null) throw new Error("codex adapter 尚未启动");
    return this.#threadId;
  }

  // MARK: - stdio

  /**
   * app-server 用换行分隔的 JSON：一行一条完整消息，没有 Content-Length 头。
   * 实测确认（0.144.4）——按行切分能完整解析全部 109 条录制消息。
   */
  #onStdout(chunk: string): void {
    this.#stdoutBuffer += chunk;
    let newline = this.#stdoutBuffer.indexOf("\n");
    while (newline !== -1) {
      const line = this.#stdoutBuffer.slice(0, newline);
      this.#stdoutBuffer = this.#stdoutBuffer.slice(newline + 1);
      newline = this.#stdoutBuffer.indexOf("\n");
      if (line.trim().length === 0) continue;
      this.#onLine(line);
    }
  }

  #onLine(line: string): void {
    let message: CodexIncomingMessage;
    try {
      message = JSON.parse(line) as CodexIncomingMessage;
    } catch {
      this.#sink({
        type: "error",
        message: `codex 输出了无法解析的一行：${line.slice(0, 200)}`,
        fatal: false,
      });
      return;
    }

    // 无 method 有 id 的是我们发出去的请求的响应
    if (message.method === undefined && message.id !== undefined) {
      this.#settleRequest(message);
      return;
    }

    for (const event of this.#normalizer.normalize(message)) {
      this.#sink(event);
    }

    if (message.method !== undefined && message.id !== undefined) {
      this.#answerServerRequest(message.method, message.id);
    }
  }

  #onStderr(chunk: string): void {
    for (const line of chunk.split("\n")) {
      if (line.trim().length === 0) continue;
      this.#stderrTail.push(line);
      if (this.#stderrTail.length > STDERR_TAIL_LINES) this.#stderrTail.shift();
    }
  }

  /**
   * 服务端请求必须每条都应答，否则 app-server 会一直等。
   * 归一器登记成审批的交给人裁决；其余（item/tool/call、attestation/generate 等
   * 我们不实现的能力）当场回 JSON-RPC 错误。
   */
  #answerServerRequest(method: string, id: CodexRequestId): void {
    if (isCodexServerRequestMethod(method) && this.#normalizer.hasPendingApproval(String(id))) {
      return;
    }
    this.#write({
      jsonrpc: "2.0",
      id,
      error: { code: -32601, message: `lenscrew 不支持 ${method}` },
    });
  }

  #settleRequest(message: CodexIncomingMessage): void {
    const key = String(message.id);
    const pending = this.#pending.get(key);
    if (!pending) return;
    this.#pending.delete(key);
    if (message.error) {
      pending.reject(
        new Error(`codex ${message.error.message}（code=${message.error.code}）`),
      );
      return;
    }
    pending.resolve(message.result ?? {});
  }

  #onProcessGone(reason: string): void {
    if (this.#closing) return;
    this.#closing = true;
    this.#child = null;
    const tail = this.#stderrTail.join("\n");
    const message = tail.length > 0 ? `${reason}\n${tail}` : reason;
    this.#sink({ type: "error", message, fatal: true });
    this.#sink({ type: "status", status: "ended" });
    this.#failPending(new Error(message));
  }

  #failPending(error: Error): void {
    for (const pending of this.#pending.values()) pending.reject(error);
    this.#pending.clear();
  }

  #request(method: string, params: unknown): Promise<unknown> {
    const id = this.#nextRequestId++;
    return new Promise<unknown>((resolve, reject) => {
      this.#pending.set(String(id), { resolve, reject });
      try {
        this.#write({ jsonrpc: "2.0", id, method, params });
      } catch (error) {
        this.#pending.delete(String(id));
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  #notify(method: string): void {
    this.#write({ jsonrpc: "2.0", method });
  }

  #write(payload: unknown): void {
    const child = this.#child;
    if (!child || child.stdin.destroyed) {
      throw new Error("codex app-server 不在运行");
    }
    child.stdin.write(`${JSON.stringify(payload)}\n`);
  }
}
