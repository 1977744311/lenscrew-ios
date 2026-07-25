import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

import {
  buildClientAuthMessage,
  buildTranscript,
  deriveKeys,
  ed25519PublicRawFromSeed,
  exportEd25519PrivateSeed,
  exportEd25519PublicRaw,
  generateEd25519SeedKeyPair,
  generateX25519KeyPairRaw,
  importEd25519PrivateSeed,
  importEd25519PublicRaw,
  lengthPrefixed,
  openEnvelope,
  sealEnvelope,
  signTranscript,
  verifyTranscript,
  x25519PublicRawFromPrivate,
  x25519SharedSecret,
  type TranscriptParams,
} from "../src/secure/crypto.ts";
import {
  E2EE_FIXTURE_INPUTS,
  E2EE_FIXTURE_URL,
  renderE2eeFixtureJson,
  type E2eeFixtureExpected,
  type E2eeFixtureInputs,
} from "../src/secure/fixture.ts";

function sha256Hex(data: Uint8Array): string {
  return createHash("sha256").update(data).digest("hex");
}

// MARK: - lengthPrefixed

test("lengthPrefixed 边界:空列表、空字段、多字段、跨 1 字节长度", () => {
  assert.equal(lengthPrefixed([]).length, 0);
  assert.equal(lengthPrefixed([Buffer.alloc(0)]).toString("hex"), "00000000");
  assert.equal(
    lengthPrefixed([Buffer.from("ab", "utf8"), Buffer.from("c", "utf8")]).toString("hex"),
    "000000026162" + "0000000163",
  );
  const long = lengthPrefixed([Buffer.alloc(256, 0xaa)]);
  assert.equal(long.length, 4 + 256);
  assert.equal(long.subarray(0, 4).toString("hex"), "00000100");
});

test("lengthPrefixed 消除字段边界歧义", () => {
  const a = lengthPrefixed([Buffer.from("ab"), Buffer.from("c")]);
  const b = lengthPrefixed([Buffer.from("a"), Buffer.from("bc")]);
  assert.notDeepEqual(a, b);
});

// MARK: - transcript

const baseTranscriptParams: TranscriptParams = {
  roomId: "room-1",
  protocolVersion: 1,
  handshakeMode: "qr_bootstrap",
  keyEpoch: 1,
  macDeviceId: "mac-1",
  phoneDeviceId: "phone-1",
  macIdentityPublicKey: "bWFjLWlk",
  phoneIdentityPublicKey: "cGhvbmUtaWQ=",
  macEphemeralPublicKey: "bWFjLWVwaA==",
  phoneEphemeralPublicKey: "cGhvbmUtZXBo",
  clientNonce: "Y2xpZW50",
  serverNonce: "c2VydmVy",
  pairingExpiresAtMs: 1753500000000,
};

test("buildTranscript 对相同输入逐字节确定,任一字段变动即不同", () => {
  const a = buildTranscript(baseTranscriptParams);
  const b = buildTranscript({ ...baseTranscriptParams });
  assert.deepEqual(a, b);
  assert.notDeepEqual(a, buildTranscript({ ...baseTranscriptParams, keyEpoch: 2 }));
  assert.notDeepEqual(a, buildTranscript({ ...baseTranscriptParams, serverNonce: "c2VydmVyMg==" }));
  assert.notDeepEqual(a, buildTranscript({ ...baseTranscriptParams, handshakeMode: "trusted_reconnect" }));
});

// MARK: - Ed25519 / X25519 raw 互转

test("Ed25519 seed/公钥 raw 往返互转与签名验签", () => {
  const pair = generateEd25519SeedKeyPair();
  assert.equal(pair.privateSeed.length, 32);
  assert.equal(pair.publicKeyRaw.length, 32);
  assert.deepEqual(ed25519PublicRawFromSeed(pair.privateSeed), pair.publicKeyRaw);
  assert.deepEqual(exportEd25519PrivateSeed(importEd25519PrivateSeed(pair.privateSeed)), pair.privateSeed);
  assert.deepEqual(exportEd25519PublicRaw(importEd25519PublicRaw(pair.publicKeyRaw)), pair.publicKeyRaw);

  const message = Buffer.from("lenscrew transcript bytes", "utf8");
  const signature = signTranscript(pair.privateSeed, message);
  assert.equal(signature.length, 64);
  assert.ok(verifyTranscript(pair.publicKeyRaw, message, signature));
  assert.ok(!verifyTranscript(pair.publicKeyRaw, Buffer.from("tampered"), signature));
  const other = generateEd25519SeedKeyPair();
  assert.ok(!verifyTranscript(other.publicKeyRaw, message, signature));
  // 畸形签名不许抛异常,必须按 false 处理
  assert.ok(!verifyTranscript(pair.publicKeyRaw, message, Buffer.alloc(3)));
});

