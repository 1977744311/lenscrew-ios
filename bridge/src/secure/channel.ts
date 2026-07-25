// mac 侧 E2EE 握手状态机。纯逻辑:不碰网络与磁盘,收发帧、信任表读写、
// 时钟、配对窗口全部由调用方注入,relay/本地端点(下一个任务)只负责搬运帧。
//
// 协议流(每个 phone 独立):
//   phone→ clientHello ──校验版本/配对窗口/信任表──→ ←serverHello(mac 签 transcript)
//   phone→ clientAuth(phone 签 transcript‖"client-auth")──验签──→ ←secureReady
//   之后双向 encryptedEnvelope,counter 单调防重放。

import { randomBytes } from "node:crypto";

import {
  buildClientAuthMessage,
  buildTranscript,
  deriveKeys,
  generateX25519KeyPairRaw,
  openEnvelope,
  sealEnvelope,
  signTranscript,
  verifyTranscript,
  x25519SharedSecret,
  type EncryptedEnvelope,
} from "./crypto.ts";
import type { BridgeIdentity, TrustedPhones } from "../state/stateDir.ts";

export const SECURE_PROTOCOL_VERSION = 1;

// MARK: - 帧类型

export type HandshakeMode = "qr_bootstrap" | "trusted_reconnect";

export interface ClientHelloFrame {
  kind: "clientHello";
  protocolVersion: number;
  roomId: string;
  handshakeMode: HandshakeMode;
  phoneDeviceId: string;
  /** Ed25519 raw 32B base64 */
  phoneIdentityPublicKey: string;
  /** X25519 raw 32B base64 */
  phoneEphemeralPublicKey: string;
  clientNonce: string;
}

export interface ServerHelloFrame {
  kind: "serverHello";
  protocolVersion: number;
  roomId: string;
  handshakeMode: HandshakeMode;
  macDeviceId: string;
  macIdentityPublicKey: string;
  macEphemeralPublicKey: string;
  serverNonce: string;
  keyEpoch: number;
  /** qr_bootstrap = 配对窗口截止时刻;trusted_reconnect 恒为 0 */
  pairingExpiresAtMs: number;
  /** mac 对 transcript 的 Ed25519 签名 base64 */
  macSignature: string;
  /** 原样回显,phone 据此把响应对回自己的请求 */
  clientNonce: string;
  displayName: string;
}

export interface ClientAuthFrame {
  kind: "clientAuth";
  roomId: string;
  phoneDeviceId: string;
  keyEpoch: number;
  /** phone 对 transcript‖lengthPrefixed("client-auth") 的 Ed25519 签名 base64 */
  phoneSignature: string;
}

export interface SecureReadyFrame {
  kind: "secureReady";
  roomId: string;
  keyEpoch: number;
  macDeviceId: string;
}

export type SecureErrorCode =
  | "protocol_mismatch"
  | "pairing_expired"
  | "phone_not_trusted"
  | "phone_identity_changed"
  | "invalid_signature"
  | "decrypt_failed"
  | "unexpected_frame";

export interface SecureErrorFrame {
  kind: "secureError";
  code: SecureErrorCode;
  message: string;
}

export type HostFrame = ServerHelloFrame | SecureReadyFrame | SecureErrorFrame | EncryptedEnvelope;

// MARK: - 注入依赖

export interface TrustedPhonesStore {
  load(): TrustedPhones;
  save(phones: TrustedPhones): void;
}

export interface PairingWindow {
  isOpen(): boolean;
  /** serverHello 的 pairingExpiresAtMs 要回窗口截止时刻,所以除 isOpen 外还需要它 */
  expiresAtMs(): number;
}

export interface SecureChannelHostOptions {
  identity: BridgeIdentity;
  trustedPhones: TrustedPhonesStore;
  displayName: string;
  pairingWindow: PairingWindow;
  now: () => number;
}

/** 每次 handleFrame 注入,而不是构造时绑定:同一状态机可服务多条传输路径 */
export interface SecureChannelIo {
  send(frame: HostFrame): void;
  onSessionReady?(phoneDeviceId: string): void;
  onMessage?(phoneDeviceId: string, plaintext: string): void;
}

// MARK: - 会话状态

interface PendingSession {
  phase: "pending";
  roomId: string;
  handshakeMode: HandshakeMode;
  keyEpoch: number;
  phoneIdentityPublicKey: string;
  transcript: Buffer;
  sharedSecret: Buffer;
}

