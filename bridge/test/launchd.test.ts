import assert from "node:assert/strict";
import { test } from "node:test";

import {
  buildLaunchdPlist,
  canonicalUpArgs,
  stabilizedPathEnv,
  SERVICE_LABEL,
  servicePlistPath,
} from "../src/service/launchd.ts";

test("plist 包含常驻三件套:RunAtLoad、KeepAlive、日志双流同文件", () => {
  const plist = buildLaunchdPlist({
    label: SERVICE_LABEL,
    nodePath: "/opt/node/bin/node",
    entryPath: "/repo/bridge/bin/lenscrew.ts",
    upArgs: ["--host", "0.0.0.0", "--token", "secret"],
    logPath: "/home/u/.lenscrew/logs/bridge.log",
    workingDirectory: "/repo/bridge",
    pathEnv: "/opt/node/bin:/usr/bin",
  });
  assert.match(plist, /<key>RunAtLoad<\/key>\s*<true\/>/);
  assert.match(plist, /<key>KeepAlive<\/key>\s*<true\/>/);
  assert.equal(plist.match(/<string>\/home\/u\/\.lenscrew\/logs\/bridge\.log<\/string>/g)?.length, 2);
  // ProgramArguments 顺序:node、入口、up、透传参数
  const nodeAt = plist.indexOf("<string>/opt/node/bin/node</string>");
  const entryAt = plist.indexOf("<string>/repo/bridge/bin/lenscrew.ts</string>");
  const upAt = plist.indexOf("<string>up</string>");
  const hostAt = plist.indexOf("<string>--host</string>");
  assert.ok(nodeAt >= 0 && nodeAt < entryAt && entryAt < upAt && upAt < hostAt);
  assert.match(plist, /<key>PATH<\/key>\s*<string>\/opt\/node\/bin:\/usr\/bin<\/string>/);
});

test("plist 对 XML 特殊字符转义", () => {
  const plist = buildLaunchdPlist({
    label: SERVICE_LABEL,
    nodePath: "/n",
    entryPath: "/e",
    upArgs: ["--name", `a<b & "c"`],
    logPath: "/l",
    workingDirectory: "/w",
    pathEnv: "/p",
  });
  assert.ok(plist.includes("a&lt;b &amp; &quot;c&quot;"));
  assert.ok(!plist.includes(`a<b`));
});

test("canonicalUpArgs 全部显式化,relay/stateDir 缺席时不出现", () => {
  const base = canonicalUpArgs({
    host: "0.0.0.0",
    port: 4311,
    token: "tok",
    relay: null,
    name: "mac",
    stateDir: null,
  });
  assert.deepEqual(base, ["--host", "0.0.0.0", "--port", "4311", "--token", "tok", "--name", "mac"]);

  const full = canonicalUpArgs({
    host: "127.0.0.1",
    port: 0,
    token: "t",
    relay: "https://relay.example",
    name: "n",
    stateDir: "/tmp/state",
  });
  assert.deepEqual(full.slice(-4), ["--relay", "https://relay.example", "--state-dir", "/tmp/state"]);
});

test("stabilizedPathEnv 逐项 realpath 化、去重、坏目录原样保留", () => {
  const resolved = stabilizedPathEnv(
    "/tmp/fnm_multishells/1/bin:/usr/bin:/tmp/fnm_multishells/2/bin::/gone",
    (dir) => {
      if (dir.includes("fnm_multishells")) return "/fnm/node-versions/v24/bin";
      if (dir === "/gone") throw new Error("ENOENT");
      return dir;
    },
  );
  // 两个 multishell 项解析成同一真实目录后去重,空项被丢弃,坏目录保留
  assert.equal(resolved, "/fnm/node-versions/v24/bin:/usr/bin:/gone");
});

test("plist 安装路径在用户 LaunchAgents 下且带 label 名", () => {
  const path = servicePlistPath();
  assert.ok(path.endsWith(`/Library/LaunchAgents/${SERVICE_LABEL}.plist`));
});
