import type {
  AgentCapabilities,
  AgentKind,
  ApprovalOutcome,
  ApprovalRequest,
  SessionMode,
  SessionStatus,
  TranscriptBlock,
  TranscriptBlockPatch,
} from "../protocol/events.ts";

/**
 * adapter 发出的未编号事件。seq 由 SessionHub 统一分配，adapter 不关心编号,
 * 这样 normalizer 可以是纯函数、能直接对着 protocol/fixtures/ 做单测。
 */
export type AdapterEvent =
  | { type: "nativeIdAssigned"; nativeId: string }
  | { type: "modelResolved"; model: string }
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
    }
  | { type: "error"; message: string; fatal: boolean };

/**
 * 原生协议消息 → 统一事件的纯翻译器。
 *
 * 拆成纯函数是为了能脱离进程和网络做单测：三个运行时的真实输出录在
 * protocol/fixtures/ 里，normalizer 喂进去应当得到确定的事件序列。
 * 进程拉起、stdio 分帧、请求应答这些副作用留在 AgentAdapter 实现里。
 */
export interface ProtocolNormalizer<TMessage> {
  /** 一条原生消息可能翻译成 0 到多个统一事件 */
  normalize(message: TMessage): AdapterEvent[];
}

export interface AdapterStartOptions {
  workspaceRoot: string;
  model: string | null;
  mode: SessionMode;
  /** 续接已有会话；null 表示开新会话 */
  resumeNativeId: string | null;
}

export interface AgentAdapter {
  readonly kind: AgentKind;
  readonly capabilities: AgentCapabilities;

  start(options: AdapterStartOptions): Promise<void>;
  sendMessage(text: string): Promise<void>;
  interrupt(): Promise<void>;
  /**
   * 把审批裁决回送给运行时。capabilities.approvals 为 false 的 adapter
   * 收到本调用应当抛错而不是静默吞掉——静默吞掉会让手机端以为批准生效了。
   */
  resolveApproval(approvalId: string, optionId: string): Promise<void>;
  close(): Promise<void>;
}

export type AdapterEventSink = (event: AdapterEvent) => void;
