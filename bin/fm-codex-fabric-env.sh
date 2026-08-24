#!/usr/bin/env bash
# Acquire one fresh Microsoft Fabric API token from the existing Azure CLI
# session, expose it under the two environment names consumed by Codex's global
# Fabric Core and Fabric Warehouse MCP definitions, then replace this process
# with the requested Codex command.
# Usage: fm-codex-fabric-env.sh <codex-command> [args...]
#
# The token is captured from stdout into shell memory and reaches only the
# exec'd worker environment and its children.
# It is never printed, persisted, placed in a process argument, or exported into
# the long-lived backend or pane-shell environment.
# If Azure CLI is absent or cannot answer from its existing non-interactive
# session, the command runs with the caller's environment unchanged.
{ set +x; } 2>/dev/null
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

if [ "$#" -eq 0 ]; then
  echo "usage: fm-codex-fabric-env.sh <codex-command> [args...]" >&2
  exit 2
fi
case "${1##*/}" in
  codex) ;;
  *)
    echo "error: fm-codex-fabric-env.sh launches codex only" >&2
    exit 2
    ;;
esac

launch_with_fabric_token() {
  local fabric_access_token_fresh=
  export -n fabric_access_token_fresh
  fabric_access_token_fresh=$(fm_run_timed 10 az account get-access-token \
    --resource https://api.fabric.microsoft.com \
    --query accessToken \
    --output tsv \
    --only-show-errors 2>/dev/null) || return 1
  [ -n "$fabric_access_token_fresh" ] || return 1

  export FABRIC_CORE_BEARER_TOKEN=$fabric_access_token_fresh
  export FABRIC_DW_GLOBAL_BEARER_TOKEN=$fabric_access_token_fresh
  unset fabric_access_token_fresh
  exec "$@"
}

if command -v az >/dev/null 2>&1; then
  launch_with_fabric_token "$@"
fi

exec "$@"
