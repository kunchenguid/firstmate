#!/usr/bin/env bash
# The weekly backlog pruner, driven through the real bin/fm-backlog-pruner.sh,
# the real tasks-axi and a fixture backlog. Assertions are on the files the
# captain would read: the backlog, the fog file, the report and the check line.
#   1. A dry run moves nothing, writes no ledger, and reports what it would do.
#   2. --apply moves every queued item idle for 7 days, in one tasks-axi mv, and
#      keeps held calls, recent items, in-flight items and whole dependency sets.
#   3. An item citing only merged PRs is listed with the URL and never moved.
#      An item citing one merged and one open PR is not listed.
#   4. An edited note counts as a change, so the item stays.
#   5. `check` runs once per interval, stays silent when idle, and arm/disarm
#      bind and remove the watcher check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found (required by the move)"; exit 0; }

PRUNER="$ROOT/bin/fm-backlog-pruner.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-pruner)
NOW=$(date -u -d '2026-10-05 12:00:00' +%s)

make_gh() {  # <dir> -> echoes fakebin dir; PR 11 and 12 are merged, 13 is open
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
number=
for a in "$@"; do case "$a" in number=*) number=${a#number=} ;; esac; done
case "$number" in
  11|12) printf 'state=MERGED\nmerged=true\n' ;;
  13) printf 'state=OPEN\nmerged=false\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fb/gh"
  printf '%s\n' "$fb"
}

write_backlog() {  # <home>
  cat > "$1/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] running-work - Work a crewmate is doing (repo: proj) (kind: ship) (since 2026-09-01)
  Long running and old on purpose.

## Queued
- [ ] stale-plain - Idle for weeks (repo: proj) (kind: ship) (since 2026-09-10)
  Nothing happened here.
- [ ] stale-edge - Idle for exactly the window (repo: proj) (kind: ship) (since 2026-09-28)
  Created 7 days before the run.
- [ ] recent-item - Created inside the window (repo: proj) (kind: ship) (since 2026-09-29)
  Created 6 days before the run.
- [ ] stale-held - A captain call (repo: proj) (kind: captain) (since 2026-09-01) (hold: waiting for the captain) (hold-kind: captain)
  Captain hold set: 2026-09-01T10:00:00Z
- [ ] stale-blocker - Blocks a recent item (repo: proj) (kind: ship) (since 2026-09-02)
  Idle, but a recent item depends on it.
- [ ] recent-dependent - Depends on the stale blocker blocked-by: stale-blocker (repo: proj) (kind: ship) (since 2026-10-03)
  New.
- [ ] stale-dependent - Blocked by running work blocked-by: running-work (repo: proj) (kind: ship) (since 2026-09-03)
  Idle, but its blocker is in flight.
- [ ] stale-merged - Shipped already (repo: proj) (kind: ship) (since 2026-09-04)
  Landed in https://github.com/o/r/pull/11 and https://github.com/o/r/pull/12 last week.
- [ ] stale-half-merged - Two PRs, one still open (repo: proj) (kind: ship) (since 2026-09-05)
  See https://github.com/o/r/pull/11 and https://github.com/o/r/pull/13.
- [ ] stale-dep-a - First of a stale pair (repo: proj) (kind: ship) (since 2026-09-06)
  Idle.
- [ ] stale-dep-b - Second of a stale pair blocked-by: stale-dep-a (repo: proj) (kind: ship) (since 2026-09-06)
  Idle.

## Done
EOF
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/data" "$home/state"
  chmod 700 "$home/state"
  write_backlog "$home"
  printf '%s\n' "$home"
}

run_pruner() {  # <home> <fakebin> <args...>
  local home=$1 fb=$2; shift 2
  env PATH="$fb:$PATH" FM_HOME="$home" FM_BACKLOG_PRUNER_NOW="$NOW" "$PRUNER" "$@"
}

ids_in() {  # <file> -> ids of its items, one per line
  sed -n 's/^- \[[ xX]\] \([^ ]*\) - .*/\1/p' "$1"
}

