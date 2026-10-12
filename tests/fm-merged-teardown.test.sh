#!/usr/bin/env bash
# Behavior tests for bin/fm-merged-teardown.check.sh, the merged-PR teardown actuator.
#
# The check runs as the registered state/merged-teardown.check.sh on the
# watcher's normal scheduling sweep. These cases pin the one-shot event
# contract using a scratch home whose gh (fakebin) and fm-teardown.sh stub
# decide the outcome:
#
#   1. A ship task whose latest status line is `done [at=<epoch>]: PR <url>`
#      with gh reporting MERGED -> fm-teardown.sh fires exactly once.
#   2. A second sweep of the same home -> no teardown (ack marker).
#   3. gh reporting CLOSED -> one `closed-no-merge: <id>` wake, no teardown,
#      and nothing on the sweep after that.
#   4. gh reporting OPEN -> nothing happens.
#   5. fm-teardown.sh refusing (unlanded work) -> one
#      `teardown-refused: <id>: <reason>` wake, no done ack.
#
# No case ever contacts a forge; gh is the fakebin shim and fm-teardown.sh is
# a fixture stub.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-merged-teardown.check.sh"
TMP_ROOT=$(fm_test_tmproot fm-merged-teardown)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
GH_STATE="$TMP_ROOT/gh-state" # one PR state per line; the fake consumes head -1
GH_LOG="$TMP_ROOT/gh.log"
TEARDOWN_LOG="$TMP_ROOT/teardown.log"
install_gh() {
  cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
# fakebin gh: consumes one state per invocation from $GH_STATE, logs the call
# to $GH_LOG, and answers `gh pr view ... --json state` with that state. The
# fixture writes states in call order so agent re-polls after an event stay
# observable and deterministic.
printf '%s\n' "$*" >>"${GH_LOG:?}"
state=$(head -n 1 "$GH_STATE" 2>/dev/null) || exit 1
[ -n "$state" ] || exit 1
tmp=$(mktemp)
sed -e '1d' "$GH_STATE" > "$tmp"
cat "$tmp" > "$GH_STATE"
rm -f -- "$tmp"
printf '%s\n' "$state"
SH
  chmod +x "$FAKEBIN/gh"
}

gh_states() {
  : > "$GH_LOG"
  printf '%s\n' "$@" > "$GH_STATE"
}

install_teardown_stub() {
  # <exit-code> <stderr-line>
  local rc=$1 line=$2
  cat > "$FAKEBIN/teardown.sh" <<SH
#!/usr/bin/env bash
# fm-merged-teardown test stub: records the invocation then returns the fixture's
# verdict. The executable-interface seam the check resolves through
# FM_MERGED_TEARDOWN_TEARDOWN_BIN.
printf '%s\n' "\$1" >>"${TEARDOWN_LOG:?}"
[ -z "$line" ] || printf '%s\n' '$line' >&2
exit $rc
SH
  chmod 0700 "$FAKEBIN/teardown.sh"
  : > "$TEARDOWN_LOG"
}

make_home() {
  local name=$1
  printf '%s\n' "$TMP_ROOT/$name"
}

make_ship_task() {
  local home=$1 id=$2 status_line=$3 kind=${4:-ship}
  mkdir -p "$home/state"
  meta "$home" "$id" "$kind"
  printf '%s\n' "$status_line" > "$home/state/$id.status"
}

meta() {
  local home=$1 id=$2 kind=$3
  cat > "$home/state/$id.meta" <<EOF
window=default:w1:p1
endpoint_task_id=$id
worktree=$home/nowhere
project=/nowhere/real
harness=omp
kind=$kind
mode=direct-PR
yolo=off
branch=fm/$id
EOF
}

run_check() {
  local home=$1
  FM_HOME="$home" PATH="$FAKEBIN:$PATH" \
    FM_MERGED_TEARDOWN_TEARDOWN_BIN="$FAKEBIN/teardown.sh" \
    GH_LOG="$GH_LOG" GH_STATE="$GH_STATE" \
    "$CHECK" 2>&1
}

run_dry() {
  local home=$1
  FM_HOME="$home" PATH="$FAKEBIN:$PATH" \
    FM_MERGED_TEARDOWN_TEARDOWN_BIN="$FAKEBIN/teardown.sh" \
    GH_LOG="$GH_LOG" GH_STATE="$GH_STATE" \
    "$CHECK" dry-run 2>&1
}

