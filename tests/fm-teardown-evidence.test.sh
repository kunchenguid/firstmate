#!/usr/bin/env bash
# Behavior tests for the evidence custody gate in bin/fm-teardown.sh.
#
# Cleanup destroys a worktree, so it must not proceed over evidence that was
# never preserved. It must equally not depend on a reachable network, or a
# machine that is offline could never reclaim a worktree again. These tests pin
# both halves at the teardown boundary, not just inside bin/fm-evidence.sh,
# because it is the wiring that decides whether cleanup stops.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-evidence)
TASKS_AXI_BIN=$(command -v tasks-axi || true)
fm_git_identity

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# A scout task that has already passed every gate ahead of the evidence gate, so
# these tests observe the evidence gate itself rather than an earlier refusal:
# metadata, a worktree carrying a sentinel, the report that is a scout's work
# product, and the completion attestation. Echoes the case directory.
make_case() {  # <name> <task-id>
  local dir="$TMP_ROOT/$1" id=$2 fakebin
  mkdir -p "$dir/home/state" "$dir/home/data/$id" "$dir/home/config" \
    "$dir/worktree" "$dir/project" "$dir/evidence"
  cp "$ROOT/.tasks.toml" "$dir/home/.tasks.toml"
  : > "$dir/worktree/sentinel"
  printf 'findings\n' > "$dir/home/data/$id/report.md"
  printf 'measurement\n' > "$dir/home/data/$id/raw-measurement.txt"

  git -C "$dir/evidence" init -q
  git -C "$dir/evidence" config user.name 'Firstmate Tests'
  git -C "$dir/evidence" config user.email 'tests@example.invalid'

  fakebin=$(fm_fakebin "$dir/home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi

  cat > "$dir/home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Preserve sample measurements (repo: sample) (kind: scout) (since 2026-07-31)

## Queued

## Done
EOF
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" \
    "harness=codex" "kind=scout" "mode=scout"
  printf 'done: measurements captured\n' > "$dir/home/state/$id.status"

  PATH="$fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" \
    "$ROOT/bin/fm-decision-hold.sh" complete "$id" --none >/dev/null \
    || fail "fixture could not pass the completion gate ahead of the evidence gate"

  printf '%s\n' "$dir"
}

run_teardown() {  # <case-dir> <task-id> [extra args...]
  local dir=$1 id=$2
  shift 2
  PATH="$dir/home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" "$TEARDOWN" "$id" "$@" 2>&1
}

# A destination that is configured but cannot be committed to must stop cleanup,
# because the worktree is about to be destroyed and the evidence would go with
# whatever was never preserved.
test_unpreservable_evidence_refuses_cleanup() {
  local dir id=broken-dest out rc
  dir=$(make_case broken "$id")
  printf '%s\n' "$TMP_ROOT/no-such-destination" > "$dir/home/config/evidence-repo"

  set +e
  out=$(run_teardown "$dir" "$id")
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "cleanup proceeded despite unpreservable evidence"
  assert_contains "$out" "could not preserve" "the refusal did not name the evidence gate"
  assert_present "$dir/worktree/sentinel" "cleanup destroyed the worktree before refusing"
  assert_present "$dir/home/state/$id.meta" "cleanup cleared task state before refusing"
  pass "fm-teardown: unpreservable evidence refuses cleanup and keeps the worktree"
}

# The mirror image, and the one that must never be "tidied" into the case above:
# a committed artifact plus an unreachable remote is preserved evidence, so
# cleanup proceeds.
test_unreachable_remote_does_not_block_cleanup() {
  local dir id=offline-dest out rc dest
  dir=$(make_case offline "$id")
  printf '%s\n' "$dir/evidence" > "$dir/home/config/evidence-repo"
  git -C "$dir/evidence" remote add origin "ssh://git@github.invalid/owner/name.git"

  set +e
  out=$(run_teardown "$dir" "$id")
  rc=$?
  set -e

  expect_code 0 "$rc" "cleanup blocked on an unreachable remote"$'\n'"$out"
  dest=$(FM_HOME="$dir/home" "$ROOT/bin/fm-evidence.sh" path "$id")
  assert_present "$dest/raw-measurement.txt" "the evidence was not preserved before cleanup"
  assert_contains "$(git -C "$dir/evidence" ls-files)" "$id/raw-measurement.txt" \
    "the evidence was never committed"
  pass "fm-teardown: an unreachable remote preserves evidence and still cleans up"
}

# A home that never opted in must clean up exactly as it always has.
test_optout_home_cleans_up_unchanged() {
  local dir id=optout-dest out rc
  dir=$(make_case optout "$id")

  set +e
  out=$(run_teardown "$dir" "$id")
  rc=$?
  set -e

  expect_code 0 "$rc" "cleanup changed behavior in a home that never opted in"$'\n'"$out"
  assert_not_contains "$out" "preserve" "an opted-out home mentioned evidence preservation"
  pass "fm-teardown: a home without an evidence destination cleans up unchanged"
}

# --force is the approved discard path, so a broken destination warns instead of
# blocking, exactly as it does for every other teardown refusal.
test_force_warns_but_proceeds() {
  local dir id=forced-dest out rc
  dir=$(make_case forced "$id")
  printf '%s\n' "$TMP_ROOT/no-such-destination" > "$dir/home/config/evidence-repo"

  set +e
  out=$(run_teardown "$dir" "$id" --force)
  rc=$?
  set -e

  expect_code 0 "$rc" "--force was blocked by the evidence gate"$'\n'"$out"
  assert_contains "$out" "WARNING" "--force gave no warning about the unpreserved evidence"
  pass "fm-teardown: --force warns about unpreservable evidence and proceeds"
}

test_unpreservable_evidence_refuses_cleanup
test_unreachable_remote_does_not_block_cleanup
test_optout_home_cleans_up_unchanged
test_force_warns_but_proceeds
