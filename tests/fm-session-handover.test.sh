#!/usr/bin/env bash
# Behavior tests for the captain-triggered session handover
# (docs/session-handover.md).
#
# Subjects:
#   bin/fm-session-pulse.sh     - turn-end pulse: stamps the helm activity marker
#                                 and reports a due handover ONCE, never blocking.
#   bin/fm-handover.sh          - prepare, verify, release, consume, and above all
#                                 REFUSE an incomplete handover.
#   bin/fm-decided.sh           - the searchable record of answered questions.
#   bin/fm-awaiting-captain.sh  - the short early block of what waits on the captain.
#   bin/fm-session-start.sh     - surfacing both near the top of the digest.
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

# A genuine linked worktree, the shape every crewmate and scout task gets. Git
# chatter is silenced so the echoed path stays the only output: a fixture that
# leaks it produces a bogus path and a test that passes for the wrong reason.
make_crewmate_worktree() {
  local base=$1 dir=$2
  git -C "$base" worktree add --quiet -b fm/handover-test-branch "$dir" >/dev/null 2>&1 \
    || fail "could not create the crewmate worktree fixture"
  mkdir -p "$dir/state" "$dir/data" "$dir/bin"
  : > "$dir/AGENTS.md"
  printf '%s\n' "$dir"
}

add_task() {
  local home=$1 id=$2
  fm_write_meta "$home/state/$id.meta" "window=fm:$id" "worktree=$home/wt-$id" "project=alpha"
  printf -- '- [ ] %s - a task (repo: alpha) (kind: ship)\n' "$id" >> "$home/data/backlog.md"
}

# One assistant transcript line whose four usage fields sum to $1.
assistant_line() {
  local total=$1 rid=${2:-req-1} sidechain=${3:-false}
  printf '{"type":"assistant","isSidechain":%s,"requestId":"%s","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":8,"cache_read_input_tokens":%s,"output_tokens":10}}}\n' \
    "$sidechain" "$rid" "$((total - 20))"
}

write_transcript() {
  local path=$1 total
  shift
  : > "$path"
  for total in "$@"; do
    assistant_line "$total" "req-$total" >> "$path"
  done
}

stop_payload() {
  printf '{"session_id":"%s","stop_hook_active":false,"transcript_path":"%s"}' "${2:-sess-1}" "$1"
}

# A trailing synthetic entry, the shape Claude Code writes when a turn ends
# abnormally: assistant, main chain, model "<synthetic>", all four usage fields 0.
synthetic_zero_line() {
  printf '{"type":"assistant","isSidechain":false,"message":{"model":"<synthetic>","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n'
}

