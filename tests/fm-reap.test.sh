#!/usr/bin/env bash
# tests/fm-reap.test.sh - the stale-record reaper (bin/fm-reap.sh).
# Every case drives the executable against a disposable home whose worker
# endpoints, forge reads, staleness store, and action owners are PATH or
# FM_REAP_*_BIN fakes that log what they were asked to do. The suite pins the
# contract from the script header: a dry run changes nothing, only the safe
# classes reach an owner, --force is never passed, a dead worker with unlanded
# work is relaunched once and then escalated, a refused action is not retried
# until its evidence changes, and a staleness row closes only once its record
# is reaped or its orphaned work is proved landed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REAP="$ROOT/bin/fm-reap.sh"
TMP_ROOT=$(fm_test_tmproot fm-reap-tests)
fm_git_identity

# make_home <name> -> case dir with home/{state,data,config}, fakebin, and a
# per-window fake tmux directory. Fakes append one line per call to
# $FM_FAKE_LOG so a case can assert exactly which owners ran.
make_home() {
  local dir="$TMP_ROOT/$1" fakebin="$TMP_ROOT/$1/fakebin"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$fakebin" "$dir/tmux"
  : > "$dir/actions.log"
  # tmux: list-windows prints the file names under FM_FAKE_TMUX_DIR; the pane
  # command of a window is that file's content (zsh = a dead shell, claude = a
  # live agent). No pane_tty is reported, so the classifier reads the command.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=''
prev=''
for arg in "$@"; do
  [ "$prev" != -t ] || target=$arg
  prev=$arg
done
window=${target##*:}
window=${window#=}
case "${1:-}" in
  list-windows)
    for f in "${FM_FAKE_TMUX_DIR:?}"/*; do
      [ -e "$f" ] || continue
      printf '%s\n' "${f##*/}"
    done
    ;;
  display-message)
    case "${@: -1}" in
      '#{pane_tty}') printf '\n' ;;
      '#{pane_current_command}') cat "${FM_FAKE_TMUX_DIR:?}/$window" 2>/dev/null || printf '\n' ;;
    esac
    ;;
esac
exit 0
SH
  # gh-axi: the forge record for every PR the case asks about.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'state: %s\n' "${FM_FAKE_PR_STATE:-open}"
printf 'checks: "%s"\n' "${FM_FAKE_PR_CHECKS:-2 passed, 0 failed, 2 total}"
exit 0
SH
  # staleness: serves the fixture JSON and records every close.
  cat > "$fakebin/staleness" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list) [ -n "${FM_FAKE_STALENESS_JSON:-}" ] && cat "$FM_FAKE_STALENESS_JSON" ;;
  close) printf 'staleness %s\n' "$*" >> "${FM_FAKE_LOG:?}"; exit "${FM_FAKE_STALENESS_CLOSE_RC:-0}" ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
printf 'teardown %s\n' "$*" >> "${FM_FAKE_LOG:?}"
if [ "${FM_FAKE_TEARDOWN_RC:-0}" -ne 0 ]; then
  echo "REFUSED: fixture refusal for $1" >&2
  exit "$FM_FAKE_TEARDOWN_RC"
fi
exit 0
SH
  cat > "$fakebin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf 'control %s\n' "$*" >> "${FM_FAKE_LOG:?}"
exit 0
SH
  cat > "$fakebin/fm-pr-merge.sh" <<'SH'
#!/usr/bin/env bash
printf 'merge %s\n' "$*" >> "${FM_FAKE_LOG:?}"
exit 0
SH
  cat > "$fakebin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  verify) exit "${FM_FAKE_HOLD_VERIFY_RC:-0}" ;;
  open) exit "${FM_FAKE_HOLD_OPEN_RC:-1}" ;;
  hold) printf 'hold %s\n' "$*" >> "${FM_FAKE_LOG:?}"; exit 0 ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin"/*
  printf '%s\n' "$dir"
}

