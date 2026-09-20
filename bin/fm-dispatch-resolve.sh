#!/usr/bin/env bash
# fm-dispatch-resolve.sh - resolve one concrete crewmate or scout dispatch
# profile from a task brief with typesafe.ai's System One model (Jev), opt-in.
#
# Usage:
#   fm-dispatch-resolve.sh <brief-file> [--project <name>]
#
# Opt-in gate: TYPESAFE_API_KEY or OPENROUTER_API_KEY non-empty in this
#   process environment, else the same names in $FM_HOME/.env read with
#   fmx_env_get, the same accessor as FMX_PAIRING_TOKEN (bin/fm-env-lib.sh).
#   The environment wins. Absent in both: one "dispatch-resolve: off" line on
#   stderr, nothing on stdout, exit 0, no network call, so firstmate
#   dispatches exactly as today. Keys reach curl only through bin/fm-jev-lib.sh
#   as an Authorization header read from a file descriptor, never on argv;
#   nothing logs or writes them.
#
# What it does when on with at least one rule: one POST through
#   bin/fm-jev-lib.sh (TypeSafe /v1/systemone, or OpenRouter
#   /api/alpha/decisions when OPENROUTER_API_KEY is set and TYPESAFE_API_KEY
#   is not, or when JEV_ROUTE=openrouter) with the project name plus either
#   the whole brief or a compact intent summary as state, and a Choice
#   question whose options are every rule's `when` from
#   config/crew-dispatch.json plus one fixed generic none option. Jev returns
#   the matched rule, a probability per option, and a confidence. The same
#   response carries a second typed Choice classifying the reasoning effort
#   the brief itself needs (low|medium|high|xhigh|max). Everything after that
#   is jq: the confidence floor, the rule's declared `approval` and `floor`,
#   each profile's declared `provider` and `floor`, the quota rows from ONE
#   quota-axi --json snapshot, the spend ledger's predicted burn for the
#   assessed class (bin/fm-spend-ledger.py predict), and the spendPriority
#   argmax over the eligible candidates. The model never sees quota,
#   catalogs, approvals, `why`, or `use`. With no rules, it returns a
#   non-clear result so firstmate keeps using the existing intake.
#   docs/configuration.md "Crew dispatch profiles" owns the declared fields and
#   "Typed dispatch resolution" owns this tool's operator contract.
#
# Effort is dynamic, not static: a profile's declared `effort` is the ceiling
#   Jev may not exceed (xhigh when undeclared, so max always needs an explicit
#   declaration), and the emitted --effort is the assessed class. A missing or
#   malformed effort answer falls back to the declared effort and says so.
#   A candidate that cannot supply the assessed class fails fit before quota
#   gates; one whose predicted burn exceeds the tightest applicable remaining
#   percent or usable runway is refused with the prediction named in the
#   reason. Missing ledger evidence never fabricates a limit: the candidate
#   keeps today's rank and its line shows pred=unknown.
#   FM_SPEND_LEDGER overrides the ledger path (tests).
#
# Output (stdout, TOON-style block):
#   dispatch-resolve:
#     status: clear | ambiguous | escalate | error
#     model/latency_ms/tokens, rule (when excerpt) and confidence, probabilities
#     effort: <assessed class> (jev confidence=.. | declared | declared fallback (classifier <why>))
#     reason: <why the status is not clear; an all-refused escalate names the predicted burn>
#     candidate: <harness>:<model> provider=.. effort=<class>(<ceiling> ceiling) scope=.. remaining=..%
#       spendPriority=.. runway=.. pred=~<tokens>tok/<seconds>s | pred=unknown
#       -> eligible | eligible, unranked: <reason> | not eligible: <reason>
#     profile: --harness <h> [--model <m>] [--effort <e>]     (status clear only; effort is the assessed class)
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
#   TYPESAFE_API_KEY and/or OPENROUTER_API_KEY opt the resolver in.
#   JEV_ROUTE, JEV_MODEL, JEV_URL, JEV_BASE, and JEV_TIMEOUT follow
#   docs/configuration.md "Typed dispatch resolution" (env then .env).
#   JEV_ROUTE=openrouter selects OpenRouter even when a TypeSafe key is also
#   present. FM_JEV_DISPATCH_SHADOW=1 or config/jev-dispatch-shadow logs the
#   Jev pick to state/jev-dispatch-shadow.jsonl and does not add spawn
#   authority beyond today's optional clear-profile use.
#   FM_JEV_DISPATCH_EXTRA=1 adds log-only home and deliverable questions.
#   FM_JEV_DISPATCH_COMPACT is read from the process environment first, else
#   from $FM_HOME/.env via fmx_env_get; the environment wins. A truthy value
#   sends a 400-800 character intent summary instead of the whole brief
#   (default on for the OpenRouter route when both are unset).
#
# Authority: this tool never replaces firstmate's judgment, quota-array-dispatch,
#   the captain-approval gate, or fm-spawn.sh validation; it publishes one
#   inspectable answer plus every candidate's evidence, in code.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
OPENROUTER_API_KEY_PRIVATE=${OPENROUTER_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY OPENROUTER_API_KEY

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
# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"

CONFIDENCE_FLOOR=0.6
DEFAULT_WHEN="No listed rule applies to this task."
DISPATCH_HOMES="main agency lay frontend zimmer"

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

fm_dispatch_truthy() {
  case "$1" in 1|on|true|yes) return 0 ;; *) return 1 ;; esac
}

