#!/usr/bin/env bash
# Live Orca agent-state + native-busy guard (live-harness-optin family).
#
# The Orca backend's recovery-grade agent-state classifier and its native busy
# signal both read Orca's own structured `worktree ps` agent model. A stub can
# only confirm the shape already written into the stub, so this guard launches
# real Claude Code in an isolated Orca worktree and drives it through every
# state transition fm_backend_orca_agent_state / fm_backend_orca_busy_state
# depend on:
#   - a working turn reads alive / busy,
#   - a settled turn reads alive / idle,
#   - an agent exited to a shell reads dead (the agent-vs-shell distinction that
#     lets fm-control prove an `exit` of an idle agent),
#   - a stale handle reads missing.
# It fails naming the Orca version rather than degrading quietly.
#
# NOTE on interrupts: this guard deliberately drives `exit` through an IDLE
# agent (it waits for the turn to settle, never a mid-turn interrupt). Orca's
# structured agent model is turn-hook driven and does NOT observe a raw-ESC
# interrupt (it leaves agents[].state at "working" until the next completed
# turn), and a lone ESC byte is not a reliable cancel, so mid-turn interrupt of
# an Escape harness is not a verified Orca capability. See
# docs/verification/runtime-backends.md "Orca".
#
# Run explicitly with FM_ORCA_AGENT_STATE_LIVE=1 after an Orca or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Orca" entry.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_ORCA_AGENT_STATE_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_ORCA_AGENT_STATE_LIVE=1 to run the live Orca agent-state guard"
  exit 0
fi

command -v orca >/dev/null 2>&1 || fail "FM_ORCA_AGENT_STATE_LIVE=1 but the orca CLI is not installed"
command -v claude >/dev/null 2>&1 || fail "FM_ORCA_AGENT_STATE_LIVE=1 but Claude Code is not installed"
command -v node >/dev/null 2>&1 || fail "FM_ORCA_AGENT_STATE_LIVE=1 but node is not installed"

# shellcheck source=bin/backends/orca.sh
. "$ROOT/bin/backends/orca.sh"

APPVER=$(orca status --json 2>/dev/null | node -e 'try{const d=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write(String((d.result&&d.result.runtime&&d.result.runtime.appVersion)||"unknown"));}catch(e){process.stdout.write("unknown");}')
fm_backend_orca_runtime_check >/dev/null 2>&1 || fail "Orca runtime is not ready (appVersion=$APPVER); start Orca and retry"

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-orca-live.XXXXXX")
REPO_DIR="$TMP_ROOT/repo"
REPO_ID=""
WT_ID=""
TERM=""

