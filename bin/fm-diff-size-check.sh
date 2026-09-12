#!/usr/bin/env bash
# Worker-facing lane size check. Usage: fm-diff-size-check.sh <worktree>
# Prints "<changed lines> changed lines across <n> files: <verdict>".
# Exit 0 always: a worker's own measurement must never end its turn.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-diff-size-lib.sh
. "$SCRIPT_DIR/fm-diff-size-lib.sh"

WT=$(cd "${1:-.}" && pwd)
BASE=$(git -C "$WT" rev-parse --verify --quiet origin/HEAD 2>/dev/null) \
    || BASE=$(git -C "$WT" rev-parse --verify --quiet main 2>/dev/null) \
    || BASE=$(git -C "$WT" rev-parse --verify --quiet HEAD 2>/dev/null)
read -r LINES FILES <<< "$(fm_diff_size "$WT" "$BASE")"
printf '%s changed lines across %s files: %s\n' \
    "$LINES" "$FILES" "$(fm_diff_size_verdict "$LINES")"
exit 0
