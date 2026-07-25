import test from "node:test";
import assert from "node:assert/strict";

import {
  buildFunctionPatterns,
  dataModulePositions,
  encodeQr,
  formatBitPositions,
  maskPredicate,
  QR_MAX_VERSION,
  QR_MIN_VERSION,
  qrMatrix,
  rsSyndromes,
  totalCodewordCount,
  versionBitPositions,
  versionInfoBits,
  versionSpec,
} from "../src/qr/qrEncode.ts";
import type { QrEncodeDetail } from "../src/qr/qrEncode.ts";

// 覆盖 v1(无对齐图形)、v7(版本信息起点)、v10(16bit 长度域)、v13(容量上限)
const SAMPLE_TEXTS: readonly (readonly [string, number])[] = [
  ["hi lenscrew", 1],
  ["x".repeat(120), 7],
  ["y".repeat(200), 10],
  [
    JSON.stringify({
      v: 1,
      kind: "lenscrew-pair",
      host: "198.51.100.23",
      port: 48239,
      macDeviceId: "0f9a3d2e-6b1c-4a8e-9c7d-2f1e0a3b4c5d",
      identityPublicKey: "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqaw==",
      psk: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2Nzg5YWJjZGVm",
      expiresAtMs: 1799999999999,
    }),
    13,
  ],
];

function bchRemainder(value: number, generator: number, genDegree: number, totalBits: number): number {
  let v = value;
  for (let bit = totalBits - 1; bit >= genDegree; bit--) {
    if (((v >>> bit) & 1) === 1) v ^= generator << (bit - genDegree);
  }
  return v;
}

/** finder 7×7 的期望图形:中心 3×3 与外圈暗,中间圈亮 */
function expectedFinderDark(dr: number, dc: number): boolean {
  return Math.max(Math.abs(dr - 3), Math.abs(dc - 3)) !== 2;
}

test("qrMatrix:输出为 size×size 的方阵", () => {
  for (const [text, version] of SAMPLE_TEXTS) {
    const matrix = qrMatrix(text);
    const size = 17 + version * 4;
    assert.equal(matrix.length, size);
    for (const row of matrix) assert.equal(row.length, size);
  }
});

test("结构不变量:finder/分隔符/timing/暗模块", () => {
  for (const [text, version] of SAMPLE_TEXTS) {
    const detail = encodeQr(text);
    assert.equal(detail.version, version);
    const { matrix, size } = detail;

    for (const [originRow, originCol] of [
      [0, 0],
      [0, size - 7],
      [size - 7, 0],
    ]) {
      for (let dr = -1; dr <= 7; dr++) {
        for (let dc = -1; dc <= 7; dc++) {
          const row = originRow! + dr;
          const col = originCol! + dc;
          if (row < 0 || row >= size || col < 0 || col >= size) continue;
          const inFinder = dr >= 0 && dr <= 6 && dc >= 0 && dc <= 6;
          const expected = inFinder ? expectedFinderDark(dr, dc) : false;
          assert.equal(matrix[row]![col], expected, `v${version} finder(${row},${col})`);
        }
      }
    }

    for (let i = 8; i <= size - 9; i++) {
      assert.equal(matrix[6]![i], i % 2 === 0, `v${version} 横 timing(6,${i})`);
      assert.equal(matrix[i]![6], i % 2 === 0, `v${version} 竖 timing(${i},6)`);
    }

    assert.equal(matrix[size - 8]![8], true, `v${version} 暗模块`);
  }
});

test("格式信息:两份一致、BCH 自洽、EC=M、mask 与编码器一致", () => {
  for (const [text, version] of SAMPLE_TEXTS) {
    const detail = encodeQr(text);
    const { first, second } = formatBitPositions(detail.size);
    let firstBits = 0;
    let secondBits = 0;
    for (let i = 0; i < 15; i++) {
      const [fr, fc] = first[i]!;
      if (detail.matrix[fr]![fc]!) firstBits |= 1 << i;
      const [sr, sc] = second[i]!;
      if (detail.matrix[sr]![sc]!) secondBits |= 1 << i;
    }
    assert.equal(firstBits, secondBits, `v${version} 两份格式信息应一致`);
    const unmasked = firstBits ^ 0x5412;
    assert.equal(bchRemainder(unmasked, 0x537, 10, 15), 0, `v${version} 格式信息 BCH 余数`);
    const data5 = unmasked >>> 10;
    assert.equal(data5 >>> 3, 0b00, `v${version} EC level 应为 M`);
    assert.equal(data5 & 0b111, detail.mask, `v${version} mask 读回`);
  }
});

test("版本信息:v7+ 两份一致且与 versionInfoBits 相同", () => {
  for (const [text, version] of SAMPLE_TEXTS) {
    if (version < 7) continue;
    const detail = encodeQr(text);
    const positions = versionBitPositions(detail.size);
    let copyA = 0;
    let copyB = 0;
    for (let i = 0; i < 18; i++) {
      const [posA, posB] = positions[i]!;
      if (detail.matrix[posA![0]]![posA![1]]!) copyA |= 1 << i;
      if (detail.matrix[posB![0]]![posB![1]]!) copyB |= 1 << i;
    }
    assert.equal(copyA, copyB);
    assert.equal(copyA, versionInfoBits(version));
    assert.equal(copyA >>> 12, version);
  }
});

