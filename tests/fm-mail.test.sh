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

test_whitespace_only_required_settings_fail() {
  local name
  for name in FM_MAIL_USER FM_MAIL_PASS FM_IMAP_HOST FM_SMTP_HOST; do
    if env FM_HOME="$HOME_DIR" FM_MAIL_USER=test FM_MAIL_PASS=pass \
      FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test "$name=   " "$MAIL" status \
      >"$TMP_ROOT/whitespace.out" 2>&1; then
      fail "status accepted whitespace-only $name"
    fi
  done
  pass "fm-mail: whitespace-only required settings fail cleanly"
}

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
  assert_not_contains "$(cat "$HOME_DIR/state/.mail-seen" 2>/dev/null)" $'\t' \
    "heal must record only the uid, not a tagged journal field, into the cursor"
  pass "fm-mail: poll surfaces each new uid exactly once"
}

test_poll_records_ignored_and_deferred_without_waking() {
  local fakebin ignored_home out rc=0 wakeq cursor retry
  fakebin=$(fm_fakebin "$TMP_ROOT")
  ignored_home="$TMP_ROOT/ignored-status-home"
  mkdir -p "$ignored_home/bin" "$ignored_home/state"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$ignored_home/bin/fm-wake-lib.sh"
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t54321\n'
if [ -e "$FM_HOME/returned" ]; then
  printf '41\t\tattacker@example.com\tforged\tok\n'
else
  printf '41\t\tjohnpoyser@gmail.com\tforged\tignored\n'
fi
printf '42\t\t(unverified sender)\t\tdeferred\n'
printf '43\t\tjohnpoyser@gmail.com\tverified\tok\n'
SH
  chmod +x "$fakebin/python3"

  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$ignored_home" PATH="$fakebin:$PATH" "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "poll with ignored and deferred rows must succeed"
  assert_contains "$out" "woke for 43" "authenticated owner mail remains wakeable"
  assert_not_contains "$out" "woke for 41" "forged sender is never woken"
  assert_not_contains "$out" "woke for 42" "unverified sender is never woken"
  cursor=$(cat "$ignored_home/state/.mail-seen")
  assert_not_contains "$cursor" "41" "away-ignored uid remains unseen for attended polling"
  assert_contains "$cursor" "42" "unverified uid is durably cursor-recorded"
  retry=$(cat "$ignored_home/state/.mail-retry")
  assert_contains "$retry" "42" "unverified uid remains retryable without a wake"
  wakeq=$(cat "$ignored_home/state/.wake-queue")
  assert_contains "$wakeq" "mail from johnpoyser@gmail.com - verified" "only accepted owner mail reaches the wake queue"
  assert_not_contains "$wakeq" "forged" "forged From never reaches the wake queue"
  assert_not_contains "$wakeq" "unverified" "unverified mail never reaches the wake queue"

  touch "$ignored_home/returned"
  rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$ignored_home" PATH="$fakebin:$PATH" "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "attended poll after return must succeed"
  assert_contains "$out" "woke for 41" "mail ignored while away is reported after return"
  assert_not_contains "$out" "woke for 43" "already surfaced owner mail never re-wakes"
  assert_contains "$(cat "$ignored_home/state/.mail-seen")" "41" "attended delivery records the formerly ignored uid"
  wakeq=$(cat "$ignored_home/state/.wake-queue")
  assert_contains "$wakeq" "mail from attacker@example.com - forged" "attended polling reports the message after away filtering ends"
  pass "fm-mail: away-ignored mail remains unseen and surfaces after return"
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

test_poll_duplicate_wakes_on_interrupted_poll() {
  # A poll killed after the wake row was appended but before the journal or
  # cursor was written leaves the uid only in the durable queue. The next poll
  # must record the uid from that queued key, not surface the mail again.
  local fakebin homedir_bin interrupted_home out rc=0 wakeq
  fakebin=$(fm_fakebin "$TMP_ROOT")
  interrupted_home="$TMP_ROOT/interrupted-home"
  homedir_bin="$interrupted_home/bin"
  mkdir -p "$homedir_bin" "$interrupted_home/state"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"

  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity	80008\n'
printf '33\t2026-09-05T00:00:00Z\talice@example.com\tHello\n'
SH
  chmod +x "$fakebin/python3"

  # First poll appends the wake and writes the evidence.
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$interrupted_home" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "first poll must succeed"
  assert_contains "$out" "woke for 33" "first poll wakes uid 33"
  assert_contains "$(cat "$interrupted_home/state/.mail-woken" 2>/dev/null)" "80008" \
    "first poll writes the journal generation"
  assert_contains "$(cat "$interrupted_home/state/.mail-woken" 2>/dev/null)" "33" \
    "first poll writes the journal uid"

  # Simulate a kill between the queue append and the evidence writes: keep the
  # queued wake row, but drop both journal and cursor records.
  printf 'uidvalidity=80008\n' > "$interrupted_home/state/.mail-seen"
  : > "$interrupted_home/state/.mail-woken"
  wakeq=$(grep -c "check: mail 33" "$interrupted_home/state/.wake-queue" 2>/dev/null || true)
  expect_code 1 "$wakeq" "the wake row survived the simulated interruption"

  rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$interrupted_home" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "healing poll must succeed"
  assert_not_contains "$out" "woke for 33" "healing poll must not duplicate the queued mail"
  assert_contains "$(cat "$interrupted_home/state/.mail-seen" 2>/dev/null)" "33" \
    "healing poll records the uid from the queued wake key"
  wakeq=$(grep -c "check: mail 33" "$interrupted_home/state/.wake-queue" 2>/dev/null || true)
  expect_code 1 "$wakeq" "the queued wake row stays appended exactly once"
  pass "fm-mail: a poll interrupted before evidence writes does not duplicate on recovery"
}

test_poll_acknowledged_wake_evading_recovery() {
  # A poll killed after the journal was written but before the cursor, followed
  # by the drain acknowledging the wake, leaves the uid only in the journal.
  # The next poll must record the uid from the journal and clear the journal,
  # never re-waking the mail.
  local fakebin homedir_bin acked_home out rc=0 wakeq
  fakebin=$(fm_fakebin "$TMP_ROOT")
  acked_home="$TMP_ROOT/acked-home"
  homedir_bin="$acked_home/bin"
  mkdir -p "$homedir_bin" "$acked_home/state"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"

  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t90009\n'
printf '44\t2026-09-05T00:00:00Z\talice@example.com\tHello\n'
SH
  chmod +x "$fakebin/python3"

  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$acked_home" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "first poll must succeed"
  assert_contains "$out" "woke for 44" "first poll wakes uid 44"

  # Simulate: journal survived, cursor did not, and the drain consumed the wake.
  printf 'uidvalidity=90009\n' > "$acked_home/state/.mail-seen"
  printf '%s\t%s\n' '90009' '44' > "$acked_home/state/.mail-woken"
  grep -v "check: mail 44" "$acked_home/state/.wake-queue" > "$TMP_ROOT/wakeq.acked" 2>/dev/null || true
  mv "$TMP_ROOT/wakeq.acked" "$acked_home/state/.wake-queue"

  rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$acked_home" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "recovery poll must succeed"
  assert_not_contains "$out" "woke for 44" "recovery must not re-wake the acknowledged mail"
  assert_contains "$(cat "$acked_home/state/.mail-seen" 2>/dev/null)" "44" \
    "journal heal records the acknowledged uid in the cursor"
  assert_equals "" "$(cat "$acked_home/state/.mail-woken" 2>/dev/null)" \
    "journal is cleared once every uid is durably recorded"
  wakeq=$(grep -c "check: mail 44" "$acked_home/state/.wake-queue" 2>/dev/null || true)
  expect_code 0 "$wakeq" "recovery must not append a second wake for uid 44"
  pass "fm-mail: an acknowledged wake whose cursor record was lost is recovered from the journal"
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
  local fakebin miss_home miss_bin
  fakebin=$(fm_fakebin "$TMP_ROOT")
  miss_home="$TMP_ROOT/misslib-home"
  miss_bin="$TMP_ROOT/misslib-bin"
  mkdir -p "$miss_home" "$miss_bin"
  # Hide the script-relative wake library: poll sources fm-wake-lib.sh from
  # next to fm-mail.sh, not from $FM_HOME/bin. Copy only the plane scripts.
  cp "$ROOT/bin/fm-mail.sh" "$miss_bin/fm-mail.sh"
  cp "$ROOT/bin/fm-mail.py" "$miss_bin/fm-mail.py"
  chmod +x "$miss_bin/fm-mail.sh"

  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t10010\n'
printf '33\t2026-09-05T00:00:00Z\talice@example.com\tHello\n'
SH
  chmod +x "$fakebin/python3"

  local out rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$miss_home" PATH="$fakebin:$PATH" \
    "$miss_bin/fm-mail.sh" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "poll must stop when the wake library is missing"
  assert_contains "$out" "fm-wake-lib.sh missing" "missing-lib error names the wake library"
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

write_away_poll_harness() {
  cat > "$1" <<'PYEOF'
import json
import os
import sys
import time
from io import StringIO
from contextlib import redirect_stderr, redirect_stdout

scenario, state_dir, mail_py = sys.argv[1:4]
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.gmail.com', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
    'FM_MAIL_CURSOR': os.path.join(state_dir, 'seen'),
    'FM_MAIL_RETRY': os.path.join(state_dir, 'retry'),
    'FM_MAIL_AWAY_SCAN': os.path.join(state_dir, 'away-scan'),
    'FM_MAIL_POLL_MAX_WAKES': '20', 'FM_AFK_POSTURE': '1',
})
with open(os.environ['FM_MAIL_CURSOR'], 'w') as f:
    f.write('uidvalidity=777\n')
open(os.environ['FM_MAIL_RETRY'], 'w').close()
owner = 'johnpoyser@gmail.com'
auth = 'Authentication-Results: mx.google.com; dkim=pass header.d=gmail.com\r\n'
body = b'From: johnpoyser@gmail.com\r\nSubject: reply\r\n\r\nFM-AFK-REPLY test answer'
slow = {}
search_delay = 0
body_failures = {}
header_failures = {}
if scenario in ('header-fail', 'header-outage'):
    uids = ['1', '2']
    authentic = {'2'}
    header_failures = {'1': 99}
    os.environ['FM_MAIL_POLL_BUDGET'] = '1'
elif scenario in ('transient', 'permanent', 'handoff-timeout', 'handoff-fails', 'config-outage'):
    uids = ['1', '2', '3']
    authentic = {'1', '2'}
    body_failures = {'1': 1 if scenario == 'transient' else (99 if scenario == 'permanent' else 0)}
    os.environ['FM_MAIL_POLL_BUDGET'] = '1'
elif scenario == 'spoofed':
    uids = [str(u) for u in range(1, 27)]
    authentic = {'26'}
elif scenario == 'retry':
    uids = ['5', '6']
    authentic = {'6'}
    with open(os.environ['FM_MAIL_CURSOR'], 'a') as f:
        f.write('5\n')
    with open(os.environ['FM_MAIL_RETRY'], 'w') as f:
        f.write('5\n')
else:
    os.environ['FM_MAIL_POLL_BUDGET'] = '1'
    uids = [str(u) for u in range(1, 11)]
    authentic = {'1'}
    if scenario == 'slow':
        slow = {u: 0.4 for u in uids[1:]}
    elif scenario == 'hang':
        slow = {'2': 30}
    elif scenario == 'search-hang':
        search_delay = 30

class FakeSock:
    timeouts = []
    def settimeout(self, value):
        self.timeouts.append(value)

class FakeConn:
    untagged_responses = {'UIDVALIDITY': [b'777']}
    searches = []
    header_fetches = []
    body_fetches = []
    other_commands = []
    connect_timeouts = []
    def __init__(self):
        self.sock = FakeSock()
    def login(self, *args): pass
    def select(self, *args): return ('OK', [])
    def uid(self, command, *args):
        if command == 'search':
            self.searches.append(args)
            if search_delay:
                time.sleep(search_delay)
            return ('OK', [' '.join(uids).encode()])
        if command != 'fetch' or 'PEEK' not in args[1]:
            self.other_commands.append((command, args))
        uid, spec = args
        number = uid.decode()
        if 'HEADER' in spec:
            self.header_fetches.append(number)
            if header_failures.get(number, 0) > 0:
                header_failures[number] -= 1
                return ('NO', [])
            if slow.get(number):
                time.sleep(slow[number])
            extra = auth if number in authentic else ''
            header = f'From: {owner}\r\n{extra}Subject: mail {number}\r\n\r\n'.encode()
            return ('OK', [(f'RFC822.SIZE {len(body)}'.encode(), header)])
        self.body_fetches.append(number)
        if body_failures.get(number, 0) > 0:
            body_failures[number] -= 1
            return ('NO', [])
        return ('OK', [(f'RFC822.SIZE {len(body)}'.encode(), body)])
    def store(self, *args):
        self.other_commands.append(('store', args))
    def logout(self): pass

import imaplib
def fake_imap(*args, **kwargs):
    FakeConn.connect_timeouts.append(kwargs.get('timeout'))
    return FakeConn()
imaplib.IMAP4_SSL = fake_imap
import subprocess
handoffs = []
handoff_timeouts = []
def fake_run(*args, **kwargs):
    if kwargs.get('input'):
        handoff_timeouts.append(kwargs.get('timeout'))
        if scenario == 'handoff-timeout' and len(handoff_timeouts) == 1:
            raise subprocess.TimeoutExpired(args[0], kwargs['timeout'])
        if scenario == 'handoff-fails' and len(handoff_timeouts) <= 4:
            return type('Result', (), {'returncode': 1, 'stdout': '', 'stderr': ''})()
        handoffs.extend(message['uid'] for message in json.loads(kwargs['input']))
    return type('Result', (), {'returncode': 0, 'stdout': '', 'stderr': ''})()
subprocess.run = fake_run
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', mail_py)
mail = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mail)
mail.afk_record_field = lambda name: 'email' if name == 'reach_channels' else '1700000000'
alerts = []
mail.send_message = lambda to, subj, text, timeout=None: alerts.append((to, subj, text))

