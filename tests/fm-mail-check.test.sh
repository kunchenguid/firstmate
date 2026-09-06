#!/usr/bin/env bash
# Behavior tests for bin/fm-mail-check.sh, the standing received-mail check.
#
# Two surfaces are exercised through their executable interfaces:
#
#   * arming/disarming state/mail.check.sh with its trust binding, including
#     the refusal paths (symlink at the shim path, missing mail plane);
#
#   * the `check` action itself, which runs the real fm-mail.sh poll against a
#     scratch home whose .env and fake python3 decide the outcome. The cases
#     that matter are the reporting contract: a healthy poll is silent (the
#     poll still surfaces new mail itself as durable wakes), a failing poll
#     reports one line, and the same story is reported once until it changes.
#
# No case ever contacts a real IMAP or SMTP server.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-mail-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-mail-check)

# Pin the watcher bound and clear any ambient mail config so the poll's
# readiness decision comes from the fixture .env alone. The check binary is an
# explicit argument so the missing-mail-plane case runs a copy without fm-mail.sh.
run_check() {
  local home=$1 out=$2 check=$3
  shift 3
  local status=0
  env -u FM_MAIL_USER -u FM_MAIL_PASS -u FM_IMAP_HOST -u FM_SMTP_HOST \
    -u FM_MAIL_CHECK_BUDGET \
    FM_CHECK_TIMEOUT=30 \
    "$@" FM_HOME="$home" PATH="$FAKEBIN:$PATH" \
    "$check" check >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
}

# make_home <name>: a scratch home without a mail plane yet.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# write_env <home>: the four FM_MAIL_* values the poll requires.
write_env() {
  local home=$1
  printf '%s\n' \
    'FM_MAIL_USER=test@example.invalid' \
    'FM_MAIL_PASS=test-pass' \
    'FM_IMAP_HOST=imap.test.invalid' \
    'FM_SMTP_HOST=smtp.test.invalid' > "$home/.env"
}

