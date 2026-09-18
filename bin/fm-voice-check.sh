#!/usr/bin/env bash
# fm-voice-check.sh - check a pull request or issue description, or a no-mistakes
# --intent string, for internal voice before it is published, opt-in.
#
# Usage:
#   fm-voice-check.sh [--kind pr|issue|intent] [--language <name>]
#                     [--accept-unverified <reason>] <text-file|->
#
# Opt-in gate: the same TYPESAFE_API_KEY as bin/fm-dispatch-resolve.sh, from
#   this process environment or a TYPESAFE_API_KEY= line in $FM_HOME/.env; the
#   environment wins. Absent in both: one "voice-check: off" line on stderr,
#   nothing on stdout, exit 0, and no network call, so publication proceeds
#   exactly as it does without the check. bin/fm-typesafe-lib.sh owns the
#   service client and key handling.
#
# What it does when on: one POST to typesafe.ai's System One with the text as
#   state and four closed yes/no questions, one per kind of internal voice:
#     operator_address  direct address to the human operator ("Captain, ...")
#     relayed_orders    supervisor orders to the implementing worker ("do not
#                       merge", "in the new PR description, explain ...")
#     quoted_answer     the operator's conversational answer, ruling, or words
#                       quoted or reported
#     other_language    prose in a language other than --language (English)
#   The service only answers; every decision below is code.
#
# Decision, per category and then for the text:
#   yes is the answer (any confidence)          -> category flagged
#   no with confidence >= 0.6                   -> category clear
#   no below that floor                         -> category uncertain
#   any flagged                                 -> status flagged, exit 1
#   all clear                                   -> status clear, exit 0
#   otherwise, or no usable answer (transport, timeout, HTTP, or malformed
#   response, after one retry)                  -> status unverified, exit 3
#   A flagged text is never published by this tool's verdict: no flag or
#   override turns flagged into exit 0.
#   --accept-unverified <reason> turns an unverified result (and only that) into
#   exit 0 and prints the reason; use it only on an explicit instruction for
#   that one publication.
#
# Output (stdout):
#   voice-check:
#     status: clear | flagged | unverified
#     kind: pr | issue | intent
#     finding: <category> yes=<p> confidence=<c>     (flagged categories)
#     uncertain: <category> yes=<p> confidence=<c>   (uncertain categories)
#     reason: <why the status is not clear>
#     accepted-unverified: <reason>                  (override used)
#   Exit: 0 clear, off, or accepted unverified; 1 flagged; 3 unverified;
#   2 usage error (unreadable text, empty text, bad flag, or missing jq).
#
# docs/configuration.md "Pre-publication voice check" owns the operator
# contract and the publication points that call this tool.
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
# shellcheck source=bin/fm-typesafe-lib.sh
. "$SCRIPT_DIR/fm-typesafe-lib.sh"

# A full description is longer than a dispatch brief; allow it more time.
FM_TYPESAFE_TIMEOUT=20
CONFIDENCE_FLOOR=0.6
EXIT_FLAGGED=1
EXIT_UNVERIFIED=3

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

KIND=pr LANGUAGE=English ACCEPT_UNVERIFIED='' INPUT=''
while [ $# -gt 0 ]; do
  case "$1" in
    --kind)
      [ $# -ge 2 ] || die "--kind needs a value"
      case "$2" in pr|issue|intent) KIND=$2 ;; *) die "--kind must be pr, issue, or intent" ;; esac
      shift 2 ;;
    --language) [ $# -ge 2 ] && [ -n "$2" ] || die "--language needs a value"; LANGUAGE=$2; shift 2 ;;
    --accept-unverified)
      [ $# -ge 2 ] && [ -n "$(printf '%s' "$2" | tr -d '[:space:]')" ] || die "--accept-unverified needs a reason"
      ACCEPT_UNVERIFIED=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -) [ -z "$INPUT" ] || die "one text input only"; INPUT=-; shift ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$INPUT" ] || die "one text input only"; INPUT=$1; shift ;;
  esac
done
[ -n "$INPUT" ] || die "text file or - required (see --help)"

if ! fm_typesafe_key_resolve "$FM_HOME/.env"; then
  echo "voice-check: off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env)" >&2
  exit 0
fi

command -v jq >/dev/null 2>&1 || die "jq required"
TEXT_FILE=$(mktemp) || die "mktemp failed"
RESP_FILE=$(mktemp) || { rm -f "$TEXT_FILE"; die "mktemp failed"; }
trap 'rm -f "$TEXT_FILE" "$RESP_FILE"' EXIT
if [ "$INPUT" = - ]; then
  cat > "$TEXT_FILE" || die "could not read text from stdin"
else
  [ -r "$INPUT" ] && [ -f "$INPUT" ] || die "text file not readable: $INPUT"
  cat "$INPUT" > "$TEXT_FILE" || die "could not read text file: $INPUT"
fi
[ -n "$(tr -d '[:space:]' < "$TEXT_FILE")" ] || die "text is empty"

case "$KIND" in
  pr) ARTIFACT="pull request description" ;;
  issue) ARTIFACT="issue description" ;;
  intent) ARTIFACT="pull request intent section" ;;
esac

emit() {  # <status> <reason-or-empty> [<findings-json>]
  local status=$1 reason=$2 findings=${3:-'[]'}
  printf 'voice-check:\n  status: %s\n  kind: %s\n' "$status" "$KIND"
  jq -r '.[] | "  \(.line): \(.category) yes=\(.yes) confidence=\(.confidence)"' <<<"$findings"
  [ -z "$reason" ] || printf '  reason: %s\n' "$(printf '%s' "$reason" | tr '\t\r\n' '   ')"
}

