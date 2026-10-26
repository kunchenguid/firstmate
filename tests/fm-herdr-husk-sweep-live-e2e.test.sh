#!/usr/bin/env bash
# Default-on live guard for the session-start Herdr husk sweep
# (bin/fm-herdr-husk-lib.sh via bin/fm-bootstrap.sh) against the REAL installed
# herdr, on a private named lab session only (tests/herdr-test-safety.sh).
#
# The portable suite (tests/fm-herdr-husk-sweep.test.sh) pins the decision
# logic against a fake; this guard proves the vendor facts it rests on: a
# real restored-shape task tab (a labelled tab holding one bare idle shell that
# no local home records) is closed by the sweep and confirmed gone, while a
# labelled tab whose shell is running a foreground command is kept with that
# reason and left running. The process proof reads the real `pane
# process-info` and the real process table, so a change in either fails here
# naming the Herdr version. No prompt is submitted to a model, so the shared
# live gate runs this by default wherever its tools exist.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

fm_live_gate default-on FM_LIVE_HERDR_HUSK_SWEEP herdr jq

herdr_forget_inherited_pane
SESSION=$("$ROOT/bin/fm-herdr-lab.sh" name fm-husk-sweep)
export HERDR_SESSION="$SESSION"
HERDR_VERSION=$(herdr --version 2>/dev/null | head -1)
TMP_ROOT=$(fm_test_tmproot fm-herdr-husk-sweep-live)

cleanup_all() {
  local status=$?
  herdr_safe_stop_and_delete "$SESSION"
  exit "$status"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session $SESSION"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"
fm_backend_herdr_server_ensure "$SESSION" || fail "could not start the lab server for $SESSION"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
printf 'herdr\n' > "$HOME_DIR/config/backend"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
CWD="$TMP_ROOT/cwd"
mkdir -p "$CWD"

WSID=$(herdr workspace create --label firstmate --cwd "$CWD" --no-focus --session "$SESSION" 2>/dev/null \
  | jq -r '.result.workspace.workspace_id // empty')
[ -n "$WSID" ] || fail "could not create the lab workspace ($HERDR_VERSION)"
create_tab() { # <label> -> pane id
  herdr tab create --workspace "$WSID" --cwd "$CWD" --label "$1" --no-focus --session "$SESSION" 2>/dev/null \
    | jq -r '.result.root_pane.pane_id // empty'
}
HUSK_PANE=$(create_tab fm-husk-live-a)
BUSY_PANE=$(create_tab fm-husk-live-b)
[ -n "$HUSK_PANE" ] && [ -n "$BUSY_PANE" ] || fail "could not create the lab task tabs ($HERDR_VERSION)"

# The husk's shell must have finished initializing (the same proof the sweep
# applies), and the busy pane must be running its foreground command.
fm_backend_herdr_pane_idle_shell_wait "$SESSION" "$HUSK_PANE" 120 0.25 >/dev/null \
  || fail "the fresh lab pane $HUSK_PANE never became a lone idle shell within 30s ($HERDR_VERSION)"
fm_backend_herdr_pane_idle_shell_wait "$SESSION" "$BUSY_PANE" 120 0.25 >/dev/null \
  || fail "the fresh lab pane $BUSY_PANE never became a lone idle shell within 30s ($HERDR_VERSION)"
herdr pane run "$BUSY_PANE" "sleep 300" --session "$SESSION" >/dev/null 2>&1 || fail "could not start the busy pane's command"
for _ in $(seq 1 40); do
  if ! FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 fm_backend_herdr_pane_idle_shell_pid "$SESSION" "$BUSY_PANE" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
! FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 fm_backend_herdr_pane_idle_shell_pid "$SESSION" "$BUSY_PANE" >/dev/null 2>&1 \
  || fail "the busy pane still reads as a lone idle shell after sleep 300 was typed ($HERDR_VERSION)"

out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" FM_BOOTSTRAP_NETWORK=skip \
  "$ROOT/bin/fm-bootstrap.sh" 2>"$TMP_ROOT/bootstrap.stderr" | grep '^BOOTSTRAP_INFO: herdr husk' || true)
case "$out" in
  *"herdr husk fm-husk-live-a ($SESSION:$HUSK_PANE) closed"*) : ;;
  *) fail "the sweep did not close the real husk tab on $HERDR_VERSION; output:"$'\n'"$out"$'\n'"stderr:"$'\n'"$(cat "$TMP_ROOT/bootstrap.stderr")" ;;
esac
case "$out" in
  *"herdr husk fm-husk-live-b ($SESSION:$BUSY_PANE) kept: its pane is not a lone idle shell"*) : ;;
  *) fail "the sweep did not keep the busy tab with its reason on $HERDR_VERSION; output:"$'\n'"$out" ;;
esac
[ "$(fm_backend_herdr_pane_presence_state "$SESSION" "$HUSK_PANE")" = dead ] \
  || fail "the husk pane $HUSK_PANE is still present after the sweep reported it closed ($HERDR_VERSION)"
[ "$(fm_backend_herdr_pane_presence_state "$SESSION" "$BUSY_PANE")" = present ] \
  || fail "the busy pane $BUSY_PANE disappeared ($HERDR_VERSION)"
pass "real herdr: the sweep closed the restored-shape husk and kept the busy tab with its reason ($HERDR_VERSION)"

out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" FM_BOOTSTRAP_NETWORK=skip \
  "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep '^BOOTSTRAP_INFO: herdr husk' || true)
case "$out" in
  *"fm-husk-live-a"*) fail "a repeat sweep found the closed husk again ($HERDR_VERSION)"$'\n'"$out" ;;
esac
pass "real herdr: a repeat sweep is a no-op for the closed husk"

echo "evidence: herdr=$HERDR_VERSION husk-closed=$HUSK_PANE busy-kept=$BUSY_PANE default-session-tripwire=armed"
