#!/usr/bin/env bash
# Automatic retirement selects finished merged ships and done scouts, then
# calls ordinary teardown without --force. Refusals stay refusals and are
# not retried. Unclassifiable records are reported and left untouched.
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
if [ -f "$dir/refuse/\$id" ]; then
  echo "REFUSED: worktree has uncommitted changes." >&2
  exit 1
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
  printf 'done: PR merged\n' > "$dir/home/state/merged-ship.status"
  out=$(run_retire "$dir") || fail "merged ship retire failed: $out"
  assert_contains "$out" "retired: merged-ship (merged PR)" "merged ship was not retired"
  [ ! -e "$dir/home/state/merged-ship.meta" ] || fail "merged ship meta survived"
  grep -qx 'teardown merged-ship' "$dir/teardown.log" || fail "teardown was not invoked without extra flags"
  grep -q 'slack message retired merged-ship (merged PR)' "$dir/slack.log" \
    || fail "slack line missing: $(cat "$dir/slack.log" 2>/dev/null)"
  pass "a done ship with a merged PR is retired through ordinary teardown"
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

test_merged_done_ship_is_retired
test_done_scout_with_report_is_retired
test_open_pr_and_working_ship_are_left_alone
test_gh_fail_is_unclassified_and_untouched
test_teardown_refusal_never_claims_retirement_or_a_decision
test_secondmate_and_reportless_scout_are_left_alone
test_working_appended_during_forge_lookup_is_refused
test_watcher_surfaces_one_retirement
