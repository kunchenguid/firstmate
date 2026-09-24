#!/usr/bin/env bash
# fm-dispatch-resolve.sh - resolve one concrete crewmate or scout dispatch
# profile from a task brief with typesafe.ai's System One model (Jev), opt-in.
#
# Usage:
#   fm-dispatch-resolve.sh <brief-file> [--project <name>]
#
# Opt-in gate: TYPESAFE_API_KEY non-empty in this process environment, else a
#   TYPESAFE_API_KEY= line in $FM_HOME/.env read with fmx_env_get, the same
#   accessor as FMX_PAIRING_TOKEN (bin/fm-env-lib.sh). The environment wins.
#   Absent in both: one "dispatch-resolve: off" line on stderr, nothing on
#   stdout, exit 0, no network call, so firstmate dispatches exactly as today.
#   The key lives in one shell variable and reaches curl as a header read from
#   a file descriptor, never on argv; nothing logs or writes it.
#
# What it does when on with at least one rule: one POST to
#   https://api.typesafe.ai/v1/systemone with the project name and the whole brief as
#   state and ONE Choice question whose
#   options are every rule's `when` from config/crew-dispatch.json plus one
#   fixed generic none option. Jev returns the matched rule, a probability per
#   option, and a confidence. Everything after that is jq: the confidence
#   floor, the rule's declared `approval` and `floor`, each profile's declared
#   `provider` and `floor`, the quota rows from ONE quota-axi --json snapshot
#   (schema 5 or 6; each candidate binds to one row through quota_row in
#   bin/fm-quota-axi-lib.sh, so a Pi lane such as openai-codex-work/...
#   reads its own account's row and an expanded provider with no row for the
#   candidate is unmeasured, never blocked), and the spendPriority argmax over
#   the eligible candidates. The model never
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
#   TYPESAFE_API_KEY is the only resolver-specific environment setting.
#
# Authority: this tool never replaces firstmate's judgment, quota-array-dispatch,
#   the captain-approval gate, or fm-spawn.sh validation; it publishes one
#   inspectable answer plus every candidate's evidence, in code.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

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
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"

CONFIDENCE_FLOOR=0.6
TS_MODEL=jev-latest
TS_BASE=https://api.typesafe.ai
TS_TIMEOUT=5
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

# ---- opt-in gate ---------------------------------------------------------------
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
fi
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  echo "dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env)" >&2
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
CATALOG_METHOD_HARNESSES=$("$SCRIPT_DIR/fm-model-catalog.sh" --list-harnesses | jq -Rsc 'split("\n") | map(select(length > 0))') || die "could not read model catalog methods"

