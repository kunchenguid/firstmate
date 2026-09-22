#!/usr/bin/env bash
# Install or remove Firstmate's guarded Antigravity CLI (agy) crew turn-end hook.
#
# This command is the sole owner of the edit to ${HOME}/.gemini/config/hooks.json
# and of the hook script it installs beside agy's private turn-end registry.
# install adds or replaces exactly one top-level "firstmate-turn-end" key,
# preserves every other key, and writes the hook script and its token registry.
# remove is the exact withdrawal of that install: it excises only firstmate's
# own key and deletes firstmate's own hook files, leaving a token registry that
# still holds a live task's token in place and saying so. A symlinked store, a
# store this uid does not own, and a non-object root are each refused without a
# write, and a refusal raised after that point removes whatever the run created,
# so a refused install leaves the home exactly as it found it.
#
# Usage:
#   fm-agy-turnend-hook.sh install
#   fm-agy-turnend-hook.sh remove
#
# CAPTAIN CONSENT. That store is the captain's own per-user file, not firstmate's,
# so install is gated on a one-time consent recorded in this home's
# config/agy-turnend-hook: "allow" permits the write, "deny" refuses it, and an
# absent file means the captain has not been asked yet. A recorded "deny" also
# RETRACTS: install runs the remove action instead, taking a key an earlier
# "allow" wrote back out of the store, and then refuses anyway. Consent that
# cannot be withdrawn is not consent. Absent and "deny" both end as ordinary
# refusals on the existing no-write path, so the spawn degrades to its retained
# rendered-tail read instead of dying; only the absent case carries the
# instruction to ask, so a recorded answer of either kind is never asked again.
# Firstmate asks the captain and records the answer; this command never prompts,
# and remove needs no consent because it only undoes the write.
#
# ONE RECORDING PLACE PER MACHINE. The answer is about one machine's single
# hooks.json, so the primary firstmate home is the only home that records it and
# local secondmate homes inherit the copy. A non-primary local home that
# recorded its own would have it erased by the next primary-authoritative
# convergence and would ask again, which is the repeated ask this gate exists to
# end, so an unasked local secondmate's refusal names the PRIMARY home's file
# instead of its own. A remote secondmate is a different machine that never
# receives the item, so it remains its own recording place.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONSENT_FILE="$CONFIG/agy-turnend-hook"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"

case "${1:-}" in
install | remove) ACTION=$1 ;;
-h | --help)
  sed -n '2,63{s/^# \{0,1\}//;p;}' "$0"
  exit 0
  ;;
*)
  printf 'usage: %s install|remove\n' "${0##*/}" >&2
  exit 2
  ;;
esac

DENIED=0
CREATED_GEMINI_DIR=0
CREATED_CONFIG_DIR=0
CREATED_CLI_DIR=0
CREATED_REGISTRY=0
CREATED_HOOK_SCRIPT=0
HOOK_SCRIPT_TMP=

rollback_install() {
  [ -n "$HOOK_SCRIPT_TMP" ] && rm -f "$HOOK_SCRIPT_TMP"
  [ "$CREATED_HOOK_SCRIPT" -eq 1 ] && rm -f "$HOOK_SCRIPT"
  [ "$CREATED_REGISTRY" -eq 1 ] && rmdir "$REGISTRY" 2>/dev/null
  [ "$CREATED_CLI_DIR" -eq 1 ] && rmdir "$CLI_DIR" 2>/dev/null
  [ "$CREATED_CONFIG_DIR" -eq 1 ] && rmdir "$CONFIG_DIR" 2>/dev/null
  [ "$CREATED_GEMINI_DIR" -eq 1 ] && rmdir "$GEMINI_DIR" 2>/dev/null
  return 0
}

refuse() {
  rollback_install
  printf 'fm-agy-turnend-hook: refused: %s\n' "$1" >&2
  exit 1
}

# The withdrawal half of an install: firstmate's own hook script, then its own
# token registry. Never recursive and never forced, so a registry still holding
# a live task's token survives the rmdir and is reported rather than taken. The
# agy directory holding both is agy's own and is never a candidate.
# rollback_install stays separate because it answers a different question: undo
# only what THIS run created.
remove_hook_files() {
  rm -f "$HOOK_SCRIPT"
  if ! rmdir "$REGISTRY" 2>/dev/null && [ -d "$REGISTRY" ]; then
    printf "fm-agy-turnend-hook: '%s' still holds live per-task tokens, so it was left in place.\n" \
      "$REGISTRY" >&2
  fi
  return 0
}

# The one success exit. A retraction run reached it by completing the remove a
# recorded deny demands, but the install it was asked for is still refused, so
# the caller gets the same nonzero every other refusal gives it.
finish() {
  if [ "$DENIED" -eq 1 ]; then
    printf "fm-agy-turnend-hook: refused: the captain declined the global agy turn-end hook in '%s'; any key an earlier consent installed has been removed.\n" \
      "$CONSENT_FILE" >&2
    exit 1
  fi
  exit 0
}

[ -n "${HOME:-}" ] || refuse "HOME is unset."
command -v node >/dev/null 2>&1 || refuse "node is required to edit agy's hooks.json safely."

