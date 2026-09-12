#!/usr/bin/env bash
# Automatic retirement selects finished merged ships and done scouts, then
# calls ordinary teardown without --force. Transient teardown refusals retry
# with a bounded attempt count; permanent refusals stay sticky.
# Unclassifiable records are reported and left untouched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

RETIRE="$ROOT/bin/fm-auto-retire.sh"
TMP_ROOT=$(fm_test_tmproot fm-auto-retire)

# 2026-09-12 hang: sourcing bin/fm-watch.sh in test_watcher_surfaces_one_retirement
# did not return. That case is now alarm-bounded at 20s; the suite ceiling is 120s.

seed_home() {  # <dir>
  mkdir -p "$1/home/state" "$1/home/data" "$1/fakebin"
}

write_meta() {  # <dir> <id> <kind> [pr]
  {
    printf 'kind=%s\n' "$3"
    printf 'window=firstmate:fm-%s\n' "$2"
    [ -z "${4:-}" ] || printf 'pr=%s\n' "$4"
  } > "$1/home/state/$2.meta"
}

plant_ship_debrief() {  # <dir> <id> [body]
  local dir=$1 id=$2 wt
  wt="$dir/worktrees/$id"
  mkdir -p "$wt/data/$id"
  if [ "${3+set}" = set ]; then
    printf '%s' "$3" > "$wt/data/$id/debrief.md"
  else
    printf 'debrief body\n' > "$wt/data/$id/debrief.md"
  fi
  printf 'worktree=%s\n' "$wt" >> "$dir/home/state/$id.meta"
}

install_fakes() {  # <dir>
  local dir=$1
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *"/pull/1"*) printf 'MERGED\n'; exit 0 ;;
  *"/pull/2"*) printf 'OPEN\n'; exit 0 ;;
  *) exit 1 ;;
esac
SH
  cat > "$dir/fakebin/fm-teardown.sh" <<SH
#!/usr/bin/env bash
printf 'teardown %s\n' "\$*" >> "$dir/teardown.log"
case " \$* " in
  *" --force "*) printf 'FORCE\n' >> "$dir/teardown.log"; exit 1 ;;
esac
id=\$1
if [ -f "$dir/home/data/\$id/debrief.md" ] && [ -s "$dir/home/data/\$id/debrief.md" ]; then
  printf 'debrief-present-at-teardown %s\n' "\$id" >> "$dir/teardown.log"
else
  printf 'debrief-missing-at-teardown %s\n' "\$id" >> "$dir/teardown.log"
fi
if [ -f "$dir/refuse/\$id" ]; then
  echo "REFUSED: worktree has uncommitted changes." >&2
  exit 1
fi
if [ -f "$dir/transient/\$id" ]; then
  attempt=0
  [ ! -f "$dir/transient-attempts/\$id" ] || attempt=\$(cat "$dir/transient-attempts/\$id")
  attempt=\$((attempt + 1))
  mkdir -p "$dir/transient-attempts"
  printf '%s\n' "\$attempt" > "$dir/transient-attempts/\$id"
  limit=\$(cat "$dir/transient/\$id")
  if [ "\$limit" = always ] || [ "\$attempt" -le "\$limit" ]; then
    cat "$dir/transient-text/\$id" >&2
    exit 1
  fi
fi
rm -f "$dir/home/state/\$id.meta" "$dir/home/state/\$id.status"
exit 0
SH
  cat > "$dir/fakebin/fm-slack-post.sh" <<SH
#!/usr/bin/env bash
printf 'slack %s\n' "\$*" >> "$dir/slack.log"
exit 0
SH
  chmod +x "$dir/fakebin/gh" "$dir/fakebin/fm-teardown.sh" "$dir/fakebin/fm-slack-post.sh"
}

run_retire() {  # <dir>
  local dir=$1
  PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_DATA_OVERRIDE="$dir/home/data" \
    FM_TEARDOWN_BIN="$dir/fakebin/fm-teardown.sh" \
    FM_SLACK_POST_BIN="$dir/fakebin/fm-slack-post.sh" \
    "$RETIRE" 2>&1
}

