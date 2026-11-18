#!/usr/bin/env bash
# tests/fm-backend-hc-secondmate-smoke.test.sh - real herdr-core proof of a
# persistent second mate on the hc backend (docs/hc-backend.md "Second mates").
#
# Everything else about hc second mates is pinned against a fake core
# (tests/fm-backend-hc.test.sh, tests/fm-secondmate-liveness.test.sh); this
# suite drives the REAL binary, only inside a bin/fm-hc-lab.sh session (a
# unique fm-hclab-* HC_SESSION, scratch XDG roots, a pinned FM_HC_SOCKET, a
# real-fleet tripwire, and a teardown that sweeps the session's daemons and
# their children). tests/hc-test-safety.sh owns the only sanctioned teardown
# path, and teardown failures propagate through the EXIT trap.
#
# Covered end to end through the real launch owner and the real recovery
# library (bin/fm-secondmate-liveness-lib.sh, which the session-start sweep
# and the watcher's liveness tick both drive):
#   1. `bin/fm-spawn.sh <id> <home> --secondmate --backend hc` places the
#      mate's terminal in the mate home's own Herdr.app space while this home
#      keeps the identity labels, and the classifier reads the agent alive;
#   2. a mate whose agent died (a shell left in its terminal) is closed,
#      removed, and respawned in the same space at a new address, on the
#      backend its record names (recovery keeps a local mate on its recorded
#      backend, PR #8082);
#   3. a mate whose terminal finished (program ended, record kept) has that
#      husk removed before the respawn;
#   4. an alive mate is left untouched.
# The agent is the shared stand-in (tests/lib.sh fm_agent_standin), copied
# under the name of a verified adapter so the classifier reads it alive and
# no model tokens are spent; the launch bakes its absolute path in, so the
# terminal's own shell PATH is never relied on.
#
# Skips cleanly when no herdr-core binary, jq, or an argument-tolerant
# stand-in is available (optional-binary gate); once the binary is present,
# a provisioning or teardown failure is a FAIL, not a skip.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

HC_BIN=${FM_HC_BIN:-}
[ -n "$HC_BIN" ] || HC_BIN=$(command -v herdr-core 2>/dev/null || true)
[ -n "$HC_BIN" ] || HC_BIN=$(command -v hc 2>/dev/null || true)
if [ -z "$HC_BIN" ] || [ ! -x "$HC_BIN" ]; then
  echo "skip: hc not found (install via bin/fm-install-hc.sh or set FM_HC_BIN)"
  exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the hc adapter)"; exit 0; }
export FM_HC_BIN=$HC_BIN

# shellcheck source=tests/hc-test-safety.sh
. "$ROOT/tests/hc-test-safety.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-hc-smate)

# The opencode launch template bakes the executable resolved from THIS
# process's PATH into the launch line, which is what lets a stand-in stand in
# without touching the terminal's shell PATH. fm-spawn probes that executable
# with --version before launch, and the spinner would sit on that probe for
# its whole run, so what PATH resolves is a wrapper that answers the probe at
# once and otherwise execs the spinner under the adapter's own name - the
# name hc then reports as the terminal's foreground. The spinner must survive
# the launch arguments, so the host-sleep fallback (which rejects them) means
# skip.
STANDIN=$(fm_agent_standin "$TMP_ROOT/standin") || { echo "skip: no agent stand-in survives a foreign name here"; exit 0; }
if [ -L "$STANDIN" ]; then
  echo "skip: the only agent stand-in is the host sleep, which rejects launch arguments"
  exit 0
fi
mkdir -p "$TMP_ROOT/agent" "$TMP_ROOT/agent-bin"
cp "$STANDIN" "$TMP_ROOT/agent-bin/opencode"
cat > "$TMP_ROOT/agent/opencode" <<SH
#!/usr/bin/env bash
case "\${1:-}" in --version|--help) exit 0 ;; esac
exec "$TMP_ROOT/agent-bin/opencode" "\$@"
SH
chmod +x "$TMP_ROOT/agent/opencode"
export PATH="$TMP_ROOT/agent:$PATH"
[ "$(command -v opencode)" = "$TMP_ROOT/agent/opencode" ] || fail "the stand-in must shadow any installed opencode for this run"
opencode --version || fail "the stand-in wrapper must answer the version probe"

ID="smhc$$"
HC_TEST_SES=$("$ROOT/bin/fm-hc-lab.sh" name smate)

