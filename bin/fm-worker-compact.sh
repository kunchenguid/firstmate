#!/usr/bin/env bash
# Claude saved planning state, independent of the task-worker compaction rollout.
# Usage: fm-worker-compact.sh --settings CONFIG STATE ID BRIEF SETTINGS_FILE [KIND [NOTES]]
#        fm-worker-compact.sh --card STATE ID BRIEF [NOTES]
# config/worker-compaction: off (default), half (cksum task-id parity), all.
# Change the flag before spawning/relaunching workers; existing sessions are unchanged.
# --settings initializes missing notes without replacing saved state and merges a
# SessionStart startup/resume/compact card hook, retaining existing hooks. Only
# enabled task workers get autoCompactWindow=300000; KIND=secondmate skips rollout.
# --card accepts native SessionStart JSON and caps output at 10000 characters.
# NOTES defaults to notes.md beside BRIEF; keep its essential state within 3000
# bytes and refresh it at milestones. No transcript is replayed.
set -eu

case "${1:-}" in
  --help|-h)
    head -n 12 "${BASH_SOURCE[0]}"
    exit 0
    ;;
  --settings)
    config=$2 state=$3 id=$4 brief=$5 settings=$6
    kind=${7:-task} notes=${8:-$(dirname "$brief")/notes.md}
    if [ -L "$notes" ] || { [ -e "$notes" ] && [ ! -f "$notes" ]; }; then
      echo 'error: unsafe planning notes file' >&2; exit 1
    fi
    if [ ! -e "$notes" ]; then
      # noclobber also refuses a concurrent writer or a newly inserted symlink.
      (umask 077; set -C
        {
          printf '# Saved planning state\n\n## Goal and current plan\n'
          if [ -f "$brief" ] && [ ! -L "$brief" ]; then
            awk '/^# (Task|Charter)$/ {on=1; next} on && /^# / {exit} on {print}' "$brief" | head -c 1000
          fi
          printf '\nConsult the on-disk brief for the complete contract.\n\n## Decisions and constraints\n\n## Evidence and revision\n\n## Open work and next steps\n'
        } > "$notes"
      ) || exit 1
    fi
    mode=off
    if [ "$kind" != secondmate ] && [ -f "$config/worker-compaction" ]; then
      mode=$(tr -d '[:space:]' < "$config/worker-compaction")
    fi
    case "$mode" in
      off|'') enabled=0 ;;
      all) enabled=1 ;;
      half)
        checksum=$(printf '%s' "$id" | cksum)
        enabled=$(( ${checksum%% *} % 2 ))
        ;;
      *) echo 'error: config/worker-compaction must be off, half, or all' >&2; exit 1 ;;
    esac
    printf -v command 'bash %q --card %q %q %q %q' "${BASH_SOURCE[0]}" "$state" "$id" "$brief" "$notes"
    jq --arg command "$command" --argjson enabled "$enabled" '
      (if $enabled == 1 then .autoCompactWindow = 300000 else . end)
      | .hooks.SessionStart = ((.hooks.SessionStart // []) +
          [{matcher: "startup|resume|compact", hooks: [{type: "command", command: $command, timeout: 5}]}])
    ' "$settings"
    ;;
  --card)
    state=$2 id=$3 brief=$4
    source=$(jq -r '.source // ""' 2>/dev/null) || exit 0
    case "$source" in startup|resume|compact) ;; *) exit 0 ;; esac
    notes=${5:-$(dirname "$brief")/notes.md}
    # Byte-bounded reads also bound memory use. jq's final Unicode slice is the
    # single output ceiling, including labels and unexpectedly long paths.
    {
      printf 'Worker task card: %s\nStatus: %s/%s.status\nInbox: %s/%s.inbox\nNotes: %s\n' "$id" "$state" "$id" "$state" "$id" "$notes"
      printf '\nRead back the saved planning state below before continuing; fill missing sections before starting work.\nKeep notes within 3000 bytes; refresh at every milestone and before compaction or handoff.\nRecord current goal/plan, decisions and constraints, evidence/revision, open work and next steps.\nPreserve live board chat and required independent critics.\n'
      printf '\nWorker notes:\n'
      if [ -f "$notes" ] && [ ! -L "$notes" ]; then head -c 3000 "$notes"; fi
      printf '\nTask and goal (brief excerpt):\n'
      if [ -f "$brief" ] && [ ! -L "$brief" ]; then
        awk '/^# (Task|Charter)$/ {on=1; next} on && /^# / {exit} on {print}' "$brief" | head -c 3000
        printf '\nDone rule (brief excerpt):\n'
        awk '/^# Definition of done$/ {on=1; next} on && /^# / {exit} on {print}' "$brief" | head -c 2000
      fi
      printf '\nLast status lines:\n'
      if [ -f "$state/$id.status" ] && [ ! -L "$state/$id.status" ]; then
        tail -n 8 "$state/$id.status" | tail -c 1000
      fi
      printf '\nContinue this task; consult the on-disk brief for the complete contract.\n'
    } | jq -Rrjs '.[0:10000]'
    ;;
  *) echo 'usage: fm-worker-compact.sh --help' >&2; exit 1 ;;
esac
