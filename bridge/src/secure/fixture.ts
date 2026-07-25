// e2ee-handshake.json 黄金样本的唯一生成器。
// 输入(测试密钥/随机数)全部写死成可读的字节模式;expected 由 crypto.ts 重算——
// 生成与测试共用同一段装配逻辑,fixture 文件被手改会立刻被逐字节比对测试抓住。

import { createHash } from "node:crypto";
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import {
  buildClientAuthMessage,
  buildTranscript,
  deriveKeys,
  ed25519PublicRawFromSeed,
  sealEnvelope,
  signTranscript,
  x25519PublicRawFromPrivate,
  x25519SharedSecret,
  type EncryptedEnvelope,
} from "./crypto.ts";

/** 连续递增字节,一眼可辨是测试值:0x00 起=mac 身份种子,0x20 起=phone 身份种子…… */
function patternBytes(start: number): Buffer {
  return Buffer.from(Array.from({ length: 32 }, (_, i) => (start + i) & 0xff));
}

export interface E2eeFixtureInputs {
  protocolVersion: number;
  handshakeMode: "qr_bootstrap";
  roomId: string;
  macDeviceId: string;
  phoneDeviceId: string;
  displayName: string;
  keyEpoch: number;
  pairingExpiresAtMs: number;
  macIdentitySeedBase64: string;
  phoneIdentitySeedBase64: string;
  macEphemeralPrivateKeyBase64: string;
  phoneEphemeralPrivateKeyBase64: string;
  clientNonceBase64: string;
  serverNonceBase64: string;
}

export const E2EE_FIXTURE_INPUTS: E2eeFixtureInputs = {
  protocolVersion: 1,
  handshakeMode: "qr_bootstrap",
  roomId: "11111111-1111-4111-8111-111111111111",
  macDeviceId: "11111111-1111-4111-8111-111111111111",
  phoneDeviceId: "22222222-2222-4222-8222-222222222222",
  displayName: "Fixture Mac",
  keyEpoch: 1,
  pairingExpiresAtMs: 1753500000000,
  macIdentitySeedBase64: patternBytes(0x00).toString("base64"),
  phoneIdentitySeedBase64: patternBytes(0x20).toString("base64"),
  macEphemeralPrivateKeyBase64: patternBytes(0x40).toString("base64"),
  phoneEphemeralPrivateKeyBase64: patternBytes(0x60).toString("base64"),
  clientNonceBase64: patternBytes(0x80).toString("base64"),
  serverNonceBase64: patternBytes(0xa0).toString("base64"),
};

export interface E2eeFixtureEnvelopeCase {
  plaintextUtf8: string;
  envelope: EncryptedEnvelope;
}

export interface E2eeFixtureExpected {
  macIdentityPublicKeyBase64: string;
  phoneIdentityPublicKeyBase64: string;
  macEphemeralPublicKeyBase64: string;
  phoneEphemeralPublicKeyBase64: string;
  transcriptSha256Hex: string;
  macSignatureBase64: string;
  phoneSignatureBase64: string;
  sharedSecretHex: string;
  keyPhoneToMacHex: string;
  keyMacToPhoneHex: string;
  envelopes: E2eeFixtureEnvelopeCase[];
}