def poll(away, recipient=owner):
    """Run one poll and, like fm-mail.sh, record surfaced non-ignored rows in the cursor."""
    mail.afk_email_context = (lambda: (recipient, True, False)) if away else (lambda: (None, False, False))
    FakeConn.header_fetches.clear()
    output, error = StringIO(), StringIO()
    started = time.monotonic()
    with redirect_stdout(output), redirect_stderr(error):
        rc = mail.cmd_poll_list()
    elapsed = time.monotonic() - started
    rows = [line.split('\t') for line in output.getvalue().splitlines()[1:]]
    with open(os.environ['FM_MAIL_CURSOR'], 'a') as cursor:
        for row in rows:
            if row[4] not in ('ignored', 'retry'):
                cursor.write(row[0] + '\n')
    staged = os.environ['FM_MAIL_AWAY_SCAN'] + '.next'
    if os.path.exists(staged):
        os.replace(staged, os.environ['FM_MAIL_AWAY_SCAN'])
    return rc, rows, list(FakeConn.header_fetches), elapsed, error.getvalue()

def status(rows):
    return ','.join(f'{row[0]}:{row[4]}' for row in rows)

if scenario in ('transient', 'handoff-timeout'):
    rc, rows, first, _, _ = poll(True)
    print(f'first rc={rc} rows={status(rows)} handoffs={handoffs}')
    rc, rows, second, _, _ = poll(True)
    print(f'second rc={rc} fetched={",".join(second)} handoffs={handoffs} alerts={len(alerts)}')
    print('handoff_timeouts_bounded=%s' % all(0 < t <= 2 for t in handoff_timeouts))
elif scenario == 'handoff-fails':
    for _ in range(5):
        rc, rows, fetched, _, _ = poll(True)
        assert rc == 0, rc
    print(f'handoffs={sorted(set(handoffs))} alerts={len(alerts)}')
elif scenario == 'config-outage':
    rc, rows, first, _, _ = poll(True, None)
    print(f'outage rows={status(rows)} handoffs={handoffs}')
    rc, rows, second, _, _ = poll(True)
    print(f'restored fetched={",".join(second)} handoffs={handoffs}')
elif scenario == 'header-outage':
    fetched_total = []
    for recipient in (None, None, None, None, owner, owner):
        rc, rows, fetched, _, _ = poll(True, recipient)
        assert rc == 0, rc
        fetched_total += fetched
        if recipient is None:
            print(f'outage alerts={len(alerts)}')
    print(f'header_fetches={fetched_total.count("1")} alerts={len(alerts)} to={alerts[0][0] if alerts else ""}')
    print('alert_says_check_gmail=%s' % (
        len(alerts) == 1 and 'check gmail' in alerts[0][2].lower()))
elif scenario == 'header-fail':
    fetched_total = []
    for _ in range(4):
        rc, rows, fetched, _, _ = poll(True)
        assert rc == 0, rc
        fetched_total += fetched
    print(f'header_fetches={fetched_total.count("1")} alerts={len(alerts)}')
    print('alert_says_check_gmail=%s' % (
        len(alerts) == 1 and 'one message could not be read' in alerts[0][1].lower()
        and 'check gmail' in alerts[0][2].lower()
    ))
    print('alert_content_safe=%s' % all(
        secret not in value
        for _, subject, text in alerts
        for value in (subject, text)
        for secret in (owner, 'mail 1', 'FM-AFK-REPLY', 'test answer')
    ))
elif scenario == 'permanent':
    fetched_total = []
    for _ in range(4):
        rc, rows, fetched, _, _ = poll(True)
        assert rc == 0, rc
        fetched_total += fetched
    print(f'handoffs={handoffs} owner_fetches={fetched_total.count("1")} spoof_fetches={fetched_total.count("3")}')
    print(f'alerts={len(alerts)} to={alerts[0][0] if alerts else ""}')
    print(f'alert_has_body={any("FM-AFK-REPLY" in text or "test answer" in text for _, _, text in alerts)}')
elif scenario == 'spoofed':
    fetched_total = []
    polls = 0
    while polls < 4 and '26' not in handoffs:
        rc, rows, fetched, _, _ = poll(True)
        assert rc == 0, rc
        fetched_total += fetched
        polls += 1
    print(f'polls={polls} handoffs={handoffs}')
    print('max_spoofed_fetches=%d' % max(fetched_total.count(u) for u in uids if u not in authentic))
    rc, rows, fetched, _, _ = poll(True)
    print(f'away_repoll_fetches={len(fetched)}')
    rc, rows, fetched, _, _ = poll(False)
    print('attended_ok=%s' % status(rows))
    print('searches=%s' % sorted(set(FakeConn.searches)))
    print(f'unread_preserved={not FakeConn.other_commands}')
elif scenario == 'retry':
    rc, rows, first, _, _ = poll(True)
    print(f'first={status(rows)} fetched={",".join(first)} handoffs={handoffs}')
    rc, rows, second, _, _ = poll(True)
    print(f'second_fetched={",".join(second)}')
elif scenario == 'search-hang':
    rc, rows, fetched, elapsed, error = poll(True)
    print(f'rc={rc} bounded={elapsed < 2.5} fetched={len(fetched)}')
    print(error, end='')
else:
    rc, rows, first, elapsed, _ = poll(True)
    print(f'first rc={rc} bounded={elapsed < 2.5} handoffs={handoffs} rows={status(rows)} fetched={",".join(first)}')
    print('timeouts_bounded=%s' % all(t <= 1 for t in FakeSock.timeouts + FakeConn.connect_timeouts))
    slow.clear()
    rc, rows, second, _, _ = poll(True)
    print(f'second rc={rc} fetched={",".join(second)} rows={status(rows)}')
PYEOF
}

run_away_poll_harness() {
  local state="$TMP_ROOT/away-$1-state"
  mkdir -p "$state"
  python3 "$TMP_ROOT/away-poll-harness.py" "$1" "$state" "$ROOT/bin/fm-mail.py" 2>&1
}

test_away_spoofed_owner_backlog_cannot_block_reply() {
  local out
  write_away_poll_harness "$TMP_ROOT/away-poll-harness.py"
  out=$(run_away_poll_harness spoofed)
  assert_contains "$out" "polls=2 handoffs=['26']" \
    "an authenticated reply behind 25 spoofed owner messages is handed off by the next bounded poll"
  assert_contains "$out" 'max_spoofed_fetches=1' "each spoofed message is examined once per away posture"
  assert_contains "$out" 'away_repoll_fetches=0' "a later away poll resumes past examined mail"
  assert_contains "$out" 'attended_ok=1:ok,2:ok' "ignored mail is reported by attended polling after return"
  assert_contains "$out" "searches=[(None, 'UNSEEN')]" "polling issues no owner sender search"
  assert_contains "$out" 'unread_preserved=True' "ignored mail is never marked seen"
  pass "fm-mail: spoofed owner backlog is scanned once and cannot block an authenticated reply"
}

test_away_retry_mail_examined_once() {
  local out
  write_away_poll_harness "$TMP_ROOT/away-poll-harness.py"
  out=$(run_away_poll_harness retry)
  assert_contains "$out" "first=5:ignored,6:ok fetched=5,6 handoffs=['6']" \
    "retry mail is examined by the away scan in uid order"
  assert_contains "$out" 'second_fetched=' "a second away poll is recorded"
  assert_not_contains "$out" 'second_fetched=5' "an ignored retry uid is not examined again while away"
  pass "fm-mail: away retry mail is examined once per away posture"
}

test_away_owner_read_failures_retry_then_alert() {
  local out
  write_away_poll_harness "$TMP_ROOT/away-poll-harness.py"
  out=$(run_away_poll_harness transient)
  assert_contains "$out" "first rc=0 rows=1:degraded,2:ok,3:ignored handoffs=['2']" \
    "a failed owner read does not block later mail"
  assert_contains "$out" "second rc=0 fetched=1 handoffs=['2', '1'] alerts=0" \
    "a transient owner read failure is retried and delivered"
  out=$(run_away_poll_harness header-fail)
  assert_contains "$out" 'header_fetches=3 alerts=1' \
    "three failed header reads stop retrying and produce exactly one alert"
  assert_contains "$out" 'alert_says_check_gmail=True' \
    "the one alert tells the captain to check Gmail"
  assert_contains "$out" 'alert_content_safe=True' \
    "the alert contains no sender, subject, or message body"
  out=$(run_away_poll_harness header-outage)
  assert_not_contains "$out" 'outage alerts=1' "no alert is attempted while the destination is missing"
  assert_contains "$out" 'header_fetches=3 alerts=1 to=johnpoyser@gmail.com' \
    "an exhausted header read is kept through a destination outage and alerted once after restore"
  assert_contains "$out" 'alert_says_check_gmail=True' "the retained alert tells the captain to check Gmail"
  out=$(run_away_poll_harness permanent)
  assert_contains "$out" "handoffs=['2'] owner_fetches=3 spoof_fetches=1" \
    "a permanently unreadable owner reply is tried three times while later mail is processed"
  assert_contains "$out" 'alerts=1 to=johnpoyser@gmail.com' "one alert is sent to the owner after three failed reads"
  assert_contains "$out" 'alert_has_body=False' "the alert carries no message body"
  out=$(run_away_poll_harness handoff-timeout)
  assert_contains "$out" "second rc=0 fetched=1,2 handoffs=['1', '2']" \
    "a timed-out handoff retains the reply for the next poll"
  assert_contains "$out" 'handoff_timeouts_bounded=True' "the reply handoff is bounded by the poll budget"
  out=$(run_away_poll_harness handoff-fails)
  assert_contains "$out" "handoffs=['1', '2'] alerts=0" \
    "repeated handoff failures stay retryable and never count as unreadable replies"
  out=$(run_away_poll_harness config-outage)
  assert_contains "$out" "outage rows=1:degraded,2:degraded,3:ignored handoffs=[]" \
    "owner replies are not read while mail configuration is missing"
  assert_contains "$out" "restored fetched=1,2 handoffs=['1', '2']" \
    "owner replies are retained and delivered once configuration returns"
  pass "fm-mail: failed away owner reads retry, then alert once"
}

test_away_cursor_commits_only_after_publication() {
  local fakebin pub_home out rc=0
  fakebin=$(fm_fakebin "$TMP_ROOT")
  pub_home="$TMP_ROOT/away-publication-home"
  mkdir -p "$pub_home/bin" "$pub_home/state"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$pub_home/bin/fm-wake-lib.sh"
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'away-scan\t777\t1700000000\n5\n' > "$FM_MAIL_AWAY_SCAN.next"
printf 'uidvalidity\t777\n'
printf '5\t\tjohnpoyser@gmail.com\t[away-mode reply not processed: message body exceeds 256 KiB] reply\tok\n'
SH
  chmod +x "$fakebin/python3"
  printf 'away-scan\t777\t1700000000\n0\n' > "$pub_home/state/.mail-away-scan"
  : > "$pub_home/state/.wake-queue.seq"
  chmod 0000 "$pub_home/state/.wake-queue.seq"
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$pub_home" PATH="$fakebin:$PATH" "$MAIL" poll 2>&1) || rc=$?
  chmod 0600 "$pub_home/state/.wake-queue.seq"
  expect_code 1 "$rc" "a failed owner-mail wake fails the poll"
  assert_contains "$(sed -n 2p "$pub_home/state/.mail-away-scan")" "0" \
    "the away cursor is unchanged when the owner-mail wake was not published"
  rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$pub_home" PATH="$fakebin:$PATH" "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "the next poll publishes the owner-mail wake"
  assert_contains "$out" "woke for 5" "the owner message is examined again and woken"
  assert_contains "$(sed -n 2p "$pub_home/state/.mail-away-scan")" "5" \
    "the away cursor advances after the wake is published"
  pass "fm-mail: the away cursor commits only after emitted rows are published"
}

