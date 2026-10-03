# shellcheck shell=bash
# shellcheck disable=SC2034 # Answer output globals are read by sourcing callers.
# fm-jev-lib.sh - the shared shape every Jev-consulting tool in this repo uses.
# Usage: . bin/fm-jev-lib.sh
#
# Jev is typesafe.ai's System One model. A tool that consults it is ALWAYS a
# second opinion on top of a deterministic answer, never the authority. This
# library owns the parts that must be identical across every such tool, so the
# safety properties are stated once instead of re-derived per tool:
#
#   - The opt-in gate. No key means no network call and no behavior change.
#   - Fail-open. Every failure is an answer of `unavailable`, never an error the
#     caller must handle and never a blocked decision.
#   - Key hygiene. The key lives in one shell variable and reaches curl through
#     a file descriptor, never on argv, and nothing logs or writes it.
#   - Coarse telemetry and bounded calibration, both free of task ids, of PHI,
#     and of message content. Calibration records the candidate and chosen
#     option keys by design (seat ids among them), because comparing the
#     model's confidence against the option it picked is what it is for.
#
# bin/fm-dispatch-resolve.sh is this family's precedent and predates this
# library; it carries its own copy of the client and is deliberately left alone
# rather than refactored underneath a working tool. New members use this.
#
# THE FAMILY. Each member is named here so the set is inspectable rather than
# discovered by grep:
#   dispatch-resolve   bin/fm-dispatch-resolve.sh     which dispatch profile fits a brief
#   alert-route        bin/fm-alert-route.sh          which seat charter owns an unowned alert
#   seat-state-advise  bin/fm-seat-state-advise.sh    is an inconclusive seat waiting or wedged
fm_jev_members() {
  printf '%s\n' \
    'dispatch-resolve bin/fm-dispatch-resolve.sh' \
    'alert-route bin/fm-alert-route.sh' \
    'seat-state-advise bin/fm-seat-state-advise.sh'
}

FM_JEV_MODEL_PIN=jev-latest
FM_JEV_BASE=https://api.typesafe.ai
FM_JEV_TIMEOUT=5
FM_JEV_CONFIDENCE_FLOOR=0.6
FM_JEV_CALIBRATION_MAX=${FM_JEV_CALIBRATION_MAX:-200}

# fm_jev_key_resolve: environment wins, then <home>/.env, exactly as the
# precedent resolves it. Returns 1 when the tool is off, and the caller then
# prints its own one-line off notice and exits 0 without a network call.
fm_jev_key_resolve() {  # <home>
  FM_JEV_KEY=${TYPESAFE_API_KEY:-}
  unset TYPESAFE_API_KEY
  if [ -z "$FM_JEV_KEY" ] && command -v fmx_env_get >/dev/null 2>&1; then
    FM_JEV_KEY=$(fmx_env_get TYPESAFE_API_KEY "$1/.env")
  fi
  [ -n "$FM_JEV_KEY" ]
}

