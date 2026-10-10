#!/usr/bin/env bash
# Regression test for the fm-spawn.sh seized-worktree refusal (issue #947).
#
# Treehouse's slot lease is pid-based, so a host crash followed by a backend
# agent resume under new pids frees every live task's slot at once. The next
# `treehouse get` can then hand one live task's pool slot to a fresh spawn, and
# neither the pane-settle loop nor the isolation guard can see it: the seized
# slot IS a real isolated worktree. fm-spawn must therefore refuse the resolved
# path whenever another task's record names it as its worktree= and that task's
# recorded endpoint cannot be proven agent-free - before claiming the slot or
# freshening its base, so a refusal never strips the live task's claim or
# resets its checkout.
#
# These cases drive the real bin/fm-spawn.sh against a fake tmux that reports
# the seized slot as the pane's settled path, with an existing task meta
# recording the same worktree= plus a window whose agent state the stub
# controls (FM_FAKE_PANE_COMMAND: claude reads alive, bash reads dead, and a
# window absent from list-windows reads missing). The cross-home leg uses the
# pool slot's own .fm-slot-owner claim to reach a task record this home's
# state/*.meta scan cannot see.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-seize)

# make_seize_case <name> <id>: a home, a project, and a managed-pool-shaped
# worktree at <case>/pool/2/repo with a treehouse-state.json pool marker. The
# claim file <case>/pool/2/.fm-slot-owner is left for the caller to write.
make_seize_case() {
  local name=$1 id=$2 case_dir home proj slot fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  slot="$case_dir/pool/2/repo"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$slot" "slot-$name"
  printf '{}\n' > "$case_dir/pool/treehouse-state.json"
  fm_test_spawn_brief "$home" "$id" "Exercise seized-worktree handling for $id."
  printf '%s\n' "$case_dir|$home|$proj|$slot|$fakebin"
}

read_seize_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR SLOT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

write_owner_claim() { # <slot> <task> <home>
  printf 'task=%s\nhome=%s\n' "$2" "$3" > "$(dirname "$1")/.fm-slot-owner"
}

write_task_meta() { # <meta-file> <id> <worktree> <window>
  fm_write_meta "$1" \
    "window=$4" \
    "endpoint_task_id=$2" \
    "worktree=$3" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "branch=fm/$2" \
    "backend=tmux"
}

run_seize_spawn() { # <id>
  fm_test_run_spawn "$HOME_DIR" "$SLOT_DIR" "$FAKEBIN_DIR" \
    "$1" "$PROJ_DIR" --mode no-mistakes --yolo off
}

