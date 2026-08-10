# shellcheck shell=bash
# fm-route-lib.sh - single owner of the ROUTE and ELIGIBLE decisions read out of
# config/crew-dispatch.json, and of the narrow availability record FAILOVER
# writes.
# Usage: . bin/fm-route-lib.sh
#
# WHY THIS EXISTS. The routing policy already states, in prose a human reads,
# which models a route may use, what capability floor each route requires, and
# that a failed primary is replaced only from inside its own pool. Nothing read
# any of it. A dispatch could name a model no pool contains, run it below its
# route's effort floor, or substitute a plausible sibling from another route,
# and the first evidence would be the work coming back wrong. This library is
# the enforced copy of those rules; the prose stays descriptive.
#
# ONE OWNER PER QUESTION, exactly as the policy's own `_interfaces` block names
# the seams:
#
#   ROUTE     this library      which route, which floor, which ordered pool.
#                               Availability-blind by construction: nothing here
#                               reads quota, fleet load, or an outage.
#   ADMIT     bin/fm-admission.sh  whether the fleet accepts another task at all.
#   ELIGIBLE  this library      the route's pool filtered by the floor and by the
#                               availability record, in pool order. It reads the
#                               record and never probes: routine intake costs
#                               nothing.
#   FAILOVER  this library      the ONLY writer of availability state, and it
#                               writes availability alone. A model that keeps
#                               failing is recorded UNAVAILABLE, never demoted;
#                               demotion is a policy change and needs review.
#
# What this library deliberately does NOT own: whether a model may be paid for
# at all, whether the account may reach it, and how many of it may run at once.
# bin/fm-model-registry-lib.sh has owned those since the model registry landed,
# it is already enforced at the spawn chokepoint, and eligibility COMPOSES it
# rather than re-deciding it.
#
# NOT ENFORCED, and it is worth saying why rather than leaving it to be
# rediscovered: config/models.json's per-model `eligible_routes` and
# `prohibited_routes` look like exactly this check and cannot be run as one
# today, because the two files name routes in two different vocabularies. The
# registry's older entries carry tier slugs ("t2-substantive", "t1-risk",
# "long-context-specialist") while its newest entry and every rule here carry
# route ids ("R2-LONGCTX", "R3-MED"), and no mapping between them exists. Wiring
# them together before one vocabulary wins would refuse correct dispatches
# wholesale - the routing policy's own primary at four routes records neither of
# those routes in its registry entry. Reconciling the two is a change to the
# registry, owned by model-onboarding, not something to paper over here.
#
# ENFORCEMENT SCOPE - the same deliberate asymmetry the model registry uses:
#
#   No routed pool configured -> inert. A home whose config/crew-dispatch.json is
#                                absent, or which uses only the documented
#                                harness/model/effort profile schema with no
#                                `pool`, behaves exactly as it did before this
#                                existed. Nothing to check is not a refusal.
#   A routed pool configured   -> fail closed. A dispatch must name the route it
#                                claims, and an unreadable config, an unknown
#                                route, a duplicate route id, or a floor axis
#                                whose evidence is missing all REFUSE. A safety
#                                file that cannot be read must never read as an
#                                absent one.
#
# Every refusal names the violated rule: the route, the exact JSON config path,
# the configured value, and the observed value. A refusal a reader cannot trace
# back to a line of policy is a refusal nobody can fix.
#
# docs/configuration.md "Crew dispatch profiles" owns the config schema and
# "Model availability record" owns state/model-health.json. This header owns the
# mechanics.