test_dry_run_moves_nothing() {
  local dir home fb out before report
  dir="$TMP_ROOT/dry"; mkdir -p "$dir"
  fb=$(make_gh "$dir"); home=$(setup_home dry)
  before=$(cat "$home/data/backlog.md")
  out=$(run_pruner "$home" "$fb" run) || fail "the dry run failed: $out"
  assert_equals "$before" "$(cat "$home/data/backlog.md")" "a dry run changed the backlog"
  [ ! -e "$home/data/backlog-fog.md" ] || fail "a dry run wrote the fog file"
  [ ! -e "$home/state/backlog-pruner.seen" ] || fail "a dry run wrote the change ledger"
  report=$(cat "$home/data/backlog-prune-report.md")
  assert_contains "$report" "Would move to the fog (dry run)" "the report does not say it is a dry run"
  assert_contains "$report" "- stale-plain (since 2026-09-10)" "the report misses an idle item"
  assert_contains "$out" "would move 5 item(s) to the fog" "the summary count is wrong"
  pass "a dry run leaves the backlog alone and reports what it would move"
}

test_apply_moves_only_idle_items() {
  local dir home fb out
  dir="$TMP_ROOT/apply"; mkdir -p "$dir"
  fb=$(make_gh "$dir"); home=$(setup_home apply)
  out=$(run_pruner "$home" "$fb" run --apply) || fail "apply failed: $out"
  assert_contains "$out" "moved 5 item(s) to the fog" "the summary does not report the move"

  assert_contains "$(ids_in "$home/data/backlog-fog.md")" "stale-plain" "an idle item is not in the fog"
  assert_contains "$(ids_in "$home/data/backlog-fog.md")" "stale-edge" "an item idle for exactly the window is not in the fog"
  assert_contains "$(ids_in "$home/data/backlog-fog.md")" "stale-dep-a" "the stale pair was split"
  assert_contains "$(ids_in "$home/data/backlog-fog.md")" "stale-dep-b" "the stale pair was split"
  assert_contains "$(ids_in "$home/data/backlog-fog.md")" "stale-half-merged" "an idle item with an open PR is not in the fog"
  assert_not_contains "$(ids_in "$home/data/backlog.md")" "stale-plain" "a moved item is still in the backlog"

  local kept
  kept=$(ids_in "$home/data/backlog.md")
  for id in running-work recent-item stale-held stale-blocker recent-dependent stale-dependent stale-merged; do
    assert_contains "$kept" "$id" "$id must stay in the backlog"
  done
  assert_not_contains "$(ids_in "$home/data/backlog-fog.md")" "stale-merged" "an item citing merged PRs was moved instead of reported"
  pass "--apply moves idle items in one step and keeps held, recent, in-flight and dependency sets whole"
}

test_merged_pr_items_are_reported() {
  local dir home fb report
  dir="$TMP_ROOT/merged"; mkdir -p "$dir"
  fb=$(make_gh "$dir"); home=$(setup_home merged)
  run_pruner "$home" "$fb" run --apply >/dev/null || fail "apply failed"
  report=$(cat "$home/data/backlog-prune-report.md")
  assert_contains "$report" "- stale-merged (queued) - https://github.com/o/r/pull/11 https://github.com/o/r/pull/12" \
    "the report misses the merged-PR item or its URLs"
  assert_not_contains "${report#*Cite only}" "stale-half-merged" "an item with an open PR was reported as closable"
  pass "an item citing only merged PRs is reported with their URLs and an item with an open PR is not"
}

test_in_flight_item_citing_merged_pr_is_reported_not_closed() {
  local dir home fb report
  dir="$TMP_ROOT/inflight"; mkdir -p "$dir"
  fb=$(make_gh "$dir"); home=$(setup_home inflight)
  sed -i 's#^  Long running and old on purpose.#  Delivered as https://github.com/o/r/pull/11 already.#' "$home/data/backlog.md"
  run_pruner "$home" "$fb" run --apply >/dev/null || fail "apply failed"
  report=$(cat "$home/data/backlog-prune-report.md")
  assert_contains "$report" "- running-work (in_flight) - https://github.com/o/r/pull/11" "the in-flight item was not reported"
  assert_contains "$(ids_in "$home/data/backlog.md")" "running-work" "the in-flight item left the backlog"
  pass "an in-flight item citing a merged PR is reported and stays in flight"
}

