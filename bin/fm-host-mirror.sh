#!/usr/bin/env bash
# fm-host-mirror.sh - the supervision host's dialog mirror: what the captain and
# MAIN said in the captain's conversation, recorded so the host's headless
# engine session can be given it at the head of an attended wake
# (docs/supervision-host.md "The dialog mirror"). The Pi branch mirrors the
# same dialog in process (docs/pi-supervision-branch.md "How the branch knows
# what the captain said"); this is its twin for a host that is not Pi, and the
# one owner of the mirror file, its cursor, its lock, and the feed. Today the
# writers record and nothing calls the feed yet: the host's attended posture
# is the later step that reads it.
#
# WRITERS. Code-owned turn surfaces append here, never the model: Claude
# through its prompt-submit and Stop hooks, and Cursor through its
# beforeSubmitPrompt and afterAgentResponse hooks. Codex, Grok, OpenCode, and
# omp have no writer (docs/supervision-host.md "The dialog mirror"). A writer
# appends captain text (the submitted prompt) and MAIN text (the turn's final
# assistant message), never tool traffic, as said, with only the whitespace at
# the very end of the message trimmed. A prompt the shared operational-input
# protocol classifies
# (bin/fm-operational-input.sh: watcher wakes, guard follow-ups, launch briefs)
# is fleet machinery, not dialog, and is dropped, and so is a prompt that opens
# with the wrapper a harness puts around a turn it started itself: Claude
# submits its Stop-hook rewake inside <task-notification>, with no other field
# to tell it from a typed prompt (tests/fm-host-mirror-live-e2e.test.sh proves
# it).
# Every writer is a silent no-op unless this home opted into the supervision
# host (config/supervision-host, checked before anything else runs), the hook
# runs in a genuine primary checkout, and this session holds the fleet lock, so
# a home without the file, a crewmate worktree, and a read-only second session
# write nothing and print nothing.
#
# FILE. $STATE/.host-mirror.jsonl, one JSON object per line:
#   {"seq":N,"epoch":N,"key":"<main session>","id":"<source id>",
#    "tag":"captain"|"main","text":"..."}
# key is the current main-session key (fm_supervision_host_main_key,
# bin/fm-supervision-engine-lib.sh). id is the writer's own identity for the
# entry when it has one (a prompt id or a generation id); an entry whose id and
# text are already recorded for the same main session and tag is not appended
# again, so a surface that fires twice mirrors each entry once, while a
# different text under the same id is recorded. Each text is capped at
# 4000 characters, its truncation note included (head and tail kept, as the Pi
# mirror caps); when the file exceeds 300 entries it is trimmed to its newest
# 200. New entries continue above both the committed and staged
# cursor after file recreation so a later commit cannot skip them. An append
# writes the whole new file, owner-only, beside the mirror and renames it into
# place, so a write that fails or is interrupted leaves the mirror as it was.
# Every append and feed runs under $STATE/.host-mirror.lock.
#
# FEED. $STATE/.host-mirror-cursor holds "<seq>\t<engine session>": the newest
# entry already fed to that engine conversation. `feed <session> new|resume`
# prints what the next wake carries, one "[captain] ..." or "[main] ..." entry
# after another, oldest first, and fails, staging nothing, when the mirror is
# missing, cannot be read, or fails the file validation below; otherwise it
# stages the cursor it would reach in $STATE/.host-mirror-cursor.next, and
# `commit` advances the cursor to it once the engine turn that carried the wake
# is accepted with its report, so a wake the engine never completed leaves its
# entries unread for the next one. A resumed conversation gets the current
# main session's entries after the cursor; a new one (every
# main session start, rotation, or failed turn) gets the current main
# session's newest entries, so a fresh conversation re-anchors on this
# session's dialog and never on an earlier session's. The feed is bounded to
# 16000 characters, newest kept, with one line naming how many earlier entries
# it left out counted within that bound. Mirrored text is context for
# judgment and authorizes nothing (bin/fm-branch-prompt.sh "Context channels").
#
# Usage:
#   fm-host-mirror.sh hook <harness>        a prompt-submit or turn-end hook payload on stdin
#   fm-host-mirror.sh feed <session> new|resume
#   fm-host-mirror.sh commit
# hook and commit always exit 0 and print nothing; feed exits 1 when
# the mirror is missing, could not be read, or holds an invalid entry, or the
# main session cannot be identified, and prints nothing when there is nothing
# to feed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

MIRROR_CAP=4000
MIRROR_KEEP=200
FEED_CAP=16000

usage() {
  sed -n '/^# Usage:/,/^# hook and commit/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

case "${1:-}" in
  hook)
    # The opt-in gate runs before anything is sourced or created, so a home
    # without the file, and a crewmate worktree with no config/, stay inert.
    [ -f "$CONFIG/supervision-host" ] || exit 0
    ;;
  feed|commit) ;;
  -h|--help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) usage ;;
