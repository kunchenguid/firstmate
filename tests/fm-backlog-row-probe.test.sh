#!/usr/bin/env bash
# tests/fm-backlog-row-probe.test.sh - fm_backlog_row_probe's output-global
# contract (bin/fm-backlog-transition-lib.sh): RESULT, STATE, TITLE, and ERROR
# describe THIS probe on every return path. A probe that fails before it can
# read the row must clear a prior successful probe's outputs, so a caller
# holding the globals can never act on a stale title from an unrelated row.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found (fm_backlog_row_probe reads rows through it)"; exit 0; }

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$ROOT/bin/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$ROOT/bin/fm-backlog-transition-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backlog-row-probe)
mkdir -p "$TMP_ROOT/data"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$TMP_ROOT/data/backlog.md"
tasks-axi add t1 "Paint the fence" --file="$TMP_ROOT/data/backlog.md" >/dev/null \
  || fail "fixture: could not seed the backlog row"

if ! fm_backlog_row_probe "$TMP_ROOT/data" t1; then
  fail "a probe of an existing row should succeed: $FM_BACKLOG_ROW_ERROR"
fi
[ "$FM_BACKLOG_ROW_RESULT" = found ] \
  || fail "a probe of an existing row should report found, got '$FM_BACKLOG_ROW_RESULT'"
[ "$FM_BACKLOG_ROW_TITLE" = "Paint the fence" ] \
  || fail "a found row should report its title, got '$FM_BACKLOG_ROW_TITLE'"
pass "fm_backlog_row_probe: a found row reports its title"

# tasks-axi show serializes a title containing ':' or '"' in its quoted,
# backslash-escaped form; the probe must hand callers the title itself.
tasks-axi add t2 "fix: label workers" --file="$TMP_ROOT/data/backlog.md" >/dev/null \
  || fail "fixture: could not seed the colon-bearing row"
if ! fm_backlog_row_probe "$TMP_ROOT/data" t2; then
  fail "a probe of a colon-bearing row should succeed: $FM_BACKLOG_ROW_ERROR"
fi
[ "$FM_BACKLOG_ROW_TITLE" = "fix: label workers" ] \
  || fail "a colon-bearing title should report itself unquoted, got '$FM_BACKLOG_ROW_TITLE'"
pass "fm_backlog_row_probe: a colon-bearing title is reported unquoted"

tasks-axi add t3 'say: "hi" \back' --file="$TMP_ROOT/data/backlog.md" >/dev/null \
  || fail "fixture: could not seed the quote-bearing row"
if ! fm_backlog_row_probe "$TMP_ROOT/data" t3; then
  fail "a probe of a quote-bearing row should succeed: $FM_BACKLOG_ROW_ERROR"
fi
[ "$FM_BACKLOG_ROW_TITLE" = 'say: "hi" \back' ] \
  || fail "a quote-bearing title should report itself unescaped, got '$FM_BACKLOG_ROW_TITLE'"
pass "fm_backlog_row_probe: a quote-bearing title is reported unescaped"

# The default show render truncates titles past ~84 characters and annotates
# the truncation; the probe must still report the complete title, because that
# title names the tab.
long_title="Refactor the duplicate-refusal path so the message carries the matched tab's own label rather than the label being created"
tasks-axi add t4 "$long_title" --file="$TMP_ROOT/data/backlog.md" >/dev/null \
  || fail "fixture: could not seed the long-title row"
if ! fm_backlog_row_probe "$TMP_ROOT/data" t4; then
  fail "a probe of a long-title row should succeed: $FM_BACKLOG_ROW_ERROR"
fi
[ "$FM_BACKLOG_ROW_TITLE" = "$long_title" ] \
  || fail "a long title should be reported complete, got '$FM_BACKLOG_ROW_TITLE'"
pass "fm_backlog_row_probe: a long title is reported complete, never truncated"

# The serializer escapes control characters; the probe must decode them, and a
# literal backslash-t must stay two characters rather than become a tab.
tasks-axi add t5 $'has\ttab' --file="$TMP_ROOT/data/backlog.md" >/dev/null \
  || fail "fixture: could not seed the tab-bearing row"
if ! fm_backlog_row_probe "$TMP_ROOT/data" t5; then
  fail "a probe of a tab-bearing row should succeed: $FM_BACKLOG_ROW_ERROR"
fi
[ "$FM_BACKLOG_ROW_TITLE" = $'has\ttab' ] \
  || fail "a tab-bearing title should decode to a real tab, got '$FM_BACKLOG_ROW_TITLE'"
pass "fm_backlog_row_probe: a tab-bearing title is decoded to a real tab"

tasks-axi add t6 'tab\tsep' --file="$TMP_ROOT/data/backlog.md" >/dev/null \
  || fail "fixture: could not seed the backslash-t row"
if ! fm_backlog_row_probe "$TMP_ROOT/data" t6; then
  fail "a probe of a backslash-t row should succeed: $FM_BACKLOG_ROW_ERROR"
fi
[ "$FM_BACKLOG_ROW_TITLE" = 'tab\tsep' ] \
  || fail "a literal backslash-t title should stay literal, got '$FM_BACKLOG_ROW_TITLE'"
pass "fm_backlog_row_probe: a literal backslash-t title is not turned into a tab"

if fm_backlog_row_probe "$TMP_ROOT/no-such-data" t1; then
  fail "a probe against an unresolvable data directory should fail"
fi
[ "$FM_BACKLOG_ROW_RESULT" = error ] \
  || fail "an unresolvable data directory should report error, got '$FM_BACKLOG_ROW_RESULT'"
[ -z "$FM_BACKLOG_ROW_STATE" ] \
  || fail "an unresolvable data directory left a stale state: '$FM_BACKLOG_ROW_STATE'"
[ -z "$FM_BACKLOG_ROW_TITLE" ] \
  || fail "an unresolvable data directory left a stale title: '$FM_BACKLOG_ROW_TITLE'"
[ -n "$FM_BACKLOG_ROW_ERROR" ] \
  || fail "an unresolvable data directory should name the failure"
pass "fm_backlog_row_probe: an unresolvable data directory clears the prior probe's outputs"
