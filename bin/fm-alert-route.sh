#!/usr/bin/env bash
# fm-alert-route.sh - name the seat charter that owns an alert, so an alert with
# no obvious owner is routed instead of going unattended.
#
# Usage:
#   fm-alert-route.sh <alert-name> [<alert-text>]
#   fm-alert-route.sh --help
#
# The gap this closes: monitoring rails whose names map to no charter at all are
# never routed to anyone. Nothing is broken and nothing reports it, because every
# existing signal measures whether the alert fired, not whether it reached a
# seat. An alert nobody owns is indistinguishable from an alert nobody needed.
#
# DETERMINISTIC FIRST, ALWAYS. The alert's name is matched against the seat
# registry in data/secondmates.md before anything else: first for a seat whose
# id equals the alert name, then for an alert namespaced under a seat id (as
# `gpu-ops.thermal` under `gpu-ops`), then against each seat's scope text by
# exact token, longest prefix first, so `gpu.repo_drift` is placed by the seat
# whose scope names `gpu.` without any model involved. Only an alert that exact
# matching could not place is shown to Jev, and only as a choice among those
# same registered charters. The model never re-decides a name that matched.
#
# FAIL-OPEN MEANS TOWARD PAGING, NEVER TOWARD SILENCE. In alert context the safe
# default is that a human hears about it. So every failure and every untrusted
# answer names the fallback owner rather than dropping the alert: a missing key,
# a missing charter registry, or a registry with no charters ends at
# `status: escalate` with the model never consulted; a request that cannot be
# built or a model answer that cannot be reached or parsed ends at
# `status: unavailable`; and an answer below the confidence floor ends at
# `status: ambiguous`, answered without confidence and carrying its ranking as
# evidence instead of routing on a guess. Unowned never means unattended, and
# there is no path through this tool that drops an alert.
#
# Output (stdout, a TOON-style block), always exit 0:
#   alert-route:
#     status: clear | ambiguous | escalate | unavailable
#     owner: <seat>            the charter to route it to
#     source: exact | model | fallback
#     confidence/probabilities/latency_ms   when the model was consulted
#     reason: <why the status is not clear>
# Exit 2 only for a usage error, which is actionable rather than routed around.
#
# Opt-in: TYPESAFE_API_KEY in the environment, else a TYPESAFE_API_KEY= line in
# $FM_HOME/.env. Absent in both, the deterministic layer still runs and still
# routes or escalates; only the model half is off. bin/fm-jev-lib.sh owns the
# family's shared shape and names every member.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REGISTRY="$DATA/secondmates.md"
FALLBACK=captain

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

TOOL=alert-route

usage() {
  cat <<'USAGE'
fm-alert-route.sh - name the seat charter that owns an alert.

  fm-alert-route.sh <alert-name> [<alert-text>]

Matches the alert name against the registered seats first by id and then by
scope claim, and asks Jev only about a name exact matching cannot place. Every
failure escalates to the fallback owner rather than dropping the alert. Always
exits 0 except on a usage error. docs/configuration.md "Alert ownership
routing" owns the contract.
USAGE
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  '') printf 'error: fm-alert-route.sh needs an alert name\n' >&2; exit 2 ;;
esac

ALERT=$1
TEXT=${2:-}
case "$ALERT" in
  *[!A-Za-z0-9._:-]*|'') printf 'error: alert name has characters an alert name does not carry\n' >&2; exit 2 ;;
esac

emit() {  # <status> <owner> <source> <reason> [extra-line...]
  local status=$1 owner=$2 source=$3 reason=$4
  shift 4
  printf '%s:\n  status: %s\n  owner: %s\n  source: %s\n' "$TOOL" "$status" "$owner" "$source"
  while [ "$#" -gt 0 ]; do printf '  %s\n' "$1"; shift; done
  [ -z "$reason" ] || printf '  reason: %s\n' "$reason"
}

# --- the deterministic layer -------------------------------------------------
#
# One row per registered seat: "<seat>\t<scope text>". The registry line grammar
# belongs to bin/fm-secondmate-registry-lib.sh, the parser every other consumer
# of data/secondmates.md uses, so this tool reads the same fields they read. A
# line that parser rejects is skipped as a candidate while routing continues:
# a malformed line is a missing charter, never a reason to drop an alert.
seats() {
  local line
  [ -f "$REGISTRY" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    printf '%s\t%s\n' "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_SCOPE"
  done < "$REGISTRY"
}

# exact_owner: the ONE seat this alert name names outright, or failing that the
# ONE seat whose scope explicitly claims the longest namespace prefix of it.
# The strengths, strongest first: an alert name equal to a registered seat id;
# an alert namespaced under a seat id, as `gpu-ops.thermal` under `gpu-ops`;
# then a scope that claims a namespace by writing it with a trailing dot or
# star, as `gpu.*` or `monitor.` do; prose that merely contains the word does
# not claim it, which is why a bare substring search is wrong here.
#
# Two seats matching at the same strength is NOT an exact answer. It is a
# genuine ambiguity, and returning either one would silently route an alert to
# the wrong seat while skipping the model that exists to break exactly this
# tie. So a tie fails, and the caller falls through.
exact_owner() {
  local name scope best='' best_strength=0 best_len=0 ties=0 probe len strength
  while IFS=$'\t' read -r name scope; do
    [ -n "$name" ] || continue
    strength=0
    len=0
    if [ "$ALERT" = "$name" ]; then
      strength=3
      len=${#ALERT}
    else
      case "$ALERT" in
        "$name".*|"$name":*)
          strength=2
          len=${#name}
          ;;
      esac
    fi
    if [ "$strength" -eq 0 ]; then
      probe=$ALERT
      while [ -n "$probe" ]; do
        case "$scope" in
          *"$probe".*|*"$probe"\**)
            # A one or two character coincidence is not a claim of ownership.
            [ "${#probe}" -ge 3 ] || break
            strength=1
            len=${#probe}
            break
            ;;
        esac
        case "$probe" in
          *[.:]*) probe=${probe%[.:]*} ;;
          *) probe='' ;;
        esac
      done
    fi
    [ "$strength" -gt 0 ] || continue
    if [ "$strength" -gt "$best_strength" ]; then
      best=$name
      best_strength=$strength
      best_len=$len
      ties=1
    elif [ "$strength" -eq "$best_strength" ]; then
      if [ "$len" -gt "$best_len" ]; then
        best=$name
        best_len=$len
        ties=1
      elif [ "$len" -eq "$best_len" ] && [ "$name" != "$best" ]; then
        ties=$(( ties + 1 ))
      fi
    fi
  done <<EOF
$(seats)
EOF
  # A contested match is not an exact answer.
  [ "$best_strength" -gt 0 ] || return 1
  [ "$ties" -eq 1 ] || return 1
  printf '%s' "$best"
}