# enter_mailbox <home> <mailbox-generator-command...>: wires the scratch home's
# bin to the real wake library and FAKEBIN to a python3 running <cmd> so a poll
# against this home can surface and durably record a wake.
enter_mailbox() {
  local home=$1 generator=$2
  mkdir -p "$home/bin" "$FAKEBIN"
  [ -e "$home/bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$home/bin/fm-wake-lib.sh"
  printf '%s\n' "$generator" > "$FAKEBIN/python3"
  chmod +x "$FAKEBIN/python3"
}

FAKEBIN="$TMP_ROOT/fakebin"

test_help_and_usage() {
  local out rc=0
  out=$("$CHECK" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "check" "--help lists the check action"
  assert_contains "$out" "arm" "--help lists the arm action"
  assert_contains "$out" "disarm" "--help lists the disarm action"
  rc=0
  out=$("$CHECK" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown action must exit 2"
  assert_contains "$out" "unknown action" "unknown action is refused loudly"
  pass "fm-mail-check: help and usage plumbing"
}

test_arm_writes_and_binds_the_check_and_disarm_removes_it() {
  local home out
  home=$(make_home arm)
  write_env "$home"
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || fail "arm must succeed: $out"
  assert_contains "$out" "armed: state/mail.check.sh" "arm names the shim it wrote"
  assert_present "$home/state/mail.check.sh" "arm writes the check shim"
  assert_present "$home/state/mail.check-trust" "arm binds the shim for the watcher"
  assert_contains "$(cat "$home/state/mail.check.sh")" "fm-mail-check.sh check" "shim dispatches the check action"
  assert_contains "$(cat "$home/state/mail.check.sh")" "FM_HOME=$home" "shim pins the absolute home"

  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || fail "re-arm must succeed: $out"
  assert_contains "$out" "armed" "re-arm stays armed"

  out=$(FM_HOME="$home" "$CHECK" disarm 2>&1) || fail "disarm must succeed: $out"
  assert_absent "$home/state/mail.check.sh" "disarm removes the check shim"
  assert_absent "$home/state/mail.check-trust" "disarm removes the trust binding"
  assert_absent "$home/state/.mail-check" "disarm removes the report record"
  pass "fm-mail-check: arm writes and binds, re-arm is idempotent, disarm removes"
}

test_arm_resolves_a_relative_home_into_the_shim() {
  local home rel out
  home=$(make_home relative)
  write_env "$home"
  rel="$(basename "$home")"
  out=$(cd "$TMP_ROOT" && env FM_HOME="$rel" "$CHECK" arm 2>&1) || fail "arm with a relative FM_HOME must succeed: $out"
  assert_contains "$(cat "$home/state/mail.check.sh")" "export FM_HOME=$home" "the shim pins the resolved absolute home, not the relative spelling"
  pass "fm-mail-check: arm resolves a relative home into the shim"
}

test_arm_refuses_a_symlink_at_the_shim_path() {
  local home target out rc=0
  home=$(make_home symlink)
  write_env "$home"
  target="$TMP_ROOT/outside"
  mkdir -p "$target"
  printf '#!/usr/bin/env bash\n' > "$target/mail.check.sh"
  ln -s "$target/mail.check.sh" "$home/state/mail.check.sh"
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must refuse a symlink at the shim path"
  assert_contains "$out" "could not write" "arm reports the shim write failure"
  assert_absent "$home/state/mail.check-trust" "no trust binding is left behind by a refused arm"
  pass "fm-mail-check: arm refuses a symlink at the shim path"
}

test_arm_refuses_without_the_mail_plane() {
  local tmpbin home out rc=0
  # A copy of the check tool with no fm-mail.sh beside it is a home whose mail
  # plane has not landed yet: arming must refuse instead of delegating silence.
  tmpbin="$TMP_ROOT/plane/bin"
  home="$TMP_ROOT/plane/home"
  mkdir -p "$tmpbin" "$home/state"
  cp "$ROOT/bin/fm-mail-check.sh" "$tmpbin/"
  for lib in fm-timeout-lib.sh fm-pr-lib.sh fm-line-cap-lib.sh fm-check-lib.sh; do
    [ -e "$tmpbin/$lib" ] || ln -s "$ROOT/bin/$lib" "$tmpbin/$lib"
  done
  out=$(FM_HOME="$home" "$tmpbin/fm-mail-check.sh" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must refuse when the mail plane is missing"
  assert_contains "$out" "mail plane is missing" "arm names the missing plane"
  assert_absent "$home/state/mail.check.sh" "a refused arm writes no shim"
  pass "fm-mail-check: arm refuses without the mail plane"
}

test_successful_poll_is_silent_and_new_mail_still_surfaces() {
  local home out wakeq
  home=$(make_home success)
  write_env "$home"
  enter_mailbox "$home" \
    'printf "uidvalidity\\t20002\\n"
printf "42\\t2026-09-05T00:00:00Z\\talice@example.com\\tHello\\n"'
  out="$home/out.txt"
  run_check "$home" "$out" "$CHECK"
  [ ! -s "$out" ] || fail "a healthy poll must print nothing: $(cat "$out")"
  assert_present "$home/state/.mail-check" "a healthy poll records its outcome"
  assert_contains "$(cat "$home/state/.mail-check")" "fm-mail-check-v1" "the record carries its schema"
  assert_not_contains "$(cat "$home/state/.mail-check")" "reported=mail:" "the healthy record carries no reported finding"
  wakeq="$home/state/.wake-queue"
  assert_contains "$(cat "$wakeq" 2>/dev/null)" "mail from alice@example.com" "the check-run poll still surfaces new mail as a durable wake"
  assert_contains "$(cat "$home/state/.mail-seen" 2>/dev/null)" "42" "the check-run poll still advances the inbox cursor"
  pass "fm-mail-check: healthy poll stays silent while the poll still surfaces new mail"
}

test_failure_is_reported_once_until_it_changes() {
  local home out
  home=$(make_home failure)
  write_env "$home"
  enter_mailbox "$home" \
    'printf "fm-mail poll error: connection refused\\n" >&2
exit 1'

  out="$home/out.txt"
  run_check "$home" "$out" "$CHECK"
  assert_contains "$(cat "$out")" "mail: fm-mail poll error: connection refused" "a failing poll reports its cause in one line"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "a failing poll reports exactly one line: $(cat "$out")"

  out="$home/out2.txt"
  run_check "$home" "$out" "$CHECK"
  [ ! -s "$out" ] || fail "the same failure must not be reported again: $(cat "$out")"
  assert_contains "$(cat "$home/state/.mail-check")" "reported=fm-mail poll error: connection refused" "the record carries the reported finding"

  # A healthy poll clears the record, so the next failure is news again.
  enter_mailbox "$home" \
    'printf "uidvalidity\\t20003\\n"'
  out="$home/out3.txt"
  run_check "$home" "$out" "$CHECK"
  [ ! -s "$out" ] || fail "a recovered poll must stay silent: $(cat "$out")"

  enter_mailbox "$home" \
    'printf "fm-mail poll error: connection refused\\n" >&2
exit 1'
  out="$home/out4.txt"
  run_check "$home" "$out" "$CHECK"
  assert_contains "$(cat "$out")" "mail: fm-mail poll error: connection refused" "a failure after a healthy poll is news again"
  pass "fm-mail-check: a poll failure is reported once and re-reported after recovery"
}

test_unconfigured_home_is_reported_once() {
  local home out
  home=$(make_home unconfigured)
  # No .env: the poll names the missing value, and the check turns that into
  # its one line instead of leaving an armed channel quiet.
  out="$home/out.txt"
  run_check "$home" "$out" "$CHECK"
  assert_contains "$(cat "$out")" "mail: missing required" "an unconfigured home reports the missing setup"
  assert_contains "$(cat "$out")" "FM_MAIL_USER" "the report names the missing variable"
  out="$home/out2.txt"
  run_check "$home" "$out" "$CHECK"
  [ ! -s "$out" ] || fail "the unconfigured state must not repeat: $(cat "$out")"
  pass "fm-mail-check: an unconfigured home is reported once, not every poll"
}

test_slow_poll_times_out_and_is_reported() {
  local home out
  home=$(make_home slow)
  write_env "$home"
  enter_mailbox "$home" \
    'sleep 6'
  out="$home/out.txt"
  run_check "$home" "$out" "$CHECK" FM_MAIL_CHECK_BUDGET=5
  assert_contains "$(cat "$out")" "mail: poll did not finish within the 5s budget" "a poll past its budget is reported, not ignored"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "a poll timeout reports exactly one line: $(cat "$out")"
  pass "fm-mail-check: a slow poll times out into a one-line report"
}

test_fail_closed_poll_after_wake_reports_the_failure() {
  # A poll can publish a wake and then fail closed (stale retry still on disk
  # and unwritable). The standing check must report that failure, not the
  # earlier success-wake line, or the news key hides the real condition.
  local home out
  home=$(make_home fail-closed-after-wake)
  write_env "$home"
  enter_mailbox "$home" \
    'printf "uidvalidity\\t90009\\n"
printf "77\\t2026-09-05T00:00:00Z\\tfrom@x\\tHello\\tok\\n"'
  printf 'uidvalidity=90009\n' > "$home/state/.mail-seen"
  printf '77\n' > "$home/state/.mail-retry"
  chmod 0000 "$home/state/.mail-retry"
  out="$home/out.txt"
  run_check "$home" "$out" "$CHECK"
  chmod 0600 "$home/state/.mail-retry"
  assert_contains "$(cat "$out")" "mail: could not clear retry for recovered 77 after publish" "a fail-closed poll after a wake reports the failure"
  assert_not_contains "$(cat "$out")" "woke for 77" "the standing check must not treat the success-wake line as the failure"
  assert_contains "$(cat "$home/state/.mail-check")" "reported=could not clear retry for recovered 77 after publish" "the news key is the failure, not the wake"
  pass "fm-mail-check: a fail-closed poll after a wake reports the failure, not the wake"
}

test_missing_mail_plane_is_reported() {
  local tmpbin home out check_bin
  tmpbin="$TMP_ROOT/plane2/bin"
  home="$TMP_ROOT/plane2/home"
  mkdir -p "$tmpbin" "$home/state"
  check_bin="$tmpbin/fm-mail-check.sh"
  cp "$ROOT/bin/fm-mail-check.sh" "$tmpbin/"
  for lib in fm-timeout-lib.sh fm-pr-lib.sh fm-line-cap-lib.sh fm-check-lib.sh; do
    [ -e "$tmpbin/$lib" ] || ln -s "$ROOT/bin/$lib" "$tmpbin/$lib"
  done
  out="$home/out.txt"
  run_check "$home" "$out" "$check_bin"
  assert_contains "$(cat "$out")" "mail: fm-mail.sh is missing next to this check" "a home lacking the mail plane reports it"
  pass "fm-mail-check: a missing mail plane is reported, not assumed"
}

test_help_and_usage
test_arm_writes_and_binds_the_check_and_disarm_removes_it
test_arm_resolves_a_relative_home_into_the_shim
test_arm_refuses_a_symlink_at_the_shim_path
test_arm_refuses_without_the_mail_plane
test_successful_poll_is_silent_and_new_mail_still_surfaces
test_failure_is_reported_once_until_it_changes
test_unconfigured_home_is_reported_once
test_slow_poll_times_out_and_is_reported
test_fail_closed_poll_after_wake_reports_the_failure
test_missing_mail_plane_is_reported