#!/usr/bin/env bash
# fm-dispatch-resolve.sh - match one configured crewmate or scout dispatch rule
# to a task brief with typesafe.ai's System One model (Jev), opt-in.
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
#   floor and the rule's declared `approval`. The model never sees catalogs,
#   quota, approvals, `why`, or `use`. The result never authorizes a profile:
#   catalog/provider, authentication, reasoning-class, and quota gates stay in
#   the existing dispatch intake. With no rules, it returns a non-clear result
#   so firstmate keeps using that intake unchanged.
#   docs/configuration.md "Crew dispatch profiles" owns the declared fields and
#   "Typed dispatch resolution" owns this tool's operator contract.
#
# Output (stdout, TOON-style block):
#   dispatch-resolve:
#     status: ambiguous | escalate | error
#     model/latency_ms/tokens, rule (when excerpt) and confidence, probabilities
#     reason: <why normal dispatch must continue>
#   ambiguous -> confidence below the floor; decide as today from the probabilities
#   escalate  -> the rule requires captain approval or normal profile gates remain
#   error     -> API, network, or response failure; decide as today
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
#   inspectable rule-match answer.
set +x
set +a
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

# The fields this tool consumes must be well formed; bootstrap owns the wider
# schema diagnostic, but an intake never selects around a malformed file.
rules_err=$(jq -r --argjson verified_harnesses "$VERIFIED_HARNESSES" --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
  def verified($h): $verified_harnesses | index($h);
  def provider_id($p): ($p | type) == "string" and ($p | test($provider_re));
  def effort_ok($h; $m; $e):
    if $e == null then true
    elif ($e | type) != "string" then false
    elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "codex" then (["low","medium","high","xhigh"] | index($e)) != null
    elif $h == "grok" then (["low","medium","high"] | index($e)) != null
    elif $h == "pi" or $h == "pi-signed" or $h == "muse" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
    else true end;
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def profile_floor_bad($f):
    ($f | type) != "object"
    or (($f.scope | type) != "string") or (($f.scope | length) == 0)
    or (($f.min_percent | type) != "number") or ($f.min_percent < 0) or ($f.min_percent > 100)
    or ($f | has("provider"));
  def profile_bad($p):
    ($p | type) != "object"
    or (($p.harness | type) != "string") or (($p.harness | length) == 0)
    or ($p | has("model") and ((.model | type) != "string" or (.model | length) == 0))
    or ($p | has("effort") and ((.effort | type) != "string" or (.effort | length) == 0))
    or ($p | has("provider") and (provider_id(.provider) | not))
    or ($p | has("floor") and profile_floor_bad(.floor));
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
trap 'rm -f "$RULES" "$RESP_FILE"' EXIT
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
  HTTP=$(printf '%s' "$REQUEST" | curl -q -sS --max-time "$TS_TIMEOUT" -o "$RESP_FILE" -w '%{http_code}' \
    -X POST "$TS_BASE/v1/systemone" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") \
    --data-binary @- 2>/dev/null) || HTTP=000
  T1=$(fm_timing_now_ms)
  LAT_MS=$(( T1 - T0 ))
  [ "$HTTP" = 200 ] || emit_error "http $HTTP after ${LAT_MS} ms: $(head -c 200 "$RESP_FILE" 2>/dev/null | tr '\n' ' ')"
jq -e --slurpfile rules "$RULES" '
    (($rules[0].rules | to_entries | map("rule_" + ((.key + 1) | tostring))) + ["default"] | sort) as $choices |
    .answers.rule.type == "choice" and
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

# ---- resolution: rule-match evidence only -------------------------------------
RESULT=$(jq -n --arg floor "$CONFIDENCE_FLOOR" --argjson lat "$LAT_MS" --arg none_criterion "$DEFAULT_WHEN" \
  --slurpfile resp "$RESP_FILE" --slurpfile rules "$RULES" '
  ($resp[0]) as $r | ($rules[0]) as $cfg | ($r.answers.rule) as $a |
  ($a.choice) as $choice |
  (if ($choice | test("^rule_[1-9][0-9]*$"))
   then ($choice | ltrimstr("rule_") | tonumber)
   else null end) as $rule_number |
  (if $choice == "default" then null
   elif $rule_number != null and $rule_number <= (($cfg.rules // []) | length) then $cfg.rules[$rule_number - 1]
   else null end) as $rule |
  (if $choice != "default" and $rule == null then
     {invalid: "rule \($choice) is not in the rules file"}
   elif $rule == null then
     {note: "no rule matched"}
   elif ($rule.approval // "") == "captain" then
     {escalate: "rule requires the captain'\''s explicit approval before dispatch"}
   else
     {note: "rule matched"}
   end) as $sel |
  {
    model: $r.model, latency_ms: $lat, tokens: ($r.usage // null),
    rule: $choice,
    rule_when: (if $rule == null then $none_criterion else $rule.when end | .[0:60]),
    confidence: $a.confidence, probabilities: $a.probabilities
  } as $ev |
  if $sel.invalid then
    $ev + {status: "error", reason: $sel.invalid}
  elif $sel.escalate then
    $ev + {status: "escalate", reason: $sel.escalate}
  elif $a.confidence < ($floor | tonumber) then
    $ev + {status: "ambiguous", reason: "confidence \($a.confidence) below floor \($floor)"}
  else
    $ev + {
      status: "escalate",
      reason: "normal dispatch must verify catalog, provider, authentication, reasoning-class, and quota gates",
      note: $sel.note
    }
  end') || emit_error "resolution failed"

TEXT=$(jq -r '
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($value): ($value // "-") | flat;
  "dispatch-resolve:",
  "  status: \(.status | flat)",
  "  model: \(show(.model))   latency_ms: \(show(.latency_ms))   tokens: \(show(.tokens.input_tokens))/\(show(.tokens.output_tokens))",
  "  rule: \(.rule | flat) (\(.rule_when | flat))   confidence: \(.confidence | flat)",
  "  probabilities: \([.probabilities | to_entries[] | "\(.key | flat)=\(.value | flat)"] | join(" "))",
  (if .reason then "  reason: \(.reason | flat)" else empty end),
  (if .note then "  note: \(.note | flat)" else empty end)' <<<"$RESULT") || emit_error "output rendering failed"
printf '%s\n' "$TEXT"
exit 0