cleanup_lab() {
  local rc=$?
  trap - EXIT
  hc_test_safe_teardown "$ROOT" "$HC_TEST_SES" || rc=1
  fm_test_remove_tree "/tmp/fm-$ID"
  [ -z "${LAUNCH_DIR:-}" ] || fm_test_remove_tree "$LAUNCH_DIR"
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
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET FM_ROOT_OVERRIDE FM_BACKEND \
  TMUX HERDR_ENV FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

# The primary home that owns the mate's record, and the seeded mate home. The
# primary sets config/backend=hc as an ordinary home setting; the recovery
# respawn below stays on hc because the mate's record names hc.
PRIMARY=$TMP_ROOT/home
MATE=$TMP_ROOT/mate
mkdir -p "$PRIMARY/state" "$PRIMARY/config" "$PRIMARY/data" "$TMP_ROOT/user-home" \
  "$MATE/bin" "$MATE/data" "$MATE/state" "$MATE/config" "$MATE/projects"
printf 'hc\n' > "$PRIMARY/config/backend"
printf 'opencode\n' > "$PRIMARY/config/secondmate-harness"
printf '%s\n' "$ID" > "$MATE/.fm-secondmate-home"
printf '# Firstmate\n' > "$MATE/AGENTS.md"
printf 'charter\n' > "$MATE/data/charter.md"
printf '%s\n' 'projects/' 'state/' 'data/' 'config/' > "$MATE/.gitignore"
git -C "$MATE" init -q -b main
export FM_HOME=$PRIMARY HOME=$TMP_ROOT/user-home FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_SYNC=1
STATE=$PRIMARY/state
LAUNCH_DIR="/tmp/fm-$ID+$(printf '%s' "$(cd "$PRIMARY" && pwd -P)" | shasum -a 256 | awk '{print $1}')"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source hc || fail "could not source the hc adapter"
PRIMARY_TAG=$(fm_backend_hometag)
MATE_TAG=$(FM_HOME="$MATE" FM_ROOT="$MATE" fm_backend_hometag)
[ -n "$PRIMARY_TAG" ] && [ -n "$MATE_TAG" ] && [ "$PRIMARY_TAG" != "$MATE_TAG" ] || fail "could not resolve distinct home tags"

wait_for() {  # <seconds> <cmd...>
  local tries=$(( $1 * 10 ))
  shift
  while [ "$tries" -gt 0 ]; do
    "$@" && return 0
    tries=$((tries - 1))
    sleep 0.1
  done
  return 1
}
lab() { "$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" "$@"; }
meta_field() { fm_meta_get "$STATE/$ID.meta" "$1"; }
state_is() { [ "$(fm_backend_agent_state hc "$(meta_field window)")" = "$1" ]; }
assert_mate_labels() {  # <address>
  local labels
  labels=$(lab get "$1" --json | jq -r '.labels["herdr.space"], .labels["herdr.tab"], .labels["firstmate.task"], .labels["firstmate.home"]') \
    || fail "hc get on the mate's terminal $1 failed"
  [ "$(printf '%s\n' "$labels" | sed -n 1p)" = "fm-$MATE_TAG" ] || fail "the mate's herdr.space must be fm-$MATE_TAG, got: $labels"
  [ "$(printf '%s\n' "$labels" | sed -n 2p)" = "$PRIMARY_TAG-fm-$ID" ] || fail "the mate's herdr.tab must be $PRIMARY_TAG-fm-$ID, got: $labels"
  [ "$(printf '%s\n' "$labels" | sed -n 3p)" = "fm-$ID" ] || fail "the mate's firstmate.task must be fm-$ID, got: $labels"
  [ "$(printf '%s\n' "$labels" | sed -n 4p)" = "$PRIMARY_TAG" ] || fail "the mate's firstmate.home must be $PRIMARY_TAG, got: $labels"
}
agent_pid() { lab get "$(meta_field hc_terminal)" --json | jq -r '.foreground.pid // empty'; }

# --- 1. the launch ------------------------------------------------------------
OUT=$("$ROOT/bin/fm-spawn.sh" "$ID" "$MATE" --secondmate --backend hc 2>"$TMP_ROOT/spawn.err") \
  || fail "fm-spawn.sh --secondmate --backend hc failed"$'\n'"--- stdout ---"$'\n'"$OUT"$'\n'"--- stderr ---"$'\n'"$(cat "$TMP_ROOT/spawn.err")"
case "$OUT" in *"spawned $ID harness=opencode kind=secondmate"*) : ;; *) fail "unexpected spawn output: $OUT" ;; esac
[ "$(meta_field backend)" = hc ] || fail "the record must say backend=hc"
[ "$(meta_field hc_session)" = "$HC_TEST_SES" ] || fail "the record must name the lab session"
[ "$(meta_field home)" = "$(cd "$MATE" && pwd -P)" ] || fail "the record must name the mate home"
ADDR1=$(meta_field hc_terminal)
[ -n "$ADDR1" ] || fail "the record must name the mate's terminal"
assert_mate_labels "$ADDR1"
wait_for 20 state_is alive || fail "the mate's agent never read alive (state: $(fm_backend_agent_state hc "$(meta_field window)"))"
pass "hc secondmate smoke: a real --secondmate launch lands in the mate's own space with this home's identity and an alive agent"

