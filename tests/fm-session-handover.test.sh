#!/usr/bin/env bash
# Behavior tests for the captain-invoked session handover
# (docs/session-handover.md).
#
# Subjects:
#   bin/fm-handover.sh  - prepare, verify, release, consume, and above all
#                         REFUSE an incomplete handover.
#   bin/fm-lock.sh      - release the helm this session holds, and the captain's
#                         clear --pid override for the one it does not.
#
# Nothing here measures a session. The handover starts when the captain asks for
# one, so these tests drive it the same way: by running the command.
#
# All hermetic over temp dirs: no real agent session, no network, no forge call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-handover)
fm_git_identity fmtest fmtest@example.invalid

BG_PIDS=()
cleanup_bg() {
  local p
  for p in "${BG_PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  fm_test_cleanup
}
trap cleanup_bg EXIT

# --- fixtures ----------------------------------------------------------------

# A primary-shaped home: plain (non-worktree) git repo, AGENTS.md, bin/, state/,
# data/ - everything the shared primary scope requires, with the real scripts
# still running from this repo's bin via FM_ROOT_OVERRIDE.
make_home() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/data"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  printf '# Backlog\n\n## In flight\n' > "$dir/data/backlog.md"
  printf 'Report format: one line, no mechanics.\n' > "$dir/data/captain.md"
  printf '%s\n' "$dir"
}

add_task() {
  local home=$1 id=$2
  fm_write_meta "$home/state/$id.meta" "window=fm:$id" "worktree=$home/wt-$id" "project=alpha"
  printf -- '- [ ] %s - a task (repo: alpha) (kind: ship)\n' "$id" >> "$home/data/backlog.md"
}

# make_fake_ps <fakebin> <harness-pid>: report <harness-pid> as a live claude and
# every other queried pid as a shell whose parent is <harness-pid>, so an ancestry
# walk from any test subprocess resolves to <harness-pid>. The controlling
# terminal comes from <fakebin>/.tty-<pid> when present, defaulting to none.
make_fake_ps() {
  local fakebin=$1 harness_pid=$2
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
pid=""
prev=""
for arg in "\$@"; do
  [ "\$prev" = "-p" ] && pid="\$arg"
  prev="\$arg"
done
case "\$*" in
  *"tty="*)
    if [ -f "$fakebin/.tty-\$pid" ]; then cat "$fakebin/.tty-\$pid"; else printf '??\n'; fi
    exit 0
    ;;
  *"comm="*)
    if [ "\$pid" = "$harness_pid" ]; then printf '/usr/local/bin/claude\n'; else printf '/bin/zsh\n'; fi
    exit 0
    ;;
  *"args="*)
    if [ "\$pid" = "$harness_pid" ]; then printf 'claude\n'; else printf 'zsh\n'; fi
    exit 0
    ;;
  *"ppid="*)
    if [ "\$pid" = "$harness_pid" ]; then printf '1\n'; else printf '%s\n' "$harness_pid"; fi
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

# start_holder: a real live process to stand in for a harness, so kill -0 checks
# see a genuine pid without any real agent running. It sets HOLDER_PID rather
# than printing: a command substitution would wait on the background process's
# inherited stdout and hang the suite.
start_holder() {
  sleep 300 >/dev/null 2>&1 &
  HOLDER_PID=$!
  BG_PIDS+=("$HOLDER_PID")
}

# hold_helm <home> <fakebin>: make this test process look like the session
# holding the home's helm, which prepare, release, and consume all require. The
# fake ps resolves any ancestry walk to HOLDER_PID, and state/.lock records it.
hold_helm() {
  local home=$1 fakebin=$2
  start_holder
  make_fake_ps "$fakebin" "$HOLDER_PID"
  printf '%s\n' "$HOLDER_PID" > "$home/state/.lock"
}

# --- the handover record: pointers, not assertions ---------------------------

test_prepare_refuses_an_unaccounted_worker() {
  local home fakebin out status
  home=$(make_home "$TMP_ROOT/prep-refuse")
  fakebin=$(fm_fakebin "$TMP_ROOT/prep-refuse")
  hold_helm "$home" "$fakebin"
  add_task "$home" alpha-task
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" prepare --next "merge the open PR" 2>&1); status=$?
  expect_code 1 "$status" "prepare must refuse while a live worker has no note"
  assert_contains "$out" "alpha-task" "the refusal must name the unaccounted worker"
  assert_contains "$out" "mid-way through" "the refusal must say what is missing"
  assert_absent "$home/data/handover.md" "a refused prepare must not leave a record behind"
  pass "fm-handover prepare: refuses while any live worker is unaccounted for"
}

