#!/usr/bin/env bash
# tests/fm-spawn-isolation.test.sh - regression coverage for bin/fm-spawn.sh's
# ship/scout isolation gate: the resolved task worktree must be a real git
# worktree root that is NOT the shared project checkout, proven before any hook,
# metadata, or launch write.
#
# The failure this file exists for: firstmate dispatched a scout for a project
# whose registered local copy sat under a firstmate home typed as
# /Users/<u>/work/firstmate while the on-disk directory was /Users/<u>/Work/...
# On a case-insensitive filesystem (macOS's default APFS, HFS+, exFAT) both
# spellings name one directory, but `pwd -P` canonicalizes symlinks WITHOUT
# normalizing case, so the two spellings stayed different strings. fm-spawn
# compared those strings to decide "has the pane left the project?" and "is this
# worktree distinct from the project?", answered yes to both, and launched the
# scout against the shared checkout - overwriting the project's own
# .claude/settings.local.json with the task's turn-end hook and recording the
# shared path as the task's worktree.
#
# The gate now answers both questions by filesystem identity (device+inode), so
# no spelling of the project can pass. The cases below pin that, plus the
# adjacent ordering hazards: nothing may be written into the project before the
# gate passes, a refusal must publish no task record and launch no agent, and
# relative and absolute project arguments must behave identically.
#
# Case-insensitivity coverage needs a case-insensitive fixture filesystem. It
# runs natively on macOS; elsewhere it reports a skip line unless
# FM_TEST_REQUIRE_CASE_INSENSITIVE=1 is set, which CI's macOS job does so the
# regression can never silently stop being exercised.
#
# One case (test_project_only_pane_refuses_and_leaves_the_project_untouched)
# deliberately pays fm-spawn's full 60s worktree-discovery timeout: it is the
# exact end-user terminal outcome, and shortening it would stop proving that the
# project spelling is refused for the whole wait rather than for a few polls.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-isolation)

# The project-owned config the live incident destroyed. Any byte change to this
# file after a spawn means the shared checkout was written to.
PROJECT_SETTINGS='{"mcpServers":{"jira":{"command":"jira-mcp","args":["--site","example"]}}}'

# --- fixture builders --------------------------------------------------------

# A fake tmux whose pane_current_path answers come from a script file, one path
# per poll, with the last line repeating forever. Every invocation is appended to
# FM_TMUX_LOG so a test can prove no launch command was ever sent.
make_isolation_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "${FM_TMUX_LOG:?}"
case "$*" in
  *"#{pane_current_path}"*)
    n=0
    if [ -s "${FM_PANE_COUNT:?}" ]; then n=$(cat "$FM_PANE_COUNT"); fi
    n=$((n + 1))
    printf '%s\n' "$n" > "$FM_PANE_COUNT"
    total=$(wc -l < "${FM_PANE_SCRIPT:?}")
    total=$((total))
    [ "$n" -le "$total" ] || n=$total
    [ "$n" -ge 1 ] || n=1
    sed -n "${n}p" "$FM_PANE_SCRIPT"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '@7\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  fm_fake_exit0 "$fb" treehouse
  printf '%s\n' "$fb"
}

# setup_case <name> <home-dir-on-disk> <home-dir-as-typed>: build a firstmate
# home, a registered project holding the captain's own .claude config, a real
# linked worktree standing in for a treehouse allocation, and an unrelated real
# git checkout. The two home arguments are the same directory whenever the
# fixture filesystem is case-insensitive; passing the same string twice gives the
# ordinary portable fixture.
setup_case() {  # <name> <home-on-disk> <home-as-typed>
  CASE_DIR="$TMP_ROOT/$1"
  HOME_REAL="$CASE_DIR/$2"
  HOME_TYPED="$CASE_DIR/$3"
  mkdir -p "$HOME_REAL/data" "$HOME_REAL/state" "$HOME_REAL/config" "$HOME_REAL/projects"
  touch "$HOME_REAL/state/.last-watcher-beat"
  PROJ="$HOME_REAL/projects/peo-native"
  TASK_WT="$CASE_DIR/pool/worktree"
  OTHER_REPO="$CASE_DIR/other-checkout"
  mkdir -p "$CASE_DIR/pool"
  fm_git_worktree "$PROJ" "$TASK_WT" "fm/$1"
  fm_git_init_commit "$OTHER_REPO"
  mkdir -p "$PROJ/.claude"
  printf '%s\n' "$PROJECT_SETTINGS" > "$PROJ/.claude/settings.local.json"
  FAKEBIN=$(make_isolation_fakebin "$CASE_DIR/fake")
  TMUX_LOG="$CASE_DIR/tmux.log"
  PANE_SCRIPT="$CASE_DIR/pane-script"
  PANE_COUNT="$CASE_DIR/pane-count"
  : > "$TMUX_LOG"
  : > "$PANE_COUNT"
}

