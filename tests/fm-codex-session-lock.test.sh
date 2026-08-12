#!/usr/bin/env bash
# Focused behavior tests for Codex marker-owned session locks and lifecycle hooks.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK="$ROOT/bin/fm-lock.sh"
HOOK="$ROOT/bin/fm-codex-session-lock-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-session-lock-tests)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
HOOK_ROOT="$TMP_ROOT/hook-primary"
mkdir -p "$HOOK_ROOT"
fm_git_init_commit "$HOOK_ROOT"
printf '# agents\n' > "$HOOK_ROOT/AGENTS.md"
ln -s "$ROOT/bin" "$HOOK_ROOT/bin"
mkdir -p "$HOOK_ROOT/.codex"
cp "$ROOT/.codex/hooks.json" "$HOOK_ROOT/.codex/hooks.json"
git -C "$HOOK_ROOT" add AGENTS.md bin
git -C "$HOOK_ROOT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm primary

# Codex owner records exist only while no other harness marker claims the thread,
# so a marker exported by the shell that launches this suite (a Claude, Pi, or
# Grok session running the gate) would silently reduce every Codex owner here to a
# markerless legacy lock. Scrub them once; each case sets the markers it needs.
unset CLAUDECODE PI_CODING_AGENT GROK_AGENT CODEX_THREAD_ID

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf 'root=%s\ntoken=hook-%s\n' "$HOOK_ROOT" "$1" > "$home/state/.primary-attestation"
  chmod 600 "$home/state/.primary-attestation"
  printf '%s\n' "$home"
}

make_hidden_ps() {
  local dir=$1
  mkdir -p "$dir"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$dir/ps"
  chmod +x "$dir/ps"
}

make_live_owner_ps() {
  local dir=$1 command_name=${2:-codex}
  mkdir -p "$dir"
  sed "s/@COMMAND@/$command_name/g" > "$dir/ps" <<'SH'
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
  *"comm="*) printf '%s\n' @COMMAND@ ;;
  *"args="*) printf '%s\n' @COMMAND@ ;;
  *"ppid="*) printf '%s\n' 1 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/ps"
}

make_any_grok_ps() {
  local dir=$1
  mkdir -p "$dir"
  sed 's/^+//' > "$dir/ps" <<'SH'
+#!/usr/bin/env bash
+case "$*" in
+  *"comm="*) printf '%s\n' grok ;;
+  *"args="*) printf '%s\n' grok ;;
+  *"ppid="*) printf '%s\n' 1 ;;
+  *) exit 1 ;;
+esac
SH
  chmod +x "$dir/ps"
}

make_codex_parent_ps() {
  local dir=$1
  mkdir -p "$dir"
  sed 's/^+//' > "$dir/ps" <<'SH'
+#!/usr/bin/env bash
+set -u
+pid=
+previous=
+for argument in "$@"; do
+  [ "$previous" = -p ] && pid=$argument
+  previous=$argument
+done
+case "$*" in
+  *"comm="*)
+    if [ "$pid" = "${FM_FAKE_CODEX_PID:?}" ]; then printf '%s\n' codex; else printf '%s\n' bash; fi
+    ;;
+  *"args="*)
+    if [ "$pid" = "${FM_FAKE_CODEX_PID:?}" ]; then printf '%s\n' codex; else printf '%s\n' bash; fi
+    ;;
+  *"ppid="*) printf '%s\n' "${FM_FAKE_CODEX_PID:?}" ;;
+  *) exit 1 ;;
+esac
SH
  chmod +x "$dir/ps"
}

run_lock() {
  local home=$1 thread=$2 fakebin=$3 token
  token=$(awk -F= '$1 == "token" {print substr($0, index($0, "=") + 1); exit}' \
    "$home/state/.primary-attestation" 2>/dev/null || true)
  ( cd "$HOOK_ROOT" && env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
      FM_ROOT_OVERRIDE="$HOOK_ROOT" FM_HOME="$home" CODEX_THREAD_ID="$thread" \
      FM_PRIMARY_ATTESTATION="$token" \
      PATH="$fakebin:$BASE_PATH" bash "$LOCK" )
}

