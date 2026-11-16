#!/usr/bin/env bash
# tests/fm-check-audience.test.sh - routine checks climb the event ladder only
# as far as they need: a check that finds nothing wakes nothing, and a check
# registered for the supervision audience goes to the supervision host's small
# engine instead of the main session while the captain is present.
#
# Drives the real bin/fm-check-register.sh, bin/fm-watch.sh, and
# bin/fm-branch-dispatch.mjs (the routing CLI the supervision host runs).
# Pins:
#   1. the default registration record is unchanged; --audience supervision
#      adds exactly one hash-bound line; any other third line is refused;
#   2. a supervision-audience check's wake is branch-eligible while attended,
#      a main-audience or tampered one stays main's, and away is unchanged;
#   3. 5, 100 and 1000 registered checks that print nothing produce no wake at
#      all, while one that prints, run after all of them, produces exactly its
#      own wake (timings are printed as evidence).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"
DISPATCH="$ROOT/bin/fm-branch-dispatch.mjs"
TMP_ROOT=$(fm_test_tmproot fm-check-audience)

write_check() {  # <state> <id> <output-or-empty>
  if [ -n "$3" ]; then
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$3" >"$1/$2.check.sh"
  else
    printf '#!/usr/bin/env bash\nexit 0\n' >"$1/$2.check.sh"
  fi
  chmod 0700 "$1/$2.check.sh"
}

registered() {  # <state> <id> -> prints the reader's audience or fails
  FM_STATE_OVERRIDE="$1" bash -c '. "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-check-lib.sh"
    fm_custom_check_registered "$2" "$3" && printf "%s\n" "$FM_CUSTOM_CHECK_AUDIENCE"' _ "$ROOT" "$1" "$2"
}

offer() {  # <state> <reason> [--afk]
  local state=$1 reason=$2
  shift 2
  printf '%s\n' "$reason" | FM_STATE_OVERRIDE="$state" node "$DISPATCH" offer "$@" | sed -n 's/^eligible=//p'
}

test_registration_record() {
  local state="$TMP_ROOT/register/state" out
  mkdir -p "$state"
  write_check "$state" plain 'found one'
  write_check "$state" helper 'found two'
  FM_STATE_OVERRIDE="$state" "$REGISTER" plain >/dev/null || fail "default registration failed"
  assert_equals 2 "$(grep -c '' "$state/plain.check-trust")" "the default record keeps exactly two lines"
  assert_equals main "$(registered "$state" plain)" "the default audience is main"
  out=$(FM_STATE_OVERRIDE="$state" "$REGISTER" helper --audience supervision) || fail "supervision registration failed"
  assert_contains "$out" '(audience supervision)' "registration names the audience"
  assert_equals audience=supervision "$(sed -n 3p "$state/helper.check-trust")" "the audience is the record's third line"
  assert_equals supervision "$(registered "$state" helper)" "the reader returns the supervision audience"
  FM_STATE_OVERRIDE="$state" "$REGISTER" helper --audience everyone >/dev/null 2>&1
  expect_code 2 "$?" "an unknown audience is refused"
  printf 'audience=main\n' | cat <(head -n 2 "$state/helper.check-trust") - >"$state/helper.check-trust.new"
  mv "$state/helper.check-trust.new" "$state/helper.check-trust"
  chmod 0600 "$state/helper.check-trust"
  if registered "$state" helper >/dev/null; then fail "a hand-written third line must reject the record"; fi
  FM_STATE_OVERRIDE="$state" "$REGISTER" helper --audience supervision >/dev/null || fail "re-registration failed"
  printf 'extra\n' >>"$state/helper.check-trust"
  if registered "$state" helper >/dev/null; then fail "a fourth line must reject the record"; fi
  pass "registration keeps the default record byte-identical and binds a supervision audience; other lines are refused"
}

