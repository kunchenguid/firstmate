#!/usr/bin/env bash
# fm-jev.sh - the one Jev judgment command for firstmate and every worker.
#
# A lean CLI over bin/fm-jev-lib.sh, which stays the single owner of the HTTP
# call, route, and transport. This
# script owns only the typed argv/stdin interface, the privacy refusal, the
# escalation floor, and the one-line-per-answer output. bin/fm-dod-lib.sh's
# fm_jev_first_rule names this command to every worker; `--help` (usage below)
# is the only schema an agent ever loads, so keep it under 15 lines.
#
# Key resolution uses TYPESAFE_API_KEY from the environment, then $FM_HOME/.env,
# then the .env of the firstmate home that owns this checkout. For pooled
# worktrees, the owning home is the main worktree resolved through git-common-dir.
# The key stays in non-exported shell variables and reaches curl only as an
# Authorization header read from a file descriptor, never on argv. This command
# always uses the TypeSafe route and production endpoint. Crew workers run as
# the same OS user with full file access and are not sandboxed.
#
# Privacy: callers must pass only task facts and never personal data or
# private-vault content. The command also refuses obvious secrets, email
# addresses, and phone numbers as a safety net only, not a general personal-data
# detector. State, question IDs and text, option labels and meanings are refused
# when their combined UTF-8 text exceeds FM_JEV_CLI_INPUT_MAX bytes (4096), when
# fm_jev_compact_state would strip anything, or when the text contains a live key.
#
# Option text accepts label=meaning, split on its first equals sign; later
# equals signs belong to the meaning, so labels cannot contain equals signs.
# Option labels and meanings must not contain control characters.
#
# Escalation floor: a verdict whose confidence is below the floor prints
# ESCALATE. The default floor follows the confidence source: 0.5 for the
# confidence TypeSafe reports on choice and score answers, 0.4 for a yes/no
# answer, whose confidence is estimated here as 2*|p-0.5|, and for a choice or
# score answer with no reported confidence, estimated as top minus runner-up
# probability.
#
# Log: every attempted call appends one metadata-only record (purpose
# worker-cli, route, model, http, latency, usage in/out token counts - named
# so fm_jev_log_call's token-key redaction leaves them readable - question count,
# escalations, exit code; never the working directory, state, or question text) through
# fm_jev_log_call to the chosen home's state/jev-calls.jsonl. A log failure
# never changes the result.
#
# Exit: 0 every question answered, 2 at least one escalation, 1 any error
# (usage, privacy refusal, missing key, transport, malformed response) with a
# one-line reason on stderr.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
OPENROUTER_API_KEY_PRIVATE=${OPENROUTER_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY OPENROUTER_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_JEV_CLI_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_JEV_CLI_URL='https://api.typesafe.ai/v1/systemone'
FM_JEV_CLI_INPUT_MAX=4096

usage() {
  cat <<'EOF'
fm-jev.sh - one typed Jev judgment (TypeSafe) with one output line per question.
  fm-jev.sh pick  "<state>" "<question>" optA optB ...   pick one option, at most 255
  fm-jev.sh yes   "<state>" "<question>"                 yes/no with probability p of yes
  fm-jev.sh score "<state>" "<question>" lvl1 lvl2 ...   ordered levels, at most 10
  fm-jev.sh batch < {"state":"..","questions":[{"id":"x","type":"pick|yes|score","q":"..","opts":[..]}]}
    Several questions on one state in one call; opts is an array of label or label=meaning strings.
    First "=" splits label from meaning; later "=" stays in meaning; labels cannot contain "="; labels and meanings cannot contain controls.
Flags follow the command: --json (raw response); --help prints this interface.
Output: "pick: answer p=0.96 conf=0.94"; a batch uses its question id; escalation prints "ESCALATE conf=0.31 prior=X -> decide yourself".
Exit: 0 answered, 2 any escalation, 1 error with a one-line reason; on 1 or 2 use your own judgment, never block.
Input: 4096 bytes total; caller must pass only task facts, never personal data or private-vault content. Obvious secrets, email addresses and phone numbers are refused as a safety net only.
Key: workers use the firstmate home .env (launch environments clear keys); direct calls use TYPESAFE_API_KEY env, FM_HOME/.env, then owning checkout .env.
Security: crew workers run as the same OS user with full file access and are not sandboxed.
EOF
}

die() {
  printf 'fm-jev: %s\n' "$1" >&2
  exit 1
}

firstmate_home() {
  local common
  common=$(git -C "$FM_JEV_CLI_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=
  case "$common" in
    */.git) printf '%s' "${common%/.git}" ;;
    *) printf '%s' "$FM_JEV_CLI_ROOT" ;;
  esac
}

