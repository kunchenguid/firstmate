#!/usr/bin/env bash
# Portable process/protocol controls for the owning Codex app-server client.
# The credentialed companion drives these same client paths against the real
# installed app-server. This fixture keeps failure, process-group, and bounded
# log paths deterministic in ordinary CI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-appserver-client)
STATE="$TMP_ROOT/state"
WORK="$TMP_ROOT/work"
FAKEBIN="$TMP_ROOT/fakebin"
SERVER="$TMP_ROOT/fake-appserver.mjs"
CLIENT="$ROOT/bin/fm-codex-appserver-client.mjs"
mkdir -p "$STATE" "$WORK" "$FAKEBIN"

cleanup() {
  local suffix
  for suffix in success exit-mismatch terminal-missing interrupt timeout log-failure delayed-evidence; do
    rm -rf -- "/tmp/fm-codex-appserver-test-$suffix"
  done
  fm_test_cleanup
}
trap cleanup EXIT

cat > "$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version)
    printf 'codex-cli 0.147.0\n'
    ;;
  app-server)
    exec node "$FM_FAKE_APPSERVER"
    ;;
  *)
    printf 'unexpected fake codex arguments: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$FAKEBIN/codex"

cat > "$SERVER" <<'NODE'
#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import readline from "node:readline";

const mode = process.env.FM_FAKE_SERVER_MODE || "success";
const marker = process.env.FM_FAKE_DESCENDANT_MARKER || "";
const busyRecord = process.env.FM_FAKE_BUSY_RECORD || "";
const stderrLog = process.env.FM_FAKE_STDERR_LOG || "";
const threadId = "thread-fixture-1";
const turnId = "turn-fixture-1";
const write = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);
let exitCode = 0;

if (mode === "timeout") {
  process.on("SIGTERM", () => {});
}

const input = readline.createInterface({ input: process.stdin });
input.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    write({ id: message.id, result: { userAgent: "fixture" } });
    return;
  }
  if (message.method === "initialized") return;
  if (message.method === "thread/start" || message.method === "thread/resume") {
    write({ id: message.id, result: { thread: { id: threadId } } });
    return;
  }
  if (message.method === "turn/start") {
    write({ id: message.id, result: { turn: { id: turnId, status: "inProgress", items: [] } } });
    if (mode === "log-failure") {
      renameSync(stderrLog, `${stderrLog}.removed`);
      mkdirSync(stderrLog);
      process.stderr.write("trigger bounded log failure\n");
      return;
    }
    if (mode === "delayed-evidence") {
      setTimeout(() => {
        write({ method: "turn/started", params: { turn: { id: turnId, status: "inProgress", items: [] } } });
        write({ method: "thread/status/changed", params: { threadId, status: { type: "active" } } });
        setTimeout(() => {
          writeFileSync(marker, readFileSync(busyRecord));
          write({ method: "turn/completed", params: { turn: { id: turnId, status: "completed", error: null } } });
          write({ method: "thread/status/changed", params: { threadId, status: { type: "idle" } } });
        }, 100);
      }, 1100);
      return;
    }
    write({ method: "turn/started", params: { turn: { id: turnId, status: "inProgress", items: [] } } });
    write({ method: "thread/status/changed", params: { threadId, status: { type: "active" } } });
    if (mode === "success" || mode === "exit-mismatch") {
      process.stderr.write(`${"x".repeat(10000)}LOG_END\n`);
      write({ method: "item/agentMessage/delta", params: { itemId: "item-1", delta: "FIXTURE_DONE" } });
      setTimeout(() => {
        write({ method: "turn/completed", params: { turn: { id: turnId, status: "completed", error: null } } });
        write({ method: "thread/status/changed", params: { threadId, status: { type: "idle" } } });
        if (mode === "exit-mismatch") exitCode = 9;
      }, 30);
      return;
    }
    if (mode === "terminal-missing") {
      setTimeout(() => process.exit(0), 30);
      return;
    }
    if (mode === "timeout") {
      spawn(process.execPath, [
        "-e",
        `const fs=require("fs");process.on("SIGTERM",()=>{});setTimeout(()=>fs.writeFileSync(${JSON.stringify(marker)},"survived"),3000)`,
      ], { stdio: "ignore" });
    }
    return;
  }
  if (message.method === "turn/interrupt") {
    write({ id: message.id, result: {} });
    if (mode === "interrupt") {
      write({ method: "turn/completed", params: { turn: { id: turnId, status: "interrupted", error: null } } });
      write({ method: "thread/status/changed", params: { threadId, status: { type: "idle" } } });
    }
    return;
  }
  if (message.method === "turn/steer") {
    write({ id: message.id, result: { turnId } });
  }
});
input.on("close", () => setTimeout(() => process.exit(exitCode), 5));
NODE
chmod +x "$SERVER"