test("X25519 raw 往返互转与共享密钥双向一致", () => {
  const a = generateX25519KeyPairRaw();
  const b = generateX25519KeyPairRaw();
  assert.deepEqual(x25519PublicRawFromPrivate(a.privateKeyRaw), a.publicKeyRaw);
  const ab = x25519SharedSecret(a.privateKeyRaw, b.publicKeyRaw);
  const ba = x25519SharedSecret(b.privateKeyRaw, a.publicKeyRaw);
  assert.equal(ab.length, 32);
  assert.deepEqual(ab, ba);
});

// MARK: - envelope

const envelopeKey = Buffer.alloc(32, 7);
const envelopeBase = {
  key: envelopeKey,
  roomId: "room-1",
  keyEpoch: 1,
  sender: "phone",
  counter: 1,
  plaintext: "你好 from phone",
} as const;

test("envelope 往返:密文可解回原文", () => {
  const envelope = sealEnvelope(envelopeBase);
  assert.equal(envelope.kind, "encryptedEnvelope");
  assert.equal(envelope.v, 1);
  assert.equal(openEnvelope({ key: envelopeKey, envelope }), envelopeBase.plaintext);
});

test("envelope AAD 篡改任一头字段都解密失败", () => {
  const envelope = sealEnvelope(envelopeBase);
  assert.throws(() => openEnvelope({ key: envelopeKey, envelope: { ...envelope, roomId: "room-2" } }));
  assert.throws(() => openEnvelope({ key: envelopeKey, envelope: { ...envelope, keyEpoch: 2 } }));
  assert.throws(() => openEnvelope({ key: envelopeKey, envelope: { ...envelope, sender: "mac" } }));
  assert.throws(() => openEnvelope({ key: envelopeKey, envelope: { ...envelope, counter: 2 } }));
  assert.throws(() =>
    openEnvelope({ key: envelopeKey, envelope: { ...envelope, tag: Buffer.alloc(16).toString("base64") } }),
  );
  assert.throws(() => openEnvelope({ key: Buffer.alloc(32, 8), envelope }));
});

test("envelope 不同 counter/sender 得到不同 nonce 与密文", () => {
  const c1 = sealEnvelope(envelopeBase);
  const c2 = sealEnvelope({ ...envelopeBase, counter: 2 });
  const asMac = sealEnvelope({ ...envelopeBase, sender: "mac" });
  assert.notEqual(c1.ciphertext, c2.ciphertext);
  assert.notEqual(c1.ciphertext, asMac.ciphertext);
});

// MARK: - deriveKeys

test("deriveKeys 双方向密钥独立且确定", () => {
  const transcript = buildTranscript(baseTranscriptParams);
  const params = {
    sharedSecret: Buffer.alloc(32, 3),
    transcript,
    roomId: "room-1",
    macDeviceId: "mac-1",
    phoneDeviceId: "phone-1",
    keyEpoch: 1,
  };
  const keys = deriveKeys(params);
  assert.equal(keys.phoneToMac.length, 32);
  assert.equal(keys.macToPhone.length, 32);
  assert.notDeepEqual(keys.phoneToMac, keys.macToPhone);
  assert.deepEqual(deriveKeys(params), keys);
  assert.notDeepEqual(deriveKeys({ ...params, keyEpoch: 2 }), keys);
});

// MARK: - 跨语言 fixture

const fixtureText = readFileSync(E2EE_FIXTURE_URL, "utf8");

test("fixture 文件与实现重新生成的内容逐字节一致", () => {
  assert.equal(fixtureText, renderE2eeFixtureJson());
});