# pane_reports <path> [more paths...]: the pane's cwd for poll 1, 2, ... with the
# final path repeating for every later poll.
pane_reports() {
  local p
  : > "$PANE_SCRIPT"
  for p in "$@"; do printf '%s\n' "$p" >> "$PANE_SCRIPT"; done
  : > "$PANE_COUNT"
  : > "$TMUX_LOG"
}

run_spawn() {  # <id> <project-arg> [extra fm-spawn args...]
  local id=$1 proj_arg=$2
  shift 2
  mkdir -p "$HOME_REAL/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_REAL/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_TYPED" \
    FM_STATE_OVERRIDE="$HOME_TYPED/state" FM_DATA_OVERRIDE="$HOME_TYPED/data" \
    FM_PROJECTS_OVERRIDE="$HOME_TYPED/projects" FM_CONFIG_OVERRIDE="$HOME_TYPED/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_TMUX_LOG="$TMUX_LOG" FM_PANE_SCRIPT="$PANE_SCRIPT" FM_PANE_COUNT="$PANE_COUNT" \
    PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$proj_arg" --harness claude "$@" 2>&1
}

# --- assertions --------------------------------------------------------------

# Byte-for-byte content of every tracked-or-untracked file in the project except
# its .git directory, so any write into the shared checkout shows up as a diff.
project_fingerprint() {  # <project-dir>
  (
    cd "$1" || exit 1
    find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do
      printf '=== %s\n' "$f"
      cat "$f"
    done
  )
}

assert_project_untouched() {  # <before> <project> <msg>
  local after
  after=$(project_fingerprint "$2")
  [ "$1" = "$after" ] || fail "$3"$'\n'"--- before ---"$'\n'"$1"$'\n'"--- after ---"$'\n'"$after"
}

assert_no_agent_launched() {  # <msg>
  ! grep -qF 'dangerously-skip-permissions' "$TMUX_LOG" \
    || fail "$1 (a launch command reached the pane; see $TMUX_LOG)"
}

# --- case-insensitivity probe ------------------------------------------------

# Echo a case-insensitive directory under TMP_ROOT, or nothing when the fixture
# filesystem distinguishes case.
case_insensitive_probe() {
  local probe="$TMP_ROOT/CaseProbe"
  mkdir -p "$probe" 2>/dev/null || return 0
  [ -d "$TMP_ROOT/caseprobe" ] || return 0
  printf 'yes\n'
}

# --- the exact end-user failure ----------------------------------------------

