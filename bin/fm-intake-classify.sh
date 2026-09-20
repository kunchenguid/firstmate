#!/usr/bin/env bash
# fm-intake-classify.sh - recommend a firstmate intake disposition with
# typesafe.ai's System One model (Jev), opt-in.
#
# Usage:
#   fm-intake-classify.sh <request-file> [--project <name>]
#
# Opt-in gate: TYPESAFE_API_KEY non-empty in this process environment, else a
#   TYPESAFE_API_KEY= line in $FM_HOME/.env read with fmx_env_get. The
#   environment wins. Absent in both: one "intake-classify: off" line on
#   stderr, nothing on stdout, exit 0, and no network call.
#
# What it does when on: one POST to https://api.typesafe.ai/v1/systemone with
# the project name and a bounded request-text snapshot as state. It asks three
# parallel questions: a Choice recommendation of ship, scout, answer_now, or
# unclear; a NOUL answer about implementation authorization; and a three-level
# urgency Score. Jq composes clear, ambiguous, escalate, or error afterwards.
# The result is recommendation-only: it never spawns a worker, chooses a
# harness or model, or changes firstmate's intake judgment.
#
# Output (stdout, TOON-style block):
#   intake-classify:
#     status: clear | ambiguous | escalate | error
#     model/latency_ms/tokens, deliverable and confidence, intent_clear and
#     confidence, urgency and score, request truncation, and any reason
#   clear     -> a concrete, authorized recommendation for firstmate to inspect
#   ambiguous -> a low-confidence or unclear recommendation
#   escalate  -> no concrete implementation authorization
#   error     -> API, network, response, or rendering failure
#   Every runtime outcome exits 0 so intake is never blocked by this tool.
#   Exit 2 only for a usage or configuration error (unreadable request or
#   missing jq), which is actionable and never selected around.
#
# Environment:
#   TYPESAFE_API_KEY is the only classifier-specific environment setting.
#
# Authority: docs/configuration.md "Typed intake classification" owns the
# operator contract. This script owns flags and exact output. The classifier
# never replaces firstmate judgment or auto-spawns work.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"

CONFIDENCE_FLOOR=0.6
TS_MODEL=jev-latest
TS_BASE=https://api.typesafe.ai
TS_TIMEOUT=5
REQUEST_MAX_BYTES=32768

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}
emit_error() {
  local reason=$1
  printf 'intake-classify: error (%s)\n' "$reason" >&2
  printf 'intake-classify:\n  status: error\n  reason: %s\n' "$reason"
  exit 0
}

REQUEST_FILE='' PROJECT=''
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || die "--project needs a value"; PROJECT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$REQUEST_FILE" ] || die "one request file only"; REQUEST_FILE=$1; shift ;;
  esac
done

# ---- opt-in gate ---------------------------------------------------------------
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
fi
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  printf '%s\n' 'intake-classify: off' >&2
  exit 0
fi

# ---- inputs --------------------------------------------------------------------
[ -n "$REQUEST_FILE" ] || die "request file required (see --help)"
[ -r "$REQUEST_FILE" ] || die "request file not readable: $REQUEST_FILE"
command -v jq >/dev/null 2>&1 || die "jq required"

REQUEST_SNAPSHOT=$(mktemp) || die "mktemp failed"
RESP_FILE=$(mktemp) || { rm -f "$REQUEST_SNAPSHOT"; die "mktemp failed"; }
trap 'rm -f "$REQUEST_SNAPSHOT" "$RESP_FILE"' EXIT
head -c "$REQUEST_MAX_BYTES" "$REQUEST_FILE" > "$REQUEST_SNAPSHOT" || die "could not read request file: $REQUEST_FILE"
REQUEST_BYTES=$(wc -c < "$REQUEST_FILE" | tr -d '[:space:]')
case "$REQUEST_BYTES" in ''|*[!0-9]*) die "could not measure request file: $REQUEST_FILE" ;; esac
if [ "$REQUEST_BYTES" -gt "$REQUEST_MAX_BYTES" ]; then REQUEST_TRUNCATED=true; else REQUEST_TRUNCATED=false; fi

