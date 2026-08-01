#!/usr/bin/env bash
# Behavior tests for the boot recovery scan, dedupe, and unit installer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-reboot-sweep)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FIXTURE_HOME="$TMP_ROOT/firstmate-home"
FIXTURE_STATE="$FIXTURE_HOME/state"
FIXTURE_UNITS="$TMP_ROOT/systemd-user"
FAKE_LOG="$TMP_ROOT/fake.log"
TMUX_STATE="$TMP_ROOT/bizmate.running"
BOOT_ID_FILE="$TMP_ROOT/boot-id"
mkdir -p "$FIXTURE_STATE" "$FIXTURE_UNITS"
: > "$FAKE_LOG"
printf '%s\n' 'fm-bug-006-test-boot' > "$BOOT_ID_FILE"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'herdr' >> "$FM_REBOOT_TEST_LOG"
printf ' <%s>' "$@" >> "$FM_REBOOT_TEST_LOG"
printf '\n' >> "$FM_REBOOT_TEST_LOG"
case "${1:-} ${2:-}" in
  "api snapshot")
    jq -nc --arg cwd "$FM_HOME" '{result:{snapshot:{agents:[{agent:"claude",cwd:$cwd,focused:true,pane_id:"primary-pane"}]}}}'
    ;;
  "pane read")
    case "${3:-}" in
      secondmate-pane) printf '%s\n' 'accept edits on' ;;
      *) exit 1 ;;
    esac
    ;;
  "pane send-text"|"pane send-keys")
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

cat > "$FAKEBIN/systemctl" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'systemctl' >> "$FM_REBOOT_TEST_LOG"
printf ' <%s>' "$@" >> "$FM_REBOOT_TEST_LOG"
printf '\n' >> "$FM_REBOOT_TEST_LOG"
case " $* " in
  *" is-failed "*) exit 1 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/systemctl"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'tmux' >> "$FM_REBOOT_TEST_LOG"
printf ' <%s>' "$@" >> "$FM_REBOOT_TEST_LOG"
printf '\n' >> "$FM_REBOOT_TEST_LOG"
case "${1:-}" in
  has-session) [ -f "$FM_REBOOT_TEST_TMUX_STATE" ] ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/tmux"

cat > "$FAKEBIN/bizmate-start" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' 'bizmate-start' >> "$FM_REBOOT_TEST_LOG"
: > "$FM_REBOOT_TEST_TMUX_STATE"
SH
chmod +x "$FAKEBIN/bizmate-start"

cat > "$FIXTURE_STATE/mate-one.meta" <<'META'
kind=secondmate
harness=claude
backend=herdr
window=default:secondmate-pane
META

run_recovery() {
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$FIXTURE_HOME" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_REBOOT_BOOT_ID_FILE="$BOOT_ID_FILE" \
    FM_REBOOT_BIZMATE_START="$FAKEBIN/bizmate-start" \
    FM_REBOOT_SYSTEMCTL="$FAKEBIN/systemctl" \
    FM_REBOOT_TMUX="$FAKEBIN/tmux" \
    FM_REBOOT_WATCHER_CONFIRM=0 \
    FM_REBOOT_TEST_LOG="$FAKE_LOG" \
    FM_REBOOT_TEST_TMUX_STATE="$TMUX_STATE" \
    "$ROOT/bin/fm-reboot-sweep.sh" --recover
}

assert_eq_local() {
  local expected=$1 actual=$2 message=$3
  [ "$actual" = "$expected" ] || fail "$message (expected '$expected', got '$actual')"
}

test_authority_classifier() {
  local out
  out=$(printf '%s\n' 'bypass permissions on' | "$ROOT/bin/fm-reboot-sweep.sh" --classify-authority) \
    || fail "bypass authority classification failed"
  assert_eq_local 'healthy:bypass-permissions' "$out" "bypass permissions must be healthy"

  out=$(printf '%s\n' 'accept edits on' | "$ROOT/bin/fm-reboot-sweep.sh" --classify-authority) \
    || fail "accept-edits classification failed"
  assert_eq_local 'broken:accept-edits' "$out" "accept edits must be broken"

  out=$(printf '%s\n' 'auto mode' | "$ROOT/bin/fm-reboot-sweep.sh" --classify-authority) \
    || fail "auto-mode classification failed"
  assert_eq_local 'broken:auto-mode' "$out" "auto mode must be broken"

  out=$(printf '%s\n' 'manual mode' | "$ROOT/bin/fm-reboot-sweep.sh" --classify-authority) \
    || fail "manual-mode classification failed"
  assert_eq_local 'broken:manual-mode' "$out" "manual mode must be broken"

  out=$(printf '%s\n' 'accept edits on' 'bypass permissions on' \
    | "$ROOT/bin/fm-reboot-sweep.sh" --classify-authority) \
    || fail "last-mode classification failed"
  assert_eq_local 'healthy:bypass-permissions' "$out" "the last rendered mode must win"
  pass "fm-reboot-sweep: authority mode classification distinguishes bypass from broken modes"
}