gh_calls() {
  wc -l < "$GH_LOG" | tr -d ' '
}

teardown_calls() {
  wc -l < "$TEARDOWN_LOG" | tr -d ' '
}

ack_dir() { printf '%s\n' "$TMP_ROOT/$1/state/.merged-teardown-acks"; }
id_ack() { printf '%s\n' "$(ack_dir "$1")/$2.$3"; }

test_done_merged_tears_down_once() {
  local home first second
  home=$(make_home merged-once)
  install_gh; install_teardown_stub 0 ""
  make_ship_task "$home" fm-a1 \
    'done [at=1791816290]: PR https://github.com/bluejay-creators/firstmate/pull/1'
  gh_states MERGED MERGED

  first=$(run_check "$home")
  expect_code 0 "$?" "first sweep exit"
  assert_contains "$first" "merged-teardown: fm-a1 torn down after PR merge" \
    "first sweep wake line"
  assert_equals "1" "$(teardown_calls)" "teardown fired once: stub call count"
  [ "$(cat "$TEARDOWN_LOG")" = fm-a1 ] ||
    fail "teardown was invoked for the wrong id: $(cat "$TEARDOWN_LOG")"
  assert_present "$(id_ack merged-once fm-a1 "done")" ".done ack marker"
  assert_absent "$(id_ack merged-once fm-a1 teardown-refused)" \
    "no teardown-refused ack after success"

  # Second sweep: nothing despite the status line still being there.
  second=$(run_check "$home")
  expect_code 0 "$?" "second sweep exit"
  [ -z "$second" ] || fail "second sweep printed unexpected wake: $second"
  assert_equals "1" "$(teardown_calls)" "no teardown rerun after ack"
  # gh_states resets the gh log, so a fresh seed exposes a re-query as 1:
  # the ack must stop the sweep before it ever asks gh again.
  gh_states MERGED
  third=$(run_check "$home")
  expect_code 0 "$?" "third sweep exit"
  [ -z "$third" ] || fail "third sweep printed unexpected wake: $third"
  assert_equals "0" "$(gh_calls)" "no gh re-query for an acked task"
  pass "done + MERGED tears down exactly once, then stays quiet"
}

test_closed_no_merge_wakes_once_never_tears_down() {
  local home first second
  home=$(make_home closed-once)
  install_gh; install_teardown_stub 0 ""
  make_ship_task "$home" fm-c7 \
    'done [at=1791816290]: PR https://github.com/bluejay-creators/setup/pull/28'
  gh_states CLOSED CLOSED

  first=$(run_check "$home")
  expect_code 0 "$?" "closed sweep exit"
  assert_contains "$first" "closed-no-merge: fm-c7" "closed-no-merge wake"
  assert_equals "0" "$(teardown_calls)" "no teardown on a rimmed PR"
  assert_present "$(id_ack closed-once fm-c7 closed-no-merge)" \
    "closed-no-merge ack marker"

  second=$(run_check "$home")
  expect_code 0 "$?" "post-closed sweep exit"
  [ -z "$second" ] || fail "post-closed sweep woke again: $second"
  gh_states CLOSED
  third=$(run_check "$home")
  expect_code 0 "$?" "third closed sweep exit"
  [ -z "$third" ] || fail "third closed sweep woke again: $third"
  assert_equals "0" "$(gh_calls)" "no gh re-query after closed-no-merge ack"
}

test_open_leaves_alone() {
  local home out
  home=$(make_home open-quiet)
  install_gh; install_teardown_stub 0 ""
  make_ship_task "$home" fm-o3 \
    'paused [at=1791816290]: PR https://github.com/bluejay-creators/firstmate/pull/1 up, awaiting captain merge of https://github.com/bluejay-creators/firstmate/pull/1'
  gh_states OPEN OPEN

  out=$(run_check "$home")
  expect_code 0 "$?" "open sweep exit"
  [ -z "$out" ] || fail "open PR printed a wake: $out"
  assert_equals "0" "$(teardown_calls)" "no teardown on an OPEN PR"
  [ -e "$(id_ack open-quiet fm-o3 "done")" ] && fail "premature .done ack on OPEN"
  [ -e "$(id_ack open-quiet fm-o3 closed-no-merge)" ] && fail "premature closed ack on OPEN"

  # Later tick, still open: the check keeps watching and still stays quiet.
  out=$(run_check "$home")
  [ -z "$out" ] || fail "second open sweep woke: $out"
  pass "OPEN leaves the task alone and silent"
}

