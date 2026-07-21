#!/usr/bin/env bash
# Behavior tests for the multi-account dispatch pool selector.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pool-tests)
mkdir -p "$TMP_ROOT"
POOL="$ROOT/bin/fm-pool.sh"

# Each test gets its own home so rotation cursors and cooldowns never leak.
new_home() {
  local home
  home=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
  mkdir -p "$home/state" "$home/config" "$home/keys"
  printf '%s\n' "$home"
}

pool() {
  local home=$1
  shift
  FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" \
  FM_CONFIG_OVERRIDE="$home/config" \
  FM_POOL_KEY_DIR="$home/keys" \
    "$POOL" "$@"
}

write_config() {
  cat > "$1/config/dispatch-pool.json" <<'JSON'
{
  "cooldown_default_seconds": 3600,
  "backends": [
    { "id": "claude-1", "harness": "claude", "env": { "CLAUDE_CONFIG_DIR": "~/.claude" } },
    { "id": "claude-2", "harness": "claude", "env": { "CLAUDE_CONFIG_DIR": "~/.claude-2" } },
    { "id": "cursor-1", "harness": "cursor", "key_env": "CURSOR_API_KEY" },
    { "id": "cursor-2", "harness": "cursor", "key_env": "CURSOR_API_KEY" }
  ]
}
JSON
}

chosen() {
  pool "$1" select 2>/dev/null | sed -n 's/^backend=//p'
}

test_absent_config_is_inert() {
  local home out status
  home=$(new_home)
  set +e
  out=$(pool "$home" select 2>&1)
  status=$?
  set -e
  [ "$status" -eq 3 ] || fail "absent config should exit 3, got $status"
  case "$out" in
    *"no dispatch pool configured"*) ;;
    *) fail "absent config should say the pool is unconfigured, got: $out" ;;
  esac
  [ ! -e "$home/state/.pool-cursor" ] || fail "absent config must not write a rotation cursor"
  pass "an absent config leaves the pool inert and writes no state"
}

test_equal_round_robin() {
  local home got=()
  home=$(new_home)
  write_config "$home"
  printf 'k\n' > "$home/keys/cursor-1.key"
  printf 'k\n' > "$home/keys/cursor-2.key"
  for _ in 1 2 3 4 5 6 7 8; do
    got+=("$(chosen "$home")")
  done
  local joined
  joined=$(printf '%s ' "${got[@]}")
  [ "$joined" = "claude-1 claude-2 cursor-1 cursor-2 claude-1 claude-2 cursor-1 cursor-2 " ] \
    || fail "expected equal round-robin over all four, got: $joined"
  pass "select round-robins equally across every healthy backend"
}

test_cooldown_is_visibly_skipped() {
  local home err first second
  home=$(new_home)
  write_config "$home"
  printf 'k\n' > "$home/keys/cursor-1.key"
  printf 'k\n' > "$home/keys/cursor-2.key"
  pool "$home" cooldown claude-2 --seconds 600 --reason 'usage credits exhausted' >/dev/null
  first=$(chosen "$home")
  [ "$first" = claude-1 ] || fail "first pick should be claude-1, got $first"
  err=$(pool "$home" select 2>&1 >/dev/null)
  second=$(pool "$home" select 2>/dev/null | sed -n 's/^backend=//p')
  case "$err" in
    *"skipping claude-2: cooling"*) ;;
    *) fail "a cooling backend must be reported as skipped, got: $err" ;;
  esac
  [ "$second" != claude-2 ] || fail "a cooling backend must never be selected"
  pass "a backend in cooldown is skipped and the skip is reported with its reason"
}

