import type {
  ApprovalKind,
  ApprovalOption,
  ApprovalOptionKind,
  ApprovalScope,
  BlockStatus,
  PlanStep,
  TranscriptBlockPatch,
  TurnStopReason,
} from "../../protocol/events.ts";
import type { AdapterEvent, ProtocolNormalizer } from "../types.ts";
import type {
  AcpContentBlock,
  AcpNewSessionResult,
  AcpPermissionOptionKind,
  AcpPromptParams,
  AcpPromptResult,
  AcpRequestPermissionParams,
  AcpRequestPermissionResult,
  AcpSessionNotificationParams,
  AcpSessionUpdate,
  AcpStopReason,
  AcpToolCallStatus,
  AcpToolKind,
  AcpWireMessage,
} from "./protocol.ts";

/**
 * agent 主动发给客户端的方法。方向不在报文里，只能靠方法名归属判断；
 * 其余方法一律视为客户端发出的。
 */
const AGENT_ORIGINATED_METHODS = new Set([
  "session/update",
  "session/request_permission",
  "fs/read_text_file",
  "fs/write_text_file",
  "terminal/create",
  "terminal/output",
  "terminal/release",
  "terminal/kill",
  "terminal/wait_for_exit",
]);

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null;

const textOf = (content: AcpContentBlock[]): string =>
  content
    .filter((block) => block.type === "text")
    .map((block) => block.text ?? "")
    .join("");

const imageCountOf = (content: AcpContentBlock[]): number =>
  content.filter((block) => block.type === "image").length;

/** 眼镜端只保证 title 能一行放下，这里先把换行压掉 */
const singleLine = (value: string): string => value.replace(/\s+/gu, " ").trim();

const toBlockStatus = (status: AcpToolCallStatus | undefined): BlockStatus => {
  switch (status) {
    case "in_progress":
      return "running";
    case "completed":
      return "ok";
    case "failed":
      return "failed";
    default:
      return "pending";
  }
};

const toApprovalKind = (kind: AcpToolKind | undefined): ApprovalKind => {
  switch (kind) {
    case "execute":
      return "shellCommand";
    case "edit":
    case "delete":
    case "move":
      return "fileChange";
    case "switch_mode":
      return "permission";
    default:
      return "tool";
  }
};

/** ACP 的四档权限选项逐一落到契约的 kind + scope，不再有语义损失 */
const toApprovalChoice = (
  kind: AcpPermissionOptionKind,
): { kind: ApprovalOptionKind; scope: ApprovalScope } => {
  switch (kind) {
    case "allow_once":
      return { kind: "allow", scope: "once" };
    case "allow_always":
      return { kind: "allow", scope: "persistent" };
    case "reject_always":
      return { kind: "deny", scope: "persistent" };
    default:
      // reject_once 与将来可能冒出来的新档位，一律按最保守的「只拒这一次」解释
      return { kind: "deny", scope: "once" };
  }
};

const toTurnStopReason = (reason: AcpStopReason | undefined): TurnStopReason | null => {
  switch (reason) {
    case "end_turn":
      return "completed";
    case "cancelled":
      return "interrupted";
    case "max_tokens":
      return "maxTokens";
    case "refusal":
      return "refused";
    // agent 自己撞上了「一轮内最多几次模型请求」的护栏，对用户而言这轮没跑完
    case "max_turn_requests":
      return "failed";
    default:
      return null;
  }
};

const toPlanSteps = (
  entries: Array<{ content: string; status: "pending" | "in_progress" | "completed" }>,
): PlanStep[] =>
  entries.map((entry) => ({
    text: entry.content,
    status:
      entry.status === "in_progress" ? "running" : entry.status === "completed" ? "done" : "pending",
  }));

type TextBlockKind = "agentMessage" | "reasoning" | "userMessage";

export interface CursorAcpNormalizerOptions {
  /** [实测] ACP 的 tool_call 不带工作目录，只能拿会话 cwd 兜底 */
  cwd?: string | null;
  /** [实测] 审批请求不带时间戳；注入时钟纯粹是为了 fixture 测试可断言 */
  now?: () => number;
}

