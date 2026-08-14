#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same executable interface also covers the optional per-project acquisition
# command: safe <slug> substitution, a creator-plus-cd command that actually
# enters the prepared worktree, two-read settling after command completion, and
# an immediate preserving refusal when a retry finds the target already present.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

make_project_command_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    n=0
    [ ! -f "$FM_FAKE_PANE_COUNTFILE" ] || n=$(cat "$FM_FAKE_PANE_COUNTFILE")
    printf '%s\n' "$((n + 1))" > "$FM_FAKE_PANE_COUNTFILE"
    cat "$FM_FAKE_PANE_PATH_FILE"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '@project-command-wid\n'; exit 0 ;;
  list-windows|has-session|new-session|kill-window|set-window-option) exit 0 ;;
  send-keys)
    printf 'tmux %s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    case "$payload" in
      *__fm_worktree_acquire*)
        (
          cd "$FM_FAKE_PROJECT" || exit 1
          eval "$payload"
          pwd -P > "$FM_FAKE_PANE_PATH_FILE"
        )
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'unexpected treehouse %s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
exit 99
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

make_project_command_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project prepared fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  prepared="$case_dir/prepared"
  fakebin=$(make_project_command_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" \
    "$home/config/worktree-acquire" "$prepared"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_init_commit "$project"
  fm_git_add_origin "$project" "$case_dir/origin.git"
  cat > "$project/prepare-worktree.sh" <<'SH'
#!/usr/bin/env bash
set -eu
slug=${1:?slug required}
printf '%s\n' "$slug" >> "$FM_FAKE_PREPARE_LOG"
target="../prepared/$slug"
if [ -e "$target" ]; then
  echo "error: $target already exists" >&2
  exit 42
fi
git worktree add --quiet -b "$slug" "$target" HEAD
SH
  chmod +x "$project/prepare-worktree.sh"
  printf '%s\n' './prepare-worktree.sh <slug> && cd ../prepared/<slug>' \
    > "$home/config/worktree-acquire/project"
  printf '%s\n' "$project" > "$case_dir/pane-path"
  : > "$case_dir/tmux.log"
  : > "$case_dir/treehouse.log"
  : > "$case_dir/prepare.log"
  printf '%s\n' "$case_dir|$home|$project|$prepared|$fakebin"
}

read_project_command_record() {
  IFS='|' read -r CUSTOM_CASE CUSTOM_HOME CUSTOM_PROJECT CUSTOM_PREPARED CUSTOM_FAKEBIN <<EOF
$1
EOF
}

run_project_command_spawn() {  # <id>
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$CUSTOM_HOME" \
    FM_STATE_OVERRIDE="$CUSTOM_HOME/state" FM_DATA_OVERRIDE="$CUSTOM_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CUSTOM_HOME/projects" FM_CONFIG_OVERRIDE="$CUSTOM_HOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PROJECT="$CUSTOM_PROJECT" \
    FM_FAKE_PANE_PATH_FILE="$CUSTOM_CASE/pane-path" \
    FM_FAKE_PANE_COUNTFILE="$CUSTOM_CASE/pane-count" \
    FM_FAKE_TMUX_LOG="$CUSTOM_CASE/tmux.log" \
    FM_FAKE_TREEHOUSE_LOG="$CUSTOM_CASE/treehouse.log" \
    FM_FAKE_PREPARE_LOG="$CUSTOM_CASE/prepare.log" \
    PATH="$CUSTOM_FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$CUSTOM_PROJECT" --mode no-mistakes --yolo off 2>&1
}