test_cooldown_expires_on_its_own() {
  local home f until later got
  home=$(new_home)
  write_config "$home"
  printf 'k\n' > "$home/keys/cursor-1.key"
  printf 'k\n' > "$home/keys/cursor-2.key"
  pool "$home" cooldown claude-1 --seconds 600 --reason 'session limit' >/dev/null
  f="$home/state/.pool-cooldown-claude-1"
  [ -f "$f" ] || fail "cooldown file should exist"
  until=$(sed -n 's/^until=//p' "$f")
  # No manual clear: simply being past `until` must expire it.
  later=$((until + 1))
  got=$(FM_POOL_NOW="$later" pool "$home" status | grep '^claude-1' || true)
  case "$got" in
    *ready*) ;;
    *) fail "an elapsed cooldown should read ready, got: $got" ;;
  esac
  [ ! -f "$f" ] || fail "an elapsed cooldown file should be removed by the reader, not left for manual clearing"
  pass "cooldowns expire on their own and are cleaned up without manual intervention"
}

test_session_limit_string_parses_its_reset() {
  local home out epoch reason
  home=$(new_home)
  write_config "$home"
  out=$(printf "You've hit your session limit \xc2\xb7 resets 2:20pm (America/Los_Angeles)\n" | pool "$home" detect)
  case "$out" in
    *"limit=session-limit"*) ;;
    *) fail "session limit string should classify as session-limit, got: $out" ;;
  esac
  epoch=$(printf '%s\n' "$out" | sed -n 's/^reset_epoch=//p')
  [ -n "$epoch" ] || fail "session limit string carries a reset time and it should be parsed"
  case "$epoch" in *[!0-9]*) fail "reset_epoch should be epoch seconds, got: $epoch" ;; esac
  [ "$epoch" -gt "$(date +%s)" ] || fail "a parsed reset should be in the future, got: $epoch"
  reason=$(printf '%s\n' "$out" | sed -n 's/^reason=//p')
  [ -n "$reason" ] || fail "detect should carry a human reason"
  pass "a session-limit string parses its reset time into a future epoch"
}

test_credits_exhausted_uses_default_interval() {
  local home out epoch until now
  home=$(new_home)
  write_config "$home"
  out=$(printf 'Fast mode disabled \xc2\xb7 usage credits exhausted\n' | pool "$home" detect)
  case "$out" in
    *"limit=credits-exhausted"*) ;;
    *) fail "credits string should classify as credits-exhausted, got: $out" ;;
  esac
  epoch=$(printf '%s\n' "$out" | sed -n 's/^reset_epoch=//p')
  [ -z "$epoch" ] || fail "credits-exhausted carries no reset time, got: $epoch"
  now=$(date +%s)
  printf 'Fast mode disabled \xc2\xb7 usage credits exhausted\n' | pool "$home" cooldown claude-1 --from-stdin >/dev/null
  until=$(sed -n 's/^until=//p' "$home/state/.pool-cooldown-claude-1")
  # cooldown_default_seconds is 3600 in the fixture; allow slack for clock drift.
  [ "$((until - now))" -ge 3500 ] && [ "$((until - now))" -le 3700 ] \
    || fail "absent reset should fall back to cooldown_default_seconds, got $((until - now))s"
  pass "a limit with no reset time falls back to the configured default interval"
}

test_missing_or_empty_key_disables_with_a_reason() {
  local home status_out
  home=$(new_home)
  write_config "$home"
  printf 'k\n' > "$home/keys/cursor-1.key"
  : > "$home/keys/cursor-2.key"
  rm -f "$home/keys/cursor-1.key"
  printf '   \n' > "$home/keys/cursor-1.key"
  status_out=$(pool "$home" status)
  case "$status_out" in
    *"cursor-1     cursor   nokey"*) ;;
    *) fail "a blank key file should read nokey, got: $status_out" ;;
  esac
  case "$status_out" in
    *"key file is empty"*) ;;
    *) fail "a blank key file should state why, got: $status_out" ;;
  esac
  rm -f "$home/keys/cursor-2.key"
  status_out=$(pool "$home" status)
  case "$status_out" in
    *"no key file at"*) ;;
    *) fail "a missing key file should state the path, got: $status_out" ;;
  esac
  # Neither case is a crash: selection still succeeds on the Claude accounts.
  [ "$(chosen "$home")" = claude-1 ] || fail "keyless backends must not break selection"
  pass "a missing or empty key file disables that backend with a clear reason, never a crash"
}

