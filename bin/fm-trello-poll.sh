#!/usr/bin/env bash
# One sweep of the Trello board for captain-driven control-plane triggers.
#
# Inert by default: a HARD no-op (exit 0, no output) unless config/trello.env
# supplies TRELLO_API_KEY, TRELLO_TOKEN, and TRELLO_BOARD_SHORTLINK. This script
# is the body of the watcher check shim state/trello-watch.check.sh, where the
# contract is "output => wake firstmate, silence => keep sleeping", so the no-op
# keeps the watcher behaving exactly as today until a user opts in.
#
# It ALSO no-ops while state/.trello-paused exists (global hibernate), so the
# whole poll stands down without touching the watcher backbone.
#
# Ownership model: the captain owns exactly two moves - creating an Inbox card
# and moving a card to Ready / Go (or adding a `go` label) with a comment.
# Firstmate owns every other lane and NEVER places a card into Inbox or Ready, so
# any card there is unambiguously captain-driven. That is what lets this poll
# treat lane membership as a trust signal.
#
# Triggers emitted (becomes the watcher's check: wake):
#   trello-inbox <cardid>            a new/updated card in Inbox (= new task request)
#   trello-ready <cardid>            a card in Ready/Go, or a freshly `go`-labeled
#                                    card with a comment (= captain decision)
#   trello-nudge <cardid> <taskid>   a new captain comment on a firstmate-owned card
#                                    bound to a live task, in In Progress / Needs Input
#                                    (= extra input; relay to the worker)
#   trello-hold  <cardid> <taskid>   a `hold` label, or a captain move back to Needs
#                                    Input, of a bound In-Progress card (= per-task pause)
#
# At most ONE trigger line is emitted per sweep, matching fm-x-poll.sh: the
# watcher flattens all shim stdout into a single wake payload, so emitting several
# differing-arity trigger lines at once would collapse into an unparseable blob.
# Any other firing-eligible card keeps its marker and fires on a later sweep.
#
# Ready/Go and a fresh captain-applied `go` label outrank any task binding.
# Binding affects only In Progress and Needs Input nudge/hold routing.
#
# Cross-process synchronization: the poll holds state/.trello-sync.lock through
# its board read, classification, and marker update. Every fm-trello.sh board
# mutation holds the same lock through its marker update, so firstmate's own
# edit cannot be misclassified in the post-mutation/pre-marker window.
#
# Idempotency: a per-card seen marker state/.trello-seen-<cardid> records the
# card's dateLastActivity, list id, go-label state, and comment count.
# A card fires only when activity advanced past the marker (or the marker is
# absent, for the inherently-new Inbox/Ready cases).
# Every fm-trello.sh mutation bumps this marker, so firstmate's own edits never
# wake it - only a genuine captain edit does.
# Distinguishing a per-task pause (move back to Needs Input) from a nudge
# (comment) uses the marker's recorded prior list id.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-trello-lib.sh
. "$SCRIPT_DIR/fm-trello-lib.sh"

trello_load_config
# Hard no-op when Trello mode is off: this is what keeps the check shim inert.
trello_configured || exit 0
# Global hibernate: paused poll stands down without touching the watcher.
[ -e "$STATE/.trello-paused" ] && exit 0

ERROR_FILE="$STATE/trello-poll.error"

emit_error_once() {
  local msg=$1
  mkdir -p "$STATE" 2>/dev/null || true
  if [ -f "$ERROR_FILE" ] && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" > "$ERROR_FILE" 2>/dev/null || true
  printf 'trello-mode-error %s\n' "$msg"
}
clear_error() { rm -f "$ERROR_FILE" 2>/dev/null || true; }

command -v curl >/dev/null 2>&1 || { emit_error_once "missing curl"; exit 0; }
command -v jq   >/dev/null 2>&1 || { emit_error_once "missing jq"; exit 0; }

# The shared portable lock recovers stale owners and is safe on macOS Bash 3.2.
# Acquire before any board read so a CLI mutation cannot interleave before the
# emitted trigger or seen-marker update.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
TRELLO_SYNC_LOCK="$STATE/.trello-sync.lock"
CARDS_FILE=
trello_poll_cleanup() {
  [ -z "$CARDS_FILE" ] || rm -f "$CARDS_FILE" 2>/dev/null || true
  fm_lock_release "$TRELLO_SYNC_LOCK"
}
fm_lock_acquire_wait "$TRELLO_SYNC_LOCK"
trap trello_poll_cleanup EXIT

# Resolve the lanes we care about. A missing lane is not fatal - the board may
# not have every lane yet - but Inbox and Ready are the captain-owned request and
# decision lanes, so if neither resolves there is nothing to poll.
#
# trello_lists_json already retries a curl transport failure internally
# (trello_curl); rc 2 means that retry budget is exhausted and this is still a
# benign network blip, not an actionable board/credential problem - defer
# silently to the next scheduled sweep rather than waking the watcher over it.
trello_lists_json >/dev/null
LISTS_RC=$?
if [ "$LISTS_RC" -eq 2 ]; then
  exit 0
elif [ "$LISTS_RC" -ne 0 ]; then
  emit_error_once "cannot read board lists"
  exit 0
fi
INBOX_ID=$(trello_lane_id "Inbox" || true)
READY_ID=$(trello_lane_id "Ready" || true)
INPROGRESS_ID=$(trello_lane_id "In Progress" || true)
NEEDSINPUT_ID=$(trello_lane_id "Needs Input" || true)
if [ -z "$INBOX_ID" ] && [ -z "$READY_ID" ]; then
  emit_error_once "board has no Inbox or Ready lane"
  exit 0
fi

