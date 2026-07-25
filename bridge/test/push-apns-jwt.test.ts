import test from "node:test";
import assert from "node:assert/strict";
import { createVerify, generateKeyPairSync } from "node:crypto";

import { ApnsJwtSigner } from "../src/push/apnsClient.ts";

const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const privateKeyPem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();

const BASE_MS = 1_700_000_000_000;

test("JWT:三段 base64url,header/claims 字段正确,ES256 签名可验", () => {
  const signer = new ApnsJwtSigner({
    teamId: "TEAMABCDEF",
    keyId: "KEYID12345",
    privateKeyPem,
    now: () => BASE_MS,
  });
  const token = signer.token();
  const parts = token.split(".");
  assert.equal(parts.length, 3);
  for (const part of parts) assert.match(part, /^[A-Za-z0-9_-]+$/, "base64url 不应含 +/=");

  const header = JSON.parse(Buffer.from(parts[0]!, "base64url").toString("utf8")) as unknown;
  assert.deepEqual(header, { alg: "ES256", kid: "KEYID12345" });

  const claims = JSON.parse(Buffer.from(parts[1]!, "base64url").toString("utf8")) as unknown;
  assert.deepEqual(claims, { iss: "TEAMABCDEF", iat: Math.floor(BASE_MS / 1000) });

  const signature = Buffer.from(parts[2]!, "base64url");
  assert.equal(signature.length, 64, "JOSE r‖s 原始签名应为 64 字节");
  const verified = createVerify("SHA256")
    .update(`${parts[0]}.${parts[1]}`)
    .verify({ key: publicKey, dsaEncoding: "ieee-p1363" }, signature);
  assert.equal(verified, true);
});

test("JWT:50 分钟内复用缓存,过期重签且 iat 更新", () => {
  let nowMs = BASE_MS;
  const signer = new ApnsJwtSigner({
    teamId: "TEAMABCDEF",
    keyId: "KEYID12345",
    privateKeyPem,
    now: () => nowMs,
  });
  const first = signer.token();
  nowMs += 49 * 60 * 1000;
  assert.equal(signer.token(), first, "49 分钟内应复用");

  nowMs = BASE_MS + 51 * 60 * 1000;
  const second = signer.token();
  assert.notEqual(second, first, "超过 50 分钟应重签");
  const claims = JSON.parse(
    Buffer.from(second.split(".")[1]!, "base64url").toString("utf8"),
  ) as { iat: number };
  assert.equal(claims.iat, Math.floor(nowMs / 1000));
});
