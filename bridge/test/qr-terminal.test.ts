import test from "node:test";
import assert from "node:assert/strict";

import { renderQrAnsi } from "../src/qr/qrTerminal.ts";
import { renderPairingQr } from "../src/qr/index.ts";
import { encodeQr } from "../src/qr/qrEncode.ts";

const WHITE_FG = "\u001b[97m";
const RESET = "\u001b[0m";

function stripAnsi(text: string): string {
  return text.replaceAll(/\u001b\[[0-9;]*m/g, "");
}

test("renderQrAnsi:1×1 黑模块 + quietZone 1 的半块拼合", () => {
  const out = renderQrAnsi([[true]], { quietZone: 1 });
  const lines = out.split("\n");
  assert.equal(lines.length, 2);
  for (const line of lines) {
    assert.ok(line.startsWith(WHITE_FG) && line.endsWith(RESET), "每行都应包白色前景与复位");
  }
  // 白=█、黑=空格;上白下黑=▀;底部奇数行按白补
  assert.deepEqual(lines.map(stripAnsi), ["█▀█", "███"]);
});

test("renderQrAnsi:上黑下白用 ▄,全黑用空格", () => {
  const out = renderQrAnsi(
    [
      [true, true],
      [false, true],
    ],
    { quietZone: 0 },
  );
  assert.deepEqual(stripAnsi(out).split("\n"), ["▄ "]);
});

test("renderQrAnsi:默认 quietZone=2,全亮矩阵输出全白块", () => {
  const matrix = Array.from({ length: 5 }, () => new Array<boolean>(5).fill(false));
  const lines = stripAnsi(renderQrAnsi(matrix)).split("\n");
  assert.equal(lines.length, Math.ceil((5 + 4) / 2));
  for (const line of lines) assert.equal(line, "█".repeat(9));
});

test("renderPairingQr:整体尺寸与静区", () => {
  const payload = JSON.stringify({ v: 1, host: "127.0.0.1" });
  const size = encodeQr(payload).size;
  const lines = stripAnsi(renderPairingQr(payload)).split("\n");
  assert.equal(lines.length, Math.ceil((size + 4) / 2));
  for (const line of lines) assert.equal([...line].length, size + 4);
  // 顶部两行模块全是静区 → 首行全白
  assert.equal(lines[0], "█".repeat(size + 4));
  // 静区白边:每行首尾都是白块
  for (const line of lines) {
    assert.ok(line.startsWith("█") && line.endsWith("█"));
  }
  // 码区必然存在黑模块
  assert.ok(lines.some((line) => line.includes(" ") || line.includes("▀") || line.includes("▄")));
});
