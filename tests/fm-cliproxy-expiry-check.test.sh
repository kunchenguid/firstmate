#!/usr/bin/env bash
# tests/fm-cliproxy-expiry-check.test.sh - the CLIProxyAPI expiry alarm must wake
# firstmate while a Claude credential is still replaceable, and must not wake it
# on every poll for a condition it already reported. The incident this pins: the
# 2026-10 fall wave, where ten accounts died 27-30 days after login and the pool
# was quietly broken for days because nothing watched that calendar.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-cliproxy-expiry-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-cliproxy-expiry)
AUTH="$TMP_ROOT/auth"
HOME_DIR="$TMP_ROOT/home"
NOW=2026-11-04T12:00:00Z

mkdir -p "$AUTH" "$HOME_DIR/state" "$HOME_DIR/config"

write_registry() {  # <email> <date> [<email> <date> ...]
  python3 - "$HOME_DIR/config/cliproxy-login-registry.json" "$@" <<'PY'
import json
import sys

path = sys.argv[1]
pairs = sys.argv[2:]
data = {"_note": "human login date per Claude account"}
for index in range(0, len(pairs) - 1, 2):
    data[pairs[index]] = pairs[index + 1]
with open(path, "w") as handle:
    json.dump(data, handle)
PY
}

credential() {  # <filename> <json-object>
  printf '%s\n' "$2" > "$AUTH/$1"
}

clear_auth() { rm -f "$AUTH"/claude-*.json; }
clear_state() { rm -f "$HOME_DIR/state/.cliproxy-expiry"; }

# poll prints whatever the check printed; it never inherits the real host's
# credential dir or registry, so this suite can never read a live credential.
poll() {
  env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_CLIPROXY_AUTH_DIR="$AUTH" \
    FM_CLIPROXY_NOW="$NOW" "$CHECK" "$@"
}

# --- a healthy pool is silent and records an empty finding set ---------------

clear_auth
write_registry a@x.com 2026-10-28 b@y.com 2026-10-30
credential claude-1-a@x.com.json \
  '{"email":"a@x.com","last_refresh":"2026-11-04T10:00:00Z","expired":"2026-11-04T18:00:00Z","refresh_token":"r"}'
credential claude-2-b@y.com.json \
  '{"email":"b@y.com","last_refresh":"2026-11-04T09:00:00Z","expired":"2026-11-04T17:00:00Z","refresh_token":"r"}'
out=$(poll check)
[ -z "$out" ] || fail "a healthy pool must wake nobody, got: $out"
assert_present "$HOME_DIR/state/.cliproxy-expiry" "the sweep records its finding set"
assert_contains "$(cat "$HOME_DIR/state/.cliproxy-expiry")" '"identities":[]' \
  "a clear pool records an empty identity set"
pass "healthy pool stays silent"

# --- a stalled refresh wakes once, naming the account, its age, its expiry ---

clear_state
credential claude-2-b@y.com.json \
  '{"email":"b@y.com","last_refresh":"2026-11-03T20:00:00Z","expired":"2026-11-04T04:00:00Z","refresh_token":"r"}'
out=$(poll check)
assert_contains "$out" "cliproxy-expiry:" "a stalled refresh wakes firstmate"
assert_contains "$out" "b@y.com" "the wake names the account"
assert_contains "$out" "refresh-stalled=16h" "the wake names how long the refresh has been stalled"
assert_contains "$out" "expired=2026-11-04" "the wake names the expiry date"
assert_contains "$out" "age=5d" "the wake names the login age"
second=$(poll check)
[ -z "$second" ] || fail "a reported stall must not wake again on the next poll, got: $second"
pass "a stalled refresh wakes once with account, age, and expiry"

# --- the age signal fires before the wall, and its identity follows the login -

clear_state
clear_auth
write_registry a@x.com 2026-10-08 b@y.com 2026-10-28
credential claude-1-a@x.com.json \
  '{"email":"a@x.com","last_refresh":"2026-11-04T11:00:00Z","expired":"2026-11-04T19:00:00Z","refresh_token":"r"}'
credential claude-2-b@y.com.json \
  '{"email":"b@y.com","last_refresh":"2026-11-04T11:00:00Z","expired":"2026-11-04T19:00:00Z","refresh_token":"r"}'
out=$(poll check)
assert_contains "$out" "a@x.com age=27d login=2026-10-08 expires~=2026-11-05" \
  "an old login wakes with age, login date, and the estimated family expiry"
assert_not_contains "$out" "b@y.com" "a young login does not wake"
# The same condition on the next poll is not news.
second=$(poll check)
[ -z "$second" ] || fail "an unchanged age condition must not repeat, got: $second"
# A fresh login makes the condition clear, and its return is news again.
write_registry a@x.com 2026-11-02
poll check >/dev/null
write_registry a@x.com 2026-10-08
third=$(poll check)
assert_contains "$third" "a@x.com age=27d" "a condition that clears and returns is news again"
pass "the login-age signal follows its condition"

