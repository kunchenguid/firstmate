#!/usr/bin/env bash
# fm-base-state.sh - what is this task's declared base RIGHT NOW?
#
# The CREWMATE's accessor onto bin/fm-base-lib.sh. A based brief is scaffolded once and
# reused verbatim on every relaunch, while the base underneath it moves: it can merge
# mid-flight (the normal end-state of a stacked PR), and its branch may or may not be
# deleted afterwards. So the brief does not hard-code a base story - it has the crewmate
# ask this, before it touches a branch and again before it targets a PR at the base.
#
# IT ASKS THE SAME QUESTION EVERY OTHER CONSUMER ASKS, of the same owner: has the base's
# work LANDED in the default branch (bin/fm-base-lib.sh's fm_base_resolve_state)? Never
# whether the branch still exists, which answers nothing in either direction, and never
# what a fetch's exit status was, which cannot tell a branch that is gone from an origin
# that could not be reached.
#
# Usage: fm-base-state.sh <path to state/<task-id>.meta>
#
# Prints key=value lines on stdout:
#   state=live       the base still carries unmerged work: the based task is on
#   state=landed     its work is in the default branch already (branch kept OR deleted):
#                    there is nothing left to stack on, so the task is an ordinary
#                    default-branch task now
#   state=abandoned  the branch is gone from origin and its work never landed
#   state=unknown    it could not be settled (origin unreachable, no usable recorded tip,
#                    or a landedness that cannot be proved either way): do not guess
#   state=none       the task declares no base at all
#   base=<branch>    the declared base (absent for state=none)
#   tip=<sha>        the commit the state was decided from: the base's live tip while it
#                    is on origin, else the tip recorded at spawn. This is the commit a
#                    branch stacked on the base must be rebased OFF of once it lands
#   default=<branch> the repo's default branch
#   why=<reason>     how it was decided (ancestor|contained|squashed|replayed|diverged|...)
#
# git's own error, when there is one, goes to stderr.
#
# Exit 0 whenever a state line was printed - INCLUDING abandoned and unknown, which are
# answers, not failures. Exit 1 only when the question cannot be asked at all (no meta, no
# worktree, no default branch), because a caller that cannot even ask must not proceed as
# though the answer were reassuring.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-base-lib.sh
. "$SCRIPT_DIR/fm-base-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"

usage() {
  echo "usage: fm-base-state.sh <path to state/<task-id>.meta>" >&2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

META=${1:-}
[ -n "$META" ] || { usage; exit 1; }
[ -f "$META" ] || { echo "error: no task meta at $META" >&2; exit 1; }

meta_value() {  # <key>
  grep "^$1=" "$META" | tail -1 | cut -d= -f2- || true
}

BASE=$(meta_value base)
BASE_SHA=$(meta_value base_sha)
WT=$(meta_value worktree)

if [ -z "$BASE" ]; then
  echo "state=none"
  exit 0
fi

# meta is a plain text file a human can edit, and both values reach git as a refspec or a
# rev, where a leading dash would be read as an option. Same rule the other consumers
# re-assert on the way out of meta.
fm_base_valid_branch_name "$BASE" || {
  echo "error: task meta $META records base='$BASE', which is not a valid git branch name" >&2
  exit 1
}
if [ -n "$BASE_SHA" ] && ! fm_base_valid_commit_id "$BASE_SHA"; then
  echo "error: task meta $META records base_sha='$BASE_SHA', which is not a git object id" >&2
  exit 1
fi

[ -n "$WT" ] || { echo "error: task meta $META is missing worktree=" >&2; exit 1; }
[ -d "$WT" ] || { echo "error: worktree $WT does not exist" >&2; exit 1; }
git -C "$WT" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "error: $WT is not a git worktree" >&2
  exit 1
}

DEFAULT=$(fm_default_branch "$WT") || {
  echo "error: cannot resolve the default branch of $WT (expected origin/HEAD, main, or master)" >&2
  exit 1
}

STATE_RC=0
fm_base_resolve_state "$WT" "$BASE" "$BASE_SHA" "$DEFAULT" || STATE_RC=$?
case "$STATE_RC" in
  "$FM_BASE_STATE_LIVE") STATE=live ;;
  "$FM_BASE_STATE_LANDED") STATE=landed ;;
  "$FM_BASE_STATE_ABANDONED") STATE=abandoned ;;
  *) STATE=unknown ;;
esac

[ -z "$FM_BASE_STATE_ERR" ] || printf 'git: %s\n' "$FM_BASE_STATE_ERR" >&2

echo "state=$STATE"
echo "base=$BASE"
echo "tip=$FM_BASE_STATE_TIP"
echo "default=$DEFAULT"
echo "why=$FM_BASE_STATE_WHY"
