#!/usr/bin/env bash
# fm-seat-state-advise.sh - advise whether a seat whose endpoint probe came back
# inconclusive is waiting on something or genuinely wedged.
#
# Usage:
#   fm-seat-state-advise.sh <seat-id>
#   fm-seat-state-advise.sh --help
#
# The gap this closes: the deterministic signals are each individually correct
# and jointly inconclusive. A recorded state can read done while the pane reads
# working and unhandled inbox messages suggest a failed steer, and the seat is in
# fact reading those messages and working. That is a semantic judgment over
# several weak signals, which is what this family exists for.
#
# ADVISORY ONLY, AND IT CAN NEVER AUTHORIZE A RELAUNCH. This tool has no
# authority over recovery and holds no lever that touches a seat. Only a probe
# state of dead or missing authorizes a relaunch, and this tool never produces
# one: its answers are `pipeline_wait`, `true_wedge`, and `healthy_idle`. A
# `true_wedge` answer is evidence for a human or for an escalation, never
# permission to replace an agent, because acting on a semantic guess about an
# endpoint that could not be classified is how unlanded work gets destroyed.
#
# DETERMINISTIC FIRST. A probe that answers alive, dead, or missing is already
# conclusive and is reported as-is with no network call. Only ambiguous,
# unreadable, and unverified reach the model.
#
# FAIL-OPEN TOWARD WAITING. Every failure answers `healthy_idle`, because a
# false wedge verdict invites disturbing a seat that is working, while a delayed
# wedge verdict costs only time: the deterministic rail keeps running
# independently, and a genuinely dead seat still trips the hard signals and is
# reported regardless of what this tool said.
#
# WHAT IT SENDS. Structured signals only: the probe's own state and fixed reason
# phrase, the busy-state word, the leading verb of the last status line, and the
# ages of the turn-end, activity, and status records. No pane text, no status
# line beyond that one verb, no brief, no message content ever leaves this host,
# so an inconclusive seat cannot leak what it was working on.
#
# Output (stdout, a TOON-style block), always exit 0:
#   seat-state-advise:
#     status: clear | ambiguous | unavailable
#     advice: pipeline_wait | true_wedge | healthy_idle
#     probe: <the deterministic state>
#     source: deterministic | model | fail-open
#     confidence/probabilities/latency_ms   when the model was consulted
#     authority: advisory only; never authorizes a relaunch
# Exit 2 only for a usage error.
#
# Opt-in: TYPESAFE_API_KEY in the environment, else a TYPESAFE_API_KEY= line in
# $FM_HOME/.env. bin/fm-jev-lib.sh owns the family's shared shape.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"
# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"

TOOL=seat-state-advise
NOW=$(date +%s)

usage() {
  cat <<'USAGE'
fm-seat-state-advise.sh - is an inconclusive seat waiting, or wedged?

  fm-seat-state-advise.sh <seat-id>

Reports a conclusive probe as-is with no network call, and asks Jev only about an
ambiguous, unreadable, or unverified endpoint. Advisory only: it never authorizes
a relaunch, and every failure answers healthy_idle. Always exits 0 except on a
usage error. docs/configuration.md "Seat state advice" owns the contract.
USAGE
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
esac
SEAT=${1:-}
fm_pr_task_id_valid "$SEAT" || { printf 'error: fm-seat-state-advise.sh needs a seat id\n' >&2; exit 2; }
META="$STATE/$SEAT.meta"
[ -f "$META" ] || { printf 'error: no record for seat %s in this home\n' "$SEAT" >&2; exit 2; }

emit() {  # <status> <advice> <probe> <source> [extra...]
  local status=$1 advice=$2 probe=$3 source=$4
  shift 4
  printf '%s:\n  status: %s\n  advice: %s\n  probe: %s\n  source: %s\n' \
    "$TOOL" "$status" "$advice" "$probe" "$source"
  while [ "$#" -gt 0 ]; do printf '  %s\n' "$1"; shift; done
  printf '  authority: advisory only; never authorizes a relaunch\n'
}

age_of() {  # <file>
  local m
  if command -v gstat >/dev/null 2>&1; then m=$(gstat -c %Y "$1" 2>/dev/null)
  else m=$(stat -c %Y "$1" 2>/dev/null || /usr/bin/stat -f %m "$1" 2>/dev/null); fi
  case "${m:-}" in ''|*[!0-9]*) printf -- 'null' ;; *) printf '%s' "$(( NOW - m ))" ;; esac
}

fm_secondmate_liveness_probe "$META" "$SEAT" poll
PROBE=${FM_SM_LIVE_STATE:-unknown}

# A conclusive probe needs no second opinion, and asking for one would invite
# overriding an answer that is already authoritative.
case "$FM_SM_LIVE_STATUS" in
  alive)
    fm_jev_telemetry "$STATE" "$TOOL" status=clear source=deterministic probe=alive
    emit clear healthy_idle "$PROBE" deterministic
    exit 0
    ;;
  relaunchable)
    fm_jev_telemetry "$STATE" "$TOOL" status=clear source=deterministic probe="$PROBE"
    emit clear true_wedge "$PROBE" deterministic \
      'note: the deterministic probe already proves no agent is running, so recovery needs no advice from this tool'
    exit 0
    ;;
  silent)
    fm_jev_telemetry "$STATE" "$TOOL" status=clear source=deterministic probe=silent
    emit clear healthy_idle silent deterministic \
      'note: the record names no endpoint, which provisioning owns rather than liveness'
    exit 0
    ;;
