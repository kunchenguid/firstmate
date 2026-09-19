#!/usr/bin/env bash
# fm-jev-retrieval-miss.sh - shadow classifier for a wiki-engine retrieval miss.
#
# Usage:
#   fm-jev-retrieval-miss.sh --query <text> --envelope-file <path> \
#     [--embeddings-enabled 0|1] [--openviking-enabled 0|1]
#
# Firstmate's wiki-ask path runs this only after wiki-tool ask reports
# no-match or missing-source. It asks Jev one Choice over
# {true_miss, vocab_divergence, consent_blocked, need_human} using an
# explicit allowlist of metadata fields: the query string, retrieval
# status, mode, pages searched, and whether embeddings and OpenViking
# were enabled. Nothing else is sent.
#
# Hard guard: if the envelope carries page content, an excerpt, a
# citation body, or a conflict line, the helper refuses, logs the
# refusal, and does not call Jev. Query text may leave the machine;
# page bodies, excerpts, and conflict lines never may
# (docs/configuration.md "Wiki engine ask").
#
# Confidence below the library floor (default 0.7), missing confidence,
# or invalid confidence rewrites vocab_divergence and consent_blocked to
# need_human (true_miss stays true_miss). Operator safety invariants are
# owned by docs/configuration.md "Wiki engine ask".
#
# Output (stdout):
#   jev-retrieval-miss:
#     verdict: true_miss | vocab_divergence | consent_blocked | need_human | skipped | refused
#     confidence: <n or empty>
#     sent: yes | no
#     shadow: yes
# sent records an HTTP attempt, not successful delivery or classification;
# failed HTTP responses, invalid JSON, and transport errors still say yes.
# Exit 0 except usage/config (exit 2). Evaluation failure, a missing key,
# and the excerpt guard still exit 0 so a miss is never blocked.
#
# Log: one JSONL object appended to $FM_HOME/state/jev-retrieval-miss.jsonl.
# Records the query and allowlisted retrieval metadata, verdict, confidence,
# sent/refused flags, route, HTTP code (000 for a transport error), latency_ms,
# decide_code, and shadow=true, retry=false, config_write=false.
# Missing keys skip classification without sending, but still log the query.
# Secrets follow fm_jev_log_call redaction. This script does not roll its
# own HTTP; docs/configuration.md "Jev caller library" owns the client.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"

usage() {
  printf 'Usage: fm-jev-retrieval-miss.sh --query <text> --envelope-file <path> [--embeddings-enabled 0|1] [--openviking-enabled 0|1]\n' >&2
}

die() {
  printf 'jev-retrieval-miss: %s\n' "$1" >&2
  exit 2
}

query=
envelope_file=
embeddings_enabled=0
openviking_enabled=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --query)
      [ $# -ge 2 ] || die "missing value for $1"
      query=$2
      shift 2
      ;;
    --envelope-file)
      [ $# -ge 2 ] || die "missing value for $1"
      envelope_file=$2
      shift 2
      ;;
    --embeddings-enabled)
      [ $# -ge 2 ] || die "missing value for $1"
      embeddings_enabled=$2
      shift 2
      ;;
    --openviking-enabled)
      [ $# -ge 2 ] || die "missing value for $1"
      openviking_enabled=$2
      shift 2
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      die "unexpected argument: $1"
      ;;
  esac
done

[ -n "$query" ] || { usage; die "--query is required"; }
case "$embeddings_enabled" in 0|1) ;; *) die "--embeddings-enabled must be 0 or 1" ;; esac
case "$openviking_enabled" in 0|1) ;; *) die "--openviking-enabled must be 0 or 1" ;; esac

[ -n "$envelope_file" ] || { usage; die "--envelope-file is required"; }
[ -f "$envelope_file" ] && [ -r "$envelope_file" ] && [ ! -L "$envelope_file" ] \
  || die "envelope file is unreadable"
envelope=$(cat "$envelope_file") || die "could not read envelope file"
[ -n "$envelope" ] || die "envelope must be a JSON object"

command -v jq >/dev/null 2>&1 || die "jq is required"

if ! printf '%s' "$envelope" | jq -e 'type == "object"' >/dev/null 2>&1; then
  die "envelope must be a JSON object"
fi

# Refuse any payload that still carries page content rather than stripping it.
forbidden=0
if printf '%s' "$envelope" | jq -e '
  def forbidden_key:
    ascii_downcase
    | test("^(excerpt|excerpts|contradiction|contradictions|context_cautions|conflict|conflicts|conflict_line|conflict_lines|body|bodies|content|page_body|source_excerpt|citations)$");
  def nonempty:
    if type == "string" then length > 0
    elif type == "array" then length > 0
    elif type == "object" then length > 0
    else false end;
  [paths as $p
    | select(($p | length) > 0)
    | {key: ($p[-1] | tostring), value: getpath($p)}
    | select((.key | forbidden_key) and (.value | nonempty))
  ] | length > 0