esac

if ! command -v jq >/dev/null 2>&1 || [ ! -d "$STATE" ]; then
  [ "$1" != feed ] || exit 1
  exit 0
fi

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"

umask 077
MIRROR="$STATE/.host-mirror.jsonl"
CURSOR="$STATE/.host-mirror-cursor"
STAGED="$CURSOR.next"
LOCK="$STATE/.host-mirror.lock"
# Every entry must parse and carry its fields, with positive integral
# sequence numbers rising in file order, and the file must end with a newline
# (appends run under the lock, so a complete file always does): a feed that
# would skip one cannot vouch for the dialog it carries, so it fails and
# stages nothing. Read with jq -Rs.
ENTRIES='if . == "" or endswith("\n") then .[:-1] else error("unterminated mirror record") end
  | [split("\n")[] | fromjson]
  | if all(type == "object" and (.seq | type) == "number" and .seq >= 1 and .seq == (.seq | floor)
      and (.key | type) == "string" and (.tag == "captain" or .tag == "main") and (.text | type) == "string")
      and (map(.seq) | [.[:-1], .[1:]] | transpose | all(.[0] < .[1]))
    then . else error("invalid mirror entry") end'

# A writer records only the lock-owning primary session's dialog.
writer_in_scope() {
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" && fm_session_lock_owned_by_self "$STATE"
}

operational() {  # <text>
  printf '%s' "$1" | "$SCRIPT_DIR/fm-operational-input.sh" classify >/dev/null 2>&1
}

