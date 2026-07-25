import test from "node:test";
import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";

import {
  SecureChannelHost,
  type ClientAuthFrame,
  type ClientHelloFrame,
  type HandshakeMode,
  type HostFrame,
  type SecureChannelIo,
  type SecureErrorCode,
  type SecureReadyFrame,
  type ServerHelloFrame,
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
  verifyTranscript,
  x25519SharedSecret,
  type DirectionalKeys,
  type EncryptedEnvelope,
} from "../src/secure/crypto.ts";
import type { BridgeIdentity, TrustedPhones } from "../src/state/stateDir.ts";

const WINDOW_EXPIRES_AT = 1753500000000;
const NOW = 1700000000000;

// MARK: - host 测试台

interface HostHarness {
  host: SecureChannelHost;
  identity: BridgeIdentity;
  io: SecureChannelIo;
  sent: HostFrame[];
  messages: Array<{ phoneDeviceId: string; plaintext: string }>;
  ready: string[];
  trusted: () => TrustedPhones;
  saveCount: () => number;
  setPairingOpen: (open: boolean) => void;
}

function createHost(options?: { pairingOpen?: boolean; trusted?: TrustedPhones }): HostHarness {
  const pair = generateEd25519SeedKeyPair();
  const identity: BridgeIdentity = {
    version: 1,
    macDeviceId: randomUUID(),
    identityPublicKey: pair.publicKeyRaw.toString("base64"),
    identityPrivateKey: pair.privateSeed.toString("base64"),
    createdAtMs: NOW,
  };
  let trusted: TrustedPhones = options?.trusted ?? {};
  let saves = 0;
  let pairingOpen = options?.pairingOpen ?? true;
  const sent: HostFrame[] = [];
  const messages: Array<{ phoneDeviceId: string; plaintext: string }> = [];
  const ready: string[] = [];
  const host = new SecureChannelHost({
    identity,
    trustedPhones: {
      load: () => trusted,
      save: (phones) => {
        trusted = phones;
        saves += 1;
      },
    },
    displayName: "Test Mac",
    pairingWindow: { isOpen: () => pairingOpen, expiresAtMs: () => WINDOW_EXPIRES_AT },
    now: () => NOW,
  });
  return {
    host,
    identity,
    io: {
      send: (frame) => sent.push(frame),
      onSessionReady: (phoneDeviceId) => ready.push(phoneDeviceId),
      onMessage: (phoneDeviceId, plaintext) => messages.push({ phoneDeviceId, plaintext }),
    },
    sent,
    messages,
    ready,
    trusted: () => trusted,
    saveCount: () => saves,
    setPairingOpen: (open) => {
      pairingOpen = open;
    },
  };
}

function lastFrame(h: HostHarness): HostFrame {
  const frame = h.sent.at(-1);
  if (frame === undefined) {
    assert.fail("host 应当已发出帧");
  }
  return frame;
}

function expectError(h: HostHarness, code: SecureErrorCode): void {
  const frame = lastFrame(h);
  if (frame.kind !== "secureError") {
    assert.fail(`期望 secureError,实际 ${frame.kind}`);
  }
  assert.equal(frame.code, code);
  assert.ok(frame.message.length > 0);
}

// MARK: - phone 侧参考实现(iOS 之后按同一套纯函数对齐)

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

