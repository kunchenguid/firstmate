#!/usr/bin/env bash
# tests/fm-afk-email.test.sh - Pi away-email configuration, batching, and reply trust.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-email-tests)
REPO="$TMP_ROOT/repo"
mkdir -p "$REPO"
cp -R "$ROOT/bin" "$REPO/bin"
CAPTURE="$TMP_ROOT/sent"
mkdir -p "$CAPTURE"
export CAPTURE
cat > "$REPO/bin/fm-mail.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = send ] || exit 2
count=$(find "$CAPTURE" -maxdepth 1 -name '*.txt' | wc -l | tr -d ' ')
path="$CAPTURE/$count.txt"
printf 'to=%s\nsubject=%s\n' "$2" "$3" > "$path"
cat >> "$path"
printf 'fake SMTP accepted\n' >&2
SH
chmod 700 "$REPO/bin/fm-mail.sh"
cat > "$REPO/bin/fm-harness.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_TEST_HARNESS:-pi}"
SH
chmod 700 "$REPO/bin/fm-harness.sh"

make_home() {  # <name> [configured]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  if [ "${2:-}" = configured ]; then
    cat > "$home/.env" <<'ENV'
FM_MAIL_USER=owner@example.com
FM_MAIL_PASS=mail-secret-not-to-leak
FM_IMAP_HOST=imap.example.test
FM_SMTP_HOST=smtp.example.test
FM_AFK_EMAIL_TO=owner@example.com
ENV
  fi
  printf '%s\n' "$home"
}

run_contract() {  # <home> [extra env assignments are supplied by caller]
  local home=$1
  shift
  env -u CLAUDECODE -u CURSOR_AGENT -u GEMINI_CLI -u FM_OMP_HARNESS \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$REPO" \
    "$@" "$REPO/bin/fm-afk-contract.sh" enter
}

run_email() {  # <home> <command>
  local home=$1 command=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$REPO" \
    python3 "$REPO/bin/fm-afk-email.py" "$command" "$@"
}

write_outcomes() {  # <home> <entry epoch>
  local home=$1 entered=$2
  cat > "$home/state/branch-outcomes.jsonl" <<EOF
{"seq":1,"epoch":$((entered + 1)),"task":"ui","wake":"check","verdict":"captain","summary":"PR https://github.com/example/ui/pull/17 is ready; leaked value mail-secret-not-to-leak","silent":false}
{"seq":2,"epoch":$((entered + 2)),"task":"api","wake":"check","verdict":"captain","summary":"The API fix needs your decision","silent":false}
EOF
  printf '0\n' > "$home/state/.branch-outcomes-processed"
}

message() {  # <home> <uid> <sender> <subject> <body>
  local home=$1 uid=$2 sender=$3 subject=$4 body=$5
  printf '[{"uidvalidity":"44","uid":"%s","from":%s,"subject":%s,"body":%s}]\n' \
    "$uid" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$sender")" \
    "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$subject")" \
    "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$body")" \
    | run_email "$home" receive-batch
}

count_sends() {
  find "$CAPTURE" -maxdepth 1 -name '*.txt' -type f | wc -l | tr -d ' '
}

# Missing mail values and non-Pi primaries keep hold-for-return with no private email state.
test_unconfigured_and_non_pi_retain_existing_behavior() {
  local home out
  home=$(make_home unconfigured)
  out=$(run_contract "$home" FM_TEST_HARNESS=pi 2>&1) || fail "unconfigured Pi entry failed: $out"
  assert_contains "$out" 'hold-for-return only. No phone channel is configured; anything that needs you waits for your return.' 'unconfigured announcement is unchanged'
  [ "$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$REPO/bin/fm-afk-contract.sh" field reach_channels)" = none ] \
    || fail "unconfigured posture selected email reach"
  [ ! -e "$home/state/afk-email" ] || fail "unconfigured entry created email state"
  out=$(run_email "$home" queue-unprocessed 2>&1) || fail "unconfigured queue check failed: $out"
  [ -z "$out" ] || fail "unconfigured email queue was not silent: $out"

  home=$(make_home non-pi configured)
  out=$(run_contract "$home" FM_TEST_HARNESS=claude 2>&1) || fail "non-Pi entry failed: $out"
  [ "$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$REPO/bin/fm-afk-contract.sh" field reach_channels)" = none ] \
    || fail "non-Pi posture claimed Pi email delivery"
  pass "unconfigured and non-Pi away entries preserve hold-for-return without creating email state"
}

