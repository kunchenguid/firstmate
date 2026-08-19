#!/usr/bin/env bash
# Public behavior tests for completed Herdr sibling-worker pressure reporting.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot fm-herdr-completed-pressure)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

make_fakebin() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"result":{"process_info":{"shell_pid":4242}}}'
SH
  cat > "$dir/ps" <<'SH'
#!/usr/bin/env bash
if [ "$1" = -axo ]; then
  printf ' 4242 1 %s\n' "${FM_TEST_COMPLETED_RSS_KIB:-1}"
else
  /bin/ps "$@"
fi
SH
  chmod +x "$dir/herdr" "$dir/ps"
}

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
cat > "$HOME_DIR/state/finished.meta" <<'EOF'
window=lab:p1
endpoint_task_id=finished
worktree=/tmp/finished
project=/tmp/project
harness=pi
kind=ship
backend=herdr
herdr_session=lab
herdr_workspace_id=w1
herdr_tab_id=w1:t1
herdr_pane_id=p1
herdr_presentation=tabs
task_title=Complete fixture
herdr_tab_completed=1
EOF
FAKEBIN="$TMP_ROOT/fakebin"
make_fakebin "$FAKEBIN"

out=$(PATH="$FAKEBIN:$PATH" FM_TEST_COMPLETED_RSS_KIB=$((10 * 1024 * 1024 + 1)) \
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  "$ROOT/bin/fm-herdr-completed-pressure.sh") || fail "pressure check failed at the completed-worker RSS threshold"
[ "$out" = 'Captain, completed workers - resource pressure.' ] \
  || fail "pressure warning was not the required concise captain message: '$out'"
pass "completed worker RSS above 10 GiB emits exactly the one required warning"

out=$(PATH="$FAKEBIN:$PATH" FM_TEST_COMPLETED_RSS_KIB=1 \
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  "$ROOT/bin/fm-herdr-completed-pressure.sh") || fail "pressure check failed below the completed-worker RSS threshold"
[ -z "$out" ] || fail "sub-threshold completed workers emitted a warning: '$out'"
pass "completed worker RSS below 10 GiB is silent"

PROC_ROOT="$TMP_ROOT/proc"
mkdir -p "$PROC_ROOT"
printf 'MemAvailable: 1048576 kB\n' > "$PROC_ROOT/meminfo"
out=$(PATH="$FAKEBIN:$PATH" FM_TEST_COMPLETED_RSS_KIB=1 FM_PROC_ROOT_OVERRIDE="$PROC_ROOT" \
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  "$ROOT/bin/fm-herdr-completed-pressure.sh") || fail "pressure check failed at the available-memory threshold"
[ "$out" = 'Captain, completed workers - resource pressure.' ] \
  || fail "available memory below 2 GiB did not emit the required warning: '$out'"
pass "available memory below 2 GiB emits exactly the one required warning"

rm -f "$HOME_DIR/state/finished.meta"
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  "$ROOT/bin/fm-herdr-completed-pressure.sh") || fail "pressure check failed without completed workers"
[ -z "$out" ] || fail "no completed workers emitted a warning: '$out'"
pass "no completed worker is silent"