run_pulse() {
  local home=$1 payload=$2
  shift 2
  printf '%s' "$payload" | env "$@" CLAUDECODE=1 FM_ROOT_OVERRIDE="$home" \
    bash "$ROOT/bin/fm-session-pulse.sh" --claude 2>&1
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

# --- the pulse: one report, never a block ------------------------------------

test_pulse_reports_once_over_threshold_and_never_blocks() {
  local home transcript out status second
  home=$(make_home "$TMP_ROOT/pulse-once")
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" 260000
  out=$(run_pulse "$home" "$(stop_payload "$transcript")"); status=$?
  expect_code 0 "$status" "the pulse must never block a turn end"
  assert_contains "$out" "handover due" "the pulse must report that a handover is due"
  assert_contains "$out" "260000" "the report must name the measured total"
  assert_contains "$out" "250000" "the report must name the threshold it crossed"
  assert_contains "$out" "Keep working" "the report must say the session carries on"
  second=$(run_pulse "$home" "$(stop_payload "$transcript")")
  [ -z "$second" ] || fail "the pulse reported twice in one session: $second"
  pass "fm-session-pulse: reports a due handover once, keeps working, never blocks"
}

test_pulse_rearms_after_falling_back_below() {
  local home over under out
  home=$(make_home "$TMP_ROOT/pulse-rearm")
  over="$home/over.jsonl"; under="$home/under.jsonl"
  write_transcript "$over" 260000
  write_transcript "$under" 40000
  run_pulse "$home" "$(stop_payload "$over")" >/dev/null
  run_pulse "$home" "$(stop_payload "$under")" >/dev/null
  out=$(run_pulse "$home" "$(stop_payload "$over")")
  assert_contains "$out" "handover due" "falling back below the threshold must re-arm the report"
  pass "fm-session-pulse: re-arms after the session falls back below the threshold"
}

# fm-session-pulse-false-zero: a turn that ends abnormally leaves a trailing
# synthetic all-zero-usage entry as the transcript's last countable assistant
# entry. That must not read as an empty session and wipe a handover already due.
test_pulse_does_not_wipe_handover_due_on_a_trailing_synthetic_zero() {
  local home transcript due
  home=$(make_home "$TMP_ROOT/pulse-false-zero")
  transcript="$home/t.jsonl"
  due="$home/state/.handover-due"
  write_transcript "$transcript" 300010
  run_pulse "$home" "$(stop_payload "$transcript")" >/dev/null
  assert_present "$due" "a turn over the threshold must set the handover-due marker"
  synthetic_zero_line >> "$transcript"
  run_pulse "$home" "$(stop_payload "$transcript")" >/dev/null
  assert_present "$due" \
    "a trailing synthetic zero-usage entry must not wipe a handover already due"
  pass "fm-session-pulse: a trailing synthetic zero-usage entry does not wipe a due handover"
}

test_pulse_threshold_is_a_flat_250000() {
  local home transcript out
  home=$(make_home "$TMP_ROOT/pulse-threshold")
  transcript="$home/t.jsonl"
  # Just under and just over the fixed number, with no override in play.
  write_transcript "$transcript" 249999
  out=$(run_pulse "$home" "$(stop_payload "$transcript")")
  [ -z "$out" ] || fail "249999 tokens must stay silent under a 250000 threshold: $out"
  write_transcript "$transcript" 250000
  out=$(run_pulse "$home" "$(stop_payload "$transcript")")
  assert_contains "$out" "250000" "250000 tokens must report against the flat 250000 threshold"
  pass "fm-session-pulse: the threshold is a flat 250000 tokens, not a share of the window"
}

test_pulse_excludes_subagent_turns() {
  local home transcript out
  home=$(make_home "$TMP_ROOT/pulse-sidechain")
  transcript="$home/t.jsonl"
  : > "$transcript"
  assistant_line 40000 req-primary false >> "$transcript"
  assistant_line 900000 req-sub true >> "$transcript"
  out=$(run_pulse "$home" "$(stop_payload "$transcript")")
  [ -z "$out" ] || fail "a subagent turn must never inflate the primary measurement: $out"
  pass "fm-session-pulse: a subagent's context never counts against the primary"
}

test_pulse_is_silent_in_a_crewmate_worktree() {
  local base wt transcript out status
  base="$TMP_ROOT/pulse-base"
  fm_git_init_commit "$base"
  wt=$(make_crewmate_worktree "$base" "$TMP_ROOT/pulse-wt")
  transcript="$wt/t.jsonl"
  write_transcript "$transcript" 900000
  out=$(run_pulse "$wt" "$(stop_payload "$transcript")"); status=$?
  expect_code 0 "$status" "the pulse must exit 0 inside a task worktree"
  [ -z "$out" ] || fail "the pulse must be silent inside a crewmate worktree: $out"
  pass "fm-session-pulse: inert inside a crewmate or scout task worktree"
}

test_pulse_degrades_silently_on_unmeasurable_input() {
  local home out status
  home=$(make_home "$TMP_ROOT/pulse-degrade")
  out=$(run_pulse "$home" '{"session_id":"s","transcript_path":"/nope/missing.jsonl"}'); status=$?
  expect_code 0 "$status" "a missing transcript must not block a turn end"
  [ -z "$out" ] || fail "a missing transcript must degrade silently: $out"
  out=$(printf '' | env CLAUDECODE=1 FM_ROOT_OVERRIDE="$home" bash "$ROOT/bin/fm-session-pulse.sh" --claude 2>&1); status=$?
  expect_code 0 "$status" "empty stdin must not block a turn end"
  [ -z "$out" ] || fail "empty stdin must degrade silently: $out"
  pass "fm-session-pulse: every unmeasurable input is a silent, non-blocking no-op"
}

test_pulse_stamps_the_helm_activity_marker() {
  local home fakebin holder transcript marker
  home=$(make_home "$TMP_ROOT/pulse-stamp")
  fakebin=$(fm_fakebin "$TMP_ROOT/pulse-stamp")
  start_holder; holder=$HOLDER_PID
  make_fake_ps "$fakebin" "$holder"
  printf '%s\n' "$holder" > "$home/state/.lock"
  transcript="$home/t.jsonl"
  write_transcript "$transcript" 1000
  run_pulse "$home" "$(stop_payload "$transcript")" PATH="$fakebin:$PATH" >/dev/null
  marker="$home/state/.helm-activity"
  assert_present "$marker" "the pulse must stamp the helm activity marker for the lock holder"
  assert_grep "pid=$holder" "$marker" "the marker must record which session stamped it"
  assert_grep "transcript=$transcript" "$marker" "the marker must record the transcript so mid-turn work is visible"
  pass "fm-session-pulse: stamps the helm activity marker for the session holding the helm"
}

test_pulse_does_not_stamp_for_a_session_without_the_helm() {
  local home fakebin holder other transcript
  home=$(make_home "$TMP_ROOT/pulse-nostamp")
  fakebin=$(fm_fakebin "$TMP_ROOT/pulse-nostamp")
  start_holder; holder=$HOLDER_PID
  start_holder; other=$HOLDER_PID
  make_fake_ps "$fakebin" "$other"
  # The helm belongs to a different session than the one ending a turn.
  printf '%s\n' "$holder" > "$home/state/.lock"
  transcript="$home/t.jsonl"
  write_transcript "$transcript" 1000
  run_pulse "$home" "$(stop_payload "$transcript")" PATH="$fakebin:$PATH" >/dev/null
  assert_absent "$home/state/.helm-activity" \
    "a session that does not hold the helm must not vouch for the holder's activity"
  pass "fm-session-pulse: only the session holding the helm stamps its activity"
}

# The record of why a turn end resolved no transcript is diagnostics that explain
# a later refusal, so each reason must point at the thing that actually failed:
# a payload naming a transcript that is gone is a different problem from a
# payload that named none at all.
test_pulse_records_why_it_could_not_resolve_a_transcript() {
  local home fakebin holder declined
  home=$(make_home "$TMP_ROOT/pulse-declined")
  fakebin=$(fm_fakebin "$TMP_ROOT/pulse-declined")
  start_holder; holder=$HOLDER_PID
  make_fake_ps "$fakebin" "$holder"
  printf '%s\n' "$holder" > "$home/state/.lock"
  declined="$home/state/.helm-activity-declined"

  run_pulse "$home" "$(stop_payload "$home/gone.jsonl")" PATH="$fakebin:$PATH" >/dev/null
  assert_present "$home/state/.helm-activity" \
    "the marker must still be written, so no earlier turn's marker stands in for this one"
  grep -q '^transcript=$' "$home/state/.helm-activity" \
    || fail "a turn that resolved no transcript must say so in the marker"
  assert_present "$declined" "a turn end that resolved no transcript must record why"
  assert_grep "pid=$holder" "$declined" "the record must name the session it belongs to"
  assert_grep "gone.jsonl" "$declined" \
    "a payload naming a transcript that is not there must not read as a payload naming none"

  run_pulse "$home" '{"session_id":"s"}' PATH="$fakebin:$PATH" >/dev/null
  assert_grep "carried no transcript path" "$declined" \
    "a payload with no transcript path at all must say exactly that"

  write_transcript "$home/t.jsonl" 1000
  run_pulse "$home" "$(stop_payload "$home/t.jsonl")" PATH="$fakebin:$PATH" >/dev/null
  assert_absent "$declined" "a turn end that does resolve a transcript must clear the record"
  pass "fm-session-pulse: records why a transcript could not be resolved, naming the real cause"
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

# --- the searchable record of answered questions -----------------------------

test_decided_search_finds_an_answer_in_an_existing_decision_log() {
  local home out
  home=$(make_home "$TMP_ROOT/decided-search")
  cat > "$home/data/stripe-decision-log.md" <<'LOG'
# Stripe decisions
**D35. Leave the existing duplicate customer records alone.** Only 26 have money
on more than one record; those 26 need per-person review, never a bulk script.
2026-07-29.
LOG
  out=$(FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-decided.sh" search "duplicate customer" 2>&1) \
    || fail "an already-answered question must be findable: $out"
  assert_contains "$out" "D35" "the search must surface the settled decision"
  assert_contains "$out" "stripe-decision-log.md" "the search must name the source so the answer stays checkable"
  pass "fm-decided search: finds a question already answered in an existing decision log"
}

test_decided_search_requires_every_term_and_reports_no_match() {
  local home out status
  home=$(make_home "$TMP_ROOT/decided-and")
  printf '# d\n**D1. Cancel keeps access until period end.** 2026-07-01.\n' > "$home/data/decisions.md"
  out=$(FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-decided.sh" search cancel access 2>&1) \
    || fail "an AND search over one line must match: $out"
  assert_contains "$out" "D1" "both terms on one line must match"
  out=$(FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-decided.sh" search cancel refund 2>&1); status=$?
  expect_code 1 "$status" "a term that appears nowhere must report no match"
  assert_contains "$out" "may genuinely be unanswered" "a miss must not read as a settled answer"
  pass "fm-decided search: every term must match, and a miss says it may be unanswered"
}

test_decided_search_caps_output_and_names_what_it_dropped() {
  local home out i
  home=$(make_home "$TMP_ROOT/decided-cap")
  : > "$home/data/decisions.md"
  i=0
  while [ "$i" -lt 12 ]; do
    printf '**D%s. widget ruling number %s.** 2026-07-01.\n' "$i" "$i" >> "$home/data/decisions.md"
    i=$((i + 1))
  done
  out=$(FM_DECIDED_MAX_LINES=5 FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-decided.sh" search widget 2>&1)
  assert_contains "$out" "7 more match(es) omitted" "a capped search must say how many it dropped"
  [ "$(printf '%s\n' "$out" | grep -c 'widget ruling')" = 5 ] \
    || fail "the cap must bound the printed matches"
  pass "fm-decided search: caps its output and says what it omitted rather than truncating silently"
}

test_decided_record_keeps_one_answer_per_key() {
  local home out status
  home=$(make_home "$TMP_ROOT/decided-record")
  FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-decided.sh" record --key duplicate-customers \
    --answer "leave them alone; the 26 with money get per-person review" \
    --source data/stripe-decision-log.md --date 2026-07-29 >/dev/null \
    || fail "record must accept a well-formed answer"
  assert_grep "- [duplicate-customers] 2026-07-29" "$home/data/decided.md" "the answer must be indexed under its key"
  assert_grep "(source: data/stripe-decision-log.md)" "$home/data/decided.md" "the answer must keep its source"
  out=$(FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-decided.sh" record --key duplicate-customers \
    --answer "something else" 2>&1); status=$?
  expect_code 1 "$status" "a second answer under one key must be refused"
  assert_contains "$out" "already answered" "the refusal must show the existing answer"
  FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-decided.sh" record --key duplicate-customers \
    --answer "revised: consolidate after all" --supersede >/dev/null \
    || fail "--supersede must replace the answer"
  [ "$(grep -c '^- \[duplicate-customers\]' "$home/data/decided.md")" = 1 ] \
    || fail "superseding must leave exactly one answer for the key"
  assert_grep "revised: consolidate after all" "$home/data/decided.md" "the superseding answer must win"
  out=$(FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-decided.sh" count 2>&1)
  assert_contains "$out" "1 answered decision(s) indexed" "count must report the indexed answers"
  assert_contains "$out" "Search before escalating anything" "count must carry the search instruction"
  pass "fm-decided record: one answer per stable key, superseded explicitly, counted for startup"
}

# The count is the ONE startup line the searchable-decision design rests on, and
# an index that exists with no entries is ordinary: hand-created, or pruned.
test_decided_count_of_an_empty_index_is_one_clean_line() {
  local home out
  home=$(make_home "$TMP_ROOT/decided-empty-index")
  printf '# Answered decisions\n' > "$home/data/decided.md"
  out=$(FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-decided.sh" count 2>&1)
  assert_contains "$out" "0 answered decision(s) indexed" "an empty index must report zero answers"
  printf '%s\n' "$out" | grep -qx '0' \
    && fail "the count printed a stray bare 0 line above the digest line: $out"
  [ "$(printf '%s\n' "$out" | grep -c 'answered decision(s) indexed')" = 1 ] \
    || fail "the count must print exactly one digest line: $out"
  pass "fm-decided count: a zero-entry index reports one clean line, with no stray zero"
}

test_decided_search_excludes_the_open_items_view() {
  local home out status
  home=$(make_home "$TMP_ROOT/decided-open")
  printf '# Decisions waiting on the captain\n\n- **should we widget?**\n' > "$home/data/NEED_DECISION.md"
  out=$(FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-decided.sh" search widget 2>&1); status=$?
  expect_code 1 "$status" "an unanswered item must not match an answered-decision search"
  out=$(FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-decided.sh" sources 2>&1)
  assert_not_contains "$out" "NEED_DECISION" "the open view must not be a source of answered decisions"
  pass "fm-decided: the open-items view is never mistaken for a settled answer"
}

# --- what waits on the captain, early ----------------------------------------

test_awaiting_block_lists_held_decisions_and_caps_them() {
  local home out i
  home=$(make_home "$TMP_ROOT/awaiting")
  # The canonical record model (bin/fm-backlog-record-lib.sh) decides this:
  # a hold waits on the captain only when it is QUEUED, kind captain, hold-kind
  # captain, has a reason, and has no unresolved blocker.
  {
    printf -- '- [ ] inflight-hold - Being worked already (repo: fe) (kind: captain) (hold: mid-flight) (hold-kind: captain)\n'
    printf -- '- [ ] busy-task - Something under way (repo: fe) (kind: ship)\n'
    printf '## Queued\n'
    printf -- '- [ ] fe-signin - Sign in with a code (repo: fe) (kind: captain) (hold: captain grill first) (hold-kind: captain)\n'
    printf -- '- [ ] blocked-hold - Waiting on other work (repo: fe) (kind: captain) (hold: needs the migration) (hold-kind: captain) blocked-by: busy-task\n'
    printf '## Done\n- [x] old-thing - answered long ago (kind: captain) (hold: settled) (hold-kind: captain)\n'
  } >> "$home/data/backlog.md"
  fm_write_meta "$home/state/busy-task.meta" "window=fm:busy-task" "pr=https://github.com/x/y/pull/9"
  fm_write_meta "$home/state/event-task.meta" "window=fm:event-task"
  printf 'pr opened: https://github.com/x/y/pull/11\n' > "$home/state/event-task.status"
  out=$(FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-awaiting-captain.sh" 2>&1)
  assert_contains "$out" "Decisions held for you:" "the block must name what waits on the captain"
  assert_contains "$out" "fe-signin - Sign in with a code" "a decision held for the captain must be listed"
  assert_not_contains "$out" "busy-task - Something under way" "ordinary work under way is not waiting on the captain"
  assert_not_contains "$out" "inflight-hold" "a hold already being worked is not waiting on the captain"
  assert_not_contains "$out" "blocked-hold" "a hold whose blocker is still open is not actionable yet"
  assert_not_contains "$out" "old-thing" "a finished item must not be listed as waiting"
  assert_contains "$out" "https://github.com/x/y/pull/9" "work recorded as waiting to land must be listed"
  assert_contains "$out" "https://github.com/x/y/pull/11" \
    "a pull request recorded only in a status event must be listed too"
  assert_contains "$out" "Search before escalating anything" "the block must carry the one-line search instruction"
  assert_contains "$out" "data/captain.md" "the block must point at the captain's standing preferences early"
  # Rebuild the backlog in order, so the extra held items land in a live section
  # rather than after the Done heading.
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  i=0
  while [ "$i" -lt 6 ]; do
    printf -- '- [ ] held-%s - held item %s (repo: fe) (kind: captain) (hold: waiting) (hold-kind: captain)\n' "$i" "$i" >> "$home/data/backlog.md"
    i=$((i + 1))
  done
  out=$(FM_AWAITING_MAX=3 FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-awaiting-captain.sh" 2>&1)
  [ "$(printf '%s\n' "$out" | grep -c '^- held-')" = 3 ] || fail "the cap must bound the held-decision list"
  assert_contains "$out" "more held decision(s) omitted" "a capped list must say what it dropped"
  pass "fm-awaiting-captain: lists only what waits on the captain, capped, never silently truncated"
}

# A read that failed must never render as an empty list: "(none)" reads as
# "nothing is waiting on you", which is the failure this whole block exists to
# prevent, and the cap protects the same property at the other end.
test_awaiting_block_says_so_when_the_record_model_cannot_be_read() {
  local home fakebin out
  home=$(make_home "$TMP_ROOT/awaiting-unreadable")
  fakebin=$(fm_fakebin "$TMP_ROOT/awaiting-unreadable")
  printf -- '- [ ] fe-signin - Sign in with a code (repo: fe) (kind: captain) (hold: grill first) (hold-kind: captain)\n' \
    >> "$home/data/backlog.md"
  fm_write_meta "$home/state/beta-task.meta" "window=fm:beta-task" "pr=https://github.com/x/y/pull/3"
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
echo "jq: broken on this host" >&2
exit 5
SH
  chmod +x "$fakebin/jq"
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-awaiting-captain.sh" 2>&1)
  assert_contains "$out" "held decisions unread" "a failed read must say so, never render as an empty list"
  assert_not_contains "$out" "(none)" "a failed read must not be reported as nothing waiting"
  pass "fm-awaiting-captain: an unreadable record model is reported, never shown as nothing waiting"
}

# The same property one list down: a task whose records cannot be read has an
# UNKNOWN pull-request state, and reporting that as "no pull request" is the
# same lie. bin/fm-pr-check.sh writes metas at 0600, so an unreadable-but-present
# meta is a real filesystem state rather than a hypothetical one.
test_awaiting_block_says_so_when_a_task_meta_cannot_be_read() {
  local home out
  home=$(make_home "$TMP_ROOT/awaiting-unreadable-meta")
  fm_write_meta "$home/state/locked-task.meta" "window=fm:locked-task" "pr=https://github.com/x/y/pull/7"
  chmod 000 "$home/state/locked-task.meta"
  out=$(FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-awaiting-captain.sh" 2>&1)
  chmod 600 "$home/state/locked-task.meta"
  assert_contains "$out" "locked-task: UNREAD" "an unreadable task record must be named, not dropped"
  assert_contains "$out" "unknown, not no" "the marker must say the answer is unknown rather than absent"
  pass "fm-awaiting-captain: a task whose records cannot be read is named, never silently dropped"
}

# A task's meta survives from merge until teardown removes it, so listing every
# recorded pull request reports work the captain already merged back to him as
# still waiting. The local record model already knows; no forge call is allowed
# here, because the local-only rule is what keeps this block cheap.
test_awaiting_block_drops_pull_requests_the_local_record_says_have_landed() {
  local home out
  home=$(make_home "$TMP_ROOT/awaiting-landed")
  {
    printf -- '- [ ] open-task - still open (repo: fe) (kind: ship)\n'
    printf '## Done\n'
    printf -- '- [x] landed-task - shipped it (repo: fe) (kind: ship) (merged 2026-07-30)\n'
  } >> "$home/data/backlog.md"
  fm_write_meta "$home/state/landed-task.meta" "window=fm:landed-task" "pr=https://github.com/x/y/pull/41"
  fm_write_meta "$home/state/open-task.meta" "window=fm:open-task" "pr=https://github.com/x/y/pull/42"
  out=$(FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-awaiting-captain.sh" 2>&1)
  assert_contains "$out" "pull/42" "a pull request the local record still calls open must be listed"
  assert_not_contains "$out" "pull/41" "a pull request the local record already calls merged must not be listed as waiting"
  assert_contains "$out" "not verified against the forge" \
    "the list must not overclaim: these are recorded locally, not checked"
  pass "fm-awaiting-captain: work the local record says has landed is not reported as waiting"
}

test_awaiting_block_surfaces_a_waiting_handover() {
  local home fakebin holder out
  home=$(make_home "$TMP_ROOT/awaiting-handover")
  fakebin=$(fm_fakebin "$TMP_ROOT/awaiting-handover")
  start_holder; holder=$HOLDER_PID
  make_fake_ps "$fakebin" "$holder"
  printf '%s\n' "$holder" > "$home/state/.lock"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" prepare --next "merge the open PR" >/dev/null 2>&1
  out=$(FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-awaiting-captain.sh" 2>&1)
  assert_not_contains "$out" "HANDOVER WAITING" "a prepared but unreleased handover is not waiting for a replacement"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-handover.sh" release >/dev/null 2>&1
  out=$(FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-awaiting-captain.sh" 2>&1)
  assert_contains "$out" "HANDOVER WAITING" "a released handover must be surfaced to the replacement"
  assert_contains "$out" "fm-handover.sh consume" "the replacement must be told how to close it out"
  # A session refused the helm still sees the handover, and is told not to take it.
  out=$(FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-awaiting-captain.sh" --read-only 2>&1)
  assert_contains "$out" "HANDOVER WAITING" "a refused session must still be shown the waiting handover"
  assert_contains "$out" "must NOT" "a refused session must be told not to consume it"
  assert_not_contains "$out" "run bin/fm-handover.sh consume" \
    "a refused session must not be told to run the command it is not allowed to run"
  pass "fm-awaiting-captain: surfaces a released handover, and only once it is released"
}

# The pulse only measures anything if the harness actually calls it, and a
# cwd-relative command would silently never fire from a task worktree.
test_pulse_is_registered_as_a_stop_hook() {
  local settings found
  settings="$ROOT/.claude/settings.json"
  assert_present "$settings" "tracked .claude/settings.json is missing"
  found=$(jq -r '[.hooks.Stop[].hooks[].command] | map(select(test("fm-session-pulse\\.sh"))) | .[0] // empty' "$settings")
  [ -n "$found" ] || fail "the turn-end pulse is not registered as a Stop hook"
  assert_contains "$found" 'CLAUDE_PROJECT_DIR' "the pulse hook must resolve via CLAUDE_PROJECT_DIR, not a cwd-relative path"
  assert_contains "$found" '--claude' "the pulse must be invoked in its only supported mode"
  found=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  assert_contains "$found" 'fm-turnend-guard.sh' "the pulse must not displace the turn-end guard from first position"
  pass "fm-session-pulse: registered as a Stop hook without displacing the turn-end guard"
}

run_all() {
  test_pulse_is_registered_as_a_stop_hook
  test_pulse_reports_once_over_threshold_and_never_blocks
  test_pulse_rearms_after_falling_back_below
  test_pulse_does_not_wipe_handover_due_on_a_trailing_synthetic_zero
  test_pulse_threshold_is_a_flat_250000
  test_pulse_excludes_subagent_turns
  test_pulse_is_silent_in_a_crewmate_worktree
  test_pulse_degrades_silently_on_unmeasurable_input
  test_pulse_stamps_the_helm_activity_marker
  test_pulse_does_not_stamp_for_a_session_without_the_helm
  test_pulse_records_why_it_could_not_resolve_a_transcript
  test_prepare_refuses_an_unaccounted_worker
  test_prepared_record_is_advisory_and_carries_the_unrecorded_facts
  test_check_refuses_when_a_pointed_at_record_is_sabotaged
  test_check_refuses_a_worker_with_no_durable_record
  test_release_refuses_and_keeps_the_helm
  test_release_hands_over_and_preserves_queued_events
  test_consume_refuses_without_a_released_handover_and_names_records_after
  test_a_session_without_the_helm_can_neither_prepare_nor_consume
  test_decided_search_finds_an_answer_in_an_existing_decision_log
  test_decided_search_requires_every_term_and_reports_no_match
  test_decided_search_caps_output_and_names_what_it_dropped
  test_decided_record_keeps_one_answer_per_key
  test_decided_count_of_an_empty_index_is_one_clean_line
  test_decided_search_excludes_the_open_items_view
  test_awaiting_block_lists_held_decisions_and_caps_them
  test_awaiting_block_says_so_when_the_record_model_cannot_be_read
  test_awaiting_block_says_so_when_a_task_meta_cannot_be_read
  test_awaiting_block_drops_pull_requests_the_local_record_says_have_landed
  test_awaiting_block_surfaces_a_waiting_handover
}

if ! command -v jq >/dev/null 2>&1; then
  printf 'skip: jq not found - the context measurement needs it\n'
  exit 0
fi

run_all