new_case() {  # <suffix> -> prints id gen tasktmp
  local suffix=$1 id gen task_tmp
  id="codex-appserver-test-$suffix"
  task_tmp="/tmp/fm-$id"
  rm -rf -- "$task_tmp"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$id" \
    --state unknown --source codex-appserver --event launch-pending) || fail "could not arm $id"
  printf '%s\t%s\t%s\n' "$id" "$gen" "$task_tmp"
}

run_case() {  # <mode> <id> <gen> <tasktmp> [stdin-producer]
  local mode=$1 id=$2 gen=$3 task_tmp=$4 producer=${5:-}
  local -a command
  command=("$CLIENT" --state-dir "$STATE" --task-id "$id" --generation "$gen" \
    --cwd "$WORK" --task-tmp "$task_tmp" --turn-ended "$STATE/$id.turn-ended" \
    --deadline-secs "${FM_TEST_DEADLINE_SECS:-1}" --prompt "fixture prompt" --one-shot)
  if [ -n "$producer" ]; then
    eval "$producer" | env PATH="$FAKEBIN:$PATH" FM_CODEX_BIN="$FAKEBIN/codex" \
      FM_FAKE_APPSERVER="$SERVER" FM_FAKE_SERVER_MODE="$mode" \
      FM_FAKE_DESCENDANT_MARKER="$task_tmp/descendant-survived" \
      FM_FAKE_BUSY_RECORD="$STATE/$id.busy-state" \
      FM_FAKE_STDERR_LOG="$task_tmp/codex-appserver.stderr.log" \
      FM_CODEX_APPSERVER_STDERR_MAX_BYTES=4096 \
      FM_CODEX_APPSERVER_STARTUP_TIMEOUT_MS=1000 \
      FM_CODEX_APPSERVER_INTERRUPT_GRACE_MS=100 \
      FM_CODEX_APPSERVER_TERM_GRACE_MS=100 "${command[@]}"
  else
    env PATH="$FAKEBIN:$PATH" FM_CODEX_BIN="$FAKEBIN/codex" \
      FM_FAKE_APPSERVER="$SERVER" FM_FAKE_SERVER_MODE="$mode" \
      FM_FAKE_DESCENDANT_MARKER="$task_tmp/descendant-survived" \
      FM_FAKE_BUSY_RECORD="$STATE/$id.busy-state" \
      FM_FAKE_STDERR_LOG="$task_tmp/codex-appserver.stderr.log" \
      FM_CODEX_APPSERVER_STDERR_MAX_BYTES=4096 \
      FM_CODEX_APPSERVER_STARTUP_TIMEOUT_MS=1000 \
      FM_CODEX_APPSERVER_INTERRUPT_GRACE_MS=100 \
      FM_CODEX_APPSERVER_TERM_GRACE_MS=100 "${command[@]}" < /dev/null
  fi
}

classify() {  # <id>
  PATH="$FAKEBIN:$PATH" fm_busy_classify tmux fixture codex "$1" "$STATE"
}

test_terminal_and_clean_exit_are_joint_success() {
  local id gen task_tmp out size
  IFS=$'\t' read -r id gen task_tmp <<EOF
$(new_case success)
EOF
  out=$(run_case success "$id" "$gen" "$task_tmp") || fail "successful protocol case exited nonzero: $out"
  [ "$(classify "$id")" = "idle codex-appserver" ] \
    || fail "terminal plus clean child exit did not classify idle: $(classify "$id")"
  assert_contains "$(cat "$STATE/$id.codex-appserver-result")" "outcome=success" \
    "successful receipt omitted the joint outcome"
  size=$(wc -c < "$task_tmp/codex-appserver.stderr.log" | tr -d ' ')
  [ "$size" -le 4096 ] || fail "bounded stderr log grew to $size bytes"
  assert_contains "$(tail -c 32 "$task_tmp/codex-appserver.stderr.log")" "LOG_END" \
    "bounded stderr log did not retain its newest evidence"
  pass "matching terminal plus clean child exit publishes success and bounds stderr"
}