test_merged_done_ship_is_retired() {
  local dir out
  dir="$TMP_ROOT/merged"
  seed_home "$dir"
  install_fakes "$dir"
  write_meta "$dir" merged-ship ship 'https://github.com/example/repo/pull/1'
  plant_ship_debrief "$dir" merged-ship
  printf 'done: PR merged\n' > "$dir/home/state/merged-ship.status"
  out=$(run_retire "$dir") || fail "merged ship retire failed: $out"
  assert_contains "$out" "retired: merged-ship (merged PR)" "merged ship was not retired"
  [ ! -e "$dir/home/state/merged-ship.meta" ] || fail "merged ship meta survived"
  grep -qx 'teardown merged-ship' "$dir/teardown.log" || fail "teardown was not invoked without extra flags"
  grep -qx 'debrief-present-at-teardown merged-ship' "$dir/teardown.log" \
    || fail "teardown ran before the home debrief copy landed"
  [ -s "$dir/home/data/merged-ship/debrief.md" ] || fail "home debrief copy missing after retirement"
  grep -qx 'debrief body' "$dir/home/data/merged-ship/debrief.md" \
    || fail "home debrief copy did not match the worktree file"
  [ ! -e "$dir/slack.log" ] || fail "automatic retirement posted to Slack"
  pass "a done ship with a merged PR is retired through ordinary teardown without a Slack post"
}

test_done_scout_with_report_is_retired() {
  local dir out
  dir="$TMP_ROOT/scout"
  seed_home "$dir"
  install_fakes "$dir"
  write_meta "$dir" scout-done scout
  printf 'done: investigation complete\n' > "$dir/home/state/scout-done.status"
  mkdir -p "$dir/home/data/scout-done"
  printf 'report\n' > "$dir/home/data/scout-done/report.md"
  out=$(run_retire "$dir") || fail "scout retire failed: $out"
  assert_contains "$out" "retired: scout-done (done scout with report)" "scout was not retired"
  [ ! -e "$dir/home/state/scout-done.meta" ] || fail "scout meta survived"
  pass "a done scout with its report present is retired"
}

test_open_pr_and_working_ship_are_left_alone() {
  local dir out
  dir="$TMP_ROOT/skip"
  seed_home "$dir"
  install_fakes "$dir"
  write_meta "$dir" open-ship ship 'https://github.com/example/repo/pull/2'
  printf 'done: PR opened\n' > "$dir/home/state/open-ship.status"
  write_meta "$dir" live-ship ship 'https://github.com/example/repo/pull/1'
  printf 'working: still landing\n' > "$dir/home/state/live-ship.status"
  out=$(run_retire "$dir") || fail "skip pass failed: $out"
  [ -z "$out" ] || fail "skip pass printed output: $out"
  [ -f "$dir/home/state/open-ship.meta" ] || fail "open PR record was touched"
  [ -f "$dir/home/state/live-ship.meta" ] || fail "working ship record was touched"
  [ ! -e "$dir/teardown.log" ] || fail "teardown ran for non-candidates"
  pass "open PRs and working ships are left alone"
}

test_gh_fail_is_unclassified_and_untouched() {
  local dir out
  dir="$TMP_ROOT/gh-fail"
  seed_home "$dir"
  install_fakes "$dir"
  write_meta "$dir" gh-fail ship 'https://github.com/example/repo/pull/6'
  printf 'done: waiting on forge\n' > "$dir/home/state/gh-fail.status"
  out=$(run_retire "$dir") || fail "unclassified pass failed: $out"
  assert_contains "$out" "unclassified: gh-fail" "gh failure was not reported"
  [ -f "$dir/home/state/gh-fail.meta" ] || fail "unclassified record was removed"
  [ ! -e "$dir/teardown.log" ] || fail "teardown ran for an unclassified record"
  out=$(run_retire "$dir") || fail "second unclassified pass failed: $out"
  [ -z "$out" ] || fail "unclassified record was retried: $out"
  pass "a forge lookup failure is reported once and left untouched"
}

