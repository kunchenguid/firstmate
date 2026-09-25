#!/usr/bin/env bash
set -euo pipefail

root=${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd -P)}
export WINNOW_HOME=${WINNOW_HOME:-$root/.claude/jev-safety/winnow-home}
export WINNOW_JUDGE=typesafe
if [[ -z ${TYPESAFE_API_KEY:-} ]]; then
  source "$root/bin/fm-env-lib.sh"
  key=$(fmx_env_get TYPESAFE_API_KEY "${FM_HOME:-$root}/.env")
  if [[ -n $key ]]; then export TYPESAFE_API_KEY=$key; fi
fi

uv run -q --project "$root/.claude/jev-safety" \
  python "$root/.claude/jev-safety/server.py" --ensure
uv run -q --project "$root/.claude/upstreams/winnow/sidecar" \
  python -m winnow serve --ensure
