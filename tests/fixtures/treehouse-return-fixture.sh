#!/usr/bin/env bash
# Exact-target Treehouse return fixture for the real Herdr auto-reap regression.
set -euo pipefail

[ "$#" -eq 3 ] && [ "$1" = return ] && [ "$2" = --force ] && [ "$3" = . ] || {
  echo "fixture refused unexpected Treehouse command: $*" >&2
  exit 91
}

target=$(pwd -P)
project=${FM_TREEHOUSE_RETURN_PROJECT:?}
[ "$target" = "${FM_AUTO_REAP_E2E_WORKTREE:?}" ] || {
  echo "fixture refused unexpected Treehouse worktree: $target" >&2
  exit 92
}
[ "$project" = "${FM_AUTO_REAP_E2E_PROJECT:?}" ] || {
  echo "fixture refused unexpected Treehouse project: $project" >&2
  exit 93
}

python3 - "${FM_AUTO_REAP_E2E_TREEHOUSE_STATE:?}" "$target" <<'PY'
import json
import os
import sys

state_path, target = sys.argv[1:]
with open(state_path, encoding="utf-8") as stream:
    state = json.load(stream)

matches = [
    entry
    for entry in state.get("worktrees", [])
    if os.path.realpath(entry.get("path", "")) == target
]
if len(matches) != 1 or matches[0].get("leased") is not True:
    raise SystemExit("fixture could not prove one live Treehouse lease")
matches[0]["leased"] = False
matches[0]["lease_holder"] = None

with open(state_path, "w", encoding="utf-8") as stream:
    json.dump(state, stream)
PY

git -C "$project" worktree remove --force "$target"
printf 'returned %s\n' "$target" >> "${FM_AUTO_REAP_E2E_TREEHOUSE_LOG:?}"