fm_dispatch_shadow_on() {
  local v=${FM_JEV_DISPATCH_SHADOW:-}
  if [ -n "$v" ]; then
    fm_dispatch_truthy "$v"
    return
  fi
  [ -e "$CONFIG/jev-dispatch-shadow" ]
}

fm_dispatch_route() {
  local route
  route=$(_fm_jev_cfg JEV_ROUTE)
  case "$route" in
    openrouter) printf 'openrouter' ;;
    typesafe) printf 'typesafe' ;;
    '')
      if [ -n "$TYPESAFE_API_KEY_PRIVATE" ]; then
        printf 'typesafe'
      else
        printf 'openrouter'
      fi
      ;;
    *) printf '%s' "$route" ;;
  esac
}

fm_dispatch_compact_on() {
  local v=${FM_JEV_DISPATCH_COMPACT:-}
  if [ -n "$v" ]; then
    fm_dispatch_truthy "$v"
    return
  fi
  v=$(fmx_env_get FM_JEV_DISPATCH_COMPACT "$FM_HOME/.env")
  if [ -n "$v" ]; then
    fm_dispatch_truthy "$v"
    return
  fi
  [ "$(fm_dispatch_route)" = openrouter ]
}

fm_dispatch_flatten_truncate() {
  local n=${2:-800}
  printf '%s' "$1" | awk -v n="$n" '
    {
      if (NR > 1) buf = buf " "
      buf = buf $0
    }
    END {
      gsub(/[ \t\r\n]+/, " ", buf)
      sub(/^ /, "", buf)
      sub(/ $/, "", buf)
      if (n > 0 && length(buf) > n) buf = substr(buf, 1, n)
      printf "%s", buf
    }'
}

