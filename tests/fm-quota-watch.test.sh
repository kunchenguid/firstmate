#!/usr/bin/env bash
# Tests for bin/fm-quota-watch.sh: the agent-free, cron/launchd-driven Claude
# quota gate that pauses and resumes this home's live ship/scout crew.
#
# Every case fakes quota-axi (via FM_QUOTA_AXI_BIN, fed a fixture JSON file
# through FM_TEST_QUOTA_JSON) and fakes the crewmate sender (via
# FM_QUOTA_SEND_BIN, which logs every call instead of touching a real backend),
# so nothing here depends on a real quota reading, a real tmux/herdr pane, or
# this repo's own live fleet.
#
# Matrix:
#   (a) crossing the pause threshold interrupts every live ship/scout crew and
#       records the pause (flag + status line), never touching a secondmate
#   (b) rerunning while still above threshold is idempotent: no resend, no
#       duplicate flag entries
#   (c) a crew spawned while already paused is picked up on the next high-pct
#       run without resending to the ones already recorded
#   (d) a reading inside the hysteresis band leaves an existing pause alone
#   (e) dropping below the resume threshold sends one note per paused crew and
#       clears the flag
#   (f) auth_required (empty windows) is a harmless no-op
#   (g) a missing quota-axi binary is a harmless no-op
#   (h) an unrecognized harness is refused rather than guessed, and is not
#       recorded as paused
#   (i) --status prints the resolved config and current reading and takes no
#       action
#   (j) a high credits (paid overage) window never drives a pause when
#       session/weekly are both low - only the rate-limit-style windows count
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QUOTA_WATCH="$ROOT/bin/fm-quota-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-watch-tests)

# --- fixtures ----------------------------------------------------------------

# Minimal quota-axi --provider claude --json shape with one kind=session
# window at <pct>, matching the real schema's rate-limit-style window shape.
quota_json_pct() {  # <pct>
  printf '{"providers":[{"provider":"claude","windows":[{"id":"five_hour","kind":"session","percentUsed":%s}],"state":{"status":"fresh"}}]}\n' "$1"
}

# All three real window kinds present: session, weekly, and credits (paid
# overage spend). Lets a test independently control each.
quota_json_windows() {  # <session_pct> <weekly_pct> <credits_pct>
  printf '{"providers":[{"provider":"claude","windows":[{"id":"five_hour","kind":"session","percentUsed":%s},{"id":"seven_day","kind":"weekly","percentUsed":%s},{"id":"extra_usage","kind":"credits","percentUsed":%s}],"state":{"status":"fresh"}}]}\n' "$1" "$2" "$3"
}

quota_json_auth_required() {
  printf '%s\n' '{"providers":[{"provider":"claude","windows":[],"state":{"status":"auth_required","error":"Claude sign-in required"}}]}'
}

# Build a case sandbox: state/, config/, fakebin/ with a quota-axi stub reading
# FM_TEST_QUOTA_JSON and a fm-send stub that logs to FM_TEST_SEND_LOG. Echoes
# the case dir.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/fakebin"

  cat > "$case_dir/fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
cat "$FM_TEST_QUOTA_JSON"
SH
  chmod +x "$case_dir/fakebin/quota-axi"

  cat > "$case_dir/fakebin/fm-send" <<'SH'
#!/usr/bin/env bash
id=${1:-}
printf '%s\n' "$*" >> "$FM_TEST_SEND_LOG"
[ "${FM_TEST_SEND_FAIL_ID:-}" != "$id" ]
SH
  chmod +x "$case_dir/fakebin/fm-send"

  : > "$case_dir/send.log"
  printf '%s\n' "$case_dir"
}

# write_crew_meta <case_dir> <id> <kind> [harness]
write_crew_meta() {
  local case_dir=$1 id=$2 kind=$3 harness=${4:-claude}
  fm_write_meta "$case_dir/state/$id.meta" \
    "window=fm-$id" \
    "worktree=$case_dir/wt-$id" \
    "project=$case_dir/project" \
    "harness=$harness" \
    "kind=$kind" \
    "mode=no-mistakes" \
    "yolo=off"
}