test_teardown_refusal_never_claims_retirement_or_a_decision() {
  local dir out open
  dir="$TMP_ROOT/refuse"
  seed_home "$dir"
  install_fakes "$dir"
  mkdir -p "$dir/refuse"
  : > "$dir/refuse/dirty-ship"
  write_meta "$dir" dirty-ship ship 'https://github.com/example/repo/pull/1'
  plant_ship_debrief "$dir" dirty-ship
  printf 'done: PR merged\n' > "$dir/home/state/dirty-ship.status"
  out=$(run_retire "$dir") || fail "refusal pass failed: $out"
  assert_contains "$out" "refused: dirty-ship" "refusal was not reported"
  [ -f "$dir/home/state/dirty-ship.meta" ] || fail "refused record was removed"
  grep -q 'done: auto-retired' "$dir/home/state/dirty-ship.status" \
    && fail "refusal claimed retirement before teardown succeeded"
  grep -q 'note: automatic retirement refused:' "$dir/home/state/dirty-ship.status" \
    || fail "refusal was not written as an operational note"
  open=$(status_open_decisions "$dir/home/state/dirty-ship.status")
  [ -z "$open" ] || fail "refusal opened a decision: $open"
  : > "$dir/teardown.log"
  out=$(run_retire "$dir") || fail "second refusal pass failed: $out"
  [ -z "$out" ] || fail "refused retirement was retried: $out"
  [ ! -s "$dir/teardown.log" ] || fail "teardown was retried after a refusal"
  pass "a teardown refusal is noted once without claiming retirement or opening a decision"
}

test_transient_refusal_retries_until_teardown_succeeds() {
  local dir out
  dir="$TMP_ROOT/transient-twice"
  seed_home "$dir"
  install_fakes "$dir"
  mkdir -p "$dir/transient" "$dir/transient-text"
  printf '2\n' > "$dir/transient/retry-ship"
  printf 'REFUSED: another Treehouse slot allocation or return is in progress; nothing was changed\n' \
    > "$dir/transient-text/retry-ship"
  write_meta "$dir" retry-ship ship 'https://github.com/example/repo/pull/1'
  plant_ship_debrief "$dir" retry-ship
  printf 'done: PR merged\n' > "$dir/home/state/retry-ship.status"

  out=$(run_retire "$dir") || fail "first transient pass failed: $out"
  assert_contains "$out" "refused: retry-ship (transient slot-allocation-or-return-in-progress attempt 1/5)" \
    "first transient refusal was not recorded as retryable"
  [ "$(cat "$dir/home/state/retry-ship.auto-retire")" = \
    $'retry\t1\tslot-allocation-or-return-in-progress' ] \
    || fail "first transient attempt was not recorded"

  out=$(run_retire "$dir") || fail "second transient pass failed: $out"
  assert_contains "$out" "refused: retry-ship (transient slot-allocation-or-return-in-progress attempt 2/5)" \
    "second transient refusal was not retried"
  [ "$(cat "$dir/home/state/retry-ship.auto-retire")" = \
    $'retry\t2\tslot-allocation-or-return-in-progress' ] \
    || fail "second transient attempt was not recorded"

  out=$(run_retire "$dir") || fail "third transient pass failed: $out"
  assert_contains "$out" "retired: retry-ship (merged PR)" \
    "later cycle did not retire after transient contention cleared"
  [ ! -e "$dir/home/state/retry-ship.meta" ] || fail "retry ship meta survived successful teardown"
  [ ! -e "$dir/home/state/retry-ship.auto-retire" ] \
    || fail "successful retry left its attempt sidecar behind"
  [ "$(cat "$dir/transient-attempts/retry-ship")" = 3 ] \
    || fail "teardown did not run exactly three times"
  pass "transient teardown refusals retry across cycles until teardown succeeds"
}

