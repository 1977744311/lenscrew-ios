// Codex app-server 协议子集 —— 只声明 LensCrew adapter 真正消费的那部分。
//
// 来源：`codex app-server generate-ts`（codex-cli 0.144.4）输出的 89 个文件的子集。
// 升级 codex 后重新生成并逐条比对本文件：
//   codex app-server generate-ts --out /tmp/lenscrew-codex-ts
//   codex app-server generate-json-schema --out /tmp/lenscrew-codex-schema
//
// 2026-07-25 用 0.144.4 实测发现的、和生成物对不上的地方，本文件按实测为准：
//
// 1. v2 审批的裁决枚举不是 ReviewDecision。给 `item/commandExecution/requestApproval`
//    回 `{"decision":"approved"}` 会被 app-server 拒绝：
//      unknown variant `approved`, expected one of `accept`, `acceptForSession`,
//      `acceptWithExecpolicyAmendment`, `applyNetworkPolicyAmendment`, `decline`, `cancel`
//    ReviewDecision（approved/approved_for_session/denied/abort）只属于旧版
//    `execCommandApproval` / `applyPatchApproval`。两套裁决必须分开，混用会静默丢批准
//    ——被拒的那次审批最终以 status="declined" 收场，手机端看不出是自己发错了格式。
//
// 2. 审批请求线上带 `availableDecisions`，generate-ts 和 generate-json-schema 里都没有。
//    它逐请求告知本次真正可用的裁决（实测某次只给了 accept / acceptWithExecpolicyAmendment
//    / cancel，没有 acceptForSession 和 decline），是构造审批选项的权威来源。
//
// 3. `item/permissions/requestApproval` 的响应根本没有 decision 字段，
//    而是 { permissions, scope }，和另外两种审批不同构。

// MARK: - JSON-RPC 信封

export type CodexRequestId = string | number;

export interface CodexRpcError {
  code: number;
  message: string;
  data?: unknown;
}

/**
 * 分帧后的单条消息。app-server 走换行分隔的 JSON（一行一条完整消息），
 * 不是 LSP 那种 Content-Length 头 —— 0.144.4 实测确认。
 *
 * 三种形态共用这一个信封：
 *   通知     method 有、id 无
 *   服务端请求 method 有、id 有（必须应答，审批走这条）
 *   响应     method 无、id 有
 */
export interface CodexIncomingMessage {
  jsonrpc?: string;
  id?: CodexRequestId;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: CodexRpcError;
}

// MARK: - 审批裁决

/** execpolicy 前缀规则：命中该前缀的命令后续免审批 */
export type CodexExecPolicyAmendment = string[];

export interface CodexNetworkPolicyAmendment {
  host: string;
  action: string;
}

export type CodexCommandExecutionApprovalDecision =
  | "accept"
  | "acceptForSession"
  | {
      acceptWithExecpolicyAmendment: {
        execpolicy_amendment: CodexExecPolicyAmendment;
      };
    }
  | {
      applyNetworkPolicyAmendment: {
        network_policy_amendment: CodexNetworkPolicyAmendment;
      };
    }
  | "decline"
  | "cancel";

export type CodexFileChangeApprovalDecision =
  | "accept"
  | "acceptForSession"
  | "decline"
  | "cancel";

/** 仅用于旧版 execCommandApproval / applyPatchApproval */
export type CodexReviewDecision =
  | "approved"
  | "approved_for_session"
  | "denied"
  | "timed_out"
  | "abort";

// MARK: - ThreadItem（18 类，全部列出以便折叠时不漏）

export type CodexUserInput =
  | { type: "text"; text: string }
  | { type: "image"; url: string }
  | { type: "localImage"; path: string }
  | { type: "skill"; name: string; path: string }
  | { type: "mention"; name: string; path: string };

export type CodexCommandExecutionStatus =
  | "inProgress"
  | "completed"
  | "failed"
  | "declined";

/** fileChange 用的状态，取值和 CommandExecutionStatus 一致但是两个独立类型 */
export type CodexPatchApplyStatus =
  | "inProgress"
  | "completed"
  | "failed"
  | "declined";

