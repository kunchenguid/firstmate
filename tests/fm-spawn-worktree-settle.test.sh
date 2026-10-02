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
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-treehouse-lib.sh
. "$ROOT/bin/fm-treehouse-lib.sh"

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
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      printf '%s\n' "$*" >> "$FM_FAKE_LAUNCH_LOG"
    fi
    exit 0
    ;;
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
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
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
  mkdir -p "$HOME_DIR/user-home"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_LAUNCH_LOG="$HOME_DIR/launch.log" TREEHOUSE_ROOT="$HOME_DIR/shared-treehouse" \
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

# The get command must carry the launching home's pool root, and the shell must
# resume with its original HOME before the harness launch.
test_spawn_get_uses_per_home_treehouse_root() {
  local rec id out status expected_root expected_home
  id=settle-per-home-root-z3
  rec=$(make_settle_case settle-per-home-root "$id" 0)
  read_settle_record "$rec"
  mkdir -p "$HOME_DIR/user-home"
  printf 'https://user:secret@example.invalid\n' > "$HOME_DIR/user-home/.git-credentials"
  printf 'machine example.invalid login user password secret\n' > "$HOME_DIR/user-home/.netrc"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed while recording the per-home Treehouse root"
  expected_home=$(cd "$HOME_DIR/user-home" && pwd -P)
  expected_root=$(HOME="$expected_home" fm_treehouse_pool_root "$HOME_DIR")
  case "$expected_root" in
    "$expected_home"/*) ;;
    *) fail "per-home Treehouse root '$expected_root' must live under the launching HOME, never inside the firstmate home" ;;
  esac
  assert_present "$expected_root/firstmate-home" "spawn did not prepare the per-home Treehouse root"
  [ -L "$expected_root/.git-credentials" ] || fail "spawn did not bridge the launching HOME's Git credential store"
  assert_grep "https://user:secret@example.invalid" "$expected_root/.git-credentials" \
    "prepared pool root cannot read the launching HOME's Git credential store"
  [ -L "$expected_root/.netrc" ] || fail "spawn did not bridge the launching HOME's netrc credential store"
  assert_grep "machine example.invalid login user password secret" "$expected_root/.netrc" \
    "prepared pool root cannot read the launching HOME's netrc credential store"
  assert_grep "cd $PROJ_DIR && TREEHOUSE_ROOT=$expected_root HOME=$expected_root treehouse get Enter" "$HOME_DIR/launch.log" \
    "treehouse get did not receive the per-home root"
  assert_grep "export HOME=$expected_home Enter" "$HOME_DIR/launch.log" \
    "spawn did not restore the launching HOME after Treehouse acquisition"
  pass "fm-spawn.sh scopes treehouse get to the launching home's pool and restores HOME"
}

test_spawn_refuses_project_treehouse_config() {
  local rec id out status config
  id=settle-project-config-z4
  rec=$(make_settle_case settle-project-config "$id" 0)
  read_settle_record "$rec"
  config="$PROJ_DIR/treehouse.toml"
  : > "$config"
  : > "$HOME_DIR/launch.log"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 1 "$status" "spawn should refuse a project treehouse.toml"
  assert_contains "$out" "$config" "spawn refusal did not name the project treehouse.toml"
  assert_no_grep "treehouse get" "$HOME_DIR/launch.log" \
    "spawn attempted Treehouse acquisition despite the project treehouse.toml"
  pass "fm-spawn.sh refuses project treehouse.toml before Treehouse acquisition"
}

test_pool_root_keeps_sha1_key_with_sha1sum_fallback() {
  local shasum_bin sha1sum_bin root_with_shasum root_with_sha1sum status cut_path
  shasum_bin="$HOME_DIR/shasum-tools"
  sha1sum_bin="$HOME_DIR/sha1sum-tools"
  mkdir -p "$shasum_bin" "$sha1sum_bin" "$HOME_DIR/user-home"
  cut_path=$(command -v cut)
  ln -sf "$cut_path" "$shasum_bin/cut"
  ln -sf "$cut_path" "$sha1sum_bin/cut"
  printf '%s\n' '#!/bin/sh' 'IFS= read -r input || :' "printf '%s  -\\n' 0123456789abcdef0123456789abcdef01234567" > "$shasum_bin/shasum"
  printf '%s\n' '#!/bin/sh' 'IFS= read -r input || :' "printf '%s  -\\n' 0123456789abcdef0123456789abcdef01234567" > "$sha1sum_bin/sha1sum"
  chmod +x "$shasum_bin/shasum" "$sha1sum_bin/sha1sum"

  status=0
  root_with_shasum=$(PATH="$shasum_bin" HOME="$HOME_DIR/user-home" fm_treehouse_pool_root "$HOME_DIR") || status=$?
  expect_code 0 "$status" "pool root should resolve with the established shasum path"
  status=0
  root_with_sha1sum=$(PATH="$sha1sum_bin" HOME="$HOME_DIR/user-home" fm_treehouse_pool_root "$HOME_DIR") || status=$?
  expect_code 0 "$status" "pool root should resolve when sha1sum is the only available hasher"
  [ "$root_with_sha1sum" = "$root_with_shasum" ] || \
    fail "sha1sum fallback changed the established pool key: '$root_with_shasum' != '$root_with_sha1sum'"
  [ "${root_with_sha1sum##*/}" = 0123456789ab ] || fail "SHA-1 pool key was not truncated to its first 12 hex characters"
  pass "Treehouse pool roots keep the established SHA-1 key with the sha1sum fallback"
}