test_terminal_without_clean_exit_refuses_success() {
  local id gen task_tmp out rc=0
  IFS=$'\t' read -r id gen task_tmp <<EOF
$(new_case exit-mismatch)
EOF
  out=$(run_case exit-mismatch "$id" "$gen" "$task_tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "completed event plus exit 9 falsely returned success: $out"
  [ "$(classify "$id")" = "unknown codex-process-error" ] \
    || fail "process mismatch was not surfaced concretely: $(classify "$id")"
  pass "a completed event cannot override a disagreeing process result"
}

test_clean_exit_without_terminal_refuses_success() {
  local id gen task_tmp out rc=0
  IFS=$'\t' read -r id gen task_tmp <<EOF
$(new_case terminal-missing)
EOF
  out=$(run_case terminal-missing "$id" "$gen" "$task_tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "clean exit without terminal falsely returned success: $out"
  [ "$(classify "$id")" = "unknown codex-terminal-missing" ] \
    || fail "missing terminal was not surfaced concretely: $(classify "$id")"
  pass "a clean process exit cannot replace the matching terminal event"
}

test_manual_interrupt_requires_interrupted_terminal_and_exit() {
  local id gen task_tmp out rc=0
  IFS=$'\t' read -r id gen task_tmp <<EOF
$(new_case interrupt)
EOF
  out=$(run_case interrupt "$id" "$gen" "$task_tmp" "sleep 0.2; printf '\\033'" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "interrupted turn returned success: $out"
  [ "$(classify "$id")" = "unknown codex-turn-interrupted" ] \
    || fail "interrupted terminal was not surfaced concretely: $(classify "$id")"
  pass "manual interruption records the real interrupted terminal after child exit"
}

test_timeout_kills_only_the_owned_process_group() {
  local id gen task_tmp out rc=0 child_pid
  IFS=$'\t' read -r id gen task_tmp <<EOF
$(new_case timeout)
EOF
  out=$(run_case timeout "$id" "$gen" "$task_tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "deadline expiry returned success: $out"
  [ "$(classify "$id")" = "unknown codex-timeout" ] \
    || fail "timeout was not surfaced concretely: $(classify "$id")"
  assert_contains "$(cat "$STATE/$id.codex-appserver-result")" "outcome=timeout" \
    "timeout receipt omitted its failure outcome"
  child_pid=$(sed -n 's/.* child_pid=\([0-9][0-9]*\) .*/\1/p' "$STATE/$id.codex-appserver-result")
  [ -n "$child_pid" ] || fail "timeout receipt omitted the owned child PID"
  if kill -0 "$child_pid" 2>/dev/null; then
    fail "owned app-server PID $child_pid survived timeout escalation"
  fi
  sleep 3.1
  assert_absent "$task_tmp/descendant-survived" \
    "a descendant escaped the timeout's exact owned process-group kill"
  pass "deadline expiry records timeout and reaps the exact owned process group"
}

test_bounded_log_failure_publishes_unknown_and_reaps_group() {
  local id gen task_tmp out rc=0 child_pid
  IFS=$'\t' read -r id gen task_tmp <<EOF
$(new_case log-failure)
EOF
  out=$(run_case log-failure "$id" "$gen" "$task_tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "bounded log failure returned success: $out"
  [ "$(classify "$id")" = "unknown codex-protocol-error" ] \
    || fail "bounded log failure was not surfaced concretely: $(classify "$id")"
  child_pid=$(sed -n 's/.* child_pid=\([0-9][0-9]*\) .*/\1/p' "$STATE/$id.codex-appserver-result")
  [ -n "$child_pid" ] || fail "bounded log failure receipt omitted the owned child PID"
  if kill -0 "$child_pid" 2>/dev/null; then
    fail "owned app-server PID $child_pid survived bounded log failure escalation"
  fi
  pass "bounded log failures publish unknown and reap the owned process group"
}

test_delayed_evidence_preserves_absolute_deadline() {
  local id gen task_tmp out observed_deadline receipt_deadline
  IFS=$'\t' read -r id gen task_tmp <<EOF
$(new_case delayed-evidence)
EOF
  out=$(FM_TEST_DEADLINE_SECS=3 run_case delayed-evidence "$id" "$gen" "$task_tmp") \
    || fail "delayed evidence case exited nonzero: $out"
  observed_deadline=$(sed -n 's/.* deadline=\([0-9][0-9]*\)$/\1/p' "$task_tmp/descendant-survived")
  receipt_deadline=$(sed -n 's/.* deadline=\([0-9][0-9]*\) .*/\1/p' "$STATE/$id.codex-appserver-result")
  [ -n "$observed_deadline" ] && [ "$observed_deadline" = "$receipt_deadline" ] \
    || fail "delayed evidence rebased deadline $observed_deadline away from authoritative $receipt_deadline"
  pass "delayed active evidence preserves the turn's absolute deadline"
}

test_terminal_and_clean_exit_are_joint_success
test_terminal_without_clean_exit_refuses_success
test_clean_exit_without_terminal_refuses_success
test_manual_interrupt_requires_interrupted_terminal_and_exit
test_timeout_kills_only_the_owned_process_group
test_bounded_log_failure_publishes_unknown_and_reaps_group
test_delayed_evidence_preserves_absolute_deadline

echo "all fm-codex-appserver-client tests passed"
