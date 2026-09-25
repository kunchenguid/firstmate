#!/usr/bin/env bash
# Git hook dispatcher for a firstmate task worktree. Every file in bin/git-hooks
# is a symlink to this script, and bin/fm-worktree-hooks-lib.sh points the task
# worktree's own core.hooksPath at that directory, so git runs it under the
# hook's name.
#
# commit-msg first refuses a message carrying AI self-attribution, using the
# same matcher as the Claude PreToolUse guard (bin/fm-attribution-pretool-check.sh
# --message-file), so the rule holds for a worker on any harness. Every hook,
# commit-msg included once the message passes, then runs the project's own hook
# of the same name with the same arguments, stdin, and exit status. The project's
# hooks are found where they would be without the worktree override: the
# core.hooksPath the project set in its shared, global, or system config
# (relative to the worktree top level), else the common git dir's hooks/.
set -u

HOOK=$(basename "$0")
BIN_DIR=$(cd "$(dirname "$0")/.." && pwd)

if [ "$HOOK" = commit-msg ]; then
  "$BIN_DIR/fm-attribution-pretool-check.sh" --message-file "${1-}" || exit 1
fi

project_hooks=
for scope in --local --global --system; do
  project_hooks=$(git config "$scope" --path --get core.hooksPath 2>/dev/null) && [ -n "$project_hooks" ] && break
  project_hooks=
done
if [ -z "$project_hooks" ]; then
  project_hooks="$(git rev-parse --git-common-dir 2>/dev/null)/hooks" || exit 0
fi
case "$project_hooks" in
  /*) ;;
  *) project_hooks="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/$project_hooks" ;;
esac

[ -f "$project_hooks/$HOOK" ] && [ -x "$project_hooks/$HOOK" ] || exit 0
exec "$project_hooks/$HOOK" "$@"
