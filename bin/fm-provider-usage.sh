#!/usr/bin/env bash
# fm-provider-usage.sh - provider advisory usage snapshots and ready receipts.
#
# No supported machine-readable consumer-quota API exists across Claude, Codex,
# or Ollama that firstmate can treat as authoritative. This script therefore
# records only two kinds of durable evidence:
#   - advisory snapshots from quota-axi or external UI readings (freshness evidence
#     only, never a quota-confirmed ready verdict);
#   - ready receipts produced by a successful non-token native operation probe.
# Provider-error holds remain the only authoritative exhaustion signal.
#
# Usage:
#   fm-provider-usage.sh refresh [--providers <quota-axi list>]
#       Non-interactive refresh via `quota-axi --json --full` when installed. The
#       result is recorded as source=quota-axi-advisory; it NEVER passes
#       --allow-keychain-prompt, and it never sets status=ready. A failed,
#       stale, or missing read records NOTHING so the provider ages into unknown.
#   fm-provider-usage.sh record <provider> [--session-pct N] [--week-pct N]
#       [--model-pct <model>=<N>]... [--source <name>] [--reset <text>]
#       Record an advisory snapshot by hand or from an external source (for
#       example the captain's authenticated usage page). Absent or expired
#       advisory telemetry never blocks work - error-based supervision and holds
#       remain the backstop.
#   fm-provider-usage.sh ready <provider>
#       Run the non-token native readiness probe for <provider> and record a
#       status=ready receipt when it succeeds. This is the only way to make a
#       provider strictly ready without a successful task already on it.
#   fm-provider-usage.sh status [<provider>] [--model <model>]
#       Print each snapshot's age, source, advisory values, readiness state, and
#       advisory pressure verdict.
#
# Snapshot format (state/.provider-usage-<provider>): recorded_at=<epoch>,
# source=<name>, status=<ready|advisory>, plus optional session_pct=<n>,
# week_pct=<n>, reset=<text>, and repeated model_pct=<model>=<n> lines. Freshness
# window and thresholds are owned by bin/fm-failover-lib.sh
# (FM_PROVIDER_USAGE_MAX_AGE_SECS 1800).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-failover-lib.sh
. "$SCRIPT_DIR/fm-failover-lib.sh"

usage() { awk 'NR == 1 {next} !/^#/ {exit} {sub(/^# ?/, ""); print}' "$0"; }

write_snapshot() {  # <provider> <source> <status> <session> <week> <reset> <model-pct-lines>
  local provider=$1 source=$2 status=$3 session=$4 week=$5 reset=$6 model_lines=$7 tmp path max_age
  fm_failover_provider_name_valid "$provider" || { echo "error: invalid provider name '$provider'" >&2; return 1; }
  mkdir -p "$STATE"
  path=$(fm_failover_usage_path "$STATE" "$provider")
  tmp=$(mktemp "$STATE/.provider-usage-tmp.XXXXXX") || return 1
  max_age=${FM_PROVIDER_USAGE_MAX_AGE_SECS:-1800}
  {
    printf 'recorded_at=%s\n' "$(date +%s)"
    printf 'source=%s\n' "${source:-manual}"
    printf 'status=%s\n' "${status:-advisory}"
    printf 'max_age_secs=%s\n' "$max_age"
    [ -z "$session" ] || printf 'session_pct=%s\n' "$session"
    [ -z "$week" ] || printf 'week_pct=%s\n' "$week"
    [ -z "$reset" ] || printf 'reset=%s\n' "$reset"
    [ -z "$model_lines" ] || printf '%s\n' "$model_lines"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$path" || { rm -f "$tmp"; return 1; }
  echo "recorded: provider $provider source=${source:-manual} status=${status:-advisory} session=${session:-unknown}% week=${week:-unknown}%"
}

CMD=${1:-}
case "$CMD" in
  -h|--help|'') usage; [ -n "$CMD" ] && exit 0 || exit 2 ;;
esac
shift

case "$CMD" in
  refresh)
    PROVIDERS=claude,codex
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --providers) shift; PROVIDERS=${1:-} ;;
        *) echo "error: unknown argument $1" >&2; exit 2 ;;
      esac
      shift || true
    done
    command -v quota-axi >/dev/null 2>&1 || { echo "error: quota-axi not installed" >&2; exit 1; }
    command -v jq >/dev/null 2>&1 || { echo "error: jq is required for the machine-readable refresh" >&2; exit 1; }
    REFRESH_TIMEOUT=${FM_PROVIDER_USAGE_REFRESH_TIMEOUT:-60}
    case "$REFRESH_TIMEOUT" in ''|*[!0-9]*) REFRESH_TIMEOUT=60 ;; esac
    if command -v timeout >/dev/null 2>&1; then
      OUT=$(timeout "$REFRESH_TIMEOUT" quota-axi --provider "$PROVIDERS" --json --full 2>/dev/null) || OUT=
    elif command -v gtimeout >/dev/null 2>&1; then
      OUT=$(gtimeout "$REFRESH_TIMEOUT" quota-axi --provider "$PROVIDERS" --json --full 2>/dev/null) || OUT=
    else
      OUT=$(quota-axi --provider "$PROVIDERS" --json --full 2>/dev/null) || OUT=
    fi
    if [ -z "$OUT" ]; then
      echo "refresh: quota-axi returned nothing; no snapshot recorded (existing telemetry ages into unknown; holds unaffected)"
      exit 0
    fi
    recorded_any=0
    while IFS=$(printf '\t') read -r qa_provider qa_stale qa_session qa_week qa_models; do
      [ -n "$qa_provider" ] || continue
      case "$qa_provider" in
        claude) provider=anthropic ;;
        codex) provider=openai ;;
        grok) provider=xai ;;
        *) provider=$qa_provider ;;
      esac
      if [ "$qa_stale" = true ]; then
        echo "refresh: $qa_provider telemetry marked stale by quota-axi; nothing recorded for $provider"
        continue
      fi
      model_lines=
      if [ -n "$qa_models" ]; then
        model_lines=$(printf '%s\n' "$qa_models" | tr ';' '\n' | sed -n 's/^\(..*\)/model_pct=\1/p')
      fi
      write_snapshot "$provider" quota-axi-advisory advisory "${qa_session:-}" "${qa_week:-}" "" "$model_lines" || continue
      recorded_any=1
    done <<EOF
