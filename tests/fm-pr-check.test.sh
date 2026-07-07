#!/usr/bin/env bash
# Tests for bin/fm-pr-check.sh and the merge-attribution it arms.
#
# fm-pr-check.sh records the PR's CI check count (so the merge path can tell a
# real green from a vacuous one) and generates state/<id>.check.sh, the watcher's
# per-task poll. That generated check.sh must ATTRIBUTE a merge, not merely detect
# it: a merge firstmate performed (marked by merged_by_firstmate in meta) stays
# silent, a merge firstmate did NOT perform emits a distinct unattributed-merge:
# wake, and an unreadable PR state warns rather than assuming the PR is unmerged.
#
# The attribution rule itself lives in bin/fm-merge-attribution-lib.sh, exercised
# here through both the generated check.sh and the heartbeat fleet-scan
# (fm_merge_scan_unattributed) that the watcher backstop uses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-check-tests)

# --- fixtures ---------------------------------------------------------------

# A task sandbox with a ship meta and an empty fakebin. Echoes the case dir.
make_check_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/fakebin" "$case_dir/wt"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/proj" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' "$case_dir"
}

# gh stub used while ARMING (fm-pr-check reads headRefOid + statusCheckRollup from
# the worktree). <checks> is echoed for the statusCheckRollup length query, or the
# token "err" to simulate an unreadable count (gh exits non-zero -> pr_checks
# stays unknown).
write_gh_arm_stub() {
  local case_dir=$1 checks=$2
  if [ "$checks" = err ]; then
    cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *headRefOid*) printf '%s\n' 'abc123' ;;
  *statusCheckRollup*) exit 1 ;;
esac
exit 0
SH
  else
    cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *headRefOid*) printf '%s\n' 'abc123' ;;
  *statusCheckRollup*) printf '%s\n' '$checks' ;;
esac
exit 0
SH
  fi
  chmod +x "$case_dir/fakebin/gh"
}

# gh stub used while RUNNING the generated check.sh: answers the PR state and, for
# the merged-by lookup, a login. <state> may be OPEN/MERGED/CLOSED or "" to
# simulate an unreadable state.
write_gh_state_stub() {
  local case_dir=$1 state=$2 mergedby=${3:-someuser}
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *' --json state '*) [ -n '$state' ] && printf '%s\n' '$state' ;;
  *' --json mergedBy '*) printf '%s\n' '$mergedby' ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

arm() {
  local case_dir=$1 url=$2 checks=${3:-0}
  write_gh_arm_stub "$case_dir" "$checks"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_GUARD_GRACE=999999 \
    PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-x1 "$url" >/dev/null 2>&1
}

run_check_sh() {
  local case_dir=$1
  PATH="$case_dir/fakebin:$PATH" bash "$case_dir/state/task-x1.check.sh"
}

# --- generated check.sh attribution -----------------------------------------

test_attributed_merge_is_silent() {
  local case_dir url out
  case_dir=$(make_check_case attributed)
  url="https://github.com/example/repo/pull/13"
  arm "$case_dir" "$url" 2
  # firstmate merged it: the marker fm-pr-merge writes before its own merge.
  printf 'merged_by_firstmate=%s\n' "$url" >> "$case_dir/state/task-x1.meta"
  write_gh_state_stub "$case_dir" MERGED kevin
  out=$(run_check_sh "$case_dir")
  [ -z "$out" ] || fail "attributed merge should be silent, got: $out"
  pass "generated check.sh stays silent for a firstmate-attributed merge"
}

test_unattributed_merge_wakes_once() {
  local case_dir url out n
  case_dir=$(make_check_case unattributed)
  url="https://github.com/example/repo/pull/13"
  arm "$case_dir" "$url" 2
  # No marker: firstmate did not merge this. Out-of-band merge.
  write_gh_state_stub "$case_dir" MERGED kevin
  out=$(run_check_sh "$case_dir")
  assert_contains "$out" "unattributed-merge:" "expected an unattributed-merge wake"
  assert_contains "$out" "$url" "unattributed wake should name the PR"
  assert_contains "$out" "by kevin" "unattributed wake should name the merger"
  n=$(printf '%s\n' "$out" | grep -c 'unattributed-merge:')
  [ "$n" = 1 ] || fail "expected exactly one unattributed-merge line, got $n"
  out=$(run_check_sh "$case_dir")
  [ -z "$out" ] || fail "an unchanged unattributed outcome must not re-fire every poll, got: $out"
  pass "generated check.sh emits unattributed-merge once, not once per poll interval"
}

