#!/usr/bin/env bash
# fm-jev-router.sh - route a captain request with typesafe.ai's System One
# model (Jev) in one typed call, confidence-gated.
#
# Sends the request text as TypeSafe "state" plus six typed routing questions
# (project, deliverable, effort class, worker, surface, safety) in a single
# POST, then applies confidence-gated routing:
#   - a high safety flag escalates (exit 2) even when routing is otherwise
#     confident;
#   - an unknown project or low confidence on project or worker escalates
#     (exit 2) instead of guessing;
#   - high confidence routes (exit 0); medium confidence routes but flags the
#     suggestion for review (exit 0);
#   - a missing key, missing input, transport error, or malformed response is
#     an error (exit 1); the router never fabricates a route.
# The router is advisory: it publishes an inspectable suggestion and a
# machine-readable exit code, and never spawns, merges, or mutates anything.
#
# Opt-in key: TYPESAFE_API_KEY non-empty in this process environment, else a
#   TYPESAFE_API_KEY= line in $FM_HOME/.env read with fmx_env_get
#   (bin/fm-env-lib.sh), the same accessor the typed dispatch resolver and the
#   Relay pairing token use. The environment wins. The key lives in one shell
#   variable and reaches curl only as a header read from a file descriptor,
#   never on argv; nothing prints, logs, or writes it. --dry-run previews the
#   request without a key.
#
# Exit codes:
#   0  routed (confident or flagged-for-review)
#   2  escalated (safety flag, unknown project, or low confidence)
#   1  error (missing input, missing key, transport error, malformed response)
#
# Usage:
#   fm-jev-router.sh --state "add a pricing page to the marketing site"
#   echo "rotate the credentials in the operator workspace" | fm-jev-router.sh
#   fm-jev-router.sh --dry-run --state "audit the billing site for SEO"
#   fm-jev-router.sh --help
#
# Environment:
#   TYPESAFE_API_KEY   required for a live call; else use --dry-run
#   JEV_MODEL          model id (default jev-latest)
#   JEV_HIGH           high-confidence threshold, route on >= (default 0.7)
#   JEV_LOW            low-confidence threshold, escalate on < (default 0.4)
#   JEV_HIGH and JEV_LOW are numbers in 0..1.
#
# The six routing dimensions (names, types, and instructions) are the shipped
# default; the safety dimension is three atomic Noul judgments (destructive,
# irreversible, security-sensitive), and a high value on any one escalates.
# Project and worker criteria are deliberately neutral placeholders - no fleet
# project or secondmate name is hard-coded here, so a not-yet-wired router
# escalates on every project and routes the worker to "main". Registry-driven
# criteria are a later phase (docs/configuration.md "Jev intake router").
#
# The endpoint is fixed at https://api.typesafe.ai and the request timeout at 5
# seconds, matching the typed dispatch resolver.
set -euo pipefail

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

TS_MODEL="${JEV_MODEL:-jev-latest}"
TS_BASE="https://api.typesafe.ai"
TS_TIMEOUT=5
HIGH="${JEV_HIGH:-0.7}"
LOW="${JEV_LOW:-0.4}"
SAFETY_FLAG=0.5

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() { printf 'fm-jev-router: %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Gather the state (the captain's request) from --state / --file / argv / stdin.
# ---------------------------------------------------------------------------
DRY=0
STATE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --state) STATE="${2:-}"; shift 2 ;;
    --file) STATE="$(cat "${2:-}")"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) STATE="${STATE:+$STATE }$1"; shift ;;
  esac
done
if [[ -z "$STATE" && ! -t 0 ]]; then
  STATE="$(cat)"
fi
[[ -n "$STATE" ]] || die "no request text provided (use --state, --file, argv, or stdin)"

