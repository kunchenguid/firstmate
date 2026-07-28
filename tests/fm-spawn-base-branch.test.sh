#!/usr/bin/env bash
# Regression test for fm-spawn.sh's task-worktree base branch
# (bin/fm-spawn.sh's ensure_spawn_base_branch, bin/fm-project-mode.sh's base=).
#
# A freshly allocated pool worktree lands on the repo's DEFAULT branch. For a
# project that develops on another branch that is silently the wrong base: task
# jt-style-number-column audited a tree 1036 commits behind origin/develop and
# correctly reported that nothing described in its brief existed. A REUSED slot
# already sits on the right branch, which is why only a cold slot is affected.
#
# The fixtures below build exactly that shape - a main-defaulted clone whose
# work happens on develop, plus a cold worktree detached at main - and assert
# the recorded base is checked out, an unconfirmable base is refused instead of
# launched, and a project with no base= record still spawns as it does today.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-base-branch)
fm_git_identity

# make_base_fakebin <dir>: fake tmux reporting the cold worktree as the pane's
# cwd (standing in for treehouse get), plus a no-op treehouse.
make_base_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_base_case <name> <id> <primary-branch> [registry-line]: build a home plus
# a project clone whose default branch is main and whose develop branch is three
# commits ahead, with a COLD worktree detached at main. <primary-branch> is the
# branch the project clone itself sits on; a registry line is written only when
# one is given (its absence is the unregistered-project case).
make_base_case() {
  local name=$1 id=$2 primary=$3 reg_line=${4:-}
  local case_dir home src bare proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  src="$case_dir/src"
  bare="$case_dir/remote.git"
  proj="$case_dir/projects/$name"
  wt="$case_dir/cold-slot"
  fakebin=$(make_base_fakebin "$case_dir/fake")

  fm_git_init_commit "$src"
  git -C "$src" branch -M main
  git -C "$src" checkout -q -b develop
  local i
  for i in 1 2 3; do
    printf 'develop work %s\n' "$i" > "$src/dev-$i.txt"
    git -C "$src" add "dev-$i.txt"
    git -C "$src" commit -qm "develop $i"
  done
  git -C "$src" checkout -q main
  git clone --quiet --bare "$src" "$bare"
  mkdir -p "$case_dir/projects"
  git clone --quiet "$bare" "$proj"
  git -C "$proj" checkout -q "$primary"
  # The cold slot: a brand-new worktree off the DEFAULT branch, exactly what a
  # freshly allocated pool slot hands over.
  git -C "$proj" worktree add --quiet --detach "$wt" main

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  if [ -n "$reg_line" ]; then
    printf '# Projects\n%s\n' "$reg_line" > "$home/data/projects.md"
  fi

  printf '%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin"
}

read_base_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_base_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

head_sha() { git -C "$1" rev-parse HEAD; }