test_batched_mail_redacts_secrets_and_replies_are_item_bound() {
  local home out entered body reply_body token1 token2 sent1 sent2 inbox note
  home=$(make_home configured configured)
  out=$(run_contract "$home" FM_TEST_HARNESS=pi 2>&1) || fail "configured Pi entry failed: $out"
  assert_contains "$out" 'email reach active.' 'configured Pi entry announces email reach'
  assert_contains "$out" 'Captain-facing outcomes are emailed to the configured address' 'record announces email delivery'
  [ "$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$REPO/bin/fm-afk-contract.sh" field reach_channels)" = email ] \
    || fail "configured Pi posture did not record email reach"
  entered=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$REPO/bin/fm-afk-contract.sh" field entered_epoch)
  write_outcomes "$home" "$entered"

  out=$(run_email "$home" queue-unprocessed) || fail "queueing outcomes failed: $out"
  assert_contains "$out" 'queued 2 away-email item(s)' 'both captain-facing outcomes are queued'
  out=$(run_email "$home" flush) || fail "flush failed: $out"
  assert_contains "$out" 'sent 2 away-email item(s)' 'outcomes are sent in one batch'
  [ "$(count_sends)" = 1 ] || fail "a burst was sent as more than one email"
  sent1="$home/state/afk-email/sent/1.json"
  sent2="$home/state/afk-email/sent/2.json"
  [ -f "$sent1" ] && [ -f "$sent2" ] || fail "sent item records were not retained"
  body=$(awk 'f { print } /^subject=/ { f=1; next }' "$CAPTURE/0.txt")
  assert_contains "$body" 'https://github.com/example/ui/pull/17' 'the original full PR URL is preserved'
  assert_not_contains "$body" 'mail-secret-not-to-leak' 'mail credentials are never included in outcome email'
  assert_contains "$body" 'Email replies never authorize destructive, irreversible, or security-sensitive actions' 'the safety limit is in the footer'
  token1=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token_hash"])' "$sent1")
  token2=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token_hash"])' "$sent2")
  [ "$token1" != "$token2" ] || fail "each outcome did not receive a distinct code"
  token1=$(grep -oE 'FM-AFK-[A-Za-z0-9_-]{16}' "$CAPTURE/0.txt" | sed -n '1p')
  token2=$(grep -oE 'FM-AFK-[A-Za-z0-9_-]{16}' "$CAPTURE/0.txt" | sed -n '2p')
  [ -n "$token1" ] && [ -n "$token2" ] && [ "$token1" != "$token2" ] || fail "the batch omitted distinct per-item reply codes"

  printf '{"seq":3,"epoch":%s,"task":"extra","wake":"check","verdict":"captain","summary":"another outcome","silent":false}\n' "$((entered + 3))" >> "$home/state/branch-outcomes.jsonl"
  out=$(run_email "$home" queue-unprocessed) || fail "queueing the next outcome failed: $out"
  out=$(run_email "$home" flush) || fail "rate-limited flush failed: $out"
  assert_contains "$out" 'deferred ' 'outbound batches obey the send-rate limit'
  [ "$(count_sends)" = 1 ] || fail "a second message bypassed the rate limit"

  reply_body=$(printf 'FM-AFK-REPLY %s\nmerge the PR' "$token1")
  out=$(message "$home" 100 'spoof@example.com' 'Re: Firstmate away update' "$reply_body" 2>&1) \
    || fail "spoofed mail handoff errored: $out"
  assert_contains "$out" 'received 0 verified and 1 untrusted' 'a mismatched sender is surfaced as untrusted'
  [ -z "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("used_epoch", ""))' "$sent1")" ] \
    || fail "spoofed sender consumed the valid item code"
  inbox="$home/state/inbox"
  note=$(find "$inbox" -maxdepth 1 -name '*.note' -print -quit)
  [ -n "$note" ] || fail "spoofed email was not surfaced in the existing inbox"
  assert_contains "$(cat "$note")" 'Untrusted email during away mode' 'the inbox marks spoofed mail untrusted'
  assert_not_contains "$(cat "$note")" 'merge the PR' 'untrusted message contents are not handed to the away agent'
  note_id=$(basename "$note" .note)
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$REPO" "$REPO/bin/fm-inbox.sh" drain --ack "$note_id" >/dev/null \
    || fail "could not acknowledge untrusted notification"

  reply_body=$(printf 'FM-AFK-REPLY %s\nPlease merge the UI pull request' "$token1")
  out=$(message "$home" 101 'owner@example.com' 'Re: Firstmate away update' "$reply_body" 2>&1) \
    || fail "valid reply handoff errored: $out"
  assert_contains "$out" 'received 1 verified and 0 untrusted' 'matching sender and code are accepted'
  note=$(find "$inbox" -maxdepth 1 -name '*.note' -print -quit)
  [ -n "$note" ] || fail "accepted reply did not enter the existing inbox"
  assert_contains "$(cat "$note")" 'outcome seq 1 on task ui only' 'the reply is bound to its exact outcome'
  assert_contains "$(cat "$note")" 'Please merge the UI pull request' 'the captain words reach the inbox'
  [ -n "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("used_epoch", ""))' "$sent1")" ] \
    || fail "accepted code was not marked consumed"

  reply_body=$(printf 'FM-AFK-REPLY %s\nrepeat answer' "$token1")
  out=$(message "$home" 102 'owner@example.com' 'Re: Firstmate away update' "$reply_body" 2>&1) \
    || fail "replayed code handoff errored: $out"
  assert_contains "$out" 'received 0 verified and 1 untrusted' 'a one-time code cannot be replayed'
  pass "captain outcomes batch with full URLs and redaction, while reply codes are item-bound, one-use, and sender-checked"
}