# --- a setup token is measured by its own one-year expiry -------------------

clear_state
clear_auth
credential claude-setup-b@y.com.json \
  '{"type":"claude","email":"b@y.com","access_token":"sk-ant-oat01-x","is_setup_token":true,"expired":"2026-11-14T00:00:00Z"}'
out=$(poll check)
assert_contains "$out" "b@y.com expires=2026-11-14" "a setup token inside the warning window wakes"
assert_contains "$out" "(9d left)" "the setup-token warning says how long is left"
assert_not_contains "$out" "refresh-stalled" "a setup token has no refresh, so it is never a stall"
second=$(poll check)
[ -z "$second" ] || fail "an unchanged setup-token expiry must not repeat, got: $second"
pass "a setup token is measured by its own expiry"

# --- an unmeasurable login age is reported, never silently dropped ----------

clear_state
clear_auth
rm -f "$HOME_DIR/config/cliproxy-login-registry.json"
credential claude-1-a@x.com.json \
  '{"email":"a@x.com","last_refresh":"2026-11-04T11:00:00Z","expired":"2026-11-04T19:00:00Z","refresh_token":"r"}'
out=$(poll check)
assert_contains "$out" "login registry" "a missing registry is its own condition"
assert_contains "$out" "is missing" "the wake says the registry is missing"
second=$(poll check)
[ -z "$second" ] || fail "a reported missing registry must not repeat every poll, got: $second"
pass "a missing registry cannot disable the age signal silently"

# --- a disabled credential is not on the calendar --------------------------

clear_state
clear_auth
write_registry a@x.com 2026-10-08
credential claude-1-a@x.com.json \
  '{"email":"a@x.com","disabled":true,"last_refresh":"2026-10-01T00:00:00Z","expired":"2026-10-01T08:00:00Z"}'
out=$(poll check)
[ -z "$out" ] || fail "a disabled credential is not loaded, so it must not wake anyone, got: $out"
pass "a disabled credential is not on the calendar"

# --- no credential at all is itself a condition -----------------------------

clear_state
clear_auth
out=$(poll check)
assert_contains "$out" "no claude-*.json credential is present" "an empty pool wakes firstmate"
pass "an empty pool wakes firstmate"

# --- an absent auth dir is news once, not a wake on every poll --------------

clear_state
out=$(env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_CLIPROXY_AUTH_DIR="$TMP_ROOT/no-such-dir" \
  FM_CLIPROXY_NOW="$NOW" "$CHECK" check)
assert_contains "$out" "auth dir $TMP_ROOT/no-such-dir does not exist" \
  "an armed check with nothing to sweep says so"
second=$(env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_CLIPROXY_AUTH_DIR="$TMP_ROOT/no-such-dir" \
  FM_CLIPROXY_NOW="$NOW" "$CHECK" check)
[ -z "$second" ] || fail "a reported absent auth dir must not repeat, got: $second"
pass "an absent auth dir is reported once"

# --- status reads the whole set and writes no record ------------------------

clear_auth
clear_state
write_registry a@x.com 2026-10-08
credential claude-1-a@x.com.json \
  '{"email":"a@x.com","last_refresh":"2026-11-04T11:00:00Z","expired":"2026-11-04T19:00:00Z","refresh_token":"r"}'
out=$(poll status)
assert_contains "$out" "a@x.com age=27d" "status prints the current finding set"
assert_absent "$HOME_DIR/state/.cliproxy-expiry" "status writes no record"
pass "status reports without waking or recording"

# --- arm and disarm the watcher check --------------------------------------

env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$CHECK" arm >/dev/null \
  || fail "arm must succeed in an owned home"
assert_present "$HOME_DIR/state/cliproxy-expiry.check.sh" "arm writes the watcher shim"
assert_present "$HOME_DIR/state/cliproxy-expiry.check-trust" "arm binds the shim's bytes"
assert_contains "$(cat "$HOME_DIR/state/cliproxy-expiry.check.sh")" "$CHECK check" \
  "the shim dispatches the tracked check"
env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$CHECK" disarm >/dev/null \
  || fail "disarm must succeed"
assert_absent "$HOME_DIR/state/cliproxy-expiry.check.sh" "disarm removes the shim"
assert_absent "$HOME_DIR/state/cliproxy-expiry.check-trust" "disarm removes the trust binding"
assert_absent "$HOME_DIR/state/.cliproxy-expiry" "disarm removes the record"
pass "arm and disarm own the watcher check"

printf 'all fm-cliproxy-expiry-check tests passed\n'
