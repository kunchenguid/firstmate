#!/usr/bin/env bash
# gh-axi wrapper for crewmate briefs: refuses fixed shared --body-file paths.
# All other arguments pass through to gh-axi unchanged.
set -euo pipefail
d=${BASH_SOURCE[0]%/*}
[ "$d" != "${BASH_SOURCE[0]}" ] || d=.
# shellcheck source=bin/fm-forge-lib.sh
. "$(cd "${d:-/}" && pwd)/fm-forge-lib.sh"
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --body-file)
      shift
      [ $# -gt 0 ] || { echo "error: fm-gh-axi: --body-file requires a path" >&2; exit 2; }
      fm_forge_body_file_refuse "$1" || exit 1
      args+=(--body-file "$1")
      shift
      ;;
    --body-file=*)
      fm_forge_body_file_refuse "${1#--body-file=}" || exit 1
      args+=("$1")
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
exec gh-axi "${args[@]}"
