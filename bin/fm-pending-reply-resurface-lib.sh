#!/usr/bin/env bash
# Dismissal scan and Bearings rows for an opt-in pending-reply re-surface.
#
# Callers source bin/fm-pending-reply-lib.sh first. This file stays out of that
# library so the scripts that source the library do not re-analyse the scan.
# docs/configuration.md "Escalated pending-reply re-surfacing" owns the switch.

# Read the parent status log line by line and print open or dismissed.
# A status log that cannot be read is a failure, not an open result.
_fm_pending_reply_scan_dismissal() {  # <status-file> <key>
  local parent_status=$1 key=$2 line untimed seen=''
  [ -f "$parent_status" ] && [ -r "$parent_status" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *"[key=$key]"*) ;; *) continue ;; esac
    _fm_status_untimed "$line" untimed
    case "$untimed" in
      "blocked [key=$key]: "*) seen=open ;;
      "resolved [key=$key]: pending-reply-resolved: "*) [ -z "$seen" ] || seen=dismissed ;;
    esac
  done < "$parent_status" || return 1
  if [ "$seen" = dismissed ]; then
    printf 'dismissed'
  else
    printf 'open'
  fi
}

# 0 when the operator dismissed this record's escalation: the parent channel
# holds the resolved [key=pending-reply-<corr>] close fm-send --resolve-key
# writes, after the escalation opened under that key. Nothing else dismisses.
# An unchanged log keeps the previous escalation_dismiss_scan answer. A read
# that fails is not cached. Never writes the record: after a fresh scan it
# stores the value for escalation_dismiss_scan in <scan-var>, for a caller
# holding the record's lock to save.
fm_pending_reply_escalation_dismissed() {  # <record-path> [<scan-var>]
  local rec=$1 parent_status key signature cached seen
  [ -z "${2:-}" ] || printf -v "$2" '%s' ''
  [ -z "$(fm_pending_reply_get "$rec" escalation_dismissed_epoch)" ] || return 0
  parent_status=$(fm_pending_reply_get "$rec" parent_status)
  [ -n "$parent_status" ] && [ -f "$parent_status" ] || return 1
  key=$(fm_pending_reply_escalation_key "$(fm_pending_reply_get "$rec" corr_id)")
  signature=$(fm_pending_reply_file_signature "$parent_status")
  cached=$(fm_pending_reply_get "$rec" escalation_dismiss_scan)
  case "$signature" in
    missing|unreadable) ;;
    *)
      case "$cached" in
        "$signature open") return 1 ;;
        "$signature dismissed") return 0 ;;
      esac
      ;;
  esac
  seen=$(_fm_pending_reply_scan_dismissal "$parent_status" "$key") || return 1
  case "$seen" in
    open|dismissed) ;;
    *) return 1 ;;
  esac
  case "$signature" in
    missing|unreadable) ;;
    *) [ -z "${2:-}" ] || printf -v "$2" '%s' "$signature $seen" ;;
  esac
  [ "$seen" = dismissed ]
}

# JSON array of unresolved escalated records for bearings decisions_open.
# Prints [] when none are escalated. Does not wake or mutate.
fm_pending_reply_escalated_decisions_json() {  # <state-dir>
  local state=$1 dir rec corr task summary key item out=''
  dir=$(fm_pending_reply_dir "$state")
  [ -d "$dir" ] || { printf '[]'; return 0; }
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    case "$(basename "$rec")" in .*) continue ;; esac
    [ "$(fm_pending_reply_get "$rec" phase)" = escalated ] || continue
    fm_pending_reply_escalation_dismissed "$rec" && continue
    corr=$(fm_pending_reply_get "$rec" corr_id)
    task=$(fm_pending_reply_get "$rec" task_id)
    summary=$(fm_pending_reply_get "$rec" request_summary)
    [ -n "$corr" ] && [ -n "$task" ] || continue
    key=$(fm_pending_reply_escalation_key "$corr")
    item=$(jq -nc --arg id "$task" --arg key "$key" \
      --arg summary "pending-reply escalated: task=$task pending-reply-id=$corr request=$summary" \
      '{id:$id,key:$key,verb:"blocked",summary:$summary,owner:"(main)"}') || return 1
    if [ -n "$out" ]; then out="$out,$item"; else out=$item; fi
  done
  printf '[%s]' "$out"
}