# add_record <dir> <id> <kind> <yolo> [meta line ...]: a project repo with a
# local origin, a worktree on branch fm/<id> holding one pushed commit, a dead
# tmux window, and the task record. Extra meta lines land after the standard
# ones so a `pr=` line keeps its identity-parser position at the end.
add_record() {
  local dir=$1 id=$2 kind=$3 yolo=$4 repo wt
  shift 4
  repo="$dir/$id.project"
  wt="$dir/$id.wt"
  fm_git_worktree "$repo" "$wt" "fm/$id"
  printf 'work\n' > "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -qm "fm/$id work"
  git -C "$wt" push -q origin "fm/$id"
  printf 'zsh\n' > "$dir/tmux/fm-$id"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$wt" "project=$repo" "harness=claude" \
    "kind=$kind" "mode=no-mistakes" "yolo=$yolo" "branch=fm/$id" "$@"
}

# land_record <dir> <id>: merge the task branch into main, push main, and
# record the merge notification the PR poller would have left.
land_record() {
  local dir=$1 id=$2 repo="$1/$2.project"
  git -C "$repo" merge -q --no-edit "fm/$id"
  git -C "$repo" push -q origin main
  mark_merge_notified "$dir/home/state" "$id" || fail "could not record the merge notification"
}

mark_merge_notified() {  # <state> <id>
  ( . "$ROOT/bin/fm-pr-lib.sh" && fm_pr_poll_merge_mark_notified "$1" "$2" github github.com acme/widgets 7 )
}

pr_line() { printf 'pr=https://github.com/acme/widgets/pull/%s' "${1:-7}"; }

# run_reap <dir> <args...>: run the reaper against the case home with every
# owner replaced by its fake; stdout and stderr are returned together.
run_reap() {
  local dir=$1
  shift
  env -u FM_SUPERVISION_ACTOR -u PI_CODING_AGENT \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$PATH" \
    FM_FAKE_LOG="$dir/actions.log" FM_FAKE_TMUX_DIR="$dir/tmux" \
    FM_REAP_TEARDOWN_BIN="$dir/fakebin/fm-teardown.sh" \
    FM_REAP_CONTROL_BIN="$dir/fakebin/fm-control.sh" \
    FM_REAP_PR_MERGE_BIN="$dir/fakebin/fm-pr-merge.sh" \
    FM_REAP_CAPTAIN_HOLD_BIN="$dir/fakebin/fm-captain-hold.sh" \
    FM_REAP_STALENESS_BIN="$dir/fakebin/staleness" \
    FM_REAP_MIN_AGE_SECS="${REAP_MIN_AGE:-0}" \
    "$REAP" "$@" 2>&1
}

line_for() {  # <output> <id> -> the record's line
  printf '%s\n' "$1" | grep -E "^$2 " || true
}

# assert_line <regex> <file> <msg> / assert_no_line: anchored owner-log checks.
assert_line() {
  grep -E -- "$1" "$2" >/dev/null || fail "$3; owner log: $(cat "$2")"
}

assert_no_line() {
  ! grep -E -- "$1" "$2" >/dev/null || fail "$3; owner log: $(cat "$2")"
}

# --- dry run and the untouchable classes --------------------------------------

test_dry_run_classifies_without_acting() {
  local dir out
  dir=$(make_home dry-run)
  add_record "$dir" landed ship off "$(pr_line)"
  land_record "$dir" landed
  add_record "$dir" alive ship off
  printf 'claude\n' > "$dir/tmux/fm-alive"
  add_record "$dir" blocked ship off
  printf 'blocked [at=1]: waiting on a credential\n' > "$dir/home/state/blocked.status"
  add_record "$dir" failing ship off
  printf 'failed [at=1]: build broke\n' > "$dir/home/state/failing.status"
  add_record "$dir" deciding ship off
  printf 'needs-decision [at=1]: which color\n' > "$dir/home/state/deciding.status"

  out=$(run_reap "$dir" scan)
  assert_contains "$(line_for "$out" landed)" "LANDED" "merged, clean, pushed record classifies as landed"
  assert_contains "$(line_for "$out" alive)" "ALIVE" "a live agent classifies as alive"
  assert_contains "$(line_for "$out" blocked)" "BLOCKED" "a blocked ledger is reported as blocked"
  assert_contains "$(line_for "$out" failing)" "FAILED" "a failed ledger is reported as failed"
  assert_contains "$(line_for "$out" deciding)" "NEEDS-DECISION" "a needs-decision ledger is reported as such"
  [ ! -s "$dir/actions.log" ] || fail "dry run reached an owner: $(cat "$dir/actions.log")"
  assert_present "$dir/home/state/landed.meta" "dry run removed a record"
  assert_absent "$dir/home/state/.wake-queue" "dry run appended a wake"

  out=$(run_reap "$dir" scan --actionable)
  assert_contains "$out" "landed LANDED" "--actionable keeps the pending teardown"
  assert_not_contains "$out" "alive" "--actionable prints nothing for a live agent"
  assert_not_contains "$out" "blocked" "--actionable prints nothing for a reported-only class"

  out=$(run_reap "$dir" scan --act)
  assert_line "^teardown landed$" "$dir/actions.log" "landed record was torn down without --force"
  [ "$(grep -c . "$dir/actions.log")" -eq 1 ] || fail "only the landed record may reach an owner: $(cat "$dir/actions.log")"
  assert_grep "check: reap landed teardown ok" "$dir/home/state/.wake-queue" "teardown outcome was queued as a check wake"
  pass "fm-reap: a dry run only classifies; --act tears down only the landed record and never a live, blocked, failed, or deciding one"
}