# --- 2. dead agent: close, remove, respawn --------------------------------------
# shellcheck source=/dev/null
. "$ROOT/bin/fm-secondmate-liveness-lib.sh"
recover() {  # -> runs one full sweep episode on the mate, failing on anything but a relaunch
  fm_secondmate_liveness_lock "$ID" || fail "could not take the mate's liveness lock"
  fm_secondmate_liveness_probe "$STATE/$ID.meta" "$ID" full
  [ "$FM_SM_LIVE_STATUS" = relaunchable ] || { fm_secondmate_liveness_unlock "$ID"; fail "expected a relaunchable verdict, got status=$FM_SM_LIVE_STATUS state=$FM_SM_LIVE_STATE reason=$FM_SM_LIVE_REASON"; }
  [ "$FM_SM_LIVE_KILL" = 1 ] || { fm_secondmate_liveness_unlock "$ID"; fail "an hc husk must be closed before the respawn (kill=$FM_SM_LIVE_KILL)"; }
  fm_secondmate_liveness_relaunch "$STATE/$ID.meta" "$ID" || { fm_secondmate_liveness_unlock "$ID"; fail "the respawn failed: $FM_SM_LIVE_OUT"; }
  fm_secondmate_liveness_unlock "$ID"
}
PID1=$(agent_pid)
[ -n "$PID1" ] || fail "could not read the agent's pid"
kill "$PID1" 2>/dev/null || fail "could not end the stand-in agent"
wait_for 20 state_is dead || fail "a terminal whose agent ended must read dead (state: $(fm_backend_agent_state hc "$(meta_field window)"))"
recover
ADDR2=$(meta_field hc_terminal)
[ -n "$ADDR2" ] && [ "$ADDR2" != "$ADDR1" ] || fail "the respawn must bind a fresh terminal, got '$ADDR2' after '$ADDR1'"
[ "$(meta_field backend)" = hc ] || fail "the respawn must stay on the recorded backend hc"
rc=0; lab get "$ADDR1" --json >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "the dead terminal $ADDR1 must be removed from the core (hc get exited $rc)"
assert_mate_labels "$ADDR2"
wait_for 20 state_is alive || fail "the respawned agent never read alive"
grep -q relaunched "$STATE/.secondmate-relaunch-$ID" || fail "the relaunch ledger must record the outcome"
pass "hc secondmate smoke: a dead mate is closed, removed, and respawned in the same space at a new address"

# --- 3. finished terminal: husk removed before respawn --------------------------
PID2=$(agent_pid)
kill "$PID2" 2>/dev/null || fail "could not end the second stand-in agent"
wait_for 20 state_is dead || fail "the second agent's terminal never read dead"
lab kill "$ADDR2" --json >/dev/null || fail "could not finish the mate's terminal"
wait_for 20 state_is missing || fail "a finished terminal must read missing (state: $(fm_backend_agent_state hc "$(meta_field window)"))"
[ "$(lab get "$ADDR2" --json | jq -r .state)" = finished ] || fail "the finished record must still exist before recovery"
recover
ADDR3=$(meta_field hc_terminal)
[ -n "$ADDR3" ] && [ "$ADDR3" != "$ADDR2" ] || fail "the respawn after a finished terminal must bind a fresh one"
rc=0; lab get "$ADDR2" --json >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "the finished husk $ADDR2 must be removed from the core (hc get exited $rc)"
assert_mate_labels "$ADDR3"
wait_for 20 state_is alive || fail "the agent respawned after a finished terminal never read alive"
pass "hc secondmate smoke: a finished terminal is removed as a husk before the mate is respawned"

# --- 4. alive: untouched --------------------------------------------------------
BEFORE=$(cat "$STATE/$ID.meta")
fm_secondmate_liveness_probe "$STATE/$ID.meta" "$ID" full
[ "$FM_SM_LIVE_STATUS" = alive ] || fail "an alive mate must probe alive, got $FM_SM_LIVE_STATUS ($FM_SM_LIVE_STATE)"
[ "$(cat "$STATE/$ID.meta")" = "$BEFORE" ] || fail "probing an alive mate must not change its record"
state_is alive || fail "the alive mate must still be alive after the probe"
pass "hc secondmate smoke: an alive mate is left exactly as it is"

fm_backend_kill hc "$(meta_field window)" '' "fm-$ID" || fail "closing the mate's terminal failed"
echo FM_TEST_COMPLETE
