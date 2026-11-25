#!/usr/bin/env bash
# Broker composition through executable stubs, never implementation-byte checks.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP=$(fm_test_tmproot fm-dispatch)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/data/task" "$TMP/home/state/dispatch-receipt"
cp "$ROOT/bin/fm-dispatch.sh" "$ROOT/bin/fm-pr-lib.sh" "$TMP/bin/"
export FM_HOME="$TMP/home" BROKER_LOG="$TMP/log" PROFILE_FILE="$TMP/profile.json"
export RESOLVE_MODE=clear GATE_RC=0 LAUNCH_RC=0
cat > "$TMP/bin/fm-dispatch-resolve.sh" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "$1" = gate ]; then
  printf 'gate\n' >> "$BROKER_LOG"
  exit "$GATE_RC"
fi
jq -cn --args '$ARGS.positional' -- "$@" >> "$BROKER_LOG"
[ "$RESOLVE_MODE" != error ] || exit 7
if [ "$RESOLVE_MODE" = held ]; then
  printf 'dispatch-resolve:\n  status: held\n'
  exit 3
fi
if [ "$RESOLVE_MODE" = pending ]; then
  printf 'dispatch-resolve:\n  status: captain-pick\n  receipt: none - captain must pick\n'
  exit 0
fi
# Resolver owns quota intake, then writes the receipt; the broker must not
# mint either record or call a second intake over the receipt's binding.
printf 'intake\nreceipt\n' >> "$BROKER_LOG"
jq -cn --arg task "${RECEIPT_TASK:-task}" --slurpfile p "$PROFILE_FILE" '{task:$task,profile:$p[0]}' > "$FM_HOME/state/dispatch-receipt/routed.json"
printf 'dispatch-resolve:\n  status: clear\n  profile: do-not-eval-this\n  receipt: routed.json (one launch, valid 900s)\n'
SH
cat > "$TMP/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'spawn\n' >> "$BROKER_LOG"
jq -cn --args '$ARGS.positional' -- "$@" >> "$BROKER_LOG"
exit "$LAUNCH_RC"
SH
cat > "$TMP/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'control\n' >> "$BROKER_LOG"
jq -cn --args '$ARGS.positional' -- "$@" >> "$BROKER_LOG"
exit "$LAUNCH_RC"
SH
cat > "$TMP/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'send\n' >> "$BROKER_LOG"
jq -cn --args '$ARGS.positional' -- "$@" >> "$BROKER_LOG"
SH
cat > "$TMP/bin/fm-promote.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'promote\n' >> "$BROKER_LOG"
jq -cn --args '$ARGS.positional' -- "$@" >> "$BROKER_LOG"
printf 'kind=ship\nproject=/projects/project\nharness=claude\nmodel=opus\neffort=high\naccount=seat\n' > "$FM_HOME/state/task.meta"
printf 'ship instructions with spaces\n' > "$FM_HOME/data/task/ship-instructions.md"
SH
cat > "$TMP/bin/fm-pr-start-template.sh" <<'SH'
#!/usr/bin/env bash
printf 'verify\n' >> "$BROKER_LOG"
exit "${VERIFY_RC:-0}"
SH
cat > "$TMP/bin/fm-admission-queue.sh" <<'SH'
#!/usr/bin/env bash
exec "$QUEUE_REAL" "$@"
SH
export QUEUE_REAL="$ROOT/bin/fm-admission-queue.sh"
chmod +x "$TMP/bin/"*.sh
BROKER="$TMP/bin/fm-dispatch.sh"
printf '# Task\nA written brief\n' > "$FM_HOME/data/task/brief.md"
reset_case() {
  : > "$BROKER_LOG"
  export RESOLVE_MODE=clear GATE_RC=0 LAUNCH_RC=0
  unset RECEIPT_TASK
  printf '{"harness":"claude","model":"opus","effort":"high","account":"seat"}\n' > "$PROFILE_FILE"
  printf 'kind=scout\nproject=/projects/project\nharness=claude\nmodel=opus\neffort=high\naccount=seat\n' > "$FM_HOME/state/task.meta"
  rm -f "$FM_HOME/data/task/ship-instructions.md"
}
run_broker() {
  RC=0
  if [ "${1:-}" = new ]; then
    bash "$BROKER" "$@" --wait > "$TMP/out" 2>&1 || RC=$?
  else
    bash "$BROKER" "$@" > "$TMP/out" 2>&1 || RC=$?
  fi
}
assert_rc() { [ "$RC" -eq "$1" ] || fail "expected exit $1, got $RC: $(<"$TMP/out")"; }
last_args() { tail -n 1 "$BROKER_LOG"; }