test_pool_root_refuses_relative_override() {
  local out status
  status=0
  out=$(FM_TREEHOUSE_POOL_BASE=relative-pools HOME="$HOME_DIR/user-home" \
    fm_treehouse_pool_root "$HOME_DIR" 2>&1) || status=$?
  expect_code 1 "$status" "relative Treehouse pool bases should be refused"
  assert_contains "$out" "must be absolute" "relative pool-base refusal was not actionable"
  pass "Treehouse pool roots refuse caller-relative overrides"
}

test_prepare_root_filters_treehouse_user_config() {
  local user_home pool_root race_bin real_ln
  user_home="$HOME_DIR/config-user-home"
  pool_root="$HOME_DIR/prepared-pool"
  mkdir -p "$user_home/.config/git" "$user_home/.config/treehouse" "$pool_root"
  printf 'root = "/shared"\n' > "$user_home/.config/treehouse/config.toml"
  ln -s "$user_home/.config" "$pool_root/.config"

  HOME="$user_home" fm_treehouse_prepare_root "$HOME_DIR" "$pool_root" || \
    fail "pool preparation failed while migrating the existing .config link"
  [ -d "$pool_root/.config" ] && [ ! -L "$pool_root/.config" ] || \
    fail "pool preparation did not replace the broad .config link with a real directory"
  [ -L "$pool_root/.config/git" ] || fail "pool preparation did not bridge non-Treehouse user config"
  [ ! -e "$pool_root/.config/treehouse" ] && [ ! -L "$pool_root/.config/treehouse" ] || \
    fail "pool preparation exposed the user's Treehouse root configuration"

  mkdir -p "$user_home/.config/gh"
  ln -s "$user_home/.config/treehouse" "$pool_root/.config/treehouse"
  race_bin="$HOME_DIR/config-race-bin"
  real_ln=$(command -v ln)
  mkdir -p "$race_bin"
  printf '%s\n' '#!/bin/sh' \
    "for arg do config_target=\$arg; done" \
    "case \"\$config_target\" in */git) exit 91 ;; esac" \
    "\"\$FM_REAL_LN\" \"\$@\"" \
    'exit 1' > "$race_bin/ln"
  chmod +x "$race_bin/ln"
  HOME="$user_home" FM_REAL_LN="$real_ln" PATH="$race_bin:$PATH" \
    fm_treehouse_prepare_root "$HOME_DIR" "$pool_root" || \
    fail "pool preparation failed while refreshing filtered user config"
  [ -L "$pool_root/.config/git" ] || fail "pool preparation replaced a valid config bridge"
  [ -L "$pool_root/.config/gh" ] || fail "pool preparation did not bridge a newly added user config entry"
  [ ! -e "$pool_root/.config/treehouse" ] && [ ! -L "$pool_root/.config/treehouse" ] || \
    fail "pool preparation retained a stale Treehouse config link"
  pass "Treehouse pool preparation bridges user config without exposing Treehouse root settings"
}

test_pool_root_recovery_uses_fixed_treehouse_layout() {
  local pool_root worktree recovered
  pool_root="$HOME_DIR/user-home/.treehouse/firstmate/0123456789ab"
  worktree="$pool_root/.treehouse/.treehouse-deadbeef/slot/.treehouse"
  recovered=$(fm_treehouse_root_for_worktree "$HOME_DIR" "$worktree") || \
    fail "pool-root recovery failed for a .treehouse repository in the fixed Treehouse layout"
  [ "$recovered" = "$pool_root" ] || \
    fail "pool-root recovery did not use the fixed Treehouse layout: '$recovered' != '$pool_root'"
  pass "Treehouse return recovers the pool root for a .treehouse repository"
}

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 3 ] || fail "already-settled pane took $reads reads to confirm - expected the first read, one confirmation, and the launch-boundary cwd check"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

test_single_stale_first_read_is_not_accepted
test_spawn_get_uses_per_home_treehouse_root
test_spawn_refuses_project_treehouse_config
test_pool_root_keeps_sha1_key_with_sha1sum_fallback
test_pool_root_refuses_relative_override
test_prepare_root_filters_treehouse_user_config
test_pool_root_recovery_uses_fixed_treehouse_layout
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline

echo "# all fm-spawn-worktree-settle tests passed"
