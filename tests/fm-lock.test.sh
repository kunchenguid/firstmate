#!/usr/bin/env bash
# tests/fm-lock.test.sh - per-home session lock: harness-pid discovery and
# holder liveness. Covers the ps-walk ancestry path, the FM_HARNESS_PID override
# for a harness whose bash sandbox cannot traverse its own ancestry via ps
# (Claude Code's Bash tool reports "no such process" for its own $$), the
# env-marker fallback that unblocks such a ps-blind session, and the holder
# liveness checks - the pi basename match (the prior "<basename> <args>" + ^pi$
# concatenation never matched a live pi holder, so a second pi session could
# clobber a live one) and the ps-blind fail-safe (an uninspectable live holder
# is treated as held rather than stolen). These are safety-critical process
# invariants, so they run against real live PIDs and a fake ps.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK="$ROOT/bin/fm-lock.sh"
TMP=$(fm_test_tmproot fm-lock-tests)

# fake ps that always fails (simulates a sandbox blind to every process, as
# Claude Code's Bash tool reports "no such process" for its own $$).
fakebin_ps_fail() {
  local fb; fb=$(fm_fakebin "$1")
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fb/ps"
  printf '%s\n' "$fb"
}

# fake ps that reports comm "pi" / args "pi" for the pid in FM_FAKE_PS_PID
# (a real pi harness process has basename "pi"); every other pid is invisible.
fakebin_ps_pi() {
  local fb; fb=$(fm_fakebin "$1")
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
fmt= p=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) fmt=$2; shift 2 ;;
    -p) p=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ "$p" = "${FM_FAKE_PS_PID:-}" ] || exit 1
case "$fmt" in
  comm=) printf 'pi\n' ;;
  args=) printf 'pi\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fb/ps"
  printf '%s\n' "$fb"
}

test_holder_pi_basename_recognized() {
  local dir fb state child out
  dir="$TMP/holder-pi"
  state="$dir/state"; mkdir -p "$state"
  fb=$(fakebin_ps_pi "$dir/fb")
  sleep 30 & child=$!
  printf '%s\n' "$child" > "$state/.lock"
  out=$(env PATH="$fb:$PATH" FM_FAKE_PS_PID="$child" FM_STATE_OVERRIDE="$state" \
        "$LOCK" status 2>&1)
  kill "$child" 2>/dev/null; wait "$child" 2>/dev/null || true
  [ "$out" = "lock: held by live harness pid $child" ] \
    || fail "pi holder misreported: '$out' (expected held)"
  pass "pi holder recognized via basename (was 'stale' before fix)"
}

test_env_marker_fallback_acquires_when_ps_blind() {
  local dir fb state out rc
  dir="$TMP/env-fallback"
  state="$dir/state"; mkdir -p "$state"
  fb=$(fakebin_ps_fail "$dir/fb")
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
        CLAUDECODE=1 PI_CODING_AGENT= GROK_AGENT= \
        PATH="$fb:$PATH" FM_STATE_OVERRIDE="$state" "$LOCK" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "env-marker fallback did not acquire (exit $rc): $out"
  case "$out" in
    "lock acquired: harness pid "*) ;;
    *) fail "env-marker fallback wrong output: '$out'" ;;
  esac
  pass "env-marker fallback acquires when ps is blind (claude unblocked)"
}

test_harness_pid_override_acquires_when_ps_blind() {
  local dir fb state child out rc
  dir="$TMP/override"
  state="$dir/state"; mkdir -p "$state"
  fb=$(fakebin_ps_fail "$dir/fb")
  sleep 30 & child=$!
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
        CLAUDECODE= PI_CODING_AGENT= GROK_AGENT= \
        PATH="$fb:$PATH" FM_STATE_OVERRIDE="$state" FM_HARNESS_PID="$child" \
        "$LOCK" 2>&1); rc=$?
  kill "$child" 2>/dev/null; wait "$child" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "FM_HARNESS_PID override did not acquire (exit $rc): $out"
  [ "$out" = "lock acquired: harness pid $child" ] \
    || fail "override wrong output: '$out'"
  pass "FM_HARNESS_PID override acquires when ps is blind"
}

test_ps_blind_live_holder_not_stolen() {
  local dir fb state child out rc
  dir="$TMP/ps-blind-held"
  state="$dir/state"; mkdir -p "$state"
  fb=$(fakebin_ps_fail "$dir/fb")
  sleep 30 & child=$!
  printf '%s\n' "$child" > "$state/.lock"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
        CLAUDECODE= PI_CODING_AGENT= GROK_AGENT= \
        PATH="$fb:$PATH" FM_STATE_OVERRIDE="$state" FM_HARNESS_PID="$$" \
        "$LOCK" 2>&1); rc=$?
  kill "$child" 2>/dev/null; wait "$child" 2>/dev/null || true
  [ "$rc" -eq 1 ] || fail "ps-blind live holder was stolen (exit $rc): $out"
  case "$out" in
    *"another live firstmate session holds the lock"*) ;;
    *) fail "ps-blind holder refusal wrong output: '$out'" ;;
  esac
  pass "ps-blind live holder is not stolen (fail-safe held)"
}

test_holder_dead_pid_is_stale() {
  local dir fb state out dead
  dir="$TMP/holder-dead"
  state="$dir/state"; mkdir -p "$state"
  fb=$(fm_fakebin "$dir/fb")
  dead=999999
  while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
  printf '%s\n' "$dead" > "$state/.lock"
  out=$(env PATH="$fb:$PATH" FM_STATE_OVERRIDE="$state" "$LOCK" status 2>&1)
  [ "$out" = "lock: stale (pid $dead dead or not a harness)" ] \
    || fail "dead holder misreported: '$out'"
  pass "dead holder pid is stale"
}

test_harness_pid_override_rejects_dead() {
  # A dead FM_HARNESS_PID must not be used; harness_pid falls through. With ps
  # also blind and no env marker, acquire must fail rather than write a dead pid.
  local dir fb state dead out rc
  dir="$TMP/override-dead"
  state="$dir/state"; mkdir -p "$state"
  fb=$(fakebin_ps_fail "$dir/fb")
  dead=999998
  while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
        CLAUDECODE= PI_CODING_AGENT= GROK_AGENT= \
        PATH="$fb:$PATH" FM_STATE_OVERRIDE="$state" FM_HARNESS_PID="$dead" \
        "$LOCK" 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "dead FM_HARNESS_PID was accepted (exit $rc): $out"
  case "$out" in
    *"cannot locate harness process in ancestry"*) ;;
    *) fail "dead override wrong output: '$out'" ;;
  esac
  pass "dead FM_HARNESS_PID rejected, acquire falls through and fails"
}

test_holder_dead_pid_is_stale
test_holder_pi_basename_recognized
test_env_marker_fallback_acquires_when_ps_blind
test_harness_pid_override_acquires_when_ps_blind
test_harness_pid_override_rejects_dead
test_ps_blind_live_holder_not_stolen