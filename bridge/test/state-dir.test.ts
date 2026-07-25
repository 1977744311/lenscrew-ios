import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  loadOrCreateIdentity,
  loadTrustedPhones,
  resolveStateDir,
  saveTrustedPhones,
  STATE_DIR_ENV,
  type TrustedPhones,
} from "../src/state/stateDir.ts";
import { ed25519PublicRawFromSeed } from "../src/secure/crypto.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function withTempStateDir(run: (dir: string) => void): void {
  const base = mkdtempSync(join(tmpdir(), "lenscrew-state-"));
  try {
    run(resolveStateDir({ [STATE_DIR_ENV]: join(base, "state") }));
  } finally {
    rmSync(base, { recursive: true, force: true });
  }
}

function fileMode(path: string): number {
  return statSync(path).mode & 0o777;
}

test("resolveStateDir 优先环境变量并以 0700 创建目录", () => {
  const base = mkdtempSync(join(tmpdir(), "lenscrew-state-"));
  try {
    const target = join(base, "nested", "state");
    const dir = resolveStateDir({ [STATE_DIR_ENV]: target });
    assert.equal(dir, target);
    assert.equal(fileMode(dir), 0o700);
    // 再次解析幂等
    assert.equal(resolveStateDir({ [STATE_DIR_ENV]: target }), target);
  } finally {
    rmSync(base, { recursive: true, force: true });
  }
});

test("loadOrCreateIdentity 首次生成、之后幂等,文件 0600", () => {
  withTempStateDir((dir) => {
    const first = loadOrCreateIdentity(dir, () => 123);
    assert.equal(first.version, 1);
    assert.match(first.macDeviceId, UUID_RE);
    assert.equal(first.createdAtMs, 123);

    const seed = Buffer.from(first.identityPrivateKey, "base64");
    const publicKey = Buffer.from(first.identityPublicKey, "base64");
    assert.equal(seed.length, 32);
    assert.equal(publicKey.length, 32);
    // 公私钥必须是同一对
    assert.deepEqual(ed25519PublicRawFromSeed(seed), publicKey);

    const path = join(dir, "identity.json");
    assert.equal(fileMode(path), 0o600);
    assert.deepEqual(JSON.parse(readFileSync(path, "utf8")), first);

    // 第二次调用读回同一身份,不重新生成
    const second = loadOrCreateIdentity(dir, () => 456);
    assert.deepEqual(second, first);
  });
});

test("trusted-phones 缺省为空表,保存/读回往返,文件 0600", () => {
  withTempStateDir((dir) => {
    assert.deepEqual(loadTrustedPhones(dir), {});

    const phones: TrustedPhones = {
      "phone-A": { identityPublicKey: "QQ==", name: "Steven iPhone", addedAtMs: 1 },
      "phone-B": { identityPublicKey: "Qg==", addedAtMs: 2 },
    };
    saveTrustedPhones(dir, phones);
    assert.deepEqual(loadTrustedPhones(dir), phones);

    const path = join(dir, "trusted-phones.json");
    assert.equal(fileMode(path), 0o600);

    // 覆盖写后权限仍收紧为 0600
    saveTrustedPhones(dir, { ...phones, "phone-C": { identityPublicKey: "Qw==", addedAtMs: 3 } });
    assert.equal(fileMode(path), 0o600);
    assert.equal(Object.keys(loadTrustedPhones(dir)).length, 3);
  });
});
