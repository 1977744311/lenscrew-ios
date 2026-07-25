#!/usr/bin/env node
import { randomBytes } from "node:crypto";
import { networkInterfaces } from "node:os";

import { defaultAdapterFactory } from "../src/adapters/registry.ts";
import { SessionHub } from "../src/session/hub.ts";
import { createBridgeServer } from "../src/transport/server.ts";

interface Options {
  host: string;
  port: number;
  token: string;
}

function parseArguments(argv: string[]): Options {
  // 默认只监听回环。要让手机连上必须显式 --host，
  // 免得在咖啡馆的 Wi-Fi 上不知不觉把本机 agent 暴露出去。
  const options: Options = {
    host: "127.0.0.1",
    port: 4311,
    token: process.env["LENSCREW_TOKEN"] ?? randomBytes(24).toString("base64url"),
  };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (flag === "--host" && value) {
      options.host = value;
      index += 1;
    } else if (flag === "--port" && value) {
      const port = Number(value);
      if (!Number.isInteger(port) || port < 1 || port > 65535) {
        throw new Error(`端口不合法: ${value}`);
      }
      options.port = port;
      index += 1;
    } else if (flag === "--token" && value) {
      options.token = value;
      index += 1;
    } else if (flag === "--help" || flag === "-h") {
      process.stdout.write(
        [
          "用法: lenscrew up [--host <地址>] [--port <端口>] [--token <口令>]",
          "",
          "  --host   监听地址，默认 127.0.0.1。手机要连就传局域网地址或 0.0.0.0",
          "  --port   监听端口，默认 4311",
          "  --token  访问口令，默认每次随机生成（也可用 LENSCREW_TOKEN 环境变量）",
          "",
        ].join("\n"),
      );
      process.exit(0);
    }
  }
  return options;
}

function reachableAddresses(host: string): string[] {
  if (host !== "0.0.0.0") return [host];
  return Object.values(networkInterfaces())
    .flatMap((entries) => entries ?? [])
    .filter((entry) => entry.family === "IPv4" && !entry.internal)
    .map((entry) => entry.address);
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const command = argv[0] === "up" ? argv.slice(1) : argv;
  const options = parseArguments(command);

  const hub = new SessionHub(defaultAdapterFactory);
  const server = createBridgeServer({ hub, ...options });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(options.port, options.host, resolve);
  });

  for (const address of reachableAddresses(options.host)) {
    process.stdout.write(`  http://${address}:${options.port}\n`);
  }
  process.stdout.write(`  口令 ${options.token}\n`);
  if (options.host === "127.0.0.1") {
    process.stdout.write("  仅监听回环，手机连不上；要连手机请加 --host\n");
  }

  let shuttingDown = false;
  const shutdown = () => {
    if (shuttingDown) return;
    shuttingDown = true;
    server.close();
    // 不等 agent 进程自己退：用户按了 Ctrl-C 就该立刻还他终端
    void hub.closeAll().then(() => process.exit(0));
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((error: unknown) => {
  process.stderr.write(
    `启动失败: ${error instanceof Error ? error.message : String(error)}\n`,
  );
  process.exit(1);
});
