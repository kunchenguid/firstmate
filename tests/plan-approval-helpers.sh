#!/usr/bin/env bash
# tests/plan-approval-helpers.sh - obtain a real plan approval for a fixture.
#
# A ship spawn or a scout promotion started in a home carrying the
# .fm-secondmate-home marker refuses without the primary firstmate's signed
# approval (bin/fm-plan-approval.sh owns that contract). Any fixture that drives
# such a spawn for another reason - Herdr workspace placement, trace context,
# backend behavior - needs a valid approval as a precondition.
#
# This is deliberately its own small file rather than part of tests/lib.sh: the
# suites that need it most are the real-Herdr end-to-end scripts, which bring
# their own reporters and cleanup and must not inherit lib.sh's traps.
#
# Source it after ROOT is set:
#   # shellcheck source=tests/plan-approval-helpers.sh
#   . "$ROOT/tests/plan-approval-helpers.sh"
#
# No side effects on source. set -u / set -e safe.

# fm_test_plan_approval <primary-home> <secondmate-home> <task-id> [<plan-file>]
# Create the primary keypair on first use, approve through the real tool rather
# than hand-writing a record, and place the public half where that home verifies
# against it. <plan-file> defaults to <secondmate-home>/data/<task-id>/brief.md,
# whose acceptance block is what the gate binds. A fixture that also records a
# .fm-secondmate-parent binding must point it at this same primary home, because
# a local parent binding is authoritative over the home's own copy.
# Returns non-zero without output on any failure; callers add their own `|| fail`.
#
# The v=2 contract signs a Freigabenotiz, a class, and an order rather than the
# brief's bytes, so the helper writes a throwaway note answering the five
# questions. A fixture approval is a PRECONDITION for suites that are about
# something else entirely (Herdr workspace placement, trace context, backend
# behavior); the cases that are about the note, the class, and the captain's
# wording live in tests/fm-plan-approval-v2.test.sh. The class is routine with a
# stated justification, so a fixture brief that happens to carry a destructive
# marker still yields an approval instead of tripping a wire this suite has no
# opinion about.
fm_test_plan_approval() {
  local primary=$1 home=$2 task=$3 plan=${4:-} sid notiz rc=0
  [ -n "${ROOT:-}" ] || return 1
  [ -n "$plan" ] || plan="$home/data/$task/brief.md"
  IFS= read -r sid < "$home/.fm-secondmate-home" || return 1
  sid=${sid//[[:space:]]/}
  [ -n "$sid" ] || return 1
  mkdir -p "$primary/config" "$primary/state" "$primary/data" "$home/config" || return 1
  notiz=$(mktemp "${TMPDIR:-/tmp}/fm-test-freigabenotiz.XXXXXX") || return 1
  {
    printf 'F1 Praemissen: the fixture home is shaped the way the gate expects.\n'
    printf 'F2 Abnahme: the brief acceptance block is the whole bar.\n'
    printf 'F3 Vision: exercises a test fixture, not a product.\n'
    printf 'F4 Budget: one fixture run.\n'
    printf 'F5 Betroffene: nobody outside this temporary directory.\n'
  } > "$notiz" || { rm -f "$notiz"; return 1; }
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$primary" \
    FM_STATE_OVERRIDE="$primary/state" FM_DATA_OVERRIDE="$primary/data" \
    FM_CONFIG_OVERRIDE="$primary/config" \
    "$ROOT/bin/fm-plan-approval.sh" approve "$sid" "$task" \
    --plan-file "$plan" --home "$home" \
    --klasse routine --no-order --notiz "$notiz" \
    --klasse-begruendung 'test fixture: no real system is reachable from here' \
    >/dev/null || rc=1
  rm -f "$notiz"
  [ "$rc" -eq 0 ] || return 1
  cp "$primary/config/plan-approval-key.pub" "$home/config/plan-approval-key.pub"
}
