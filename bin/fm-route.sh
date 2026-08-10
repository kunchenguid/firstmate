#!/usr/bin/env bash
# fm-route.sh - read the ROUTE and ELIGIBLE decisions, and record the one thing
# FAILOVER is allowed to write.
#
# The routing policy in config/crew-dispatch.json states which models a route
# may use, the capability floor each route requires, and that a failed primary
# is replaced only from inside its own pool, in pool order. This command answers
# those questions deterministically so a dispatch never rests on recollection,
# and bin/fm-spawn.sh enforces the same answers at the spawn chokepoint.
# bin/fm-route-lib.sh owns the decision itself; this file is its interface.
#
# Usage:
#   fm-route.sh routes                       every route, its floor and its pool
#   fm-route.sh check --route <id> --model <name> [--effort <band>]
#                                            is this exact dispatch allowed?
#   fm-route.sh eligible --route <id>        the route's pool filtered by the
#                                            floor, the availability record and
#                                            the model registry, in pool order
#   fm-route.sh next --route <id> --after <model>
#                                            the failover substitute: the next
#                                            eligible candidate INSIDE the same
#                                            pool, after <model>
#   fm-route.sh availability                 every hold still in force
#   fm-route.sh availability hold <model> [--scope provider] --state <state>
#                                [--for-seconds <n>] [--evidence <text>]
#   fm-route.sh availability release <model> [--scope provider]
#   fm-route.sh --help
#
# A hold names a MODEL by default, resolved against the configured pools exactly
# as a dispatch's --model is: a fully qualified entry must be in a pool, and a
# bare name must match exactly one. Holding a whole provider is asked for with
# --scope provider. Nothing is inferred from the presence of a slash, because a
# hold recorded under a key no candidate can match is a hold that silently does
# nothing while reporting success.
#
# --json prints the decision record instead of prose, on check, eligible, next
# and availability.
#
# Exit status is the answer, so a caller that ignores the output still stops
# safely:
#   0  allowed / candidates exist
#   1  refused - the named rule is violated
#   2  could not be read - usage error, missing jq, or unreadable policy. NEVER
#      a pass: an unreadable safety file must not read as an absent one
#   3  NO_CANDIDATE - every candidate is ineligible. This is a real, expected
#      answer that triggers the policy's terminal stop, and it is never a signal
#      to lower the floor
#
# ELIGIBLE composes three landed owners rather than re-deciding them: the floor
# and pool from the routing policy (this command), the availability record
# (bin/fm-route-lib.sh), and cost, routability and concurrency from the model
# registry (bin/fm-model-registry-lib.sh). No probe runs on the happy path.
#
# Environment:
#   FM_HOME  the firstmate home whose config/ and state/ are read
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export STATE CONFIG

# shellcheck source=bin/fm-route-lib.sh
. "$SCRIPT_DIR/fm-route-lib.sh"
# shellcheck source=bin/fm-model-registry-lib.sh
. "$SCRIPT_DIR/fm-model-registry-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SCRIPT_DIR/fm-route.sh"
}

die() { printf 'error: %s\n' "$1" >&2; exit 2; }

