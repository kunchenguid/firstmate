#!/usr/bin/env bash
# Outbound tap: post a short Discord message for captain-relevant events.
#
# Usage:
#   fm-discord-notify.sh --event <key> --class decision|completion|blocker
#     --text <plain-language summary> [--link <url>] [--decision-key <key>]
#   fm-discord-notify.sh --wake-line <reason-line> --event <key>
#     --text <summary> [--link <url>]
#   echo "<wake reason line>" | fm-discord-notify.sh --wake --event <key>
#     --text <summary> [--link <url>]
#
# Exactly three event classes ever send: a decision waiting on the captain,
# finished work (including review and merge calls), and blockers or
# failures. Anything else - routine progress, retries, internal supervision
# mechanics - stays silent (exit 0, no message). The --wake/--wake-line
# hook classifies a watcher wake or supervision outcome reason line into
# one of those classes so the supervision flow can pipe wakes through this
# script: lines naming an open decision/answer-needed wake map to decision,
# lines naming a completion/review-ready/merge-call map to completion,
# lines naming a blocked/failed wake map to blocker, and every other line
# maps to routine and stays silent. An explicit --class overrides the wake
# classification for direct callers that already know the class.
#
# Each message is one short plain-language outcome: the summary text, the
# link or decision key when there is one, and a mention of the owner user
# (<@owner-id>) so the phone pings. Text is passed through discord_redact
# so secrets, tokens, or credential shapes never ride along, and internal
# machinery terms are left out by the caller-supplied wording (this script
# never invents detail beyond --text/--link/--decision-key).
#
# Destination: DISCORD_NOTIFY_CHANNEL_ID names the notify channel. When it
# is unset or empty, the script falls back to the existing send-channel
# behavior: DISCORD_CHANNEL_ID, then the first entry of
# DISCORD_CHANNEL_IDS, then config/discord.json poll_channel_id. When no
# channel resolves, or no bot token is configured, the script stays silent
# (exit 0). Documented default: unset DISCORD_NOTIFY_CHANNEL_ID means
# "notify where the home already sends".
#
# Rate-limit and dedup: one message per event key. The first call for a
# key sends; repeats for the same key (re-wakes for the same open
# decision, re-processed outcomes) are silent successes. Markers live in
# state/discord-notify/ and are pruned like the discord-seen store. A
# failed send releases its marker so a later retry can still deliver. 429
# Retry-After is honored by the underlying fm-discord-send.sh path, which
# this script delegates to rather than reimplementing.
#
# Exit codes: 0 sent or correctly stayed silent; 1 send failed (marker
# released, safe to retry); 2 usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-discord-lib.sh
. "$SCRIPT_DIR/fm-discord-lib.sh"

usage() { echo "usage: fm-discord-notify.sh --event <key> [--class decision|completion|blocker] [--wake|--wake-line <line>] --text <summary> [--link <url>] [--decision-key <key>]" >&2; }
help() { sed -n '2,/^set -u/p' "$0" | sed 's/^# //;s/^#//'; }

event=; class=; wake_line=; wake_stdin=0; text=; link=; decision_key=
while [ "$#" -gt 0 ]; do case "$1" in
  --help|-h) help; exit 0 ;;
  --event) shift; event=${1:-}; ;;
  --class) shift; class=${1:-}; ;;
  --wake-line) shift; wake_line=${1:-}; ;;
  --wake) wake_stdin=1 ;;
  --text) shift; text=${1:-}; ;;
  --link) shift; link=${1:-}; ;;
  --decision-key) shift; decision_key=${1:-}; ;;
  *) usage; exit 2 ;;
esac; shift || true; done

case "$event" in ''|.*|*[!A-Za-z0-9._-]*) usage; exit 2 ;; esac
[ -n "${text:-}" ] || { usage; exit 2; }
if [ "$wake_stdin" = 1 ]; then
  wake_line=$(cat)
fi

notify_classify_wake() {
  local line
  line=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$line" in
    *needs-decision*|*open\ decision*|*awaiting*answer*|*answer*needed*|*captain*decision*|*ask-user*|*decision*waiting*)
      printf 'decision\n'; return 0 ;;
  esac
  if printf '%s' "$line" | grep -Eq '(^|[^a-z0-9])(blocked|blocker|blockers|blocking|fail|failed|failing|failure|failures)([^a-z0-9]|$)'; then
    printf 'blocker\n'; return 0
  fi
  case "$line" in
    *review-ready*|*review*ready*|*check*green*|*checks-passed*|*ready*for*review*|*landed*|*shipped*)
      printf 'completion\n'; return 0 ;;
  esac
  if printf '%s' "$line" | grep -Eq '(^|[^a-z0-9])(complete|completed|completing|completion|merge|merged|merging)([^a-z0-9]|$)'; then
    printf 'completion\n'; return 0
  fi
  printf 'routine\n'
}

