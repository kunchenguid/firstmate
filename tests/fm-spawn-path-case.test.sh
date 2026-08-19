#!/usr/bin/env bash
# Regression test for fm-spawn.sh's directory comparisons when one directory is
# reachable under more than one spelling (bin/fm-spawn.sh: the treehouse-get
# settle loop and validate_spawn_worktree).
#
# macOS volumes are case-insensitive by default, so /a/Code/x and /a/code/x are
# ONE directory. bash's `pwd -P` resolves symlinks but preserves whatever case
# the caller cd'd with, while every backend's pane-path read and
# `git rev-parse --show-toplevel` report the canonical case. Comparing those as
# strings made two spellings of one directory look like two directories, and
# broke the spawn chain in both directions:
#
#   - The settle loop read the pane's canonical-case PROJECT path as "the pane
#     already left the project", accepted it, and recorded the PRIMARY CHECKOUT
#     as worktree= in state/<id>.meta - the exact tangle the loop exists to
#     prevent. validate_spawn_worktree then compared the same two spellings and
#     passed instead of refusing.
#   - Read the other way, a legitimate worktree reported under a non-canonical
#     spelling failed the guard's own wt/wt-top check, refusing a spawn that
#     never tangled anything.
#
# Both directions are pinned below, together with the guard's refusal on a path
# it cannot prove is an isolated worktree, so no future change can buy the first
# two by making the guard lenient.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-path-case)

# Filesystem identity of a directory: equal for every spelling that reaches one
# directory. The assertions below compare recorded paths this way rather than as
# strings, because the meta may legitimately record any spelling of the right
# directory - only which directory it names is under test.
if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
  dir_identity() { stat -f '%d:%i' "$1" 2>/dev/null || true; }
else
  dir_identity() { stat -c '%d:%i' "$1" 2>/dev/null || true; }
fi

# lower_case_component <path> <mixed-case-component>: the same path with that one
# component lowercased, leaving every other byte untouched.
lower_case_component() {
  local path=$1 component=$2 lowered
  lowered=$(printf '%s' "$component" | tr '[:upper:]' '[:lower:]')
  printf '%s\n' "${path//$component/$lowered}"
}

# This whole file is about a case-INSENSITIVE filesystem. On a case-sensitive one
# the two spellings are genuinely two directories and there is no bug to pin, so
# skip loudly rather than passing vacuously.
mkdir -p "$TMP_ROOT/CaseProbe"
if [ -z "$(dir_identity "$TMP_ROOT/CaseProbe")" ] ||
  [ "$(dir_identity "$TMP_ROOT/CaseProbe")" != "$(dir_identity "$TMP_ROOT/caseprobe")" ]; then
  echo "skip: ${TMPDIR:-/tmp} is a case-sensitive filesystem; the path-case tangle cannot occur here"
  exit 0
fi

# make_case_fakebin <dir>: a fake tmux whose `#{pane_current_path}` query walks a
# scripted sequence of paths, one per line, repeating the last line forever. The
# sequence is how each case below stages what the pane reports and when.
make_case_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    seqfile="${FM_FAKE_PANE_SEQUENCE:?FM_FAKE_PANE_SEQUENCE unset}"
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    total=$(wc -l < "$seqfile" | tr -d ' ')
    [ "$n" -le "$total" ] || n=$total
    sed -n "${n}p" "$seqfile"
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

# make_case_home <name> <id>: a firstmate home plus a project with one real
# worktree, both under a deliberately mixed-case directory component so each case
# can address them under a second, lowercased spelling of the same directories.
# Sets CASE_DIR / HOME_DIR / PROJ_DIR / WT_DIR / FAKEBIN_DIR / SEQFILE /
# COUNTFILE, and the ALT_* spellings that reach the very same directories.
make_case_home() {
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/CaseSpawn-$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  SEQFILE="$CASE_DIR/pane-sequence"
  COUNTFILE="$CASE_DIR/pane-call-count"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  touch "$HOME_DIR/state/.last-watcher-beat"
  FAKEBIN_DIR=$(make_case_fakebin "$CASE_DIR/fake")
  ALT_PROJ_DIR=$(lower_case_component "$PROJ_DIR" "CaseSpawn-$name")
  ALT_WT_DIR=$(lower_case_component "$WT_DIR" "CaseSpawn-$name")
  # The alternate spellings must reach the very same directories, or every case
  # below would be testing two unrelated paths instead of one path twice.
  [ -n "$(dir_identity "$PROJ_DIR")" ] && [ "$(dir_identity "$PROJ_DIR")" = "$(dir_identity "$ALT_PROJ_DIR")" ] ||
    fail "fixture: '$ALT_PROJ_DIR' does not reach the same directory as '$PROJ_DIR'"
  [ -n "$(dir_identity "$WT_DIR")" ] && [ "$(dir_identity "$WT_DIR")" = "$(dir_identity "$ALT_WT_DIR")" ] ||
    fail "fixture: '$ALT_WT_DIR' does not reach the same directory as '$WT_DIR'"
}