fm_dispatch_intent_summary() {
  local brief=$1 text
  text=$(awk '
    /^## Captain'\''s intent([[:space:]]|$)/ { grab=1; next }
    /^## / { if (grab) exit }
    grab { print }
  ' "$brief")
  if [ -z "$text" ]; then
    text=$(cat "$brief")
  fi
  fm_dispatch_flatten_truncate "$text" 800
}

fm_dispatch_home_criteria() {
  local reg="$FM_HOME/data/secondmates.md" id scope fallback json='{}'
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
  for id in $DISPATCH_HOMES; do
    if [ "$id" = main ]; then
      fallback='The main firstmate home; work that no registered secondmate scope covers.'
    else
      fallback="The ${id} secondmate home."
    fi
    scope=''
    if [ -f "$reg" ] && [ ! -L "$reg" ]; then
      scope=$(secondmate_registry_field "$reg" "$id" scope 2>/dev/null) || scope=''
    fi
    if [ -z "$scope" ]; then
      scope=$fallback
    fi
    scope=$(fm_dispatch_flatten_truncate "$scope" 200)
    json=$(jq -c --arg id "$id" --arg scope "$scope" '. + {($id): $scope}' <<<"$json")
  done
  printf '%s' "$json"
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
if [ -z "$OPENROUTER_API_KEY_PRIVATE" ]; then
  OPENROUTER_API_KEY_PRIVATE=$(fmx_env_get OPENROUTER_API_KEY "$FM_HOME/.env")
fi
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ] && [ -z "$OPENROUTER_API_KEY_PRIVATE" ]; then
  echo "dispatch-resolve: off (TYPESAFE_API_KEY and OPENROUTER_API_KEY absent from the environment and $FM_HOME/.env)" >&2
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
EXTRA_LOG=null
command -v curl >/dev/null 2>&1 || emit_error "curl not installed"
[ -n "$TYPESAFE_API_KEY_PRIVATE" ] && TYPESAFE_API_KEY=$TYPESAFE_API_KEY_PRIVATE
[ -n "$OPENROUTER_API_KEY_PRIVATE" ] && OPENROUTER_API_KEY=$OPENROUTER_API_KEY_PRIVATE
EXTRA=0
if fm_dispatch_truthy "${FM_JEV_DISPATCH_EXTRA:-}"; then
  EXTRA=1
fi
if [ "$EXTRA" -eq 1 ]; then
  HOME_CRITERIA=$(fm_dispatch_home_criteria)
else
  HOME_CRITERIA='{}'
fi
if fm_dispatch_compact_on; then
  BRIEF_TEXT=$(fm_dispatch_intent_summary "$BRIEF")
else
  BRIEF_TEXT=$(cat "$BRIEF")
fi
BRIEF_TEXT=$(fm_jev_compact_state "$BRIEF_TEXT") || emit_error "state exceeds size limit"
STATE=$(jq -nc --arg project "$PROJECT" --arg brief "$BRIEF_TEXT" '{task:{project:$project, brief:$brief}}') \
  || emit_error "could not build state"
QUESTIONS=$(jq -nc --arg none_criterion "$DEFAULT_WHEN" --argjson extra "$EXTRA" --argjson homes "$HOME_CRITERIA" --slurpfile rules "$RULES" '
  ($rules[0].rules | to_entries | map({key: ("rule_" + ((.key + 1) | tostring)), value: .value.when}) | from_entries) as $criteria |
  {
    rule: {
      type: "choice",
      instructions: "Which ONE dispatch rule best fits `task` (read `task.brief` and `task.project`)? Each option is the rule'"'"'s own matching condition; pick `default` when no rule'"'"'s condition is met, including when a rule'"'"'s own exemption text excludes this task.",
      criteria: ($criteria + {default: $none_criterion})
    },
    effort: {
      type: "choice",
      instructions: "What reasoning effort does `task` itself need? Judge the work'"'"'s intrinsic difficulty from task.brief, independently of any dispatch rule. `max` is reserved: choose it only when the task text itself explicitly demands maximum effort; otherwise never.",
      criteria: {
        low: "Trivial mechanical work: a rote rename, formatting sweep, targeted typo fix, or single-file gathering.",
        medium: "Contained work needing ordinary care: a small feature, a narrow bug fix, or a bounded question.",
        high: "Big or ambiguous multi-file work: a feature across several files, a risky refactor, or many moving parts.",
        xhigh: "Deep-deliberation work: safety-critical, subtle, or highly ambiguous tasks where mistakes are costly.",
        max: "Maximum effort. Choose only when the task text itself explicitly demands maximum effort; otherwise never."
      }
    }
  } + (if $extra == 1 then {
    home: {
      type: "choice",
      instructions: "Which Firstmate home should own this work? This answer is log-only and must not route the task.",
      criteria: $homes
    },
    deliverable: {
      type: "choice",
      instructions: "Should this work ship a change, produce a scout report, or neither? This answer is log-only.",
      criteria: {
        ship: "A project change through the selected delivery path.",
        scout: "A knowledge-only report, not a PR.",
        neither: "Neither a ship nor a scout."
      }
    }
  } else {} end)
') || emit_error "could not build questions"
DECIDE_ERR=0
fm_jev_decide "$STATE" "$QUESTIONS" > "$RESP_FILE" || DECIDE_ERR=$?
LAT_MS=${FM_JEV_LAST_LATENCY_MS:-0}
HTTP=${FM_JEV_LAST_HTTP:-000}
unset TYPESAFE_API_KEY OPENROUTER_API_KEY
if [ "$DECIDE_ERR" -ne 0 ]; then
  if [ -n "$HTTP" ] && [ "$HTTP" != 200 ]; then
    emit_error "http $HTTP after ${LAT_MS} ms"
  else
    emit_error "jev caller failed"
  fi
fi
if [ "$EXTRA" -eq 1 ]; then
  EXTRA_LOG=$(jq -c '{
    home: (.answers.home.choice // null),
    deliverable: (.answers.deliverable.choice // null),
    home_confidence: (.answers.home.confidence // null),
    deliverable_confidence: (.answers.deliverable.confidence // null)
  }' "$RESP_FILE") || EXTRA_LOG='{}'
fi
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

# The effort answer is a second typed Choice in the same response. It is
# validated separately and softly: a missing or malformed effort answer falls
# back to the rule's declared effort with the fallback disclosed in the
# output, while a well-formed answer becomes the assessed reasoning class.
EFFORT_JSON=$(jq -c '
  (["low","medium","high","xhigh","max"]) as $classes |
  (.answers.effort // null) as $a |
  if $a == null then {choice: null, source: "absent"}
  elif (($a.choice | type) == "string") and ($classes | index($a.choice) != null) and
       (($a.confidence | type) == "number") and ($a.confidence >= 0) and ($a.confidence <= 1) and
       (($a.probabilities | type) == "object") and (($a.probabilities | keys | sort) == ($classes | sort)) and
       (all($a.probabilities[]; type == "number" and . >= 0 and . <= 1)) and
       (($a.probabilities | [.[]] | add) >= 0.99) and (($a.probabilities | [.[]] | add) <= 1.01)
    then {choice: $a.choice, confidence: $a.confidence, source: "jev"}
    else {choice: null, source: "malformed"}
    end' "$RESP_FILE" 2>/dev/null) || EFFORT_JSON='{"choice":null,"source":"malformed"}'

# ---- quota evidence: one quota-axi --json snapshot -----------------------------
command -v quota-axi >/dev/null 2>&1 || emit_error "quota-axi not installed"
quota-axi --json > "$QUOTA" 2>/dev/null || emit_error "quota-axi --json failed"
fm_quota_json_valid < "$QUOTA" || emit_error "quota-axi --json returned an invalid snapshot"

# ---- spend prediction: one ledger pass over the same quota snapshot ----------
# bin/fm-spend-ledger.py owns the measurement; absent or unreadable output
# leaves every burn gate inert and shows pred=unknown on the candidate lines.
PREDICT_FILE=$(mktemp) || { rm -f "$RULES" "$RESP_FILE" "$QUOTA"; die "mktemp failed"; }
trap 'rm -f "$RULES" "$RESP_FILE" "$QUOTA" "$PREDICT_FILE"' EXIT
SPEND_LEDGER=${FM_SPEND_LEDGER:-$SCRIPT_DIR/fm-spend-ledger.py}
if [ -x "$SPEND_LEDGER" ]; then
  FM_HOME="$FM_HOME" "$SPEND_LEDGER" predict --quota "$QUOTA" > "$PREDICT_FILE" 2>/dev/null \
    || printf '{"status":"unavailable"}\n' > "$PREDICT_FILE"
else
  printf '{"status":"unavailable"}\n' > "$PREDICT_FILE"
fi
jq -e 'type == "object"' "$PREDICT_FILE" >/dev/null 2>&1 \
  || printf '{"status":"unavailable"}\n' > "$PREDICT_FILE"

# ---- resolution: declared gates + quota evidence + argmax, all in jq ------------
RESULT=$(jq -n --arg floor "$CONFIDENCE_FLOOR" --argjson lat "$LAT_MS" --arg none_criterion "$DEFAULT_WHEN" --argjson pmap "$PMAP" --argjson effort "$EFFORT_JSON" \
  --slurpfile resp "$RESP_FILE" --slurpfile rules "$RULES" --slurpfile quota "$QUOTA" --slurpfile predict "$PREDICT_FILE" '
  ($resp[0]) as $r | ($rules[0]) as $cfg | ($quota[0]) as $q | ($r.answers.rule) as $a |
  ($predict[0] // {status:"unavailable"}) as $pd | ($effort.choice) as $jev_effort |
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def prov($p): ([$q.providers[] | select(.provider == $p)] | first) // null;
  def rows($p): (prov($p) | .quotaSemantics.effectiveAvailability // []);
  def bare($m): ($m | split("/") | last);
  def effort_rank($e): (["low","medium","high","xhigh","max","ultra"] | index($e));
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
  def fmt_tokens($t): if $t >= 1000000 then "\(($t / 100000) | round / 10)M" elif $t >= 1000 then "\(($t / 100) | round / 10)k" else "\($t)" end;
  def median_burn($p; $e):
    if $p == null then null
    elif $e == null then (($pd.median[$p].all // $pd.anyProvider.all) // null)
    else (($pd.median[$p][$e] // $pd.median[$p].all // $pd.anyProvider[$e] // $pd.anyProvider.all) // null)
    end;
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
    $rows | map({scope, status, pct: (.effectivePercentRemaining // null), runway: (.runway.status // null), runwaySeconds: (.runway.usableRunwaySeconds // null), spendPriority: (.selection.spendPriority // null)});
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
  # The declared effort is a ceiling, not a floor: the assessed class
  # may be lower, never higher. An undeclared ceiling is xhigh - max and ultra
  # therefore always need an explicit declaration. A candidate that cannot
  # supply the assessed class fails fit before any quota evidence is read.
  def resolve_effort($c):
    ($c.effort // null) as $declared |
    (if $declared == null then "xhigh" else $declared end) as $ceiling |
    if $jev_effort == null then {effort: $declared, ceiling: $ceiling, source: "declared", ok: true}
    elif (effort_rank($jev_effort) <= effort_rank($ceiling)) then {effort: $jev_effort, ceiling: $ceiling, source: "jev", ok: true}
    else {effort: $jev_effort, ceiling: $ceiling, source: "jev", ok: false,
          reason: "assessed effort \($jev_effort) exceeds declared ceiling \($ceiling)"}
    end;
  # Burn gates bind only where the ledger produced evidence: a median burn for
  # this provider/effort ladder, a calibrated tokens-per-point for the current
  # provider window, and finite quota bounds. Missing evidence stays
  # disclosed (pred=unknown) and never fabricates a limit.
  def burn_gate($ev):
    if ($ev.eligible != true) then $ev
    else
      (median_burn($ev.provider; $ev.effort)) as $med |
      if $med == null or ($med.tokens | type) != "number" then $ev + {pred: null}
      else
        ($med.tokens) as $pt | ($med.seconds // null) as $ps |
        (if $ev.provider == null then null else ($pd.providers[$ev.provider].tokensPerPoint // null) end) as $tpp |
        (if $tpp != null then $pt / $tpp else null end) as $pred_pct |
        ([($ev.bounds // [])[] | select((.pct | type) == "number")] ) as $b |
        (if ($b | length) > 0 then ($b | min_by(.pct)) else null end) as $limit |
        ([($ev.bounds // [])[] | select((.runwaySeconds | type) == "number") | .runwaySeconds] | if length > 0 then min else null end) as $min_runway |
        ($ev + {pred: {tokens: $pt, seconds: $ps, pct: $pred_pct}}) as $evp |
        if $pred_pct != null and $limit != null and $pred_pct > $limit.pct then
          $evp + {eligible: false,
                  reason: "predicted burn ~\(fmt_tokens($pt)) tokens (~\($pred_pct | round)%) exceeds remaining \($limit.pct)% at \($limit.scope)"}
        elif $ps != null and $min_runway != null and $ps > $min_runway then
          ($evp.bounds // [] | map(select((.runwaySeconds | type) == "number")) | min_by(.runwaySeconds)) as $lr |
          $evp + {eligible: false,
                  reason: "predicted duration ~\(($ps | round))s exceeds usable runway \(($min_runway | round))s at \($lr.scope)"}
        else $evp
        end
      end
    end;
  def assess($c):
    (resolve_effort($c)) as $er |
    if ($er.ok | not) then
      {profile: $c, eligible: false, effort: $er.effort, ceiling: $er.ceiling, effort_source: $er.source,
       reason: $er.reason}
    elif $er.effort != null and (effort_ok($c.harness; $c.model; $er.effort) | not) then
      if (effort_ok($c.harness; $c.model; "low") | not) then
        # The harness carries no effort knob at all (cursor, kimi, opencode):
        # the assessed class is disclosed on the line but cannot gate, and
        # the emitted profile stays effort-free exactly as today.
        (evaluate($c) + {effort: $er.effort, ceiling: $er.ceiling, effort_source: $er.source,
                         effort_emit: false, effort_note: "effort unenforceable on \($c.harness)"}) | burn_gate(.)
      else
        {profile: $c, eligible: false, effort: $er.effort, ceiling: $er.ceiling, effort_source: $er.source,
         reason: "harness \($c.harness) cannot supply assessed effort \($er.effort)"}
      end
    else
      (evaluate($c) + {effort: $er.effort, ceiling: $er.ceiling, effort_source: $er.source}) | burn_gate(.)
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
    confidence: $a.confidence, probabilities: $a.probabilities,
    effort: {choice: $jev_effort, confidence: $effort.confidence, source: $effort.source}
  } as $ev |
  if $sel.invalid then $ev + {status: "error", reason: $sel.invalid}
  elif $a.confidence < ($floor | tonumber) then
    $ev + {status: "ambiguous", reason: "confidence \($a.confidence) below floor \($floor)", candidates: ($answer_use | map(assess(.)))}
  elif $sel.escalate then
    $ev + {status: "escalate", reason: $sel.escalate, candidates: ($answer_use | map(assess(.)))}
  elif ($sel.use | length) == 0 then $ev + {status: "escalate", reason: "no profiles configured for \($sel.source)", note: $sel.note, candidates: []}
  else
    ($sel.use | map(assess(.))) as $cands |
    ([$cands[] | select(.eligible and ((.unranked // false) | not))]) as $elig |
    ([$cands[] | select(.unranked)]) as $unranked |
    ([$cands[] | select(.pred != null) | .pred.tokens] | if length > 0 then min else null end) as $min_pred |
    if ($elig | length) == 0 then
      $ev + {status: "escalate",
             reason: ("no rankable eligible candidate" +
               (if $min_pred != null then " (predicted burn ~\(fmt_tokens($min_pred)) tokens at \($jev_effort // "declared") effort)" else "" end)),
             note: $sel.note, candidates: $cands}
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
  "  effort: \(show(.effort.choice)) (\(if .effort.source == "jev" then "jev confidence=\(show(.effort.confidence))" elif .effort.source == "declared" then "declared" else "declared fallback (classifier \(.effort.source))" end))",
  (if .reason then "  reason: \(.reason | flat)" else empty end),
  (if .note then "  note: \(.note | flat)" else empty end),
  (if .unranked_note then "  note: \(.unranked_note | flat)" else empty end),
  (.candidates[]? | "  candidate: \(.profile.harness | flat):\(show(.profile.model))"
      + (if .provider then "  provider=\(.provider | flat)" else "" end)
      + (if .effort then "  effort=\(.effort | flat)" + (if .ceiling then "(\(.ceiling | flat) ceiling)" else "" end) + (if .effort_note then " [\(.effort_note | flat)]" else "" end) else "" end)
      + (if .scope then "  scope=\(.scope | flat)  remaining=\(show(.pct))%  spendPriority=\(show(.spendPriority))  runway=\(show(.runway))" else "" end)
      + (if .pred then "  pred=~\(.pred.tokens | flat)tok/\(show(.pred.seconds))s" elif has("pred") then "  pred=unknown" else "" end)
      + (if (.bounds // [] | length) > 1 then "  bounds=" + ([.bounds[] | "\(.scope | flat):\(show(.pct))%/\((.runway // .status) | flat)"] | join(",")) else "" end)
      + "  -> " + (if .unranked then "eligible, unranked: \(.reason | flat): disclosed uncertainty" elif .eligible then "eligible" else "not eligible: \(.reason | flat)" end)),
  (if .chosen then "  profile: --harness \(.chosen.profile.harness | shell_arg)"
      + (if .chosen.profile.model then " --model \(.chosen.profile.model | shell_arg)" else "" end)
      + (if .chosen.effort_emit == false then
           (if .chosen.profile.effort then " --effort \(.chosen.profile.effort | shell_arg)" else "" end)
         elif .chosen.effort then " --effort \(.chosen.effort | shell_arg)"
         elif .chosen.profile.effort then " --effort \(.chosen.profile.effort | shell_arg)" else "" end) else empty end)' <<<"$RESULT") || emit_error "output rendering failed"
if fm_dispatch_shadow_on; then
  SHADOW_PATH="$FM_HOME/state/jev-dispatch-shadow.jsonl"
  SHADOW=$(jq -nc --argjson result "$RESULT" --arg route "${FM_JEV_LAST_ROUTE:-}" \
    --arg url "${FM_JEV_LAST_URL:-}" --arg model "${FM_JEV_LAST_MODEL:-}" \
    --arg project "$PROJECT" --argjson extra "$EXTRA_LOG" \
    --arg compact "$(if fm_dispatch_compact_on; then printf 1; else printf 0; fi)" '{
      purpose: "dispatch-shadow",
      route: $route,
      url: $url,
      model: $model,
      project: $project,
      compact: ($compact == "1"),
      status: $result.status,
      rule: $result.rule,
      confidence: $result.confidence,
      probabilities: $result.probabilities,
      profile: (if $result.chosen then $result.chosen.profile else null end),
      extra: $extra
    }') || SHADOW=''
  if [ -n "$SHADOW" ]; then
    fm_jev_log_call "$SHADOW" "$SHADOW_PATH" || true
  fi
fi
printf '%s\n' "$TEXT"
exit 0