/**
 * 路径 B（cursor-agent acp）的归一化器，同时吃两个方向的报文。
 *
 * 之所以连客户端自己发出去的报文也喂进来：
 *   1. cursor 不回显用户消息，userMessage 块只能从我们发出的 session/prompt 里造；
 *   2. JSON-RPC 响应只带 id，不带方法名，必须先见过请求才知道响应在答什么;
 *   3. 我们对审批请求的答复本身就是 approvalSettled 的唯一来源。
 *
 * 响应的方向靠 id 命名空间区分：adapter 发出的请求 id 一律是 "lc-<n>" 字符串，
 * [实测] agent 发出的请求 id 是从 0 开始的数字，两者不会撞。若两边都用裸数字，
 * 「agent 对 session/prompt 的响应」和「我们对审批的答复」会因同号而互相误判。
 */
export class CursorAcpNormalizer implements ProtocolNormalizer<AcpWireMessage> {
  readonly #cwd: string | null;
  readonly #now: () => number;
  /** 我们发出、等 agent 回的请求：id -> method */
  readonly #pendingOutbound = new Map<string, string>();
  /** agent 发来、等我们回的请求：id -> method */
  readonly #pendingInbound = new Map<string, string>();
  readonly #commandByToolCall = new Map<string, string>();
  #blockSeq = 0;
  #currentText: { id: string; kind: TextBlockKind } | null = null;
  #planBlockId: string | null = null;
  #promptInFlight = false;

  constructor(options: CursorAcpNormalizerOptions = {}) {
    this.#cwd = options.cwd ?? null;
    this.#now = options.now ?? (() => Date.now());
  }

  normalize(message: AcpWireMessage): AdapterEvent[] {
    const method = message.method;
    if (method === undefined) return this.#onResponse(message);
    return AGENT_ORIGINATED_METHODS.has(method)
      ? this.#onAgentOriginated(method, message)
      : this.#onClientOriginated(method, message);
  }