# fm-spawn must never accept a differently-cased spelling of the project as the
# task worktree. The pane reports the project under its on-disk case for the
# first polls while the home is addressed in another case; before the fix that
# string difference alone was accepted as "the pane left the project", so the
# project became the worktree, its .claude/settings.local.json was overwritten
# with the turn-end hook, and worktree= recorded the shared checkout.
test_case_differing_project_spelling_is_never_the_worktree() {
  local id out status before proj_canonical
  if [ -z "$(case_insensitive_probe)" ]; then
    if [ "${FM_TEST_REQUIRE_CASE_INSENSITIVE:-0}" = 1 ]; then
      fail "FM_TEST_REQUIRE_CASE_INSENSITIVE=1 but $TMP_ROOT is on a case-sensitive filesystem"
    fi
    printf 'skip: case-insensitive filesystem unavailable - case-spelling coverage not exercised here\n'
    return 0
  fi
  id=caseworktreez1
  setup_case case-worktree Home home
  proj_canonical=$(cd "$PROJ" && pwd -P)
  before=$(project_fingerprint "$PROJ")
  # Polls 1-3 report the project in its on-disk case; the pane only really
  # reaches the worktree afterwards.
  pane_reports "$proj_canonical" "$proj_canonical" "$proj_canonical" "$TASK_WT"
  out=$(run_spawn "$id" projects/peo-native --scout)
  status=$?

  expect_code 0 "$status" "spawn should succeed once the pane truly reaches the worktree"$'\n'"$out"
  assert_grep "worktree=$TASK_WT" "$HOME_REAL/state/$id.meta" \
    "meta did not record the real isolated worktree"
  assert_no_grep "worktree=$proj_canonical" "$HOME_REAL/state/$id.meta" \
    "meta recorded the shared project checkout as the task worktree"
  assert_project_untouched "$before" "$PROJ" \
    "the shared project checkout was written to while the pane still sat in it"
  assert_present "$TASK_WT/.claude/settings.local.json" \
    "the turn-end hook was not installed in the isolated worktree"
  pass "fm-spawn: a differently-cased spelling of the project is never accepted as the worktree"
}

# The terminal end-user outcome: a pane that never leaves the project (treehouse
# never moved it) must exhaust the discovery wait and refuse, with the project
# byte-identical, no task record published, and no agent launched.
test_project_only_pane_refuses_and_leaves_the_project_untouched() {
  local id out status before proj_canonical
  if [ -z "$(case_insensitive_probe)" ]; then
    if [ "${FM_TEST_REQUIRE_CASE_INSENSITIVE:-0}" = 1 ]; then
      fail "FM_TEST_REQUIRE_CASE_INSENSITIVE=1 but $TMP_ROOT is on a case-sensitive filesystem"
    fi
    printf 'skip: case-insensitive filesystem unavailable - case-spelling refusal not exercised here\n'
    return 0
  fi
  id=caserefusez2
  setup_case case-refuse Home home
  proj_canonical=$(cd "$PROJ" && pwd -P)
  before=$(project_fingerprint "$PROJ")
  pane_reports "$proj_canonical"
  out=$(run_spawn "$id" projects/peo-native --scout)
  status=$?

  assert_project_untouched "$before" "$PROJ" \
    "a refused spawn wrote into the shared project checkout"
  assert_absent "$HOME_REAL/state/$id.meta" \
    "a refused spawn published a task record"
  assert_no_agent_launched "a refused spawn still launched an agent"
  [ "$status" -ne 0 ] || fail "spawn should refuse when the pane never leaves the project"$'\n'"$out"
  assert_contains "$out" "did not enter a worktree" \
    "refusal did not explain that no worktree was ever reached"
  pass "fm-spawn: a pane that never leaves the project refuses, publishes nothing, and launches nothing"
}

# --- identity, not strings (portable) ----------------------------------------

# A symlinked spelling of the project is the same directory, so it must be
# treated exactly like the project itself rather than as somewhere the pane moved
# to. This holds on every filesystem, case-sensitive or not.
test_symlinked_project_spelling_is_not_an_isolated_worktree() {
  local id out status before link
  id=symlinkspellz3
  setup_case symlink-spelling home home
  link="$CASE_DIR/project-link"
  ln -s "$PROJ" "$link"
  before=$(project_fingerprint "$PROJ")
  pane_reports "$link" "$link" "$link" "$TASK_WT"
  out=$(run_spawn "$id" "$PROJ")
  status=$?

  expect_code 0 "$status" "spawn should succeed once the pane reaches the worktree"$'\n'"$out"
  assert_grep "worktree=$TASK_WT" "$HOME_REAL/state/$id.meta" \
    "meta did not record the real isolated worktree"
  assert_no_grep "worktree=$link" "$HOME_REAL/state/$id.meta" \
    "meta recorded a symlinked spelling of the project as the task worktree"
  assert_project_untouched "$before" "$PROJ" \
    "a symlinked spelling of the project was written to as if it were a worktree"
  pass "fm-spawn: a symlinked spelling of the project is not an isolated worktree"
}

