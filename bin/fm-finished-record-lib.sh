# shellcheck shell=bash
# fm-finished-record-lib.sh - give finished work a cleanup owner from disk.
#
# Sourced by bin/fm-watch.sh, which runs finished_records_review on every
# heartbeat in both postures, before its fleet-scan triage, so a finished
# record reaches someone who cleans it up without a supervisor noticing it.
# It relies on the libraries the watcher already sources (fm-wake-lib.sh,
# fm-classify-lib.sh, fm-pr-lib.sh, fm-backend.sh, fm-busy-lib.sh) and on the
# watcher's STATE, CONFIG, FM_HOME, and SCRIPT_DIR.
#
# A task record (state/<id>.meta; persistent secondmates never count) is
# FINISHED when one of these holds, each read from files plus at most one
# endpoint liveness read and no forge read:
#   merged     - its recorded pr= has the merge-notified record
#                (state/<id>.pr-poll-merge-notified) that every merge path
#                writes through bin/fm-merge-outcome-lib.sh - bin/fm-pr-merge.sh
#                and the watcher's merge poll alike - and that record is at
#                least FM_FINISHED_GRACE_SECS old;
#   dead       - its newest crew status line is done: or failed:, the status log
#                was last written at least FM_FINISHED_GRACE_SECS ago, and
#                fm_backend_agent_state (bin/fm-backend.sh) reads its endpoint
#                dead or missing;
#   unattended - its newest crew status line is done: or failed: and the status
#                log was last written at least FM_FINISHED_AGE_SECS ago.
# FM_FINISHED_GRACE_SECS (default 3600) leaves the ordinary merge and completion
# handling time to act first; FM_FINISHED_AGE_SECS (default 86400) bounds how
# long a finished record may sit with a live agent.
# The two terminal conditions skip a record whose merge poll is still armed
# (state/<id>.check.sh): that poll owns a PR awaiting merge, and a merge it sees
# becomes the merged condition. Every condition skips a lane parked on review
# or one with a pending merged-lane cleanup request (bin/fm-park.sh owns both),
# and a record whose latest status event is captain-held. A record with
# remote_host= is never probed for liveness, so only merged and unattended
# apply to it.
#
# Each finished record is handled once per fact. Its signature - the merged PR
# URL, or the terminal status line - is written to
# state/.finished-records-surfaced only after its action is durable, so a
# failure retries on the next heartbeat rather than going silent, and an
# unchanged fact never notifies or acts twice. A new terminal line or another
# merged PR is a new fact. Lines for records that no longer exist are pruned.
#
# The action is one of:
#   - opt-in automatic cleanup: a merged record in a home with config/auto-land,
#     or a finished record without pr= in a home with config/auto-clean-finished
#     whose endpoint reads dead or missing, or alive and idle, with no
#     unhandled steering message and no remote_host=, starts the detached
#     `bin/fm-park.sh land <id> --if-eligible --detach` that the merge poll
#     starts for merged lanes. Every bin/fm-teardown.sh gate applies unchanged,
#     teardown is never forced, and bin/fm-park.sh tick reports the outcome,
#     including a refusal, which is a finding and is never retried here.
#   - otherwise one durable `check: finished work:` wake row keyed
#     finished-<id> that names the record, why it counts as finished, and the
#     cleanup command.
#
# finished_records_review returns 0 when it queued at least one notification
# and sets FM_FINISHED_RECORDS_REASON to the joined reasons, 1 when it queued
# none, and 2 when a wake row could not be queued; the watcher exits on 2 like
# any other failed durable append.

finished_record_secs() {  # <value> <default>
  case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

# The signature already recorded for <id>, or nothing.
finished_record_prior() {  # <surfaced-file> <id>
  [ -f "$1" ] || return 0
  awk -F '\t' -v id="$2" '$1 == id { sig = substr($0, length(id) + 2) } END { if (sig != "") print sig }' "$1"
}

# 0 when the opt-in automatic cleanup may start for this finished record.
finished_record_auto_eligible() {  # <id> <condition> <pr> <agent-state>
  local id=$1 cond=$2 pr=$3 agent=$4 meta verdict
  meta="$STATE/$id.meta"
  if [ "$cond" = merged ]; then
    [ -e "$CONFIG/auto-land" ]
    return
  fi
  [ -z "$pr" ] && [ -e "$CONFIG/auto-clean-finished" ] || return 1
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 1
  if find "$STATE/$id.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | grep -q .; then
    return 1
  fi
  if [ -z "$agent" ]; then
    agent=$(fm_backend_agent_state "$(fm_backend_of_meta "$meta")" \
      "$(fm_backend_target_of_meta "$meta")" 2>/dev/null) || agent=unreadable
  fi
  case "$agent" in
    dead|missing) return 0 ;;
    alive) ;;
    *) return 1 ;;
  esac
  verdict=$(fm_busy_classify_meta "$meta" "$id" "$STATE" 2>/dev/null || true)
  case "$verdict" in idle\ *) return 0 ;; esac
  return 1
}

