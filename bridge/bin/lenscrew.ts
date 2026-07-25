#!/usr/bin/env node
import { createHash, randomBytes } from "node:crypto";
import { chmodSync, writeFileSync } from "node:fs";
import { hostname, networkInterfaces } from "node:os";
import { join } from "node:path";

import { defaultAdapterFactory } from "../src/adapters/registry.ts";
import { SessionHub } from "../src/session/hub.ts";
import { createBridgeServer } from "../src/transport/server.ts";
import { createRelayServer } from "../src/relay/relayServer.ts";
import { startRelayClient } from "../src/relay/relayClient.ts";
import { SecureGateway } from "../src/secure/secureGateway.ts";
import {
  loadOrCreateIdentity,
  resolveStateDir,
  STATE_DIR_ENV,
  type BridgeIdentity,
} from "../src/state/stateDir.ts";

const PAIRING_WINDOW_MS = 5 * 60_000;

interface UpOptions {
  host: string;
  port: number;
  token: string;
  relay: string | null;
  name: string;
  stateDir: string | null;
}

function parseUpArguments(argv: string[]): UpOptions {
  // 默认只监听回环。要让手机连上必须显式 --host,
  // 免得在咖啡馆的 Wi-Fi 上不知不觉把本机 agent 暴露出去。
  const options: UpOptions = {
    host: "127.0.0.1",
    port: 4311,
    token: process.env["LENSCREW_TOKEN"] ?? randomBytes(24).toString("base64url"),
    relay: null,
    name: hostname(),
    stateDir: null,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (flag === "--host" && value) {
      options.host = value;
      index += 1;
    } else if (flag === "--port" && value) {
      const port = Number(value);
      // 0 = 交给系统挑随机端口,实际端口会写进 admin.json
      if (!Number.isInteger(port) || port < 0 || port > 65535) {
        throw new Error(`端口不合法: ${value}`);
      }
      options.port = port;
      index += 1;
    } else if (flag === "--token" && value) {
      options.token = value;
      index += 1;
    } else if (flag === "--relay" && value) {
      options.relay = value.replace(/\/+$/, "");
      index += 1;
    } else if (flag === "--name" && value) {
      options.name = value;
      index += 1;
    } else if (flag === "--state-dir" && value) {
      options.stateDir = value;
      index += 1;
    } else if (flag === "--help" || flag === "-h") {
      printHelp();
      process.exit(0);
    }
  }
  return options;
}

function printHelp(): void {
  process.stdout.write(
    [
      "用法: lenscrew up [选项]        启动 bridge",
      "      lenscrew relay [选项]     启动自架中继服务器",
      "",
      "up 选项:",
      "  --host <地址>      监听地址,默认 127.0.0.1。手机走局域网直连需传局域网地址或 0.0.0.0",
      "  --port <端口>      监听端口,默认 4311;0 表示随机端口(写入 admin.json)",
      "  --token <口令>     /events /command 的访问口令,默认随机(也可用 LENSCREW_TOKEN)",
      "  --relay <url>      启用远程中继,如 https://relay.example",
      "  --name <名字>      配对时展示的设备名,默认本机 hostname",
      "  --state-dir <目录> 状态目录(身份/信任表),等价环境变量 " + STATE_DIR_ENV,
      "",
      "relay 选项:",
      "  --host <地址>      监听地址,默认 0.0.0.0",
      "  --port <端口>      监听端口,默认 4370",
      "",
    ].join("\n"),
  );
}

function reachableAddresses(host: string): string[] {
  if (host !== "0.0.0.0") return [host];
  return Object.values(networkInterfaces())
    .flatMap((entries) => entries ?? [])
    .filter((entry) => entry.family === "IPv4" && !entry.internal)
    .map((entry) => entry.address);
}

function isLoopbackHost(host: string): boolean {
  return host === "127.0.0.1" || host === "localhost" || host === "::1";
}

/** 身份公钥指纹,配对时人眼比对用:SHA-256 前 16 hex */
function identityFingerprint(identity: BridgeIdentity): string {
  return createHash("sha256")
    .update(Buffer.from(identity.identityPublicKey, "base64"))
    .digest("hex")
    .slice(0, 16);
}

interface PairPayloadInputs {
  identity: BridgeIdentity;
  displayName: string;
  expiresAtMs: number;
  relay: string | null;
  host: string;
  port: number;
}

/** 配对 payload:QR 渲染是另一任务,这里保证 `lenscrew qr` 与启动日志拿到同一结构 */
function buildPairPayload(inputs: PairPayloadInputs): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    v: 1,
    kind: "lenscrew-pair",
    macDeviceId: inputs.identity.macDeviceId,
    macIdentityPublicKey: inputs.identity.identityPublicKey,
    displayName: inputs.displayName,
    expiresAtMs: inputs.expiresAtMs,
  };
  if (inputs.relay !== null) {
    payload["relay"] = inputs.relay;
  }
  if (!isLoopbackHost(inputs.host)) {
    // 通配地址本身连不了,取本机首个非回环 IPv4;具体地址则原样用
    const lanHost = inputs.host === "0.0.0.0" ? reachableAddresses("0.0.0.0")[0] : inputs.host;
    if (lanHost !== undefined) {
      payload["lan"] = { host: lanHost, port: inputs.port };
    }
  }
  return payload;
}

