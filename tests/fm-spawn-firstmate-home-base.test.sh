#!/usr/bin/env bash
# Regression test: a ship/scout task whose project IS firstmate's own repo must
# start its fresh task worktree from THIS HOME's LOCAL main tip, never
# origin/<default>. A home with no push rights to upstream (a secondmate, or a
# primary that only lands local-only work) would otherwise hand the worker a
# branch that cannot fast-forward onto local main at merge time - the exact
# incident bin/fm-spawn.sh's freshen_spawn_worktree_base now guards against
# (AGENTS.md task fm-spawn-base-local-main).
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-firstmate-home-base)

# write_setup_shaped_brief <home> <id>: like fm_test_spawn_brief (tests/fixtures.sh),
# plus the scaffold's real "# Setup" anchor line
# (bin/fm-brief.sh: "You are in a disposable git worktree of ...") that
# record_spawn_base_in_brief (bin/fm-spawn.sh) inserts its "Base: ..." note
# after. fm_test_spawn_brief's minimal fixture brief omits that line entirely.
write_setup_shaped_brief() {
  local home=$1 id=$2
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
brief for $id

## Firstmate spec
Exercise the spawn behavior under test.

Prep: Tier 0 - test fixture, not a real change

# Setup
You are in a disposable git worktree of firstmate, at a detached HEAD on a clean default branch.
EOF
}

# make_case <name> <id>: a fake firstmate home whose own code root ("main")
# carries an origin remote AND a local-only commit origin never received (no
# push rights to upstream - the scenario the fix targets). "main" is both
# FM_ROOT_OVERRIDE and the ship task's project, i.e. a firstmate-repo task.
# "pool" is a treehouse-pool worktree of "main", detached at the STALE
# origin-published commit, mirroring a pool slot allocated before the local
# commit landed. bin/ is a real symlink to this repo's own bin/, so every
# $FM_ROOT/bin/*.sh helper fm-spawn.sh calls along the way is the genuine
# script, just rooted at the fixture instead of this checkout.
make_case() {
  local name=$1 id=$2 case_dir home main origin pool fakebin origin_sha local_sha
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  main="$case_dir/main"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  write_setup_shaped_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$main"
  printf 'v1\n' > "$main/AGENTS.md"
  ln -s "$ROOT/bin" "$main/bin"
  git -C "$main" add AGENTS.md bin
  git -C "$main" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$main" "$origin"
  git -C "$main" remote add origin "file://$origin"
  origin_sha=$(git -C "$main" rev-parse HEAD)

  git -C "$main" worktree add --quiet --detach "$pool" "$origin_sha"

  # This home lands a local-only commit no push rights ever send upstream.
  printf 'local only\n' > "$main/local-only.txt"
  git -C "$main" add local-only.txt
  git -C "$main" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm local-advance
  local_sha=$(git -C "$main" rev-parse HEAD)

  printf '%s\n' "$case_dir|$home|$main|$pool|$fakebin|$origin_sha|$local_sha"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR MAIN_DIR POOL_DIR FAKEBIN_DIR ORIGIN_SHA LOCAL_SHA <<EOF
$1
EOF
}

# Mirrors fm_test_run_spawn (tests/fixtures.sh), except FM_ROOT_OVERRIDE tracks
# the fixture's own "main" instead of pinning to this checkout - the one thing
# that makes the spawned task's project equal its FM_ROOT.
run_firstmate_home_spawn() {
  local id=$1 spawn_home
  shift
  spawn_home="$HOME_DIR/user-home"
  mkdir -p "$spawn_home"
  FM_ROOT_OVERRIDE="$MAIN_DIR" FM_HOME="$HOME_DIR" HOME="$spawn_home" \
    CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$POOL_DIR" TMUX="${TMUX:-fake,1,0}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$MAIN_DIR" "$@" 2>&1
}

test_firstmate_home_task_starts_at_local_main() {
  local rec id out status
  id='fmhome-local-main-r1'
  rec=$(make_case local-main "$id")
  read_case_record "$rec"

  out=$(run_firstmate_home_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a firstmate-home ship task should spawn"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$LOCAL_SHA" ] \
    || fail "spawn did not start the firstmate task worktree at this home's local main tip"
  [ "$LOCAL_SHA" != "$ORIGIN_SHA" ] \
    || fail "fixture did not prove local main advanced past origin"
  assert_grep "Base: $LOCAL_SHA (local main ($MAIN_DIR))." "$HOME_DIR/data/$id/launch-brief.md" \
    "spawn did not record the chosen local-main base in the launch brief"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed firstmate-home base (%s): HEAD=%s local-main=%s origin=%s\n' \
      "$CASE_DIR" "$(git -C "$POOL_DIR" rev-parse HEAD)" "$LOCAL_SHA" "$ORIGIN_SHA"
  fi
  pass "a firstmate-home ship task starts its fresh worktree at this home's local main tip, and the launch brief records it"
}

test_firstmate_home_task_refreshes_idempotently() {
  local rec id out status current
  id='fmhome-local-main-repeat-r1'
  rec=$(make_case local-main-repeat "$id")
  read_case_record "$rec"

  out=$(run_firstmate_home_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the first firstmate-home spawn should succeed"
  current=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$current" = "$LOCAL_SHA" ] || fail "the first spawn did not reach local main tip"

  id='fmhome-local-main-repeat-r1b'
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(run_firstmate_home_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "repeating the local-main refresh should be idempotent"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
    || fail "an idempotent repeat moved the firstmate task worktree away from local main"
  pass "repeating a firstmate-home spawn against an already-current pool is idempotent"
}

test_firstmate_home_task_refuses_when_local_main_unresolvable() {
  local rec id out status before
  id='fmhome-unresolvable-r1'
  rec=$(make_case unresolvable "$id")
  read_case_record "$rec"
  # Strand this home's own code root off its local default branch entirely, so
  # primary_head_commit (bin/fm-ff-lib.sh) cannot resolve a local main tip.
  git -C "$MAIN_DIR" checkout --quiet --detach HEAD
  git -C "$MAIN_DIR" branch -D main >/dev/null
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_firstmate_home_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unresolvable local main tip"
  assert_contains "$out" "could not resolve this home's local default-branch tip" \
    "spawn did not clearly refuse an unresolvable local main tip"
  assert_contains "$out" "git -C '$POOL_DIR' fetch '$MAIN_DIR' main" \
    "refusal did not name the exact recovery command"
  assert_not_contains "$out" "origin/main" \
    "spawn fell back to origin/main instead of refusing"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved the firstmate task worktree while refusing an unresolvable base"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unresolvable-local-main refusal: %s\n' "$(printf '%s\n' "$out" | grep 'could not resolve' | head -n 1)"
  fi
  pass "a firstmate-home task with no resolvable local main tip refuses instead of falling back to origin"
}

test_firstmate_home_task_starts_at_local_main
test_firstmate_home_task_refreshes_idempotently
test_firstmate_home_task_refuses_when_local_main_unresolvable

echo "# all fm-spawn-firstmate-home-base tests passed"
