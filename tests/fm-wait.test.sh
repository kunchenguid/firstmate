#!/usr/bin/env bash
# tests/fm-wait.test.sh - the declared-wait machine field (bin/fm-wait-lib.sh)
# and its only writer (bin/fm-wait.sh). The field is a worker's deliberate
# external wait with reason and deadline: declare writes the field atomically
# AND appends the matching paused status event in one command, clear removes
# it with a resume event, re-declaring refreshes it, a deadline that is not in
# the future is refused, and a malformed field parses as undeclared so it can
# never silence an alarm. The watcher-side damping and single-fire expiry
# semantics are exercised in tests/fm-watch-triage.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-wait-lib.sh
. "$ROOT/bin/fm-wait-lib.sh"

WAIT="$ROOT/bin/fm-wait.sh"
TMP_ROOT=$(fm_test_tmproot fm-wait-tests)

new_home() {  # <name> [id]
  local dir="$TMP_ROOT/$1" id=${2:-t1}
  mkdir -p "$dir/state"
  : > "$dir/state/$id.meta"
  printf '%s\n' "$dir"
}

test_declare_writes_field_and_status_event() {
  local home out
  home=$(new_home declare)
  out=$(FM_HOME="$home" "$WAIT" declare t1 --reason "upstream release, ts=decoy" --until +120) \
    || fail "declare failed: $out"
  fm_wait_read "$home/state" t1 || fail "declared field did not parse"
  [ "$FM_WAIT_STATE" = active ] || fail "fresh declaration must be active, got $FM_WAIT_STATE"
  [ "$FM_WAIT_REASON" = "upstream release, ts=decoy" ] \
    || fail "reason with an embedded ts= token was mangled: '$FM_WAIT_REASON'"
  [ "$FM_WAIT_IDENTITY" = "$FM_WAIT_TS-$FM_WAIT_UNTIL" ] || fail "identity is not ts-until"
  grep -q '^paused: upstream release, ts=decoy (until ' "$home/state/t1.status" \
    || fail "declare did not append the paused status event"
  pass "declare writes the field and the paused status event in one command"
}

test_declare_refuses_bad_input() {
  local home
  home=$(new_home refuse)
  FM_HOME="$home" "$WAIT" declare missing-id --reason x --until +60 2>/dev/null \
    && fail "declare accepted an id with no metadata"
  FM_HOME="$home" "$WAIT" declare t1 --reason x --until +0 2>/dev/null \
    && fail "declare accepted a deadline that is not in the future"
  FM_HOME="$home" "$WAIT" declare t1 --reason x --until "not a date" 2>/dev/null \
    && fail "declare accepted an unparseable deadline"
  FM_HOME="$home" "$WAIT" declare t1 --until +60 2>/dev/null \
    && fail "declare accepted a missing reason"
  [ ! -e "$home/state/t1.wait" ] || fail "a refused declare still wrote a field"
  pass "declare refuses missing metadata, past or unparseable deadlines, and a missing reason"
}

test_redeclare_replaces_and_clear_removes() {
  local home first_until
  home=$(new_home refresh)
  FM_HOME="$home" "$WAIT" declare t1 --reason "first" --until +60 >/dev/null || fail "first declare failed"
  fm_wait_read "$home/state" t1 || fail "first field did not parse"
  first_until=$FM_WAIT_UNTIL
  FM_HOME="$home" "$WAIT" declare t1 --reason "second" --until +600 >/dev/null || fail "re-declare failed"
  fm_wait_read "$home/state" t1 || fail "refreshed field did not parse"
  [ "$FM_WAIT_REASON" = second ] || fail "re-declare did not replace the reason"
  [ "$FM_WAIT_UNTIL" -gt "$first_until" ] || fail "re-declare did not extend the deadline"
  FM_HOME="$home" "$WAIT" clear t1 >/dev/null || fail "clear failed"
  [ ! -e "$home/state/t1.wait" ] || fail "clear left the field behind"
  grep -q '^working: wait cleared (second)$' "$home/state/t1.status" \
    || fail "clear did not append the resume event naming the cleared reason"
  fm_wait_read "$home/state" t1 && fail "a cleared field still parsed"
  pass "re-declare refreshes the field and clear removes it with a resume event"
}

test_expired_and_malformed_fields() {
  local home now rc
  home=$(new_home states)
  now=$(date +%s)
  printf 'v1 until=%s ts=%s reason=already over\n' $(( now - 5 )) $(( now - 50 )) > "$home/state/t1.wait"
  fm_wait_read "$home/state" t1 || fail "expired field did not parse"
  [ "$FM_WAIT_STATE" = expired ] || fail "past deadline must read expired, got $FM_WAIT_STATE"
  printf 'v1 until=notanumber ts=1 reason=x\n' > "$home/state/t1.wait"
  fm_wait_read "$home/state" t1
  rc=$?
  [ "$rc" -eq 2 ] || fail "malformed field must return 2 (undeclared, silences nothing), got $rc"
  [ -z "$FM_WAIT_STATE" ] || fail "malformed field must leave no parsed state behind"
  printf 'v1 until=%s ts=%s\n' $(( now + 60 )) "$now" > "$home/state/t1.wait"
  fm_wait_read "$home/state" t1
  [ $? -eq 2 ] || fail "a field with no reason must be malformed"
  FM_HOME="$home" "$WAIT" show t1 >/dev/null 2>&1 && fail "show must exit non-zero on a malformed field"
  pass "expired fields read expired; malformed fields read as undeclared and never silence"
}

test_declare_refuses_multiline_reason() {
  local home
  home=$(new_home multiline)
  FM_HOME="$home" "$WAIT" declare t1 --reason "$(printf 'a\nb')" --until +60 2>/dev/null \
    && fail "declare accepted a multi-line reason"
  [ ! -e "$home/state/t1.wait" ] || fail "a refused multi-line declare still wrote a field"
  pass "declare refuses a multi-line reason (the field is exactly one line)"
}

test_declare_writes_field_and_status_event
test_declare_refuses_bad_input
test_redeclare_replaces_and_clear_removes
test_expired_and_malformed_fields
test_declare_refuses_multiline_reason