test_permanent_transient_refusal_parks_after_five_attempts() {
  local dir out i
  dir="$TMP_ROOT/transient-permanent"
  seed_home "$dir"
  install_fakes "$dir"
  mkdir -p "$dir/transient" "$dir/transient-text"
  printf 'always\n' > "$dir/transient/stuck-ship"
  printf 'error: endpoint is busy for stuck-ship; nothing was changed\n' \
    > "$dir/transient-text/stuck-ship"
  write_meta "$dir" stuck-ship ship 'https://github.com/example/repo/pull/1'
  plant_ship_debrief "$dir" stuck-ship
  printf 'done: PR merged\n' > "$dir/home/state/stuck-ship.status"

  i=1
  while [ "$i" -le 5 ]; do
    out=$(run_retire "$dir") || fail "permanent transient pass $i failed: $out"
    assert_contains "$out" "refused: stuck-ship" "transient pass $i was not attempted"
    i=$((i + 1))
  done
  assert_contains "$out" "refused: stuck-ship (transient endpoint-busy exhausted after 5 attempts)" \
    "permanent transient refusal did not name exhausted retry state"
  assert_contains "$(cat "$dir/home/state/stuck-ship.auto-retire")" \
    $'refused\ttransient-exhausted reason=endpoint-busy attempts=5:' \
    "sticky refusal did not retain its class and attempt count"
  : > "$dir/teardown.log"
  out=$(run_retire "$dir") || fail "parked transient pass failed: $out"
  [ -z "$out" ] || fail "exhausted transient refusal was retried: $out"
  [ ! -s "$dir/teardown.log" ] || fail "teardown ran after transient attempts were exhausted"
  pass "a permanent transient refusal parks after five recorded attempts"
}

test_presentation_lock_refusal_is_transient() {
  local dir out
  dir="$TMP_ROOT/transient-presentation-lock"
  seed_home "$dir"
  install_fakes "$dir"
  mkdir -p "$dir/transient" "$dir/transient-text"
  printf 'always\n' > "$dir/transient/lock-ship"
  printf 'error: herdr session presentation lock is contended for lock-ship; nothing was changed\n' \
    > "$dir/transient-text/lock-ship"
  write_meta "$dir" lock-ship ship 'https://github.com/example/repo/pull/1'
  plant_ship_debrief "$dir" lock-ship
  printf 'done: PR merged\n' > "$dir/home/state/lock-ship.status"
  out=$(run_retire "$dir") || fail "presentation lock pass failed: $out"
  assert_contains "$out" "refused: lock-ship (transient presentation-lock-held attempt 1/5)" \
    "presentation lock refusal was not classified as transient"
  pass "presentation lock refusal remains eligible for a later retry"
}

test_permanent_refusal_replaces_an_existing_retry_mark() {
  local dir out
  dir="$TMP_ROOT/transient-then-permanent"
  seed_home "$dir"
  install_fakes "$dir"
  mkdir -p "$dir/transient" "$dir/transient-text"
  printf '1\n' > "$dir/transient/change-task"
  printf 'error: endpoint is busy for change-task; nothing was changed\n' \
    > "$dir/transient-text/change-task"
  write_meta "$dir" change-task ship 'https://github.com/example/repo/pull/1'
  plant_ship_debrief "$dir" change-task
  printf 'done: PR merged\n' > "$dir/home/state/change-task.status"
  out=$(run_retire "$dir") || fail "initial transient pass failed: $out"
  assert_contains "$out" "transient endpoint-busy attempt 1/5" \
    "initial retryable refusal did not create the setup state"

  mkdir -p "$dir/refuse"
  : > "$dir/refuse/change-task"
  out=$(run_retire "$dir") || fail "permanent refusal pass failed: $out"
  assert_contains "$(cat "$dir/home/state/change-task.auto-retire")" $'refused\t' \
    "permanent refusal did not replace the non-sticky retry mark"
  pass "a permanent refusal after transient contention becomes sticky immediately"
}

