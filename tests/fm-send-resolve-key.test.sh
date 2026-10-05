#!/usr/bin/env bash
# fm-send answerer-closes (--resolve-key) behavior.
#
# A captain decision opened by a keyed needs-decision:/blocked: status line
# historically stayed open forever when the answer kicked off work: the worker's
# next line is working [key=<workstream>], never resolved [key=<decision>].
# fm-send's --resolve-key removes that writer-dependency at its source: the
# ANSWERING firstmate closes the decision in this home's own ledger at answer
# time - for a local target that is ENQUEUE time, because the durable inbox
# write is delivery to the task's record. These tests drive the real fm-send
# executable over stubbed transports and assert closure through the real
# consumer (fm-wake-drain.sh's OPEN DECISIONS section), never through source
# text:
#   1. An answer send closes the open decision, including the answer-starts-work
#      scenario where the worker never writes a matching resolved line.
#   2. A routine steer without the flag never closes anything, and a working:/
#      done: line still cannot clear a captain decision.
#   3. A key that is not open refuses BEFORE anything is sent (mistype safety).
#   4. The close happens at enqueue: a failed doorbell ring still closes the
#      answered key (the record is durably sent), while a failed ENQUEUE - the
#      real local failure - closes nothing and leaves the decision open.
#   5. Flag misuse (--key, empty message, explicit backend target) refuses.
#   6. Reserved keys owned by another subsystem refuse before anything is sent.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SEND="$ROOT/bin/fm-send.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-resolve-key)

# Stub Herdr CLI: logs literal typed text to FM_SEND_LOG and lets the submit path
# reach a clean "empty" verdict from an empty bordered composer.
# FM_FAKE_HERDR_SEND_FAIL=1 makes pane sends fail so the delivery-failure leg can
# assert that a failed send closes nothing.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  fm_test_fake_herdr_send "$fb"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <home> <send-log> <fm-send args...>: run the real fm-send
# with the stubs on PATH against the given home. Guard noise goes to stderr,
# captured per test when the diagnostic matters.
run_send() {
  local fb=$1 home=$2 log=$3; shift 3
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$@" 2>/dev/null
}

setup_home() {  # <name> -> echoes a fresh home dir with an empty state/
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

write_task_fixture() { # <meta-path> <metadata fields...>
  local path=$1 fixture_home task
  fixture_home=${path%/state/*}; task=${path##*/}; task=${task%.meta}
  mkdir -p "$fixture_home/data"
  FM_HOME="$fixture_home" "$ROOT/bin/fm-tasks-axi.sh" add "$task" "$task" --kind ship --start >/dev/null \
    || fail "answer task registration failed"
  fm_write_meta "$@"
}

drain_out() {  # <home>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$DRAIN" 2>/dev/null
}

test_answer_send_closes_open_decision() {
  local dir fb log home rc out
  dir="$TMP_ROOT/closes"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home closes)
  write_task_fixture "$home/state/t1.meta" "window=sess:w1:p-t1" "backend=herdr" "kind=ship"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$home/state/t1.status"
  printf 'working: kept busy on an unrelated stream\n' >> "$home/state/t1.status"

  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "precondition: the buried decision should list as open before the answer"

  run_send "$fb" "$home" "$log" t1 --resolve-key api-shape "go with REST"; rc=$?
  expect_code 0 "$rc" "an answer send with --resolve-key should succeed"
  grep -qF "go with REST" "$home/state/t1.inbox/001.msg" \
    || fail "the answer text should reach the worker's durable inbox record"
  assert_contains "$(cat "$log")" "Firstmate instruction waiting" "the doorbell should be rung for the answer"
  grep -F 'resolved [key=api-shape]: answered: go with REST' "$home/state/t1.status" >/dev/null \
    || fail "fm-send did not append the closing resolved line:"$'\n'"$(cat "$home/state/t1.status")"

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key: the answer send itself closes the open decision"
}

# The answerer's close is this home's own bookkeeping: it must not re-wake the
# session that wrote it, while any other writer's later line on the same task
# still must. Both directions are read through the production seen-signature
# gate the watcher's signal scan consumes (bin/fm-wake-lib.sh).
test_answer_close_is_self_announced() {
  local dir fb log home rc
  dir="$TMP_ROOT/self-announced"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home self-announced)
  write_task_fixture "$home/state/t9.meta" "window=sess:w1:p-t9" "backend=herdr" "kind=ship"
  printf 'needs-decision [key=port-choice]: 8080 or 9090\n' > "$home/state/t9.status"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/t9.status" \
    || fail "could not prime the announced baseline"

  run_send "$fb" "$home" "$log" t9 --resolve-key port-choice "use 9090"; rc=$?
  expect_code 0 "$rc" "the answer send should succeed"
  grep -F 'resolved [key=port-choice]: answered: use 9090' "$home/state/t9.status" >/dev/null \
    || fail "the closing resolved line is missing"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/t9.status" \
    || fail "the answerer's own close was left to re-wake this same home"

  printf 'done: worker finished after the answer\n' >> "$home/state/t9.status"
  if FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/t9.status"; then
    fail "a later worker line after the self-announced close was swallowed"
  fi
  pass "fm-send --resolve-key: the close never re-wakes its own home, later lines still do"
}

