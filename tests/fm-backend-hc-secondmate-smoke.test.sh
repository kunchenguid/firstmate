#!/usr/bin/env bash
# tests/fm-backend-hc-secondmate-smoke.test.sh - real herdr-core end-to-end
# proof that a second mate runs on the hc backend (docs/hc-backend.md): the
# REAL bin/fm-spawn.sh, fm-send.sh, fm-control.sh, the secondmate liveness
# library, and fm-teardown.sh against a real core, because the guarantees
# under test exist only where those scripts meet the adapter.
#
# Covers, for one seeded secondmate home:
#   - the primary's --secondmate spawn lands on hc, records hc_session and
#     hc_terminal, keeps the PRIMARY's identity labels (its record owns the
#     endpoint), and labels the terminal into the secondmate home's own
#     Herdr.app space - the space that home's own workers use;
#   - liveness reads the live mate alive, fm-send writes the durable inbox
#     record, and fm-control interrupt reaches the agent;
#   - a dead agent reads relaunchable, and the liveness relaunch closes the
#     husk and respawns the mate on hc in a fresh, correctly labeled terminal;
#   - forced retirement closes a child endpoint labeled for the secondmate's
#     own home, then the secondmate's own terminal, and removes the home.
#
# No real harness runs: the first agent is fm_agent_standin's spinner under a
# harness name, and the respawned harness is an inert opencode script first on
# this script's PATH, which the spawn resolves to the absolute path it launches.
# Everything lands in a bin/fm-hc-lab.sh session (unique fm-hclab-* HC_SESSION,
# scratch XDG roots, a pinned FM_HC_SOCKET, and a fleet-state tripwire), and
# tests/hc-test-safety.sh owns the only sanctioned teardown. Skips cleanly when
# no resolved Core binary, jq, or stand-in is available; a provisioning or
# teardown failure is a FAIL, not a skip.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }

HC_BIN=${FM_HC_BIN:-}
[ -n "$HC_BIN" ] || HC_BIN=$(command -v herdr-core 2>/dev/null || true)
[ -n "$HC_BIN" ] || HC_BIN=$(command -v hc 2>/dev/null || true)
if [ -z "$HC_BIN" ] || [ ! -x "$HC_BIN" ]; then
  echo "skip: hc not found (install via bin/fm-install-hc.sh or set FM_HC_BIN)"
  exit 0
fi
command -v jq >/dev/null 2>&1 || {
  echo "skip: jq not found (required by the hc adapter)"
  exit 0
}
export FM_HC_BIN=$HC_BIN

# shellcheck source=tests/hc-test-safety.sh
. "$ROOT/tests/hc-test-safety.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-hc-secondmate)
STANDIN=$(fm_agent_standin "$TMP_ROOT/standin") || {
  echo "skip: no long-running stand-in binary survives a rename (multicall coreutils, no C compiler)"
  exit 0
}
AGENT_BIN=$TMP_ROOT/agentbin
mkdir -p "$AGENT_BIN"
ln -s "$STANDIN" "$AGENT_BIN/codex"

# A per-run id keeps fm-spawn's /tmp/fm-<id> task directories ours alone.
ID=hcsm$$

# The respawned harness: records only the launch made as the secondmate's home.
FAKEBIN=$TMP_ROOT/fakebin
mkdir -p "$FAKEBIN"
export PATH="$FAKEBIN:$PATH"

