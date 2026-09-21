#!/usr/bin/env bash
# Read-only capability gate shared by Codex supervision's renderer, model,
# Stop guard and async owner. Exit 0 only for stable Codex CLI >=0.154.0 with
# hooks enabled and the verified queue --thread/--message transport available.
# Unknown versions, prereleases, disabled/missing features and failed probes
# retain foreground checkpoints. Each vendor probe is bounded to three seconds.
# Probes reflect the executable/config visible to this process; restart Codex
# after changing its binary or hook configuration.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
command -v codex >/dev/null 2>&1 || exit 1
version=$(fm_run_timed 3 codex --version 2>/dev/null) || exit 1
if [[ "$version" =~ ^codex-cli[[:space:]]+([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  major=${BASH_REMATCH[1]}
  minor=${BASH_REMATCH[2]}
else
  exit 1
fi
# Compare decimal text without overflow or octal interpretation.
major=$(printf '%s' "$major" | sed 's/^0*//')
minor=$(printf '%s' "$minor" | sed 's/^0*//')
if [ -z "$major" ]; then
  [ "${#minor}" -gt 3 ] || { [ "${#minor}" -eq 3 ] && [ "$minor" -ge 154 ]; } || exit 1
fi
features=$(fm_run_timed 3 codex features list 2>/dev/null) || exit 1
printf '%s\n' "$features" | awk '$1 == "hooks" && $NF == "true" { found=1 } END { exit !found }' || exit 1
help=$(fm_run_timed 3 codex queue --help 2>/dev/null) || exit 1
# Old CLIs can print generic help with a successful exit for unknown commands.
[[ "$help" == *'Usage: codex queue '* && "$help" == *'--thread'* && "$help" == *'--message'* ]]