test_away_poll_budget_bounds_wall_clock() {
  local out
  write_away_poll_harness "$TMP_ROOT/away-poll-harness.py"
  out=$(run_away_poll_harness slow)
  assert_contains "$out" "first rc=0 bounded=True handoffs=['1'] rows=1:ok,2:ignored" \
    "slow fetches hand off the owner reply fetched first"
  assert_not_contains "$out" 'fetched=1,2,3,4,5' "the budget stops the first scan early"
  assert_contains "$out" 'timeouts_bounded=True' "socket timeouts never exceed the poll budget"
  assert_not_contains "$out" 'second rc=0 fetched=1' "the next poll does not refetch the delivered reply"
  assert_not_contains "$out" 'second rc=0 fetched=2,' "the next poll resumes after examined mail"
  assert_contains "$out" ',10:ignored' "the next poll reaches the remaining candidates"
  out=$(run_away_poll_harness hang)
  assert_contains "$out" "first rc=0 bounded=True handoffs=['1'] rows=1:ok fetched=1,2" \
    "a hanging fetch is interrupted at the budget and the earlier reply is handed off"
  assert_contains "$out" 'second rc=0 fetched=2,' "the interrupted uid is resumed on the next poll"
  out=$(run_away_poll_harness search-hang)
  assert_contains "$out" 'rc=1 bounded=True fetched=0' "a hanging search fails the poll within the budget"
  assert_contains "$out" 'mail poll budget exhausted' "the budget failure is reported"
  pass "fm-mail: one wall-clock budget bounds the whole away poll"
}

test_poll_retry_surfaces_under_new_mail_flood() {
  local harness out
  harness="$TMP_ROOT/retry-budget-harness.py"
  cat > "$harness" <<'PYEOF'
import os, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
    'FM_MAIL_CURSOR': sys.argv[1],
    'FM_MAIL_RETRY': sys.argv[2],
    'FM_MAIL_POLL_MAX_WAKES': '4',
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
            return ('OK', [b'51 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66 67 68 69 70 41'])
        if cmd == 'fetch':
            return ('OK', [(b'', b'Subject: good\r\nFrom: a@b.c\r\n\r\n')])
    def logout(self):
        pass
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[3])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(mod.cmd_poll_list())
PYEOF
  # cap=4 reserves retry_budget = max(1, 4//4) = 1. Twenty new uids (51-70)
  # exceed the new window (max(4*4, 4+10) = 16) and would fill the cap alone;
  # the recovering retry uid 41, sliced separately, must still take its slot.
  {
    printf 'uidvalidity=90009\n'
    printf '41\n'
  } > "$HOME_DIR/state/.mail-seen"
  printf '41\n' > "$HOME_DIR/state/.mail-retry"

  out=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" "$ROOT/bin/fm-mail.py" 2>&1)
  assert_contains "$out" $'41\t\ta@b.c\tgood\tretry' "recovered metadata surfaces despite the new-mail flood"
  pass "fm-mail: the reserved retry budget survives a new-mail flood"
}

test_poll_cap_one_alternates_new_and_retry() {
  local harness out1 out2 rc1=0 rc2=0
  harness="$TMP_ROOT/cap-one-turn-harness.py"
  cat > "$harness" <<'PYEOF'
import os, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
    'FM_MAIL_CURSOR': sys.argv[1],
    'FM_MAIL_RETRY': sys.argv[2],
    'FM_MAIL_TURN': sys.argv[3],
    'FM_MAIL_POLL_MAX_WAKES': '1',
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
            return ('OK', [b'90 100'])
        if cmd == 'fetch':
            return ('OK', [(b'', b'Subject: good\r\nFrom: a@b.c\r\n\r\n')])
    def logout(self):
        pass
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[4])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(mod.cmd_poll_list())
PYEOF
  # uid 90 is cursor-recorded and in the retry set (recovered degraded mail);
  # uid 100 is new unseen mail. cap=1 leaves one contended slot, so the poll
  # alternates: the first poll surfaces new mail and the next surfaces the
  # recovered retry metadata, and neither class can starve the other.
  {
    printf 'uidvalidity=90009\n'
    printf '90\n'
  } > "$HOME_DIR/state/.mail-seen"
  printf '90\n' > "$HOME_DIR/state/.mail-retry"
  : > "$HOME_DIR/state/.mail-turn"

  out1=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-turn" "$ROOT/bin/fm-mail.py" 2>&1) || rc1=$?
  expect_code 0 "$rc1" "first contended poll must succeed"
  assert_contains "$out1" $'100\t\ta@b.c\tgood\tok' "the first contended slot surfaces new mail"
  assert_not_contains "$out1" $'90\t' "the retry recovery waits its turn"

  out2=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-turn" "$ROOT/bin/fm-mail.py" 2>&1) || rc2=$?
  expect_code 0 "$rc2" "second contended poll must succeed"
  assert_contains "$out2" $'90\t\ta@b.c\tgood\tretry' "the second contended slot surfaces the recovered retry metadata"
  assert_not_contains "$out2" $'100\t' "new mail waits its turn"
  pass "fm-mail: a single contended slot alternates between new mail and retry recovery"
}

test_poll_cap_one_does_not_advance_unexamined_retry_window() {
  local harness out1 out2 pos1 pos2 rc1=0 rc2=0
  harness="$TMP_ROOT/cap-one-retry-pos-harness.py"
  cat > "$harness" <<'PYEOF'
import os, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
    'FM_MAIL_CURSOR': sys.argv[1],
    'FM_MAIL_RETRY': sys.argv[2],
    'FM_MAIL_TURN': sys.argv[3],
    'FM_MAIL_RETRY_POS': sys.argv[4],
    'FM_MAIL_POLL_MAX_WAKES': '1',
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
            return ('OK', [b'71 72 73 74 75 76 77 78 79 80 81 82 100'])
        if cmd == 'fetch':
            return ('OK', [(b'', b'Subject: good\r\nFrom: a@b.c\r\n\r\n')])
    def logout(self):
        pass
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[5])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(mod.cmd_poll_list())
PYEOF
  # 12 retry uids plus one new uid, cap=1. The first contended poll spends the
  # slot on new mail (retry_budget=0) and must leave the retry-scan position
  # unchanged so the next poll still examines retries 71-81 instead of wrapping
  # to 82.
  {
    printf 'uidvalidity=90009\n'
    for u in 71 72 73 74 75 76 77 78 79 80 81 82; do
      printf '%s\n' "$u"
    done
  } > "$HOME_DIR/state/.mail-seen"
  : > "$HOME_DIR/state/.mail-retry"
  for u in 71 72 73 74 75 76 77 78 79 80 81 82; do
    printf '%s\n' "$u" >> "$HOME_DIR/state/.mail-retry"
  done
  : > "$HOME_DIR/state/.mail-turn"
  : > "$HOME_DIR/state/.mail-retry-pos"

  out1=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-turn" "$HOME_DIR/state/.mail-retry-pos" "$ROOT/bin/fm-mail.py" 2>&1) || rc1=$?
  expect_code 0 "$rc1" "first contended poll must succeed"
  assert_contains "$out1" $'100\t\ta@b.c\tgood\tok' "the first contended slot surfaces new mail"
  assert_not_contains "$out1" $'71\t' "retry recovery waits its turn"
  pos1=$(cat "$HOME_DIR/state/.mail-retry-pos" 2>/dev/null || printf '')
  assert_equals "" "$pos1" "retry_budget 0 must not advance the retry-scan position"

  out2=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-turn" "$HOME_DIR/state/.mail-retry-pos" "$ROOT/bin/fm-mail.py" 2>&1) || rc2=$?
  expect_code 0 "$rc2" "second contended poll must succeed"
  assert_contains "$out2" $'71\t\ta@b.c\tgood\tretry' "the unexamined retry window is scanned from the start"
  assert_not_contains "$out2" $'82\t' "the scan must not wrap over the unexamined window"
  pos2=$(cat "$HOME_DIR/state/.mail-retry-pos" 2>/dev/null || printf '')
  assert_equals "" "$pos2" "position does not advance while a retry row is emitted"
  pass "fm-mail: a zero retry budget leaves the retry-scan position unchanged"
}

test_poll_cap_one_never_suppresses_new_mail() {
  local harness out
  harness="$TMP_ROOT/cap-one-harness.py"
  cat > "$harness" <<'PYEOF'
import os, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
    'FM_MAIL_CURSOR': sys.argv[1],
    'FM_MAIL_RETRY': sys.argv[2],
    'FM_MAIL_POLL_MAX_WAKES': '1',
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
            return ('OK', [b'61 41'])
        if cmd == 'fetch':
            return ('OK', [(b'', b'Subject: good\r\nFrom: a@b.c\r\n\r\n')])
    def logout(self):
        pass
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[3])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(mod.cmd_poll_list())
PYEOF
  # cap=1 with a retry present would compute new_budget=0; the fix guarantees
  # new mail keeps at least one slot, so uid 61 surfaces and the retry waits.
  {
    printf 'uidvalidity=90009\n'
    printf '41\n'
  } > "$HOME_DIR/state/.mail-seen"
  printf '41\n' > "$HOME_DIR/state/.mail-retry"

  out=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" "$ROOT/bin/fm-mail.py" 2>&1)
  assert_contains "$out" $'61\t\ta@b.c\tgood\tok' "new mail keeps its slot when the cap is one"
  pass "fm-mail: a cap of one never suppresses new mail while retries exist"
}

