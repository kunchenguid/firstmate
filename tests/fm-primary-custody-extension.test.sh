#!/usr/bin/env bash
# Runtime contract tests for the Pi-side primary custody attestor.
set -eu
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo 'skip: node not found'; exit 0; }
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-primary-custody-extension.XXXXXX")
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/.pi/extensions" "$T/repo/bin"
cp "$ROOT/.pi/extensions/fm-primary-custody.ts" "$T/repo/.pi/extensions/fm-primary-custody.ts"
PLUGIN="$T/repo/.pi/extensions/fm-primary-custody.ts"
LOG="$T/attest.log"

cat > "$T/repo/bin/fm-primary-pi.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ATTEST_LOG"
if [ -e "$TEST_ATTEST_FAIL" ]; then
  printf 'failed\n'
  exit 1
fi
if [ -e "$TEST_ATTEST_PENDING" ]; then
  printf 'pending\n'
  exit 0
fi
printf 'ok\n'
SH
chmod +x "$T/repo/bin/fm-primary-pi.sh"

run_node_case() {
  PLUGIN="$PLUGIN" TEST_ATTEST_LOG="$LOG" TEST_ATTEST_FAIL="$T/fail" TEST_ATTEST_PENDING="$T/pending" \
  FM_PRIMARY_PI_TOKEN=0123456789abcdef0123456789abcdef \
  FM_PRIMARY_PI_RECOVERY="${TEST_RECOVERY_MODE:-1}" \
  node --input-type=module
}

