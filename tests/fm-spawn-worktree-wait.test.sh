#!/usr/bin/env bash
# Behavior tests for fm-spawn's worktree-discovery poll after `treehouse get`.
#
# The pane's cwd does not move from the project to the worktree atomically:
# treehouse's setup hops through intermediate directories (the user's home, the
# firstmate home) before settling. The old poll accepted the FIRST cwd that
# differed from the project clone, so a sample landing mid-hop recorded a wrong
# worktree= in the task meta and installed the crew's turn-end hook into the
# wrong checkout. The fix accepts a candidate only once fm_isolated_worktree_root
# (bin/fm-tangle-lib.sh) proves it: physically AT a git worktree top, distinct
# from the project clone and from the firstmate home/root.
#
# These tests pin the predicate against every observed mis-sample shape, then
# replay the observed hop sequence (project -> home dir -> firstmate home ->
# real worktree) through the poll's accept logic and assert it settles only on
# the last. Structural checks pin fm-spawn's poll to the predicate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tangle-lib.sh
. "$ROOT/bin/fm-tangle-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-wait)
fm_git_identity fmtest fmtest@example.invalid

# --- fixtures: the directory shapes the pane cwd can land in -----------------

# The project clone: a normal git repo on main with one commit.
PROJ="$TMP_ROOT/projects/someproj"
mkdir -p "$(dirname "$PROJ")"
git init -q -b main "$PROJ"
git -C "$PROJ" commit -q --allow-empty -m init

# The firstmate home: a DIFFERENT valid git repo root (the 2026-07-04 recurrence:
# a mis-sample can be another valid repo root, so not-the-project is not enough).
FM_HOME_DIR="$TMP_ROOT/fm-home"
git init -q -b main "$FM_HOME_DIR"
git -C "$FM_HOME_DIR" commit -q --allow-empty -m init

# A bare non-repo directory (the user's home mid-hop).
HOME_DIR="$TMP_ROOT/userhome"
mkdir -p "$HOME_DIR"

# A real linked worktree of the project: a genuine isolated worktree top.
WORKTREE="$TMP_ROOT/pool/someproj-wt"
mkdir -p "$(dirname "$WORKTREE")"
git -C "$PROJ" worktree add -q --detach "$WORKTREE"
mkdir -p "$WORKTREE/subdir"

# A symlink to the project clone: physical resolution must still reject it.
PROJ_LINK="$TMP_ROOT/proj-link"
ln -s "$PROJ" "$PROJ_LINK"

PROJ_REAL=$(cd "$PROJ" && pwd -P)
FM_HOME_REAL=$(cd "$FM_HOME_DIR" && pwd -P)
WORKTREE_REAL=$(cd "$WORKTREE" && pwd -P)

# --- the predicate: accept only a genuine isolated worktree root --------------

test_predicate_cases() {
  local label cand expect out status
  while IFS='|' read -r label cand expect; do
    [ -n "$label" ] || continue
    out=$(fm_isolated_worktree_root "$cand" "$PROJ_REAL" "$FM_HOME_REAL") && status=0 || status=$?
    if [ "$expect" = accept ]; then
      [ "$status" -eq 0 ] || fail "$label: expected accept, got reject"
      [ "$out" = "$WORKTREE_REAL" ] || fail "$label: echoed '$out', want '$WORKTREE_REAL'"
    else
      [ "$status" -ne 0 ] || fail "$label: expected reject, got accept ('$out')"
    fi
  done <<ROWS
bare non-repo dir (user home mid-hop) is rejected|$HOME_DIR|reject
nonexistent path is rejected|$TMP_ROOT/does-not-exist|reject
the project clone itself is rejected|$PROJ|reject
a symlink to the project clone is rejected (physical path check)|$PROJ_LINK|reject
the firstmate home is rejected even though it is a valid repo root|$FM_HOME_DIR|reject
a subdir INSIDE a worktree is rejected (must sit AT the top)|$WORKTREE/subdir|reject
a real isolated worktree top is accepted|$WORKTREE|accept
ROWS
  pass "fm_isolated_worktree_root accepts only a genuine isolated worktree top"
}

# --- the race: replay the observed hop sequence through the poll's logic ------

test_poll_settles_only_on_the_worktree() {
  # The exact accept condition fm-spawn's poll uses, over the observed hop
  # sequence. The old `!= project` condition would have settled on the FIRST
  # hop (the user's home); the fix must skip every intermediate and settle on
  # the real worktree.
  local WT='' p
  for p in "$PROJ" "$HOME_DIR" "$FM_HOME_DIR" "$WORKTREE"; do
    if [ -n "$p" ] && fm_isolated_worktree_root "$p" "$PROJ_REAL" "$FM_HOME_REAL" >/dev/null; then
      WT="$p"
      break
    fi
  done
  [ "$WT" = "$WORKTREE" ] || fail "poll settled on '$WT', want '$WORKTREE'"
  pass "poll logic skips project/home-dir/firstmate-home hops and settles on the worktree"
}

# --- structural: fm-spawn's poll is wired to the predicate --------------------

test_spawn_uses_predicate() {
  # shellcheck disable=SC2016  # literal source string
  grep -F '. "$SCRIPT_DIR/fm-tangle-lib.sh"' "$SPAWN" >/dev/null \
    || fail "fm-spawn does not source fm-tangle-lib.sh"
  # shellcheck disable=SC2016  # literal source string
  grep -F 'fm_isolated_worktree_root "$p"' "$SPAWN" >/dev/null \
    || fail "fm-spawn's poll does not validate candidates with fm_isolated_worktree_root"
  # The racy first-cwd-that-differs acceptance must be gone (both the original
  # raw-string form and the later physically-canonicalized form of it).
  # shellcheck disable=SC2016  # literal source strings
  if grep -F '[ "$p" != "$PROJ_ABS" ]' "$SPAWN" >/dev/null \
    || grep -F '!= "$PROJ_ABS_REAL" ]' "$SPAWN" >/dev/null; then
    fail "fm-spawn still accepts the first cwd that merely differs from the project"
  fi
  pass "fm-spawn's worktree poll validates each sample with fm_isolated_worktree_root"
}

test_predicate_cases
test_poll_settles_only_on_the_worktree
test_spawn_uses_predicate