# stage_pane_sequence <path> ...: what the pane reports, one read per argument,
# with the last one repeating for the rest of the settle loop.
stage_pane_sequence() {
  local path
  : > "$SEQFILE"
  for path in "$@"; do
    printf '%s\n' "$path" >> "$SEQFILE"
  done
  : > "$COUNTFILE"
}

# run_case_spawn <id> <project-arg>: spawn <id> against the project addressed
# exactly as given, so a case can hand fm-spawn a non-canonical spelling.
run_case_spawn() {
  local id=$1 project_arg=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_SEQUENCE="$SEQFILE" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$project_arg" --mode no-mistakes --yolo off 2>&1
}

# recorded_worktree <id>: the worktree= value fm-spawn wrote to state/<id>.meta.
recorded_worktree() {
  sed -n 's/^worktree=//p' "$HOME_DIR/state/$1.meta" 2>/dev/null | head -n 1
}

# The incident itself. firstmate reaches the project under a non-canonical
# spelling, so fm-spawn's own project path carries that spelling, while the pane
# reports the canonical one until `treehouse get` lands. Those are the same
# directory, so the settle loop must keep waiting for the real worktree rather
# than accepting the project as one - and the recorded worktree must be the
# isolated worktree, never the primary checkout.
test_project_under_another_spelling_is_not_recorded_as_the_worktree() {
  local id out status recorded
  id="path-case-primary-c1"
  make_case_home primary "$id"
  # Four reads still inside the project (canonical spelling), then the worktree.
  stage_pane_sequence "$PROJ_DIR" "$PROJ_DIR" "$PROJ_DIR" "$PROJ_DIR" "$WT_DIR"

  out=$(run_case_spawn "$id" "$ALT_PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane reaches the real worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  recorded=$(recorded_worktree "$id")
  [ -n "$recorded" ] || fail "no worktree= recorded in state/$id.meta"
  [ "$(dir_identity "$recorded")" != "$(dir_identity "$PROJ_DIR")" ] ||
    fail "meta recorded the PRIMARY CHECKOUT as the worktree ('$recorded'); the project reached under another spelling was mistaken for an isolated worktree"
  [ "$(dir_identity "$recorded")" = "$(dir_identity "$WT_DIR")" ] ||
    fail "meta recorded '$recorded', which is not the isolated worktree '$WT_DIR'"
  pass "the project reached under another spelling is not accepted as the worktree"
}

# The same comparison read the other way. The pane reports the real worktree
# under a non-canonical spelling while git reports its canonical top-level; that
# is one directory, so the isolation guard must accept it instead of refusing a
# spawn that never tangled anything.
test_worktree_under_another_spelling_is_still_accepted() {
  local id out status recorded
  id="path-case-worktree-c2"
  make_case_home worktree "$id"
  stage_pane_sequence "$PROJ_DIR" "$ALT_WT_DIR"

  out=$(run_case_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn should accept the real worktree reported under another spelling, got: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  recorded=$(recorded_worktree "$id")
  [ "$(dir_identity "$recorded")" = "$(dir_identity "$WT_DIR")" ] ||
    fail "meta recorded '$recorded', which is not the isolated worktree '$WT_DIR'"
  pass "the real worktree reported under another spelling is still accepted"
}

# The refusal itself must survive the fix. A path inside the project is not the
# top-level of any worktree, so the guard cannot prove isolation and must refuse
# loudly rather than launch - the same refusal, now decided on directory identity
# instead of string spelling.
test_guard_still_refuses_a_path_that_is_not_a_worktree_root() {
  local id out status
  id="path-case-refuse-c3"
  make_case_home refuse "$id"
  mkdir -p "$PROJ_DIR/nested"
  stage_pane_sequence "$PROJ_DIR" "$PROJ_DIR/nested"

  out=$(run_case_spawn "$id" "$ALT_PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse a path that is not a worktree root, got exit 0: $out"
  assert_contains "$out" "did not yield an isolated worktree" \
    "refusal did not name the isolation failure"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a refused spawn must not record task metadata"
  pass "the isolation guard still refuses a path it cannot prove is a worktree root"
}

test_project_under_another_spelling_is_not_recorded_as_the_worktree
test_worktree_under_another_spelling_is_still_accepted
test_guard_still_refuses_a_path_that_is_not_a_worktree_root

echo "# all fm-spawn-path-case tests passed"
