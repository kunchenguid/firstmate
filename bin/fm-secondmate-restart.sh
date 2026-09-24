#!/usr/bin/env bash
# Restart second mates onto the current instruction surface and launch-time
# wiring, persisting their open records first.
#
# Usage: fm-secondmate-restart.sh <secondmate-id>... [--help]
#
# This is the executable half of /updatefirstmate's reload step. A running agent
# holds AGENTS.md and every skill it has loaded frozen from launch, and no
# verified harness offers a reload, so a re-read steer cannot replace either -
# it appends a second copy of the mate's own job description with no defined
# precedence. Replacing the agent is the only mechanism that guarantees the new
# bytes are the ones read, and the only one that re-resolves the launch-time
# wiring - harness, model, effort, turn-end hooks, and every other flag a harness
# reads once at startup. That second half is why the update pass sends every live
# mate here, including one already on the target commit: launch-time wiring is
# not derivable from a git diff, so an unchanged tracked surface does not mean
# the running agent is already on the current behavior.
#
# The cost of that guarantee is the conversation, which is why this command runs
# in two phases and why the first one is a GATE, not a courtesy:
#
#   A. PERSIST. Every mate is asked, in one marked request, to durably record the
#      open work it holds only in conversation - a task for each unfiled open
#      record, including a captain call it formed but never registered, and a
#      status correction for each task whose recorded state is now stale. That is
#      the /stow skill's "Open-record persistence" contract and nothing else from
#      it: no memory, learnings, or captain-preference sweep, which would make
#      every instruction update cost far more than the reload it is paying for.
#      All requests go out before any restart, so a slow mate delays only its own
#      restart instead of serializing the fleet behind it.
#   B. RESTART. Only after that mate's own correlated terminal `done` answer
#      lands on the parent channel. Progress and terminal non-success replies do
#      not authorize replacement; a blocked, failed, or needs-decision answer
#      takes the ordinary nudge path. The exact request and correlated answer
#      become a content-addressed handoff delivered to the replacement. Its raw
#      copies remain until that agent confirms receipt and readiness to resume;
#      a failed or uncertain local or remote delivery retains the parent copy.
#      The gate is terminal success, never a wall clock, so a mate that is
#      mid-turn queues the request behind that turn; the bound below exists to
#      end the wait, not to authorize a restart. A timeout deliberately leaves
#      an unanswered or still-in-progress expectation open: it is a genuine
#      open loop owned by the ordinary pending-reply recovery ladder, not state
#      this restart pass may close.
#
# A mate whose persist answer is missing, still in progress, or non-successful,
# or whose runtime cannot prove a restart, gets the ordinary re-read nudge and is
# reported as a nudge, never as a clean reload. Once a relaunch is attempted,
# any failed or ambiguous result is reported as unknown rather than attributing
# it to either incarnation.
#
# Placement changes the transport and nothing else. A local mate is restarted
# with bin/fm-control.sh <id> relaunch; a remote mate is restarted by running THAT
# SAME command on its host over bin/fm-on.sh, through the host-local
# fm-remote-secondmate-control.sh relaunch verb. The restart decision, the
# profile, the request text, the bound, the failure vocabulary, and this report
# are all computed here in the primary and are identical for both.
#
# Nothing here forces, stashes, or discards anything. bin/fm-control.sh owns the
# restart transaction, its checkpoint, its journal, and its rollback; a refusal
# before the agent is stopped leaves the mate running exactly as it was.
#
# Restart candidacy itself belongs to bin/fm-update.sh, which knows which homes
# the update pass actually left on the target commit; this command re-checks
# capability on its own argv rather than trusting a caller's list.
#
# Environment knobs:
#   FM_SECONDMATE_PERSIST_WAIT  seconds to wait for one mate's persist answer (900)
#   FM_SECONDMATE_PERSIST_POLL  seconds between checks of that answer (5)
#
# Exit status: 0 every named mate restarted; 3 at least one was nudged or left
# unreached and every mate was still accounted for; 1 the input itself is
# unusable; 2 invalid use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,65{s/^# \{0,1\}//;p;}' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac

if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-secondmate-restart refuses to resolve second mates without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing; fm-secondmate-restart cannot resolve second mates for FM_HOME '$FM_HOME'" >&2; exit 1; }