# Idempotent guard: fm-spawn.sh and fm-route.sh may both be in one process tree.
if [ -n "${FM_ROUTE_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_ROUTE_LIB_SOURCED=1

# The availability record's only schema, and the closed state vocabulary it
# accepts. Every state is one a `_failover.conditions.*.sets` value names, so a
# recorded hold always traces back to a condition the policy defines. An
# unknown state is refused rather than stored: a vocabulary that grows at the
# call site cannot be reported on.
FM_ROUTE_HEALTH_SCHEMA='fm-model-health.v1'
FM_ROUTE_HEALTH_STATES='degraded
rate_limited
model_unavailable
provider_unavailable
auth_failure
subscription_quota_exhausted
daily_quota_exhausted
admin_disabled'

# Stable refusal tokens. Tests and callers match these rather than prose.
# shellcheck disable=SC2034 # Contract constants are consumed by sourcing callers.
{
FM_ROUTE_TOKEN_REQUIRED=FM_SPAWN_ROUTE_REQUIRED
FM_ROUTE_TOKEN_UNKNOWN=FM_SPAWN_ROUTE_UNKNOWN
FM_ROUTE_TOKEN_UNREADABLE=FM_SPAWN_ROUTE_UNREADABLE
FM_ROUTE_TOKEN_AMBIGUOUS=FM_SPAWN_ROUTE_AMBIGUOUS
FM_ROUTE_TOKEN_FLOOR_MISMATCH=FM_SPAWN_ROUTE_FLOOR_MISMATCH
FM_ROUTE_TOKEN_POOL=FM_SPAWN_ROUTE_POOL_VIOLATION
FM_ROUTE_TOKEN_FLOOR=FM_SPAWN_ROUTE_FLOOR_VIOLATION
FM_ROUTE_TOKEN_NO_CANDIDATE=FM_ROUTE_NO_CANDIDATE
FM_ROUTE_TOKEN_HEALTH_STATE=FM_ROUTE_HEALTH_STATE_UNKNOWN
}

# ---------------------------------------------------------------------------
# Location and presence
# ---------------------------------------------------------------------------

fm_route_config_path() {  # [<config-dir>]
  local cfg=${1:-}
  [ -n "$cfg" ] || cfg="${CONFIG:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-.}/config}}"
  printf '%s\n' "$cfg/crew-dispatch.json"
}

fm_route_health_path() {  # [<state-dir>]
  local st=${1:-}
  [ -n "$st" ] || st="${STATE:-${FM_STATE_OVERRIDE:-${FM_HOME:-.}/state}}"
  printf '%s\n' "$st/model-health.json"
}

# True when this home's dispatch config carries at least one route that names an
# ordered pool. That, and only that, is what turns enforcement on: the schema
# documented for every other home has no `pool`, so those homes stay inert.
# Exit 0 = enforcing, 1 = nothing to enforce, 2 = the file exists but cannot be
# read, which is unverifiable rather than empty.
fm_route_pools_configured() {  # [<config-dir>]
  local file answer
  file=$(fm_route_config_path "${1:-}")
  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 2
  answer=$(jq -r '
    [ (.rules // [])[]? | select((.route? | type) == "string")
      | select((.pool? | type) == "array" and (.pool | length) > 0) ] | length > 0
  ' "$file" 2>/dev/null) || return 2
  [ "$answer" = true ]
}

# A content digest of the surface this library actually enforces, so a recorded
# dispatch can be proved against the exact policy that checked it. The prose
# `_policy.version` string is deliberately not used: it is maintained by hand
# and has been observed stale, while this cannot be.
fm_route_policy_digest() {  # [<config-dir>]
  local file surface sum
  file=$(fm_route_config_path "${1:-}")
  [ -f "$file" ] || { printf 'unconfigured\n'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'unreadable\n'; return 0; }
  surface=$(jq -S -c '{rules: (.rules // []), default: (.default // null),
                       floors: (._floors // {}), models: (._models // {})}' "$file" 2>/dev/null) \
    || { printf 'unreadable\n'; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(printf '%s' "$surface" | sha256sum | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    sum=$(printf '%s' "$surface" | shasum -a 256 | awk '{print $1}')
  else
    printf 'unavailable\n'; return 0
  fi
  printf 'sha256:%s\n' "${sum:0:16}"
}

# ---------------------------------------------------------------------------
# The decision program
# ---------------------------------------------------------------------------

# One jq program answers every route question, so the floor axes are spelled
# exactly once and a check and an eligibility listing can never disagree about
# what a floor means. It takes the config as input plus $route, $model, $effort,
# $holds and $now, and prints a decision record.
#
# The three mechanically checkable axes are the ones the policy's own
# `_floors._axes._mechanically_checkable` block names: effort, context, and tool
# loop. The six axes it lists as judged at admission are deliberately NOT
# checked here - reading a passing floor check as evidence on them is the exact
# mistake that block exists to prevent.
# shellcheck disable=SC2016 # jq program, not shell expansion.
FM_ROUTE_DECISION_JQ='
def bands: ["low","medium","high","xhigh","max","ultra"];
def rank($b): (if ($b | type) == "string" then (bands | index($b)) else null end);
def loop_rank($v): (if ($v | type) == "string"
                    then {"not-required":0,"required":1,"verified-agentic":2}[$v]
                    else null end);
def provider_of($m): (if ($m | test("/")) then ($m | split("/") | .[0]) else null end);

# A route is DEFINED by a rule. The top-level `default` names which route is the
# default and carries its profile, so a default pointing at an existing rule is
# not a second definition of that route - only a rules[] id used twice is, and
# that one is refused because every check against it would be meaningless.
def rule_routes:
  [ (.rules // []) | to_entries[]
    | select((.value.route? | type) == "string")
    | {id: .value.route, path: ("/rules/" + (.key | tostring)), rule: .value} ];
def default_routes:
  ( (.default // null) as $d
    | if ($d | type) == "object" and (($d.route? | type) == "string")
      then [{id: $d.route, path: "/default", rule: $d}]
      elif ($d | type) == "array"
      then [ $d | to_entries[] | select((.value.route? | type) == "string")
             | {id: .value.route, path: ("/default/" + (.key | tostring)), rule: .value} ]
      else [] end );

. as $cfg
| (rule_routes | map(select(.id == $route))) as $rule_matches
| (if ($rule_matches | length) > 0 then $rule_matches
   else (default_routes | map(select(.id == $route)) | .[0:1]) end) as $matches
| ($cfg._models // null) as $models
| ($matches | length) as $n
| if $n == 0 then
    {schema:"fm-route-decision.v1", route:$route, route_known:false,
     known_routes:((rule_routes + default_routes) | map(.id) | unique)}
  elif $n > 1 then
    {schema:"fm-route-decision.v1", route:$route, route_known:true,
     duplicate_paths:($matches | map(.path))}
  else
    $matches[0] as $m
    | $m.rule as $rule
    | ($rule.floor? // null) as $floor_id
    | (if ($floor_id != null) then ($cfg._floors // {})[$floor_id] else null end) as $floor_raw
    | (if ($floor_raw | type) == "object" then $floor_raw else {} end) as $floor
    | (if ($floor_id != null) then ("/_floors/" + $floor_id) else null end) as $floor_path
    | (if (($rule.pool? | type) == "array") then $rule.pool else [] end) as $pool
    | ($m.path + "/pool") as $pool_path
    | ($floor.effort_floor? // null) as $ef_raw
    | (if ($ef_raw | type) == "string" and (rank($ef_raw) != null) then $ef_raw else null end) as $ef
    | (($ef_raw | type) == "string" and ($ef_raw | startswith("WAIVED"))) as $ef_waived
    | (($ef_raw != null) and ($ef == null) and ($ef_waived | not)) as $ef_malformed
    | ($floor.context_ceiling? // null) as $ctx
    | ($floor.tool_loop? // null) as $tl
    | (($floor.selectable_by_crew_rule? // true) == false) as $unselectable

    | def held($m):
        ($holds.models[$m] // null) as $mh
        | (provider_of($m)) as $p
        | (if $p != null then ($holds.providers[$p] // null) else null end) as $ph
        | if $mh != null then ($mh + {scope:"model", subject:$m})
          elif $ph != null then ($ph + {scope:"provider", subject:$p})
          else null end;

    def violations($m; $e):
        [ (if ($unselectable)
           then {rule:"floor_not_selectable", config_path:($floor_path + "/selectable_by_crew_rule"),
                 configured:"false", observed:$m}
           else empty end),
          (if (($pool | length) > 0) and (($pool | index($m)) == null)
           then {rule:"model_not_in_pool", config_path:$pool_path,
                 configured:($pool | join(", ")), observed:$m}
           else empty end),
          (if ($ef != null) and (($e | length) == 0)
           then {rule:"effort_unstated", config_path:($floor_path + "/effort_floor"),
                 configured:$ef, observed:"provider default"}
           elif ($ef != null) and (rank($e) == null)
           then {rule:"effort_unknown_band", config_path:($floor_path + "/effort_floor"),
                 configured:(bands | join(", ")), observed:$e}
           elif ($ef != null) and (rank($e) < rank($ef))
           then {rule:"effort_below_floor", config_path:($floor_path + "/effort_floor"),
                 configured:$ef, observed:$e}
           else empty end),
          (if ($ef_malformed)
           then {rule:"effort_floor_malformed", config_path:($floor_path + "/effort_floor"),
                 configured:($ef_raw | tostring), observed:"unreadable"}
           else empty end),
          (if ($models != null) and ($ef != null) and (($e | length) > 0) and (rank($e) != null)
           then ($models[$m].effort_expressible? // null) as $ee
             | if $ee == null
               then {rule:"effort_unverifiable", config_path:("/_models/" + $m + "/effort_expressible"),
                     configured:"an expressible-band array", observed:"absent"}
               elif ($ee | index($e)) == null
               then {rule:"effort_not_expressible", config_path:("/_models/" + $m + "/effort_expressible"),
                     configured:($ee | join(", ")), observed:$e}
               else empty end
           else empty end),
          (if ($models != null) and ($ctx != null)
           then ($models[$m].smart_zone? // null) as $sz
             | if ($sz | type) != "number"
               then {rule:"context_unverifiable", config_path:("/_models/" + $m + "/smart_zone"),
                     configured:("at least " + ($ctx | tostring)), observed:"absent"}
               elif $sz < $ctx
               then {rule:"context_below_floor", config_path:($floor_path + "/context_ceiling"),
                     configured:($ctx | tostring), observed:($sz | tostring)}
               else empty end
           else empty end),
          (if ($models != null) and ($tl != null) and (loop_rank($tl) != null) and (loop_rank($tl) > 0)
           then ($models[$m].tool_loop? // null) as $mt
             | if (loop_rank($mt) == null)
               then {rule:"tool_loop_unverifiable", config_path:("/_models/" + $m + "/tool_loop"),
                     configured:$tl, observed:($mt // "absent" | tostring)}
               elif (loop_rank($mt) < loop_rank($tl))
               then {rule:"tool_loop_below_floor", config_path:($floor_path + "/tool_loop"),
                     configured:$tl, observed:$mt}
               else empty end
           else empty end) ];

    def resolve($want):
        if ($want | length) == 0 then {resolved:null, resolution:"unstated"}
        elif (($pool | index($want)) != null) then {resolved:$want, resolution:"exact"}
        elif ($want | test("/")) then {resolved:$want, resolution:"qualified"}
        else ([ $pool[] | select(endswith("/" + $want)) ]) as $s
          | if ($s | length) == 1 then {resolved:$s[0], resolution:"suffix"}
            elif ($s | length) > 1 then {resolved:null, resolution:"ambiguous", matches:$s}
            else {resolved:$want, resolution:"bare"} end
        end;

    {schema:"fm-route-decision.v1",
     route:$route, route_known:true, route_path:$m.path,
     floor:$floor_id, floor_path:$floor_path,
     floor_axes:{effort_floor:$ef, effort_waived:$ef_waived, context_ceiling:$ctx,
                 tool_loop:$tl, selectable:($unselectable | not)},
     models_recorded:($models != null),
     pool:$pool, pool_path:$pool_path, pool_configured:(($pool | length) > 0),
     use:($rule.use? // null),
     promotion_target:($rule.promotion_target? // null),
     subject:( (resolve($model)) as $r
               | $r + {requested:$model, effort:$effort,
                       held:(if $r.resolved != null then held($r.resolved) else null end),
                       violations:(if $r.resolved != null then violations($r.resolved; $effort) else [] end)} ),
     candidates:[ $pool | to_entries[]
                  | .value as $c
                  | (held($c)) as $h
                  | (violations($c; (if ($effort | length) > 0 then $effort else ($ef // "") end))) as $v
                  | {model:$c, position:(.key + 1), held:$h, violations:$v,
                     floor_met:(($v | length) == 0),
                     eligible:(($v | length) == 0 and $h == null)} ]}
  end
'

# fm_route_decision <config-dir> <route> <model> <effort> [<state-dir>]
# Print the decision record for one route. Return 2 when the config is absent or
# unreadable, so a caller can tell "no policy" from "policy says no".
fm_route_decision() {
  local cfg=$1 route=$2 model=${3:-} effort=${4:-} state=${5:-} file holds now
  file=$(fm_route_config_path "$cfg")
  [ -f "$file" ] || return 2
  command -v jq >/dev/null 2>&1 || return 2
  now=$(date -u +%s)
  holds=$(fm_route_health_active "$state" "$now") || return 2
  jq -c --arg route "$route" --arg model "$model" --arg effort "$effort" \
     --argjson holds "$holds" \
     "$FM_ROUTE_DECISION_JQ" "$file" 2>/dev/null || return 2
}

# The routes this home defines, one per line, for a refusal that has to name
# them.
fm_route_ids() {  # [<config-dir>]
  local file
  file=$(fm_route_config_path "${1:-}")
  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 2
  jq -r '
    [ (.rules // [])[]? | .route? | select(type == "string") ]
    + [ (.default // empty) | if type == "object" then .route? elif type == "array" then .[]?.route? else empty end
        | select(type == "string") ]
    | unique | .[]
  ' "$file" 2>/dev/null || return 2
}

# The single route that names capability floor $2, for deriving the claim from
# an explicit --capability-floor. Prints nothing and returns 1 when no route or
# more than one route names it: a floor shared by two routes cannot stand in for
# a route id, and guessing one would defeat the check.
fm_route_for_floor() {  # <config-dir> <floor>
  local file matches
  file=$(fm_route_config_path "$1")
  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  matches=$(jq -r --arg floor "$2" '
    [ (.rules // [])[]? | select((.route? | type) == "string") | select(.floor? == $floor) | .route ]
    + [ (.default // empty)
        | if type == "object" then . elif type == "array" then .[]? else empty end
        | select((.route? | type) == "string") | select(.floor? == $floor) | .route ]
    | unique | .[]
  ' "$file" 2>/dev/null) || return 1
  [ "$(printf '%s\n' "$matches" | grep -c .)" = 1 ] || return 1
  printf '%s\n' "$matches"
}

# ---------------------------------------------------------------------------
# Refusal rendering
# ---------------------------------------------------------------------------

# One violation as one line naming the route, the exact config path, and the
# configured value against the observed one. Every refusal this library prints
# is built from these, so no caller invents its own wording for a rule.
fm_route_violation_lines() {  # <route> <decision-json> <jq-path-to-violations>
  local route=$1 decision=$2 path=$3
  printf '%s' "$decision" | jq -r --arg route "$route" "
    $path | .[]? |
    \"  \" + .rule + \": route \" + \$route + \" \" + .config_path
      + \" configures \" + (.configured | tostring)
      + \"; this dispatch observed \" + (.observed | tostring)
  " 2>/dev/null
}

# fm_route_check_refusal <config-dir> <route> <model> <effort> [<state-dir>]
# Print a complete refusal and return 1 when the dispatch violates the route it
# claims; print nothing and return 0 when it is compliant. Return 2 when the
# route decision itself could not be read, which is never a pass.
fm_route_check_refusal() {
  local cfg=$1 route=$2 model=${3:-} effort=${4:-} state=${5:-} decision known dup resolution count
  decision=$(fm_route_decision "$cfg" "$route" "$model" "$effort" "$state") || {
    printf '%s: %s/crew-dispatch.json defines routed pools but its route decision could not be read (missing jq or malformed JSON), so a dispatch cannot be checked against the policy it claims\n' \
      "$FM_ROUTE_TOKEN_UNREADABLE" "$cfg"
    return 2
  }
  known=$(printf '%s' "$decision" | jq -r '.route_known')
  if [ "$known" != true ]; then
    printf '%s: route %s is not defined by %s/crew-dispatch.json. Defined: %s\n' \
      "$FM_ROUTE_TOKEN_UNKNOWN" "$route" "$cfg" \
      "$(printf '%s' "$decision" | jq -r '.known_routes | join(", ")')"
    return 1
  fi
  dup=$(printf '%s' "$decision" | jq -r '.duplicate_paths // empty | join(", ")')
  if [ -n "$dup" ]; then
    printf '%s: route %s is defined more than once in %s/crew-dispatch.json (%s); a duplicate route id makes every check against it meaningless\n' \
      "$FM_ROUTE_TOKEN_AMBIGUOUS" "$route" "$cfg" "$dup"
    return 1
  fi
  resolution=$(printf '%s' "$decision" | jq -r '.subject.resolution')
  if [ "$resolution" = ambiguous ]; then
    printf '%s: route %s: the bare model name %s matches more than one pool entry (%s); the mixed-key rule forbids guessing which one was meant\n' \
      "$FM_ROUTE_TOKEN_POOL" "$route" "$model" \
      "$(printf '%s' "$decision" | jq -r '.subject.matches | join(", ")')"
    return 1
  fi
  count=$(printf '%s' "$decision" | jq -r '.subject.violations | length')
  [ "$count" = 0 ] && return 0
  printf 'this dispatch violates the route it claims (%s, floor %s):\n' \
    "$route" "$(printf '%s' "$decision" | jq -r '.floor // "unconfigured"')"
  fm_route_violation_lines "$route" "$decision" '.subject.violations'
  return 1
}

# ---------------------------------------------------------------------------
# The availability record - FAILOVER's only output
# ---------------------------------------------------------------------------

fm_route_health_state_known() {  # <state>
  local want=$1 known
  while IFS= read -r known; do
    [ "$known" = "$want" ] && return 0
  done <<EOF
$FM_ROUTE_HEALTH_STATES
EOF
  return 1
}

fm_route_health_states_oneline() {
  printf '%s\n' "$FM_ROUTE_HEALTH_STATES" | tr '\n' ' ' | sed 's/ $//'
}

# Every hold still in force at epoch $2, as {"models":{...},"providers":{...}}.
# An absent record is an empty one: absence means no REMEMBERED cooldown, never
# a capability assertion, and never a claim that a model is healthy. An expired
# hold is dropped on read rather than swept, so nothing has to run to forget.
fm_route_health_active() {  # [<state-dir>] [<now-epoch>]
  local file now
  file=$(fm_route_health_path "${1:-}")
  now=${2:-$(date -u +%s)}
  if [ ! -f "$file" ] || ! command -v jq >/dev/null 2>&1; then
    printf '{"models":{},"providers":{}}\n'
    return 0
  fi
  jq -c --argjson now "$now" '
    def live: with_entries(select(.value.until == null or (.value.until > $now)));
    {models: ((.models // {}) | live), providers: ((.providers // {}) | live)}
  ' "$file" 2>/dev/null || {
    # A record that exists and cannot be parsed is not an empty record. Refuse
    # rather than silently treating every held model as available again.
    return 1
  }
}

# fm_route_health_write <state-dir> <scope: model|provider> <subject> <state>
#                       <until-epoch|""> <evidence>
# Record one availability hold, atomically and privately. Clearing is the same
# call with an empty state.
#
# This is the ONLY writer. It writes availability and nothing else: it never
# touches rules, floors, or pools, because a model that keeps failing is
# unavailable rather than demoted.
fm_route_health_write() {
  local state=$1 scope=$2 subject=$3 hold=$4 expires=${5:-} evidence=${6:-} file tmp now current expires_json
  file=$(fm_route_health_path "$state")
  command -v jq >/dev/null 2>&1 || { echo "jq is required to record model availability" >&2; return 1; }
  mkdir -p "$(dirname "$file")" || return 1
  now=$(date -u +%s)
  expires_json=null
  [ -z "$expires" ] || expires_json=$expires
  case "$scope" in model|provider) ;; *) echo "unknown availability scope: $scope" >&2; return 1 ;; esac
  if [ -n "$hold" ] && ! fm_route_health_state_known "$hold"; then
    echo "$FM_ROUTE_TOKEN_HEALTH_STATE: '$hold' is not an availability state; the vocabulary is closed to the states the policy's failover conditions set. One of: $(fm_route_health_states_oneline)" >&2
    return 1
  fi
  if [ -f "$file" ]; then
    current=$(jq -c . "$file" 2>/dev/null) || { echo "existing availability record is malformed: $file" >&2; return 1; }
  else
    current="{\"schema\":\"$FM_ROUTE_HEALTH_SCHEMA\",\"models\":{},\"providers\":{}}"
  fi
  tmp=$(mktemp "$file.XXXXXX") || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  if ! printf '%s' "$current" | jq \
      --arg schema "$FM_ROUTE_HEALTH_SCHEMA" --arg scope "${scope}s" --arg subject "$subject" \
      --arg hold "$hold" --arg evidence "$evidence" \
      --argjson now "$now" --argjson expires "$expires_json" '
      .schema = $schema
      | .models = (.models // {}) | .providers = (.providers // {})
      | if ($hold | length) == 0
        then .[$scope] |= del(.[$subject])
        else .[$scope][$subject] = {state:$hold, until:$expires, recorded_at:$now, evidence:$evidence}
        end
    ' > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "could not update the availability record" >&2
    return 1
  fi
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  chmod 600 "$file" 2>/dev/null || true
  return 0
}
