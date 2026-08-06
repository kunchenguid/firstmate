#!/usr/bin/env node
import { existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const allowed = new Set([
  "fm-sessionstart-run.sh",
  "fm-arm-pretool-check.sh",
  "fm-cd-pretool-check.sh",
  "fm-turnend-guard.sh",
]);

const script = process.argv[2] || "";
if (!allowed.has(script)) process.exit(0);

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const hooksPath = join(root, ".codex", "hooks.json");
const target = join(root, "bin", script);
if (!existsSync(join(root, "AGENTS.md")) || !existsSync(hooksPath) || !existsSync(target)) {
  process.exit(0);
}

try {
  const hooks = JSON.parse(readFileSync(hooksPath, "utf8"));
  if (!JSON.stringify(hooks).includes(script)) process.exit(0);
} catch {
  process.exit(0);
}

const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
const payload = Buffer.concat(chunks);
if (payload.length === 0) process.exit(0);

const candidates = process.platform === "win32"
  ? [
      process.env.ProgramFiles && join(process.env.ProgramFiles, "Git", "bin", "bash.exe"),
      process.env.LOCALAPPDATA && join(process.env.LOCALAPPDATA, "Programs", "Git", "bin", "bash.exe"),
      "bash.exe",
    ].filter(Boolean)
  : ["bash"];

for (const bash of candidates) {
  const result = spawnSync(bash, [target], {
    cwd: root,
    input: payload,
    encoding: null,
    windowsHide: true,
    stdio: ["pipe", "pipe", "pipe"],
  });
  if (result.error?.code === "ENOENT") continue;
  if (result.stdout?.length) process.stdout.write(result.stdout);
  if (result.stderr?.length) process.stderr.write(result.stderr);
  process.exit(Number.isInteger(result.status) ? result.status : 0);
}

// Hook transports are safety belts, not availability dependencies. If no
// verified Bash runtime is reachable, fail open instead of blocking every tool.
process.exit(0);
