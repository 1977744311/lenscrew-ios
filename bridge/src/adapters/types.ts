import type {
  AgentCapabilities,
  AgentKind,
  AgentQuotaSnapshot,
  ApprovalOutcome,
  ApprovalRequest,
  SessionModelOption,
  SessionModeOption,
  SessionStatus,
  TranscriptBlock,
  TranscriptBlockPatch,
  TurnStopReason,
} from "../protocol/events.ts";

/**
 * adapter 发出的未编号事件。seq 由 SessionHub 统一分配，adapter 不关心编号,
 * 这样 normalizer 可以是纯函数、能直接对着 protocol/fixtures/ 做单测。
 */
export type AdapterEvent =
  | { type: "nativeIdAssigned"; nativeId: string }
  | { type: "modelResolved"; model: string }
  /** 运行时可能在 turn 中途给会话改名（ACP 实测第一条 update 就会） */
  | { type: "titleResolved"; title: string }
  /** start() 之后真实能力才确定，adapter 用它把修正后的能力发出来 */
  | { type: "capabilitiesResolved" }
  | { type: "status"; status: SessionStatus }
  | { type: "blockAppended"; block: TranscriptBlock }
  | { type: "blockUpdated"; blockId: string; patch: TranscriptBlockPatch }
  | { type: "approvalRequested"; approval: ApprovalRequest }
  | {
      type: "approvalSettled";
      approvalId: string;
      optionId: string | null;
      outcome: ApprovalOutcome;
    }
  | {
      type: "turnCompleted";
      inputTokens: number | null;
      outputTokens: number | null;
      cachedInputTokens: number | null;
      stopReason: TurnStopReason | null;
    }
  /**
   * 账号级额度快照（可能只含部分桶——codex 的 updated 通知是稀疏的）。
   * SessionHub 不给它编号也不进会话日志，而是并入 host 级缓存后另行广播。
   */
  | { type: "quotaUpdated"; quota: AgentQuotaSnapshot }
  /** 运行时回显的当前模式（claude 的 system/status、cursor 的 current_mode_update） */
  | { type: "modeResolved"; modeId: string }
  /** 运行时自陈的可用模式清单（cursor 的 session/new 响应），覆盖 adapter 的静态表 */
  | { type: "modesResolved"; modes: SessionModeOption[] }
  /** 运行时自陈的可用模型清单（claude init / cursor session/new / codex model/list） */
  | { type: "modelsResolved"; models: SessionModelOption[] }
  /** 运行时回显的当前推理档（codex 的 thread/resume 响应或切换后自发） */
  | { type: "reasoningEffortResolved"; effort: string }
  | { type: "error"; message: string; fatal: boolean };

/**
 * 原生协议消息 → 统一事件的翻译器。
 *
 * 不做 I/O，且对消息序列确定：同样的消息序列必然得到同样的事件序列，
 * 因此可以脱离进程和网络，直接拿 protocol/fixtures/ 里录的真实输出做单测。
 *
 * 注意它**不是无状态的**——三个运行时的增量消息都不带块 id、
 * JSON-RPC 响应也不带方法名，翻译必须记住前文。
 * 进程拉起、stdio 分帧、请求应答这些副作用留在 AgentAdapter 实现里。
 */
export interface ProtocolNormalizer<TMessage> {
  /** 一条原生消息可能翻译成 0 到多个统一事件 */
  normalize(message: TMessage): AdapterEvent[];
}

export interface AdapterStartOptions {
  workspaceRoot: string;
  model: string | null;
  /** 见 SessionModeOption.id；null 用 adapter 的缺省档 */
  modeId: string | null;
  /** 推理档；null 跟随 CLI 默认（仅 codex 消费） */
  reasoningEffort: string | null;
  /** 续接已有会话；null 表示开新会话 */
  resumeNativeId: string | null;
}

/**
 * 事件出口由构造函数注入（`AdapterEventSink`），方法签名里看不到——
 * 实现新 adapter 时别漏。
 */
export interface AgentAdapter {
  readonly kind: AgentKind;
  /**
   * **start() resolve 之前不可信**：几个运行时的真实能力取决于启动参数或握手结果
   * （claude 的 approvals 看启动时带不带权限 flag，cursor 的 resume 要等 ACP 自陈）。
   * 修正后的能力由 SessionHub 在 start() 之后统一发一条快照出去，
   * adapter **不要**自己再发 `capabilitiesResolved`，否则会多广播一次。
   */
  readonly capabilities: AgentCapabilities;
  /** 可选模式清单（静态自陈；cursor 运行中自陈更新经 modesResolved 事件） */
  readonly modes: SessionModeOption[];
  /** 创建时未指定 modeId 的缺省档；无模式概念时为 null */
  readonly defaultModeId: string | null;
  /** 当前生效的模式；hub 用它填会话快照初值 */
  readonly currentModeId: string | null;

  start(options: AdapterStartOptions): Promise<void>;
  /**
   * 消息被运行时接收即返回，**不等这一轮跑完**。
   * 不这样定的话，手机上点一次发送要等整轮结束才拿到回执。
   */
  sendMessage(text: string): Promise<void>;
  interrupt(): Promise<void>;
  /**
   * 把审批裁决回送给运行时。capabilities.approvals 为 false 的 adapter
   * 收到本调用应当抛错而不是静默吞掉——静默吞掉会让手机端以为批准生效了。
   */
  resolveApproval(approvalId: string, optionId: string): Promise<void>;
  /**
   * 会话中切换模式。生效后 adapter 发 `modeResolved` 回显；
   * 未知 modeId 抛错并把合法取值写进错误信息。
   */
  setMode(modeId: string): Promise<void>;
  /** 会话中切换模型。生效后 adapter 发 `modelResolved` 回显 */
  setModel(modelId: string): Promise<void>;
  /** 会话中切换推理档。不支持档位的运行时抛错说明原因 */
  setReasoningEffort(effort: string): Promise<void>;
  close(): Promise<void>;
}

export type AdapterEventSink = (event: AdapterEvent) => void;
