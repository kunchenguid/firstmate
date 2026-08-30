#!/usr/bin/env bash
# fm-supervision-oracle.sh - deterministic correctness oracle for synthetic homes.
#
# Usage:
#   fm-supervision-oracle.sh check [--home <path>]
#   fm-supervision-oracle.sh snapshot [--home <path>]
#   fm-supervision-oracle.sh init-synthetic [--home <path>]
#   fm-supervision-oracle.sh -h | --help
#
# The oracle refuses every live-fleet path and requires .fm-synthetic-home.
# Exit 0 when all invariants hold; exit 1 when any invariant is violated; exit 2 on usage or safety refusal.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOME_ARG=
CMD=

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      shift
      HOME_ARG=${1:-}
      [ -n "$HOME_ARG" ] || { usage >&2; exit 2; }
      shift
      ;;
    check|snapshot|init-synthetic)
      [ -z "$CMD" ] || { usage >&2; exit 2; }
      CMD=$1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

[ -n "$CMD" ] || { usage >&2; exit 2; }

FM_ORACLE_HOME=${HOME_ARG:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$SCRIPT_DIR/..}}}
FM_ORACLE_STATE="$FM_ORACLE_HOME/state"
FM_ORACLE_SNAPSHOT="$FM_ORACLE_STATE/.supervision-oracle-snapshot.tsv"
FM_ORACLE_LIVENESS="$FM_ORACLE_STATE/.supervision-oracle-liveness.tsv"
FM_ORACLE_ENDPOINTS="$FM_ORACLE_STATE/.supervision-oracle-endpoints.tsv"

# shellcheck source=bin/fm-supervision-oracle-lib.sh
. "$SCRIPT_DIR/fm-supervision-oracle-lib.sh"

case "$CMD" in
  init-synthetic)
    FM_ORACLE_HOME=$(fm_oracle_realpath "$FM_ORACLE_HOME") \
      || { fm_oracle_die "home is not reachable: $FM_ORACLE_HOME"; exit 2; }
    case "$FM_ORACLE_HOME" in
      /Users/pedromuller/dev/firstmate/state|/Users/pedromuller/dev/firstmate/state/*|\
      /Users/pedromuller/.treehouse|/Users/pedromuller/.treehouse/*)
        fm_oracle_die "refusing live fleet path: $FM_ORACLE_HOME"
        exit 2
        ;;
    esac
    mkdir -p "$FM_ORACLE_HOME/state"
    printf 'synthetic stress-test home\n' > "$FM_ORACLE_HOME/.fm-synthetic-home"
    exit 0
    ;;
esac

FM_ORACLE_HOME=$(fm_oracle_assert_synthetic_home "$FM_ORACLE_HOME") || exit 2
FM_ORACLE_STATE="$FM_ORACLE_HOME/state"
FM_ORACLE_SNAPSHOT="$FM_ORACLE_STATE/.supervision-oracle-snapshot.tsv"
FM_ORACLE_LIVENESS="$FM_ORACLE_STATE/.supervision-oracle-liveness.tsv"
FM_ORACLE_ENDPOINTS="$FM_ORACLE_STATE/.supervision-oracle-endpoints.tsv"
mkdir -p "$FM_ORACLE_STATE"

case "$CMD" in
  snapshot)
    fm_oracle_snapshot_write
    exit 0
    ;;
  check)
    if fm_oracle_check_all; then
      exit 0
    fi
    exit 1
    ;;
esac

usage >&2
exit 2