# shellcheck source=bin/fm-secondmate-restart-lib.sh
. "$SCRIPT_DIR/fm-secondmate-restart-lib.sh"
# shellcheck source=bin/fm-secondmate-nudge-lib.sh
. "$SCRIPT_DIR/fm-secondmate-nudge-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

PERSIST_WAIT=${FM_SECONDMATE_PERSIST_WAIT:-900}
PERSIST_POLL=${FM_SECONDMATE_PERSIST_POLL:-5}
case "$PERSIST_WAIT" in ''|*[!0-9]*) echo "error: FM_SECONDMATE_PERSIST_WAIT must be a non-negative integer: $PERSIST_WAIT" >&2; exit 2 ;; esac
case "$PERSIST_POLL" in ''|*[!0-9]*|0) echo "error: FM_SECONDMATE_PERSIST_POLL must be a positive integer: $PERSIST_POLL" >&2; exit 2 ;; esac

IDS=()
for arg in "$@"; do
  case "$arg" in
    -*) echo "error: unexpected argument '$arg'" >&2; usage >&2; exit 2 ;;
  esac
  # /updatefirstmate's action line names each mate by its fm-<id> selector; the
  # bare id is equally acceptable so a hand-run stays natural.
  id=${arg#fm-}
  case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid second mate id: $arg" >&2; exit 2 ;; esac
  case " ${IDS[*]:-} " in
    *" $id "*) continue ;;
  esac
  IDS+=("$id")
done
[ "${#IDS[@]}" -gt 0 ] || { usage >&2; exit 2; }

# Per-mate pass state, kept as parallel indexed arrays so this stays bash-3.2
# safe. PLAN is the phase the mate reached: persist-sent, or fallback with the
# reason already decided.
PLAN=()
REASON=()
CORR=()
DEADLINE=()
PLACEMENT=()
HOST=()
HARNESS=()
MODEL=()
EFFORT=()
RESTART_PID=()
RESTART_RESULT=()

restarted_count=0
nudged_count=0
unreached_count=0

# The first line of a command's output that carries anything, flattened to one
# readable line with its "error: " prefix dropped. A refusal's own words are the
# most useful thing this report can carry, and its first line is often blank.
first_reported_line() {  # <text>
  printf '%s\n' "$1" | sed -n '/./{s/^error: //;s/[[:space:]]\{1,\}/ /g;p;q;}'
}

# Classify the latest correlated reply without allowing the generic pending-reply
# resolver to turn progress or failure into permission to replace the agent.
classify_persist_reply() {  # <array-index>
  local i=$1 corr rec status_file line latest='' verb
  PERSIST_REPLY_STATE=pending
  PERSIST_REPLY_VERB=
  PERSIST_REPLY_LINE=
  corr=${CORR[i]}
  rec=$(fm_pending_reply_path "$STATE" "$corr")
  status_file=$(fm_pending_reply_get "$rec" parent_status)
  [ -f "$status_file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    fm_pending_reply_line_resolves "$line" "$corr" || continue
    latest=$line
  done < "$status_file"
  [ -n "$latest" ] || return 0
  PERSIST_REPLY_LINE=$latest
  verb=$(status_line_verb "$latest")
  PERSIST_REPLY_VERB=$verb
  case "$verb" in
    done) PERSIST_REPLY_STATE=success ;;
    needs-decision|blocked|failed) PERSIST_REPLY_STATE=failure ;;
  esac
}

# Advance only a terminal persist result. A terminal non-success reply settles
# its own expectation but never authorizes replacement; progress keeps waiting.
restart_sha256_file() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

restart_file_link_count() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

