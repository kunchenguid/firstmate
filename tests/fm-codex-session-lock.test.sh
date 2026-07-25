#!/usr/bin/env bash
# Focused behavior tests for Codex marker-owned session locks and the native
# SessionStart/SessionEnd lifecycle adapter.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK="$ROOT/bin/fm-lock.sh"
HOOK="$ROOT/bin/fm-codex-session-lock-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-session-lock-tests)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

make_hidden_ps() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$dir/ps"
}

make_live_owner_ps() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
[ "$pid" = "${FM_FAKE_LIVE_PID:-}" ] || exit 1
case "$*" in
  *"comm="*) printf '%s\n' codex ;;
  *"args="*) printf '%s\n' codex ;;
  *"ppid="*) printf '%s\n' 1 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/ps"
}

run_lock() {
  local home=$1 thread=$2 fakebin=$3
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    FM_HOME="$home" CODEX_THREAD_ID="$thread" PATH="$fakebin:$BASE_PATH" \
    bash "$LOCK"
}

run_hook() {
  local home=$1 event=$2 session=$3
  printf '{"hook_event_name":"%s","session_id":"%s","cwd":"%s"}\n' \
    "$event" "$session" "$ROOT" \
    | FM_HOME="$home" CODEX_THREAD_ID="$session" bash "$HOOK"
}

test_hook_registration() {
  local command
  jq -e '.hooks.SessionEnd | length == 1' "$ROOT/.codex/hooks.json" >/dev/null \
    || fail "Codex SessionEnd hook is not registered exactly once"
  command=$(jq -r '.hooks.SessionEnd[0].hooks[0].command' "$ROOT/.codex/hooks.json")
  # shellcheck disable=SC2016 # The command must retain this literal shell expression.
  assert_contains "$command" 'root=$(pwd -P)' "Codex SessionEnd hook is not pwd-anchored"
  assert_contains "$command" 'fm-codex-session-lock-hook.sh' "Codex SessionEnd hook does not invoke the lock adapter"
  jq -e '.hooks.SessionEnd[0].hooks[0].timeout == 3' "$ROOT/.codex/hooks.json" >/dev/null \
    || fail "Codex SessionEnd hook must respect Codex's three-second maximum"
  jq -e '[.hooks.SessionStart[]?.hooks[] | select(.command | contains("fm-codex-session-lock-hook.sh"))] | length == 1' \
    "$ROOT/.codex/hooks.json" >/dev/null \
    || fail "Codex SessionStart does not retain a verified harness owner before the first turn"
  pass "Codex registers one bounded SessionEnd release and one SessionStart owner claim"
}

test_clean_session_end_releases_matching_lock() {
  local home
  home=$(make_home clean-exit)
  printf '%s\n' '999999|codex:thread-clean|fallback' > "$home/state/.lock"
  run_hook "$home" SessionEnd thread-clean
  [ ! -e "$home/state/.lock" ] || fail "matching SessionEnd left the Codex session lock behind"
  pass "matching Codex SessionEnd releases the lock used by /quit"
}

test_session_start_retains_verified_harness_owner() {
  local home fakecodex owner
  home=$(make_home start-owner)
  fakecodex="$home/codex"
  ln -s /bin/bash "$fakecodex"
  # shellcheck disable=SC2016 # FM_HOOK_PATH expands inside the fake Codex process.
  FM_HOOK_PATH="$HOOK" FM_HOME="$home" CODEX_THREAD_ID=thread-start \
    "$fakecodex" -c 'printf '\''{"hook_event_name":"SessionStart","session_id":"thread-start"}\n'\'' | bash "$FM_HOOK_PATH"'
  owner=$(cat "$home/state/.lock")
  case "$owner" in
    *'|codex:thread-start|harness') ;;
    *) fail "SessionStart did not retain the visible Codex harness PID: $owner" ;;
  esac
  pass "Codex SessionStart retains a verified harness PID when ancestry is visible"
}

