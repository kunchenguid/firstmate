#!/usr/bin/env bash
# Resume one stopped ordinary TraeX worker in its exact recorded Herdr pane.
# Usage: fm-traex-resume.sh <task-id> <recorded-session-id>
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

[ "$#" -eq 2 ] || {
  echo "usage: fm-traex-resume.sh <task-id> <recorded-session-id>" >&2
  exit 1
}
if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; TraeX resume refuses to resolve task ownership" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || {
  echo "error: state dir '$STATE' is missing; TraeX resume cannot resolve task ownership" >&2
  exit 1
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source herdr
fm_backend_herdr_traex_resume "$STATE" "$1" "$2"
