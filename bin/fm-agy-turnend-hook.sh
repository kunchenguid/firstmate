#!/usr/bin/env bash
# Install or remove Firstmate's guarded Antigravity CLI (agy) crew turn-end hook.
#
# This command is the sole owner of the edit to ${HOME}/.gemini/config/hooks.json
# and of the hook script it installs beside agy's private turn-end registry.
# install adds or replaces exactly one top-level "firstmate-turn-end" key and
# preserves every other key; remove deletes only that key. A symlinked store, a
# store this uid does not own, and a non-object root are each refused without a
# write.
#
# Usage:
#   fm-agy-turnend-hook.sh install
#   fm-agy-turnend-hook.sh remove
#
# WHY A GLOBAL FILE. agy reads hooks only from its customization roots: the
# global ${HOME}/.gemini/config/ and a workspace's own .agents/ directory. It
# exposes no settings-path environment variable or flag, so there is no gemini
# GEMINI_CLI_SYSTEM_SETTINGS_PATH equivalent to point at a per-task copy, and a
# workspace copy would mean writing into the project under test. The global file
# is therefore the only firstmate-owned location, and the hook installed here is
# a no-op for every agy session that is not a firstmate crewmate - including the
# captain's own CLI sessions and the Antigravity IDE, which share this file.
#
# HOW A FIRING IS ATTRIBUTED. bin/fm-spawn.sh mints a random token per task in
# ${HOME}/.gemini/antigravity-cli/fm-turn-end.d/ carrying that task's turn-end
# marker, busy-event writer, state dir, id, and busy generation, and exports the
# token name to the launched agy process as FM_AGY_TURNEND_TOKEN. Hook commands
# are children of agy and inherit that environment (verified live). The hook
# acts only when the variable names a well-formed token that exists in the
# private registry, so a session firstmate did not launch can never reach a task
# record, and a forged value cannot escape the registry directory.
#
# BOUNDED BY CONSTRUCTION. agy runs hooks synchronously and blocks its own agent
# loop while they run, with a 30s vendor default timeout. Both handlers are
# registered with an explicit 5s timeout, the hook shells out only to the
# busy-state writer, and every path exits 0 after printing the JSON object agy's
# hook contract requires on stdout.
set -u
unset CDPATH

case "${1:-}" in
install | remove) ACTION=$1 ;;
-h | --help)
  sed -n '2,36{s/^# \{0,1\}//;p;}' "$0"
  exit 0
  ;;
*)
  printf 'usage: %s install|remove\n' "${0##*/}" >&2
  exit 2
  ;;
esac

refuse() {
  printf 'fm-agy-turnend-hook: refused: %s\n' "$1" >&2
  exit 1
}

[ -n "${HOME:-}" ] || refuse "HOME is unset."
command -v node >/dev/null 2>&1 || refuse "node is required to edit agy's hooks.json safely."

CONFIG_DIR="$HOME/.gemini/config"
CLI_DIR="$HOME/.gemini/antigravity-cli"
STORE="$CONFIG_DIR/hooks.json"
REGISTRY="$CLI_DIR/fm-turn-end.d"
HOOK_SCRIPT="$CLI_DIR/fm-turn-end.sh"

shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

if [ "$ACTION" = install ]; then
  mkdir -p "$CONFIG_DIR" "$REGISTRY" || refuse "could not create agy's config and registry directories."
  chmod 700 "$REGISTRY" 2>/dev/null || true

  # The hook script is self-contained and absolute: the worktree that installed
  # it is torn down after the task lands, and each home resolves its own
  # firstmate root through the per-task token instead.
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' '# Firstmate agy turn-end hook. Installed and owned by bin/fm-agy-turnend-hook.sh.'
    printf '%s\n' '# Inert unless FM_AGY_TURNEND_TOKEN names a live token in the private registry.'
    printf '%s\n' '# Always exits 0 after printing the JSON object agy requires on stdout.'
    printf '%s\n' 'set -u'
    printf 'auth_dir=%s\n' "$(shell_quote "$REGISTRY")"
    cat <<'HOOKBODY'

event=${1:-}
case "$event" in
stop) out='{"decision":"stop"}' ;;
*) out='{}' ;;
esac

# Drain agy's payload so its write can never see a closed pipe, then answer.
emit() {
  cat >/dev/null 2>&1 || true
  printf '%s' "$out"
  exit 0
}

