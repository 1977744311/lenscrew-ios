import { spawn } from "node:child_process";
import type { ChildProcessWithoutNullStreams } from "node:child_process";

import type { AgentCapabilities, AgentKind } from "../../protocol/events.ts";
import type { AdapterEventSink, AdapterStartOptions, AgentAdapter } from "../types.ts";
import { ClaudeNormalizer } from "./normalizer.ts";
import type {
  ClaudeCanUseToolRequest,
  ClaudeControlRequest,
  ClaudeControlResponse,
  ClaudeMessage,
  ClaudePermissionDecision,
  ClaudeStdinMessage,
} from "./protocol.ts";
import { isCanUseTool, isHookCallback } from "./protocol.ts";

/**
 * --permission-prompt-tool 的取值，"stdio" 是保留字，不是随便起的名字。
 *
 * 该 flag 在 2.1.215 的 --help 里被隐藏，但仍然生效，且是审批通道的总开关。
 * CLI 内部按三岔路分发（函数体实测自 2.1.215 二进制）：
 *   传 "stdio"  → 审批走 stdio control protocol，也就是本 adapter 要的通道
 *   不传        → 用本地权限机，headless 下等价于直接拒绝
 *   传别的字符串 → 当成 MCP 工具名去查，查不到就报
 *                 "Error: MCP tool <name> (passed via --permission-prompt-tool) not found"
 *                 并让整轮以 exit code 1 挂掉（这条是踩过的坑，不是推测）
 *
 * 官方 SDK 也是这么干的：用户传了 canUseTool 回调，SDK 就往命令行塞
 * --permission-prompt-tool stdio。
 */
const PERMISSION_PROMPT_TOOL = "stdio";

/** initialize 里注册的 hook 回调 id，CLI 会带着它回调过来 */
const PRE_TOOL_USE_CALLBACK_ID = "lenscrew_pre_tool_use";

const CONTROL_TIMEOUT_MS = 15_000;
const CLOSE_GRACE_MS = 3_000;

interface PendingControl {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

interface PendingApproval {
  requestId: string;
  /** CLI 给的持久放行建议，allowAlways 时原样回送 */
  suggestions: unknown[] | null;
}

export class ClaudeAdapter implements AgentAdapter {
  readonly kind: AgentKind = "claude";

  /**
   * 逐条的验证依据（2026-07-25，本机 claude 2.1.215）：
   *
   * approvals       [实测] can_use_tool 控制请求 + control_response 裁决，allow 与 deny
   *                 两条路径都跑通了（allow 后工具真的执行、deny 后文件真的没被创建）。
   *                 前提是 start() 里拼的那套 flag 和 initialize 握手一个都不能少。
   * steering        [实测] turn 跑到一半（工具还没回）时往 stdin 塞第二条消息，CLI 在本轮
   *                 内就把它回放了出来，整轮仍以一个 result 收尾（num_turns=3），
   *                 没有被打断。注意：当时模型端是本地 mock，只能证明 CLI 接了消息且
   *                 没断 turn，证明不了模型在同一轮里读到了它。
   * interrupt       [实测] control_request{subtype:"interrupt"} 返回
   *                 {still_queued:[]}，与 init 自陈的 interrupt_receipt_v1 对得上。
   * planMode        [实测] --permission-mode plan 下 init 回显 permissionMode:"plan"。
   *                 计划模式里审批是否照常走 control protocol 未验证。
   * resume          [未实测] CLI 有 --resume <session_id>，本机 OAuth 过期没法验证
   *                 续接后的历史是否完整。
   * streamingDeltas [实测] --include-partial-messages 产出 content_block_delta。
   *
   * 这里的能力不随握手结果变化——审批那套 flag 是 start() 写死带上的，
   * 所以没有需要 adapter 自己发 capabilitiesResolved 的时机，SessionHub 在
   * start() 之后统一补一发就够了，adapter 再发一次只会多刷一次 sessionUpdated。
   */
  readonly capabilities: AgentCapabilities = {
    approvals: true,
    steering: true,
    interrupt: true,
    planMode: true,
    resume: true,
    streamingDeltas: true,
  };

  private readonly emit: AdapterEventSink;
  private readonly normalizer: ClaudeNormalizer;
  private readonly executable: string;

  private child: ChildProcessWithoutNullStreams | null = null;
  private stdoutBuffer = "";
  private requestSeq = 0;
  private readonly pendingControl = new Map<string, PendingControl>();
  private readonly pendingApprovals = new Map<string, PendingApproval>();
  private closing = false;

