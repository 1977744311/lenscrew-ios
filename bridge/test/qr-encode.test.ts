import test from "node:test";
import assert from "node:assert/strict";

import {
  BitBuffer,
  buildDataCodewords,
  byteCapacity,
  dataCodewordCount,
  formatInfoBits,
  gfMul,
  interleaveCodewords,
  maskPredicate,
  penaltyBlocks,
  penaltyDarkRatio,
  penaltyFinderLike,
  penaltyRuns,
  QR_MAX_VERSION,
  QR_MIN_VERSION,
  rsEncode,
  rsGeneratorPoly,
  rsSyndromes,
  selectVersion,
  splitIntoBlocks,
  totalCodewordCount,
  versionInfoBits,
  versionSpec,
} from "../src/qr/qrEncode.ts";

// 独立实现的 BCH 余数检查,避免与被测代码共用同一段循环
function bchRemainder(value: number, generator: number, genDegree: number, totalBits: number): number {
  let v = value;
  for (let bit = totalBits - 1; bit >= genDegree; bit--) {
    if (((v >>> bit) & 1) === 1) v ^= generator << (bit - genDegree);
  }
  return v;
}

function hammingDistance(a: number, b: number): number {
  let x = a ^ b;
  let count = 0;
  while (x !== 0) {
    count += x & 1;
    x >>>= 1;
  }
  return count;
}

/** 确定性伪随机字节(LCG),测试可复现 */
function pseudoRandomBytes(length: number, seed: number): Uint8Array {
  const out = new Uint8Array(length);
  let state = seed >>> 0;
  for (let i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) >>> 0;
    out[i] = (state >>> 16) & 0xff;
  }
  return out;
}

test("BitBuffer:大端追加与字节化", () => {
  const bits = new BitBuffer();
  bits.push(0b0100, 4);
  bits.push(0x41, 8);
  assert.equal(bits.length, 12);
  assert.deepEqual([...bits.toBytes()], [0x44, 0x10]);
});

test("容量表:数据/总码字数与 byte mode 容量(v1–v13,EC M)", () => {
  const expectedData = [16, 28, 44, 64, 86, 108, 124, 154, 182, 216, 254, 290, 334];
  const expectedTotal = [26, 44, 70, 100, 134, 172, 196, 242, 292, 346, 404, 466, 532];
  const expectedByteCap = [14, 26, 42, 62, 84, 106, 122, 152, 180, 213, 251, 287, 331];
  for (let v = QR_MIN_VERSION; v <= QR_MAX_VERSION; v++) {
    assert.equal(dataCodewordCount(v), expectedData[v - 1], `v${v} data codewords`);
    assert.equal(totalCodewordCount(v), expectedTotal[v - 1], `v${v} total codewords`);
    assert.equal(byteCapacity(v), expectedByteCap[v - 1], `v${v} byte capacity`);
  }
});

test("selectVersion:边界与超容量", () => {
  assert.equal(selectVersion(0), 1);
  assert.equal(selectVersion(14), 1);
  assert.equal(selectVersion(15), 2);
  assert.equal(selectVersion(26), 2);
  assert.equal(selectVersion(27), 3);
  assert.equal(selectVersion(180), 9);
  assert.equal(selectVersion(181), 10); // 长度域从 8bit 切到 16bit 的边界
  assert.equal(selectVersion(331), 13);
  assert.throws(() => selectVersion(332), RangeError);
});

test('buildDataCodewords:"A" 的 v1 bit 流(mode+长度+数据+终止符+EC/11 填充)', () => {
  const codewords = buildDataCodewords(new TextEncoder().encode("A"), 1);
  assert.deepEqual(
    [...codewords],
    [0x40, 0x14, 0x10, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec],
  );
});

test("buildDataCodewords:v10+ 用 16bit 长度域", () => {
  const bytes = new Uint8Array(181).fill(0xff);
  const codewords = buildDataCodewords(bytes, 10);
  // 0100 | 00000000 10110101 | 11111111... → 0x40 0x0B 0x5F
  assert.deepEqual([...codewords.slice(0, 3)], [0x40, 0x0b, 0x5f]);
  assert.equal(codewords.length, dataCodewordCount(10));
});