token=${FM_AGY_TURNEND_TOKEN:-}
[ -n "$token" ] || emit
case "$token" in
fm.*) rest=${token#fm.} ;;
*) emit ;;
esac
[ "${#rest}" -eq 12 ] || emit
case "$rest" in *[!A-Za-z0-9]*) emit ;; esac

auth="$auth_dir/$token"
[ -f "$auth" ] || emit

turnend=
busy_event=
state=
id=
gen=
while IFS='=' read -r key value; do
  case "$key" in
  turnend) turnend=$value ;;
  busy_event) busy_event=$value ;;
  state) state=$value ;;
  id) id=$value ;;
  gen) gen=$value ;;
  esac
done <"$auth"

case "$event" in
stop)
  busy_state=idle
  # The watcher's turn-end notification, the same marker grok and kimi touch.
  [ -n "$turnend" ] && touch "$turnend" 2>/dev/null
  ;;
pre-invocation) busy_state=busy ;;
*) emit ;;
esac

if [ -n "$busy_event" ] && [ -n "$state" ] && [ -n "$id" ] && [ -n "$gen" ] && [ -x "$busy_event" ]; then
  "$busy_event" apply "$state" "$id" "$busy_state" \
    --gen "$gen" --source agy-hook --event "$event" >/dev/null 2>&1 || true
fi

emit
HOOKBODY
  } >"$HOOK_SCRIPT.tmp.$$" || refuse "could not write the agy turn-end hook script."
  chmod 700 "$HOOK_SCRIPT.tmp.$$" || refuse "could not set mode on the agy turn-end hook script."
  mv -f "$HOOK_SCRIPT.tmp.$$" "$HOOK_SCRIPT" || refuse "could not install the agy turn-end hook script."
fi

if [ -L "$STORE" ]; then
  refuse "'$STORE' is a symlink; firstmate edits only a regular file it owns."
fi
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file."
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user."
  [ -w "$STORE" ] || refuse "'$STORE' is not writable."
fi
if [ "$ACTION" = remove ] && [ ! -e "$STORE" ]; then
  exit 0
fi

# Read-modify-write with a fingerprint check before the rename and a readback
# after it, the bin/fm-agy-trust.sh shape: agy and the captain both write this
# file, so a store that moved under us is retried once and then refused rather
# than clobbered.
if ! node - "$STORE" "$ACTION" "$HOOK_SCRIPT" <<'NODE'; then
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, action, hookScript] = process.argv.slice(2);
const KEY = "firstmate-turn-end";
const desired = {
  PreInvocation: [{ type: "command", command: `${hookScript} pre-invocation`, timeout: 5 }],
  Stop: [{ type: "command", command: `${hookScript} stop`, timeout: 5 }],
};
const readStore = () => {
  try {
    return fs.readFileSync(store);
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
};
const fingerprint = (buf) =>
  buf === null ? "absent" : crypto.createHash("sha256").update(buf).digest("hex");
const settled = (root) =>
  action === "remove"
    ? !Object.prototype.hasOwnProperty.call(root, KEY)
    : JSON.stringify(root[KEY]) === JSON.stringify(desired);
const attempt = () => {
  const original = readStore();
  const before = fingerprint(original);
  let root = {};
  if (original !== null) {
    const raw = original.toString("utf8");
    if (raw.trim() !== "") {
      root = JSON.parse(raw);
      if (root === null || typeof root !== "object" || Array.isArray(root)) {
        throw new Error(`${store} is not a JSON object`);
      }
    }
  }
  if (settled(root)) return "settled";
  if (action === "remove") delete root[KEY];
  else root[KEY] = desired;
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(store), `.hooks.json.fm-turnend.${unique}`);
  fs.writeFileSync(tmp, `${JSON.stringify(root, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(readStore()) !== before) return "moved";
    fs.renameSync(tmp, store);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  const after = fs.readFileSync(store, "utf8");
  return settled(after.trim() === "" ? {} : JSON.parse(after)) ? "settled" : "dropped";
};
try {
  for (let i = 0; i < 3; i += 1) {
    const result = attempt();
    if (result === "settled") process.exit(0);
    if (result === "moved" && i >= 1) {
      console.error(`error: ${store} was modified while the firstmate hook was being recorded; refusing to overwrite it`);
      process.exit(1);
    }
  }
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
console.error(`error: ${store} did not retain the firstmate turn-end hook after 3 attempts`);
process.exit(1);
NODE
  refuse "agy's hooks.json could not be updated safely."
fi

exit 0