  constructor(emit: AdapterEventSink, executable = "claude") {
    this.emit = emit;
    this.executable = executable;
    this.normalizer = new ClaudeNormalizer();
  }

  // MARK: - 生命周期

  async start(options: AdapterStartOptions): Promise<void> {
    if (this.child) throw new Error("ClaudeAdapter 已经启动过");

    this.emit({ type: "status", status: "starting" });

    const child = spawn(this.executable, this.buildArgs(options), {
      cwd: options.workspaceRoot,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child = child;

    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => this.onStdout(chunk));

    // stderr 只用来在异常退出时给用户一句可读的原因，不当协议看
    let stderrTail = "";
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => {
      stderrTail = (stderrTail + chunk).slice(-2000);
    });

    child.on("error", (error: Error) => {
      this.failAllPending(error);
      this.emit({ type: "error", message: `claude 进程启动失败: ${error.message}`, fatal: true });
      this.emit({ type: "status", status: "error" });
    });

    child.on("close", (code: number | null) => {
      this.child = null;
      this.failAllPending(new Error("claude 进程已退出"));
      if (this.closing) {
        this.emit({ type: "status", status: "ended" });
        return;
      }
      const reason = stderrTail.trim();
      this.emit({
        type: "error",
        message: `claude 进程意外退出 (code=${code ?? "null"})${reason ? `: ${reason}` : ""}`,
        fatal: true,
      });
      this.emit({ type: "status", status: "ended" });
    });

    // 必须在第一条用户消息之前完成：不注册 PreToolUse hook 的话，
    // stdin 会在审批作答之前被收掉，can_use_tool 就永远等不到回复。
    await this.sendControlRequest({
      subtype: "initialize",
      hooks: {
        PreToolUse: [{ matcher: null, hookCallbackIds: [PRE_TOOL_USE_CALLBACK_ID] }],
      },
    });
  }

  private buildArgs(options: AdapterStartOptions): string[] {
    const args = [
      "-p",
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
      "--verbose",
      "--include-partial-messages",
      "--replay-user-messages",
      // 子 agent 文本带 parent_tool_use_id 回来，normalizer 靠它折进父 Task 块
      "--forward-subagent-text",
      "--permission-prompt-tool",
      PERMISSION_PROMPT_TOOL,
      "--permission-mode",
      options.mode === "plan" ? "plan" : "manual",
    ];
    if (options.model) args.push("--model", options.model);
    if (options.resumeNativeId) args.push("--resume", options.resumeNativeId);
    return args;
  }

  async sendMessage(text: string): Promise<void> {
    this.write({
      type: "user",
      message: { role: "user", content: [{ type: "text", text }] },
    });
  }

  /**
   * 走 control protocol 而不是发信号。
   *
   * 理由：SIGINT/SIGTERM 会把子进程连同会话一起打掉，客户端想接着聊只能重开会话；
   * control_request{interrupt} 实测返回 {still_queued:[]} 后进程还活着，
   * 下一条消息能接着同一个 session_id 走。CLI 在 init 里自陈 interrupt_receipt_v1，
   * 也是指这条回执通道。
   */
  async interrupt(): Promise<void> {
    await this.sendControlRequest({ subtype: "interrupt" });
  }

  async resolveApproval(approvalId: string, optionId: string): Promise<void> {
    const pending = this.pendingApprovals.get(approvalId);
    if (!pending) {
      throw new Error(`未知或已结算的审批: ${approvalId}`);
    }
    this.pendingApprovals.delete(approvalId);

    const decision = buildDecision(optionId, pending.suggestions);
    this.write({
      type: "control_response",
      response: {
        subtype: "success",
        request_id: pending.requestId,
        response: decision,
      },
    });

    this.emit({
      type: "approvalSettled",
      approvalId,
      optionId,
      outcome: "resolved",
    });
    this.emit({ type: "status", status: "running" });
  }

