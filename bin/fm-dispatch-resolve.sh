#!/usr/bin/env bash
# fm-dispatch-resolve.sh - resolve one concrete crewmate or scout dispatch
# profile from a task brief with typesafe.ai's System One model (Jev), opt-in.
#
# Usage:
#   fm-dispatch-resolve.sh <brief-file> [--project <name>]
#
# Opt-in gate: TYPESAFE_PROVIDER selects which service serves Jev, defaulting
#   to `typesafe` and accepting `openrouter`, and the selected service's key
#   (TYPESAFE_API_KEY or OPENROUTER_API_KEY) activates the tool. Each setting is
#   read from this process environment first, then from a KEY= line in
#   $FM_HOME/.env read with fmx_env_get, the same accessor as FMX_PAIRING_TOKEN
#   (bin/fm-env-lib.sh); the environment wins. An ambient OPENROUTER_API_KEY
#   alone never activates the tool because that gateway key is common in other
#   tools' environments, so `openrouter` must be selected explicitly; an unknown
#   non-empty TYPESAFE_PROVIDER is an actionable exit 2 configuration error.
#   Absent key: one "dispatch-resolve: off" line on stderr, nothing on stdout,
#   exit 0, no network call, so firstmate dispatches exactly as today. The key
#   lives in one shell variable and reaches curl as a header read from a file
#   descriptor, never on argv; nothing logs or writes it.
#
# What it does when on with at least one rule: one POST to the selected service
#   - https://api.typesafe.ai/v1/systemone with model `jev-latest`, or
#   https://openrouter.ai/api/alpha/decisions with model `typesafe/jev-1.13` -
#   with the project name and the whole brief as
#   state and ONE Choice question whose
#   options are every rule's `when` from config/crew-dispatch.json plus one
#   fixed generic none option. Jev returns the matched rule, a probability per
#   option, and a confidence. Everything after that is jq: the confidence
#   floor, the rule's declared `approval` and `floor`, each profile's declared
#   `provider` and `floor`, the quota rows from ONE quota-axi --json snapshot,
#   and the spendPriority argmax over the eligible candidates. The model never
#   sees quota, catalogs, approvals, `why`, or `use`. With no rules, it returns
#   a non-clear result so firstmate keeps using the existing intake.
#   docs/configuration.md "Crew dispatch profiles" owns the declared fields and
#   "Typed dispatch resolution" owns this tool's operator contract.
#
# Output (stdout, TOON-style block):
#   dispatch-resolve:
#     status: clear | ambiguous | escalate | error
#     model/latency_ms/tokens, rule (when excerpt) and confidence, probabilities
#     reason: <why the status is not clear>
#     candidate: <harness>:<model> provider=.. scope=.. remaining=..% spendPriority=.. runway=.. -> eligible | eligible, unranked: <reason> | not eligible: <reason>
#     profile: --harness <h> [--model <m>] [--effort <e>]     (status clear only)
#   clear     -> pass the profile line to fm-spawn.sh unless you state a reason to override
#   ambiguous -> confidence below the floor; decide as today from the probabilities
#   escalate  -> the rule requires captain approval, no candidate is rankable, or a genuine tie
#   error     -> API, network, response, or quota-axi failure; decide as today
#   Every outcome exits 0 so an intake is never blocked by this tool.
#   Exit 2 only for a usage or configuration error (unreadable brief, an
#   existing unreadable rules file, malformed rules, or missing jq), which is
#   actionable, never selected around.
#
# Environment:
#   TYPESAFE_PROVIDER selects `typesafe` (default) or `openrouter`, and the
#   selected service's key (TYPESAFE_API_KEY or OPENROUTER_API_KEY) activates
#   the tool; those are the only resolver-specific environment settings.
#
# Authority: this tool never replaces firstmate's judgment, quota-array-dispatch,
#   the captain-approval gate, or fm-spawn.sh validation; it publishes one
#   inspectable answer plus every candidate's evidence, in code.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY
OPENROUTER_API_KEY_PRIVATE=${OPENROUTER_API_KEY:-}
export -n OPENROUTER_API_KEY_PRIVATE 2>/dev/null || true
unset OPENROUTER_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"

