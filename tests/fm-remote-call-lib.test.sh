#!/usr/bin/env bash
# tests/fm-remote-call-lib.test.sh - bin/fm-remote-call-lib.sh, the single owner
# of the hard bound on supervision-side remote fm-on.sh calls.
#
# The gap under test (evidence 2026-11-01): an unreachable remote machine could
# stall a whole supervision cycle. bin/fm-on.sh's ServerAlive keepalives only
# cover an established-then-dropped link, so a peer whose sshd stays up while
# its command never returns blocked every caller indefinitely.
#
# The guarantees under test:
#   - One bound governs every call site: FM_REMOTE_CALL_TIMEOUT defaults to 15
#     seconds, above fm-on.sh's own SSH ConnectTimeout so a merely unreachable
#     host still reports its own 255 rather than being preempted here.
#   - A value that is not a positive integer falls back to that default instead
#     of disabling the bound.
#   - A call that outlives the bound returns the bound's own status (what
#     fm_timed_out accepts) instead of hanging, while a call that returns keeps
#     its own status unchanged, including 255.
#   - FM_REMOTE_CALL_ELAPSED reports the whole seconds actually spent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-call)
LIB="$ROOT/bin/fm-remote-call-lib.sh"

# call_once <timeout> <script> [extra env...] -> "<rc>|<elapsed>|<out>"
call_once() {
  local timeout=$1 script=$2; shift 2
  # shellcheck disable=SC2016 # positional params expand in the child shell.
  env FM_REMOTE_CALL_TIMEOUT="$timeout" "$@" bash -c '
    . "$1"
    rc=0
    fm_remote_call "$2" || rc=$?
    printf "%s|%s|%s\n" "$rc" "$FM_REMOTE_CALL_ELAPSED" "$FM_REMOTE_CALL_OUT"
  ' _ "$LIB" "$script"
}

test_default_bound_and_override_validation() {
  local out
  out=$(bash -c '. "$1"; printf "%s\n" "$FM_REMOTE_CALL_TIMEOUT"' _ "$LIB")
  [ "$out" = 15 ] || fail "the default remote-call bound should be 15s, got '$out'"

  for value in '' 0 00 15s -1 2.5; do
    # shellcheck disable=SC2016 # positional params expand in the child shell.
    out=$(env FM_REMOTE_CALL_TIMEOUT="$value" bash -c '. "$1"; printf "%s\n" "$FM_REMOTE_CALL_TIMEOUT"' _ "$LIB")
    [ "$out" = 15 ] || fail "a remote-call bound of '$value' must fall back to 15s rather than disabling the bound, got '$out'"
  done

  # shellcheck disable=SC2016 # positional params expand in the child shell.
  out=$(env FM_REMOTE_CALL_TIMEOUT=40 bash -c '. "$1"; printf "%s\n" "$FM_REMOTE_CALL_TIMEOUT"' _ "$LIB")
  [ "$out" = 40 ] || fail "an explicit positive bound must be honoured, got '$out'"
  pass "remote call bound: one default above the SSH connect timeout, invalid values fall back"
}

test_silent_call_is_bounded() {
  local script out rc elapsed reported
  script="$TMP_ROOT/silent.sh"
  cat > "$script" <<'SH'
#!/usr/bin/env bash
exec sleep "${FM_TEST_SILENT_SECS:-120}"
SH
  chmod +x "$script"

  out=$(call_once 1 "$script" FM_TEST_SILENT_SECS=120)
  IFS='|' read -r rc elapsed reported <<< "$out"

  case "$rc" in
    124 | 137) ;;
    *) fail "a call that outlives the bound must report the bound's status, got rc=$rc" ;;
  esac
  [ "$elapsed" -ge 1 ] || fail "a bounded call must report the seconds it actually spent, got ${elapsed}s"
  [ "$elapsed" -le 30 ] || fail "a bounded call must return promptly at its bound, took ${elapsed}s"
  [ -z "$reported" ] || fail "a timed-out call must not hand back output, got '$reported'"
  pass "remote call bound: a peer that never answers returns at the bound instead of hanging"
}

test_returning_call_keeps_its_own_status() {
  local script out rc elapsed reported
  script="$TMP_ROOT/answers.sh"
  cat > "$script" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "alive"
exit "${FM_TEST_CALL_RC:-0}"
SH
  chmod +x "$script"

  out=$(call_once 10 "$script")
  IFS='|' read -r rc elapsed reported <<< "$out"
  [ "$rc" = 0 ] || fail "a successful call must return 0, got rc=$rc"
  [ "$reported" = alive ] || fail "a successful call's stdout must reach the caller, got '$reported'"

  out=$(call_once 10 "$script" FM_TEST_CALL_RC=255)
  IFS='|' read -r rc elapsed reported <<< "$out"
  [ "$rc" = 255 ] || fail "ssh's own 255 must survive the bound unchanged, got rc=$rc"
  pass "remote call bound: a returning call keeps its own status, including ssh's 255"
}

test_default_bound_and_override_validation
test_silent_call_is_bounded
test_returning_call_keeps_its_own_status

echo "# all fm-remote-call-lib tests passed"