test_check_alarm_refires_on_distinct_outcome() {
  local case_dir url out
  case_dir=$(make_check_case outcome-change)
  url="https://github.com/example/repo/pull/13"
  arm "$case_dir" "$url" 2
  write_gh_state_stub "$case_dir" ""   # unreadable PR state
  out=$(run_check_sh "$case_dir")
  assert_contains "$out" "merge-state-unknown:" "first unknown outcome must alarm"
  out=$(run_check_sh "$case_dir")
  [ -z "$out" ] || fail "an unchanged unknown outcome must stay silent, got: $out"
  write_gh_state_stub "$case_dir" MERGED kevin
  out=$(run_check_sh "$case_dir")
  assert_contains "$out" "unattributed-merge:" \
    "a distinct outcome (unknown -> unattributed) must alarm again"
  pass "generated check.sh re-alarms when the outcome changes, once per distinct outcome"
}

test_benign_outcome_resets_alarm_dedupe() {
  local case_dir url out
  case_dir=$(make_check_case benign-reset)
  url="https://github.com/example/repo/pull/13"
  arm "$case_dir" "$url" 2
  write_gh_state_stub "$case_dir" ""   # unreadable PR state: first episode
  out=$(run_check_sh "$case_dir")
  assert_contains "$out" "merge-state-unknown:" "first unknown episode must alarm"
  write_gh_state_stub "$case_dir" OPEN  # readable again: benign, clears the record
  out=$(run_check_sh "$case_dir")
  [ -z "$out" ] || fail "a benign outcome should be silent, got: $out"
  write_gh_state_stub "$case_dir" ""   # second distinct episode
  out=$(run_check_sh "$case_dir")
  assert_contains "$out" "merge-state-unknown:" \
    "a new anomaly episode after a benign read must alarm again"
  pass "a benign outcome resets the dedupe so a later anomaly episode alarms again"
}

test_sibling_marker_does_not_attribute_other_pr() {
  local case_dir url_sib url out
  case_dir=$(make_check_case sibling)
  url_sib="https://github.com/example/repo/pull/15"
  url="https://github.com/example/repo/pull/13"
  # firstmate merged the SIBLING PR (#15) on the same branch; the marker names
  # #15 only. Attribution is by PR number, never branch, so #13 must NOT be
  # treated as firstmate-merged.
  arm "$case_dir" "$url" 2
  printf 'merged_by_firstmate=%s\n' "$url_sib" >> "$case_dir/state/task-x1.meta"
  write_gh_state_stub "$case_dir" MERGED kevin
  out=$(run_check_sh "$case_dir")
  assert_contains "$out" "unattributed-merge:" \
    "a marker for a sibling PR must not attribute this PR's merge"
  pass "attribution is keyed by PR number, not branch: a sibling marker does not silence this PR"
}

test_unknown_state_warns_never_assumes_unmerged() {
  local case_dir url out
  case_dir=$(make_check_case unknown-state)
  url="https://github.com/example/repo/pull/13"
  arm "$case_dir" "$url" 2
  write_gh_state_stub "$case_dir" ""   # unreadable PR state
  out=$(run_check_sh "$case_dir")
  assert_contains "$out" "merge-state-unknown:" \
    "an unreadable PR state must warn loudly, never silently assume unmerged"
  pass "generated check.sh warns on an unreadable PR state instead of assuming not-merged"
}

test_open_pr_is_silent() {
  local case_dir url out
  case_dir=$(make_check_case open-pr)
  url="https://github.com/example/repo/pull/13"
  arm "$case_dir" "$url" 2
  write_gh_state_stub "$case_dir" OPEN
  out=$(run_check_sh "$case_dir")
  [ -z "$out" ] || fail "an open PR should be silent, got: $out"
  pass "generated check.sh stays silent while the PR is still open"
}

# --- pr_checks recording ----------------------------------------------------