test_merged_pr_with_unlanded_work_is_never_torn_down() {
  local dir out
  dir=$(make_home merged-dirty)
  add_record "$dir" dirty ship off "$(pr_line)"
  land_record "$dir" dirty
  printf 'edit\n' >> "$dir/dirty.wt/work.txt"
  add_record "$dir" ahead ship off "$(pr_line 8)"
  land_record "$dir" ahead
  printf 'more\n' > "$dir/ahead.wt/more.txt"
  git -C "$dir/ahead.wt" add more.txt
  git -C "$dir/ahead.wt" commit -qm "unpushed follow-up"

  out=$(run_reap "$dir" scan --act)
  assert_contains "$(line_for "$out" dirty)" "DEAD-UNLANDED" "a merged PR with uncommitted changes stays dead-unlanded"
  assert_contains "$(line_for "$out" ahead)" "DEAD-UNLANDED" "a merged PR with an unpushed commit stays dead-unlanded"
  assert_no_line "^teardown" "$dir/actions.log" "unlanded work reached teardown"
  assert_present "$dir/home/state/dirty.meta" "record with uncommitted changes was removed"
  pass "fm-reap: a merged PR never lands a worktree that still holds uncommitted or unpushed work"
}

test_skips_young_secondmate_and_captain_held_records() {
  local dir out
  dir=$(make_home skips)
  add_record "$dir" young ship off "$(pr_line)"
  land_record "$dir" young
  fm_write_secondmate_meta "$dir/home/state/mate.meta" "$dir/mate-home"
  add_record "$dir" held ship off
  printf 'captain-held [at=1]: waiting for the captain\n' > "$dir/home/state/held.status"

  out=$(REAP_MIN_AGE=600 run_reap "$dir" scan --act)
  assert_contains "$(line_for "$out" young)" "SKIP" "a record changed moments ago is skipped"
  assert_contains "$(line_for "$out" mate)" "SKIP" "a secondmate record is skipped"
  assert_contains "$(line_for "$out" held)" "SKIP" "a captain-held record is skipped"
  [ ! -s "$dir/actions.log" ] || fail "a skipped record reached an owner: $(cat "$dir/actions.log")"

  fm_touch_epoch "$(( $(date +%s) - 3600 ))" "$dir/home/state/young.meta"
  out=$(REAP_MIN_AGE=600 run_reap "$dir" scan)
  assert_contains "$(line_for "$out" young)" "LANDED" "an aged record is classified"
  pass "fm-reap: young, secondmate, and captain-held records are skipped untouched"
}

# --- ghost slot ------------------------------------------------------------------

