#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-crew-state.sh"
fm_test_tmproot_into TMP_ROOT fm-crew-state
trap 'rm -rf "$TMP_ROOT"' EXIT

state="$TMP_ROOT/state"
worktree="$TMP_ROOT/worktree"
fakebin="$TMP_ROOT/fakebin"
mkdir -p "$state" "$worktree" "$fakebin"

cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  has-session) exit "${FM_FAKE_TMUX_MISSING:-0}" ;;
  capture-pane) printf '%s\n' "${FM_FAKE_PANE:-idle}" ;;
  display-message) printf '%s\n' 'firstmate:fm-demo' ;;
  list-windows) printf '%s\n' 'fm-demo' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$fakebin/tmux"

assert_line() {
  local expected=$1 out
  shift
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$@")
  printf '%s\n' "$out" | grep -Fq "$expected" \
    || fail "expected '$expected' in: $out"
}

assert_line 'state: unknown · source: none · no metadata for missing' \
  "$SCRIPT" missing

cat > "$state/demo.meta" <<EOF
worktree=$worktree
kind=ship
backend=tmux
window=firstmate:fm-demo
EOF

FM_FAKE_PANE='Working... esc to interrupt' \
  assert_line 'state: working · source: pane · harness busy' "$SCRIPT" demo

printf '%s\n' 'paused: waiting for an external deployment' > "$state/demo.status"
FM_FAKE_PANE=idle \
  assert_line 'state: paused · source: status-log' "$SCRIPT" demo

printf '%s\n' 'done: PR merged' > "$state/demo.status"
FM_FAKE_PANE=idle \
  assert_line 'state: done · source: status-log · PR merged' "$SCRIPT" demo

printf '%s\n' \
  'needs-decision [key=audience]: choose the release audience' \
  'working: unrelated follow-up' \
  'done: implementation ready' > "$state/demo.status"
FM_FAKE_PANE=idle \
  assert_line 'state: parked · source: status-log · choose the release audience' "$SCRIPT" demo

printf '%s\n' 'resolved [key=audience]: captain chose' >> "$state/demo.status"
FM_FAKE_PANE=idle \
  assert_line 'state: unknown · source: none · backend idle with no current-state event' "$SCRIPT" demo

FM_FAKE_TMUX_MISSING=1 \
  assert_line 'state: unknown · source: none · backend target gone' "$SCRIPT" demo

pass 'crew state uses only the backend endpoint and task status log'
