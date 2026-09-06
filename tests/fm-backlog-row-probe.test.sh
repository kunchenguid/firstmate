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
