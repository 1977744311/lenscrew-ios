// 端到端实扫:qrMatrix → 纯手写 PNG(无压缩 zlib stored blocks)→ swift -e Vision
// VNDetectBarcodesRequest 解码 → 断言 payload 与输入一致。
// swift/Vision 不可用(无 CLT 等)时标记 skip,不算失败。

import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { encodeQr } from "../src/qr/qrEncode.ts";

// MARK: - 最小 PNG writer(灰度 8bit、filter 0、stored deflate)

function crc32(bytes: Uint8Array): number {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let k = 0; k < 8; k++) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function adler32(bytes: Uint8Array): number {
  let a = 1;
  let b = 0;
  for (const byte of bytes) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return (((b << 16) >>> 0) | a) >>> 0;
}

function u32be(value: number): Uint8Array {
  return Uint8Array.of((value >>> 24) & 0xff, (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff);
}

function concatBytes(parts: readonly Uint8Array[]): Uint8Array {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function pngChunk(type: string, data: Uint8Array): Uint8Array {
  const typeBytes = new TextEncoder().encode(type);
  return concatBytes([u32be(data.length), typeBytes, data, u32be(crc32(concatBytes([typeBytes, data])))]);
}

/** 无压缩 zlib:0x78 0x01 + stored deflate blocks + adler32 */
function zlibStored(raw: Uint8Array): Uint8Array {
  const parts: Uint8Array[] = [Uint8Array.of(0x78, 0x01)];
  const blockSize = 65535;
  for (let offset = 0; offset < raw.length; offset += blockSize) {
    const chunk = raw.subarray(offset, Math.min(offset + blockSize, raw.length));
    const isLast = offset + blockSize >= raw.length;
    parts.push(
      Uint8Array.of(
        isLast ? 1 : 0,
        chunk.length & 0xff,
        (chunk.length >>> 8) & 0xff,
        ~chunk.length & 0xff,
        (~chunk.length >>> 8) & 0xff,
      ),
      chunk,
    );
  }
  parts.push(u32be(adler32(raw)));
  return concatBytes(parts);
}

function matrixToPng(matrix: readonly (readonly boolean[])[], scale: number, quietModules: number): Uint8Array {
  const size = matrix.length;
  const pixels = (size + quietModules * 2) * scale;
  const stride = pixels + 1; // 每行 1 字节 filter 前缀
  const raw = new Uint8Array(stride * pixels).fill(255);
  for (let y = 0; y < pixels; y++) raw[y * stride] = 0;
  for (let row = 0; row < size; row++) {
    for (let col = 0; col < size; col++) {
      if (!matrix[row]![col]!) continue;
      for (let dy = 0; dy < scale; dy++) {
        const base = ((row + quietModules) * scale + dy) * stride + 1 + (col + quietModules) * scale;
        raw.fill(0, base, base + scale);
      }
    }
  }
  const ihdr = concatBytes([u32be(pixels), u32be(pixels), Uint8Array.of(8, 0, 0, 0, 0)]);
  return concatBytes([
    Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a),
    pngChunk("IHDR", ihdr),
    pngChunk("IDAT", zlibStored(raw)),
    pngChunk("IEND", new Uint8Array(0)),
  ]);
}

// MARK: - swift + Vision 解码

// payload 以 base64 打印,避免 tab/换行歧义;不限定 symbology,少一层 SDK 版本兼容风险
const SWIFT_DECODER = [
  "import Foundation",
  "import Vision",
  "",
  "var failed = false",
  "for path in CommandLine.arguments.dropFirst() {",
  "    let request = VNDetectBarcodesRequest()",
  "    let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path))",
  "    do {",
  "        try handler.perform([request])",
  "    } catch {",
  '        print("ERR\\t" + path + "\\t" + String(describing: error))',
  "        failed = true",
  "        continue",
  "    }",
  "    let payloads = (request.results ?? []).compactMap { $0.payloadStringValue }",
  "    if let payload = payloads.first {",
  '        print("OK\\t" + path + "\\t" + Data(payload.utf8).base64EncodedString())',
  "    } else {",
  '        print("NONE\\t" + path)',
  "        failed = true",
  "    }",
  "}",
  "exit(failed ? 2 : 0)",
].join("\n");

interface VisionDecodeResult {
  payloads: Map<string, string>;
  log: string;
}

/** 返回 null 表示 swift/Vision 环境不可用(与"能跑但没解出码"区分开) */
function runVisionDecode(workDir: string, pngPaths: readonly string[]): VisionDecodeResult | null {
  const probe = spawnSync("swift", ["--version"], { encoding: "utf8", timeout: 120_000 });
  if (probe.error !== undefined || probe.status !== 0) return null;

  const sourcePath = join(workDir, "decode-qr.swift");
  writeFileSync(sourcePath, SWIFT_DECODER);
  const run = spawnSync("swift", [sourcePath, ...pngPaths], { encoding: "utf8", timeout: 300_000 });
  if (run.error !== undefined) return null;

  const lines = (run.stdout ?? "")
    .split("\n")
    .map((line) => line.trimEnd())
    .filter((line) => line !== "");
  const structured = lines.filter(
    (line) => line.startsWith("OK\t") || line.startsWith("NONE\t") || line.startsWith("ERR\t"),
  );
  // 一行结构化输出都没有 → swift 编译/运行环境问题,按不可用处理
  if (structured.length === 0) return null;

  const payloads = new Map<string, string>();
  for (const line of structured) {
    const [tag, path, extra] = line.split("\t");
    if (tag === "OK" && path !== undefined && extra !== undefined) {
      payloads.set(path, Buffer.from(extra, "base64").toString("utf8"));
    }
  }
  return { payloads, log: `stdout:\n${run.stdout}\nstderr:\n${run.stderr}` };
}

// MARK: - 测试

const SHORT_TEXT = "LENSCREW:PAIR:OK";
const PAIRING_JSON = JSON.stringify({
  v: 1,
  kind: "lenscrew-pair",
  host: "198.51.100.23",
  port: 48239,
  macDeviceId: "0f9a3d2e-6b1c-4a8e-9c7d-2f1e0a3b4c5d",
  identityPublicKey: "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqaw==",
  psk: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2Nzg5YWJjZGVm",
  expiresAtMs: 1799999999999,
});

test("Vision 实扫:PNG 渲染的 QR 解码回原文", { timeout: 600_000 }, (t) => {
  const shortDetail = encodeQr(SHORT_TEXT);
  const pairingDetail = encodeQr(PAIRING_JSON);
  // 双覆盖:8bit 长度域小版本 + 16bit 长度域大版本(含版本信息区)
  assert.equal(shortDetail.version, 2);
  assert.equal(pairingDetail.version, 13);

  const workDir = mkdtempSync(join(tmpdir(), "lenscrew-qr-scan-"));
  try {
    const shortPng = join(workDir, "short.png");
    const pairingPng = join(workDir, "pairing.png");
    const shortBytes = matrixToPng(shortDetail.matrix, 8, 4);
    const pairingBytes = matrixToPng(pairingDetail.matrix, 8, 4);
    writeFileSync(shortPng, shortBytes);
    writeFileSync(pairingPng, pairingBytes);

    // PNG 结构自检(与 swift 是否可用无关,始终执行)
    for (const bytes of [shortBytes, pairingBytes]) {
      assert.deepEqual([...bytes.slice(0, 8)], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
      assert.equal(new TextDecoder().decode(bytes.slice(12, 16)), "IHDR");
      assert.equal(new TextDecoder().decode(bytes.slice(bytes.length - 8, bytes.length - 4)), "IEND");
    }

    const result = runVisionDecode(workDir, [shortPng, pairingPng]);
    if (result === null) {
      t.skip("swift/Vision 不可用(缺 Xcode CLT 或被沙箱拦截),实扫跳过");
      return;
    }
    assert.equal(result.payloads.get(shortPng), SHORT_TEXT, `短 payload 实扫失败\n${result.log}`);
    assert.equal(result.payloads.get(pairingPng), PAIRING_JSON, `配对 JSON 实扫失败\n${result.log}`);
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }
});
