import test from "node:test";
import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { mkdtempSync } from "node:fs";
import { get, request, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createBridgeServer } from "../src/transport/server.ts";
import { SecureGateway, type GatewayHub } from "../src/secure/secureGateway.ts";
import type { SessionHub } from "../src/session/hub.ts";
import type {
  ClientAuthFrame,
  ClientHelloFrame,
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

const TOKEN = "e2ee-test-token";

// MARK: - 假 hub(server 的类型是 nominal 的 SessionHub,测试用最小 stub 顶上)

class FakeHub implements GatewayHub {
  readonly #listeners = new Set<(event: BridgeEvent) => void>();
  sessions: AgentSession[] = [];
  handled: ClientCommand[] = [];
  replayResult: BridgeEvent[] = [];

  onEvent(listener: (event: BridgeEvent) => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }
  async handle(command: ClientCommand): Promise<void> {
    this.handled.push(command);
  }
  replay(): BridgeEvent[] {
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
    title: "e2ee 会话",
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
    createdAtMs: 1,
    updatedAtMs: 1,
  };
}

// MARK: - 测试台

interface Harness {
  server: Server;
  base: string;
  hub: FakeHub;
  gateway: SecureGateway;
}

async function startServer(): Promise<Harness> {
  const pair = generateEd25519SeedKeyPair();
  const identity: BridgeIdentity = {
    version: 1,
    macDeviceId: randomUUID(),
    identityPublicKey: pair.publicKeyRaw.toString("base64"),
    identityPrivateKey: pair.privateSeed.toString("base64"),
    createdAtMs: 1,
  };
  const hub = new FakeHub();
  const gateway = new SecureGateway({
    hub,
    identity,
    stateDir: mkdtempSync(join(tmpdir(), "lenscrew-e2ee-")),
    displayName: "E2EE Mac",
    pairingWindow: { isOpen: () => true, expiresAtMs: () => Date.now() + 300_000 },
  });
  // server 只调用 hub 的 onEvent/handle/replay/listSessions/latestQuota;
  // SessionHub 的 # 私有字段挡住了结构化 stub,这里显式越过 nominal 检查
  const server = createBridgeServer({
    hub: hub as unknown as SessionHub,
    token: TOKEN,
    host: "127.0.0.1",
    port: 0,
    gateway,
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  return { server, base: `http://127.0.0.1:${port}`, hub, gateway };
}

function stopServer(h: Harness): void {
  h.gateway.close();
  h.server.close();
  h.server.closeAllConnections();
}

interface SseStream {
  status: number;
  frames: unknown[];
  closed: boolean;
  close(): void;
}

/** /e2ee/stream 与 /events 一样是「一条 data: 行一帧」,这里直接按行解析成 JSON */
function openStream(url: string): Promise<SseStream> {
  return new Promise((resolve, reject) => {
    let settled = false;
    const req = get(url, { headers: { accept: "text/event-stream" } }, (response: IncomingMessage) => {
      const stream: SseStream = {
        status: response.statusCode ?? 0,
        frames: [],
        closed: false,
        close: () => req.destroy(),
      };
      settled = true;
      if (response.statusCode !== 200) {
        response.resume();
        resolve(stream);
        return;
      }
      let buffer = "";
      response.setEncoding("utf8");
      response.on("data", (chunk: string) => {
        buffer += chunk;
        let newline = buffer.indexOf("\n");
        while (newline !== -1) {
          const line = buffer.slice(0, newline);
          buffer = buffer.slice(newline + 1);
          newline = buffer.indexOf("\n");
          if (line.startsWith("data: ")) {
            stream.frames.push(JSON.parse(line.slice(6)));
          }
        }
      });
      // 服务端顶替/关闭长连接时会先冒 ECONNRESET,测试只关心 closed 状态
      response.on("error", () => {});
      response.on("close", () => {
        stream.closed = true;
      });
      resolve(stream);
    });
    req.on("error", (error) => {
      if (!settled) reject(error);
    });
  });
}

function httpCall(
  method: string,
  url: string,
  body?: string,
  headers?: Record<string, string>,
): Promise<{ status: number; json: Record<string, unknown> }> {
  return new Promise((resolve, reject) => {
    const req = request(url, { method, agent: false, headers: headers ?? {} }, (response) => {
      const chunks: Buffer[] = [];
      response.on("error", reject);
      response.on("data", (chunk: Buffer) => chunks.push(chunk));
      response.on("end", () => {
        resolve({
          status: response.statusCode ?? 0,
          json: JSON.parse(Buffer.concat(chunks).toString("utf8")) as Record<string, unknown>,
        });
      });
    });
    req.on("error", reject);
    req.end(body);
  });
}

async function waitFor(check: () => boolean, what: string, timeoutMs = 3000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!check()) {
    if (Date.now() > deadline) assert.fail(`等待超时: ${what}`);
    await new Promise((r) => setTimeout(r, 10));
  }
}

// MARK: - phone 侧参考实现

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
}

function createPhone(phoneDeviceId: string, roomId: string): Phone {
  const identityPair = generateEd25519SeedKeyPair();
  const ephemeral = generateX25519KeyPairRaw();
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
  phone.outboundCounter = 0;
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

function phoneSeal(phone: Phone, keyEpoch: number, plaintext: string): EncryptedEnvelope {
  phone.outboundCounter += 1;
  return sealEnvelope({
    key: phoneKeys(phone).phoneToMac,
    roomId: phone.roomId,
    keyEpoch,
    sender: "phone",
    counter: phone.outboundCounter,
    plaintext,
  });
}

function decryptedMessages(phone: Phone, stream: SseStream): Array<Record<string, unknown>> {
  return stream.frames
    .filter((f): f is EncryptedEnvelope => (f as { kind?: string }).kind === "encryptedEnvelope")
    .map((envelope) =>
      JSON.parse(openEnvelope({ key: phoneKeys(phone).macToPhone, envelope })) as Record<string, unknown>,
    );
}

// MARK: - 用例

test("本地 /e2ee 完整握手到 listSessions reply,快照与事件照常下发", async () => {
  const h = await startServer();
  const phone = createPhone("phone-e2ee", "room-e2ee-1");
  h.hub.sessions = [sampleSession("s-1")];
  try {
    // 先 POST 后开流:serverHello 应进入出站队列而不是丢失
    const hello = await httpCall("POST", `${h.base}/e2ee/send`, JSON.stringify(helloFrame(phone)));
    assert.equal(hello.status, 202);
    assert.deepEqual(hello.json, { ok: true });

    const stream = await openStream(`${h.base}/e2ee/stream?device=${phone.phoneDeviceId}`);
    await waitFor(() => stream.frames.length >= 1, "队列中的 serverHello 补发");
    const serverHello = stream.frames[0] as ServerHelloFrame;
    assert.equal(serverHello.kind, "serverHello");

    await httpCall("POST", `${h.base}/e2ee/send`, JSON.stringify(phoneHandleServerHello(phone, serverHello)));
    await waitFor(
      () => stream.frames.some((f) => (f as { kind?: string }).kind === "secureReady"),
      "secureReady 下行",
    );
    // 握手完成即收到会话快照
    await waitFor(() => decryptedMessages(phone, stream).length >= 1, "sessionCreated 快照");
    assert.deepEqual(decryptedMessages(phone, stream)[0], {
      t: "event",
      data: { type: "sessionCreated", seq: 0, session: sampleSession("s-1") },
    });

    // 信封只带 roomId,server 靠 clientHello 学到的映射路由回同一 device
    const cmd = phoneSeal(
      phone,
      serverHello.keyEpoch,
      JSON.stringify({ t: "cmd", id: 11, data: { type: "listSessions" } }),
    );
    const sent = await httpCall("POST", `${h.base}/e2ee/send`, JSON.stringify(cmd));
    assert.equal(sent.status, 202);
    await waitFor(() => decryptedMessages(phone, stream).length >= 2, "listSessions reply");
    assert.deepEqual(decryptedMessages(phone, stream)[1], { t: "reply", id: 11, ok: true });
    assert.deepEqual(h.hub.handled, [{ type: "listSessions" }]);

    // hub 事件出口 → 信封下发
    const event: BridgeEvent = { type: "sessionStatus", seq: 5, sessionId: "s-1", status: "running" };
    h.hub.emit(event);
    await waitFor(() => decryptedMessages(phone, stream).length >= 3, "事件广播下行");
    assert.deepEqual(decryptedMessages(phone, stream)[2], { t: "event", data: event });

    stream.close();
  } finally {
    stopServer(h);
  }
});

test("同 device 新流顶替旧流", async () => {
  const h = await startServer();
  const phone = createPhone("phone-e2ee", "room-e2ee-2");
  try {
    const first = await openStream(`${h.base}/e2ee/stream?device=${phone.phoneDeviceId}`);
    const second = await openStream(`${h.base}/e2ee/stream?device=${phone.phoneDeviceId}`);
    await waitFor(() => first.closed, "旧流被服务端关闭");

    await httpCall("POST", `${h.base}/e2ee/send`, JSON.stringify(helloFrame(phone)));
    await waitFor(() => second.frames.length >= 1, "帧走新流");
    assert.equal((second.frames[0] as { kind?: string }).kind, "serverHello");
    assert.deepEqual(first.frames, []);
    second.close();
  } finally {
    stopServer(h);
  }
});

test("路由不了的帧与缺参请求被拒", async () => {
  const h = await startServer();
  try {
    const noDevice = await openStream(`${h.base}/e2ee/stream`);
    assert.equal(noDevice.status, 400);

    // 没经过 clientHello 的房间,信封无从路由
    const orphan = await httpCall(
      "POST",
      `${h.base}/e2ee/send`,
      JSON.stringify({ kind: "encryptedEnvelope", v: 1, roomId: "never-seen", keyEpoch: 1, sender: "phone", counter: 1, ciphertext: "eA==", tag: "eA==" }),
    );
    assert.equal(orphan.status, 400);
  } finally {
    stopServer(h);
  }
});

test("既有端点行为不变:/health 免鉴权,/events /command 仍要口令", async () => {
  const h = await startServer();
  try {
    const health = await httpCall("GET", `${h.base}/health`);
    assert.deepEqual(health.json, { ok: true });

    const events = await openStream(`${h.base}/events`);
    assert.equal(events.status, 401);

    const denied = await httpCall("POST", `${h.base}/command`, JSON.stringify({ type: "listSessions" }));
    assert.equal(denied.status, 401);

    const allowed = await httpCall(
      "POST",
      `${h.base}/command`,
      JSON.stringify({ type: "listSessions" }),
      { authorization: `Bearer ${TOKEN}` },
    );
    assert.equal(allowed.status, 200);
    assert.deepEqual(allowed.json, { ok: true });
  } finally {
    stopServer(h);
  }
});
