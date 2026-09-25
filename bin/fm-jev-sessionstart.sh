#!/usr/bin/env bash
set -euo pipefail

root=${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd -P)}
winnow_project="$root/.claude/upstreams/winnow/sidecar"
if [[ ! -f $winnow_project/pyproject.toml ]]; then
  printf 'Winnow sidecar is missing: %s\nInitialize its pinned submodule with: git submodule update --init .claude/upstreams/winnow\n' "$winnow_project" >&2
  exit 1
fi
export WINNOW_HOME=${WINNOW_HOME:-$root/.claude/jev-safety/winnow-home}
export WINNOW_JUDGE=typesafe
if [[ -z ${TYPESAFE_API_KEY:-} ]]; then
  source "$root/bin/fm-env-lib.sh"
  key=$(fmx_env_get TYPESAFE_API_KEY "${FM_HOME:-$root}/.env")
  if [[ -n $key ]]; then export TYPESAFE_API_KEY=$key; fi
fi

uv run -q --project "$root/.claude/jev-safety" python -c 'import detect_secrets'
uv run -q --project "$winnow_project" python -m winnow serve --ensure