test_teardown_refusal_wakes_once() {
  local home first second
  home=$(make_home refuse-once)
  install_gh; install_teardown_stub 1 "refusing: worktree holds unlanded work"
  make_ship_task "$home" fm-r9 \
    'done [at=1791816290]: PR https://github.com/bluejay-creators/firstmate/pull/1'
  gh_states MERGED MERGED

  first=$(run_check "$home")
  expect_code 0 "$?" "refusal sweep exit"
  assert_contains "$first" "teardown-refused: fm-r9: refusing: worktree holds unlanded work" \
    "teardown-refused wake carries the reason"
  assert_present "$(id_ack refuse-once fm-r9 teardown-refused)" \
    "teardown-refused ack marker"
  assert_absent "$(id_ack refuse-once fm-r9 "done")" "no .done ack after refusal"

  second=$(run_check "$home")
  expect_code 0 "$?" "post-refusal sweep exit"
  [ -z "$second" ] || fail "refusal woke twice: $second"
  [ "$(gh_calls)" -le 1 ] || fail "refusal path re-queried gh after the ack"
  pass "teardown refusal wakes once with the reason and backs off"
}

test_only_ship_kind_dispatches() {
  local home out
  home=$(make_home kinds-filtered)
  install_gh; install_teardown_stub 0 ""
  make_ship_task "$home" fm-s2 \
    'done [at=1791816290]: PR https://github.com/bluejay-creators/firstmate/pull/1' \
    scout
  gh_states MERGED

  out=$(run_check "$home")
  expect_code 0 "$?" "non-ship sweep exit"
  [ -z "$out" ] || fail "a non-ship task was dispatched: $out"
  assert_equals "0" "$(gh_calls)" "gh queried for a non-ship task"
  assert_equals "0" "$(teardown_calls)" "teardown ran for a non-ship task"
  pass "only kind=ship tasks dispatch"
}

test_dry_run_reports_without_dispatching() {
  local home out
  home=$(make_home dry-run)
  install_gh; install_teardown_stub 0 ""
  make_ship_task "$home" fm-d4 \
    'done [at=1791816290]: PR https://github.com/bluejay-creators/firstmate/pull/1'
  gh_states MERGED

  out=$(run_dry "$home")
  expect_code 0 "$?" "dry-run exit"
  assert_contains "$out" "merged-teardown(dry): fm-d4 would be torn down" \
    "dry-run reports the would-be dispatch"
  assert_equals "0" "$(teardown_calls)" "dry-run ran teardown"
  [ -e "$(id_ack dry-run fm-d4 "done")" ] && fail "dry-run stamped the ack"
  pass "dry-run reports the dispatch intent without acting"
}

test_dry_run_empty_fleet_prints_noop() {
  local home out
  home=$(make_home dry-empty)
  install_gh; install_teardown_stub 0 ""
  mkdir -p "$home/state"
  gh_states
  out=$(run_dry "$home")
  expect_code 0 "$?" "empty dry-run exit"
  assert_contains "$out" "dry-run no-op" "empty fleet dry-run announces the no-op"
  assert_equals "0" "$(gh_calls)" "empty fleet queried gh"
  pass "dry-run with no eligible tasks prints dry-run no-op"
}

test_help_and_usage() {
  local out rc=0
  out=$("$CHECK" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "check" "--help lists check"
  assert_contains "$out" "arm" "--help lists arm"
  assert_contains "$out" "disarm" "--help lists disarm"
  assert_contains "$out" "dry-run" "--help lists dry-run"
  rc=0
  out=$("$CHECK" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown action must refuse with 2"
  assert_contains "$out" "unknown action" "usage error names the bad action"
  pass "--help documents the actions; unknown action refuses"
}

test_done_merged_tears_down_once
test_closed_no_merge_wakes_once_never_tears_down
test_open_leaves_alone
test_teardown_refusal_wakes_once
test_only_ship_kind_dispatches
test_dry_run_reports_without_dispatching
test_dry_run_empty_fleet_prints_noop
test_help_and_usage
