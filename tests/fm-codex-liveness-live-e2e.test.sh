#!/usr/bin/env bash
# Opt-in credentialed guard for Firstmate's owning Codex app-server client.
# Every case starts the real installed app-server, drives the real JSONL
# protocol, and checks its individual terminal receipt rather than accepting an
# aggregate command status.
set -u

if [ "${FM_CODEX_LIVENESS_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_LIVENESS_LIVE_E2E=1 to run the real Codex app-server liveness guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

CLIENT="$ROOT/bin/fm-codex-appserver-client.mjs"
CODEX_BIN=$(command -v codex 2>/dev/null || true)
[ -x "$CODEX_BIN" ] || fail "FM_CODEX_LIVENESS_LIVE_E2E=1 but codex is not installed"
CODEX_VERSION=$($CODEX_BIN --version 2>/dev/null || true)
fm_busy_codex_appserver_observable \
  || fail "installed Codex cannot use the owning app-server client: ${CODEX_VERSION:-unreadable}"

LAB=$(fm_test_tmproot fm-codex-appserver-live)
STATE="$LAB/state"
WORK="$LAB/work"
mkdir -p "$STATE" "$WORK"
git -C "$WORK" init -q

cleanup() {
  local suffix
  for suffix in success failure interrupt timeout; do
    rm -rf -- "/tmp/fm-codex-appserver-live-$suffix"
  done
  fm_test_cleanup
}
trap cleanup EXIT

new_case() {  # <suffix> -> prints id gen tasktmp
  local suffix=$1 id gen task_tmp
  id="codex-appserver-live-$suffix"
  task_tmp="/tmp/fm-$id"
  rm -rf -- "$task_tmp"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$id" \
    --state unknown --source codex-appserver --event launch-pending) || fail "could not arm $id"
  printf '%s\t%s\t%s\n' "$id" "$gen" "$task_tmp"
}

run_live() {  # <id> <gen> <tasktmp> <deadline> <prompt> [model]
  local id=$1 gen=$2 task_tmp=$3 deadline=$4 prompt=$5 model=${6:-}
  local -a command
  command=("$CLIENT" --state-dir "$STATE" --task-id "$id" --generation "$gen" \
    --cwd "$WORK" --task-tmp "$task_tmp" --turn-ended "$STATE/$id.turn-ended" \
    --deadline-secs "$deadline" --prompt "$prompt" --one-shot)
  [ -z "$model" ] || command+=(--model "$model")
  FM_CODEX_BIN="$CODEX_BIN" FM_CODEX_APPSERVER_INTERRUPT_GRACE_MS=1000 \
    FM_CODEX_APPSERVER_TERM_GRACE_MS=1000 "${command[@]}"
}

classify() {  # <id>
  fm_busy_classify tmux live codex "$1" "$STATE"
}

assert_process_gone() {  # <receipt>
  local receipt=$1 child_pid
  child_pid=$(sed -n 's/.* child_pid=\([0-9][0-9]*\) .*/\1/p' "$receipt")
  [ -n "$child_pid" ] || fail "terminal receipt omitted the owned child PID"
  kill -0 "$child_pid" 2>/dev/null \
    && fail "owned app-server PID $child_pid survived its terminal receipt"
}

wait_until_busy_then_escape() {  # <id>
  local id=$1 i=0
  while [ "$i" -lt 300 ]; do
    case "$(classify "$id")" in
      busy*) printf '\033'; return 0 ;;
      unknown\ codex-turn-failed|unknown\ codex-protocol-*) return 1 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_real_success() {
  local id gen task_tmp out receipt
  IFS=$'\t' read -r id gen task_tmp <<EOF
$(new_case success)
EOF
  out=$(run_live "$id" "$gen" "$task_tmp" 60 \
    'Reply exactly APPSERVER_LIVE_SUCCESS and do nothing else.') \
    || fail "real app-server success case failed: $out"
  [ "$(classify "$id")" = "idle codex-appserver" ] \
    || fail "real completed turn did not classify idle: $(classify "$id")"
  receipt="$STATE/$id.codex-appserver-result"
  assert_contains "$(cat "$receipt")" "outcome=success" "real success receipt omitted outcome"
  assert_contains "$out" "APPSERVER_LIVE_SUCCESS" "real success omitted streamed agent output"
  assert_process_gone "$receipt"
  pass "real app-server success joined completed terminal with clean process exit"
}

test_real_failed_terminal() {
  local id gen task_tmp out receipt rc=0
  IFS=$'\t' read -r id gen task_tmp <<EOF
$(new_case failure)
EOF
  out=$(run_live "$id" "$gen" "$task_tmp" 60 'Reply SHOULD_NOT_SUCCEED.' \
    definitely-not-a-real-model-0815 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "real failed turn returned success: $out"
  [ "$(classify "$id")" = "unknown codex-turn-failed" ] \
    || fail "real failed terminal was not surfaced: $(classify "$id")"
  receipt="$STATE/$id.codex-appserver-result"
  assert_contains "$(cat "$receipt")" "terminal=failed" "real failure receipt omitted failed terminal"
  assert_process_gone "$receipt"
  pass "real app-server failed terminal remained failure after clean process exit"
}

test_real_interrupted_terminal() {
  local id gen task_tmp out receipt rc=0
  IFS=$'\t' read -r id gen task_tmp <<EOF
$(new_case interrupt)
EOF
  out=$(wait_until_busy_then_escape "$id" | run_live "$id" "$gen" "$task_tmp" 60 \
    'Use the shell tool to run sleep 20, then reply exactly INTERRUPT_SHOULD_NOT_COMPLETE. Do nothing else.' 2>&1) \
    || rc=$?
  [ "$rc" -ne 0 ] || fail "real interrupted turn returned success: $out"
  [ "$(classify "$id")" = "unknown codex-turn-interrupted" ] \
    || fail "real interrupted terminal was not surfaced: $(classify "$id")"
  receipt="$STATE/$id.codex-appserver-result"
  assert_contains "$(cat "$receipt")" "terminal=interrupted" \
    "real interrupt receipt omitted interrupted terminal"
  assert_process_gone "$receipt"
  pass "real app-server interruption used turn/interrupt and observed its terminal"
}

test_real_timeout() {
  local id gen task_tmp out receipt rc=0
  IFS=$'\t' read -r id gen task_tmp <<EOF
$(new_case timeout)
EOF
  out=$(run_live "$id" "$gen" "$task_tmp" 3 \
    'Use the shell tool to run sleep 30, then reply exactly TIMEOUT_SHOULD_NOT_COMPLETE. Do nothing else.' 2>&1) \
    || rc=$?
  [ "$rc" -ne 0 ] || fail "real deadline expiry returned success: $out"
  [ "$(classify "$id")" = "unknown codex-timeout" ] \
    || fail "real timeout was not surfaced: $(classify "$id")"
  receipt="$STATE/$id.codex-appserver-result"
  assert_contains "$(cat "$receipt")" "outcome=timeout" "real timeout receipt omitted timeout outcome"
  assert_process_gone "$receipt"
  pass "real app-server deadline recorded timeout and reaped its owned process group"
}

printf '%s\n' "$CODEX_VERSION"
test_real_success
test_real_failed_terminal
test_real_interrupted_terminal
test_real_timeout
printf 'ok - %s live owning-client guard passed all individual controls\n' "$CODEX_VERSION"