cleanup() {
  local rc=$?
  trap - EXIT
  [ -z "$TERM" ] || orca terminal close --terminal "$TERM" --json >/dev/null 2>&1 || true
  [ -z "$WT_ID" ] || orca worktree rm --worktree "id:$WT_ID" --force --json >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

json_field() {  # <field-path> ; reads stdin JSON, prints the field or empty
  node -e '
const fs = require("fs");
let d; try { d = JSON.parse(fs.readFileSync(0, "utf8")); } catch (e) { process.exit(0); }
let cur = d;
for (const k of process.argv[1].split(".")) { if (cur == null) break; cur = cur[k]; }
if (cur != null) process.stdout.write(String(cur));
' "$1"
}

# poll_state <fn> <want> <timeout-secs>: poll adapter <fn> "$TERM" until it
# prints <want>, up to <timeout-secs>. Prints the final observed value.
poll_state() {  # <fn> <want> <timeout-secs>
  local fn=$1 want=$2 timeout=$3 elapsed=0 got
  while :; do
    got=$("$fn" "$TERM")
    [ "$got" != "$want" ] || { printf '%s' "$got"; return 0; }
    awk -v e="$elapsed" -v t="$timeout" 'BEGIN{exit !(e < t)}' || break
    sleep 1
    elapsed=$((elapsed + 1))
  done
  printf '%s' "$got"
  return 1
}

# --- set up a scratch repo, worktree, and claude terminal -------------------
mkdir -p "$REPO_DIR"
( cd "$REPO_DIR" \
  && git init -q \
  && git config user.email orca-live@example.com \
  && git config user.name orca-live \
  && printf '# orca live guard\n' > README.md \
  && git add -A \
  && git commit -q -m init ) || fail "could not create the scratch git repo"

REPO_ID=$(orca repo add --path "$REPO_DIR" --json 2>/dev/null | json_field result.repo.id)
[ -n "$REPO_ID" ] || REPO_ID=$(orca repo show --repo "path:$REPO_DIR" --json 2>/dev/null | json_field result.repo.id)
[ -n "$REPO_ID" ] || fail "could not register the scratch repo with Orca (appVersion=$APPVER)"

WT_ID=$(orca worktree create --repo "id:$REPO_ID" --name "fm-orca-live" --no-parent --setup skip --json 2>/dev/null | json_field result.worktree.id)
[ -n "$WT_ID" ] || fail "could not create an Orca worktree (appVersion=$APPVER)"

TERM=$(orca terminal create --worktree "id:$WT_ID" --title "fm-orca-live" --command "claude" --json 2>/dev/null | json_field result.terminal.handle)
[ -n "$TERM" ] || fail "could not create an Orca terminal running claude (appVersion=$APPVER)"

# Accept the first-run workspace-trust modal, then wait for claude to reach its
# idle prompt.
sleep 3
orca terminal send --terminal "$TERM" --text "" --enter --json >/dev/null 2>&1 || true
idle=$(poll_state fm_backend_orca_busy_state idle 30) \
  || fail "claude never reached an idle prompt on Orca (last busy_state=$idle, appVersion=$APPVER)"

state=$(fm_backend_orca_agent_state "$TERM")
[ "$state" = alive ] || fail "an idle claude agent must read alive, got '$state' (appVersion=$APPVER)"
pass "orca live: an idle claude agent reads alive / idle (appVersion=$APPVER)"

# --- a working turn reads alive / busy, then settles to idle ----------------
orca terminal send --terminal "$TERM" --text "Count from 1 to 20, one number per line." --enter --json >/dev/null 2>&1 \
  || fail "could not send a working prompt to claude on Orca"
busy=$(poll_state fm_backend_orca_busy_state busy 20) \
  || fail "a working claude turn must read busy, got '$busy' (appVersion=$APPVER)"
state=$(fm_backend_orca_agent_state "$TERM")
[ "$state" = alive ] || fail "a working claude agent must read alive, got '$state' (appVersion=$APPVER)"
pass "orca live: a working claude turn reads alive / busy (appVersion=$APPVER)"

# The turn settles back to idle on its own (no interrupt).
settled=$(poll_state fm_backend_orca_busy_state idle 40) \
  || fail "a completed claude turn must settle back to idle, got '$settled' (appVersion=$APPVER)"
pass "orca live: a completed claude turn settles back to alive / idle (appVersion=$APPVER)"

# --- exit an idle agent to a shell reads dead -------------------------------
orca terminal send --terminal "$TERM" --text "/exit" --enter --json >/dev/null 2>&1 || true
dead=$(poll_state fm_backend_orca_agent_state dead 30) \
  || fail "an agent exited to a shell must read dead, got '$dead' (appVersion=$APPVER)"
pass "orca live: an idle claude agent that ran /exit reads dead (appVersion=$APPVER)"

# --- a stale handle reads missing -------------------------------------------
stale=$(fm_backend_orca_agent_state "term_00000000-0000-0000-0000-000000000000")
[ "$stale" = missing ] || fail "a stale terminal handle must read missing, got '$stale' (appVersion=$APPVER)"
pass "orca live: a stale terminal handle reads missing (appVersion=$APPVER)"

pass "orca live: agent-state and native busy signal verified against real Orca (appVersion=$APPVER)"