test_all_cooling_reports_earliest_reset() {
  local home status err soonest
  home=$(new_home)
  write_config "$home"
  printf 'k\n' > "$home/keys/cursor-1.key"
  printf 'k\n' > "$home/keys/cursor-2.key"
  pool "$home" cooldown claude-1 --seconds 7200 >/dev/null
  pool "$home" cooldown claude-2 --seconds 600 >/dev/null
  pool "$home" cooldown cursor-1 --seconds 3600 >/dev/null
  pool "$home" cooldown cursor-2 --seconds 3600 >/dev/null
  set +e
  err=$(pool "$home" select 2>&1 >/dev/null)
  status=$?
  set -e
  [ "$status" -eq 4 ] || fail "all-cooling should exit 4, got $status"
  case "$err" in
    *"every backend is cooling down"*) ;;
    *) fail "all-cooling should say so plainly, got: $err" ;;
  esac
  soonest=$(printf '%s\n' "$err" | grep -o 'earliest reset is [a-z0-9-]*' | head -1)
  [ "$soonest" = "earliest reset is claude-2" ] \
    || fail "all-cooling should name the soonest-resetting backend, got: $soonest"
  pass "when every backend is cooling, select refuses and names the earliest reset"
}

test_select_never_emits_key_material() {
  local home out secret
  home=$(new_home)
  write_config "$home"
  secret='sk-super-secret-value-do-not-leak'
  printf '%s\n' "$secret" > "$home/keys/cursor-1.key"
  printf '%s\n' "$secret" > "$home/keys/cursor-2.key"
  pool "$home" select >/dev/null 2>&1
  pool "$home" select >/dev/null 2>&1
  out=$(pool "$home" select 2>&1; pool "$home" status 2>&1; pool "$home" resolve cursor-1 2>&1)
  case "$out" in
    *"$secret"*) fail "the pool must never print key material" ;;
  esac
  case "$out" in
    *"key_file=$home/keys/cursor-1.key"*) ;;
    *) fail "the pool should emit the key PATH so the caller can expand it at launch, got: $out" ;;
  esac
  pass "the selector emits key paths, never key contents"
}

test_resolve_refuses_an_unhealthy_backend() {
  local home status out
  home=$(new_home)
  write_config "$home"
  printf 'k\n' > "$home/keys/cursor-1.key"
  printf 'k\n' > "$home/keys/cursor-2.key"
  [ "$(pool "$home" resolve cursor-1 | sed -n 's/^backend=//p')" = cursor-1 ] \
    || fail "resolve should return the named healthy backend"
  pool "$home" cooldown cursor-1 --seconds 600 >/dev/null
  set +e
  out=$(pool "$home" resolve cursor-1 2>&1)
  status=$?
  set -e
  [ "$status" -eq 4 ] || fail "resolve of a cooling backend should exit 4, got $status"
  case "$out" in
    *"is cooling"*) ;;
    *) fail "resolve should state why it refused, got: $out" ;;
  esac
  pass "resolve pins a named account but still refuses an unhealthy one"
}

test_disabled_backend_is_never_selected() {
  local home got
  home=$(new_home)
  cat > "$home/config/dispatch-pool.json" <<'JSON'
{
  "backends": [
    { "id": "claude-1", "harness": "claude" },
    { "id": "claude-2", "harness": "claude", "enabled": false }
  ]
}
JSON
  for _ in 1 2 3; do
    got=$(chosen "$home")
    [ "$got" = claude-1 ] || fail "an explicitly disabled backend must never be selected, got $got"
  done
  pass "an explicitly disabled backend is never selected"
}

test_absent_config_is_inert
test_equal_round_robin
test_cooldown_is_visibly_skipped
test_cooldown_expires_on_its_own
test_session_limit_string_parses_its_reset
test_credits_exhausted_uses_default_interval
test_missing_or_empty_key_disables_with_a_reason
test_all_cooling_reports_earliest_reset
test_select_never_emits_key_material
test_resolve_refuses_an_unhealthy_backend
test_disabled_backend_is_never_selected

echo "# all fm-pool tests passed"
