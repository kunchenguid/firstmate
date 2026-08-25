#!/usr/bin/env bash
# tests/fm-owned.test.sh - fm-owned.sh must actually draw the ownership
# boundary L86 needs: a task's own identifiers are registered and readable
# back, an unrelated pid reads as unowned, and a task's own descendant
# processes read as allowed without each one self-registering.
#
#   1. CLI contract: add writes the documented "<kind> <value> <ts>" line,
#      list/list-all read it back, remove drops exactly the matching line and
#      no other (a sibling value for the same kind survives).
#   2. pid-erlaubt: a directly registered pid is allowed; a descendant of a
#      registered pid (a real child process) is allowed; an unrelated,
#      unregistered pid is denied - divergence asserted so the case cannot go
#      vacuous.
#   3. Validation refuses loudly (L33): unknown kind, non-numeric pid/port,
#      a task containing '/' - none of these write a file.
#   4. A kind=pfad value with spaces round-trips through add/list/remove.
#
# Isolation: everything runs against a throwaway FM_HOME. Nothing touches the
# real fleet state.
# shellcheck disable=SC2015 # ok/fail are echo-only, so `A && ok || fail` cannot misfire.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNED="$REPO/bin/fm-owned.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_A="$TMP/home"
mkdir -p "$HOME_A/state"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

run() { FM_HOME="$HOME_A" "$OWNED" "$@"; }

# --- 1. CLI contract -------------------------------------------------------
run add taska pid 4242 || fail "add must succeed for a valid pid"
run add taska pid 4343 || fail "add must succeed for a second pid"
FILE="$HOME_A/state/taska.owned"
[ -f "$FILE" ] || fail "add must create state/<task>.owned"
grep -qE '^pid 4242 [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$FILE" \
  && ok "add writes the documented '<kind> <value> <ts>' line" \
  || fail "add must write the documented line format"

list_out="$(run list taska)"
printf '%s\n' "$list_out" | grep -q '^pid 4242 ' && printf '%s\n' "$list_out" | grep -q '^pid 4343 ' \
  && ok "list shows both registered pids" || fail "list must show both registered pids"

run add taskb port 8080 || fail "add must succeed for taskb"
all_out="$(run list-all)"
printf '%s\n' "$all_out" | grep -q '^taska pid 4242 ' \
  && printf '%s\n' "$all_out" | grep -q '^taskb port 8080 ' \
  && ok "list-all aggregates across tasks, each prefixed with its task" \
  || fail "list-all must aggregate every task's owned lines"

run remove taska pid 4242 || fail "remove must succeed"
after_remove="$(run list taska)"
printf '%s\n' "$after_remove" | grep -q '^pid 4242 ' \
  && fail "remove must drop the matching line" \
  || ok "remove drops exactly the matching line"
printf '%s\n' "$after_remove" | grep -q '^pid 4343 ' \
  || fail "remove must not touch a sibling value for the same kind"
ok "remove leaves the sibling pid intact"

# --- 4. a pfad value with spaces round-trips --------------------------------
run add taska pfad "/some path/with spaces" || fail "add must accept a pfad value with spaces"
printf '%s\n' "$(run list taska)" | grep -qF 'pfad /some path/with spaces ' \
  && ok "a pfad value with spaces round-trips through list" \
  || fail "list must preserve a pfad value's internal spaces"
run remove taska pfad "/some path/with spaces" || fail "remove must accept a pfad value with spaces"
printf '%s\n' "$(run list taska)" | grep -qF '/some path/with spaces' \
  && fail "remove must drop a pfad value with spaces" \
  || ok "remove drops a pfad value with spaces"

# --- 2. pid-erlaubt ----------------------------------------------------------
run add taskc pid "$$" || fail "add must accept this test's own pid"
if run pid-erlaubt "$$"; then
  ok "pid-erlaubt allows a directly registered pid"
else
  fail "pid-erlaubt must allow a directly registered pid"
fi

sleep 30 &
CHILD=$!
if run pid-erlaubt "$CHILD"; then
  ok "pid-erlaubt allows a real descendant of a registered pid"
else
  fail "pid-erlaubt must allow a descendant of a registered pid"
fi
kill "$CHILD" 2>/dev/null || true
wait "$CHILD" 2>/dev/null || true

if run pid-erlaubt 999999; then
  fail "pid-erlaubt must deny an unregistered, unrelated pid"
else
  ok "pid-erlaubt denies an unregistered, unrelated pid (divergence from the allowed case above)"
fi

# --- 3. validation refuses loudly and writes nothing ------------------------
before_count="$(find "$HOME_A/state" -name '*.owned' -exec cat {} \; | wc -l)"
if run add taska bogus 1 >/dev/null 2>&1; then
  fail "add must refuse an unknown kind"
else
  ok "add refuses an unknown kind"
fi
if run add taska pid notanumber >/dev/null 2>&1; then
  fail "add must refuse a non-numeric pid value"
else
  ok "add refuses a non-numeric pid value"
fi
if run add taska port notanumber >/dev/null 2>&1; then
  fail "add must refuse a non-numeric port value"
else
  ok "add refuses a non-numeric port value"
fi
if run add "bad/task" pid 1 >/dev/null 2>&1; then
  fail "add must refuse a task containing '/'"
else
  ok "add refuses a task containing '/'"
fi
after_count="$(find "$HOME_A/state" -name '*.owned' -exec cat {} \; | wc -l)"
[ "$before_count" -eq "$after_count" ] \
  && ok "refused adds write nothing" \
  || fail "a refused add must not write a line (before=$before_count after=$after_count)"

# --- list/list-all on an empty or missing registry are quiet, not errors ---
if FM_HOME="$HOME_A" "$OWNED" list nosuchtask >/dev/null 2>&1; then
  ok "list on a task with no owned file exits cleanly"
else
  fail "list on a task with no owned file must exit 0"
fi

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS failure(s)" >&2
  exit 1
fi
echo "all fm-owned checks passed"