# A cold slot for a develop-based project starts the worker on develop, not on
# the default branch the slot was allocated from.
test_recorded_base_is_checked_out() {
  local rec id out status
  id=base-recorded-b1
  rec=$(make_base_case base-recorded "$id" main \
    '- base-recorded [no-mistakes base=develop] - develop-based (added 2026-07-28)')
  read_base_record "$rec"

  out=$(run_base_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed with a recorded base branch: $out"
  [ "$(head_sha "$WT_DIR")" = "$(git -C "$PROJ_DIR" rev-parse origin/develop)" ] \
    || fail "cold slot was not moved to the recorded base branch (HEAD $(head_sha "$WT_DIR"))"
  pass "a cold slot for a develop-based project starts the worker on develop"
}

# The assertion fires: no base record, and the default branch the slot came from
# is genuinely behind the branch the project is actually developed on.
test_unconfirmable_base_is_refused() {
  local rec id out status
  id=base-stale-b2
  rec=$(make_base_case base-stale "$id" develop \
    '- base-stale [no-mistakes] - no base record (added 2026-07-28)')
  read_base_record "$rec"

  out=$(run_base_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn onto an unconfirmable base should have been refused: $out"
  assert_contains "$out" "cannot be confirmed correct" "refusal did not explain the base could not be confirmed"
  assert_contains "$out" "expected base 'develop'" "refusal did not name the expected branch"
  assert_contains "$out" "Actual base 'main'" "refusal did not name the actual base"
  assert_contains "$out" "3 commits behind" "refusal did not report the gap"
  assert_contains "$out" "base=develop" "refusal did not say how to record the base"
  [ -f "$HOME_DIR/state/$id.meta" ] && fail "a refused spawn must not publish task metadata"
  pass "a worker whose base cannot be confirmed is refused, naming branch, base, and gap"
}

# The assertion passes when the default branch IS the right base: no record, and
# the project develops on its default branch.
test_default_base_passes_assertion() {
  local rec id out status
  id=base-default-b3
  rec=$(make_base_case base-default "$id" main \
    '- base-default [direct-PR] - main-based (added 2026-07-28)')
  read_base_record "$rec"

  out=$(run_base_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the default branch is the right base: $out"
  [ "$(head_sha "$WT_DIR")" = "$(git -C "$PROJ_DIR" rev-parse origin/main)" ] \
    || fail "worker was not left on the default branch"
  assert_grep "mode=direct-PR" "$HOME_DIR/state/$id.meta" "delivery mode was not recorded"
  pass "a project whose default branch is the right base passes the assertion"
}

# An unregistered project - no registry at all - spawns exactly as it does today.
test_unregistered_project_spawns_as_today() {
  local rec id out status
  id=base-unregistered-b4
  rec=$(make_base_case base-unregistered "$id" main)
  read_base_record "$rec"
  [ -f "$HOME_DIR/data/projects.md" ] && fail "fixture should have no registry"

  out=$(run_base_spawn "$id")
  status=$?
  expect_code 0 "$status" "an unregistered project must still spawn: $out"
  [ "$(head_sha "$WT_DIR")" = "$(git -C "$PROJ_DIR" rev-parse origin/main)" ] \
    || fail "unregistered project did not fall back to the repo default branch"
  assert_grep "mode=no-mistakes" "$HOME_DIR/state/$id.meta" "unregistered fallback mode changed"
  pass "an unregistered project falls back to the default branch and spawns as today"
}

# A base= record naming a branch this repo does not have is refused rather than
# silently ignored back to the default branch.
test_missing_base_branch_is_refused() {
  local rec id out status
  id=base-typo-b5
  rec=$(make_base_case base-typo "$id" main \
    '- base-typo [no-mistakes base=develp] - typo in the base record (added 2026-07-28)')
  read_base_record "$rec"

  out=$(run_base_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a base= record naming a missing branch should be refused: $out"
  assert_contains "$out" "'develp'" "refusal did not name the missing base branch"
  pass "a base= record naming a branch the repo does not have is refused"
}

# A local-only project lands work with bin/fm-merge-local.sh, which fast-forwards
# the LOCAL default branch and never pushes, so origin/main is the stale ref
# there and the worker must start from the local branch instead.
test_local_only_prefers_local_branch() {
  local rec id out status
  id=base-localonly-b6
  rec=$(make_base_case base-localonly "$id" main \
    '- base-localonly [local-only] - merged locally, never pushed (added 2026-07-28)')
  read_base_record "$rec"
  printf 'landed locally\n' > "$PROJ_DIR/landed.txt"
  git -C "$PROJ_DIR" add landed.txt
  git -C "$PROJ_DIR" commit -qm "landed locally"

  out=$(run_base_spawn "$id")
  status=$?
  expect_code 0 "$status" "a local-only project must still spawn: $out"
  [ "$(head_sha "$WT_DIR")" = "$(git -C "$PROJ_DIR" rev-parse main)" ] \
    || fail "local-only worker did not start from the local default branch (HEAD $(head_sha "$WT_DIR"))"
  [ "$(head_sha "$WT_DIR")" != "$(git -C "$PROJ_DIR" rev-parse origin/main)" ] \
    || fail "local-only worker started from the stale origin/main"
  pass "a local-only project starts the worker from the local default branch"
}

# The registry parse: base= is readable alongside the delivery mode, and every
# pre-existing line shape keeps parsing to exactly the same two words.
test_registry_parse_is_backward_compatible() {
  local dir out
  dir="$TMP_ROOT/parse/data"
  mkdir -p "$dir"
  cat > "$dir/projects.md" <<'EOF'
# Projects
- legacy - plain line (added 2026-01-01)
- moded [direct-PR] - mode only (added 2026-01-01)
- yolod [local-only +yolo] - mode and yolo (added 2026-01-01)
- based [no-mistakes base=develop] - base record (added 2026-01-01)
- everything [direct-PR +yolo base=develop] - all tokens (added 2026-01-01)
- reordered [direct-PR base=develop +yolo] - unordered tokens (added 2026-01-01)
- baseonly [base=develop] - base without a mode (added 2026-01-01)
EOF

  local name want
  while IFS='|' read -r name want; do
    [ -n "$name" ] || continue
    out=$(FM_DATA_OVERRIDE="$dir" "$MODE" "$name" 2>/dev/null)
    [ "$out" = "$want" ] \
      || fail "delivery-mode parse changed for $name: got '$out', want '$want'"
  done <<'EOF'
legacy|no-mistakes off
moded|direct-PR off
yolod|local-only on
based|no-mistakes off
everything|direct-PR on
reordered|direct-PR on
baseonly|no-mistakes off
EOF

  for name in based everything reordered baseonly; do
    out=$(FM_DATA_OVERRIDE="$dir" "$MODE" --base "$name" 2>/dev/null)
    [ "$out" = develop ] || fail "--base did not read base= for $name: got '$out'"
  done
  for name in legacy moded yolod absent; do
    out=$(FM_DATA_OVERRIDE="$dir" "$MODE" --base "$name" 2>/dev/null)
    [ -z "$out" ] || fail "--base invented a base branch for $name: got '$out'"
  done
  out=$(FM_DATA_OVERRIDE="$TMP_ROOT/parse/absent" "$MODE" --base anything 2>/dev/null)
  [ -z "$out" ] || fail "--base against a missing registry should print nothing: got '$out'"

  pass "base= parses alongside the delivery mode without changing any existing line's mode"
}

test_registry_parse_is_backward_compatible
test_recorded_base_is_checked_out
test_unconfirmable_base_is_refused
test_default_base_passes_assertion
test_unregistered_project_spawns_as_today
test_missing_base_branch_is_refused
test_local_only_prefers_local_branch

echo "# all fm-spawn-base-branch tests passed"