write_context_handoff() {  # <array-index> <destination>
  local i=$1 id=${IDS[$1]} destination=$2 tmp latest_digest existing_digest links
  [ "$PERSIST_REPLY_STATE" = success ] && [ -n "$PERSIST_REPLY_LINE" ] \
    || return 1
  tmp=$(mktemp "$STATE/.$id.secondmate-restart.handoff.XXXXXX") || return 1
  if ! (umask 077; {
    printf '# Persisted context handoff for secondmate %s\n\n' "$id"
    printf 'correlation=%s\n\n' "${CORR[$i]}"
    printf '## Original persistence request\n\n%s\n\n' "$FM_SECONDMATE_PERSIST_REQUEST"
    printf '## Exact correlated terminal response\n\n%s\n' "$PERSIST_REPLY_LINE"
  } > "$tmp"); then
    rm -f -- "$tmp"
    return 1
  fi
  latest_digest=$(restart_sha256_file "$tmp") || { rm -f -- "$tmp"; return 1; }
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    [ -f "$destination" ] && [ ! -L "$destination" ] \
      || { rm -f -- "$tmp"; return 1; }
    links=$(restart_file_link_count "$destination") || { rm -f -- "$tmp"; return 1; }
    [ "$links" = 1 ] || { rm -f -- "$tmp"; return 1; }
    existing_digest=$(restart_sha256_file "$destination") || { rm -f -- "$tmp"; return 1; }
    if [ "$existing_digest" != "$latest_digest" ] || ! cmp -s "$tmp" "$destination"; then
      rm -f -- "$tmp"
      return 1
    fi
    rm -f -- "$tmp"
    return 0
  fi
  mv "$tmp" "$destination" || { rm -f -- "$tmp"; return 1; }
  return 0
}

advance_persist_reply() {  # <array-index>
  local i=$1 id rec status_file handoff
  id=${IDS[$i]}
  classify_persist_reply "$i"
  case "$PERSIST_REPLY_STATE" in
    success)
      handoff="$STATE/$id.secondmate-restart.handoff-${CORR[i]}"
      if ! write_context_handoff "$i" "$handoff"; then
        rec=$(fm_pending_reply_path "$STATE" "${CORR[i]}")
        status_file=$(fm_pending_reply_get "$rec" parent_status)
        fm_pending_reply_try_resolve "$STATE" "${CORR[i]}" "$status_file" >/dev/null 2>&1 || true
        report_unreached "$id" "its successful persistence response could not be retained as an integrity-checked handoff, so the live agent was not restarted"
        PLAN[i]='done'
        pending_count=$((pending_count - 1))
        return 0
      fi
      rec=$(fm_pending_reply_path "$STATE" "${CORR[i]}")
      status_file=$(fm_pending_reply_get "$rec" parent_status)
      fm_pending_reply_try_resolve "$STATE" "${CORR[i]}" "$status_file" || return 1
      pending_count=$((pending_count - 1))
      launch_restart "$i"
      return 0
      ;;
    failure)
      rec=$(fm_pending_reply_path "$STATE" "${CORR[i]}")
      status_file=$(fm_pending_reply_get "$rec" parent_status)
      fm_pending_reply_try_resolve "$STATE" "${CORR[i]}" "$status_file" >/dev/null 2>&1 || true
      fall_back_to_nudge "$id" \
        "its persistence reply reported $PERSIST_REPLY_VERB instead of done, so its conversation was not spent"
      PLAN[i]='done'
      pending_count=$((pending_count - 1))
      return 0
      ;;
  esac
  return 1
}

# Send the ordinary re-read steer to a mate this pass will not restart, and say
# plainly which it was. A nudge is a partial reload and is never reported as more.
fall_back_to_nudge() {  # <id> <reason>
  local id=$1 reason=$2 out
  if out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-send.sh" "$id" "$FM_SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
    nudged_count=$((nudged_count + 1))
    printf 'nudged: %s: %s\n' "$id" "$reason"
  else
    unreached_count=$((unreached_count + 1))
    printf 'unreached: %s: %s; the re-read message could not be delivered either: %s\n' \
      "$id" "$reason" "$(first_reported_line "$out")"
  fi
}

report_unreached() {  # <id> <reason>
  unreached_count=$((unreached_count + 1))
  printf 'unreached: %s: %s\n' "$1" "$2"
}

