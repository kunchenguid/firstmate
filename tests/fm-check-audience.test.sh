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
#      all, while one that prints produces exactly its own wake (timings and
#      sizes are printed as evidence).
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
  printf '1\t1\tcheck\t%s\tcheck: %s: found two\n' "$state/helper.check.sh" "$state/helper.check.sh" >"$state/.wake-queue"
  printf 'fm-custom-check-v1\n%064d\naudience=supervision\nextra\n' 0 >"$state/helper.check-trust"
  assert_equals 0 "$(offer "$state" "check: $state/helper.check.sh: found two")" "a malformed record falls back to main"
  pass "only a hash-bound supervision record moves a check's wake off main; built-in and malformed stay main's"
}

test_silent_checks_never_wake() {
  local n state dir i out start ms pid bytes
  for n in 5 100 1000; do
    dir=$(make_case "silent-$n")
    state="$dir/state"
    for i in $(seq 1 "$n"); do
      write_check "$state" "quiet-$i" ''
      FM_STATE_OVERRIDE="$state" "$REGISTER" "quiet-$i" >/dev/null || fail "register quiet-$i"
    done
    out="$dir/watch.out"
    start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
    PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 \
      FM_HEARTBEAT=999999 "$WATCH" >"$out" 2>&1 &
    pid=$!
    # One full check pass has run once .last-check exists; nothing may wake.
    i=0
    while [ ! -e "$state/.last-check" ] && [ "$i" -lt 1200 ]; do sleep 0.1; i=$((i + 1)); done
    ms=$(( $(perl -MTime::HiRes=time -e 'printf "%d", time*1000') - start ))
    [ -e "$state/.last-check" ] || fail "$n silent checks: the watcher never finished a check pass"
    sleep 1
    kill -TERM "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    if grep -q '^check:' "$out"; then fail "$n silent checks produced a wake: $(head -3 "$out")"; fi
    [ ! -s "$state/.wake-queue" ] || fail "$n silent checks queued a wake row"
    bytes=$(wc -c <"$out" | tr -d ' ')
    printf '# scale: %s silent checks -> first pass in %s ms, 0 wakes, %s bytes of watcher output\n' "$n" "$ms" "$bytes"
    dir=$(make_case "finder-$n")
    state="$dir/state"
    out="$dir/watch.out"
    for i in $(seq 1 "$n"); do
      write_check "$state" "quiet-$i" ''
      FM_STATE_OVERRIDE="$state" "$REGISTER" "quiet-$i" >/dev/null || fail "register quiet-$i"
    done
    write_check "$state" finder 'found it'
    FM_STATE_OVERRIDE="$state" "$REGISTER" finder >/dev/null
    PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 \
      FM_HEARTBEAT=999999 "$WATCH" >"$out" 2>&1 &
    wait_for_exit "$!" 1200 || fail "$n checks: the watcher did not wake for the one finding"
    assert_equals 1 "$(grep -c '^check:' "$out")" "$n checks: exactly one wake for the one finding"
    grep -qF "check: $state/finder.check.sh: found it" "$out" || fail "$n checks: the wake is not the finder's: $(cat "$out")"
  done
  pass "at 5, 100 and 1000 checks, silence wakes nothing and one finding wakes exactly once"
}

test_registration_record
test_routing
test_silent_checks_never_wake