test_routing() {
  local state="$TMP_ROOT/route/state"
  mkdir -p "$state"
  write_check "$state" plain 'found one'
  write_check "$state" helper 'found two'
  FM_STATE_OVERRIDE="$state" "$REGISTER" plain >/dev/null
  FM_STATE_OVERRIDE="$state" "$REGISTER" helper --audience supervision >/dev/null
  printf '1\t1\tcheck\t%s\tcheck: %s: found two\n' "$state/helper.check.sh" "$state/helper.check.sh" >"$state/.wake-queue"
  assert_equals 1 "$(offer "$state" "check: $state/helper.check.sh: found two")" "a supervision-audience check is branch-eligible while attended"
  printf '1\t1\tcheck\t%s\tcheck: %s: found one\n' "$state/plain.check.sh" "$state/plain.check.sh" >"$state/.wake-queue"
  assert_equals 0 "$(offer "$state" "check: $state/plain.check.sh: found one")" "a main-audience check stays main's while attended"
  assert_equals 1 "$(offer "$state" "check: $state/plain.check.sh: found one" --afk)" "away, every check is the branch's as before"
  assert_equals 0 "$(offer "$state" "check: rearm-resurface")" "a built-in check stays main's"
  queue_helper() { printf '1\t1\tcheck\t%s\tcheck: %s: found two\n' "$1/helper.check.sh" "$1/helper.check.sh" >"$state/.wake-queue"; }
  queue_helper "$state"
  printf 'fm-custom-check-v1\n%064d\naudience=supervision\nextra\n' 0 >"$state/helper.check-trust"
  assert_equals 0 "$(offer "$state" "check: $state/helper.check.sh: found two")" "a malformed record falls back to main"
  # The reviewer's case: registered for supervision, then edited before its
  # queued finding is offered. The byte binding no longer holds.
  FM_STATE_OVERRIDE="$state" "$REGISTER" helper --audience supervision >/dev/null
  assert_equals 1 "$(offer "$state" "check: $state/helper.check.sh: found two")" "re-registered, it is the branch's again"
  printf '# edited after registration\n' >>"$state/helper.check.sh"
  if registered "$state" helper >/dev/null; then fail "the shell reader must reject an edited check"; fi
  assert_equals 0 "$(offer "$state" "check: $state/helper.check.sh: found two")" "an edited check's queued finding falls back to main"
  FM_STATE_OVERRIDE="$state" "$REGISTER" helper --audience supervision >/dev/null
  chmod 0777 "$state/helper.check.sh"
  assert_equals 0 "$(offer "$state" "check: $state/helper.check.sh: found two")" "a check with loosened permissions falls back to main"
  chmod 0700 "$state/helper.check.sh"
  # A wake naming a same-named check in another directory is not this home's.
  mkdir -p "$TMP_ROOT/route/other"
  cp -p "$state/helper.check.sh" "$TMP_ROOT/route/other/helper.check.sh"
  queue_helper "$TMP_ROOT/route/other"
  assert_equals 0 "$(offer "$state" "check: $TMP_ROOT/route/other/helper.check.sh: found two")" "a check outside this state directory falls back to main"
  # A linked check is never trusted.
  queue_helper "$state"
  mv "$state/helper.check.sh" "$TMP_ROOT/route/helper.real"
  ln -s "$TMP_ROOT/route/helper.real" "$state/helper.check.sh"
  assert_equals 0 "$(offer "$state" "check: $state/helper.check.sh: found two")" "a linked check falls back to main"
  pass "only a supervision registration the shell reader still accepts for the check's current bytes, in this state directory, moves its wake off main"
}

test_silent_checks_never_wake() {
  local n state dir i out start ms rows rc
  for n in 5 100 1000; do
    dir=$(make_case "scale-$n")
    state="$dir/state"
    out="$dir/watch.out"
    for i in $(seq 1 "$n"); do
      write_check "$state" "quiet-$i" ''
      FM_STATE_OVERRIDE="$state" "$REGISTER" "quiet-$i" >/dev/null || fail "register quiet-$i"
    done
    # The watcher runs checks in name order and wakes on the first finding, so
    # a finder that sorts last is reached only after every silent check ran
    # without waking: one wake, and only the finder's, proves both halves.
    write_check "$state" zz-finder 'found it'
    FM_STATE_OVERRIDE="$state" "$REGISTER" zz-finder >/dev/null
    start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
    PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 \
      FM_HEARTBEAT=999999 "$WATCH" >"$out" 2>&1 &
    # One pass runs every check in turn, about 0.1 s each on an idle machine,
    # so the bound scales with the count and leaves room for a loaded host.
    rc=0
    wait_for_exit "$!" $((600 + n * 6)) || rc=$?
    [ "$rc" -eq 0 ] || fail "$n checks: the watcher did not wake for the one finding (exit $rc after $(( ($(perl -MTime::HiRes=time -e 'printf "%d", time*1000') - start) / 1000 )) s): $(tail -n 5 "$out" | tr '\n' ' ') triage: $(tail -n 5 "$state/.watch-triage.log" 2>/dev/null | tr '\n' ' ')"
    ms=$(( $(perl -MTime::HiRes=time -e 'printf "%d", time*1000') - start ))
    assert_equals 1 "$(grep -c '^check:' "$out")" "$n checks: exactly one wake for the one finding"
    grep -qF "check: $state/zz-finder.check.sh: found it" "$out" || fail "$n checks: the wake is not the finder's: $(cat "$out")"
    rows=$(grep -c . "$state/.wake-queue" 2>/dev/null || true)
    assert_equals 1 "${rows:-0}" "$n checks: exactly one queued wake row"
    printf '# scale: %s silent checks then one finding -> one wake after %s ms, 0 wakes from the silent ones\n' "$n" "$ms"
  done
  pass "at 5, 100 and 1000 checks, silence wakes nothing and one finding wakes exactly once"
}

test_registration_record
test_routing
test_silent_checks_never_wake