CONFIDENCE_FLOOR=0.6
TS_TIMEOUT=5
TYPESAFE_ENDPOINT=https://api.typesafe.ai/v1/systemone
TYPESAFE_MODEL=jev-latest
OPENROUTER_ENDPOINT=https://openrouter.ai/api/alpha/decisions
OPENROUTER_MODEL=typesafe/jev-1.13
DEFAULT_WHEN="No listed rule applies to this task."

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
no_rules() {
  printf 'dispatch-resolve:\n  status: escalate\n  reason: no rules to match\n'
  exit 0
}
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

BRIEF='' PROJECT='' RULES_PATH="$CONFIG/crew-dispatch.json" RULES=''
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || die "--project needs a value"; PROJECT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$BRIEF" ] || die "one brief file only"; BRIEF=$1; shift ;;
  esac
done

# ---- provider and opt-in gate --------------------------------------------------
TYPESAFE_PROVIDER_VALUE=${TYPESAFE_PROVIDER:-}
[ -n "$TYPESAFE_PROVIDER_VALUE" ] || TYPESAFE_PROVIDER_VALUE=$(fmx_env_get TYPESAFE_PROVIDER "$FM_HOME/.env")
case "$TYPESAFE_PROVIDER_VALUE" in
  ''|typesafe)
    JEV_PROVIDER=typesafe
    JEV_KEY_NAME=TYPESAFE_API_KEY
    JEV_API_KEY=$TYPESAFE_API_KEY_PRIVATE
    JEV_ENDPOINT=$TYPESAFE_ENDPOINT
    JEV_MODEL=$TYPESAFE_MODEL
    ;;
  openrouter)
    JEV_PROVIDER=openrouter
    JEV_KEY_NAME=OPENROUTER_API_KEY
    JEV_API_KEY=$OPENROUTER_API_KEY_PRIVATE
    JEV_ENDPOINT=$OPENROUTER_ENDPOINT
    JEV_MODEL=$OPENROUTER_MODEL
    ;;
  *) die "unknown TYPESAFE_PROVIDER: $TYPESAFE_PROVIDER_VALUE (expected typesafe or openrouter)" ;;
esac
if [ -z "$JEV_API_KEY" ]; then
  JEV_API_KEY=$(fmx_env_get "$JEV_KEY_NAME" "$FM_HOME/.env")
fi
if [ -z "$JEV_API_KEY" ]; then
  echo "dispatch-resolve: off ($JEV_KEY_NAME absent from the environment and $FM_HOME/.env, with TYPESAFE_PROVIDER=${TYPESAFE_PROVIDER_VALUE:-typesafe})" >&2
  exit 0
fi

# ---- inputs --------------------------------------------------------------------
[ -n "$BRIEF" ] || die "brief file required (see --help)"
[ -r "$BRIEF" ] || die "brief file not readable: $BRIEF"
[ -e "$RULES_PATH" ] || [ -L "$RULES_PATH" ] || no_rules
[ -r "$RULES_PATH" ] || die "rules file not readable: $RULES_PATH"
command -v jq >/dev/null 2>&1 || die "jq required"
RULES=$(mktemp) || die "mktemp failed"
trap 'rm -f "$RULES"' EXIT
cp "$RULES_PATH" "$RULES" || die "could not snapshot rules file: $RULES_PATH"
chmod 400 "$RULES" || die "could not protect rules snapshot"
VERIFIED_HARNESSES=$(fm_control_harnesses | jq -Rsc 'split("\n") | map(select(length > 0))')