unverified() {  # <reason> [<findings-json>]
  if [ -n "$ACCEPT_UNVERIFIED" ]; then
    emit unverified "$1" "${2:-[]}"
    printf '  accepted-unverified: %s\n' "$(printf '%s' "$ACCEPT_UNVERIFIED" | tr '\t\r\n' '   ')"
    exit 0
  fi
  emit unverified "$1" "${2:-[]}"
  echo "voice-check: unverified ($1); do not publish this text without an explicit instruction" >&2
  exit "$EXIT_UNVERIFIED"
}

REQUEST=$(jq -n --rawfile text "$TEXT_FILE" --arg model "$FM_TYPESAFE_MODEL" \
  --arg artifact "$ARTIFACT" --arg language "$LANGUAGE" '
  def q($i): {type: "choice", instructions: $i, criteria: {yes: "Yes, the text does this.", no: "No, the text does not do this."}};
  {
    model: $model,
    state: {artifact: {kind: $artifact, expected_language: $language, text: $text}},
    questions: {
      operator_address: q("`artifact.text` is about to be published as a public \($artifact) on a code forge, written by an AI agent working for a human operator. Does it speak directly TO that human operator, for example greeting or calling them \"captain\", \"Captain,\", or addressing them as you? Mentions of \"captain\" as a product role or term (captain-held, the captain decision board, captain intent) and addressing the public reader or maintainer are NOT direct address to the operator."),
      relayed_orders: q("`artifact.text` is about to be published as a public \($artifact). Does it contain orders a supervisor gave to the worker agent about how to do or deliver the work, rather than a statement of what the change must do? Examples: \"do not merge\", \"in the new PR description, explain ...\", \"when you write the pull request, state ...\", \"do not re-raise\", \"TO DELIVER:\", \"FORBIDDEN:\", \"so you know what depends on this\". Requirements on the software behaviour itself are NOT orders."),
      quoted_answer: q("`artifact.text` is about to be published as a public \($artifact). Does it quote or report the human operator'"'"'s own conversational answer, ruling, choice, or words (for example \"His words: ...\", \"the captain answered\", \"the captain ruled this himself\", a one-word answer such as \"yes\" or \"oui\" attributed to the operator)? Citing a public issue, a maintainer comment, or documentation is NOT this."),
      other_language: q("`artifact.text` is about to be published as a public \($artifact) that must be written in \($language). Is any passage of prose, including quoted prose, written in a natural language other than \($language)? Code, identifiers, file paths, command lines, and proper names do NOT count.")
    }
  }') || die "could not build the request"

attempt_post() {
  fm_typesafe_post "$RESP_FILE" <<<"$REQUEST"
  [ "$FM_TYPESAFE_HTTP" = 200 ] || return 1
  jq -e '
    def ok($a): ($a | type) == "object" and
      (["yes", "no"] | index($a.choice)) != null and
      ($a.confidence | type) == "number" and $a.confidence >= 0 and $a.confidence <= 1 and
      ($a.probabilities | type) == "object" and
      (($a.probabilities | keys | sort) == ["no", "yes"]) and
      all($a.probabilities[]; type == "number" and . >= 0 and . <= 1) and
      (($a.probabilities | [.[]] | add) as $t | $t >= 0.99 and $t <= 1.01);
    ok(.answers.operator_address) and ok(.answers.relayed_orders) and
    ok(.answers.quoted_answer) and ok(.answers.other_language)' "$RESP_FILE" >/dev/null 2>&1
}

if ! attempt_post && ! attempt_post; then
  if [ "$FM_TYPESAFE_HTTP" = 200 ]; then
    unverified "service response is not a yes/no answer for every category"
  fi
  unverified "service unavailable: http $FM_TYPESAFE_HTTP after ${FM_TYPESAFE_LATENCY_MS} ms"
fi

VERDICT=$(jq -c --argjson floor "$CONFIDENCE_FLOOR" '
  [.answers | to_entries[]
   | select(.key == "operator_address" or .key == "relayed_orders" or .key == "quoted_answer" or .key == "other_language")
   | {category: .key, yes: .value.probabilities.yes, confidence: .value.confidence,
      state: (if .value.choice == "yes" then "flagged"
              elif .value.confidence >= $floor then "clear"
              else "uncertain" end)}]
  | {flagged: map(select(.state == "flagged") | . + {line: "finding"}),
     uncertain: map(select(.state == "uncertain") | . + {line: "uncertain"})}' "$RESP_FILE") \
  || unverified "service response could not be judged"

if [ "$(jq '.flagged | length' <<<"$VERDICT")" -gt 0 ]; then
  emit flagged "internal voice found; do not publish this text, rewrite it for its public reader" \
    "$(jq -c '.flagged + .uncertain' <<<"$VERDICT")"
  echo "voice-check: flagged; do not publish this text" >&2
  exit "$EXIT_FLAGGED"
fi
if [ "$(jq '.uncertain | length' <<<"$VERDICT")" -gt 0 ]; then
  unverified "confidence below $CONFIDENCE_FLOOR on a category the service leaned clear" "$(jq -c '.uncertain' <<<"$VERDICT")"
fi
emit clear ''
exit 0