esac

# Only the three documented inconclusive states are a question worth asking. A
# probe that never ran, or answered with a word this tool does not classify,
# takes the fail-open path with no network call, because guessing about an
# endpoint the probe never read is how a working seat gets called wedged.
case "$PROBE" in
  ambiguous|unreadable|unverified) ;;
  *)
    fm_jev_telemetry "$STATE" "$TOOL" status=unavailable source=fail-open probe="$PROBE" reason=probe_not_inconclusive
    emit unavailable healthy_idle "$PROBE" fail-open \
      "reason: ${FM_SM_LIVE_REASON:-the endpoint probe produced no inconclusive state}, so the seat is left alone rather than guessed at"
    exit 0
    ;;
esac

if ! fm_jev_key_resolve "$FM_HOME"; then
  echo "$TOOL: off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env)" >&2
  fm_jev_telemetry "$STATE" "$TOOL" status=unavailable source=fail-open probe="$PROBE" reason=off
  emit unavailable healthy_idle "$PROBE" fail-open \
    'reason: the model half is off, and an unclassifiable endpoint is left alone rather than guessed at'
  exit 0
fi

# Structured signals only. Nothing here is free text the seat produced, so an
# inconclusive seat cannot leak its work through this request.
BUSY=$(sed -n '1p' "$STATE/$SEAT.busy-state" 2>/dev/null | tr -cd 'A-Za-z0-9_-')
STATUS_VERB=$(sed -n '$p' "$STATE/$SEAT.status" 2>/dev/null | sed -n 's/^\([a-z-]\{1,\}\).*/\1/p')
STATE_JSON=$(jq -n \
  --arg probe "$PROBE" --arg reason "${FM_SM_LIVE_REASON:-}" \
  --arg busy "${BUSY:-unknown}" --arg verb "${STATUS_VERB:-none}" \
  --arg turn "$(age_of "$STATE/$SEAT.turn-ended")" \
  --arg act "$(age_of "$STATE/$SEAT.progress")" \
  --arg st "$(age_of "$STATE/$SEAT.status")" '
  {seat: {endpoint_probe: $probe, probe_reason: $reason, busy_state: $busy,
          last_status_verb: $verb,
          turn_ended_age_s: (try ($turn | tonumber) catch null),
          activity_age_s: (try ($act | tonumber) catch null),
          status_age_s: (try ($st | tonumber) catch null)}}' 2>/dev/null) || STATE_JSON=

CRITERIA='{
  "pipeline_wait": "The seat is blocked waiting on something outside itself that is expected to finish, such as a validation run, a build, or a remote call. Work is in progress and nobody needs to intervene yet.",
  "true_wedge": "The seat has stopped making progress and will not resume on its own. It needs a person or a supervisor to act.",
  "healthy_idle": "The seat has nothing to do and is correctly waiting for work. An idle seat is healthy."
}'

if [ -z "$STATE_JSON" ] || ! fm_jev_ask seat_state "$STATE_JSON" "$CRITERIA" \
  'Read the seat signals and choose the ONE description that best fits them. Every field is a deterministic signal recorded by the supervisor, and the endpoint probe could not be classified, which is why you are being asked.'; then
  fm_jev_telemetry "$STATE" "$TOOL" status=unavailable source=fail-open probe="$PROBE" \
    "reason=$(printf '%s' "${FM_JEV_REASON:-request_build}" | tr ' ' '_')"
  emit unavailable healthy_idle "$PROBE" fail-open \
    "reason: ${FM_JEV_REASON:-could not build the request}, so the seat is left alone" \
    "latency_ms: ${FM_JEV_LATENCY_MS:-null}"
  exit 0
fi

fm_jev_calibration "$STATE" "$TOOL" "$(jq -n \
  --arg probe "$PROBE" --arg choice "$FM_JEV_CHOICE" --arg conf "$FM_JEV_CONFIDENCE" \
  --arg probs "$FM_JEV_PROBS" --arg at "$NOW" \
  '{at: ($at | tonumber), deterministic: $probe, choice: $choice,
    confidence: ($conf | tonumber), probabilities: $probs}' 2>/dev/null)"

if fm_jev_clears_floor "$FM_JEV_CONFIDENCE"; then
  fm_jev_telemetry "$STATE" "$TOOL" status=clear source=model probe="$PROBE" \
    advice="$FM_JEV_CHOICE" cleared_floor=yes
  emit clear "$FM_JEV_CHOICE" "$PROBE" model \
    "confidence: $FM_JEV_CONFIDENCE" "probabilities: $FM_JEV_PROBS" \
    "latency_ms: $FM_JEV_LATENCY_MS" "tokens: $FM_JEV_TOKENS"
  exit 0
fi

# Under the floor the answer is not trusted, and the fail-open direction applies
# rather than the model's ranking, because a weak wedge verdict is exactly the
# one that would invite disturbing a working seat.
fm_jev_telemetry "$STATE" "$TOOL" status=ambiguous source=model probe="$PROBE" cleared_floor=no
emit ambiguous healthy_idle "$PROBE" fail-open \
  "reason: the best answer scored $FM_JEV_CONFIDENCE, under the $FM_JEV_CONFIDENCE_FLOOR floor, so the seat is left alone" \
  "best: $FM_JEV_CHOICE" "probabilities: $FM_JEV_PROBS" "latency_ms: $FM_JEV_LATENCY_MS"
exit 0