test_ghost_slot_uses_record_only_teardown() {
  local dir out repo
  dir=$(make_home ghost)
  repo="$dir/project"
  fm_git_init_commit "$repo"
  mkdir -p "$dir/pool/1"
  git -C "$repo" worktree add -q --detach "$dir/pool/1/project"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$dir/pool/1/project" > "$dir/pool/treehouse-state.json"
  printf 'zsh\n' > "$dir/tmux/fm-stale"
  fm_write_meta "$dir/home/state/stale.meta" \
    "window=firstmate:fm-stale" "endpoint_task_id=stale" \
    "worktree=$dir/pool/1/project" "project=$repo" "harness=claude" "kind=ship" \
    "mode=no-mistakes" "yolo=off" "branch=fm/stale"
  fm_write_meta "$dir/home/state/claimant.meta" \
    "window=firstmate:fm-claimant" "endpoint_task_id=claimant" \
    "worktree=$dir/pool/1/project" "project=$repo" "harness=claude" "kind=ship" \
    "mode=no-mistakes" "yolo=off" "branch=fm/claimant"
  printf 'claude\n' > "$dir/tmux/fm-claimant"
  printf 'task=claimant\nhome=%s\n' "$dir/home" > "$dir/pool/1/.fm-slot-owner"

  out=$(run_reap "$dir" scan --act)
  assert_contains "$(line_for "$out" stale)" "GHOST" "a record whose slot another task claims is a ghost"
  assert_contains "$(line_for "$out" claimant)" "ALIVE" "the claimant is left alone"
  assert_line "^teardown stale --record-only$" "$dir/actions.log" "ghost reaches teardown as record-only"
  assert_no_grep "claimant" "$dir/actions.log" "the live claimant reached an owner"

  # A ghost whose slot still sits on this task's branch with unpushed commits is
  # not a ghost: the evidence contradicts itself, so nothing is touched.
  : > "$dir/actions.log"
  git -C "$dir/pool/1/project" checkout -q -b fm/stale
  printf 'x\n' > "$dir/pool/1/project/x.txt"
  git -C "$dir/pool/1/project" add x.txt
  git -C "$dir/pool/1/project" commit -qm unpushed
  out=$(run_reap "$dir" scan --act --task stale)
  assert_contains "$(line_for "$out" stale)" "UNSURE" "a reassigned slot still on the task's branch with unpushed work is unsure"
  [ ! -s "$dir/actions.log" ] || fail "an unsure ghost reached an owner: $(cat "$dir/actions.log")"
  pass "fm-reap: a ghost slot retires through record-only teardown and an ambiguous one is left alone"
}

# --- scouts -----------------------------------------------------------------------

test_scout_done_tears_down_only_with_a_report_and_verified_calls() {
  local dir out
  dir=$(make_home scout)
  add_record "$dir" scouted scout off
  printf 'done [at=1]: report written\n' > "$dir/home/state/scouted.status"
  add_record "$dir" reportless scout off
  printf 'done [at=1]: finished\n' > "$dir/home/state/reportless.status"
  mkdir -p "$dir/home/data/scouted"
  printf '# findings\n' > "$dir/home/data/scouted/report.md"

  out=$(FM_FAKE_HOLD_VERIFY_RC=1 run_reap "$dir" scan --act)
  assert_contains "$(line_for "$out" scouted)" "SCOUT-DONE" "a done scout with a report is scout-done"
  assert_contains "$(line_for "$out" reportless)" "DEAD-UNLANDED" "a done scout without a report is dead-unlanded"
  [ ! -s "$dir/actions.log" ] || fail "a scout with unverified captain calls reached an owner: $(cat "$dir/actions.log")"

  out=$(run_reap "$dir" scan --act)
  assert_line "^teardown scouted$" "$dir/actions.log" "a scout with verified captain calls is torn down"
  assert_no_grep "reportless" "$dir/actions.log" "a reportless scout reached an owner"
  pass "fm-reap: a finished scout is torn down only once its report exists and its captain calls verify"
}

# --- open PRs -----------------------------------------------------------------------

test_merge_due_yolo_on_merges_only_green_unheld_prs() {
  local dir out
  dir=$(make_home merge-due)
  add_record "$dir" ready ship on "$(pr_line)"
  printf 'done [at=1]: PR https://github.com/acme/widgets/pull/7 checks green\n' > "$dir/home/state/ready.status"

  out=$(FM_FAKE_PR_CHECKS="1 passed, 1 failed, 2 total" run_reap "$dir" scan --act)
  assert_contains "$(line_for "$out" ready)" "MERGE-DUE" "an open PR on a done ship is merge-due"
  assert_contains "$(line_for "$out" ready)" "waiting" "red checks wait"
  assert_no_line "^merge" "$dir/actions.log" "a red PR reached the merge owner"

  out=$(FM_FAKE_HOLD_OPEN_RC=0 run_reap "$dir" scan --act)
  assert_contains "$(line_for "$out" ready)" "hold is open" "an open captain hold is reported"
  assert_no_line "^merge" "$dir/actions.log" "a held PR reached the merge owner"

  out=$(run_reap "$dir" scan --act)
  assert_line "^merge ready https://github.com/acme/widgets/pull/7$" "$dir/actions.log" "a green unheld PR is merged through the guarded owner"
  assert_grep "check: reap ready merge ok" "$dir/home/state/.wake-queue" "the merge outcome was queued"
  pass "fm-reap: with yolo on, only a green PR without an open captain hold reaches the merge owner"
}

