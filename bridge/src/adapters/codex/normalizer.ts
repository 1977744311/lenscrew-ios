// Codex app-server 消息 → LensCrew 统一事件的纯翻译。无 IO、无计时器、无随机数，
// 同一串输入永远得到同一串输出，好让 protocol/fixtures/codex-turn.jsonl 能当回归基线。

import type {
  ApprovalOption,
  ApprovalOptionKind,
  ApprovalScope,
  BlockStatus,
  FileChangeSummary,
  PlanStep,
  SessionStatus,
  TranscriptBlock,
  TranscriptBlockPatch,
  TurnStopReason,
} from "../../protocol/events.ts";
import type { AdapterEvent, ProtocolNormalizer } from "../types.ts";
import type {
  CodexApplyPatchApprovalParams,
  CodexCommandExecutionApprovalDecision,
  CodexCommandExecutionRequestApprovalParams,
  CodexDynamicToolCallOutputContentItem,
  CodexErrorParams,
  CodexExecCommandApprovalParams,
  CodexFileChangePatchUpdatedParams,
  CodexFileChangeRequestApprovalParams,
  CodexFileUpdateChange,
  CodexIncomingMessage,
  CodexItemCompletedParams,
  CodexItemDeltaParams,
  CodexItemStartedParams,
  CodexMcpElicitationRequestParams,
  CodexMcpToolCallError,
  CodexMcpToolCallResult,
  CodexPermissionsRequestApprovalParams,
  CodexRequestId,
  CodexServerRequestMethod,
  CodexServerRequestResolvedParams,
  CodexThreadNameUpdatedParams,
  CodexThreadSettingsUpdatedParams,
  CodexThreadStartedParams,
  CodexThreadStatusChangedParams,
  CodexThreadTokenUsageUpdatedParams,
  CodexThreadItem,
  CodexToolRequestUserInputParams,
  CodexTurnCompletedParams,
  CodexTurnPlanUpdatedParams,
  CodexTurnStartedParams,
  CodexTurn,
} from "./protocol.ts";

/** adapter 要回送给 app-server 的应答体 */
export interface CodexApprovalResponse {
  requestId: CodexRequestId;
  result: Record<string, unknown>;
}

interface PendingApproval {
  requestId: CodexRequestId;
  method: CodexServerRequestMethod;
  /** optionId → 该选项对应的 JSON-RPC result，直接原样发回 */
  results: Map<string, Record<string, unknown>>;
  /** 本地已裁决过的 optionId；serverRequest/resolved 时用来区分是我们答的还是被取消 */
  chosenOptionId: string | null;
}

export interface CodexNormalizerOptions {
  /** 只在协议没给时间戳时兜底；给了 startedAtMs 的审批不会用到，保证测试可复现 */
  now?: () => number;
}

/**
 * codex 的裁决取值 → 契约的 kind + scope。
 *
 * scope 的分档以「批准一次之后，下次同样的操作还会不会再问」为准：
 *   accept                        只放行这一次
 *   acceptForSession              本 thread 内不再问，进程退出即失效
 *   acceptWithExecpolicyAmendment 往 execpolicy 里写一条 prefix_rule，跨会话长期生效
 *   applyNetworkPolicyAmendment   往网络策略里写一条 host 规则，同样跨会话
 * 后两者虽然也是"以后别问了"，但落盘位置和存活期跟 session 档完全不同，
 * 眼镜端必须能一眼分出来，所以归 persistent 而不是和 session 挤在一起。
 */
const DECISION_SHAPES: Record<
  string,
  { kind: ApprovalOptionKind; scope: ApprovalScope }
> = {
  accept: { kind: "allow", scope: "once" },
  acceptForSession: { kind: "allow", scope: "session" },
  acceptWithExecpolicyAmendment: { kind: "allow", scope: "persistent" },
  applyNetworkPolicyAmendment: { kind: "allow", scope: "persistent" },
  decline: { kind: "deny", scope: "once" },
  cancel: { kind: "abort", scope: "once" },
  // 旧版 execCommandApproval / applyPatchApproval 的 ReviewDecision，取值另成一套
  approved: { kind: "allow", scope: "once" },
  approved_for_session: { kind: "allow", scope: "session" },
  denied: { kind: "deny", scope: "once" },
  abort: { kind: "abort", scope: "once" },
};

