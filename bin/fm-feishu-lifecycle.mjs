#!/usr/bin/env node
// Credential-blind launcher for configuration-driven Feishu activation.
//
// The dedicated transport process parses config/feishu.env and owns all
// credential handling.  This launcher forwards session identity on stdin and
// exposes only its body-free result to the Pi extension.
import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const MODULE_FILE = fileURLToPath(import.meta.url);
const ROOT = resolve(dirname(MODULE_FILE), "..");
const HOME = realpathSync(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || ROOT);
const TRANSPORT_SCRIPT = process.env.FM_FEISHU_TRANSPORT_SCRIPT || resolve(ROOT, "bin/fm-feishu-transport.sh");
const transportEnvironment = Object.fromEntries(Object.entries({
  ...process.env,
  FM_HOME: HOME,
  FM_ROOT_OVERRIDE: ROOT,
  FM_FEISHU_SILENT: "1",
  FM_FEISHU_APP_ID: undefined,
  FM_FEISHU_APP_SECRET: undefined,
  FM_FEISHU_P2P_CHAT_ID: undefined,
  FM_FEISHU_CONFIG_IDENTITY: undefined,
}).filter(([, value]) => typeof value === "string"));

function usage() {
  return "usage: fm-feishu-lifecycle.mjs reconcile";
}

async function main(argv) {
  if (argv.shift() !== "reconcile" || argv.length > 0) throw new Error(usage());
  const child = spawn(TRANSPORT_SCRIPT, ["reconcile"], {
    cwd: ROOT,
    env: transportEnvironment,
    stdio: ["pipe", "pipe", "pipe"],
  });
  process.stdin.pipe(child.stdin);
  child.stdout.pipe(process.stdout);
  child.stderr.pipe(process.stderr);
  await new Promise((resolvePromise, rejectPromise) => {
    child.once("error", rejectPromise);
    child.once("close", (code) => {
      if (code === 0) resolvePromise();
      else rejectPromise(Object.assign(new Error("Feishu activation stopped safely; inspect config/feishu.env and docs/feishu-channel.md"), { reported: true }));
    });
  });
}

main(process.argv.slice(2)).catch((error) => {
  if (!error?.reported) process.stderr.write("Feishu activation stopped safely; inspect config/feishu.env and docs/feishu-channel.md\n");
  process.exitCode = 2;
});
