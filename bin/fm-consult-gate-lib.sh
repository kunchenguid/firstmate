#!/usr/bin/env bash
# fm-consult-gate-lib.sh - the dispatch-time ChatGPT consultation gate: a ship
# or scout launch must carry a stored ChatGPT-generated prompt for the stage in
# play, or an explicit recorded waiver, so the captain's consultation flow can
# never be bypassed silently.
#
# Usage: . bin/fm-consult-gate-lib.sh
#        fm_consult_gate_check <data-dir> <task-id> <kind> <waiver-set:0|1> <waiver-reason>
#        fm_consult_gate_record_backlog <config-dir> <data-dir> <kind> <task-id> <reason>
#
# WHY. bin/fm-chatgpt-loop.sh records each ChatGPT answer under
# data/<task-id>/chatgpt-loop.json, but nothing in the launch path required one,
# so "the consultation is redundant here" stayed a judgment call at intake and
# the consultations simply stopped running. This gate moves that decision into
# the launch itself: a launch without its stored prompt stops, and every way
# past the gate leaves a reason in a durable record.
#
# CONTRACT (single owner of the gate's rules; docs/configuration.md "ChatGPT
# consultation channel" states the operator-facing summary, bin/fm-spawn.sh's
# header documents --consult-waived, and the chatgpt-consultation skill owns the
# agent-side procedure around it):
#   - Scope: kind ship and scout, fresh launches and relaunches alike. A
#     secondmate is a persistent home rather than a worker task and is not
#     gated; passing --consult-waived to one is refused rather than ignored.
#   - Stored prompt: data/<task-id>/chatgpt-loop.json must exist, parse as a
#     JSON object, and carry a non-empty (whitespace-only counts as empty)
#     prompt for the stage its phase puts in play, with a phase that proves this
#     round's consultation ran: audit_prompt at audit-dispatch or audit-worker,
#     plan at plan-dispatch, plan-worker, or complete. No other phase name is
#     required. A record whose phase names no stage, a record still waiting at
#     its consult phase, an unreadable record, and an empty stage prompt all
#     fail closed, so a prompt left over from a finished round can never satisfy
#     the gate - bin/fm-chatgpt-loop.sh's next-round clears those round-scoped
#     fields as well.
#   - No usable record: the bounded channel probe (bin/fm-chatgpt-bridge-lib.sh)
#     runs HERE and only here, so an ordinary launch pays no probe, and nothing
#     here starts, stops, or repairs the bridge. Every verdict refuses: a
#     `healthy` channel, a channel the probe reports unavailable - unreachable,
#     unhealthy, misconfigured, unconfigured - and a probe that cannot run. The
#     refusal prints the exact record path, the bin/fm-chatgpt-loop.sh init and
#     consult commands that create the prompt, the probe verdict that names the
#     real cause, and the --consult-waived <reason> command, so an unavailable
#     channel is a refusal with a named cause rather than a pass. The explicit
#     waiver below is the only way past the gate.
#   - Explicit waiver: --consult-waived <reason>. An empty or whitespace-only
#     reason is refused, and so is a multi-line reason, which could not be
#     recorded safely in a one-value-per-line task record. A supplied reason
#     proceeds, and the caller MUST then record it in state/<id>.meta (fm-spawn
#     writes consult_waived=) and in the task's backlog note through
#     fm_consult_gate_record_backlog, which refuses the launch when this home's
#     backlog contract applies and the note cannot be written.
#   - The loop's own dispatch: bin/fm-chatgpt-loop.sh marks the spawn it makes
#     with FM_CHATGPT_LOOP_DISPATCH_TASK=<loop task id>. A launch task with NO
#     record of its own then satisfies the gate when that loop record sits at
#     its <stage>-dispatch phase with that stage's prompt non-empty - the
#     consultation the loop already ran and is about to hand over. The marker
#     alone proves nothing: without such a record the launch is still refused.
#   - A loop-dispatched worker: a launch task with NO record of its own also
#     satisfies the gate when this home holds a readable loop record whose
#     worker_task is exactly that task id and whose phase is <stage>-worker,
#     the phase the loop enters once dispatch delivered the stage prompt. This
#     is what lets an ordinary relaunch recover a worker the loop already
#     consulted without an ad-hoc waiver. No other phase proves delivery, and a
#     record naming a different task proves nothing.
#
# fm_consult_gate_check returns 0 to proceed and 1 to refuse, printing its full
# diagnostic on stderr. On a proceeding launch, FM_CONSULT_GATE_WAIVER_REASON
# holds the reason the caller must record (empty when nothing was waived).
# fm_consult_gate_record_backlog returns 0 when the reason is recorded, or 0
# with a notice when this home keeps no backlog note to record it in, and 1
# with FM_CONSULT_GATE_RECORD_ERROR when an applicable note could not be written.

# shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
FM_CONSULT_GATE_WAIVER_REASON=
FM_CONSULT_GATE_RECORD_ERROR=

FM_CONSULT_GATE_LIBDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-chatgpt-bridge-lib.sh
. "$FM_CONSULT_GATE_LIBDIR/fm-chatgpt-bridge-lib.sh"
unset FM_CONSULT_GATE_LIBDIR

# fm_consult_gate_record_path <data-dir> <task-id>
# Prints this task's consultation record path: the artifact the gate requires.
fm_consult_gate_record_path() {
  printf '%s/%s/chatgpt-loop.json\n' "$1" "$2"
}

# fm_consult_gate_record_verdict <record-file>
# Prints one line classifying the record against the gate:
#   ok <stage>              the phase proves this round's consultation ran and
#                           the stage prompt is non-empty
#   missing                 no record exists at that path
#   unreadable <detail>     the record cannot be read as a JSON object
#   no-stage <phase>        the record's phase names no stage in play
#   consult-pending <stage> the record waits at this round's <stage>-consult,
#                           so no current-round prompt exists yet
#   no-prompt <stage>       the stage in play has an empty or blank prompt
fm_consult_gate_record_verdict() {
  local file=$1 phase prompt stage field
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf 'missing\n'
    return 0
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'unreadable it is not a readable regular file\n'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'unreadable jq is needed to read it and is not installed\n'
    return 0
  fi
  if ! phase=$(jq -r '.phase // "" | if type == "string" then . else "" end' "$file" 2>/dev/null); then
    printf 'unreadable it does not parse as JSON\n'
    return 0
  fi
  case "$phase" in
  audit-dispatch | audit-worker)
    stage=audit
    field=audit_prompt
    ;;
  plan-dispatch | plan-worker | complete)
    stage=plan
    field=plan
    ;;
  audit-consult | plan-consult)
    printf 'consult-pending %s\n' "${phase%-consult}"
    return 0
    ;;
  *)
    printf 'no-stage %s\n' "${phase:-<none>}"
    return 0
    ;;
  esac
  if ! prompt=$(jq -r --arg f "$field" 'if ((.[$f] // null) | type) == "string" then .[$f] else "" end' "$file" 2>/dev/null); then
    printf 'unreadable it does not parse as JSON\n'
    return 0
  fi
  if [ -z "$(printf '%s' "$prompt" | tr -d '[:space:]')" ]; then
    printf 'no-prompt %s\n' "$stage"
    return 0
  fi
  printf 'ok %s\n' "$stage"
}

# fm_consult_gate_loop_dispatch_valid <data-dir> <loop-task-id>
# True only for a loop record sitting at its dispatch phase with a non-empty
# stage prompt: a consultation that already happened and is waiting to hand its
# prompt to the worker this launch is starting.
fm_consult_gate_loop_dispatch_valid() {
  local file verdict phase
  file=$(fm_consult_gate_record_path "$1" "$2")
  verdict=$(fm_consult_gate_record_verdict "$file")
  case "$verdict" in
  ok\ *) ;;
  *) return 1 ;;
  esac
  phase=$(jq -r '.phase // ""' "$file" 2>/dev/null) || return 1
  case "$phase" in
  audit-dispatch | plan-dispatch) return 0 ;;
  esac
  return 1
}

