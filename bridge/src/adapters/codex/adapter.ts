// 驱动本机 `codex app-server` 的 adapter：进程生命周期、stdio 分帧、请求应答配对，
// 以及把审批裁决翻回 app-server 认的裁决体。协议翻译全部委托给 CodexNormalizer。

import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";

import type {
  AgentCapabilities,
  AgentKind,
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
  type CodexTurnStartParams,
  type CodexTurnSteerParams,
} from "./protocol.ts";

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

/** 保留最近若干行 stderr，进程猝死时用来给出可读原因 */
const STDERR_TAIL_LINES = 20;

export class CodexAdapter implements AgentAdapter {
  readonly kind: AgentKind = "codex";
  readonly capabilities: AgentCapabilities = CODEX_CAPABILITIES;

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
  #closing = false;

  constructor(options: CodexAdapterOptions) {
    this.#sink = options.sink;
    this.#command = options.command ?? "codex";
    this.#shutdownGraceMs = options.shutdownGraceMs ?? 2000;
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

    const { approvalPolicy, sandbox } = this.#policyFor(options.mode);
    if (options.resumeNativeId !== null) {
      const params: CodexThreadResumeParams = {
        threadId: options.resumeNativeId,
        cwd: options.workspaceRoot,
        approvalPolicy,
        sandbox,
      };
      if (options.model !== null) params.model = options.model;
      const result = (await this.#request("thread/resume", params)) as {
        thread?: { id?: string };
      };
      this.#threadId = result.thread?.id ?? options.resumeNativeId;
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

    const params: CodexTurnStartParams = { threadId, input };
    await this.#request("turn/start", params);
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

  /** plan 模式靠只读沙箱 + 不询问审批实现：读得到、想得了、写不了 */
  #policyFor(mode: AdapterStartOptions["mode"]): {
    approvalPolicy: CodexAskForApproval;
    sandbox: CodexSandboxMode;
  } {
    if (mode === "plan") {
      return { approvalPolicy: "never", sandbox: "read-only" };
    }
    return { approvalPolicy: "untrusted", sandbox: "workspace-write" };
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
