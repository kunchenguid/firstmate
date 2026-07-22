#!/usr/bin/env bash
# Regression tests for fm-spawn.sh's treehouse-get worktree-detection settle
# loop and the independent validate_spawn_worktree safety check.
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta.
# The same string-based path logic also let a case-variant spelling of the
# unchanged primary directory win on a case-insensitive filesystem.
# These tests simulate both sequences and assert that metadata and teardown
# use the real, settled git top-level, never a stale or primary path alias.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
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
    if [ "$n" -eq 1 ] && [ -n "${FM_FAKE_RENAME_FROM:-}" ]; then
      mv "$FM_FAKE_RENAME_FROM" "${FM_FAKE_RENAME_TO:?FM_FAKE_RENAME_TO unset}"
    fi
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
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_FAKE_TREEHOUSE_LOG:-}" ]; then
  { printf 'treehouse'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$FM_FAKE_TREEHOUSE_LOG"
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" sleep
  printf '%s\n' "$fakebin"
}

add_nonisolated_orca_fake() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'orca'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "${FM_FAKE_ORCA_LOG:?}"
case "${1:-} ${2:-}" in
  'status --json')
    printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
    ;;
  'repo show')
    exit 1
    ;;
  'repo add')
    printf '{"ok":true,"result":{"repo":{"id":"repo-primary-alias"}}}\n'
    ;;
  'worktree create')
    if [ -n "${FM_FAKE_RENAME_FROM:-}" ]; then
      mv "$FM_FAKE_RENAME_FROM" "${FM_FAKE_RENAME_TO:?FM_FAKE_RENAME_TO unset}"
    fi
    printf '{"ok":true,"result":{"worktree":{"id":"wt-primary-alias","path":"%s"},"terminal":{"handle":"term-primary-alias"}}}\n' \
      "${FM_FAKE_ORCA_WORKTREE_PATH:?}"
    ;;
  'terminal close'|'worktree rm')
    printf '{"ok":true,"result":{}}\n'
    ;;
  *)
    printf '{"ok":true,"result":{}}\n'
    ;;
esac
SH
  chmod +x "$fakebin/orca"
}

# Print a differently-cased spelling of <dir> that identifies the same
# directory on every supported test filesystem. A case-insensitive filesystem
# resolves it natively; a case-sensitive filesystem gets an equivalent symlink.
case_variant_dir_alias() {  # <dir>
  local dir=$1 parent base variant alias
  parent=$(dirname "$dir")
  base=$(basename "$dir")
  variant=$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]')
  [ "$variant" != "$base" ] || fail "case-variant fixture needs an alphabetic directory basename: $base"
  alias="$parent/$variant"
  [ -e "$alias" ] || ln -s "$dir" "$alias"
  [ "$alias" -ef "$dir" ] || fail "case-variant fixture does not identify the source directory: $alias"
  printf '%s\n' "$alias"
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
  wt=$(cd "$wt" && pwd -P)
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
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" "$@" 2>&1
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

# Herdr can report the unchanged primary directory with letter casing that
# differs from the physical project spelling on case-insensitive macOS.
# Use that native alias where available and an equivalent symlink on
# case-sensitive CI, then require two alias reads before the real worktree.
# The spawn must wait through both primary-directory replies, record the git
# top-level reached afterward, and hand exactly that path to teardown.
test_case_variant_primary_alias_waits_for_real_worktree_and_cleanup_target() {
  local rec id out status project_alias polls teardown_log teardown_out
  id=settle-case-alias-z3
  rec=$(make_settle_case settle-case-alias "$id" 2)
  read_settle_record "$rec"
  project_alias=$(case_variant_dir_alias "$PROJ_DIR")
  STALE_DIR=$project_alias

  out=$(run_settle_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "spawn should wait through case-variant primary replies and accept the real worktree"$'\n'"$out"
  polls=$(cat "$COUNTFILE")
  [ "$polls" -ge 4 ] || fail "spawn accepted the case-variant primary alias before the real worktree transition (polls=$polls)"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the actual isolated git top-level"
  assert_no_grep "worktree=$project_alias" "$HOME_DIR/state/$id.meta" \
    "meta recorded the case-variant primary alias"

  printf 'case-variant isolation findings\n' > "$HOME_DIR/data/$id/report.md"
  printf 'decisions_reviewed=1\ndecision_keys=\n' >> "$HOME_DIR/state/$id.meta"
  teardown_log="$HOME_DIR/treehouse-teardown.log"
  : > "$teardown_log"
  teardown_out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_FAKE_TREEHOUSE_LOG="$teardown_log" PATH="$FAKEBIN_DIR:$PATH" \
      "$TEARDOWN" "$id" 2>&1
  )
  status=$?
  expect_code 0 "$status" "teardown should consume the recorded isolated worktree"$'\n'"$teardown_out"
  assert_contains "$(cat "$teardown_log")" $'treehouse\x1freturn\x1f--force\x1f'"$WT_DIR" \
    "teardown did not target the actual isolated worktree"
  assert_not_contains "$(cat "$teardown_log")" "$project_alias" \
    "teardown targeted the case-variant primary alias"
  pass "case-variant primary cwd aliases cannot win the settle race or become metadata/cleanup targets"
}