test_merge_due_yolo_off_files_one_captain_hold() {
  local dir out
  dir=$(make_home merge-hold)
  add_record "$dir" ready ship off "$(pr_line)"
  printf 'done [at=1]: PR ready\n' > "$dir/home/state/ready.status"

  out=$(run_reap "$dir" scan --act)
  assert_contains "$(line_for "$out" ready)" "MERGE-DUE" "an open PR with yolo off is merge-due"
  assert_line "^hold hold ready --reason .*https://github.com/acme/widgets/pull/7" "$dir/actions.log" "a captain hold naming the PR is filed"
  assert_no_line "^merge" "$dir/actions.log" "yolo off reached the merge owner"

  out=$(run_reap "$dir" scan --act)
  assert_contains "$(line_for "$out" ready)" "already filed" "the second scan reports the hold as filed"
  [ "$(grep -c '^hold' "$dir/actions.log")" -eq 1 ] || fail "the captain hold was filed more than once: $(cat "$dir/actions.log")"
  pass "fm-reap: with yolo off, a ready PR files exactly one captain hold and then waits"
}

test_closed_pr_is_reported_only() {
  local dir out
  dir=$(make_home pr-closed)
  add_record "$dir" dropped ship on "$(pr_line)"
  printf 'done [at=1]: PR opened\n' > "$dir/home/state/dropped.status"
  out=$(FM_FAKE_PR_STATE=closed run_reap "$dir" scan --act)
  assert_contains "$(line_for "$out" dropped)" "PR-CLOSED" "a closed PR is pr-closed"
  [ ! -s "$dir/actions.log" ] || fail "a closed PR reached an owner: $(cat "$dir/actions.log")"
  assert_present "$dir/home/state/dropped.meta" "a closed PR's record was removed"
  pass "fm-reap: a PR closed without merging is reported and never torn down"
}

# --- dead workers -------------------------------------------------------------------

test_dead_unlanded_relaunches_once_then_escalates() {
  local dir out
  dir=$(make_home relaunch)
  add_record "$dir" dead ship off
  printf 'working [at=1]: half way\n' > "$dir/home/state/dead.status"
  printf 'wip\n' > "$dir/dead.wt/wip.txt"
  git -C "$dir/dead.wt" add wip.txt
  git -C "$dir/dead.wt" commit -qm wip

  out=$(run_reap "$dir" scan --act)
  assert_contains "$(line_for "$out" dead)" "DEAD-UNLANDED" "a dead worker with an unpushed commit is dead-unlanded"
  assert_line "^control dead relaunch --note " "$dir/actions.log" "the dead worker is relaunched through the control owner"
  assert_no_line "^teardown" "$dir/actions.log" "unlanded work reached teardown"

  out=$(run_reap "$dir" scan --act)
  assert_contains "$(line_for "$out" dead)" "escalated" "a worker dead again after its relaunch is escalated"
  [ "$(grep -c '^control' "$dir/actions.log")" -eq 1 ] || fail "the worker was relaunched more than once: $(cat "$dir/actions.log")"
  assert_grep "check: reap dead escalate" "$dir/home/state/.wake-queue" "the escalation was queued"

  out=$(run_reap "$dir" scan --actionable)
  [ -z "$(line_for "$out" dead)" ] || fail "an already-escalated record is still actionable: $out"
  run_reap "$dir" scan --act >/dev/null
  [ "$(grep -c 'reap dead escalate' "$dir/home/state/.wake-queue")" -eq 1 ] || fail "the escalation was queued more than once"
  assert_present "$dir/home/state/dead.meta" "a dead-unlanded record was removed"
  pass "fm-reap: a dead worker with unlanded work is relaunched once, then escalated once, never torn down"
}