test("数据区模块数 = 码字位数 + 剩余位(v1–v13 全量)", () => {
  const remainderBits: Record<number, number> = {
    1: 0, 2: 7, 3: 7, 4: 7, 5: 7, 6: 7, 7: 0, 8: 0, 9: 0, 10: 0, 11: 0, 12: 0, 13: 0,
  };
  for (let v = QR_MIN_VERSION; v <= QR_MAX_VERSION; v++) {
    const { size, reserved } = buildFunctionPatterns(v);
    const positions = dataModulePositions(size, (row, col) => reserved[row * size + col] === 1);
    assert.equal(
      positions.length,
      totalCodewordCount(v) * 8 + remainderBits[v]!,
      `v${v} 数据模块数`,
    );
    const unique = new Set(positions.map(([row, col]) => row * size + col));
    assert.equal(unique.size, positions.length, `v${v} 之字形遍历不应重复`);
  }
});

// ——最小解码器:读回矩阵 → 去掩码 → 反交织 → RS 校验 → 解析 byte mode——

function extractCodewords(detail: QrEncodeDetail): Uint8Array {
  const { matrix, reserved, size, mask } = detail;
  const positions = dataModulePositions(size, (row, col) => reserved[row]![col]!);
  const out = new Uint8Array(detail.codewords.length);
  for (let i = 0; i < out.length * 8; i++) {
    const [row, col] = positions[i]!;
    const bit = matrix[row]![col]! !== maskPredicate(mask, row, col);
    if (bit) out[i >> 3] = out[i >> 3]! | (0x80 >>> (i & 7));
  }
  return out;
}

function deinterleave(codewords: Uint8Array, version: number): Uint8Array[] {
  const spec = versionSpec(version);
  const dataLengths: number[] = [];
  for (const [count, dataLen] of spec.blocks) {
    for (let i = 0; i < count; i++) dataLengths.push(dataLen);
  }
  const blocks = dataLengths.map((len) => new Uint8Array(len + spec.ecPerBlock));
  let r = 0;
  const maxLen = Math.max(...dataLengths);
  for (let i = 0; i < maxLen; i++) {
    for (let b = 0; b < blocks.length; b++) {
      if (i < dataLengths[b]!) blocks[b]![i] = codewords[r++]!;
    }
  }
  for (let i = 0; i < spec.ecPerBlock; i++) {
    for (let b = 0; b < blocks.length; b++) {
      blocks[b]![dataLengths[b]! + i] = codewords[r++]!;
    }
  }
  assert.equal(r, codewords.length);
  return blocks;
}

function parseByteMode(dataCodewords: Uint8Array, version: number): string {
  const bitAt = (i: number): number => (dataCodewords[i >> 3]! >>> (7 - (i & 7))) & 1;
  const readBits = (start: number, len: number): number => {
    let value = 0;
    for (let i = 0; i < len; i++) value = (value << 1) | bitAt(start + i);
    return value;
  };
  assert.equal(readBits(0, 4), 0b0100, "mode indicator 应为 byte mode");
  const countBits = version <= 9 ? 8 : 16;
  const count = readBits(4, countBits);
  const bytes = new Uint8Array(count);
  for (let i = 0; i < count; i++) bytes[i] = readBits(4 + countBits + i * 8, 8);
  return new TextDecoder().decode(bytes);
}

test("端到端读回:去掩码 → 反交织 → syndromes 全零 → 解析回原文", () => {
  for (const [text, version] of SAMPLE_TEXTS) {
    const detail = encodeQr(text);
    assert.equal(detail.version, version);

    const extracted = extractCodewords(detail);
    assert.deepEqual([...extracted], [...detail.codewords], `v${version} 读回码字`);

    const spec = versionSpec(version);
    const blocks = deinterleave(extracted, version);
    const dataParts: number[] = [];
    for (const block of blocks) {
      assert.deepEqual(
        rsSyndromes(block, spec.ecPerBlock),
        new Array<number>(spec.ecPerBlock).fill(0),
        `v${version} block RS 校验`,
      );
      dataParts.push(...block.slice(0, block.length - spec.ecPerBlock));
    }
    assert.equal(parseByteMode(Uint8Array.from(dataParts), version), text, `v${version} 原文读回`);
  }
});

test("UTF-8 中文 payload 也能按 byte mode 往返", () => {
  const text = "眼镜配对:LensCrew 桥 v1";
  const detail = encodeQr(text);
  const spec = versionSpec(detail.version);
  const blocks = deinterleave(extractCodewords(detail), detail.version);
  const dataParts: number[] = [];
  for (const block of blocks) dataParts.push(...block.slice(0, block.length - spec.ecPerBlock));
  assert.equal(parseByteMode(Uint8Array.from(dataParts), detail.version), text);
});