# The reported failure behind issue #2109: a worker that put the colon first
# (needs-decision: [key=X] ...) had its key silently folded to "default", so
# the answer's --resolve-key X refused with "no open decision or blocker with
# that key". The stated key must be honored in that position too, end to end
# through the real send.
test_colon_first_key_position_is_answerable() {
  local dir fb log home rc out
  dir="$TMP_ROOT/colon-first"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home colon-first)
  write_task_fixture "$home/state/t8.meta" "window=sess:w1:p-t8" "backend=herdr" "kind=ship"
  printf 'needs-decision: [key=seam-max-bound] cap the seam at 4 or 8\n' > "$home/state/t8.status"

  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=seam-max-bound]' >/dev/null \
    || fail "precondition: the colon-first decision should list as open under its stated key: $out"

  run_send "$fb" "$home" "$log" t8 --resolve-key seam-max-bound "cap it at 4"; rc=$?
  expect_code 0 "$rc" "answering a colon-first stated key should succeed, not refuse as unknown"
  grep -F 'resolved [key=seam-max-bound]: answered: cap it at 4' "$home/state/t8.status" >/dev/null \
    || fail "the closing resolved line is missing:"$'\n'"$(cat "$home/state/t8.status")"

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered colon-first decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key: a colon-first stated key is open under that key and answerable"
}

test_answer_starts_work_never_orphans() {
  local dir fb log home rc out
  dir="$TMP_ROOT/starts-work"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home starts-work)
  write_task_fixture "$home/state/t2.meta" "window=sess:w1:p-t2" "backend=herdr" "kind=ship"
  printf 'needs-decision [key=rollout]: big-bang or phased\n' > "$home/state/t2.status"

  run_send "$fb" "$home" "$log" t2 --resolve-key rollout "phased, gate each region"; rc=$?
  expect_code 0 "$rc" "the rollout answer send should succeed"
  # The forensic scenario: the answer starts a workstream, so the worker's next
  # events use a DIFFERENT key namespace and it never writes
  # resolved [key=rollout] itself.
  printf 'working [key=phased-impl]: building region gates\n' >> "$home/state/t2.status"
  printf 'done [key=phased-impl]: PR up\n' >> "$home/state/t2.status"

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered decision orphaned after the answer started work: $out"
  fi
  pass "fm-send --resolve-key: an answer that starts a workstream leaves no orphaned decision"
}

test_routine_steer_never_closes() {
  local dir fb log home rc out
  dir="$TMP_ROOT/routine"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home routine)
  write_task_fixture "$home/state/t3.meta" "window=sess:w1:p-t3" "backend=herdr" "kind=ship"
  printf 'needs-decision [key=schema]: split or embed\n' > "$home/state/t3.status"

  run_send "$fb" "$home" "$log" t3 "unrelated nudge, keep going"; rc=$?
  expect_code 0 "$rc" "a routine steer should still succeed"
  printf 'working: resumed\n' >> "$home/state/t3.status"
  printf 'done: unrelated milestone\n' >> "$home/state/t3.status"

  if grep -F 'resolved' "$home/state/t3.status" >/dev/null; then
    fail "a routine steer wrote a resolved line: $(cat "$home/state/t3.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=schema]' >/dev/null \
    || fail "a routine steer (or later working/done lines) cleared an unanswered captain decision: $out"
  pass "fm-send: a send without --resolve-key never closes a decision, and working/done still cannot"
}

