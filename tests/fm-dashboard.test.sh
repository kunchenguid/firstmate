#!/usr/bin/env bash
# Behavior tests for the read-only tmux dashboard and its no-active-state view.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dashboard-tests)
mkdir -p "$TMP_ROOT"

cat > "$TMP_ROOT/empty.json" <<'JSON'
{"schema":"fm-fleet-snapshot.v1","generated":"2026-07-19T12:00:00Z","tasks":[]}
JSON

test_no_active_session_render() {
  local roster details
  roster=$("$ROOT/bin/fm-dashboard-view.sh" roster --snapshot "$TMP_ROOT/empty.json")
  details=$("$ROOT/bin/fm-dashboard-view.sh" details --target fm-demo --snapshot "$TMP_ROOT/empty.json")
  assert_contains "$roster" "No active or recorded workers" "empty roster must be explicit"
  assert_contains "$details" "No active worker" "empty details must be explicit"
  assert_contains "$details" "Session/work order: fm-demo" "work order identity must stay visible"
  assert_contains "$details" "Work-order scope: unavailable" "missing scope must be explicit"
  assert_contains "$details" "unavailable in current telemetry" "missing telemetry must be labeled unavailable"
  pass "dashboard renders a definitive no-active-worker state without invented telemetry"
}

test_dashboard_uses_observer_only_tmux_operations() {
  local fakebin log output
  fakebin=$(fm_fakebin "$TMP_ROOT/tmux")
  log="$TMP_ROOT/tmux.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_DASHBOARD_TMUX_LOG"
case "$1" in
  has-session)
    case "$*" in *fm-dashboard-demo*) exit 1 ;; *) exit 0 ;; esac
    ;;
  new-session|split-window) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  output=$(PATH="$fakebin:/usr/bin:/bin" FM_DASHBOARD_TMUX_LOG="$log" \
    "$ROOT/bin/fm-dashboard.sh" fm-demo --no-attach)
  assert_contains "$output" "mutation: false" "dashboard must declare read-only behavior"
  assert_contains "$(cat "$log")" "new-session -d -s fm-dashboard-demo" "observer session was not created"
  assert_contains "$(cat "$log")" "split-window" "dashboard panes were not created"
  if grep -Eq 'send-keys|kill-session|kill-window' "$log"; then
    fail "dashboard used a mutating target-session operation: $(cat "$log")"
  fi
  pass "dashboard creates only its observer panes and never sends keys to the target"
}

test_no_active_session_render
test_dashboard_uses_observer_only_tmux_operations

echo "# all fm-dashboard tests passed"