$(printf '%s' "$OUT" | jq -r '
  .providers[]? |
  [
    .provider,
    (.state.stale // false | tostring),
    ((.windows[]? | select(.kind == "session") | .percentUsed) // "" | tostring),
    ((.windows[]? | select(.kind == "weekly") | .percentUsed) // "" | tostring),
    ([.windows[]? | select(.kind == "model") | "\(.id | sub("^model:"; ""))=\(.percentUsed)"] | join(";"))
  ] | @tsv' 2>/dev/null)
EOF
    [ "$recorded_any" = 1 ] || echo "refresh: no fresh provider telemetry recorded"
    exit 0
    ;;
  record)
    PROVIDER=${1:-}
    shift || true
    SESSION=
    WEEK=
    SOURCE=manual
    STATUS=advisory
    RESET=
    MODEL_LINES=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --session-pct) shift; SESSION=${1:-} ;;
        --week-pct) shift; WEEK=${1:-} ;;
        --source) shift; SOURCE=${1:-manual} ;;
        --status) shift; STATUS=${1:-advisory} ;;
        --reset) shift; RESET=${1:-} ;;
        --model-pct)
          shift
          case "${1:-}" in
            *=*) MODEL_LINES="${MODEL_LINES:+$MODEL_LINES
}model_pct=${1}" ;;
            *) echo "error: --model-pct expects <model>=<percent>" >&2; exit 2 ;;
          esac
          ;;
        *) echo "error: unknown argument $1" >&2; exit 2 ;;
      esac
      shift || true
    done
    case "$SESSION" in *[!0-9]*) echo "error: --session-pct must be a whole percentage" >&2; exit 2 ;; esac
    case "$WEEK" in *[!0-9]*) echo "error: --week-pct must be a whole percentage" >&2; exit 2 ;; esac
    write_snapshot "$PROVIDER" "$SOURCE" "$STATUS" "$SESSION" "$WEEK" "$RESET" "$MODEL_LINES" || exit 1
    exit 0
    ;;
  ready)
    PROVIDER=${1:-}
    [ -n "$PROVIDER" ] || { echo "error: ready requires a provider name" >&2; exit 2; }
    fm_failover_provider_name_valid "$PROVIDER" || { echo "error: invalid provider name '$PROVIDER'" >&2; exit 2; }
    code=0
    OUT=$(fm_failover_provider_ready_probe "$PROVIDER") || code=$?
    VERDICT=$(fm_failover_probe_classify "$code" "$OUT")
    if [ "$VERDICT" = available ]; then
      write_snapshot "$PROVIDER" "ready-probe" ready "" "" "" "" || exit 1
      echo "ready: provider $PROVIDER (non-token native probe succeeded)"
      exit 0
    fi
    echo "error: provider $PROVIDER ready probe failed (exit $code, verdict $VERDICT: $(printf '%s' "$OUT" | head -1 | cut -c1-200))" >&2
    exit 1
    ;;
  status)
    ONLY=
    MODEL=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --model) shift; MODEL=${1:-} ;;
        --*) echo "error: unknown argument $1" >&2; exit 2 ;;
        *) ONLY=$1 ;;
      esac
      shift || true
    done
    found=0
    for usage_file in "$STATE"/.provider-usage-*; do
      [ -e "$usage_file" ] || continue
      provider=${usage_file##*/.provider-usage-}
      [ -z "$ONLY" ] || [ "$provider" = "$ONLY" ] || continue
      found=1
      recorded=$(sed -n 's/^recorded_at=//p' "$usage_file" | head -1)
      age=unknown
      case "$recorded" in *[!0-9]*|'') : ;; *) age=$(( $(date +%s) - recorded )) ;; esac
      printf '%s age=%ss source=%s status=%s session=%s%% week=%s%% readiness: %s pressure: %s\n' \
        "$provider" "$age" \
        "$(sed -n 's/^source=//p' "$usage_file" | head -1)" \
        "$(sed -n 's/^status=//p' "$usage_file" | head -1)" \
        "$(sed -n 's/^session_pct=//p' "$usage_file" | head -1)" \
        "$(sed -n 's/^week_pct=//p' "$usage_file" | head -1)" \
        "$(fm_failover_provider_readiness "$STATE" "$provider")" \
        "$(fm_failover_provider_pressure "$STATE" "$provider" "$MODEL")"
    done
    if [ "$found" = 0 ]; then
      if [ -n "$ONLY" ]; then
        printf '%s readiness: %s pressure: %s\n' "$ONLY" "$(fm_failover_provider_readiness "$STATE" "$ONLY" "$MODEL")" "$(fm_failover_provider_pressure "$STATE" "$ONLY" "$MODEL")"
      else
        echo "no provider usage snapshots recorded"
      fi
    fi
    exit 0
    ;;
  *)
    echo "error: unknown command '$CMD'" >&2
    usage >&2
    exit 2
    ;;
esac
