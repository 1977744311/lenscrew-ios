import test from "node:test";
import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { SecureGateway, loadPushTokens, type GatewayHub } from "../src/secure/secureGateway.ts";
import type {
  ClientAuthFrame,
  ClientHelloFrame,
  HostFrame,
  ServerHelloFrame,
} from "../src/secure/channel.ts";
import {
  buildClientAuthMessage,
  buildTranscript,
  deriveKeys,
  generateEd25519SeedKeyPair,
  generateX25519KeyPairRaw,
  openEnvelope,
  sealEnvelope,
  signTranscript,
  x25519SharedSecret,
  type DirectionalKeys,
  type EncryptedEnvelope,
} from "../src/secure/crypto.ts";
import type { BridgeIdentity } from "../src/state/stateDir.ts";
import type {
  AgentQuotaSnapshot,
  AgentSession,
  BridgeEvent,
  ClientCommand,
} from "../src/protocol/events.ts";

const NOW = 1700000000000;

// MARK: - 假 hub(按 GatewayHub 最小签名)

class FakeHub implements GatewayHub {
  readonly #listeners = new Set<(event: BridgeEvent) => void>();
  sessions: AgentSession[] = [];
  handled: ClientCommand[] = [];
  replayResult: BridgeEvent[] = [];
  replayCalls: Array<{ sessionId: string; fromSeq: number }> = [];
  failNextWith: string | null = null;