test_poll_restores_retry_when_recovered_wake_cannot_append() {
  local fakebin homedir_bin out rc=0
  fakebin=$(fm_fakebin "$TMP_ROOT")
  mkdir -p "$HOME_DIR/bin"
  [ -e "$HOME_DIR/bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$HOME_DIR/bin/fm-wake-lib.sh"
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t90009\n'
printf '77\t\tfrom@x\tRe: hi\tretry\n'
SH
  chmod +x "$fakebin/python3"
  printf 'uidvalidity=90009\n77\n' > "$HOME_DIR/state/.mail-seen"
  rm -f "$HOME_DIR/state/.mail-retry"
  printf '77\n' > "$HOME_DIR/state/.mail-retry"
  : > "$HOME_DIR/state/.wake-queue.seq"
  chmod 0000 "$HOME_DIR/state/.wake-queue.seq"

  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "poll must fail when the recovered wake cannot be appended"
  assert_contains "$(cat "$HOME_DIR/state/.mail-retry" 2>/dev/null)" "77" "the retry record is restored so the recovered metadata can be re-fetched"
  chmod 0600 "$HOME_DIR/state/.wake-queue.seq"
  pass "fm-mail: a recovered wake that cannot append restores the retry instead of stranding the metadata"
}

test_poll_death_between_retry_remove_and_publish_does_not_strand() {
  # Old ordering: retry_remove ran BEFORE wake_for, so a kill after the remove
  # but before the publish left the uid cursor-recorded from the degraded wake
  # but no longer retry-eligible. The retry clear is now inside wake_for and
  # runs only after a successful publish, so the same kill window cannot strand
  # metadata. This test proves the invariant by forcing publish to fail and
  # verifying the retry entry survives, then that a follow-up poll recovers it.
  local fakebin homedir_bin test_home out rc=0 wakeq
  fakebin=$(fm_fakebin "$TMP_ROOT")
  test_home="$TMP_ROOT/retry-survives-failed-publish-home"
  homedir_bin="$test_home/bin"
  mkdir -p "$homedir_bin" "$test_home/state"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"

  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity	90009\n'
printf '77\t2026-09-05T00:00:00Z\tfrom@x\tRe: hi\tretry\n'
SH
  chmod +x "$fakebin/python3"

  # Cursor records the uid from the earlier degraded wake; retry set exists.
  printf 'uidvalidity=90009\n77\n' > "$test_home/state/.mail-seen"
  printf '77\n' > "$test_home/state/.mail-retry"

  # Make the wake queue unwritable so the recovered wake cannot append. The
  # retry record must NOT be cleared in this case.
  : > "$test_home/state/.wake-queue.seq"
  chmod 0000 "$test_home/state/.wake-queue.seq"

  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$test_home" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "poll must fail closed when the recovered wake cannot be published"
  assert_contains "$out" "wake append failed for 77" "poll reports the failed wake append"
  assert_grep "77" "$test_home/state/.mail-retry" "retry entry survives a failed publish"
  assert_not_contains "$(cat "$test_home/state/.wake-queue" 2>/dev/null)" "check: mail 77" \
    "no wake is queued when publish fails"

  # Restore writable state: the next poll must recover the metadata.
  rm -f "$test_home/state/.wake-queue.seq"
  rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$test_home" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "follow-up poll must succeed and recover the metadata"
  assert_contains "$out" "woke for 77" "follow-up poll re-surfaces the recovered uid"
  assert_contains "$(cat "$test_home/state/.mail-seen" 2>/dev/null)" "77" \
    "follow-up poll records the uid in the cursor"
  wakeq=$(grep -c "check: mail 77" "$test_home/state/.wake-queue" 2>/dev/null || true)
  expect_code 1 "$wakeq" "exactly one recovery wake is queued"
  pass "fm-mail: a death between retry remove and wake publish cannot strand recovered metadata"
}

test_poll_fails_closed_when_poll_list_fails() {
  local fakebin out rc=0
  fakebin=$(fm_fakebin "$TMP_ROOT")
  mkdir -p "$HOME_DIR/bin"
  [ -e "$HOME_DIR/bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$HOME_DIR/bin/fm-wake-lib.sh"
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_POLL_FAIL_MARKER" ]; then
  echo 'fm-mail poll error: simulated failure' >&2
  exit 1
fi
printf 'uidvalidity\t90009\n'
printf '7\t\tfrom@x\tnew mail\tok\n'
SH
  chmod +x "$fakebin/python3"
  printf 'uidvalidity=90009\n' > "$HOME_DIR/state/.mail-seen"
  touch "$HOME_DIR/fail.marker"

  out=$(FM_POLL_FAIL_MARKER="$HOME_DIR/fail.marker" FM_MAIL_USER=test FM_MAIL_PASS=pass \
    FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "poll must fail when poll_list fails"
  assert_not_contains "$out" "woke for 7" "nothing is woken from a failed poll_list"
  assert_not_contains "$out" "no new mail" "a failed poll is not reported as no new mail"

  rm -f "$HOME_DIR/fail.marker"
  rc=0
  out=$(FM_POLL_FAIL_MARKER="$HOME_DIR/fail.marker" FM_MAIL_USER=test FM_MAIL_PASS=pass \
    FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "a later poll must succeed, proving the mail-seen lock was released"
  assert_contains "$out" "woke for 7" "the later poll wakes the new mail"
  pass "fm-mail: a failed poll_list fails closed, wakes nothing, and releases the lock"
}

test_poll_fails_closed_when_retry_clear_fails() {
  # The retry record is now cleared inside wake_for, AFTER the wake is durably
  # published. A failed clear therefore leaves the wake in the queue while the
  # poll fails closed; later polls retry the clear without appending another wake.
  local fakebin homedir_bin out rc=0 test_home wakeq
  fakebin=$(fm_fakebin "$TMP_ROOT")
  test_home="$TMP_ROOT/retry-clear-fail-home"
  homedir_bin="$test_home/bin"
  mkdir -p "$homedir_bin" "$test_home/state"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t90009\n'
printf '77\t\tfrom@x\tRe: hi\tretry\n'
SH
  chmod +x "$fakebin/python3"
  printf 'uidvalidity=90009\n77\n' > "$test_home/state/.mail-seen"
  printf '77\n' > "$test_home/state/.mail-retry"
  chmod 0000 "$test_home/state/.mail-retry"

  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$test_home" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "poll must fail when the retry record cannot be cleared"
  assert_contains "$out" "could not clear retry for recovered 77 after publish" "failure names the post-publish retry cleanup"
  assert_grep "check: mail 77" "$test_home/state/.wake-queue" "the recovery wake was already published before the cleanup failed"
  wakeq=$(grep -c "check: mail 77" "$test_home/state/.wake-queue" 2>/dev/null || true)
  expect_code 1 "$wakeq" "exactly one recovery wake is queued after the failed clear"

  rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$test_home" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "a later poll must still fail closed while the retry record cannot be cleared"
  assert_not_contains "$out" "woke for 77" "a later poll must not re-append a recovery wake"
  wakeq=$(grep -c "check: mail 77" "$test_home/state/.wake-queue" 2>/dev/null || true)
  expect_code 1 "$wakeq" "the queued recovery wake is not duplicated while the retry clear keeps failing"

  chmod 0600 "$test_home/state/.mail-retry"
  assert_grep "77" "$test_home/state/.mail-retry" "the retry entry remains for the next poll to clear"
  rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$test_home" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "poll must succeed once the retry record can be cleared"
  assert_not_contains "$out" "woke for 77" "clearing the retry record must not re-wake the uid"
  assert_not_contains "$(cat "$test_home/state/.mail-retry" 2>/dev/null || true)" "77" \
    "the retry entry is cleared without a duplicate wake"
  wakeq=$(grep -c "check: mail 77" "$test_home/state/.wake-queue" 2>/dev/null || true)
  expect_code 1 "$wakeq" "exactly one recovery wake remains after a successful retry clear"
  pass "fm-mail: a failed retry clear fails the poll; the published wake stays and the retry entry remains"
}

test_poll_fails_closed_when_stale_retry_clear_fails() {
  # After a successful non-degraded wake, a stale retry entry must be cleared
  # fail-closed: swallowing that failure would leave the uid eligible for a
  # duplicate recovery wake on the next poll.
  local fakebin homedir_bin out rc=0 test_home
  fakebin=$(fm_fakebin "$TMP_ROOT")
  test_home="$TMP_ROOT/stale-retry-clear-fail-home"
  homedir_bin="$test_home/bin"
  mkdir -p "$homedir_bin" "$test_home/state"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t90009\n'
printf '77\t2026-09-05T00:00:00Z\tfrom@x\tHello\tok\n'
SH
  chmod +x "$fakebin/python3"
  printf 'uidvalidity=90009\n' > "$test_home/state/.mail-seen"
  printf '77\n' > "$test_home/state/.mail-retry"
  chmod 0000 "$test_home/state/.mail-retry"

  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$test_home" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "poll must fail when a stale retry cannot be cleared after wake"
  assert_contains "$out" "could not clear retry for recovered 77 after publish" "failure names the post-publish retry cleanup"
  assert_grep "check: mail 77" "$test_home/state/.wake-queue" "the wake already landed before the cleanup failure"
  chmod 0600 "$test_home/state/.mail-retry"
  assert_grep "77" "$test_home/state/.mail-retry" "the stale retry entry remains for the next poll to clear"
  pass "fm-mail: a failed stale-retry clear fails the poll instead of silently leaving a duplicate-wake entry"
}

test_assert_equals_rejects_mismatch() {
  # Guard against a silent false pass: assert_equals must be defined and must
  # abort on a mismatch (the retry-scan cursor test depends on it).
  if ( assert_equals "11" "10" "deliberate mismatch" ) >/dev/null 2>&1; then
    fail "assert_equals must fail when expected and actual differ"
  fi
  assert_equals "11" "11" "matching values must pass"
  pass "tests/lib: assert_equals fails on mismatch so cursor assertions cannot false-pass"
}

test_poll_fails_closed_when_retry_unwritable() {
  local fakebin homedir_bin out rc=0
  fakebin=$(fm_fakebin "$TMP_ROOT")
  homedir_bin="$HOME_DIR/bin"
  mkdir -p "$homedir_bin"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"

  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t90009\n'
printf '77\t\t(no header)\tunfetchable header - see fm-mail read\tdegraded\n'
SH
  chmod +x "$fakebin/python3"
  printf 'uidvalidity=90009\n' > "$HOME_DIR/state/.mail-seen"
  : > "$HOME_DIR/state/.mail-retry"
  chmod 0400 "$HOME_DIR/state/.mail-retry"

  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "poll must fail when the retry record cannot be written"
  assert_not_contains "$out" "woke for 77" "no wake is emitted before the retry record"
  assert_not_contains "$(cat "$HOME_DIR/state/.mail-seen" 2>/dev/null)" "77" "a failed retry write must not cursor-record the uid"
  chmod 0600 "$HOME_DIR/state/.mail-retry"
  pass "fm-mail: a failed retry write fails the poll instead of losing recovery"
}

test_poll_journal_failure_never_cursor_records() {
  # A mail must never be marked surfaced in the cursor without the journal
  # recording its wake. If the journal write fails, the cursor is NOT written
  # and the poll fails closed, so the next poll re-wakes the mail instead of
  # silently suppressing it (cursor-without-journal suppression).
  local fakebin homedir_bin out rc=0
  fakebin=$(fm_fakebin "$TMP_ROOT")
  homedir_bin="$HOME_DIR/bin"
  mkdir -p "$homedir_bin"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"

  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t90009\n'
printf '78\t2026-09-06T00:00:00Z\tfrom@x\tHello\tok\n'
SH
  chmod +x "$fakebin/python3"
  printf 'uidvalidity=90009\n' > "$HOME_DIR/state/.mail-seen"
  : > "$HOME_DIR/state/.mail-woken"
  chmod 0400 "$HOME_DIR/state/.mail-woken"

  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "poll must fail when the journal cannot be written"
  assert_not_contains "$out" "woke for 78" "no wake is emitted before the journal commits"
  assert_not_contains "$(cat "$HOME_DIR/state/.mail-seen" 2>/dev/null)" "78" \
    "a failed journal write must not cursor-record the uid (no cursor-without-journal suppression)"
  chmod 0600 "$HOME_DIR/state/.mail-woken"
  pass "fm-mail: a journal write failure never cursor-records a suppressed mail"
}

test_poll_resurfaces_degraded_uid_whose_wake_never_recorded() {
  local harness out rc=0
  harness="$TMP_ROOT/retry-not-seen-harness.py"
  cat > "$harness" <<'PYEOF'
import os, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
    'FM_MAIL_CURSOR': sys.argv[1],
    'FM_MAIL_RETRY': sys.argv[2],
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
            return ('OK', [b'90'])
        if cmd == 'fetch':
            return ('NO', None)
    def logout(self):
        pass
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[3])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(mod.cmd_poll_list())
PYEOF
  # uid 90 is in the retry set (a prior degraded wake) but NOT in the cursor
  # (that wake failed and was rolled back). It must be re-surfaced as degraded
  # on this poll - a retry uid the cursor does not record must never be
  # silently dropped as a pure retry.
  printf 'uidvalidity=90009\n' > "$HOME_DIR/state/.mail-seen"
  printf '90\n' > "$HOME_DIR/state/.mail-retry"

  out=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$ROOT/bin/fm-mail.py" 2>&1) || rc=$?
  expect_code 0 "$rc" "poll must succeed"
  assert_contains "$out" $'90\t\t(no header)\tunfetchable header - see fm-mail read\tdegraded' "a retry uid the cursor never recorded is re-surfaced degraded"
  pass "fm-mail: a retry uid whose degraded wake never recorded is re-surfaced, not dropped"
}

test_poll_fetch_raise_does_not_abort_the_scan() {
  local harness out rc=0
  harness="$TMP_ROOT/fetch-raise-harness.py"
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
                raise RuntimeError('simulated imap fetch failure')
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
  expect_code 0 "$rc" "a raised fetch must not abort the scan"
  assert_contains "$out" $'1\t\t(no header)\tunfetchable header - see fm-mail read\tdegraded' "the raising uid is surfaced degraded"
  assert_contains "$out" $'2\t\ta@b.c\tgood\tok' "the scan advances past the raising uid"
  pass "fm-mail: a raised FETCH surfaces that uid degraded and advances"
}

test_poll_retry_cursor_advances_past_failures() {
  local harness out1 out2 pos1 pos2 rc1=0 rc2=0
  harness="$TMP_ROOT/retry-cursor-harness.py"
  cat > "$harness" <<'PYEOF'
import os, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
    'FM_MAIL_CURSOR': sys.argv[1],
    'FM_MAIL_RETRY': sys.argv[2],
    'FM_MAIL_RETRY_POS': sys.argv[5],
    'FM_MAIL_POLL_MAX_WAKES': '1',
})
FAILING = set(sys.argv[3].split(',')) if len(sys.argv) > 3 else set()
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
            return ('OK', [b'71 72 73 74 75 76 77 78 79 80 81 82'])
        if cmd == 'fetch':
            if args[0].decode() in FAILING:
                return ('NO', None)
            return ('OK', [(b'', b'Subject: good\r\nFrom: a@b.c\r\n\r\n')])
    def logout(self):
        pass
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[4])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(mod.cmd_poll_list())
PYEOF
  # All 12 uids are cursor-recorded (degraded wakes) and listed in the retry
  # set; 71..81 keep failing, 82 recovered. window = max(1*4, 1+10) = 11, so a
  # single poll examines a bounded 11-uid window starting at the durable retry
  # position. Position 0 scans 71..81 first, then the stored position advances
  # to 11 so the next poll wraps and reaches 82 - a recovered uid can never be
  # stranded behind the persistent-failure prefix.
  {
    printf 'uidvalidity=90009\n'
    for u in 71 72 73 74 75 76 77 78 79 80 81 82; do
      printf '%s\n' "$u"
    done
  } > "$HOME_DIR/state/.mail-seen"
  : > "$HOME_DIR/state/.mail-retry"
  for u in 71 72 73 74 75 76 77 78 79 80 81 82; do
    printf '%s\n' "$u" >> "$HOME_DIR/state/.mail-retry"
  done
  : > "$HOME_DIR/state/.mail-retry-pos"

  out1=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "71,72,73,74,75,76,77,78,79,80,81" "$ROOT/bin/fm-mail.py" "$HOME_DIR/state/.mail-retry-pos" 2>&1) || rc1=$?
  expect_code 0 "$rc1" "first retry poll must succeed"
  assert_not_contains "$out1" $'82\t' "the recovered uid is not reached while failures hold the window"
  pos1=$(cat "$HOME_DIR/state/.mail-retry-pos" 2>/dev/null || printf '')
  assert_equals "11" "$pos1" "the retry-scan position advances past the scanned window"

  out2=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "71,72,73,74,75,76,77,78,79,80,81" "$ROOT/bin/fm-mail.py" "$HOME_DIR/state/.mail-retry-pos" 2>&1) || rc2=$?
  expect_code 0 "$rc2" "second retry poll must succeed"
  assert_contains "$out2" $'82\t\ta@b.c\tgood\tretry' "the cursor wraps and the recovered uid surfaces on the next poll"
  pos2=$(cat "$HOME_DIR/state/.mail-retry-pos" 2>/dev/null || printf '')
  assert_equals "11" "$pos2" "position does not advance while a recovered row is emitted (bash removes it from the retry set)"

  # Simulate the bash layer removing the recovered uid from the retry set
  # after a successful publish; the next poll scans the remaining uids from
  # the same numeric start, so an unfetchable-only window still advances.
  grep -vx -e '82' "$HOME_DIR/state/.mail-retry" > "$HOME_DIR/state/.mail-retry.tmp" || true
  mv -f -- "$HOME_DIR/state/.mail-retry.tmp" "$HOME_DIR/state/.mail-retry"

  rc2=0
  _out3=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "71,72,73,74,75,76,77,78,79,80,81" "$ROOT/bin/fm-mail.py" "$HOME_DIR/state/.mail-retry-pos" 2>&1) || rc2=$?
  expect_code 0 "$rc2" "third retry poll must succeed"
  pos3=$(cat "$HOME_DIR/state/.mail-retry-pos" 2>/dev/null || printf '')
  assert_equals "0" "$pos3" "the retry-scan position advances only past candidates examined within budget after the recovered uid is removed"
  pass "fm-mail: the retry-scan cursor advances past persistent failures"
}

