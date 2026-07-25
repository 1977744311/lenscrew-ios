// E2EE 通道与会话总线之间的粘合层。SecureChannelHost 只管帧与密钥,
// SessionHub 只管 agent 会话;通道内跑什么协议、hub 事件怎么下发到每台手机,
// 全在这一层。relay 客户端与本地 /e2ee 端点共用同一个实例——
// 传输路径只负责搬帧,每次 handleFrame 把「怎么把帧送回这台手机」作为 sink 传进来。

import { chmodSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { SecureChannelHost, type HostFrame, type PairingWindow } from "./channel.ts";
import { loadTrustedPhones, saveTrustedPhones, type BridgeIdentity } from "../state/stateDir.ts";
import type { AgentSession, BridgeEvent, ClientCommand } from "../protocol/events.ts";

/** 把一个出站帧送回某台 phone 的传输回调,由各传输路径在 handleFrame 时注入 */
export type FrameSink = (frame: HostFrame) => void;

/**
 * gateway 只依赖 hub 的这四个能力,结构化声明而不是直接引 SessionHub,
 * 测试就能用最小 stub 顶上。真 SessionHub 天然满足。
 */
export interface GatewayHub {
  onEvent(listener: (event: BridgeEvent) => void): () => void;
  handle(command: ClientCommand): Promise<void>;
  replay(sessionId: string, fromSeq: number): BridgeEvent[];
  listSessions(): AgentSession[];
}

export interface SecureGatewayOptions {
  hub: GatewayHub;
  identity: BridgeIdentity;
  /** trusted-phones.json 与 push-tokens.json 都落在这里 */
  stateDir: string;
  displayName: string;
  pairingWindow: PairingWindow;
  now?: () => number;
}

// MARK: - 通道内协议(明文层,双方向都是单行 JSON)
//
// phone → mac:
//   { t: "cmd", id, data: <ClientCommand> }
//   { t: "push-register", deviceToken, environment, alertsEnabled }
// mac → phone:
//   { t: "reply", id, ok: true, events? }   cmd 的应答,subscribe 附带补发事件
//   { t: "reply", id, ok: false, error }
//   { t: "event", data: <BridgeEvent> }     hub 事件广播 + 会话快照

const PUSH_TOKENS_FILE = "push-tokens.json";

export interface PushTokenRecord {
  deviceToken: string;
  environment: string;
  alertsEnabled: boolean;
  updatedAtMs: number;
}

/** key 是 phoneDeviceId;APNs 发送端(并行任务)按此结构消费 */
export type PushTokens = Record<string, PushTokenRecord>;

export function loadPushTokens(dir: string): PushTokens {
  const path = join(dir, PUSH_TOKENS_FILE);
  if (!existsSync(path)) return {};
  return JSON.parse(readFileSync(path, "utf8")) as PushTokens;
}

export class SecureGateway {
  readonly #host: SecureChannelHost;
  readonly #hub: GatewayHub;
  readonly #stateDir: string;
  readonly #now: () => number;
  readonly #unsubscribe: () => void;
  /** 每台已握手 phone 最近一次使用的传输路径,hub 事件经它下发 */
  readonly #transports = new Map<string, FrameSink>();

  constructor(options: SecureGatewayOptions) {
    this.#hub = options.hub;
    this.#stateDir = options.stateDir;
    this.#now = options.now ?? Date.now;
    this.#host = new SecureChannelHost({
      identity: options.identity,
      trustedPhones: {
        load: () => loadTrustedPhones(options.stateDir),
        save: (phones) => saveTrustedPhones(options.stateDir, phones),
      },
      displayName: options.displayName,
      pairingWindow: options.pairingWindow,
      now: this.#now,
    });
    this.#unsubscribe = this.#hub.onEvent((event) => this.#broadcast(event));
  }

  /** 传输路径的唯一入口:入站帧 + 「回帧走哪」 */
  handleFrame(frame: unknown, sink: FrameSink): void {
    this.#host.handleFrame(frame, {
      send: sink,
      onSessionReady: (phoneDeviceId) => {
        this.#transports.set(phoneDeviceId, sink);
        this.#sendSnapshot(phoneDeviceId, sink);
      },
      onMessage: (phoneDeviceId, plaintext) => {
        // phone 可能换传输路径(局域网↔relay),以最近一次来包的路径为准
        this.#transports.set(phoneDeviceId, sink);
        void this.#handleMessage(phoneDeviceId, plaintext, sink);
      },
    });
  }

  hasEstablishedSession(phoneDeviceId: string): boolean {
    return this.#host.hasEstablishedSession(phoneDeviceId);
  }

  close(): void {
    this.#unsubscribe();
    this.#transports.clear();
  }

  /** 与 /events 首连等价:每个已有会话补一条 seq=0 的 sessionCreated 快照 */
  #sendSnapshot(phoneDeviceId: string, sink: FrameSink): void {
    for (const session of this.#hub.listSessions()) {
      this.#sendToPhone(phoneDeviceId, sink, {
        t: "event",
        data: { type: "sessionCreated", seq: 0, session },
      });
    }
  }

  #broadcast(event: BridgeEvent): void {
    for (const [phoneDeviceId, sink] of this.#transports) {
      if (!this.#host.hasEstablishedSession(phoneDeviceId)) {
        this.#transports.delete(phoneDeviceId);
        continue;
      }
      this.#sendToPhone(phoneDeviceId, sink, { t: "event", data: event });
    }
  }

  async #handleMessage(phoneDeviceId: string, plaintext: string, sink: FrameSink): Promise<void> {
    let message: Record<string, unknown>;
    try {
      const parsed = JSON.parse(plaintext) as unknown;
      if (typeof parsed !== "object" || parsed === null) return;
      message = parsed as Record<string, unknown>;
    } catch {
      // 解析不了就无从得知 id,没法回 reply,只能丢弃
      return;
    }

    if (message["t"] === "cmd") {
      await this.#handleCommand(phoneDeviceId, sink, message);
      return;
    }
    if (message["t"] === "push-register") {
      this.#handlePushRegister(phoneDeviceId, message);
      return;
    }
  }

  async #handleCommand(
    phoneDeviceId: string,
    sink: FrameSink,
    message: Record<string, unknown>,
  ): Promise<void> {
    const id = message["id"];
    try {
      const command = message["data"] as ClientCommand;
      if (typeof command !== "object" || command === null) {
        throw new Error("cmd.data must be a ClientCommand object");
      }
      if (command.type === "subscribe") {
        // 与 /command 相同:subscribe 不进 hub.handle,直接补发断档
        this.#sendToPhone(phoneDeviceId, sink, {
          t: "reply",
          id,
          ok: true,
          events: this.#hub.replay(command.sessionId, command.fromSeq),
        });
        return;
      }
      await this.#hub.handle(command);
      this.#sendToPhone(phoneDeviceId, sink, { t: "reply", id, ok: true });
    } catch (error) {
      this.#sendToPhone(phoneDeviceId, sink, { t: "reply", id, ok: false, error: String(error) });
    }
  }

  #handlePushRegister(phoneDeviceId: string, message: Record<string, unknown>): void {
    const deviceToken = message["deviceToken"];
    if (typeof deviceToken !== "string" || deviceToken.length === 0) return;
    const environment = message["environment"];
    const alertsEnabled = message["alertsEnabled"];
    const tokens = loadPushTokens(this.#stateDir);
    tokens[phoneDeviceId] = {
      deviceToken,
      environment: typeof environment === "string" && environment.length > 0 ? environment : "production",
      alertsEnabled: typeof alertsEnabled === "boolean" ? alertsEnabled : true,
      updatedAtMs: this.#now(),
    };
    const path = join(this.#stateDir, PUSH_TOKENS_FILE);
    writeFileSync(path, `${JSON.stringify(tokens, null, 2)}\n`, { mode: 0o600 });
    // mode 只在新建时生效,覆盖后要重新收紧
    chmodSync(path, 0o600);
  }

  #sendToPhone(phoneDeviceId: string, sink: FrameSink, payload: unknown): void {
    let frame: HostFrame;
    try {
      frame = this.#host.sendSecure(phoneDeviceId, JSON.stringify(payload));
    } catch {
      // 会话已被顶替/断开,该 phone 重新握手后会拿到快照,这里不值得报错
      this.#transports.delete(phoneDeviceId);
      return;
    }
    sink(frame);
  }
}
