#!/usr/bin/env bash
# Regression test for fm-spawn.sh acquiring an isolated task worktree from a
# project clone whose main checkout deliberately carries core.bare=true
# (bin/fm-spawn.sh, project_is_bare_flagged and lease_bare_clone_worktree).
#
# A harness may set that flag on purpose so the checkout can double as a ref host
# that advances its own branches with a ref-only fetch. git then refuses every
# work-tree operation against the clone, including the `git rev-parse
# --show-toplevel` that `treehouse get` starts with, so the spawn used to die
# before any worker existed. The flag is deliberate and must survive the spawn
# untouched.
#
# The fake treehouse here is a thin pool wrapper only: its repo resolution and
# its per-worktree cleanliness check are REAL git commands run against a real
# bare-flagged fixture clone, so git itself - not a hardcoded assumption - is
# what enforces the constraints under test.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-bare-clone)

# make_bare_fakebin <dir> <lease_support> [holder_guard_support] builds the fake
# tmux and fake treehouse. <holder_guard_support> defaults to yes and stands for
# `treehouse return --if-lease-holder`, which the version this repo pins does not
# have: the fake rejects the flag as unknown when it is no, exactly as that binary
# does, so a release that assumes the flag visibly fails to free the pool slot.
#
# The fake treehouse mirrors the two real behaviours that matter:
#   * `get` resolves the repo from its cwd with `git rev-parse --show-toplevel`,
#     which is a work-tree operation and so fails against a bare-flagged clone
#     unless the caller scoped a GIT_WORK_TREE override around the invocation.
#   * before handing back a pooled worktree it checks that worktree is clean with
#     `git -C <tree> status --porcelain`. An ABSOLUTE GIT_WORK_TREE pins that
#     check to the clone's work tree instead, so the clone's own untracked files
#     make every pooled tree read dirty and the real treehouse then refuses to
#     hand any of them out. Only a relative override keeps this check honest.
# Every send-keys line is appended to FM_FAKE_SENDKEYS_LOG so the test can assert
# which acquire command each path actually put in the pane.
make_bare_fakebin() {
  local dir=$1 lease_support=$2 holder_guard_support=${3:-yes} fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    if [ -f "${FM_FAKE_PANE_PATHFILE:?FM_FAKE_PANE_PATHFILE unset}" ]; then
      cat "$FM_FAKE_PANE_PATHFILE"
    else
      printf '%s\n' "${FM_FAKE_PANE_PROJECT:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  send-keys)
    printf '%s\n' "$*" >> "${FM_FAKE_SENDKEYS_LOG:?FM_FAKE_SENDKEYS_LOG unset}"
    # A `cd <path>` line is the pane moving into an already-leased worktree; a
    # bare `treehouse get` line is the pane acquiring one itself. Either way the
    # simulated pane's reported cwd becomes the worktree, exactly as the real
    # pane's would.
    # FM_FAKE_PANE_SETTLE stands in for a pane that settles somewhere other than
    # the path it was sent to, which is the transient stale pane_current_path the
    # settle loop guards against.
    case "$*" in
      *"cd "*)
        printf '%s\n' "${FM_FAKE_PANE_SETTLE:-${FM_FAKE_LEASE_PATH:-}}" > "$FM_FAKE_PANE_PATHFILE" ;;
      *"treehouse get"*)
        printf '%s\n' "${FM_FAKE_PANE_SETTLE:-${FM_FAKE_LEASE_PATH:-}}" > "$FM_FAKE_PANE_PATHFILE" ;;
    esac
    exit 0
    ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
set -u
LEASE_SUPPORT=$lease_support
HOLDER_GUARD_SUPPORT=$holder_guard_support
SH
  cat >> "$fakebin/treehouse" <<'SH'
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:?FM_FAKE_TREEHOUSE_LOG unset}"
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf 'Acquire a worktree from the pool and open a subshell in it.\n'
  printf 'Flags:\n  -h, --help  help for get\n'
  [ "$LEASE_SUPPORT" = yes ] && printf '      --lease     Durably lease a worktree\n'
  exit 0
