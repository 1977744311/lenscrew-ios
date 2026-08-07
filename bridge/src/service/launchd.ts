// launchd 常驻:把 bridge 装成 macOS LaunchAgent——开机自启、崩溃拉起、日志落盘。
// plist 生成与参数组装是纯函数(可单测);launchctl 交互集中在 install/uninstall/status 薄壳里。

import { execFile } from "node:child_process";
import { chmodSync, mkdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { homedir, userInfo } from "node:os";
import { join } from "node:path";

export const SERVICE_LABEL = "com.lenscrew.bridge";

export interface ServicePlistInputs {
  label: string;
  /** node 可执行文件的真实路径(realpath 后,避开 fnm multishell 短命软链) */
  nodePath: string;
  /** bin/lenscrew.ts 的绝对路径 */
  entryPath: string;
  /** 传给 `up` 的参数,全部显式化让 plist 自描述 */
  upArgs: string[];
  logPath: string;
  workingDirectory: string;
  pathEnv: string;
}

function escapeXml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function buildLaunchdPlist(inputs: ServicePlistInputs): string {
  const args = [inputs.nodePath, inputs.entryPath, "up", ...inputs.upArgs]
    .map((arg) => `    <string>${escapeXml(arg)}</string>`)
    .join("\n");
  return [
    `<?xml version="1.0" encoding="UTF-8"?>`,
    `<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">`,
    `<plist version="1.0">`,
    `<dict>`,
    `  <key>Label</key>`,
    `  <string>${escapeXml(inputs.label)}</string>`,
    `  <key>ProgramArguments</key>`,
    `  <array>`,
    args,
    `  </array>`,
    `  <key>WorkingDirectory</key>`,
    `  <string>${escapeXml(inputs.workingDirectory)}</string>`,
    `  <key>EnvironmentVariables</key>`,
    `  <dict>`,
    `    <key>PATH</key>`,
    `    <string>${escapeXml(inputs.pathEnv)}</string>`,
    `  </dict>`,
    `  <key>RunAtLoad</key>`,
    `  <true/>`,
    `  <key>KeepAlive</key>`,
    `  <true/>`,
    `  <key>StandardOutPath</key>`,
    `  <string>${escapeXml(inputs.logPath)}</string>`,
    `  <key>StandardErrorPath</key>`,
    `  <string>${escapeXml(inputs.logPath)}</string>`,
    `</dict>`,
    `</plist>`,
    ``,
  ].join("\n");
}

/**
 * launchd 不继承 shell 环境,PATH 必须在安装时快照进 plist。
 * 逐项 realpath 化:fnm multishell 目录是每个 shell 会话的短命软链,
 * 解析成真实安装目录(node-versions/…)后跨重启依然有效;spawn codex/claude 全靠它。
 */
export function stabilizedPathEnv(
  pathEnv: string,
  resolve: (dir: string) => string = (dir) => realpathSync(dir),
): string {
  const seen = new Set<string>();
  for (const dir of pathEnv.split(":")) {
    if (dir === "") continue;
    let real = dir;
    try {
      real = resolve(dir);
    } catch {
      // 目录不存在就原样保留,不因一项脏数据丢掉整条 PATH
    }
    seen.add(real);
  }
  return [...seen].join(":");
}

export interface ServiceUpOptions {
  host: string;
  port: number;
  token: string;
  relay: string | null;
  name: string;
  stateDir: string | null;
  allowPlaintextLan?: boolean;
}

/** 把 up 选项全部显式化成 argv,plist 里不留"默认值随版本漂移"的余地 */
export function canonicalUpArgs(options: ServiceUpOptions): string[] {
  const args = [
    "--host",
    options.host,
    "--port",
    String(options.port),
    "--token",
    options.token,
    "--name",
    options.name,
  ];
  if (options.relay !== null) {
    args.push("--relay", options.relay);
  }
  if (options.stateDir !== null) {
    args.push("--state-dir", options.stateDir);
  }
  if (options.allowPlaintextLan === true) {
    args.push("--allow-plaintext-lan");
  }
  return args;
}

function launchctl(args: string[]): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    execFile("launchctl", args, { encoding: "utf8" }, (error, stdout, stderr) => {
      const code =
        error !== null && typeof (error as NodeJS.ErrnoException & { code?: unknown }).code === "number"
          ? ((error as unknown as { code: number }).code)
          : error !== null
            ? 1
            : 0;
      resolve({ code, stdout, stderr });
    });
  });
}

