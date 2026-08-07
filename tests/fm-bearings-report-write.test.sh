#!/usr/bin/env bash
# Behavior tests for explicit /bearings file report writes.
# The firing input is an existing same-day report.
# The writer must preserve it and create a distinct report path.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRITER=${FM_BEARINGS_REPORT_WRITER:-$ROOT/bin/fm-bearings-report-write.sh}
TMP_ROOT=$(fm_test_tmproot fm-bearings-report-write)

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

write_report() {  # <home> <content>
  local home=$1 content=$2
  printf '%s\n' "$content" | FM_HOME="$home" \
    FM_BEARINGS_REPORT_DATE=2026-08-06 \
    FM_BEARINGS_REPORT_TIME=101112 \
    "$WRITER"
}

test_existing_same_day_report_is_preserved() {
  local home original first second
  [ -x "$WRITER" ] || fail "Bearings file mode has no executable create-exclusive report writer"
  home=$(make_home preserve)
  original=$home/data/status-report-2026-08-06.md
  printf '%s\n' 'immutable same-day report' > "$original"

  first=$(write_report "$home" 'fresh report one') \
    || fail "Bearings file mode refused a new report beside an existing same-day report"
  [ "$first" != "$original" ] \
    || fail "same-day original was replaced instead of preserved"
  [ "$(cat "$original")" = 'immutable same-day report' ] \
    || fail "same-day original was replaced instead of preserved"
  [ "$first" = "$home/data/status-report-2026-08-06-101112.md" ] \
    || fail "first collision-safe report path was not timestamped: $first"
  [ "$(cat "$first")" = 'fresh report one' ] \
    || fail "first collision-safe report was not written"

  second=$(write_report "$home" 'fresh report two') \
    || fail "Bearings file mode refused a second same-second report"
  [ "$second" = "$home/data/status-report-2026-08-06-101112-1.md" ] \
    || fail "second collision-safe report path did not receive a suffix: $second"
  [ "$(cat "$first")" = 'fresh report one' ] \
    || fail "first collision-safe report was replaced by a later same-second report"
  [ "$(cat "$second")" = 'fresh report two' ] \
    || fail "second collision-safe report was not written"
  pass "/bearings file preserves same-day reports and creates collision-safe successors"
}

test_existing_same_day_report_is_preserved