fi
if [ "${1:-}" = get ]; then
  # Real repo resolution: refuses on a bare-flagged clone with no work tree.
  if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "not in a git repository: git rev-parse --show-toplevel: fatal: this operation must be run in a work tree" >&2
    exit 1
  fi
  case " $* " in
    *" --lease "*)
      [ "$LEASE_SUPPORT" = yes ] || { echo "unknown flag: --lease" >&2; exit 1; }
      ;;
    *)
      # Real `treehouse get` without --lease execs an INTERACTIVE SUBSHELL in the
      # worktree and prints no path to stdout. Modelling that faithfully is what
      # makes --lease load-bearing in this test rather than decorative: it is the
      # only form that hands the path back to the caller, and so the only form
      # that keeps the GIT_WORK_TREE override off the worker's own shell.
      echo "🌳 Setting up worktree..." >&2
      exit 0
      ;;
  esac
  # Real pool-cleanliness check on the worktree about to be handed out.
  if [ -n "$(git -C "${FM_FAKE_LEASE_PATH:?}" status --porcelain 2>&1)" ]; then
    echo "all worktrees are in use or dirty (max_trees = 1)" >&2
    exit 1
  fi
  echo "🌳 Setting up worktree..." >&2
  printf '%s\n' "$FM_FAKE_LEASE_PATH"
  exit 0
fi
if [ "${1:-}" = return ]; then
  # Real `treehouse return` takes an explicit path and needs no work tree of its
  # own, so it resolves against a bare-flagged clone too. The argv log above is
  # what the test asserts on.
  if [ "${2:-}" = --help ]; then
    printf 'Terminate lingering processes and return a worktree\n'
    printf 'Flags:\n      --force   Clean, reset, and return without prompting\n'
    [ "$HOLDER_GUARD_SUPPORT" = yes ] \
      && printf '      --if-lease-holder string   Return only if the current lease has this holder\n'
    exit 0
  fi
  case " $* " in
    *" --if-lease-holder "*)
      # The pinned treehouse has no such flag and rejects the whole command, so a
      # release that assumes it never frees the pool slot.
      [ "$HOLDER_GUARD_SUPPORT" = yes ] || { echo "unknown flag: --if-lease-holder" >&2; exit 1; }
      ;;
  esac
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_bare_case <name> <id> <bare> <lease_support> [holder_guard_support] builds
# a home plus a project clone with a real linked worktree standing in for the
# pooled tree. When <bare> is yes the clone gets core.bare=true AND an untracked
# file in its work tree - the untracked file is what makes an absolute
# GIT_WORK_TREE override visibly corrupt the pool-cleanliness check above.
make_bare_case() {
  local name=$1 id=$2 bare=$3 lease_support=$4 holder_guard_support=${5:-yes}
  local case_dir home proj wt stale fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/pool-worktree"
  stale="$case_dir/stale-worktree"
  fakebin=$(make_bare_fakebin "$case_dir/fake" "$lease_support" "$holder_guard_support")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "pool-$name"
  git -C "$wt" checkout --detach -q
  # A second real, isolated worktree: the stale pane path that passes both the
  # non-project comparison and validate_spawn_worktree, so only waiting for the
  # leased path itself can reject it.
  git -C "$proj" worktree add --quiet -b "stale-$name" "$stale"
  git -C "$stale" checkout --detach -q
  if [ "$bare" = yes ]; then
    printf 'max_trees = 1\n' > "$proj/treehouse.toml"
    git -C "$proj" config core.bare true
  fi
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin"
}

read_bare_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR <<EOF
$1
EOF
  SENDKEYS_LOG="$CASE_DIR/sendkeys.log"
  TREEHOUSE_LOG="$CASE_DIR/treehouse.log"
  PANE_PATHFILE="$CASE_DIR/pane-path"
  PANE_SETTLE=""
  # The spelling treehouse hands back, which is also the only spelling its own
  # `return` accepts. It is the pooled tree's own path unless a case points it at
  # an equivalent-but-differently-spelled route to the same directory.
  LEASE_PATH="$WT_DIR"
  : > "$SENDKEYS_LOG"
  : > "$TREEHOUSE_LOG"
  rm -f "$PANE_PATHFILE"
}