# fm_jev_ask <question-name> <state-json> <criteria-json> <instructions>
#
# One POST carrying one Choice question. On success sets FM_JEV_CHOICE,
# FM_JEV_CONFIDENCE, FM_JEV_PROBS, FM_JEV_LATENCY_MS and FM_JEV_TOKENS, and
# returns 0. On ANY failure - missing curl or jq, transport, timeout, non-200,
# or a malformed answer - sets FM_JEV_REASON and returns 1. It never exits, so
# fail-open stays the caller's single code path.
fm_jev_ask() {
  local qname=$1 state=$2 criteria=$3 instructions=$4 resp req http t0 t1
  FM_JEV_CHOICE='' FM_JEV_CONFIDENCE='' FM_JEV_PROBS=''
  FM_JEV_LATENCY_MS=null FM_JEV_TOKENS=null FM_JEV_REASON=''
  command -v curl >/dev/null 2>&1 || { FM_JEV_REASON='curl not installed'; return 1; }
  command -v jq >/dev/null 2>&1 || { FM_JEV_REASON='jq not installed'; return 1; }
  resp=$(mktemp) || { FM_JEV_REASON='mktemp failed'; return 1; }
  req=$(jq -n --arg model "$FM_JEV_MODEL_PIN" --arg q "$qname" \
    --arg instructions "$instructions" \
    --argjson state "$state" --argjson criteria "$criteria" '
    {model: $model, state: $state,
     questions: {($q): {type: "choice", instructions: $instructions, criteria: $criteria}}}' \
    2>/dev/null) || { rm -f "$resp"; FM_JEV_REASON='could not build the request'; return 1; }
  t0=$(fm_timing_now_ms)
  http=$(printf '%s' "$req" | curl -sS --max-time "$FM_JEV_TIMEOUT" -o "$resp" -w '%{http_code}' \
    -X POST "$FM_JEV_BASE/v1/systemone" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$FM_JEV_KEY") \
    --data-binary @- 2>/dev/null) || http=000
  t1=$(fm_timing_now_ms)
  FM_JEV_LATENCY_MS=$(( t1 - t0 ))
  if [ "$http" != 200 ]; then
    FM_JEV_REASON="http $http after ${FM_JEV_LATENCY_MS} ms"
    rm -f "$resp"
    return 1
  fi
  # The answer must be a well-formed Choice over exactly the options asked, with
  # probabilities that sum to one. A response that merely parses is not an
  # answer; anything less is unavailable rather than half-trusted.
  if ! jq -e --arg q "$qname" --argjson criteria "$criteria" '
      ($criteria | keys | sort) as $choices |
      (.answers[$q].choice | type) == "string" and
      ((.answers[$q].choice) as $c | $choices | index($c) != null) and
      (.answers[$q].confidence | type) == "number" and
      .answers[$q].confidence >= 0 and .answers[$q].confidence <= 1 and
      (.answers[$q].probabilities | type) == "object" and
      ((.answers[$q].probabilities | keys | sort) == $choices) and
      all(.answers[$q].probabilities[]; type == "number" and . >= 0 and . <= 1) and
      ((.answers[$q].probabilities | [.[]] | add) as $t | $t >= 0.99 and $t <= 1.01)' \
      "$resp" >/dev/null 2>&1; then
    FM_JEV_REASON="response is not a $qname Choice answer"
    rm -f "$resp"
    return 1
  fi
  FM_JEV_CHOICE=$(jq -r --arg q "$qname" '.answers[$q].choice' "$resp")
  FM_JEV_CONFIDENCE=$(jq -r --arg q "$qname" '.answers[$q].confidence' "$resp")
  FM_JEV_PROBS=$(jq -r --arg q "$qname" \
    '.answers[$q].probabilities | to_entries | map("\(.key)=\(.value)") | join(" ")' "$resp")
  FM_JEV_TOKENS=$(jq -r 'if has("usage") then ((.usage.input_tokens // 0) + (.usage.output_tokens // 0)) else "null" end' "$resp")
  rm -f "$resp"
}

# fm_jev_clears_floor <confidence>: the shared confidence floor, so one tool
# cannot quietly trust a weaker answer than another.
fm_jev_clears_floor() {
  case "${1:-}" in ''|*[!0-9.]*) return 1 ;; esac
  awk -v c="$1" -v f="$FM_JEV_CONFIDENCE_FLOOR" 'BEGIN { exit (c >= f) ? 0 : 1 }'
}

# fm_jev_telemetry <state-dir> <tool> <key=value>...
#
# One coarse line per decision, appended to state/.<tool>-telemetry. It carries
# NO task id, NO lane or seat name, and none of the content the model was shown,
# because this file exists to show whether the tool is working, not what it
# was asked about. Callers pass only bucketed or enumerated values.
fm_jev_telemetry() {
  local dir=$1 tool=$2
  shift 2
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  umask 077
  printf '%s\t%s\t%s\n' "$(date +%s)" "$tool" "$*" >> "$dir/.$tool-telemetry" 2>/dev/null || return 0
}

# fm_jev_calibration <state-dir> <tool> <json-object>
#
# One JSON line per decision for the first FM_JEV_CALIBRATION_MAX decisions,
# then nothing, so an always-on tool cannot grow this file without bound. Same
# content rule as telemetry: no task id, no PHI, no message content, and no
# free text. What it records by design is the deterministic verdict, the
# candidate and chosen option keys (seat ids for alert routing), and their
# confidence and probabilities, which is the comparison calibration exists for.
fm_jev_calibration() {
  local dir=$1 tool=$2 line=$3 f
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  f="$dir/.$tool-calibration.jsonl"
  if [ -f "$f" ]; then
    [ "$(awk 'END { print NR + 0 }' "$f" 2>/dev/null || printf 0)" -lt "$FM_JEV_CALIBRATION_MAX" ] || return 0
  fi
  umask 077
  printf '%s\n' "$line" >> "$f" 2>/dev/null || return 0
}