# The fields this tool consumes must be well formed; bootstrap owns the wider
# schema diagnostic, but an intake never selects around a malformed file.
rules_err=$(jq -r --argjson verified_harnesses "$VERIFIED_HARNESSES" --argjson catalog_method_harnesses "$CATALOG_METHOD_HARNESSES" --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
  def verified($h): $verified_harnesses | index($h);
  def catalog_method($h): $catalog_method_harnesses | index($h);
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
  def dynamic($v): ($v | type) == "object" and ((($v.discover // null) | type) == "object");
  def profiles($v): if dynamic($v) then [] elif ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
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
  def string_array($v): ($v | type) == "array" and all($v[]; (type == "string" and length > 0));
  def unsupported_catalog_harness($d):
    if ($d.harnesses | type) == "array" then any($d.harnesses[]; catalog_method(.) == null) else false end;
  def dynamic_bad($d):
    (($d.task_type | type) != "string" or ($d.task_type | length) == 0)
    or ((["low","medium","high","xhigh","max"] | index($d.required_reasoning_class)) == null)
    or (string_array($d.harnesses) | not)
    or (($d.harnesses | length) == 0)
    or unsupported_catalog_harness($d)
    or ($d | has("providers") and ((string_array($d.providers) | not) or any($d.providers[]; provider_id(.) | not)))
    or ($d | has("preferred_models") and (string_array($d.preferred_models) | not))
    or ($d | has("preferred_families") and (string_array($d.preferred_families) | not))
    or ($d | has("floor") and floor_bad($d.floor; false));
  if type != "object" then "top-level value must be an object"
  elif has("rules") and (.rules | type) != "array" then "rules must be an array"
  elif any((.rules // [])[]; type != "object") then "each rule must be an object"
  elif any((.rules // [])[]; (.when | type) != "string" or (.when | length) == 0) then "each rule needs non-empty when"
  elif any((.rules // [])[]; (dynamic(.use) | not) and (profiles(.use) | length) == 0) then "each rule needs at least one use profile"
  elif any((.rules // [])[]; dynamic(.use) and dynamic_bad(.use.discover)) then "dynamic use needs discover.task_type, required_reasoning_class, non-empty harnesses, optional providers, preferred_models, preferred_families, and floor with well formed values"
  elif any((.rules // [])[]; has("approval") and .approval != "captain") then "approval must be \"captain\" when present"
  elif any((.rules // [])[]; has("select") and ((.select | type) != "string" or (.select | length) == 0)) then "select must be a non-empty string"
  elif any((.rules // [])[]; has("select") and .select != "quota-balanced") then
    "unknown select: " + ([.rules[] | select(has("select") and .select != "quota-balanced") | .select] | unique | join(", "))
  elif any((.rules // [])[]; has("floor") and floor_bad(.floor; true)) then "rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\\z"
  elif any((.rules // [])[] | profiles(.use)[]; profile_bad(.)) then "each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif any((.rules // [])[]; duplicate_profiles(profiles(.use))) then "each rule use must not contain duplicate harness, model, and effort profiles"
  elif any((.rules // [])[] | select(dynamic(.use)) | .use.discover.harnesses[]; (verified(.) | not)) then "dynamic use harnesses must name verified harnesses"
  elif any((.rules // [])[] | profiles(.use)[]; (verified(.harness) | not)) then "each use profile must name a verified harness"
  elif any((.rules // [])[] | profiles(.use)[]; (effort_ok(.harness; .model; .effort) | not)) then "each use profile effort must be supported by its harness and model"
  elif has("default") and (dynamic(.default) | not) and (profiles(.default) | length) == 0 then "default must be a profile object or non-empty profile array"
  elif has("default") and dynamic(.default) and dynamic_bad(.default.discover) then "dynamic default needs discover.task_type, required_reasoning_class, non-empty harnesses, optional providers, preferred_models, preferred_families, and floor with well formed values"
  elif has("default") and any(profiles(.default)[]; profile_bad(.)) then "each default profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif has("default") and duplicate_profiles(profiles(.default)) then "default must not contain duplicate harness, model, and effort profiles"
  elif has("default") and dynamic(.default) and any(.default.discover.harnesses[]; (verified(.) | not)) then "dynamic default harnesses must name verified harnesses"
  elif has("default") and any(profiles(.default)[]; (verified(.harness) | not)) then "each default profile must name a verified harness"
  elif has("default") and any(profiles(.default)[]; (effort_ok(.harness; .model; .effort) | not)) then "each default profile effort must be supported by its harness and model"
  else empty end
' "$RULES" 2>/dev/null) || die "malformed rules file: $RULES_PATH (not JSON)"
[ -z "$rules_err" ] || die "malformed rules file: $RULES_PATH - $rules_err"

missing_provider=$(jq -r '
  def dynamic($v): ($v | type) == "object" and ((($v.discover // null) | type) == "object");
  def profiles($v): if dynamic($v) then [] elif ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
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
  def dynamic($v): ($v | type) == "object" and ((($v.discover // null) | type) == "object");
  def profiles($v): if dynamic($v) then [] elif ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
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
CATALOG=$(mktemp) || { rm -f "$RESP_FILE" "$QUOTA"; die "mktemp failed"; }
: > "$CATALOG" || die "could not initialize catalog snapshot"
trap 'rm -f "$RULES" "$RESP_FILE" "$QUOTA" "$CATALOG"' EXIT
LAT_MS=null
command -v curl >/dev/null 2>&1 || emit_error "curl not installed"
  REQUEST=$(jq -n --rawfile brief "$BRIEF" --arg project "$PROJECT" --arg model "$TS_MODEL" \
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
    -X POST "$TS_BASE/v1/systemone" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") \
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

# ---- dynamic catalog evidence for the selected policy, if any ------------------
CATALOG_HARNESSES=()
while IFS= read -r catalog_harness; do
  [ -n "$catalog_harness" ] || continue
  CATALOG_HARNESSES[${#CATALOG_HARNESSES[@]}]=$catalog_harness
done < <(jq -n -r --slurpfile resp "$RESP_FILE" --slurpfile rules "$RULES" --slurpfile quota "$QUOTA" "$FM_QUOTA_ROW_JQ"'
  def dynamic($v): ($v | type) == "object" and ((($v.discover // null) | type) == "object");
  def floor_below($f):
    if ($f | type) != "object" then false
    else (quota_row($quota[0]; $f.provider; "")) as $row |
      if $row == null or ((["known", "partial"] | index($row.quotaSemantics.status)) | not) then false
      else [($row.quotaSemantics.effectiveAvailability // [])[] | select(.scope == $f.scope)] as $matches |
        ($matches | length) > 0 and all($matches[]; .status == "known") and
        any($matches[]; .effectivePercentRemaining < $f.min_percent)
      end
    end;
  ($resp[0].answers.rule.choice) as $choice |
  (if ($choice | test("^rule_[1-9][0-9]*$")) then ($choice | ltrimstr("rule_") | tonumber) else null end) as $rule_number |
  (if $choice == "default" then
     [($rules[0].default // null)]
   elif $rule_number != null and $rule_number <= (($rules[0].rules // []) | length) then
     ($rules[0].rules[$rule_number - 1]) as $rule |
     [$rule.use, (if floor_below($rule.floor) then ($rules[0].default // null) else null end)]
   else []
   end)[] |
  select(dynamic(.)) |
  .discover.harnesses[]
' /dev/null | awk '!seen[$0]++')
if [ "${#CATALOG_HARNESSES[@]}" -gt 0 ]; then
  for catalog_harness in "${CATALOG_HARNESSES[@]}"; do
    catalog_account=''
    case "$catalog_harness" in
      claude|pi|pi-signed)
        catalog_account=$(fm_worker_account_resolve "$catalog_harness" "$CONFIG") ||
          emit_error "could not resolve $catalog_harness worker account for model catalog"
        ;;
    esac
    case "$catalog_harness" in
      claude)
        if [ -n "$catalog_account" ]; then
          IFS=$'\t' read -r catalog_declared catalog_root catalog_providers <<< "$catalog_account"
          catalog_env=(env)
          for catalog_var in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do
            catalog_env[${#catalog_env[@]}]=-u
            catalog_env[${#catalog_env[@]}]=$catalog_var
          done
          if [ -n "$catalog_root" ]; then
            catalog_env[${#catalog_env[@]}]="CLAUDE_CONFIG_DIR=$catalog_root"
          else
            catalog_env[${#catalog_env[@]}]=-u
            catalog_env[${#catalog_env[@]}]=CLAUDE_CONFIG_DIR
          fi
          "${catalog_env[@]}" "$SCRIPT_DIR/fm-model-catalog.sh" "$catalog_harness" >> "$CATALOG" 2>/dev/null || true
        else
          "$SCRIPT_DIR/fm-model-catalog.sh" "$catalog_harness" >> "$CATALOG" 2>/dev/null || true
        fi
        ;;
      pi|pi-signed)
        if [ -n "$catalog_account" ]; then
          IFS=$'\t' read -r catalog_declared catalog_root catalog_providers <<< "$catalog_account"
          PI_CODING_AGENT_DIR="$catalog_root" "$SCRIPT_DIR/fm-model-catalog.sh" "$catalog_harness" >> "$CATALOG" 2>/dev/null || true
        else
          "$SCRIPT_DIR/fm-model-catalog.sh" "$catalog_harness" >> "$CATALOG" 2>/dev/null || true
        fi
        ;;
      *)
        "$SCRIPT_DIR/fm-model-catalog.sh" "$catalog_harness" >> "$CATALOG" 2>/dev/null || true
        ;;
    esac
  done
fi

# ---- resolution: declared gates + quota evidence + argmax, all in jq ------------
RESULT=$(jq -n --arg floor "$CONFIDENCE_FLOOR" --argjson lat "$LAT_MS" --arg none_criterion "$DEFAULT_WHEN" --argjson pmap "$PMAP" \
  --slurpfile resp "$RESP_FILE" --slurpfile rules "$RULES" --slurpfile quota "$QUOTA" --slurpfile catalog "$CATALOG" "$FM_QUOTA_ROW_JQ"'
  ($resp[0]) as $r | ($rules[0]) as $cfg | ($quota[0]) as $q | ($r.answers.rule) as $a |
  def dynamic($v): ($v | type) == "object" and ((($v.discover // null) | type) == "object");
  def profiles($v): if dynamic($v) then [] elif ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def prov($p; $lane): quota_row($q; $p; $lane);
  def rows($p; $lane): (prov($p; $lane) | .quotaSemantics.effectiveAvailability // []);
  def bare($m): ($m | split("/") | last);
  def provider_of($c): ($c.provider // $pmap[$c.harness] // null);
  def lane_of($c): quota_lane($c.harness; $c.model);
  def reasoning_rank($class):
    if $class == "low" then 1 elif $class == "medium" then 2 elif $class == "high" then 3 elif $class == "xhigh" then 4 elif $class == "max" then 5 else 0 end;
  def inferred_reasoning($model; $provider):
    (($model // "") | ascii_downcase) as $m |
    (($provider // "") | ascii_downcase) as $p |
    if ($m | test("gpt-5\\.6-luna")) then "max"
    elif ($m | test("opus|fable|gpt-5\\.6|gpt-5\\.5|sol|grok-4|k3|k2\\.7|sonnet-5")) then "xhigh"
    elif ($m | test("sonnet|gpt-5|claude|kimi|codex|space-bunny")) then "high"
    elif ($p | test("claude|codex|opencode|grok|kimi|cursor")) then "medium"
    else "low" end;
  def catalog_reasoning($row):
    [($row.reasoningCapabilities // [])[]? | ascii_downcase | select(reasoning_rank(.) > 0)] | unique as $classes |
    if ($classes | length) == 0 then
      {class: inferred_reasoning($row.model; $row.provider), source: "prior", confidence: "low", known: false, capabilities: []}
    else
      {class: ($classes | max_by(reasoning_rank(.))), source: "catalog", confidence: "catalog", known: true, capabilities: $classes}
    end;
  def task_alias($task):
    (($task // "") | ascii_downcase) as $name |
    if (["implementation", "coding", "code", "software"] | index($name)) != null then "implementation"
    elif (["documentation", "docs", "writing", "writer"] | index($name)) != null then "documentation"
    else $name end;
  def task_fit_prior($task; $row):
    (task_alias($task)) as $task_name |
    (($row.model // "") + " " + ($row.provider // "") | ascii_downcase) as $identity |
    if $task_name == "implementation" and ($identity | test("code|coder|coding|dev|swe|software")) then
      {status: "prior", eligible: true, confidence: "low", reason: "low-confidence implementation prior from catalog identity"}
    elif $task_name == "documentation" and ($identity | test("doc|write|writing|sonnet|opus|haiku|claude|gemini|gpt")) then
      {status: "prior", eligible: true, confidence: "low", reason: "low-confidence documentation prior from catalog identity"}
    else
      {status: "unknown", eligible: true, confidence: "low", reason: ("catalog has no task metadata; task fit for " + $task_name + " is uncertain")}
    end;
  def task_fit($task; $row):
    (task_alias($task)) as $task_name |
    [($row.taskTypes // [])[]? | task_alias(.)] | unique as $declared_tasks |
    if ($declared_tasks | length) > 0 then
      if ($declared_tasks | index($task_name)) != null then
        {status: "supported", eligible: true, confidence: "catalog", reason: ("catalog declares " + $task_name)}
      else
        {status: "unsupported", eligible: false, confidence: "catalog", reason: ("catalog declares " + ($declared_tasks | join(", ")) + ", not " + $task_name)}
      end
    else
      task_fit_prior($task_name; $row)
    end;
  def preference($model; $d):
    (($model // "") | ascii_downcase) as $m |
    ((($d.preferred_models // []) | map(ascii_downcase) | index($m)) != null) as $model_hit |
    ((($d.preferred_families // []) | map(ascii_downcase)) as $families | any($families[]?; . as $family | ($m | contains($family)))) as $family_hit |
    if $model_hit then "preferred_model" elif $family_hit then "preferred_family" else "none" end;
  def dynamic_profiles($u):
    ($u.discover) as $d |
    ([ $catalog[]? | select(. as $row | $row.status == "error" and (($d.harnesses // []) | index($row.harness))) ]) as $errs |
    ([ $catalog[]? | select(. as $row | ($row.harness | type) == "string" and (($d.harnesses // []) | index($row.harness))) | .harness ] | unique) as $seen_harnesses |
    ([ ($d.harnesses // [])[] | select(($seen_harnesses | index(.)) == null) ]) as $missing |
    if ($errs | length) > 0 then
      {error: ("model catalog discovery failed: " + ([$errs[] | (.harness + ": " + (.reason // "unknown"))] | join("; ")))}
    elif ($missing | length) > 0 then
      {error: ("model catalog discovery returned no result for " + ($missing | join(", ")))}
    else
      ([ $catalog[]? |
        select(.status == "ok") |
        select(. as $row | (($d.harnesses // []) | index($row.harness))) |
        select(. as $row | ((($d.providers // []) | length) == 0 or (($d.providers // []) | index($row.provider)))) |
        (.model) as $model | (.provider) as $provider |
        (catalog_reasoning(.)) as $reasoning |
        (task_fit($d.task_type; .)) as $task_fit |
        (reasoning_rank($reasoning.class)) as $class_rank |
        (reasoning_rank($d.required_reasoning_class)) as $required_rank |
        {harness: .harness, model: $model, provider: $provider,
         catalogMethod: (.provenance.method // "unknown"), catalogCapabilities: $reasoning.capabilities,
         taskType: $d.task_type, taskFit: $task_fit.status, taskFitConfidence: $task_fit.confidence, taskFitReason: $task_fit.reason,
         fitClass: $reasoning.class, fitSource: $reasoning.source, fitConfidence: $reasoning.confidence,
         fitEligible: ($task_fit.eligible and (($reasoning.known | not) or ($class_rank >= $required_rank))),
         fitUnranked: ($reasoning.known | not),
         fitReason: (if ($reasoning.known | not) then "catalog did not declare support for " + $d.required_reasoning_class + "; using low-confidence " + $reasoning.class + " prior" else if ($class_rank >= $required_rank) then "meets " + $d.required_reasoning_class else "requires " + $d.required_reasoning_class + ", catalog fit is " + $reasoning.class end end),
         preference: preference($model; $d)}
        + (if $d.floor then {floor: $d.floor} else {} end)
      ] | unique_by([.harness, .model, .provider])) as $profiles |
      if ($profiles | length) == 0 then {error: "model catalog discovery returned no candidates matching the dynamic policy"}
      else {profiles: $profiles} end
    end;
  def expand_use($u): if dynamic($u) then dynamic_profiles($u) else {profiles: profiles($u)} end;
  def measured($p; $lane):
    (prov($p; $lane) != null and (["known", "partial"] | index(prov($p; $lane).quotaSemantics.status)) != null);
  def applicable($p; $lane; $m):
    (bare($m)) as $bare |
    [rows($p; $lane)[] | select(
      .scope == "all_models" or .scope == "all_products" or
      ($m != "" and (.scope == ("model:" + $bare) or .scope == ("product:" + $bare)))
    )];
  def floor_state($f; $p; $lane):
    if $f == null then "none"
    elif prov($p; $lane) == null or (measured($p; $lane) | not) then "unknown"
    else [rows($p; $lane)[] | select(.scope == $f.scope)] as $matches
      | if ($matches | length) == 0 or any($matches[]; .status != "known") then "unknown"
        elif any($matches[]; .effectivePercentRemaining < $f.min_percent) then "below"
        else "ok"
        end
    end;
  def evidence($rows):
    $rows | map({scope, status, pct: (.effectivePercentRemaining // null), runway: (.runway.status // null), spendPriority: (.selection.spendPriority // null)});
  def evaluate($c):
    (provider_of($c)) as $p | (lane_of($c)) as $lane |
    if ($c.fitEligible == false) then {profile: $c, provider: $p, eligible: false, reason: "task fit rejected: \($c.taskFitReason)"}
    elif $p == null then {profile: $c, eligible: false, reason: "no provider family for harness \($c.harness); declare provider on the profile"}
    elif prov($p; $lane) == null then
      {profile: $c, provider: $p, eligible: true, unranked: true,
       reason: (if any($q.providers[]; .provider == $p)
                then "provider \($p) has no quota row for account \(if $lane == "" then "default" else $lane end)"
                else "provider \($p) not in the quota snapshot" end)}
    else
      (applicable($p; $lane; ($c.model // ""))) as $rows |
      (evidence($rows)) as $bounds |
      (floor_state($c.floor; $p; $lane)) as $profile_floor_state |
      if any($rows[]; (.runway.status // "") == "exhausted_now") then
        ($rows | map(select((.runway.status // "") == "exhausted_now")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: ($bad.effectivePercentRemaining // null), runway: $bad.runway.status, eligible: false, reason: "runway exhausted_now at \($bad.scope)"}
      elif any($rows[]; .status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0) then
        ($rows | map(select(.status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0)) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: false, reason: "0% remaining at \($bad.scope)"}
      elif $profile_floor_state == "below" then
        ([rows($p; $lane)[] | select(
          .scope == $c.floor.scope and
          .effectivePercentRemaining < $c.floor.min_percent
        )] | first) as $floor_row |
        {profile: $c, provider: $p, bounds: $bounds, scope: ($floor_row.scope // $c.floor.scope), pct: ($floor_row.effectivePercentRemaining // null), runway: ($floor_row.runway.status // null), eligible: false, reason: "profile floor \($c.floor.scope) below \($c.floor.min_percent)%"}
      elif $c.fitUnranked then
        {profile: $c, provider: $p, bounds: $bounds, eligible: true, unranked: true, unknown: true,
         reason: "reasoning fit is low-confidence: \($c.fitClass) prior does not prove \($c.fitReason)"}
      elif (measured($p; $lane) | not) then
        ($rows | first) as $row |
        {profile: $c, provider: $p, bounds: $bounds, scope: ($row.scope // null), pct: ($row.effectivePercentRemaining // null), runway: ($row.runway.status // null), eligible: true, unranked: true, unknown: true, reason: "provider \($p) unmeasured (\(prov($p; $lane).quotaSemantics.status))"}
      elif ($rows | length) == 0 then
        {profile: $c, provider: $p, bounds: $bounds, eligible: true, unranked: true, unknown: true, reason: "no applicable quota row for provider \($p)"}
      elif $profile_floor_state == "unknown" then
        ([rows($p; $lane)[] | select(.scope == $c.floor.scope)] | first) as $floor_row |
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
  (if $rule == null then "none" else floor_state($rule.floor; $rule.floor.provider; "") end) as $rule_floor_state |
  (if $choice != "default" and $rule == null then null
   elif $rule == null then ($cfg.default // null)
   else $rule.use
   end) as $answer_raw_use |
  (expand_use($answer_raw_use)) as $answer_expanded |
  (if $choice != "default" and $rule == null then {invalid: "rule \($choice) is not in the rules file"}
   elif $rule == null then (expand_use($cfg.default // null) + {source: "default", note: "no rule matched"})
   elif ($rule.approval // "") == "captain" then ($answer_expanded + {source: $choice, escalate: "rule requires the captain'"'"'s explicit approval before dispatch"})
   elif $rule_floor_state == "unknown" then ($answer_expanded + {source: $choice, escalate: "rule \($choice) floor \($rule.floor.provider)/\($rule.floor.scope) is unverifiable"})
   elif $rule_floor_state == "below"
     then (expand_use($cfg.default // null) + {source: "default", note: "rule \($choice) floor \($rule.floor.scope) below \($rule.floor.min_percent)%: fall through to default"})
   else ($answer_expanded + {source: $choice, note: "rule matched"}) end) as $sel |
  {
    model: $r.model, latency_ms: $lat, tokens: ($r.usage // null),
    rule: $choice,
    rule_when: (if $rule == null then $none_criterion else $rule.when end | .[0:60]),
    confidence: $a.confidence, probabilities: $a.probabilities
  } as $ev |
  if $sel.invalid then $ev + {status: "error", reason: $sel.invalid}
  elif $sel.error then $ev + {status: "error", reason: $sel.error, candidates: []}
  elif $a.confidence < ($floor | tonumber) then
    $ev + {status: "ambiguous", reason: "confidence \($a.confidence) below floor \($floor)", candidates: (($sel.profiles // []) | map(evaluate(.)))}
  elif $sel.escalate then
    $ev + {status: "escalate", reason: $sel.escalate, candidates: (($sel.profiles // []) | map(evaluate(.)))}
  elif (($sel.profiles // []) | length) == 0 then $ev + {status: "escalate", reason: "no profiles configured for \($sel.source)", note: $sel.note, candidates: []}
  else
    (($sel.profiles // []) | map(evaluate(.))) as $cands |
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
      + (if .profile.catalogMethod then "  catalog=\(.profile.catalogMethod | flat)" else "" end)
      + (if .profile.fitClass then "  fit=task:\(.profile.taskType | flat)/\(.profile.taskFit | flat)/\(.profile.taskFitConfidence | flat)  reasoning:\(.profile.fitClass | flat) [\(.profile.fitSource | flat)/\(.profile.fitConfidence | flat)]  fitReason=\(.profile.taskFitReason | flat); \(.profile.fitReason | flat)" else "" end)
      + (if .profile.preference and .profile.preference != "none" then "  preference=\(.profile.preference | flat)" else "" end)
      + (if .scope then "  scope=\(.scope | flat)  remaining=\(show(.pct))%  spendPriority=\(show(.spendPriority))  runway=\(show(.runway))" else "" end)
      + (if (.bounds // [] | length) > 1 then "  bounds=" + ([.bounds[] | "\(.scope | flat):\(show(.pct))%/\((.runway // .status) | flat)"] | join(",")) else "" end)
      + "  -> " + (if .unranked then "eligible, unranked: \(.reason | flat): disclosed uncertainty" elif .eligible then "eligible" else "not eligible: \(.reason | flat)" end)),
  (if .chosen then "  profile: --harness \(.chosen.profile.harness | shell_arg)"
      + (if .chosen.profile.model then " --model \(.chosen.profile.model | shell_arg)" else "" end)
      + (if .chosen.profile.effort then " --effort \(.chosen.profile.effort | shell_arg)" else "" end) else empty end)' <<<"$RESULT") || emit_error "output rendering failed"
printf '%s\n' "$TEXT"
exit 0
