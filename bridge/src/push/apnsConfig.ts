// APNs 配置:状态目录下的 apns.json。缺文件/缺字段/坏 JSON 一律返回 null,
// 上层据此整体禁用推送并只日志一次,而不是让 bridge 启动失败。

import { readFileSync } from "node:fs";
import { isAbsolute, join } from "node:path";

export const APNS_CONFIG_FILE = "apns.json";

export interface ApnsConfig {
  teamId: string;
  keyId: string;
  bundleId: string;
  privateKeyPem: string;
}

/**
 * apns.json 结构:{ teamId, keyId, bundleId, privateKey 或 privateKeyPath }。
 * privateKey 直接内嵌 PEM;privateKeyPath 相对状态目录或绝对路径。
 */
export function loadApnsConfig(stateDir: string): ApnsConfig | null {
  let rawText: string;
  try {
    rawText = readFileSync(join(stateDir, APNS_CONFIG_FILE), "utf8");
  } catch {
    return null;
  }
  let raw: unknown;
  try {
    raw = JSON.parse(rawText);
  } catch {
    return null;
  }
  if (typeof raw !== "object" || raw === null) return null;
  const record = raw as Record<string, unknown>;

  const teamId = nonEmptyString(record["teamId"]);
  const keyId = nonEmptyString(record["keyId"]);
  const bundleId = nonEmptyString(record["bundleId"]);
  if (teamId === null || keyId === null || bundleId === null) return null;

  const inlineKey = nonEmptyString(record["privateKey"]);
  if (inlineKey !== null) {
    return { teamId, keyId, bundleId, privateKeyPem: inlineKey };
  }

  const keyPath = nonEmptyString(record["privateKeyPath"]);
  if (keyPath === null) return null;
  const resolved = isAbsolute(keyPath) ? keyPath : join(stateDir, keyPath);
  try {
    return { teamId, keyId, bundleId, privateKeyPem: readFileSync(resolved, "utf8") };
  } catch {
    return null;
  }
}

function nonEmptyString(value: unknown): string | null {
  return typeof value === "string" && value !== "" ? value : null;
}