# Orca supplies its worktree path directly and therefore bypasses the settle
# loop. The shared final validator must independently reject the primary by
# filesystem identity even when Orca returns a case-variant alias.
test_validator_refuses_case_variant_primary_alias_without_settle_loop() {
  local rec id out status project_alias orca_log
  id=validate-case-alias-z4
  rec=$(make_settle_case validate-case-alias "$id" 0)
  read_settle_record "$rec"
  project_alias=$(case_variant_dir_alias "$PROJ_DIR")
  orca_log="$HOME_DIR/orca.log"
  : > "$orca_log"
  add_nonisolated_orca_fake "$FAKEBIN_DIR"

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_ORCA_LOG="$orca_log" \
      FM_FAKE_ORCA_WORKTREE_PATH="$project_alias" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --harness codex --backend orca 2>&1
  )
  status=$?
  expect_code 1 "$status" "validator should refuse Orca's case-variant primary alias"
  assert_contains "$out" "orca worktree create did not yield an isolated worktree" \
    "validator did not report the isolation refusal"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "validator published metadata for the primary checkout alias"
  assert_contains "$(cat "$orca_log")" $'orca\x1fterminal\x1fclose\x1f--terminal\x1fterm-primary-alias' \
    "validation abort did not close Orca's implicit terminal"
  assert_contains "$(cat "$orca_log")" $'orca\x1fworktree\x1frm\x1f--worktree\x1fid:wt-primary-alias' \
    "validation abort did not remove Orca's claimed worktree"
  pass "validate_spawn_worktree independently rejects a case-variant primary alias by filesystem identity"
}

test_settle_loop_refuses_missing_primary_identity() {
  local rec id out status renamed_project
  id=settle-missing-primary-z5
  rec=$(make_settle_case settle-missing-primary "$id" 60)
  read_settle_record "$rec"
  renamed_project="$(dirname "$PROJ_DIR")/renamed-primary"
  STALE_DIR=$renamed_project

  out=$(
    FM_FAKE_RENAME_FROM="$PROJ_DIR" FM_FAKE_RENAME_TO="$renamed_project" \
      run_settle_spawn "$id" 2>&1
  )
  status=$?
  expect_code 1 "$status" "settle loop should refuse to infer distinction after the primary path disappears"
  assert_contains "$out" "treehouse get did not enter a worktree" \
    "settle loop accepted the renamed primary checkout as isolated"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "settle loop published metadata after losing the primary identity path"
  pass "settle loop requires positive filesystem distinction from an existing primary path"
}

test_validator_refuses_missing_primary_identity() {
  local rec id out status renamed_project orca_log
  id=validate-missing-primary-z6
  rec=$(make_settle_case validate-missing-primary "$id" 0)
  read_settle_record "$rec"
  renamed_project="$(dirname "$PROJ_DIR")/renamed-primary"
  orca_log="$HOME_DIR/orca.log"
  : > "$orca_log"
  add_nonisolated_orca_fake "$FAKEBIN_DIR"

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_ORCA_LOG="$orca_log" \
      FM_FAKE_RENAME_FROM="$PROJ_DIR" FM_FAKE_RENAME_TO="$renamed_project" \
      FM_FAKE_ORCA_WORKTREE_PATH="$renamed_project" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --harness codex --backend orca 2>&1
  )
  status=$?
  expect_code 1 "$status" "validator should refuse to infer distinction after the primary path disappears"
  assert_contains "$out" "orca worktree create did not yield an isolated worktree" \
    "validator accepted the renamed primary checkout as isolated"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "validator published metadata after losing the primary identity path"
  pass "validator requires positive filesystem distinction from an existing primary path"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_case_variant_primary_alias_waits_for_real_worktree_and_cleanup_target
test_validator_refuses_case_variant_primary_alias_without_settle_loop
test_settle_loop_refuses_missing_primary_identity
test_validator_refuses_missing_primary_identity

echo "# all fm-spawn-worktree-settle tests passed"
