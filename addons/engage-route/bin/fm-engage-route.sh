#!/usr/bin/env bash
# Route durable sign-off Go deeper asks to the matching Firstmate task inbox.
set -euo pipefail

FM_ROOT=${FM_ROOT_OVERRIDE:-${FM_HOME:?set FM_HOME}/}
FM_ROOT=${FM_ROOT%/}
STATE=${FM_STATE_OVERRIDE:-$FM_ROOT/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_ROOT/config}
SIGNOFF=${SIGN_OFF_CLI:-sign-off-axi}
# shellcheck source=/dev/null
. "$FM_ROOT/bin/fm-task-inbox-lib.sh"
usage() { echo 'usage: fm-engage-route.sh dispatch <board.json> | bind <filer> <task-id>' >&2; exit 2; }
finished() { grep -Eq '^(done|failed|cancelled|finished) \[at=[0-9]+\]:' "$STATE/$1.status" 2>/dev/null; }
[ "$#" -ge 1 ] || usage
cmd=$1; shift
case $cmd in
  bind)
    [ "$#" = 2 ] || usage
    [[ $1 =~ ^[A-Za-z0-9._-]{1,128}$ && $2 =~ ^[A-Za-z0-9._-]{1,128}$ ]] || { echo 'filer and task id must be 1-128 safe characters' >&2; exit 2; }
    mkdir -p "$CONFIG"
    file=$CONFIG/engage-owners
    tmp=$(mktemp "$CONFIG/.engage-owners.XXXXXX")
    if [ -f "$file" ]; then awk -F '\t' -v f="$1" '$1 != f' "$file" > "$tmp"; fi
    printf '%s\t%s\n' "$1" "$2" >> "$tmp"
    mv "$tmp" "$file"
    ;;
  dispatch)
    [ "$#" = 1 ] && [ -f "$1" ] || usage
    board=$1
    # Read only filer metadata and open requests; this never touches answers or captain holds.
    filers=$("$SIGNOFF" list "$board" --json | jq -r '.decisions[] | .filer // empty' | sort -u)
    while IFS= read -r filer; do
      [ -n "$filer" ] || continue
      [[ $filer =~ ^[A-Za-z0-9._-]{1,128}$ ]] || continue
      task=$filer
      if [ -f "$CONFIG/engage-owners" ]; then
        override=$(awk -F '\t' -v f="$filer" '$1 == f { print $2; exit }' "$CONFIG/engage-owners")
        [ -z "$override" ] || task=$override
      fi
      [[ $task =~ ^[A-Za-z0-9._-]{1,128}$ ]] || { echo "invalid owner task id for filer $filer" >&2; continue; }
      asks=$("$SIGNOFF" deeper "$board" --filer "$filer" --json --all | jq -c '.deeper[]? | select(.done != true)')
      while IFS= read -r ask; do
        [ -n "$ask" ] || continue
        id=$(jq -r '.id' <<<"$ask")
        meta=$STATE/$task.meta
        if [ ! -f "$meta" ]; then
          reason="no owner record for filer $filer"
          finished "$task" && reason="owner task $task is finished"
          printf '%s\tqueued\t%s\n' "$id" "$reason" >> "$STATE/engage-route.log"
          continue
        fi
        if finished "$task"; then
          printf '%s\tqueued\towner task %s is finished\n' "$id" "$task" >> "$STATE/engage-route.log"
          continue
        fi
        message=$(jq -r '"Sign-off engagement request " + .id + " for filer " + .key + " (" + .part + "): " + (.q // "Go deeper")' <<<"$ask")
        handled=$(for existing in "$STATE/$task.inbox/handled/"*.msg; do
          [ -f "$existing" ] || continue
          [ "$(fm_task_inbox_body "$existing")" != "$message" ] || { printf '%s' "$existing"; break; }
        done)
        if [ -n "$handled" ]; then
          printf '%s\towner-ack\t%s\n' "$id" "$task" >> "$STATE/engage-route.log"
          continue
        fi
        # The inbox library deduplicates exact request bodies across replay.
        record=$(fm_task_inbox_write_idempotent "$STATE" "$task" "$message")
        backend=$(fm_backend_of_meta "$meta")
        target=$(fm_backend_target_of_meta "$meta")
        [ -n "$target" ] || { echo "no endpoint for owner task $task" >&2; continue; }
        if [[ $record == */handled/* ]]; then
          printf '%s\towner-ack\t%s\n' "$id" "$task" >> "$STATE/engage-route.log"
        else
          if ! fm_task_inbox_ring "$backend" "$target" "$record" "fm-$task"; then
            echo "request $id is in the owner inbox, but ringing $task failed: ${FM_TASK_INBOX_RING_REASON:-endpoint unavailable}" >&2
          fi
          printf '%s\tinbox-recorded\t%s\n' "$id" "$task" >> "$STATE/engage-route.log"
        fi
      done <<< "$asks"
    done <<< "$filers"
    ;;
  *) usage ;;
esac
