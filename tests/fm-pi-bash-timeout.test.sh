#!/usr/bin/env bash
# Opt-in default and cap behavior for Pi primary Bash tool calls.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const extensionPath = resolve(".pi/extensions/fm-primary-turnend-guard.ts");
async function run(setting, timeout) {
  if (setting === undefined) delete process.env.FM_PI_BASH_TIMEOUT_MAX_MS;
  else process.env.FM_PI_BASH_TIMEOUT_MAX_MS = setting;
  const handlers = new Map();
  const pi = { on(event, handler) { handlers.set(event, handler); }, sendMessage() {} };
  const mod = await import(`${pathToFileURL(extensionPath).href}?case=${Math.random()}`);
  mod.default(pi);
  const input = timeout === undefined ? { command: "" } : { command: "", timeout };
  await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input });
  return input;
}
assert.equal((await run(undefined)).timeout, undefined, "unset setting preserves default behavior");
assert.equal((await run("5000")).timeout, 5000, "opt-in supplies missing timeout");
assert.equal((await run("5000", 9000)).timeout, 5000, "opt-in caps larger timeout");
assert.equal((await run("5000", 3000)).timeout, 3000, "opt-in preserves shorter timeout");
assert.equal((await run("invalid")).timeout, undefined, "invalid setting leaves call unchanged");
JS
pass "Pi Bash timeout cap is opt-in, bounded, and preserves shorter timeouts"