  #nextBlockId(prefix: string): string {
    this.#blockSeq += 1;
    return `${prefix}-${this.#blockSeq}`;
  }

  #closeTextBlock(): AdapterEvent[] {
    const current = this.#currentText;
    if (current === null) return [];
    this.#currentText = null;
    // userMessage 没有 streaming 字段，收尾只是内部状态复位
    if (current.kind === "userMessage") return [];
    return [{ type: "blockUpdated", blockId: current.id, patch: { streaming: false } }];
  }

  #appendText(kind: TextBlockKind, text: string): AdapterEvent[] {
    if (text === "") return [];
    const current = this.#currentText;
    if (current !== null && current.kind === kind) {
      return [{ type: "blockUpdated", blockId: current.id, patch: { appendText: text } }];
    }
    const events = this.#closeTextBlock();
    const id = this.#nextBlockId(kind === "reasoning" ? "reasoning" : kind === "userMessage" ? "user" : "message");
    this.#currentText = { id, kind };
    if (kind === "userMessage") {
      events.push({
        type: "blockAppended",
        block: { kind: "userMessage", id, text, imageCount: 0 },
      });
      return events;
    }
    events.push({
      type: "blockAppended",
      block: kind === "reasoning"
        ? { kind: "reasoning", id, text, streaming: true }
        : { kind: "agentMessage", id, text, streaming: true },
    });
    return events;
  }

  #onClientOriginated(method: string, message: AcpWireMessage): AdapterEvent[] {
    const id = message.id;
    if (id !== undefined) this.#pendingOutbound.set(String(id), method);
    if (method !== "session/prompt") return [];
    const params = message.params as AcpPromptParams | undefined;
    const prompt = params?.prompt ?? [];
    this.#promptInFlight = true;
    return [
      {
        type: "blockAppended",
        block: {
          kind: "userMessage",
          id: this.#nextBlockId("user"),
          text: textOf(prompt),
          imageCount: imageCountOf(prompt),
        },
      },
      { type: "status", status: "running" },
    ];
  }

  #onAgentOriginated(method: string, message: AcpWireMessage): AdapterEvent[] {
    if (message.id === undefined) {
      if (method !== "session/update" || !isRecord(message.params)) return [];
      const params = message.params as unknown as AcpSessionNotificationParams;
      return this.#onSessionUpdate(params.update);
    }
    if (method !== "session/request_permission" || !isRecord(message.params)) return [];
    return this.#onPermissionRequest(String(message.id), message.params as unknown as AcpRequestPermissionParams);
  }

  #onPermissionRequest(approvalId: string, params: AcpRequestPermissionParams): AdapterEvent[] {
    this.#pendingInbound.set(approvalId, "session/request_permission");
    const toolCall = params.toolCall;
    // [实测] 审批请求本身不带命令，只带 title 和一句「Not in allowlist: echo」，
    // 命令要从同 toolCallId 的 tool_call 更新里翻出来才凑得齐 detail
    const command = this.#commandByToolCall.get(toolCall.toolCallId);
    const reason = (toolCall.content ?? [])
      .map((item) => item.content?.text ?? "")
      .filter((text) => text !== "")
      .join("\n");
    const detail = [command, reason].filter((part) => part !== undefined && part !== "").join("\n");
    return [
      {
        type: "approvalRequested",
        approval: {
          id: approvalId,
          kind: toApprovalKind(toolCall.kind),
          title: singleLine(toolCall.title ?? command ?? "工具调用"),
          detail,
          cwd: this.#cwd,
          options: params.options.map((option): ApprovalOption => {
            const choice = toApprovalChoice(option.kind);
            return {
              id: option.optionId,
              label: option.name,
              kind: choice.kind,
              scope: choice.scope,
            };
          }),
          requestedAtMs: this.#now(),
        },
      },
    ];
  }

  #onSessionUpdate(update: AcpSessionUpdate): AdapterEvent[] {
    switch (update.sessionUpdate) {
      case "agent_message_chunk":
        return this.#appendText("agentMessage", update.content.text ?? "");
      case "agent_thought_chunk":
        return this.#appendText("reasoning", update.content.text ?? "");
      case "user_message_chunk":
        // 直播时 cursor 不回显用户输入，userMessage 已由 session/prompt 造出；
        // 这条只在 session/load 重放历史时才会来，认它才补得回历史里的用户轮次
        return this.#promptInFlight ? [] : this.#appendText("userMessage", update.content.text ?? "");
      case "tool_call": {
        const events = this.#closeTextBlock();
        const command = update.rawInput?.command;
        if (command !== undefined) this.#commandByToolCall.set(update.toolCallId, command);
        const status = toBlockStatus(update.status);
        if (update.kind === "execute" || command !== undefined) {
          events.push({
            type: "blockAppended",
            block: {
              kind: "shellCommand",
              id: update.toolCallId,
              command: command ?? singleLine(update.title ?? ""),
              cwd: this.#cwd,
              output: "",
              exitCode: null,
              status,
            },
          });
          return events;
        }
        events.push({
          type: "blockAppended",
          block: {
            kind: "toolCall",
            id: update.toolCallId,
            source: null,
            tool: update.kind ?? "other",
            summary: singleLine(update.title ?? ""),
            output: "",
            status,
          },
        });
        return events;
      }
      case "tool_call_update": {
        const patch: TranscriptBlockPatch = {};
        const rawOutput = update.rawOutput;
        const exitCode = rawOutput?.exitCode;
        if (rawOutput !== undefined) {
          const output = `${rawOutput.stdout ?? ""}${rawOutput.stderr ?? ""}`;
          if (output !== "") patch.appendText = output;
          if (typeof exitCode === "number") patch.exitCode = exitCode;
        }
        if (update.status !== undefined) {
          // ACP 只说「跑完了」，非零退出码在契约里要落到 failed
          patch.status =
            update.status === "completed" && typeof exitCode === "number" && exitCode !== 0
              ? "failed"
              : toBlockStatus(update.status);
        }
        if (Object.keys(patch).length === 0) return [];
        return [{ type: "blockUpdated", blockId: update.toolCallId, patch }];
      }
      case "plan": {
        const steps = toPlanSteps(update.entries);
        const planBlockId = this.#planBlockId;
        // ACP 每次都发全量计划，客户端整块替换
        if (planBlockId !== null) {
          return [{ type: "blockUpdated", blockId: planBlockId, patch: { steps } }];
        }
        const events = this.#closeTextBlock();
        const id = this.#nextBlockId("plan");
        this.#planBlockId = id;
        events.push({ type: "blockAppended", block: { kind: "plan", id, steps } });
        return events;
      }
      case "session_info_update": {
        const title = update.title;
        // title 可以是 null，[规范] 表示清空标题；titleResolved 只承载字符串，
        // 清空就什么都不发，免得把会话标题刷成空白
        return typeof title === "string" && title !== ""
          ? [{ type: "titleResolved", title: singleLine(title) }]
          : [];
      }
      // [实测] session/set_mode 成功前 agent 先推这条——模式切换的权威回显
      case "current_mode_update":
        return [{ type: "modeResolved", modeId: update.currentModeId }];
      default:
        // available_commands_update 是本机 slash 命令清单，usage_update 给的是
        // 上下文窗口占用而不是本轮用量，两者在契约里都没有落点
        return [];
    }
  }

  #onResponse(message: AcpWireMessage): AdapterEvent[] {
    const id = message.id;
    if (id === undefined) return [];
    const key = String(id);
    const outboundMethod = this.#pendingOutbound.get(key);
    if (outboundMethod !== undefined) {
      this.#pendingOutbound.delete(key);
      return this.#onAgentResponse(outboundMethod, message);
    }
    if (this.#pendingInbound.delete(key)) return this.#onApprovalAnswered(key, message);
    return [];
  }

  #onAgentResponse(method: string, message: AcpWireMessage): AdapterEvent[] {
    const error = message.error;
    if (error !== undefined) {
      const events: AdapterEvent[] = [
        {
          type: "error",
          message: `${method} 失败：${error.message}`,
          fatal: method === "initialize" || method === "session/new",
        },
      ];
      if (method === "session/prompt") {
        this.#promptInFlight = false;
        events.push(...this.#closeTextBlock());
        // 这一轮确实结束了，只是结束得不体面；不发 turnCompleted 会话就卡在 running
        events.push({
          type: "turnCompleted",
          inputTokens: null,
          outputTokens: null,
          cachedInputTokens: null,
          stopReason: "failed",
        });
        events.push({ type: "status", status: "error" });
      }
      return events;
    }

    if (method === "session/new" || method === "session/load") {
      const result = message.result as AcpNewSessionResult | undefined;
      const events: AdapterEvent[] = [];
      const sessionId = result?.sessionId;
      if (sessionId !== undefined) events.push({ type: "nativeIdAssigned", nativeId: sessionId });
      const model = result?.models?.currentModelId;
      if (model !== undefined) events.push({ type: "modelResolved", model });
      // 模式清单以运行时自陈为准（agent/plan/ask 是 2026.07.23 的实测值，
      // 上游加档后这里自动跟上，adapter 的静态表只是启动前的兜底）
      const modes = result?.modes;
      if (modes !== undefined) {
        events.push({
          type: "modesResolved",
          modes: modes.availableModes.map((mode) => ({
            id: mode.id,
            label: mode.name ?? mode.id,
            detail: mode.description ?? "",
          })),
        });
        events.push({ type: "modeResolved", modeId: modes.currentModeId });
      }
      // 模型清单同样自陈，手机端的模型切换菜单靠它
      const availableModels = result?.models?.availableModels;
      if (availableModels !== undefined && availableModels.length > 0) {
        events.push({
          type: "modelsResolved",
          // 档位/上下文编死在官方模型 id 的参数里，没有独立的档位维度
          models: availableModels.map((entry) => ({
            id: entry.modelId,
            label: entry.name ?? entry.modelId,
            reasoningEfforts: [],
          })),
        });
      }
      events.push({ type: "status", status: "idle" });
      return events;
    }

    if (method === "session/prompt") {
      const result = message.result as AcpPromptResult | undefined;
      this.#promptInFlight = false;
      const events = this.#closeTextBlock();
      if (result?.stopReason === "refusal") {
        events.push({ type: "error", message: "agent 拒绝继续本轮", fatal: false });
      }
      // [实测] ACP 的 prompt 响应只有 stopReason，拿不到任何 token 用量
      events.push({
        type: "turnCompleted",
        inputTokens: null,
        outputTokens: null,
        cachedInputTokens: null,
        stopReason: toTurnStopReason(result?.stopReason),
      });
      events.push({ type: "status", status: "idle" });
      return events;
    }

    return [];
  }

  #onApprovalAnswered(approvalId: string, message: AcpWireMessage): AdapterEvent[] {
    const result = message.result as AcpRequestPermissionResult | undefined;
    const outcome = result?.outcome;
    if (outcome !== undefined && outcome.outcome === "selected") {
      return [
        { type: "approvalSettled", approvalId, optionId: outcome.optionId, outcome: "resolved" },
      ];
    }
    return [{ type: "approvalSettled", approvalId, optionId: null, outcome: "cancelled" }];
  }
}
