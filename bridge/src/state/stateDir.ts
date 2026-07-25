// bridge 的持久状态目录:mac 身份密钥与手机信任表。
// 这是 secure/ 之外唯一碰磁盘的地方,channel.ts 只通过回调消费这里的读写。

import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

import { generateEd25519SeedKeyPair } from "../secure/crypto.ts";

export const STATE_DIR_ENV = "LENSCREW_STATE_DIR";

const IDENTITY_FILE = "identity.json";
const TRUSTED_PHONES_FILE = "trusted-phones.json";

/** 环境变量优先(测试与多实例隔离用),否则 ~/.lenscrew;确保存在且仅本用户可进 */
export function resolveStateDir(env: Record<string, string | undefined> = process.env): string {
  const fromEnv = env[STATE_DIR_ENV];
  const dir = fromEnv !== undefined && fromEnv !== "" ? fromEnv : join(homedir(), ".lenscrew");
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  return dir;
}

export interface BridgeIdentity {
  version: 1;
  macDeviceId: string;
  /** Ed25519 raw 32B base64——不用 DER,跨语言(CryptoKit rawRepresentation)最简 */
  identityPublicKey: string;
  /** Ed25519 seed 32B base64 */
  identityPrivateKey: string;
  createdAtMs: number;
}

/** 首次生成写盘,之后原样读回:mac 身份在重装 App 之外必须终身稳定,手机信任表才有意义 */
export function loadOrCreateIdentity(dir: string, now: () => number = Date.now): BridgeIdentity {
  const path = join(dir, IDENTITY_FILE);
  if (existsSync(path)) {
    return JSON.parse(readFileSync(path, "utf8")) as BridgeIdentity;
  }
  const { publicKeyRaw, privateSeed } = generateEd25519SeedKeyPair();
  const identity: BridgeIdentity = {
    version: 1,
    macDeviceId: randomUUID(),
    identityPublicKey: publicKeyRaw.toString("base64"),
    identityPrivateKey: privateSeed.toString("base64"),
    createdAtMs: now(),
  };
  writeSecretJson(path, identity);
  return identity;
}

export interface TrustedPhone {
  /** phone 的 Ed25519 身份公钥 raw 32B base64 */
  identityPublicKey: string;
  name?: string;
  addedAtMs: number;
}

/** key 是 phoneDeviceId */
export type TrustedPhones = Record<string, TrustedPhone>;

export function loadTrustedPhones(dir: string): TrustedPhones {
  const path = join(dir, TRUSTED_PHONES_FILE);
  if (!existsSync(path)) {
    return {};
  }
  return JSON.parse(readFileSync(path, "utf8")) as TrustedPhones;
}

export function saveTrustedPhones(dir: string, phones: TrustedPhones): void {
  writeSecretJson(join(dir, TRUSTED_PHONES_FILE), phones);
}

function writeSecretJson(path: string, value: unknown): void {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  // writeFileSync 的 mode 只在新建时生效,覆盖已有文件后要重新收紧
  chmodSync(path, 0o600);
}