JSON=0
ROUTE=
MODEL=
EFFORT=
AFTER=
HOLD_STATE=
HOLD_SECONDS=
HOLD_EVIDENCE=
HOLD_SCOPE=
CMD=
POS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --route) shift; [ $# -gt 0 ] || die "--route needs a value"; ROUTE=$1 ;;
    --route=*) ROUTE=${1#--route=} ;;
    --model) shift; [ $# -gt 0 ] || die "--model needs a value"; MODEL=$1 ;;
    --model=*) MODEL=${1#--model=} ;;
    --effort) shift; [ $# -gt 0 ] || die "--effort needs a value"; EFFORT=$1 ;;
    --effort=*) EFFORT=${1#--effort=} ;;
    --after) shift; [ $# -gt 0 ] || die "--after needs a value"; AFTER=$1 ;;
    --after=*) AFTER=${1#--after=} ;;
    --state) shift; [ $# -gt 0 ] || die "--state needs a value"; HOLD_STATE=$1 ;;
    --state=*) HOLD_STATE=${1#--state=} ;;
    --for-seconds) shift; [ $# -gt 0 ] || die "--for-seconds needs a value"; HOLD_SECONDS=$1 ;;
    --for-seconds=*) HOLD_SECONDS=${1#--for-seconds=} ;;
    --evidence) shift; [ $# -gt 0 ] || die "--evidence needs a value"; HOLD_EVIDENCE=$1 ;;
    --evidence=*) HOLD_EVIDENCE=${1#--evidence=} ;;
    --scope) shift; [ $# -gt 0 ] || die "--scope needs a value"; HOLD_SCOPE=$1 ;;
    --scope=*) HOLD_SCOPE=${1#--scope=} ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) if [ -z "$CMD" ]; then CMD=$1; else POS+=("$1"); fi ;;
  esac
  shift
done

[ -n "$CMD" ] || { usage; exit 2; }
command -v jq >/dev/null 2>&1 || die "jq is required to read the routing policy"

CONFIG_FILE=$(fm_route_config_path "$CONFIG")
[ -f "$CONFIG_FILE" ] || die "no routing policy in this home: $CONFIG_FILE"

# The registry gate for one candidate. Prints the refusal when a landed owner
# refuses it; prints nothing and returns 0 when every owner admits it.
registry_refusal() {  # <qualified-model>
  local m=$1 out
  if ! out=$(fm_model_zero_budget_decision "$m"); then printf '%s\n' "$out"; return 1; fi
  if ! out=$(fm_model_routable_decision "$m"); then printf '%s\n' "$out"; return 1; fi
  if ! out=$(fm_model_concurrency_decision "$m" "$STATE"); then printf '%s\n' "$out"; return 1; fi
  return 0
}

# The route decision plus, per candidate, the registry verdict the routing
# policy cannot answer by itself. One record, so prose and --json never diverge,
# and it takes the decision it enriches so no command in this file evaluates the
# same policy twice against possibly different config or availability state.
enrich() {  # <decision-json>
  local decision=$1 candidates model refusal enriched
  [ "$(printf '%s' "$decision" | jq -r '.route_known')" = true ] || { printf '%s' "$decision"; return 0; }
  [ -z "$(printf '%s' "$decision" | jq -r '.duplicate_paths // empty')" ] || { printf '%s' "$decision"; return 0; }
  candidates=$(printf '%s' "$decision" | jq -r '.candidates[]?.model')
  enriched='[]'
  while IFS= read -r model; do
    [ -n "$model" ] || continue
    if refusal=$(registry_refusal "$model"); then refusal=; fi
    enriched=$(printf '%s' "$enriched" | jq -c --arg m "$model" --arg r "$refusal" \
      '. + [{model:$m, registry_refusal:(if ($r|length)>0 then $r else null end)}]')
  done <<EOF
$candidates
EOF
  printf '%s' "$decision" | jq -c --argjson reg "$enriched" '
    .candidates = [ .candidates[]
      | . as $c
      | (($reg[] | select(.model == $c.model) | .registry_refusal) // null) as $rr
      | $c + {registry_refusal:$rr,
              eligible:($c.floor_met and ($c.held == null) and ($rr == null))} ]'
}

# The policy names exactly what a terminal report has to contain: the route and
# its floor, every candidate considered IN ORDER with the axis or availability
# state that rejected it, the earliest known recovery time, and the operator
# action that would clear it. Printing less than that is what leaves a stopped
# route looking like a mystery.
terminal_report() {  # <decision-json>
  local d=$1
  printf '%s: route %s (floor %s) has no eligible candidate.\n' \
    "$FM_ROUTE_TOKEN_NO_CANDIDATE" \
    "$(printf '%s' "$d" | jq -r '.route')" \
    "$(printf '%s' "$d" | jq -r '.floor // "unconfigured"')"
  printf '%s' "$d" | jq -r '
    .candidates[]
    | "  " + (.position | tostring) + ". " + .model + " - "
      + ( if (.violations | length) > 0
          then ([.violations[] | .rule + " (" + .config_path + " configures "
                 + (.configured | tostring) + ", observed " + (.observed | tostring) + ")"] | join("; "))
          elif .held != null
          then "held " + .held.state + " on the " + .held.scope + " "
               + .held.subject
               + (if .held.until != null then " until epoch " + (.held.until | tostring) else " until released" end)
          elif .registry_refusal != null then .registry_refusal
          else "eligible" end )'
  printf '%s' "$d" | jq -r '
    [ .candidates[] | select(.held != null) | .held.until | select(. != null) ] | min
    | if . == null then "  earliest known recovery: none of the rejections names one"
      else "  earliest known recovery: epoch " + (. | tostring) end'
  printf '  do not lower the floor and do not substitute a model outside this pool: stop, report, and queue the work.\n'
}

case "$CMD" in
  routes)
    # Every route this home defines, from the one place bin/fm-route-lib.sh says
    # a route may be defined. A listing that omits a route `check` enforces and
    # `fm-spawn.sh` demands is what makes a route look like a typo.
    jq -r "$FM_ROUTE_ENTRIES_JQ"'
      def profiles($v): if ($v|type) == "array" then $v elif ($v|type) == "object" then [$v] else [] end;
      [ route_entries[] ] as $all
      | ([ $all[] | select(.source == "rule") ]) as $rules
      | ([ $rules[] | .id ]) as $rule_ids
      | ($rules + [ $all[] | select(.source == "default")
                    | . as $e | select(($rule_ids | index($e.id)) == null) ])[]
      | .id + "  floor=" + (.rule.floor // "-")
        + "  primary=" + ((profiles(.rule.use)[0]?.model) // "-")
        + "  effort=" + ((profiles(.rule.use)[0]?.effort) // "-")
        + "  pool=" + ((.rule.pool // []) | join(","))
        + "  promotes_to=" + (.rule.promotion_target // "-")
        + "  defined_at=" + .path
    ' "$CONFIG_FILE"
    printf 'policy_digest=%s\n' "$(fm_route_policy_digest "$CONFIG")"
    ;;

  check)
    [ -n "$ROUTE" ] || die "check needs --route"
    [ -n "$MODEL" ] || die "check needs --model"
    DECISION=$(fm_route_decision "$CONFIG" "$ROUTE" "$MODEL" "$EFFORT" "$STATE") \
      || { printf '%s\n' "$(fm_route_unreadable_refusal "$CONFIG")" >&2; exit 2; }
    if [ "$JSON" -eq 1 ]; then
      enrich "$DECISION"
      printf '\n'
    fi
    if refusal=$(fm_route_refusal_from_decision "$CONFIG" "$ROUTE" "$MODEL" "$DECISION" "$STATE"); then
      rc=0
    else
      rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      [ "$JSON" -eq 1 ] || printf '%s\n' "$refusal" >&2
      exit "$rc"
    fi
    # The routing policy allows it; the landed registry owners still decide
    # whether it may be paid for, reached, and run concurrently.
    resolved=$(printf '%s' "$DECISION" | jq -r '.subject.resolved // empty')
    if [ -n "$resolved" ] && ! refusal=$(registry_refusal "$resolved"); then
      [ "$JSON" -eq 1 ] || printf 'error: %s\n' "$refusal" >&2
      exit 1
    fi
    [ "$JSON" -eq 1 ] || printf 'ok: %s at %s is inside route %s\n' \
      "$MODEL" "${EFFORT:-provider default}" "$ROUTE"
    ;;

  eligible|next)
    [ -n "$ROUTE" ] || die "$CMD needs --route"
    [ "$CMD" != next ] || [ -n "$AFTER" ] || die "next needs --after <model>"
    DECISION=$(fm_route_decision "$CONFIG" "$ROUTE" "" "" "$STATE") \
      || die "the routing policy could not be read: $CONFIG_FILE"
    DECISION=$(enrich "$DECISION")
    [ "$(printf '%s' "$DECISION" | jq -r '.route_known')" = true ] \
      || die "route $ROUTE is not defined by $CONFIG_FILE"
    if [ "$CMD" = next ]; then
      AFTER_POS=$(printf '%s' "$DECISION" | jq -r --arg a "$AFTER" '
        [ .candidates[] | select(.model == $a or (.model | endswith("/" + $a))) | .position ] | first // empty')
      [ -n "$AFTER_POS" ] || die "$FM_ROUTE_TOKEN_POOL: $AFTER is not in route $ROUTE's pool, so no substitution inside that pool can follow it"
      DECISION=$(printf '%s' "$DECISION" | jq -c --argjson p "$AFTER_POS" \
        '.candidates = [ .candidates[] | select(.position > $p) ]')
    fi
    if [ "$JSON" -eq 1 ]; then printf '%s\n' "$DECISION"; fi
    ELIGIBLE=$(printf '%s' "$DECISION" | jq -r '[ .candidates[] | select(.eligible) | .model ] | .[]')
    if [ -z "$ELIGIBLE" ]; then
      [ "$JSON" -eq 1 ] || terminal_report "$DECISION" >&2
      exit 3
    fi
    [ "$JSON" -eq 1 ] || printf '%s\n' "$ELIGIBLE"
    ;;

  availability)
    SUB=${POS[0]:-}
    case "$SUB" in
      ''|list)
        if [ "$JSON" -eq 1 ]; then
          fm_route_health_active "$STATE" || die "the availability record is malformed: $(fm_route_health_path "$STATE")"
        else
          fm_route_health_active "$STATE" \
            | jq -r '(.models | to_entries[] | "model    " + .key + "  " + .value.state
                        + "  until=" + (.value.until // "released-explicitly" | tostring)
                        + "  " + (.value.evidence // "")),
                     (.providers | to_entries[] | "provider " + .key + "  " + .value.state
                        + "  until=" + (.value.until // "released-explicitly" | tostring)
                        + "  " + (.value.evidence // ""))' \
            || die "the availability record is malformed: $(fm_route_health_path "$STATE")"
        fi
        ;;
      hold|release)
        SUBJECT=${POS[1]:-}
        [ -n "$SUBJECT" ] || die "availability $SUB needs a model or provider"
        case "$HOLD_SCOPE" in
          ''|model|provider) ;;
          *) die "--scope takes model or provider, not '$HOLD_SCOPE'" ;;
        esac
        # A release resolves against what is actually recorded first, so a hold
        # can always be cleared even after a config edit dropped its subject
        # from every pool. A record that can be written and never cleared is a
        # trap; clearing availability is always safe.
        SCOPE=
        if [ "$SUB" = release ]; then
          SCOPE=$(fm_route_hold_recorded_scope "$STATE" "$SUBJECT" || true)
          [ -z "$SCOPE" ] || [ -z "$HOLD_SCOPE" ] || [ "$SCOPE" = "$HOLD_SCOPE" ] \
            || die "$SUBJECT is recorded as a $SCOPE hold, not a $HOLD_SCOPE one"
        fi
        if [ -z "$SCOPE" ]; then
          RESOLVED=$(fm_route_hold_subject "$CONFIG" "$HOLD_SCOPE" "$SUBJECT") || exit 2
          SCOPE=${RESOLVED%% *}
          SUBJECT=${RESOLVED#* }
        fi
        if [ "$SUB" = release ]; then
          fm_route_health_write "$STATE" "$SCOPE" "$SUBJECT" '' '' '' || exit 2
          printf 'released %s %s\n' "$SCOPE" "$SUBJECT"
        else
          [ -n "$HOLD_STATE" ] || die "availability hold needs --state <$(fm_route_health_states_oneline)>"
          EXPIRES=
          if [ -n "$HOLD_SECONDS" ]; then
            case "$HOLD_SECONDS" in ''|*[!0-9]*) die "--for-seconds must be a whole number of seconds" ;; esac
            EXPIRES=$(( $(date -u +%s) + HOLD_SECONDS ))
          fi
          fm_route_health_write "$STATE" "$SCOPE" "$SUBJECT" "$HOLD_STATE" "$EXPIRES" "$HOLD_EVIDENCE" || exit 2
          printf 'held %s %s state=%s until=%s\n' "$SCOPE" "$SUBJECT" "$HOLD_STATE" "${EXPIRES:-released-explicitly}"
        fi
        ;;
      *) die "unknown availability subcommand: $SUB" ;;
    esac
    ;;

  *) die "unknown command: $CMD" ;;
esac
