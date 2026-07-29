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

# The attempt budget is PER NUMERIC SENDER. A bot is reachable by any Telegram
# user who knows its @handle, so a single global counter let a stranger burn the
# whole offer and deny the intended recipient their own attempt - repeatably, on
# demand. A guessing loop must exhaust its own budget and nobody else's.
test_pairing_attempt_budget_is_per_sender() {
  local dir home fakebin code i
  dir="$TMP_ROOT/pair-budget"
  mkdir -p "$dir"
  tg_fake_api "$dir"
  fakebin=$TG_FAKEBIN
  home=$(tg_home "$dir" home "$TEST_TOKEN")
  code=$(FM_TELEGRAM_PAIR_ATTEMPTS=2 tg_run "$home" "$fakebin" "$PAIR" begin \
    --label eren --project eren-pov-site | sed -n 's|^  /start ||p')
  i=0
  while [ "$i" -lt 5 ]; do
    tg_queue "$(( 300 + i ))" "$OTHER_ID" "$OTHER_ID" "/start WRONGCDE"
    i=$(( i + 1 ))
  done
  FM_TELEGRAM_PAIR_ATTEMPTS=2 tg_run "$home" "$fakebin" "$POLL" >/dev/null
  assert_absent "$home/state/telegram/peer.json" "a wrong code pinned a peer"

  # The stranger is locked out, and its own counter shows why.
  [ "$(jq -r --arg u "$OTHER_ID" '.attempts_by[$u]' "$home/state/telegram/pairing.json")" -ge 2 ] \
    || fail "the guessing sender did not consume its own attempt budget"

  # The intended recipient still has a full budget and can redeem.
  tg_queue 310 "$PEER_ID" "$PEER_ID" "/start $code"
  FM_TELEGRAM_PAIR_ATTEMPTS=2 tg_run "$home" "$fakebin" "$POLL" >/dev/null
  assert_present "$home/state/telegram/peer.json" \
    "a stranger's guessing loop denied the intended recipient their own pairing"
  [ "$(jq -r '.user_id' "$home/state/telegram/peer.json")" = "$PEER_ID" ] \
    || fail "the wrong identity was pinned"
  pass "the pairing attempt budget is per sender, so a stranger cannot exhaust it remotely"
}

# A guessing loop from ONE sender still locks that sender out entirely.
test_pairing_attempt_budget_locks_out_the_guesser() {
  local dir home fakebin code i
  dir="$TMP_ROOT/pair-budget-self"
  mkdir -p "$dir"
  tg_fake_api "$dir"
  fakebin=$TG_FAKEBIN
  home=$(tg_home "$dir" home "$TEST_TOKEN")
  code=$(FM_TELEGRAM_PAIR_ATTEMPTS=2 tg_run "$home" "$fakebin" "$PAIR" begin \
    --label eren --project eren-pov-site | sed -n 's|^  /start ||p')
  i=0
  while [ "$i" -lt 3 ]; do
    tg_queue "$(( 320 + i ))" "$OTHER_ID" "$OTHER_ID" "/start WRONGCDE"
    i=$(( i + 1 ))
  done
  FM_TELEGRAM_PAIR_ATTEMPTS=2 tg_run "$home" "$fakebin" "$POLL" >/dev/null
  tg_queue 330 "$OTHER_ID" "$OTHER_ID" "/start $code"
  FM_TELEGRAM_PAIR_ATTEMPTS=2 tg_run "$home" "$fakebin" "$POLL" >/dev/null
  assert_absent "$home/state/telegram/peer.json" \
    "the correct code still paired the sender that had already spent its budget"
  pass "a sender that spends its own attempt budget cannot pair even with the right code"
}