run_hook() {
  local home=$1 event=$2 session=$3
  ( cd "$HOOK_ROOT" && printf '{"hook_event_name":"%s","session_id":"%s","cwd":"%s"}\n' \
      "$event" "$session" "$HOOK_ROOT" \
      | FM_ROOT_OVERRIDE="$HOOK_ROOT" FM_HOME="$home" CODEX_THREAD_ID="$session" bash "$HOOK" )
}

test_hook_registration_preserves_jt_pretool() {
  local home command out status
  jq -e '.hooks.PreToolUse | type == "array" and length > 0 and all(.[]; (.hooks | type) == "array" and all(.hooks[]; .type == "command"))' \
    "$ROOT/.codex/hooks.json" >/dev/null || fail "JT PreToolUse hook configuration is not a command hook"
  jq -e '[.hooks.SessionStart[]?.hooks[]? | select(.type == "command")] | length == 1' \
    "$ROOT/.codex/hooks.json" >/dev/null || fail "Codex SessionStart hook is not registered exactly once"
  jq -e '[.hooks.SessionEnd[]?.hooks[]? | select(.type == "command")] | length == 1' \
    "$ROOT/.codex/hooks.json" >/dev/null || fail "Codex SessionEnd hook is not registered exactly once"
  jq -e '.hooks.SessionStart[0].hooks[0].timeout == 3 and .hooks.SessionEnd[0].hooks[0].timeout == 3' \
    "$ROOT/.codex/hooks.json" >/dev/null || fail "Codex lock hooks must use the three-second bound"

  home=$(make_home configured-lifecycle)
  rm -f "$home/state/.primary-attestation"
  command=$(jq -r '[.hooks.SessionStart[]?.hooks[]? | select(.type == "command") | .command] | if length == 1 then .[0] else empty end' "$ROOT/.codex/hooks.json")
  [ -n "$command" ] || fail "configured SessionStart command could not be normalized"
  out=$(cd "$HOOK_ROOT" && printf '{"hook_event_name":"SessionStart","session_id":"configured-thread"}\n' \
    | FM_ROOT_OVERRIDE="$HOOK_ROOT" FM_HOME="$home" CODEX_THREAD_ID=configured-thread \
      bash -lc "$command" 2>&1) || status=$?
  status=${status:-0}
  [ "$status" -eq 0 ] || fail "configured SessionStart command failed: $out"
  [ -f "$home/state/.lock" ] || fail "configured SessionStart command did not acquire the lock"

  command=$(jq -r '[.hooks.SessionEnd[]?.hooks[]? | select(.type == "command") | .command] | if length == 1 then .[0] else empty end' "$ROOT/.codex/hooks.json")
  [ -n "$command" ] || fail "configured SessionEnd command could not be normalized"
  out=$(cd "$HOOK_ROOT" && printf '{"hook_event_name":"SessionEnd","session_id":"configured-thread"}\n' \
    | FM_ROOT_OVERRIDE="$HOOK_ROOT" FM_HOME="$home" CODEX_THREAD_ID=configured-thread \
      bash -lc "$command" 2>&1) || status=$?
  status=${status:-0}
  [ "$status" -eq 0 ] || fail "configured SessionEnd command failed: $out"
  [ ! -e "$home/state/.lock" ] || fail "configured SessionEnd command did not release the lock"
  pass "Codex lock hook configuration executes its lifecycle contract"
}

