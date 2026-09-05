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
export LC_ALL=C LANG=C
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
# FAKE_SLACK_REACTION_FAIL, FAKE_SLACK_REACTION_FAIL_ONCE,
# FAKE_SLACK_ALREADY_REACTED. Echoes the fakebin dir.
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
    if [ -n "${FAKE_SLACK_POST_DELAY:-}" ]; then
      sleep "$FAKE_SLACK_POST_DELAY"
    fi
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
    if [ -n "${FAKE_SLACK_ALREADY_REACTED:-}" ]; then
      body='{"ok":false,"error":"already_reacted"}'
    elif [ -n "${FAKE_SLACK_REACTION_FAIL:-}" ]; then
      body='{"ok":false,"error":"reaction_failed"}'
    elif [ -n "${FAKE_SLACK_REACTION_FAIL_ONCE:-}" ] \
      && [ "$(cat "$FAKE_SLACK_REACTION_FAIL_ONCE" 2>/dev/null || printf 0)" -gt 0 ]; then
      printf '0\n' > "$FAKE_SLACK_REACTION_FAIL_ONCE"
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

# --- binary-safe assertions -------------------------------------------------
# Command substitution strips trailing newlines, so byte equality for artifacts
# whose trailing bytes carry meaning (the snapshot once-file, the identity record)
# must use cmp, never [ "$(cat a)" = "$(cat b)" ]. assert_bytes_eq proves two
# files hold identical bytes; the expected file is produced independently (a
# printf into a file outside the fixture tree, or a byte literal), never by
# reading the artifact under test.
assert_bytes_eq() {
  cmp -s "$1" "$2" || fail "bytes differ: $1 != $2"
}

# _fstat_mode <path> prints the numeric mode (e.g. 700) portably.
_fstat_mode() {
  local p=$1
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$p" 2>/dev/null
  else
    stat -c %a "$p" 2>/dev/null
  fi
}

# _fstat_type <path> prints a single token: link, dir, file, or other.
_fstat_type() {
  local p=$1
  [ -L "$p" ] && { printf 'link\n'; return; }
  [ -d "$p" ] && { printf 'dir\n'; return; }
  [ -f "$p" ] && { printf 'file\n'; return; }
  printf 'other\n'
}

# _fstat_nlink <path> prints the link count portably.
_fstat_nlink() {
  local p=$1
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$p" 2>/dev/null
  else
    stat -c %h "$p" 2>/dev/null
  fi
}

# manifest <dir> <out> records a complete, byte-stable inventory of a directory:
# relative path, type, mode, size, link count, and a content digest (no
# symlink following). find -mindepth 1 -maxdepth 1 sees dotfiles and dangling
# symlinks and has no early-termination sentinel, so a pre/post manifest
# comparison proves a refusal left every byte, type, mode, and link count
# unchanged. Two manifests compared with assert_bytes_eq prove invariance.
manifest() {
  local dir=$1 out=$2 p rel mode type size nlink digest
  {
    find "$dir" -mindepth 1 -maxdepth 1 -print0 | sort -z \
    | while IFS= read -r -d '' p; do
        rel=${p#"$dir"/}
        type=$(_fstat_type "$p")
        mode=$(_fstat_mode "$p")
        if [ "$(uname)" = Darwin ]; then
          size=$(stat -f %z "$p" 2>/dev/null)
        else
          size=$(stat -c %s "$p" 2>/dev/null)
        fi
        nlink=$(_fstat_nlink "$p")
        if [ "$type" = file ] && [ -L "$p" ]; then
          digest='link'
        elif [ "$type" = file ]; then
          digest=$(shasum -a 256 "$p" 2>/dev/null | awk '{print $1}')
        else
          digest=$type
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$type" "$mode" "$size" "$nlink" "$digest"
      done
  } > "$out"
}