function guiDomain(): string {
  return `gui/${userInfo().uid}`;
}

export function servicePlistPath(): string {
  return join(homedir(), "Library", "LaunchAgents", `${SERVICE_LABEL}.plist`);
}

export interface InstallServiceInputs {
  options: ServiceUpOptions;
  /** bin/lenscrew.ts 的绝对路径(调用方从 process.argv[1] realpath 得来) */
  entryPath: string;
  stateDir: string;
  log: (line: string) => void;
}

export async function installService(inputs: InstallServiceInputs): Promise<void> {
  const logDir = join(inputs.stateDir, "logs");
  mkdirSync(logDir, { recursive: true, mode: 0o700 });
  const logPath = join(logDir, "bridge.log");

  const plist = buildLaunchdPlist({
    label: SERVICE_LABEL,
    nodePath: realpathSync(process.execPath),
    entryPath: inputs.entryPath,
    upArgs: canonicalUpArgs(inputs.options),
    logPath,
    workingDirectory: join(inputs.entryPath, "..", ".."),
    pathEnv: stabilizedPathEnv(process.env["PATH"] ?? "/usr/bin:/bin"),
  });

  const plistPath = servicePlistPath();
  mkdirSync(join(homedir(), "Library", "LaunchAgents"), { recursive: true });
  // token 明文在 plist 里,权限收紧到仅本人可读
  writeFileSync(plistPath, plist, { mode: 0o600 });
  chmodSync(plistPath, 0o600);

  // 重装 = 先卸旧再装新;bootout 失败(之前没装过)是正常路径。
  // bootout 是异步的,旧实例没退干净就 bootstrap 会报 5: Input/output error,
  // 轮询到 label 真正消失再装。
  await launchctl(["bootout", `${guiDomain()}/${SERVICE_LABEL}`]);
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const probe = await launchctl(["print", `${guiDomain()}/${SERVICE_LABEL}`]);
    if (probe.code !== 0) break;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  const result = await launchctl(["bootstrap", guiDomain(), plistPath]);
  if (result.code !== 0) {
    throw new Error(`launchctl bootstrap 失败: ${result.stderr.trim() || result.stdout.trim()}`);
  }

  inputs.log(`已安装 LaunchAgent ${SERVICE_LABEL}(开机自启,崩溃自动拉起)`);
  inputs.log(`plist  ${plistPath}`);
  inputs.log(`日志   ${logPath}`);
  inputs.log(`口令   ${inputs.options.token}`);
  inputs.log(`稍候几秒 bridge 起来后,可用 lenscrew qr 重开配对窗口扫码`);
}

export async function uninstallService(log: (line: string) => void): Promise<void> {
  const result = await launchctl(["bootout", `${guiDomain()}/${SERVICE_LABEL}`]);
  rmSync(servicePlistPath(), { force: true });
  if (result.code === 0) {
    log(`已停止并卸载 ${SERVICE_LABEL}`);
  } else {
    log(`${SERVICE_LABEL} 本就不在运行,已清理 plist`);
  }
}

export async function serviceStatus(log: (line: string) => void): Promise<void> {
  const result = await launchctl(["print", `${guiDomain()}/${SERVICE_LABEL}`]);
  if (result.code !== 0) {
    log(`${SERVICE_LABEL} 未安装(lenscrew service install 安装常驻)`);
    return;
  }
  const interesting = result.stdout
    .split("\n")
    .filter((line) => /^\s*(state|pid|last exit code|path)\s*=/.test(line))
    .map((line) => line.trim());
  log(`${SERVICE_LABEL}`);
  for (const line of interesting) {
    log(`  ${line}`);
  }
}