home_env_value() {
  local name=$1 value owner
  case "$name" in
    TYPESAFE_API_KEY) value=${TYPESAFE_API_KEY_PRIVATE:-} ;;
    OPENROUTER_API_KEY) value=${OPENROUTER_API_KEY_PRIVATE:-} ;;
    *) value=${!name-} ;;
  esac
  [ -n "$value" ] && { printf '%s' "$value"; return 0; }
  if [ -n "${FM_HOME:-}" ]; then
    value=$(fmx_env_get "$name" "$FM_HOME/.env")
    [ -n "$value" ] && { printf '%s' "$value"; return 0; }
  fi
  owner=$(firstmate_home)
  if [ "$owner" != "${FM_HOME:-}" ]; then
    value=$(fmx_env_get "$name" "$owner/.env")
  fi
  printf '%s' "$value"
}

resolve_typesafe_key() {
  TYPESAFE_API_KEY_PRIVATE=$(home_env_value TYPESAFE_API_KEY)
  [ -n "$TYPESAFE_API_KEY_PRIVATE" ] || die "TYPESAFE_API_KEY missing; set it in the environment or the resolved .env"
}

# Succeeds when <text> contains a live Jev provider key. Keys stay local.
contains_live_key() {
  local text=$1 name key
  for name in TYPESAFE_API_KEY OPENROUTER_API_KEY; do
    key=$(home_env_value "$name")
    [ -n "$key" ] || continue
    case "$text" in
      *"$key"*) return 0 ;;
    esac
  done
  return 1
}

# --- argv ------------------------------------------------------------------
JSON=0
parse_flags() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) JSON=1; FLAG_SHIFT=$((FLAG_SHIFT + 1)); shift ;;
      --help) usage; exit 0 ;;
      *) return 0 ;;
    esac
  done
}

FLAG_SHIFT=0
[ $# -gt 0 ] || { usage >&2; exit 1; }
if [ "$1" = --help ]; then usage; exit 0; fi
SUB=$1
shift
FLAG_SHIFT=0
parse_flags "$@"
shift "$FLAG_SHIFT"

command -v jq >/dev/null 2>&1 || die "jq required"

# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"

# Build the normalized spec {state, questions:[{id,type,q,opts}]} on stdout.
case "$SUB" in
  pick|score)
    [ $# -ge 4 ] || die "$SUB needs <state> <question> and at least two options"
    SPEC=$(jq -n --arg id "$SUB" --arg type "$SUB" --arg state "$1" --arg q "$2" \
      '{state: $state, questions: [{id: $id, type: $type, q: $q, opts: $ARGS.positional}]}' \
      --args "${@:3}") || die "could not build the question"
    ;;
  yes)
    [ $# -eq 2 ] || die "yes needs exactly <state> <question>"
    SPEC=$(jq -n --arg id "$SUB" --arg state "$1" --arg q "$2" \
      '{state: $state, questions: [{id: $id, type: "yes", q: $q}]}') || die "could not build the question"
    ;;
  batch)
    [ $# -eq 0 ] || die "batch reads its JSON from stdin and takes no arguments"
    SPEC=$(jq -cs 'if length == 1 then .[0] else error("x") end' 2>/dev/null) \
      || die "batch input must be exactly one JSON object"
    ;;
  *)
    die "unknown command (want pick, yes, score, or batch; --help)"
    ;;
esac

