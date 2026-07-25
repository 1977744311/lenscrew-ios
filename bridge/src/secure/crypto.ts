// LensCrew E2EE 密码学纯函数。零依赖(只 node:crypto),无 I/O、无内部随机态
// (密钥生成除外),所有派生/签名/封装对固定输入逐字节确定——
// protocol/fixtures/e2ee-handshake.json 与 iOS CryptoKit 实现都以此为准。
//
// raw 32 字节 ↔ KeyObject 互转走"固定 DER 前缀 + raw"的标准做法:
// SPKI/PKCS8 里除密钥本体外全是常量头,CryptoKit 的 rawRepresentation 与这里的
// raw 完全同构,跨语言只需要搬 32 字节。

import {
  createCipheriv,
  createDecipheriv,
  createHash,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  sign,
  verify,
  type KeyObject,
} from "node:crypto";

export const PROTOCOL_LABEL = "lenscrew-e2ee-v1";
export const CLIENT_AUTH_LABEL = "client-auth";

// MARK: - raw ↔ KeyObject

const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
const ED25519_PKCS8_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");
const X25519_SPKI_PREFIX = Buffer.from("302a300506032b656e032100", "hex");
const X25519_PKCS8_PREFIX = Buffer.from("302e020100300506032b656e04220420", "hex");

function assertRaw32(raw: Uint8Array, what: string): void {
  if (raw.byteLength !== 32) {
    throw new Error(`${what} must be 32 bytes, got ${raw.byteLength}`);
  }
}

function importPrivateRaw(prefix: Buffer, raw: Uint8Array, what: string): KeyObject {
  assertRaw32(raw, what);
  return createPrivateKey({ key: Buffer.concat([prefix, raw]), format: "der", type: "pkcs8" });
}

function importPublicRaw(prefix: Buffer, raw: Uint8Array, what: string): KeyObject {
  assertRaw32(raw, what);
  return createPublicKey({ key: Buffer.concat([prefix, raw]), format: "der", type: "spki" });
}

// SPKI/PKCS8 DER 的最后 32 字节就是密钥本体,对 ed25519/x25519 都成立
function derTail32(der: Buffer): Buffer {
  return Buffer.from(der.subarray(der.length - 32));
}

export function importEd25519PrivateSeed(seed: Uint8Array): KeyObject {
  return importPrivateRaw(ED25519_PKCS8_PREFIX, seed, "ed25519 seed");
}

export function importEd25519PublicRaw(raw: Uint8Array): KeyObject {
  return importPublicRaw(ED25519_SPKI_PREFIX, raw, "ed25519 public key");
}

export function exportEd25519PublicRaw(key: KeyObject): Buffer {
  return derTail32(key.export({ format: "der", type: "spki" }));
}

export function exportEd25519PrivateSeed(key: KeyObject): Buffer {
  return derTail32(key.export({ format: "der", type: "pkcs8" }));
}

export function ed25519PublicRawFromSeed(seed: Uint8Array): Buffer {
  return exportEd25519PublicRaw(createPublicKey(importEd25519PrivateSeed(seed)));
}

export function generateEd25519SeedKeyPair(): { publicKeyRaw: Buffer; privateSeed: Buffer } {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return {
    publicKeyRaw: exportEd25519PublicRaw(publicKey),
    privateSeed: exportEd25519PrivateSeed(privateKey),
  };
}

export function importX25519PrivateRaw(raw: Uint8Array): KeyObject {
  return importPrivateRaw(X25519_PKCS8_PREFIX, raw, "x25519 private key");
}

export function importX25519PublicRaw(raw: Uint8Array): KeyObject {
  return importPublicRaw(X25519_SPKI_PREFIX, raw, "x25519 public key");
}

export function x25519PublicRawFromPrivate(raw: Uint8Array): Buffer {
  return derTail32(
    createPublicKey(importX25519PrivateRaw(raw)).export({ format: "der", type: "spki" }),
  );
}

export function generateX25519KeyPairRaw(): { publicKeyRaw: Buffer; privateKeyRaw: Buffer } {
  const { publicKey, privateKey } = generateKeyPairSync("x25519");
  return {
    publicKeyRaw: derTail32(publicKey.export({ format: "der", type: "spki" })),
    privateKeyRaw: derTail32(privateKey.export({ format: "der", type: "pkcs8" })),
  };
}

export function x25519SharedSecret(privateKeyRaw: Uint8Array, peerPublicRaw: Uint8Array): Buffer {
  return diffieHellman({
    privateKey: importX25519PrivateRaw(privateKeyRaw),
    publicKey: importX25519PublicRaw(peerPublicRaw),
  });
}

// MARK: - transcript

/**
 * 每字段 4 字节大端长度前缀再拼接。长度前缀让字段边界无歧义,
 * 否则 ("ab","c") 与 ("a","bc") 会拼出同一串字节,签名就能被跨字段挪移。
 */
export function lengthPrefixed(fields: readonly Uint8Array[]): Buffer {
  const parts: Uint8Array[] = [];
  for (const field of fields) {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(field.byteLength, 0);
    parts.push(len, field);
  }
  return Buffer.concat(parts);
}

export interface TranscriptParams {
  roomId: string;
  protocolVersion: number;
  handshakeMode: string;
  keyEpoch: number;
  macDeviceId: string;
  phoneDeviceId: string;
  /** 以下四个密钥字段与两个 nonce 都是 base64 字符串原文,不解码——跨语言只比字符串 */
  macIdentityPublicKey: string;
  phoneIdentityPublicKey: string;
  macEphemeralPublicKey: string;
  phoneEphemeralPublicKey: string;
  clientNonce: string;
  serverNonce: string;
  pairingExpiresAtMs: number;
}

