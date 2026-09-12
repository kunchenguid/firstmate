#!/usr/bin/env bash
# Dry-run zombie sweep: lock GC, missing-status repair, and idle-record classes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/fm-zombie-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-zombie-sweep)

seed() {  # <dir>
  mkdir -p "$1/home/state" "$1/home/data"
}

run_sweep() {  # <dir> [args]
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_DATA_OVERRIDE="$dir/home/data" \
    FM_ZOMBIE_LIVE_IDS="${FM_ZOMBIE_LIVE_IDS:-}" \
    FM_TEARDOWN_BIN="$dir/fake-teardown.sh" \
    "$SWEEP" "$@" 2>&1
}

install_teardown() {  # <dir>
  cat > "$1/fake-teardown.sh" <<SH
#!/usr/bin/env bash
printf 'teardown %s\n' "\$*" >> "$1/teardown.log"
rm -f "$1/home/state/\$1.meta" "$1/home/state/\$1.status"
exit 0
SH
  chmod +x "$1/fake-teardown.sh"
}

install_pane_close() {  # <dir>
  cat > "$1/fake-pane-close.sh" <<SH
#!/usr/bin/env bash
printf 'close %s\n' "\$1" >> "$1/pane-close.log"
SH
  chmod +x "$1/fake-pane-close.sh"
}

test_lock_gc_removes_dead_owner_only_on_apply() {
  local dir out owner lock
  dir="$TMP_ROOT/locks"
  seed "$dir"
  owner="$dir/home/state/.watch.lock.owner.dead"
  mkdir -p "$owner"
  printf '999999\n' > "$owner/pid"
  lock="$dir/home/state/.watch.lock"
  ln -s "$owner" "$lock"
  out=$(run_sweep "$dir") || fail "dry-run lock gc failed: $out"
  assert_contains "$out" "lock-gc: .watch.lock pid 999999 dead" "dead lock was not listed"
  [ -d "$owner" ] || fail "dry-run removed the owner dir"
  [ -L "$lock" ] || fail "dry-run removed the lock symlink"
  out=$(run_sweep "$dir" --apply) || fail "apply lock gc failed: $out"
  [ ! -e "$owner" ] || fail "apply left the dead owner dir"
  [ ! -e "$lock" ] || fail "apply left the dead lock symlink"
  pass "lock GC lists a dead owner on dry-run and removes it only on --apply"
}

test_lock_gc_keeps_live_owner_and_pidless() {
  local dir out owner lock live
  dir="$TMP_ROOT/lock-keep"
  seed "$dir"
  live="$dir/home/state/.watch.lock.owner.live"
  mkdir -p "$live"
  printf '%s\n' "$$" > "$live/pid"
  ln -s "$live" "$dir/home/state/.watch.lock"
  owner="$dir/home/state/.other.lock.owner.nopid"
  mkdir -p "$owner"
  out=$(run_sweep "$dir" --apply) || fail "keep pass failed: $out"
  [ -d "$live" ] || fail "live owner was removed"
  [ -L "$dir/home/state/.watch.lock" ] || fail "live lock symlink was removed"
  assert_contains "$out" "unclassified: lock owner .other.lock.owner.nopid has no pid" "pidless owner was not reported"
  [ -d "$owner" ] || fail "pidless owner was removed"
  pass "live owners and pidless lock dirs are left untouched"
}

test_missing_status_gets_paused_line() {
  local dir out
  dir="$TMP_ROOT/paused"
  seed "$dir"
  printf 'kind=ship\nwindow=\n' > "$dir/home/state/ghost.meta"
  out=$(run_sweep "$dir") || fail "dry-run paused repair failed: $out"
  assert_contains "$out" "paused-repair: ghost missing status" "missing status was not listed"
  [ ! -e "$dir/home/state/ghost.status" ] || fail "dry-run wrote a status file"
  out=$(run_sweep "$dir" --apply) || fail "apply paused repair failed: $out"
  grep -q 'paused: missing status file; endpoint dead' "$dir/home/state/ghost.status" \
    || fail "apply did not write the paused line"
  pass "a meta with no status gets one paused line on --apply"
}

