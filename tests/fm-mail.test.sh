#!/usr/bin/env bash
# Behavior tests for bin/fm-mail.sh.
#
# fm-mail.sh is a network mail client, so these tests exercise only the paths
# that need no real IMAP/SMTP connection: the config-validation dry run, the
# read-only `status` surface, and the CLI usage/help plumbing. All of them go
# through the executable public interface of bin/fm-mail.sh and never assert
# internal source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MAIL="$ROOT/bin/fm-mail.sh"
TMP_ROOT=$(fm_test_tmproot fm-mail)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR"

test_missing_secret_fails_cleanly() {
  local out rc
  env -u FM_MAIL_USER -u FM_MAIL_PASS -u FM_IMAP_HOST -u FM_SMTP_HOST \
    FM_HOME="$HOME_DIR" "$MAIL" status >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  rc=$?
  expect_code 1 "$rc" "status without configuration must fail"
  out=$(cat "$TMP_ROOT/err")
  assert_contains "$out" "FM_MAIL_USER" "missing-config error names the missing variable"
  assert_contains "$out" "FM_MAIL_*" "missing-config error names the configuration family"
  assert_not_contains "$out" "test-pass" "missing-config error never leaks a secret"
  pass "fm-mail: missing required configuration fails cleanly naming the variable"
}

test_status_without_network() {
  local out rc
  out=$(FM_MAIL_USER="test@example.com" FM_MAIL_PASS="test-pass" \
    FM_IMAP_HOST="imap.test.invalid" FM_SMTP_HOST="smtp.test.invalid" \
    FM_HOME="$HOME_DIR" "$MAIL" status 2>&1)
  rc=$?
  expect_code 0 "$rc" "status with configuration must succeed without network"
  assert_contains "$out" "mail account: test@example.com" "status prints the configured account"
  assert_contains "$out" "imap.test.invalid:993" "status prints the configured imap endpoint"
  assert_contains "$out" "smtp.test.invalid:465" "status prints the configured smtp endpoint"
  assert_contains "$out" "cursor:" "status prints the cursor line"
  pass "fm-mail: status succeeds without network and prints configuration"
}

test_help_plumbing() {
  local out rc
  out=$(FM_MAIL_USER="test@example.com" FM_MAIL_PASS="test-pass" \
    FM_IMAP_HOST="imap.test.invalid" FM_SMTP_HOST="smtp.test.invalid" \
    FM_HOME="$HOME_DIR" "$MAIL" --help 2>&1)
  rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "read" "--help lists the read subcommand"
  assert_contains "$out" "send" "--help lists the send subcommand"
  assert_contains "$out" "poll" "--help lists the poll subcommand"
  assert_contains "$out" "status" "--help lists the status subcommand"
  pass "fm-mail: --help prints usage for every subcommand"
}

test_unknown_subcommand_prints_usage() {
  local out rc
  out=$(FM_MAIL_USER="test@example.com" FM_MAIL_PASS="test-pass" \
    FM_IMAP_HOST="imap.test.invalid" FM_SMTP_HOST="smtp.test.invalid" \
    FM_HOME="$HOME_DIR" "$MAIL" bogus 2>&1)
  rc=$?
  expect_code 1 "$rc" "unknown subcommand must exit 1"
  assert_contains "$out" "read" "unknown subcommand prints usage"
  assert_contains "$out" "status" "unknown subcommand prints usage"
  pass "fm-mail: unknown subcommand prints usage and exits non-zero"
}

test_no_secret_leaked_to_status() {
  local out
  out=$(FM_MAIL_USER="test@example.com" FM_MAIL_PASS="test-pass" \
    FM_IMAP_HOST="imap.test.invalid" FM_SMTP_HOST="smtp.test.invalid" \
    FM_HOME="$HOME_DIR" "$MAIL" status 2>&1)
  assert_not_contains "$out" "test-pass" "status must never print the password"
  pass "fm-mail: status never prints the password"
}

