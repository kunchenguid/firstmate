#!/usr/bin/env bash
# fm-live-alert-scout.sh - turn a live-alert inbox note into a P0 read-only scout.
#
# Usage: fm-live-alert-scout.sh <inbox-note-id>
#        fm-live-alert-scout.sh --help
#
# <inbox-note-id> is the id `fm-inbox.sh list` prints for a note the game host's
# watchdog relayed. The note must open with "[Lloegrys live] Alerta"; any other
# note is refused (exit 1) and nothing is created.
#
# Everything judgment-free about handling such an alert happens here:
#   1. Refuse a missing or non-alert note.
#   2. Idempotency by note id: when the backlog already has item
#      lloegrys-live-alerta-<lowercased note id>, print its state and exit 0.
#      Nothing else runs, so a repeated wake never makes a second scout.
#   3. Add that item (kind scout, priority 0, repo lloegrys-live) with
#      fm-tasks-axi.sh, scaffold its brief with `fm-brief.sh <item> lloegrys-live
#      --scout`, and fill {TASK} and {FIRSTMATE_SPEC} from the fixed template
#      docs/templates/live-alert-scout.md. The template is the single owner of
#      what the scout investigates and of its read-only limits.
#   4. Resolve the profile with fm-dispatch-resolve.sh and dispatch with
#      `fm-spawn.sh <item> <projects>/lloegrys-live --scout`. A clear status
#      passes its profile line to the spawn. Off, ambiguous or error dispatches
#      on the static scout harness and says so. An escalate status stops with
#      exit 3 after the item and brief exist, because the matched rule needs the
#      captain's approval; the message names the fm-spawn command to run after
#      that decision.
#   5. Print one line: the item id, the log window and the profile used.
#
# The note is NOT marked handled. Acknowledging it is the decision of whoever
# reads the scout's result.
#
# Log window: 15 minutes around the note's `at=` time - 10 minutes before it to
# 5 minutes after, in UTC. The watchdog reports after it sees a signature, so
# the cause sits mostly before the note.
#
# Template placeholders: {NOTE_ID} {NOTE_AT} {WINDOW_SINCE} {WINDOW_UNTIL}
# {NOTE_BODY}. The template holds two sections, "## Captain's intent" and
# "## Firstmate spec", exactly as the scout brief does.
#
# Exit codes: 0 scout dispatched or already present; 1 refused (bad id, note
# missing, not an alert, missing template or project); 2 usage; 3 item created
# but not dispatched (escalate status, or a tool failed - stderr names it).
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE and
# FM_PROJECTS_OVERRIDE select the operational home exactly as the sibling
# scripts do.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
INBOX="$STATE/inbox"
TEMPLATE="$FM_ROOT/docs/templates/live-alert-scout.md"
REPO=lloegrys-live
ALERT_PREFIX='[Lloegrys live] Alerta'
WINDOW_BEFORE=600
WINDOW_AFTER=300

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