function commandStatus(
  status: "inProgress" | "completed" | "failed" | "declined",
): BlockStatus {
  switch (status) {
    case "inProgress":
      return "running";
    case "completed":
      return "ok";
    case "failed":
      return "failed";
    case "declined":
      return "rejected";
  }
}

function toolStatus(status: "inProgress" | "completed" | "failed"): BlockStatus {
  switch (status) {
    case "inProgress":
      return "running";
    case "completed":
      return "ok";
    case "failed":
      return "failed";
  }
}

/** codex 不直接给 added/removed，只能数 diff 的 +/- 行 */
function diffStat(diff: string): { added: number; removed: number } {
  let added = 0;
  let removed = 0;
  for (const line of diff.split("\n")) {
    if (line.startsWith("+++") || line.startsWith("---")) continue;
    if (line.startsWith("+")) added += 1;
    else if (line.startsWith("-")) removed += 1;
  }
  return { added, removed };
}

function fileSummaries(changes: CodexFileUpdateChange[]): FileChangeSummary[] {
  return changes.map((change) => {
    // 没有 diff 就是真的算不出来，只能报 null；填 0 等于告诉客户端"改了但零增零删"
    if (typeof change.diff !== "string" || change.diff.length === 0) {
      return { path: change.path, added: null, removed: null };
    }
    const stat = diffStat(change.diff);
    return { path: change.path, added: stat.added, removed: stat.removed };
  });
}

/** MCP 的 content 是富内容数组，文本项形如 { type: "text", text } */
function mcpToolOutput(
  result: CodexMcpToolCallResult | null,
  error: CodexMcpToolCallError | null,
): string {
  if (error) return error.message;
  if (!result) return "";
  const parts: string[] = [];
  for (const entry of result.content ?? []) {
    if (
      entry !== null &&
      typeof entry === "object" &&
      "text" in entry &&
      typeof entry.text === "string"
    ) {
      parts.push(entry.text);
    } else {
      parts.push(JSON.stringify(entry));
    }
  }
  if (parts.length === 0 && result.structuredContent != null) {
    parts.push(JSON.stringify(result.structuredContent));
  }
  return parts.join("\n");
}

function dynamicToolOutput(
  items: CodexDynamicToolCallOutputContentItem[] | null,
): string {
  return (items ?? [])
    .map((item) => (item.type === "inputText" ? item.text : item.imageUrl))
    .join("\n");
}

/**
 * codex 的 TurnStatus 只有四档，能可靠对上契约的三种。
 * codex 把上下文超限表达成 status=failed + codexErrorInfo=contextWindowExceeded，
 * 这里挑出来归到 maxTokens：对用户来说"上下文满了"和"出错了"是两种处置
 * （前者去压缩或开新会话），归成 failed 等于把这个信息藏起来。
 * 配额类的 usageLimitExceeded / sessionBudgetExceeded 不算，它们不是模型的 token 上限。
 *
 * refused 在 codex 这边没有对应取值，不硬塞。
 */
function stopReasonFor(turn: CodexTurn | undefined): TurnStopReason | null {
  switch (turn?.status) {
    case "completed":
      return "completed";
    case "interrupted":
      return "interrupted";
    case "failed":
      return turn.error?.codexErrorInfo === "contextWindowExceeded"
        ? "maxTokens"
        : "failed";
    default:
      return null;
  }
}

/** 眼镜屏一行放不下整条命令/整段计划，标题和摘要都只取第一行并截断 */
function firstLine(text: string): string {
  const line = text.split("\n")[0] ?? "";
  return line.length > 60 ? `${line.slice(0, 57)}...` : line;
}

function reasoningText(summary: string[], content: string[]): string {
  return [...summary, ...content].filter((part) => part.length > 0).join("\n\n");
}

function decisionOptionId(decision: unknown): string | null {
  if (typeof decision === "string") return decision;
  if (decision !== null && typeof decision === "object") {
    const keys = Object.keys(decision);
    return keys[0] ?? null;
  }
  return null;
}

