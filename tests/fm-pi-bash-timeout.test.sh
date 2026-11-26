#!/usr/bin/env bash
# Opt-in default and cap behavior for Pi primary Bash tool calls.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const extensionPath = resolve(".pi/extensions/fm-primary-turnend-guard.ts");
const testHome = mkdtempSync(resolve(tmpdir(), "fm-pi-bash-timeout-test-"));
process.once("exit", () => rmSync(testHome, { recursive: true, force: true }));
process.env.FM_HOME = testHome;
process.env.FM_STATE_OVERRIDE = resolve(testHome, "state");
async function run(setting, timeout) {
  if (setting === undefined) delete process.env.FM_PI_BASH_TIMEOUT_MAX_MS;
  else process.env.FM_PI_BASH_TIMEOUT_MAX_MS = setting;
  const handlers = new Map();
  const pi = { on(event, handler) { handlers.set(event, handler); }, sendMessage() {} };
  const mod = await import(`${pathToFileURL(extensionPath).href}?case=${Math.random()}`);
  mod.default(pi);
  const input = timeout === undefined ? { command: "" } : { command: "", timeout };
  await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input });
  await handlers.get("session_shutdown")();
  return input;
}
assert.equal((await run(undefined)).timeout, undefined, "unset setting preserves default behavior");
assert.equal((await run("5000")).timeout, 5, "opt-in supplies missing timeout in seconds");
assert.equal((await run("5000", 60)).timeout, 5, "opt-in caps larger timeout in seconds");
assert.equal((await run("5000", 3)).timeout, 3, "opt-in preserves shorter timeout in seconds");
assert.equal((await run("5000", 5)).timeout, 5, "opt-in preserves timeout equal to cap");
assert.equal((await run("500")).timeout, 0.5, "subsecond cap supplies fractional seconds");
assert.equal((await run("500", 1)).timeout, 0.5, "subsecond cap bounds an explicit timeout");
assert.equal((await run("500", 0.25)).timeout, 0.25, "subsecond cap preserves shorter timeout");
assert.equal((await run("1")).timeout, 0.001, "minimum cap supplies one millisecond in seconds");
assert.equal((await run("2147483647")).timeout, 2147483.647, "native timer maximum supplies a supported timeout");
assert.equal((await run("2147483647", 2147483.648)).timeout, 2147483.647, "native timer maximum caps an unsupported explicit timeout");
for (const setting of ["2147483648", "9007199254740991", "9007199254740992"]) {
  assert.equal((await run(setting)).timeout, undefined, `${setting} cannot inject an unsupported timeout`);
  assert.equal((await run(setting, 60)).timeout, 60, `${setting} preserves an explicit timeout`);
}
assert.equal((await run("invalid")).timeout, undefined, "invalid setting leaves call unchanged");
JS
pass "Pi Bash timeout cap is opt-in, bounded, and preserves shorter timeouts"