test_send_passes_body() {
  local fakebin body_file stdin_file
  fakebin=$(fm_fakebin "$TMP_ROOT")
  stdin_file="$TMP_ROOT/stdin_capture.txt"

  # Fake python3 that reads stdin (the body pipe) and writes it to a file.
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
cat > "${FM_MAIL_TEST_STDIN_FILE:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/python3"

  body_file="$TMP_ROOT/body.txt"
  printf '%s' "hello world" > "$body_file"
  export FM_MAIL_TEST_STDIN_FILE="$stdin_file"
  local out rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=h FM_SMTP_HOST=h \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" send to@example.com subj "hello world" 2>&1) || rc=$?
  expect_code 0 "$rc" "send with body must succeed"
  local captured
  captured=$(cat "$stdin_file" 2>/dev/null || echo "")
  assert_contains "$captured" "hello world" "send passes body through stdin to python3"
  pass "fm-mail: send passes body not empty through stdin"
}

test_poll_error_propagates() {
  local fakebin homedir_bin
  fakebin=$(fm_fakebin "$TMP_ROOT")
  homedir_bin="$HOME_DIR/bin"
  mkdir -p "$homedir_bin"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"

  # Fake python3 that exits with an error (simulating IMAP failure).
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
echo "fm-mail poll error: connection refused" >&2
exit 1
SH
  chmod +x "$fakebin/python3"

  local out rc=0
  out=$(env -u FM_MAIL_USER -u FM_MAIL_PASS -u FM_IMAP_HOST -u FM_SMTP_HOST \
    FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "poll must propagate python3 errors"
  assert_contains "$out" "connection refused" "poll error message is visible"
  pass "fm-mail: poll propagates errors instead of swallowing them"
}

test_poll_dedupes_surfaces_by_uid() {
  local fakebin homedir_bin
  fakebin=$(fm_fakebin "$TMP_ROOT")

  # Fake python3 that emits the mailbox generation guard then one UID'd
  # poll_list line (uidvalidity, uid \t date \t from \t subj).
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t10001\n'
printf '42\t2026-09-05T00:00:00Z\talice@example.com\tHello\n'
SH
  chmod +x "$fakebin/python3"

  # Provide the real wake lib under the temp home so wake_for can append wakes
  # into the temp home's state (never the repo's).
  homedir_bin="$HOME_DIR/bin"
  mkdir -p "$homedir_bin"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"

  local out rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "poll must succeed when python3 lists mail"
  assert_contains "$out" "woke for 42" "first poll wakes the new uid"
  local wakeq="$HOME_DIR/state/.wake-queue"
  assert_contains "$(cat "$wakeq" 2>/dev/null)" "mail from alice@example.com" "wake queue names the sender"
  assert_contains "$(cat "$HOME_DIR/state/.mail-seen" 2>/dev/null)" "42" "cursor records the surfaced uid"

  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "second poll must succeed"
  assert_not_contains "$out" "woke for 42" "re-polling the same uid must not re-wake"
  assert_contains "$out" "no new mail" "second poll reports no new mail"
  pass "fm-mail: poll surfaces each new uid exactly once"
}

test_poll_resurfaces_uid_after_generation_change() {
  local fakebin homedir_bin
  fakebin=$(fm_fakebin "$TMP_ROOT")
  homedir_bin="$HOME_DIR/bin"
  mkdir -p "$homedir_bin"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"

  # First mailbox generation surfaces uid 77 under uidvalidity 30003.
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t30003\n'
printf '77\t2026-09-05T00:00:00Z\talice@example.com\tHello\n'
SH
  chmod +x "$fakebin/python3"

  local out rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "first-generation poll must succeed"
  assert_contains "$out" "woke for 77" "first generation wakes uid 77"

  # Recreated mailbox: same numeric uid 77 under a new UIDVALIDITY.
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t40004\n'
printf '77\t2026-09-06T00:00:00Z\tbob@example.com\tAgain\n'
SH
  chmod +x "$fakebin/python3"

  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "second-generation poll must succeed"
  assert_contains "$out" "woke for 77" "reused uid wakes again under a new generation"
  pass "fm-mail: generation change prevents a reused uid from being suppressed"
}

test_poll_heals_wake_without_cursor_record() {
  local fakebin homedir_bin
  fakebin=$(fm_fakebin "$TMP_ROOT")
  homedir_bin="$HOME_DIR/bin"
  mkdir -p "$homedir_bin"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"

  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t60006\n'
printf '99\t2026-09-05T00:00:00Z\talice@example.com\tHello\n'
SH
  chmod +x "$fakebin/python3"

  # First poll wakes 99 and records it, proving the normal path.
  local out rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "first poll must succeed"
  assert_contains "$out" "woke for 99" "first poll wakes uid 99"

  # Simulate a poll interrupted after its wake append but before its cursor
  # write: remove the uid from the cursor while its wake stays queued.
  printf 'uidvalidity=60006\n' > "$HOME_DIR/state/.mail-seen"

  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "healing poll must succeed"
  assert_not_contains "$out" "woke for 99" "healing poll must not re-wake the queued mail"
  assert_contains "$(cat "$HOME_DIR/state/.mail-seen" 2>/dev/null)" "99" "healing poll restores the cursor record"
  local wakeq
  wakeq=$(grep -c "check: mail 99" "$HOME_DIR/state/.wake-queue" 2>/dev/null || true)
  expect_code 1 "$wakeq" "queued wake is still appended exactly once"
  pass "fm-mail: poll heals a wake whose cursor record was interrupted"
}

test_poll_serializes_overlapping_invocations() {
local fakebin homedir_bin
  fakebin=$(fm_fakebin "$TMP_ROOT")
  homedir_bin="$HOME_DIR/bin"
  mkdir -p "$homedir_bin"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"

  # Fresh-generation fake python3 that pauses so two concurrently started
  # polls genuinely overlap and contend on the cursor.
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
sleep 0.2
printf 'uidvalidity\t50005\n'
printf '88\t2026-09-05T00:00:00Z\talice@example.com\tHello\n'
SH
  chmod +x "$fakebin/python3"

  local combined woke_count
  FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll >"$TMP_ROOT/poll-a.out" 2>&1 &
  FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll >"$TMP_ROOT/poll-b.out" 2>&1 &
  wait

  combined="$(cat "$TMP_ROOT/poll-a.out" "$TMP_ROOT/poll-b.out")"
  woke_count=$(printf '%s' "$combined" | grep -c "woke for 88" || true)
  expect_code 1 "$woke_count" "overlapping polls surface uid 88 exactly once"
  local wakeq
  wakeq=$(grep -c "check: mail 88" "$HOME_DIR/state/.wake-queue" 2>/dev/null || true)
  expect_code 1 "$wakeq" "overlapping polls append exactly one wake for uid 88"
  pass "fm-mail: the poll lock serializes overlapping polls so mail wakes exactly once"
}

test_poll_recovers_journaled_wake_after_ack() {
  local fakebin homedir_bin
  fakebin=$(fm_fakebin "$TMP_ROOT")
  homedir_bin="$HOME_DIR/bin"
  mkdir -p "$homedir_bin"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"

  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t70007\n'
printf '55\t2026-09-05T00:00:00Z\talice@example.com\tHello\n'
SH
  chmod +x "$fakebin/python3"

  local out rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "first poll must succeed"
  assert_contains "$out" "woke for 55" "first poll wakes uid 55"

  # Simulate a poll killed between wake append and cursor record, then the
  # fleet drain acknowledging and consuming that wake: the wake is removed
  # from the queue and the uid is absent from the cursor, but the journal
  # survives.
  printf 'uidvalidity=70007\n' > "$HOME_DIR/state/.mail-seen"
  printf '%s\t%s\n' '70007' '55' > "$HOME_DIR/state/.mail-woken"
  grep -v "check: mail 55" "$HOME_DIR/state/.wake-queue" > "$TMP_ROOT/wakeq.acked" 2>/dev/null || true
  mv "$TMP_ROOT/wakeq.acked" "$HOME_DIR/state/.wake-queue"

  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "recovery poll must succeed"
  assert_not_contains "$out" "woke for 55" "recovery must not re-wake the acked mail"
  assert_contains "$(cat "$HOME_DIR/state/.mail-seen" 2>/dev/null)" "55" "journal heal restores the cursor record"
  local wakeq
  wakeq=$(grep -c "check: mail 55" "$HOME_DIR/state/.wake-queue" 2>/dev/null || true)
  expect_code 0 "$wakeq" "recovery must not append a second wake for uid 55"
  pass "fm-mail: journal recovers a wake the drain already acknowledged"
}

test_poll_legacy_wake_does_not_leak_into_generation() {
  local fakebin homedir_bin
  fakebin=$(fm_fakebin "$TMP_ROOT")
  homedir_bin="$HOME_DIR/bin"
  mkdir -p "$homedir_bin"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"

  # Fresh mailbox generation (uidvalidity 90009) whose uid 42 is currently
  # unseen. A legacy generation-less wake `mail:42` from an earlier era is
  # still queued.
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t90009\n'
printf '42\t2026-09-05T00:00:00Z\talice@example.com\tHello\n'
SH
  chmod +x "$fakebin/python3"
  printf 'uidvalidity=90009\n' > "$HOME_DIR/state/.mail-seen"

  # Seed a legacy wake key (no generation) directly in the wake queue.
  printf '0\t9001\tcheck\tmail:42\tcheck: mail 42 - legacy\n' >> "$HOME_DIR/state/.wake-queue"

  local out rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "poll with a queued legacy wake must succeed"
  assert_contains "$out" "woke for 42" "a reused uid must still wake under the current generation"
  pass "fm-mail: a legacy generation-less wake never marks a reused uid surfaced"
}

test_poll_missing_wake_lib_does_not_suppress() {
  local fakebin miss_home
  fakebin=$(fm_fakebin "$TMP_ROOT")
  miss_home="$TMP_ROOT/misslib-home"
  mkdir -p "$miss_home"
  # No bin/fm-wake-lib.sh in this home: wake_for must fail, not silently
  # succeed and record the uid without a wake.

  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t10010\n'
printf '33\t2026-09-05T00:00:00Z\talice@example.com\tHello\n'
SH
  chmod +x "$fakebin/python3"

  local out rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$miss_home" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "poll must stop when the wake library is missing"
  assert_not_contains "$(cat "$miss_home/state/.mail-seen" 2>/dev/null)" "33" "a failed wake must never be committed to the cursor"
  pass "fm-mail: a missing wake library fails the poll instead of suppressing mail"
}

test_poll_rolls_back_wake_without_durable_record() {
  local fakebin homedir_bin roll_home
  fakebin=$(fm_fakebin "$TMP_ROOT")
  roll_home="$TMP_ROOT/rollback-home"
  mkdir -p "$roll_home"
  homedir_bin="$roll_home/bin"
  mkdir -p "$homedir_bin"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"

  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t90009\n'
printf '66\t2026-09-05T00:00:00Z\nalice@example.com\tHello\n'
SH
  chmod +x "$fakebin/python3"

  # Make both durable evidence writes fail. The wake append still succeeds (the
  # queue is a different, writable file), but the journal and cursor cannot be
  # recorded. The rollback must remove the queued wake so nothing ackable
  # survives without a durable record.
  mkdir -p "$roll_home/state"
  printf 'uidvalidity=90009\n' > "$roll_home/state/.mail-seen"
  : > "$roll_home/state/.mail-woken"
  chmod 0400 "$roll_home/state/.mail-seen" "$roll_home/state/.mail-woken"
  [ -w "$roll_home/state/.mail-seen" ] && { echo "fixture unexpected: cursor still writable"; return 1; }

  local out rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$roll_home" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "poll must fail when no durable record can be written"
  assert_contains "$out" "rolled back" "poll reports the wake was rolled back"
  local wakeq
  wakeq=$(grep -c "check: mail 66" "$roll_home/state/.wake-queue" 2>/dev/null || true)
  expect_code 0 "$wakeq" "rolled-back wake must not stay queued without a durable record"

  # Restore write access: the next poll must surface the mail fresh, exactly
  # once, as if the interrupted attempt never happened.
  chmod 0600 "$roll_home/state/.mail-seen" "$roll_home/state/.mail-woken"
  rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$roll_home" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "retry poll must succeed"
  assert_contains "$out" "woke for 66" "retry poll surfaces the mail exactly once"
  wakeq=$(grep -c "check: mail 66" "$roll_home/state/.wake-queue" 2>/dev/null || true)
  expect_code 1 "$wakeq" "retry poll appends exactly one wake for uid 66"
  pass "fm-mail: a wake with no durable record is rolled back, not left ackable"
}

test_poll_rollback_failure_never_leaves_unrecorded_ackable_wake() {
  local fakebin roll_home
  fakebin=$(fm_fakebin "$TMP_ROOT")
  roll_home="$TMP_ROOT/rollback-failure-home"
  mkdir -p "$roll_home/bin" "$roll_home/state"
  [ -e "$roll_home/bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$roll_home/bin/fm-wake-lib.sh"

  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t90009\n'
printf '88\t2026-09-05T00:00:00Z\talice@example.com\tHello\n'
SH
  chmod +x "$fakebin/python3"

  # Triple-fault fixture: the journal and cursor cannot be written (read-only),
  # and the queue file is write-only so the wake append succeeds but the
  # rollback's awk rewrite cannot read the queue and must fail. No durable
  # record and no queue rewrite can remove the wake row, so the poll must fail
  # closed with an honest report and leave the row for the next poll to heal.
  printf 'uidvalidity=90009\n' > "$roll_home/state/.mail-seen"
  : > "$roll_home/state/.mail-woken"
  : > "$roll_home/state/.wake-queue"
  chmod 0400 "$roll_home/state/.mail-seen" "$roll_home/state/.mail-woken"
  chmod 0200 "$roll_home/state/.wake-queue"
  [ -w "$roll_home/state/.mail-seen" ] && { echo "fixture unexpected: cursor still writable"; return 1; }
  [ -w "$roll_home/state/.wake-queue" ] || { echo "fixture unexpected: queue not appendable"; return 1; }

  local out rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$roll_home" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "poll must fail when the wake can be neither recorded nor rolled back"
  assert_not_contains "$out" "rolled back (journal and cursor writes failed)" "poll must not report a rollback it did not achieve"
  assert_contains "$out" "could not be rolled back or durably recorded" "poll reports the honest rollback-failure outcome"
  assert_not_contains "$(cat "$roll_home/state/.mail-seen" 2>/dev/null)" "88" "a failed wake must never be committed to the cursor"

  # Restore access: the still-queued wake must be healed without re-waking, so
  # the mail surfaces exactly once from the retained row and never duplicates.
  chmod 0600 "$roll_home/state/.mail-seen" "$roll_home/state/.mail-woken"
  chmod 0644 "$roll_home/state/.wake-queue"
  rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$roll_home" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "retry poll must succeed after access is restored"
  assert_contains "$out" "no new mail" "retry poll heals the retained wake without re-waking"
  assert_not_contains "$out" "woke for 88" "retry poll must not surface the mail a second time"
  assert_contains "$(cat "$roll_home/state/.mail-seen")" "88" "retry poll records the retained wake's uid in the cursor"
  local wakeq
  wakeq=$(grep -c "check: mail 88" "$roll_home/state/.wake-queue" 2>/dev/null || true)
  expect_code 1 "$wakeq" "the retained wake row stays queued for the drain exactly once"
  pass "fm-mail: a rollback failure never releases a wake the drain could acknowledge without a durable record"
}

test_poll_skips_unfetchable_uid_but_keeps_progress() {
  local harness out rc=0
  harness="$TMP_ROOT/poll-window-harness.py"
  cat > "$harness" <<'PYEOF'
import os, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
    'FM_MAIL_CURSOR': sys.argv[1],
    'FM_MAIL_POLL_MAX_WAKES': '2',
})
class FakeConn:
    untagged_responses = {'UIDVALIDITY': [b'90009']}
    def __init__(self, *a, **k):
        pass
    def login(self, *a):
        pass
    def select(self, *a):
        return ('OK', [])
    def uid(self, cmd, *args):
        if cmd == 'search':
            return ('OK', [b'1 2 3'])
        if cmd == 'fetch':
            if args[0] == b'1':
                return ('NO', None)  # persistently unfetchable message
            return ('OK', [(b'', b'Subject: good\r\nFrom: a@b.c\r\n\r\n')])
    def logout(self):
        pass
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[2])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(mod.cmd_poll_list())
PYEOF
  printf 'uidvalidity=90009\n' > "$HOME_DIR/state/.mail-seen"
  out=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$ROOT/bin/fm-mail.py" 2>&1) || rc=$?
  expect_code 0 "$rc" "window poll must succeed"
  assert_contains "$out" "uidvalidity	90009" "poll emits the generation guard"
  assert_contains "$out" $'1\t' "the unfetchable uid is still surfaced, not missed"
  assert_contains "$out" $'2\t' "a later uid surfaces despite the failure"
  pass "fm-mail: an unfetchable uid is surfaced degraded and cannot starve later mail"
}