test_records_zero_check_count() {
  local case_dir
  case_dir=$(make_check_case checks-zero)
  arm "$case_dir" "https://github.com/example/repo/pull/9" 0
  assert_grep "pr_checks=0" "$case_dir/state/task-x1.meta" \
    "a definite zero-check PR must record pr_checks=0"
  pass "fm-pr-check records pr_checks=0 for a no-CI PR"
}

test_records_positive_check_count() {
  local case_dir
  case_dir=$(make_check_case checks-positive)
  arm "$case_dir" "https://github.com/example/repo/pull/9" 3
  assert_grep "pr_checks=3" "$case_dir/state/task-x1.meta" \
    "a PR with 3 checks must record pr_checks=3"
  pass "fm-pr-check records a positive pr_checks count"
}

test_records_unknown_check_count_on_unreadable() {
  local case_dir
  case_dir=$(make_check_case checks-unknown)
  arm "$case_dir" "https://github.com/example/repo/pull/9" err
  assert_grep "pr_checks=unknown" "$case_dir/state/task-x1.meta" \
    "an unreadable check count must record pr_checks=unknown, never 0"
  pass "fm-pr-check records pr_checks=unknown when the count cannot be read"
}

test_rearm_replaces_stale_check_count() {
  local case_dir
  case_dir=$(make_check_case checks-rearm)
  arm "$case_dir" "https://github.com/example/repo/pull/9" 0
  arm "$case_dir" "https://github.com/example/repo/pull/9" 3
  assert_grep "pr_checks=3" "$case_dir/state/task-x1.meta" \
    "re-arming must reflect the latest check count"
  [ "$(grep -c '^pr_checks=' "$case_dir/state/task-x1.meta")" = 1 ] \
    || fail "re-arming must replace, not accumulate, pr_checks lines"
  pass "fm-pr-check replaces a stale pr_checks on re-arm rather than accumulating"
}

# --- heartbeat fleet-scan backstop ------------------------------------------

test_scan_reports_only_unattributed_ship_prs() {
  local case_dir state out
  case_dir="$TMP_ROOT/scan"
  state="$case_dir/state"
  mkdir -p "$state" "$case_dir/fakebin"
  # Every PR reads MERGED; attribution turns on the marker, not gh.
  write_gh_state_stub "$case_dir" MERGED kevin
  fm_write_meta "$state/task-un.meta"  "kind=ship"      "pr=https://github.com/example/repo/pull/13"
  fm_write_meta "$state/task-attr.meta" "kind=ship"     "pr=https://github.com/example/repo/pull/15" \
    "merged_by_firstmate=https://github.com/example/repo/pull/15"
  fm_write_meta "$state/task-scout.meta" "kind=scout"   "pr=https://github.com/example/repo/pull/16"
  fm_write_meta "$state/task-nopr.meta"  "kind=ship"
  # A marker for a SIBLING PR must not shield this task's own pr= from the scan:
  # the backstop uses the same exact-URL attribution rule as the per-task check.
  fm_write_meta "$state/task-sib.meta"   "kind=ship"    "pr=https://github.com/example/repo/pull/17" \
    "merged_by_firstmate=https://github.com/example/repo/pull/18"
  out=$(PATH="$case_dir/fakebin:$PATH" bash -c '. "'"$ROOT"'/bin/fm-merge-attribution-lib.sh"; fm_merge_scan_unattributed "'"$state"'"')
  assert_contains "$out" "task-un" "scan must report the unattributed ship PR"
  assert_contains "$out" "task-sib" "a sibling-PR marker must not attribute this PR in the scan"
  assert_not_contains "$out" "task-attr" "scan must not report a firstmate-attributed merge"
  assert_not_contains "$out" "task-scout" "scan must skip scout tasks"
  assert_not_contains "$out" "task-nopr" "scan must skip tasks with no recorded PR"
  pass "fm_merge_scan_unattributed reports only unattributed ship-task merges, keyed by exact PR URL"
}

test_attributed_merge_is_silent
test_unattributed_merge_wakes_once
test_check_alarm_refires_on_distinct_outcome
test_benign_outcome_resets_alarm_dedupe
test_sibling_marker_does_not_attribute_other_pr
test_unknown_state_warns_never_assumes_unmerged
test_open_pr_is_silent
test_records_zero_check_count
test_records_positive_check_count
test_records_unknown_check_count_on_unreadable
test_rearm_replaces_stale_check_count
test_scan_reports_only_unattributed_ship_prs