HC_TEST_SES=$("$ROOT/bin/fm-hc-lab.sh" name secondmate)
cleanup_lab() {
  local rc=$? d
  trap - EXIT
  hc_test_safe_teardown "$ROOT" "$HC_TEST_SES" || rc=1
  for d in /tmp/fm-"$ID" /tmp/fm-"$ID"+*; do
    [ -d "$d" ] || continue
    chmod -R u+rwx "$d" 2>/dev/null
    rm -rf "$d"
  done
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_lab EXIT

"$ROOT/bin/fm-hc-lab.sh" provision "$HC_TEST_SES" \
  || fail "hc lab could not provision with $HC_BIN"
HC_TEST_SOCK=$("$ROOT/bin/fm-hc-lab.sh" socket "$HC_TEST_SES")
[ -n "$HC_TEST_SOCK" ] || fail "hc lab provisioned without a socket"
hc_test_refuse_if_unsafe "$HC_TEST_SES" \
  || fail "provisioned session '$HC_TEST_SES' does not satisfy the lab safety contract"

HC_LAB_DIR=$(hc_test_lab_dir)/$HC_TEST_SES
export HC_SESSION=$HC_TEST_SES FM_HC_SOCKET=$HC_TEST_SOCK
export XDG_STATE_HOME="$HC_LAB_DIR/env/xdg-state" \
  XDG_CONFIG_HOME="$HC_LAB_DIR/env/xdg-config" \
  XDG_DATA_HOME="$HC_LAB_DIR/env/xdg-data"
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET FM_HC_SPACE \
  FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

# --- a primary home and one seeded secondmate home ---------------------------
PRIMARY=$TMP_ROOT/primary
SM=$TMP_ROOT/sm-home
mkdir -p "$PRIMARY/state" "$PRIMARY/data" "$PRIMARY/config"
printf 'opencode\n' >"$PRIMARY/config/secondmate-harness"
FM_HOME=$PRIMARY FM_SECONDMATE_CHARTER='hc lab second mate: nothing to do' \
  "$ROOT/bin/fm-brief.sh" "$ID" --secondmate --no-projects >/dev/null \
  || fail "could not scaffold the secondmate charter"
FM_HOME=$PRIMARY "$ROOT/bin/fm-home-seed.sh" "$ID" "$SM" --no-projects >/dev/null \
  || fail "could not seed the secondmate home"
SM=$(cd "$SM" && pwd -P)
# shellcheck disable=SC2016 # the variables intentionally expand in the generated stub, not here
printf '#!/bin/sh\n[ "${1:-}" = --version ] && { echo 1.0.0; exit 0; }\n[ "${FM_HOME:-}" = %s ] && : > %s\n' \
  "'$SM'" "'$TMP_ROOT/opencode-launched'" >"$FAKEBIN/opencode"
chmod +x "$FAKEBIN/opencode"

# Every script call runs as the primary, with no ambient surface marker.
as_primary() {
  env -u TMUX -u FM_BACKEND -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u REX_BLOCK \
    FM_HOME="$PRIMARY" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 "$@"
}

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source hc || fail "could not source the hc adapter"
PRIMARY_TAG=$(FM_HOME=$PRIMARY FM_ROOT=$ROOT fm_backend_hometag)
SM_TAG=$(FM_HOME=$SM FM_ROOT=$SM fm_backend_hometag)
[ "$PRIMARY_TAG" != "$SM_TAG" ] || fail "the two homes must not share a home tag"

meta_value() { sed -n "s/^$1=//p" "$PRIMARY/state/$ID.meta" | tail -1; }
label() { # <address> <key>
  "$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" get "$1" --json | jq -r --arg k "$2" '.labels[$k] // empty'
}
wait_state() { # <target> <state>
  local i
  for i in $(seq 1 100); do
    [ "$(FM_HOME=$PRIMARY FM_ROOT=$ROOT fm_backend_agent_state hc "$1")" = "$2" ] && return 0
    sleep 0.1
  done
  return 1
}
# liveness <probe|relaunch>: the secondmate liveness library, as the watcher runs it.
liveness() {
  # shellcheck disable=SC2016 # expanded by the child shell
  as_primary STATE="$PRIMARY/state" FM_ROOT="$ROOT" bash -c '
    . "$1/bin/fm-secondmate-liveness-lib.sh"
    fm_secondmate_liveness_probe "$2" "$3" poll
    if [ "$4" = relaunch ]; then
      # A changed caller session must not move the recovered mate to another core.
      HC_SESSION=wrong-session
      fm_secondmate_liveness_relaunch "$2" "$3" 120 || { printf "%s\n" "$FM_SM_LIVE_OUT" >&2; exit 1; }
    fi
    printf "%s %s %s\n" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE" "${FM_SM_LIVE_KILL:-0}"
  ' _ "$ROOT" "$PRIMARY/state/$ID.meta" "$ID" "$1"
}
assert_mate_labels() { # <address> <what>
  [ "$(label "$1" firstmate.task)" = "fm-$ID" ] || fail "$2 must carry firstmate.task=fm-$ID"
  [ "$(label "$1" firstmate.home)" = "$PRIMARY_TAG" ] \
    || fail "$2's identity must be the primary's ($PRIMARY_TAG), got $(label "$1" firstmate.home)"
  [ "$(label "$1" herdr.space)" = "fm-$SM_TAG" ] \
    || fail "$2 must open in the secondmate home's own space fm-$SM_TAG, got $(label "$1" herdr.space)"
  [ "$(label "$1" herdr.tab)" = "$PRIMARY_TAG-fm-$ID" ] || fail "$2 must carry its herdr.tab"
}

# --- spawn ------------------------------------------------------------------
OUT=$(as_primary "$ROOT/bin/fm-spawn.sh" "$ID" "$SM" "$AGENT_BIN/codex 900" --secondmate --backend hc 2>"$TMP_ROOT/spawn.err") \
  || fail "the primary's --secondmate spawn on hc failed"$'\n'"$OUT"$'\n'"$(cat "$TMP_ROOT/spawn.err")"
case "$OUT" in *"spawned $ID "*"kind=secondmate"*) : ;; *) fail "unexpected spawn output: $OUT" ;; esac
[ "$(meta_value backend)" = hc ] || fail "meta must record backend=hc"
[ "$(meta_value kind)" = secondmate ] || fail "meta must record kind=secondmate"
[ "$(meta_value home)" = "$SM" ] || fail "meta must record the secondmate home"
[ "$(meta_value hc_session)" = "$HC_TEST_SES" ] || fail "meta must record the lab hc_session"
ADDR=$(meta_value hc_terminal)
T=$HC_TEST_SES:$ADDR
[ "$(meta_value window)" = "$T" ] || fail "window= must be hc_session:hc_terminal"
assert_mate_labels "$ADDR" "the secondmate's terminal"
pass "spawn: a --secondmate lands on hc with the primary's identity and the secondmate home's own Herdr.app space"