test_not_open_key_refuses_before_send() {
  local dir fb log home err rc out
  dir="$TMP_ROOT/not-open"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home not-open)
  write_task_fixture "$home/state/t4.meta" "window=sess:w1:p-t4" "backend=herdr" "kind=ship"
  printf 'needs-decision [key=real-key]: choose\n' > "$home/state/t4.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t4 --resolve-key mistyped "the answer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a not-open key should refuse"
  assert_contains "$(cat "$err")" "--resolve-key 'mistyped'" "the refusal should name the bad key"
  assert_contains "$(cat "$err")" "nothing was sent" "the refusal should state nothing was sent"
  [ ! -s "$log" ] || fail "a refused answer still typed text: $(cat "$log")"
  [ ! -d "$home/state/t4.inbox" ] || fail "a refused answer still enqueued an inbox record"
  if grep -F 'resolved' "$home/state/t4.status" >/dev/null; then
    fail "a refused answer still closed something: $(cat "$home/state/t4.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=real-key]' >/dev/null \
    || fail "the real decision disappeared after a refused answer: $out"
  pass "fm-send --resolve-key: a key that is not open refuses loudly before anything is sent"
}

# The close is an enqueue-time fact: the durable record IS the delivery, so a
# failed doorbell keystroke must not reopen the split-brain where the close
# waited on an unconfirmable submit.
test_failed_ring_still_closes_at_enqueue() {
  local dir fb log home rc out
  dir="$TMP_ROOT/ring-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home ring-fail)
  write_task_fixture "$home/state/t5.meta" "window=sess:w1:p-t5" "backend=herdr" "kind=ship"
  printf 'blocked [key=creds]: need the deploy token\n' > "$home/state/t5.status"

  : > "$log"
  env PATH="$fb:$PATH" FM_FAKE_HERDR_SEND_FAIL=1 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t5 --resolve-key creds "token is in the vault now" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a failed doorbell must not fail the durably enqueued answer"
  grep -qF 'token is in the vault now' "$home/state/t5.inbox/001.msg" \
    || fail "the answer must be durably recorded despite the failed ring"
  grep -F 'resolved [key=creds]' "$home/state/t5.status" >/dev/null \
    || fail "the enqueued answer must close the decision at answer time: $(cat "$home/state/t5.status")"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F '[key=creds]' >/dev/null; then
    fail "the answered blocker still lists as open after an enqueue-time close: $out"
  fi
  pass "fm-send --resolve-key: the close happens at enqueue, surviving a failed doorbell"
}

# The real local failure - an unwritable record - is the case that must never
# close anything: nothing durable was sent.
test_failed_enqueue_does_not_close() {
  local dir fb log home rc out
  dir="$TMP_ROOT/enqueue-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home enqueue-fail)
  write_task_fixture "$home/state/t5.meta" "window=sess:w1:p-t5" "backend=herdr" "kind=ship"
  printf 'blocked [key=creds]: need the deploy token\n' > "$home/state/t5.status"
  : > "$home/state/t5.inbox"   # a FILE where the inbox dir must go

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t5 --resolve-key creds "token is in the vault now" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "a failed enqueue should exit nonzero"
  if grep -F 'resolved' "$home/state/t5.status" >/dev/null; then
    fail "a failed enqueue still closed the decision: $(cat "$home/state/t5.status")"
  fi
  [ ! -s "$log" ] || fail "a failed enqueue still typed something: $(cat "$log")"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=creds]' >/dev/null \
    || fail "the blocker vanished after a failed enqueue: $out"
  pass "fm-send --resolve-key: a failed enqueue never closes the decision"
}

test_multiple_keys_close_together() {
  local dir fb log home rc out
  dir="$TMP_ROOT/multi"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home multi)
  write_task_fixture "$home/state/t6.meta" "window=sess:w1:p-t6" "backend=herdr" "kind=ship"
  {
    printf 'needs-decision [key=k1]: first\n'
    printf 'blocked [key=k2]: second\n'
    printf 'needs-decision [key=k3]: third, unanswered\n'
  } > "$home/state/t6.status"

  run_send "$fb" "$home" "$log" t6 --resolve-key k1 --resolve-key k2 \
    "one answer covering both"; rc=$?
  expect_code 0 "$rc" "an answer resolving two keys should succeed"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=k3]' >/dev/null \
    || fail "the unanswered third decision must stay open: $out"
  if printf '%s' "$out" | grep -E '\[key=k1\]|\[key=k2\]' >/dev/null; then
    fail "an answered key is still open after a multi-key answer: $out"
  fi
  pass "fm-send --resolve-key: one answer closes each named key and only those"
}