test_dead_worker_with_uncommitted_changes_is_never_relaunched_blindly_or_torn_down() {
  local dir out
  dir=$(make_home dirty-dead)
  add_record "$dir" messy ship off
  printf 'edit\n' >> "$dir/messy.wt/work.txt"
  out=$(run_reap "$dir" scan --act)
  assert_contains "$(line_for "$out" messy)" "DEAD-UNLANDED" "uncommitted changes classify as dead-unlanded"
  assert_contains "$(line_for "$out" messy)" "reported only" "uncommitted changes are reported only"
  [ ! -s "$dir/actions.log" ] || fail "a worktree with uncommitted changes reached an owner: $(cat "$dir/actions.log")"
  pass "fm-reap: a dead worker's uncommitted changes are reported and never acted on"
}

# --- refusals -------------------------------------------------------------------------

test_refused_action_is_not_retried_until_the_evidence_changes() {
  local dir out
  dir=$(make_home refused)
  add_record "$dir" landed ship off "$(pr_line)"
  land_record "$dir" landed

  out=$(FM_FAKE_TEARDOWN_RC=1 run_reap "$dir" scan --act)
  assert_contains "$(line_for "$out" landed)" "teardown refused" "the refusal is reported"
  assert_grep "check: reap landed teardown refused: REFUSED: fixture refusal" "$dir/home/state/.wake-queue" "the refusal was queued with its first line"

  out=$(run_reap "$dir" scan --act)
  assert_contains "$(line_for "$out" landed)" "refused earlier" "unchanged evidence reports the earlier refusal"
  [ "$(grep -c '^teardown' "$dir/actions.log")" -eq 1 ] || fail "a refused teardown was retried on unchanged evidence: $(cat "$dir/actions.log")"

  rm -rf "$dir/landed.wt"
  out=$(run_reap "$dir" scan --act)
  assert_contains "$(line_for "$out" landed)" "worktree gone" "changed evidence is re-evaluated"
  [ "$(grep -c '^teardown' "$dir/actions.log")" -eq 2 ] || fail "changed evidence did not retry the teardown: $(cat "$dir/actions.log")"
  pass "fm-reap: a refused action is remembered and retried only when the evidence changes"
}

# --- staleness rows ------------------------------------------------------------------

test_staleness_rows_close_only_for_reaped_or_landed_orphans() {
  local dir out json orphan_repo
  dir=$(make_home rows)
  add_record "$dir" landed ship off "$(pr_line)"
  land_record "$dir" landed
  # Orphan rows: no record in this home.
  orphan_repo="$dir/orphan.project"
  fm_git_worktree "$orphan_repo" "$dir/holds.wt" fm/holds
  printf 'unpushed\n' > "$dir/holds.wt/u.txt"
  git -C "$dir/holds.wt" add u.txt
  git -C "$dir/holds.wt" commit -qm unpushed
  git -C "$orphan_repo" worktree add -q -b fm/merged "$dir/merged.wt"
  printf 'landed\n' > "$dir/merged.wt/l.txt"
  git -C "$dir/merged.wt" add l.txt
  git -C "$dir/merged.wt" commit -qm landed
  git -C "$dir/merged.wt" push -q origin fm/merged
  git -C "$orphan_repo" merge -q --no-edit fm/merged
  git -C "$orphan_repo" push -q origin main
  json="$dir/rows.json"
  cat > "$json" <<EOF
[
  {"id":"stale-follow","status":"open","title":"Stale task landed: fm/landed","description":"worktree: $dir/landed.wt\nbranch: fm/landed\nproject: $dir/landed.project"},
  {"id":"stale-gone","status":"open","title":"Stale agent shut down: vanished","description":"kind=ship; worktree=$dir/nowhere; branch=HEAD"},
  {"id":"stale-holds","status":"open","title":"Stale task holds: fm/holds","description":"worktree: $dir/holds.wt\nbranch: fm/holds\nproject: $orphan_repo"},
  {"id":"stale-merged","status":"open","title":"Stale task merged: fm/merged","description":"worktree: $dir/merged.wt\nbranch: fm/merged\nproject: $orphan_repo"},
  {"id":"stale-odd","status":"open","title":"Something else entirely","description":""},
  {"id":"stale-closed","status":"closed","title":"Stale task closed: fm/closed","description":"worktree: $dir/nowhere"}
]
EOF

  out=$(FM_FAKE_STALENESS_JSON="$json" run_reap "$dir" scan)
  assert_contains "$(line_for "$out" stale-follow)" "ROW-FOLLOWS" "a row for a present record follows the record"
  assert_contains "$(line_for "$out" stale-gone)" "ROW-ORPHAN-CLEAR" "a row whose worktree is gone with no branch is clear"
  assert_contains "$(line_for "$out" stale-holds)" "ROW-ORPHAN-HOLDS" "a row with unpushed commits holds work"
  assert_contains "$(line_for "$out" stale-merged)" "ROW-ORPHAN-CLEAR" "a pushed, merged orphan is clear"
  assert_contains "$(line_for "$out" stale-odd)" "ROW-UNMATCHED" "a row naming no task is unmatched"
  assert_not_contains "$out" "stale-closed" "closed rows are ignored"
  assert_no_line "^staleness" "$dir/actions.log" "a dry run closed a staleness row"

  out=$(FM_FAKE_STALENESS_JSON="$json" run_reap "$dir" scan --act)
  assert_line "^teardown landed$" "$dir/actions.log" "the landed record was reaped"
  assert_line "^staleness close stale-follow --reason fm-reap: " "$dir/actions.log" "the row following the reaped record was closed"
  assert_line "^staleness close stale-gone --reason " "$dir/actions.log" "the vanished orphan row was closed"
  assert_line "^staleness close stale-merged --reason " "$dir/actions.log" "the landed orphan row was closed"
  assert_no_line "^staleness close stale-holds" "$dir/actions.log" "a row holding unpushed work was closed"
  assert_no_line "^staleness close stale-odd" "$dir/actions.log" "an unmatched row was closed"
  assert_grep "check: reap stale-follow staleness-close ok" "$dir/home/state/.wake-queue" "the row closure was queued"

  # A row whose record exists but was not reaped this scan stays open.
  : > "$dir/actions.log"
  out=$(FM_FAKE_STALENESS_JSON="$json" FM_FAKE_TEARDOWN_RC=1 run_reap "$dir" scan --act --task landed)
  assert_contains "$(line_for "$out" stale-follow)" "closes when the record is reaped" "an unreaped record keeps its row open"
  assert_no_line "^staleness close stale-follow" "$dir/actions.log" "a row was closed although its record was not reaped"
  pass "fm-reap: staleness rows close only once their record is reaped or their orphaned work is proved landed"
}

