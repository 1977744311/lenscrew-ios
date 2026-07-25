import test from "node:test";
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { existsSync, mkdtempSync, readFileSync, statSync } from "node:fs";
import { request } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { renderPairingQr } from "../src/qr/index.ts";

const BIN = fileURLToPath(new URL("../bin/lenscrew.ts", import.meta.url));

interface Spawned {
  child: ChildProcess;
  stdout: () => string;
  stderr: () => string;
}

function spawnCli(args: string[], env: Record<string, string | undefined>): Spawned {
  const child = spawn(process.execPath, [BIN, ...args], {
    env: { ...process.env, ...env },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let out = "";
  let err = "";
  child.stdout?.setEncoding("utf8");
  child.stdout?.on("data", (chunk: string) => {
    out += chunk;
  });
  child.stderr?.setEncoding("utf8");
  child.stderr?.on("data", (chunk: string) => {
    err += chunk;
  });
  return { child, stdout: () => out, stderr: () => err };
}

async function stopCli(spawned: Spawned): Promise<void> {
  if (spawned.child.exitCode !== null) return;
  spawned.child.kill("SIGINT");
  const killer = setTimeout(() => spawned.child.kill("SIGKILL"), 5000);
  await once(spawned.child, "exit");
  clearTimeout(killer);
}

function httpCall(
  method: string,
  url: string,
  headers?: Record<string, string>,
): Promise<{ status: number; json: Record<string, unknown> }> {
  return new Promise((resolve, reject) => {
    const req = request(url, { method, agent: false, headers: headers ?? {} }, (response) => {
      const chunks: Buffer[] = [];
      response.on("error", reject);
      response.on("data", (chunk: Buffer) => chunks.push(chunk));
      response.on("end", () => {
        resolve({
          status: response.statusCode ?? 0,
          json: JSON.parse(Buffer.concat(chunks).toString("utf8")) as Record<string, unknown>,
        });
      });
    });
    req.on("error", reject);
    req.end();
  });
}

test("lenscrew up --port 0:生成 admin.json,/admin/pairing 可重开配对窗口", async () => {
  const stateDir = mkdtempSync(join(tmpdir(), "lenscrew-cli-"));
  const spawned = spawnCli(["up", "--port", "0", "--name", "CLI Test Mac"], {
    LENSCREW_STATE_DIR: stateDir,
  });

  // 真进程冒烟,失败时把子进程输出带进断言,不然只有一句超时没法查
  async function waitFor(check: () => boolean, what: string, timeoutMs = 15000): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (!check()) {
      if (Date.now() > deadline) {
        assert.fail(`等待超时: ${what}\nstdout:\n${spawned.stdout()}\nstderr:\n${spawned.stderr()}`);
      }
      await new Promise((r) => setTimeout(r, 25));
    }
  }

  try {
    const adminPath = join(stateDir, "admin.json");
    let admin: { port: number; adminToken: string; pid: number } | null = null;
    await waitFor(() => {
      if (!existsSync(adminPath)) return false;
      try {
        const parsed = JSON.parse(readFileSync(adminPath, "utf8")) as typeof admin;
        if (parsed === null || typeof parsed.port !== "number" || parsed.port === 0) return false;
        admin = parsed;
        return true;
      } catch {
        return false;
      }
    }, "admin.json 生成");
    assert.ok(admin !== null);
    const { port, adminToken, pid } = admin as { port: number; adminToken: string; pid: number };
    assert.equal(pid, spawned.child.pid);
    assert.ok(adminToken.length >= 24);
    // 管理口令能打开配对窗口,权限必须只有本用户可读
    assert.equal(statSync(adminPath).mode & 0o777, 0o600);

    // 身份已持久化
    assert.ok(existsSync(join(stateDir, "identity.json")));

    // 启动日志打印单行配对 payload
    await waitFor(() => spawned.stdout().includes('"kind":"lenscrew-pair"'), "启动日志包含配对 payload");

    const url = `http://127.0.0.1:${port}/admin/pairing`;
    const noToken = await httpCall("POST", url);
    assert.equal(noToken.status, 401);
    const badToken = await httpCall("POST", url, { authorization: "Bearer wrong-token" });
    assert.equal(badToken.status, 401);

    const before = Date.now();
    const reply = await httpCall("POST", url, { authorization: `Bearer ${adminToken}` });
    assert.equal(reply.status, 200);
    assert.equal(reply.json["ok"], true);
    const expiresAtMs = reply.json["expiresAtMs"];
    assert.ok(typeof expiresAtMs === "number" && expiresAtMs >= before + 4 * 60_000, "重开后约 5 分钟窗口");

    const payload = reply.json["pairPayload"] as Record<string, unknown>;
    assert.equal(payload["v"], 1);
    assert.equal(payload["kind"], "lenscrew-pair");
    assert.equal(payload["displayName"], "CLI Test Mac");
    assert.equal(payload["expiresAtMs"], expiresAtMs);
    assert.ok(typeof payload["macDeviceId"] === "string" && payload["macDeviceId"] !== "");
    assert.equal(Buffer.from(payload["macIdentityPublicKey"] as string, "base64").length, 32);
    // 默认回环监听、未启用 relay:payload 不该有 lan/relay
    assert.ok(!("lan" in payload));
    assert.ok(!("relay" in payload));
  } finally {
    await stopCli(spawned);
  }
});

test("up 日志的配对 payload 可被 qr 模块编码;lenscrew qr 对运行中 bridge 重开新窗口", async () => {
  const stateDir = mkdtempSync(join(tmpdir(), "lenscrew-cli-qr-"));
  const spawned = spawnCli(["up", "--port", "0", "--name", "QR Test Mac"], {
    LENSCREW_STATE_DIR: stateDir,
  });

  async function waitFor(check: () => boolean, what: string, timeoutMs = 15000): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (!check()) {
      if (Date.now() > deadline) {
        assert.fail(`等待超时: ${what}\nstdout:\n${spawned.stdout()}\nstderr:\n${spawned.stderr()}`);
      }
      await new Promise((r) => setTimeout(r, 25));
    }
  }

  function extractPayload(stdout: string): Record<string, unknown> {
    const line = stdout.split("\n").find((entry) => entry.includes('"kind":"lenscrew-pair"'));
    assert.ok(line !== undefined, `输出里找不到配对 payload:\n${stdout}`);
    return JSON.parse(line.slice(line.indexOf("{"))) as Record<string, unknown>;
  }

  try {
    // 启动日志包含单行配对 payload(runUp 在 admin.json 写盘之后才打印它)
    await waitFor(() => spawned.stdout().includes('"kind":"lenscrew-pair"'), "启动日志包含配对 payload");
    const bootPayload = extractPayload(spawned.stdout());
    assert.equal(bootPayload["kind"], "lenscrew-pair");

    // qr 模块能对同一 payload 编码:不抛、产出非空多行 ANSI 块
    const rendered = renderPairingQr(JSON.stringify(bootPayload));
    assert.ok(rendered.length > 0);
    assert.ok(rendered.split("\n").length > 10, "二维码应是多行终端块");

    // 对运行中的 bridge 跑 `lenscrew qr`:经 admin.json 重开配对窗口,拿到新 expiresAtMs
    const before = Date.now();
    const qrCli = spawnCli(["qr", "--state-dir", stateDir], {});
    await once(qrCli.child, "exit");
    assert.equal(qrCli.child.exitCode, 0, `lenscrew qr 退出异常:\n${qrCli.stderr()}`);
    assert.ok(qrCli.stdout().includes("配对窗口至"));

    const qrPayload = extractPayload(qrCli.stdout());
    const expiresAtMs = qrPayload["expiresAtMs"];
    assert.ok(
      typeof expiresAtMs === "number" && expiresAtMs >= before + 4 * 60_000,
      "重开后应是新的约 5 分钟窗口",
    );
    assert.ok(
      (expiresAtMs as number) > (bootPayload["expiresAtMs"] as number),
      "新窗口必须晚于启动时的窗口",
    );
    assert.equal(qrPayload["macDeviceId"], bootPayload["macDeviceId"], "身份不因重开而漂移");
  } finally {
    await stopCli(spawned);
  }
});

test("--help 覆盖新 flags 与 relay 子命令", async () => {
  const spawned = spawnCli(["up", "--help"], {});
  await once(spawned.child, "exit");
  assert.equal(spawned.child.exitCode, 0);
  for (const expected of ["--relay", "--name", "--state-dir", "lenscrew relay"]) {
    assert.ok(spawned.stdout().includes(expected), `--help 应包含 ${expected}`);
  }
});