# The gate proves a worktree ROOT, not merely "a path inside some repository":
# a subdirectory of a genuine worktree must refuse rather than become the task
# worktree.
test_worktree_subdirectory_refuses() {
  local id out status before
  id=subdirrefusez4
  setup_case subdir-refuse home home
  mkdir -p "$TASK_WT/nested"
  before=$(project_fingerprint "$PROJ")
  pane_reports "$TASK_WT/nested"
  out=$(run_spawn "$id" "$PROJ")
  status=$?

  [ "$status" -ne 0 ] || fail "spawn should refuse a subdirectory of a worktree"$'\n'"$out"
  assert_absent "$HOME_REAL/state/$id.meta" "a refused spawn published a task record"
  assert_project_untouched "$before" "$PROJ" "a refused spawn wrote into the project"
  assert_no_agent_launched "a refused spawn still launched an agent"
  assert_contains "$out" "did not yield an isolated worktree" \
    "subdirectory refusal lacked the isolation error"
  assert_contains "$out" "not the worktree root" \
    "subdirectory refusal did not name the failing condition"
  pass "fm-spawn: a subdirectory of a worktree refuses and names the failing condition"
}

# A path that is not inside any repository must refuse, and the refusal must say
# so rather than silently timing out.
test_non_repository_path_refuses() {
  local id out status before
  id=nonrepoz5
  setup_case non-repo home home
  mkdir -p "$CASE_DIR/plain-dir"
  before=$(project_fingerprint "$PROJ")
  pane_reports "$CASE_DIR/plain-dir"
  out=$(run_spawn "$id" "$PROJ" --scout)
  status=$?

  [ "$status" -ne 0 ] || fail "spawn should refuse a path outside any repository"$'\n'"$out"
  assert_absent "$HOME_REAL/state/$id.meta" "a refused spawn published a task record"
  assert_project_untouched "$before" "$PROJ" "a refused spawn wrote into the project"
  assert_no_agent_launched "a refused spawn still launched an agent"
  assert_contains "$out" "not inside a git worktree" \
    "non-repository refusal did not name the failing condition"
  pass "fm-spawn: a path outside any repository refuses and names the failing condition"
}

# --- argument-form consistency (portable) ------------------------------------

# The registered project resolves to the same directory whether firstmate passes
# projects/<name> or the absolute path, so both forms must reach the identical
# outcome - the same accepted worktree, and the same refusal when the pane stays
# in the project.
test_relative_and_absolute_project_arguments_agree() {
  local out_rel out_abs status_rel status_abs before
  setup_case arg-forms home home
  before=$(project_fingerprint "$PROJ")

  pane_reports "$TASK_WT"
  out_rel=$(run_spawn relformokz6 projects/peo-native)
  status_rel=$?
  pane_reports "$TASK_WT"
  out_abs=$(run_spawn absformokz7 "$PROJ")
  status_abs=$?
  expect_code 0 "$status_rel" "relative project argument should spawn"$'\n'"$out_rel"
  expect_code 0 "$status_abs" "absolute project argument should spawn"$'\n'"$out_abs"
  assert_grep "worktree=$TASK_WT" "$HOME_REAL/state/relformokz6.meta" \
    "relative form did not record the isolated worktree"
  assert_grep "worktree=$TASK_WT" "$HOME_REAL/state/absformokz7.meta" \
    "absolute form did not record the isolated worktree"

  pane_reports "$PROJ/nested-missing"
  mkdir -p "$PROJ/nested-missing"
  out_rel=$(run_spawn relformbadz8 projects/peo-native)
  status_rel=$?
  pane_reports "$PROJ/nested-missing"
  out_abs=$(run_spawn absformbadz9 "$PROJ")
  status_abs=$?
  rmdir "$PROJ/nested-missing"
  [ "$status_rel" -ne 0 ] || fail "relative form should refuse a path inside the project"$'\n'"$out_rel"
  [ "$status_abs" -ne 0 ] || fail "absolute form should refuse a path inside the project"$'\n'"$out_abs"
  assert_absent "$HOME_REAL/state/relformbadz8.meta" "refused relative form published a task record"
  assert_absent "$HOME_REAL/state/absformbadz9.meta" "refused absolute form published a task record"
  assert_project_untouched "$before" "$PROJ" "an argument-form spawn wrote into the project"
  assert_contains "$out_rel" "not the worktree root" "relative form gave a different refusal reason"
  assert_contains "$out_abs" "not the worktree root" "absolute form gave a different refusal reason"
  pass "fm-spawn: relative and absolute project arguments reach identical outcomes"
}