test_poll_retry_position_does_not_advance_past_unpublished_wake() {
  # The durable retry-scan position must never advance past a uid whose wake
  # did not durably publish. cmd_poll_list cannot observe the bash wake_for
  # result, so it leaves the position unchanged whenever a row is emitted;
  # the bash layer removes recovered uids from the retry set, and the next
  # poll's same numeric start scans the next remaining uid.
  local harness out rc=0 pos
  harness="$TMP_ROOT/retry-pos-unpublished-harness.py"
  cat > "$harness" <<'PYEOF'
import os, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
    'FM_MAIL_CURSOR': sys.argv[1],
    'FM_MAIL_RETRY': sys.argv[2],
    'FM_MAIL_RETRY_POS': sys.argv[3],
    'FM_MAIL_POLL_MAX_WAKES': '1',
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
            return ('OK', [b'81 82'])
        if cmd == 'fetch':
            # 81 is still failing; 82 has just recovered real metadata.
            if args[0] == b'81':
                return ('NO', None)
            return ('OK', [(b'', b'Subject: recovered\r\nFrom: bob@x.com\r\n\r\n')])
    def logout(self):
        pass
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[4])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(mod.cmd_poll_list())
PYEOF
  # Both uids are already cursor-recorded from prior degraded wakes; 81 is
  # still unfetchable, 82 has recovered. cap=1 emits only the recovered row.
  {
    printf 'uidvalidity=90009\n'
    printf '81\n82\n'
  } > "$HOME_DIR/state/.mail-seen"
  printf '81\n82\n' > "$HOME_DIR/state/.mail-retry"
  : > "$HOME_DIR/state/.mail-retry-pos"

  # The recovered row is emitted, but the wake has not yet been published.
  # The durable position must advance only up to the first emitted uid (index 1
  # because 81 is still unfetchable), never past it, so a failed publish would
  # re-scan 82 on the next poll instead of dropping it until the cursor wraps.
  out=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-retry-pos" "$ROOT/bin/fm-mail.py" 2>&1) || rc=$?
  expect_code 0 "$rc" "poll must succeed while emitting the recovered row"
  assert_contains "$out" $'82\t\tbob@x.com\trecovered\tretry' \
    "recovered row is emitted to the bash wake layer"
  pos=$(cat "$HOME_DIR/state/.mail-retry-pos" 2>/dev/null || printf '')
  assert_equals "1" "$pos" "cursor lands on the first emitted uid, not past it"

  # Simulate a failed wake publish: 82 is still in the retry set, and the next
  # poll must start at 82 again rather than skipping it.
  rc=0
  out=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-retry-pos" "$ROOT/bin/fm-mail.py" 2>&1) || rc=$?
  expect_code 0 "$rc" "retry poll must re-scan the uid whose wake did not publish"
  assert_contains "$out" $'82\t\tbob@x.com\trecovered\tretry' \
    "recovered uid is re-scanned while its wake is still unpublished"
  pos=$(cat "$HOME_DIR/state/.mail-retry-pos" 2>/dev/null || printf '')
  assert_equals "1" "$pos" "cursor stays on the unpublished uid"

  # Simulate the bash layer removing the recovered uid after a successful
  # publish; the next poll scans the remaining uid from the same numeric start
  # and advances only when no row is emitted.
  printf '81\n' > "$HOME_DIR/state/.mail-retry"
  rc=0
  out=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-retry-pos" "$ROOT/bin/fm-mail.py" 2>&1) || rc=$?
  expect_code 0 "$rc" "retry poll must succeed after the recovered uid is removed"
  assert_not_contains "$out" $'82\t' "recovered uid is no longer in the retry set"
  pos=$(cat "$HOME_DIR/state/.mail-retry-pos" 2>/dev/null || printf '')
  assert_equals "0" "$pos" "position advances only after an emission-free poll"
  pass "fm-mail: retry-scan position does not advance past an unpublished wake"
}

test_poll_retry_budget_advances_by_examined_not_window() {
  # Greptile regression: when the retry window holds more uids than the
  # reserved retry budget, the durable position must advance by the candidates
  # actually examined within budget - never by the full window. Advancing by
  # the full window while emitting only the budgeted prefix revisits the same
  # prefix every poll and strands later recovered uids.
  local harness out pos rc=0
  harness="$TMP_ROOT/retry-budget-cursor-harness.py"
  cat > "$harness" <<'PYEOF'
import os, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
    'FM_MAIL_CURSOR': sys.argv[1],
    'FM_MAIL_RETRY': sys.argv[2],
    'FM_MAIL_RETRY_POS': sys.argv[3],
    # cap=4 -> retry_budget = max(1, 4//4) = 1, so only one retry uid may
    # emit per poll while the window (max(4*4, 4+10) = 16) holds all 12.
    'FM_MAIL_POLL_MAX_WAKES': '4',
})
FAILING = set(sys.argv[5].split(',')) if len(sys.argv) > 5 else set()
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
            return ('OK', [b'101 102 103 104 105 106 107 108 109 110 111 112'])
        if cmd == 'fetch':
            # The first three uids are still unfetchable; the rest have
            # recovered. The durable position must advance by the examined
            # prefix (3), never the full window (16), so the recovered uid
            # behind the unfetchable prefix is reached promptly.
            if args[0].decode() in FAILING:
                return ('NO', None)
            return ('OK', [(b'', b'Subject: r\r\nFrom: a@b.c\r\n\r\n')])
    def logout(self):
        pass
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[4])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(mod.cmd_poll_list())
PYEOF
  # All 12 uids are cursor-recorded and in the retry set; the first three are
  # still unfetchable and the rest have recovered. The durable position must
  # advance by the examined prefix (3), never the full window (16), so the
  # recovered uid behind the unfetchable prefix is reached promptly.
  mkdir -p "$HOME_DIR/state"
  {
    printf 'uidvalidity=90009\n'
    for u in 101 102 103 104 105 106 107 108 109 110 111 112; do
      printf '%s\n' "$u"
    done
  } > "$HOME_DIR/state/.mail-seen"
  printf '101\n102\n103\n104\n105\n106\n107\n108\n109\n110\n111\n112\n' > "$HOME_DIR/state/.mail-retry"
  : > "$HOME_DIR/state/.mail-retry-pos"

  out=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-retry-pos" "$ROOT/bin/fm-mail.py" "101,102,103" 2>&1) || rc=$?
  expect_code 0 "$rc" "first retry poll must succeed"
  assert_contains "$out" $'104\t\ta@b.c\tr\tretry' \
    "the first recovered uid after the unfetchable prefix is emitted within budget"
  assert_not_contains "$out" $'105\t' "only the budgeted retry uid is emitted"
  pos=$(cat "$HOME_DIR/state/.mail-retry-pos" 2>/dev/null || printf '')
  assert_equals "3" "$pos" \
    "position advances by the examined prefix, never the full window"
  pass "fm-mail: retry budget advances the scan by examined candidates, not the window"
}

test_poll_retry_window_of_unseen_never_stalls_cursor() {
  # Greptile regression: when a retry scan window holds only uids absent from
  # the seen cursor while an eligible retry uid lies beyond that window, the
  # durable position must still advance so the later recovered uid is
  # reachable. A window of unseen uids must never stall the cursor
  # permanently (retry_candidates empty would otherwise keep budget 0 and the
  # position would never move).
  local harness out1 out2 rc1=0 rc2=0 pos
  harness="$TMP_ROOT/retry-stall-harness.py"
  cat > "$harness" <<'PYEOF'
import os, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
    'FM_MAIL_CURSOR': sys.argv[1],
    'FM_MAIL_RETRY': sys.argv[2],
    'FM_MAIL_RETRY_POS': sys.argv[3],
    'FM_MAIL_POLL_MAX_WAKES': '4',
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
            # Nothing is unseen (all server-seen); only uid 320 is in our
            # cursor and retry-eligible, beyond the first 16-uid window.
            return ('OK', [b''])
        if cmd == 'fetch':
            return ('OK', [(b'', b'Subject: rec\r\nFrom: z@x.c\r\n\r\n')])
    def logout(self):
        pass
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[4])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(mod.cmd_poll_list())
PYEOF
  # Retry set 301..320; cursor records ONLY 320 (the recovered uid). The first
  # scan window (301..316) therefore holds only unseen uids, yet the cursor
  # must advance past it so 320 is reached on a later window.
  mkdir -p "$HOME_DIR/state"
  printf 'uidvalidity=90009\n320\n' > "$HOME_DIR/state/.mail-seen"
  for u in $(seq 301 320); do printf '%s\n' "$u"; done > "$HOME_DIR/state/.mail-retry"
  : > "$HOME_DIR/state/.mail-retry-pos"

  out1=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-retry-pos" "$ROOT/bin/fm-mail.py" 2>&1) || rc1=$?
  expect_code 0 "$rc1" "first poll must succeed"
  pos=$(cat "$HOME_DIR/state/.mail-retry-pos" 2>/dev/null || printf '')
  assert_equals "16" "$pos" "the stale unseen window advances the cursor by the scanned window (cap=4 window=16)"

  out2=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-retry-pos" "$ROOT/bin/fm-mail.py" 2>&1) || rc2=$?
  expect_code 0 "$rc2" "second poll must succeed"
  assert_contains "$out2" $'320\t\tz@x.c\trec\tretry' \
    "the recovered uid beyond the stale window surfaces once the cursor advances"
  pass "fm-mail: a retry window of unseen uids never stalls the cursor"
}