if [ -z "$class" ]; then
  [ -n "$wake_line" ] || { usage; exit 2; }
  class=$(notify_classify_wake "$wake_line")
fi
case "$class" in decision|completion|blocker) ;; routine) exit 0 ;; *) usage; exit 2 ;; esac

command -v jq >/dev/null 2>&1 || { echo "fm-discord-notify: jq not found" >&2; exit 1; }
discord_load_config
[ -n "${DISCORD_BOT_TOKEN:-}" ] || exit 0  # inert when not configured

notify_channel() {
  # Resolve the notify channel: DISCORD_NOTIFY_CHANNEL_ID, then the
  # existing send-channel behavior (DISCORD_CHANNEL_ID, first of
  # DISCORD_CHANNEL_IDS, config poll_channel_id).
  local notify ids first
  if [ -n "${DISCORD_NOTIFY_CHANNEL_ID+x}" ]; then notify=${DISCORD_NOTIFY_CHANNEL_ID-}; else notify=$(fmx_env_get DISCORD_NOTIFY_CHANNEL_ID "$(discord_env_file)"); fi
  export DISCORD_NOTIFY_CHANNEL_ID="$notify"
  [ -n "$notify" ] && { printf '%s\n' "$notify"; return 0; }
  if [ -n "${DISCORD_CHANNEL_ID:-}" ]; then printf '%s\n' "$DISCORD_CHANNEL_ID"; return 0; fi
  ids=${DISCORD_CHANNEL_IDS:-}
  first=$(printf '%s' "$ids" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | head -n1 || true)
  [ -n "$first" ] && { printf '%s\n' "$first"; return 0; }
  discord_config_json poll_channel_id
}

channel=$(notify_channel)
[ -n "$channel" ] || exit 0  # no destination configured: stay silent
case "$channel" in ''|*[!A-Za-z0-9_-]*) echo "fm-discord-notify: unsafe channel id" >&2; exit 2 ;; esac

owner=$(discord_effective_owner)
[ -n "$owner" ] || exit 0  # nobody to ping: stay silent

# Dedup: one message per event key. Claim before sending; a failed send
# releases the claim so a retry can still deliver.
notify_dir=$(discord_state_dir "discord-notify") || exit 1
marker="$notify_dir/$event"
if [ -e "$marker" ]; then exit 0; fi
tmp=$(umask 077; mktemp "$notify_dir/.claim.XXXXXX" 2>/dev/null) || exit 1
if ! printf '%s\n' "$(date +%s)" > "$tmp" || ! chmod 600 "$tmp"; then rm -f "$tmp"; exit 1; fi
if ln -- "$tmp" "$marker" 2>/dev/null; then rm -f "$tmp"; else rm -f "$tmp"; if [ -e "$marker" ]; then exit 0; fi; echo "fm-discord-notify: cannot claim event $event" >&2; exit 1; fi
find "$notify_dir" -type f -mtime +"$DISCORD_SEEN_RETENTION_DAYS" -delete 2>/dev/null || true

body=$(discord_redact "$text")
if [ -n "$link" ]; then
  printf '%s' "$link" | grep -qE '^[A-Za-z0-9_/:.?=&%#@+,;~*-]+$' || { echo "fm-discord-notify: unsafe link" >&2; rm -f "$marker"; exit 2; }
  body="$body $link"
fi
case "$decision_key" in ''|*[!A-Za-z0-9._-]*) [ -z "$decision_key" ] || { echo "fm-discord-notify: unsafe decision key" >&2; rm -f "$marker"; exit 2; } ;; esac
[ -z "$decision_key" ] || body="$body (decision: $decision_key)"
msg="<@$owner> $body"

case "$owner" in ''|*[!A-Za-z0-9_-]*) echo "fm-discord-notify: unsafe owner id" >&2; rm -f "$marker"; exit 2 ;; esac
if "$SCRIPT_DIR/fm-discord-send.sh" "$channel" --allow-user "$owner" "$msg" >/dev/null 2>&1; then
  printf 'notified %s\n' "$event"
else
  rc=$?
  rm -f "$marker"  # release: a retry may still deliver
  echo "fm-discord-notify: send failed for event $event" >&2
  exit "$rc"
fi