run_bare_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_SPAWN_SETTLE_INTERVAL=0.02 \
    FM_FAKE_LEASE_PATH="$LEASE_PATH" FM_FAKE_PANE_PROJECT="$PROJ_DIR" \
    FM_FAKE_PANE_SETTLE="$PANE_SETTLE" \
    FM_FAKE_PANE_PATHFILE="$PANE_PATHFILE" FM_FAKE_SENDKEYS_LOG="$SENDKEYS_LOG" \
    FM_FAKE_TREEHOUSE_LOG="$TREEHOUSE_LOG" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# The headline case: a bare-flagged clone must still yield an isolated worktree.
test_bare_flagged_clone_spawns() {
  local rec id out status
  id='bare-clone-spawn-b1'
  rec=$(make_bare_case bare-spawn "$id" yes yes)
  read_bare_record "$rec"

  out=$(run_bare_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed against a bare-flagged clone"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the leased worktree"
  # The pane must be moved into an already-leased worktree, never asked to run
  # `treehouse get` itself - that is the call that cannot work here.
  assert_grep "cd " "$SENDKEYS_LOG" "pane was not sent a cd into the leased worktree"
  assert_no_grep "treehouse get" "$SENDKEYS_LOG" \
    "pane was told to run treehouse get against a bare-flagged clone"
  # --lease is what hands the path back instead of exec'ing a subshell that would
  # inherit the GIT_WORK_TREE override into the worker's own environment.
  assert_grep "get --lease" "$TREEHOUSE_LOG" \
    "worktree was not acquired with treehouse get --lease"
  # Once the meta records the worktree, fm-teardown.sh owns the lease: a spawn
  # that reached that point must not hand the pool slot back under the live task.
  assert_no_grep "return --force" "$TREEHOUSE_LOG" \
    "successful spawn returned the lease out from under the live task"
  pass "a bare-flagged clone yields an isolated worktree leased by firstmate"
}

# A pane that never reaches the leased worktree must not be accepted: the leased
# tree would stay leased with nobody to return it and the task would run in a
# tree treehouse never handed to it. The stand-in path here is a second real,
# isolated worktree, so only the wait-for-the-leased-path rule can reject it.
test_settled_path_must_be_the_leased_worktree() {
  local rec id out status
  id='bare-stale-pane-b5'
  rec=$(make_bare_case bare-stale "$id" yes yes)
  read_bare_record "$rec"
  PANE_SETTLE="$STALE_DIR"

  out=$(run_bare_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a settled path that was never leased for the task"
  assert_contains "$out" "$WT_DIR" "refusal did not name the leased worktree"
  assert_contains "$out" "$STALE_DIR" "refusal did not name the observed worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "refused spawn still recorded task metadata"
  pass "a settled path other than the leased worktree is refused by name"
}

# `treehouse return` matches the path treehouse recorded literally: an equivalent
# spelling of the same directory is rejected as unmanaged. The pane reports its
# physically-resolved cwd, so with a symlink anywhere above the pool the two
# spellings differ, and recording the pane's would leave fm-teardown.sh passing a
# path treehouse refuses - burning the pool slot for good, since a leased tree is
# never pruned and never handed to a later get.
test_meta_records_the_treehouse_spelling_of_the_lease() {
  local rec id out status
  id='bare-lease-spelling-b8'
  rec=$(make_bare_case bare-spelling "$id" yes yes)
  read_bare_record "$rec"
  ln -s "$WT_DIR" "$CASE_DIR/pool-link"
  LEASE_PATH="$CASE_DIR/pool-link"
  PANE_SETTLE="$WT_DIR"

  out=$(run_bare_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should accept a pane that resolves to the leased worktree"
  assert_grep "worktree=$LEASE_PATH" "$HOME_DIR/state/$id.meta" \
    "meta did not record treehouse's own spelling of the leased worktree"
  assert_no_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta recorded the pane's spelling, which treehouse return rejects as unmanaged"
  pass "the meta records the spelling treehouse leased, not the pane's resolved cwd"
}

# Every abort before the meta write has to give the pool slot back: no state file
# records the lease yet, so fm-teardown.sh can never release it.
test_abort_before_meta_releases_the_lease() {
  local rec id
  id='bare-lease-release-b6'
  rec=$(make_bare_case bare-release "$id" yes yes)
  read_bare_record "$rec"
  PANE_SETTLE="$STALE_DIR"

  run_bare_spawn "$id" >/dev/null
  assert_grep "return --force --if-lease-holder $id $WT_DIR" "$TREEHOUSE_LOG" \
    "aborted spawn did not release the worktree it had leased"
  pass "an abort before the meta write releases the durable lease"
}

# --if-lease-holder postdates the treehouse version this repo pins, which rejects
# the whole command as an unknown flag. The release still has to happen there:
# skipping it burns the pool slot, which is the leak the cleanup exists to close.
test_abort_releases_the_lease_without_holder_guard() {
  local rec id out
  id='bare-lease-release-b7'
  rec=$(make_bare_case bare-release-noguard "$id" yes yes no)
  read_bare_record "$rec"
  PANE_SETTLE="$STALE_DIR"

  out=$(run_bare_spawn "$id")
  assert_grep "return --force $WT_DIR" "$TREEHOUSE_LOG" \
    "aborted spawn did not fall back to a plain release when treehouse lacks --if-lease-holder"
  assert_no_grep "--if-lease-holder" "$TREEHOUSE_LOG" \
    "aborted spawn passed --if-lease-holder to a treehouse that does not support it"
  case "$out" in
    *"could not release the worktree leased for $id"*)
      fail "the lease release failed against a treehouse without --if-lease-holder" ;;
  esac
  pass "an abort releases the lease unguarded when treehouse lacks --if-lease-holder"
}

# The deliberate flag is the whole reason this path exists: it must survive.
test_bare_flag_survives_the_spawn() {
  local rec id status
  id='bare-clone-flag-b2'
  rec=$(make_bare_case bare-flag "$id" yes yes)
  read_bare_record "$rec"

  run_bare_spawn "$id" >/dev/null
  status=$?
  expect_code 0 "$status" "spawn should succeed against a bare-flagged clone"
  [ "$(git -C "$PROJ_DIR" config --get core.bare)" = true ] \
    || fail "spawn cleared the clone's deliberate core.bare=true flag"
  [ "$(git -C "$PROJ_DIR" rev-parse --is-bare-repository)" = true ] \
    || fail "clone no longer reports as bare after the spawn"
  pass "the clone's deliberate core.bare=true survives the spawn unchanged"
}

# An ordinary clone must keep acquiring its worktree exactly as before: the pane
# runs `treehouse get` itself and no lease is taken.
test_non_bare_clone_path_is_unchanged() {
  local rec id out status
  id='non-bare-clone-b3'
  rec=$(make_bare_case non-bare "$id" no yes)
  read_bare_record "$rec"

  out=$(run_bare_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed against an ordinary clone"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the worktree"
  assert_grep "treehouse get" "$SENDKEYS_LOG" \
    "ordinary clone no longer has the pane run treehouse get"
  # The lease is a subprocess of fm-spawn.sh, never a pane command, so the pane
  # log cannot witness it either way - the treehouse argv log is the real signal
  # that no lease was taken and the ordinary path is untouched.
  assert_no_grep "--lease" "$TREEHOUSE_LOG" \
    "ordinary clone wrongly took the bare-clone lease path"
  pass "an ordinary clone still acquires its worktree through the pane's own treehouse get"
}

# A bare-flagged clone with no --lease support cannot be isolated safely, so the
# spawn must refuse by name rather than fall back to the call that corrupts.
test_bare_without_lease_support_refuses() {
  local rec id out status
  id='bare-no-lease-b4'
  rec=$(make_bare_case bare-no-lease "$id" yes no)
  read_bare_record "$rec"

  out=$(run_bare_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse a bare-flagged clone when treehouse lacks --lease"
  assert_contains "$out" "core.bare=true" "refusal did not name the bare-flagged clone"
  assert_contains "$out" "--lease" "refusal did not name the missing treehouse capability"
  assert_absent "$HOME_DIR/state/$id.meta" "refused spawn still recorded task metadata"
  pass "a bare-flagged clone refuses by name when treehouse cannot lease"
}

test_bare_flagged_clone_spawns
test_bare_flag_survives_the_spawn
test_non_bare_clone_path_is_unchanged
test_bare_without_lease_support_refuses
test_settled_path_must_be_the_leased_worktree
test_meta_records_the_treehouse_spelling_of_the_lease
test_abort_before_meta_releases_the_lease
test_abort_releases_the_lease_without_holder_guard

echo "# all fm-spawn-bare-clone tests passed"