export function computeE2eeFixtureExpected(inputs: E2eeFixtureInputs): E2eeFixtureExpected {
  const macIdentitySeed = Buffer.from(inputs.macIdentitySeedBase64, "base64");
  const phoneIdentitySeed = Buffer.from(inputs.phoneIdentitySeedBase64, "base64");
  const macEphemeralPrivate = Buffer.from(inputs.macEphemeralPrivateKeyBase64, "base64");
  const phoneEphemeralPrivate = Buffer.from(inputs.phoneEphemeralPrivateKeyBase64, "base64");

  const macIdentityPublic = ed25519PublicRawFromSeed(macIdentitySeed);
  const phoneIdentityPublic = ed25519PublicRawFromSeed(phoneIdentitySeed);
  const macEphemeralPublic = x25519PublicRawFromPrivate(macEphemeralPrivate);
  const phoneEphemeralPublic = x25519PublicRawFromPrivate(phoneEphemeralPrivate);

  const transcript = buildTranscript({
    roomId: inputs.roomId,
    protocolVersion: inputs.protocolVersion,
    handshakeMode: inputs.handshakeMode,
    keyEpoch: inputs.keyEpoch,
    macDeviceId: inputs.macDeviceId,
    phoneDeviceId: inputs.phoneDeviceId,
    macIdentityPublicKey: macIdentityPublic.toString("base64"),
    phoneIdentityPublicKey: phoneIdentityPublic.toString("base64"),
    macEphemeralPublicKey: macEphemeralPublic.toString("base64"),
    phoneEphemeralPublicKey: phoneEphemeralPublic.toString("base64"),
    clientNonce: inputs.clientNonceBase64,
    serverNonce: inputs.serverNonceBase64,
    pairingExpiresAtMs: inputs.pairingExpiresAtMs,
  });

  const sharedSecret = x25519SharedSecret(macEphemeralPrivate, phoneEphemeralPublic);
  const keys = deriveKeys({
    sharedSecret,
    transcript,
    roomId: inputs.roomId,
    macDeviceId: inputs.macDeviceId,
    phoneDeviceId: inputs.phoneDeviceId,
    keyEpoch: inputs.keyEpoch,
  });

  const common = { roomId: inputs.roomId, keyEpoch: inputs.keyEpoch } as const;
  const envelopeCase = (
    sender: "mac" | "phone",
    counter: number,
    plaintextUtf8: string,
  ): E2eeFixtureEnvelopeCase => ({
    plaintextUtf8,
    envelope: sealEnvelope({
      ...common,
      key: sender === "phone" ? keys.phoneToMac : keys.macToPhone,
      sender,
      counter,
      plaintext: plaintextUtf8,
    }),
  });

  return {
    macIdentityPublicKeyBase64: macIdentityPublic.toString("base64"),
    phoneIdentityPublicKeyBase64: phoneIdentityPublic.toString("base64"),
    macEphemeralPublicKeyBase64: macEphemeralPublic.toString("base64"),
    phoneEphemeralPublicKeyBase64: phoneEphemeralPublic.toString("base64"),
    transcriptSha256Hex: createHash("sha256").update(transcript).digest("hex"),
    macSignatureBase64: signTranscript(macIdentitySeed, transcript).toString("base64"),
    phoneSignatureBase64: signTranscript(phoneIdentitySeed, buildClientAuthMessage(transcript)).toString("base64"),
    sharedSecretHex: sharedSecret.toString("hex"),
    keyPhoneToMacHex: keys.phoneToMac.toString("hex"),
    keyMacToPhoneHex: keys.macToPhone.toString("hex"),
    envelopes: [
      envelopeCase("phone", 1, "hello from phone"),
      envelopeCase("mac", 1, "hello from mac"),
      envelopeCase("phone", 2, '{"t":"cmd","id":1,"data":{"type":"listSessions"}}'),
    ],
  };
}

const FIXTURE_COMMENT =
  "跨语言 E2EE 握手黄金样本。inputs 是写死的测试密钥/随机数(仅供 fixture,严禁用于生产);" +
  "expected 是 bridge/src/secure/crypto.ts 对这些输入的确定性输出:transcript(14 字段长度前缀拼接)的 SHA-256、" +
  "Ed25519 签名(clientAuth 带 client-auth 域分隔)、X25519 共享密钥、HKDF-SHA256 方向密钥、AES-256-GCM 信封。" +
  "iOS 侧用 CryptoKit 按相同输入必须逐字节复现全部 expected。" +
  "本文件由 bridge/src/secure/fixture.ts 生成:cd bridge && node --input-type=module -e " +
  '"const m=await import(\'./src/secure/fixture.ts\');console.log(m.writeE2eeFixture())";' +
  "bridge/test/secure-crypto.test.ts 会断言本文件与重新生成的内容逐字节一致。";

export function renderE2eeFixtureJson(): string {
  const document = {
    _comment: FIXTURE_COMMENT,
    inputs: E2EE_FIXTURE_INPUTS,
    expected: computeE2eeFixtureExpected(E2EE_FIXTURE_INPUTS),
  };
  return `${JSON.stringify(document, null, 2)}\n`;
}

export const E2EE_FIXTURE_URL = new URL(
  "../../../protocol/fixtures/e2ee-handshake.json",
  import.meta.url,
);

export function writeE2eeFixture(): string {
  writeFileSync(E2EE_FIXTURE_URL, renderE2eeFixtureJson());
  return fileURLToPath(E2EE_FIXTURE_URL);
}
