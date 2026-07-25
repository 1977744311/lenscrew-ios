// qr 模块对外入口:配对 payload → 可直接 console.log 的 ANSI 二维码字符串

import { qrMatrix } from "./qrEncode.ts";
import { renderQrAnsi } from "./qrTerminal.ts";

export { encodeQr, qrMatrix } from "./qrEncode.ts";
export type { QrEncodeDetail } from "./qrEncode.ts";
export { renderQrAnsi } from "./qrTerminal.ts";
export type { RenderQrAnsiOptions } from "./qrTerminal.ts";

export function renderPairingQr(payloadJson: string): string {
  return renderQrAnsi(qrMatrix(payloadJson));
}