restart_mate() {  # <array-index>
  local i=$1 id restart_out restart_rc restart_reason ran_on handoff handoff_sha256
  id=${IDS[$i]}
  handoff="$STATE/$id.secondmate-restart.handoff-${CORR[i]}"
  [ -f "$handoff" ] && [ ! -L "$handoff" ] \
    || { report_unreached "$id" "the confirmed persistence answer has no safe retained context handoff; the live agent was not restarted"; return; }
  handoff_sha256=$(restart_sha256_file "$handoff") \
    || { report_unreached "$id" "the retained context handoff could not be hashed; the live agent was not restarted"; return; }
  if [ "${PLACEMENT[i]}" = remote ]; then
    restart_out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-on.sh" --stdin "$id" \
      fm-remote-secondmate-control.sh relaunch \
      "$id" "${HARNESS[i]}" "${MODEL[i]:-default}" "${EFFORT[i]:-default}" \
      "$handoff_sha256" < "$handoff" 2>&1)
    restart_rc=$?
  else
    restart_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-control.sh" "$id" relaunch \
      --handoff-file "$handoff" --handoff-sha256 "$handoff_sha256" 2>&1)
    restart_rc=$?
  fi
  if [ "$restart_rc" -eq 0 ]; then
    if ! rm -f -- "$handoff"; then
      report_unreached "$id" "the replacement confirmed safe resumption, but its superseded parent-side raw context could not be retired at $handoff"
      return
    fi
    ran_on=$(printf '%s\n' "$restart_out" | sed -n 's/^relaunched .* harness=\([^ ]*\).*/\1/p' | tail -1)
    [ -n "$ran_on" ] || ran_on=${HARNESS[i]}
    if [ "${PLACEMENT[i]}" = remote ]; then
      printf 'restarted: %s on %s (%s)\n' "$id" "${HOST[i]}" "$ran_on"
    else
      printf 'restarted: %s (%s)\n' "$id" "$ran_on"
    fi
    return
  fi

  restart_reason=$(first_reported_line "$restart_out")
  [ -n "$restart_reason" ] || restart_reason="the restart failed without a reported reason"
  report_unreached "$id" "the restart outcome is unknown: $restart_reason"
}

launch_restart() {  # <array-index>
  local i=$1 result tmp
  result="$RESULT_DIR/$i.result"
  tmp="$result.tmp"
  ( trap - EXIT; restart_mate "$i" > "$tmp"; mv -f "$tmp" "$result" ) &
  RESTART_PID[i]=$!
  RESTART_RESULT[i]=$result
  PLAN[i]=restarting
  restart_active_count=$((restart_active_count + 1))
}

harvest_restarts() {
  local i out worker_state
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" != restarting ]; then
      i=$((i + 1))
      continue
    fi
    if [ -f "${RESTART_RESULT[i]}" ]; then
      wait "${RESTART_PID[i]}" 2>/dev/null || true
      out=$(cat "${RESTART_RESULT[i]}")
    else
      if kill -0 "${RESTART_PID[i]}" 2>/dev/null; then
        worker_state=$(ps -p "${RESTART_PID[i]}" -o stat= 2>/dev/null || true)
        case "$worker_state" in
          Z*) ;;
          *)
            i=$((i + 1))
            continue
            ;;
        esac
      fi
      wait "${RESTART_PID[i]}" 2>/dev/null || true
      if [ -f "${RESTART_RESULT[i]}" ]; then
        out=$(cat "${RESTART_RESULT[i]}")
      else
        out="unreached: ${IDS[$i]}: the restart worker exited before publishing an outcome"
      fi
    fi
    printf '%s\n' "$out"
    case "$out" in
      restarted:*) restarted_count=$((restarted_count + 1)) ;;
      nudged:*) nudged_count=$((nudged_count + 1)) ;;
      *) unreached_count=$((unreached_count + 1)) ;;
    esac
    PLAN[i]="done"
    restart_active_count=$((restart_active_count - 1))
    i=$((i + 1))
  done
}

# --- phase A: persist ------------------------------------------------------
# Every request goes out before any restart, so the fleet persists concurrently
# and one busy mate delays only itself.

