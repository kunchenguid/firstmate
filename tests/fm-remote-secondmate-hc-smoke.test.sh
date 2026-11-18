#!/usr/bin/env bash
# tests/fm-remote-secondmate-hc-smoke.test.sh - real herdr-core proof of a
# remote second mate's host-local control plane on the hc backend
# (docs/remote-secondmates.md "Where the remote agent runs").
#
# tests/fm-remote-secondmate-hc.test.sh pins the same verbs against a fake
# core; this suite drives the REAL binary, only inside a bin/fm-hc-lab.sh
# session (a unique fm-hclab-* session named through FM_REMOTE_HC_SESSION,
# scratch XDG roots, a pinned FM_HC_SOCKET, a real-fleet tripwire, and the
# guarded teardown tests/hc-test-safety.sh owns). Covered end to end through
# bin/fm-remote-secondmate-control.sh, the way the parent reaches it over SSH:
#   1. `launch ... hc` lands the mate's terminal in the remote hc session with
#      the code root's identity labels and the mate home's Herdr.app space,
#      and the agent reads alive;
#   2. a steer is recorded in the mate's inbox and its doorbell is typed into
#      the mate's terminal, which the code root's identity owns;
#   3. a finished terminal is removed as a husk and the mate relaunched;
#   4. retirement closes the terminal and removes the home.
# The agent is the shared stand-in (tests/lib.sh fm_agent_standin) under a
# verified adapter's name, so no model tokens are spent.
#
# Skips cleanly when no herdr-core binary, jq, node, or an argument-tolerant
# stand-in is available; once the binary is present, a provisioning or
# teardown failure is a FAIL, not a skip.
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
command -v node >/dev/null 2>&1 || { echo "skip: node not found (required by the hc socket probe)"; exit 0; }
export FM_HC_BIN=$HC_BIN

# shellcheck source=tests/hc-test-safety.sh
. "$ROOT/tests/hc-test-safety.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-smate-hc)

# The same stand-in wrapper tests/fm-backend-hc-secondmate-smoke.test.sh uses:
# PATH resolves a wrapper that answers the launch probe at once and otherwise
# execs the spinner under the adapter's own name.
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

ID="rsmhc$$"
HC_TEST_SES=$("$ROOT/bin/fm-hc-lab.sh" name rsmate)

