#!/usr/bin/env bash
# tests/fm-status-presentation-manifest.test.sh - executable regressions for the
# fleet presentation manifest lookups in bin/fm-classify-lib.sh
# (status_presentation_cursor_offset / status_outcome_backstop_cursor_offset).
# Every drain looks each task up several times, so a lookup that costs time
# proportional to the whole manifest made a drain over a few hundred status logs
# take minutes. These call the real functions and assert both the exact lookup
# results (including the rejection rules) and a wall-clock bound on a manifest
# far larger than any real fleet, so a regression to a per-row shell loop fails.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-status-presentation-manifest-tests)
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"
export FM_HOME="$TMP_ROOT" STATE
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

MANIFEST="$STATE/.status-presentation-cursor"

make_status() {  # <task> <bytes>
  head -c "$2" /dev/zero | tr '\0' 'x' > "$STATE/$1.status"
}

row() {  # <task> <presented> <backstop> [<ident-override>]
  local ident=${4:-$(_fm_open_decisions_file_ident "$STATE/$1.status")}
  printf '%s\t%s\t%s\t%s\n' "$1" "$ident" "$2" "$3"
}

# lookup <function> <task>: prints "<rc>:<stdout>"
lookup() {
  local out rc
  out=$("$1" "$STATE/$2.status"); rc=$?
  printf '%s:%s' "$rc" "$out"
}

expect() {  # <label> <expected> <actual>
  [ "$2" = "$3" ] || fail "$1: expected '$2', got '$3'"
}