test_poll_retry_unfetchable_window_advances_with_new_mail() {
  # Greptile P1 / no-mistakes retry-pos-not-out-stalls-mixed: when every
  # retry uid in the current window is unfetchable while new mail fills the
  # poll output, the durable position must still advance. Gating persist on
  # an empty `out` re-scans the same failed prefix forever and strands a
  # recovered uid beyond the window.
  local harness out1 out2 pos rc1=0 rc2=0
  harness="$TMP_ROOT/retry-newmail-unfetchable-harness.py"
  cat > "$harness" <<'PYEOF'
import os, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
    'FM_MAIL_CURSOR': sys.argv[1],
    'FM_MAIL_RETRY': sys.argv[2],
    'FM_MAIL_RETRY_POS': sys.argv[3],
    'FM_MAIL_POLL_MAX_WAKES': '4',
})
# First window (cap=4 -> window=16) is 301..316; those stay unfetchable.
# 320 has recovered and sits beyond that window. 400 is sustained new mail.
FAILING = {str(u).encode() for u in range(301, 320)}
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
            return ('OK', [b'400'])
        if cmd == 'fetch':
            if args[0] in FAILING:
                return ('NO', None)
            return ('OK', [(b'', b'Subject: rec\r\nFrom: z@x.c\r\n\r\n')])
    def logout(self):
        pass
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[4])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(mod.cmd_poll_list())
PYEOF
  mkdir -p "$HOME_DIR/state"
  {
    printf 'uidvalidity=90009\n'
    for u in $(seq 301 320); do printf '%s\n' "$u"; done
  } > "$HOME_DIR/state/.mail-seen"
  for u in $(seq 301 320); do printf '%s\n' "$u"; done > "$HOME_DIR/state/.mail-retry"
  : > "$HOME_DIR/state/.mail-retry-pos"

  out1=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-retry-pos" "$ROOT/bin/fm-mail.py" 2>&1) || rc1=$?
  expect_code 0 "$rc1" "first poll must succeed while new mail fills the output"
  assert_contains "$out1" $'400\t\tz@x.c\trec\tok' \
    "sustained new mail is emitted on the first poll"
  assert_not_contains "$out1" $'320\t' \
    "the recovered retry uid is still beyond the unfetchable window"
  pos=$(cat "$HOME_DIR/state/.mail-retry-pos" 2>/dev/null || printf '')
  assert_equals "16" "$pos" \
    "unfetchable retry window advances the cursor even while new mail fills out"

  out2=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-retry-pos" "$ROOT/bin/fm-mail.py" 2>&1) || rc2=$?
  expect_code 0 "$rc2" "second poll must succeed"
  assert_contains "$out2" $'320\t\tz@x.c\trec\tretry' \
    "the recovered uid beyond the failed prefix surfaces once the cursor advances"
  pass "fm-mail: an unfetchable retry window still advances while new mail fills out"
}

test_poll_retry_unseen_window_advances_with_new_mail() {
  # Same stall as retry-pos-not-out-stalls-mixed on the all-unseen window
  # branch: a retry window of uids absent from the seen cursor must still
  # advance the durable position when new mail fills `out`, so a later
  # eligible retry uid beyond that window remains reachable.
  local harness out1 out2 pos rc1=0 rc2=0
  harness="$TMP_ROOT/retry-newmail-unseen-harness.py"
  cat > "$harness" <<'PYEOF'
import os, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
    'FM_MAIL_CURSOR': sys.argv[1],
    'FM_MAIL_RETRY': sys.argv[2],
    'FM_MAIL_RETRY_POS': sys.argv[3],
    'FM_MAIL_POLL_MAX_WAKES': '4',
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
            return ('OK', [b'400'])
        if cmd == 'fetch':
            return ('OK', [(b'', b'Subject: rec\r\nFrom: z@x.c\r\n\r\n')])
    def logout(self):
        pass
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[4])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(mod.cmd_poll_list())
PYEOF
  mkdir -p "$HOME_DIR/state"
  printf 'uidvalidity=90009\n320\n' > "$HOME_DIR/state/.mail-seen"
  for u in $(seq 301 320); do printf '%s\n' "$u"; done > "$HOME_DIR/state/.mail-retry"
  : > "$HOME_DIR/state/.mail-retry-pos"

  out1=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-retry-pos" "$ROOT/bin/fm-mail.py" 2>&1) || rc1=$?
  expect_code 0 "$rc1" "first poll must succeed while new mail fills the output"
  assert_contains "$out1" $'400\t\tz@x.c\trec\tok' \
    "sustained new mail is emitted on the first poll"
  assert_not_contains "$out1" $'320\t' \
    "the recovered retry uid is still beyond the unseen window"
  pos=$(cat "$HOME_DIR/state/.mail-retry-pos" 2>/dev/null || printf '')
  assert_equals "16" "$pos" \
    "unseen retry window advances the cursor even while new mail fills out"

  out2=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-retry-pos" "$ROOT/bin/fm-mail.py" 2>&1) || rc2=$?
  expect_code 0 "$rc2" "second poll must succeed"
  assert_contains "$out2" $'320\t\tz@x.c\trec\tretry' \
    "the recovered uid beyond the unseen window surfaces once the cursor advances"
  pass "fm-mail: an unseen retry window still advances while new mail fills out"
}

test_poll_retry_logout_before_emit_and_position_save() {
  # A standing check can SIGKILL poll_list while IMAP logout is still blocked.
  # Logout must finish before any emit or persist so that kill cannot advance
  # the retry-scan position over rows bash never received.
  local harness out rc=0 pos
  harness="$TMP_ROOT/retry-logout-order-harness.py"
  cat > "$harness" <<'PYEOF'
import os, signal, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
    'FM_MAIL_CURSOR': sys.argv[1],
    'FM_MAIL_RETRY': sys.argv[2],
    'FM_MAIL_RETRY_POS': sys.argv[3],
    'FM_MAIL_POLL_MAX_WAKES': '1',
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
            return ('OK', [b'81 82'])
        if cmd == 'fetch':
            if args[0] == b'81':
                return ('NO', None)
            return ('OK', [(b'', b'Subject: recovered\r\nFrom: bob@x.com\r\n\r\n')])
    def logout(self):
        os.kill(os.getpid(), signal.SIGKILL)
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[4])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(mod.cmd_poll_list())
PYEOF
  {
    printf 'uidvalidity=90009\n'
    printf '81\n82\n'
  } > "$HOME_DIR/state/.mail-seen"
  printf '81\n82\n' > "$HOME_DIR/state/.mail-retry"
  : > "$HOME_DIR/state/.mail-retry-pos"

  out=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-retry-pos" "$ROOT/bin/fm-mail.py" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "poll_list must not exit 0 when logout is killed"
  assert_not_contains "$out" $'82\t' "a killed logout must not emit rows"
  pos=$(cat "$HOME_DIR/state/.mail-retry-pos" 2>/dev/null || printf '')
  assert_equals "" "$pos" "a killed logout must not advance the retry-scan position"
  pass "fm-mail: hung logout cannot advance the retry-scan position"
}

test_poll_list_logs_out_on_imap_error() {
  # A standing check that fails after IMAP login must still log out so repeated
  # select/search/fetch errors cannot leak sessions until the server times them
  # out.
  local harness out marker rc=0
  harness="$TMP_ROOT/poll-logout-on-error-harness.py"
  marker="$TMP_ROOT/poll-logout-on-error.marker"
  rm -f "$marker"
  cat > "$harness" <<'PYEOF'
import os, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
    'FM_MAIL_CURSOR': sys.argv[2],
    'FM_MAIL_POLL_MAX_WAKES': '1',
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
            raise RuntimeError('search failed')
        return ('NO', None)
    def logout(self):
        open(sys.argv[1], 'w', encoding='utf-8').write('logged-out\n')
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[3])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(mod.cmd_poll_list())
PYEOF
  {
    printf 'uidvalidity=90009\n'
  } > "$HOME_DIR/state/.mail-seen"

  out=$(python3 "$harness" "$marker" "$HOME_DIR/state/.mail-seen" "$ROOT/bin/fm-mail.py" 2>&1) || rc=$?
  expect_code 1 "$rc" "poll_list must fail when IMAP search raises"
  assert_contains "$out" "search failed" "the IMAP error is reported on stderr"
  [ -f "$marker" ] || fail "poll_list must log out after a post-login IMAP error"
  assert_equals "logged-out" "$(cat "$marker")" "logout ran on the error path"
  pass "fm-mail: poll_list logs out when IMAP work fails after login"
}

test_poll_retry_position_not_saved_when_row_emitted() {
  # When a retry row is emitted, cmd_poll_list must not persist the retry-scan
  # position at all: a kill in the position-write window cannot drop a uid
  # whose wake has not yet durably published. Wrapping save_retry_pos so that
  # any call SIGKILLs the process proves the call is skipped when rows are
  # emitted.
  local harness out rc=0 pos
  harness="$TMP_ROOT/retry-no-save-on-emit-harness.py"
  cat > "$harness" <<'PYEOF'
import os, signal, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
    'FM_MAIL_CURSOR': sys.argv[1],
    'FM_MAIL_RETRY': sys.argv[2],
    'FM_MAIL_RETRY_POS': sys.argv[3],
    'FM_MAIL_POLL_MAX_WAKES': '1',
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
            return ('OK', [b'81 82'])
        if cmd == 'fetch':
            # The first fetchable retry uid is emitted; the cursor does not
            # advance when a row is emitted, so a save would write the same
            # position. The kill wrapper proves save_retry_pos is still called
            # and flushed stdout survives it.
            return ('OK', [(b'', b'Subject: recovered\r\nFrom: bob@x.com\r\n\r\n')])
    def logout(self):
        pass
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[4])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
orig = mod.save_retry_pos
def save_then_kill(*a, **k):
    orig(*a, **k)
    os.kill(os.getpid(), signal.SIGKILL)
mod.save_retry_pos = save_then_kill
sys.exit(mod.cmd_poll_list())
PYEOF
  {
    printf 'uidvalidity=90009\n'
    printf '81\n82\n'
  } > "$HOME_DIR/state/.mail-seen"
  printf '81\n82\n' > "$HOME_DIR/state/.mail-retry"
  : > "$HOME_DIR/state/.mail-retry-pos"

  out=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-retry-pos" "$ROOT/bin/fm-mail.py" 2>&1) || rc=$?
  expect_code 0 "$rc" "poll_list must not call save_retry_pos when a row is emitted"
  assert_contains "$out" $'81\t\tbob@x.com\trecovered\tretry' \
    "the recovered row is emitted without persisting the position"
  pos=$(cat "$HOME_DIR/state/.mail-retry-pos" 2>/dev/null || printf '')
  assert_equals "" "$pos" "position must remain unchanged while a row is emitted"
  pass "fm-mail: retry-scan position is not saved when a row is emitted"
}

test_poll_retry_small_window_rotates_past_unfetchable_prefix() {
  # Greptile regression: when the retry set fits inside the scan window, the
  # durable position must still rotate the scan. A persistently unfetchable
  # leading uid must not monopolize the retry budget and strand later
  # recovered uids.
  local harness out rc=0 pos
  harness="$TMP_ROOT/retry-small-window-harness.py"
  cat > "$harness" <<'PYEOF'
import os, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
    'FM_MAIL_CURSOR': sys.argv[1],
    'FM_MAIL_RETRY': sys.argv[2],
    'FM_MAIL_RETRY_POS': sys.argv[3],
    # cap=4 -> window = max(4*4, 4+10) = 16, which is larger than the retry set.
    'FM_MAIL_POLL_MAX_WAKES': '4',
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
            return ('OK', [b'101 102 103 104 105'])
        if cmd == 'fetch':
            # 101 is persistently unfetchable; every other uid has recovered.
            if args[0] == b'101':
                return ('NO', None)
            return ('OK', [(b'', b'Subject: ok\r\nFrom: a@b.c\r\n\r\n')])
    def logout(self):
        pass
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[4])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(mod.cmd_poll_list())
PYEOF
  mkdir -p "$HOME_DIR/state"
  {
    printf 'uidvalidity=90009\n'
    for u in 101 102 103 104 105; do
      printf '%s\n' "$u"
    done
  } > "$HOME_DIR/state/.mail-seen"
  printf '101\n102\n103\n104\n105\n' > "$HOME_DIR/state/.mail-retry"
  : > "$HOME_DIR/state/.mail-retry-pos"

  # With the unfixed small-window branch, every poll would start at 101 and
  # emit 102 repeatedly; with the fix each recovered uid surfaces in turn.
  # The durable cursor advances only up to the first emitted uid, so the first
  # poll moves from 101 to 102 (index 1) and then stays there while recovered
  # uids are removed by the bash layer.
  for expected in 102 103 104 105; do
    local want
    rc=0
    out=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
      "$HOME_DIR/state/.mail-retry-pos" "$ROOT/bin/fm-mail.py" 2>&1) || rc=$?
    expect_code 0 "$rc" "poll for $expected must succeed"
    want=$(printf '%s\t\ta@b.c\tok\tretry' "$expected")
    assert_contains "$out" "$want" "recovered uid $expected surfaces after the unfetchable prefix"
    assert_not_contains "$out" $'101\t' "unfetchable uid 101 is not emitted as retry"
    pos=$(cat "$HOME_DIR/state/.mail-retry-pos" 2>/dev/null || printf '')
    assert_equals "1" "$pos" "cursor advances only up to the first emitted retry uid"
    # Simulate the bash layer removing the just-recovered uid from the retry set.
    grep -vx -e "$expected" "$HOME_DIR/state/.mail-retry" > "$HOME_DIR/state/.mail-retry.tmp" || true
    mv -f -- "$HOME_DIR/state/.mail-retry.tmp" "$HOME_DIR/state/.mail-retry"
  done

  # Only the unfetchable uid remains; an emission-free poll advances the
  # cursor so the scan does not stall.
  rc=0
  out=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-retry-pos" "$ROOT/bin/fm-mail.py" 2>&1) || rc=$?
  expect_code 0 "$rc" "poll with only the unfetchable uid must succeed"
  assert_not_contains "$out" $'101\t' "unfetchable uid still is not emitted"
  pos=$(cat "$HOME_DIR/state/.mail-retry-pos" 2>/dev/null || printf '')
  assert_equals "0" "$pos" "emission-free poll advances the position past the small window"

  # A non-zero starting position must rotate the small scan too: starting at
  # position 4 puts uid 105 first in the rotated order.
  printf '101\n102\n103\n104\n105\n' > "$HOME_DIR/state/.mail-retry"
  printf '4\n' > "$HOME_DIR/state/.mail-retry-pos"
  rc=0
  out=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-retry-pos" "$ROOT/bin/fm-mail.py" 2>&1) || rc=$?
  expect_code 0 "$rc" "wrap poll must succeed"
  assert_contains "$out" $'105\t\ta@b.c\tok\tretry' \
    "a non-zero starting position wraps within the small retry set"

  pass "fm-mail: small retry window rotates past an unfetchable prefix"
}