test_prepared_record_is_advisory_and_carries_the_unrecorded_facts() {
  local home fakebin out record
  home=$(make_home "$TMP_ROOT/prep-record")
  fakebin=$(fm_fakebin "$TMP_ROOT/prep-record")
  hold_helm "$home" "$fakebin"
  add_task "$home" alpha-task
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" prepare \
    --next "merge the open PR once its checks pass" \
    --worker alpha-task="halfway through the second review round" 2>&1) \
    || fail "prepare must succeed once every worker is accounted for: $out"
  record="$home/data/handover.md"
  assert_present "$record" "prepare must write the durable record"
  assert_grep "ADVISORY" "$record" "the record must say it is advisory, not authoritative"
  assert_grep "records below win" "$record" "the record must say durable records win on conflict"
  assert_grep "Next step: merge the open PR once its checks pass" "$record" "the record must carry the concrete next step"
  assert_grep "- worker alpha-task: halfway through the second review round" "$record" \
    "the record must carry what each worker is mid-way through"
  assert_grep "- record data/backlog.md" "$record" "the record must point at the durable queue"
  assert_grep "- record data/captain.md" "$record" "the record must point at the captain's own rules"
  assert_grep "fm-session-start.sh" "$record" "the record must send the replacement to fresh fleet state"
  # The record must live in the home, never in the OS temp dir: a temp clone
  # vanished here once and read as data loss. The whole fixture is itself under a
  # temp root, so the proof is a canary TMPDIR that must stay empty rather than a
  # pattern match on the record's path.
  local canary
  canary="$TMP_ROOT/prep-record-tmpdir"
  mkdir -p "$canary"
  TMPDIR="$canary" PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" prepare \
    --next "merge the open PR once its checks pass" \
    --worker alpha-task="halfway through the second review round" >/dev/null 2>&1 \
    || fail "prepare must still succeed with TMPDIR redirected"
  [ -z "$(find "$canary" -mindepth 1 2>/dev/null)" ] \
    || fail "the record must never live in a temp directory: prepare wrote into $canary"
  assert_grep "prepared=" "$home/state/.handover" "prepare must record that a handover is prepared"
  pass "fm-handover prepare: writes an advisory, durable record carrying only the unrecorded facts"
}

