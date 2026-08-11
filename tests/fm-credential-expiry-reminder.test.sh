#!/usr/bin/env bash
# Executable-boundary tests for bootstrap's metadata-only credential expiry
# reminder.  Each case owns an isolated FM_HOME and supplies an epoch clock, so
# no credential file, external auth surface, or wall clock participates.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-credential-expiry-reminder-tests)
FIXTURE="$ROOT/tests/fixtures/credential-expiry-reminders/ci-pr-credential.json"
REAL_NODE=$(command -v node) || fail "node is required for credential expiry reminder tests"
trap fm_test_cleanup EXIT

make_fake_toolchain() { # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux gh-axi chrome-devtools-axi lavish-axi
  cat > "$fakebin/node" <<SH
#!/usr/bin/env bash
exec "$REAL_NODE" "\$@"
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
fi
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' '0.1.1' ;;
  update) printf '%s\n' '  --archive-body' ;;
  mv) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...]' ;;
esac
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.16'
fi
SH
  chmod +x "$fakebin/node" "$fakebin/gh" "$fakebin/treehouse" "$fakebin/no-mistakes" "$fakebin/tasks-axi" "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

make_home() { # <name>
  local root="$TMP_ROOT/$1/root" home="$TMP_ROOT/$1/home"
  mkdir -p "$home/config" "$home/state"
  git init -q -b main "$root"
  git -C "$root" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q --allow-empty -m init
  printf '%s\n' "$root" > "$home/.test-root"
  printf '%s\n' manual > "$home/config/backlog-backend"
  printf '%s\n' tmux > "$home/config/backend"
  printf '%s\n' "$home"
}

bootstrap() { # <home> <fakebin> <now>
  PATH="$2:$BASE_PATH" FM_HOME="$1" FM_ROOT_OVERRIDE="$(cat "$1/.test-root")" \
    FM_CREDENTIAL_EXPIRY_REMINDER_NOW="$3" "$ROOT/bin/fm-bootstrap.sh"
}

install_fixture() { # <home>
  cp "$FIXTURE" "$1/config/credential-expiry-reminders.json"
}

test_future_and_absent_metadata_stay_silent() {
  local home fakebin out
  home=$(make_home future)
  fakebin=$(make_fake_toolchain "$TMP_ROOT/future")
  out=$(bootstrap "$home" "$fakebin" 1788220800)
  [ -z "$out" ] || fail "absent reminder metadata changed bootstrap output: $out"
  install_fixture "$home"
  out=$(bootstrap "$home" "$fakebin" 1787011200)
  [ -z "$out" ] || fail "expiry beyond the warning horizon surfaced: $out"
  [ ! -e "$home/state/credential-expiry-reminders" ] || fail "silent future metadata created reminder state"
  pass "absent and future expiry metadata preserve silent bootstrap behavior"
}

test_near_expiry_persists_and_deduplicates_across_restarts() {
  local home fakebin out state
  home=$(make_home near)
  fakebin=$(make_fake_toolchain "$TMP_ROOT/near")
  install_fixture "$home"
  out=$(bootstrap "$home" "$fakebin" 1788220800)
  [ "$out" = 'CREDENTIAL_EXPIRY_REMINDER: ci-pr-credential expires 2026-09-09T00:00:00Z (in 8d 0h); update config/credential-expiry-reminders.json' ] \
    || fail "near expiry diagnostic was not dated and actionable: $out"
  state=$(find "$home/state/credential-expiry-reminders" -type f -name '*.state' -print)
  [ -n "$state" ] || fail "near expiry did not persist bounded surfacing state"
  assert_not_contains "$(cat "$state")" 'token' "state must never contain credential material"
  out=$(bootstrap "$home" "$fakebin" 1788224400)
  [ -z "$out" ] || fail "routine restart ignored persisted reminder dedupe: $out"
  pass "near expiry surfaces once and survives a fresh bootstrap process"
}