test_poll_cap_one_turn_not_saved_before_emit() {
  # At cap==1 with both new and retry candidates, the alternating turn must be
  # persisted only after the rows are emitted and flushed. A kill in the
  # logout/emit window must not advance the turn, so the next poll still gets
  # the new-mail turn it was owed.
  local harness out rc=0 turn
  harness="$TMP_ROOT/cap-one-turn-kill-harness.py"
  cat > "$harness" <<'PYEOF'
import os, signal, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
    'FM_MAIL_CURSOR': sys.argv[1],
    'FM_MAIL_RETRY': sys.argv[2],
    'FM_MAIL_TURN': sys.argv[3],
    'FM_MAIL_POLL_MAX_WAKES': '1',
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
            return ('OK', [b'90 100'])
        if cmd == 'fetch':
            return ('OK', [(b'', b'Subject: good\r\nFrom: a@b.c\r\n\r\n')])
    def logout(self):
        # Kill the process between the fetch decision and the emit/flush,
        # before the turn can be persisted.
        os.kill(os.getpid(), signal.SIGKILL)
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[4])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(mod.cmd_poll_list())
PYEOF
  {
    printf 'uidvalidity=90009\n'
    printf '90\n'
  } > "$HOME_DIR/state/.mail-seen"
  printf '90\n' > "$HOME_DIR/state/.mail-retry"
  : > "$HOME_DIR/state/.mail-turn"

  out=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-turn" "$ROOT/bin/fm-mail.py" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "poll_list must not exit 0 when logout is killed before emit"
  assert_not_contains "$out" $'100\t' "a killed logout must not emit rows"
  assert_not_contains "$out" $'90\t' "a killed logout must not emit rows"
  turn=$(cat "$HOME_DIR/state/.mail-turn" 2>/dev/null || printf '')
  assert_equals "" "$turn" "the alternating turn must not advance when emit is killed"
  pass "fm-mail: cap-one turn is not saved before emit/flush"
}

test_poll_cap_one_turn_not_saved_when_retry_pos_write_fails() {
  # At cap=1 on the retry turn, 81 is unfetchable and 82 is recovered, so the
  # durable retry-scan position must advance. If that write fails closed, the
  # poll must not spend the retry turn: the next successful poll still emits 82
  # instead of handing the slot to new mail.
  local harness out1 out2 turn rc1=0 rc2=0
  harness="$TMP_ROOT/cap-one-turn-pos-fail-harness.py"
  cat > "$harness" <<'PYEOF'
import os, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
    'FM_MAIL_CURSOR': sys.argv[1],
    'FM_MAIL_RETRY': sys.argv[2],
    'FM_MAIL_TURN': sys.argv[3],
    'FM_MAIL_RETRY_POS': sys.argv[4],
    'FM_MAIL_POLL_MAX_WAKES': '1',
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
            return ('OK', [b'81 82 100'])
        if cmd == 'fetch':
            if args[0] == b'81':
                return ('NO', None)
            return ('OK', [(b'', b'Subject: good\r\nFrom: a@b.c\r\n\r\n')])
    def logout(self):
        pass
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[5])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(mod.cmd_poll_list())
PYEOF
  {
    printf 'uidvalidity=90009\n'
    printf '81\n82\n'
  } > "$HOME_DIR/state/.mail-seen"
  printf '81\n82\n' > "$HOME_DIR/state/.mail-retry"
  printf '1\n' > "$HOME_DIR/state/.mail-turn"
  rm -f "$HOME_DIR/state/.mail-retry-pos"
  mkdir -p "$HOME_DIR/state/.mail-retry-pos"

  out1=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-turn" "$HOME_DIR/state/.mail-retry-pos" "$ROOT/bin/fm-mail.py" 2>&1) || rc1=$?
  [ "$rc1" -ne 0 ] || fail "poll_list must fail closed when retry-pos cannot be written"
  turn=$(cat "$HOME_DIR/state/.mail-turn" 2>/dev/null || printf '')
  assert_equals "1" "$turn" "a failed retry-pos write must not spend the retry turn"

  rmdir "$HOME_DIR/state/.mail-retry-pos"
  : > "$HOME_DIR/state/.mail-retry-pos"
  out2=$(python3 "$harness" "$HOME_DIR/state/.mail-seen" "$HOME_DIR/state/.mail-retry" \
    "$HOME_DIR/state/.mail-turn" "$HOME_DIR/state/.mail-retry-pos" "$ROOT/bin/fm-mail.py" 2>&1) || rc2=$?
  expect_code 0 "$rc2" "the next poll after a fail-closed position write must succeed"
  assert_contains "$out2" $'82\t\ta@b.c\tgood\tretry' "the unspent retry turn still surfaces recovered uid 82"
  assert_not_contains "$out2" $'100\t' "new mail must not take the unspent retry turn"
  pass "fm-mail: a failed retry-pos write does not spend the cap-one retry turn"
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
  assert_contains "$out" $'1\t\t(no header)\tunfetchable header - see fm-mail read\tdegraded' \
    "the unfetchable uid is still surfaced degraded, not missed"
  assert_contains "$out" $'2\t\ta@b.c\tgood\tok' \
    "a later uid surfaces as ok despite the earlier failure"
  pass "fm-mail: an unfetchable uid is surfaced degraded and cannot starve later mail"
}

test_poll_retries_transient_fetch_and_surfaces_real_metadata() {
  local fakebin homedir_bin real_py harness retry_home control out rc=0 wakeq
  fakebin=$(fm_fakebin "$TMP_ROOT")
  retry_home="$TMP_ROOT/retry-home"
  homedir_bin="$retry_home/bin"
  mkdir -p "$homedir_bin" "$retry_home/state"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"
  real_py=$(command -v python3)
  harness="$TMP_ROOT/retry-poll-harness.py"
  control="$TMP_ROOT/retry-fetch-count"
  printf '0' > "$control"

  # Drive the real poll_list through a stubbed IMAP connection whose header
  # fetch fails on the first two polls and succeeds on the third, proving a
  # transient failure surfaces degraded once, does not re-wake while still
  # failing, then recovers the real From/Subject and leaves the retry set.
  cat > "$harness" <<'PYEOF'
import imaplib, importlib.util, os, sys

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
            return ('OK', [b'41'])
        if cmd == 'fetch':
            n = int(open(os.environ['FM_MAIL_TEST_FETCH_COUNT']).read() or '0')
            if n < 3:
                return ('NO', None)
            return ('OK', [(b'', b'Subject: Hello captain\r\nFrom: alice@example.com\r\nDate: 5 Sep 2026 00:00:00 +0000\r\n\r\n')])
        return ('NO', None)
    def logout(self):
        pass

imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
if len(sys.argv) > 2 and sys.argv[2] == 'poll_list':
    path = os.environ['FM_MAIL_TEST_FETCH_COUNT']
    n = int(open(path).read() or '0')
    open(path, 'w').write(str(n + 1))
    sys.exit(mod.cmd_poll_list())
sys.exit(1)
PYEOF
  cat > "$fakebin/python3" <<EOF
#!/bin/bash
exec "$real_py" "$harness" "\$@"
EOF
  chmod +x "$fakebin/python3"
  printf 'uidvalidity=90009\n' > "$retry_home/state/.mail-seen"
  : > "$retry_home/state/.wake-queue"

  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$retry_home" PATH="$fakebin:$PATH" \
    FM_MAIL_TEST_FETCH_COUNT="$control" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "first poll of a failing fetch must succeed"
  assert_contains "$out" "woke for 41" "failed fetch still wakes once, never missed"
  assert_contains "$(cat "$retry_home/state/.wake-queue")" "(no header)" \
    "first wake uses the degraded sender placeholder"
  assert_contains "$(cat "$retry_home/state/.wake-queue")" "unfetchable header" \
    "first wake uses the degraded subject placeholder"
  assert_contains "$(cat "$retry_home/state/.mail-retry" 2>/dev/null)" "41" \
    "the uid is recorded for retry after the degraded wake"
  assert_contains "$(cat "$retry_home/state/.mail-seen")" "41" \
    "the degraded surfacing is still cursor-recorded"

  rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$retry_home" PATH="$fakebin:$PATH" \
    FM_MAIL_TEST_FETCH_COUNT="$control" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "still-failing retry poll must succeed"
  assert_not_contains "$out" "woke for 41" "a still-unfetchable retry uid must not re-wake"
  assert_contains "$out" "no new mail" "a still-unfetchable retry poll reports no new mail"
  assert_contains "$(cat "$retry_home/state/.mail-retry" 2>/dev/null)" "41" \
    "the uid stays in the retry set while the fetch keeps failing"
  wakeq=$(grep -c "check: mail" "$retry_home/state/.wake-queue" 2>/dev/null || true)
  expect_code 1 "$wakeq" "still-failing retry must not append a second wake"

  rc=0
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$retry_home" PATH="$fakebin:$PATH" \
    FM_MAIL_TEST_FETCH_COUNT="$control" \
    "$MAIL" poll 2>&1) || rc=$?
  if [ "$rc" != 0 ]; then
    printf 'poll output on failure:\n%s\n' "$out" >&2
    fail "recovered fetch poll must succeed: expected exit 0, got $rc"
  fi
  assert_contains "$out" "woke for 41" "recovered fetch wakes with the real metadata"
  assert_contains "$(cat "$retry_home/state/.wake-queue")" "alice@example.com" \
    "recovered wake names the real sender"
  assert_contains "$(cat "$retry_home/state/.wake-queue")" "Hello captain" \
    "recovered wake names the real subject"
  assert_not_contains "$(cat "$retry_home/state/.mail-retry" 2>/dev/null || true)" "41" \
    "the uid leaves the retry set after a successful fetch"
  wakeq=$(grep -c "check: mail" "$retry_home/state/.wake-queue" 2>/dev/null || true)
  expect_code 2 "$wakeq" "degraded then recovered metadata are two wakes"
  pass "fm-mail: a transient fetch failure recovers real metadata on a later poll"
}

test_poll_keeps_journal_when_heal_cannot_record() {
  local fakebin homedir_bin out rc=0
  fakebin=$(fm_fakebin "$TMP_ROOT")
  homedir_bin="$HOME_DIR/bin"
  mkdir -p "$homedir_bin"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"

  # No unseen mail; the poll only heals the seeded journal entry.
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t90009\n'
SH
  chmod +x "$fakebin/python3"
  printf 'uidvalidity=90009\n' > "$HOME_DIR/state/.mail-seen"
  printf '%s\t%s\n' '90009' '55' > "$HOME_DIR/state/.mail-woken"
  chmod 0400 "$HOME_DIR/state/.mail-seen"

  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "poll must fail when the heal cannot record a uid"
  assert_contains "$out" "heal could not record a uid" "poll reports the unrecordable heal"
  assert_contains "$(cat "$HOME_DIR/state/.mail-woken" 2>/dev/null)" "55" "journal evidence survives an unrecordable heal"
  chmod 0600 "$HOME_DIR/state/.mail-seen"
  pass "fm-mail: the journal survives when the heal cannot commit a uid"
}

test_poll_heal_failure_does_not_rewake_unseen_mail() {
  local fakebin homedir_bin heal_home out rc=0
  fakebin=$(fm_fakebin "$TMP_ROOT")
  heal_home="$TMP_ROOT/heal-fail-home"
  homedir_bin="$heal_home/bin"
  mkdir -p "$homedir_bin" "$heal_home/state"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"

  # Journal names uid 55; the cursor cannot be appended to; IMAP still lists
  # 55 as UNSEEN. The poll must fail closed before the wake loop so the uid
  # is not surfaced a second time.
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf 'uidvalidity\t90009\n'
printf '55\t2026-09-05T00:00:00Z\talice@example.com\tHello\n'
SH
  chmod +x "$fakebin/python3"
  printf 'uidvalidity=90009\n' > "$heal_home/state/.mail-seen"
  printf '%s\t%s\n' '90009' '55' > "$heal_home/state/.mail-woken"
  : > "$heal_home/state/.wake-queue"
  chmod 0400 "$heal_home/state/.mail-seen"

  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$heal_home" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "heal failure with unseen mail must fail the poll"
  assert_not_contains "$out" "woke for 55" "heal failure must not re-wake a journaled uid"
  assert_contains "$(cat "$heal_home/state/.mail-woken" 2>/dev/null)" "55" "journal evidence is kept"
  local wakeq
  wakeq=$(grep -c "check: mail 55" "$heal_home/state/.wake-queue" 2>/dev/null || true)
  expect_code 0 "$wakeq" "heal failure must not append a second wake"
  chmod 0600 "$heal_home/state/.mail-seen"
  pass "fm-mail: heal failure with unseen mail fails the poll instead of re-waking"
}