# Binding the offer to one numeric account is the strongest form: any other
# sender is dropped before the attempt budget is touched at all.
test_pairing_can_be_bound_to_one_numeric_account() {
  local dir home fakebin code
  dir="$TMP_ROOT/pair-userid"
  mkdir -p "$dir"
  tg_fake_api "$dir"
  fakebin=$TG_FAKEBIN
  home=$(tg_home "$dir" home "$TEST_TOKEN")
  code=$(tg_run "$home" "$fakebin" "$PAIR" begin --label eren \
    --project eren-pov-site --user-id "$PEER_ID" | sed -n 's|^  /start ||p')

  tg_queue 340 "$OTHER_ID" "$OTHER_ID" "/start $code"
  tg_run "$home" "$fakebin" "$POLL" >/dev/null
  assert_absent "$home/state/telegram/peer.json" \
    "an account the offer was not bound to redeemed the code"
  [ "$(jq -r '.attempts_by | length' "$home/state/telegram/pairing.json")" = 0 ] \
    || fail "a sender the offer was not bound to still consumed an attempt"
  [ "$(tg_sent_count)" = 0 ] || fail "a refused pairing attempt produced an outbound message"

  tg_queue 341 "$PEER_ID" "$PEER_ID" "/start $code"
  tg_run "$home" "$fakebin" "$POLL" >/dev/null
  assert_present "$home/state/telegram/peer.json" "the bound account could not redeem its own offer"
  pass "an offer bound to one numeric account refuses every other sender without spending anything"
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

test_re_announcement_budget_retires_a_stuck_entry() {
  local out i now entry
  paired_home recovery-bound
  tg_queue 1110 "$PEER_ID" "$PEER_ID" "anfrage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  entry="$HOME_DIR/state/telegram/inbox/tg-1110.json"
  now=$(date +%s)

  # The agent never drains it - a reply that keeps failing leaves the entry in
  # place on purpose. Each poll is a whole recovery window later, so every sweep
  # is due and the entry would re-wake firstmate forever if it were unbounded.
  i=1
  while [ "$i" -le 3 ]; do
    out=$(FMTG_NOW_OVERRIDE=$(( now + i * 1000 )) tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" 2>&1)
    assert_contains "$out" "telegram-message tg-1110" "re-announcement $i of the budget never happened"
    i=$(( i + 1 ))
  done

  out=$(FMTG_NOW_OVERRIDE=$(( now + 4000 )) tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" 2>&1)
  assert_contains "$out" "telegram-error" "a stuck entry was retired without reporting it once"
  assert_not_contains "$out" "telegram-message tg-1110" "the spent budget still produced a message wake"

  out=$(FMTG_NOW_OVERRIDE=$(( now + 5000 )) tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" 2>&1)
  [ -z "$out" ] || fail "a stuck entry kept waking firstmate after its budget was spent: $out"
  assert_present "$entry" "an undelivered request was dropped instead of being kept for the agent"
  pass "a stuck inbox entry is re-announced a bounded number of times, reported once, and never dropped"
}

test_long_poll_stays_inside_the_watcher_kill_budget() {
  local line maxtime timeout
  paired_home budget

  # 45 is a documented-valid poll timeout, and the watcher's default per-check
  # kill budget is 30 seconds. A check the watcher kills produces no output at
  # all, which is indistinguishable from "nothing to report", so the request has
  # to finish inside that budget rather than be honored as configured.
  FM_TELEGRAM_POLL_TIMEOUT=45 tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  line=$(grep '^getUpdates ' "$FAKE_TG_DIR/budget.log" | tail -n1)
  maxtime=${line#*max-time=}
  maxtime=${maxtime%% *}
  timeout=${line##*timeout=}
  case "$maxtime$timeout" in ''|*[!0-9]*) fail "the request recorded no usable deadlines: $line" ;; esac
  [ "$maxtime" -lt 30 ] \
    || fail "the request deadline (${maxtime}s) is not inside the watcher's 30s kill budget"
  [ "$timeout" -lt "$maxtime" ] \
    || fail "the long poll (${timeout}s) outlives its own request deadline (${maxtime}s)"

  # The ceiling follows the budget rather than replacing it: a bigger budget
  # restores the configured poll.
  FM_CHECK_TIMEOUT=60 FM_TELEGRAM_POLL_TIMEOUT=45 tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  line=$(grep '^getUpdates ' "$FAKE_TG_DIR/budget.log" | tail -n1)
  timeout=${line##*timeout=}
  [ "$timeout" = 45 ] \
    || fail "a larger per-check budget did not restore the configured long poll (${timeout}s)"
  pass "the long poll and its request deadline stay inside the watcher's per-check kill budget"
}

test_one_check_spends_one_budget_across_its_calls() {
  local dir home fakebin code line poll_max send_max
  dir="$TMP_ROOT/budget-shared"
  mkdir -p "$dir"
  tg_fake_api "$dir"
  fakebin=$TG_FAKEBIN
  home=$(tg_home "$dir" home "$TEST_TOKEN")
  code=$(tg_run "$home" "$fakebin" "$PAIR" begin --label eren --project eren-pov-site \
    | sed -n 's|^  /start ||p')
  tg_queue 1300 "$PEER_ID" "$PEER_ID" "/start $code"

  # Redeeming a code makes ONE check issue two calls: the long poll, and then the
  # pairing confirmation. The watcher kills the check rather than the call, so a
  # second call that started its own full-length deadline would be killed
  # mid-request and the "telegram-paired" wake would be lost with it.
  FAKE_TG_GETUPDATES_DELAY=2 tg_run "$home" "$fakebin" "$POLL" >/dev/null

  line=$(grep '^getUpdates ' "$FAKE_TG_DIR/budget.log" | tail -n1)
  poll_max=${line#*max-time=}
  poll_max=${poll_max%% *}
  line=$(grep '^sendMessage ' "$FAKE_TG_DIR/budget.log" | tail -n1)
  send_max=${line#*max-time=}
  send_max=${send_max%% *}
  case "$poll_max$send_max" in ''|*[!0-9]*) fail "the check recorded no usable deadlines: $poll_max/$send_max" ;; esac

  [ "$send_max" -le "$(( poll_max - 2 ))" ] \
    || fail "the pairing confirmation took a fresh ${send_max}s deadline after the long poll had already spent 2s of the same ${poll_max}s budget"
  [ "$send_max" -ge 2 ] \
    || fail "the pairing confirmation was given a deadline (${send_max}s) too short to ever succeed"
  assert_present "$home/state/telegram/peer.json" "the delayed poll never pinned the peer"
  [ "$(tg_sent_count)" = 1 ] || fail "the pairing confirmation was not delivered"
  pass "one watcher check spends one budget across every call it makes"
}

test_orphaned_publication_temps_are_swept() {
  local temp fresh now
  paired_home temps
  tg_queue 1200 "$PEER_ID" "$PEER_ID" "anfrage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  now=$(date +%s)

  # What a poll killed between mktemp and its rename leaves behind: the message
  # body under a name no *.json scan can see.
  temp="$HOME_DIR/state/telegram/inbox/.tg-1201.json.fm-private.aBc123"
  printf '{"text":"geheime nachricht"}\n' > "$temp"
  chmod 600 "$temp"

  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  assert_present "$temp" "the sweep took a publication temporary that could still be in flight"

  FMTG_NOW_OVERRIDE=$(( now + 4000 )) tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  assert_absent "$temp" "an orphaned publication temporary was left holding message content"

  # Revoke reports that pending messages are gone, so it takes them at any age.
  fresh="$HOME_DIR/state/telegram/inbox/.tg-1202.json.fm-private.XyZ987"
  printf '{"text":"geheime nachricht"}\n' > "$fresh"
  chmod 600 "$fresh"
  tg_run "$HOME_DIR" "$FAKEBIN" "$PAIR" revoke --yes >/dev/null
  assert_absent "$fresh" "revoke left a temporary holding message content behind"
  pass "an orphaned publication temporary is swept, an in-flight one is left alone, and revoke takes both"
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

  # The flood continues into the next poll cycle. That poll's getUpdates answers
  # 200, which proves the transport recovered and nothing else - re-arming the
  # rate report on it would cost one wake per cycle for the rest of the window,
  # which is exactly the amplification the limiter exists to prevent.
  i=0
  while [ "$i" -lt 5 ]; do
    tg_queue "$(( 1510 + i ))" "$PEER_ID" "$PEER_ID" "noch eine $i"
    i=$(( i + 1 ))
  done
  out=$(FM_TELEGRAM_RATE_MAX=2 tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" 2>&1)
  [ -z "$out" ] || fail "a continuing flood woke firstmate again on the next poll cycle: $out"
  [ "$(count_files "$HOME_DIR/state/telegram/inbox")" = 2 ] \
    || fail "the rate limit stopped bounding the flood on a later cycle"

  # A reopened window is the one thing that does re-arm the report, so a second
  # flood later is not silently swallowed.
  i=0
  while [ "$i" -lt 5 ]; do
    tg_queue "$(( 1520 + i ))" "$PEER_ID" "$PEER_ID" "spaeter $i"
    i=$(( i + 1 ))
  done
  out=$(FMTG_NOW_OVERRIDE=$(( $(date +%s) + 4000 )) FM_TELEGRAM_RATE_MAX=2 \
    tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" 2>&1)
  assert_contains "$out" "rate limit" "a flood in a fresh window was never reported"
  pass "a flood costs one wake per window, not one per poll cycle, and a new window reports again"
}

# The watcher TERMs and then KILLs a check that outruns its budget, and the long
# poll is the widest window inside that budget, so no cleanup path can be relied
# on: the token must never be written anywhere a kill could strand it.
test_a_killed_poll_leaves_no_token_on_disk() {
  local tmp pid i leaked
  paired_home killed
  tg_queue 1700 "$PEER_ID" "$PEER_ID" "anfrage"
  tmp="$TMP_ROOT/killed/tmp"
  mkdir -p "$tmp"
  : > "$FAKE_TG_DIR/token-seen.log"

  PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    TMPDIR="$tmp" FAKE_TG_GETUPDATES_DELAY=5 "$POLL" >/dev/null 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$FAKE_TG_DIR/token-seen.log" ]; do
    sleep 0.1
    i=$(( i + 1 ))
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  # Both halves, so neither can pass vacuously: the killed call really did carry
  # the token to the transport, and the kill really did strand temporaries.
  assert_grep "$TEST_TOKEN" "$FAKE_TG_DIR/token-seen.log" \
    "the killed call never carried a token, so the on-disk assertion proves nothing"
  [ "$(count_files "$HOME_DIR/state/telegram/inbox")" = 0 ] \
    || fail "the poll ran to completion instead of being killed mid-call"
  [ -n "$(find "$tmp" -type f 2>/dev/null)" ] \
    || fail "the kill stranded no temporary at all, so nothing was proven"

  leaked=$(grep -rl "$TEST_TOKEN" "$tmp" 2>/dev/null || true)
  [ -z "$leaked" ] || fail "a killed poll left the bot token on disk: $leaked"
  pass "a killed poll strands temporaries but never one holding the bot token"
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

  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" arm-publish wrong 2>&1 || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=6" "arming a publish in another project was not refused"
  pass "task links and publish arming are refused outside the paired project"
}

# An operator reading `show` has to be able to tell an unlinked task from one
# linked to an empty value, so an absent meta key must not read as a blank.
test_show_names_an_absent_link_rather_than_printing_a_blank() {
  local out
  paired_home show
  tg_queue 1650 "$PEER_ID" "$PEER_ID" "anfrage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  fm_write_meta "$HOME_DIR/state/site.meta" "project=$HOME_DIR/projects/eren-pov-site" "window=t:1"
  fm_write_meta "$HOME_DIR/state/bare.meta" "window=t:2"

  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" show site 2>&1)
  assert_contains "$out" "linked request: <none>" "an unlinked task printed a blank instead of <none>"
  assert_contains "$out" "linked chat: <none>" "an unlinked task printed a blank chat instead of <none>"

  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" show bare 2>&1)
  assert_contains "$out" "project: <none>" "a task with no project line printed a blank project"

  tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" link site tg-1650 >/dev/null \
    || fail "linking a task in the paired project was refused"
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" show site 2>&1)
  assert_contains "$out" "linked request: tg-1650" "show did not report a real link"
  assert_not_contains "$out" "linked request: <none>" "a linked task still read as unlinked"
  pass "show distinguishes an absent link from a linked value instead of printing a blank"
}

# --- two-step publish -------------------------------------------------------

# Deliver one real inbound message from the paired person and echo its request
# id. Every confirmation below has to travel this way: confirm-publish reads the
# text from the message's own stored record, never from a caller-supplied path.
tg_say() {  # <update_id> <text>
  tg_queue "$1" "$PEER_ID" "$PEER_ID" "$2"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  printf 'tg-%s' "$1"
}

# Arm a publish confirmation on a paired home. Sets HOME_DIR, FAKEBIN, and
# PUBLISH_CODE in the caller.
publish_home() {  # <name>
  local name=$1
  paired_home "$name"
  # arm-publish and confirm-publish resolve the prepared revision from the
  # task's own worktree with `git rev-parse HEAD`, so the fixture needs a real
  # one. That is the point: an agent cannot arm one revision and confirm
  # against another, because neither end takes the revision from its caller.
  PUBLISH_WT="$HOME_DIR/wt"
  mkdir -p "$PUBLISH_WT"
  git -C "$PUBLISH_WT" init -q
  git -C "$PUBLISH_WT" -c user.email=t@example.invalid -c user.name=t \
    commit -q --allow-empty -m prepared
  fm_write_meta "$HOME_DIR/state/site.meta" "project=$HOME_DIR/projects/eren-pov-site" \
    "worktree=$PUBLISH_WT" "window=t:1"
  PUBLISH_HEAD=$(git -C "$PUBLISH_WT" rev-parse HEAD)
  PUBLISH_CODE=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" arm-publish site)
}

test_publish_needs_a_matching_confirmation() {
  local rid out
  publish_home publish-ok
  [ -n "$PUBLISH_CODE" ] || fail "arm-publish printed no confirmation code"
  # The armed revision is the worktree's real HEAD, resolved by arm-publish
  # itself, so the record cannot describe a change the caller merely claimed.
  [ "$(jq -r '.head' "$HOME_DIR/state/telegram/publish/site.json")" = "$PUBLISH_HEAD" ] \
    || fail "arm-publish did not record the task's actual prepared revision"
  assert_no_grep "$PUBLISH_CODE" "$HOME_DIR/state/telegram/publish/site.json" \
    "the confirmation code was stored in the clear and could be replayed"

  rid=$(tg_say 1900 "ja mach das live: $PUBLISH_CODE")
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" confirm-publish site --request "$rid" 2>&1)
  assert_contains "$out" "confirmed" "a matching confirmation was not accepted"
  # The approval names the message that carried it, not just the moment it was taken.
  [ "$(jq -r '.confirmed_by' "$HOME_DIR/state/telegram/publish/site.json")" = "$rid" ] \
    || fail "the consumed record does not name the message that confirmed it"

  # Single use.
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" confirm-publish site --request "$rid" 2>&1 \
    || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=7" "a confirmation was accepted twice"
  pass "publishing needs one matching confirmation code, and it is single use"
}

test_bare_agreement_is_not_a_confirmation() {
  local rid out
  publish_home publish-bare
  rid=$(tg_say 1910 "ja klar, mach das")
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" confirm-publish site --request "$rid" 2>&1 \
    || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=5" "a bare yes was treated as a publish confirmation"
  pass "a bare agreement without the code never authorizes publishing"
}

test_stale_confirmation_is_refused() {
  local rid out
  publish_home publish-stale
  rid=$(tg_say 1920 "$PUBLISH_CODE")
  # The prepared change really moved after the preview was shown: the worktree
  # has a new HEAD, and confirm-publish resolves that itself rather than
  # believing a revision its caller passed in.
  git -C "$PUBLISH_WT" -c user.email=t@example.invalid -c user.name=t \
    commit -q --allow-empty -m rebuilt
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" confirm-publish site --request "$rid" 2>&1 \
    || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=6" "a confirmation for a change that moved was accepted"
  assert_contains "$out" "re-preview" "the stale refusal did not say what to do next"
  pass "a confirmation is refused once the prepared change is no longer what was previewed"
}

test_expired_and_over_budget_confirmations_are_refused() {
  local rid wrong out i
  publish_home publish-expiry
  rid=$(tg_say 1930 "$PUBLISH_CODE")
  out=$(FMTG_NOW_OVERRIDE=$(( $(date +%s) + 200000 )) tg_run "$HOME_DIR" "$FAKEBIN" \
    "$TGTASK" confirm-publish site --request "$rid" 2>&1 || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=4" "an expired confirmation was accepted"

  publish_home publish-budget
  wrong=$(tg_say 1940 "WRONGX")
  i=0
  while [ "$i" -lt 5 ]; do
    tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" confirm-publish site --request "$wrong" >/dev/null 2>&1 || true
    i=$(( i + 1 ))
  done
  rid=$(tg_say 1941 "$PUBLISH_CODE")
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" confirm-publish site --request "$rid" 2>&1 \
    || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=8" "the confirmation attempt budget was not enforced"
  pass "expired confirmations and exhausted attempt budgets are both refused"
}

# The publish confirmation used to be read from any path the caller named, so
# nothing tied an approval to the paired person having said anything at all:
# writing the code the script had just printed into a file confirmed it, and
# "never arm and confirm in the same turn" lived only in an agent skill.
test_a_confirmation_must_be_carried_by_a_fresh_message_from_that_person() {
  local out rid armed_late
  publish_home publish-source

  # The exact reproducer: the agent writes the code it was just handed into a
  # file of its own. There is no path argument left to point anywhere.
  printf 'ja mach das live: %s\n' "$PUBLISH_CODE" > "$HOME_DIR/self.txt"
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" confirm-publish site \
    --message-file "$HOME_DIR/self.txt" 2>&1 || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=2" "the removed --message-file path argument was still accepted"
  [ "$(jq -r '.consumed_at' "$HOME_DIR/state/telegram/publish/site.json")" = null ] \
    || fail "a self-written file consumed the publish authorization"

  # A syntactically valid request id this home never accepted is inert too.
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" confirm-publish site \
    --request tg-nonexistent 2>&1 || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=9" "an invented request id confirmed a publish"

  # A message that predates the preview cannot be an answer to it, however
  # perfectly it matches: this is the same-turn arm-and-confirm reproducer.
  rid=$(tg_say 1950 "$PUBLISH_CODE")
  armed_late=$(( $(date +%s) + 600 ))
  FMTG_NOW_OVERRIDE=$armed_late tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" arm-publish site >/dev/null
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" confirm-publish site --request "$rid" 2>&1 \
    || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=9" "a message that arrived before the preview confirmed it anyway"
  assert_contains "$out" "before the preview" "the stale-message refusal did not say why"
  [ "$(jq -r '.consumed_at' "$HOME_DIR/state/telegram/publish/site.json")" = null ] \
    || fail "a message older than the preview consumed the publish authorization"
  pass "a publish confirmation must be carried by a fresh, authentic message from the paired person"
}

# A confirmation must also arrive inside a live exchange: once a terminal reply
# has closed that conversation, nothing in it can authorize anything.
test_a_closed_exchange_cannot_confirm_a_publish() {
  local rid out
  publish_home publish-closed
  rid=$(tg_say 1970 "$PUBLISH_CODE")
  printf 'alles klar\n' | tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" "$rid" --final >/dev/null
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" confirm-publish site --request "$rid" 2>&1 \
    || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=9" "a message from a closed exchange confirmed a publish"
  [ "$(jq -r '.consumed_at' "$HOME_DIR/state/telegram/publish/site.json")" = null ] \
    || fail "a message from a closed exchange consumed the publish authorization"
  pass "a message from an exchange a final reply already closed cannot confirm a publish"
}

# A message with no text at all - an attachment or an over-long body - carries
# no words, so it can never carry a confirmation either.
test_a_textless_message_cannot_confirm_a_publish() {
  local out
  publish_home publish-textless
  tg_queue_json "$(jq -cn --argjson chat "$PEER_ID" \
    '{update_id:1960, message:{message_id:19600, date:1750000000,
      from:{id:$chat, is_bot:false, first_name:"Paired"},
      chat:{id:$chat, type:"private"}, photo:[{file_id:"x"}]}}')"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  [ "$(jq -r '.kind' "$HOME_DIR/state/telegram/inbox/tg-1960.json")" = unsupported ] \
    || fail "the fixture did not produce a textless inbox entry"
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" confirm-publish site --request tg-1960 2>&1 \
    || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=9" "a message carrying no text confirmed a publish"
  pass "a message with no text can never carry a publish confirmation"
}

# arm-publish and confirm-publish both resolve the prepared revision by running
# git in the task's own worktree, and that resolution can fail. It used to fail
# inside a command substitution, where `exit` ends only the subshell: both
# subcommands printed the refusal and then carried on with an empty revision.
test_an_unresolvable_prepared_revision_refuses_instead_of_arming() {
  local out
  paired_home publish-norev
  fm_write_meta "$HOME_DIR/state/site.meta" "project=$HOME_DIR/projects/eren-pov-site" \
    "worktree=$HOME_DIR/gone" "window=t:1"
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" arm-publish site 2>&1 || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=6" "arming with an unresolvable prepared revision was not refused"
  assert_absent "$HOME_DIR/state/telegram/publish/site.json" \
    "a refused arm still wrote a publish record no landing could ever match"
  pass "an unresolvable prepared revision refuses instead of arming an empty one"
}

# --- replies ----------------------------------------------------------------

test_reply_is_literal_and_single_target() {
  local out body
  paired_home reply
  body="$HOME_DIR/reply.txt"
  printf '%s\n' '*fett* _kursiv_ [link](x) `code` \ und & <b>' > "$body"
  tg_queue 1700 "$PEER_ID" "$PEER_ID" "frage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" tg-1700 >/dev/null < "$body"

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
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" tg-1800 2>&1 < "$HOME_DIR/reply.txt" \
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
  out=$(tg_run "$home" "$fakebin" "$REPLY" tg-1 2>&1 < "$home/reply.txt" || printf 'rc=%s' "$?")
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
  FM_TELEGRAM_MAX_CHARS=200 tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" tg-1900 >/dev/null < "$body"

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
    tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" tg-2000 2>&1 < "$body" || printf 'rc=%s' "$?")
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

  tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" --task site --final >/dev/null < "$HOME_DIR/reply.txt"
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
  FM_TELEGRAM_DRY_RUN=1 tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" tg-2200 >/dev/null < "$HOME_DIR/reply.txt"
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
  # The marker is DATA, never shell: nothing sources it, and the watcher derives
  # its own cadence from the byte-authenticated shim instead. A marker that
  # still carried an `export` would invite exactly the arm-time execution the
  # seatbelt can no longer bless.
  assert_grep 'check_interval=30' "$home/config/telegram.env" \
    "the armed marker does not record the bridged cadence"
  assert_no_grep 'export' "$home/config/telegram.env" \
    "the armed marker still looks like something a caller should source"

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

# No harness protocol may tell anyone to source a cadence file, because nothing
# sources one any more: the blessed-path source node was an indirect shell
# execution vector, and bin/fm-watch.sh derives its cadence from the
# byte-authenticated channel shim instead.
test_no_harness_protocol_sources_a_cadence_file() {
  local dir home config out h
  dir="$TMP_ROOT/cadence"
  home="$dir/home"
  config="$dir/config"
  mkdir -p "$home/state" "$config"
  : > "$config/telegram.env"
  for h in claude codex opencode pi pi-signed grok unknown; do
    out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" \
      "$ROOT/bin/fm-supervision-instructions.sh" --harness "$h")
    assert_contains "$out" "- Telegram bridge: active" "harness $h lost the bridge state line"
    assert_not_contains "$out" ". '$config/telegram.env'" \
      "harness $h still renders a source node for the bridge cadence file"
    assert_not_contains "$out" "source '$config/telegram.env'" \
      "harness $h still tells the agent to source the bridge cadence file"
  done
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness claude --repair-line)
  assert_not_contains "$out" "$config/telegram.env" \
    "the repair line still tells the agent to source the bridge cadence file"
  pass "no harness protocol sources a cadence file, on any supported harness"
}

# The watcher resolves its own cadence, and only from a shim whose bytes still
# match. A tampered or mode-widened shim falls back to the slow default rather
# than being trusted.
test_watcher_derives_its_cadence_from_the_authenticated_shim() {
  local dir home out
  dir="$TMP_ROOT/derived-cadence"
  home="$dir/home"
  mkdir -p "$home/state" "$home/config"
  probe() {
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash -c \
      '. "$1/bin/fm-watch.sh" >/dev/null 2>&1; printf "%s" "$CHECK_INTERVAL"' _ "$ROOT"
  }
  out=$(probe)
  [ "$out" = 300 ] || fail "an unbridged home did not use the default cadence (got $out)"

  bash -c '. "$1/bin/fm-tg-lib.sh"; fmtg_poll_shim_content "$2" "$1"' _ "$ROOT" "$home" \
    > "$home/state/telegram-watch.check.sh"
  chmod 700 "$home/state/telegram-watch.check.sh"
  out=$(probe)
  [ "$out" = 30 ] || fail "a bridged home did not derive the 30s cadence (got $out)"

  printf '\n# tampered\n' >> "$home/state/telegram-watch.check.sh"
  out=$(probe)
  [ "$out" = 300 ] || fail "a tampered shim was still trusted for the fast cadence (got $out)"

  bash -c '. "$1/bin/fm-tg-lib.sh"; fmtg_poll_shim_content "$2" "$1"' _ "$ROOT" "$home" \
    > "$home/state/telegram-watch.check.sh"
  chmod 777 "$home/state/telegram-watch.check.sh"
  out=$(probe)
  [ "$out" = 300 ] || fail "a world-writable shim was still trusted for the fast cadence (got $out)"
  pass "the watcher derives its cadence only from a shim whose bytes and mode still validate"
}

# The exact adversarial reproducer: a mode-0600 cadence file at the blessed path
# whose contents are a command. The seatbelt must deny the rendered arm rather
# than allowing a source node it cannot authenticate.
test_arm_seatbelt_blesses_no_source_node() {
  local dir home out rc
  dir="$TMP_ROOT/arm-source"
  home="$dir/home"
  mkdir -p "$home/config" "$home/state"
  printf 'touch %s\nexport FM_CHECK_INTERVAL=30\n' "$home/CODE_EXECUTED" > "$home/config/telegram.env"
  chmod 600 "$home/config/telegram.env"

  rc=0
  FM_HOME="$home" "$ROOT/bin/fm-arm-pretool-check.sh" \
    --command "[ -f $home/config/telegram.env ] && . $home/config/telegram.env; exec bin/fm-watch-arm.sh" \
    >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "the seatbelt still allows an arm that sources the cadence file"

  rc=0
  FM_HOME="$home" "$ROOT/bin/fm-arm-pretool-check.sh" \
    --command ". $home/config/telegram.env; exec bin/fm-watch-arm.sh" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "the seatbelt still allows a bare source node before the arm"

  # The command firstmate actually renders is still allowed, and so is ordinary
  # cd/export setup, so removing the source blessing did not break arming.
  rc=0
  FM_HOME="$home" "$ROOT/bin/fm-arm-pretool-check.sh" --command 'exec bin/fm-watch-arm.sh' \
    >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "the seatbelt denies the arm command firstmate itself renders"
  rc=0
  FM_HOME="$home" "$ROOT/bin/fm-arm-pretool-check.sh" \
    --command 'cd /tmp; export FM_POLL=5; exec bin/fm-watch-arm.sh' >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "the seatbelt denies ordinary cd/export setup before the arm"

  assert_absent "$home/CODE_EXECUTED" "the cadence payload ran during the policy check"
  pass "the arm seatbelt blesses no source node, so a writable cadence file cannot execute"
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
  assert_contains "$out" "exec bin/fm-watch-arm.sh" "the arm command was lost"
  assert_not_contains "$out" "x-mode.env' ]" "the arm command still sources the X cadence file"
  assert_not_contains "$out" "telegram.env' ]" "the arm command still sources the bridge cadence file"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness claude --repair-line)
  assert_not_contains "$out" "$config/telegram.env" "the repair line still sources a cadence file"
  assert_not_contains "$out" "$config/x-mode.env" "the repair line still sources a cadence file"
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

# The three integration points below are the ones a bridge-only home actually
# depends on and that no earlier test touched: the PR-check migration that runs
# on every watcher start, the arm seatbelt that vets the rendered arm command,
# and the Claude Stop auto-arm that is the default harness's routine arm path.

test_migration_does_not_quarantine_the_bridge_shim() {
  local dir home out
  dir="$TMP_ROOT/migration"
  mkdir -p "$dir"
  tg_fake_api "$dir"
  home=$(tg_home "$dir" home "$TEST_TOKEN")
  tg_run "$home" "$TG_FAKEBIN" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1 || true
  assert_present "$home/state/telegram-watch.check.sh" "bootstrap did not arm the shim to migrate against"

  # bin/fm-watch.sh runs this on every watcher start, before taking the lock.
  for out in "" --checks-safe; do
    PATH="$TG_FAKEBIN:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
      "$ROOT/bin/fm-pr-check-migrate.sh" $out >/dev/null 2>&1 || true
    assert_present "$home/state/telegram-watch.check.sh" \
      "the migration quarantined a valid bridge shim (mode '$out'), disarming the bridge on watcher start"
  done
  assert_absent "$home/state/.pr-check-quarantine/telegram-watch.check.sh" \
    "the bridge shim was moved into PR-check quarantine"

  # A shim whose bytes do not match is not exempt and must still be quarantined.
  printf '#!/usr/bin/env bash\nexec /bin/echo tampered\n' > "$home/state/telegram-watch.check.sh"
  chmod 700 "$home/state/telegram-watch.check.sh"
  PATH="$TG_FAKEBIN:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-pr-check-migrate.sh" >/dev/null 2>&1 || true
  assert_absent "$home/state/telegram-watch.check.sh" \
    "a tampered bridge shim was treated as exempt instead of being quarantined"
  pass "the PR-check migration exempts a valid bridge shim and still quarantines a tampered one"
}

test_arm_seatbelt_allows_the_rendered_bridge_arm() {
  local dir home config rendered out rc
  dir="$TMP_ROOT/seatbelt"
  home="$dir/home"
  # The policy blesses only <home>/config/<cadence>.env, so the fixture uses the
  # real layout rather than a detached config dir.
  config="$home/config"
  mkdir -p "$home/state" "$config"
  : > "$config/telegram.env"

  # Feed the seatbelt the exact string the supervision renderer emits.
  rendered=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness grok --telegram 1 \
    | grep -F 'exec bin/fm-watch-arm.sh' | sed 's/^ *`//; s/`$//')
  [ -n "$rendered" ] || fail "could not render the grok arm command"
  rc=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-arm-pretool-check.sh" --command "$rendered" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the seatbelt denied firstmate's own bridge arm command (exit $rc): $out"

  # Both channels armed renders two source nodes; that must pass too.
  : > "$config/x-mode.env"
  rendered=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness grok \
    | grep -F 'exec bin/fm-watch-arm.sh' | sed 's/^ *`//; s/`$//')
  rc=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-arm-pretool-check.sh" --command "$rendered" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the seatbelt denied the two-channel arm command (exit $rc): $out"

  # The widening must not bless an arbitrary sourced file.
  rc=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-arm-pretool-check.sh" --command \
    "[ -f '$config/evil.env' ] && . '$config/evil.env'; exec bin/fm-watch-arm.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the seatbelt now allows sourcing an arbitrary file before the arm"
  pass "the arm seatbelt accepts the rendered bridge arm, one or both channels, and nothing else"
}

# The routine arm path for the default primary harness must reach the bridged
# cadence WITHOUT sourcing anything. The hook used to source both cadence files
# directly, which is the same indirect execution vector the arm seatbelt was
# hardened against; the cadence now comes from the watcher's own derivation.
test_stop_autoarm_reaches_the_bridge_cadence_without_sourcing() {
  local dir home out
  dir="$TMP_ROOT/autoarm"
  home="$dir/home"
  mkdir -p "$home/state" "$home/config"
  printf 'channel=telegram\ncheck_interval=30\n' > "$home/config/telegram.env"

  assert_no_grep '\. "\$CONFIG/\$cadence_env"' "$ROOT/bin/fm-claude-stop-autoarm.sh" \
    "the Claude Stop auto-arm still sources a cadence file"
  assert_no_grep 'cadence_env' "$ROOT/bin/fm-claude-stop-autoarm.sh" \
    "the Claude Stop auto-arm still iterates cadence files to source"

  # A bridged home still arms at 30s, derived from the validated shim.
  bash -c '. "$1/bin/fm-tg-lib.sh"; fmtg_poll_shim_content "$2" "$1"' _ "$ROOT" "$home" \
    > "$home/state/telegram-watch.check.sh"
  chmod 700 "$home/state/telegram-watch.check.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash -c \
    '. "$1/bin/fm-watch.sh" >/dev/null 2>&1; printf "%s" "$CHECK_INTERVAL"' _ "$ROOT")
  [ "$out" = 30 ] || fail "a bridge-only home would arm at cadence $out instead of 30"
  pass "the default harness's routine arm reaches the bridge cadence without sourcing anything"
}

test_gate_agent_cannot_reach_the_channel() {
  local out
  paired_home gate
  printf 'hallo\n' > "$HOME_DIR/reply.txt"
  # A no-mistakes gate agent runs inside a firstmate checkout and auto-loads
  # AGENTS.md, so it can read that this channel exists. The same guard the fleet
  # entrypoints use must keep it away from a channel that reaches outside.
  out=$(NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS='' tg_run "$HOME_DIR" "$FAKEBIN" \
    "$REPLY" tg-1 2>&1 < "$HOME_DIR/reply.txt" || true)
  assert_contains "$out" "gate agent must not drive the fleet" \
    "a gate agent was allowed to message the paired person"
  [ "$(tg_sent_count)" = 1 ] || fail "a gate agent delivered a message"

  out=$(NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS='' tg_run "$HOME_DIR" "$FAKEBIN" \
    "$PAIR" revoke --yes 2>&1 || true)
  assert_contains "$out" "gate agent must not drive the fleet" \
    "a gate agent was allowed to revoke the pairing"
  assert_present "$HOME_DIR/state/telegram/peer.json" "a gate agent revoked the pairing"

  out=$(NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS='' tg_run "$HOME_DIR" "$FAKEBIN" \
    "$TGTASK" arm-publish site 2>&1 || true)
  assert_contains "$out" "gate agent must not drive the fleet" \
    "a gate agent was allowed to arm a publish confirmation"
  pass "a no-mistakes gate agent cannot message, unpair, or authorize a publish"
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

# --- adversarial regressions ------------------------------------------------
#
# Each test below is a counterexample from the two independent security reviews
# of this branch, committed so the defect cannot come back silently.

# The reply helper must not be a generic path-to-Telegram primitive, and must
# not answer a request this home never accepted.
test_reply_needs_a_real_request_and_takes_no_path() {
  local out sentinel
  paired_home reply-authentic
  sentinel="$HOME_DIR/captain-private.txt"
  printf 'CAPTAIN_PRIVATE_SENTINEL\n' > "$sentinel"

  # The exact reproducer: a syntactically valid but never-accepted request id
  # plus a file outside any reply area.
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" tg-nonexistent --text-file "$sentinel" 2>&1 \
    || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=2" "the removed --text-file path argument was still accepted"
  assert_not_contains "$out" "CAPTAIN_PRIVATE_SENTINEL" "the refusal echoed the file it was pointed at"

  # Even on stdin, an invented request id cannot address the channel.
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" tg-nonexistent 2>&1 < "$sentinel" \
    || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=4" "a request this home never accepted was answered anyway"
  [ "$(tg_sent_count)" = 1 ] \
    || fail "an unauthenticated reply reached the chat (only the pairing confirmation should have)"
  assert_absent "$HOME_DIR/state/telegram/reply/tg-nonexistent.txt" \
    "a refused reply still staged a body"
  pass "a reply needs a request this home really accepted, and takes no caller-supplied path"
}

# A real request is answered, staged under bridge state, and closed by --final
# so nothing can post against the finished exchange afterwards.
test_reply_body_is_staged_and_the_request_closes() {
  local out
  paired_home reply-staged
  tg_queue 2300 "$PEER_ID" "$PEER_ID" "kannst du die ueberschrift aendern"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null

  printf 'die ueberschrift ist geaendert\n' \
    | tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" tg-2300 --final >/dev/null \
    || fail "a genuine reply to a real request was refused"
  [ "$(tg_sent_text 2)" = 'die ueberschrift ist geaendert' ] || fail "the staged body was not delivered"
  assert_absent "$HOME_DIR/state/telegram/reply/tg-2300.txt" \
    "the staged reply body outlived its delivery"
  assert_present "$HOME_DIR/state/telegram/context/tg-2300.json" \
    "closing the request erased the evidence of which conversation it answered"

  out=$(printf 'nochmal\n' | tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" tg-2300 2>&1 || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=7" "a closed request accepted a further reply"
  pass "a reply body is staged under bridge state and a final reply closes the request"
}

# The outbound path checks project scope, exactly as the inbound task
# operations do.
test_reply_refuses_a_task_outside_the_paired_project() {
  local out
  paired_home reply-project
  tg_queue 2400 "$PEER_ID" "$PEER_ID" "frage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  fm_write_meta "$HOME_DIR/state/other.meta" "project=$HOME_DIR/projects/venture-cockpit" \
    "window=t:9" "tg_request=tg-2400" "tg_chat=$PEER_ID" "tg_request_ts=1"
  out=$(printf 'hallo\n' | tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" --task other 2>&1 || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=6" "a task outside the paired project addressed the channel"
  pass "a reply for a task outside the paired project is refused"
}

# Progress that is delivered but not durably recorded is ambiguous, never
# "preserved for retry": a retry from a stale counter repeats a real message.
test_undurable_progress_is_reported_as_ambiguous_delivery() {
  local out body
  paired_home reply-ambiguous
  body="$HOME_DIR/reply.txt"
  printf 'Erster Absatz mit genug Text fuer eine eigene Nachricht.\n\nZweiter Absatz mit genug Text fuer eine eigene Nachricht.\n' > "$body"
  tg_queue 2500 "$PEER_ID" "$PEER_ID" "frage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null

  # Make the outbox unwritable after the plan is staged, so the FIRST progress
  # write after a successful send fails.
  printf 'x\n' | tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" tg-2500 >/dev/null 2>&1 || true
  tg_queue 2501 "$PEER_ID" "$PEER_ID" "frage2"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  chmod 500 "$HOME_DIR/state/telegram/outbox" 2>/dev/null || true
  out=$(FM_TELEGRAM_MAX_CHARS=100 tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" tg-2501 2>&1 < "$body" \
    || printf 'rc=%s' "$?")
  chmod 700 "$HOME_DIR/state/telegram/outbox" 2>/dev/null || true
  assert_contains "$out" "rc=" "an unwritable outbox produced no diagnosis at all"
  assert_not_contains "$out" "retry with --retry" \
    "an undurable progress record still claimed the reply was safely preserved for retry"
  pass "delivery whose progress cannot be persisted is never reported as safely resumable"
}

# Cleanup must hold the same boundary publication does. Replacing the bridge
# directory with a symlink must refuse, not delete the symlink's target.
test_cleanup_refuses_a_symlinked_bridge_directory() {
  local dir home victim out
  dir="$TMP_ROOT/cleanup-symlink"
  home="$dir/home"
  victim="$dir/victim"
  mkdir -p "$home/state" "$victim"
  printf 'must-survive\n' > "$victim/peer.json"
  printf 'must-survive\n' > "$victim/pairing.json"
  ln -s "$victim" "$home/state/telegram"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-tg-pair.sh" revoke --yes 2>&1 || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=2" "revoke through a symlinked bridge directory was not refused"
  assert_present "$victim/peer.json" "revoke deleted a file outside bridge state"
  assert_present "$victim/pairing.json" "revoke deleted a file outside bridge state"
  pass "cleanup refuses a symlinked bridge directory instead of deleting through it"
}

# Only Telegram's own HTTPS endpoint, or an explicit loopback address, may ever
# receive a request carrying the bot token.
test_api_origin_is_restricted_to_telegram_or_loopback() {
  local out
  out=$(FM_HOME="$TMP_ROOT" bash -c '
    . "$1/bin/fm-tg-lib.sh"
    for u in http://attacker.example https://evil.test:8443/x https://api.telegram.org.evil.test \
             http://user@127.0.0.1 http://127.0.0.1:8081 https://api.telegram.org; do
      FM_TELEGRAM_API_URL=$u FM_TELEGRAM_BOT_TOKEN=1234567890:AAHfakefakefakefakefakefake fmtg_load_config
      printf "%s=%s\n" "$u" "$FMTG_API"
    done' _ "$ROOT")
  assert_contains "$out" "http://attacker.example=https://api.telegram.org" \
    "a remote plaintext origin was accepted for token-bearing traffic"
  assert_contains "$out" "https://evil.test:8443/x=https://api.telegram.org" \
    "an arbitrary remote HTTPS origin was accepted"
  assert_contains "$out" "https://api.telegram.org.evil.test=https://api.telegram.org" \
    "a lookalike host was accepted"
  assert_contains "$out" "http://user@127.0.0.1=https://api.telegram.org" \
    "a userinfo-carrying origin was accepted"
  assert_contains "$out" "http://127.0.0.1:8081=http://127.0.0.1:8081" \
    "an explicit loopback local Bot API server was rejected"
  assert_contains "$out" "https://api.telegram.org=https://api.telegram.org" \
    "the real Bot API endpoint was rejected"
  pass "only Telegram's HTTPS endpoint or an explicit loopback origin may carry the bot token"
}

# Replacement is one crash-safe identity transition: the old peer loses
# authority, and the new immutable numeric identity can actually redeem.
test_replace_retires_the_old_peer_and_lets_the_new_one_redeem() {
  local code out
  paired_home replace
  fm_write_meta "$HOME_DIR/state/site.meta" "project=$HOME_DIR/projects/eren-pov-site" "window=t:1"
  tg_queue 2600 "$PEER_ID" "$PEER_ID" "alte anfrage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  assert_present "$HOME_DIR/state/telegram/inbox/tg-2600.json" "the fixture message was not accepted"

  code=$(tg_run "$HOME_DIR" "$FAKEBIN" "$PAIR" begin --label sibling \
    --project eren-pov-site --replace | sed -n 's|^  /start ||p')
  assert_absent "$HOME_DIR/state/telegram/peer.json" \
    "--replace left the old peer pinned and still authorized"
  assert_absent "$HOME_DIR/state/telegram/inbox/tg-2600.json" \
    "--replace kept the retired peer's pending message"
  assert_absent "$HOME_DIR/state/telegram/context/tg-2600.json" \
    "--replace kept the retired peer's reply context"

  # The old peer is no longer heard.
  tg_queue 2601 "$PEER_ID" "$PEER_ID" "noch eine anfrage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  assert_absent "$HOME_DIR/state/telegram/inbox/tg-2601.json" \
    "the retired peer was still able to send work into the bridge"

  # The replacement can actually redeem, which the stranded-offer defect made
  # impossible.
  tg_queue 2602 "$OTHER_ID" "$OTHER_ID" "/start $code"
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$POLL")
  assert_contains "$out" "telegram-paired sibling" "the replacement identity could not redeem its own code"
  [ "$(jq -r '.user_id' "$HOME_DIR/state/telegram/peer.json")" = "$OTHER_ID" ] \
    || fail "the replacement was not pinned to its own numeric identity"
  pass "--replace retires the old peer and its records, and the new numeric identity can redeem"
}

# An armed publish authorization must not survive a re-pairing.
test_replace_clears_armed_publish_authorizations() {
  publish_home replace-publish
  assert_present "$HOME_DIR/state/telegram/publish/site.json" "the fixture did not arm a publish"
  tg_run "$HOME_DIR" "$FAKEBIN" "$PAIR" begin --label sibling \
    --project eren-pov-site --replace >/dev/null
  assert_absent "$HOME_DIR/state/telegram/publish/site.json" \
    "an armed publish authorization survived the re-pairing that retired the person who gave it"
  pass "re-pairing clears publish authorizations the retired person had given"
}

# The per-poll prune is bounded work, so a large retained set cannot outrun the
# check budget and silently kill delivery.
test_prune_is_bounded_and_retires_confirmed_markers() {
  local seen i before after
  paired_home prune-bound
  seen="$HOME_DIR/state/telegram/seen"
  mkdir -p "$seen"
  chmod 700 "$seen"
  i=1
  while [ "$i" -le 400 ]; do
    printf '{"update_id":"%s","seen_at":1}\n' "$i" > "$seen/$i.json"
    chmod 600 "$seen/$i.json"
    i=$(( i + 1 ))
  done
  before=$(count_files "$seen")
  [ "$before" -ge 400 ] || fail "the backlog fixture was not created"

  # A real message still gets through with the backlog present.
  tg_queue 2700 "$PEER_ID" "$PEER_ID" "frage trotz rueckstand"
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$POLL")
  assert_contains "$out" "telegram-message tg-2700" \
    "a large duplicate-suppression backlog stopped the bridge delivering"

  # And the backlog is draining, by name, against the confirmed offset.
  after=$(count_files "$seen")
  [ "$after" -lt "$before" ] || fail "the prune retired nothing (before=$before after=$after)"
  pass "the per-poll prune is bounded and retires markers the confirmed offset already covers"
}

# The other way a prepared change reaches the world is the guarded local merge,
# so it carries the same gate. Without it, a project whose delivery mode is
# local-only would land Telegram-requested work on the person's request alone.
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"

# Build a local-only task whose project has a real default branch and fm/<id>
# branch, plus a paired peer and a publish record in the requested state.
local_merge_case() {  # <name> <record-project> <consumed-at|null> <head-mode>
  local name=$1 record_project=$2 consumed=$3 head_mode=$4 dir proj head
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state/telegram/publish"
  chmod 700 "$dir/state/telegram" "$dir/state/telegram/publish"
  proj="$dir/eren-pov-site"
  mkdir -p "$proj"
  git -C "$proj" init -q -b main
  git -C "$proj" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m base
  git -C "$proj" checkout -q -b fm/site
  git -C "$proj" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m prepared
  head=$(git -C "$proj" rev-parse "refs/heads/fm/site")
  git -C "$proj" checkout -q main
  [ "$head_mode" = moved ] && head=1111111111111111111111111111111111111111
  fm_write_meta "$dir/state/site.meta" "project=$proj" "mode=local-only" \
    "window=t:1" "worktree=$proj" "tg_request=tg-42" "tg_chat=$PEER_ID" "tg_request_ts=1"
  printf '%s\n' '{"label":"eren","project":"eren-pov-site","user_id":555001,"chat_id":555001,"paired_at":1}' \
    > "$dir/state/telegram/peer.json"
  chmod 600 "$dir/state/telegram/peer.json"
  if [ "$record_project" != none ]; then
    printf '{"task_id":"site","project":"%s","head":"%s","salt":"s","code_sha256":"h","peer_user":%s,"peer_chat":%s,"armed_at":1,"expires_at":9999999999,"consumed_at":%s,"attempts":0}\n' \
      "$record_project" "$head" "$PEER_ID" "$PEER_ID" "$consumed" \
      > "$dir/state/telegram/publish/site.json"
    chmod 600 "$dir/state/telegram/publish/site.json"
  fi
  printf '%s\n' "$dir"
}

run_local_merge() {  # <case-dir>
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$1/state" \
    "$MERGE_LOCAL" site 2>&1
}

test_local_merge_refuses_a_telegram_task_without_confirmation() {
  local dir out
  dir=$(local_merge_case local-absent none null exact)
  out=$(run_local_merge "$dir" || printf 'rc=%s' "$?")
  assert_contains "$out" "no publish confirmation was ever armed" \
    "the local merge landed a Telegram-linked task with no confirmation"
  git -C "$dir/eren-pov-site" merge-base --is-ancestor "refs/heads/fm/site" main 2>/dev/null \
    && fail "the refused local merge still fast-forwarded the default branch"
  pass "the local merge refuses a Telegram-linked task with no publish confirmation"
}

test_local_merge_refuses_an_unconsumed_or_moved_confirmation() {
  local dir out
  dir=$(local_merge_case local-unconsumed eren-pov-site null exact)
  out=$(run_local_merge "$dir" || printf 'rc=%s' "$?")
  assert_contains "$out" "has not confirmed publishing" \
    "the local merge landed on an armed but unconfirmed record"
  git -C "$dir/eren-pov-site" merge-base --is-ancestor "refs/heads/fm/site" main 2>/dev/null \
    && fail "the refused local merge still fast-forwarded the default branch"

  dir=$(local_merge_case local-moved eren-pov-site 100 moved)
  out=$(run_local_merge "$dir" || printf 'rc=%s' "$?")
  assert_contains "$out" "moved since the paired person approved it" \
    "the local merge landed a revision the person never approved"
  pass "the local merge refuses unconfirmed and moved-revision publish authorizations"
}

test_local_merge_lands_once_on_a_matching_confirmation() {
  local dir out
  dir=$(local_merge_case local-ok eren-pov-site 100 exact)
  out=$(run_local_merge "$dir") || fail "a correctly confirmed local merge was refused: $out"
  git -C "$dir/eren-pov-site" merge-base --is-ancestor "refs/heads/fm/site" main \
    || fail "the confirmed local merge did not fast-forward the default branch"
  assert_grep '"landed_at"' "$dir/state/telegram/publish/site.json" \
    "the local landing did not consume the authorization"

  # The same authorization cannot land again.
  git -C "$dir/eren-pov-site" checkout -q fm/site
  git -C "$dir/eren-pov-site" -c user.email=t@example.invalid -c user.name=t \
    commit -q --allow-empty -m more
  git -C "$dir/eren-pov-site" checkout -q main
  out=$(run_local_merge "$dir" || printf 'rc=%s' "$?")
  assert_contains "$out" "already used to land" "one local confirmation landed twice"
  pass "the local merge lands exactly one confirmed change and refuses the replay"
}

test_local_merge_is_unaffected_without_a_telegram_link() {
  local dir out
  dir=$(local_merge_case local-unlinked none null exact)
  fm_write_meta "$dir/state/site.meta" "project=$dir/eren-pov-site" "mode=local-only" "window=t:1"
  out=$(run_local_merge "$dir") || fail "an unlinked local-only task was blocked by the bridge gate: $out"
  git -C "$dir/eren-pov-site" merge-base --is-ancestor "refs/heads/fm/site" main \
    || fail "the unlinked local merge did not fast-forward"
  pass "a local-only task with no Telegram link merges exactly as it did before the bridge existed"
}

# The landing gate used to read the OPEN exchange - tg_request/tg_chat - and
# both `--final` and `unlink` clear exactly those keys with no authorization
# check. A terminal reply sent before the merge therefore switched the whole
# publish gate off for a task the paired person had already been shown.
test_ending_the_conversation_does_not_disarm_the_landing_gate() {
  local dir out
  paired_home gate-origin
  tg_queue 2900 "$PEER_ID" "$PEER_ID" "mach das bitte"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  fm_write_meta "$HOME_DIR/state/site.meta" "project=$HOME_DIR/projects/eren-pov-site" "window=t:1"
  tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" link site tg-2900 >/dev/null

  printf 'fertig\n' | tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" --task site --final >/dev/null
  assert_no_grep 'tg_request=' "$HOME_DIR/state/site.meta" "the final reply left the exchange open"
  assert_grep 'tg_origin=tg-2900' "$HOME_DIR/state/site.meta" \
    "the final reply erased the task's Telegram origin, which is the landing gate's own evidence"
  tg_run "$HOME_DIR" "$FAKEBIN" "$TGTASK" unlink site >/dev/null
  assert_grep 'tg_origin=tg-2900' "$HOME_DIR/state/site.meta" \
    "unlink erased the task's Telegram origin"

  # And a task carrying only that origin really is still gated.
  dir=$(local_merge_case gate-origin-merge none null exact)
  fm_write_meta "$dir/state/site.meta" "project=$dir/eren-pov-site" "mode=local-only" \
    "window=t:1" "worktree=$dir/eren-pov-site" "tg_origin=tg-42"
  out=$(run_local_merge "$dir" || printf 'rc=%s' "$?")
  assert_contains "$out" "no publish confirmation was ever armed" \
    "a task whose Telegram exchange was closed landed with no publish gate at all"
  git -C "$dir/eren-pov-site" merge-base --is-ancestor "refs/heads/fm/site" main 2>/dev/null \
    && fail "the refused local merge still fast-forwarded the default branch"
  pass "ending the Telegram conversation cannot turn the landing gate off"
}

# The other half of the same hole: a task whose record carries no Telegram keys
# at all, but for which a preview was armed under this task id.
test_an_armed_publish_record_alone_gates_the_landing() {
  local dir out
  dir=$(local_merge_case gate-armed-only eren-pov-site null exact)
  fm_write_meta "$dir/state/site.meta" "project=$dir/eren-pov-site" "mode=local-only" \
    "window=t:1" "worktree=$dir/eren-pov-site"
  out=$(run_local_merge "$dir" || printf 'rc=%s' "$?")
  assert_contains "$out" "has not confirmed publishing" \
    "a task with an armed publish record landed as if it had never been previewed"
  git -C "$dir/eren-pov-site" merge-base --is-ancestor "refs/heads/fm/site" main 2>/dev/null \
    && fail "the refused local merge still fast-forwarded the default branch"
  pass "an armed publish record gates the landing even with no link left in the task record"
}

# An approval binds to the landing it was first spent on, so it cannot be moved
# from a pull request to a local merge. Reporting that as a plain replay hid
# which of the two landings actually ran.
test_a_confirmation_bound_to_another_landing_is_refused() {
  local dir out
  dir=$(local_merge_case local-target eren-pov-site 100 exact)
  jq -c '.landing_target = "https://github.com/example/repo/pull/9"' \
    "$dir/state/telegram/publish/site.json" > "$dir/rec.tmp" \
    && mv -f "$dir/rec.tmp" "$dir/state/telegram/publish/site.json"
  chmod 600 "$dir/state/telegram/publish/site.json"
  out=$(run_local_merge "$dir" || printf 'rc=%s' "$?")
  assert_contains "$out" "approved for a different landing target" \
    "an approval already spent on a pull request was spent again on a local merge"
  git -C "$dir/eren-pov-site" merge-base --is-ancestor "refs/heads/fm/site" main 2>/dev/null \
    && fail "the refused local merge still fast-forwarded the default branch"
  pass "a publish confirmation bound to one landing target cannot be spent on another"
}

# Every send needs an authenticated, still-open request. --retry checked only
# the target chat, so it was the one send that could finish an abandoned reply
# into an exchange that is no longer this home's to answer.
test_retry_needs_the_request_to_still_be_open() {
  local out before ctx
  paired_home retry-authentic
  tg_queue 3100 "$PEER_ID" "$PEER_ID" "frage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  printf 'Erster Absatz mit genug Text fuer eine eigene Nachricht.\n\nZweiter Absatz mit genug Text fuer eine eigene Nachricht.\n\nDritter Absatz mit genug Text fuer eine eigene Nachricht.\n' \
    > "$HOME_DIR/reply.txt"

  # A real mid-send failure, so the preserved record is the genuine article.
  FAKE_TG_SEND_FAIL_FROM=3 FM_TELEGRAM_MAX_CHARS=100 \
    tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" tg-3100 >/dev/null 2>&1 < "$HOME_DIR/reply.txt" || true
  assert_present "$HOME_DIR/state/telegram/outbox/tg-3100.json" \
    "the failed send preserved nothing to retry"

  # The exchange is then closed exactly as a --final reply closes it.
  ctx="$HOME_DIR/state/telegram/context/tg-3100.json"
  jq -c '.closed_at = 1750000000' "$ctx" > "$HOME_DIR/ctx.tmp" && mv -f "$HOME_DIR/ctx.tmp" "$ctx"
  chmod 600 "$ctx"

  before=$(tg_sent_count)
  out=$(tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" --retry tg-3100 2>&1 || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=7" "a retry delivered into an exchange a final reply had already closed"
  [ "$(tg_sent_count)" = "$before" ] || fail "the refused retry still delivered a message"
  pass "a retry needs the same authenticated, still-open request every other send needs"
}

# FM_TELEGRAM_PAIR_SENDERS is documented as an operator knob, so setting it has
# to change behavior rather than leave an internal default in charge.
test_the_documented_sender_cap_is_honored() {
  local dir home fakebin code
  dir="$TMP_ROOT/pair-senders"
  mkdir -p "$dir"
  tg_fake_api "$dir"
  fakebin=$TG_FAKEBIN
  home=$(tg_home "$dir" home "$TEST_TOKEN")
  code=$(tg_run "$home" "$fakebin" "$PAIR" begin --label eren --project eren-pov-site \
    | sed -n 's|^  /start ||p')

  # One sender fills the whole map, so the next distinct sender is refused
  # before it can consume anybody's attempts.
  tg_queue 400 "$OTHER_ID" "$OTHER_ID" "/start WRONGCDE"
  FM_TELEGRAM_PAIR_SENDERS=1 tg_run "$home" "$fakebin" "$POLL" >/dev/null
  tg_queue 401 "$PEER_ID" "$PEER_ID" "/start $code"
  FM_TELEGRAM_PAIR_SENDERS=1 tg_run "$home" "$fakebin" "$POLL" >/dev/null
  assert_absent "$home/state/telegram/peer.json" \
    "the documented sender cap did nothing: a sender past the cap still redeemed"
  [ "$(jq -r '(.attempts_by | length)' "$home/state/telegram/pairing.json")" = 1 ] \
    || fail "a sender past the cap was still tracked"

  # At the default the same offer admits that sender and pairs.
  tg_queue 402 "$PEER_ID" "$PEER_ID" "/start $code"
  tg_run "$home" "$fakebin" "$POLL" >/dev/null
  assert_present "$home/state/telegram/peer.json" \
    "the cap was not the reason the earlier redemption was refused"
  pass "FM_TELEGRAM_PAIR_SENDERS really caps how many senders one offer tracks"
}

# An abandoned attempt must not leave message content sitting in bridge state,
# and "nothing to send" must be distinguishable from "that request was never
# accepted here" - both used to exit 4.
test_empty_reply_is_its_own_outcome_and_leaves_nothing_staged() {
  local out
  paired_home reply-empty
  tg_queue 2800 "$PEER_ID" "$PEER_ID" "frage"
  tg_run "$HOME_DIR" "$FAKEBIN" "$POLL" >/dev/null
  out=$(printf '' | tg_run "$HOME_DIR" "$FAKEBIN" "$REPLY" tg-2800 2>&1 || printf 'rc=%s' "$?")
  assert_contains "$out" "rc=10" "an empty reply did not report its own outcome"
  assert_absent "$HOME_DIR/state/telegram/reply/tg-2800.txt" \
    "an abandoned reply left its staged body in bridge state"
  [ "$(tg_sent_count)" = 1 ] || fail "an empty reply still delivered a message"
  pass "an empty reply is its own outcome and leaves no staged body behind"
}

test_absent_config_is_a_complete_no_op
test_malformed_token_is_refused_without_echoing_it
test_token_never_reaches_argv_or_state
test_private_files_are_owner_only
test_pairing_success_pins_numeric_identity
test_pairing_stores_no_recoverable_code
test_wrong_code_is_silent_and_bounded
test_pairing_attempt_budget_is_per_sender
test_pairing_attempt_budget_locks_out_the_guesser
test_pairing_can_be_bound_to_one_numeric_account
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
test_re_announcement_budget_retires_a_stuck_entry
test_long_poll_stays_inside_the_watcher_kill_budget
test_one_check_spends_one_budget_across_its_calls
test_orphaned_publication_temps_are_swept
test_non_private_and_bot_senders_get_no_access
test_unsupported_media_and_oversized_text_are_bounded
test_message_content_stays_inert_data
test_rate_limit_bounds_a_flood
test_a_killed_poll_leaves_no_token_on_disk
test_conflicting_poller_is_reported
test_routing_is_pinned_to_the_paired_project
test_show_names_an_absent_link_rather_than_printing_a_blank
test_publish_needs_a_matching_confirmation
test_bare_agreement_is_not_a_confirmation
test_stale_confirmation_is_refused
test_expired_and_over_budget_confirmations_are_refused
test_a_confirmation_must_be_carried_by_a_fresh_message_from_that_person
test_a_closed_exchange_cannot_confirm_a_publish
test_a_textless_message_cannot_confirm_a_publish
test_an_unresolvable_prepared_revision_refuses_instead_of_arming
test_reply_is_literal_and_single_target
test_reply_refuses_when_the_target_no_longer_matches
test_reply_without_a_peer_sends_nothing
test_long_reply_splits_deterministically
test_failed_send_is_preserved_and_resumes
test_final_reply_clears_the_link_but_keeps_evidence
test_dry_run_records_without_sending
test_bootstrap_arms_and_disarms_the_bridge
test_supervision_is_required_for_a_bridged_home
test_no_harness_protocol_sources_a_cadence_file
test_watcher_derives_its_cadence_from_the_authenticated_shim
test_arm_seatbelt_blesses_no_source_node
test_both_channels_coexist_in_one_home
test_watcher_rotates_between_always_on_channels
test_migration_does_not_quarantine_the_bridge_shim
test_arm_seatbelt_allows_the_rendered_bridge_arm
test_stop_autoarm_reaches_the_bridge_cadence_without_sourcing
test_gate_agent_cannot_reach_the_channel
test_homes_cannot_read_each_other
test_reply_needs_a_real_request_and_takes_no_path
test_reply_body_is_staged_and_the_request_closes
test_reply_refuses_a_task_outside_the_paired_project
test_undurable_progress_is_reported_as_ambiguous_delivery
test_cleanup_refuses_a_symlinked_bridge_directory
test_api_origin_is_restricted_to_telegram_or_loopback
test_replace_retires_the_old_peer_and_lets_the_new_one_redeem
test_replace_clears_armed_publish_authorizations
test_prune_is_bounded_and_retires_confirmed_markers
test_local_merge_refuses_a_telegram_task_without_confirmation
test_local_merge_refuses_an_unconsumed_or_moved_confirmation
test_local_merge_lands_once_on_a_matching_confirmation
test_local_merge_is_unaffected_without_a_telegram_link
test_ending_the_conversation_does_not_disarm_the_landing_gate
test_an_armed_publish_record_alone_gates_the_landing
test_a_confirmation_bound_to_another_landing_is_refused
test_retry_needs_the_request_to_still_be_open
test_the_documented_sender_cap_is_honored
test_empty_reply_is_its_own_outcome_and_leaves_nothing_staged