test_check_refuses_when_a_pointed_at_record_is_sabotaged() {
  local home fakebin out status
  home=$(make_home "$TMP_ROOT/check-sabotage")
  fakebin=$(fm_fakebin "$TMP_ROOT/check-sabotage")
  hold_helm "$home" "$fakebin"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" prepare --next "keep going" >/dev/null 2>&1 \
    || fail "prepare must succeed with no live workers"
  : > "$home/data/captain.md"
  out=$(FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" check 2>&1); status=$?
  expect_code 1 "$status" "an emptied pointer target must fail the check"
  assert_contains "$out" "data/captain.md" "the refusal must name the record that went missing"
  assert_contains "$out" "empty" "the refusal must say what is wrong with it"
  rm -f "$home/data/captain.md"
  out=$(FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" check 2>&1); status=$?
  expect_code 1 "$status" "a deleted pointer target must fail the check"
  assert_contains "$out" "does not exist" "the refusal must distinguish a deleted record from an empty one"
  pass "fm-handover check: refuses when a record the handover points at is emptied or deleted"
}

test_check_refuses_a_worker_with_no_durable_record() {
  local home fakebin out status
  home=$(make_home "$TMP_ROOT/check-orphan")
  fakebin=$(fm_fakebin "$TMP_ROOT/check-orphan")
  hold_helm "$home" "$fakebin"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" prepare --next "keep going" >/dev/null 2>&1
  # A worker that appeared after the record was written, with no backlog item.
  fm_write_meta "$home/state/ghost-task.meta" "window=fm:ghost-task" "project=alpha"
  out=$(FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" check 2>&1); status=$?
  expect_code 1 "$status" "a live worker with no durable record must fail the check"
  assert_contains "$out" "ghost-task" "the refusal must name the worker"
  assert_contains "$out" "no backlog item" "the refusal must say its thread is not durably recorded"
  pass "fm-handover check: refuses a live worker whose thread no durable record backs"
}

test_release_refuses_and_keeps_the_helm() {
  local home fakebin holder out status
  home=$(make_home "$TMP_ROOT/release-refuse")
  fakebin=$(fm_fakebin "$TMP_ROOT/release-refuse")
  start_holder; holder=$HOLDER_PID
  make_fake_ps "$fakebin" "$holder"
  printf '%s\n' "$holder" > "$home/state/.lock"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" prepare --next "keep going" >/dev/null 2>&1
  rm -f "$home/data/backlog.md"
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" release 2>&1); status=$?
  expect_code 1 "$status" "release must refuse an incomplete handover"
  assert_contains "$out" "REFUSING" "the refusal must be unmistakable"
  assert_contains "$out" "data/backlog.md" "the refusal must name exactly what is missing"
  assert_contains "$out" "nothing was discarded" "the refusal must say nothing was lost"
  assert_present "$home/state/.lock" "a refused release must leave the helm held"
  pass "fm-handover release: refuses an incomplete handover and keeps the helm"
}

test_release_hands_over_and_preserves_queued_events() {
  local home fakebin holder out
  home=$(make_home "$TMP_ROOT/release-ok")
  fakebin=$(fm_fakebin "$TMP_ROOT/release-ok")
  start_holder; holder=$HOLDER_PID
  make_fake_ps "$fakebin" "$holder"
  printf '%s\n' "$holder" > "$home/state/.lock"
  printf '111\t1\tsignal\talpha-task\tdone\n222\t2\tcheck\tbeta\tmerged\n' > "$home/state/.wake-queue"
  add_task "$home" alpha-task
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" prepare \
    --next "merge the open PR" --worker alpha-task="mid-review" >/dev/null 2>&1
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" release 2>&1) \
    || fail "release must succeed once the handover is complete: $out"
  assert_contains "$out" "handover released" "release must confirm the handover landed"
  assert_contains "$out" "queued notifications waiting for the replacement: 2" \
    "release must report the queued events the replacement will find"
  assert_contains "$out" "read-only" "release must tell the outgoing session it is now read-only"
  assert_absent "$home/state/.lock" "release must free the helm for the replacement"
  assert_grep "signal" "$home/state/.wake-queue" "release must never drain the durable wake queue"
  assert_grep "released=" "$home/state/.handover" "release must record that the handover was released"
  pass "fm-handover release: frees the helm, keeps queued events, and reports the gap"
}

test_consume_refuses_without_a_released_handover_and_names_records_after() {
  local home fakebin holder out status
  home=$(make_home "$TMP_ROOT/consume")
  fakebin=$(fm_fakebin "$TMP_ROOT/consume")
  hold_helm "$home" "$fakebin"; holder=$HOLDER_PID
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" consume 2>&1); status=$?
  expect_code 1 "$status" "consume must refuse when no handover was released"
  assert_contains "$out" "no released handover" "the refusal must name what is missing, not the helm"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" prepare --next "keep going" >/dev/null 2>&1
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" release >/dev/null 2>&1 \
    || fail "release must succeed for the consume case"
  # release freed the helm, so the replacement takes it before picking the
  # handover up - the same order a real session start follows.
  printf '%s\n' "$holder" > "$home/state/.lock"
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" consume 2>&1) \
    || fail "consume must succeed on a released handover: $out"
  assert_contains "$out" "data/backlog.md" "consume must name the records the replacement was expected to read"
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" consume 2>&1); status=$?
  expect_code 1 "$status" "a handover already picked up must not be picked up twice"
  pass "fm-handover consume: refuses without a release, then names the records consulted"
}

# A session refused the helm is shown the handover and must not be able to move
# it: a consume from the wrong window leaves the session that actually takes the
# helm told nothing is waiting, and a prepare from there replaces the outgoing
# holder's record with one composed by a session that has no authority.
test_a_session_without_the_helm_can_neither_prepare_nor_consume() {
  local home fakebin holder other out status before
  home=$(make_home "$TMP_ROOT/readonly-lifecycle")
  fakebin=$(fm_fakebin "$TMP_ROOT/readonly-lifecycle")
  hold_helm "$home" "$fakebin"; holder=$HOLDER_PID
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" prepare \
    --next "merge the open PR" >/dev/null 2>&1 || fail "the holder must be able to prepare"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" release >/dev/null 2>&1 \
    || fail "the holder must be able to release"
  before=$(cat "$home/data/handover.md")

  # A second window takes the helm; the released record is still waiting for it.
  start_holder; other=$HOLDER_PID
  printf '%s\n' "$other" > "$home/state/.lock"
  # ...and the outgoing session, which no longer holds the helm, tries both.
  make_fake_ps "$fakebin" "$holder"
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" consume 2>&1); status=$?
  expect_code 1 "$status" "a session without the helm must not consume the handover"
  assert_contains "$out" "does not hold the helm" "the refusal must say why"
  assert_contains "$out" "fm-lock.sh status" "the refusal must point at what does hold it"
  if grep -q '^consumed=' "$home/state/.handover"; then
    fail "a refused consume must not mark the handover picked up"
  fi

  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" prepare \
    --next "something else entirely" 2>&1); status=$?
  expect_code 1 "$status" "a session without the helm must not prepare a handover"
  assert_contains "$out" "does not hold the helm" "the refusal must say why"
  [ "$(cat "$home/data/handover.md")" = "$before" ] \
    || fail "a refused prepare must leave the released record exactly as it was"
  assert_absent "$home/data/handover-prev.md" "a refused prepare must not rotate the record away"

  # The session that does hold the helm still picks it up.
  make_fake_ps "$fakebin" "$other"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" consume >/dev/null 2>&1 \
    || fail "the session holding the helm must still be able to consume the handover"
  assert_grep "consumed=" "$home/state/.handover" "the helm holder's consume must land"
  pass "fm-handover: only the session holding the helm may prepare or consume a handover"
}

# --- the helm: release it, or clear the one this session does not hold --------

test_release_refuses_from_a_session_that_does_not_hold_the_helm() {
  local home fakebin holder other out status
  home=$(make_home "$TMP_ROOT/lock-release")
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-release")
  hold_helm "$home" "$fakebin"; holder=$HOLDER_PID

  # A second window holds the helm, and this one tries to release it anyway.
  start_holder; other=$HOLDER_PID
  printf '%s\n' "$other" > "$home/state/.lock"
  make_fake_ps "$fakebin" "$holder"
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-lock.sh" release 2>&1); status=$?
  expect_code 1 "$status" "release must refuse from a session that does not hold the helm"
  assert_contains "$out" "does not hold the lock" "the refusal must say why"
  assert_grep "$other" "$home/state/.lock" "a refused release must leave the helm exactly as it was"

  # The holder releases its own helm, and releasing an already-free helm is fine.
  make_fake_ps "$fakebin" "$other"
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-lock.sh" release 2>&1) \
    || fail "the holder must be able to release its own helm: $out"
  assert_absent "$home/state/.lock" "release must free the helm"
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-lock.sh" release 2>&1) \
    || fail "releasing an already-free helm must succeed: $out"
  assert_contains "$out" "already free" "an already-free helm must say so rather than fail"
  pass "fm-lock release: only the session holding the helm may release it"
}

# The captain's override is the escape hatch for a helm held by a session they
# cannot recover. It must name itself in the refusal - a captain who is told only
# that something else holds the helm has no way forward - and it must refuse a
# pid that is not the recorded holder, so a stale reading cannot clear a helm
# that has since changed hands.
test_the_live_holder_refusal_names_the_exact_clear_command() {
  local home fakebin holder out status
  home=$(make_home "$TMP_ROOT/lock-clear")
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-clear")
  start_holder; holder=$HOLDER_PID
  make_fake_ps "$fakebin" "$holder"
  printf '%s\n' "$holder" > "$home/state/.lock"

  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-lock.sh" status 2>&1)
  assert_contains "$out" "held by live harness pid $holder" "status must name the live holder"
  assert_contains "$out" "clear --pid $holder" "status must name the exact command that clears it"

  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-lock.sh" clear --pid $((holder + 1)) 2>&1); status=$?
  expect_code 1 "$status" "clear must refuse a pid that does not hold the helm"
  assert_contains "$out" "does not hold the lock" "the refusal must say the pid is not the holder"
  assert_grep "$holder" "$home/state/.lock" "a refused clear must leave the helm exactly as it was"

  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-lock.sh" clear --pid "$holder" 2>&1) \
    || fail "clear must succeed on the recorded holder: $out"
  assert_contains "$out" "still running and was not touched" \
    "clear must say it dropped the record and stopped nothing"
  assert_absent "$home/state/.lock" "clear must drop the recorded helm"
  kill -0 "$holder" 2>/dev/null || fail "clear must never stop the session that held the helm"
  pass "fm-lock clear: names itself in the refusal, requires the holder pid, and stops no session"
}

run_all() {
  test_prepare_refuses_an_unaccounted_worker
  test_prepared_record_is_advisory_and_carries_the_unrecorded_facts
  test_check_refuses_when_a_pointed_at_record_is_sabotaged
  test_check_refuses_a_worker_with_no_durable_record
  test_release_refuses_and_keeps_the_helm
  test_release_hands_over_and_preserves_queued_events
  test_consume_refuses_without_a_released_handover_and_names_records_after
  test_a_session_without_the_helm_can_neither_prepare_nor_consume
  test_release_refuses_from_a_session_that_does_not_hold_the_helm
  test_the_live_holder_refusal_names_the_exact_clear_command
}

run_all