# Validate and normalize: opts becomes an ordered [[label, meaning]] list.
NORM=$(printf '%s' "$SPEC" | jq -c '
  def fail(m): error(m);
  def has_control: ([explode[] | select(. < 32 or (. >= 127 and . <= 159))] | length > 0);
  def has_nul: ([explode[] | select(. == 0)] | length > 0);
  if type != "object" then fail("input must be a JSON object") else . end
  | if (.state | type) != "string" or .state == "" then fail("state must be a non-empty string")
    elif (.state | has_nul) then fail("state must not contain NUL") else . end
  | if (.questions | type) != "array" or (.questions | length) == 0 then fail("questions must be a non-empty array") else . end
  | .questions |= [ to_entries[] | .key as $i | .value
      | if type != "object" then fail("question \($i + 1) must be an object") else . end
      | .id = (if has("id") then .id else "q\($i + 1)" end)
      | if (.id | type) != "string" or (.id | has_control) or (.id | test("^[A-Za-z0-9_-]{1,64}$") | not)
        then fail("question \($i + 1) id must match [A-Za-z0-9_-]{1,64}") else . end
      | if (.q | type) != "string" or .q == "" then fail("question \($i + 1): q must be a non-empty string")
        elif (.q | has_nul) then fail("question \($i + 1): q must not contain NUL") else . end
      | if (.type | IN("pick", "yes", "score") | not) then fail("question \($i + 1): type must be pick, yes, or score") else . end
      | if .type == "yes" then .opts = []
        else
          .opts = (if (.opts | type) == "array" then
                     [ .opts[] | if type != "string" or . == "" then fail("question \($i + 1): options must be non-empty strings") else . end
                       | . as $option
                       | ($option | index("=")) as $separator
                       | if $separator != null
                         then [$option[0:$separator], $option[($separator + 1):]]
                         else [$option, $option]
                         end
                       | if .[0] == "" then fail("question \($i + 1): empty option label") else . end
                       | if .[1] == "" then .[1] = .[0] else . end
                       | if (.[0] | has_control) or (.[1] | has_control)
                         then fail("option labels and meanings must not contain control characters") else . end ]
                   else fail("question \($i + 1): opts must be an array of strings") end)
          | if (.opts | length) < 2 then fail("question \($i + 1): needs at least two options") else . end
          | if .type == "pick" and (.opts | length) > 255 then fail("question \($i + 1): pick supports at most 255 options")
            elif .type == "score" and (.opts | length) > 10 then fail("question \($i + 1): score supports at most 10 levels")
            else . end
          | if ([.opts[][0]] | unique | length) != (.opts | length) then fail("question \($i + 1): option labels must be unique") else . end
        end
      | {id, type, q, opts} ]
  | if ([.questions[].id] | unique | length) != (.questions | length) then fail("question ids must be unique") else . end
  | {state, questions}
' 2>&1) || die "$(printf '%s' "$NORM" | sed -n 's/^jq: error ([^)]*): //p' | head -n 1)"

STATE_TEXT=$(printf '%s' "$NORM" | jq -jr '.state + "x"') \
  || die "could not read normalized state"
STATE_TEXT=${STATE_TEXT%x}
ALL_TEXT=$(printf '%s' "$NORM" | jq -jr '[.state, (.questions[] | .id, .q, (.opts[][]))] | join("\n") + "\nx"') \
  || die "could not read normalized input"

# --- privacy guard -----------------------------------------------------------
INPUT_BYTES=$(printf '%s' "$NORM" | jq -r '[.state, (.questions[] | .id, .q, (.opts[][]))] | map(utf8bytelength) | add')
[ "$INPUT_BYTES" -le "$FM_JEV_CLI_INPUT_MAX" ] \
  || die "input is $INPUT_BYTES bytes, over the $FM_JEV_CLI_INPUT_MAX-byte cap; pass only the facts the judgment needs"
if fm_jev_has_sensitive_key "$ALL_TEXT"; then
  die "input contains a secret, credential, or personal data; refused, nothing sent"
fi
COMPACT=$(fm_jev_compact_state "$ALL_TEXT" 2>/dev/null) \
  || die "could not screen the input for secrets or personal data"
