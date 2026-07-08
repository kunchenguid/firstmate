#!/usr/bin/env bash
# Observe-only session metrics collection for the firstmate watchdog.
#
# fm_watchdog_collect_metrics <harness> <session_id> writes one metrics snapshot
# to $STATE/watchdog/metrics-<session_id>.json.
# The path is under state/watchdog so watchdog artifacts stay with firstmate's
# existing runtime signals without mixing into the watcher's own dotfile internals.
set -euo pipefail

FM_WATCHDOG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$FM_WATCHDOG_LIB_DIR/fm-wake-lib.sh"

FM_WATCHDOG_PARSER_VERSION=1

fm_watchdog_default_config() {
  cat <<'JSON'
{
  "poll_interval_sec": 30,
  "thresholds": {
    "compact_at_context_pct": 85,
    "successor_at_context_pct": 95,
    "embargo_at_5hr_pct": 85,
    "embargo_at_7d_pct": 85
  },
  "steer_retries": 3,
  "steer_timeout_sec": 120,
  "rotate_to": ["codex", "opencode"],
  "parser_version": 1
}
JSON
}

fm_watchdog_thresholds() {
  local config_dir=${FM_CONFIG_OVERRIDE:-$FM_HOME/config} config
  config=${FM_WATCHDOG_CONFIG:-$config_dir/watchdog.json}
  if [ -f "$config" ]; then
    jq -c . "$config"
  else
    fm_watchdog_default_config | jq -c .
  fi
}

fm_watchdog_metrics_dir() {
  printf '%s/watchdog\n' "$STATE"
}

fm_watchdog_metrics_path() {
  local session_id=$1
  printf '%s/metrics-%s.json\n' "$(fm_watchdog_metrics_dir)" "$session_id"
}

fm_watchdog_parser_mismatch() {
  printf 'WATCHDOG_PARSER_MISMATCH: %s\n' "$1" >&2
  return 3
}

fm_watchdog_latest_file() {
  local dir=$1 pattern=$2 file mtime best_file='' best_mtime=-1
  [ -d "$dir" ] || return 1
  while IFS= read -r -d '' file; do
    mtime=$(fm_path_mtime "$file") || continue
    case "$mtime" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$mtime" -gt "$best_mtime" ]; then
      best_mtime=$mtime
      best_file=$file
    fi
  done < <(find "$dir" -type f -name "$pattern" -print0 2>/dev/null)
  [ -n "$best_file" ] || return 1
  printf '%s\n' "$best_file"
}

fm_watchdog_latest_claude_checkpoint() {
  local dir=${FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR:-$HOME/.claude/token-optimizer/checkpoints}
  fm_watchdog_latest_file "$dir" '*.json'
}

fm_watchdog_latest_codex_rollout() {
  local dir=${FM_WATCHDOG_CODEX_SESSION_DIR:-$HOME/.codex/sessions}
  fm_watchdog_latest_file "$dir" 'rollout-*.jsonl'
}

fm_watchdog_write_metrics() {
  local path=$1 json=$2 tmp
  mkdir -p "$(dirname "$path")"
  tmp=$(mktemp "${path}.tmp.XXXXXX")
  printf '%s\n' "$json" > "$tmp"
  mv "$tmp" "$path"
  printf '%s\n' "$path"
}

fm_watchdog_claude_metrics_json() {
  local harness=$1 session_id=$2 checkpoint=$3 collected_at
  collected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -ce \
    --arg harness "$harness" \
    --arg collected_at "$collected_at" \
    --argjson parser_version "$FM_WATCHDOG_PARSER_VERSION" '
      def number_or_null: if type == "number" then . else null end;
      if (.version == 1)
        and (.fill_pct | type == "number")
        and (.quality | type == "object")
        and (.quality.tool_calls | type == "number")
      then
        {
          harness: $harness,
          context_pct: .fill_pct,
          five_hr_pct: null,
          seven_day_pct: null,
          tool_calls: .quality.tool_calls,
          collected_at: $collected_at,
          parser_version: $parser_version
        }
      else
        error("unsupported token-optimizer checkpoint shape")
      end
    ' "$checkpoint" 2>/dev/null || fm_watchdog_parser_mismatch "claude checkpoint format drift: $checkpoint"
}

fm_watchdog_codex_metrics_json() {
  local harness=$1 session_id=$2 rollout=$3 collected_at
  collected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -sce \
    --arg harness "$harness" \
    --arg session_id "$session_id" \
    --arg collected_at "$collected_at" \
    --argjson parser_version "$FM_WATCHDOG_PARSER_VERSION" '
      def token_events:
        map(select(.type == "event_msg" and .payload.type == "token_count"));
      def last_token_event: token_events | last;
      def pct($used; $limit):
        if ($used | type == "number") and ($limit | type == "number") and $limit > 0
        then (($used / $limit * 1000) | round / 10)
        else null
        end;
      if (last_token_event | type == "object")
        and (last_token_event.payload.info.last_token_usage.total_tokens | type == "number")
        and (last_token_event.payload.info.model_context_window | type == "number")
        and (last_token_event.payload.rate_limits.primary.used_percent | type == "number")
        and (last_token_event.payload.rate_limits.secondary.used_percent | type == "number")
      then
        last_token_event.payload as $p
        | {
            harness: $harness,
            context_pct: pct($p.info.last_token_usage.total_tokens; $p.info.model_context_window),
            five_hr_pct: $p.rate_limits.primary.used_percent,
            seven_day_pct: $p.rate_limits.secondary.used_percent,
            tool_calls: null,
            collected_at: $collected_at,
            parser_version: $parser_version
          }
      else
        error("unsupported codex rollout token-count shape")
      end
    ' "$rollout" 2>/dev/null || fm_watchdog_parser_mismatch "codex rollout format drift: $rollout"
}

fm_watchdog_unknown_metrics_json() {
  local harness=$1 collected_at
  collected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -cn \
    --arg harness "$harness" \
    --arg collected_at "$collected_at" \
    --argjson parser_version "$FM_WATCHDOG_PARSER_VERSION" \
    '{
      harness: $harness,
      context_pct: null,
      five_hr_pct: null,
      seven_day_pct: null,
      tool_calls: null,
      collected_at: $collected_at,
      parser_version: $parser_version
    }'
}

fm_watchdog_collect_metrics() {
  local harness=$1 session_id=$2 path metrics source
  path=$(fm_watchdog_metrics_path "$session_id")
  case "$harness" in
    claude)
      source=$(fm_watchdog_latest_claude_checkpoint) \
        || fm_watchdog_parser_mismatch "no claude token-optimizer checkpoint found"
      metrics=$(fm_watchdog_claude_metrics_json "$harness" "$session_id" "$source")
      ;;
    codex)
      source=$(fm_watchdog_latest_codex_rollout) \
        || fm_watchdog_parser_mismatch "no codex rollout file found"
      metrics=$(fm_watchdog_codex_metrics_json "$harness" "$session_id" "$source")
      ;;
    *)
      metrics=$(fm_watchdog_unknown_metrics_json "$harness")
      ;;
  esac
  fm_watchdog_write_metrics "$path" "$metrics"
}
