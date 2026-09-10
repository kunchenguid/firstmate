#!/usr/bin/env bash
# fm-notify.sh - best-effort review-ready notification for a task PR.
#
# Usage: fm-notify.sh task-ready <task-id> <pr-url>
#
# Post one short message to the captain's Discord webhook when a task's pull
# request becomes ready for review, so the outcome reaches them without anyone
# remembering to send it. The webhook is read fresh from the home-local,
# gitignored config/discord-webhook on every call; a missing, empty, or
# unreadable file is a silent no-op that exits 0.
#
# The notification is best-effort by design and runs after the PR is recorded:
# any networking, HTTP, or parsing failure logs one warning to stderr and still
# exits 0, so it can never fail or delay the calling supervisor step. The
# message names the task, gives a one-line summary of what was implemented, and
# carries the full PR URL, bounded to Discord's 2000-character limit.
#
# The webhook URL never leaves its config file: it is streamed into curl as a
# private config document on stdin rather than an argument, and curl's own
# diagnostic output is discarded so an error can never echo it. A private
# per-task marker records the exact notified PR identity (format owned by
# bin/fm-pr-lib.sh) so a re-run for the same PR never double-notifies.
#
# Callers must invoke this only after the PR record is written, and guard the
# call so a notification failure cannot change their own exit status.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
WEBHOOK_FILE="$CONFIG/discord-webhook"
NOTIFY_TIMEOUT="${FM_NOTIFY_TIMEOUT:-10}"
DISCORD_MAX_CHARS=2000

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

fm_notify_warn() {  # <task-id> <message>
  printf 'fm-notify: %s: %s\n' "$1" "$2" >&2
}

# Print one curl config document for a JSON POST to the webhook. The URL is
# read from <webhook-file> through sed/tr so the secret never enters a command
# argument list; <payload-file> holds the JSON body, referenced by path.
fm_notify_curl_config() {  # <webhook-file> <payload-file>
  printf 'header = "Content-Type: application/json"\n'
  printf 'data-binary = "@%s"\n' "$2"
  printf 'url = "'
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" \
    | tr -d '\n\r'
  printf '"\n'
}

# Print the Discord JSON payload for the message. The summary is truncated by
# whole characters so the content stays within Discord's limit while the URL
# stays whole. json_pp owns all escaping, including invalid-UTF-8 replacement.
fm_notify_payload() {  # <task-id> <summary> <pr-url>
  NOTIFY_TASK_ID="$1" NOTIFY_SUMMARY="$2" NOTIFY_PR_URL="$3" NOTIFY_MAX="$DISCORD_MAX_CHARS" \
    perl -MJSON::PP -MEncode -e '
      my $dec = sub { Encode::decode("UTF-8", $_[0], Encode::FB_DEFAULT()) };
      my $id = $dec->($ENV{NOTIFY_TASK_ID});
      my $summary = $dec->($ENV{NOTIFY_SUMMARY});
      my $url = $dec->($ENV{NOTIFY_PR_URL});
      my $max = 0 + $ENV{NOTIFY_MAX};
      my $header = "PR ready for review: $id";
      my $message = "$header\n$summary\n$url";
      if (length($message) > $max) {
        my $fixed = length($header) + 2 + length($url) + 3;
        my $avail = $max - $fixed;
        $avail = 0 if $avail < 0;
        $summary = substr($summary, 0, $avail);
        $message = "$header\n$summary...\n$url";
      }
      print JSON::PP->new->utf8->encode({ content => $message });
    ' 2>/dev/null
}

# Best-effort fetch of the PR title through the same forge CLIs the merge poll
# uses. Any failure (missing CLI, non-zero exit, empty title) yields no output.
fm_notify_pr_title() {  # <provider> <url> <number> <host> <path>
  local provider=$1 url=$2 number=$3 host=$4 path=$5 raw title
  case "$provider" in
    github)
      command -v gh >/dev/null 2>&1 || return 1
      title=$(fm_run_timed "$NOTIFY_TIMEOUT" gh pr view "$url" --json title -q .title 2>/dev/null) || return 1
      ;;
    gitlab)
      command -v glab >/dev/null 2>&1 || return 1
      raw=$(fm_run_timed "$NOTIFY_TIMEOUT" glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || return 1
      title=$(printf '%s\n' "$raw" | sed -n 's/^title:[[:space:]]*//p' | head -1)
      ;;
    *) return 1 ;;
  esac
  [ -n "$title" ] || return 1
  printf '%s' "$title"
}

