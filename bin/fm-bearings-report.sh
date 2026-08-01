#!/usr/bin/env bash
# Install a complete Bearings draft as today's dated report. If a same-day
# report exists, preserve its exact bytes at a unique create-exclusive path and
# write a digest-bound custody receipt before replacing it.
#
# Usage: fm-bearings-report.sh <complete-draft.md>
#
# FM_BEARINGS_REPORT_DATE may pin YYYY-MM-DD for deterministic tests. The draft
# remains untouched. The command prints the installed report path.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-custody-lib.sh
. "$SCRIPT_DIR/fm-custody-lib.sh"

fail() {
  printf 'fm-bearings-report: %s\n' "$*" >&2
  exit 1
}

[ "$#" -eq 1 ] || fail "usage: fm-bearings-report.sh <complete-draft.md>"
draft=$1
[ -f "$draft" ] && [ ! -L "$draft" ] || fail "draft must be a regular non-symlink file: $draft"
report_date=${FM_BEARINGS_REPORT_DATE:-$(date '+%Y-%m-%d')}
case "$report_date" in
  ????-??-??) ;;
  *) fail "report date must be YYYY-MM-DD: $report_date" ;;
esac
mkdir -p "$DATA"
target="$DATA/status-report-$report_date.md"
versions="$DATA/status-report-versions"
source_ref=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null || printf 'unversioned-firstmate-root')

if [ -e "$target" ]; then
  [ -f "$target" ] && [ ! -L "$target" ] || fail "existing report is not a regular non-symlink file: $target"
  fm_custody_preserve "$target" "$versions" "$source_ref" bearings-prior-snapshot >/dev/null \
    || fail "could not preserve the prior report before replacement"
fi

tmp="$DATA/.status-report-$report_date.${BASHPID:-$$}.tmp"
trap 'rm -f "$tmp"' EXIT INT TERM
(umask 077; cp "$draft" "$tmp") || fail "could not stage the complete report"
mv "$tmp" "$target" || fail "could not install the complete report"
trap - EXIT INT TERM
printf '%s\n' "$target"