test_same_thread_preserves_existing_owner() {
  local home fakebin before out
  home=$(make_home same-thread)
  fakebin="$home/fakebin"
  make_hidden_ps "$fakebin"
  before='8123|codex:thread-same|fallback'
  printf '%s\n' "$before" > "$home/state/.lock"
  out=$(run_lock "$home" thread-same "$fakebin") || fail "same Codex thread could not reacquire its lock: $out"
  [ "$(cat "$home/state/.lock")" = "$before" ] || fail "same thread replaced the stable owner with a transient tool PID"
  assert_contains "$out" "$before" "same-thread acquisition did not report the preserved owner"
  pass "same Codex thread preserves its existing owner across PID-isolated tool calls"
}

test_dead_verified_owner_is_reclaimed() {
  local home fakebin out owner
  home=$(make_home dead-owner)
  fakebin="$home/fakebin"
  make_hidden_ps "$fakebin"
  printf '%s\n' '99999999|codex:thread-dead|harness' > "$home/state/.lock"
  out=$(run_lock "$home" thread-new "$fakebin") || fail "provably dead Codex owner was not reclaimed: $out"
  owner=$(cat "$home/state/.lock")
  case "$owner" in
    *'|codex:thread-new|fallback') ;;
    *) fail "dead owner recovery wrote unexpected owner: $owner" ;;
  esac
  pass "a verified Codex harness PID that is provably dead is reclaimed"
}

test_different_live_thread_is_excluded() {
  local home fakebin sleeper out status owner
  home=$(make_home live-other)
  fakebin="$home/fakebin"
  sleep 60 &
  sleeper=$!
  make_live_owner_ps "$fakebin"
  owner="$sleeper|codex:thread-live|harness"
  printf '%s\n' "$owner" > "$home/state/.lock"
  status=0
  out=$(FM_FAKE_LIVE_PID="$sleeper" run_lock "$home" thread-other "$fakebin" 2>&1) || status=$?
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  expect_code 1 "$status" "different live Codex thread must be excluded"
  assert_contains "$out" "another live firstmate session holds the lock" "live-thread refusal was not explicit"
  [ "$(cat "$home/state/.lock")" = "$owner" ] || fail "different thread replaced the live Codex owner"
  pass "a different live Codex thread remains excluded"
}

test_different_fallback_thread_stays_fail_closed() {
  local home fakebin out status owner
  home=$(make_home fallback-other)
  fakebin="$home/fakebin"
  make_hidden_ps "$fakebin"
  owner='17|codex:thread-hidden|fallback'
  printf '%s\n' "$owner" > "$home/state/.lock"
  status=0
  out=$(run_lock "$home" thread-other "$fakebin" 2>&1) || status=$?
  expect_code 1 "$status" "different thread must not reclaim a PID-isolated fallback owner"
  assert_contains "$out" "cannot verify whether another Codex session holds the lock" "fallback refusal lost its fail-closed reason"
  [ "$(cat "$home/state/.lock")" = "$owner" ] || fail "different thread replaced the unverifiable fallback owner"
  pass "a different thread cannot weaken the PID-isolated fallback boundary"
}

test_session_end_disconfirming_cases_leave_lock() {
  local home owner
  home=$(make_home release-disconfirming)
  for owner in \
    '4321' \
    '4321|codex:thread-other|harness' \
    '4321|codex:thread-clean|unknown' \
    '4321|unexpected|codex:thread-clean|harness' \
    'not-an-owner'; do
    printf '%s\n' "$owner" > "$home/state/.lock"
    run_hook "$home" SessionEnd thread-clean
    [ "$(cat "$home/state/.lock")" = "$owner" ] || fail "SessionEnd removed or changed disconfirming owner '$owner'"
  done
  rm -f "$home/state/.lock"
  ln -s "$home/state/missing-target" "$home/state/.lock"
  run_hook "$home" SessionEnd thread-clean
  [ -L "$home/state/.lock" ] || fail "SessionEnd followed or removed a symlinked lock"
  pass "SessionEnd leaves numeric, different, malformed, and symlinked owners untouched"
}

test_hook_registration
test_clean_session_end_releases_matching_lock
test_session_start_retains_verified_harness_owner
test_same_thread_preserves_existing_owner
test_dead_verified_owner_is_reclaimed
test_different_live_thread_is_excluded
test_different_fallback_thread_stays_fail_closed
test_session_end_disconfirming_cases_leave_lock