# Rewrites the surfaced-signature file as <kept> lines for records that still
# exist, with each <added> line replacing its record's earlier one. A failed
# write leaves the old file, so its records are handled again next heartbeat.
finished_records_record() {  # <surfaced-file> <kept-lines> <added-lines>
  local surfaced=$1 next tmp
  next=$(printf '%s' "$2" | FM_FINISHED_ADDED=$3 awk -F '\t' '
    BEGIN { n = split(ENVIRON["FM_FINISHED_ADDED"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") { split(a[i], f, "\t"); drop[f[1]] = 1 } }
    !($1 in drop) { print }')
  next="${next:+$next$'\n'}$3"
  if [ -z "$next" ]; then
    rm -f -- "$surfaced"
    return 0
  fi
  [ "$(cat "$surfaced" 2>/dev/null)"$'\n' != "$next" ] || return 0
  tmp=$(mktemp "$STATE/.finished-records-surfaced.XXXXXX") || return 1
  if ! { printf '%s' "$next" > "$tmp" && mv -f -- "$tmp" "$surfaced"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}

finished_records_review() {
  local surfaced grace age now meta id prior keep='' added=''
  local status last crew verb pr sig cond detail mtime elapsed agent reason auto_eligible
  # shellcheck disable=SC2034 # Read by bin/fm-watch.sh after this returns.
  FM_FINISHED_RECORDS_REASON=''
  surfaced="$STATE/.finished-records-surfaced"
  grace=$(finished_record_secs "${FM_FINISHED_GRACE_SECS-}" 3600)
  age=$(finished_record_secs "${FM_FINISHED_AGE_SECS-}" 86400)
  now=$(date +%s)
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    fm_pr_task_id_valid "$id" || continue
    [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
    prior=$(finished_record_prior "$surfaced" "$id")
    [ -z "$prior" ] || keep="$keep$id"$'\t'"$prior"$'\n'
    if [ -e "$STATE/$id.review-park" ] || [ -e "$STATE/$id.review-park-land" ]; then
      continue
    fi
    status="$STATE/$id.status"
    last=$(last_status_line "$status")
    ! status_is_captain_held "$last" || continue
    pr=$(fm_meta_get "$meta" pr)
    agent=''
    if [ -n "$pr" ] && fm_pr_url_parse "$pr" \
      && fm_pr_poll_merge_already_notified "$STATE" "$id" \
        "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"; then
      sig="merged $FM_PR_URL"
      mtime=$(_fm_status_file_mtime "$STATE/$id.pr-poll-merge-notified") || continue
      case "$mtime" in ''|*[!0-9]*) continue ;; esac
      [ $(( now - mtime )) -ge "$grace" ] || continue
      cond=merged
      detail="PR $FM_PR_URL is merged and its record is still present"
    else
      [ ! -e "$STATE/$id.check.sh" ] || continue
      crew=$(last_crew_status_line "$status")
      status_line_verb "$crew" verb
      case "$verb" in done|failed) ;; *) continue ;; esac
      sig="finished $(printf '%s' "$crew" | fm_wake_clean_field)"
      mtime=$(_fm_status_file_mtime "$status") || continue
      case "$mtime" in ''|*[!0-9]*) continue ;; esac
      elapsed=$(( now - mtime ))
      [ "$elapsed" -ge "$grace" ] || continue
      if [ "$elapsed" -ge "$age" ]; then
        cond=unattended
        detail="its last report is $verb: and has had no newer status for $(( elapsed / 3600 ))h"
      else
        [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
        agent=$(fm_backend_agent_state "$(fm_backend_of_meta "$meta")" \
          "$(fm_backend_target_of_meta "$meta")" 2>/dev/null) || agent=unreadable
        case "$agent" in dead|missing) ;; *) continue ;; esac
        cond=dead
        detail="its last report is $verb: and its agent is gone ($agent)"
      fi
    fi
    auto_eligible=0
    finished_record_auto_eligible "$id" "$cond" "$pr" "$agent" && auto_eligible=1
    if [ "$sig" = "$prior" ] && [ "$auto_eligible" != 1 ]; then
      continue
    fi
    if [ "$auto_eligible" = 1 ]; then
      if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
        "$SCRIPT_DIR/fm-park.sh" land "$id" --if-eligible --detach >/dev/null 2>&1; then
        triage_log "could not start automatic cleanup of finished record $id ($cond); retrying next heartbeat"
        continue
      fi
      triage_log "started automatic cleanup of finished record $id ($cond)"
    else
      reason="check: finished work: $id - $detail; clean up with bin/fm-teardown.sh $id, which refuses unlanded work"
      fm_wake_append check "finished-$id" "$reason" || return 2
      FM_FINISHED_RECORDS_REASON="${FM_FINISHED_RECORDS_REASON:+$FM_FINISHED_RECORDS_REASON; }${reason#check: }"
    fi
    added="$added$id"$'\t'"$sig"$'\n'
  done
  finished_records_record "$surfaced" "$keep" "$added"
  if [ -n "$FM_FINISHED_RECORDS_REASON" ]; then
    FM_FINISHED_RECORDS_REASON="check: $FM_FINISHED_RECORDS_REASON"
    return 0
  fi
  return 1
}
