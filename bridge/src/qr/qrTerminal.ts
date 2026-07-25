// 终端 ANSI 渲染:深色终端上二维码必须"白底黑码"才可扫,
// 所以白模块用白色前景实心块画出,黑模块留终端默认(深色)背景,
// 每两行模块并成一行半块字符以保持接近 1:1 的宽高比。

export interface RenderQrAnsiOptions {
  /** 四周静区宽度(模块数) */
  quietZone?: number;
}

const WHITE_FG = "\u001b[97m";
const RESET = "\u001b[0m";

export function renderQrAnsi(
  matrix: readonly (readonly boolean[])[],
  options: RenderQrAnsiOptions = {},
): string {
  const quietZone = options.quietZone ?? 2;
  const size = matrix.length;
  const total = size + quietZone * 2;
  // 静区与底部奇数行的补齐都按亮(白)处理
  const isDark = (row: number, col: number): boolean => {
    const r = row - quietZone;
    const c = col - quietZone;
    return r >= 0 && r < size && c >= 0 && c < size && matrix[r]![c]!;
  };
  const lines: string[] = [];
  for (let row = 0; row < total; row += 2) {
    let line = WHITE_FG;
    for (let col = 0; col < total; col++) {
      const top = isDark(row, col);
      const bottom = isDark(row + 1, col);
      line += top ? (bottom ? " " : "▄") : bottom ? "▀" : "█";
    }
    lines.push(line + RESET);
  }
  return lines.join("\n");
}
