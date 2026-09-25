#!/usr/bin/env bash
set -euo pipefail

root=${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd -P)}
uv run -q --project "$root/.claude/jev-safety" python "$root/.claude/jev-safety/server.py" --ensure

if [[ -z ${TYPESAFE_API_KEY:-} ]]; then
  # The project's standard one-key .env reader does not log credential values.
  source "$root/bin/fm-env-lib.sh"
  env_home=${FM_HOME:-$root}
  key=$(fmx_env_get TYPESAFE_API_KEY "$env_home/.env")
  if [[ -n $key ]]; then export TYPESAFE_API_KEY=$key; fi
fi

export JEV_PROVIDER=typesafe
exec node --import "$root/.claude/jev-safety/preload.mjs" \
  "$root/.claude/upstreams/jev-mcp/dist/index.js"