test_body_preview_falls_back_from_empty_plain() {
  local harness out
  harness="$TMP_ROOT/body-preview-harness.py"
  cat > "$harness" <<'PYEOF'
import os, sys
os.environ.update({'FM_MAIL_USER':'t','FM_MAIL_PASS':'p','FM_IMAP_HOST':'h','FM_IMAP_PORT':'993','FM_SMTP_HOST':'s','FM_SMTP_PORT':'465'})
import email, importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
msg = email.message_from_string(
    "Content-Type: multipart/alternative; boundary=b\r\n\r\n"
    "--b\r\nContent-Type: text/plain\r\n\r\n\r\n"
    "--b\r\nContent-Type: text/html\r\n\r\n<p>Hello</p>\r\n"
    "--b--\r\n")
print(mod.body_preview(msg))
PYEOF
  out=$(python3 "$harness" "$ROOT/bin/fm-mail.py")
  assert_contains "$out" "Hello" "empty plain-text alternative falls back to the html preview"
  pass "fm-mail: an empty plain-text alternative falls back to the html preview"
}

test_body_preview_tolerates_none_payload() {
  local harness out rc=0
  harness="$TMP_ROOT/none-payload-harness.py"
  cat > "$harness" <<'PYEOF'
import os, sys
os.environ.update({'FM_MAIL_USER':'t','FM_MAIL_PASS':'p','FM_IMAP_HOST':'h','FM_IMAP_PORT':'993','FM_SMTP_HOST':'s','FM_SMTP_PORT':'465'})
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

class NonePart:
    def walk(self):
        yield self
    def get_content_type(self):
        return 'text/plain'
    def get_payload(self, decode=True):
        return None

print(repr(mod.body_preview(NonePart())))
PYEOF
  out=$(python3 "$harness" "$ROOT/bin/fm-mail.py") || rc=$?
  expect_code 0 "$rc" "None payload must not crash body_preview"
  assert_contains "$out" "''" "None payload yields an empty preview"
  pass "fm-mail: body_preview does not crash on a None payload"
}

test_read_surfaces_unfetchable_uid() {
  local harness out rc=0
  harness="$TMP_ROOT/read-unfetchable-harness.py"
  cat > "$harness" <<'PYEOF'
import os, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
})
class FakeConn:
    def __init__(self, *a, **k):
        pass
    def login(self, *a):
        pass
    def select(self, *a):
        return ('OK', [])
    def uid(self, cmd, *args):
        if cmd == 'search':
            return ('OK', [b'7 8'])
        if cmd == 'fetch':
            if args[0] == b'7':
                return ('NO', None)
            return ('OK', [(b'', b'From: a@b.c\r\nSubject: ok\r\n\r\nplain body\r\n')])
        return ('NO', None)
    def logout(self):
        pass
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(mod.cmd_read())
PYEOF
  out=$(python3 "$harness" "$ROOT/bin/fm-mail.py" 2>&1) || rc=$?
  expect_code 0 "$rc" "read must succeed when one uid is unfetchable"
  assert_contains "$out" "Uid: 7" "unfetchable uid is still named"
  assert_contains "$out" "unfetchable body" "unfetchable uid is reported degraded"
  assert_contains "$out" "Body: (body unavailable)" "degraded fetch row always prints a Body line"
  assert_contains "$out" "Subj: ok" "a later fetchable uid is still shown"
  pass "fm-mail: read does not silently hide an unfetchable uid"
}

test_read_tolerates_none_payload() {
  local harness out rc=0
  harness="$TMP_ROOT/read-none-payload-harness.py"
  cat > "$harness" <<'PYEOF'
import os, sys
os.environ.update({
    'FM_MAIL_USER': 't', 'FM_MAIL_PASS': 'p',
    'FM_IMAP_HOST': 'imap.test', 'FM_IMAP_PORT': '993',
    'FM_SMTP_HOST': 'smtp.test', 'FM_SMTP_PORT': '465',
})
class FakeConn:
    def __init__(self, *a, **k):
        pass
    def login(self, *a):
        pass
    def select(self, *a):
        return ('OK', [])
    def uid(self, cmd, *args):
        if cmd == 'search':
            return ('OK', [b'9'])
        if cmd == 'fetch':
            # imaplib may return a tuple whose payload bytes are None.
            return ('OK', [(b'', None)])
        return ('NO', None)
    def logout(self):
        pass
import imaplib
imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
import importlib.util
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(mod.cmd_read())
PYEOF
  out=$(python3 "$harness" "$ROOT/bin/fm-mail.py" 2>&1) || rc=$?
  expect_code 0 "$rc" "read must succeed when the fetch payload is None"
  assert_contains "$out" "Uid: 9" "None-payload uid is still named"
  assert_contains "$out" "Body: (body unavailable)" "None-payload degraded row prints a Body line"
  pass "fm-mail: read tolerates a None payload without crashing"
}

test_ports_must_be_in_range() {
  local name value out rc
  for name in FM_IMAP_PORT FM_SMTP_PORT; do
    for value in 0 65536 abc; do
      rc=0
      out=$(env FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=h FM_SMTP_HOST=h \
        "$name=$value" FM_HOME="$HOME_DIR" "$MAIL" status 2>&1) || rc=$?
      expect_code 1 "$rc" "$name=$value must fail"
      assert_contains "$out" "$name must be an integer from 1 through 65535" "$name range error is explicit"
      assert_not_contains "$out" "ValueError" "invalid port must not leak a python traceback"
    done
    for value in 1 65535; do
      out=$(env FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=h FM_SMTP_HOST=h \
        "$name=$value" FM_HOME="$HOME_DIR" "$MAIL" status 2>&1) \
        || fail "$name=$value should be accepted: $out"
    done
  done
  pass "fm-mail: IMAP and SMTP ports enforce the inclusive valid range"
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
  local fakebin homedir_bin real_py harness
  fakebin=$(fm_fakebin "$TMP_ROOT")
  homedir_bin="$HOME_DIR/bin"
  mkdir -p "$homedir_bin"
  [ -e "$homedir_bin/fm-wake-lib.sh" ] || ln -s "$ROOT/bin/fm-wake-lib.sh" "$homedir_bin/fm-wake-lib.sh"
  real_py=$(command -v python3)
  harness="$TMP_ROOT/sanitize-poll-harness.py"

  # Drive the real poll_list/clean path through a stubbed IMAP connection so a
  # tab in Subject and an RFC-2047-encoded newline cannot split the TSV or
  # inject a forged uid for the bash wake loop.
  cat > "$harness" <<'PYEOF'
import imaplib, importlib.util, sys

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
            return ('OK', [b'60 61'])
        if cmd == 'fetch':
            if args[0] == b'60':
                return ('OK', [(b'', b'Subject: Tab\there\r\nFrom: alice@example.com\r\nDate: 5 Sep 2026 00:00:00 +0000\r\n\r\n')])
            # RFC-2047 payload of "Line\n99\tfake" so decode keeps the newline
            # and tab; clean() must collapse them or bash would wake forged uid 99.
            raw = b'Subject: =?utf-8?b?TGluZQo5OQlmYWtl?=\r\nFrom: alice@example.com\r\nDate: 5 Sep 2026 00:00:00 +0000\r\n\r\n'
            return ('OK', [(b'', raw)])
        return ('NO', None)
    def logout(self):
        pass

imaplib.IMAP4_SSL = lambda *a, **k: FakeConn()
spec = importlib.util.spec_from_file_location('fm_mail', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
if len(sys.argv) > 2 and sys.argv[2] == 'poll_list':
    sys.exit(mod.cmd_poll_list())
sys.exit(1)
PYEOF
  cat > "$fakebin/python3" <<EOF
#!/bin/bash
exec "$real_py" "$harness" "\$@"
EOF
  chmod +x "$fakebin/python3"
  printf 'uidvalidity=90009\n' > "$HOME_DIR/state/.mail-seen"
  : > "$HOME_DIR/state/.wake-queue"

  local out rc=0 wakeq
  out=$(FM_MAIL_USER=test FM_MAIL_PASS=pass FM_IMAP_HOST=imap.test FM_SMTP_HOST=smtp.test \
    FM_HOME="$HOME_DIR" PATH="$fakebin:$PATH" \
    "$MAIL" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "sanitizing poll must succeed"
  assert_contains "$out" "woke for 60" "tab-bearing subject still wakes once"
  assert_contains "$out" "woke for 61" "newline-bearing subject still wakes once"
  assert_not_contains "$out" "woke for 99" "a newline in Subject must not inject a forged uid"
  assert_not_contains "$out" "woke for fake" "a tab in Subject must not inject a forged uid"
  wakeq=$(grep -c "check: mail" "$HOME_DIR/state/.wake-queue" 2>/dev/null || true)
  expect_code 2 "$wakeq" "exactly the two real uids wake"
  assert_contains "$(cat "$HOME_DIR/state/.wake-queue")" "mail:90009/60" "wake key is the real uid 60"
  assert_contains "$(cat "$HOME_DIR/state/.wake-queue")" "mail:90009/61" "wake key is the real uid 61"
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
test_whitespace_only_required_settings_fail
test_env_overrides_env_file
test_status_without_network
test_help_plumbing
test_unknown_subcommand_prints_usage
test_no_secret_leaked_to_status
test_send_passes_body
test_poll_error_propagates
test_poll_dedupes_surfaces_by_uid
test_poll_records_ignored_and_deferred_without_waking
test_poll_resurfaces_uid_after_generation_change
test_poll_heals_wake_without_cursor_record
test_poll_duplicate_wakes_on_interrupted_poll
test_poll_serializes_overlapping_invocations
test_poll_recovers_journaled_wake_after_ack
test_poll_acknowledged_wake_evading_recovery
test_poll_legacy_wake_does_not_leak_into_generation
test_poll_missing_wake_lib_does_not_suppress
test_poll_rolls_back_wake_without_durable_record
test_poll_rollback_failure_never_leaves_unrecorded_ackable_wake
test_poll_caps_wakes_per_run
test_poll_sanitizes_header_fields
test_poll_bounded_fetch_progresses_large_backlog
test_poll_skips_unfetchable_uid_but_keeps_progress
test_poll_retries_transient_fetch_and_surfaces_real_metadata
test_poll_retry_cursor_advances_past_failures
test_poll_retry_position_does_not_advance_past_unpublished_wake
test_poll_retry_budget_advances_by_examined_not_window
test_poll_retry_window_of_unseen_never_stalls_cursor
test_poll_retry_unfetchable_window_advances_with_new_mail
test_poll_retry_unseen_window_advances_with_new_mail
test_poll_retry_logout_before_emit_and_position_save
test_poll_list_logs_out_on_imap_error
test_poll_retry_position_not_saved_when_row_emitted
test_poll_retry_small_window_rotates_past_unfetchable_prefix
test_poll_cap_one_turn_not_saved_before_emit
test_poll_cap_one_turn_not_saved_when_retry_pos_write_fails
test_away_spoofed_owner_backlog_cannot_block_reply
test_away_retry_mail_examined_once
test_away_owner_read_failures_retry_then_alert
test_away_cursor_commits_only_after_publication
test_away_poll_budget_bounds_wall_clock
test_poll_retry_surfaces_under_new_mail_flood
test_poll_resurfaces_degraded_uid_whose_wake_never_recorded
test_poll_cap_one_never_suppresses_new_mail
test_poll_cap_one_alternates_new_and_retry
test_poll_cap_one_does_not_advance_unexamined_retry_window
test_poll_fails_closed_when_retry_unwritable
test_poll_journal_failure_never_cursor_records
test_poll_fails_closed_when_retry_clear_fails
test_poll_fails_closed_when_stale_retry_clear_fails
test_assert_equals_rejects_mismatch
test_poll_fails_closed_when_poll_list_fails
test_poll_restores_retry_when_recovered_wake_cannot_append
test_poll_death_between_retry_remove_and_publish_does_not_strand
test_poll_fetch_raise_does_not_abort_the_scan
test_poll_keeps_journal_when_heal_cannot_record
test_poll_heal_failure_does_not_rewake_unseen_mail
test_body_preview_falls_back_from_empty_plain
test_body_preview_tolerates_none_payload
test_read_tolerates_none_payload
test_read_surfaces_unfetchable_uid
test_ports_must_be_in_range