# ---- one System One request ----------------------------------------------------
command -v curl >/dev/null 2>&1 || emit_error "curl not installed"
REQUEST=$(jq -n --rawfile request "$REQUEST_SNAPSHOT" --arg project "$PROJECT" --arg model "$TS_MODEL" '
  {
    model: $model,
    state: {intake: {project: $project, request: $request}},
    questions: {
      deliverable: {
        type: "choice",
        instructions: "Which disposition should firstmate consider for this request? This is advice only and must not create, dispatch, or select any worker.",
        criteria: {
          ship: "A concrete, authorized implementation change should be handled as a ship task.",
          scout: "The request needs bounded investigation, reproduction, audit, or planning before an implementation decision.",
          answer_now: "The request can be answered directly now without creating a worker task.",
          unclear: "The request is too incomplete or conflicting to recommend a disposition."
        }
      },
      intent_clear: {
        type: "noul",
        instructions: "Is the captain already authorizing a concrete implementation change in this request? Answer true only when the requested change and scope are sufficiently concrete."
      },
      urgency: {
        type: "score",
        instructions: "Score urgency on this ordered scale: 0 routine means ordinary work with no material time pressure; 1 soon means a stated near-term deadline or materially useful prompt follow-up; 2 blocking means current work, a release, safety, or a stated deadline is blocked until this is addressed.",
        criteria: [
          "0 routine: ordinary work with no material time pressure.",
          "1 soon: a stated near-term deadline or materially useful prompt follow-up.",
          "2 blocking: current work, a release, safety, or a stated deadline is blocked until this is addressed."
        ]
      }
    }
  }') || emit_error "request rendering failed"

T0=$(fm_timing_now_ms)
HTTP=$(printf '%s' "$REQUEST" | curl -q -sS --max-time "$TS_TIMEOUT" -o "$RESP_FILE" -w '%{http_code}' \
  -X POST "$TS_BASE/v1/systemone" -H 'Content-Type: application/json' \
  -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") \
  --data-binary @- 2>/dev/null) || HTTP=000
T1=$(fm_timing_now_ms)
LAT_MS=$(( T1 - T0 ))
[ "$HTTP" = 200 ] || emit_error "http $HTTP after ${LAT_MS} ms: $(head -c 200 "$RESP_FILE" 2>/dev/null | tr '\n' ' ')"

# ---- response validation and status composition --------------------------------
jq -e '
  def confidence($a): $a.confidence;
  def intent_noul($a): $a.noul;
  def urgency_score($a): $a.score;
  def confidence_ok($a): (confidence($a) | type) == "number" and confidence($a) >= 0 and confidence($a) <= 1;
  (.answers | type) == "object" and
  (.answers.deliverable | type) == "object" and
  (.answers.deliverable.choice | type) == "string" and
  (.answers.deliverable.choice as $choice | ["ship", "scout", "answer_now", "unclear"] | index($choice)) != null and
  confidence_ok(.answers.deliverable) and
  (.answers.deliverable.probabilities | type) == "object" and
  ((.answers.deliverable.probabilities | keys | sort) == ["answer_now", "scout", "ship", "unclear"]) and
  all(.answers.deliverable.probabilities[]; type == "number" and . >= 0 and . <= 1) and
  ((.answers.deliverable.probabilities | [.[]] | add) as $total | $total >= 0.99 and $total <= 1.01) and
  (.answers.intent_clear | type) == "object" and
  (intent_noul(.answers.intent_clear) | type) == "number" and
  intent_noul(.answers.intent_clear) >= 0 and intent_noul(.answers.intent_clear) <= 1 and
  (.answers.urgency | type) == "object" and
  (urgency_score(.answers.urgency) | type) == "number" and
  urgency_score(.answers.urgency) >= 0 and urgency_score(.answers.urgency) <= 2 and
  confidence_ok(.answers.urgency) and
  ((has("usage") | not) or
    ((.usage | type) == "object" and
     (.usage.input_tokens | type) == "number" and
     (.usage.output_tokens | type) == "number"))
' "$RESP_FILE" >/dev/null 2>&1 || emit_error "response is not a typed intake answer"

RESULT=$(jq -n --argjson floor "$CONFIDENCE_FLOOR" --argjson latency "$LAT_MS" --argjson truncated "$REQUEST_TRUNCATED" --slurpfile response "$RESP_FILE" '
  ($response[0]) as $r |
  ($r.answers.deliverable) as $deliverable |
  ($r.answers.intent_clear) as $intent |
  ($r.answers.urgency) as $urgency |
  def intent_noul: .noul;
  def urgency_score: .score;
  def urgency_level($score):
    if $score < 0.5 then "routine"
    elif $score < 1.5 then "soon"
    else "blocking"
    end;
  ($deliverable.confidence) as $deliverable_confidence |
  ($intent | intent_noul) as $intent_noul |
  ($urgency.confidence) as $urgency_confidence |
  ([ $deliverable_confidence, $urgency_confidence ] | min) as $confidence |
  {
    model: $r.model,
    latency_ms: $latency,
    tokens: ($r.usage // null),
    deliverable: $deliverable.choice,
    deliverable_confidence: $deliverable_confidence,
    deliverable_probabilities: $deliverable.probabilities,
    intent_clear: ($intent_noul >= $floor),
    intent_clear_noul: $intent_noul,
    urgency: urgency_level($urgency | urgency_score),
    urgency_score: ($urgency | urgency_score),
    urgency_confidence: $urgency_confidence,
    confidence: $confidence,
    request_truncated: $truncated
  } |
  if $confidence < $floor then
    . + {status: "ambiguous", reason: "lowest answer confidence \($confidence) below floor \($floor)"}
  elif .intent_clear != true then
    . + {status: "escalate", reason: "concrete implementation authorization is not clear"}
  elif .deliverable == "unclear" then
    . + {status: "ambiguous", reason: "deliverable recommendation is unclear"}
  else . + {status: "clear"}
  end') || emit_error "status composition failed"

TEXT=$(jq -r '
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($value): ($value // "-") | flat;
  "intake-classify:",
  "  status: \(.status | flat)",
  "  model: \(show(.model))   latency_ms: \(show(.latency_ms))   tokens: \(show(.tokens.input_tokens))/\(show(.tokens.output_tokens))",
  "  deliverable: \(.deliverable | flat)   confidence: \(.deliverable_confidence | flat)",
  "  probabilities: \([.deliverable_probabilities | to_entries[] | "\(.key | flat)=\(.value | flat)"] | join(" "))",
  "  intent_clear: \(.intent_clear | flat)   noul: \(.intent_clear_noul | flat)",
  "  urgency: \(.urgency | flat)   score: \(.urgency_score | flat)   confidence: \(.urgency_confidence | flat)",
  "  request_truncated: \(.request_truncated | flat)",
  (if .reason then "  reason: \(.reason | flat)" else empty end)' <<<"$RESULT") || emit_error "output rendering failed"
printf '%s\n' "$TEXT"
exit 0