test("GF(256) 乘法:手算抽查(本原多项式 0x11d)", () => {
  assert.equal(gfMul(0, 77), 0);
  assert.equal(gfMul(1, 77), 77);
  // 2·128 = 0x100 → ^0x11d = 0x1d
  assert.equal(gfMul(2, 128), 0x1d);
  // 2·255 = 0x1fe → ^0x11d = 0xe3
  assert.equal(gfMul(2, 255), 0xe3);
  // (x+1)(x²+x+1) = x³+1,无需约减
  assert.equal(gfMul(3, 7), 9);
  // (x²+1)(x⁴+1) = x⁶+x⁴+x²+1 = 85
  assert.equal(gfMul(5, 17), 85);
  // 16=α⁴,α⁸ = 0x1d
  assert.equal(gfMul(16, 16), 0x1d);
});

test("RS 生成多项式:degree 2 手算,degree 10 形状", () => {
  // (x−1)(x−α) = x² + 3x + 2
  assert.deepEqual([...rsGeneratorPoly(2)], [1, 3, 2]);
  const g10 = rsGeneratorPoly(10);
  assert.equal(g10.length, 11);
  assert.equal(g10[0], 1);
});

test('RS 黄金向量:ISO 18004 附录 "01234567" v1-M 的纠错码字', () => {
  const data = [16, 32, 12, 86, 97, 128, 236, 17, 236, 17, 236, 17, 236, 17, 236, 17];
  const ec = rsEncode(data, 10);
  assert.deepEqual([...ec], [0xa5, 0x24, 0xd4, 0xc1, 0xed, 0x36, 0xc7, 0x87, 0x2c, 0x55]);
});

test("RS 自校验:任意数据的(数据‖纠错)syndromes 全零,篡改后非零", () => {
  const ecLens = [10, 16, 18, 22, 24, 26, 30];
  for (const ecLen of ecLens) {
    const data = pseudoRandomBytes(40, ecLen * 7 + 1);
    const ec = rsEncode(data, ecLen);
    const codeword = [...data, ...ec];
    assert.deepEqual(
      rsSyndromes(codeword, ecLen),
      new Array<number>(ecLen).fill(0),
      `ecLen=${ecLen} syndromes 应全零`,
    );
    const corrupted = [...codeword];
    corrupted[3] = corrupted[3]! ^ 0x42;
    assert.ok(
      rsSyndromes(corrupted, ecLen).some((s) => s !== 0),
      `ecLen=${ecLen} 篡改后 syndromes 应非零`,
    );
  }
});

test("交织:v8-M(2×38 + 2×39)块结构与列交织顺序", () => {
  const version = 8;
  const spec = versionSpec(version);
  const data = new Uint8Array(dataCodewordCount(version));
  for (let i = 0; i < data.length; i++) data[i] = i & 0xff;

  const blocks = splitIntoBlocks(data, version);
  assert.deepEqual(blocks.map((b) => b.length), [38, 38, 39, 39]);

  const out = interleaveCodewords(data, version);
  assert.equal(out.length, totalCodewordCount(version));
  // 数据区:第 0 轮取各块第 0 个码字
  assert.deepEqual([...out.slice(0, 4)], [0, 38, 76, 115]);
  // 第 39 轮只剩两个长块
  assert.deepEqual([...out.slice(38 * 4, 38 * 4 + 2)], [114, 153]);
  // 纠错区:按块轮转
  const ecBlocks = blocks.map((block) => rsEncode(block, spec.ecPerBlock));
  for (let i = 0; i < spec.ecPerBlock; i++) {
    for (let b = 0; b < 4; b++) {
      assert.equal(out[154 + i * 4 + b], ecBlocks[b]![i], `ec[${b}][${i}]`);
    }
  }
  // 逐块重组后 RS 自洽
  for (let b = 0; b < 4; b++) {
    const codeword = [...blocks[b]!, ...ecBlocks[b]!];
    assert.deepEqual(rsSyndromes(codeword, spec.ecPerBlock), new Array<number>(spec.ecPerBlock).fill(0));
  }
});

test("maskPredicate:8 种掩码手算抽查", () => {
  assert.equal(maskPredicate(0, 0, 0), true);
  assert.equal(maskPredicate(0, 0, 1), false);
  assert.equal(maskPredicate(1, 0, 5), true);
  assert.equal(maskPredicate(1, 1, 0), false);
  assert.equal(maskPredicate(2, 5, 0), true);
  assert.equal(maskPredicate(2, 5, 1), false);
  assert.equal(maskPredicate(2, 5, 3), true);
  assert.equal(maskPredicate(3, 1, 2), true);
  assert.equal(maskPredicate(3, 1, 1), false);
  assert.equal(maskPredicate(4, 0, 0), true);
  assert.equal(maskPredicate(4, 2, 0), false);
  assert.equal(maskPredicate(4, 2, 3), true);
  assert.equal(maskPredicate(4, 0, 3), false);
  assert.equal(maskPredicate(5, 0, 7), true);
  assert.equal(maskPredicate(5, 1, 1), false);
  assert.equal(maskPredicate(5, 2, 3), true);
  assert.equal(maskPredicate(5, 3, 3), false);
  assert.equal(maskPredicate(6, 1, 1), true);
  assert.equal(maskPredicate(6, 2, 1), true);
  assert.equal(maskPredicate(6, 3, 1), false);
  assert.equal(maskPredicate(7, 0, 0), true);
  assert.equal(maskPredicate(7, 1, 1), false);
  assert.equal(maskPredicate(7, 3, 1), true);
  assert.throws(() => maskPredicate(8, 0, 0), RangeError);
});

