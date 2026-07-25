// 零依赖 QR 编码器:byte mode、EC level M、v1–v13,按 ISO/IEC 18004 实现。
// 配对 payload 只在本机终端一次性展示,M 级纠错足够;v13-M 可容纳 331 字节。
// 每个步骤(bit 流、RS、交织、功能图形、掩码罚分、格式/版本信息)单独导出,
// 以便确定性单测;qrMatrix / encodeQr 是组合入口。

export const QR_MIN_VERSION = 1;
export const QR_MAX_VERSION = 13;

/** EC level M 在格式信息里的指示位(L=01 M=00 Q=11 H=10) */
const EC_LEVEL_M_BITS = 0b00;

export interface QrVersionSpec {
  /** 每个 RS block 的纠错码字数 */
  ecPerBlock: number;
  /** [block 个数, 每 block 数据码字数];标准规定短 block 在前 */
  blocks: readonly (readonly [number, number])[];
}

// ISO/IEC 18004 表 9 的 EC level M 行(v1–v13),下标 = version - 1
const VERSION_SPECS: readonly QrVersionSpec[] = [
  { ecPerBlock: 10, blocks: [[1, 16]] },
  { ecPerBlock: 16, blocks: [[1, 28]] },
  { ecPerBlock: 26, blocks: [[1, 44]] },
  { ecPerBlock: 18, blocks: [[2, 32]] },
  { ecPerBlock: 24, blocks: [[2, 43]] },
  { ecPerBlock: 16, blocks: [[4, 27]] },
  { ecPerBlock: 18, blocks: [[4, 31]] },
  { ecPerBlock: 22, blocks: [[2, 38], [2, 39]] },
  { ecPerBlock: 22, blocks: [[3, 36], [2, 37]] },
  { ecPerBlock: 26, blocks: [[4, 43], [1, 44]] },
  { ecPerBlock: 30, blocks: [[1, 50], [4, 51]] },
  { ecPerBlock: 22, blocks: [[6, 36], [2, 37]] },
  { ecPerBlock: 22, blocks: [[8, 37], [1, 38]] },
];

// 对齐图形中心坐标(v1 没有),下标 = version - 1
const ALIGNMENT_CENTERS: readonly (readonly number[])[] = [
  [],
  [6, 18],
  [6, 22],
  [6, 26],
  [6, 30],
  [6, 34],
  [6, 22, 38],
  [6, 24, 42],
  [6, 26, 46],
  [6, 28, 50],
  [6, 30, 54],
  [6, 32, 58],
  [6, 34, 62],
];

export function versionSpec(version: number): QrVersionSpec {
  const spec = VERSION_SPECS[version - 1];
  if (version < QR_MIN_VERSION || version > QR_MAX_VERSION || spec === undefined) {
    throw new RangeError(`QR version 超出支持范围(v1–v${QR_MAX_VERSION}):${version}`);
  }
  return spec;
}

export function versionSize(version: number): number {
  versionSpec(version);
  return 17 + version * 4;
}

export function dataCodewordCount(version: number): number {
  let total = 0;
  for (const [count, dataLen] of versionSpec(version).blocks) total += count * dataLen;
  return total;
}

export function totalCodewordCount(version: number): number {
  const spec = versionSpec(version);
  let blockCount = 0;
  for (const [count] of spec.blocks) blockCount += count;
  return dataCodewordCount(version) + blockCount * spec.ecPerBlock;
}

function charCountBits(version: number): number {
  return version <= 9 ? 8 : 16;
}

/** byte mode 下该 version 能放的最大字节数(终止符可被填充吸收,不计入) */
export function byteCapacity(version: number): number {
  const headerBits = 4 + charCountBits(version);
  return Math.floor((dataCodewordCount(version) * 8 - headerBits) / 8);
}

export function selectVersion(byteLength: number): number {
  for (let v = QR_MIN_VERSION; v <= QR_MAX_VERSION; v++) {
    if (byteCapacity(v) >= byteLength) return v;
  }
  throw new RangeError(
    `payload ${byteLength} 字节超出 v${QR_MAX_VERSION}-M 容量 ${byteCapacity(QR_MAX_VERSION)} 字节`,
  );
}

// MARK: - bit 流

export class BitBuffer {
  #bits: number[] = [];

  get length(): number {
    return this.#bits.length;
  }

  /** 大端追加 value 的低 bitLength 位 */
  push(value: number, bitLength: number): void {
    for (let i = bitLength - 1; i >= 0; i--) this.#bits.push((value >>> i) & 1);
  }