# One board-cards fetch gives lane, labels, and comment count for every open
# card - enough to classify all four triggers without per-card round-trips.
CARDS_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-trello-cards.XXXXXX") || exit 0
CODE=$(trello_api GET "1/boards/$TRELLO_BOARD/cards?fields=id,name,idList,dateLastActivity,labels,badges" "$CARDS_FILE")
CARDS_RC=$?
if [ "$CARDS_RC" -eq 2 ]; then
  exit 0
elif [ "$CARDS_RC" -ne 0 ]; then
  emit_error_once "cannot read board cards"
  exit 0
fi
case "$CODE" in
  200) ;;
  400|401|403|404) emit_error_once "board cards returned HTTP $CODE"; exit 0 ;;
  *) exit 0 ;;
esac
clear_error

# Build the set of live-task bindings as a plain "cardid<TAB>taskid" table (stock
# macOS Bash 3.2 has no associative arrays). Only bound cards fire a nudge/hold.
BOUND_MAP=""
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  cid=$(grep -E '^trello_card=' "$meta" 2>/dev/null | tail -n1 | sed 's/^trello_card=//')
  [ -n "$cid" ] || continue
  tid=$(basename "$meta" .meta)
  BOUND_MAP="$BOUND_MAP$cid	$tid
"
done

# Print the task id bound to a card id, or nothing.
bound_task() {
  [ -n "$BOUND_MAP" ] || return 0
  printf '%s' "$BOUND_MAP" \
    | awk -F'\t' -v c="$1" '$1==c{print $2}' \
    | LC_ALL=C sort \
    | head -n1
}

has_label() {
  # $1 = labels JSON array (compact), $2 = label name (normalized to lower alnum)
  printf '%s' "$1" | jq -e --arg n "$2" '
    any(.[]?; ((.name // "") | ascii_downcase | gsub("[^a-z0-9]"; "")) == $n)' >/dev/null 2>&1
}

# Iterate cards as compact JSON lines so field parsing stays hermetic.
jq -c '.[]' "$CARDS_FILE" 2>/dev/null | while IFS= read -r card; do
  cardid=$(printf '%s' "$card" | jq -r '.id // ""')
  [ -n "$cardid" ] || continue
  trello_safe_cardid "$cardid" || continue
  idlist=$(printf '%s' "$card" | jq -r '.idList // ""')
  date=$(printf '%s' "$card" | jq -r '.dateLastActivity // ""')
  labels=$(printf '%s' "$card" | jq -c '.labels // []')
  comments=$(printf '%s' "$card" | jq -r '.badges.comments // 0')

  # Read prior seen marker:
  # "<date>\t<listid>\t<go-state>\t<comment-count>".
  # Legacy date/list-only markers remain valid and leave the new fields unknown.
  marker=$(trello_marker_read "$cardid")
  IFS=$'\t' read -r prev_date prev_list prev_go prev_comments <<EOF
$marker
EOF
  seen=0; [ -n "$marker" ] && seen=1
  changed=0; { [ "$seen" -eq 0 ] || [ "$date" != "$prev_date" ]; } && changed=1
  current_go=0
  has_label "$labels" "go" && current_go=1
  fresh_go=0
  if [ "$current_go" -eq 1 ] && [ "$comments" -gt 0 ] 2>/dev/null; then
    if [ "$seen" -eq 0 ]; then
      fresh_go=1
    elif [ "$prev_go" = "0" ] \
      && [ -n "$prev_comments" ] \
      && [ "$comments" -gt "$prev_comments" ] 2>/dev/null; then
      fresh_go=1
    fi
  fi

  taskid=$(bound_task "$cardid")
  fire=""

  # Captain-owned Ready/Go semantics outrank binding. A stale, completed, dead,
  # duplicate, or still-current task meta cannot suppress an explicit Ready move.
  # A fresh go-label transition is also authoritative; an old go label does not
  # turn an ordinary bound In-Progress comment into a new pickup.
  if [ -n "$INBOX_ID" ] && [ "$idlist" = "$INBOX_ID" ]; then
    [ "$changed" -eq 1 ] && fire="trello-inbox $cardid"
  elif [ "$fresh_go" -eq 1 ]; then
    [ "$changed" -eq 1 ] && fire="trello-ready $cardid"
  elif [ -n "$READY_ID" ] && [ "$idlist" = "$READY_ID" ]; then
    [ "$changed" -eq 1 ] && fire="trello-ready $cardid"
  elif [ -n "$taskid" ] && { [ "$idlist" = "$INPROGRESS_ID" ] || [ "$idlist" = "$NEEDSINPUT_ID" ]; }; then
    if [ "$changed" -eq 1 ]; then
      if has_label "$labels" "hold"; then
        fire="trello-hold $cardid $taskid"
      elif [ -n "$NEEDSINPUT_ID" ] && [ "$idlist" = "$NEEDSINPUT_ID" ] && [ -n "$INPROGRESS_ID" ] && [ "$prev_list" = "$INPROGRESS_ID" ]; then
        fire="trello-hold $cardid $taskid"
      else
        fire="trello-nudge $cardid $taskid"
      fi
    fi
  else
    # Not a watched card: leave no marker so state stays bounded to relevant cards.
    continue
  fi

  # Emit AT MOST ONE trigger per sweep, matching fm-x-poll.sh's one-line-per-sweep
  # contract: the watcher flattens all shim stdout newlines into a single wake
  # payload, so multiple differing-arity trigger lines would collapse into an
  # unparseable blob. Advance the seen marker ONLY for the card we actually emit,
  # then stop; every other firing-eligible card keeps its existing marker
  # UNCHANGED and fires on a subsequent sweep, so no trigger is dropped.
  if [ -n "$fire" ]; then
    trello_marker_write "$cardid" "$date" "$idlist" "$current_go" "$comments" || true
    printf '%s\n' "$fire"
    break
  fi
done