test_hooks_work_when_jq_fails() {
  local home fakebin
  home=$(make_home no-jq)
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  rm -f "$home/state/.primary-attestation"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 127' > "$fakebin/jq"
  chmod +x "$fakebin/jq"
  ln -s "$(command -v node)" "$fakebin/node"
  ( cd "$HOOK_ROOT" && printf '{"hook_event_name":"SessionStart","session_id":"thread-no-jq"}\n' \
      | FM_ROOT_OVERRIDE="$HOOK_ROOT" FM_HOME="$home" CODEX_THREAD_ID=thread-no-jq \
        PATH="$fakebin:$BASE_PATH" bash "$HOOK" )
  [ -f "$home/state/.lock" ] || fail "SessionStart did not acquire without jq"
  [ -f "$home/state/.primary-attestation" ] || fail "SessionStart did not establish the primary attestation"
  ( cd "$HOOK_ROOT" && printf '{"hook_event_name":"SessionEnd","session_id":"thread-no-jq"}\n' \
      | FM_ROOT_OVERRIDE="$HOOK_ROOT" FM_HOME="$home" CODEX_THREAD_ID=thread-no-jq \
        PATH="$fakebin:$BASE_PATH" bash "$HOOK" )
  [ ! -e "$home/state/.lock" ] || fail "SessionEnd did not release without jq"
  pass "Codex lifecycle hooks do not depend on jq"
}

test_matching_session_end_only_releases_regular_exact_owner() {
  local home owner
  home=$(make_home exact-release)
  printf '%s\n' '999999|codex:thread-clean|fallback' > "$home/state/.lock"
  run_hook "$home" SessionEnd thread-clean
  [ ! -e "$home/state/.lock" ] || fail "matching SessionEnd left the lock behind"

  for owner in \
    '4321' \
    '4321|codex:thread-other|harness' \
    '4321|codex:thread-clean|unknown' \
    '4321|unexpected|codex:thread-clean|harness' \
    'not-an-owner'; do
    printf '%s\n' "$owner" > "$home/state/.lock"
    run_hook "$home" SessionEnd thread-clean
    [ "$(cat "$home/state/.lock")" = "$owner" ] || fail "SessionEnd changed disconfirming owner '$owner'"
  done
  rm -f "$home/state/.lock"
  ln -s "$home/state/missing-target" "$home/state/.lock"
  run_hook "$home" SessionEnd thread-clean
  [ -L "$home/state/.lock" ] || fail "SessionEnd followed or removed a symlinked lock"
  pass "SessionEnd removes only the matching regular lock"
}

test_session_start_retains_verified_harness_owner() {
  local home fakecodex owner
  home=$(make_home start-owner)
  fakecodex="$home/codex"
  ln -s /bin/bash "$fakecodex"
  # shellcheck disable=SC2016
  ( cd "$HOOK_ROOT" && FM_HOOK_PATH="$HOOK" FM_ROOT_OVERRIDE="$HOOK_ROOT" \
    FM_HOME="$home" CODEX_THREAD_ID=thread-start \
      "$fakecodex" -c 'printf '\''{"hook_event_name":"SessionStart","session_id":"thread-start"}\n'\'' | bash "$FM_HOOK_PATH"' )
  owner=$(cat "$home/state/.lock")
  case "$owner" in *'|codex:thread-start|harness') ;; *) fail "unexpected SessionStart owner: $owner" ;; esac
  pass "SessionStart retains a visible Codex harness PID"
}

test_same_thread_preserves_existing_owner() {
  local home fakebin before out
  home=$(make_home same-thread)
  fakebin="$home/fakebin"
  make_hidden_ps "$fakebin"
  before='8123|codex:thread-same|fallback'
  printf '%s\n' "$before" > "$home/state/.lock"
  out=$(run_lock "$home" thread-same "$fakebin") || fail "same Codex thread could not reacquire: $out"
  [ "$(cat "$home/state/.lock")" = "$before" ] || fail "same thread replaced the stable owner"
  pass "same Codex thread preserves its owner across PID isolation"
}