  onEvent(listener: (event: BridgeEvent) => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  async handle(command: ClientCommand): Promise<void> {
    if (this.failNextWith !== null) {
      const message = this.failNextWith;
      this.failNextWith = null;
      throw new Error(message);
    }
    this.handled.push(command);
  }

  replay(sessionId: string, fromSeq: number): BridgeEvent[] {
    this.replayCalls.push({ sessionId, fromSeq });
    return this.replayResult;
  }

  listSessions(): AgentSession[] {
    return this.sessions;
  }

  quota: AgentQuotaSnapshot[] = [];

  latestQuota(): AgentQuotaSnapshot[] {
    return this.quota;
  }

  emit(event: BridgeEvent): void {
    for (const listener of this.#listeners) listener(event);
  }
}

function sampleSession(id: string): AgentSession {
  return {
    id,
    agent: "codex",
    nativeId: null,
    workspaceRoot: "/tmp/ws",
    title: "测试会话",
    model: null,
    status: "idle",
    capabilities: {
      approvals: true,
      steering: true,
      interrupt: true,
      planMode: true,
      resume: true,
      streamingDeltas: true,
    },
    modeId: "default",
    modes: [{ id: "default", label: "默认", detail: "每步审批" }],
    createdAtMs: NOW,
    updatedAtMs: NOW,
  };
}

// MARK: - gateway 测试台

interface Harness {
  gateway: SecureGateway;
  hub: FakeHub;
  stateDir: string;
}

function createHarness(): Harness {
  const pair = generateEd25519SeedKeyPair();
  const identity: BridgeIdentity = {
    version: 1,
    macDeviceId: randomUUID(),
    identityPublicKey: pair.publicKeyRaw.toString("base64"),
    identityPrivateKey: pair.privateSeed.toString("base64"),
    createdAtMs: NOW,
  };
  const hub = new FakeHub();
  const stateDir = mkdtempSync(join(tmpdir(), "lenscrew-gateway-"));
  const gateway = new SecureGateway({
    hub,
    identity,
    stateDir,
    displayName: "Gateway Mac",
    pairingWindow: { isOpen: () => true, expiresAtMs: () => NOW + 300_000 },
    now: () => NOW,
  });
  return { gateway, hub, stateDir };
}

// MARK: - phone 侧参考实现(与 secure-channel.test.ts 同一套纯函数)

interface Phone {
  phoneDeviceId: string;
  roomId: string;
  identitySeed: Buffer;
  identityPublicKey: string;
  ephemeralPrivate: Buffer;
  ephemeralPublic: string;
  clientNonce: string;
  keys: DirectionalKeys | null;
  outboundCounter: number;
  /** 该 phone 的传输 sink 收到的全部出站帧 */
  frames: HostFrame[];
  sink: (frame: HostFrame) => void;
}

function createPhone(phoneDeviceId: string, roomId: string): Phone {
  const identityPair = generateEd25519SeedKeyPair();
  const ephemeral = generateX25519KeyPairRaw();
  const frames: HostFrame[] = [];
  return {
    phoneDeviceId,
    roomId,
    identitySeed: identityPair.privateSeed,
    identityPublicKey: identityPair.publicKeyRaw.toString("base64"),
    ephemeralPrivate: ephemeral.privateKeyRaw,
    ephemeralPublic: ephemeral.publicKeyRaw.toString("base64"),
    clientNonce: randomBytes(32).toString("base64"),
    keys: null,
    outboundCounter: 0,
    frames,
    sink: (frame) => frames.push(frame),
  };
}

function helloFrame(phone: Phone): ClientHelloFrame {
  return {
    kind: "clientHello",
    protocolVersion: 1,
    roomId: phone.roomId,
    handshakeMode: "qr_bootstrap",
    phoneDeviceId: phone.phoneDeviceId,
    phoneIdentityPublicKey: phone.identityPublicKey,
    phoneEphemeralPublicKey: phone.ephemeralPublic,
    clientNonce: phone.clientNonce,
  };
}

function phoneHandleServerHello(phone: Phone, serverHello: ServerHelloFrame): ClientAuthFrame {
  const transcript = buildTranscript({
    roomId: serverHello.roomId,
    protocolVersion: serverHello.protocolVersion,
    handshakeMode: serverHello.handshakeMode,
    keyEpoch: serverHello.keyEpoch,
    macDeviceId: serverHello.macDeviceId,
    phoneDeviceId: phone.phoneDeviceId,
    macIdentityPublicKey: serverHello.macIdentityPublicKey,
    phoneIdentityPublicKey: phone.identityPublicKey,
    macEphemeralPublicKey: serverHello.macEphemeralPublicKey,
    phoneEphemeralPublicKey: phone.ephemeralPublic,
    clientNonce: phone.clientNonce,
    serverNonce: serverHello.serverNonce,
    pairingExpiresAtMs: serverHello.pairingExpiresAtMs,
  });
  phone.keys = deriveKeys({
    sharedSecret: x25519SharedSecret(
      phone.ephemeralPrivate,
      Buffer.from(serverHello.macEphemeralPublicKey, "base64"),
    ),
    transcript,
    roomId: serverHello.roomId,
    macDeviceId: serverHello.macDeviceId,
    phoneDeviceId: phone.phoneDeviceId,
    keyEpoch: serverHello.keyEpoch,
  });
  return {
    kind: "clientAuth",
    roomId: serverHello.roomId,
    phoneDeviceId: phone.phoneDeviceId,
    keyEpoch: serverHello.keyEpoch,
    phoneSignature: signTranscript(phone.identitySeed, buildClientAuthMessage(transcript)).toString("base64"),
  };
}

function phoneKeys(phone: Phone): DirectionalKeys {
  assert.ok(phone.keys !== null, "phone 尚未完成握手");
  return phone.keys;
}

function phoneSeal(phone: Phone, plaintext: string): EncryptedEnvelope {
  phone.outboundCounter += 1;
  return sealEnvelope({
    key: phoneKeys(phone).phoneToMac,
    roomId: phone.roomId,
    keyEpoch: 1,
    sender: "phone",
    counter: phone.outboundCounter,
    plaintext,
  });
}

/** 解开该 phone sink 里全部 mac→phone 信封,返回明文 JSON 对象序列 */
function decryptedMessages(phone: Phone): Array<Record<string, unknown>> {
  return phone.frames
    .filter((frame): frame is EncryptedEnvelope => frame.kind === "encryptedEnvelope")
    .map((envelope) =>
      JSON.parse(openEnvelope({ key: phoneKeys(phone).macToPhone, envelope })) as Record<string, unknown>,
    );
}

function establish(h: Harness, phone: Phone): void {
  h.gateway.handleFrame(helloFrame(phone), phone.sink);
  const serverHello = phone.frames.at(-1);
  assert.ok(serverHello !== undefined && serverHello.kind === "serverHello", "期望 serverHello");
  h.gateway.handleFrame(phoneHandleServerHello(phone, serverHello), phone.sink);
  // secureReady 之后可能紧跟快照信封,不能只看最后一帧
  assert.ok(phone.frames.some((frame) => frame.kind === "secureReady"), "期望 secureReady");
  assert.ok(h.gateway.hasEstablishedSession(phone.phoneDeviceId));
}

async function waitFor(check: () => boolean, what: string, timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!check()) {
    if (Date.now() > deadline) assert.fail(`等待超时: ${what}`);
    await new Promise((r) => setTimeout(r, 5));
  }
}

// MARK: - 用例

test("握手完成即下发全部会话的 sessionCreated 快照", () => {
  const h = createHarness();
  h.hub.sessions = [sampleSession("s-1"), sampleSession("s-2")];
  const phone = createPhone("phone-A", "room-A");
  establish(h, phone);

  const snapshots = decryptedMessages(phone);
  assert.equal(snapshots.length, 2);
  assert.deepEqual(snapshots[0], {
    t: "event",
    data: { type: "sessionCreated", seq: 0, session: sampleSession("s-1") },
  });
  assert.deepEqual((snapshots[1]?.["data"] as Record<string, unknown>)["session"], sampleSession("s-2"));
});

test("cmd 走 hub.handle 并回 reply,失败回 ok:false", async () => {
  const h = createHarness();
  const phone = createPhone("phone-A", "room-A");
  establish(h, phone);

  const command: ClientCommand = { type: "sendMessage", sessionId: "s-1", text: "你好" };
  h.gateway.handleFrame(phoneSeal(phone, JSON.stringify({ t: "cmd", id: 1, data: command })), phone.sink);
  await waitFor(() => decryptedMessages(phone).length === 1, "cmd reply");
  assert.deepEqual(decryptedMessages(phone)[0], { t: "reply", id: 1, ok: true });
  assert.deepEqual(h.hub.handled, [command]);

  h.hub.failNextWith = "adapter 爆了";
  h.gateway.handleFrame(
    phoneSeal(phone, JSON.stringify({ t: "cmd", id: 2, data: { type: "interrupt", sessionId: "s-1" } })),
    phone.sink,
  );
  await waitFor(() => decryptedMessages(phone).length === 2, "失败 reply");
  const failed = decryptedMessages(phone)[1];
  assert.equal(failed?.["ok"], false);
  assert.equal(failed?.["id"], 2);
  assert.match(String(failed?.["error"]), /adapter 爆了/);
});

test("subscribe 不进 hub.handle,reply 附带 replay 事件", async () => {
  const h = createHarness();
  const phone = createPhone("phone-A", "room-A");
  establish(h, phone);

  const backlog: BridgeEvent[] = [
    { type: "sessionStatus", seq: 3, sessionId: "s-1", status: "running" },
    { type: "sessionClosed", seq: 4, sessionId: "s-1", reason: "done" },
  ];
  h.hub.replayResult = backlog;
  h.gateway.handleFrame(
    phoneSeal(
      phone,
      JSON.stringify({ t: "cmd", id: 9, data: { type: "subscribe", sessionId: "s-1", fromSeq: 3 } }),
    ),
    phone.sink,
  );
  await waitFor(() => decryptedMessages(phone).length === 1, "subscribe reply");
  assert.deepEqual(decryptedMessages(phone)[0], { t: "reply", id: 9, ok: true, events: backlog });
  assert.deepEqual(h.hub.replayCalls, [{ sessionId: "s-1", fromSeq: 3 }]);
  assert.deepEqual(h.hub.handled, []);
});

test("hub 事件广播到每个已建立会话的 phone", async () => {
  const h = createHarness();
  const phoneA = createPhone("phone-A", "room-A");
  const phoneB = createPhone("phone-B", "room-B");
  establish(h, phoneA);
  establish(h, phoneB);

  const event: BridgeEvent = { type: "sessionStatus", seq: 7, sessionId: "s-1", status: "running" };
  h.hub.emit(event);
  assert.deepEqual(decryptedMessages(phoneA), [{ t: "event", data: event }]);
  assert.deepEqual(decryptedMessages(phoneB), [{ t: "event", data: event }]);
});

test("push-register 落盘 push-tokens.json,含 updatedAtMs", async () => {
  const h = createHarness();
  const phone = createPhone("phone-A", "room-A");
  establish(h, phone);

  h.gateway.handleFrame(
    phoneSeal(
      phone,
      JSON.stringify({
        t: "push-register",
        deviceToken: "tok-123",
        environment: "sandbox",
        // 手机发的是 { approvals, turns } 对象;这里关掉审批推送、保留轮次
        alertsEnabled: { approvals: false, turns: true },
      }),
    ),
    phone.sink,
  );
  await waitFor(() => {
    try {
      return loadPushTokens(h.stateDir)["phone-A"] !== undefined;
    } catch {
      return false;
    }
  }, "push-tokens.json 写盘");

  assert.deepEqual(loadPushTokens(h.stateDir), {
    "phone-A": {
      deviceToken: "tok-123",
      environment: "sandbox",
      alertsEnabled: { approvals: false, turns: true },
      updatedAtMs: NOW,
    },
  });
  // 文件应是普通 JSON,APNs 任务直接读
  const raw = readFileSync(join(h.stateDir, "push-tokens.json"), "utf8");
  assert.ok(raw.endsWith("\n"));
});

test("通道里塞进解析不了的明文只被丢弃,会话不受影响", async () => {
  const h = createHarness();
  const phone = createPhone("phone-A", "room-A");
  establish(h, phone);

  h.gateway.handleFrame(phoneSeal(phone, "这不是 JSON"), phone.sink);
  h.gateway.handleFrame(phoneSeal(phone, JSON.stringify({ t: "mystery" })), phone.sink);
  h.gateway.handleFrame(
    phoneSeal(phone, JSON.stringify({ t: "cmd", id: 3, data: { type: "listSessions" } })),
    phone.sink,
  );
  await waitFor(() => decryptedMessages(phone).length === 1, "后续 cmd 依旧可用");
  assert.deepEqual(decryptedMessages(phone)[0], { t: "reply", id: 3, ok: true });
});