[ "$COMPACT" = "$ALL_TEXT" ] \
  || die "input contains a secret, credential, or personal data; refused, nothing sent"

resolve_typesafe_key
if contains_live_key "$ALL_TEXT"; then
  die "input carries the Jev API key itself; refused, nothing sent"
fi

# --- the call ------------------------------------------------------------------
QUESTIONS=$(printf '%s' "$NORM" | jq -c '
  [ .questions[]
    | { key: .id,
        value: (if .type == "yes" then {type: "noul", instructions: .q}
                elif .type == "pick" then {type: "choice", instructions: .q, criteria: (.opts | map({(.[0]): .[1]}) | add)}
                else {type: "score", instructions: .q, criteria: [.opts[][1]]} end) } ]
  | from_entries')

log_call() {
  local exit_code=$1 response=${2:-} escalated=${3:-0} payload
  payload=$(jq -nc \
    --arg route "${FM_JEV_LAST_ROUTE:-}" \
    --arg model "${FM_JEV_LAST_MODEL:-}" \
    --arg http "${FM_JEV_LAST_HTTP:-}" \
    --arg latency "${FM_JEV_LAST_LATENCY_MS:-}" \
    --argjson questions "$(printf '%s' "$NORM" | jq '.questions | length')" \
    --argjson escalated "$escalated" \
    --argjson exit "$exit_code" \
    --arg response "$response" \
    '{
      purpose: "worker-cli",
      route: $route,
      model: $model,
      http: $http,
      latency_ms: (try ($latency | tonumber) catch null),
      usage: {
        in: (try ($response | fromjson | .usage.input_tokens) catch null),
        out: (try ($response | fromjson | .usage.output_tokens) catch null)
      },
      questions: $questions,
      escalated: $escalated,
      exit: $exit
    }' 2>/dev/null) || return 0
  fm_jev_log_call "$payload" >/dev/null 2>&1 || true
}

# fm_jev_decide runs in this shell, not a command substitution, so the
# FM_JEV_LAST_* globals it sets reach the log record.
OUT_FILE=$(mktemp) || die "mktemp failed"
ERR_FILE=$(mktemp) || { rm -f "$OUT_FILE"; die "mktemp failed"; }
trap 'rm -f "$OUT_FILE" "$ERR_FILE"' EXIT
if ! JEV_ROUTE=typesafe JEV_URL="$FM_JEV_CLI_URL" \
  fm_jev_decide "$STATE_TEXT" "$QUESTIONS" --string >"$OUT_FILE" 2>"$ERR_FILE"; then
  log_call 1
  reason=$(sed -e 's/^jev: //' "$ERR_FILE" | head -n 1)
  die "${reason:-Jev call failed} -> decide yourself"
fi
RESPONSE=$(cat "$OUT_FILE")

# --- output --------------------------------------------------------------------
# Emits "A<TAB>line" per answered question and "E<TAB>line" per escalation, or
# fails with a one-line reason when an answer is missing or mistyped.
LINES=$(jq -rn --argjson spec "$NORM" --argjson resp "$RESPONSE" '
  def r2: (. * 100 | round) / 100;
  def estimate(p): (p | [.[]] | sort | reverse) as $s | (($s[0] // 0) - ($s[1] // 0));
  def unique_top($probabilities):
    ($probabilities | [.[]] | max) as $maximum
    | ([$probabilities[] | select(. == $maximum)] | length) == 1;
  def unit_interval(message):
    if type != "number" or . < 0 or . > 1 then error(message) else . end;
  def checked_probabilities(probabilities; expected_keys; id; kind):
    if probabilities == null or probabilities == {} then {}
    elif (probabilities | type) != "object" then
      error("answer \(id) probabilities must be an object")
    elif (probabilities | keys) != expected_keys then
      error("answer \(id) probability keys do not match offered \(kind)")
    elif any(probabilities[]; type != "number" or . < 0 or . > 1) then
      error("answer \(id) has a probability outside 0..1")
    elif ((((probabilities | [.[]] | add) - 1) | fabs) > 0.0100000001) then
      error("answer \(id) probabilities must sum to approximately 1")
    else probabilities end;
  ($resp.answers // error("response has no answers")) as $answers
  | $spec.questions[]
  | . as $q
  | ($answers[$q.id] // error("response missing answer for \($q.id)")) as $a
  | (if $a.confidence == null then null
     else ($a.confidence | unit_interval("answer \($q.id) confidence must be within 0..1"))
     end) as $confidence
  | if $q.type == "yes" then
      (($a.noul | numbers) // error("answer \($q.id) has no probability")) as $raw_p
      | ($raw_p | unit_interval("answer \($q.id) probability must be within 0..1")) as $p
      | { answer: (if $p >= 0.5 then "yes" else "no" end), p: $p,
          conf: ((($p - 0.5) | fabs) * 2), floor: 0.4 }
    elif $q.type == "pick" then
      (($a.choice | strings) // error("answer \($q.id) has no choice")) as $c
      | checked_probabilities($a.probabilities; ($q.opts | map(.[0]) | sort); $q.id; "options") as $probabilities
      | { answer: $c,
          prior: (if (($q.opts | map(.[0]) | index($c)) == null) then "invalid"
                  elif ($probabilities | length) == 0 then "unknown" else $c end),
          p: ($probabilities[$c] // null),
          conf: (if $confidence != null then $confidence
                 elif ($probabilities | length) > 0 then estimate($probabilities) else null end),
          floor: (if $confidence != null then 0.5 else 0.4 end),
          force_escalate: (($probabilities | length) == 0
            or ($q.opts | map(.[0]) | index($c)) == null
            or (unique_top($probabilities) | not)
            or $probabilities[$c] != ($probabilities | [.[]] | max)) }
    else
      (($a.score | numbers) // error("answer \($q.id) has no score")) as $s
      | ($q.opts | length) as $n
      | checked_probabilities($a.probabilities; ([range(0; $n) | tostring] | sort); $q.id; "levels") as $probabilities
      | if ($probabilities | length) == 0 then
          { answer: "unknown", p: null, s: $s, conf: null, floor: 0.4, force_escalate: true }
        else
          ($probabilities | to_entries | max_by(.value) | {i: (.key | tonumber), p: .value}) as $top
          | ($probabilities | to_entries | map(select(.value == $top.p) | (.key | tonumber))) as $top_indices
          | ((($probabilities | to_entries | map((.key | tonumber) * .value) | add)
              / ($probabilities | [.[]] | add))) as $weighted
          | { answer: $q.opts[$top.i][0], p: $top.p, s: $s,
              conf: (if $confidence != null then $confidence else estimate($probabilities) end),
              floor: (if $confidence != null then 0.5 else 0.4 end),
              # A mean between distant probability peaks is a split judgment; escalate.
              force_escalate: ($s < 0 or $s > ($n - 1)
                or ($top_indices | length) != 1
                or ($top_indices | index($s | round)) == null
                or (($s - $weighted) | fabs) > 0.05) }
        end
    end
  | if (.force_escalate // false) or .conf == null or .conf < .floor then
      "E\t\($q.id): ESCALATE conf=\(if .conf == null then "na" else (.conf | r2) end) prior=\(.prior // .answer) -> decide yourself"
    else
      "A\t\($q.id): \(.answer)\(if .s != null then " s=\(.s | r2)" else "" end)\(if .p != null then " p=\(.p | r2)" else "" end) conf=\(.conf | r2)"
    end
' 2>&1) || {
  reason=$(printf '%s' "$LINES" | sed -n 's/^jq: error ([^)]*): //p' | head -n 1)
  log_call 1 "$RESPONSE"
  die "${reason:-malformed Jev response} -> decide yourself"
}

ESCALATED=$(printf '%s\n' "$LINES" | grep -c '^E' || true)
if [ "$ESCALATED" -gt 0 ]; then CODE=2; else CODE=0; fi
log_call "$CODE" "$RESPONSE" "$ESCALATED"

if [ "$JSON" -eq 1 ]; then
  printf '%s\n' "$RESPONSE"
else
  printf '%s\n' "$LINES" | cut -f2-
fi
exit "$CODE"
