#!/usr/bin/env bash
# fm-bearings-report-write.sh - create one collision-safe Bearings report.
#
# Input: complete report content on stdin.
# Output: the absolute path created, followed by a newline.
#
# The first report for a day uses status-report-<YYYY-MM-DD>.md.
# An existing report is never read, removed, truncated, or replaced.
# Later same-day reports use -<HHMMSS> and then the first available -N suffix.
set -eu

usage() {
  echo "usage: fm-bearings-report-write.sh < report.md" >&2
  exit 2
}

[ "$#" -eq 0 ] || usage

FM_HOME=${FM_HOME:?fm-bearings-report-write: FM_HOME is required}
REPORT_DAY=${FM_BEARINGS_REPORT_DATE:-$(date +%Y-%m-%d)}
REPORT_TIME=${FM_BEARINGS_REPORT_TIME:-$(date +%H%M%S)}
case "$REPORT_DAY" in ????-??-??) ;; *) echo "fm-bearings-report-write: invalid report date" >&2; exit 2 ;; esac
case "$REPORT_TIME" in ??????) ;; *) echo "fm-bearings-report-write: invalid report time" >&2; exit 2 ;; esac
case "$REPORT_TIME" in *[!0-9]*) echo "fm-bearings-report-write: invalid report time" >&2; exit 2 ;; esac

REPORT_DIR=$FM_HOME/data
[ -d "$REPORT_DIR" ] || { echo "fm-bearings-report-write: missing data directory: $REPORT_DIR" >&2; exit 1; }
REPORT_STEM=$REPORT_DIR/status-report-$REPORT_DAY

path_exists() {  # <path>
  [ -e "$1" ] || [ -L "$1" ]
}

write_exclusive() {  # <path>
  (set -C; cat > "$1") 2>/dev/null
}

candidate=$REPORT_STEM.md
if write_exclusive "$candidate"; then
  printf '%s\n' "$candidate"
  exit 0
fi
path_exists "$candidate" \
  || { echo "fm-bearings-report-write: could not create report: $candidate" >&2; exit 1; }

candidate=$REPORT_STEM-$REPORT_TIME.md
suffix=1
while :; do
  if write_exclusive "$candidate"; then
    printf '%s\n' "$candidate"
    exit 0
  fi
  path_exists "$candidate" \
    || { echo "fm-bearings-report-write: could not create report: $candidate" >&2; exit 1; }
  candidate=$REPORT_STEM-$REPORT_TIME-$suffix.md
  suffix=$((suffix + 1))
done
