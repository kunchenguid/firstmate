#!/usr/bin/env bash
# Review a crewmate branch against the authoritative base.
#
# Pooled project clones do not keep their local default branch current, so this
# helper compares remote-backed projects against origin/<default> after fetching
# the default branch, and local-only projects against the local default branch.
# Usage: fm-review-diff.sh <task-id> [--stat]
#   --stat prints only the stat summary; default prints stat summary plus full diff.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-cs-lib.sh
. "$SCRIPT_DIR/fm-cs-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true

usage() {
  echo "usage: fm-review-diff.sh <task-id> [--stat]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ID=${1:-}
[ -n "$ID" ] || { usage; exit 1; }
STAT_ONLY=false
case "${2:-}" in
  '') ;;
  --stat) STAT_ONLY=true ;;
  *) usage; exit 1 ;;
esac
[ $# -le 2 ] || { usage; exit 1; }

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

CODESPACE=$(grep '^codespace=' "$META" | cut -d= -f2- || true)
if [ -n "$CODESPACE" ]; then
  # Codespace crewmate: the branch lives in the codespace; diff over SSH against
  # the authoritative origin/<default> base, mirroring the local path.
  RDIR=$(grep '^repo_dir=' "$META" | cut -d= -f2- || true)
  [ -n "$RDIR" ] || { echo "error: meta for task $ID is missing repo_dir=" >&2; exit 1; }
  remote=$(cat <<EOF
set -e
cd '$RDIR'
DEFAULT=\$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
[ -n "\$DEFAULT" ] || { for b in main master; do git show-ref --verify --quiet "refs/heads/\$b" && DEFAULT=\$b && break; done; }
[ -n "\$DEFAULT" ] || { echo "error: cannot determine default branch" >&2; exit 1; }
BRANCH='fm/$ID'
git rev-parse --verify --quiet "refs/heads/\$BRANCH" >/dev/null || BRANCH=\$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ -n "\$BRANCH" ] || { echo "error: branch fm/$ID missing and HEAD detached" >&2; exit 1; }
git fetch origin "+refs/heads/\$DEFAULT:refs/remotes/origin/\$DEFAULT" --quiet 2>/dev/null || true
BASE="origin/\$DEFAULT"
git rev-parse --verify --quiet "\$BASE^{commit}" >/dev/null || BASE="\$DEFAULT"
echo "diff base: \$BASE"
if git diff --quiet "\$BASE...\$BRANCH" --; then echo "no changes vs \$BASE"; exit 0; fi
git diff --stat "\$BASE...\$BRANCH" --
if [ "$STAT_ONLY" != true ]; then echo; git diff "\$BASE...\$BRANCH" --; fi
EOF
)
  cs_ssh "$CODESPACE" -- "$remote"
  exit $?
fi

WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
[ -n "$WT" ] || { echo "error: meta for task $ID is missing worktree=" >&2; exit 1; }
[ -n "$PROJ" ] || { echo "error: meta for task $ID is missing project=" >&2; exit 1; }
[ -d "$WT" ] || { echo "error: worktree for task $ID is missing: $WT" >&2; exit 1; }
[ -d "$PROJ" ] || { echo "error: project for task $ID is missing: $PROJ" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

BRANCH="fm/$ID"
if ! git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$BRANCH" ] || { echo "error: branch fm/$ID does not exist and worktree $WT is detached" >&2; exit 1; }
  git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $WT" >&2; exit 1; }
fi

if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
  # Update the remote-tracking ref itself; a bare single-branch fetch can leave
  # origin/<default> stale on some Git versions and only refresh FETCH_HEAD.
  git -C "$WT" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet
  BASE="origin/$DEFAULT"
else
  BASE="$DEFAULT"
fi

git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { echo "error: base $BASE does not exist in $WT" >&2; exit 1; }
git -C "$WT" rev-parse --verify --quiet "$BRANCH^{commit}" >/dev/null || { echo "error: branch $BRANCH does not resolve in $WT" >&2; exit 1; }

echo "diff base: $BASE"
if git -C "$WT" diff --quiet "$BASE...$BRANCH" --; then
  echo "no changes vs $BASE"
  exit 0
fi

git -C "$WT" diff --stat "$BASE...$BRANCH" --
if ! "$STAT_ONLY"; then
  echo
  git -C "$WT" diff "$BASE...$BRANCH" --
fi