' >/dev/null 2>&1; then
  forbidden=1
fi

retrieval_status=$(printf '%s' "$envelope" | jq -r '.retrieval.status // .status // empty')
mode=$(printf '%s' "$envelope" | jq -r '.retrieval.mode // empty')
pages_searched=$(printf '%s' "$envelope" | jq -r '.retrieval.pages_searched // 0')
case "$pages_searched" in ''|*[!0-9]*) pages_searched=0 ;; esac

verdict=skipped
confidence=
sent=no
decide_code=0
response=

emit_log() {
  local log_path log_payload
  log_path="$FM_HOME/state/jev-retrieval-miss.jsonl"
  mkdir -p "$FM_HOME/state"
  log_payload=$(jq -nc \
    --arg query "$query" \
    --arg retrieval_status "$retrieval_status" \
    --arg mode "$mode" \
    --argjson pages_searched "$pages_searched" \
    --argjson embeddings_enabled "$embeddings_enabled" \
    --argjson openviking_enabled "$openviking_enabled" \
    --arg verdict "$verdict" \
    --arg confidence "$confidence" \
    --arg sent "$sent" \
    --arg route "${FM_JEV_LAST_ROUTE:-}" \
    --arg http "${FM_JEV_LAST_HTTP:-}" \
    --arg latency "${FM_JEV_LAST_LATENCY_MS:-}" \
    --argjson decide_code "$decide_code" \
    '{
      purpose: "retrieval-miss",
      query: $query,
      retrieval_status: $retrieval_status,
      mode: $mode,
      pages_searched: $pages_searched,
      embeddings_enabled: ($embeddings_enabled == 1),
      openviking_enabled: ($openviking_enabled == 1),
      verdict: $verdict,
      confidence: (try ($confidence | tonumber) catch null),
      sent: ($sent == "yes"),
      refused: ($verdict == "refused"),
      route: $route,
      http: $http,
      latency_ms: (try ($latency | tonumber) catch null),
      decide_code: $decide_code,
      shadow: true,
      retry: false,
      config_write: false
    }') || die "failed to render log payload"
  fm_jev_log_call "$log_payload" "$log_path"
}

print_record() {
  printf 'jev-retrieval-miss:\n'
  printf '  verdict: %s\n' "$verdict"
  printf '  confidence: %s\n' "$confidence"
  printf '  sent: %s\n' "$sent"
  printf '  shadow: yes\n'
}

if [ "$forbidden" -eq 1 ]; then
  verdict=refused
  emit_log
  print_record
  exit 0
fi

state=$(printf '%s\n' \
  "query: $query" \
  "retrieval_status: ${retrieval_status:-(none)}" \
  "mode: ${mode:-(none)}" \
  "pages_searched: $pages_searched" \
  "embeddings_enabled: $embeddings_enabled" \
  "openviking_enabled: $openviking_enabled")
compacted=
if compacted=$(fm_jev_compact_state "$state"); then
  :
else
  die "allowlisted state exceeded the Jev state budget"
fi

questions=$(jq -nc '{
  miss: {
    type: "choice",
    instructions: "Why did this retrieval miss? Use only the query and retrieval metadata. Never recommend a retry, enabling embeddings, or a config write. Prefer need_human when the metadata cannot decide.",
    criteria: {
      true_miss: "The consented corpus should not contain an answer to this query.",
      vocab_divergence: "The corpus likely has the fact under different wording, the eval_semantic shape.",
      consent_blocked: "Dense embeddings or OpenViking look relevant but are not enabled.",
      need_human: "A human must inspect; the metadata cannot decide."
    }
  }
}') || die "jq is required"

mkdir -p "$FM_HOME/state" || die "could not create state directory"
response_file=$(mktemp "$FM_HOME/state/.jev-retrieval-response.XXXXXX") || die "could not create response file"
trap 'rm -f -- "$response_file"' EXIT
fm_jev_decide "$compacted" "$questions" > "$response_file" || decide_code=$?
response=$(cat "$response_file")
[ -z "${FM_JEV_LAST_HTTP:-}" ] || sent=yes

if [ "$decide_code" -eq 0 ] && [ -n "$response" ]; then
  choice=$(printf '%s' "$response" | jq -r '.answers.miss.choice // empty')
  confidence=$(printf '%s' "$response" | jq -r '.answers.miss.confidence // empty')
  case "$choice" in
    true_miss|vocab_divergence|consent_blocked|need_human)
      verdict=$choice
      ;;
    *)
      verdict=skipped
      confidence=
      ;;
  esac
  if [ "$verdict" != skipped ] \
    && ! fm_jev_choice_confidence_ok "$confidence"; then
    case "$verdict" in
      true_miss) ;;
      *) verdict=need_human ;;
    esac
  fi
fi

emit_log
print_record
exit 0