i=0
while [ "$i" -lt "${#IDS[@]}" ]; do
  id=${IDS[$i]}
  PLAN[i]="fallback"
  REASON[i]=""
  CORR[i]=""
  DEADLINE[i]=""
  PLACEMENT[i]=""
  HOST[i]=""
  HARNESS[i]=""
  MODEL[i]=""
  EFFORT[i]=""
  if ! fm_secondmate_restart_capable "$STATE/$id.meta"; then
    REASON[i]=$FM_SECONDMATE_RESTART_REASON
    i=$((i + 1))
    continue
  fi
  PLACEMENT[i]=$FM_SECONDMATE_RESTART_PLACEMENT
  HOST[i]=$FM_SECONDMATE_RESTART_HOST
  HARNESS[i]=$FM_SECONDMATE_RESTART_HARNESS
  if [ "${PLACEMENT[i]}" = remote ]; then
    # A local relaunch re-resolves this home's durable secondmate pin on its own,
    # which is the one owner of that resolution. A remote one cannot: it runs in
    # a home whose config/secondmate-harness is deliberately NOT inherited, so
    # the file on that host belongs to a different home and re-resolving there
    # would silently move the mate onto another runtime. Resolve the pin here and
    # pass it explicitly, so both placements land on the same decision.
    HARNESS[i]=$("$SCRIPT_DIR/fm-harness.sh" secondmate 2>/dev/null || true)
    [ -n "${HARNESS[i]}" ] || HARNESS[i]=$FM_SECONDMATE_RESTART_HARNESS
    MODEL[i]=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model 2>/dev/null || true)
    EFFORT[i]=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort 2>/dev/null || true)
    case "${EFFORT[i]}" in
      ''|low|medium|high|xhigh|max|ultra) ;;
      *) EFFORT[i]="" ;;
    esac
    if [ "${EFFORT[i]}" = ultra ] && ! "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "${HARNESS[i]}" "${MODEL[i]}" "${EFFORT[i]}"; then
      REASON[i]="the configured Ultra profile does not select native Codex through Pi"
      i=$((i + 1))
      continue
    fi
  fi

  if ! corr=$(fm_pending_reply_create "$FM_HOME" "$STATE" "$id" \
    "$FM_SECONDMATE_PERSIST_REQUEST"); then
    REASON[i]="its answer about the open work cannot be tracked, so a clean reload could not be proven"
    i=$((i + 1))
    continue
  fi
  if ! send_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    FM_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$SCRIPT_DIR/fm-send.sh" "$id" "$FM_SECONDMATE_PERSIST_REQUEST" 2>&1); then
    fm_pending_reply_discard_undelivered "$STATE" "$corr" >/dev/null 2>&1 || true
    REASON[i]="the request to write down its open work could not be delivered: $(first_reported_line "$send_out")"
    i=$((i + 1))
    continue
  fi
  CORR[i]=$corr
  DEADLINE[i]=$(($(date +%s) + PERSIST_WAIT))
  PLAN[i]="persisted-pending"
  i=$((i + 1))
done

# --- phase B: restart ------------------------------------------------------

RESULT_DIR=$(mktemp -d "$STATE/.secondmate-restart.XXXXXX") || {
  echo "error: could not create restart result directory under $STATE" >&2
  exit 1
}
trap 'rm -rf -- "$RESULT_DIR"' EXIT
pending_count=0
restart_active_count=0
i=0
while [ "$i" -lt "${#IDS[@]}" ]; do
  if [ "${PLAN[i]}" = persisted-pending ]; then
    pending_count=$((pending_count + 1))
  else
    fall_back_to_nudge "${IDS[$i]}" "${REASON[i]}"
    PLAN[i]="done"
  fi
  i=$((i + 1))
done

while [ "$((pending_count + restart_active_count))" -gt 0 ]; do
  now=$(date +%s)
  next_wait=$PERSIST_POLL
  # Resolve every arrived answer before processing any timeout. Delivery of a
  # later fleet request can outlast an earlier mate's deadline under load; that
  # expired mate must not hold an already-confirmed mate behind its fallback.
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    [ "${PLAN[i]}" != persisted-pending ] || advance_persist_reply "$i" || true
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" != persisted-pending ]; then
      i=$((i + 1))
      continue
    fi
    if [ "$now" -ge "${DEADLINE[i]}" ]; then
      # A reply can land after the fleet-wide resolution pass. Recheck at the
      # timeout decision so an answer already on disk wins over the fallback.
      if ! advance_persist_reply "$i"; then
        fall_back_to_nudge "${IDS[$i]}" \
          "it did not report terminal success within ${PERSIST_WAIT}s confirming its open work is written down, so its conversation was not spent"
        PLAN[i]="done"
        pending_count=$((pending_count - 1))
      fi
    else
      remaining=$((DEADLINE[i] - now))
      [ "$remaining" -ge "$next_wait" ] || next_wait=$remaining
    fi
    i=$((i + 1))
  done
  harvest_restarts
  [ "$((pending_count + restart_active_count))" -eq 0 ] || sleep "$next_wait"
done

# --- summary ---------------------------------------------------------------

printf 'summary: %d of %d restarted, %d nudged, %d unreached\n' \
  "$restarted_count" "${#IDS[@]}" "$nudged_count" "$unreached_count"
[ "$((nudged_count + unreached_count))" -eq 0 ] || exit 3
exit 0
