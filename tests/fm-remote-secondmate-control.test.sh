#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-control)
FIXTURE_ROOT="$TMP_ROOT/root"
HOME_DIR="$TMP_ROOT/home"
CALLS="$TMP_ROOT/spawn.calls"
mkdir -p "$FIXTURE_ROOT/bin" "$HOME_DIR/bin" "$HOME_DIR/state/parent-route" \
  "$HOME_DIR/data/.parent-route" "$HOME_DIR/config"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cp "$ROOT/bin/fm-remote-secondmate-control.sh" "$FIXTURE_ROOT/bin/"
cat > "$FIXTURE_ROOT/bin/fm-backend.sh" <<'SH'
fm_backend_validate_task_endpoint() {
  [ -f "$1" ] || return 1
  FM_BACKEND_VALIDATED_BACKEND=herdr
  FM_BACKEND_VALIDATED_TARGET=fm-remote:workspace:pane
}
fm_backend_meta_exact_value() {
  awk -F= -v key="$2" '$1 == key { print substr($0, length(key) + 2); exit }' "$1"
}
fm_backend_agent_state() { printf 'alive\n'; }
fm_backend_kill() { return 1; }
fm_meta_get() {
  awk -F= -v key="$2" '$1 == key { print substr($0, length(key) + 2); exit }' "$1"
}
SH
: > "$FIXTURE_ROOT/bin/fm-pending-reply-lib.sh"
cat > "$FIXTURE_ROOT/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${FM_REMOTE_SECONDMATE_LAUNCH:-}" = 1 ]
[ "${FM_STATE_OVERRIDE:-}" = "$FM_TEST_STATE" ]
[ "${FM_DATA_OVERRIDE:-}" = "$FM_TEST_DATA" ]
printf '%s\n' "$*" >> "$FM_TEST_CALLS"
rm -f -- "$FM_STATE_OVERRIDE/remote.spawn-endpoint.json"
SH
chmod +x "$FIXTURE_ROOT/bin/fm-remote-secondmate-control.sh" "$FIXTURE_ROOT/bin/fm-spawn.sh"
printf 'remote\n' > "$HOME_DIR/.fm-secondmate-home"
printf 'fixture\n' > "$HOME_DIR/AGENTS.md"
cat > "$HOME_DIR/state/parent-route/remote.meta" <<EOF
backend=herdr
window=fm-remote:workspace:pane
herdr_session=fm-remote
harness=kimi
EOF

run_launch() {
  local harness=${1:-kimi}
  FM_ROOT_OVERRIDE="$FIXTURE_ROOT" FM_HOME="$HOME_DIR" \
    FM_TEST_STATE="$HOME_DIR/state/parent-route" \
    FM_TEST_DATA="$HOME_DIR/data/.parent-route" FM_TEST_CALLS="$CALLS" \
    "$FIXTURE_ROOT/bin/fm-remote-secondmate-control.sh" \
      launch remote "$harness" - - herdr
}

out=$(run_launch) || fail "alive completed route was not reusable"
assert_contains "$out" 'schema=fm-remote-secondmate-control.v1' \
  "alive completed route did not return its public route"
assert_absent "$CALLS" "completed route unnecessarily resumed host-local spawn"

: > "$HOME_DIR/state/parent-route/remote.spawn-endpoint.json"
rc=0
out=$(run_launch 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "incomplete remote Kimi delivery was resumed without a prompt receipt"
assert_contains "$out" 'no transaction-scoped prompt receipt' \
  "remote Kimi refusal did not identify its missing acceptance boundary"
assert_absent "$CALLS" "remote Kimi refusal invoked host-local spawn"

sed 's/^harness=.*/harness=codex/' \
  "$HOME_DIR/state/parent-route/remote.meta" > "$HOME_DIR/state/parent-route/remote.meta.next"
mv -- "$HOME_DIR/state/parent-route/remote.meta.next" "$HOME_DIR/state/parent-route/remote.meta"
out=$(run_launch codex) || fail "alive Codex route with recovery evidence did not resume"
assert_contains "$out" 'harness=codex' "resumed launch did not return the Codex route"
[ "$(wc -l < "$CALLS" | tr -d ' ')" -eq 1 ] \
  || fail "host-local spawn was not resumed exactly once"
assert_grep '--secondmate --harness codex --backend herdr' "$CALLS" \
  "host-local recovery did not preserve the launch identity"
assert_absent "$HOME_DIR/state/parent-route/remote.spawn-endpoint.json" \
  "resumed host-local transaction did not retire its recovery receipt"

pass "remote secondmate launch refuses Kimi and resumes receiptable routes"
echo "ALL TESTS PASSED"