/** mcpToolCall / dynamicToolCall 用，没有 declined */
export type CodexToolCallStatus = "inProgress" | "completed" | "failed";

export type CodexPatchChangeKind =
  | { type: "add" }
  | { type: "delete" }
  | { type: "update"; move_path: string | null };

export interface CodexFileUpdateChange {
  path: string;
  kind: CodexPatchChangeKind;
  diff: string;
}

/**
 * 折不进契约 8 类 TranscriptBlock 的 ThreadItem 类型，一律走 toolCall 兜底。
 * 显式列出而不是用 string 兜，是为了 codex 新增 item 类型时 TS 能报出来。
 */
export type CodexFallbackItemType =
  | "hookPrompt"
  | "collabAgentToolCall"
  | "subAgentActivity"
  | "imageView"
  | "sleep"
  | "imageGeneration"
  | "enteredReviewMode"
  | "exitedReviewMode"
  | "contextCompaction";

export type CodexThreadItem =
  | { type: "userMessage"; id: string; content: CodexUserInput[] }
  | { type: "agentMessage"; id: string; text: string }
  | { type: "reasoning"; id: string; summary: string[]; content: string[] }
  | { type: "plan"; id: string; text: string }
  | {
      type: "commandExecution";
      id: string;
      command: string;
      cwd: string;
      status: CodexCommandExecutionStatus;
      aggregatedOutput: string | null;
      exitCode: number | null;
    }
  | {
      type: "fileChange";
      id: string;
      changes: CodexFileUpdateChange[];
      status: CodexPatchApplyStatus;
    }
  | {
      type: "mcpToolCall";
      id: string;
      server: string;
      tool: string;
      status: CodexToolCallStatus;
    }
  | {
      type: "dynamicToolCall";
      id: string;
      namespace: string | null;
      tool: string;
      status: CodexToolCallStatus;
    }
  | { type: "webSearch"; id: string; query: string }
  | { type: CodexFallbackItemType; id: string };

// MARK: - 通知

export type CodexThreadStatus =
  | { type: "notLoaded" }
  | { type: "idle" }
  | { type: "systemError" }
  | { type: "active"; activeFlags: CodexThreadActiveFlag[] };

export type CodexThreadActiveFlag = "waitingOnApproval" | "waitingOnUserInput";

export interface CodexThread {
  id: string;
  cwd: string;
  modelProvider: string;
  status: CodexThreadStatus;
}

export type CodexTurnStatus =
  | "completed"
  | "interrupted"
  | "failed"
  | "inProgress";

export interface CodexTurn {
  id: string;
  status: CodexTurnStatus;
}

export interface CodexThreadStartedParams {
  thread: CodexThread;
}

export interface CodexThreadStatusChangedParams {
  threadId: string;
  status: CodexThreadStatus;
}

export interface CodexTurnStartedParams {
  threadId: string;
  turn: CodexTurn;
}

/** 唯一能拿到实际生效 model 名字的通知；thread/started 只给 modelProvider */
export interface CodexThreadSettingsUpdatedParams {
  threadId: string;
  threadSettings: {
    model: string;
    modelProvider: string;
  };
}

export interface CodexTurnCompletedParams {
  threadId: string;
  turn: CodexTurn;
}

export interface CodexItemStartedParams {
  item: CodexThreadItem;
  threadId: string;
  turnId: string;
}

export interface CodexItemCompletedParams {
  item: CodexThreadItem;
  threadId: string;
  turnId: string;
}

/** agentMessage / commandExecution 输出 / reasoning 三种增量共用的形状 */
export interface CodexItemDeltaParams {
  threadId: string;
  turnId: string;
  itemId: string;
  delta: string;
}

export interface CodexFileChangePatchUpdatedParams {
  threadId: string;
  turnId: string;
  itemId: string;
  changes: CodexFileUpdateChange[];
}

export type CodexTurnPlanStepStatus = "pending" | "inProgress" | "completed";

export interface CodexTurnPlanStep {
  step: string;
  status: CodexTurnPlanStepStatus;
}

export interface CodexTurnPlanUpdatedParams {
  threadId: string;
  turnId: string;
  plan: CodexTurnPlanStep[];
}

