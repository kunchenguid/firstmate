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
printf 'ok\n'
SH
chmod +x "$T/repo/bin/fm-primary-pi.sh"

run_node_case() {
  PLUGIN="$PLUGIN" TEST_ATTEST_LOG="$LOG" TEST_ATTEST_FAIL="$T/fail" \
  FM_PRIMARY_PI_TOKEN=0123456789abcdef0123456789abcdef \
  FM_PRIMARY_PI_RECOVERY=1 \
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
for (const required of ["session_start", "message_end", "agent_settled", "input"]) {
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
JS
) || fail "successful custody extension case failed: $out"
[ -z "$out" ] || fail "successful custody extension case printed output: $out"
assert_grep 'attest --token 0123456789abcdef0123456789abcdef' "$LOG" 'extension must call the custody executable interface'
assert_grep '--actual-id full-session-id' "$LOG" 'extension must report the full actual session id'
assert_grep '--session-file /canonical/sessions/full.jsonl' "$LOG" 'extension must report the actual full session path'
assert_grep '--session-dir /canonical/sessions' "$LOG" 'extension must report the actual session directory'
assert_grep '--cwd /canonical/project' "$LOG" 'extension must report the actual session cwd'
assert_grep '--reason startup --recovery' "$LOG" 'recovery startup must request strict expected-identity attestation'
pass 'custody extension blocks input until exact recovery startup attests'

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
: > "$LOG"
out=$(run_node_case 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";
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
writeFileSync(process.env.TEST_ATTEST_FAIL, "fail\n");
await handlers.get("agent_settled")({}, ctx);
if (shutdowns !== 1) throw new Error(`lost-integrity shutdown count ${shutdowns}`);
const input = await handlers.get("input")({}, ctx);
if (input.action !== "handled") throw new Error("lost integrity still accepted input");
JS
) || fail "lost-integrity extension case failed: $out"
[ -z "$out" ] || fail "lost-integrity extension case printed output: $out"
pass 'later session-integrity loss revokes input and shuts Pi down'

printf 'all fm-primary-custody-extension runtime tests passed\n'
