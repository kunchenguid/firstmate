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

# make_bare_fakebin <dir> <lease_support> builds the fake tmux and fake treehouse.
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
  local dir=$1 lease_support=$2 fakebin
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
    case "$*" in
      *"cd "*)
        printf '%s\n' "${FM_FAKE_LEASE_PATH:-}" > "$FM_FAKE_PANE_PATHFILE" ;;
      *"treehouse get"*)
        printf '%s\n' "${FM_FAKE_LEASE_PATH:-}" > "$FM_FAKE_PANE_PATHFILE" ;;
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
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_bare_case <name> <id> <bare> <lease_support> builds a home plus a project
# clone with a real linked worktree standing in for the pooled tree. When <bare>
# is yes the clone gets core.bare=true AND an untracked file in its work tree -
# the untracked file is what makes an absolute GIT_WORK_TREE override visibly
# corrupt the pool-cleanliness check above.
make_bare_case() {
  local name=$1 id=$2 bare=$3 lease_support=$4 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/pool-worktree"
  fakebin=$(make_bare_fakebin "$case_dir/fake" "$lease_support")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "pool-$name"
  git -C "$wt" checkout --detach -q
  if [ "$bare" = yes ]; then
    printf 'max_trees = 1\n' > "$proj/treehouse.toml"
    git -C "$proj" config core.bare true
  fi
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_bare_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
  SENDKEYS_LOG="$CASE_DIR/sendkeys.log"
  TREEHOUSE_LOG="$CASE_DIR/treehouse.log"
  PANE_PATHFILE="$CASE_DIR/pane-path"
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
    FM_FAKE_LEASE_PATH="$WT_DIR" FM_FAKE_PANE_PROJECT="$PROJ_DIR" \
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
  pass "a bare-flagged clone yields an isolated worktree leased by firstmate"
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

echo "# all fm-spawn-bare-clone tests passed"