/**
 * 认不出的裁决直接不给选项，而不是猜一个 kind/scope 顶上。
 * 契约要求 scope 能被眼镜端当逻辑判断用，猜错等于把"永久放行"画成"就这一次"。
 * 漏掉也不会卡死：调用方总会补上 decline / cancel 兜底。
 * label 按契约填运行时原文，客户端不拿它做显示。
 */
function toApprovalOption(optionId: string): ApprovalOption | null {
  const shape = DECISION_SHAPES[optionId];
  if (!shape) return null;
  return { id: optionId, label: optionId, kind: shape.kind, scope: shape.scope };
}

function toApprovalOptions(optionIds: Iterable<string>): ApprovalOption[] {
  const options: ApprovalOption[] = [];
  for (const optionId of optionIds) {
    const option = toApprovalOption(optionId);
    if (option) options.push(option);
  }
  return options;
}

export class CodexNormalizer
  implements ProtocolNormalizer<CodexIncomingMessage>
{
  readonly #now: () => number;
  /** itemId → 已生成的 block 类型，item/completed 和各种 delta 靠它决定怎么打补丁 */
  readonly #blockKinds = new Map<string, TranscriptBlock["kind"]>();
  readonly #approvals = new Map<string, PendingApproval>();
  /** 已经为哪些 turn 建过 plan block；turn/plan/updated 会反复推送同一份计划 */
  readonly #planTurns = new Set<string>();
  #lastStatus: SessionStatus | null = null;
  #lastInputTokens: number | null = null;
  #lastOutputTokens: number | null = null;
  #lastCachedInputTokens: number | null = null;
  #errorSeq = 0;
  #currentTurnId: string | null = null;

  constructor(options: CodexNormalizerOptions = {}) {
    this.#now = options.now ?? Date.now;
  }

  /** 当前活动 turn；turn/steer 和 turn/interrupt 都要求带上它 */
  get currentTurnId(): string | null {
    return this.#currentTurnId;
  }

  normalize(message: CodexIncomingMessage): AdapterEvent[] {
    const method = message.method;
    if (method === undefined) return [];

    // 有 id 的是服务端请求，必须应答；其中审批类要交给客户端裁决
    if (message.id !== undefined) {
      return this.#serverRequest(method, message.id, message.params);
    }

    switch (method) {
      case "thread/started":
        return this.#threadStarted(message.params as CodexThreadStartedParams);
      case "thread/settings/updated": {
        const params = message.params as CodexThreadSettingsUpdatedParams;
        const model = params.threadSettings?.model;
        return model ? [{ type: "modelResolved", model }] : [];
      }
      case "thread/status/changed":
        return this.#statusEvents(
          this.#mapStatus(message.params as CodexThreadStatusChangedParams),
        );
      case "turn/started": {
        const params = message.params as CodexTurnStartedParams;
        this.#currentTurnId = params.turn?.id ?? null;
        return this.#statusEvents("running");
      }
      case "turn/completed":
        return this.#turnCompleted(message.params as CodexTurnCompletedParams);
      case "thread/name/updated": {
        const params = message.params as CodexThreadNameUpdatedParams;
        const title = params.threadName;
        return title ? [{ type: "titleResolved", title }] : [];
      }
      case "thread/tokenUsage/updated": {
        const params = message.params as CodexThreadTokenUsageUpdatedParams;
        const last = params.tokenUsage?.last;
        if (last) {
          this.#lastInputTokens = last.inputTokens;
          this.#lastOutputTokens = last.outputTokens;
          this.#lastCachedInputTokens = last.cachedInputTokens;
        }
        return [];
      }
      case "item/started":
        return this.#itemStarted(message.params as CodexItemStartedParams);
      case "item/completed":
        return this.#itemCompleted(message.params as CodexItemCompletedParams);
      case "item/agentMessage/delta":
      case "item/reasoning/textDelta":
      case "item/reasoning/summaryTextDelta":
        return this.#textDelta(message.params as CodexItemDeltaParams, true);
      case "item/commandExecution/outputDelta":
        return this.#textDelta(message.params as CodexItemDeltaParams, false);
      case "item/fileChange/patchUpdated": {
        const params = message.params as CodexFileChangePatchUpdatedParams;
        if (!this.#blockKinds.has(params.itemId)) return [];
        return [
          {
            type: "blockUpdated",
            blockId: params.itemId,
            patch: { files: fileSummaries(params.changes ?? []) },
          },
        ];
      }
      case "turn/plan/updated":
        return this.#planUpdated(message.params as CodexTurnPlanUpdatedParams);
      case "serverRequest/resolved":
        return this.#serverRequestResolved(
          message.params as CodexServerRequestResolvedParams,
        );
      case "error":
        return this.#error(message.params as CodexErrorParams);
      default:
        // 账号额度、MCP 启动状态、远程控制、废弃提示等与会话流水无关的通知一律丢弃
        return [];
    }
  }

  /**
   * 把客户端选的 optionId 翻回 app-server 认的裁决体。
   * 同时记下 optionId，等 serverRequest/resolved 到达时才能报出到底批了哪一项。
   */
  buildApprovalResponse(
    approvalId: string,
    optionId: string,
  ): CodexApprovalResponse | null {
    const pending = this.#approvals.get(approvalId);
    if (!pending) return null;
    const result = pending.results.get(optionId);
    if (!result) return null;
    pending.chosenOptionId = optionId;
    return { requestId: pending.requestId, result };
  }

  hasPendingApproval(approvalId: string): boolean {
    return this.#approvals.has(approvalId);
  }

  #threadStarted(params: CodexThreadStartedParams): AdapterEvent[] {
    const id = params.thread?.id;
    return id ? [{ type: "nativeIdAssigned", nativeId: id }] : [];
  }

  #mapStatus(params: CodexThreadStatusChangedParams): SessionStatus {
    const status = params.status;
    switch (status?.type) {
      case "idle":
        return "idle";
      case "systemError":
        return "error";
      case "notLoaded":
        return "starting";
      case "active":
        // waitingOnUserInput 也是在等人，契约里没有单独状态，一并算作待审批
        return status.activeFlags?.length ? "awaitingApproval" : "running";
      default:
        return "running";
    }
  }

  /** 同一状态连着来好几次很常见（status/changed 后紧跟 turn/started），去重 */
  #statusEvents(status: SessionStatus): AdapterEvent[] {
    if (this.#lastStatus === status) return [];
    this.#lastStatus = status;
    return [{ type: "status", status }];
  }

  #turnCompleted(params: CodexTurnCompletedParams): AdapterEvent[] {
    this.#currentTurnId = null;
    const events: AdapterEvent[] = [
      {
        type: "turnCompleted",
        inputTokens: this.#lastInputTokens,
        outputTokens: this.#lastOutputTokens,
        cachedInputTokens: this.#lastCachedInputTokens,
        stopReason: stopReasonFor(params.turn),
      },
    ];
    // 下一轮没推 tokenUsage 就该报 null，不能把这轮的数字漏过去
    this.#lastInputTokens = null;
    this.#lastOutputTokens = null;
    this.#lastCachedInputTokens = null;
    return events;
  }

  #itemStarted(params: CodexItemStartedParams): AdapterEvent[] {
    const block = this.#toBlock(params.item, true);
    if (!block) return [];
    this.#blockKinds.set(block.id, block.kind);
    return [{ type: "blockAppended", block }];
  }

  #itemCompleted(params: CodexItemCompletedParams): AdapterEvent[] {
    const item = params.item;
    // item/started 可能因为断线补齐而缺失，这时直接补一条 append，不要丢内容
    if (!this.#blockKinds.has(item.id)) {
      const block = this.#toBlock(item, false);
      if (!block) return [];
      this.#blockKinds.set(block.id, block.kind);
      return [{ type: "blockAppended", block }];
    }

    const patch = this.#finalPatch(item);
    if (!patch) return [];
    return [{ type: "blockUpdated", blockId: item.id, patch }];
  }

  #textDelta(
    params: CodexItemDeltaParams,
    streaming: boolean,
  ): AdapterEvent[] {
    if (!this.#blockKinds.has(params.itemId)) return [];
    const patch: TranscriptBlockPatch = { appendText: params.delta };
    if (streaming) patch.streaming = true;
    return [{ type: "blockUpdated", blockId: params.itemId, patch }];
  }

  #planUpdated(params: CodexTurnPlanUpdatedParams): AdapterEvent[] {
    const steps: PlanStep[] = (params.plan ?? []).map((entry) => ({
      text: entry.step,
      status:
        entry.status === "completed"
          ? "done"
          : entry.status === "inProgress"
            ? "running"
            : "pending",
    }));
    // 计划是 turn 级的，没有 itemId，只能自己造一个跨推送稳定的 blockId
    const blockId = `plan:${params.turnId}`;
    if (this.#planTurns.has(params.turnId)) {
      return [{ type: "blockUpdated", blockId, patch: { steps } }];
    }
    this.#planTurns.add(params.turnId);
    this.#blockKinds.set(blockId, "plan");
    return [{ type: "blockAppended", block: { kind: "plan", id: blockId, steps } }];
  }

  #error(params: CodexErrorParams): AdapterEvent[] {
    const message = params.error?.message ?? "codex 返回了未知错误";
    const detail = params.error?.additionalDetails;
    const text = detail ? `${message}\n${detail}` : message;
    this.#errorSeq += 1;
    const blockId = `error:${params.turnId}:${this.#errorSeq}`;
    return [
      { type: "blockAppended", block: { kind: "error", id: blockId, message: text } },
      // willRetry 为真时 codex 会自己重试，会话没死；进程级致命错误由 adapter 单独报
      { type: "error", message: text, fatal: false },
    ];
  }

  #serverRequestResolved(
    params: CodexServerRequestResolvedParams,
  ): AdapterEvent[] {
    const approvalId = String(params.requestId);
    const pending = this.#approvals.get(approvalId);
    if (!pending) return [];
    this.#approvals.delete(approvalId);
    // 我们没答过却被解决，只能是 app-server 那侧撤销了（turn 中断、超时等）
    return [
      {
        type: "approvalSettled",
        approvalId,
        optionId: pending.chosenOptionId,
        outcome: pending.chosenOptionId === null ? "cancelled" : "resolved",
      },
    ];
  }

  #serverRequest(
    method: string,
    requestId: CodexRequestId,
    rawParams: unknown,
  ): AdapterEvent[] {
    const approvalId = String(requestId);
    switch (method) {
      case "item/commandExecution/requestApproval":
        return this.#commandApproval(
          approvalId,
          requestId,
          rawParams as CodexCommandExecutionRequestApprovalParams,
        );
      case "item/fileChange/requestApproval":
        return this.#fileChangeApproval(
          approvalId,
          requestId,
          rawParams as CodexFileChangeRequestApprovalParams,
        );
      case "item/permissions/requestApproval":
        return this.#permissionsApproval(
          approvalId,
          requestId,
          rawParams as CodexPermissionsRequestApprovalParams,
        );
      case "item/tool/requestUserInput":
        return this.#userInputRequest(
          approvalId,
          requestId,
          rawParams as CodexToolRequestUserInputParams,
        );
      case "mcpServer/elicitation/request":
        return this.#elicitationRequest(
          approvalId,
          requestId,
          rawParams as CodexMcpElicitationRequestParams,
        );
      case "execCommandApproval":
        return this.#legacyExecApproval(
          approvalId,
          requestId,
          rawParams as CodexExecCommandApprovalParams,
        );
      case "applyPatchApproval":
        return this.#legacyPatchApproval(
          approvalId,
          requestId,
          rawParams as CodexApplyPatchApprovalParams,
        );
      default:
        // item/tool/call、attestation/generate 等不需要人裁决的请求由 adapter 直接回
        return [];
    }
  }

  #register(
    approvalId: string,
    requestId: CodexRequestId,
    method: CodexServerRequestMethod,
    results: Map<string, Record<string, unknown>>,
  ): void {
    this.#approvals.set(approvalId, {
      requestId,
      method,
      results,
      chosenOptionId: null,
    });
  }

  #commandApproval(
    approvalId: string,
    requestId: CodexRequestId,
    params: CodexCommandExecutionRequestApprovalParams,
  ): AdapterEvent[] {
    const results = new Map<string, Record<string, unknown>>();

    // availableDecisions 是服务端逐请求给的权威清单，优先照抄
    for (const decision of params.availableDecisions ?? []) {
      const optionId = decisionOptionId(decision);
      if (!optionId || results.has(optionId)) continue;
      results.set(optionId, { decision });
    }

    // 服务端可能不列 decline，但拒绝是手机端必须永远有的兜底动作
    for (const fallback of ["decline", "cancel"] satisfies
      CodexCommandExecutionApprovalDecision[]) {
      if (results.has(fallback)) continue;
      results.set(fallback, { decision: fallback });
    }

    const options = toApprovalOptions(results.keys());
    this.#register(approvalId, requestId, "item/commandExecution/requestApproval", results);
    const command = params.command ?? "";
    return [
      {
        type: "approvalRequested",
        approval: {
          id: approvalId,
          kind: "shellCommand",
          title: firstLine(command),
          detail: params.reason ? `${command}\n\n${params.reason}` : command,
          cwd: params.cwd ?? null,
          options,
          requestedAtMs: this.#startedAt(params),
        },
      },
    ];
  }

  #fileChangeApproval(
    approvalId: string,
    requestId: CodexRequestId,
    params: CodexFileChangeRequestApprovalParams,
  ): AdapterEvent[] {
    const results = new Map<string, Record<string, unknown>>();
    const available = params.availableDecisions ?? [
      "accept",
      "acceptForSession",
      "decline",
      "cancel",
    ];
    for (const decision of available) {
      const optionId = decisionOptionId(decision);
      if (!optionId || results.has(optionId)) continue;
      results.set(optionId, { decision });
    }
    for (const fallback of ["decline", "cancel"] as const) {
      if (results.has(fallback)) continue;
      results.set(fallback, { decision: fallback });
    }

    const options = toApprovalOptions(results.keys());
    this.#register(approvalId, requestId, "item/fileChange/requestApproval", results);
    const detail = params.grantRoot
      ? `请求写入权限：${params.grantRoot}`
      : "请求应用文件改动";
    return [
      {
        type: "approvalRequested",
        approval: {
          id: approvalId,
          kind: "fileChange",
          title: "应用文件改动",
          detail: params.reason ? `${detail}\n\n${params.reason}` : detail,
          cwd: null,
          options,
          requestedAtMs: this.#startedAt(params),
        },
      },
    ];
  }

  #permissionsApproval(
    approvalId: string,
    requestId: CodexRequestId,
    params: CodexPermissionsRequestApprovalParams,
  ): AdapterEvent[] {
    // 这类审批的应答体和另外两种完全不同构：没有 decision，
    // 批准是回 { permissions, scope }，拒绝是回空 permissions。
    const granted = params.permissions ?? {};
    const results = new Map<string, Record<string, unknown>>([
      ["accept", { permissions: granted, scope: "turn" }],
      ["acceptForSession", { permissions: granted, scope: "session" }],
      ["decline", { permissions: {}, scope: "turn" }],
    ]);
    this.#register(approvalId, requestId, "item/permissions/requestApproval", results);
    return [
      {
        type: "approvalRequested",
        approval: {
          id: approvalId,
          kind: "permission",
          title: "提升权限",
          detail: params.reason ?? "codex 请求额外的网络或文件系统权限",
          cwd: params.cwd ?? null,
          options: toApprovalOptions(results.keys()),
          requestedAtMs: this.#startedAt(params),
        },
      },
    ];
  }

  #userInputRequest(
    approvalId: string,
    requestId: CodexRequestId,
    params: CodexToolRequestUserInputParams,
  ): AdapterEvent[] {
    // 契约的审批只能表达“选一个选项”，没有自由文本回填通道，
    // 所以这里只能给一个空答案把请求了结，避免 turn 永远卡住。
    const results = new Map<string, Record<string, unknown>>([
      ["decline", { answers: {} }],
    ]);
    this.#register(approvalId, requestId, "item/tool/requestUserInput", results);
    const prompts = (params.questions ?? [])
      .map((question) => question.prompt ?? "")
      .filter((prompt) => prompt.length > 0);
    return [
      {
        type: "approvalRequested",
        approval: {
          id: approvalId,
          kind: "tool",
          title: "工具需要补充输入",
          detail: prompts.length ? prompts.join("\n") : "工具请求用户输入",
          cwd: null,
          options: toApprovalOptions(results.keys()),
          requestedAtMs: this.#now(),
        },
      },
    ];
  }

  #elicitationRequest(
    approvalId: string,
    requestId: CodexRequestId,
    params: CodexMcpElicitationRequestParams,
  ): AdapterEvent[] {
    const results = new Map<string, Record<string, unknown>>([
      ["decline", { action: "decline", content: null, _meta: null }],
      ["cancel", { action: "cancel", content: null, _meta: null }],
    ]);
    this.#register(approvalId, requestId, "mcpServer/elicitation/request", results);
    return [
      {
        type: "approvalRequested",
        approval: {
          id: approvalId,
          kind: "tool",
          title: `${params.serverName} 请求确认`,
          detail: params.message ?? "",
          cwd: null,
          options: toApprovalOptions(results.keys()),
          requestedAtMs: this.#now(),
        },
      },
    ];
  }

  #legacyExecApproval(
    approvalId: string,
    requestId: CodexRequestId,
    params: CodexExecCommandApprovalParams,
  ): AdapterEvent[] {
    // 旧版通道用 ReviewDecision，和 v2 的 accept/decline 不是一套，绝不能混
    const results = new Map<string, Record<string, unknown>>([
      ["approved", { decision: "approved" }],
      ["approved_for_session", { decision: "approved_for_session" }],
      ["denied", { decision: "denied" }],
      ["abort", { decision: "abort" }],
    ]);
    this.#register(approvalId, requestId, "execCommandApproval", results);
    const command = (params.command ?? []).join(" ");
    return [
      {
        type: "approvalRequested",
        approval: {
          id: approvalId,
          kind: "shellCommand",
          title: firstLine(command),
          detail: params.reason ? `${command}\n\n${params.reason}` : command,
          cwd: params.cwd ?? null,
          options: toApprovalOptions(results.keys()),
          requestedAtMs: this.#now(),
        },
      },
    ];
  }

  #legacyPatchApproval(
    approvalId: string,
    requestId: CodexRequestId,
    params: CodexApplyPatchApprovalParams,
  ): AdapterEvent[] {
    const results = new Map<string, Record<string, unknown>>([
      ["approved", { decision: "approved" }],
      ["approved_for_session", { decision: "approved_for_session" }],
      ["denied", { decision: "denied" }],
      ["abort", { decision: "abort" }],
    ]);
    this.#register(approvalId, requestId, "applyPatchApproval", results);
    const paths = Object.keys(params.fileChanges ?? {});
    return [
      {
        type: "approvalRequested",
        approval: {
          id: approvalId,
          kind: "fileChange",
          title: `应用改动（${paths.length} 个文件）`,
          detail: params.reason ? `${paths.join("\n")}\n\n${params.reason}` : paths.join("\n"),
          cwd: null,
          options: toApprovalOptions(results.keys()),
          requestedAtMs: this.#now(),
        },
      },
    ];
  }

  #startedAt(params: { startedAtMs?: number }): number {
    return typeof params.startedAtMs === "number" ? params.startedAtMs : this.#now();
  }

  /**
   * ThreadItem 18 类 → 契约 8 类 TranscriptBlock。
   * 折不进去的走 toolCall 兜底，不新增 block 类型。
   */
  #toBlock(item: CodexThreadItem, streaming: boolean): TranscriptBlock | null {
    switch (item.type) {
      case "userMessage": {
        const content = item.content ?? [];
        const text = content
          .filter((part) => part.type === "text")
          .map((part) => part.text)
          .join("\n");
        const imageCount = content.filter(
          (part) => part.type === "image" || part.type === "localImage",
        ).length;
        return { kind: "userMessage", id: item.id, text, imageCount };
      }
      case "agentMessage":
        return {
          kind: "agentMessage",
          id: item.id,
          text: item.text ?? "",
          streaming,
        };
      case "reasoning":
        return {
          kind: "reasoning",
          id: item.id,
          text: reasoningText(item.summary ?? [], item.content ?? []),
          streaming,
        };
      case "commandExecution":
        return {
          kind: "shellCommand",
          id: item.id,
          command: item.command,
          cwd: item.cwd ?? null,
          output: item.aggregatedOutput ?? "",
          exitCode: item.exitCode,
          status: commandStatus(item.status),
        };
      case "fileChange":
        return {
          kind: "fileChange",
          id: item.id,
          files: fileSummaries(item.changes ?? []),
          status: commandStatus(item.status),
        };
      case "mcpToolCall":
        // item/started 时 result 还是 null，正文要等 item/completed 才补得上
        return {
          kind: "toolCall",
          id: item.id,
          source: item.server,
          tool: item.tool,
          summary: `${item.server} / ${item.tool}`,
          output: mcpToolOutput(item.result, item.error),
          status: toolStatus(item.status),
        };
      case "dynamicToolCall":
        return {
          kind: "toolCall",
          id: item.id,
          source: item.namespace,
          tool: item.tool,
          summary: item.namespace ? `${item.namespace}/${item.tool}` : item.tool,
          output: dynamicToolOutput(item.contentItems),
          status: toolStatus(item.status),
        };
      case "webSearch":
        return {
          kind: "toolCall",
          id: item.id,
          source: null,
          tool: "webSearch",
          summary: item.query ?? "",
          // 搜索结果不作为 item 回传，只能留空
          output: "",
          status: streaming ? "running" : "ok",
        };
      case "plan":
        // ThreadItem 的 plan 是自由文本，塞不进契约 plan block 的 steps 结构；
        // 而且 item/plan/delta 被官方标为不可靠（拼起来不等于最终文本），所以不吃增量。
        return {
          kind: "toolCall",
          id: item.id,
          source: null,
          tool: "plan",
          summary: firstLine(item.text ?? ""),
          output: item.text ?? "",
          status: streaming ? "running" : "ok",
        };
      default:
        return {
          kind: "toolCall",
          id: item.id,
          source: null,
          tool: item.type,
          summary: "",
          output: "",
          status: streaming ? "running" : "ok",
        };
    }
  }

  #finalPatch(item: CodexThreadItem): TranscriptBlockPatch | null {
    switch (item.type) {
      case "agentMessage":
        return { replaceText: item.text ?? "", streaming: false };
      case "reasoning":
        return {
          replaceText: reasoningText(item.summary ?? [], item.content ?? []),
          streaming: false,
        };
      case "commandExecution": {
        // aggregatedOutput 是权威全量（含 outputDelta 没推过的 stderr），整体替换
        const patch: TranscriptBlockPatch = {
          replaceText: item.aggregatedOutput ?? "",
          status: commandStatus(item.status),
        };
        if (item.exitCode !== null) patch.exitCode = item.exitCode;
        return patch;
      }
      case "fileChange":
        return {
          files: fileSummaries(item.changes ?? []),
          status: commandStatus(item.status),
        };
      // 工具正文走 replaceText（打到 toolCall 的 output），摘要另走 summary 字段
      case "mcpToolCall":
        return {
          replaceText: mcpToolOutput(item.result, item.error),
          status: toolStatus(item.status),
        };
      case "dynamicToolCall":
        return {
          replaceText: dynamicToolOutput(item.contentItems),
          status: toolStatus(item.status),
        };
      case "plan":
        return {
          replaceText: item.text ?? "",
          summary: firstLine(item.text ?? ""),
          status: "ok",
        };
      case "webSearch":
        return { summary: item.query ?? "", status: "ok" };
      case "userMessage":
        // 用户消息在 item/started 时就是终态，没有可打的补丁
        return null;
      default:
        return { status: "ok" };
    }
  }
}