: > "$LOG"
out=$(run_node_case 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
const handlers = new Map();
let shutdowns = 0;
const notices = [];
const pi = { on(name, handler) { handlers.set(name, handler); } };
const ctx = {
  sessionManager: {
    getSessionFile: () => "/canonical/sessions/full.jsonl",
    getSessionId: () => "full-session-id",
    getSessionDir: () => "/canonical/sessions",
    getCwd: () => "/canonical/project",
  },
  ui: { notify(message, level) { notices.push([message, level]); } },
  shutdown() { shutdowns += 1; },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
for (const required of ["session_start", "agent_settled", "input"]) {
  if (!handlers.has(required)) throw new Error(`missing handler ${required}`);
}
const before = await handlers.get("input")({}, ctx);
if (before.action !== "handled") throw new Error("input was accepted before attestation");
await handlers.get("session_start")({ reason: "startup" }, ctx);
if (shutdowns !== 0) throw new Error("successful exact attestation shut Pi down");
const after = await handlers.get("input")({}, ctx);
if (after.action !== "continue") throw new Error("input remained blocked after attestation");
if (process.env.FM_PRIMARY_PI_RECOVERY !== "0") throw new Error("one-shot recovery expectation was not cleared");
if (!notices.some(([message]) => message.includes("not attested"))) throw new Error("blocked input did not explain why");
await handlers.get("agent_settled")({}, ctx);
JS
) || fail "successful custody extension case failed: $out"
[ -z "$out" ] || fail "successful custody extension case printed output: $out"
assert_grep 'attest --token 0123456789abcdef0123456789abcdef' "$LOG" 'extension must call the custody executable interface'
assert_grep '--actual-id full-session-id' "$LOG" 'extension must report the full actual session id'
assert_grep '--session-file /canonical/sessions/full.jsonl' "$LOG" 'extension must report the actual full session path'
assert_grep '--session-dir /canonical/sessions' "$LOG" 'extension must report the actual session directory'
assert_grep '--cwd /canonical/project' "$LOG" 'extension must report the actual session cwd'
assert_grep '--reason startup --recovery' "$LOG" 'recovery startup must request strict expected-identity attestation'
[ "$(wc -l < "$LOG" | tr -d ' ')" -eq 1 ] || fail 'an established session must not re-attest on routine settlement'
pass 'custody extension blocks input until exact recovery startup attests without routine rechecks'

: > "$LOG"
touch "$T/fail"
out=$(run_node_case 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
const handlers = new Map();
let shutdowns = 0;
let notice = "";
const pi = { on(name, handler) { handlers.set(name, handler); } };
const ctx = {
  sessionManager: {
    getSessionFile: () => "/canonical/sessions/full.jsonl",
    getSessionId: () => "full-session-id",
    getSessionDir: () => "/canonical/sessions",
    getCwd: () => "/canonical/project",
  },
  ui: { notify(message) { notice = message; } },
  shutdown() { shutdowns += 1; },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")({ reason: "startup" }, ctx);
if (shutdowns !== 1) throw new Error(`failed startup shutdown count ${shutdowns}`);
if (!notice.includes("attestation failed")) throw new Error(`missing failure notice: ${notice}`);
const input = await handlers.get("input")({}, ctx);
if (input.action !== "handled") throw new Error("failed startup accepted input");
JS
) || fail "failed custody extension case failed: $out"
[ -z "$out" ] || fail "failed custody extension case printed output: $out"
pass 'custody extension shuts Pi down and keeps input blocked after failed attestation'

rm "$T/fail"
touch "$T/pending"
: > "$LOG"
out=$(TEST_RECOVERY_MODE=0 run_node_case 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import { unlinkSync, writeFileSync } from "node:fs";
const handlers = new Map();
let shutdowns = 0;
const pi = { on(name, handler) { handlers.set(name, handler); } };
const ctx = {
  sessionManager: {
    getSessionFile: () => "/canonical/sessions/full.jsonl",
    getSessionId: () => "full-session-id",
    getSessionDir: () => "/canonical/sessions",
    getCwd: () => "/canonical/project",
  },
  ui: { notify() {} },
  shutdown() { shutdowns += 1; },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")({ reason: "startup" }, ctx);
const input = await handlers.get("input")({}, ctx);
if (input.action !== "continue") throw new Error("new pending session did not accept input");
unlinkSync(process.env.TEST_ATTEST_PENDING);
await handlers.get("agent_settled")({}, ctx);
if (shutdowns !== 0) throw new Error("successful persistence finalization shut Pi down");
writeFileSync(process.env.TEST_ATTEST_FAIL, "fail\n");
await handlers.get("agent_settled")({}, ctx);
if (shutdowns !== 0) throw new Error("established session performed a routine settlement attest");
JS
) || fail "pending-finalization extension case failed: $out"
[ -z "$out" ] || fail "pending-finalization extension case printed output: $out"
[ "$(wc -l < "$LOG" | tr -d ' ')" -eq 2 ] || fail 'new session should attest only at startup and first persistence'
pass 'new pending custody finalizes once and then performs no routine rechecks'

rm "$T/fail"
touch "$T/pending"
: > "$LOG"
out=$(TEST_RECOVERY_MODE=0 run_node_case 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import { unlinkSync, writeFileSync } from "node:fs";
const handlers = new Map();
let shutdowns = 0;
const pi = { on(name, handler) { handlers.set(name, handler); } };
const ctx = {
  sessionManager: {
    getSessionFile: () => "/canonical/sessions/full.jsonl",
    getSessionId: () => "full-session-id",
    getSessionDir: () => "/canonical/sessions",
    getCwd: () => "/canonical/project",
  },
  ui: { notify() {} },
  shutdown() { shutdowns += 1; },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")({ reason: "startup" }, ctx);
unlinkSync(process.env.TEST_ATTEST_PENDING);
writeFileSync(process.env.TEST_ATTEST_FAIL, "fail\n");
await handlers.get("agent_settled")({}, ctx);
if (shutdowns !== 1) throw new Error(`failed finalization shutdown count ${shutdowns}`);
const input = await handlers.get("input")({}, ctx);
if (input.action !== "handled") throw new Error("failed finalization accepted later input");
JS
) || fail "failed-finalization extension case failed: $out"
[ -z "$out" ] || fail "failed-finalization extension case printed output: $out"
pass 'failed first persistence attestation revokes input and shuts Pi down'

printf 'all fm-primary-custody-extension runtime tests passed\n'