test_poll_caps_wakes_per_run() {
  local fakebin homedir_bin
  fakebin=$(fm_fakebin "$TMP_ROOT")
  homedir_bin="$HOME_DIR/bin"
  mkdir -p "$homedir_bin"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"

  # Three unseen messages with a per-poll cap of two: exactly two wakes this
  # poll, and the third stays unseen so the next poll surfaces it.
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t90009\n'
printf '71\t2026-09-05T00:00:00Z\talice@example.com\tA\n'
printf '72\t2026-09-05T00:00:00Z\talice@example.com\tB\n'
printf '73\t2026-09-05T00:00:00Z\talice@example.com\tC\n'
SH
  chmod +x "$fakebin/python3"
  printf 'uidvalidity=90009\n' > "$HOME_DIR/state/.mail-seen"
  : > "$HOME_DIR/state/.wake-queue"

  local out rc=0 wakeq
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" FM_MAIL_POLL_MAX_WAKES=2 \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "capped poll must succeed"
  assert_contains "$out" "woke for 71" "first message wakes within the cap"
  assert_contains "$out" "woke for 72" "second message wakes within the cap"
  assert_not_contains "$out" "woke for 73" "third message must not wake in a capped poll"
  assert_contains "$out" "per-poll wake cap" "poll reports the cap"
  wakeq=$(grep -c "check: mail" "$HOME_DIR/state/.wake-queue" 2>/dev/null || true)
  expect_code 2 "$wakeq" "the durable wake queue holds exactly the capped wakes"

  # The third message is still unseen: the next poll surfaces it.
  rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" FM_MAIL_POLL_MAX_WAKES=2 \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "follow-up poll must succeed"
  assert_contains "$out" "woke for 73" "deferred message wakes on the next poll"
  pass "fm-mail: per-poll wake cap bounds the durable queue without missing mail"
}