function refreshEphemeral(phone: Phone): void {
  const ephemeral = generateX25519KeyPairRaw();
  phone.ephemeralPrivate = ephemeral.privateKeyRaw;
  phone.ephemeralPublic = ephemeral.publicKeyRaw.toString("base64");
  phone.clientNonce = randomBytes(32).toString("base64");
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

/** phone 收到 serverHello:重建 transcript、验 mac 签名、派生密钥、产出 clientAuth */
function phoneHandleServerHello(phone: Phone, serverHello: ServerHelloFrame): ClientAuthFrame {
  assert.equal(serverHello.clientNonce, phone.clientNonce);
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
  assert.ok(
    verifyTranscript(
      Buffer.from(serverHello.macIdentityPublicKey, "base64"),
      transcript,
      Buffer.from(serverHello.macSignature, "base64"),
    ),
    "phone 侧必须能验证 mac 的 transcript 签名",
  );
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

function phoneSeal(phone: Phone, roomId: string, keyEpoch: number, plaintext: string): EncryptedEnvelope {
  phone.outboundCounter += 1;
  return sealEnvelope({
    key: phoneKeys(phone).phoneToMac,
    roomId,
    keyEpoch,
    sender: "phone",
    counter: phone.outboundCounter,
    plaintext,
  });
}

function establish(
  h: HostHarness,
  phone: Phone,
  roomId: string,
  handshakeMode: HandshakeMode,
): { serverHello: ServerHelloFrame; ready: SecureReadyFrame } {
  h.host.handleFrame(helloFrame(phone, roomId, handshakeMode), h.io);
  const serverHello = lastFrame(h);
  if (serverHello.kind !== "serverHello") {
    assert.fail(`期望 serverHello,实际 ${serverHello.kind}`);
  }
  h.host.handleFrame(phoneHandleServerHello(phone, serverHello), h.io);
  const ready = lastFrame(h);
  if (ready.kind !== "secureReady") {
    assert.fail(`期望 secureReady,实际 ${ready.kind}`);
  }
  return { serverHello, ready };
}

// MARK: - 握手成功路径

test("qr_bootstrap 全流程:握手、写信任表、双向 envelope 收发", () => {
  const h = createHost({ pairingOpen: true });
  const phone = createPhone("phone-A");
  const { serverHello, ready } = establish(h, phone, "room-A", "qr_bootstrap");

  assert.equal(serverHello.protocolVersion, 1);
  assert.equal(serverHello.roomId, "room-A");
  assert.equal(serverHello.keyEpoch, 1);
  assert.equal(serverHello.pairingExpiresAtMs, WINDOW_EXPIRES_AT);
  assert.equal(serverHello.macDeviceId, h.identity.macDeviceId);
  assert.equal(serverHello.macIdentityPublicKey, h.identity.identityPublicKey);
  assert.equal(serverHello.displayName, "Test Mac");

  assert.deepEqual(ready, {
    kind: "secureReady",
    roomId: "room-A",
    keyEpoch: 1,
    macDeviceId: h.identity.macDeviceId,
  });
  assert.deepEqual(h.ready, ["phone-A"]);
  assert.ok(h.host.hasEstablishedSession("phone-A"));

  // 验签通过后 phone 才进信任表
  assert.equal(h.saveCount(), 1);
  assert.deepEqual(h.trusted()["phone-A"], {
    identityPublicKey: phone.identityPublicKey,
    addedAtMs: NOW,
  });

  // 双向密钥必须不同
  const keys = phoneKeys(phone);
  assert.notDeepEqual(keys.phoneToMac, keys.macToPhone);

  // phone → mac
  h.host.handleFrame(phoneSeal(phone, "room-A", 1, "hello from phone"), h.io);
  assert.deepEqual(h.messages, [{ phoneDeviceId: "phone-A", plaintext: "hello from phone" }]);

  // mac → phone,counter 从 1 起自增
  const out1 = h.host.sendSecure("phone-A", "hello from mac");
  assert.equal(out1.sender, "mac");
  assert.equal(out1.counter, 1);
  assert.equal(out1.keyEpoch, 1);
  assert.equal(openEnvelope({ key: keys.macToPhone, envelope: out1 }), "hello from mac");
  const out2 = h.host.sendSecure("phone-A", "second");
  assert.equal(out2.counter, 2);
  assert.equal(openEnvelope({ key: keys.macToPhone, envelope: out2 }), "second");
});

test("trusted_reconnect:配对窗口关闭也能重连,不重写信任表", () => {
  const phone = createPhone("phone-A");
  const h = createHost({
    pairingOpen: false,
    trusted: { "phone-A": { identityPublicKey: phone.identityPublicKey, addedAtMs: 1 } },
  });
  const { serverHello } = establish(h, phone, "room-R", "trusted_reconnect");
  assert.equal(serverHello.pairingExpiresAtMs, 0);
  assert.equal(h.saveCount(), 0);

  h.host.handleFrame(phoneSeal(phone, "room-R", serverHello.keyEpoch, "reconnected"), h.io);
  assert.deepEqual(h.messages, [{ phoneDeviceId: "phone-A", plaintext: "reconnected" }]);
});

test("多手机并存:会话按 phoneDeviceId 隔离、按 roomId 路由", () => {
  const h = createHost({ pairingOpen: true });
  const phoneA = createPhone("phone-A");
  const phoneB = createPhone("phone-B");
  establish(h, phoneA, "room-A", "qr_bootstrap");
  establish(h, phoneB, "room-B", "qr_bootstrap");

  h.host.handleFrame(phoneSeal(phoneB, "room-B", 1, "from B"), h.io);
  h.host.handleFrame(phoneSeal(phoneA, "room-A", 1, "from A"), h.io);
  assert.deepEqual(h.messages, [
    { phoneDeviceId: "phone-B", plaintext: "from B" },
    { phoneDeviceId: "phone-A", plaintext: "from A" },
  ]);

  const toA = h.host.sendSecure("phone-A", "to A");
  const toB = h.host.sendSecure("phone-B", "to B");
  assert.equal(openEnvelope({ key: phoneKeys(phoneA).macToPhone, envelope: toA }), "to A");
  assert.equal(openEnvelope({ key: phoneKeys(phoneB).macToPhone, envelope: toB }), "to B");
});

test("同一 phone 的新 clientHello 顶替旧会话,keyEpoch 递增", () => {
  const h = createHost({ pairingOpen: true });
  const phone = createPhone("phone-A");
  establish(h, phone, "room-1", "qr_bootstrap");
  const oldKeys = phoneKeys(phone);

  refreshEphemeral(phone);
  const { serverHello } = establish(h, phone, "room-2", "qr_bootstrap");
  assert.equal(serverHello.keyEpoch, 2);

  // 新会话可用,mac 侧 counter 重新从 1 起
  const out = h.host.sendSecure("phone-A", "epoch-2");
  assert.equal(out.keyEpoch, 2);
  assert.equal(out.counter, 1);
  assert.equal(openEnvelope({ key: phoneKeys(phone).macToPhone, envelope: out }), "epoch-2");
  assert.notDeepEqual(phoneKeys(phone).phoneToMac, oldKeys.phoneToMac);

  // 旧 roomId 的路由已被摘除
  const stale = sealEnvelope({
    key: oldKeys.phoneToMac,
    roomId: "room-1",
    keyEpoch: 1,
    sender: "phone",
    counter: 1,
    plaintext: "stale",
  });
  h.host.handleFrame(stale, h.io);
  expectError(h, "unexpected_frame");
  assert.equal(h.messages.length, 0);
});

// MARK: - 拒绝路径

test("protocolVersion 不符回 protocol_mismatch", () => {
  const h = createHost();
  const phone = createPhone("phone-A");
  h.host.handleFrame({ ...helloFrame(phone, "room-A", "qr_bootstrap"), protocolVersion: 2 }, h.io);
  expectError(h, "protocol_mismatch");
  assert.ok(!h.host.hasEstablishedSession("phone-A"));
});

test("qr_bootstrap 配对窗口关闭回 pairing_expired", () => {
  const h = createHost({ pairingOpen: false });
  const phone = createPhone("phone-A");
  h.host.handleFrame(helloFrame(phone, "room-A", "qr_bootstrap"), h.io);
  expectError(h, "pairing_expired");
});

test("trusted_reconnect 未配对回 phone_not_trusted", () => {
  const h = createHost({ pairingOpen: true });
  const phone = createPhone("phone-A");
  h.host.handleFrame(helloFrame(phone, "room-A", "trusted_reconnect"), h.io);
  expectError(h, "phone_not_trusted");
});

test("trusted_reconnect 身份公钥变化回 phone_identity_changed", () => {
  const phone = createPhone("phone-A");
  const other = generateEd25519SeedKeyPair();
  const h = createHost({
    pairingOpen: true,
    trusted: { "phone-A": { identityPublicKey: other.publicKeyRaw.toString("base64"), addedAtMs: 1 } },
  });
  h.host.handleFrame(helloFrame(phone, "room-A", "trusted_reconnect"), h.io);
  expectError(h, "phone_identity_changed");
});

test("clientAuth 验签失败回 invalid_signature 并终止握手", () => {
  const h = createHost({ pairingOpen: true });
  const phone = createPhone("phone-A");
  h.host.handleFrame(helloFrame(phone, "room-A", "qr_bootstrap"), h.io);
  const serverHello = lastFrame(h);
  if (serverHello.kind !== "serverHello") {
    assert.fail("期望 serverHello");
  }
  const auth = phoneHandleServerHello(phone, serverHello);
  const attacker = generateEd25519SeedKeyPair();
  h.host.handleFrame(
    { ...auth, phoneSignature: signTranscript(attacker.privateSeed, Buffer.from("bogus")).toString("base64") },
    h.io,
  );
  expectError(h, "invalid_signature");
  assert.ok(!h.host.hasEstablishedSession("phone-A"));
  assert.equal(h.saveCount(), 0);

  // 握手已被丢弃,重发正确的 clientAuth 也不再被接受
  h.host.handleFrame(auth, h.io);
  expectError(h, "unexpected_frame");
});

test("重放 counter 静默丢弃且不回帧", () => {
  const h = createHost({ pairingOpen: true });
  const phone = createPhone("phone-A");
  establish(h, phone, "room-A", "qr_bootstrap");

  const envelope = phoneSeal(phone, "room-A", 1, "once");
  h.host.handleFrame(envelope, h.io);
  const framesAfterFirst = h.sent.length;

  h.host.handleFrame(envelope, h.io);
  h.host.handleFrame(envelope, h.io);
  assert.equal(h.sent.length, framesAfterFirst, "重放不得回任何帧(防放大)");
  assert.equal(h.messages.length, 1);
  assert.equal(h.host.replayDropCount("phone-A"), 2);

  // 会话未受影响,后续 counter 正常收
  h.host.handleFrame(phoneSeal(phone, "room-A", 1, "next"), h.io);
  assert.equal(h.messages.length, 2);
});

test("解密失败回 decrypt_failed 并断开该 phone 会话", () => {
  const h = createHost({ pairingOpen: true });
  const phone = createPhone("phone-A");
  establish(h, phone, "room-A", "qr_bootstrap");

  const envelope = phoneSeal(phone, "room-A", 1, "tamper me");
  h.host.handleFrame({ ...envelope, ciphertext: randomBytes(16).toString("base64") }, h.io);
  expectError(h, "decrypt_failed");
  assert.ok(!h.host.hasEstablishedSession("phone-A"));
  assert.throws(() => h.host.sendSecure("phone-A", "dead"));

  // 断开后同房间的后续密文没有会话可路由
  h.host.handleFrame(phoneSeal(phone, "room-A", 1, "after drop"), h.io);
  expectError(h, "unexpected_frame");
});

test("畸形帧一律 unexpected_frame", () => {
  const h = createHost({ pairingOpen: true });
  h.host.handleFrame("not an object", h.io);
  expectError(h, "unexpected_frame");
  h.host.handleFrame({ kind: "mystery" }, h.io);
  expectError(h, "unexpected_frame");
  h.host.handleFrame({ kind: "clientHello", protocolVersion: 1, handshakeMode: "qr_bootstrap" }, h.io);
  expectError(h, "unexpected_frame");
  const phone = createPhone("phone-A");
  // 公钥不是 32 字节
  h.host.handleFrame(
    { ...helloFrame(phone, "room-A", "qr_bootstrap"), phoneEphemeralPublicKey: "c2hvcnQ=" },
    h.io,
  );
  expectError(h, "unexpected_frame");
});