GEMINI_DIR="$HOME/.gemini"
CONFIG_DIR="$GEMINI_DIR/config"
CLI_DIR="$GEMINI_DIR/antigravity-cli"
STORE="$CONFIG_DIR/hooks.json"
REGISTRY="$CLI_DIR/fm-turn-end.d"
HOOK_SCRIPT="$CLI_DIR/fm-turn-end.sh"

shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# The one place this machine's answer belongs, rendered for the refusal text.
# A primary home names its own file. A local secondmate names the primary's,
# because it inherits that copy and anything it recorded itself would be erased
# by the next convergence. A remote secondmate is another machine and never
# receives the item, so it names its own file after all.
consent_recording_location() {
  if ! fm_root_is_secondmate_home "$FM_HOME"; then
    printf "'%s'" "$CONSENT_FILE"
    return 0
  fi
  if fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent"; then
    case "$FM_SECONDMATE_PARENT_ROUTE" in
    local)
      printf "'%s/config/agy-turnend-hook', this machine's primary firstmate home" \
        "$FM_SECONDMATE_PARENT_HOME"
      return 0
      ;;
    remote)
      printf "'%s'" "$CONSENT_FILE"
      return 0
      ;;
    esac
  fi
  printf '%s' "config/agy-turnend-hook in this machine's primary firstmate home"
}

# Captain consent, checked before the store is inspected at all so an unasked
# home never reads or touches the captain's own file. remove is not gated: it
# only takes back a write this command made.
if [ "$ACTION" = install ]; then
  if [ -e "$CONSENT_FILE" ] || [ -L "$CONSENT_FILE" ]; then
    [ -f "$CONSENT_FILE" ] && [ -r "$CONSENT_FILE" ] \
      || refuse "'$CONSENT_FILE' must be a readable regular file holding one of: allow, deny."
    CONSENT=$(tr -d '[:space:]' <"$CONSENT_FILE" || true)
    case "$CONSENT" in
    allow) ;;
    deny)
      # A withdrawn consent takes the write back rather than only declining the
      # next one. Nothing has been created yet at this point, so switching to
      # the remove action here needs no rollback; finish turns the completed
      # removal back into the refusal the caller asked about.
      DENIED=1
      ACTION=remove
      ;;
    *)
      refuse "'$CONSENT_FILE' holds '$CONSENT'; accepted values are: allow, deny."
      ;;
    esac
  else
    refuse "the captain has not been asked about the global agy turn-end hook. ASK THE CAPTAIN ONCE whether firstmate may add its own 'firstmate-turn-end' key to '$STORE', a file agy and the Antigravity IDE share with the captain's own sessions, and put its own small turn-end script '$HOOK_SCRIPT' and token folder '$REGISTRY' beside it, then record the answer by writing allow or deny to $(consent_recording_location)."
  fi
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
  remove_hook_files
  finish
fi
if [ -f "$STORE" ] && ! node - "$STORE" <<'NODE'; then
const fs = require("node:fs");
const raw = fs.readFileSync(process.argv[2], "utf8");
if (raw.trim() === "") process.exit(0);
let root;
try {
  root = JSON.parse(raw);
} catch {
  process.exit(1);
}
process.exit(root !== null && typeof root === "object" && !Array.isArray(root) ? 0 : 1);
NODE
  refuse "'$STORE' does not hold a JSON object; firstmate edits only a store it can read."
fi

if [ "$ACTION" = install ]; then
  [ -d "$GEMINI_DIR" ] || CREATED_GEMINI_DIR=1
  [ -d "$CONFIG_DIR" ] || CREATED_CONFIG_DIR=1
  [ -d "$CLI_DIR" ] || CREATED_CLI_DIR=1
  [ -d "$REGISTRY" ] || CREATED_REGISTRY=1
  [ -e "$HOOK_SCRIPT" ] || CREATED_HOOK_SCRIPT=1
  mkdir -p "$CONFIG_DIR" "$REGISTRY" || refuse "could not create agy's config and registry directories."
  chmod 700 "$REGISTRY" 2>/dev/null || true

  # The hook script is self-contained and absolute: the worktree that installed
  # it is torn down after the task lands, and each home resolves its own
  # firstmate root through the per-task token instead.
  HOOK_SCRIPT_TMP="$HOOK_SCRIPT.tmp.$$"
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

# The token name is validated above, but the values inside a token are data
# too. fm-spawn only ever writes absolute paths, so anything else is a token
# this hook did not write and must not act on.
case "$busy_event" in /*) ;; *) emit ;; esac
case "$state" in /*) ;; *) emit ;; esac
case "$turnend" in /*) ;; *) emit ;; esac

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
  } >"$HOOK_SCRIPT_TMP" || refuse "could not write the agy turn-end hook script."
  chmod 700 "$HOOK_SCRIPT_TMP" || refuse "could not set mode on the agy turn-end hook script."
  mv -f "$HOOK_SCRIPT_TMP" "$HOOK_SCRIPT" || refuse "could not install the agy turn-end hook script."
  HOOK_SCRIPT_TMP=
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
const shQuote = (value) => `'${value.replace(/'/g, "'\\''")}'`;
const desired = {
  PreInvocation: [{ type: "command", command: `${shQuote(hookScript)} pre-invocation`, timeout: 5 }],
  Stop: [{ type: "command", command: `${shQuote(hookScript)} stop`, timeout: 5 }],
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

if [ "$ACTION" = remove ]; then
  remove_hook_files
fi

finish