test_poll_sanitizes_header_fields() {
  local fakebin homedir_bin
  fakebin=$(fm_fakebin "$TMP_ROOT")
  homedir_bin="$HOME_DIR/bin"
  mkdir -p "$homedir_bin"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"

  # A subject containing a literal tab and a subject containing a literal
  # newline must not split the poll row or inject a fake uid line.
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t90009\n'
printf '60\t2026-09-05T00:00:00Z\talice@example.com\tTab\there\n'
printf '61\t2026-09-05T00:00:00Z\talice@example.com\tLine\nBreak\n'
SH
  chmod +x "$fakebin/python3"
  printf 'uidvalidity=90009\n' > "$HOME_DIR/state/.mail-seen"
  : > "$HOME_DIR/state/.wake-queue"

  local out rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "sanitizing poll must succeed"
  assert_contains "$out" "woke for 60" "tab-bearing subject still wakes once"
  assert_contains "$out" "woke for 61" "newline-bearing subject still wakes once"
  pass "fm-mail: poll sanitizes tabs and newlines in header fields"
}

test_poll_bounded_fetch_progresses_large_backlog() {
  local fakebin homedir_bin
  fakebin=$(fm_fakebin "$TMP_ROOT")
  homedir_bin="$HOME_DIR/bin"
  mkdir -p "$homedir_bin"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"

  # Fake python3 emulating the bounded poll_list: read FM_MAIL_CURSOR, return
  # only uids not already recorded in the cursor, capped at the poll cap. Five
  # unseen messages with a cap of two must progress two per poll and finish
  # cleanly, never stalling on the already-surfaced head of a large backlog.
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
cursor="$FM_MAIL_CURSOR"
cap="${FM_MAIL_POLL_MAX_WAKES:-20}"
seen=""
[ -f "$cursor" ] && seen="$(grep -v '^uidvalidity=' "$cursor" 2>/dev/null || true)"
printf 'uidvalidity\t90009\n'
count=0
for u in 91 92 93 94 95; do
  if printf '%s\n' "$seen" | grep -Fqx "$u"; then continue; fi
  [ "$count" -ge "$cap" ] && break
  printf '%s\t2026-09-05T00:00:00Z\talice@example.com\tM\n' "$u"
  count=$((count + 1))
done
SH
  chmod +x "$fakebin/python3"
  printf 'uidvalidity=90009\n' > "$HOME_DIR/state/.mail-seen"
  : > "$HOME_DIR/state/.wake-queue"

  local out rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" FM_MAIL_POLL_MAX_WAKES=2 \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "first bounded poll must succeed"
  assert_contains "$out" "woke for 91" "first batch surfaces 91"
  assert_contains "$out" "woke for 92" "first batch surfaces 92"

  rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" FM_MAIL_POLL_MAX_WAKES=2 \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "second bounded poll must succeed"
  assert_contains "$out" "woke for 93" "second batch surfaces 93"
  assert_contains "$out" "woke for 94" "second batch surfaces 94"

  rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" FM_MAIL_POLL_MAX_WAKES=2 \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "third bounded poll must succeed"
  assert_contains "$out" "woke for 95" "tail batch surfaces 95"
  assert_not_contains "$out" "woke for 91" "already-surfaced mail never re-wakes"
  pass "fm-mail: bounded fetch makes progress through a large backlog without re-surfacing mail"
}