test_changed_date_and_safety_cadence_resurface() {
  local home fakebin out
  home=$(make_home changed)
  fakebin=$(make_fake_toolchain "$TMP_ROOT/changed")
  install_fixture "$home"
  bootstrap "$home" "$fakebin" 1788220800 >/dev/null
  printf '%s\n' '{"version":1,"reminders":[{"label":"ci-pr-credential","expiresAt":"2026-09-10T00:00:00Z"}]}' > "$home/config/credential-expiry-reminders.json"
  out=$(bootstrap "$home" "$fakebin" 1788224400)
  assert_contains "$out" 'expires 2026-09-10T00:00:00Z' "a changed expiry date did not bypass the dedupe throttle"
  out=$(bootstrap "$home" "$fakebin" 1788829200)
  assert_contains "$out" 'expires 2026-09-10T00:00:00Z' "reminder did not re-surface on its seven-day safety cadence"
  pass "changed dates surface immediately and unchanged metadata re-surfaces on cadence"
}

test_expired_metadata_is_urgent_not_auth_validation() {
  local home fakebin out
  home=$(make_home expired)
  fakebin=$(make_fake_toolchain "$TMP_ROOT/expired")
  install_fixture "$home"
  out=$(bootstrap "$home" "$fakebin" 1788912000)
  assert_contains "$out" 'CREDENTIAL_EXPIRY_REMINDER_EXPIRED: ci-pr-credential expired 2026-09-09T00:00:00Z (0h 0m ago)' \
    "expired metadata did not use the urgent diagnostic"
  assert_contains "$out" 'metadata only - not credential validation' \
    "expired metadata implied an unproven credential rejection"
  pass "expired metadata is urgent without becoming a credential validation claim"
}

test_malformed_metadata_fails_loudly_without_state() {
  local home fakebin out
  home=$(make_home malformed)
  fakebin=$(make_fake_toolchain "$TMP_ROOT/malformed")
  printf '%s\n' '{"version":1,"reminders":[{"label":"ci token","expiresAt":"2026-09-09T00:00:00Z"}]}' > "$home/config/credential-expiry-reminders.json"
  out=$(bootstrap "$home" "$fakebin" 1788220800)
  assert_contains "$out" 'CREDENTIAL_EXPIRY_REMINDER: invalid config/credential-expiry-reminders.json' \
    "malformed metadata did not fail loudly"
  [ ! -e "$home/state/credential-expiry-reminders" ] || fail "malformed metadata created surfacing state"
  pass "malformed reminder metadata fails safely before any state write"
}

test_linked_metadata_and_state_are_rejected_without_following_them() {
  local home fakebin out source state
  home=$(make_home linked)
  fakebin=$(make_fake_toolchain "$TMP_ROOT/linked")
  source="$home/fixture.json"
  cp "$FIXTURE" "$source"
  ln "$source" "$home/config/credential-expiry-reminders.json"
  out=$(bootstrap "$home" "$fakebin" 1788220800)
  assert_contains "$out" 'must not be hardlinked' "hardlinked reminder metadata was accepted"
  [ ! -e "$home/state/credential-expiry-reminders" ] || fail "hardlinked metadata created reminder state"

  rm "$home/config/credential-expiry-reminders.json"
  install_fixture "$home"
  bootstrap "$home" "$fakebin" 1788220800 >/dev/null
  state=$(find "$home/state/credential-expiry-reminders" -type f -name '*.state' -print)
  rm "$state"
  ln -s "$home/untrusted-state" "$state"
  out=$(bootstrap "$home" "$fakebin" 1788224400)
  assert_contains "$out" 'invalid reminder state for ci-pr-credential' "linked state was followed instead of rejected"
  pass "linked metadata and reminder state fail closed"
}

test_future_and_absent_metadata_stay_silent
test_near_expiry_persists_and_deduplicates_across_restarts
test_changed_date_and_safety_cadence_resurface
test_expired_metadata_is_urgent_not_auth_validation
test_malformed_metadata_fails_loudly_without_state
test_linked_metadata_and_state_are_rejected_without_following_them

echo '# fm-credential-expiry-reminder.test.sh: all assertions passed'
