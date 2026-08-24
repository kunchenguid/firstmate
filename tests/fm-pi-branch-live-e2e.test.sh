#!/usr/bin/env bash
# Opt-in live guard for the Pi supervision-branch extension against the REAL
# installed @earendil-works/pi-coding-agent SDK (no stubs): the branch session
# is created through the real DefaultResourceLoader/SessionManager/
# createAgentSession surface, the custom bash and fm_branch_report tool
# definitions must be accepted by the real tool registry, the session file and
# pointer must persist on disk, and - because the isolated agent dir carries no
# credentials and no models - the branch's first prompt must fail fast and
# prove the never-lose-a-wake fallback to main against the real SDK.
#
# No credentials are read and no provider call leaves the machine: the guard
# points PI_CODING_AGENT_DIR at an empty directory, so model resolution stays
# empty by construction. Run after every Pi upgrade and before trusting
# refreshed per-harness evidence (docs/verification/runtime-backends.md).
set -u

if [ "${FM_PI_BRANCH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_BRANCH_LIVE_E2E=1 to run the real-SDK Pi branch regression"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export NODE_NO_WARNINGS=1

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  fail "Pi package absent: the live branch guard needs @earendil-works/pi-coding-agent installed (FM_PI_PACKAGE_DIR to override)"
fi
PI_VERSION=$(jq -r '.version' "$PI_PACKAGE_DIR/package.json" 2>/dev/null || printf 'unknown')

TMP_ROOT=$(fm_test_tmproot fm-pi-branch-live)
repo="$TMP_ROOT/repo"
home="$TMP_ROOT/home"
agentdir="$TMP_ROOT/agent-dir"
mkdir -p "$repo/.pi/extensions/lib" "$repo/node_modules/@earendil-works" \
  "$home/state" "$home/config" "$agentdir"
cp "$ROOT/.pi/extensions/fm-branch-supervision.ts" "$repo/.pi/extensions/fm-branch-supervision.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
mkdir -p "$repo/bin"
cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
chmod +x "$repo/bin/fm-operational-input.sh"
ln -s "$PI_PACKAGE_DIR" "$repo/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$repo/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$repo/node_modules/typebox"

# Stock macOS Bash 3.2 cannot reliably parse JavaScript template literals in a
# heredoc nested inside command substitution, so capture through a file.
PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
  PI_CODING_AGENT_DIR="$agentdir" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const home = resolve(process.env.FM_HOME);
// The live guard exercises the branch only after the captain's explicit
// project-local autonomy grant.
const approvedProject = `${home}/projects/live-probe`;
writeFileSync(`${home}/config/pi-supervision-branch`, `project=${approvedProject}\n`);
const busHandlers = new Map();
const bus = {
  on(channel, handler) {
    busHandlers.set(channel, [...(busHandlers.get(channel) ?? []), handler]);
    return () => {};
  },
  emit(channel, data) {
    for (const handler of busHandlers.get(channel) ?? []) handler(data);
  },
};
const mainUserMessages = [];
const piHandlers = new Map();
const pi = {
  events: bus,
  on(event, handler) {
    piHandlers.set(event, [...(piHandlers.get(event) ?? []), handler]);
  },
  registerTool() {},
  registerCommand() {},
  registerMessageRenderer() {},
  sendMessage() {},
  sendUserMessage(content, options) {
    mainUserMessages.push({ content, options: options ?? {} });
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const sessionCtx = {
  sessionManager: { getSessionFile: () => `${home}/main.jsonl`, getEntries: () => [] },
};
for (const handler of piHandlers.get("session_start") ?? []) await handler({}, sessionCtx);
if (existsSync(`${home}/state/.pi-branch-extension-loaded`)) {
  throw new Error("branch activated before the primary session acquired its lock");
}
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);

const offer = {
  message: "signal: live-sdk probe",
  projects: [approvedProject],
  accepted: false,
  accept() {
    offer.accepted = true;
  },
};
bus.emit("fm-branch-supervision:dispatch", offer);
if (!offer.accepted) throw new Error("branch did not accept the wake offer against the real SDK");
for (let i = 0; i < 600 && mainUserMessages.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 50));
}
// With an empty agent dir there is no model, so the branch's first prompt
// must fail fast and return the wake to main - proving both that the real
// createAgentSession accepted our loader, tools, and custom definitions
// (construction succeeds) and that the fallback keeps the wake.
if (mainUserMessages.length !== 1) throw new Error("wake was lost: no fallback reached main");
const fallback = mainUserMessages[0].content;
if (!fallback.includes("FIRSTMATE WATCHER WAKE: signal: live-sdk probe")) {
  throw new Error(`fallback lost the wake reason: ${fallback}`);
}
if (!fallback.includes("Supervision branch unavailable")) {
  throw new Error(`fallback did not name the branch failure: ${fallback}`);
}
if (!existsSync(`${home}/state/.branch-session`)) {
  throw new Error("real SessionManager did not persist the branch session pointer");
}
// The real SessionManager writes the session file lazily (on its first
// persisted entry), so assert the pointer's placement rather than the file:
// the recorded path must live under this home branch-session store.
const pointer = readFileSync(`${home}/state/.branch-session`, "utf8").trim();
if (!pointer.startsWith(`${home}/state/branch-session/`) || !pointer.endsWith(".jsonl")) {
  throw new Error(`recorded branch session pointer is misplaced: ${pointer}`);
}
if (!existsSync(`${home}/state/branch-session`)) {
  throw new Error("branch session store directory was not created");
}
console.log("LIVE_OK");
process.exit(0);
EOF
status=$?
out=$(cat "$TMP_ROOT/node-output")
if [ "$status" -ne 0 ] || [ "$out" != "LIVE_OK" ]; then
  fail "real-SDK Pi branch guard failed against pi-coding-agent $PI_VERSION: $out"
fi
pass "real Pi SDK $PI_VERSION accepts the branch session construction and preserves an unpromptable wake"