reset_case
rm -f "$FM_HOME/state/task.meta"
export RESOLVE_MODE=error FM_ADMISSION_DISPATCH="$BROKER"
bash "$BROKER" new task '/projects/project with spaces' --scout --allow-duplicate 'independent critic' > "$TMP/out"
assert_contains "$(<"$TMP/out")" 'queued: task' 'async submit did not return a durable receipt'
[ ! -s "$BROKER_LOG" ] || fail 'async submit called resolver or launch'
assert_present "$FM_HOME/state/admission-queue/task.start" 'request was not persisted'
# Duplicate requests cannot overwrite arguments, consume quota or start twice.
bash "$BROKER" new task /wrong-project --scout > "$TMP/out"
export RESOLVE_MODE=clear
bash "$QUEUE_REAL" retry > "$TMP/out"
assert_contains "$(<"$TMP/out")" 'admission: started task' 'durable replay did not finish start'
last_args | jq -e '.[1] == "/projects/project with spaces"' >/dev/null || fail 'duplicate replaced saved project'
last_args | jq -e 'index("--allow-duplicate") as $i | $i != null and .[$i + 1] == "independent critic"' >/dev/null || fail 'queued replay lost the explicit ownership override'
assert_absent "$FM_HOME/state/admission-queue/task.start" 'completed request remained queued'
pass 'new returns before resolver and durable replay preserves the original request exactly once'

: > "$BROKER_LOG"
export RESOLVE_MODE=held
bash "$BROKER" new task /projects/project --scout > "$TMP/out"
bash "$QUEUE_REAL" retry > "$TMP/out"
assert_contains "$(<"$TMP/out")" 'resolver held' 'weekly hold lost from async replay'
lines=$(wc -l < "$BROKER_LOG")
bash "$QUEUE_REAL" retry > "$TMP/out"
[ "$(wc -l < "$BROKER_LOG")" -eq "$lines" ] || fail 'weekly hold retried without pacing'
export RESOLVE_MODE=pending
FM_ADMISSION_RESOLVER_RETRY_SECS=0 bash "$QUEUE_REAL" retry > "$TMP/out"
assert_contains "$(bash "$QUEUE_REAL" list)" 'task failed' 'captain pick was silently retried or dropped'
bash "$QUEUE_REAL" drop task
pass 'async weekly holds are paced and captain picks park visibly'

printf 'PR start: review https://github.com/example/project/pull/1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >> "$FM_HOME/data/task/brief.md"
: > "$BROKER_LOG"
export VERIFY_RC=2
run_broker new task /projects/project --scout --merge-review
assert_rc 2
[ "$(<"$BROKER_LOG")" = verify ] || fail 'stale PR head reached resolver or spawn'
unset VERIFY_RC
printf '# Task\nA written brief\n' > "$FM_HOME/data/task/brief.md"
pass 'head-bound templates are reverified before quota intake and launch'

reset_case
run_broker new task '/projects/project with spaces' --mode direct-PR --yolo off --backend tmux
assert_rc 0
last_args | jq -e '. == ["task","/projects/project with spaces","--mode","direct-PR","--yolo","off","--backend","tmux","--harness","claude","--model","opus","--effort","high","--account","seat"]' >/dev/null || fail 'spawn arguments changed'
[ "$(grep -E '^(intake|receipt|gate|spawn)$' "$BROKER_LOG" | tr '\n' ' ')" = 'intake receipt gate spawn ' ] || fail 'resolve/intake/gate/launch ordering'
pass 'new composes resolver-owned intake, receipt, gate and guarded spawn'

reset_case
run_broker new task /projects/project --scout --merge-review
assert_rc 0
last_args | jq -e 'index("--scout") != null and index("--merge-review") != null' >/dev/null || fail 'explicit review marker was not forwarded'
[ "$(grep -E '^(intake|receipt|gate|spawn)$' "$BROKER_LOG" | tr '\n' ' ')" = 'intake receipt gate spawn ' ] || fail 'review bypassed quota intake/receipt/gate'
reset_case
export GATE_RC=3
run_broker new task /projects/project --scout --merge-review
assert_rc 3
! grep -qx spawn "$BROKER_LOG" || fail 'review bypassed receipt gate refusal'
pass 'reserved review marker preserves resolver intake and receipt gates'

for mode in pending error; do
  reset_case
  export RESOLVE_MODE=$mode
  run_broker new task /projects/project --scout
  if [ "$mode" = pending ]; then assert_rc 3; else assert_rc 7; fi
  ! grep -Eq '^(spawn|control|send|intake)$' "$BROKER_LOG" || fail 'non-dispatchable route launched'
done
pass 'pending captain picks and resolver failure never launch'

