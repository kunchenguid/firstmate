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
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
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
    FM_FAKE_TMUX_LOG="$HOME_DIR/tmux.log" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status wt_real stale_real
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  wt_real=$(cd "$WT_DIR" && pwd -P)
  stale_real=$(cd "$STALE_DIR" && pwd -P)
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$wt_real" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$stale_real" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed physical logical token
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"
  physical=$(cd "$WT_DIR" && pwd -P)
  logical="$TMP_ROOT/settle-already-settled/wt-logical"
  ln -s "$physical" "$logical"
  WT_DIR=$logical

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  [ "$(cat "$COUNTFILE")" = 2 ] \
    || fail "physical-path guard did not require two repeated logical worktree observations"
  assert_grep "worktree=$physical" "$HOME_DIR/state/$id.meta" \
    "meta did not record the physical already-settled worktree"
  assert_no_grep "worktree=$logical" "$HOME_DIR/state/$id.meta" \
    "meta retained the reusable worktree's symlink spelling"
  token=$(sed -n 's/^worker_token=//p' "$HOME_DIR/state/$id.meta")
  case "$token" in *[!0-9a-f]*) fail "spawn recorded a malformed worker token: $token" ;; esac
  [ "${#token}" -eq 32 ] || fail "spawn did not record a 128-bit worker token"
  assert_grep "FM_WORKER_TOKEN=$token" "$HOME_DIR/tmux.log" \
    "the recorded worker token was not carried on the launch command"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane records its physical path and carries one task token without an extra poll cycle"
}

# The active assertion above must not merely document the intended output: it
# must go RED when the two canonicalization points on this path are removed.
# The fake pane supplies the same logical symlink path twice, so a raw-path
# implementation would record that spelling rather than pwd -P's physical one.
test_physical_canonicalization_guard_goes_red() {
  local rec id out status physical logical neutralized real_spawn
  id=settle-physical-guard-z3
  rec=$(make_settle_case settle-physical-guard "$id" 0)
  read_settle_record "$rec"
  physical=$(cd "$WT_DIR" && pwd -P)
  logical="$TMP_ROOT/settle-physical-guard/wt-logical"
  ln -s "$physical" "$logical"
  WT_DIR=$logical
  # Run the temporary variant from a complete sibling bin/ directory: spawn
  # deliberately resolves its helper libraries relative to its own location.
  cp -R "$ROOT/bin" "$TMP_ROOT/bin"
  neutralized="$TMP_ROOT/bin/fm-spawn.sh"
  perl -pe 's{p_real=\$\(real_path_or_raw "\$p"\)}{p_real=\$p}; s{WT=\$\(real_path_or_raw "\$WT"\)}{: # canonicalization intentionally neutralized}' \
    "$SPAWN" > "$neutralized"
  chmod +x "$neutralized"
  real_spawn=$SPAWN
  SPAWN=$neutralized
  out=$(run_settle_spawn "$id")
  status=$?
  SPAWN=$real_spawn
  expect_code 0 "$status" "neutralized fixture should still expose the raw-path regression"
  [ "$(cat "$COUNTFILE")" = 2 ] \
    || fail "neutralized fixture did not receive two repeated logical worktree observations"
  grep -Fqx "worktree=$logical" "$HOME_DIR/state/$id.meta" \
    || fail "neutralizing physical canonicalization did not record the logical symlink spelling: $out"
  if grep -Fqx "worktree=$physical" "$HOME_DIR/state/$id.meta"; then
    fail "neutralizing physical canonicalization left the physical-path assertion green: $out"
  fi
  pass "removing physical canonicalization turns the symlinked-worktree assertion RED"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_physical_canonicalization_guard_goes_red

echo "# all fm-spawn-worktree-settle tests passed"
