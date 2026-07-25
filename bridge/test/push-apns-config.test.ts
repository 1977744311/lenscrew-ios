import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { APNS_CONFIG_FILE, loadApnsConfig } from "../src/push/apnsConfig.ts";

const PEM = "-----BEGIN PRIVATE KEY-----\nMIG...\n-----END PRIVATE KEY-----\n";

function withStateDir<T>(run: (dir: string) => T): T {
  const dir = mkdtempSync(join(tmpdir(), "lenscrew-apns-config-"));
  try {
    return run(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("缺 apns.json → null", () => {
  withStateDir((dir) => {
    assert.equal(loadApnsConfig(dir), null);
  });
});

test("内嵌 privateKey 的完整配置", () => {
  withStateDir((dir) => {
    writeFileSync(
      join(dir, APNS_CONFIG_FILE),
      JSON.stringify({ teamId: "T1", keyId: "K1", bundleId: "com.x.y", privateKey: PEM }),
    );
    assert.deepEqual(loadApnsConfig(dir), {
      teamId: "T1",
      keyId: "K1",
      bundleId: "com.x.y",
      privateKeyPem: PEM,
    });
  });
});

test("privateKeyPath:相对状态目录解析", () => {
  withStateDir((dir) => {
    writeFileSync(join(dir, "AuthKey_K1.p8"), PEM);
    writeFileSync(
      join(dir, APNS_CONFIG_FILE),
      JSON.stringify({ teamId: "T1", keyId: "K1", bundleId: "com.x.y", privateKeyPath: "AuthKey_K1.p8" }),
    );
    assert.equal(loadApnsConfig(dir)?.privateKeyPem, PEM);
  });
});

test("privateKeyPath:绝对路径", () => {
  withStateDir((dir) => {
    const keyPath = join(dir, "elsewhere.p8");
    writeFileSync(keyPath, PEM);
    writeFileSync(
      join(dir, APNS_CONFIG_FILE),
      JSON.stringify({ teamId: "T1", keyId: "K1", bundleId: "com.x.y", privateKeyPath: keyPath }),
    );
    assert.equal(loadApnsConfig(dir)?.privateKeyPem, PEM);
  });
});

test("缺字段/key 文件缺失/坏 JSON → null(整体禁用推送)", () => {
  withStateDir((dir) => {
    // 缺 bundleId
    writeFileSync(
      join(dir, APNS_CONFIG_FILE),
      JSON.stringify({ teamId: "T1", keyId: "K1", privateKey: PEM }),
    );
    assert.equal(loadApnsConfig(dir), null);
    // 既无 privateKey 也无 privateKeyPath
    writeFileSync(
      join(dir, APNS_CONFIG_FILE),
      JSON.stringify({ teamId: "T1", keyId: "K1", bundleId: "com.x.y" }),
    );
    assert.equal(loadApnsConfig(dir), null);
    // privateKeyPath 指向不存在的文件
    writeFileSync(
      join(dir, APNS_CONFIG_FILE),
      JSON.stringify({ teamId: "T1", keyId: "K1", bundleId: "com.x.y", privateKeyPath: "missing.p8" }),
    );
    assert.equal(loadApnsConfig(dir), null);
    // 坏 JSON
    writeFileSync(join(dir, APNS_CONFIG_FILE), "{not json");
    assert.equal(loadApnsConfig(dir), null);
    // 空字段
    writeFileSync(
      join(dir, APNS_CONFIG_FILE),
      JSON.stringify({ teamId: "", keyId: "K1", bundleId: "com.x.y", privateKey: PEM }),
    );
    assert.equal(loadApnsConfig(dir), null);
  });
});
