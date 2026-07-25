import test from "node:test";
import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { mkdtempSync } from "node:fs";
import { get, request, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createRelayServer } from "../src/relay/relayServer.ts";
import { startRelayClient } from "../src/relay/relayClient.ts";
import { SecureGateway, type GatewayHub } from "../src/secure/secureGateway.ts";
import type {
  ClientAuthFrame,
  ClientHelloFrame,
  HandshakeMode,
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
import type { AgentSession, BridgeEvent, ClientCommand } from "../src/protocol/events.ts";

// MARK: - 最小 hub stub

class StubHub implements GatewayHub {
  handled: ClientCommand[] = [];
  onEvent(): () => void {
    return () => {};
  }
  async handle(command: ClientCommand): Promise<void> {
    this.handled.push(command);
  }
  replay(): BridgeEvent[] {
    return [];
  }
  listSessions(): AgentSession[] {
    return [];
  }
}

// MARK: - HTTP/SSE 测试小件

interface SseEvent {
  event: string;
  data: string;
}

interface SseStream {
  status: number;
  events: SseEvent[];
  closed: boolean;
  close(): void;
}

function openSse(url: string): Promise<SseStream> {
  return new Promise((resolve, reject) => {
    let settled = false;
    const req = get(url, { headers: { accept: "text/event-stream" } }, (response: IncomingMessage) => {
      const stream: SseStream = {
        status: response.statusCode ?? 0,
        events: [],
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
      let eventName = "";
      let dataLines: string[] = [];
      response.setEncoding("utf8");
      response.on("data", (chunk: string) => {
        buffer += chunk;
        let newline = buffer.indexOf("\n");
        while (newline !== -1) {
          const line = buffer.slice(0, newline);
          buffer = buffer.slice(newline + 1);
          newline = buffer.indexOf("\n");
          if (line === "") {
            if (dataLines.length > 0) {
              stream.events.push({
                event: eventName === "" ? "message" : eventName,
                data: dataLines.join("\n"),
              });
            }
            eventName = "";
            dataLines = [];
          } else if (line.startsWith("data:")) {
            dataLines.push(line.slice(5).replace(/^ /, ""));
          } else if (line.startsWith("event:")) {
            eventName = line.slice(6).replace(/^ /, "");
          }
        }
      });
      // relay 被掐掉时长连接会先冒 ECONNRESET,测试只关心 closed 状态
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

function post(url: string, body: string): Promise<number> {
  return new Promise((resolve, reject) => {
    const req = request(url, { method: "POST", agent: false }, (response) => {
      response.on("error", reject);
      response.resume();
      response.on("end", () => resolve(response.statusCode ?? 0));
    });
    req.on("error", reject);
    req.end(body);
  });
}

async function waitFor(check: () => boolean, what: string, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!check()) {
    if (Date.now() > deadline) assert.fail(`等待超时: ${what}`);
    await new Promise((r) => setTimeout(r, 10));
  }
}

// MARK: - phone 侧参考实现

interface Phone {
  phoneDeviceId: string;
  identitySeed: Buffer;
  identityPublicKey: string;
  ephemeralPrivate: Buffer;
  ephemeralPublic: string;
  clientNonce: string;
  keys: DirectionalKeys | null;
  outboundCounter: number;
}

function createPhone(phoneDeviceId: string): Phone {
  const identityPair = generateEd25519SeedKeyPair();
  const phone: Phone = {
    phoneDeviceId,
    identitySeed: identityPair.privateSeed,
    identityPublicKey: identityPair.publicKeyRaw.toString("base64"),
    ephemeralPrivate: Buffer.alloc(0),
    ephemeralPublic: "",
    clientNonce: "",
    keys: null,
    outboundCounter: 0,
  };
  refreshEphemeral(phone);
  return phone;
}

function refreshEphemeral(phone: Phone): void {
  const ephemeral = generateX25519KeyPairRaw();
  phone.ephemeralPrivate = ephemeral.privateKeyRaw;
  phone.ephemeralPublic = ephemeral.publicKeyRaw.toString("base64");
  phone.clientNonce = randomBytes(32).toString("base64");
}

function helloFrame(phone: Phone, roomId: string, handshakeMode: HandshakeMode): ClientHelloFrame {
  return {
    kind: "clientHello",
    protocolVersion: 1,
    roomId,
    handshakeMode,
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

// MARK: - 场景:注册→帧往返→断线重连

test("mac 经 relay 完成握手与 cmd 往返,relay 重启后自动重连", async () => {
  const relay1 = createRelayServer();
  await new Promise<void>((resolve) => relay1.listen(0, "127.0.0.1", resolve));
  const port = (relay1.address() as AddressInfo).port;
  const base = `http://127.0.0.1:${port}`;

  const pair = generateEd25519SeedKeyPair();
  const identity: BridgeIdentity = {
    version: 1,
    macDeviceId: randomUUID(),
    identityPublicKey: pair.publicKeyRaw.toString("base64"),
    identityPrivateKey: pair.privateSeed.toString("base64"),
    createdAtMs: Date.now(),
  };
  const roomId = identity.macDeviceId;
  const hub = new StubHub();
  const gateway = new SecureGateway({
    hub,
    identity,
    stateDir: mkdtempSync(join(tmpdir(), "lenscrew-relay-client-")),
    displayName: "Relay Mac",
    pairingWindow: { isOpen: () => true, expiresAtMs: () => Date.now() + 300_000 },
  });

  const client = startRelayClient({
    relayUrl: base,
    roomId,
    gateway,
    backoff: { initialMs: 25, maxMs: 200 },
  });

  const streamUrl = (): string => `${base}/v1/rooms/${roomId}/stream?role=phone`;
  const sendUrl = (): string => `${base}/v1/rooms/${roomId}/send?role=phone`;

  const phone = createPhone("phone-relay");
  let secondRelay: Server | null = null;
  let phoneStream: SseStream | null = null;

  try {
    // —— 第一段:mac 注册进房间,phone 完成 qr_bootstrap 握手 ——
    phoneStream = await openSse(streamUrl());
    await waitFor(
      () => phoneStream!.events.some((e) => e.event === "relay" && e.data.includes('"up"')),
      "phone 看到 mac 已在房间",
    );

    const frames = (stream: SseStream): unknown[] =>
      stream.events.filter((e) => e.event === "message").map((e) => JSON.parse(e.data) as unknown);

    await post(sendUrl(), JSON.stringify(helloFrame(phone, roomId, "qr_bootstrap")));
    await waitFor(() => frames(phoneStream!).length >= 1, "serverHello 下行");
    const serverHello = frames(phoneStream)[0] as ServerHelloFrame;
    assert.equal(serverHello.kind, "serverHello");
    assert.equal(serverHello.displayName, "Relay Mac");

    await post(sendUrl(), JSON.stringify(phoneHandleServerHello(phone, serverHello)));
    await waitFor(
      () => frames(phoneStream!).some((f) => (f as { kind?: string }).kind === "secureReady"),
      "secureReady 下行",
    );

    // —— cmd 往返 ——
    phone.outboundCounter += 1;
    const cmd = sealEnvelope({
      key: phoneKeys(phone).phoneToMac,
      roomId,
      keyEpoch: serverHello.keyEpoch,
      sender: "phone",
      counter: phone.outboundCounter,
      plaintext: JSON.stringify({ t: "cmd", id: 7, data: { type: "listSessions" } }),
    });
    await post(sendUrl(), JSON.stringify(cmd));
    await waitFor(
      () => frames(phoneStream!).some((f) => (f as { kind?: string }).kind === "encryptedEnvelope"),
      "reply 信封下行",
    );
    const replyEnvelope = frames(phoneStream).find(
      (f) => (f as { kind?: string }).kind === "encryptedEnvelope",
    ) as EncryptedEnvelope;
    const reply = JSON.parse(
      openEnvelope({ key: phoneKeys(phone).macToPhone, envelope: replyEnvelope }),
    ) as Record<string, unknown>;
    assert.deepEqual(reply, { t: "reply", id: 7, ok: true });
    assert.deepEqual(hub.handled, [{ type: "listSessions" }]);

    // —— 第二段:relay 重启,mac 客户端退避重连,phone 走 trusted_reconnect ——
    phoneStream.close();
    relay1.close();
    relay1.closeAllConnections();

    secondRelay = createRelayServer();
    await new Promise<void>((resolve, reject) => {
      secondRelay!.once("error", reject);
      secondRelay!.listen(port, "127.0.0.1", resolve);
    });

    phoneStream = await openSse(streamUrl());
    // mac 客户端重连成功的唯一外显信号:phone 能看到 peer up
    await waitFor(
      () => phoneStream!.events.some((e) => e.event === "relay" && e.data.includes('"up"')),
      "mac 重连回房间",
      8000,
    );

    refreshEphemeral(phone);
    const roomId2 = `${roomId}`.slice(0, 30) + "-r2";
    await post(
      `${base}/v1/rooms/${roomId}/send?role=phone`,
      JSON.stringify(helloFrame(phone, roomId2, "trusted_reconnect")),
    );
    const frames2 = (): unknown[] =>
      phoneStream!.events.filter((e) => e.event === "message").map((e) => JSON.parse(e.data) as unknown);
    await waitFor(() => frames2().length >= 1, "重连 serverHello 下行");
    const serverHello2 = frames2()[0] as ServerHelloFrame;
    assert.equal(serverHello2.kind, "serverHello");
    assert.equal(serverHello2.handshakeMode, "trusted_reconnect");
    assert.equal(serverHello2.pairingExpiresAtMs, 0, "trusted_reconnect 不带配对窗口");

    await post(`${base}/v1/rooms/${roomId}/send?role=phone`, JSON.stringify(phoneHandleServerHello(phone, serverHello2)));
    await waitFor(
      () => frames2().some((f) => (f as { kind?: string }).kind === "secureReady"),
      "重连 secureReady 下行",
    );
    assert.ok(gateway.hasEstablishedSession("phone-relay"));
  } finally {
    phoneStream?.close();
    client.close();
    gateway.close();
    relay1.close();
    relay1.closeAllConnections();
    if (secondRelay !== null) {
      secondRelay.close();
      secondRelay.closeAllConnections();
    }
  }
});