test_expired_and_unknown_codes_are_untrusted() {
  local home out entered token sent reply_body
  home=$(make_home expiry configured)
  run_contract "$home" FM_TEST_HARNESS=pi >/dev/null 2>&1 || fail "configured entry failed"
  entered=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$REPO/bin/fm-afk-contract.sh" field entered_epoch)
  write_outcomes "$home" "$entered"
  run_email "$home" queue-unprocessed >/dev/null || fail "queue failed"
  run_email "$home" flush >/dev/null || fail "flush failed"
  sent="$home/state/afk-email/sent/1.json"
  token=$(grep -oE 'FM-AFK-[A-Za-z0-9_-]{16}' "$CAPTURE/1.txt" | sed -n '1p')
  python3 - "$sent" <<'PY'
import json, sys
path = sys.argv[1]
item = json.load(open(path))
item['expires_epoch'] = 1
json.dump(item, open(path, 'w'))
PY
  reply_body=$(printf 'FM-AFK-REPLY %s\nlate answer' "$token")
  out=$(message "$home" 201 'owner@example.com' 'reply' "$reply_body" 2>&1) \
    || fail "expired code handoff errored: $out"
  assert_contains "$out" 'received 0 verified and 1 untrusted' 'expired code is rejected'
  out=$(message "$home" 202 'owner@example.com' 'reply' $'FM-AFK-REPLY FM-AFK-AAAAAAAAAAAAAAAA\nunknown answer' 2>&1) \
    || fail "unknown code handoff errored: $out"
  assert_contains "$out" 'received 0 verified and 1 untrusted' 'unknown code is rejected'
  pass "expired and unknown correlation codes are surfaced as untrusted mail"
}

test_unconfigured_and_non_pi_retain_existing_behavior
# The active feature is tested with synthetic mail and a local fake SMTP command; no network or mailbox is used.
test_batched_mail_redacts_secrets_and_replies_are_item_bound
test_expired_and_unknown_codes_are_untrusted