# Decode a tasks-axi show title field, which is JSON-quoted when present.
fm_notify_decode_title() {  # <shown-value>
  local value=$1
  case "$value" in
    \"*\")
      printf '%s' "$value" | perl -MJSON::PP -e '
        local $/;
        my $value = decode_json(<STDIN>);
        binmode STDOUT, ":raw";
        utf8::encode($value) if utf8::is_utf8($value);
        print $value;
      ' 2>/dev/null
      ;;
    *) printf '%s' "$value" ;;
  esac
}

# Best-effort fallback to the task's backlog title through tasks-axi, run from
# the home root so the configured backlog backend resolves. Failure is silent.
fm_notify_backlog_title() {  # <task-id>
  local output title
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(cd "$FM_HOME" && fm_run_timed "$NOTIFY_TIMEOUT" tasks-axi show "$1" --full 2>/dev/null) || return 1
  title=$(printf '%s\n' "$output" | sed -n 's/^  title: //p' | head -1)
  [ -n "$title" ] || return 1
  fm_notify_decode_title "$title"
}

# Collapse a summary to a single printable line: every control character,
# including embedded newlines and tabs, becomes a space while non-ASCII bytes
# are preserved for the JSON encoder.
fm_notify_oneline() {  # <text>
  printf '%s' "$1" | LC_ALL=C tr '\000-\037\177' ' '
}

# POST the payload to the webhook. Runs as a subshell so its traps own the
# private payload file without touching the caller's traps. Everything is
# bounded by curl's max-time and stderr is discarded so neither the URL nor the
# payload can reach a log.
fm_notify_post() (  # <webhook-file> <payload>
  local webhook_file=$1 payload=$2 payload_file rc
  payload_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-notify-payload.XXXXXX") || return 1
  printf '%s' "$payload" > "$payload_file" || { rm -f "$payload_file"; return 1; }
  trap 'rm -f "$payload_file"' EXIT
  trap 'rm -f "$payload_file"; exit 143' HUP INT TERM
  fm_notify_curl_config "$webhook_file" "$payload_file" \
    | curl -m "$NOTIFY_TIMEOUT" -sS -o /dev/null -K - 2>/dev/null
  rc=$?
  rm -f "$payload_file"
  trap - EXIT HUP INT TERM
  return "$rc"
)

if [ "$#" -ne 3 ] || [ "$1" != task-ready ]; then
  printf 'usage: fm-notify.sh task-ready <task-id> <pr-url>\n' >&2
  exit 2
fi
ID=$2
RAW_URL=$3
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  printf 'fm-notify: invalid task-ready request\n' >&2
  exit 2
fi
PROVIDER=$FM_PR_PROVIDER
URL=$FM_PR_URL
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# No webhook configured or readable: this home does not notify. Stay silent.
if [ ! -f "$WEBHOOK_FILE" ] || [ -L "$WEBHOOK_FILE" ] || [ ! -r "$WEBHOOK_FILE" ]; then
  exit 0
fi
[ -n "$(tr -d '[:space:]' < "$WEBHOOK_FILE" 2>/dev/null)" ] || exit 0

# The same PR was already announced: never notify twice.
if fm_pr_poll_ready_already_notified "$STATE" "$ID" "$PROVIDER" "$HOST" "$PROJECT_PATH" "$NUMBER"; then
  exit 0
fi

SUMMARY=$(fm_notify_pr_title "$PROVIDER" "$URL" "$NUMBER" "$HOST" "$PROJECT_PATH") || SUMMARY=
[ -n "$SUMMARY" ] || SUMMARY=$(fm_notify_backlog_title "$ID") || SUMMARY=
[ -n "$SUMMARY" ] || SUMMARY=$ID
SUMMARY=$(fm_notify_oneline "$SUMMARY")

PAYLOAD=$(fm_notify_payload "$ID" "$SUMMARY" "$URL")
if [ -z "$PAYLOAD" ]; then
  fm_notify_warn "$ID" "could not assemble the review-ready notification"
  exit 0
fi

if fm_notify_post "$WEBHOOK_FILE" "$PAYLOAD"; then
  fm_pr_poll_ready_mark_notified "$STATE" "$ID" "$PROVIDER" "$HOST" "$PROJECT_PATH" "$NUMBER" \
    || fm_notify_warn "$ID" "sent the review-ready notification but could not record it"
else
  fm_notify_warn "$ID" "could not send the review-ready notification"
fi
exit 0