test_flag_misuse_refuses() {
  local dir fb log home err rc
  dir="$TMP_ROOT/misuse"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home misuse)
  write_task_fixture "$home/state/t7.meta" "window=sess:w1:p-t7" "backend=herdr" "kind=ship"
  printf 'needs-decision [key=k]: choose\n' > "$home/state/t7.status"

  # --resolve-key with --key (both orders) is refused: an answer is text.
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t7 --resolve-key k --key Enter >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--resolve-key before --key should refuse"
  assert_contains "$(cat "$err")" "cannot accompany --key" "the --key refusal should be explicit"
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t7 --key Enter --resolve-key k >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--resolve-key after --key should refuse instead of being silently dropped"
  assert_contains "$(cat "$err")" "cannot accompany --key" "the trailing --resolve-key refusal should be explicit"

  # An empty answer message is refused.
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t7 --resolve-key k >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an empty answer message should refuse"
  assert_contains "$(cat "$err")" "nonempty answer message" "the empty-message refusal should be explicit"

  # An explicit backend target has no task ledger in this home.
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:w1:p-elsewhere --resolve-key k "answer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an explicit backend target should refuse --resolve-key"
  assert_contains "$(cat "$err")" "no decision ledger" "the explicit-target refusal should be explicit"

  # A malformed key is refused before anything else.
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t7 --resolve-key 'bad key!' "answer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed key should refuse"
  assert_contains "$(cat "$err")" "not a valid decision key" "the malformed-key refusal should be explicit"

  [ ! -s "$log" ] || fail "a refused misuse still typed text: $(cat "$log")"
  if grep -F 'resolved' "$home/state/t7.status" >/dev/null; then
    fail "a refused misuse still closed something: $(cat "$home/state/t7.status")"
  fi
  pass "fm-send --resolve-key: --key, empty message, explicit targets, and malformed keys refuse loudly"
}

test_long_decision_key_refuses_before_send() {
  local dir fb log home err key rc out
  dir="$TMP_ROOT/long-key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home long-key)
  key=$(printf 'k%.0s' {1..230})
  write_task_fixture "$home/state/t1.meta" "window=sess:w1:p-t1" "backend=herdr" "kind=ship"
  printf 'needs-decision [key=%s]: choose safely\n' "$key" > "$home/state/t1.status"

  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t1 --resolve-key "$key" "answer the long-key decision" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a key whose close prefix cannot fit should refuse before sending"
  assert_contains "$(cat "$err")" "decision key of length 230" "the refusal should report the key-length cause"
  assert_contains "$(cat "$err")" "220-character status-line cap" "the refusal should report the truncation limit"
  assert_contains "$(cat "$err")" "nothing was sent" "the refusal should state nothing was sent"
  [ ! -s "$log" ] || fail "a refused long-key close still typed text: $(cat "$log")"
  [ ! -d "$home/state/t1.inbox" ] || fail "a refused long-key close still enqueued an inbox record"
  if grep -F 'resolved' "$home/state/t1.status" >/dev/null; then
    fail "a refused long-key close still wrote a malformed resolution: $(cat "$home/state/t1.status")"
  fi
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null \
    || fail "the long-key decision disappeared after a refused close: $out"
  pass "fm-send --resolve-key: an overlong decision key refuses before sending"
}

test_failed_close_recovery_command_is_shell_safe() {
  local dir fb log home err marker answer rc diagnostic manual out
  dir="$TMP_ROOT/manual-close"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home "manual close")
  marker="$dir/injected"
  answer="ok'; touch $marker; echo '"
  write_task_fixture "$home/state/t1.meta" "window=sess:w1:p-t1" "backend=herdr" "kind=ship"
  printf 'needs-decision [key=quote-safety]: choose safely\n' > "$home/state/t1.status"
  chmod 0400 "$home/state/t1.status"

  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t1 --resolve-key quote-safety "$answer" >/dev/null 2>"$err"; rc=$?
  chmod 0600 "$home/state/t1.status"
  [ "$rc" -ne 0 ] || fail "a delivered answer with a failed close append should fail loudly"
  diagnostic=$(cat "$err")
  assert_contains "$diagnostic" "Close it manually with:" "the close failure should provide recovery guidance"
  manual=${diagnostic#*Close it manually with: }
  manual=${manual% - do not resend the answer.}
  bash -c "$manual" || fail "the generated manual close command should execute successfully"
  [ ! -e "$marker" ] || fail "the generated manual close command executed answer text as shell code"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the generated manual close command did not close the decision: $out"
  fi
  pass "fm-send --resolve-key: failed-close recovery commands safely quote operator text and paths"
}

test_answer_send_closes_open_decision
test_answer_close_is_self_announced
test_colon_first_key_position_is_answerable
test_answer_starts_work_never_orphans
test_routine_steer_never_closes
test_not_open_key_refuses_before_send
test_failed_ring_still_closes_at_enqueue
test_failed_enqueue_does_not_close
test_multiple_keys_close_together
test_flag_misuse_refuses
test_long_decision_key_refuses_before_send
test_failed_close_recovery_command_is_shell_safe