test_lookup_results_and_rejection_rules() {
  local ident function task trailing
  make_status alpha 100; make_status beta 100; make_status gamma 100
  ident=$(_fm_open_decisions_file_ident "$STATE/beta.status")

  { row alpha 40 7; row beta 60 90; row gamma 10 0; } > "$MANIFEST"
  expect "presented offset of a matching row" "0:60" "$(lookup status_presentation_cursor_offset beta)"
  expect "backstop offset of a matching row" "0:90" "$(lookup status_outcome_backstop_cursor_offset beta)"
  make_status delta 100
  expect "absent task presented offset" "0:0" "$(lookup status_presentation_cursor_offset delta)"
  expect "absent task backstop offset" "0:0" "$(lookup status_outcome_backstop_cursor_offset delta)"

  { row alpha 40 7; row beta 160 90; } > "$MANIFEST"
  expect "presented offset past EOF resets" "0:0" "$(lookup status_presentation_cursor_offset beta)"
  { row alpha 40 7; row beta 60 190; } > "$MANIFEST"
  expect "backstop offset past EOF resets" "0:0" "$(lookup status_outcome_backstop_cursor_offset beta)"

  { row alpha 40 7; row beta 60 90 "weak:0:0"; } > "$MANIFEST"
  expect "a rotated identity resets presented" "0:0" "$(lookup status_presentation_cursor_offset beta)"
  expect "a rotated identity resets backstop" "0:0" "$(lookup status_outcome_backstop_cursor_offset beta)"

  { row alpha 40 ''; row beta 60 ''; } > "$MANIFEST"
  expect "an empty backstop column reads as zero" "0:0" "$(lookup status_outcome_backstop_cursor_offset beta)"

  { row alpha 40 7; row beta 60 90; row beta 70 91; } > "$MANIFEST"
  expect "a duplicate row rejects the presented lookup" "1:" "$(lookup status_presentation_cursor_offset beta)"
  expect "backstop lookup keeps its first match" "0:90" "$(lookup status_outcome_backstop_cursor_offset beta)"

  { row alpha 40 7; row beta 60 90; printf 'gamma\t%s\tnot-a-number\t0\n' "$ident"; } > "$MANIFEST"
  expect "a malformed row after the match rejects the presented lookup" "1:" "$(lookup status_presentation_cursor_offset beta)"
  expect "a malformed row after the match is not reached by the backstop lookup" "0:90" "$(lookup status_outcome_backstop_cursor_offset beta)"
  { printf 'alpha\t%s\tnot-a-number\t0\n' "$ident"; row beta 60 90; } > "$MANIFEST"
  expect "a malformed row before the match rejects the backstop lookup" "1:" "$(lookup status_outcome_backstop_cursor_offset beta)"

  { row alpha 40 7; printf '%s\textra\n' "$(row beta 60 90)"; } > "$MANIFEST"
  expect "an extra column rejects the presented lookup" "1:" "$(lookup status_presentation_cursor_offset beta)"
  expect "an extra column rejects the backstop lookup" "1:" "$(lookup status_outcome_backstop_cursor_offset beta)"

  for trailing in $'\textra' $'\t\textra' $'\t\t\textra'; do
    { row alpha 40 7; printf '%s\t%s\n' "$(row beta 60 90)" "$trailing"; row gamma 10 0; } > "$MANIFEST"
    for function in status_presentation_cursor_offset status_outcome_backstop_cursor_offset; do
      expect "nonempty trailing fields on the match reject $function" "1:" "$(lookup "$function" beta)"
      expect "nonempty trailing fields before the match reject $function" "1:" "$(lookup "$function" gamma)"
      expect "nonempty trailing fields with no match reject $function" "1:" "$(lookup "$function" delta)"
    done
    expect "nonempty trailing fields after the match reject presentation" "1:" "$(lookup status_presentation_cursor_offset alpha)"
    expect "backstop stops before nonempty trailing fields" "0:7" "$(lookup status_outcome_backstop_cursor_offset alpha)"
  done

  { row alpha 40 7; printf '%s\t\t\t\n' "$(row beta 60 90)"; } > "$MANIFEST"
  expect "empty trailing fields preserve the presented offset" "0:60" "$(lookup status_presentation_cursor_offset beta)"
  expect "empty trailing fields preserve the backstop offset" "0:90" "$(lookup status_outcome_backstop_cursor_offset beta)"

  make_status 1 100; make_status 01 100
  for task in 1 01; do
    if [ "$task" = 1 ]; then
      { row 01 60 90; row 1 40 7; } > "$MANIFEST"
    else
      { row 1 60 90; row 01 40 7; } > "$MANIFEST"
    fi
    expect "numeric task $task has a distinct presented offset" "0:40" "$(lookup status_presentation_cursor_offset "$task")"
    expect "numeric task $task has a distinct backstop offset" "0:7" "$(lookup status_outcome_backstop_cursor_offset "$task")"
    row "$task" 70 91 >> "$MANIFEST"
    expect "an exact numeric duplicate rejects presentation" "1:" "$(lookup status_presentation_cursor_offset "$task")"
    expect "an exact numeric duplicate preserves the first backstop" "0:7" "$(lookup status_outcome_backstop_cursor_offset "$task")"
  done

  # A hand-damaged row with an empty identity or presented column used to be
  # shifted by the reader's tab collapsing and accepted; both columns are now
  # rejected as malformed. The manifest writer never emits such a row.
  { row alpha 40 7; printf 'beta\t%s\t\t90\n' "$ident"; } > "$MANIFEST"
  expect "an empty presented column rejects the presented lookup" "1:" "$(lookup status_presentation_cursor_offset beta)"
  expect "an empty presented column rejects the backstop lookup" "1:" "$(lookup status_outcome_backstop_cursor_offset beta)"
  { row alpha 40 7; printf 'beta\t\t60\t90\n'; } > "$MANIFEST"
  expect "an empty identity column rejects the presented lookup" "1:" "$(lookup status_presentation_cursor_offset beta)"
  expect "an empty identity column rejects the backstop lookup" "1:" "$(lookup status_outcome_backstop_cursor_offset beta)"
  pass "manifest lookups return exact offsets and keep their rejection rules"
}

test_lookup_cost_does_not_grow_with_the_manifest() {
  local i start elapsed ident
  make_status zeta 100; make_status eta 100
  ident=$(_fm_open_decisions_file_ident "$STATE/zeta.status")
  {
    i=0
    while [ "$i" -lt 6000 ]; do
      printf 'filler-%d\tweak:1:%d\t10\t0\n' "$i" "$i"
      i=$((i + 1))
    done
    row zeta 55 66
    row eta 20 30
  } > "$MANIFEST"
  start=$SECONDS
  for i in 1 2 3 4 5 6; do
    [ "$(lookup status_presentation_cursor_offset zeta)" = "0:55" ] || fail "large manifest presented lookup is wrong"
    [ "$(lookup status_outcome_backstop_cursor_offset eta)" = "0:30" ] || fail "large manifest backstop lookup is wrong"
  done
  elapsed=$((SECONDS - start))
  [ "$elapsed" -le 10 ] || fail "12 lookups over a 6000-row manifest took ${elapsed}s; lookup cost must not scale with a shell loop over every row"
  pass "twelve lookups over a 6000-row manifest finish within 10s (took ${elapsed}s)"
}

test_lookup_results_and_rejection_rules
test_lookup_cost_does_not_grow_with_the_manifest