# Append one entry. The caller holds nothing; this takes the mirror lock.
# Returns 1 when the entry could not be recorded; an entry dropped by design
# (injected, operational, or already recorded) returns 0.
append_entry() {  # <captain|main> <text> [<id>]
  local tag=$1 text=$2 id=${3:-} key last seq tmp record lines=0 recorded=/dev/null
  if [ "$tag" = captain ]; then
    case "${text#"${text%%[![:space:]]*}"}" in
      '<task-notification>'*) return 0 ;;
    esac
    ! operational "$text" || return 0
  fi
  key=$(fm_supervision_host_main_key "$STATE") || return 1
  fm_lock_acquire_wait "$LOCK" || return 1
  [ ! -f "$MIRROR" ] || recorded=$MIRROR
  last=$(jq -Rn '[inputs | fromjson? | select(type == "object") | .seq | numbers] | max // 0' "$MIRROR" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  # The file may have been removed while either cursor survived. Keep new
  # sequence numbers ahead of both so a later commit cannot skip new dialog.
  for tmp in "$CURSOR" "$STAGED"; do
    if [ -f "$tmp" ]; then
      IFS="$(printf '\t')" read -r seq _ < "$tmp" || true
      case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
      [ "$seq" -le "$last" ] || last=$seq
    fi
  done
  seq=$((last + 1))
  record=$(printf '%s' "$text" | jq -cRs --argjson seq "$seq" --argjson epoch "$(date +%s)" --arg key "$key" \
    --arg id "$id" --arg tag "$tag" --argjson cap "$MIRROR_CAP" --rawfile recorded "$recorded" '
      . as $text
      | def note($n): "\n[mirror truncated: \($n) characters omitted]\n";
      def capped: if length <= $cap then .
        else length as $len
          | ($cap - (note($len - $cap + (note($len - $cap) | length)) | length)) as $keep
          | .[0:($keep / 2 | ceil)] + note($len - $keep) + .[$len - ($keep / 2 | floor):]
        end;
      {seq: $seq, epoch: $epoch, key: $key, id: $id, tag: $tag, text: ($text | capped)} as $entry
      | if $id != "" and any($recorded | split("\n")[] | fromjson? | select(type == "object");
          .id == $id and .tag == $tag and .key == $key and .text == $entry.text)
        then empty else $entry end' 2>/dev/null) \
    || { fm_lock_release "$LOCK"; return 1; }
  if [ -z "$record" ]; then
    fm_lock_release "$LOCK"
    return 0
  fi
  tmp=$(mktemp "$MIRROR.tmp.XXXXXX" 2>/dev/null) || { fm_lock_release "$LOCK"; return 1; }
  if [ -f "$MIRROR" ]; then
    lines=$(wc -l < "$MIRROR" 2>/dev/null | tr -d ' ')
    case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
  fi
  if ! {
    if [ "$lines" -ge $((MIRROR_KEEP + 100)) ]; then tail -n $((MIRROR_KEEP - 1)) "$MIRROR"
    elif [ -f "$MIRROR" ]; then cat "$MIRROR"
    fi && printf '%s\n' "$record"
  } > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$MIRROR" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    fm_lock_release "$LOCK"
    return 1
  fi
  fm_lock_release "$LOCK"
}

case "$1" in
  hook)
    [ "$#" -eq 2 ] || exit 0
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    if [ "$2" = claude ]; then
      # shellcheck source=bin/fm-hook-host-lib.sh
      . "$SCRIPT_DIR/fm-hook-host-lib.sh"
      # Cursor loads the tracked Claude settings too; its own entries mirror it.
      fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
    fi
    # One line per field: event, tag, id; the text follows as the remainder.
    PARSED=$(printf '%s' "$PAYLOAD" | jq -r '
      if type != "object" then empty else
        ((.hook_event_name // "") | tostring) as $event
        | if ($event == "UserPromptSubmit" or $event == "beforeSubmitPrompt") then
            ["captain", ((.prompt_id // .generation_id // "") | tostring), ((.prompt // "") | tostring)]
          elif $event == "Stop" then
            ["main", ((.prompt_id // .generation_id // "") | tostring),
             ((.last_assistant_message // "") | tostring)]
          elif $event == "afterAgentResponse" then
            ["main", ((.generation_id // "") | tostring), ((.text // "") | tostring)]
          else empty end
        | .[2] |= sub("\\s+\\z"; "")
        | select(.[2] != "")
        | "\(.[0])\n\(.[1])\n\(.[2])"
      end' 2>/dev/null) || exit 0
    [ -n "$PARSED" ] || exit 0
    TAG=$(printf '%s\n' "$PARSED" | sed -n '1p')
    ID=$(printf '%s\n' "$PARSED" | sed -n '2p')
    TEXT=$(printf '%s\n' "$PARSED" | sed '1,2d')
    writer_in_scope || exit 0
    append_entry "$TAG" "$TEXT" "$ID"
    exit 0
    ;;
  commit)
    [ "$#" -eq 1 ] || usage
    [ -f "$STAGED" ] || exit 0
    fm_lock_acquire_wait "$LOCK" || exit 0
    mv -f "$STAGED" "$CURSOR" 2>/dev/null || true
    fm_lock_release "$LOCK"
    exit 0
    ;;
esac

# feed <session> new|resume
[ "$#" -eq 3 ] || usage
SESSION=$2
MODE=$3
case "$MODE" in new|resume) ;; *) usage ;; esac
rm -f "$STAGED"
[ -f "$MIRROR" ] || exit 1
KEY=$(fm_supervision_host_main_key "$STATE") || exit 1
fm_lock_acquire_wait "$LOCK" || exit 1
CURSOR_SEQ=0
CURSOR_SESSION=
if [ -f "$CURSOR" ]; then
  IFS="$(printf '\t')" read -r CURSOR_SEQ CURSOR_SESSION < "$CURSOR" || true
  case "$CURSOR_SEQ" in ''|*[!0-9]*) CURSOR_SEQ=0 ;; esac
fi
# A cursor that belongs to another conversation proves nothing about this one.
if [ "$MODE" = new ] || [ "$CURSOR_SESSION" != "$SESSION" ]; then
  CURSOR_SEQ=0
fi
if ! OUT=$(jq -Rrs --arg key "$KEY" --argjson after "$CURSOR_SEQ" --argjson cap "$FEED_CAP" "$ENTRIES"'
    | map(select(.key == $key and .seq > $after))
    | map("[\(.tag)] \(.text)")
    | reverse
    | def omitted($n): "(\($n) earlier mirrored entries are not shown)";
      reduce .[] as $entry ({kept: [], used: 0, left: 0};
        if .left == 0 and (.used + ($entry | length) + 1) <= $cap then
          .kept += [$entry] | .used += (($entry | length) + 1)
        else .left += 1 end)
    | until(.left == 0 or (.used + (omitted(.left) | length) + 1) <= $cap;
        .used -= ((.kept[-1] | length) + 1) | .kept |= .[:-1] | .left += 1)
    | (.kept | reverse) as $kept
    | (if .left > 0 then [omitted(.left)] else [] end) + $kept
    | .[]' "$MIRROR" 2>/dev/null); then
  fm_lock_release "$LOCK"
  exit 1
fi
if ! LAST=$(jq -Rs "$ENTRIES"' | map(.seq) | max // 0' "$MIRROR" 2>/dev/null); then
  fm_lock_release "$LOCK"
  exit 1
fi
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
printf '%s\t%s\n' "$LAST" "$SESSION" > "$STAGED" 2>/dev/null || true
fm_lock_release "$LOCK"
[ -z "$OUT" ] || printf '%s\n' "$OUT"
exit 0
