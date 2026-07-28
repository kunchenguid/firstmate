#!/usr/bin/env bash
# Behavior tests for the private Telegram bridge: the poll client
# (fm-tg-poll.sh), the pairing surface (fm-tg-pair.sh), the reply client
# (fm-tg-reply.sh), the task link and publish gate (fm-tg-task.sh), bootstrap
# activation, watcher dispatch, and supervision eligibility.
#
# The bridge must be INERT by default (no token -> the poll is a hard no-op and
# bootstrap writes and prints nothing) and additive when on. The Bot API is
# served by the hermetic fake local server in tests/telegram-helpers.sh: no
# network, no port, and no real token anywhere in this suite. jq stays the real
# tool.
#
# SC2016 is disabled file-wide: several fixtures deliberately contain literal
# $(...) and backticks, because the point is that a message body is never
# expanded by anything.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/telegram-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/telegram-helpers.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-telegram-bridge-tests)

POLL="$ROOT/bin/fm-tg-poll.sh"
PAIR="$ROOT/bin/fm-tg-pair.sh"
REPLY="$ROOT/bin/fm-tg-reply.sh"
TGTASK="$ROOT/bin/fm-tg-task.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"

TEST_TOKEN='1234567890:AAHfake-test-token-not-a-real-one'
PEER_ID=555001
OTHER_ID=999002

# Run any bridge script against <home> with the fake Bot API on PATH.
tg_run() {  # <home> <fakebin> <script> [args...]
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" "$@"
}

# Count files in a directory without depending on `ls` output parsing.
count_files() {
  local dir=$1 n
  [ -d "$dir" ] || { printf '0'; return 0; }
  n=$(find "$dir" -type f -name '*.json' 2>/dev/null | wc -l | tr -d '[:space:]')
  printf '%s' "${n:-0}"
}

path_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

# Build a home that is already paired, by queueing and redeeming a real code.
# Sets HOME_DIR and FAKEBIN in the caller, and leaves FAKE_TG_DIR exported, so
# it must be called directly rather than in a command substitution.
paired_home() {  # <name>
  local name=$1 dir code
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir"
  tg_fake_api "$dir"
  FAKEBIN=$TG_FAKEBIN
  HOME_DIR=$(tg_home "$dir" home "$TEST_TOKEN")
  code=$(tg_run "$HOME_DIR" "$FAKEBIN" "$PAIR" begin --label eren --project eren-pov-site \
    | sed -n 's|^  /start ||p')
  tg_queue 100 "$PEER_ID" "$PEER_ID" "/start $code"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
}

# --- inert by default -------------------------------------------------------

test_absent_config_is_a_complete_no_op() {
  local dir home fakebin out
  dir="$TMP_ROOT/inert"
  mkdir -p "$dir"
  tg_fake_api "$dir"
  fakebin=$TG_FAKEBIN
  home=$(tg_home "$dir" home "")

  out=$(tg_run "$home" "$fakebin" "$POLL" 2>&1)
  [ -z "$out" ] || fail "poll printed something with no token configured: $out"
  assert_absent "$home/state/telegram" "poll created bridge state with no token"
  [ ! -s "$FAKE_TG_DIR/calls.log" ] || fail "poll contacted the Bot API with no token"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_BOOTSTRAP_DETECT_ONLY=1 "$BOOTSTRAP" 2>&1 || true)
  assert_not_contains "$out" "FMTG:" "bootstrap mentioned the bridge for an unconfigured home"
  assert_absent "$home/state/telegram-watch.check.sh" "bootstrap armed a poll with no token"
  assert_absent "$home/config/telegram.env" "bootstrap wrote a cadence file with no token"
  pass "absent config is a zero-behavior no-op: nothing written, nothing printed, nothing contacted"
}

test_malformed_token_is_refused_without_echoing_it() {
  local dir home fakebin out
  dir="$TMP_ROOT/badtoken"
  mkdir -p "$dir"
  tg_fake_api "$dir"
  fakebin=$TG_FAKEBIN
  home=$(tg_home "$dir" home 'not-a-real-token-shape')

  out=$(tg_run "$home" "$fakebin" "$POLL" 2>&1)
  assert_contains "$out" "telegram-error" "a malformed token was not reported"
  assert_not_contains "$out" "not-a-real-token-shape" "the malformed token value was echoed"
  [ ! -s "$FAKE_TG_DIR/calls.log" ] || fail "a malformed token still reached the Bot API"
  pass "a malformed bot token is refused before any request, and never echoed"
}

# --- token secrecy and file permissions -------------------------------------

test_token_never_reaches_argv_or_state() {
  local leaked
  paired_home secrecy
  tg_queue 101 "$PEER_ID" "$PEER_ID" "hallo"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null

  # The transport still carried the token, so this is a real negative result.
  assert_grep "$TEST_TOKEN" "$FAKE_TG_DIR/token-seen.log" \
    "the fake server never saw a token, so the secrecy assertions prove nothing"
  assert_no_grep "$TEST_TOKEN" "$FAKE_TG_DIR/argv.log" \
    "the bot token appeared in curl's argv, where any local process can read it"

  leaked=$(grep -rl "$TEST_TOKEN" "$HOME_DIR/state" "$HOME_DIR/config" 2>/dev/null || true)
  [ -z "$leaked" ] || fail "the bot token was copied into local state: $leaked"

  leaked=$(tg_run "$HOME_DIR" "$FAKEBIN" "$PAIR" status 2>&1)
  assert_not_contains "$leaked" "$TEST_TOKEN" "pair status printed the bot token"
  assert_contains "$leaked" "token: present" "pair status did not report token presence"
  pass "the bot token stays out of argv, local state, and every status line"
}