export interface CodexTokenUsageBreakdown {
  totalTokens: number;
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
  reasoningOutputTokens: number;
}

export interface CodexThreadTokenUsageUpdatedParams {
  threadId: string;
  turnId: string;
  tokenUsage: {
    total: CodexTokenUsageBreakdown;
    last: CodexTokenUsageBreakdown;
  };
}

export interface CodexErrorParams {
  error: {
    message: string;
    additionalDetails: string | null;
  };
  willRetry: boolean;
  threadId: string;
  turnId: string;
}

export interface CodexServerRequestResolvedParams {
  threadId: string;
  requestId: CodexRequestId;
}

// MARK: - 服务端请求（审批）

export interface CodexCommandExecutionRequestApprovalParams {
  threadId: string;
  turnId: string;
  itemId: string;
  startedAtMs: number;
  command?: string | null;
  cwd?: string | null;
  reason?: string | null;
  proposedExecpolicyAmendment?: CodexExecPolicyAmendment | null;
  proposedNetworkPolicyAmendments?: CodexNetworkPolicyAmendment[] | null;
  /** 生成物里没有、线上有：本次真正可用的裁决 */
  availableDecisions?: CodexCommandExecutionApprovalDecision[] | null;
}

export interface CodexFileChangeRequestApprovalParams {
  threadId: string;
  turnId: string;
  itemId: string;
  startedAtMs: number;
  reason?: string | null;
  grantRoot?: string | null;
  availableDecisions?: CodexFileChangeApprovalDecision[] | null;
}

export interface CodexPermissionsRequestApprovalParams {
  threadId: string;
  turnId: string;
  itemId: string;
  startedAtMs: number;
  cwd: string;
  reason: string | null;
  permissions: {
    network?: unknown;
    fileSystem?: unknown;
  };
}

export interface CodexToolRequestUserInputParams {
  threadId: string;
  turnId: string | null;
  itemId: string;
  questions: Array<{ prompt?: string }>;
}

export interface CodexMcpElicitationRequestParams {
  threadId: string;
  turnId: string | null;
  serverName: string;
  message: string;
}

/** 旧版审批，conversationId 而不是 threadId，command 是 argv 数组 */
export interface CodexExecCommandApprovalParams {
  conversationId: string;
  callId: string;
  command: string[];
  cwd: string;
  reason: string | null;
}

export interface CodexApplyPatchApprovalParams {
  conversationId: string;
  callId: string;
  fileChanges: Record<string, unknown>;
  reason: string | null;
  grantRoot: string | null;
}

/** adapter 需要应答的全部服务端请求方法 */
export const CODEX_SERVER_REQUEST_METHODS = [
  "item/commandExecution/requestApproval",
  "item/fileChange/requestApproval",
  "item/permissions/requestApproval",
  "item/tool/requestUserInput",
  "mcpServer/elicitation/request",
  "execCommandApproval",
  "applyPatchApproval",
] as const;

export type CodexServerRequestMethod =
  (typeof CODEX_SERVER_REQUEST_METHODS)[number];

export function isCodexServerRequestMethod(
  method: string,
): method is CodexServerRequestMethod {
  return (CODEX_SERVER_REQUEST_METHODS as readonly string[]).includes(method);
}

// MARK: - 客户端请求

export type CodexSandboxMode =
  | "read-only"
  | "workspace-write"
  | "danger-full-access";

export type CodexAskForApproval = "untrusted" | "on-request" | "never";

export interface CodexThreadStartParams {
  cwd: string;
  approvalPolicy: CodexAskForApproval;
  sandbox: CodexSandboxMode;
  model?: string;
}

export interface CodexThreadResumeParams {
  threadId: string;
  cwd: string;
  approvalPolicy: CodexAskForApproval;
  sandbox: CodexSandboxMode;
  model?: string;
}

export interface CodexTurnStartParams {
  threadId: string;
  input: CodexUserInput[];
}

/** expectedTurnId 对不上会被拒，所以 adapter 必须自己盯住当前 turnId */
export interface CodexTurnSteerParams {
  threadId: string;
  expectedTurnId: string;
  input: CodexUserInput[];
}

export interface CodexTurnInterruptParams {
  threadId: string;
  turnId: string;
}