test_project_command_creates_and_enters_attached_worktree() {
  local rec id out status wt branch reads
  id='prepared-worktree-z3'
  rec=$(make_project_command_case project-command-success "$id")
  read_project_command_record "$rec"

  out=$(run_project_command_spawn "$id")
  status=$?
  expect_code 0 "$status" "configured project acquisition should spawn successfully"$'\n'"$out"
  wt="$CUSTOM_PREPARED/$id"
  assert_grep "worktree=$wt" "$CUSTOM_HOME/state/$id.meta" \
    "spawn did not record the project-prepared worktree"
  assert_grep 'worktree_provider=project-command' "$CUSTOM_HOME/state/$id.meta" \
    "spawn did not record the custom cleanup provider"
  [ "$(cat "$CUSTOM_CASE/prepare.log")" = "$id" ] \
    || fail "the safely substituted slug did not reach the project command exactly"
  assert_no_grep '<slug>' "$CUSTOM_CASE/tmux.log" \
    "the literal task placeholder reached the shell without substitution"
  assert_grep "./prepare-worktree.sh '$id' && cd ../prepared/'$id'" \
    "$CUSTOM_CASE/tmux.log" \
    "the validated task slug was not shell-quoted at every placeholder"
  [ ! -s "$CUSTOM_CASE/treehouse.log" ] \
    || fail "configured project acquisition unexpectedly invoked Treehouse"
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD) \
    || fail "project-prepared worktree was detached"
  [ "$branch" = "$id" ] \
    || fail "base refresh changed attached task branch '$id' to '$branch'"
  reads=$(cat "$CUSTOM_CASE/pane-count")
  [ "$reads" -ge 2 ] \
    || fail "configured acquisition was accepted without two working-directory reads"
  pass "a project command safely substitutes the task slug, enters its prepared worktree, and preserves the attached branch"
}

test_existing_project_target_refuses_quickly_and_preserves_work() {
  local rec id out status start end elapsed target
  id='prepared-existing-z4'
  rec=$(make_project_command_case project-command-existing "$id")
  read_project_command_record "$rec"
  target="$CUSTOM_PREPARED/$id"
  git -C "$CUSTOM_PROJECT" worktree add --quiet -b "$id" "$target" HEAD
  printf 'unlanded work must survive\n' > "$target/preserve-me.txt"

  start=$(date +%s)
  out=$(run_project_command_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  [ "$status" -ne 0 ] || fail "spawn succeeded despite the configured target already existing"
  assert_contains "$out" "exited with status 42" \
    "spawn did not surface the project command's actionable exit status"
  assert_contains "$out" "target is preserved" \
    "spawn did not state that the existing target was preserved"
  [ "$elapsed" -le 5 ] \
    || fail "an already-existing target waited ${elapsed}s instead of refusing promptly"
  assert_grep 'unlanded work must survive' "$target/preserve-me.txt" \
    "failed acquisition deleted or changed the existing target"
  assert_absent "$CUSTOM_HOME/state/$id.meta" \
    "failed acquisition published task metadata"
  [ ! -s "$CUSTOM_CASE/treehouse.log" ] \
    || fail "failed configured acquisition fell back to Treehouse"
  pass "an existing project target refuses promptly and preserves its unlanded work"
}

test_project_command_config_requires_one_placeholder_line() {
  local rec id out status config

  id='prepared-invalid-placeholder-z5'
  rec=$(make_project_command_case project-command-invalid-placeholder "$id")
  read_project_command_record "$rec"
  config="$CUSTOM_HOME/config/worktree-acquire/project"
  printf '%s\n' './prepare-worktree.sh task-without-placeholder' > "$config"
  out=$(run_project_command_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a project command without <slug>"
  assert_contains "$out" 'must contain the literal <slug> placeholder' \
    "missing-placeholder config did not produce its schema error"
  assert_absent "$CUSTOM_HOME/state/$id.meta" \
    "missing-placeholder config published task metadata"
  [ ! -s "$CUSTOM_CASE/tmux.log" ] \
    || fail "missing-placeholder config reached the task shell"

  id='prepared-invalid-lines-z6'
  rec=$(make_project_command_case project-command-invalid-lines "$id")
  read_project_command_record "$rec"
  config="$CUSTOM_HOME/config/worktree-acquire/project"
  printf '%s\n' './prepare-worktree.sh <slug>' 'cd ../prepared/<slug>' > "$config"
  out=$(run_project_command_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a multi-line project acquisition config"
  assert_contains "$out" 'must contain exactly one non-empty command line' \
    "multi-line config did not produce its schema error"
  assert_absent "$CUSTOM_HOME/state/$id.meta" \
    "multi-line config published task metadata"
  [ ! -s "$CUSTOM_CASE/tmux.log" ] \
    || fail "multi-line config reached the task shell"
  pass "project acquisition config requires exactly one command line containing <slug>"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_project_command_creates_and_enters_attached_worktree
test_existing_project_target_refuses_quickly_and_preserves_work
test_project_command_config_requires_one_placeholder_line

echo "# all fm-spawn-worktree-settle tests passed"