# --- liveness, steering, and control on a live agent ------------------------
wait_state "$T" alive || fail "the agent-named process never read alive (got $(fm_backend_agent_state hc "$T"))"
[ "$(liveness probe)" = "alive alive 0" ] || fail "liveness must read the live mate alive, got: $(liveness probe)"
as_primary "$ROOT/bin/fm-send.sh" "fm-$ID" 'hc lab steer' >/dev/null 2>&1 || fail "fm-send to the hc secondmate failed"
[ -f "$PRIMARY/state/$ID.inbox/001.msg" ] || fail "fm-send did not write the durable inbox record"
OUT=$(as_primary "$ROOT/bin/fm-control.sh" "$ID" interrupt 2>&1) || fail "interrupt on the hc secondmate failed: $OUT"
case "$OUT" in *"interrupt-delivered $ID harness=codex backend=hc "*) : ;;
*) fail "interrupt must reach the hc secondmate, got: $OUT" ;; esac
pass "live mate: liveness reads alive, fm-send records the steer, and interrupt reaches the agent"

# --- a dead agent: the liveness relaunch respawns the mate on hc ------------
PID=$("$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" get "$ADDR" --json | jq -r '.foreground.pid // empty')
[ -n "$PID" ] || fail "could not read the agent's pid from hc get"
kill "$PID" 2>/dev/null || fail "could not stop the agent-named process"
wait_state "$T" dead || fail "the agent-free terminal never read dead (got $(fm_backend_agent_state hc "$T"))"
[ "$(liveness probe)" = "relaunchable dead 1" ] \
  || fail "liveness must mark the dead mate relaunchable with its husk killed, got: $(liveness probe)"
OUT=$(liveness relaunch 2>&1) || fail "the liveness relaunch failed: $OUT"
for _ in $(seq 1 50); do
  [ -e "$TMP_ROOT/opencode-launched" ] && break
  sleep 0.1
done
[ -e "$TMP_ROOT/opencode-launched" ] || fail "the respawn did not launch the configured harness as the secondmate home: $OUT"$'\n'"$("$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" read "$(meta_value hc_terminal)" --lines 40 2>&1)"
if "$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" get "$ADDR" --json >/dev/null 2>&1; then
  fail "the liveness relaunch left the dead mate's husk $ADDR behind"
fi
[ "$(meta_value backend)" = hc ] || fail "the respawn must stay on hc"
NEW_ADDR=$(meta_value hc_terminal)
[ -n "$NEW_ADDR" ] && [ "$NEW_ADDR" != "$ADDR" ] || fail "the respawn must record a fresh terminal, got '$NEW_ADDR'"
[ "$(meta_value window)" = "$HC_TEST_SES:$NEW_ADDR" ] || fail "the respawn must record its window"
assert_mate_labels "$NEW_ADDR" "the respawned terminal"
pass "dead agent: liveness closes the husk and respawns the mate on hc in a fresh, correctly labeled terminal"

# --- retirement closes the mate's own child endpoints, then the mate --------
CHILD=$("$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" run --bg --no-parent --outlive-parent --no-notify \
  --label firstmate.task=fm-child1 --label "firstmate.home=$SM_TAG" | jq -r '.address // empty')
[ -n "$CHILD" ] || fail "could not start the secondmate's child terminal"
printf 'window=%s:%s\nendpoint_task_id=child1\nworktree=%s\nproject=%s\nkind=scout\nharness=codex\nbackend=hc\nhc_session=%s\nhc_terminal=%s\n' \
  "$HC_TEST_SES" "$CHILD" "$TMP_ROOT/child-copy-gone" "$TMP_ROOT/child-project-gone" "$HC_TEST_SES" "$CHILD" \
  >"$SM/state/child1.meta"
OUT=$(as_primary FM_TEARDOWN_GUARD_DONE=1 "$ROOT/bin/fm-teardown.sh" "$ID" --force 2>&1) \
  || fail "forced retirement of the hc secondmate failed: $OUT"
[ ! -e "$PRIMARY/state/$ID.meta" ] || fail "retirement left the secondmate's record"
[ ! -e "$SM" ] || fail "retirement left the secondmate home"
for a in "$NEW_ADDR" "$CHILD"; do
  if "$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" get "$a" --json >/dev/null 2>&1; then
    fail "retirement left terminal $a behind"
  fi
done
pass "retirement: the child endpoint labeled for the secondmate home and the mate's own terminal are closed"
echo FM_TEST_COMPLETE
