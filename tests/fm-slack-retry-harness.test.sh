#!/usr/bin/env bash
# Behavioral transport and public Slack-posting tests.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-slack-retry.XXXXXX") || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

make_fake_curl() {
  cat > "$TMP_ROOT/curl" <<'SH'
#!/usr/bin/env bash
set -u
ofile= method= data=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -m) printf '%s\n' "$2" >> "${FM_SLACK_TIMEOUT_LOG:?}"; shift 2 ;;
    -H|-w) shift 2 ;;
    -s*) shift ;;
    --data) data=$2; shift 2 ;;
    http://*|https://*) method=${1##*/}; shift ;;
    *) shift ;;
  esac
done
attempt_file="${FM_SLACK_ATTEMPT_FILE:?}"
attempt=$(cat "$attempt_file" 2>/dev/null || printf '0')
attempt=$((attempt + 1))
printf '%s\n' "$attempt" > "$attempt_file"
printf '%s %s\n' "$method" "$attempt" >> "${FM_SLACK_CALL_LOG:?}"
if [ "$method" = chat.postMessage ]; then
  printf '%s\n' "$data" >> "${FM_SLACK_REMOTE_MUTATIONS:?}"
  exit 7
fi
profile=${FM_SLACK_PROFILE:-S}
case "$profile" in
  F) [ "$attempt" -eq 1 ] && exit 7 ;;
  B) [ "$attempt" -lt 3 ] && exit 7 ;;
  Q) [ "$attempt" -lt 3 ] && exit 7 ;;
  V) body='{"ok":false,"error":"channel_not_found"}' ;;
  S) body='{"ok":true,"channel":"C0123456789","ts":"123.456"}' ;;
  *) exit 97 ;;
esac
if [ -n "$ofile" ]; then printf '%s' "${body:-{\"ok\":true}}" > "$ofile"; fi
exit 0
SH
  chmod +x "$TMP_ROOT/curl"
}

setup_env() {
  : > "$TMP_ROOT/attempt"
  : > "$TMP_ROOT/calls"
  : > "$TMP_ROOT/mutations"
  : > "$TMP_ROOT/timeouts"
  export FM_SLACK_CURL_BIN="$TMP_ROOT/curl"
  export FM_SLACK_ATTEMPT_FILE="$TMP_ROOT/attempt"
  export FM_SLACK_CALL_LOG="$TMP_ROOT/calls"
  export FM_SLACK_REMOTE_MUTATIONS="$TMP_ROOT/mutations"
  export FM_SLACK_TIMEOUT_LOG="$TMP_ROOT/timeouts"
  export FMS_TOKEN=xoxb-test-token FMS_API=https://slack.test/api
  export FMS_CHANNEL_ID=C0123456789
}

run_api() {
  local method=$1 profile=$2 body=$3
  : > "$FM_SLACK_ATTEMPT_FILE"
  FM_SLACK_PROFILE=$profile bash -c '. "$1"; fms_api_post "$2" "text=test" "$3"' \
    _ "$ROOT/bin/fm-slack-lib.sh" "$method" "$body"
}

test_ambiguous_post_is_not_repeated() {
  setup_env
  local body="$TMP_ROOT/post.body"
  if run_api chat.postMessage S "$body" >/dev/null 2>&1; then
    fail 'ambiguous chat.postMessage should remain unsuccessful'
  fi
  [ "$(cat "$FM_SLACK_ATTEMPT_FILE")" -eq 1 ] || fail 'ambiguous post was retried'
  [ "$(wc -l < "$FM_SLACK_REMOTE_MUTATIONS" | tr -d ' ')" -eq 1 ] || fail 'remote mutation was not recorded once'
  pass 'chat.postMessage transport ambiguity never repeats the mutation'
}

test_public_board_does_not_orphan_state() {
  setup_env
  local home="$TMP_ROOT/home"
  mkdir -p "$home/config" "$home/state"
  export FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state"
  printf '%s\n' C0123456789 > "$home/config/slack-captain-channel"
  export FM_SLACK_BOT_TOKEN=xoxb-test-token
  if "$ROOT/bin/fm-slack-post.sh" board 'board text' >/dev/null 2>&1; then
    fail 'public board post should report the lost response'
  fi
  [ "$(wc -l < "$FM_SLACK_REMOTE_MUTATIONS" | tr -d ' ')" -eq 1 ] || fail 'public board path duplicated the post'
  [ ! -e "$home/state/slack-board.meta/slack-board.meta" ] || fail 'board state was orphaned after ambiguous post'
  pass 'public board posting records no orphan after ambiguous success'
}

