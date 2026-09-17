#!/usr/bin/env bash
# Project discovery and resolution for this home (bin/fm-projects-lib.sh owns
# the contract; docs/configuration.md "Projects root and project resolution"
# owns the schema).
#
# Usage:
#   fm-projects.sh root                 print the effective projects root
#   fm-projects.sh org                  exit 0 when config/projects-root selects
#                                       the projects root, 1 otherwise
#   fm-projects.sh discover             list discoverable sibling repo names
#                                       under the projects root (never a
#                                       mutation list: discovery is not
#                                       authority)
#   fm-projects.sh aliases              list every registered project alias
#                                       (data/projects.md plus
#                                       data/project-paths.json keys)
#   fm-projects.sh resolve <arg>        resolve a project argument to a path
#   fm-projects.sh name <arg> <path>    print the stable project name for a
#                                       spawn argument and its resolved path
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-projects-lib.sh
. "$SCRIPT_DIR/fm-projects-lib.sh"

usage() {
  echo "usage: fm-projects.sh root|org|discover|aliases|resolve <arg>|name <arg> <path>" >&2
}

case "${1:-}" in
  root)
    [ $# -eq 1 ] || { usage; exit 1; }
    fm_projects_root "$FM_HOME" "$CONFIG"
    ;;
  org)
    [ $# -eq 1 ] || { usage; exit 1; }
    fm_projects_root_is_custom "$CONFIG"
    ;;
  discover)
    [ $# -eq 1 ] || { usage; exit 1; }
    fm_project_discover "$(fm_projects_root "$FM_HOME" "$CONFIG")"
    ;;
  aliases)
    [ $# -eq 1 ] || { usage; exit 1; }
    fm_project_registered_aliases "$DATA"
    ;;
  resolve)
    [ $# -eq 2 ] || { usage; exit 1; }
    fm_project_resolve "$FM_HOME" "$CONFIG" "$DATA" "$2"
    ;;
  name)
    [ $# -eq 3 ] || { usage; exit 1; }
    fm_project_name_for "$FM_HOME" "$CONFIG" "$DATA" "$2" "$3"
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 1
    ;;
esac
