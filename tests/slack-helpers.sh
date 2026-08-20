#!/usr/bin/env bash
# tests/slack-helpers.sh - shared fixtures for the Slack captain-channel suites
# (fm-slack-captain-channel and fm-slack-captain-comms-guard).
#
# These fixtures encode the Slack Web API surface the poll and post clients
# drive - a fake curl that answers auth.test/conversations.*/chat.*/reactions.*
# from FAKE_SLACK_* overrides, a configured captain home, and the PATH shape
# those clients need - so they live here rather than in the generic tests/lib.sh.
# Owning the channel id, token, and response shapes in one place keeps the two
# suites from drifting apart. Generic reporters and primitives come from lib.sh,
# which this file pulls in.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Real jq stays on PATH; everything else is the fixed system set so a developer's
# shell cannot leak tools into a hermetic run.
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"

# The configured captain channel and the identities the poll pins against.
# Consumed by the sourcing suites, not by this file, so they read as "unused" here.
CHANNEL_ID=C0BQ9K1TJKG
# shellcheck disable=SC2034
BOT_USER=U_BOT12345
# shellcheck disable=SC2034
CAPTAIN_USER=U_CAPTAIN1

# A fake curl answering every Slack method the clients call. Per-case overrides:
# FAKE_SLACK_BOT_USER, FAKE_SLACK_CHANNEL, FAKE_SLACK_HISTORY,
# FAKE_SLACK_REPLIES, FAKE_SLACK_POST, FAKE_SLACK_UPDATE, FAKE_SLACK_JOIN_TS,
# FAKE_SLACK_REACTION_FAIL. Echoes the fakebin dir.
make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" url="" data="" thread_ts=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -m|-w) shift 2 ;;
    -s*) shift ;;
    -H) shift 2 ;;
    --data) data=$2; shift 2 ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
case "$data" in
  *thread_ts=*) thread_ts=${data##*thread_ts=} ;;
esac
if [ -n "${FM_SLACK_CURL_LOG:-}" ]; then
  printf 'url=%s\ndata=%s\n' "$url" "$data" >> "$FM_SLACK_CURL_LOG"
fi
case "$url" in
  */auth.test)
    body=$(printf '{"ok":true,"user_id":"%s"}' "${FAKE_SLACK_BOT_USER:-U_BOT}")
    ;;
  */conversations.history)
    body="${FAKE_SLACK_HISTORY:-{\"ok\":true,\"messages\":[]}}"
    ;;
  */conversations.replies)
    body="${FAKE_SLACK_REPLIES:-{\"ok\":true,\"messages\":[]}}"
    ;;
  */chat.postMessage)
    if [ -n "${FAKE_SLACK_JOIN_TS:-}" ] && [ "$thread_ts" = "$FAKE_SLACK_JOIN_TS" ]; then
      body='{"ok":false,"error":"cannot_reply_to_message"}'
    elif [ -n "${FAKE_SLACK_POST:-}" ]; then
      body=$FAKE_SLACK_POST
    else
      body=$(printf '{"ok":true,"ts":"1786735224.690829","channel":"%s"}' "${FAKE_SLACK_CHANNEL:-C0BQ9K1TJKG}")
    fi
    ;;
  */chat.update)
    if [ -n "${FAKE_SLACK_UPDATE:-}" ]; then
      body=$FAKE_SLACK_UPDATE
    else
      body=$(printf '{"ok":true,"ts":"1786735224.690829","channel":"%s"}' "${FAKE_SLACK_CHANNEL:-C0BQ9K1TJKG}")
    fi
    ;;
  */reactions.add)
    if [ -n "${FAKE_SLACK_REACTION_FAIL:-}" ]; then
      body='{"ok":false,"error":"reaction_failed"}'
    else
      body='{"ok":true}'
    fi
    ;;
  */reactions.remove)
    body='{"ok":true}'
    ;;
  *)
    body='{"ok":false,"error":"unknown_method"}'
    ;;
esac
if [ -n "$ofile" ]; then
  printf '%s' "$body" > "$ofile"
else
  printf '%s' "$body"
fi
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# A home with the private state/config layout the clients require, a synthetic
# bot token, and the configured captain channel id.
make_home() {
  local dir=$1
  mkdir -p "$dir/config" "$dir/state"
  chmod 700 "$dir/config" "$dir/state"
  printf 'FM_SLACK_BOT_TOKEN=xoxb-synthetic-test-token\n' > "$dir/.env"
  chmod 600 "$dir/.env"
  printf '%s\n' "$CHANNEL_ID" > "$dir/config/slack-captain-channel"
  chmod 600 "$dir/config/slack-captain-channel"
}

run_poll() {
  local home=$1 fakebin=$2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SLACK_API_URL=https://slack.test/api FM_SLACK_CURL_BIN="$fakebin/curl" \
    PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-slack-poll.sh"
}

run_post() {
  local home=$1 fakebin=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SLACK_API_URL=https://slack.test/api FM_SLACK_CURL_BIN="$fakebin/curl" \
    PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-slack-post.sh" "$@"
}