refuse() { printf 'fm-live-alert-scout: %s\n' "$*" >&2; exit 1; }
undispatched() { printf 'fm-live-alert-scout: %s\n' "$*" >&2; exit 3; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
NOTE_ID=$1

case "$NOTE_ID" in
  ''|*/*|*[[:space:]]*|*..*|*[!A-Za-z0-9._-]*) refuse "invalid note id: $NOTE_ID" ;;
esac

NOTE_FILE=
for candidate in "$INBOX/$NOTE_ID.note" "$INBOX/handled/$NOTE_ID.note"; do
  if [ -f "$candidate" ]; then
    NOTE_FILE=$candidate
    break
  fi
done
[ -n "$NOTE_FILE" ] || refuse "no inbox note $NOTE_ID in $INBOX"

NOTE_BODY=$(awk 'found { print; next } /^--$/ { found=1 }' "$NOTE_FILE")
NOTE_AT=$(sed -n '/^--$/q;s/^at=//p' "$NOTE_FILE" | head -n 1)
case "$NOTE_BODY" in
  "$ALERT_PREFIX"*) ;;
  *) refuse "note $NOTE_ID is not a live alert (it must start with \"$ALERT_PREFIX\")" ;;
esac
[ -n "$NOTE_AT" ] || refuse "note $NOTE_ID has no at= time"

ITEM="lloegrys-live-alerta-$(printf '%s' "$NOTE_ID" | tr '[:upper:]' '[:lower:]')"

if SHOWN=$("$SELF_DIR/fm-tasks-axi.sh" show "$ITEM" 2>/dev/null); then
  ITEM_STATE=$(printf '%s\n' "$SHOWN" | sed -n 's/^  state: //p' | head -n 1)
  printf '%s already exists: state=%s\n' "$ITEM" "${ITEM_STATE:-unknown}"
  exit 0
fi

epoch_of() {  # <UTC YYYY-MM-DDTHH:MM:SSZ>
  date -u -d "$1" +%s 2>/dev/null \
    || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}

utc_of() {  # <epoch>
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

AT_EPOCH=$(epoch_of "$NOTE_AT") || refuse "note $NOTE_ID has an unreadable at= time: $NOTE_AT"
WINDOW_SINCE=$(utc_of $((AT_EPOCH - WINDOW_BEFORE)))
WINDOW_UNTIL=$(utc_of $((AT_EPOCH + WINDOW_AFTER)))

[ -r "$TEMPLATE" ] || refuse "missing template $TEMPLATE"
[ -d "$PROJECTS/$REPO" ] || refuse "project $REPO is not cloned at $PROJECTS/$REPO"

section() {  # <heading>
  awk -v heading="## $1" '
    $0 == heading { on = 1; next }
    /^## / { on = 0 }
    on { print }
  ' "$TEMPLATE"
}

fill() {  # <text>
  local text=$1
  text=${text//"{NOTE_ID}"/"$NOTE_ID"}
  text=${text//"{NOTE_AT}"/"$NOTE_AT"}
  text=${text//"{WINDOW_SINCE}"/"$WINDOW_SINCE"}
  text=${text//"{WINDOW_UNTIL}"/"$WINDOW_UNTIL"}
  text=${text//"{NOTE_BODY}"/"$NOTE_BODY"}
  printf '%s\n' "$text"
}

INTENT=$(fill "$(section "Captain's intent")")
SPEC=$(fill "$(section "Firstmate spec")")
[ -n "$INTENT" ] && [ -n "$SPEC" ] || refuse "template $TEMPLATE needs both \"## Captain's intent\" and \"## Firstmate spec\""

"$SELF_DIR/fm-tasks-axi.sh" add "$ITEM" "Live alert scout for inbox note $NOTE_ID" \
  --kind scout --repo "$REPO" --priority 0 --queue >/dev/null \
  || undispatched "could not add backlog item $ITEM"

"$SELF_DIR/fm-brief.sh" "$ITEM" "$REPO" --scout >/dev/null \
  || undispatched "item $ITEM was added but its brief could not be scaffolded"

BRIEF="$DATA/$ITEM/brief.md"
INTENT_FILE=$(mktemp)
SPEC_FILE=$(mktemp)
FILLED=$(mktemp)
trap 'rm -f "$INTENT_FILE" "$SPEC_FILE" "$FILLED"' EXIT
printf '%s\n' "$INTENT" >"$INTENT_FILE"
printf '%s\n' "$SPEC" >"$SPEC_FILE"
awk -v intent_file="$INTENT_FILE" -v spec_file="$SPEC_FILE" '
  function emit(path,   line) {
    while ((getline line < path) > 0) print line
    close(path)
  }
  $0 == "{TASK}" { emit(intent_file); next }
  $0 == "{FIRSTMATE_SPEC}" { emit(spec_file); next }
  { print }
' "$BRIEF" >"$FILLED"
cat "$FILLED" >"$BRIEF"

RESOLVE_OUT=$("$SELF_DIR/fm-dispatch-resolve.sh" "$BRIEF" --project "$REPO" || true)
RESOLVE_STATUS=$(printf '%s\n' "$RESOLVE_OUT" | sed -n 's/^ *status: //p' | head -n 1)
PROFILE_LINE=$(printf '%s\n' "$RESOLVE_OUT" | sed -n 's/^ *profile: //p' | head -n 1)

PROFILE_ARGS=()
PROFILE_USED=static
case "$RESOLVE_STATUS" in
  clear)
    case "$PROFILE_LINE" in
      ''|*[!A-Za-z0-9._/:@+\ -]*) undispatched "item $ITEM is ready but the resolved profile line is unusable: $PROFILE_LINE" ;;
    esac
    read -r -a PROFILE_ARGS <<<"$PROFILE_LINE"
    PROFILE_USED=$PROFILE_LINE
    ;;
  escalate)
    undispatched "item $ITEM is ready but the matched dispatch rule needs the captain's approval; after the decision run: fm-spawn.sh $ITEM $PROJECTS/$REPO --scout <profile flags>"
    ;;
esac

"$SELF_DIR/fm-spawn.sh" "$ITEM" "$PROJECTS/$REPO" --scout ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} >/dev/null \
  || undispatched "item $ITEM is ready but fm-spawn.sh failed; rerun: fm-spawn.sh $ITEM $PROJECTS/$REPO --scout"

printf '%s window=%s/%s profile=%s\n' "$ITEM" "$WINDOW_SINCE" "$WINDOW_UNTIL" "$PROFILE_USED"