# The fields this tool consumes must be well formed; bootstrap owns the wider
# schema diagnostic, but an intake never selects around a malformed file.
rules_err=$(jq -r --argjson verified_harnesses "$VERIFIED_HARNESSES" --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
  def verified($h): $verified_harnesses | index($h);
  def provider_id($p): ($p | type) == "string" and ($p | test($provider_re));
  def effort_ok($h; $m; $e):
    if $e == null then true
    elif ($e | type) != "string" then false
    elif $e == "ultra" then (($h == "pi" or $h == "pi-signed") and (($m | type) == "string") and ($m | startswith("codex-native/")) and ($m | length) > 13)
    elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "codex" then ((["low","medium","high","xhigh"] | index($e)) != null or ($e == "max" and $m == "gpt-5.6-luna"))
    elif $h == "grok" or $h == "agy" then (["low","medium","high"] | index($e)) != null
    elif $h == "pi" or $h == "pi-signed" or $h == "omp" or $h == "muse" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "rovo" then (["low","medium","high","max"] | index($e)) != null
    elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
    else true end;
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def floor_bad($f; $need_provider):
    ($f | type) != "object"
    or (($f.scope | type) != "string") or (($f.scope | length) == 0)
    or (($f.min_percent | type) != "number") or ($f.min_percent < 0) or ($f.min_percent > 100)
    or (if $need_provider
        then (provider_id($f.provider) | not)
        else ($f | has("provider"))
        end);
  def profile_bad($p):
    ($p | type) != "object"
    or (($p.harness | type) != "string") or (($p.harness | length) == 0)
    or ($p | has("model") and ((.model | type) != "string" or (.model | length) == 0))
    or ($p | has("effort") and ((.effort | type) != "string" or (.effort | length) == 0))
    or ($p | has("provider") and (provider_id(.provider) | not))
    or ($p | has("floor") and floor_bad(.floor; false));
  def duplicate_profiles($items):
    ($items | map([.harness, (.model // null), (.effort // null)] | @json)) as $keys
    | ($keys | length) != ($keys | unique | length);
  if type != "object" then "top-level value must be an object"
  elif has("rules") and (.rules | type) != "array" then "rules must be an array"
  elif any((.rules // [])[]; type != "object") then "each rule must be an object"
  elif any((.rules // [])[]; (.when | type) != "string" or (.when | length) == 0) then "each rule needs non-empty when"
  elif any((.rules // [])[]; (profiles(.use) | length) == 0) then "each rule needs at least one use profile"
  elif any((.rules // [])[]; has("approval") and .approval != "captain") then "approval must be \"captain\" when present"
  elif any((.rules // [])[]; has("select") and ((.select | type) != "string" or (.select | length) == 0)) then "select must be a non-empty string"
  elif any((.rules // [])[]; has("select") and .select != "quota-balanced") then
    "unknown select: " + ([.rules[] | select(has("select") and .select != "quota-balanced") | .select] | unique | join(", "))
  elif any((.rules // [])[]; has("floor") and floor_bad(.floor; true)) then "rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\\z"
  elif any((.rules // [])[] | profiles(.use)[]; profile_bad(.)) then "each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif any((.rules // [])[]; duplicate_profiles(profiles(.use))) then "each rule use must not contain duplicate harness, model, and effort profiles"
  elif any((.rules // [])[] | profiles(.use)[]; (verified(.harness) | not)) then "each use profile must name a verified harness"
  elif any((.rules // [])[] | profiles(.use)[]; (effort_ok(.harness; .model; .effort) | not)) then "each use profile effort must be supported by its harness and model"
  elif has("default") and (profiles(.default) | length) == 0 then "default must be a profile object or non-empty profile array"
  elif has("default") and any(profiles(.default)[]; profile_bad(.)) then "each default profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif has("default") and duplicate_profiles(profiles(.default)) then "default must not contain duplicate harness, model, and effort profiles"
  elif has("default") and any(profiles(.default)[]; (verified(.harness) | not)) then "each default profile must name a verified harness"
  elif has("default") and any(profiles(.default)[]; (effort_ok(.harness; .model; .effort) | not)) then "each default profile effort must be supported by its harness and model"
  else empty end
' "$RULES" 2>/dev/null) || die "malformed rules file: $RULES_PATH (not JSON)"
[ -z "$rules_err" ] || die "malformed rules file: $RULES_PATH - $rules_err"

missing_provider=$(jq -r '
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  ((.rules // [])[] | profiles(.use)[] | select(has("provider") | not) | "use\t\(.harness)"),
  (profiles(.default // null)[] | select(has("provider") | not) | "default\t\(.harness)")
' "$RULES" | while IFS=$'\t' read -r location harness; do
  if ! fm_quota_single_provider_for_harness "$harness" >/dev/null; then
    printf '%s\t%s\n' "$location" "$harness"
    break
  fi
done)
if [ -n "$missing_provider" ]; then
  IFS=$'\t' read -r location harness <<< "$missing_provider"
  die "malformed rules file: $RULES_PATH - $location profiles whose harness lacks one authoritative provider family require provider: $harness"
fi

# ---- harness -> provider map, from the single owner in fm-quota-axi-lib.sh -----
PMAP='{}'
while IFS= read -r h; do
  [ -n "$h" ] || continue
  p=$(fm_quota_single_provider_for_harness "$h" 2>/dev/null) || p=''
  PMAP=$(jq -c --arg h "$h" --arg p "$p" '. + {($h): (if $p == "" then null else $p end)}' <<<"$PMAP")
done < <(jq -r '
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  ([((.rules // [])[]) | profiles(.use)[]] + profiles(.default // null))
  | map(.harness) | unique | .[]' "$RULES")

RULE_COUNT=$(jq -r '(.rules // []) | length' "$RULES")

emit_error() {
  local reason=$1
  echo "dispatch-resolve: error ($reason)" >&2
  printf 'dispatch-resolve:\n  status: error\n  reason: %s\n' "$reason"
  exit 0
}

if [ "$RULE_COUNT" -eq 0 ]; then
  no_rules
fi

RESP_FILE=$(mktemp) || die "mktemp failed"
QUOTA=$(mktemp) || { rm -f "$RESP_FILE"; die "mktemp failed"; }
trap 'rm -f "$RULES" "$RESP_FILE" "$QUOTA"' EXIT
LAT_MS=null
command -v curl >/dev/null 2>&1 || emit_error "curl not installed"
  REQUEST=$(jq -n --rawfile brief "$BRIEF" --arg project "$PROJECT" --arg model "$JEV_MODEL" \
    --arg none_criterion "$DEFAULT_WHEN" --slurpfile rules "$RULES" '
    ($rules[0]) as $cfg |
    ($cfg.rules | to_entries | map({key: ("rule_" + ((.key + 1) | tostring)), value: .value.when}) | from_entries) as $criteria |
    {
      model: $model,
      state: {task: {project: $project, brief: $brief}},
      questions: {
        rule: {
          type: "choice",
          instructions: "Which ONE dispatch rule best fits `task` (read `task.brief` and `task.project`)? Each option is the rule'"'"'s own matching condition; pick `default` when no rule'"'"'s condition is met, including when a rule'"'"'s own exemption text excludes this task.",
          criteria: ($criteria + {default: $none_criterion})
        }
      }
    }')
  T0=$(fm_timing_now_ms)
  HTTP=$(printf '%s' "$REQUEST" | curl -sS --max-time "$TS_TIMEOUT" -o "$RESP_FILE" -w '%{http_code}' \
    -X POST "$JEV_ENDPOINT" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$JEV_API_KEY") \
    --data-binary @- 2>/dev/null) || HTTP=000
  T1=$(fm_timing_now_ms)
  LAT_MS=$(( T1 - T0 ))
  [ "$HTTP" = 200 ] || emit_error "http $HTTP after ${LAT_MS} ms: $(head -c 200 "$RESP_FILE" 2>/dev/null | tr '\n' ' ')"
jq -e --slurpfile rules "$RULES" '
    (($rules[0].rules | to_entries | map("rule_" + ((.key + 1) | tostring))) + ["default"] | sort) as $choices |
    (.answers.rule.choice | type) == "string" and
    (.answers.rule.confidence | type) == "number" and
    .answers.rule.confidence >= 0 and .answers.rule.confidence <= 1 and
    (.answers.rule.probabilities | type) == "object" and
    ((.answers.rule.probabilities | keys | sort) == $choices) and
    all(.answers.rule.probabilities[]; type == "number" and . >= 0 and . <= 1) and
    ((.answers.rule.probabilities | [.[]] | add) as $total | $total >= 0.99 and $total <= 1.01) and
    ((has("usage") | not) or
      ((.usage | type) == "object" and
       (.usage.input_tokens | type) == "number" and
       (.usage.output_tokens | type) == "number"))' \
  "$RESP_FILE" >/dev/null 2>&1 || emit_error "response is not a rule Choice answer"

# ---- quota evidence: one quota-axi --json snapshot -----------------------------
command -v quota-axi >/dev/null 2>&1 || emit_error "quota-axi not installed"
quota-axi --json > "$QUOTA" 2>/dev/null || emit_error "quota-axi --json failed"
fm_quota_json_valid < "$QUOTA" || emit_error "quota-axi --json returned an invalid snapshot"

# ---- resolution: declared gates + quota evidence + argmax, all in jq ------------
RESULT=$(jq -n --arg floor "$CONFIDENCE_FLOOR" --argjson lat "$LAT_MS" --arg none_criterion "$DEFAULT_WHEN" --argjson pmap "$PMAP" \
  --slurpfile resp "$RESP_FILE" --slurpfile rules "$RULES" --slurpfile quota "$QUOTA" '
  ($resp[0]) as $r | ($rules[0]) as $cfg | ($quota[0]) as $q | ($r.answers.rule) as $a |
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def prov($p): ([$q.providers[] | select(.provider == $p)] | first) // null;
  def rows($p): (prov($p) | .quotaSemantics.effectiveAvailability // []);
  def bare($m): ($m | split("/") | last);
  def provider_of($c): ($c.provider // $pmap[$c.harness] // null);
  def measured($p):
    (prov($p) != null and (["known", "partial"] | index(prov($p).quotaSemantics.status)) != null);
  def applicable($p; $m):
    (bare($m)) as $bare |
    [rows($p)[] | select(
      .scope == "all_models" or .scope == "all_products" or
      ($m != "" and (.scope == ("model:" + $bare) or .scope == ("product:" + $bare)))
    )];
  def floor_state($f; $p):
    if $f == null then "none"
    elif prov($p) == null or (measured($p) | not) then "unknown"
    else [rows($p)[] | select(.scope == $f.scope)] as $matches
      | if ($matches | length) == 0 or any($matches[]; .status != "known") then "unknown"
        elif any($matches[]; .effectivePercentRemaining < $f.min_percent) then "below"
        else "ok"
        end
    end;
  def evidence($rows):
    $rows | map({scope, status, pct: (.effectivePercentRemaining // null), runway: (.runway.status // null), spendPriority: (.selection.spendPriority // null)});
  def evaluate($c):
    (provider_of($c)) as $p |
    if $p == null then {profile: $c, eligible: false, reason: "no provider family for harness \($c.harness); declare provider on the profile"}
    elif prov($p) == null then {profile: $c, provider: $p, eligible: true, unranked: true, reason: "provider \($p) not in the quota snapshot"}
    else
      (applicable($p; ($c.model // ""))) as $rows |
      (evidence($rows)) as $bounds |
      (floor_state($c.floor; $p)) as $profile_floor_state |
      if any($rows[]; (.runway.status // "") == "exhausted_now") then
        ($rows | map(select((.runway.status // "") == "exhausted_now")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: ($bad.effectivePercentRemaining // null), runway: $bad.runway.status, eligible: false, reason: "runway exhausted_now at \($bad.scope)"}
      elif any($rows[]; .status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0) then
        ($rows | map(select(.status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0)) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: false, reason: "0% remaining at \($bad.scope)"}
      elif $profile_floor_state == "below" then
        ([rows($p)[] | select(
          .scope == $c.floor.scope and
          .effectivePercentRemaining < $c.floor.min_percent
        )] | first) as $floor_row |
        {profile: $c, provider: $p, bounds: $bounds, scope: ($floor_row.scope // $c.floor.scope), pct: ($floor_row.effectivePercentRemaining // null), runway: ($floor_row.runway.status // null), eligible: false, reason: "profile floor \($c.floor.scope) below \($c.floor.min_percent)%"}
      elif (measured($p) | not) then
        ($rows | first) as $row |
        {profile: $c, provider: $p, bounds: $bounds, scope: ($row.scope // null), pct: ($row.effectivePercentRemaining // null), runway: ($row.runway.status // null), eligible: true, unranked: true, unknown: true, reason: "provider \($p) unmeasured (\(prov($p).quotaSemantics.status))"}
      elif ($rows | length) == 0 then
        {profile: $c, provider: $p, bounds: $bounds, eligible: true, unranked: true, unknown: true, reason: "no applicable quota row for provider \($p)"}
      elif $profile_floor_state == "unknown" then
        ([rows($p)[] | select(.scope == $c.floor.scope)] | first) as $floor_row |
        {profile: $c, provider: $p, bounds: $bounds, scope: $c.floor.scope, pct: ($floor_row.effectivePercentRemaining // null), runway: ($floor_row.runway.status // null), eligible: true, unranked: true, unknown: true, reason: "profile floor \($c.floor.scope) is unverifiable: not rankable"}
      elif any($rows[]; .status != "known") then
        ($rows | map(select(.status != "known")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, eligible: true, unranked: true, unknown: true, reason: "quota row \($bad.scope) unknown: not rankable"}
      elif any($rows[]; (.selection.spendPriority | type) != "number") then
        ($rows | map(select((.selection.spendPriority | type) != "number")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: true, unranked: true, reason: "spendPriority missing or non-numeric at \($bad.scope): not rankable"}
      else
        ($rows | min_by(.selection.spendPriority)) as $limiting |
        {profile: $c, provider: $p, bounds: $bounds, scope: $limiting.scope, pct: $limiting.effectivePercentRemaining,
         spendPriority: $limiting.selection.spendPriority, runway: $limiting.runway.status, eligible: true, reason: "ok"}
      end
    end;
  ($a.choice) as $choice |
  (if ($choice | test("^rule_[1-9][0-9]*$"))
   then ($choice | ltrimstr("rule_") | tonumber)
   else null end) as $rule_number |
  (if $choice == "default" then null
   elif $rule_number != null and $rule_number <= (($cfg.rules // []) | length) then $cfg.rules[$rule_number - 1]
   else null end) as $rule |
  (if $rule == null then "none" else floor_state($rule.floor; $rule.floor.provider) end) as $rule_floor_state |
  (if $choice != "default" and $rule == null then []
   elif $rule == null then profiles($cfg.default // null)
   else profiles($rule.use)
   end) as $answer_use |
  (if $choice != "default" and $rule == null then {invalid: "rule \($choice) is not in the rules file"}
   elif $rule == null then {source: "default", use: profiles($cfg.default // null), note: "no rule matched"}
   elif ($rule.approval // "") == "captain" then {source: $choice, escalate: "rule requires the captain'"'"'s explicit approval before dispatch"}
   elif $rule_floor_state == "unknown" then {source: $choice, escalate: "rule \($choice) floor \($rule.floor.provider)/\($rule.floor.scope) is unverifiable"}
   elif $rule_floor_state == "below"
     then {source: "default", use: profiles($cfg.default // null), note: "rule \($choice) floor \($rule.floor.scope) below \($rule.floor.min_percent)%: fall through to default"}
   else {source: $choice, use: profiles($rule.use), note: "rule matched"} end) as $sel |
  {
    model: $r.model, latency_ms: $lat, tokens: ($r.usage // null),
    rule: $choice,
    rule_when: (if $rule == null then $none_criterion else $rule.when end | .[0:60]),
    confidence: $a.confidence, probabilities: $a.probabilities
  } as $ev |
  if $sel.invalid then $ev + {status: "error", reason: $sel.invalid}
  elif $a.confidence < ($floor | tonumber) then
    $ev + {status: "ambiguous", reason: "confidence \($a.confidence) below floor \($floor)", candidates: ($answer_use | map(evaluate(.)))}
  elif $sel.escalate then
    $ev + {status: "escalate", reason: $sel.escalate, candidates: ($answer_use | map(evaluate(.)))}
  elif ($sel.use | length) == 0 then $ev + {status: "escalate", reason: "no profiles configured for \($sel.source)", note: $sel.note, candidates: []}
  else
    ($sel.use | map(evaluate(.))) as $cands |
    ([$cands[] | select(.eligible and ((.unranked // false) | not))]) as $elig |
    ([$cands[] | select(.unranked)]) as $unranked |
    if ($elig | length) == 0 then $ev + {status: "escalate", reason: "no rankable eligible candidate", note: $sel.note, candidates: $cands}
    else
      ($elig | max_by(.spendPriority)) as $best |
      ([$elig[] | select(.spendPriority == $best.spendPriority)] | length) as $ties |
      if $ties > 1 then $ev + {status: "escalate", reason: "genuine spendPriority tie", note: $sel.note, candidates: $cands}
      else $ev + {status: "clear", note: $sel.note, candidates: $cands, chosen: $best}
        + (if ($unranked | length) > 0 then
             {unranked_note: "\($unranked | length) eligible candidate(s) unranked (\([$unranked[].provider] | unique | join(", ")))"}
           else {} end)
      end
    end
  end') || emit_error "resolution failed"

TEXT=$(jq -r '
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($value): ($value // "-") | flat;
  def shell_arg: flat | @sh;
  "dispatch-resolve:",
  "  status: \(.status | flat)",
  "  model: \(show(.model))   latency_ms: \(show(.latency_ms))   tokens: \(show(.tokens.input_tokens))/\(show(.tokens.output_tokens))",
  "  rule: \(.rule | flat) (\(.rule_when | flat))   confidence: \(.confidence | flat)",
  "  probabilities: \([.probabilities | to_entries[] | "\(.key | flat)=\(.value | flat)"] | join(" "))",
  (if .reason then "  reason: \(.reason | flat)" else empty end),
  (if .note then "  note: \(.note | flat)" else empty end),
  (if .unranked_note then "  note: \(.unranked_note | flat)" else empty end),
  (.candidates[]? | "  candidate: \(.profile.harness | flat):\(show(.profile.model))"
      + (if .provider then "  provider=\(.provider | flat)" else "" end)
      + (if .scope then "  scope=\(.scope | flat)  remaining=\(show(.pct))%  spendPriority=\(show(.spendPriority))  runway=\(show(.runway))" else "" end)
      + (if (.bounds // [] | length) > 1 then "  bounds=" + ([.bounds[] | "\(.scope | flat):\(show(.pct))%/\((.runway // .status) | flat)"] | join(",")) else "" end)
      + "  -> " + (if .unranked then "eligible, unranked: \(.reason | flat): disclosed uncertainty" elif .eligible then "eligible" else "not eligible: \(.reason | flat)" end)),
  (if .chosen then "  profile: --harness \(.chosen.profile.harness | shell_arg)"
      + (if .chosen.profile.model then " --model \(.chosen.profile.model | shell_arg)" else "" end)
      + (if .chosen.profile.effort then " --effort \(.chosen.profile.effort | shell_arg)" else "" end) else empty end)' <<<"$RESULT") || emit_error "output rendering failed"
printf '%s\n' "$TEXT"
exit 0