# The incident itself: treehouse hands a fresh spawn the slot a live task's
# meta still records as its worktree=, and that task's resumed endpoint reads
# alive. The spawn must refuse before claiming or touching anything - no task
# record, the victim's claim left naming it, and the slot's checked-out branch
# left alone.
test_seized_live_task_worktree_is_refused() {
  local rec id victim out status
  id=seize-live-z1
  victim=seize-victim-z1
  rec=$(make_seize_case seize-live "$id")
  read_seize_record "$rec"
  write_owner_claim "$SLOT_DIR" "$victim" "$HOME_DIR"
  write_task_meta "$HOME_DIR/state/$victim.meta" "$victim" "$SLOT_DIR" "victsess:fm-$victim"

  out=$(FM_FAKE_DUPLICATE_WINDOW="fm-$victim" FM_FAKE_PANE_COMMAND=claude \
    run_seize_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn seized a live task's recorded worktree"$'\n'"$out"
  assert_contains "$out" "$victim" "refusal did not name the live task holding the worktree"
  assert_contains "$out" "$SLOT_DIR" "refusal did not name the seized path"
  assert_absent "$HOME_DIR/state/$id.meta" "refused spawn published task metadata"
  assert_grep "task=$victim" "$(dirname "$SLOT_DIR")/.fm-slot-owner" \
    "refusal stripped or overwrote the live task's slot claim"
  assert_equals "slot-seize-live" "$(git -C "$SLOT_DIR" branch --show-current)" \
    "refusal still switched the live task's checked-out branch"
  pass "a live task's recorded worktree is refused before claim or freshen"
}

# Same slot, same live agent - but the owning task's record lives in another
# home's state dir, so only the pool slot's own .fm-slot-owner claim can name
# it. The refusal must follow the claim to that home's meta.
test_seized_foreign_home_task_via_claim_is_refused() {
  local rec id victim foreign out status
  id=seize-foreign-z1
  victim="foreign-victim-z1"
  rec=$(make_seize_case seize-foreign "$id")
  read_seize_record "$rec"
  foreign="$TMP_ROOT/seize-foreign/foreignhome"
  mkdir -p "$foreign/state"
  write_owner_claim "$SLOT_DIR" "$victim" "$foreign"
  write_task_meta "$foreign/state/$victim.meta" "$victim" "$SLOT_DIR" "victsess2:fm-$victim"

  out=$(FM_FAKE_DUPLICATE_WINDOW="fm-$victim" FM_FAKE_PANE_COMMAND=claude \
    run_seize_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || \
    fail "spawn seized a foreign-home live task's recorded worktree"$'\n'"$out"
  assert_contains "$out" "$victim" "refusal did not name the foreign live task"
  assert_absent "$HOME_DIR/state/$id.meta" "refused spawn published task metadata"
  assert_grep "task=$victim" "$(dirname "$SLOT_DIR")/.fm-slot-owner" \
    "refusal stripped or overwrote the foreign task's slot claim"
  pass "a foreign-home live task reached through the slot claim is refused"
}

# A task record can name the slot while its endpoint is provably agent-free -
# the worker exited and the record awaits teardown. Reclaiming that slot is the
# pool's ordinary lifecycle, not a seizure, so the spawn proceeds and the stale
# claim is replaced by the new task's own.
test_dead_recorded_endpoint_does_not_block() {
  local rec id victim out status
  id=seize-dead-z1
  victim=seize-dead-victim-z1
  rec=$(make_seize_case seize-dead "$id")
  read_seize_record "$rec"
  write_owner_claim "$SLOT_DIR" "$victim" "$HOME_DIR"
  write_task_meta "$HOME_DIR/state/$victim.meta" "$victim" "$SLOT_DIR" "victsess:fm-$victim"

  out=$(FM_FAKE_DUPLICATE_WINDOW="fm-$victim" FM_FAKE_PANE_COMMAND=bash \
    run_seize_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn refused a slot whose recorded endpoint is dead"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$SLOT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the reclaimed worktree"
  assert_grep "task=$id" "$(dirname "$SLOT_DIR")/.fm-slot-owner" \
    "the new task's claim did not replace the dead task's stale claim"
  pass "a recorded worktree with a provably dead endpoint is reclaimed normally"
}

# Same, but the stale record's window is simply gone - tmux answers missing,
# which is also provably agent-free.
test_missing_recorded_endpoint_does_not_block() {
  local rec id victim out status
  id=seize-missing-z1
  victim=seize-missing-victim-z1
  rec=$(make_seize_case seize-missing "$id")
  read_seize_record "$rec"
  write_task_meta "$HOME_DIR/state/$victim.meta" "$victim" "$SLOT_DIR" "gonesess:fm-$victim"

  out=$(FM_FAKE_PANE_COMMAND=claude run_seize_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn refused a slot whose recorded endpoint is missing"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  pass "a recorded worktree with a missing endpoint is reclaimed normally"
}

# The claim names a task whose record has since moved to a different worktree:
# stale evidence, not a live occupant, so the spawn proceeds and reclaims.
test_stale_claim_for_other_worktree_does_not_block() {
  local rec id victim foreign other out status
  id=seize-stale-z1
  victim="foreign-stale-z1"
  rec=$(make_seize_case seize-stale "$id")
  read_seize_record "$rec"
  foreign="$TMP_ROOT/seize-stale/foreignhome"
  mkdir -p "$foreign/state"
  other="$TMP_ROOT/seize-stale/other-worktree"
  git -C "$PROJ_DIR" worktree add --quiet -b "other-$id" "$other"
  write_owner_claim "$SLOT_DIR" "$victim" "$foreign"
  write_task_meta "$foreign/state/$victim.meta" "$victim" "$other" "victsess3:fm-$victim"

  out=$(FM_FAKE_DUPLICATE_WINDOW="fm-$victim" FM_FAKE_PANE_COMMAND=claude \
    run_seize_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn refused a slot whose claim is stale"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "task=$id" "$(dirname "$SLOT_DIR")/.fm-slot-owner" \
    "the new task's claim did not replace the stale claim"
  pass "a claim naming a task that moved elsewhere does not block reclaim"
}

# An unrelated live task whose meta records a DIFFERENT worktree must never
# trip the guard - it is not this slot's owner.
test_other_task_worktree_does_not_block() {
  local rec id victim other out status
  id=seize-other-z1
  victim=seize-other-victim-z1
  rec=$(make_seize_case seize-other "$id")
  read_seize_record "$rec"
  other="$TMP_ROOT/seize-other/other-worktree"
  git -C "$PROJ_DIR" worktree add --quiet -b "other-$id" "$other"
  write_task_meta "$HOME_DIR/state/$victim.meta" "$victim" "$other" "victsess4:fm-$victim"

  out=$(FM_FAKE_DUPLICATE_WINDOW="fm-$victim" FM_FAKE_PANE_COMMAND=claude \
    run_seize_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn refused a free slot because a live task exists elsewhere"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  pass "a live task holding a different worktree does not block a free slot"
}

# A claim is keyed by task id, and task ids are scoped to homes: a foreign-home
# task can carry the very id this spawn is about to take. The claim reads
# 'mine' by id alone, so only the claim's recorded home= can expose that the
# claimant lives in another home's state dir.
test_same_id_foreign_home_claim_is_refused() {
  local rec id foreign out status
  id=seize-sameid-z1
  rec=$(make_seize_case seize-sameid "$id")
  read_seize_record "$rec"
  foreign="$TMP_ROOT/seize-sameid/foreignhome"
  mkdir -p "$foreign/state"
  write_owner_claim "$SLOT_DIR" "$id" "$foreign"
  write_task_meta "$foreign/state/$id.meta" "$id" "$SLOT_DIR" "victsess5:fm-$id"

  out=$(FM_FAKE_DUPLICATE_WINDOW="fm-$id" FM_FAKE_PANE_COMMAND=claude \
    run_seize_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || \
    fail "spawn seized a foreign-home live task whose claim collided on its own id"$'\n'"$out"
  assert_contains "$out" "$id" "refusal did not name the same-id foreign task"
  assert_absent "$HOME_DIR/state/$id.meta" "refused spawn published task metadata"
  assert_grep "home=$foreign" "$(dirname "$SLOT_DIR")/.fm-slot-owner" \
    "refusal stripped or overwrote the foreign task's slot claim"
  pass "a same-id claim from a foreign home is refused"
}

# A claim that cannot be read as a claim can never prove the slot free, and
# the claim step would silently overwrite it - the same fail-closed call
# teardown makes on a slot claim it cannot prove.
test_unverifiable_claim_is_refused() {
  local rec id marker out status
  id=seize-badclaim-z1
  rec=$(make_seize_case seize-badclaim "$id")
  read_seize_record "$rec"
  marker="$(dirname "$SLOT_DIR")/.fm-slot-owner"
  printf 'task=stale-task-z1\n' > "$marker"

  out=$(run_seize_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || \
    fail "spawn seized a slot whose claim names a task without a home to inspect"$'\n'"$out"
  assert_contains "$out" "stale-task-z1" "refusal did not name the claimant"
  assert_absent "$HOME_DIR/state/$id.meta" "refused spawn published task metadata"
  assert_equals "task=stale-task-z1" "$(cat "$marker")" \
    "refusal overwrote the unverifiable claim"
  pass "a claim that cannot be inspected is refused"
}

test_seized_live_task_worktree_is_refused
test_seized_foreign_home_task_via_claim_is_refused
test_same_id_foreign_home_claim_is_refused
test_unverifiable_claim_is_refused
test_dead_recorded_endpoint_does_not_block
test_missing_recorded_endpoint_does_not_block
test_stale_claim_for_other_worktree_does_not_block
test_other_task_worktree_does_not_block

echo "# all fm-spawn-worktree-seize tests passed"
