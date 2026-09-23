#!/usr/bin/env bash
# Regression test for fm-spawn.sh's truth-path check: a fleet clone under
# projects/ whose origin is a plain local path to a non-bare repository that
# has no remote of its own shares one Treehouse worktree pool with that
# repository, because Treehouse keys a pool by the origin URL, or by the
# repository path when there is no origin. A slot that repository created is
# then handed to the clone's spawn, is a worktree of the other repository,
# and the launch used to die late on "is not a worktree of project". The
# spawn now refuses before any pane or pool slot exists, with one line naming
# the path to pass, and never silently changes which repository work lands in.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-truth-path)

# make_truth_case <name> <id> [origin-mode]
# Builds a home, a live repository at <case>/live/<name>, a fleet clone of it at
# <home>/projects/<name>, and a Treehouse-shaped pool whose slot is a linked
# worktree of the LIVE repository (the 2026-09-22 shape). origin-mode:
#   path     the clone's origin is the live repository's plain path (default)
#   file     the clone's origin is a file:// URL, which Treehouse keys apart
#   remote   the live repository has an origin of its own, so its pool is apart
#   bare     the clone's origin is a bare repository
#   noslot   the live repository has no pool slot, so the pool is the clone's
make_truth_case() {
  local name=$1 id=$2 mode=${3:-path} case_dir home live clone pool slot fakebin
  case_dir="$TMP_ROOT/$id"
  home="$case_dir/home"
  live="$case_dir/live/$name"
  clone="$home/projects/$name"
  pool="$case_dir/treehouse/$name-abc123"
  slot="$pool/2/$name"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_git_init_commit "$live"
  case "$mode" in
  bare)
    git clone --quiet --bare "$live" "$case_dir/live/$name.git"
    git clone --quiet "$case_dir/live/$name.git" "$clone"
    ;;
  file)
    git clone --quiet "file://$live" "$clone"
    ;;
  *)
    git clone --quiet "$live" "$clone"
    ;;
  esac
  if [ "$mode" = remote ]; then
    git clone --quiet --bare "$live" "$case_dir/live/upstream.git"
    git -C "$live" remote add origin "file://$case_dir/live/upstream.git"
  fi
  mkdir -p "$pool"
  printf '{"worktrees":[]}\n' > "$pool/treehouse-state.json"
  if [ "$mode" != noslot ]; then
    git -C "$live" worktree add --quiet -b "slot-$id" "$slot"
  else
    git -C "$clone" worktree add --quiet -b "slot-$id" "$slot"
  fi
  fm_test_spawn_brief "$home" "$id" "Exercise the truth-path check for $id."
  printf '%s\n' "$home|$live|$clone|$slot|$fakebin"
}

read_truth_record() {
  IFS='|' read -r HOME_DIR LIVE_DIR CLONE_DIR SLOT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_truth_spawn() {
  local id=$1 project=$2
  FM_TEST_CLAUDE_CONFIG_DIR="$HOME_DIR/claude-config" \
    fm_test_run_spawn "$HOME_DIR" "$SLOT_DIR" "$FAKEBIN_DIR" \
    "$id" "$project" --mode no-mistakes --yolo off
}

# The exact incident: projects/Wikis cloned from the live ~/Documents/Wikis,
# which has no remote, so both share one pool and the slot handed out belongs
# to the live repository. The spawn must refuse before creating a window or
# claiming a slot, and the one-line refusal must name the path to pass.
test_shared_pool_clone_refuses_early_naming_the_live_path() {
  local rec id out status live_real
  id=truth-shared-pool-z1
  rec=$(make_truth_case Wikis "$id")
  read_truth_record "$rec"
  live_real=$(cd "$LIVE_DIR" && pwd -P)

  out=$(run_truth_spawn "$id" projects/Wikis)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a clone whose pool slots belong to its origin"$'\n'"$out"
  assert_not_contains "$out" "is not a worktree of project" \
    "spawn still died late on the trust-registration refusal"
  assert_contains "$out" "project '$CLONE_DIR' shares its Treehouse worktree pool" \
    "the refusal did not name the clone it refused"$'\n'"$out"
  assert_contains "$out" "pass '$live_real'" \
    "the refusal did not name the exact path to pass"$'\n'"$out"
  [ "$(printf '%s\n' "$out" | grep -c '^error:')" -eq 1 ] \
    || fail "the refusal was not exactly one error line"$'\n'"$out"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  [ ! -e "$(dirname "$SLOT_DIR")/.fm-slot-owner" ] || fail "refused spawn claimed the pool slot"
  pass "a clone sharing its origin's Treehouse pool refuses early and names the path to pass"
}

# Passing the live repository itself is the resolution the refusal names; the
# check must not fire for it, so the spawn proceeds into its own pool slot.
test_live_path_itself_spawns() {
  local rec id out status
  id=truth-live-path-z2
  rec=$(make_truth_case Wikis "$id")
  read_truth_record "$rec"

  out=$(run_truth_spawn "$id" "$LIVE_DIR")
  status=$?
  expect_code 0 "$status" "spawn from the live repository should succeed"$'\n'"$out"
  assert_grep "worktree=$SLOT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the live repository's slot"
  pass "the path the refusal names spawns cleanly"
}

# Clones whose pool Treehouse keys apart from the origin repository, or whose
# pool holds no slot of it, must keep spawning from the clone unchanged.
test_unshared_pools_are_not_refused() {
  local mode rec id out
  for mode in file remote bare noslot; do
    id="truth-unshared-$mode-z3"
    rec=$(make_truth_case "Proj$mode" "$id" "$mode")
    read_truth_record "$rec"
    out=$(run_truth_spawn "$id" "projects/Proj$mode")
    assert_not_contains "$out" "shares its Treehouse worktree pool" \
      "origin mode $mode was wrongly refused by the truth-path check"
  done
  pass "clones with a separately keyed or clone-rooted pool are not refused"
}

test_shared_pool_clone_refuses_early_naming_the_live_path
test_live_path_itself_spawns
test_unshared_pools_are_not_refused

echo "# all fm-spawn-truth-path tests passed"