  toBytes(): Uint8Array {
    const out = new Uint8Array(Math.ceil(this.#bits.length / 8));
    for (let i = 0; i < this.#bits.length; i++) {
      if (this.#bits[i] === 1) out[i >> 3] = out[i >> 3]! | (0x80 >>> (i & 7));
    }
    return out;
  }
}

/** mode 0100 + 长度域(v1–9 8bit / v10+ 16bit) + 数据 + 终止符 + 位填充 + 0xEC/0x11 交替填充 */
export function buildDataCodewords(bytes: Uint8Array, version: number): Uint8Array {
  const capacityBits = dataCodewordCount(version) * 8;
  const bits = new BitBuffer();
  bits.push(0b0100, 4);
  bits.push(bytes.length, charCountBits(version));
  for (const byte of bytes) bits.push(byte, 8);
  if (bits.length > capacityBits) {
    throw new RangeError(`数据超出 v${version}-M 容量:${bits.length} > ${capacityBits} bits`);
  }
  bits.push(0, Math.min(4, capacityBits - bits.length));
  if (bits.length % 8 !== 0) bits.push(0, 8 - (bits.length % 8));
  let pad = 0xec;
  while (bits.length < capacityBits) {
    bits.push(pad, 8);
    pad = pad === 0xec ? 0x11 : 0xec;
  }
  return bits.toBytes();
}

// MARK: - GF(256) 与 Reed-Solomon

// 本原多项式 x^8+x^4+x^3+x^2+1(0x11d),QR 规范固定;exp 表加倍避免取模
const GF_EXP = new Uint8Array(512);
const GF_LOG = new Uint8Array(256);
{
  let x = 1;
  for (let i = 0; i < 255; i++) {
    GF_EXP[i] = x;
    GF_LOG[x] = i;
    x <<= 1;
    if ((x & 0x100) !== 0) x ^= 0x11d;
  }
  for (let i = 255; i < 512; i++) GF_EXP[i] = GF_EXP[i - 255]!;
}

export function gfMul(a: number, b: number): number {
  if (a === 0 || b === 0) return 0;
  return GF_EXP[GF_LOG[a]! + GF_LOG[b]!]!;
}

/** 生成多项式 ∏(x − α^i),i=0..degree-1;返回降幂系数,首项恒为 1 */
export function rsGeneratorPoly(degree: number): Uint8Array {
  let poly = Uint8Array.of(1);
  for (let i = 0; i < degree; i++) {
    const next = new Uint8Array(poly.length + 1);
    const alpha = GF_EXP[i]!;
    for (let j = 0; j < poly.length; j++) {
      next[j] = next[j]! ^ poly[j]!;
      next[j + 1] = next[j + 1]! ^ gfMul(poly[j]!, alpha);
    }
    poly = next;
  }
  return poly;
}

/** data·x^ecLen 除以生成多项式的余数,即纠错码字 */
export function rsEncode(data: Uint8Array | readonly number[], ecLen: number): Uint8Array {
  const gen = rsGeneratorPoly(ecLen);
  const rem = new Uint8Array(ecLen);
  for (const byte of data) {
    const factor = byte ^ rem[0]!;
    rem.copyWithin(0, 1);
    rem[ecLen - 1] = 0;
    if (factor !== 0) {
      for (let i = 0; i < ecLen; i++) rem[i] = rem[i]! ^ gfMul(gen[i + 1]!, factor);
    }
  }
  return rem;
}

/** 最小 RS 解码校验器:合法码字(数据‖纠错)在 α^0..α^{ecLen-1} 处求值必须全为 0 */
export function rsSyndromes(codeword: Uint8Array | readonly number[], ecLen: number): number[] {
  const syndromes: number[] = [];
  for (let j = 0; j < ecLen; j++) {
    const alphaJ = GF_EXP[j]!;
    let value = 0;
    for (const byte of codeword) value = gfMul(value, alphaJ) ^ byte;
    syndromes.push(value);
  }
  return syndromes;
}

// MARK: - 分块与交织

export function splitIntoBlocks(dataCodewords: Uint8Array, version: number): Uint8Array[] {
  const blocks: Uint8Array[] = [];
  let offset = 0;
  for (const [count, dataLen] of versionSpec(version).blocks) {
    for (let i = 0; i < count; i++) {
      blocks.push(dataCodewords.slice(offset, offset + dataLen));
      offset += dataLen;
    }
  }
  if (offset !== dataCodewords.length) {
    throw new RangeError(`数据码字数与 v${version}-M 不符:${dataCodewords.length} ≠ ${offset}`);
  }
  return blocks;
}

/** 数据码字按列交织,再接上按列交织的纠错码字(ISO 18004 §8.6) */
export function interleaveCodewords(dataCodewords: Uint8Array, version: number): Uint8Array {
  const spec = versionSpec(version);
  const dataBlocks = splitIntoBlocks(dataCodewords, version);
  const ecBlocks = dataBlocks.map((block) => rsEncode(block, spec.ecPerBlock));
  const out = new Uint8Array(totalCodewordCount(version));
  let w = 0;
  const maxDataLen = Math.max(...dataBlocks.map((block) => block.length));
  for (let i = 0; i < maxDataLen; i++) {
    for (const block of dataBlocks) {
      if (i < block.length) out[w++] = block[i]!;
    }
  }
  for (let i = 0; i < spec.ecPerBlock; i++) {
    for (const block of ecBlocks) out[w++] = block[i]!;
  }
  return out;
}

// MARK: - 格式/版本信息编码

/** BCH(15,5) + 固定掩码 0x5412;数据 5 bit = EC level(M=00)‖mask */
export function formatInfoBits(mask: number): number {
  if (mask < 0 || mask > 7) throw new RangeError(`mask 超界:${mask}`);
  const data = (EC_LEVEL_M_BITS << 3) | mask;
  let rem = data;
  for (let i = 0; i < 10; i++) rem = (rem << 1) ^ (((rem >>> 9) & 1) * 0x537);
  return ((data << 10) | rem) ^ 0x5412;
}

/** BCH(18,6),v7+ 才需要 */
export function versionInfoBits(version: number): number {
  versionSpec(version);
  let rem = version;
  for (let i = 0; i < 12; i++) rem = (rem << 1) ^ (((rem >>> 11) & 1) * 0x1f25);
  return (version << 12) | rem;
}

/** 格式信息 15 bit 的两份放置坐标([row, col]),数组下标 = bit 序号(LSB 在前) */
export function formatBitPositions(size: number): {
  first: (readonly [number, number])[];
  second: (readonly [number, number])[];
} {
  const first: (readonly [number, number])[] = [];
  for (let i = 0; i <= 5; i++) first.push([i, 8]);
  first.push([7, 8], [8, 8], [8, 7]);
  for (let i = 9; i < 15; i++) first.push([8, 14 - i]);
  const second: (readonly [number, number])[] = [];
  for (let i = 0; i < 8; i++) second.push([8, size - 1 - i]);
  for (let i = 8; i < 15; i++) second.push([size - 15 + i, 8]);
  return { first, second };
}

/** 版本信息 18 bit 的两份放置坐标(右上 3×6 与左下 6×3),数组下标 = bit 序号 */
export function versionBitPositions(size: number): (readonly (readonly [number, number])[])[] {
  const out: (readonly (readonly [number, number])[])[] = [];
  for (let i = 0; i < 18; i++) {
    const a = size - 11 + (i % 3);
    const b = Math.floor(i / 3);
    out.push([
      [b, a],
      [a, b],
    ]);
  }
  return out;
}

// MARK: - 功能图形

export interface FunctionPatterns {
  size: number;
  /** 1=暗,行主序 */
  modules: Uint8Array;
  /** 1=功能图形或格式/版本信息区(不参与数据放置与掩码) */
  reserved: Uint8Array;
}

export function buildFunctionPatterns(version: number): FunctionPatterns {
  const size = versionSize(version);
  const modules = new Uint8Array(size * size);
  const reserved = new Uint8Array(size * size);
  const set = (row: number, col: number, dark: boolean): void => {
    const idx = row * size + col;
    modules[idx] = dark ? 1 : 0;
    reserved[idx] = 1;
  };

  // finder(含分隔符):中心 3×3 与外圈暗,中间圈与分隔符亮
  for (const [originRow, originCol] of [
    [0, 0],
    [0, size - 7],
    [size - 7, 0],
  ] as const) {
    for (let dr = -1; dr <= 7; dr++) {
      for (let dc = -1; dc <= 7; dc++) {
        const row = originRow + dr;
        const col = originCol + dc;
        if (row < 0 || row >= size || col < 0 || col >= size) continue;
        const inFinder = dr >= 0 && dr <= 6 && dc >= 0 && dc <= 6;
        set(row, col, inFinder && Math.max(Math.abs(dr - 3), Math.abs(dc - 3)) !== 2);
      }
    }
  }

  // timing:第 6 行/列,偶数坐标为暗
  for (let i = 8; i <= size - 9; i++) {
    set(6, i, i % 2 === 0);
    set(i, 6, i % 2 === 0);
  }

  // 对齐图形:5×5,中心与外圈暗;跳过与三个 finder 重叠的角
  const centers = ALIGNMENT_CENTERS[version - 1]!;
  const lastIndex = centers.length - 1;
  for (let ri = 0; ri < centers.length; ri++) {
    for (let ci = 0; ci < centers.length; ci++) {
      const cornerOverlap =
        (ri === 0 && ci === 0) || (ri === 0 && ci === lastIndex) || (ri === lastIndex && ci === 0);
      if (cornerOverlap) continue;
      const centerRow = centers[ri]!;
      const centerCol = centers[ci]!;
      for (let dr = -2; dr <= 2; dr++) {
        for (let dc = -2; dc <= 2; dc++) {
          set(centerRow + dr, centerCol + dc, Math.max(Math.abs(dr), Math.abs(dc)) !== 1);
        }
      }
    }
  }

  // 版本信息(v7+)只依赖 version,可在此直接画定
  if (version >= 7) {
    const bits = versionInfoBits(version);
    const positions = versionBitPositions(size);
    for (let i = 0; i < 18; i++) {
      const dark = ((bits >>> i) & 1) === 1;
      for (const [row, col] of positions[i]!) set(row, col, dark);
    }
  }

  // 格式信息区先占位:实际取值依赖掩码,由 drawFormatBitsInPlace 在评估/定稿时重画
  const { first, second } = formatBitPositions(size);
  for (const [row, col] of [...first, ...second]) set(row, col, false);
  // 固定暗模块
  set(size - 8, 8, true);

  return { size, modules, reserved };
}

// MARK: - 数据放置与掩码

/** 从右下角起两列一组之字形遍历,返回全部非保留模块坐标(含剩余位),顺序即放置顺序 */
export function dataModulePositions(
  size: number,
  isReserved: (row: number, col: number) => boolean,
): (readonly [number, number])[] {
  const out: (readonly [number, number])[] = [];
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5; // 竖直 timing 列不参与配对
    const upward = ((right + 1) & 2) === 0;
    for (let vert = 0; vert < size; vert++) {
      const row = upward ? size - 1 - vert : vert;
      for (let j = 0; j < 2; j++) {
        const col = right - j;
        if (!isReserved(row, col)) out.push([row, col]);
      }
    }
  }
  return out;
}

export function maskPredicate(mask: number, row: number, col: number): boolean {
  switch (mask) {
    case 0:
      return (row + col) % 2 === 0;
    case 1:
      return row % 2 === 0;
    case 2:
      return col % 3 === 0;
    case 3:
      return (row + col) % 3 === 0;
    case 4:
      return (Math.floor(row / 2) + Math.floor(col / 3)) % 2 === 0;
    case 5:
      return ((row * col) % 2) + ((row * col) % 3) === 0;
    case 6:
      return (((row * col) % 2) + ((row * col) % 3)) % 2 === 0;
    case 7:
      return (((row + col) % 2) + ((row * col) % 3)) % 2 === 0;
    default:
      throw new RangeError(`mask 超界:${mask}`);
  }
}

// MARK: - 掩码罚分(ISO 18004 §8.8.2,N1=3 N2=3 N3=40 N4=10)

export function penaltyRuns(matrix: readonly (readonly boolean[])[]): number {
  const size = matrix.length;
  let penalty = 0;
  const scoreLine = (at: (i: number) => boolean): void => {
    let runLength = 1;
    for (let i = 1; i <= size; i++) {
      if (i < size && at(i) === at(i - 1)) {
        runLength++;
        continue;
      }
      if (runLength >= 5) penalty += 3 + (runLength - 5);
      runLength = 1;
    }
  };
  for (let r = 0; r < size; r++) scoreLine((i) => matrix[r]![i]!);
  for (let c = 0; c < size; c++) scoreLine((i) => matrix[i]![c]!);
  return penalty;
}

export function penaltyBlocks(matrix: readonly (readonly boolean[])[]): number {
  const size = matrix.length;
  let penalty = 0;
  for (let r = 0; r + 1 < size; r++) {
    for (let c = 0; c + 1 < size; c++) {
      const v = matrix[r]![c]!;
      if (v === matrix[r]![c + 1]! && v === matrix[r + 1]![c]! && v === matrix[r + 1]![c + 1]!) {
        penalty += 3;
      }
    }
  }
  return penalty;
}

// 1:1:3:1:1 finder 比例 + 一侧 4 个亮模块;正反两个方向分别计数
const FINDER_RUN = [1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0] as const;

export function penaltyFinderLike(matrix: readonly (readonly boolean[])[]): number {
  const size = matrix.length;
  let hits = 0;
  const scanLine = (at: (i: number) => boolean): void => {
    for (let start = 0; start + FINDER_RUN.length <= size; start++) {
      let forward = true;
      let backward = true;
      for (let k = 0; k < FINDER_RUN.length; k++) {
        const dark = at(start + k);
        if (dark !== (FINDER_RUN[k] === 1)) forward = false;
        if (dark !== (FINDER_RUN[FINDER_RUN.length - 1 - k] === 1)) backward = false;
      }
      if (forward) hits++;
      if (backward) hits++;
    }
  };
  for (let r = 0; r < size; r++) scanLine((i) => matrix[r]![i]!);
  for (let c = 0; c < size; c++) scanLine((i) => matrix[i]![c]!);
  return hits * 40;
}

export function penaltyDarkRatio(matrix: readonly (readonly boolean[])[]): number {
  const size = matrix.length;
  let dark = 0;
  for (const row of matrix) {
    for (const cell of row) if (cell) dark++;
  }
  const percent = (dark * 100) / (size * size);
  return Math.floor(Math.abs(percent - 50) / 5) * 10;
}

export function penaltyScore(matrix: readonly (readonly boolean[])[]): number {
  return (
    penaltyRuns(matrix) + penaltyBlocks(matrix) + penaltyFinderLike(matrix) + penaltyDarkRatio(matrix)
  );
}

// MARK: - 组装

function toBooleanMatrix(cells: Uint8Array, size: number): boolean[][] {
  const rows: boolean[][] = [];
  for (let r = 0; r < size; r++) {
    const row: boolean[] = [];
    for (let c = 0; c < size; c++) row.push(cells[r * size + c] === 1);
    rows.push(row);
  }
  return rows;
}

function applyMaskInPlace(cells: Uint8Array, reserved: Uint8Array, size: number, mask: number): void {
  for (let r = 0; r < size; r++) {
    for (let c = 0; c < size; c++) {
      const idx = r * size + c;
      if (reserved[idx] === 0 && maskPredicate(mask, r, c)) cells[idx] = cells[idx] === 1 ? 0 : 1;
    }
  }
}

function drawFormatBitsInPlace(cells: Uint8Array, size: number, mask: number): void {
  const bits = formatInfoBits(mask);
  const { first, second } = formatBitPositions(size);
  for (let i = 0; i < 15; i++) {
    const dark = ((bits >>> i) & 1) === 1 ? 1 : 0;
    const [firstRow, firstCol] = first[i]!;
    const [secondRow, secondCol] = second[i]!;
    cells[firstRow * size + firstCol] = dark;
    cells[secondRow * size + secondCol] = dark;
  }
}

export interface QrEncodeDetail {
  version: number;
  size: number;
  mask: number;
  /** true=暗(黑)模块,不含 quiet zone */
  matrix: boolean[][];
  /** true=功能图形/格式/版本信息区 */
  reserved: boolean[][];
  /** 交织后的最终码字序列(数据+纠错) */
  codewords: Uint8Array;
}

export function encodeQr(text: string): QrEncodeDetail {
  const bytes = new TextEncoder().encode(text);
  const version = selectVersion(bytes.length);
  const codewords = interleaveCodewords(buildDataCodewords(bytes, version), version);

  const { size, modules, reserved } = buildFunctionPatterns(version);
  const positions = dataModulePositions(size, (row, col) => reserved[row * size + col] === 1);
  for (let i = 0; i < codewords.length * 8; i++) {
    const [row, col] = positions[i]!;
    modules[row * size + col] = (codewords[i >> 3]! >>> (7 - (i & 7))) & 1;
  }
  // 剩余位(v2–v6 有 7 个)保持亮,后续只被掩码翻转

  // 8 种掩码全评估:罚分计入该掩码对应的格式信息位
  let bestMask = 0;
  let bestScore = Number.POSITIVE_INFINITY;
  for (let mask = 0; mask < 8; mask++) {
    const candidate = modules.slice();
    applyMaskInPlace(candidate, reserved, size, mask);
    drawFormatBitsInPlace(candidate, size, mask);
    const score = penaltyScore(toBooleanMatrix(candidate, size));
    if (score < bestScore) {
      bestScore = score;
      bestMask = mask;
    }
  }

  applyMaskInPlace(modules, reserved, size, bestMask);
  drawFormatBitsInPlace(modules, size, bestMask);
  return {
    version,
    size,
    mask: bestMask,
    matrix: toBooleanMatrix(modules, size),
    reserved: toBooleanMatrix(reserved, size),
    codewords,
  };
}

/** 输入任意 UTF-8 字符串,返回 QR 矩阵;true=黑模块,不含 quiet zone */
export function qrMatrix(text: string): boolean[][] {
  return encodeQr(text).matrix;
}
