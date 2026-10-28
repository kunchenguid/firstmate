#!/usr/bin/env bash
# fm-role.sh - report and check this home's firstmate role.
#
# Usage:
#   bin/fm-role.sh report
#   bin/fm-role.sh check <project-dir> [upstream-consent <scope>]
#
#   report   prints one line: fm-role: <user|maintainer> [<scope>] (<source>)
#            and, when a malformed or unverified input forced a closed result,
#            " - <narrow reason>". The default with no config is plain
#            "fm-role: user (default)". bin/fm-session-start.sh emits this line in the
#            startup digest; it makes no network or gh call.
#
#   check    evaluates the self-repository publication gate for a task whose
#            project is <project-dir>: exits 0 and prints
#            "authorized: <authority>" when this home may run a publication
#            contract there, exits 1 and prints "refused: <reason>" when it may
#            not, and exits 2 with "not a self-repository task" when the task
#            project is not firstmate's own repository (the boundary does not
#            apply). The optional `upstream-consent <scope>` argument is the
#            recorded per-task consent a dispatcher captured.
#
# bin/fm-role-lib.sh owns the schema summary and mechanics;
# docs/configuration.md "Firstmate role" owns the operator-facing schema.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-role-lib.sh
. "$SCRIPT_DIR/fm-role-lib.sh"

case ${1:-} in
report)
  fm_role_resolve "$FM_HOME" "$CONFIG"
  line="fm-role: $FM_ROLE"
  [ -z "$FM_ROLE_SCOPE" ] || line="$line $FM_ROLE_SCOPE"
  case $FM_ROLE_SOURCE in
  local) line="$line (local)" ;;
  inherited) line="$line (inherited)" ;;
  absent)
    if [ -z "$FM_ROLE_DIAG" ]; then
      line="$line (default)"
    fi
    ;;
  esac
  [ -z "$FM_ROLE_DIAG" ] || line="$line - $FM_ROLE_DIAG"
  printf '%s\n' "$line"
  ;;
check)
  proj=${2:-}
  [ -n "$proj" ] || {
    echo "usage: bin/fm-role.sh check <project-dir> [upstream-consent <scope>]" >&2
    exit 1
  }
  consent=
  if [ "${3:-}" = upstream-consent ]; then
    consent=${4:-}
  fi
  if fm_role_gate_self_publish "$FM_HOME" "$CONFIG" "$proj" "$FM_ROOT" "$consent"; then
    printf 'authorized: %s\n' "$FM_ROLE_PUB_AUTHORITY"
    exit 0
  else
    rc=$?
  fi
  if [ "$rc" -eq 2 ]; then
    printf 'not a self-repository task\n'
    exit 2
  fi
  printf 'refused: %s\n' "$FM_ROLE_PUB_DENIAL"
  exit 1
  ;;
-h | --help | help)
  sed -n '3,25p' "$0"
  ;;
*)
  sed -n '3,25p' "$0" >&2
  exit 1
  ;;
esac