# ---------------------------------------------------------------------------
# The routing questions: six dimensions, with the safety dimension expressed as
# three atomic Noul judgments (destructive, irreversible, security-sensitive).
# Each question is one snap judgment; Jev evaluates them all in parallel against
# the same state.
# ---------------------------------------------------------------------------
QUESTIONS_JSON='{
  "project": {
    "type": "choice",
    "instructions": "Which project does this request belong to?",
    "criteria": {
      "other": "does not match a known project"
    }
  },
  "deliverable": {
    "type": "choice",
    "instructions": "Is this request a knowledge deliverable or a code change?",
    "criteria": {
      "scout": "investigation, audit, diagnosis, report, research, or planning with no code change",
      "ship": "a change to project code, configuration, or deployment"
    }
  },
  "effort_class": {
    "type": "choice",
    "instructions": "What reasoning effort class does this request need?",
    "criteria": {
      "low": "well-understood and mechanical with explicit steps",
      "medium": "moderate complexity or some ambiguity",
      "xhigh": "ambiguous investigation, open-ended design, or high uncertainty"
    }
  },
  "safety_destructive": {
    "type": "noul",
    "instructions": "Does this request delete, overwrite, or destroy data, state, or resources?"
  },
  "safety_irreversible": {
    "type": "noul",
    "instructions": "Is this request impossible or impractical to undo once performed?"
  },
  "safety_security": {
    "type": "noul",
    "instructions": "Does this request touch credentials, secrets, access control, or security-sensitive changes?"
  },
  "secondmate_scope": {
    "type": "choice",
    "instructions": "Which worker should this request route to?",
    "criteria": {
      "main": "main-desk or unassigned work"
    }
  },
  "surface": {
    "type": "choice",
    "instructions": "Is this request product-facing or internal tooling?",
    "criteria": {
      "product": "customer-facing product or marketing surface",
      "internal": "internal-only tooling, automation, operator process, or release work",
      "uncertain": "mixed or cannot tell"
    }
  }
}'

build_request() {
  jq -n \
    --arg model "$TS_MODEL" \
    --arg state "$STATE" \
    --argjson questions "$QUESTIONS_JSON" \
    '{model: $model, state: $state, questions: $questions}'
}

# ---------------------------------------------------------------------------
# Confidence band: high (act), medium (flag), low (escalate).
# ---------------------------------------------------------------------------
band() {  # <confidence> -> high|medium|low
  awk -v c="$1" -v hi="$HIGH" -v lo="$LOW" \
    'BEGIN{ if (c+0 >= hi+0) print "high"; else if (c+0 < lo+0) print "low"; else print "medium" }'
}