test_board_rollover_snapshot_does_not_orphan_state() {
  setup_env
  local home="$TMP_ROOT/rollover-home" meta_before state_before
  mkdir -p "$home/config" "$home/state/slack-board.meta"
  chmod 700 "$home/state" "$home/state/slack-board.meta"
  export FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state"
  printf '%s\n' C0123456789 > "$home/config/slack-captain-channel"
  export FM_SLACK_BOT_TOKEN=xoxb-test-token
  printf 'channel=C0123456789\nts=999.111\n' > "$home/state/slack-board.meta/slack-board.meta"
  chmod 600 "$home/state/slack-board.meta/slack-board.meta"
  printf '{"date":"2026-08-01","body":"prior body"}' > "$home/state/slack-board.meta/slack-board.state"
  chmod 600 "$home/state/slack-board.meta/slack-board.state"
  meta_before=$(cat "$home/state/slack-board.meta/slack-board.meta")
  state_before=$(cat "$home/state/slack-board.meta/slack-board.state")
  export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-02
  if "$ROOT/bin/fm-slack-post.sh" board 'today text' >/dev/null 2>&1; then
    unset FM_SLACK_BOARD_TODAY_OVERRIDE
    fail 'ambiguous rollover snapshot post should report the lost response'
  fi
  unset FM_SLACK_BOARD_TODAY_OVERRIDE
  [ "$(wc -l < "$FM_SLACK_REMOTE_MUTATIONS" | tr -d ' ')" -eq 1 ] || fail 'rollover snapshot path duplicated the post'
  [ ! -e "$home/state/slack-board-snapshots/2026-08-01" ] || fail 'snapshot once-file was recorded despite an ambiguous post'
  [ "$(cat "$home/state/slack-board.meta/slack-board.meta")" = "$meta_before" ] \
    || fail 'live board meta was mutated by an ambiguous snapshot'
  [ "$(cat "$home/state/slack-board.meta/slack-board.state")" = "$state_before" ] \
    || fail 'board state advanced despite an ambiguous snapshot'
  pass 'rollover snapshot posting records no orphan after ambiguous success'
}

test_safe_mutation_retries() {
  setup_env
  local body="$TMP_ROOT/update.body"
  run_api chat.update F "$body" >/dev/null 2>&1 || fail 'safe chat.update did not retry'
  [ "$(cat "$FM_SLACK_ATTEMPT_FILE")" -eq 2 ] || fail 'safe mutation retry count changed'
  pass 'safe mutation retains bounded retry behavior'
}

test_retry_bound_and_timeout_are_behavioral() {
  setup_env
  local body="$TMP_ROOT/bound.body"
  run_api conversations.history Q "$body" >/dev/null 2>&1 || fail 'bounded retry should eventually succeed'
  [ "$(cat "$FM_SLACK_ATTEMPT_FILE")" -eq 3 ] || fail 'retry bound changed'
  grep -Fx '7' "$FM_SLACK_TIMEOUT_LOG" >/dev/null || fail 'curl timeout bound changed'
  ! grep -v '^7$' "$FM_SLACK_TIMEOUT_LOG" >/dev/null || fail 'unexpected curl timeout value'
  pass 'safe retry bound and curl timeout remain bounded'
}

test_locale_and_control_behavior() {
  setup_env
  cat > "$TMP_ROOT/awk" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${LC_ALL:-}" >> "${FM_SLACK_LOCALE_LOG:?}"
exec /usr/bin/awk "$@"
SH
  chmod +x "$TMP_ROOT/awk"
  : > "$TMP_ROOT/locale"
  export FM_SLACK_LOCALE_LOG="$TMP_ROOT/locale"
  PATH="$TMP_ROOT:$PATH" LC_ALL=C.UTF-8 run_api chat.update F "$TMP_ROOT/locale.body" >/dev/null 2>&1 \
    || fail 'locale-safe retry did not succeed'
  grep -Fx C "$TMP_ROOT/locale" >/dev/null || fail 'retry delay was locale-sensitive'
  setup_env
  : > "$FM_SLACK_CALL_LOG"
  if run_api unsupported S "$TMP_ROOT/control.body" >/dev/null 2>&1; then
    fail 'unsupported Slack method was accepted'
  fi
  [ ! -s "$FM_SLACK_CALL_LOG" ] || fail 'unsupported method reached transport'
  pass 'retry delay locale and method-control behavior stay safe'
}

make_fake_curl
test_ambiguous_post_is_not_repeated
test_public_board_does_not_orphan_state
test_board_rollover_snapshot_does_not_orphan_state
test_safe_mutation_retries
test_retry_bound_and_timeout_are_behavioral
test_locale_and_control_behavior
