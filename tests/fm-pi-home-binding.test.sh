#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-home-binding)
MODULE="$ROOT/.pi/extensions/lib/fm-pi-home-binding.ts"

run_case() {
  local home=$1 reason=$2 entries=$3 expected=$4
  local session_file="$TMP_ROOT/session-${reason}-${expected}.jsonl"
  : > "$session_file"
  chmod 600 "$session_file"
  FM_HOME="$home" FM_REASON="$reason" FM_ENTRIES="$entries" FM_EXPECTED="$expected" FM_SESSION_FILE="$session_file" MODULE="$MODULE" \
    node --input-type=module <<'EOF'
import { mkdirSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const appended = [];
const entries = JSON.parse(process.env.FM_ENTRIES);
const manager = {
  getHeader: () => ({ timestamp: process.env.FM_REASON === "resume" ? "2020-01-01T00:00:00.000Z" : new Date().toISOString() }),
  getSessionFile: () => process.env.FM_SESSION_FILE,
  getEntries: () => entries,
  appendCustomEntry: (type, data) => appended.push({ type, data }),
};
const { resolvePiHome } = await import(pathToFileURL(process.env.MODULE).href);
const result = resolvePiHome({ sessionManager: manager }, process.env.FM_HOME, process.env.FM_REASON);
if (process.env.FM_EXPECTED === "ok") {
  if (!result.ok || result.home !== process.env.FM_HOME || result.state !== `${process.env.FM_HOME}/state` || result.config !== `${process.env.FM_HOME}/config`) throw new Error(`unexpected result: ${JSON.stringify(result)}`);
  if (appended.length !== 1) throw new Error(`fresh session did not record exactly one binding: ${JSON.stringify(appended)}`);
  if (appended[0].data.schema !== "firstmate.pi-home-binding.v1") throw new Error("binding schema missing");
} else if (result.ok) {
  throw new Error(`unsafe session unexpectedly resolved: ${JSON.stringify(result)}`);
}
EOF
}

home_a="$TMP_ROOT/home-a"
home_b="$TMP_ROOT/home-b"
mkdir -p "$home_a" "$home_b" "$home_a/state-real"
chmod 700 "$home_a" "$home_b"

run_case "$home_a" startup '[]' ok

pi_bin=$(readlink -f "$(command -v pi)")
pi_root=$(dirname "$(dirname "$pi_bin")")
real_session_dir="$TMP_ROOT/real-pi-sessions"
mkdir -p "$real_session_dir"
FM_HOME="$home_a" MODULE="$MODULE" PI_MODULE="$pi_root/lib/node_modules/pi-monorepo/dist/index.js" PI_SESSION_DIR="$real_session_dir" node --input-type=module <<'EOF'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { SessionManager } = await import(process.env.PI_MODULE);
const { resolvePiHome } = await import(pathToFileURL(process.env.MODULE).href);
const manager = SessionManager.create(process.env.FM_HOME, process.env.PI_SESSION_DIR);
const result = resolvePiHome({ sessionManager: manager }, process.env.FM_HOME, "startup", undefined, manager.appendCustomEntry.bind(manager));
if (!result.ok || !result.recorded) throw new Error(`real Pi session manager did not bind: ${JSON.stringify(result)}`);
manager.appendMessage({ role: "user", content: [{ type: "text", text: "real Pi session fixture" }], timestamp: Date.now() });
const sessionFile = manager.getSessionFile();
if (!sessionFile || !readFileSync(sessionFile, "utf8").includes("firstmate.pi-home-binding.v1")) {
  throw new Error(`real Pi session file lacks the durable binding: ${sessionFile}`);
}
EOF

session_file="$TMP_ROOT/session-resume.jsonl"
: > "$session_file"
chmod 600 "$session_file"
FM_HOME="$home_b" FM_SESSION_FILE="$session_file" FM_ENTRIES="$(printf '[{"type":"custom","customType":"firstmate-pi-home-binding","data":{"schema":"firstmate.pi-home-binding.v1","home":"%s"}}]' "$home_a")" MODULE="$MODULE" \
  node --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";
const { resolvePiHome } = await import(pathToFileURL(process.env.MODULE).href);
const manager = {
  getHeader: () => ({ timestamp: "2020-01-01T00:00:00.000Z" }),
  getSessionFile: () => process.env.FM_SESSION_FILE,
  getEntries: () => JSON.parse(process.env.FM_ENTRIES),
};
const result = resolvePiHome({ sessionManager: manager }, process.env.FM_HOME, "resume");
if (!result.ok || !result.home.endsWith("/home-a")) throw new Error(`restored binding was not authoritative: ${JSON.stringify(result)}`);
EOF

session_file="$TMP_ROOT/session-conflict.jsonl"
: > "$session_file"
chmod 600 "$session_file"
FM_HOME="$home_a" FM_SESSION_FILE="$session_file" FM_ENTRIES="$(printf '[{"type":"custom","customType":"firstmate-pi-home-binding","data":{"schema":"firstmate.pi-home-binding.v1","home":"%s"}},{"type":"custom","customType":"firstmate-pi-home-binding","data":{"schema":"firstmate.pi-home-binding.v1","home":"%s"}}]' "$home_a" "$home_b")" MODULE="$MODULE" \
  node --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";
const { resolvePiHome } = await import(pathToFileURL(process.env.MODULE).href);
const manager = { getSessionFile: () => process.env.FM_SESSION_FILE, getEntries: () => JSON.parse(process.env.FM_ENTRIES) };
const result = resolvePiHome({ sessionManager: manager }, process.env.FM_HOME, "resume");
if (result.ok || !result.reason.includes("conflicting")) throw new Error(`conflicting bindings were not refused: ${JSON.stringify(result)}`);
EOF

run_case "$home_a" resume '[]' refused

session_file="$TMP_ROOT/session-override.jsonl"
: > "$session_file"
chmod 600 "$session_file"
FM_HOME="$home_b" FM_STATE_OVERRIDE="$home_b/state" FM_SESSION_FILE="$session_file" FM_ENTRIES="$(printf '[{"type":"custom","customType":"firstmate-pi-home-binding","data":{"schema":"firstmate.pi-home-binding.v1","home":"%s"}}]' "$home_a")" MODULE="$MODULE" \
  node --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";
const { resolvePiHome } = await import(pathToFileURL(process.env.MODULE).href);
const manager = { getSessionFile: () => process.env.FM_SESSION_FILE, getEntries: () => JSON.parse(process.env.FM_ENTRIES) };
const result = resolvePiHome({ sessionManager: manager }, process.env.FM_HOME, "resume");
if (result.ok || !result.reason.includes("FM_STATE_OVERRIDE")) throw new Error(`cross-home state override was accepted: ${JSON.stringify(result)}`);
EOF

ln -s "$home_b" "$home_a/state-out"
ln -s "$home_b" "$home_a/missing-ancestor"
ln -s "$home_a/state-real" "$home_a/state-in"

for override in "$home_a/state-out" "$home_a/state-out/new" "$home_a/missing-ancestor/new"; do
  session_file="$TMP_ROOT/session-unsafe-override-${RANDOM}.jsonl"
  : > "$session_file"
  chmod 600 "$session_file"
  FM_HOME="$home_a" FM_STATE_OVERRIDE="$override" FM_SESSION_FILE="$session_file" FM_ENTRIES="$(printf '[{"type":"custom","customType":"firstmate-pi-home-binding","data":{"schema":"firstmate.pi-home-binding.v1","home":"%s"}}]' "$home_a")" MODULE="$MODULE" \
    node --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";
const { resolvePiHome } = await import(pathToFileURL(process.env.MODULE).href);
const manager = { getSessionFile: () => process.env.FM_SESSION_FILE, getEntries: () => JSON.parse(process.env.FM_ENTRIES) };
const result = resolvePiHome({ sessionManager: manager }, process.env.FM_HOME, "resume");
if (result.ok || !result.reason.includes("FM_STATE_OVERRIDE")) throw new Error(`symlinked cross-home override was accepted: ${JSON.stringify(result)}`);
EOF
done

session_file="$TMP_ROOT/session-inside-symlink.jsonl"
: > "$session_file"
chmod 600 "$session_file"
FM_HOME="$home_a" FM_STATE_OVERRIDE="$home_a/state-in/new" FM_SESSION_FILE="$session_file" FM_ENTRIES="$(printf '[{"type":"custom","customType":"firstmate-pi-home-binding","data":{"schema":"firstmate.pi-home-binding.v1","home":"%s"}}]' "$home_a")" MODULE="$MODULE" \
  node --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";
const { resolvePiHome } = await import(pathToFileURL(process.env.MODULE).href);
const manager = { getSessionFile: () => process.env.FM_SESSION_FILE, getEntries: () => JSON.parse(process.env.FM_ENTRIES) };
const result = resolvePiHome({ sessionManager: manager }, process.env.FM_HOME, "resume");
if (!result.ok || result.state !== `${process.env.FM_HOME}/state-real/new`) throw new Error(`legitimate in-home symlink was not canonicalized: ${JSON.stringify(result)}`);
EOF

session_file="$TMP_ROOT/session-ambiguous.jsonl"
: > "$session_file"
chmod 600 "$session_file"
FM_HOME="$home_a" FM_SESSION_FILE="$session_file" MODULE="$MODULE" \
  node --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";
const { resolvePiHome } = await import(pathToFileURL(process.env.MODULE).href);
const manager = {
  getHeader: () => ({ timestamp: "not-a-pi-timestamp" }),
  getSessionFile: () => process.env.FM_SESSION_FILE,
  getEntries: () => [],
  appendCustomEntry: () => { throw new Error("must not write an ambiguous session"); },
};
const result = resolvePiHome({ sessionManager: manager }, process.env.FM_HOME, "startup");
if (result.ok || !result.reason.includes("ambiguous")) throw new Error(`ambiguous session was upgraded: ${JSON.stringify(result)}`);
EOF

FM_HOME="$home_a" MODULE="$MODULE" node --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";
const { resolvePiHome } = await import(pathToFileURL(process.env.MODULE).href);
for (const [ctx, reason] of [
  [undefined, "startup"],
  [{ sessionManager: {} }, "resume"],
  [{ sessionManager: { getSessionFile: () => undefined } }, "reload"],
]) {
  const result = resolvePiHome(ctx, process.env.FM_HOME, reason);
  if (result.ok || !result.reason.includes("persistent Pi session identity")) {
    throw new Error(`missing session identity was accepted for ${reason}: ${JSON.stringify(result)}`);
  }
}
const fresh = resolvePiHome(undefined, process.env.FM_HOME, "new");
if (!fresh.ok || fresh.recorded) throw new Error(`fresh ephemeral mode was not explicit: ${JSON.stringify(fresh)}`);
EOF

printf '\nall Pi home-binding tests passed\n'