  async close(): Promise<void> {
    const child = this.child;
    if (!child) return;
    this.closing = true;

    for (const [approvalId] of this.pendingApprovals) {
      this.emit({
        type: "approvalSettled",
        approvalId,
        optionId: null,
        outcome: "cancelled",
      });
    }
    this.pendingApprovals.clear();

    child.stdin.end();
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        child.kill("SIGTERM");
        resolve();
      }, CLOSE_GRACE_MS);
      child.once("close", () => {
        clearTimeout(timer);
        resolve();
      });
    });
  }

  // MARK: - NDJSON 分帧

  private onStdout(chunk: string): void {
    this.stdoutBuffer += chunk;
    let newline = this.stdoutBuffer.indexOf("\n");
    while (newline !== -1) {
      const line = this.stdoutBuffer.slice(0, newline);
      this.stdoutBuffer = this.stdoutBuffer.slice(newline + 1);
      if (line.trim().length > 0) this.onLine(line);
      newline = this.stdoutBuffer.indexOf("\n");
    }
  }

  private onLine(line: string): void {
    let message: ClaudeMessage;
    try {
      message = JSON.parse(line) as ClaudeMessage;
    } catch {
      // CLI 自带 stdout guard，正常不会漏非 JSON 行；漏了也不该让整条流挂掉
      return;
    }

    if (message.type === "control_response") {
      this.onControlResponse(message as ClaudeControlResponse);
      return;
    }

    if (message.type === "control_request") {
      const request = message as ClaudeControlRequest;
      if (isHookCallback(request.request)) {
        this.answerHookCallback(request.request_id);
        return;
      }
      if (isCanUseTool(request.request)) {
        this.rememberApproval(request.request_id, request.request);
      }
    }

    for (const event of this.normalizer.normalize(message)) {
      this.emit(event);
    }
  }

  /**
   * PreToolUse hook 只是用来把 stdin 撑开到审批作答为止，不参与裁决，
   * 所以固定放行；真正的准入由随后的 can_use_tool 决定。
   */
  private answerHookCallback(requestId: string): void {
    this.write({
      type: "control_response",
      response: { subtype: "success", request_id: requestId, response: { continue: true } },
    });
  }

  private rememberApproval(requestId: string, request: ClaudeCanUseToolRequest): void {
    const suggestions = Array.isArray(request.permission_suggestions)
      ? request.permission_suggestions
      : null;
    this.pendingApprovals.set(requestId, { requestId, suggestions });
  }

  // MARK: - 客户端发起的控制请求

  private sendControlRequest(request: Record<string, unknown>): Promise<unknown> {
    this.requestSeq += 1;
    const requestId = `lenscrew_${this.requestSeq}`;

    return new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingControl.delete(requestId);
        reject(new Error(`claude 控制请求超时: ${String(request["subtype"])}`));
      }, CONTROL_TIMEOUT_MS);

      this.pendingControl.set(requestId, { resolve, reject, timer });
      try {
        this.write({ type: "control_request", request_id: requestId, request });
      } catch (error) {
        clearTimeout(timer);
        this.pendingControl.delete(requestId);
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  /** 应答的 request_id 在 response 内层，和请求的顶层 request_id 不同层 */
  private onControlResponse(message: ClaudeControlResponse): void {
    const body = message.response;
    const pending = this.pendingControl.get(body.request_id);
    if (!pending) return;

    this.pendingControl.delete(body.request_id);
    clearTimeout(pending.timer);

    if (body.subtype === "error") {
      pending.reject(new Error(body.error));
      return;
    }
    pending.resolve(body.response);
  }

  private failAllPending(error: Error): void {
    for (const pending of this.pendingControl.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pendingControl.clear();
  }

  private write(message: ClaudeStdinMessage): void {
    const child = this.child;
    if (!child) throw new Error("claude 进程未运行");
    child.stdin.write(`${JSON.stringify(message)}\n`);
  }
}

/**
 * optionId 来自 normalizer 给的 ApprovalOption.id。
 *
 * allowAlways 把 CLI 自己给的 permission_suggestions 原样回送成 updatedPermissions —— 
 * 这个字段名取自 CLI 内嵌的 "Malformed updatedPermissions from SDK host ignored" 校验分支，
 * [依据文档/未实测]；即使被 CLI 忽略，behavior:"allow" 也仍然成立，最坏退化成只放行一次。
 */
function buildDecision(
  optionId: string,
  suggestions: unknown[] | null,
): ClaudePermissionDecision & { updatedPermissions?: unknown[] } {
  switch (optionId) {
    case "allow":
      return { behavior: "allow" };
    case "allowAlways":
      return suggestions
        ? { behavior: "allow", updatedPermissions: suggestions }
        : { behavior: "allow" };
    case "abort":
      return { behavior: "deny", message: "用户拒绝并中断了本轮", interrupt: true };
    case "deny":
      return { behavior: "deny", message: "用户拒绝了这次工具调用" };
    default:
      throw new Error(`未知的审批选项: ${optionId}`);
  }
}