# fm_consult_gate_loop_worker_valid <data-dir> <worker-task-id>
# True when this home holds a readable loop record that names <worker-task-id>
# as the worker its dispatch delivered the stage prompt to, at the phase the
# loop enters once that handoff ran. That record is the recoverable
# consultation behind an ordinary relaunch of a loop-dispatched worker.
fm_consult_gate_loop_worker_valid() {
  local data=$1 worker=$2 file verdict phase recorded
  for file in "$data"/*/chatgpt-loop.json; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    verdict=$(fm_consult_gate_record_verdict "$file")
    case "$verdict" in
    ok\ *) ;;
    *) continue ;;
    esac
    phase=$(jq -r '.phase // ""' "$file" 2>/dev/null) || continue
    case "$phase" in
    audit-worker | plan-worker) ;;
    *) continue ;;
    esac
    recorded=$(jq -r '.worker_task // ""' "$file" 2>/dev/null) || continue
    [ "$recorded" = "$worker" ] || continue
    return 0
  done
  return 1
}

# fm_consult_gate_refuse <task> <record-path> <detail> <stage-hint> <channel-line>
# The one refusal text: the exact artifact, the exact commands that create it,
# and the waiver that makes an exception possible without hiding it.
fm_consult_gate_refuse() {
  local task=$1 record=$2 detail=$3 stage=$4 channel=$5
  {
    printf 'error: task %s cannot launch without its stored ChatGPT-generated prompt\n' "$task"
    printf '  %s\n' "$record"
    printf '  %s\n' "$detail"
    printf '  consultation channel: %s\n' "$channel"
    printf 'Create the prompt before launching:\n'
    printf '  bin/fm-chatgpt-loop.sh init --task %s --objective-file <objective-file>\n' "$task"
    printf '  bin/fm-chatgpt-loop.sh consult --stage %s --task %s\n' "$stage" "$task"
    printf 'To launch anyway, pass an explicit waiver whose reason is recorded in the task record and the backlog note: --consult-waived <reason>\n'
  } >&2
}

# fm_consult_gate_check <data-dir> <task-id> <kind> <waiver-set:0|1> <waiver-reason>
# Returns 0 to proceed, 1 to refuse with a diagnostic on stderr. See the header
# for the full contract.
fm_consult_gate_check() {
  local data=$1 task=$2 kind=$3 waiver_set=$4 waiver_reason=$5
  local record verdict detail stage_hint probe_out probe_rc
  FM_CONSULT_GATE_WAIVER_REASON=

  case "$kind" in
  ship | scout) ;;
  *)
    if [ "$waiver_set" = 1 ]; then
      printf 'error: task %s is a %s launch, which the consultation gate does not cover; --consult-waived applies to ship and scout launches only\n' "$task" "$kind" >&2
      return 1
    fi
    return 0
    ;;
  esac

  if [ "$waiver_set" = 1 ]; then
    case "$waiver_reason" in
    *[![:space:]]*) ;;
    *)
      printf 'error: task %s may not launch under a waiver with no reason; --consult-waived needs a non-empty reason so the bypass is never unexplained\n' "$task" >&2
      return 1
      ;;
    esac
    case "$waiver_reason" in
    *$'\n'* | *$'\r'*)
      printf 'error: the --consult-waived reason for task %s spans more than one line, and a task record holds one value per line; give a single-line reason\n' "$task" >&2
      return 1
      ;;
    esac
    FM_CONSULT_GATE_WAIVER_REASON=$waiver_reason
    return 0
  fi

  record=$(fm_consult_gate_record_path "$data" "$task")
  verdict=$(fm_consult_gate_record_verdict "$record")
  case "$verdict" in
  ok\ *) return 0 ;;
  esac
  # A worker task the consultation loop dispatched has no record of its own:
  # the loop's record is the consultation this launch delivers.
  if [ "$verdict" = missing ] && [ -n "${FM_CHATGPT_LOOP_DISPATCH_TASK:-}" ] &&
    fm_consult_gate_loop_dispatch_valid "$data" "$FM_CHATGPT_LOOP_DISPATCH_TASK"; then
    return 0
  fi
  # A loop-dispatched worker recovered by an ordinary relaunch carries no marker
  # and no record of its own; the loop record that delivered its stage prompt is
  # the consultation that already ran.
  if [ "$verdict" = missing ] && fm_consult_gate_loop_worker_valid "$data" "$task"; then
    return 0
  fi

  stage_hint='audit|plan'
  case "$verdict" in
  missing)
    detail='no consultation record exists there'
    ;;
  consult-pending\ *)
    stage_hint=${verdict#consult-pending }
    detail="its ${verdict#consult-pending } stage is waiting on this round's consultation, so no current prompt exists"
    ;;
  no-stage\ *)
    detail="its phase '${verdict#no-stage }' names no stage in play"
    ;;
  no-prompt\ *)
    stage_hint=${verdict#no-prompt }
    detail="its ${verdict#no-prompt } stage in play holds no non-empty stored prompt"
    ;;
  unreadable\ *)
    detail="the record is unusable: ${verdict#unreadable }"
    ;;
  *)
    detail=$verdict
    ;;
  esac

  # The probe runs only on this refusal path, so a launch whose record exists
  # never contacts the channel.
  if probe_out=$(fm_chatgpt_bridge_health 2>&1); then
    probe_rc=0
  else
    probe_rc=$?
  fi
  probe_out=$(printf '%s' "$probe_out" | sed -n '1p')
  if [ -z "$probe_out" ]; then
    probe_out='the health probe returned no verdict'
  fi
  # A probe that cannot run leaves availability unverified, and unverified is
  # not the same as unavailable: it refuses too.
  if [ "$probe_rc" -eq 2 ]; then
    fm_consult_gate_refuse "$task" "$record" "$detail" "$stage_hint" "availability could not be verified ($probe_out)"
    return 1
  fi
  # Every verdict refuses. The probe only names the real cause inside the
  # refusal text: a healthy channel, a channel the probe reports unavailable,
  # and a probe whose verdict cannot be read are all refusals, and the explicit
  # --consult-waived reason above is the only way past the gate.
  case "$probe_out" in
  healthy*)
    fm_consult_gate_refuse "$task" "$record" "$detail" "$stage_hint" "$probe_out"
    ;;
  unreachable* | unhealthy* | misconfigured* | unconfigured*)
    fm_consult_gate_refuse "$task" "$record" "$detail" "$stage_hint" "the consultation channel is unavailable: $probe_out"
    ;;
  *)
    fm_consult_gate_refuse "$task" "$record" "$detail" "$stage_hint" "availability could not be verified ($probe_out)"
    ;;
  esac
  return 1
}

# fm_consult_gate_record_backlog <config-dir> <data-dir> <kind> <task-id> <reason>
# Appends the waiver to this home's backlog note for the task. Recording is
# required exactly where the home's backlog contract applies (bin/fm-backlog-
# transition-lib.sh's fm_backlog_transition_applies is that single gate); a home
# that keeps no backlog note has nowhere to record it, says so, and still
# carries the reason in state/<id>.meta. Returns 1 with
# FM_CONSULT_GATE_RECORD_ERROR when an applicable note could not be written.
fm_consult_gate_record_backlog() {
  local config=$1 data=$2 kind=$3 id=$4 reason=$5
  local applies=0 resolved out command_status body line new_body tmp
  FM_CONSULT_GATE_RECORD_ERROR=

  if ! declare -F fm_backlog_transition_applies >/dev/null 2>&1; then
    FM_CONSULT_GATE_RECORD_ERROR='bin/fm-backlog-transition-lib.sh is not loaded by this caller'
    return 1
  fi
  fm_backlog_transition_applies "$config" "$data" "$kind" || applies=$?
  if [ "$applies" -eq 1 ]; then
    printf 'notice: task %s consultation waiver is recorded in its task record; this home keeps no backlog note for it (%s)\n' \
      "$id" "${FM_BACKLOG_TRANSITION_SKIP:-no backlog applies}" >&2
    return 0
  fi
  if [ "$applies" -ne 0 ]; then
    FM_CONSULT_GATE_RECORD_ERROR=${FM_BACKLOG_TRANSITION_ERROR:-the backlog could not be read}
    return 1
  fi
  if ! resolved=$(fm_backlog_data_absolute "$data"); then
    FM_CONSULT_GATE_RECORD_ERROR="the data directory cannot be resolved: $data"
    return 1
  fi
  if ! fm_backlog_row_probe "$resolved" "$id"; then
    if [ "${FM_BACKLOG_ROW_RESULT:-}" = not_found ]; then
      FM_CONSULT_GATE_RECORD_ERROR="task $id has no backlog item in this home to record the waiver in"
    else
      FM_CONSULT_GATE_RECORD_ERROR=${FM_BACKLOG_ROW_ERROR:-the backlog item could not be read}
    fi
    return 1
  fi

  command_status=0
  out=$(fm_backlog_row_show "$resolved" "$id" --full) || command_status=$?
  # shellcheck disable=SC2034 # Output latch of bin/fm-backlog-transition-lib.sh.
  [ "$command_status" -ne 124 ] || FM_BACKLOG_ROW_SHOW_WEDGED=1
  if [ "$command_status" -ne 0 ]; then
    FM_CONSULT_GATE_RECORD_ERROR=$(printf '%s\n' "$out" | sed -n '1p')
    [ -n "$FM_CONSULT_GATE_RECORD_ERROR" ] ||
      FM_CONSULT_GATE_RECORD_ERROR="the backlog item $id could not be read"
    return "$command_status"
  fi
  # The body reaches this reader as one YAML double-quoted line; the single
  # owner of that decode is bin/fm-backlog-transition-lib.sh's
  # fm_backlog_row_body_decode, so a non-ASCII body can never decode differently
  # on the two paths that rewrite it.
  if ! body=$(fm_backlog_row_body_decode "$out"); then
    FM_CONSULT_GATE_RECORD_ERROR="the stored body of $id could not be decoded"
    return 1
  fi
  line="ChatGPT consultation gate waived: $reason"
  case $'\n'"$body"$'\n' in
  *$'\n'"$line"$'\n'*) return 0 ;;
  esac
  new_body=$line
  [ -z "$body" ] || new_body=$(printf '%s\n\n%s' "$body" "$line")
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-consult-gate-body.XXXXXX") || {
    FM_CONSULT_GATE_RECORD_ERROR="the waiver note for $id could not be staged"
    return 1
  }
  if ! printf '%s\n' "$new_body" >"$tmp"; then
    rm -f -- "$tmp"
    FM_CONSULT_GATE_RECORD_ERROR="the waiver note for $id could not be staged"
    return 1
  fi
  if ! fm_backlog_mutate "$data" update "$id" --body-file "$tmp"; then
    rm -f -- "$tmp"
    FM_CONSULT_GATE_RECORD_ERROR=${FM_BACKLOG_TRANSITION_ERROR:-the backlog note for $id could not be updated}
    return 1
  fi
  rm -f -- "$tmp"
  return 0
}