test_private_files_are_owner_only() {
  local f mode
  paired_home perms
  tg_queue 102 "$PEER_ID" "$PEER_ID" "eine frage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null

  mode=$(path_mode "$HOME_DIR/state/telegram")
  [ "$mode" = 700 ] || fail "the bridge state directory is mode $mode, not 700"
  for f in "$HOME_DIR/state/telegram/peer.json" "$HOME_DIR/state/telegram/offset"; do
    assert_present "$f" "expected private artifact missing: $f"
    mode=$(path_mode "$f")
    [ "$mode" = 600 ] || fail "$f is mode $mode, not 600"
  done
  for f in "$HOME_DIR"/state/telegram/inbox/*.json; do
    mode=$(path_mode "$f")
    [ "$mode" = 600 ] || fail "$f is mode $mode, not 600"
  done
  pass "bridge state is an owner-only directory of mode-0600 files"
}

# --- pairing ----------------------------------------------------------------

test_pairing_success_pins_numeric_identity() {
  local peer
  paired_home pair-ok
  peer=$(cat "$HOME_DIR/state/telegram/peer.json")
  [ "$(printf '%s' "$peer" | jq -r '.user_id')" = "$PEER_ID" ] || fail "pairing did not pin the user id"
  [ "$(printf '%s' "$peer" | jq -r '.chat_id')" = "$PEER_ID" ] || fail "pairing did not pin the chat id"
  [ "$(printf '%s' "$peer" | jq -r '.label')" = eren ] || fail "pairing lost the label"
  [ "$(printf '%s' "$peer" | jq -r '.project')" = eren-pov-site ] || fail "pairing lost the project"
  assert_absent "$HOME_DIR/state/telegram/pairing.json" "the redeemed offer was not consumed"
  [ "$(tg_sent_count)" = 1 ] || fail "pairing did not send exactly one confirmation"
  pass "a redeemed code pins the immutable numeric user and chat ids and consumes the offer"
}

test_pairing_stores_no_recoverable_code() {
  local dir home fakebin code
  dir="$TMP_ROOT/pair-hash"
  mkdir -p "$dir"
  tg_fake_api "$dir"
  fakebin=$TG_FAKEBIN
  home=$(tg_home "$dir" home "$TEST_TOKEN")
  code=$(tg_run "$home" "$fakebin" "$PAIR" begin --label eren --project eren-pov-site \
    | sed -n 's|^  /start ||p')
  [ -n "$code" ] || fail "begin printed no pairing code"
  assert_no_grep "$code" "$home/state/telegram/pairing.json" \
    "the pairing code itself was written to disk and could be replayed by a reader"
  assert_grep 'code_sha256' "$home/state/telegram/pairing.json" "no code digest was stored"
  pass "only a salted digest of the pairing code is stored, never the code"
}

test_wrong_code_is_silent_and_bounded() {
  local dir home fakebin out attempts
  dir="$TMP_ROOT/pair-wrong"
  mkdir -p "$dir"
  tg_fake_api "$dir"
  fakebin=$TG_FAKEBIN
  home=$(tg_home "$dir" home "$TEST_TOKEN")
  tg_run "$home" "$fakebin" "$PAIR" begin --label eren --project eren-pov-site >/dev/null

  tg_queue 200 "$OTHER_ID" "$OTHER_ID" "/start WRONGCDE"
  out=$(tg_run "$home" "$fakebin" "$POLL" 2>&1)
  [ -z "$out" ] || fail "a wrong pairing code produced a wake: $out"
  [ "$(tg_sent_count)" = 0 ] || fail "the bridge replied to an unpaired chat"
  assert_absent "$home/state/telegram/peer.json" "a wrong code pinned a peer"
  attempts=$(jq -r '.attempts' "$home/state/telegram/pairing.json")
  [ "$attempts" = 1 ] || fail "a wrong code did not consume an attempt (attempts=$attempts)"
  pass "a wrong pairing code is answered with silence and consumes one bounded attempt"
}

test_pairing_attempt_budget_is_enforced() {
  local dir home fakebin code i
  dir="$TMP_ROOT/pair-budget"
  mkdir -p "$dir"
  tg_fake_api "$dir"
  fakebin=$TG_FAKEBIN
  home=$(tg_home "$dir" home "$TEST_TOKEN")
  code=$(FM_TELEGRAM_PAIR_ATTEMPTS=2 tg_run "$home" "$fakebin" "$PAIR" begin \
    --label eren --project eren-pov-site | sed -n 's|^  /start ||p')
  i=0
  while [ "$i" -lt 3 ]; do
    tg_queue "$(( 300 + i ))" "$OTHER_ID" "$OTHER_ID" "/start WRONGCDE"
    i=$(( i + 1 ))
  done
  FM_TELEGRAM_PAIR_ATTEMPTS=2 tg_run "$home" "$fakebin" "$POLL" >/dev/null
  # The budget is spent, so even the correct code no longer redeems.
  tg_queue 310 "$PEER_ID" "$PEER_ID" "/start $code"
  FM_TELEGRAM_PAIR_ATTEMPTS=2 tg_run "$home" "$fakebin" "$POLL" >/dev/null
  assert_absent "$home/state/telegram/peer.json" \
    "the correct code still paired after the attempt budget was spent"
  pass "a guessing loop exhausts the offer's attempt budget and locks it out"
}

test_expired_code_does_not_pair() {
  local dir home fakebin code
  dir="$TMP_ROOT/pair-expired"
  mkdir -p "$dir"
  tg_fake_api "$dir"
  fakebin=$TG_FAKEBIN
  home=$(tg_home "$dir" home "$TEST_TOKEN")
  code=$(FM_TELEGRAM_PAIR_TTL=30 tg_run "$home" "$fakebin" "$PAIR" begin \
    --label eren --project eren-pov-site | sed -n 's|^  /start ||p')
  tg_queue 400 "$PEER_ID" "$PEER_ID" "/start $code"
  FMTG_NOW_OVERRIDE=$(( $(date +%s) + 4000 )) tg_run "$home" "$fakebin" "$POLL" >/dev/null
  assert_absent "$home/state/telegram/peer.json" "an expired code still paired"
  [ "$(tg_sent_count)" = 0 ] || fail "an expired code produced a reply"
  pass "an expired pairing code cannot pair and stays silent"
}

test_code_cannot_be_replayed() {
  local code
  paired_home pair-replay
  # Revoke the peer so the replay path is reachable, then replay the same code.
  tg_run "$HOME_DIR" "$FAKEBIN" "$PAIR" revoke --yes >/dev/null
  code=$(tg_run "$HOME_DIR" "$FAKEBIN" "$PAIR" begin --label eren --project eren-pov-site \
    | sed -n 's|^  /start ||p')
  tg_queue 500 "$PEER_ID" "$PEER_ID" "/start $code"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  assert_present "$HOME_DIR/state/telegram/peer.json" "the fresh code did not pair"
  tg_run "$HOME_DIR" "$FAKEBIN" "$PAIR" revoke --yes >/dev/null
  tg_queue 501 "$PEER_ID" "$PEER_ID" "/start $code"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  assert_absent "$HOME_DIR/state/telegram/peer.json" "a single-use code paired a second time"
  pass "a redeemed pairing code cannot be replayed after revocation"
}

test_repair_requires_an_explicit_replace() {
  local out
  paired_home pair-replace
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$PAIR" begin --label other --project eren-pov-site 2>&1 || true)
  assert_contains "$out" "--replace" "re-pairing over a live peer was not refused"
  assert_absent "$HOME_DIR/state/telegram/pairing.json" "a refused re-pair still opened an offer"
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$PAIR" begin --label other --project eren-pov-site --replace 2>&1)
  assert_contains "$out" "/start " "an explicit --replace did not open a new offer"
  pass "re-pairing over a live peer requires an explicit deliberate --replace"
}

test_revoke_clears_access_without_replaying_history() {
  local offset_before out
  paired_home revoke
  tg_queue 600 "$PEER_ID" "$PEER_ID" "eine anfrage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  offset_before=$(cat "$HOME_DIR/state/telegram/offset")

  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$PAIR" revoke 2>&1 || true)
  assert_contains "$out" "--yes" "revoke did not require confirmation for a live peer"
  tg_run "$HOME_DIR" "$FAKEBIN" "$PAIR" revoke --yes >/dev/null

  assert_absent "$HOME_DIR/state/telegram/peer.json" "revoke left the peer pinned"
  [ "$(cat "$HOME_DIR/state/telegram/offset")" = "$offset_before" ] \
    || fail "revoke rewound the update offset, which would replay old messages"
  assert_present "$HOME_DIR/state/telegram/seen" "revoke removed duplicate-suppression markers"

  tg_queue 601 "$PEER_ID" "$PEER_ID" "noch eine anfrage"
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" 2>&1)
  [ -z "$out" ] || fail "a revoked peer still reached firstmate: $out"
  pass "revoke ends access, keeps the offset so nothing replays, and needs explicit confirmation"
}

# --- inbound acceptance -----------------------------------------------------

test_paired_text_is_accepted_exactly_once() {
  local out entry
  paired_home accept
  tg_queue 700 "$PEER_ID" "$PEER_ID" "Kannst du die Ueberschrift aendern?"
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" 2>&1)
  assert_contains "$out" "telegram-message tg-700" "an accepted message did not wake firstmate"
  entry="$HOME_DIR/state/telegram/inbox/tg-700.json"
  assert_present "$entry" "no inbox entry was written"
  [ "$(jq -r '.kind' "$entry")" = text ] || fail "an accepted text message was not classified as text"
  [ "$(jq -r '.text' "$entry")" = "Kannst du die Ueberschrift aendern?" ] || fail "the message text was mangled"
  [ "$(jq -r '.project' "$entry")" = eren-pov-site ] || fail "the entry lost the pinned project"
  [ "$(jq -r 'has("username")' "$entry")" = false ] || fail "the entry carried a username, which is never authority"

  # A second poll of the same server state must be completely silent.
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" 2>&1)
  [ -z "$out" ] || fail "a second poll re-announced an already-handled message: $out"
  pass "a paired private text message is accepted exactly once"
}

test_duplicate_delivery_never_duplicates_work() {
  local out before
  paired_home dedupe
  tg_queue 800 "$PEER_ID" "$PEER_ID" "erste anfrage"
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" 2>&1)
  assert_contains "$out" "telegram-message tg-800" "the first delivery did not wake firstmate"
  before=$(cat "$HOME_DIR/state/telegram/inbox/tg-800.json")

  # Simulate Telegram redelivering the same update: rewind the confirmed offset
  # exactly as a crash before the offset write would leave it.
  printf '0\n' > "$HOME_DIR/state/telegram/offset"
  tg_queue 800 "$PEER_ID" "$PEER_ID" "erste anfrage"
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" 2>&1)
  [ -z "$out" ] || fail "a redelivered update woke firstmate a second time: $out"
  [ "$(cat "$HOME_DIR/state/telegram/inbox/tg-800.json")" = "$before" ] \
    || fail "a redelivered update rewrote the inbox entry"
  pass "a redelivered update is dropped: no second wake and no second inbox entry"
}

test_crash_before_seen_claim_still_delivers_once() {
  local out
  paired_home crash-before
  tg_queue 900 "$PEER_ID" "$PEER_ID" "anfrage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null

  # A crash between publishing the inbox entry and claiming the seen marker
  # leaves the entry with no marker and no confirmed offset.
  rm -f "$HOME_DIR/state/telegram/seen/900.json"
  printf '0\n' > "$HOME_DIR/state/telegram/offset"
  tg_queue 900 "$PEER_ID" "$PEER_ID" "anfrage"
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" 2>&1)
  assert_contains "$out" "telegram-message tg-900" "recovery did not re-announce the unclaimed message"
  [ "$(count_files "$HOME_DIR/state/telegram/inbox")" = 1 ] \
    || fail "recovery created a duplicate inbox entry"
  pass "a crash before the seen claim redelivers once, without duplicating the entry"
}

test_drained_message_is_never_resurrected() {
  local out
  paired_home crash-after
  tg_queue 910 "$PEER_ID" "$PEER_ID" "anfrage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  # The agent handled and drained it; then a crash rewound the offset.
  rm -f "$HOME_DIR/state/telegram/inbox/tg-910.json"
  printf '0\n' > "$HOME_DIR/state/telegram/offset"
  tg_queue 910 "$PEER_ID" "$PEER_ID" "anfrage"
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" 2>&1)
  [ -z "$out" ] || fail "a drained message was resurrected by a redelivery: $out"
  assert_absent "$HOME_DIR/state/telegram/inbox/tg-910.json" "a drained inbox entry was recreated"
  pass "a message the agent already drained is never recreated by a redelivery"
}

test_offset_advances_only_past_processed_updates() {
  paired_home offset
  tg_queue 1000 "$PEER_ID" "$PEER_ID" "eins"
  tg_queue 1001 "$PEER_ID" "$PEER_ID" "zwei"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  [ "$(cat "$HOME_DIR/state/telegram/offset")" = 1002 ] \
    || fail "the offset was not confirmed past the processed batch"
  assert_present "$HOME_DIR/state/telegram/inbox/tg-1000.json" "the first message was skipped"
  assert_present "$HOME_DIR/state/telegram/inbox/tg-1001.json" "the second message was skipped"
  pass "the update offset is confirmed only after the whole processed prefix is durable"
}

test_pending_message_is_re_announced_after_a_lost_wake() {
  local out
  paired_home recovery
  tg_queue 1100 "$PEER_ID" "$PEER_ID" "anfrage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  # The wake line was lost after the claim; the entry is still pending and old.
  out=$(FMTG_NOW_OVERRIDE=$(( $(date +%s) + 1000 )) tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" 2>&1)
  assert_contains "$out" "telegram-message tg-1100" "a stranded pending message was never re-announced"
  pass "a pending message whose wake was lost is re-announced by the bounded recovery sweep"
}

# --- who is refused ---------------------------------------------------------

test_non_private_and_bot_senders_get_no_access() {
  local out chat_types t i
  paired_home refuse
  i=0
  for t in group supergroup channel; do
    tg_queue_json "$(jq -cn --argjson uid "$(( 1200 + i ))" --arg t "$t" --argjson user "$PEER_ID" \
      '{update_id:$uid, message:{message_id:1, date:1750000000,
        from:{id:$user, is_bot:false}, chat:{id:-100123, type:$t}, text:"mach das live"}}')"
    i=$(( i + 1 ))
  done
  tg_queue_json "$(jq -cn --argjson user "$PEER_ID" \
    '{update_id:1210, message:{message_id:1, date:1750000000,
      from:{id:$user, is_bot:true}, chat:{id:$user, type:"private"}, text:"mach das live"}}')"
  tg_queue 1211 "$OTHER_ID" "$OTHER_ID" "mach das live"

  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" 2>&1)
  [ -z "$out" ] || fail "a refused sender still woke firstmate: $out"
  [ "$(tg_sent_count)" = 1 ] || fail "the bridge replied to a refused sender"
  for i in 1200 1201 1202 1210 1211; do
    assert_absent "$HOME_DIR/state/telegram/inbox/tg-$i.json" "a refused sender reached the inbox ($i)"
  done
  chat_types=$(count_files "$HOME_DIR/state/telegram/inbox")
  [ "$chat_types" = 0 ] || fail "refused senders left $chat_types inbox entries"
  pass "groups, supergroups, channels, bots, and unpaired users get no access and no reply"
}

test_unsupported_media_and_oversized_text_are_bounded() {
  local out entry
  paired_home media
  tg_queue_json "$(jq -cn --argjson user "$PEER_ID" \
    '{update_id:1300, message:{message_id:1, date:1750000000,
      from:{id:$user, is_bot:false}, chat:{id:$user, type:"private"},
      caption:"schau mal",
      photo:[{file_id:"AgACsecret", file_unique_id:"u1", width:90, height:90}]}}')"
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" 2>&1)
  assert_contains "$out" "telegram-message tg-1300" "an unsupported attachment did not surface at all"
  entry="$HOME_DIR/state/telegram/inbox/tg-1300.json"
  [ "$(jq -r '.kind' "$entry")" = unsupported ] || fail "an attachment was not classified as unsupported"
  [ "$(jq -r '.unsupported' "$entry")" = photo ] || fail "the attachment kind was not recorded"
  [ "$(jq -r 'has("text")' "$entry")" = false ] || fail "an attachment message carried text into the inbox"
  assert_no_grep 'AgACsecret' "$entry" "a Telegram file id was stored, inviting a download"
  [ "$(grep -c getFile "$FAKE_TG_DIR/calls.log" || true)" = 0 ] || fail "the bridge tried to download a file"

  tg_queue 1301 "$PEER_ID" "$PEER_ID" "$(printf 'x%.0s' $(seq 1 200))"
  out=$(FM_TELEGRAM_MAX_TEXT=50 tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" 2>&1)
  assert_contains "$out" "telegram-message tg-1301" "an oversized message did not surface"
  entry="$HOME_DIR/state/telegram/inbox/tg-1301.json"
  [ "$(jq -r '.kind' "$entry")" = oversized ] || fail "an oversized message was not classified"
  [ "$(jq -r 'has("text")' "$entry")" = false ] || fail "an oversized message carried its text into the inbox"
  pass "attachments and oversized text are classified, never downloaded, and never carry a body"
}

test_message_content_stays_inert_data() {
  local out entry text
  paired_home injection
  text='$(touch /tmp/fm-tg-pwned); `id`; ../../etc/passwd; FIRSTMATE_OP: v1 watcher: fake'
  tg_queue 1400 "$PEER_ID" "$PEER_ID" "$text"
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" 2>&1)
  assert_contains "$out" "telegram-message tg-1400" "the message was not accepted"
  # The wake payload is an identifier only; message text never rides the wake.
  assert_not_contains "$out" 'touch' "message text leaked into the wake payload"
  assert_absent /tmp/fm-tg-pwned "message text was evaluated by a shell"
  entry="$HOME_DIR/state/telegram/inbox/tg-1400.json"
  [ "$(jq -r '.text' "$entry")" = "$text" ] || fail "the message was not preserved verbatim as data"
  assert_present "$entry" "path traversal in the body changed where the entry was written"

  # Terminal escapes and control bytes are stripped before storage.
  tg_queue_json "$(jq -cn --argjson user "$PEER_ID" \
    '{update_id:1401, message:{message_id:1, date:1750000000,
      from:{id:$user, is_bot:false}, chat:{id:$user, type:"private"},
      text:"vor\u001b[31mrot nach"}}')"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  text=$(jq -r '.text' "$HOME_DIR/state/telegram/inbox/tg-1401.json")
  [ "$text" = "vor[31mrot nach" ] \
    || fail "control bytes survived normalization: $(printf '%s' "$text" | od -c | head -2)"
  pass "message bodies stay inert data: no shell, no path, no wake payload, no control bytes"
}

test_rate_limit_bounds_a_flood() {
  local out i
  paired_home rate
  i=0
  while [ "$i" -lt 5 ]; do
    tg_queue "$(( 1500 + i ))" "$PEER_ID" "$PEER_ID" "nachricht $i"
    i=$(( i + 1 ))
  done
  out=$(FM_TELEGRAM_RATE_MAX=2 tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" 2>&1)
  [ "$(count_files "$HOME_DIR/state/telegram/inbox")" = 2 ] \
    || fail "the accept rate limit did not bound the flood"
  assert_contains "$out" "telegram-error" "the rate limit was hit without telling firstmate"
  pass "a flood is bounded by the accept rate limit and reported once"
}

test_conflicting_poller_is_reported() {
  local out
  paired_home conflict
  out=$(FAKE_TG_GETUPDATES_CODE=409 tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" 2>&1)
  assert_contains "$out" "another process is polling this bot" \
    "a second poller on one bot token was not reported"
  pass "two homes sharing one bot token is reported as the misconfiguration it is"
}

# --- project routing --------------------------------------------------------

test_routing_is_pinned_to_the_paired_project() {
  local out
  paired_home routing
  tg_queue 1600 "$PEER_ID" "$PEER_ID" "anfrage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null

  fm_write_meta "$HOME_DIR/state/right.meta" "project=$HOME_DIR/projects/eren-pov-site" "window=t:1"
  fm_write_meta "$HOME_DIR/state/wrong.meta" "project=$HOME_DIR/projects/venture-cockpit" "window=t:2"

  tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" link right tg-1600 >/dev/null \
    || fail "linking a task in the paired project was refused"
  assert_grep 'tg_request=tg-1600' "$HOME_DIR/state/right.meta" "the link was not recorded"

  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" link wrong tg-1600 2>&1 || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=6" "linking a task in another project was not refused"
  assert_no_grep 'tg_request=' "$HOME_DIR/state/wrong.meta" "a refused link still wrote to the task record"

  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" arm-publish wrong --head abc1234 2>&1 || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=6" "arming a publish in another project was not refused"
  pass "task links and publish arming are refused outside the paired project"
}

# --- two-step publish -------------------------------------------------------

# Arm a publish confirmation on a paired home. Sets HOME_DIR, FAKEBIN, and
# PUBLISH_CODE in the caller.
publish_home() {  # <name>
  local name=$1
  paired_home "$name"
  fm_write_meta "$HOME_DIR/state/site.meta" "project=$HOME_DIR/projects/eren-pov-site" "window=t:1"
  PUBLISH_CODE=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" arm-publish site --head aaaa111)
}

test_publish_needs_a_matching_confirmation() {
  local msg out
  publish_home publish-ok
  [ -n "$PUBLISH_CODE" ] || fail "arm-publish printed no confirmation code"
  assert_no_grep "$PUBLISH_CODE" "$HOME_DIR/state/telegram/publish/site.json" \
    "the confirmation code was stored in the clear and could be replayed"

  msg="$HOME_DIR/msg.txt"
  printf 'ja mach das live: %s\n' "$PUBLISH_CODE" > "$msg"
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" confirm-publish site --head aaaa111 --message-file "$msg" 2>&1)
  assert_contains "$out" "confirmed" "a matching confirmation was not accepted"

  # Single use.
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" confirm-publish site --head aaaa111 --message-file "$msg" 2>&1 \
    || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=7" "a confirmation was accepted twice"
  pass "publishing needs one matching confirmation code, and it is single use"
}

test_bare_agreement_is_not_a_confirmation() {
  local msg out
  publish_home publish-bare
  msg="$HOME_DIR/msg.txt"
  printf 'ja klar, mach das\n' > "$msg"
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" confirm-publish site --head aaaa111 --message-file "$msg" 2>&1 \
    || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=5" "a bare yes was treated as a publish confirmation"
  pass "a bare agreement without the code never authorizes publishing"
}

test_stale_confirmation_is_refused() {
  local msg out
  publish_home publish-stale
  msg="$HOME_DIR/msg.txt"
  printf '%s\n' "$PUBLISH_CODE" > "$msg"
  # The prepared change moved after the preview was shown.
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" confirm-publish site --head bbbb222 --message-file "$msg" 2>&1 \
    || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=6" "a confirmation for a change that moved was accepted"
  assert_contains "$out" "re-preview" "the stale refusal did not say what to do next"
  pass "a confirmation is refused once the prepared change is no longer what was previewed"
}

test_expired_and_over_budget_confirmations_are_refused() {
  local msg out i
  publish_home publish-expiry
  msg="$HOME_DIR/msg.txt"
  printf '%s\n' "$PUBLISH_CODE" > "$msg"
  out=$(FMTG_NOW_OVERRIDE=$(( $(date +%s) + 200000 )) tg_run "$HOME_DIR" "$FAKEBIN" \
    "$TGTASK" confirm-publish site --head aaaa111 --message-file "$msg" 2>&1 || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=4" "an expired confirmation was accepted"

  publish_home publish-budget
  msg="$HOME_DIR/msg.txt"
  printf 'WRONGX\n' > "$msg"
  i=0
  while [ "$i" -lt 5 ]; do
    tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" confirm-publish site --head aaaa111 --message-file "$msg" >/dev/null 2>&1 || true
    i=$(( i + 1 ))
  done
  printf '%s\n' "$PUBLISH_CODE" > "$msg"
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" confirm-publish site --head aaaa111 --message-file "$msg" 2>&1 \
    || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=8" "the confirmation attempt budget was not enforced"
  pass "expired confirmations and exhausted attempt budgets are both refused"
}

# --- replies ----------------------------------------------------------------

test_reply_is_literal_and_single_target() {
  local out body
  paired_home reply
  body="$HOME_DIR/reply.txt"
  printf '%s\n' '*fett* _kursiv_ [link](x) `code` \ und & <b>' > "$body"
  tg_queue 1700 "$PEER_ID" "$PEER_ID" "frage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" tg-1700 --text-file "$body" >/dev/null

  out=$(sed -n '2p' "$FAKE_TG_DIR/sent.jsonl")
  [ "$(printf '%s' "$out" | jq -r 'has("parse_mode")')" = false ] \
    || fail "a markup parser was enabled, so user text can be mis-parsed or rejected"
  [ "$(printf '%s' "$out" | jq -r '.text')" = '*fett* _kursiv_ [link](x) `code` \ und & <b>' ] \
    || fail "reply text was not delivered literally"
  [ "$(printf '%s' "$out" | jq -r '.chat_id')" = "$PEER_ID" ] || fail "the reply went to the wrong chat"
  pass "replies are delivered literally with no markup parser, always to the pinned chat"
}

test_reply_refuses_when_the_target_no_longer_matches() {
  local out
  paired_home reply-target
  tg_queue 1800 "$PEER_ID" "$PEER_ID" "frage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  printf 'hallo\n' > "$HOME_DIR/reply.txt"

  # The pairing was replaced by a different person after the message arrived.
  jq -c '.chat_id = 424242 | .user_id = 424242' "$HOME_DIR/state/telegram/peer.json" \
    > "$HOME_DIR/peer.tmp" && mv -f "$HOME_DIR/peer.tmp" "$HOME_DIR/state/telegram/peer.json"
  chmod 600 "$HOME_DIR/state/telegram/peer.json"
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" tg-1800 --text-file "$HOME_DIR/reply.txt" 2>&1 \
    || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=6" "a reply for an older conversation was sent to a new peer"
  pass "a reply is refused rather than redirected when the pinned peer changed"
}

test_reply_without_a_peer_sends_nothing() {
  local dir home fakebin out
  dir="$TMP_ROOT/reply-unpaired"
  mkdir -p "$dir"
  tg_fake_api "$dir"
  fakebin=$TG_FAKEBIN
  home=$(tg_home "$dir" home "$TEST_TOKEN")
  printf 'hallo\n' > "$home/reply.txt"
  out=$(tg_run "$home" "$fakebin" "$REPLY" tg-1 --text-file "$home/reply.txt" 2>&1 || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=3" "a reply was attempted with no pairing"
  [ "$(tg_sent_count)" = 0 ] || fail "sendMessage ran before any pairing existed"
  pass "sendMessage never runs before pairing"
}

test_long_reply_splits_deterministically() {
  local body i n first
  paired_home reply-split
  body="$HOME_DIR/reply.txt"
  : > "$body"
  i=0
  while [ "$i" -lt 40 ]; do
    printf 'Absatz %s mit genug Text um die Grenze sicher zu ueberschreiten.\n\n' "$i" >> "$body"
    i=$(( i + 1 ))
  done
  tg_queue 1900 "$PEER_ID" "$PEER_ID" "frage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  FM_TELEGRAM_MAX_CHARS=200 tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" tg-1900 --text-file "$body" >/dev/null

  n=$(( $(tg_sent_count) - 1 ))
  [ "$n" -gt 1 ] || fail "a long reply was not split (sent $n messages)"
  first=$(tg_sent_text 2)
  [ "${#first}" -le 200 ] || fail "a split message exceeded the per-message budget: ${#first}"
  case "$first" in
    *"(1/"*) ;;
    *) fail "split messages are not numbered: $first" ;;
  esac
  pass "a long reply splits into numbered messages within the per-message budget"
}

test_failed_send_is_preserved_and_resumes() {
  local body out delivered
  paired_home reply-retry
  body="$HOME_DIR/reply.txt"
  printf 'Erster Absatz mit genug Text fuer eine eigene Nachricht.\n\nZweiter Absatz mit genug Text fuer eine eigene Nachricht.\n\nDritter Absatz mit genug Text fuer eine eigene Nachricht.\n' > "$body"
  tg_queue 2000 "$PEER_ID" "$PEER_ID" "frage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null

  # Fail from the second delivery of this run onward (the pairing confirmation
  # already counts as one), so the reply lands partially.
  out=$(FAKE_TG_SEND_FAIL_FROM=3 FM_TELEGRAM_MAX_CHARS=100 \
    tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" tg-2000 --text-file "$body" 2>&1 || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=5" "a failed send did not report a preserved retry"
  assert_present "$HOME_DIR/state/telegram/outbox/tg-2000.json" "the unsent reply was not preserved"
  delivered=$(jq -r '.sent' "$HOME_DIR/state/telegram/outbox/tg-2000.json")
  [ "$delivered" -ge 1 ] || fail "the preserved record lost track of what was already delivered"

  # Retry resumes without repeating what was delivered and without new work.
  tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" --retry tg-2000 >/dev/null
  assert_absent "$HOME_DIR/state/telegram/outbox/tg-2000.json" "a completed retry left the record behind"
  [ "$(tg_sent_text 2)" != "$(tg_sent_text 3)" ] || fail "the retry re-sent an already-delivered message"
  pass "a failed send is preserved with its progress and resumes without repeating messages"
}

test_final_reply_clears_the_link_but_keeps_evidence() {
  paired_home reply-final
  tg_queue 2100 "$PEER_ID" "$PEER_ID" "frage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  fm_write_meta "$HOME_DIR/state/site.meta" "project=$HOME_DIR/projects/eren-pov-site" "window=t:1"
  tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" link site tg-2100 >/dev/null
  printf 'fertig\n' > "$HOME_DIR/reply.txt"

  tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" --task site --final --text-file "$HOME_DIR/reply.txt" >/dev/null
  assert_no_grep 'tg_request=' "$HOME_DIR/state/site.meta" "the final reply left the link postable"
  assert_grep 'project=' "$HOME_DIR/state/site.meta" "clearing the link damaged the rest of the task record"
  assert_present "$HOME_DIR/state/telegram/context/tg-2100.json" \
    "the final reply erased the record of which conversation the task answered"
  pass "a final reply ends the thread but keeps the evidence a linked task still needs"
}

test_dry_run_records_without_sending() {
  local before
  paired_home dry
  tg_queue 2200 "$PEER_ID" "$PEER_ID" "frage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  before=$(tg_sent_count)
  printf 'vorschau\n' > "$HOME_DIR/reply.txt"
  FM_TELEGRAM_DRY_RUN=1 tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" tg-2200 --text-file "$HOME_DIR/reply.txt" >/dev/null
  [ "$(tg_sent_count)" = "$before" ] || fail "dry run still delivered a message"
  assert_grep '"dry_run":true' "$HOME_DIR/state/telegram/outbox/tg-2200.json" "no dry-run preview was recorded"
  pass "dry run records the would-be reply and sends nothing"
}

# --- activation, watcher dispatch, supervision ------------------------------

test_bootstrap_arms_and_disarms_the_bridge() {
  local dir home fakebin out
  dir="$TMP_ROOT/bootstrap"
  mkdir -p "$dir"
  tg_fake_api "$dir"
  fakebin=$TG_FAKEBIN
  home=$(tg_home "$dir" home "$TEST_TOKEN")

  out=$(tg_run "$home" "$fakebin" "$BOOTSTRAP" 2>&1 || true)
  assert_contains "$out" "FMTG: Telegram bridge armed but not paired" \
    "bootstrap did not report an armed-but-unpaired bridge"
  assert_present "$home/state/telegram-watch.check.sh" "bootstrap did not arm the poll shim"
  assert_present "$home/config/telegram.env" "bootstrap did not write the cadence file"
  [ "$(path_mode "$home/state/telegram-watch.check.sh")" = 700 ] || fail "the poll shim is not mode 700"
  assert_grep 'FM_CHECK_INTERVAL=30' "$home/config/telegram.env" "the cadence file does not raise the check rate"

  # Idempotent.
  out=$(tg_run "$home" "$fakebin" "$BOOTSTRAP" 2>&1 || true)
  assert_contains "$out" "FMTG:" "a second bootstrap run lost the bridge line"

  rm -f "$home/.env"
  out=$(tg_run "$home" "$fakebin" "$BOOTSTRAP" 2>&1 || true)
  assert_contains "$out" "FMTG: Telegram bridge off" "opt-out was not reported"
  assert_absent "$home/state/telegram-watch.check.sh" "opt-out left the poll shim armed"
  assert_absent "$home/config/telegram.env" "opt-out left the cadence file behind"

  out=$(tg_run "$home" "$fakebin" "$BOOTSTRAP" 2>&1 || true)
  assert_not_contains "$out" "FMTG:" "steady-state off is not silent"
  pass "bootstrap arms, re-arms idempotently, disarms on opt-out, and is silent once off"
}

test_supervision_is_required_for_a_bridged_home() {
  local dir state out
  dir="$TMP_ROOT/supervision"
  state="$dir/state"
  mkdir -p "$state"
  out=$(bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2" && echo yes || echo no' \
    _ "$ROOT" "$state")
  [ "$out" = no ] || fail "an idle home with no channels claimed it needs supervision"
  : > "$state/telegram-watch.check.sh"
  out=$(bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2" && echo yes || echo no' \
    _ "$ROOT" "$state")
  [ "$out" = yes ] || fail "a bridged home with no fleet work was treated as needing no supervision"
  pass "a bridged home needs the supervision cycle even with no project work"
}

test_cadence_instruction_reaches_every_harness() {
  local dir home config out h
  dir="$TMP_ROOT/cadence"
  home="$dir/home"
  config="$dir/config"
  mkdir -p "$home/state" "$config"
  : > "$config/telegram.env"
  for h in claude codex opencode pi pi-signed grok unknown; do
    out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" \
      "$ROOT/bin/fm-supervision-instructions.sh" --harness "$h")
    assert_contains "$out" "- Telegram bridge: active" "harness $h lost the bridge cadence state line"
    assert_contains "$out" "$config/telegram.env" "harness $h did not name the effective cadence file"
  done
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness claude --repair-line)
  assert_contains "$out" "source '$config/telegram.env' first" "the repair line does not source the bridge cadence"
  pass "every supported harness is told to inherit the bridge cadence"
}

test_both_channels_coexist_in_one_home() {
  local dir home config out
  dir="$TMP_ROOT/coexist"
  home="$dir/home"
  config="$dir/config"
  mkdir -p "$home/state" "$config"
  : > "$config/telegram.env"
  : > "$config/x-mode.env"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness grok)
  assert_contains "$out" "- X mode: active" "X mode was dropped when the bridge was also armed"
  assert_contains "$out" "- Telegram bridge: active" "the bridge was dropped when X mode was also armed"
  assert_contains "$out" "[ -f '$config/x-mode.env' ] && . '$config/x-mode.env'; [ -f '$config/telegram.env' ] && . '$config/telegram.env'; exec bin/fm-watch-arm.sh" \
    "the arm command does not source both channels' cadence files"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness claude --repair-line)
  assert_contains "$out" "and '$config/telegram.env' first" "the repair line does not source both cadence files"
  pass "X mode and the Telegram bridge coexist in one home without displacing each other"
}

test_watcher_rotates_between_always_on_channels() {
  local dir state name out1 out2 pid i
  dir="$TMP_ROOT/rotation"
  state="$dir/state"
  mkdir -p "$state"
  # Two registered checks that both always have something to report, standing in
  # for two armed always-on channels. The watcher wakes on the FIRST producing
  # check and abandons the cycle, so without rotation the alphabetically-earlier
  # one would speak forever and the other would never run.
  for name in a-channel z-channel; do
    printf '#!/usr/bin/env bash\necho ready\n' > "$state/$name.check.sh"
    chmod 700 "$state/$name.check.sh"
    FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" "$name" >/dev/null \
      || fail "could not register the $name check"
  done

  run_one_sweep() {  # <out>
    local out=$1 pid i
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 \
      FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$out" 2>/dev/null &
    pid=$!
    i=0
    while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$(( i + 1 )); done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  }

  out1="$dir/out1"
  run_one_sweep "$out1"
  assert_grep 'a-channel' "$out1" "the first sweep did not wake on the first check"
  [ "$(cat "$state/.last-check-woke" 2>/dev/null)" = "a-channel.check.sh" ] \
    || fail "the watcher did not record which check woke it"

  out2="$dir/out2"
  run_one_sweep "$out2"
  assert_grep 'z-channel' "$out2" \
    "the second sweep did not rotate to the other check, so one always-on channel starves the other"
  pass "the check sweep rotates, so one always-on channel cannot starve another"
}

test_homes_cannot_read_each_other() {
  local dirA dirB homeA homeB fakebinA fakebinB out
  dirA="$TMP_ROOT/isoA"
  dirB="$TMP_ROOT/isoB"
  mkdir -p "$dirA" "$dirB"
  tg_fake_api "$dirA"
  fakebinA=$TG_FAKEBIN
  homeA=$(tg_home "$dirA" home "$TEST_TOKEN")
  tg_run "$homeA" "$fakebinA" "$PAIR" begin --label eren --project eren-pov-site >/dev/null
  tg_queue 3000 "$PEER_ID" "$PEER_ID" "hallo"

  tg_fake_api "$dirB"

  fakebinB=$TG_FAKEBIN
  homeB=$(tg_home "$dirB" home "$TEST_TOKEN")

  out=$(tg_run "$homeB" "$fakebinB" "$PAIR" status 2>&1)
  assert_contains "$out" "paired: no" "a second home saw the first home's pairing"
  assert_contains "$out" "offer: none" "a second home saw the first home's pairing offer"

  # Home B has its own empty server and its own state root.
  out=$(tg_run "$homeB" "$fakebinB" "$POLL" 2>&1)
  [ -z "$out" ] || fail "a second home consumed another home's messages: $out"
  assert_absent "$homeB/state/telegram/peer.json" "a second home inherited a pinned peer"
  assert_present "$homeA/state/telegram/pairing.json" "the first home's offer was disturbed"
  pass "one firstmate home can never read or consume another home's bridge state"
}

test_absent_config_is_a_complete_no_op
test_malformed_token_is_refused_without_echoing_it
test_token_never_reaches_argv_or_state
test_private_files_are_owner_only
test_pairing_success_pins_numeric_identity
test_pairing_stores_no_recoverable_code
test_wrong_code_is_silent_and_bounded
test_pairing_attempt_budget_is_enforced
test_expired_code_does_not_pair
test_code_cannot_be_replayed
test_repair_requires_an_explicit_replace
test_revoke_clears_access_without_replaying_history
test_paired_text_is_accepted_exactly_once
test_duplicate_delivery_never_duplicates_work
test_crash_before_seen_claim_still_delivers_once
test_drained_message_is_never_resurrected
test_offset_advances_only_past_processed_updates
test_pending_message_is_re_announced_after_a_lost_wake
test_non_private_and_bot_senders_get_no_access
test_unsupported_media_and_oversized_text_are_bounded
test_message_content_stays_inert_data
test_rate_limit_bounds_a_flood
test_conflicting_poller_is_reported
test_routing_is_pinned_to_the_paired_project
test_publish_needs_a_matching_confirmation
test_bare_agreement_is_not_a_confirmation
test_stale_confirmation_is_refused
test_expired_and_over_budget_confirmations_are_refused
test_reply_is_literal_and_single_target
test_reply_refuses_when_the_target_no_longer_matches
test_reply_without_a_peer_sends_nothing
test_long_reply_splits_deterministically
test_failed_send_is_preserved_and_resumes
test_final_reply_clears_the_link_but_keeps_evidence
test_dry_run_records_without_sending
test_bootstrap_arms_and_disarms_the_bridge
test_supervision_is_required_for_a_bridged_home
test_cadence_instruction_reaches_every_harness
test_both_channels_coexist_in_one_home
test_watcher_rotates_between_always_on_channels
test_homes_cannot_read_each_other