cleanup_lab() {
  local rc=$?
  trap - EXIT
  hc_test_safe_teardown "$ROOT" "$HC_TEST_SES" || rc=1
  fm_test_remove_tree "/tmp/fm-$ID"
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
export FM_REMOTE_HC_SESSION=$HC_TEST_SES FM_HC_SOCKET=$HC_TEST_SOCK
export XDG_STATE_HOME="$HC_LAB_DIR/env/xdg-state" \
  XDG_CONFIG_HOME="$HC_LAB_DIR/env/xdg-config" \
  XDG_DATA_HOME="$HC_LAB_DIR/env/xdg-data"
unset HC_SESSION HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET FM_ROOT_OVERRIDE FM_BACKEND \
  TMUX HERDR_ENV FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

# The seeded remote mate home, exactly as remote provisioning leaves it.
MATE=$TMP_ROOT/mate
mkdir -p "$TMP_ROOT/user-home" "$MATE/bin" "$MATE/data" "$MATE/state" "$MATE/config" "$MATE/projects"
printf '%s\n' "$ID" > "$MATE/.fm-secondmate-home"
printf '# Firstmate\n' > "$MATE/AGENTS.md"
printf 'charter\n' > "$MATE/data/charter.md"
printf '%s\n' 'projects/' 'state/' 'data/' 'config/' > "$MATE/.gitignore"
git -C "$MATE" init -q -b main
export HOME=$TMP_ROOT/user-home FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 FM_SEND_SETTLE=0
META=$MATE/state/parent-route/$ID.meta

ctl() { FM_HOME="$MATE" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-remote-secondmate-control.sh" "$@"; }
lab() { "$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" "$@"; }
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
state_is() { [ "$(ctl state "$ID" 2>/dev/null)" = "$1" ]; }
meta_field() { sed -n "s/^$1=//p" "$META" | tail -1; }

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source hc || fail "could not source the hc adapter"
ROOT_TAG=$(FM_HOME="$ROOT" FM_ROOT="$ROOT" fm_backend_hometag)
MATE_TAG=$(FM_HOME="$MATE" FM_ROOT="$MATE" fm_backend_hometag)

# --- 1. the launch ------------------------------------------------------------
ctl launch "$ID" opencode - - hc > "$TMP_ROOT/launch.out" 2> "$TMP_ROOT/launch.err" \
  || fail "the remote control-plane launch on hc failed"$'\n'"$(cat "$TMP_ROOT/launch.out" "$TMP_ROOT/launch.err")"
assert_grep 'backend=hc' "$TMP_ROOT/launch.out" "the launch route did not report hc"
assert_grep "hc_session=$HC_TEST_SES" "$TMP_ROOT/launch.out" "the launch route did not name the lab session"
ADDR1=$(meta_field hc_terminal)
[ -n "$ADDR1" ] || fail "the endpoint record names no terminal"
labels=$(lab get "$ADDR1" --json | jq -r '.labels["herdr.space"], .labels["firstmate.task"], .labels["firstmate.home"]') \
  || fail "hc get on the mate's terminal failed"
[ "$(printf '%s\n' "$labels" | sed -n 1p)" = "fm-$MATE_TAG" ] || fail "the mate's terminal is not in its own space: $labels"
[ "$(printf '%s\n' "$labels" | sed -n 2p)" = "fm-$ID" ] || fail "the mate's terminal lacks its task label: $labels"
[ "$(printf '%s\n' "$labels" | sed -n 3p)" = "$ROOT_TAG" ] || fail "the mate's terminal lacks the code root's identity: $labels"
wait_for 20 state_is alive || fail "the remote hc mate never read alive (state: $(ctl state "$ID" 2>&1))"
pass "remote hc smoke: the control plane launches the mate in the remote hc session with an alive agent"

# --- 2. a steer --------------------------------------------------------------
ctl send "$ID" "smoke steer for $ID" > "$TMP_ROOT/send.out" 2>&1 || fail "the steer failed: $(cat "$TMP_ROOT/send.out")"
grep -rqs "smoke steer for $ID" "$MATE/state/parent-route/$ID.inbox" || fail "the steer was not recorded in the mate's inbox"
assert_no_grep 'did not reach' "$TMP_ROOT/send.out" "the steer's doorbell did not reach the mate: $(cat "$TMP_ROOT/send.out")"
assert_no_grep 'foreign' "$TMP_ROOT/send.out" "the mate's own terminal read as foreign"
pass "remote hc smoke: a steer is recorded and its doorbell reaches the mate"

# --- 3. a finished terminal is replaced ----------------------------------------
lab kill "$ADDR1" --json >/dev/null || fail "could not finish the mate's terminal"
wait_for 20 state_is missing || fail "a finished terminal must read missing (state: $(ctl state "$ID" 2>&1))"
ctl launch "$ID" opencode - - hc > "$TMP_ROOT/relaunch.out" 2>&1 \
  || fail "the finished mate was not relaunched: $(cat "$TMP_ROOT/relaunch.out")"
ADDR2=$(meta_field hc_terminal)
[ -n "$ADDR2" ] && [ "$ADDR2" != "$ADDR1" ] || fail "the relaunch must bind a fresh terminal, got '$ADDR2' after '$ADDR1'"
rc=0; lab get "$ADDR1" --json >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "the finished husk $ADDR1 must be removed from the core (hc get exited $rc)"
wait_for 20 state_is alive || fail "the relaunched mate never read alive"
pass "remote hc smoke: a finished terminal is removed as a husk and the mate relaunched"

# --- 4. retirement -------------------------------------------------------------
ctl retire "$ID" > "$TMP_ROOT/retire.out" 2>&1 || fail "retirement failed: $(cat "$TMP_ROOT/retire.out")"
rc=0; lab get "$ADDR2" --json >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "retirement left the mate's terminal $ADDR2 in the core (hc get exited $rc)"
assert_absent "$MATE" "retirement left the mate's home behind"
pass "remote hc smoke: retirement closes the mate's terminal and removes its home"

echo FM_TEST_COMPLETE