function writeSecretFile(path: string, value: unknown): void {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  // mode 只在新建时生效,覆盖旧文件后要重新收紧
  chmodSync(path, 0o600);
}

async function runUp(options: UpOptions): Promise<void> {
  const stateDir = resolveStateDir(
    options.stateDir !== null ? { [STATE_DIR_ENV]: options.stateDir } : process.env,
  );
  const identity = loadOrCreateIdentity(stateDir);

  // 配对窗口:启动即开 5 分钟,之后靠 /admin/pairing 重开
  let pairingExpiresAtMs = Date.now() + PAIRING_WINDOW_MS;
  const pairingWindow = {
    isOpen: () => Date.now() < pairingExpiresAtMs,
    expiresAtMs: () => pairingExpiresAtMs,
    reopen: (): number => {
      pairingExpiresAtMs = Date.now() + PAIRING_WINDOW_MS;
      return pairingExpiresAtMs;
    },
  };

  const hub = new SessionHub(defaultAdapterFactory);
  const gateway = new SecureGateway({
    hub,
    identity,
    stateDir,
    displayName: options.name,
    pairingWindow,
  });

  const adminToken = randomBytes(24).toString("base64url");
  const pairPayload = (): Record<string, unknown> =>
    buildPairPayload({
      identity,
      displayName: options.name,
      expiresAtMs: pairingExpiresAtMs,
      relay: options.relay,
      host: options.host,
      port: boundPort(),
    });

  const server = createBridgeServer({
    hub,
    token: options.token,
    host: options.host,
    port: options.port,
    gateway,
    admin: {
      token: adminToken,
      reopenPairing: () => ({ expiresAtMs: pairingWindow.reopen(), pairPayload: pairPayload() }),
    },
  });

  const boundPort = (): number => {
    const address = server.address();
    return address !== null && typeof address === "object" ? address.port : options.port;
  };

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(options.port, options.host, resolve);
  });

  // admin.json 给同机的 `lenscrew qr` 用:端口 + 独立管理口令 + pid(判活)
  writeSecretFile(join(stateDir, "admin.json"), {
    port: boundPort(),
    adminToken,
    pid: process.pid,
  });

  process.stdout.write(`  macDeviceId ${identity.macDeviceId}\n`);
  process.stdout.write(`  身份指纹 ${identityFingerprint(identity)}\n`);
  process.stdout.write(`  配对窗口至 ${new Date(pairingExpiresAtMs).toISOString()}\n`);
  if (options.relay !== null) {
    process.stdout.write(`  relay 房间 ${options.relay}/v1/rooms/${identity.macDeviceId}\n`);
  }
  process.stdout.write(`  配对 payload ${JSON.stringify(pairPayload())}\n`);
  for (const address of reachableAddresses(options.host)) {
    process.stdout.write(`  http://${address}:${boundPort()}\n`);
  }
  process.stdout.write(`  口令 ${options.token}\n`);
  if (options.host === "127.0.0.1" && options.relay === null) {
    process.stdout.write("  仅监听回环,手机连不上;要连手机请加 --host 或 --relay\n");
  }

  const relayClient =
    options.relay !== null
      ? startRelayClient({
          relayUrl: options.relay,
          roomId: identity.macDeviceId,
          gateway,
          log: (line) => process.stdout.write(`  ${line}\n`),
        })
      : null;

  let shuttingDown = false;
  const shutdown = () => {
    if (shuttingDown) return;
    shuttingDown = true;
    relayClient?.close();
    gateway.close();
    server.close();
    // 不等 agent 进程自己退:用户按了 Ctrl-C 就该立刻还他终端
    void hub.closeAll().then(() => process.exit(0));
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

interface RelayOptions {
  host: string;
  port: number;
}

function parseRelayArguments(argv: string[]): RelayOptions {
  const options: RelayOptions = { host: "0.0.0.0", port: 4370 };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (flag === "--host" && value) {
      options.host = value;
      index += 1;
    } else if (flag === "--port" && value) {
      const port = Number(value);
      if (!Number.isInteger(port) || port < 0 || port > 65535) {
        throw new Error(`端口不合法: ${value}`);
      }
      options.port = port;
      index += 1;
    } else if (flag === "--help" || flag === "-h") {
      printHelp();
      process.exit(0);
    }
  }
  return options;
}

async function runRelay(options: RelayOptions): Promise<void> {
  const server = createRelayServer({ log: (line) => process.stdout.write(`  ${line}\n`) });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(options.port, options.host, resolve);
  });
  const address = server.address();
  const port = address !== null && typeof address === "object" ? address.port : options.port;
  process.stdout.write(`  relay 监听 http://${options.host}:${port}\n`);

  let shuttingDown = false;
  const shutdown = () => {
    if (shuttingDown) return;
    shuttingDown = true;
    server.close(() => process.exit(0));
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  if (argv[0] === "relay") {
    await runRelay(parseRelayArguments(argv.slice(1)));
    return;
  }
  const command = argv[0] === "up" ? argv.slice(1) : argv;
  await runUp(parseUpArguments(command));
}

main().catch((error: unknown) => {
  process.stderr.write(
    `启动失败: ${error instanceof Error ? error.message : String(error)}\n`,
  );
  process.exit(1);
});