test_secondmate_and_reportless_scout_are_left_alone() {
  local dir out
  dir="$TMP_ROOT/leave"
  seed_home "$dir"
  install_fakes "$dir"
  write_meta "$dir" mate secondmate
  printf 'done: idle\n' > "$dir/home/state/mate.status"
  write_meta "$dir" scout-bare scout
  printf 'done: no report yet\n' > "$dir/home/state/scout-bare.status"
  out=$(run_retire "$dir") || fail "leave pass failed: $out"
  [ -z "$out" ] || fail "leave pass printed output: $out"
  [ -f "$dir/home/state/mate.meta" ] || fail "secondmate was touched"
  [ -f "$dir/home/state/scout-bare.meta" ] || fail "reportless scout was touched"
  pass "secondmates and scouts without reports are left alone"
}

test_working_appended_during_forge_lookup_is_refused() {
  local dir out
  dir="$TMP_ROOT/race"
  seed_home "$dir"
  install_fakes "$dir"
  cat > "$dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf 'working: continuing the next slice\n' >> "$dir/home/state/race-ship.status"
printf 'MERGED\n'
exit 0
SH
  chmod +x "$dir/fakebin/gh"
  write_meta "$dir" race-ship ship 'https://github.com/example/repo/pull/1'
  printf 'done: delivered\n' > "$dir/home/state/race-ship.status"
  out=$(run_retire "$dir") || fail "race pass failed: $out"
  assert_contains "$out" "refused: race-ship (status-moved)" \
    "a status that moved during forge lookup was not refused"
  assert_not_contains "$out" "retired: race-ship" \
    "a status that moved during forge lookup was retired"
  [ -f "$dir/home/state/race-ship.meta" ] || fail "race record was removed"
  [ ! -e "$dir/teardown.log" ] || fail "teardown ran after the status moved"
  grep -qx 'working: continuing the next slice' "$dir/home/state/race-ship.status" \
    || fail "lookup mutation did not land on the status file"
  : > "$dir/teardown.log"
  out=$(run_retire "$dir") || fail "second race pass failed: $out"
  [ -z "$out" ] || fail "working last-verb after the race was not skipped: $out"
  [ ! -s "$dir/teardown.log" ] || fail "teardown ran on the post-race working status"
  pass "a working line appended during forge lookup is refused and not retried while working"
}

test_watcher_surfaces_one_retirement() {
  local dir out
  dir="$TMP_ROOT/watch"
  seed_home "$dir"
  install_fakes "$dir"
  write_meta "$dir" merged-ship ship 'https://github.com/example/repo/pull/1'
  plant_ship_debrief "$dir" merged-ship
  printf 'done: PR merged\n' > "$dir/home/state/merged-ship.status"
  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_AUTO_RETIRE_BIN="$RETIRE" \
    FM_TEARDOWN_BIN="$dir/fakebin/fm-teardown.sh" \
    FM_SLACK_POST_BIN="$dir/fakebin/fm-slack-post.sh" \
    perl -e 'alarm 20; exec @ARGV' bash -c '. "$1/bin/fm-watch.sh"; watcher_heartbeat() { :; }; fm_wake_append() { printf "queued:%s:%s:%s\n" "$1" "$2" "$3"; }; wake() { printf "wake:%s\n" "$1"; }; auto_retire_surface' _ "$ROOT") \
    || fail "watcher surface failed: $out"
  assert_contains "$out" "queued:check:auto-retire:" "watcher did not queue the retirement"
  assert_contains "$out" "wake:check: auto-retire:" "watcher did not wake on retirement"
  pass "an ordinary watcher cycle surfaces one retirement"
}