test_missing_secret_fails_cleanly
test_env_overrides_env_file() {
  local env_home out
  env_home="$TMP_ROOT/envfile-home"
  mkdir -p "$env_home"
  cat > "$env_home/.env" <<'EOF'
FM_MAIL_USER=fromfile@example.com
FM_MAIL_PASS=filepass
FM_IMAP_HOST=imap.file.invalid
FM_SMTP_HOST=smtp.file.invalid
EOF
  # No environment: .env supplies the configuration.
  out=$(FM_HOME="$env_home" "$MAIL" status 2>&1)
  assert_contains "$out" "mail account: fromfile@example.com" "status uses .env when environment is unset"
  # A single environment value wins for that key; the other keys still come
  # from .env, matching the Relay/FMX "env wins over .env" contract.
  out=$(FM_MAIL_USER=fromenv@example.com FM_HOME="$env_home" "$MAIL" status 2>&1)
  assert_contains "$out" "mail account: fromenv@example.com" "environment overrides .env for a direct invocation"
  pass "fm-mail: environment values override the .env file"
}
test_status_without_network
test_env_overrides_env_file
test_help_plumbing
test_unknown_subcommand_prints_usage
test_no_secret_leaked_to_status
test_send_passes_body
test_poll_error_propagates
test_poll_dedupes_surfaces_by_uid
test_poll_resurfaces_uid_after_generation_change
test_poll_heals_wake_without_cursor_record
test_poll_serializes_overlapping_invocations
test_poll_recovers_journaled_wake_after_ack
test_poll_legacy_wake_does_not_leak_into_generation
test_poll_missing_wake_lib_does_not_suppress
test_poll_rolls_back_wake_without_durable_record
test_poll_rollback_failure_never_leaves_unrecorded_ackable_wake
test_poll_caps_wakes_per_run
test_poll_sanitizes_header_fields
test_poll_bounded_fetch_progresses_large_backlog
test_poll_skips_unfetchable_uid_but_keeps_progress