test_dead_verified_owner_is_reclaimed() {
  local home fakebin owner
  home=$(make_home dead-owner)
  fakebin="$home/fakebin"
  make_hidden_ps "$fakebin"
  printf '%s\n' '99999999|codex:thread-dead|harness' > "$home/state/.lock"
  run_lock "$home" thread-new "$fakebin" >/dev/null || fail "dead verified owner was not reclaimed"
  owner=$(cat "$home/state/.lock")
  case "$owner" in *'|codex:thread-new|fallback') ;; *) fail "unexpected reclaimed owner: $owner" ;; esac
  pass "provably dead verified Codex owners are reclaimed"
}

test_different_threads_remain_excluded() {
  local home fakebin sleeper owner out status
  home=$(make_home other-thread)
  fakebin="$home/fakebin"
  sleep 60 & sleeper=$!
  make_live_owner_ps "$fakebin" codex
  owner="$sleeper|codex:thread-live|harness"
  printf '%s\n' "$owner" > "$home/state/.lock"
  status=0
  out=$(FM_FAKE_LIVE_PID="$sleeper" run_lock "$home" thread-other "$fakebin" 2>&1) || status=$?
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  expect_code 1 "$status" "different live Codex thread must be excluded"
  assert_contains "$out" "another live firstmate session holds the lock" "live owner refusal was not explicit"

  make_hidden_ps "$fakebin"
  owner='17|codex:thread-hidden|fallback'
  printf '%s\n' "$owner" > "$home/state/.lock"
  status=0
  out=$(run_lock "$home" thread-other "$fakebin" 2>&1) || status=$?
  expect_code 1 "$status" "different thread must not reclaim a fallback owner"
  assert_contains "$out" "cannot verify whether another Codex session holds the lock" "fallback refusal lost its reason"
  pass "different Codex threads stay excluded for live and fallback owners"
}

test_grok_precedence_and_primary_lock_protection() {
  local home fakebin grokbin sleeper out status owner token
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT GROK_AGENT=1 CODEX_THREAD_ID=inherited-thread \
    FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-harness.sh")
  [ "$out" = grok ] || fail "Grok did not precede inherited CODEX_THREAD_ID: $out"

  home=$(make_home grok-owner-format)
  token=$(awk -F= '$1 == "token" {print substr($0, index($0, "=") + 1); exit}' \
    "$home/state/.primary-attestation")
  grokbin="$home/grokbin"
  make_any_grok_ps "$grokbin"
  ( cd "$HOOK_ROOT" && env -u CLAUDECODE -u PI_CODING_AGENT GROK_AGENT=1 \
      CODEX_THREAD_ID=inherited-thread FM_ROOT_OVERRIDE="$HOOK_ROOT" \
      FM_HOME="$home" FM_PRIMARY_ATTESTATION="$token" \
      PATH="$grokbin:$BASE_PATH" bash "$LOCK" >/dev/null )
  owner=$(cat "$home/state/.lock")
  case "$owner" in ''|*[!0-9]*) fail "Grok owner was incorrectly structured as Codex: $owner" ;; esac

  home=$(make_home grok-primary)
  token=$(awk -F= '$1 == "token" {print substr($0, index($0, "=") + 1); exit}' \
    "$home/state/.primary-attestation")
  fakebin="$home/fakebin"
  sleep 60 & sleeper=$!
  make_live_owner_ps "$fakebin" grok
  printf '%s\n' "$sleeper" > "$home/state/.lock"
  status=0
  out=$(FM_FAKE_LIVE_PID="$sleeper" FM_PRIMARY_ATTESTATION="$token" \
    run_lock "$home" crewmate-thread "$fakebin" 2>&1) || status=$?
  expect_code 1 "$status" "Codex crewmate must not steal a live Grok primary lock"
  run_hook "$home" SessionEnd crewmate-thread
  [ "$(cat "$home/state/.lock")" = "$sleeper" ] || fail "Codex SessionEnd changed the Grok primary owner"
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  pass "Grok precedence prevents Codex crewmates from stealing or releasing the primary lock"
}

