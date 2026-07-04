#!/usr/bin/env bash
# Behavior test for fm-spawn.sh's worktree resolution (the worktree-path fix).
#
# Regression guard for the bug where every crew's state/<id>.meta recorded
# worktree=<firstmate home / launch cwd> instead of the crew's real treehouse
# worktree. The old code sent `treehouse get` into the pane and then polled
# `pane_current_path` until it differed from PROJ_ABS, taking that first
# differing directory as the worktree - which could latch onto the session's
# default working directory (the firstmate home) before the treehouse subshell
# was entered. fm-spawn now leases the worktree authoritatively with
# `treehouse get --lease`, whose stdout is exactly the leased path, so the meta
# must record that path verbatim.
#
# The suite fakes tmux and treehouse (like every other spawn suite except the
# real-tmux smoke test): tmux is a no-op terminal, and `treehouse get --lease`
# echoes a pre-created real git worktree so fm-spawn's isolated-worktree
# validation still passes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-lease)

# Build a spawn sandbox. Sets up a firstmate home with a project git repo, a
# brief, and a fakebin with no-op tmux + a treehouse mock whose `get --lease`
# prints a pre-created worktree of the project. Echoes the case dir.
make_spawn_case() {
  local name=$1 id=$2 case_dir home project leased fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$home/projects/repo"
  leased="$case_dir/leased-worktree"
  fakebin="$case_dir/fakebin"
  mkdir -p "$home/state" "$home/config" "$home/data/$id" "$fakebin"

  # A real project repo so treehouse can add a worktree of it, and the leased
  # worktree fm-spawn will validate as a genuine isolated worktree.
  fm_git_init_commit "$project"
  git -C "$project" worktree add -q -b "fm-lease-$id" "$leased"

  # Registry line so fm-project-mode.sh resolves a delivery mode cleanly.
  printf '%s\n' "- repo [no-mistakes] - test project (added 2026-01-01)" \
    > "$home/data/projects.md"

  # Minimal brief; fm-spawn only needs it to exist and be catted into the pane.
  printf '%s\n' "Test brief for $id." > "$home/data/$id/brief.md"

  # No-op tmux: list-windows prints nothing (so the duplicate-window guard
  # passes), has-session succeeds (so container-ensure reuses "firstmate"),
  # everything else exits 0. pane_current_path is never polled anymore.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) exit 0 ;;
esac
exit 0
SH

  # treehouse mock: `get --lease ...` prints the pre-created worktree path
  # (banners would go to stderr in the real tool); every other subcommand is a
  # no-op. FM_TEST_LEASE_PATH carries the path the test expects recorded.
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = get ]; then
  printf '%s\n' "$leased"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"

  printf '%s\n' "$case_dir"
}

run_spawn() {
  local home=$1 fakebin=$2; shift 2
  # Clear ambient overrides, pin FM_HOME to the sandbox, keep FM_ROOT on the
  # real repo (so bin/ helpers resolve), force the tmux backend, and unset TMUX
  # so container-ensure takes the detached-session path.
  env -u TMUX \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_BACKEND=tmux \
    FM_SPAWN_NO_GUARD=1 \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@"
}

test_meta_records_leased_worktree_path() {
  local id case_dir home fakebin leased rc meta_wt
  id="lease-probe-a1"
  case_dir=$(make_spawn_case lease-basic "$id")
  home="$case_dir/home"
  fakebin="$case_dir/fakebin"
  leased="$case_dir/leased-worktree"

  set +e
  run_spawn "$home" "$fakebin" "$id" projects/repo codex \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  # Per-task temp root fm-spawn creates unconditionally; clean it up.
  rm -rf "/tmp/fm-$id" 2>/dev/null || true

  expect_code 0 "$rc" "spawn should succeed with a leased worktree ($(cat "$case_dir/stderr"))"
  assert_present "$home/state/$id.meta" "spawn did not write the task meta"
  meta_wt=$(grep '^worktree=' "$home/state/$id.meta" | cut -d= -f2-)
  [ "$meta_wt" = "$leased" ] \
    || fail "meta worktree is '$meta_wt', expected the leased treehouse path '$leased'"
  # The launch cwd / firstmate home must never be recorded as the worktree.
  [ "$meta_wt" != "$home" ] \
    || fail "meta worktree is the firstmate home (the original bug)"
  pass "spawn records the leased treehouse worktree path in the task meta"
}

test_meta_records_leased_worktree_path