test_gone_nonterminal_herdr_pane_closes() {
  local dir out
  dir="$TMP_ROOT/gone-pane"
  seed "$dir"
  install_pane_close "$dir"
  mkdir -p "$dir/project" "$dir/worktree"
  printf 'kind=ship\nbackend=herdr\nwindow=gone:pane\nendpoint_task_id=gone-pane\nherdr_session=gone\nherdr_workspace_id=w1\nherdr_tab_id=t1\nherdr_pane_id=pane\nworktree=%s/worktree\nproject=%s/project\n' "$dir" "$dir" > "$dir/home/state/gone-pane.meta"
  printf 'working: endpoint disappeared\n' > "$dir/home/state/gone-pane.status"
  out=$(FM_ZOMBIE_LIVE_IDS=other FM_ZOMBIE_KILL_BIN="$dir/fake-pane-close.sh" run_sweep "$dir" --apply) \
    || fail "gone-pane sweep failed: $out"
  assert_contains "$out" "pane-close: gone-pane" "nonterminal gone endpoint did not request pane close"
  grep -qx 'close gone-pane' "$dir/pane-close.log" || fail "pane close did not target the exact gone record"
  pass "a nonterminal Herdr record with a gone endpoint closes its own pane"
}

test_classes_and_summary_count() {
  local dir out
  dir="$TMP_ROOT/classes"
  seed "$dir"
  install_teardown "$dir"
  printf 'kind=ship\npr=https://github.com/example/repo/pull/1\nbackend=herdr\n' \
    > "$dir/home/state/merged.meta"
  printf 'done: PR merged\n' > "$dir/home/state/merged.status"
  printf 'kind=scout\n' > "$dir/home/state/scouted.meta"
  printf 'done: report ready\n' > "$dir/home/state/scouted.status"
  mkdir -p "$dir/home/data/scouted"
  printf 'report\n' > "$dir/home/data/scouted/report.md"
  printf 'kind=ship\nworktree=%s/gone\n' "$dir" > "$dir/home/state/gone.meta"
  printf 'failed: endpoint dead\n' > "$dir/home/state/gone.status"
  mkdir -p "$dir/wt-dirty"
  git init -q "$dir/wt-dirty"
  printf 'x\n' > "$dir/wt-dirty/x"
  printf 'kind=ship\nworktree=%s/wt-dirty\n' "$dir" > "$dir/home/state/dirty.meta"
  printf 'working: leftover\n' > "$dir/home/state/dirty.status"
  printf 'kind=ship\nwindow=firstmate:fm-live\nbackend=herdr\n' > "$dir/home/state/live.meta"
  printf 'working: still going\n' > "$dir/home/state/live.status"
  out=$(FM_ZOMBIE_LIVE_IDS=live run_sweep "$dir") || fail "class dry-run failed: $out"
  assert_contains "$out" "retire-candidate: merged class=merged" "merged class missing"
  assert_contains "$out" "retire-candidate: scouted class=report" "report class missing"
  assert_contains "$out" "retire-candidate: gone class=worktree-gone" "worktree-gone class missing"
  assert_contains "$out" "needs-decision: zombie dirty dead worktree with unlanded work" "unlanded question missing"
  assert_contains "$out" "no-live-agent=4" "no-live-agent count missing"
  printf '%s\n' "$out" | grep -E 'retire-candidate: live|pane-close: live|zombie live ' \
    && fail "live agent was treated as idle: $out"
  out=$(FM_ZOMBIE_LIVE_IDS=live run_sweep "$dir" --apply) || fail "class apply failed: $out"
  [ ! -e "$dir/home/state/merged.meta" ] || fail "merged was not retired"
  [ -f "$dir/home/state/dirty.meta" ] || fail "unlanded record was torn down"
  [ -f "$dir/home/state/live.meta" ] || fail "live record was touched"
  pass "idle records classify, count, retire safely, and question unlanded work"
}

test_lock_gc_removes_dead_owner_only_on_apply
test_lock_gc_keeps_live_owner_and_pidless
test_missing_status_gets_paused_line
test_gone_nonterminal_herdr_pane_closes
test_classes_and_summary_count