# run_watch <case_dir> [extra-arg]: run fm-quota-watch.sh against the sandbox.
# Echoes nothing; sets globals RC, OUT, ERR (file paths) for the caller.
run_watch() {
  local case_dir=$1
  shift || true
  OUT="$case_dir/out.log"
  ERR="$case_dir/err.log"
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_QUOTA_AXI_BIN="$case_dir/fakebin/quota-axi" \
  FM_QUOTA_SEND_BIN="$case_dir/fakebin/fm-send" \
  FM_TEST_QUOTA_JSON="$case_dir/quota.json" \
  FM_TEST_SEND_LOG="$case_dir/send.log" \
  FM_QUOTA_PAUSE_THRESHOLD=80 \
  FM_QUOTA_RESUME_THRESHOLD=65 \
  FM_TEST_SEND_FAIL_ID="${FM_TEST_SEND_FAIL_ID:-}" \
    "$QUOTA_WATCH" "$@" > "$OUT" 2> "$ERR"
  RC=$?
}

count_lines() {  # <file>
  [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || printf '0'
}

# --- (a) crossing the pause threshold -----------------------------------------

test_pause_crosses_threshold() {
  local case_dir
  case_dir=$(make_case pause-cross)
  write_crew_meta "$case_dir" task-a ship claude
  write_crew_meta "$case_dir" task-b scout grok
  write_crew_meta "$case_dir" sm-1 secondmate claude
  quota_json_pct 83 > "$case_dir/quota.json"

  run_watch "$case_dir"
  expect_code 0 "$RC" "pause run exits 0"

  assert_present "$case_dir/state/.quota-paused" "flag created on cross"
  assert_grep "task=task-a" "$case_dir/state/.quota-paused" "ship crew recorded paused"
  assert_grep "task=task-b" "$case_dir/state/.quota-paused" "scout crew recorded paused"
  assert_no_grep "task=sm-1" "$case_dir/state/.quota-paused" "secondmate never recorded paused"

  assert_grep "task-a --key Escape" "$case_dir/send.log" "claude crew gets single Escape"
  assert_grep "task-b --key C-c" "$case_dir/send.log" "grok crew gets Ctrl-C"
  assert_no_grep "sm-1" "$case_dir/send.log" "secondmate never sent anything"

  assert_present "$case_dir/state/task-a.status" "status file written for paused crew"
  assert_grep "paused: quota at 83%" "$case_dir/state/task-a.status" "status uses existing paused: verb"
  assert_grep "paused: quota at 83%" "$case_dir/state/task-b.status" "status uses existing paused: verb (scout)"
  assert_absent "$case_dir/state/sm-1.status" "secondmate gets no status line"

  pass "pause crosses threshold: ship+scout paused, secondmate untouched"
}

# --- (b) idempotent rerun -----------------------------------------------------

test_idempotent_rerun_same_high_pct() {
  local case_dir before after
  case_dir=$(make_case idempotent)
  write_crew_meta "$case_dir" task-a ship claude
  quota_json_pct 90 > "$case_dir/quota.json"

  run_watch "$case_dir"
  expect_code 0 "$RC" "first pause run exits 0"
  before=$(count_lines "$case_dir/send.log")
  [ "$before" -eq 1 ] || fail "expected exactly 1 send call after first pause, got $before"

  run_watch "$case_dir"
  expect_code 0 "$RC" "second run (still high) exits 0"
  after=$(count_lines "$case_dir/send.log")
  [ "$after" -eq "$before" ] || fail "rerun at same high pct resent an interrupt (log grew from $before to $after)"

  flag_lines=$(grep -c '^task=task-a$' "$case_dir/state/.quota-paused")
  [ "$flag_lines" -eq 1 ] || fail "flag duplicated task-a entry ($flag_lines occurrences)"

  pass "idempotent rerun at same high pct: no resend, no duplicate flag entry"
}

# --- (c) newly spawned crew picked up while already paused --------------------

test_pause_picks_up_newly_spawned_crew() {
  local case_dir
  case_dir=$(make_case new-crew)
  write_crew_meta "$case_dir" task-a ship claude
  quota_json_pct 85 > "$case_dir/quota.json"

  run_watch "$case_dir"
  expect_code 0 "$RC" "first pause run exits 0"
  assert_grep "task=task-a" "$case_dir/state/.quota-paused" "task-a recorded"

  write_crew_meta "$case_dir" task-c ship codex
  run_watch "$case_dir"
  expect_code 0 "$RC" "second pause run (new crew) exits 0"

  assert_grep "task=task-c" "$case_dir/state/.quota-paused" "newly spawned crew recorded on next pass"
  local task_a_calls
  task_a_calls=$(grep -c '^task-a ' "$case_dir/send.log")
  [ "$task_a_calls" -eq 1 ] || fail "task-a was resent an interrupt when only task-c was new ($task_a_calls calls)"
  assert_grep "task-c --key Escape" "$case_dir/send.log" "new codex crew interrupted"

  pass "crew spawned during an active pause is picked up without resending to existing ones"
}

# --- (d) hysteresis band leaves an existing pause alone -----------------------

test_hysteresis_band_no_resume() {
  local case_dir
  case_dir=$(make_case hysteresis)
  write_crew_meta "$case_dir" task-a ship claude
  quota_json_pct 85 > "$case_dir/quota.json"
  run_watch "$case_dir"
  expect_code 0 "$RC" "pause run exits 0"

  quota_json_pct 72 > "$case_dir/quota.json"
  run_watch "$case_dir"
  expect_code 0 "$RC" "band run exits 0"

  assert_present "$case_dir/state/.quota-paused" "flag remains inside hysteresis band"
  assert_contains "$(cat "$case_dir/out.log")" "hysteresis band" "band state is reported"
  local send_calls
  send_calls=$(count_lines "$case_dir/send.log")
  [ "$send_calls" -eq 1 ] || fail "hysteresis band run sent something (expected only the original pause call, got $send_calls total)"

  pass "reading inside the hysteresis band leaves an existing pause untouched"
}

# --- (e) recovery below resume threshold --------------------------------------

test_resume_below_recovery_threshold() {
  local case_dir
  case_dir=$(make_case resume)
  write_crew_meta "$case_dir" task-a ship claude
  write_crew_meta "$case_dir" task-b scout opencode
  quota_json_pct 88 > "$case_dir/quota.json"
  run_watch "$case_dir"
  expect_code 0 "$RC" "pause run exits 0"
  assert_grep "task-b --key Escape" "$case_dir/send.log" "opencode interrupt uses Escape"
  local opencode_escapes
  opencode_escapes=$(grep -c '^task-b --key Escape$' "$case_dir/send.log")
  [ "$opencode_escapes" -eq 2 ] || fail "opencode interrupt should send Escape twice, got $opencode_escapes"

  quota_json_pct 50 > "$case_dir/quota.json"
  run_watch "$case_dir"
  expect_code 0 "$RC" "resume run exits 0"

  assert_absent "$case_dir/state/.quota-paused" "flag cleared on recovery"
  assert_grep "task-a Quota recovered" "$case_dir/send.log" "task-a gets the resume note"
  assert_grep "task-b Quota recovered" "$case_dir/send.log" "task-b gets the resume note"

  pass "dropping below the resume threshold notifies and clears every paused crew"
}

# --- (f) auth_required is a harmless no-op ------------------------------------

test_auth_required_is_harmless_noop() {
  local case_dir
  case_dir=$(make_case auth-required)
  write_crew_meta "$case_dir" task-a ship claude
  quota_json_auth_required > "$case_dir/quota.json"

  run_watch "$case_dir"
  expect_code 0 "$RC" "auth_required run exits 0, never hangs or crashes"

  assert_absent "$case_dir/state/.quota-paused" "no pause recorded from auth_required"
  [ ! -s "$case_dir/send.log" ] || fail "auth_required must never send anything to crew"
  assert_absent "$case_dir/state/task-a.status" "no status line written from auth_required"

  pass "auth_required (empty windows) is a harmless no-op"
}

# --- (g) missing quota-axi binary is a harmless no-op -------------------------

test_missing_quota_axi_tool_is_harmless_noop() {
  local case_dir
  case_dir=$(make_case missing-tool)
  write_crew_meta "$case_dir" task-a ship claude
  quota_json_pct 90 > "$case_dir/quota.json"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_QUOTA_AXI_BIN="$case_dir/fakebin/does-not-exist-quota-axi" \
  FM_QUOTA_SEND_BIN="$case_dir/fakebin/fm-send" \
  FM_TEST_QUOTA_JSON="$case_dir/quota.json" \
  FM_TEST_SEND_LOG="$case_dir/send.log" \
    "$QUOTA_WATCH" > "$case_dir/out.log" 2> "$case_dir/err.log"
  RC=$?

  expect_code 0 "$RC" "missing quota-axi binary exits 0, never hangs or crashes"
  assert_absent "$case_dir/state/.quota-paused" "no pause recorded when quota-axi is missing"
  [ ! -s "$case_dir/send.log" ] || fail "missing quota-axi must never send anything to crew"

  pass "a missing quota-axi binary is a harmless no-op"
}

# --- (h) unrecognized harness is refused, not guessed -------------------------

test_unknown_harness_refuses_to_guess() {
  local case_dir
  case_dir=$(make_case unknown-harness)
  write_crew_meta "$case_dir" task-a ship some-future-harness
  quota_json_pct 90 > "$case_dir/quota.json"

  run_watch "$case_dir"
  expect_code 0 "$RC" "run with an unknown harness still exits 0"

  [ ! -s "$case_dir/send.log" ] || fail "unknown harness must never be sent a guessed key"
  assert_no_grep "task=task-a" "$case_dir/state/.quota-paused" "unrecognized-harness crew is not recorded paused"
  assert_contains "$(cat "$case_dir/err.log")" "refusing to guess" "refusal is logged"

  pass "an unrecognized harness is refused rather than guessed, and left unmanaged"
}

# --- (i) --status is read-only ------------------------------------------------

test_status_flag_smoke() {
  local case_dir
  case_dir=$(make_case status-smoke)
  write_crew_meta "$case_dir" task-a ship claude
  quota_json_pct 42 > "$case_dir/quota.json"

  run_watch "$case_dir" --status
  expect_code 0 "$RC" "--status exits 0"
  assert_contains "$(cat "$case_dir/out.log")" "pause_threshold=80" "status prints resolved pause threshold"
  assert_contains "$(cat "$case_dir/out.log")" "pct=42" "status prints current reading"
  assert_absent "$case_dir/state/.quota-paused" "--status takes no action"
  [ ! -s "$case_dir/send.log" ] || fail "--status must never send anything"

  pass "--status reports config/reading without acting"
}

# --- (j) the credits window never drives pause/resume -------------------------

test_credits_window_never_drives_pause() {
  local case_dir
  case_dir=$(make_case credits-ignored)
  write_crew_meta "$case_dir" task-a ship claude
  quota_json_windows 20 30 95 > "$case_dir/quota.json"

  run_watch "$case_dir" --status
  expect_code 0 "$RC" "--status exits 0"
  assert_contains "$(cat "$case_dir/out.log")" "pct=30" "status reflects max(session,weekly), ignoring the higher credits reading"

  run_watch "$case_dir"
  expect_code 0 "$RC" "run with high credits but low session/weekly exits 0"
  assert_absent "$case_dir/state/.quota-paused" "a high credits window alone never triggers a pause"
  [ ! -s "$case_dir/send.log" ] || fail "a high credits window alone must never send anything to crew"

  pass "a high credits (paid overage) window never drives a pause when session/weekly are low"
}

test_credits_window_ignored_during_resume_decision() {
  local case_dir
  case_dir=$(make_case credits-ignored-resume)
  write_crew_meta "$case_dir" task-a ship claude
  quota_json_windows 85 30 20 > "$case_dir/quota.json"
  run_watch "$case_dir"
  expect_code 0 "$RC" "pause run (high session) exits 0"
  assert_present "$case_dir/state/.quota-paused" "high session window paused the crew"

  quota_json_windows 40 30 99 > "$case_dir/quota.json"
  run_watch "$case_dir"
  expect_code 0 "$RC" "resume run exits 0"
  assert_absent "$case_dir/state/.quota-paused" "session/weekly dropping below the resume threshold resumes crew even while credits is high"
  assert_grep "task-a Quota recovered" "$case_dir/send.log" "resume note sent based on session/weekly, not the still-high credits window"

  pass "recovery is decided from session/weekly alone, even while the credits window stays high"
}

# --- (k) resume retries a failed send instead of dropping the pause -----------

test_resume_retries_failed_send() {
  local case_dir
  case_dir=$(make_case resume-retry)
  write_crew_meta "$case_dir" task-a ship claude
  write_crew_meta "$case_dir" task-b scout opencode
  quota_json_pct 88 > "$case_dir/quota.json"
  run_watch "$case_dir"
  expect_code 0 "$RC" "pause run exits 0"
  assert_present "$case_dir/state/.quota-paused" "flag created on cross"

  quota_json_pct 50 > "$case_dir/quota.json"
  FM_TEST_SEND_FAIL_ID=task-b run_watch "$case_dir"
  expect_code 0 "$RC" "resume run (one delivery failure) exits 0"

  assert_present "$case_dir/state/.quota-paused" "flag is kept when a resume note fails to deliver"
  assert_no_grep "task=task-a" "$case_dir/state/.quota-paused" "successfully-notified crew is dropped from the retry flag"
  assert_grep "task=task-b" "$case_dir/state/.quota-paused" "failed-delivery crew stays recorded for a retry"
  assert_grep "task-a Quota recovered" "$case_dir/send.log" "task-a still got its resume note"

  local task_b_attempts_first
  task_b_attempts_first=$(grep -c 'task-b Quota recovered' "$case_dir/send.log")
  [ "$task_b_attempts_first" -eq 1 ] || fail "expected exactly 1 delivery attempt to task-b, got $task_b_attempts_first"

  run_watch "$case_dir"
  expect_code 0 "$RC" "retry run (delivery now succeeds) exits 0"
  assert_absent "$case_dir/state/.quota-paused" "flag is cleared once the retried note is delivered"
  local task_a_total task_b_total
  task_a_total=$(grep -c 'task-a Quota recovered' "$case_dir/send.log")
  task_b_total=$(grep -c 'task-b Quota recovered' "$case_dir/send.log")
  [ "$task_a_total" -eq 1 ] || fail "task-a resume note was resent on retry ($task_a_total deliveries)"
  [ "$task_b_total" -eq 2 ] || fail "expected exactly 2 delivery attempts to task-b (1 failed + 1 retried), got $task_b_total"

  pass "resume retries a failed send instead of dropping pause tracking, without re-notifying already-resumed crew"
}

# --- run -----------------------------------------------------------------

test_pause_crosses_threshold
test_idempotent_rerun_same_high_pct
test_pause_picks_up_newly_spawned_crew
test_hysteresis_band_no_resume
test_resume_below_recovery_threshold
test_auth_required_is_harmless_noop
test_missing_quota_axi_tool_is_harmless_noop
test_unknown_harness_refuses_to_guess
test_status_flag_smoke
test_credits_window_never_drives_pause
test_credits_window_ignored_during_resume_decision
test_resume_retries_failed_send