# --- scout parity and hook placement (portable) ------------------------------

# A scout is the deliverable that triggered the incident, so it must clear the
# same gate as a ship and install its hook inside the isolated worktree.
test_scout_and_ship_share_the_gate_and_hook_placement() {
  local out status before
  setup_case scout-parity home home
  before=$(project_fingerprint "$PROJ")

  pane_reports "$TASK_WT"
  out=$(run_spawn shipokz10 "$PROJ")
  status=$?
  expect_code 0 "$status" "ship spawn should succeed into an isolated worktree"$'\n'"$out"
  assert_grep "kind=ship" "$HOME_REAL/state/shipokz10.meta" "ship spawn recorded the wrong kind"

  pane_reports "$TASK_WT"
  out=$(run_spawn scoutokz11 "$PROJ" --scout)
  status=$?
  expect_code 0 "$status" "scout spawn should succeed into an isolated worktree"$'\n'"$out"
  assert_grep "kind=scout" "$HOME_REAL/state/scoutokz11.meta" "scout spawn recorded the wrong kind"

  assert_present "$TASK_WT/.claude/settings.local.json" \
    "the turn-end hook was not installed in the isolated worktree"
  assert_project_untouched "$before" "$PROJ" \
    "a valid isolated spawn still wrote into the shared project checkout"
  pass "fm-spawn: ship and scout share the isolation gate and hook the worktree, not the project"
}

# --- hook-exclusion write containment (portable) -----------------------------

# The hook is excluded from git's view through `rev-parse --git-path`, which
# answers RELATIVE to the repository for a main checkout. Resolving that answer
# inside the task worktree is what keeps the write contained: taken as-is it
# lands in whatever directory fm-spawn was invoked from, which is firstmate's own
# checkout for every ordinary dispatch. The pane here reaches an unrelated main
# checkout - a genuine worktree root, distinct from the project, so the gate
# passes - and the spawn runs from a third repository standing in for firstmate's
# own working directory.
test_hook_exclusion_write_stays_in_the_task_worktree() {
  local id out status caller
  id=excludecontainz12
  setup_case exclude-containment home home
  caller="$CASE_DIR/caller-checkout"
  fm_git_init_commit "$caller"
  pane_reports "$OTHER_REPO"
  out=$(cd "$caller" && run_spawn "$id" "$PROJ")
  status=$?

  expect_code 0 "$status" "spawn should succeed into an unrelated main checkout"$'\n'"$out"
  assert_grep '.claude/settings.local.json' "$OTHER_REPO/.git/info/exclude" \
    "the hook exclusion was not recorded in the task worktree's own repository"
  assert_no_grep '.claude/settings.local.json' "$caller/.git/info/exclude" \
    "the hook exclusion escaped into the directory fm-spawn was invoked from"
  pass "fm-spawn: the hook exclusion is written inside the task worktree, never the caller's checkout"
}

test_case_differing_project_spelling_is_never_the_worktree
test_symlinked_project_spelling_is_not_an_isolated_worktree
test_worktree_subdirectory_refuses
test_non_repository_path_refuses
test_relative_and_absolute_project_arguments_agree
test_scout_and_ship_share_the_gate_and_hook_placement
test_hook_exclusion_write_stays_in_the_task_worktree
test_project_only_pane_refuses_and_leaves_the_project_untouched

echo "# all fm-spawn-isolation tests passed"