test_recovery_repairs_only_safe_boot_dependencies_and_dedupes_nudge() {
  local first second send_count enter_count start_count
  : > "$FAKE_LOG"
  rm -f "$TMUX_STATE"
  first=$(run_recovery) || fail "first recovery run failed"
  second=$(run_recovery) || fail "repeated recovery run failed"

  assert_contains "$first" 'nudge=sent' "first recovery did not send its primary nudge"
  assert_contains "$second" 'nudge=deduped' "repeated recovery did not dedupe its primary nudge"
  assert_contains "$(cat "$FAKE_LOG")" 'herdr <pane> <read> <secondmate-pane>' \
    "recovery did not inspect the registered secondmate pane"
  assert_contains "$(cat "$FAKE_LOG")" 'mate-one(default:secondmate-pane=accept-edits)' \
    "primary nudge did not surface the broken secondmate authority and explicit target"

  send_count=$(grep -c '^herdr <pane> <send-text> <primary-pane>' "$FAKE_LOG" || true)
  enter_count=$(grep -c '^herdr <pane> <send-keys> <primary-pane> <enter>' "$FAKE_LOG" || true)
  assert_eq_local 1 "$send_count" "repeated recovery sent more than one primary nudge"
  assert_eq_local 1 "$enter_count" "repeated recovery submitted more than one primary nudge"

  start_count=$(grep -c '^bizmate-start$' "$FAKE_LOG" || true)
  assert_eq_local 1 "$start_count" "Bizmate restart was not idempotent"
  assert_contains "$(cat "$FAKE_LOG")" '<start> <--no-block> <fm-boot-watcher.service>' \
    "stale watcher recovery did not start the dedicated backstop unit"
  assert_not_contains "$(cat "$FAKE_LOG")" 'herdr <pane> <send-text> <secondmate-pane>' \
    "timer recovery must never send repair input to a secondmate"
  assert_not_contains "$(cat "$FAKE_LOG")" '<--secondmate>' \
    "timer recovery must never respawn a secondmate"
  assert_not_contains "$(cat "$FAKE_LOG")" '<--channels>' \
    "boot recovery must never start a channels session"
  pass "fm-reboot-sweep: stale watcher and Bizmate repair are safe while the primary nudge is exactly-once"
}

test_installer_generates_private_user_units() {
  local log
  : > "$FAKE_LOG"
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$FIXTURE_HOME" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_REBOOT_SYSTEMD_USER_DIR="$FIXTURE_UNITS" \
    FM_REBOOT_SYSTEMCTL="$FAKEBIN/systemctl" \
    FM_REBOOT_BIZMATE_START="$FAKEBIN/bizmate-start" \
    FM_REBOOT_TEST_LOG="$FAKE_LOG" \
    "$ROOT/bin/fm-install-boot-recovery.sh" >/dev/null \
    || fail "boot recovery unit installation failed"

  assert_present "$FIXTURE_UNITS/fm-boot-recovery.timer" "installer omitted the boot timer"
  assert_present "$FIXTURE_UNITS/fm-boot-recovery.service" "installer omitted the recovery service"
  assert_present "$FIXTURE_UNITS/fm-boot-watcher.service" "installer omitted the watcher backstop service"
  assert_contains "$(cat "$FIXTURE_UNITS/fm-boot-recovery.timer")" 'OnBootSec=2min' \
    "boot timer does not wait for restored sessions"
  assert_contains "$(cat "$FIXTURE_UNITS/fm-boot-recovery.service")" \
    "ExecStart=\"$ROOT/bin/fm-reboot-sweep.sh\" --recover" \
    "recovery service does not invoke the versioned sweep"
  assert_contains "$(cat "$FIXTURE_UNITS/fm-boot-watcher.service")" \
    "ExecStart=\"$ROOT/bin/fm-watch-arm.sh\"" \
    "watcher unit does not use the tracked arm owner"
  log=$(cat "$FAKE_LOG")
  assert_contains "$log" '<--user> <daemon-reload>' "installer did not reload the user unit manager"
  assert_contains "$log" '<--user> <enable> <--now> <fm-boot-recovery.timer>' \
    "installer did not enable the timer"
  assert_not_contains "$(cat "$FIXTURE_UNITS"/*)" 'firstmate-telegram' \
    "boot units must not enable or replace the disabled Telegram service"
  assert_not_contains "$(cat "$FIXTURE_UNITS"/*)" '--channels' \
    "boot units must never start a channels session"
  pass "fm-install-boot-recovery: generated user units are boot-scoped and preserve Telegram isolation"
}

test_authority_classifier
test_recovery_repairs_only_safe_boot_dependencies_and_dedupes_nudge
test_installer_generates_private_user_units