reset_case
export GATE_RC=3
run_broker new task /projects/project --scout
assert_rc 3
! grep -qx spawn "$BROKER_LOG" || fail 'gate refusal launched'
export GATE_RC=0 LAUNCH_RC=9
run_broker new task /projects/project --scout
assert_rc 9
pass 'guard and launch failures propagate'

for arg in --harness --model=other --account --relaunch --secondmate 'raw launch'; do
  reset_case
  run_broker new task /projects/project "$arg"
  assert_rc 2
  [ ! -s "$BROKER_LOG" ] || fail 'caller profile or raw launch reached resolver'
done
run_broker new ../escape /projects/project
assert_rc 2
pass 'caller-selected profiles, lifecycle bypasses and invalid ids refuse'

reset_case
run_broker new task /projects/project --scout --pick ABCD
assert_rc 0
head -n 1 "$BROKER_LOG" | jq -e '. == ["pick","ABCD"]' >/dev/null || fail 'captain pick not delegated'
export RECEIPT_TASK=another
run_broker new task /projects/project --scout --pick ABCD
assert_rc 2
pass 'captain pick delegates verification and cannot target another task'

reset_case
run_broker new task /projects/project/ --scout --captain-pick
assert_rc 0
head -n 1 "$BROKER_LOG" | jq -e '.[1:] == ["--project","project","--task","task","--captain-pick"]' >/dev/null || fail 'project or captain-pick request lost'
run_broker new task /projects/project --scout --pick ABCD --captain-pick
assert_rc 2
printf '{"harness":"claude","model":"bad\\nvalue","effort":"high","account":"seat"}\n' > "$PROFILE_FILE"
: > "$BROKER_LOG"
run_broker new task /projects/project --scout
assert_rc 2
! grep -qx spawn "$BROKER_LOG" || fail 'malformed receipt launched'
pass 'captain requests delegate and malformed profile data fails closed'

reset_case
printf '{"harness":"codex","model":"","effort":"","account":"seat"}\n' > "$PROFILE_FILE"
run_broker relaunch task --note 'checkpoint with spaces' --priority 4
assert_rc 0
last_args | jq -e '. == ["task","relaunch","--note","checkpoint with spaces","--priority","4","--harness","codex","--model","default","--effort","default","--account","seat"]' >/dev/null || fail 'relaunch did not clear carried axes'
pass 'relaunch uses control with explicit default axes and the progress note'

reset_case
run_broker promote task --mode direct-PR --yolo off
assert_rc 0
[ "$(grep -E '^(promote|intake|receipt|gate|send|control)$' "$BROKER_LOG" | tr '\n' ' ')" = 'promote intake receipt gate send ' ] || fail 'unchanged promotion ordering'
last_args | jq -e '. == ["fm-task","--after-done","promote","ship instructions with spaces"]' >/dev/null || fail 'promotion instructions not sent'
pass 'same-profile promotion routes ship contract and sends through guarded send'

reset_case
# shellcheck disable=SC2016 # Deliberate shell syntax: profile data must stay inert.
printf '{"harness":"pi","model":"provider/model with spaces;$(false)","effort":"high","account":"other"}\n' > "$PROFILE_FILE"
run_broker promote task --mode local-only --yolo off
assert_rc 0
last_args | jq -e --arg note "$FM_HOME/data/task/ship-instructions.md" '. == ["task","relaunch","--harness","pi","--model","provider/model with spaces;$(false)","--effort","high","--account","other","--note-file",$note]' >/dev/null || fail 'changed promotion profile or note corrupted'
! grep -qx send "$BROKER_LOG" || fail 'changed promotion sent to old worker'
pass 'changed-profile promotion relaunches without evaluating profile strings'

reset_case
export RESOLVE_MODE=pending
run_broker promote task --mode direct-PR --yolo off
assert_rc 3
: > "$BROKER_LOG"
export RESOLVE_MODE=clear
run_broker promote task --pick ABCD
assert_rc 0
! grep -qx promote "$BROKER_LOG" || fail 'retry promoted twice'
grep -qx send "$BROKER_LOG" || fail 'retry did not deliver ship contract'
pass 'captain-pick promotion resumes without rewriting the ship contract'

reset_case
export GATE_RC=3
run_broker promote task --mode direct-PR --yolo off
assert_rc 3
! grep -Eq '^(control|send)$' "$BROKER_LOG" || fail 'promotion ignored receipt refusal'
pass 'same-profile promotion does not bypass receipt validation'

reset_case
printf '{"harness":"claude","model":"opus","effort":"high","account":""}\n' > "$PROFILE_FILE"
run_broker relaunch task --note recovery
assert_rc 2
! grep -qx control "$BROKER_LOG" || fail 'unclearable account reached control'
pass 'unrepresentable account clearing refuses before stopping a worker'