test_non_codex_markers_precede_inherited_thread() {
  local fakebin out marker value
  fakebin="$(make_home marker-precedence)/fakebin"
  make_any_grok_ps "$fakebin"
  for marker in CLAUDECODE PI_CODING_AGENT GROK_AGENT; do
    case "$marker" in
      CLAUDECODE) value=1 ;;
      PI_CODING_AGENT) value=true ;;
      GROK_AGENT) value=1 ;;
    esac
    out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
      "$marker=$value" CODEX_THREAD_ID=inherited-thread PATH="$fakebin:$BASE_PATH" \
      bash -c '. "$1"; fm_session_lock_owner' _ "$ROOT/bin/fm-session-lock-lib.sh")
    case "$out" in ''|*[!0-9]*) fail "$marker inherited Codex ownership: $out" ;; esac
  done
  pass "Claude, Pi, and Grok markers precede inherited Codex threads"
}

test_two_homes_release_only_their_own_lock() {
  local home_a home_b owner_b
  home_a=$(make_home home-a)
  home_b=$(make_home home-b)
  printf '%s\n' '1001|codex:shared-thread|fallback' > "$home_a/state/.lock"
  owner_b='1002|codex:shared-thread|fallback'
  printf '%s\n' "$owner_b" > "$home_b/state/.lock"
  run_hook "$home_a" SessionEnd shared-thread
  [ ! -e "$home_a/state/.lock" ] || fail "home A matching lock was not released"
  [ "$(cat "$home_b/state/.lock")" = "$owner_b" ] || fail "home A release crossed into home B"
  run_hook "$home_b" SessionEnd different-thread
  [ "$(cat "$home_b/state/.lock")" = "$owner_b" ] || fail "mismatched thread released home B"
  pass "independent homes cannot release each other's lock"
}

test_numeric_legacy_lock_contract() {
  local home fakebin sleeper out status owner
  home=$(make_home numeric-legacy)
  fakebin="$home/fakebin"
  sleep 60 & sleeper=$!
  make_live_owner_ps "$fakebin" grok
  printf '%s\n' "$sleeper" > "$home/state/.lock"
  status=0
  out=$(FM_FAKE_LIVE_PID="$sleeper" run_lock "$home" new-thread "$fakebin" 2>&1) || status=$?
  expect_code 1 "$status" "live numeric legacy owner must stay exclusive"
  run_hook "$home" SessionEnd new-thread
  [ "$(cat "$home/state/.lock")" = "$sleeper" ] || fail "SessionEnd removed a numeric legacy owner"

  make_codex_parent_ps "$fakebin"
  FM_FAKE_CODEX_PID="$sleeper" run_lock "$home" same-session "$fakebin" >/dev/null \
    || fail "same session could not upgrade its numeric legacy lock"
  owner=$(cat "$home/state/.lock")
  [ "$owner" = "$sleeper|codex:same-session|harness" ] \
    || fail "numeric legacy lock was not upgraded to the structured owner: $owner"
  printf '%s\n' "$sleeper" > "$home/state/.lock"

  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  make_hidden_ps "$fakebin"
  run_lock "$home" new-thread "$fakebin" >/dev/null || fail "dead numeric legacy owner was not reclaimable"
  pass "numeric legacy locks preserve live exclusion and stale recovery"
}

test_hook_registration_preserves_jt_pretool
test_hooks_work_when_jq_fails
test_matching_session_end_only_releases_regular_exact_owner
test_session_start_retains_verified_harness_owner
test_same_thread_preserves_existing_owner
test_dead_verified_owner_is_reclaimed
test_different_threads_remain_excluded
test_grok_precedence_and_primary_lock_protection
test_non_codex_markers_precede_inherited_thread
test_two_homes_release_only_their_own_lock
test_numeric_legacy_lock_contract
