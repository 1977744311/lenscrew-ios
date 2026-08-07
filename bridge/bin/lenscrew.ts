#!/usr/bin/env node
import { createHash, randomBytes } from "node:crypto";
import { chmodSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { hostname, networkInterfaces } from "node:os";
import { join } from "node:path";

import { defaultAdapterFactory } from "../src/adapters/registry.ts";
import { SessionHub } from "../src/session/hub.ts";
import { startQuotaProbe } from "../src/session/quotaProbe.ts";
import { loadPersistedSessions, savePersistedSessions } from "../src/state/sessionStore.ts";
import { createBridgeServer } from "../src/transport/server.ts";
import { createRelayServer } from "../src/relay/relayServer.ts";
import { startRelayClient } from "../src/relay/relayClient.ts";
import { SecureGateway, loadPushTokens, type PushTokens } from "../src/secure/secureGateway.ts";
import { loadApnsConfig } from "../src/push/apnsConfig.ts";
import {
  createApnsClient,
  type ApnsClient,
  type ApnsEnvironment,
} from "../src/push/apnsClient.ts";
import { createPushDispatcher, type PushTokenRegistry } from "../src/push/pushDispatcher.ts";
import { renderPairingQr } from "../src/qr/index.ts";
import { installService, serviceStatus, uninstallService } from "../src/service/launchd.ts";
import type { BridgeEvent } from "../src/protocol/events.ts";
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
  /** 非回环监听时仍放行明文 /events /command /git；默认关 */
  allowPlaintextLan: boolean;
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
    allowPlaintextLan: false,
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
    } else if (flag === "--allow-plaintext-lan") {
      options.allowPlaintextLan = true;
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
      "      lenscrew qr [选项]        重开配对窗口并打印二维码",
      "      lenscrew relay [选项]     启动自架中继服务器",
      "      lenscrew service install [up 选项]   装成 launchd 常驻(开机自启/崩溃拉起)",
      "      lenscrew service uninstall           停止并卸载常驻",
      "      lenscrew service status              查看常驻状态",
      "",
      "up 选项:",
      "  --host <地址>      监听地址,默认 127.0.0.1。手机走局域网直连需传局域网地址或 0.0.0.0",
      "  --port <端口>      监听端口,默认 4311;0 表示随机端口(写入 admin.json)",
      "  --token <口令>     /events /command 的访问口令,默认随机(也可用 LENSCREW_TOKEN)",
      "  --relay <url>      启用远程中继,如 https://relay.example",
      "  --name <名字>      配对时展示的设备名,默认本机 hostname",
      "  --state-dir <目录> 状态目录(身份/信任表),等价环境变量 " + STATE_DIR_ENV,
      "  --allow-plaintext-lan  非回环监听时仍放行明文 /events /command /git(默认拒绝,请走 E2EE)",
      "",
      "qr 选项:",
      "  --state-dir <目录> 状态目录,需与运行中的 bridge 一致",
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

/** 配对 payload → 终端可扫二维码;payload 太长(超 QR 容量)时退回只打 JSON */
function printPairingQr(payload: Record<string, unknown>): void {
  try {
    process.stdout.write(`\n${renderPairingQr(JSON.stringify(payload))}\n`);
  } catch {
    process.stdout.write("  (配对内容过长,无法生成二维码;用上面的 payload 手动配对)\n");
  }
}

/**
 * push-tokens.json 的 environment 是手机侧口径(development/production),
 * APNs 客户端要的是主机口径(sandbox/production),在此翻译。
 */
function toPushRegistry(tokens: PushTokens): PushTokenRegistry {
  const registry: PushTokenRegistry = {};
  for (const [phoneDeviceId, record] of Object.entries(tokens)) {
    registry[phoneDeviceId] = {
      deviceToken: record.deviceToken,
      environment: record.environment === "development" ? "sandbox" : "production",
      alertsEnabled: record.alertsEnabled,
    };
  }
  return registry;
}

function sessionTitleFor(hub: SessionHub, event: BridgeEvent): string | undefined {
  const sessionId = (event as { sessionId?: string }).sessionId;
  if (sessionId === undefined) return undefined;
  return hub.listSessions().find((session) => session.id === sessionId)?.title;
}

/**
 * 把 hub 事件流接到 APNs。缺 apns.json 就整体禁用并只提示一次——
 * SSE 在 iOS 后台不存活,审批与完成通知要靠推送唤起。返回清理回调。
 */
function startPushBridge(hub: SessionHub, stateDir: string, macDeviceId: string): () => void {
  const config = loadApnsConfig(stateDir);
  if (config === null) {
    process.stdout.write("  APNs 未配置(缺 apns.json),审批/完成推送已禁用\n");
    return () => {};
  }
  const dispatcher = createPushDispatcher();
  const clients = new Map<ApnsEnvironment, ApnsClient>();
  const clientFor = (environment: ApnsEnvironment): ApnsClient => {
    const existing = clients.get(environment);
    if (existing !== undefined) return existing;
    const client = createApnsClient({ ...config, environment });
    clients.set(environment, client);
    return client;
  };
  const unsubscribe = hub.onEvent((event) => {
    const registry = toPushRegistry(loadPushTokens(stateDir));
    const title = sessionTitleFor(hub, event);
    // exactOptionalPropertyTypes:标题缺席时不能显式塞 undefined,得整个省略键
    const context = { macDeviceId, ...(title !== undefined && { sessionTitle: title }) };
    for (const push of dispatcher.dispatch(event, registry, context)) {
      void clientFor(push.environment)
        .send({ deviceToken: push.deviceToken, payload: push.payload })
        .then((result) => {
          if (result.tokenGone) dispatcher.markTokenGone(push.deviceToken);
        })
        .catch((error: unknown) => {
          process.stderr.write(`  推送失败: ${error instanceof Error ? error.message : String(error)}\n`);
        });
    }
  });
  process.stdout.write("  APNs 已就绪,审批与轮次完成将推送到已注册手机\n");
  return () => {
    unsubscribe();
    for (const client of clients.values()) client.close();
  };
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

  const hub = new SessionHub(defaultAdapterFactory, {
    load: () => loadPersistedSessions(stateDir),
    save: (sessions) => savePersistedSessions(stateDir, sessions),
  });
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
    allowPlaintextLan: options.allowPlaintextLan,
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

  // 上次没关掉的会话自动续接（原生会话都在各 CLI 的状态目录里，丢的只是路由表）。
  // 不阻塞启动：恢复期间接入的客户端会随 sessionCreated 陆续看到会话。
  void hub.restorePersisted();

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
  if (!isLoopbackHost(options.host) && !options.allowPlaintextLan) {
    process.stdout.write(
      "  明文 /events /command /git 已关闭(非回环);手机请走 E2EE,或显式 --allow-plaintext-lan\n",
    );
  }

  const stopPushBridge = startPushBridge(hub, stateDir, identity.macDeviceId);
  // 闲时也保持 codex 额度可读：手表表盘/小组件依赖它，会话喂着数据时会自动跳过
  const quotaProbe = startQuotaProbe({
    hub,
    log: (line) => process.stdout.write(`  ${line}\n`),
  });
  // 用手机 App「添加电脑」扫这个码即完成 E2EE 配对
  printPairingQr(pairPayload());

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
    stopPushBridge();
    quotaProbe.close();
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

interface AdminHandle {
  port: number;
  adminToken: string;
  pid: number;
}

/** 向本机运行中的 bridge 请求重开配对窗口,拿到新 payload */
function requestReopenPairing(handle: AdminHandle): Promise<{ expiresAtMs: number; pairPayload: Record<string, unknown> }> {
  return new Promise((resolve, reject) => {
    const request = httpRequest(
      {
        host: "127.0.0.1",
        port: handle.port,
        path: "/admin/pairing",
        method: "POST",
        headers: { authorization: `Bearer ${handle.adminToken}` },
      },
      (response) => {
        let body = "";
        response.setEncoding("utf8");
        response.on("data", (chunk) => (body += chunk));
        response.on("end", () => {
          if (response.statusCode !== 200) {
            reject(new Error(`admin 接口返回 ${response.statusCode}: ${body}`));
            return;
          }
          try {
            const parsed = JSON.parse(body) as {
              expiresAtMs: number;
              pairPayload: Record<string, unknown>;
            };
            resolve({ expiresAtMs: parsed.expiresAtMs, pairPayload: parsed.pairPayload });
          } catch (error) {
            reject(error instanceof Error ? error : new Error(String(error)));
          }
        });
      },
    );
    request.on("error", reject);
    request.end();
  });
}

async function runQr(argv: string[]): Promise<void> {
  let stateDirArg: string | null = null;
  for (let index = 0; index < argv.length; index += 1) {
    if ((argv[index] === "--state-dir") && argv[index + 1]) {
      stateDirArg = argv[index + 1] ?? null;
      index += 1;
    } else if (argv[index] === "--help" || argv[index] === "-h") {
      printHelp();
      process.exit(0);
    }
  }
  const stateDir = resolveStateDir(
    stateDirArg !== null ? { [STATE_DIR_ENV]: stateDirArg } : process.env,
  );
  let handle: AdminHandle;
  try {
    handle = JSON.parse(readFileSync(join(stateDir, "admin.json"), "utf8")) as AdminHandle;
  } catch {
    throw new Error("找不到运行中的 bridge(缺 admin.json);请先在本机 lenscrew up");
  }
  const { expiresAtMs, pairPayload } = await requestReopenPairing(handle);
  process.stdout.write(`  配对窗口至 ${new Date(expiresAtMs).toISOString()}\n`);
  process.stdout.write(`  配对 payload ${JSON.stringify(pairPayload)}\n`);
  printPairingQr(pairPayload);
}

async function runService(argv: string[]): Promise<void> {
  const action = argv[0];
  const log = (line: string): void => {
    process.stdout.write(`  ${line}\n`);
  };
  if (action === "install") {
    // 复用 up 的解析:token 未指定时在这里随机生成一次,固定进 plist——
    // 常驻模式下 bridge 每次拉起口令必须不变,手机才不用重配。
    const options = parseUpArguments(argv.slice(1));
    await installService({
      options,
      entryPath: realpathSync(process.argv[1] ?? ""),
      stateDir: resolveStateDir(
        options.stateDir !== null ? { [STATE_DIR_ENV]: options.stateDir } : process.env,
      ),
      log,
    });
    return;
  }
  if (action === "uninstall") {
    await uninstallService(log);
    return;
  }
  if (action === "status") {
    await serviceStatus(log);
    return;
  }
  printHelp();
  process.exit(action === undefined ? 0 : 1);
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  if (argv[0] === "relay") {
    await runRelay(parseRelayArguments(argv.slice(1)));
    return;
  }
  if (argv[0] === "qr") {
    await runQr(argv.slice(1));
    return;
  }
  if (argv[0] === "service") {
    await runService(argv.slice(1));
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