test_missing_staleness_command_skips_rows_loudly() {
  local dir out
  dir=$(make_home no-staleness)
  add_record "$dir" idle ship off
  out=$(FM_REAP_STALENESS_BIN="$dir/absent-staleness" run_reap "$dir" scan)
  assert_contains "$out" "staleness rows skipped" "a missing staleness command is reported on stderr"
  assert_contains "$(line_for "$out" idle)" "DEAD-UNLANDED" "records are still scanned"
  pass "fm-reap: records scan even when the staleness command is absent"
}

# --- report ---------------------------------------------------------------------------

test_report_prints_the_evidence_and_class() {
  local dir out
  dir=$(make_home report)
  add_record "$dir" landed ship off "$(pr_line)"
  land_record "$dir" landed
  out=$(run_reap "$dir" report landed)
  assert_contains "$out" "endpoint: dead" "the report names the endpoint state"
  assert_contains "$out" "pr_state: MERGED" "the report names the PR state"
  assert_contains "$out" "class: LANDED" "the report names the class"
  assert_contains "$out" "action: teardown" "the report names the pending action"
  [ ! -s "$dir/actions.log" ] || fail "report reached an owner: $(cat "$dir/actions.log")"
  run_reap "$dir" report "../escape" >/dev/null && fail "report accepted an unsafe task id"
  pass "fm-reap: report prints the evidence behind a classification without acting"
}

test_dry_run_classifies_without_acting
test_merged_pr_with_unlanded_work_is_never_torn_down
test_skips_young_secondmate_and_captain_held_records
test_ghost_slot_uses_record_only_teardown
test_scout_done_tears_down_only_with_a_report_and_verified_calls
test_merge_due_yolo_on_merges_only_green_unheld_prs
test_merge_due_yolo_off_files_one_captain_hold
test_closed_pr_is_reported_only
test_dead_unlanded_relaunches_once_then_escalates
test_dead_worker_with_uncommitted_changes_is_never_relaunched_blindly_or_torn_down
test_refused_action_is_not_retried_until_the_evidence_changes
test_staleness_rows_close_only_for_reaped_or_landed_orphans
test_missing_staleness_command_skips_rows_loudly
test_report_prints_the_evidence_and_class