if [ ! -f "$REGISTRY" ]; then
  fm_jev_telemetry "$STATE" "$TOOL" status=escalate source=fallback reason=no_registry
  emit escalate "$FALLBACK" fallback \
    "no seat registry at $REGISTRY, so no charter can be named and this must not go unattended"
  exit 0
fi

if OWNER=$(exact_owner); then
  fm_jev_telemetry "$STATE" "$TOOL" status=clear source=exact
  emit clear "$OWNER" exact ''
  exit 0
fi

# --- the model layer, only for what exact matching could not place -----------

if ! fm_jev_key_resolve "$FM_HOME"; then
  echo "$TOOL: off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env)" >&2
  fm_jev_telemetry "$STATE" "$TOOL" status=escalate source=fallback reason=off
  emit escalate "$FALLBACK" fallback \
    'no charter matched by name and the model half is off, so this escalates rather than going unattended'
  exit 0
fi

CRITERIA=$(seats | jq -R -s 'split("\n") | map(select(length > 0) | split("\t"))
  | map(select(length == 2)) | map({key: .[0], value: .[1]}) | from_entries' 2>/dev/null) || CRITERIA=
if [ -z "$CRITERIA" ] || [ "$CRITERIA" = '{}' ]; then
  fm_jev_telemetry "$STATE" "$TOOL" status=escalate source=fallback reason=no_charters
  emit escalate "$FALLBACK" fallback 'the seat registry names no charter to choose among'
  exit 0
fi

# The model sees the alert and the charter scopes only. It never sees the
# fallback owner, the confidence floor, or which seats are live, so it cannot
# optimize against the policy applied to its answer.
STATE_JSON=$(jq -n --arg name "$ALERT" --arg text "$TEXT" \
  '{alert: {name: $name, detail: $text}}' 2>/dev/null) || STATE_JSON=
if [ -z "$STATE_JSON" ]; then
  fm_jev_telemetry "$STATE" "$TOOL" status=unavailable source=fallback reason=request_build
  emit unavailable "$FALLBACK" fallback 'could not build the request, so this escalates to the fallback owner'
  exit 0
fi

if ! fm_jev_ask charter "$STATE_JSON" "$CRITERIA" \
  'Which ONE seat charter owns this alert? Each option is that seat own scope statement. Choose the seat whose scope covers the subject matter of the alert.'; then
  fm_jev_telemetry "$STATE" "$TOOL" status=unavailable source=fallback \
    "reason=$(printf '%s' "$FM_JEV_REASON" | tr ' ' '_')"
  emit unavailable "$FALLBACK" fallback "$FM_JEV_REASON, so this escalates to the fallback owner" \
    "latency_ms: $FM_JEV_LATENCY_MS"
  exit 0
fi

fm_jev_calibration "$STATE" "$TOOL" "$(jq -n \
  --arg choice "$FM_JEV_CHOICE" --arg conf "$FM_JEV_CONFIDENCE" --arg probs "$FM_JEV_PROBS" \
  --arg exact none --arg at "$(date +%s)" \
  '{at: ($at | tonumber), deterministic: $exact, choice: $choice,
    confidence: ($conf | tonumber), probabilities: $probs}' 2>/dev/null)"

if fm_jev_clears_floor "$FM_JEV_CONFIDENCE"; then
  fm_jev_telemetry "$STATE" "$TOOL" status=clear source=model cleared_floor=yes
  emit clear "$FM_JEV_CHOICE" model '' \
    "confidence: $FM_JEV_CONFIDENCE" "probabilities: $FM_JEV_PROBS" \
    "latency_ms: $FM_JEV_LATENCY_MS" "tokens: $FM_JEV_TOKENS"
  exit 0
fi

# Below the floor the answer is evidence, not a routing decision. It escalates
# WITH the probabilities so the reader starts from the model's ranking instead of
# from nothing, and the alert still reaches a person either way.
fm_jev_telemetry "$STATE" "$TOOL" status=ambiguous source=model cleared_floor=no
emit ambiguous "$FALLBACK" fallback \
  "the best charter scored $FM_JEV_CONFIDENCE, under the $FM_JEV_CONFIDENCE_FLOOR floor, so it escalates with its ranking rather than routing on a guess" \
  "best: $FM_JEV_CHOICE" "probabilities: $FM_JEV_PROBS" "latency_ms: $FM_JEV_LATENCY_MS"
exit 0
