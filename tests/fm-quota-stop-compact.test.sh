#!/usr/bin/env bash
# Public-interface tests for low-quota heartbeat steering.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-stop-compact)
HOME_DIR="$TMP_ROOT/home"
MOCK_ROOT="$TMP_ROOT/root"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$HOME_DIR/state" "$MOCK_ROOT/bin" "$FAKEBIN"
export FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$MOCK_ROOT"
export QUOTA_FIXTURE="$TMP_ROOT/quota.json" SEND_LOG="$TMP_ROOT/sends"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
[ "$*" = '--provider claude,codex,agy --json' ] || exit 9
cat "$QUOTA_FIXTURE"
SH
cat > "$MOCK_ROOT/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: pane · active\n'
SH
cat > "$MOCK_ROOT/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "$2" >> "$SEND_LOG"
SH
chmod +x "$FAKEBIN/quota-axi" "$MOCK_ROOT/bin/fm-crew-state.sh" "$MOCK_ROOT/bin/fm-send.sh"
export PATH="$FAKEBIN:$PATH"

cat > "$HOME_DIR/state/codex-task.meta" <<'META'
harness=codex
spawn_gen=7
META
cat > "$HOME_DIR/state/claude-task.meta" <<'META'
harness=claude
spawn_gen=3
META
cat > "$HOME_DIR/state/agy-task.meta" <<'META'
harness=agy
spawn_gen=2
META

quota_fixture() {
  local claude=$1 codex=$2 agy=$3 agy_claude_gpt=${4:-$3}
  cat > "$QUOTA_FIXTURE" <<JSON
{"schemaVersion":5,"providers":[
 {"provider":"claude","state":{"status":"fresh"},"windows":[{"id":"five_hour","percentRemaining":$claude}]},
 {"provider":"codex","state":{"status":"fresh"},"windows":[{"id":"five_hour","percentRemaining":$codex}]},
 {"provider":"agy","state":{"status":"fresh"},"windows":[{"id":"gemini_5h","percentRemaining":$agy},{"id":"claude_gpt_5h","percentRemaining":$agy_claude_gpt}]}
]}
JSON
}

quota_fixture 40 11 50
out=$("$ROOT/bin/fm-quota-stop-compact.sh") || fail "healthy quota check failed: $out"
[ ! -s "$SEND_LOG" ] || fail 'healthy quotas steered a session'
[ -z "$out" ] || fail "healthy quotas produced noise: $out"
pass 'healthy five-hour quotas stay silent and do not steer'

quota_fixture 10 40 50
out=$("$ROOT/bin/fm-quota-stop-compact.sh") || fail "Claude threshold check failed: $out"
assert_contains "$out" 'claude five-hour=10%' 'Claude threshold was not reported'
assert_grep 'claude-task' "$SEND_LOG" 'Claude live task was not selected'
assert_grep 'run /compact' "$SEND_LOG" 'Claude steer omitted its compact command'
pass 'Claude five-hour threshold steers its live task to compact at a breakpoint'
: > "$SEND_LOG"

quota_fixture 40 10 50
out=$("$ROOT/bin/fm-quota-stop-compact.sh") || fail "Codex threshold check failed: $out"
assert_contains "$out" 'codex five-hour=10%' 'Codex threshold was not reported'
[ "$(wc -l < "$SEND_LOG" | tr -d ' ')" = 1 ] || fail 'Codex threshold did not send exactly one steer'
assert_grep 'run /compact' "$SEND_LOG" 'Codex steer omitted its supported compact command'

out=$("$ROOT/bin/fm-quota-stop-compact.sh") || fail "repeated Codex check failed: $out"
[ "$(wc -l < "$SEND_LOG" | tr -d ' ')" = 1 ] || fail 'same low-quota episode sent a duplicate steer'
pass 'threshold steering is idempotent within one low-quota episode'

quota_fixture 40 11 50
"$ROOT/bin/fm-quota-stop-compact.sh" || fail 'quota recovery check failed'
quota_fixture 40 9 50
"$ROOT/bin/fm-quota-stop-compact.sh" || fail 'second Codex threshold check failed'
[ "$(wc -l < "$SEND_LOG" | tr -d ' ')" = 2 ] || fail 're-crossing the threshold did not steer again'
pass 'recovery above 10% starts a fresh alert episode'

quota_fixture 40 40 40 10
out=$("$ROOT/bin/fm-quota-stop-compact.sh") || fail "AGY threshold check failed: $out"
assert_grep 'Antigravity CLI has no supported context-compaction command' "$SEND_LOG" \
  'AGY steer did not state the missing native compaction action'
assert_grep 'durable checkpoint' "$SEND_LOG" 'AGY steer omitted its safe checkpoint substitute'
pass 'AGY threshold steering requests a durable checkpoint for fresh relaunch'