test("掩码罚分:四条规则的手工向量", () => {
  const allDark5 = Array.from({ length: 5 }, () => new Array<boolean>(5).fill(true));
  assert.equal(penaltyRuns(allDark5), 30); // 每行每列 3 分
  assert.equal(penaltyBlocks(allDark5), 48); // 4×4 个 2×2 块
  assert.equal(penaltyFinderLike(allDark5), 0); // 宽度不足 11
  assert.equal(penaltyDarkRatio(allDark5), 100); // 100% 暗 → k=10

  const allLight6 = Array.from({ length: 6 }, () => new Array<boolean>(6).fill(false));
  assert.equal(penaltyRuns(allLight6), 48); // 每条线 3+(6−5)=4 分 ×12

  const checker6 = Array.from({ length: 6 }, (_, r) =>
    Array.from({ length: 6 }, (_, c) => (r + c) % 2 === 0),
  );
  assert.equal(penaltyRuns(checker6), 0);
  assert.equal(penaltyBlocks(checker6), 0);
  assert.equal(penaltyFinderLike(checker6), 0);
  assert.equal(penaltyDarkRatio(checker6), 0); // 恰好 50%

  // 1:1:3:1:1 + 一侧 4 亮:正向一次
  const finderRow = [true, false, true, true, true, false, true, false, false, false, false];
  const single11 = Array.from({ length: 11 }, (_, r) =>
    r === 0 ? [...finderRow] : new Array<boolean>(11).fill(false),
  );
  assert.equal(penaltyFinderLike(single11), 40);
  // 两侧都有 4 亮时,两个滑窗各计一次
  const centered15 = Array.from({ length: 15 }, (_, r) =>
    r === 7
      ? [false, false, false, false, true, false, true, true, true, false, true, false, false, false, false]
      : new Array<boolean>(15).fill(false),
  );
  assert.equal(penaltyFinderLike(centered15), 80);
});

test("格式信息:BCH(15,5) 自洽、掩码 0x5412、码间距 ≥7", () => {
  const all = new Set<number>();
  for (let mask = 0; mask < 8; mask++) {
    const bits = formatInfoBits(mask);
    assert.ok(bits >= 0 && bits < 1 << 15);
    all.add(bits);
    const unmasked = bits ^ 0x5412;
    assert.equal(bchRemainder(unmasked, 0x537, 10, 15), 0, `mask ${mask} BCH 余数应为 0`);
    const data5 = unmasked >>> 10;
    assert.equal(data5 >>> 3, 0b00, "EC level 指示位应为 M(00)");
    assert.equal(data5 & 0b111, mask);
  }
  assert.equal(all.size, 8);
  const values = [...all];
  for (let i = 0; i < values.length; i++) {
    for (let j = i + 1; j < values.length; j++) {
      assert.ok(hammingDistance(values[i]!, values[j]!) >= 7, "BCH(15,5) 最小码距为 7");
    }
  }
  assert.throws(() => formatInfoBits(8), RangeError);
});

test("版本信息:BCH(18,6) 自洽与已知向量(v7/v8)", () => {
  assert.equal(versionInfoBits(7), 0x07c94);
  assert.equal(versionInfoBits(8), 0x085bc);
  const values: number[] = [];
  for (let v = 7; v <= QR_MAX_VERSION; v++) {
    const bits = versionInfoBits(v);
    assert.equal(bits >>> 12, v);
    assert.equal(bchRemainder(bits, 0x1f25, 12, 18), 0, `v${v} BCH 余数应为 0`);
    values.push(bits);
  }
  for (let i = 0; i < values.length; i++) {
    for (let j = i + 1; j < values.length; j++) {
      assert.ok(hammingDistance(values[i]!, values[j]!) >= 8, "版本信息码最小码距为 8");
    }
  }
});