# ---------------------------------------------------------------------------
# Render the routing decision in plain English from the parsed answers.
# Returns 0 for route and 2 for escalate.
# ---------------------------------------------------------------------------
render_decision() {  # <response-file>
  local resp="$1"
  local pc pd pe ss sf sdest sirrev ssec pc_conf sc_conf pband dest route high_flags
  pc=$(jq -r '.answers.project.choice // "?"' "$resp")
  pd=$(jq -r '.answers.deliverable.choice // "?"' "$resp")
  pe=$(jq -r '.answers.effort_class.choice // "?"' "$resp")
  ss=$(jq -r '.answers.secondmate_scope.choice // "?"' "$resp")
  sf=$(jq -r '.answers.surface.choice // "?"' "$resp")
  sdest=$(jq -r '.answers.safety_destructive.noul // 0' "$resp")
  sirrev=$(jq -r '.answers.safety_irreversible.noul // 0' "$resp")
  ssec=$(jq -r '.answers.safety_security.noul // 0' "$resp")
  pc_conf=$(jq -r '.answers.project.confidence // 0' "$resp")
  sc_conf=$(jq -r '.answers.secondmate_scope.confidence // 0' "$resp")

  printf '%s\n' '--- Jev routing ---'
  printf 'project        : %s  (confidence %s)\n' "$pc" "$(printf '%.2f' "$pc_conf")"
  printf 'deliverable    : %s\n' "$pd"
  printf 'effort class   : %s\n' "$pe"
  printf 'worker         : %s  (confidence %s)\n' "$ss" "$(printf '%.2f' "$sc_conf")"
  printf 'surface        : %s\n' "$sf"
  printf 'safety         : destructive %s, irreversible %s, security %s\n' \
    "$(printf '%.2f' "$sdest")" "$(printf '%.2f' "$sirrev")" "$(printf '%.2f' "$ssec")"

  # Escalation gates first, in priority order. Any atomic safety judgment at or
  # above SAFETY_FLAG escalates.
  high_flags=""
  if awk -v n="$sdest" -v f="$SAFETY_FLAG" 'BEGIN{exit !(n+0 >= f+0)}'; then high_flags="${high_flags:+$high_flags, }destructive"; fi
  if awk -v n="$sirrev" -v f="$SAFETY_FLAG" 'BEGIN{exit !(n+0 >= f+0)}'; then high_flags="${high_flags:+$high_flags, }irreversible"; fi
  if awk -v n="$ssec" -v f="$SAFETY_FLAG" 'BEGIN{exit !(n+0 >= f+0)}'; then high_flags="${high_flags:+$high_flags, }security-sensitive"; fi
  if [[ -n "$high_flags" ]]; then
    printf '\n%s\n' "DECISION: ESCALATE - safety flag is high ($high_flags). Route to the captain."
    return 2
  fi
  if [[ "$pc" == "other" ]]; then
    printf '\n%s\n' 'DECISION: ESCALATE - no known project matched. Resolve the project manually before dispatch.'
    return 2
  fi
  if [[ "$(band "$pc_conf")" == "low" ]]; then
    printf '\nDECISION: ESCALATE - low confidence on project (below %s). Do not guess; resolve manually.\n' "$LOW"
    return 2
  fi
  if [[ "$(band "$sc_conf")" == "low" ]]; then
    printf '\nDECISION: ESCALATE - low confidence on worker routing (below %s). Resolve manually.\n' "$LOW"
    return 2
  fi

  # Compose the route suggestion.
  dest="$ss"
  [[ "$dest" == "main" ]] && dest="main desk"
  route="$pc -> $dest -> $pd (effort: $pe, surface: $sf)"

  printf '\n'
  pband=$(band "$pc_conf")
  if [[ "$pband" == "high" ]]; then
    printf 'DECISION: ROUTE - %s\n' "$route"
  else
    printf 'DECISION: ROUTE (FLAG FOR REVIEW) - %s\n' "$route"
    printf '  %s\n' 'medium confidence; confirm the project match before dispatch.'
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
REQUEST=$(build_request)

if [[ "$DRY" == "1" ]]; then
  echo "=== DRY RUN (no API call) ==="
  echo "--- request that would be sent to $TS_BASE/v1/systemone ---"
  jq . <<<"$REQUEST"
  echo
  echo "--- routing rules (applied once answers return) ---"
  echo "any safety flag >= $SAFETY_FLAG    -> ESCALATE (destructive/irreversible/security)"
  echo "project == 'other'        -> ESCALATE (unknown project)"
  echo "project|worker conf < $LOW -> ESCALATE (too unsure to route)"
  echo "conf >= $HIGH             -> ROUTE"
  echo "$LOW <= conf < $HIGH     -> ROUTE (flag for review)"
  echo
  echo "To run live:  TYPESAFE_API_KEY=<key> $0 --state \"$STATE\""
  exit 0
fi

# Resolve the key: env first, then .env.
if [[ -z "$TYPESAFE_API_KEY_PRIVATE" ]]; then
  TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
fi
if [[ -z "$TYPESAFE_API_KEY_PRIVATE" ]]; then
  die "TYPESAFE_API_KEY not set (environment or \$FM_HOME/.env); preview without a key with --dry-run"
fi

command -v jq >/dev/null 2>&1 || die "jq required"
command -v curl >/dev/null 2>&1 || die "curl required"

RESP_FILE=$(mktemp) || die "mktemp failed"
trap 'rm -f "$RESP_FILE"' EXIT

HTTP=$(printf '%s' "$REQUEST" | curl -sS --max-time "$TS_TIMEOUT" -o "$RESP_FILE" -w '%{http_code}' \
  -X POST "$TS_BASE/v1/systemone" -H 'Content-Type: application/json' \
  -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") \
  --data-binary @- 2>/dev/null) || HTTP=000
[[ "$HTTP" == "200" ]] || die "API call failed (http $HTTP)"

jq -e '
  (.answers.project.choice | type) == "string" and
  (.answers.project.confidence | type) == "number" and
  .answers.project.confidence >= 0 and .answers.project.confidence <= 1 and
  (.answers.secondmate_scope.choice | type) == "string" and
  (.answers.secondmate_scope.confidence | type) == "number" and
  .answers.secondmate_scope.confidence >= 0 and .answers.secondmate_scope.confidence <= 1 and
  (.answers.safety_destructive.noul | type) == "number" and
  .answers.safety_destructive.noul >= 0 and .answers.safety_destructive.noul <= 1 and
  (.answers.safety_irreversible.noul | type) == "number" and
  .answers.safety_irreversible.noul >= 0 and .answers.safety_irreversible.noul <= 1 and
  (.answers.safety_security.noul | type) == "number" and
  .answers.safety_security.noul >= 0 and .answers.safety_security.noul <= 1
' "$RESP_FILE" >/dev/null 2>&1 || die "response is not a well-formed routing answer"

printf 'model: %s\n' "$(jq -r '.model // "unknown"' "$RESP_FILE")"
rc=0
render_decision "$RESP_FILE" || rc=$?
exit "$rc"