test_merged_done_ship_without_debrief_is_refused() {
  local dir out i
  dir="$TMP_ROOT/debrief-missing"
  seed_home "$dir"
  install_fakes "$dir"
  write_meta "$dir" missing-ship ship 'https://github.com/example/repo/pull/1'
  mkdir -p "$dir/worktrees/missing-ship"
  printf 'worktree=%s\n' "$dir/worktrees/missing-ship" >> "$dir/home/state/missing-ship.meta"
  printf 'done: PR merged\n' > "$dir/home/state/missing-ship.status"
  write_meta "$dir" empty-ship ship 'https://github.com/example/repo/pull/1'
  plant_ship_debrief "$dir" empty-ship ""
  printf 'done: PR merged\n' > "$dir/home/state/empty-ship.status"
  out=$(run_retire "$dir") || fail "missing debrief pass failed: $out"
  assert_contains "$out" "refused: missing-ship (transient debrief-missing attempt 1/5)" \
    "absent debrief was not recorded as retryable"
  assert_contains "$out" "refused: empty-ship (transient debrief-missing attempt 1/5)" \
    "empty debrief was not recorded as retryable"
  assert_not_contains "$out" "retired:" "a ship without a debrief was retired"
  [ -f "$dir/home/state/missing-ship.meta" ] || fail "missing-debrief record was removed"
  [ -f "$dir/home/state/empty-ship.meta" ] || fail "empty-debrief record was removed"
  [ ! -e "$dir/teardown.log" ] || fail "teardown ran without a debrief"
  [ "$(cat "$dir/home/state/missing-ship.auto-retire")" = $'retry\t1\tdebrief-missing' ] \
    || fail "absent debrief did not record its first retry"
  [ "$(cat "$dir/home/state/empty-ship.auto-retire")" = $'retry\t1\tdebrief-missing' ] \
    || fail "empty debrief did not record its first retry"
  [ ! -e "$dir/home/data/missing-ship/debrief.md" ] \
    || fail "absent debrief still produced a home copy"
  plant_ship_debrief "$dir" missing-ship
  out=$(run_retire "$dir") || fail "debrief retry pass failed: $out"
  assert_contains "$out" "retired: missing-ship (merged PR)" \
    "a later cycle did not retire once the debrief appeared"
  assert_contains "$out" "refused: empty-ship (transient debrief-missing attempt 2/5)" \
    "empty debrief did not retain its retry count"
  grep -qx 'debrief-present-at-teardown missing-ship' "$dir/teardown.log" \
    || fail "retry teardown ran before the home debrief copy landed"
  [ -s "$dir/home/data/missing-ship/debrief.md" ] || fail "retry did not copy the debrief home"
  [ ! -e "$dir/home/state/missing-ship.auto-retire" ] \
    || fail "successful debrief retry left its attempt sidecar behind"
  i=3
  while [ "$i" -le 5 ]; do
    out=$(run_retire "$dir") || fail "empty debrief pass $i failed: $out"
    i=$((i + 1))
  done
  assert_contains "$out" "refused: empty-ship (transient debrief-missing exhausted after 5 attempts)" \
    "permanently empty debrief did not exhaust its retries"
  assert_contains "$(cat "$dir/home/state/empty-ship.auto-retire")" \
    $'refused\ttransient-exhausted reason=debrief-missing attempts=5:' \
    "empty debrief sticky refusal did not retain its class and attempt count"
  out=$(run_retire "$dir") || fail "parked empty debrief pass failed: $out"
  [ -z "$out" ] || fail "empty debrief was retried after its attempt limit: $out"
  [ -f "$dir/home/state/empty-ship.meta" ] || fail "empty-debrief record was removed on retry"
  pass "a missing debrief retries until available and parks after five failed attempts"
}

test_merged_done_ship_is_retired
test_done_scout_with_report_is_retired
test_open_pr_and_working_ship_are_left_alone
test_gh_fail_is_unclassified_and_untouched
test_teardown_refusal_never_claims_retirement_or_a_decision
test_transient_refusal_retries_until_teardown_succeeds
test_permanent_transient_refusal_parks_after_five_attempts
test_presentation_lock_refusal_is_transient
test_permanent_refusal_replaces_an_existing_retry_mark
test_secondmate_and_reportless_scout_are_left_alone
test_working_appended_during_forge_lookup_is_refused
test_watcher_surfaces_one_retirement
test_merged_done_ship_without_debrief_is_refused