test_edited_note_counts_as_change() {
  local dir home fb hash
  dir="$TMP_ROOT/edited"; mkdir -p "$dir"
  fb=$(make_gh "$dir"); home=$(setup_home edited)
  hash=$(sha256sum < /dev/null | cut -d' ' -f1)
  printf 'stale-plain\t%s\t%s\n' "$hash" "$((NOW - 30 * 86400))" > "$home/state/backlog-pruner.seen"
  run_pruner "$home" "$fb" run --apply >/dev/null || fail "apply failed"
  assert_contains "$(ids_in "$home/data/backlog.md")" "stale-plain" "an item whose text changed since the ledger was moved anyway"
  assert_contains "$(cat "$home/state/backlog-pruner.seen")" "stale-plain" "the ledger does not know the edited item"
  pass "an item edited since the last ledger run restarts its window"
}

test_check_runs_once_per_interval() {
  local dir home fb out
  dir="$TMP_ROOT/check"; mkdir -p "$dir"
  fb=$(make_gh "$dir"); home=$(setup_home check)
  out=$(run_pruner "$home" "$fb" check) || fail "check failed"
  assert_contains "$out" "backlog-pruner: would move 5 item(s) to the fog" "the first weekly check printed no report line"
  assert_contains "$out" "stale-merged https://github.com/o/r/pull/11 https://github.com/o/r/pull/12" "the check line misses the closable item"
  assert_equals "$NOW" "$(cat "$home/state/backlog-pruner.last")" "the check did not record its run"
  assert_contains "$(ids_in "$home/data/backlog.md")" "stale-plain" "an unarmed-for-apply check moved an item"

  out=$(run_pruner "$home" "$fb" check) || fail "second check failed"
  assert_equals "" "$out" "a second check inside the interval printed output"

  out=$(env PATH="$fb:$PATH" FM_HOME="$home" FM_BACKLOG_PRUNER_NOW="$((NOW + 8 * 86400))" "$PRUNER" check --apply) \
    || fail "later check failed"
  assert_contains "$out" "backlog-pruner: moved" "the later apply check did not move"
  assert_not_contains "$(ids_in "$home/data/backlog.md")" "stale-plain" "the apply check left the item"
  pass "check runs once per interval, reports when there is work, and moves only when armed to apply"
}

test_idle_check_is_silent() {
  local dir home fb out
  dir="$TMP_ROOT/silent"; mkdir -p "$dir"
  fb=$(make_gh "$dir"); home=$(setup_home silent)
  run_pruner "$home" "$fb" run --apply >/dev/null || fail "apply failed"
  sed -i '/stale-merged/,+1d' "$home/data/backlog.md"
  out=$(run_pruner "$home" "$fb" check) || fail "check failed"
  assert_equals "" "$out" "a check with nothing to report printed output"
  pass "a check with nothing to report stays silent"
}

test_arm_and_disarm() {
  local dir home fb
  dir="$TMP_ROOT/arm"; mkdir -p "$dir"
  fb=$(make_gh "$dir"); home=$(setup_home arm)
  run_pruner "$home" "$fb" arm >/dev/null || fail "arm failed"
  [ -x "$home/state/backlog-pruner.check.sh" ] || fail "arm wrote no executable check"
  [ -f "$home/state/backlog-pruner.check-trust" ] || fail "arm did not bind the check"
  assert_contains "$(cat "$home/state/backlog-pruner.check.sh")" "backlog-pruner.sh check" "the check does not call the pruner"
  assert_not_contains "$(cat "$home/state/backlog-pruner.check.sh")" "--apply" "a plain arm must stay a dry run"

  run_pruner "$home" "$fb" arm --apply >/dev/null || fail "arm --apply failed"
  assert_contains "$(cat "$home/state/backlog-pruner.check.sh")" "check --apply" "arm --apply did not switch the check to apply"

  run_pruner "$home" "$fb" disarm >/dev/null || fail "disarm failed"
  [ ! -e "$home/state/backlog-pruner.check.sh" ] || fail "disarm left the check"
  [ ! -e "$home/state/backlog-pruner.check-trust" ] || fail "disarm left the trust file"
  pass "arm binds the weekly check, --apply switches it to move, and disarm removes it"
}

test_dry_run_moves_nothing
test_apply_moves_only_idle_items
test_merged_pr_items_are_reported
test_in_flight_item_citing_merged_pr_is_reported_not_closed
test_edited_note_counts_as_change
test_check_runs_once_per_interval
test_idle_check_is_silent
test_arm_and_disarm