interface EstablishedSession {
  phase: "established";
  roomId: string;
  keyEpoch: number;
  keyPhoneToMac: Buffer;
  keyMacToPhone: Buffer;
  /** mac→phone 已用到的 counter,发送前自增,首帧为 1 */
  outboundCounter: number;
  /** phone→mac 已接受的最大 counter,重放判定基准 */
  lastInboundCounter: number;
  replayDropCount: number;
}

type PhoneSession = PendingSession | EstablishedSession;

function secureError(code: SecureErrorCode, message: string): SecureErrorFrame {
  return { kind: "secureError", code, message };
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function decodeBase64Exact(value: string, expectedLength: number): Buffer | null {
  const buf = Buffer.from(value, "base64");
  return buf.length === expectedLength ? buf : null;
}

export class SecureChannelHost {
  #identity: BridgeIdentity;
  #identitySeed: Buffer;
  #trustedPhones: TrustedPhonesStore;
  #displayName: string;
  #pairingWindow: PairingWindow;
  #now: () => number;

  /** key = phoneDeviceId;同一 phone 只保留一个会话,新 clientHello 顶替旧的 */
  #sessions = new Map<string, PhoneSession>();
  /** encryptedEnvelope 只带 roomId,靠它反查 phone */
  #roomToPhone = new Map<string, string>();
  /** per-phone 单调递增,进程内存即可:epoch 只需在 mac 存活期内不回退 */
  #keyEpochs = new Map<string, number>();

  constructor(options: SecureChannelHostOptions) {
    this.#identity = options.identity;
    this.#identitySeed = Buffer.from(options.identity.identityPrivateKey, "base64");
    this.#trustedPhones = options.trustedPhones;
    this.#displayName = options.displayName;
    this.#pairingWindow = options.pairingWindow;
    this.#now = options.now;
  }

  handleFrame(frame: unknown, io: SecureChannelIo): void {
    if (typeof frame !== "object" || frame === null) {
      io.send(secureError("unexpected_frame", "frame must be a JSON object"));
      return;
    }
    const f = frame as Record<string, unknown>;
    switch (f["kind"]) {
      case "clientHello":
        this.#handleClientHello(f, io);
        return;
      case "clientAuth":
        this.#handleClientAuth(f, io);
        return;
      case "encryptedEnvelope":
        this.#handleEnvelope(f, io);
        return;
      default:
        io.send(secureError("unexpected_frame", `unknown frame kind: ${String(f["kind"])}`));
    }
  }

  /** 密文只出不进 socket:调用方拿到信封后自己发。返回值即要发送的帧 */
  sendSecure(phoneDeviceId: string, plaintext: string): EncryptedEnvelope {
    const session = this.#sessions.get(phoneDeviceId);
    if (session === undefined || session.phase !== "established") {
      throw new Error(`no established secure session for phone ${phoneDeviceId}`);
    }
    session.outboundCounter += 1;
    return sealEnvelope({
      key: session.keyMacToPhone,
      roomId: session.roomId,
      keyEpoch: session.keyEpoch,
      sender: "mac",
      counter: session.outboundCounter,
      plaintext,
    });
  }

  hasEstablishedSession(phoneDeviceId: string): boolean {
    return this.#sessions.get(phoneDeviceId)?.phase === "established";
  }

  /** 重放丢弃不回帧(防放大),测试与日志经此观测 */
  replayDropCount(phoneDeviceId: string): number {
    const session = this.#sessions.get(phoneDeviceId);
    return session?.phase === "established" ? session.replayDropCount : 0;
  }

  #handleClientHello(f: Record<string, unknown>, io: SecureChannelIo): void {
    if (f["protocolVersion"] !== SECURE_PROTOCOL_VERSION) {
      io.send(
        secureError(
          "protocol_mismatch",
          `unsupported protocolVersion ${String(f["protocolVersion"])}, expected ${SECURE_PROTOCOL_VERSION}`,
        ),
      );
      return;
    }
    const handshakeMode = f["handshakeMode"];
    if (handshakeMode !== "qr_bootstrap" && handshakeMode !== "trusted_reconnect") {
      io.send(secureError("unexpected_frame", "clientHello has invalid handshakeMode"));
      return;
    }
    const roomId = f["roomId"];
    const phoneDeviceId = f["phoneDeviceId"];
    const phoneIdentityPublicKey = f["phoneIdentityPublicKey"];
    const phoneEphemeralPublicKey = f["phoneEphemeralPublicKey"];
    const clientNonce = f["clientNonce"];
    if (
      !isNonEmptyString(roomId) ||
      !isNonEmptyString(phoneDeviceId) ||
      !isNonEmptyString(phoneIdentityPublicKey) ||
      !isNonEmptyString(phoneEphemeralPublicKey) ||
      !isNonEmptyString(clientNonce)
    ) {
      io.send(secureError("unexpected_frame", "clientHello is missing required fields"));
      return;
    }
    if (decodeBase64Exact(phoneIdentityPublicKey, 32) === null) {
      io.send(secureError("unexpected_frame", "phoneIdentityPublicKey must be 32 bytes base64"));
      return;
    }
    const phoneEphemeralRaw = decodeBase64Exact(phoneEphemeralPublicKey, 32);
    if (phoneEphemeralRaw === null) {
      io.send(secureError("unexpected_frame", "phoneEphemeralPublicKey must be 32 bytes base64"));
      return;
    }

    if (handshakeMode === "qr_bootstrap" && !this.#pairingWindow.isOpen()) {
      io.send(secureError("pairing_expired", "pairing window is closed, rescan a fresh QR code"));
      return;
    }
    if (handshakeMode === "trusted_reconnect") {
      const trusted = this.#trustedPhones.load()[phoneDeviceId];
      if (trusted === undefined) {
        io.send(secureError("phone_not_trusted", `phone ${phoneDeviceId} is not paired with this Mac`));
        return;
      }
      if (trusted.identityPublicKey !== phoneIdentityPublicKey) {
        // 身份公钥变了要么是重装未迁移、要么是冒名——都必须重新走二维码配对
        io.send(
          secureError("phone_identity_changed", `phone ${phoneDeviceId} identity key changed, re-pair via QR`),
        );
        return;
      }
    }

    const keyEpoch = (this.#keyEpochs.get(phoneDeviceId) ?? 0) + 1;
    this.#keyEpochs.set(phoneDeviceId, keyEpoch);
    const ephemeral = generateX25519KeyPairRaw();
    const serverNonce = randomBytes(32).toString("base64");
    const macEphemeralPublicKey = ephemeral.publicKeyRaw.toString("base64");
    const pairingExpiresAtMs = handshakeMode === "qr_bootstrap" ? this.#pairingWindow.expiresAtMs() : 0;

    const transcript = buildTranscript({
      roomId,
      protocolVersion: SECURE_PROTOCOL_VERSION,
      handshakeMode,
      keyEpoch,
      macDeviceId: this.#identity.macDeviceId,
      phoneDeviceId,
      macIdentityPublicKey: this.#identity.identityPublicKey,
      phoneIdentityPublicKey,
      macEphemeralPublicKey,
      phoneEphemeralPublicKey,
      clientNonce,
      serverNonce,
      pairingExpiresAtMs,
    });

    // 顶替旧会话:先摘掉旧 roomId 的路由,防止旧房间的密文串到新会话
    const previous = this.#sessions.get(phoneDeviceId);
    if (previous !== undefined) {
      this.#roomToPhone.delete(previous.roomId);
    }
    this.#sessions.set(phoneDeviceId, {
      phase: "pending",
      roomId,
      handshakeMode,
      keyEpoch,
      phoneIdentityPublicKey,
      transcript,
      sharedSecret: x25519SharedSecret(ephemeral.privateKeyRaw, phoneEphemeralRaw),
    });
    this.#roomToPhone.set(roomId, phoneDeviceId);

    io.send({
      kind: "serverHello",
      protocolVersion: SECURE_PROTOCOL_VERSION,
      roomId,
      handshakeMode,
      macDeviceId: this.#identity.macDeviceId,
      macIdentityPublicKey: this.#identity.identityPublicKey,
      macEphemeralPublicKey,
      serverNonce,
      keyEpoch,
      pairingExpiresAtMs,
      macSignature: signTranscript(this.#identitySeed, transcript).toString("base64"),
      clientNonce,
      displayName: this.#displayName,
    });
  }

  #handleClientAuth(f: Record<string, unknown>, io: SecureChannelIo): void {
    const roomId = f["roomId"];
    const phoneDeviceId = f["phoneDeviceId"];
    const keyEpoch = f["keyEpoch"];
    const phoneSignature = f["phoneSignature"];
    if (
      !isNonEmptyString(roomId) ||
      !isNonEmptyString(phoneDeviceId) ||
      typeof keyEpoch !== "number" ||
      !isNonEmptyString(phoneSignature)
    ) {
      io.send(secureError("unexpected_frame", "clientAuth is missing required fields"));
      return;
    }
    const session = this.#sessions.get(phoneDeviceId);
    if (
      session === undefined ||
      session.phase !== "pending" ||
      session.roomId !== roomId ||
      session.keyEpoch !== keyEpoch
    ) {
      io.send(secureError("unexpected_frame", "clientAuth does not match a pending handshake"));
      return;
    }

    const verified = verifyTranscript(
      Buffer.from(session.phoneIdentityPublicKey, "base64"),
      buildClientAuthMessage(session.transcript),
      Buffer.from(phoneSignature, "base64"),
    );
    if (!verified) {
      this.#dropSession(phoneDeviceId);
      io.send(secureError("invalid_signature", "clientAuth signature verification failed"));
      return;
    }

    const keys = deriveKeys({
      sharedSecret: session.sharedSecret,
      transcript: session.transcript,
      roomId,
      macDeviceId: this.#identity.macDeviceId,
      phoneDeviceId,
      keyEpoch,
    });
    this.#sessions.set(phoneDeviceId, {
      phase: "established",
      roomId,
      keyEpoch,
      keyPhoneToMac: keys.phoneToMac,
      keyMacToPhone: keys.macToPhone,
      outboundCounter: 0,
      lastInboundCounter: 0,
      replayDropCount: 0,
    });

    if (session.handshakeMode === "qr_bootstrap") {
      // 验签通过才算配对完成;这时才把 phone 写进信任表,之后可走 trusted_reconnect
      const phones = this.#trustedPhones.load();
      const previous = phones[phoneDeviceId];
      phones[phoneDeviceId] = {
        identityPublicKey: session.phoneIdentityPublicKey,
        ...(previous?.name !== undefined ? { name: previous.name } : {}),
        addedAtMs: this.#now(),
      };
      this.#trustedPhones.save(phones);
    }

    io.send({ kind: "secureReady", roomId, keyEpoch, macDeviceId: this.#identity.macDeviceId });
    io.onSessionReady?.(phoneDeviceId);
  }

  #handleEnvelope(f: Record<string, unknown>, io: SecureChannelIo): void {
    const roomId = f["roomId"];
    const counter = f["counter"];
    if (
      f["v"] !== 1 ||
      f["sender"] !== "phone" ||
      !isNonEmptyString(roomId) ||
      typeof f["keyEpoch"] !== "number" ||
      typeof counter !== "number" ||
      !Number.isSafeInteger(counter) ||
      counter < 1 ||
      !isNonEmptyString(f["ciphertext"]) ||
      !isNonEmptyString(f["tag"])
    ) {
      io.send(secureError("unexpected_frame", "malformed encryptedEnvelope"));
      return;
    }
    const phoneDeviceId = this.#roomToPhone.get(roomId);
    const session = phoneDeviceId === undefined ? undefined : this.#sessions.get(phoneDeviceId);
    if (phoneDeviceId === undefined || session === undefined || session.phase !== "established") {
      io.send(secureError("unexpected_frame", `no established session for room ${roomId}`));
      return;
    }

    if (counter <= session.lastInboundCounter) {
      // 重放/乱序旧帧:静默丢弃只计数,回错误帧会给攻击者免费的放大器
      session.replayDropCount += 1;
      return;
    }

    let plaintext: string;
    try {
      plaintext = openEnvelope({ key: session.keyPhoneToMac, envelope: f as unknown as EncryptedEnvelope });
    } catch {
      // 认证失败说明密钥失同步或有人篡改,会话已不可信:断开,逼 phone 重新握手
      this.#dropSession(phoneDeviceId);
      io.send(secureError("decrypt_failed", "envelope authentication failed, session dropped"));
      return;
    }
    session.lastInboundCounter = counter;
    io.onMessage?.(phoneDeviceId, plaintext);
  }

  #dropSession(phoneDeviceId: string): void {
    const session = this.#sessions.get(phoneDeviceId);
    if (session !== undefined) {
      this.#roomToPhone.delete(session.roomId);
      this.#sessions.delete(phoneDeviceId);
    }
  }
}