test("fixture 期望值可由密码学原语独立重算并验证", () => {
  const doc = JSON.parse(fixtureText) as { inputs: E2eeFixtureInputs; expected: E2eeFixtureExpected };
  const { inputs, expected } = doc;
  assert.deepEqual(inputs, E2EE_FIXTURE_INPUTS);

  const macSeed = Buffer.from(inputs.macIdentitySeedBase64, "base64");
  const phoneSeed = Buffer.from(inputs.phoneIdentitySeedBase64, "base64");
  const macEphPriv = Buffer.from(inputs.macEphemeralPrivateKeyBase64, "base64");
  const phoneEphPriv = Buffer.from(inputs.phoneEphemeralPrivateKeyBase64, "base64");

  const macPub = ed25519PublicRawFromSeed(macSeed);
  const phonePub = ed25519PublicRawFromSeed(phoneSeed);
  const macEphPub = x25519PublicRawFromPrivate(macEphPriv);
  const phoneEphPub = x25519PublicRawFromPrivate(phoneEphPriv);
  assert.equal(macPub.toString("base64"), expected.macIdentityPublicKeyBase64);
  assert.equal(phonePub.toString("base64"), expected.phoneIdentityPublicKeyBase64);
  assert.equal(macEphPub.toString("base64"), expected.macEphemeralPublicKeyBase64);
  assert.equal(phoneEphPub.toString("base64"), expected.phoneEphemeralPublicKeyBase64);

  const transcript = buildTranscript({
    roomId: inputs.roomId,
    protocolVersion: inputs.protocolVersion,
    handshakeMode: inputs.handshakeMode,
    keyEpoch: inputs.keyEpoch,
    macDeviceId: inputs.macDeviceId,
    phoneDeviceId: inputs.phoneDeviceId,
    macIdentityPublicKey: expected.macIdentityPublicKeyBase64,
    phoneIdentityPublicKey: expected.phoneIdentityPublicKeyBase64,
    macEphemeralPublicKey: expected.macEphemeralPublicKeyBase64,
    phoneEphemeralPublicKey: expected.phoneEphemeralPublicKeyBase64,
    clientNonce: inputs.clientNonceBase64,
    serverNonce: inputs.serverNonceBase64,
    pairingExpiresAtMs: inputs.pairingExpiresAtMs,
  });
  assert.equal(sha256Hex(transcript), expected.transcriptSha256Hex);

  assert.equal(signTranscript(macSeed, transcript).toString("base64"), expected.macSignatureBase64);
  assert.ok(verifyTranscript(macPub, transcript, Buffer.from(expected.macSignatureBase64, "base64")));
  const clientAuthMessage = buildClientAuthMessage(transcript);
  assert.equal(signTranscript(phoneSeed, clientAuthMessage).toString("base64"), expected.phoneSignatureBase64);
  assert.ok(verifyTranscript(phonePub, clientAuthMessage, Buffer.from(expected.phoneSignatureBase64, "base64")));
  // 域分隔:phone 的 clientAuth 签名不能被当作裸 transcript 签名使用
  assert.ok(!verifyTranscript(phonePub, transcript, Buffer.from(expected.phoneSignatureBase64, "base64")));

  assert.equal(x25519SharedSecret(macEphPriv, phoneEphPub).toString("hex"), expected.sharedSecretHex);
  assert.equal(x25519SharedSecret(phoneEphPriv, macEphPub).toString("hex"), expected.sharedSecretHex);

  const keys = deriveKeys({
    sharedSecret: Buffer.from(expected.sharedSecretHex, "hex"),
    transcript,
    roomId: inputs.roomId,
    macDeviceId: inputs.macDeviceId,
    phoneDeviceId: inputs.phoneDeviceId,
    keyEpoch: inputs.keyEpoch,
  });
  assert.equal(keys.phoneToMac.toString("hex"), expected.keyPhoneToMacHex);
  assert.equal(keys.macToPhone.toString("hex"), expected.keyMacToPhoneHex);

  for (const item of expected.envelopes) {
    const key = item.envelope.sender === "phone" ? keys.phoneToMac : keys.macToPhone;
    assert.equal(openEnvelope({ key, envelope: item.envelope }), item.plaintextUtf8);
    // AES-GCM 对固定 key/nonce/AAD 确定,重加密必须逐字节复现 fixture 信封
    assert.deepEqual(
      sealEnvelope({
        key,
        roomId: item.envelope.roomId,
        keyEpoch: item.envelope.keyEpoch,
        sender: item.envelope.sender,
        counter: item.envelope.counter,
        plaintext: item.plaintextUtf8,
      }),
      item.envelope,
    );
  }
});