/** 14 字段定序 transcript,双方各自重建,任何一字段不一致签名即失效 */
export function buildTranscript(p: TranscriptParams): Buffer {
  const fields = [
    PROTOCOL_LABEL,
    p.roomId,
    String(p.protocolVersion),
    p.handshakeMode,
    String(p.keyEpoch),
    p.macDeviceId,
    p.phoneDeviceId,
    p.macIdentityPublicKey,
    p.phoneIdentityPublicKey,
    p.macEphemeralPublicKey,
    p.phoneEphemeralPublicKey,
    p.clientNonce,
    p.serverNonce,
    String(p.pairingExpiresAtMs),
  ];
  return lengthPrefixed(fields.map((f) => Buffer.from(f, "utf8")));
}

/** clientAuth 的签名域分隔:phone 签的不是裸 transcript,防止与 mac 签名互相冒用 */
export function buildClientAuthMessage(transcript: Uint8Array): Buffer {
  return Buffer.concat([transcript, lengthPrefixed([Buffer.from(CLIENT_AUTH_LABEL, "utf8")])]);
}

export function signTranscript(privateSeed: Uint8Array, message: Uint8Array): Buffer {
  return sign(null, message, importEd25519PrivateSeed(privateSeed));
}

export function verifyTranscript(
  publicKeyRaw: Uint8Array,
  message: Uint8Array,
  signature: Uint8Array,
): boolean {
  try {
    return verify(null, message, importEd25519PublicRaw(publicKeyRaw), signature);
  } catch {
    // 畸形签名/公钥按验签失败处理,不让网络输入把异常抛进状态机
    return false;
  }
}

// MARK: - 密钥派生

export interface DeriveKeysParams {
  sharedSecret: Uint8Array;
  transcript: Uint8Array;
  roomId: string;
  macDeviceId: string;
  phoneDeviceId: string;
  keyEpoch: number;
}

export interface DirectionalKeys {
  phoneToMac: Buffer;
  macToPhone: Buffer;
}

/** salt 绑定完整 transcript,info 绑定会话身份与方向:两个方向的密钥完全独立 */
export function deriveKeys(p: DeriveKeysParams): DirectionalKeys {
  const salt = createHash("sha256").update(p.transcript).digest();
  const infoBase = `${PROTOCOL_LABEL}|${p.roomId}|${p.macDeviceId}|${p.phoneDeviceId}|${p.keyEpoch}`;
  const derive = (direction: "phoneToMac" | "macToPhone"): Buffer =>
    Buffer.from(hkdfSync("sha256", p.sharedSecret, salt, `${infoBase}|${direction}`, 32));
  return { phoneToMac: derive("phoneToMac"), macToPhone: derive("macToPhone") };
}

// MARK: - AES-256-GCM 信封

export type EnvelopeSender = "mac" | "phone";

export interface EncryptedEnvelope {
  kind: "encryptedEnvelope";
  v: 1;
  roomId: string;
  keyEpoch: number;
  sender: EnvelopeSender;
  counter: number;
  ciphertext: string;
  tag: string;
}

/**
 * nonce 12B = [方向字节, counter 的 11 字节大端]。方向字节隔开双方 nonce 空间,
 * counter 单调递增保证同 key 下 nonce 永不重复(GCM 的硬性要求)。
 * counter 是 JS safe integer(< 2^53),11 字节大端 = 3 字节 0 + 8 字节 BE。
 */
function envelopeNonce(sender: EnvelopeSender, counter: number): Buffer {
  if (!Number.isSafeInteger(counter) || counter < 0) {
    throw new Error(`envelope counter must be a non-negative safe integer, got ${counter}`);
  }
  const nonce = Buffer.alloc(12);
  nonce[0] = sender === "mac" ? 1 : 2;
  nonce.writeBigUInt64BE(BigInt(counter), 4);
  return nonce;
}

/** AAD 把路由元数据绑进认证标签:改动任何一个明文头字段都会解密失败 */
function envelopeAad(roomId: string, keyEpoch: number, sender: EnvelopeSender, counter: number): Buffer {
  return Buffer.from(`${roomId}|${keyEpoch}|${sender}|${counter}`, "utf8");
}

export interface SealEnvelopeParams {
  key: Uint8Array;
  roomId: string;
  keyEpoch: number;
  sender: EnvelopeSender;
  counter: number;
  plaintext: string;
}

export function sealEnvelope(p: SealEnvelopeParams): EncryptedEnvelope {
  const cipher = createCipheriv("aes-256-gcm", p.key, envelopeNonce(p.sender, p.counter));
  cipher.setAAD(envelopeAad(p.roomId, p.keyEpoch, p.sender, p.counter));
  const ciphertext = Buffer.concat([cipher.update(p.plaintext, "utf8"), cipher.final()]);
  return {
    kind: "encryptedEnvelope",
    v: 1,
    roomId: p.roomId,
    keyEpoch: p.keyEpoch,
    sender: p.sender,
    counter: p.counter,
    ciphertext: ciphertext.toString("base64"),
    tag: cipher.getAuthTag().toString("base64"),
  };
}

/** 按信封自带的头字段重建 nonce/AAD 解密;认证失败(含任何头字段被篡改)直接抛错 */
export function openEnvelope(p: { key: Uint8Array; envelope: EncryptedEnvelope }): string {
  const e = p.envelope;
  const decipher = createDecipheriv("aes-256-gcm", p.key, envelopeNonce(e.sender, e.counter));
  decipher.setAAD(envelopeAad(e.roomId, e.keyEpoch, e.sender, e.counter));
  decipher.setAuthTag(Buffer.from(e.tag, "base64"));
  return Buffer.concat([
    decipher.update(Buffer.from(e.ciphertext, "base64")),
    decipher.final(),
  ]).toString("utf8");
}
