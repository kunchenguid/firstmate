#!/usr/bin/env bash
# tests/fm-backend-thurbox-smoke.test.sh - real thurbox smoke test for the
# thurbox session-provider adapter (bin/backends/thurbox.sh). Mirrors
# tests/fm-backend-cmux-smoke.test.sh's structure: every other thurbox case
# fakes the CLI, this one talks to the REAL binary.
#
# It exists for the two contracts a fake can only ever approximate:
#
#   1. `session send`'s ARGUMENT PARSER. The adapter's delivery promise is that
#      a leading '-' survives, and that promise is about the paste, not about
#      clap. The portable suite models clap's refusal, but a model can drift
#      from the real parser - which is exactly how this defect survived a green
#      suite in the first place.
#   2. The absence proof. `session list --deleted`'s `force_deleted` mark is
#      what separates "the window was killed" from "the row went away and the
#      agent is still running", and only the real binary produces it.
#
# SAFETY. This runs on a machine with the operator's own live sessions on it,
# including the one supervising the run. It creates ONLY `fmsmoke-`-prefixed
# sessions, records every id it creates, and touches nothing it did not create.
# It never enumerates-and-deletes, never matches by name, and never deletes
# without an id from its own list. Every created session is cleaned on exit,
# including on failure - and because thurbox refuses to force-delete a row it
# can no longer resolve, cleanup restores a soft-deleted session first so its
# pane cannot be orphaned.
#
# Skips cleanly when thurbox-cli or jq is absent, so CI is unaffected.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CREATED=""

cleanup_all() {
  local id
  for id in $CREATED; do
    # A soft-deleted row cannot be force-deleted; reclaim it first so its pane
    # is never left running.
    thurbox-cli session restore "$id" >/dev/null 2>&1 || true
    thurbox-cli session delete "$id" --force >/dev/null 2>&1 || true
  done
  CREATED=""
}
trap cleanup_all EXIT INT TERM

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v thurbox-cli >/dev/null 2>&1 || { echo "skip: thurbox-cli not installed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the thurbox adapter)"; exit 0; }

FM_ROOT_OVERRIDE="$ROOT"; export FM_ROOT_OVERRIDE
# Read by the adapter and the libraries sourced below, not by this file.
# shellcheck disable=SC2034
FM_HOME="$ROOT"
# shellcheck disable=SC2034
FM_ROOT="$ROOT"
# shellcheck disable=SC2034
FM_BACKEND_LIB_DIR="$ROOT/bin"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-transition-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/backends/tmux.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/backends/thurbox.sh"

fm_backend_thurbox_version_check >/dev/null 2>&1 || {
  echo "skip: installed thurbox-cli is below the adapter's supported floor"
  exit 0
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-thurbox-smoke.XXXXXX") || exit 1
trap 'cleanup_all; rm -rf "$WORK"' EXIT
git init -q "$WORK/repo" 2>/dev/null || { echo "skip: git unavailable"; exit 0; }
git -C "$WORK/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init 2>/dev/null

# make_session <suffix>: creates a session and sets SESSION_ID.
#
# It must NOT echo the id for a caller to capture, because a caller capturing it
# would run this in a command substitution - and the CREATED list it appends to
# would then be built in that subshell and lost. That is precisely how the
# cleanup list silently stayed empty and a probe session survived a run. The
# safety of this file depends on CREATED being right, so the id is passed back
# through a global instead.
make_session() {  # <suffix> -> sets SESSION_ID
  local suffix=$1 raw id
  SESSION_ID=""
  raw=$(thurbox-cli session create --name "fmsmoke-$suffix" --repo-path "$WORK/repo" \
    --command /bin/bash --arg -i --on-existing replace --json 2>/dev/null) || return 1
  id=$(printf '%s' "$raw" | jq -r '.id // empty' 2>/dev/null)
  [ -n "$id" ] || return 1
  CREATED="$CREATED $id"
  SESSION_ID=$id
}

# --- 1. the argument parser --------------------------------------------------

make_session send || { echo "skip: could not create a thurbox session"; exit 0; }
id=$SESSION_ID
sleep 2
target="thurbox:$id"

fm_backend_thurbox_send_literal "$target" '-x --weird leading dash' \
  || fail "send refused text beginning with a dash; the real parser claimed it as a flag"
sleep 2
fm_backend_thurbox_capture "$target" 20 | grep -aq -- '-x --weird leading dash' \
  || fail "text beginning with a dash was accepted but never reached the pane"
pass "real binary: steer text the argument parser would claim as a flag still reaches the pane"

fm_backend_thurbox_send_literal "$target" 'ordinary smoke text' \
  || fail "send refused ordinary text"
sleep 2
fm_backend_thurbox_capture "$target" 20 | grep -aq 'ordinary smoke text' \
  || fail "ordinary text never reached the pane"
pass "real binary: ordinary steer text rides the same delivery path"

# --- 2. absence has to be proven --------------------------------------------

make_session gone || fail "could not create the absence-proof session"
id=$SESSION_ID
sleep 2
target="thurbox:$id"

fm_backend_thurbox_endpoint_confirmed_gone "$target" \
  && fail "a live session must never be reported as provably gone"
pass "real binary: a live endpoint is not reported gone"

# A SOFT delete: the row goes, the pane keeps running, and thurbox will then
# refuse to force-delete the row at all. This is the state an outside delete
# leaves behind.
thurbox-cli session delete "$id" >/dev/null 2>&1 || fail "soft delete failed"
sleep 3

fm_backend_thurbox_endpoint_confirmed_gone "$target" \
  && fail "a soft-deleted session whose agent may still run was reported provably gone"
pass "real binary: a soft-deleted endpoint is not proven gone"

state=$(fm_backend_thurbox_agent_state "$target")
[ "$state" != missing ] \
  || fail "a soft-deleted session read 'missing', which licenses a relaunch beside a live agent"
pass "real binary: a soft-deleted session does not license recovery (read '$state')"

# Teardown on a soft-deleted row: a forced delete cannot resolve it, so the
# adapter reaps instead. Only once the pane is actually released is the endpoint
# provably gone. This is the whole point of reaping deliberately rather than
# waiting for an interface or the automation heartbeat that a headless firstmate
# has no guarantee of.
fm_backend_thurbox_kill "$target" || fail "teardown could not release a soft-deleted session's pane"
sleep 3

fm_backend_thurbox_endpoint_confirmed_gone "$target" \
  || fail "a reaped endpoint must be provably gone"
[ "$(fm_backend_thurbox_agent_state "$target")" = missing ] \
  || fail "a reaped endpoint must read missing"
pass "real binary: teardown reaps a soft-deleted session and the endpoint becomes provably gone"

# And the ordinary path: a live session torn down with --force.
make_session forced || fail "could not create the forced-teardown session"
id=$SESSION_ID
sleep 2
target="thurbox:$id"
fm_backend_thurbox_kill "$target" || fail "forced teardown failed"
sleep 3
fm_backend_thurbox_endpoint_confirmed_gone "$target" \
  || fail "a force-deleted endpoint must be provably gone"
pass "real binary: an ordinary forced teardown is proven gone"

echo "all fm-backend-thurbox-smoke tests passed"
