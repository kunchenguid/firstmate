#!/usr/bin/env bash
# Primary session turn-end quota instrumentation writer.
# Appends exactly one tab-separated record per primary-session turn end to
# state/quota-turns.log.
#
# PROXY DISCLAIMER: The state fingerprint recorded here is a cheap, deterministic
# proxy metric of fleet state. It CANNOT prove a turn was useless - a turn that
# answered the captain changes nothing on disk. It must be described and treated
# as a proxy everywhere.
#
# Error contract: this writer must never block, delay, or fail a turn. All errors
# are caught, written to state/.turn-quota-error.log, and swallowed with exit 0.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG_FILE="${FM_QUOTA_LOG_OVERRIDE:-$STATE/quota-turns.log}"
ERR_LOG="$STATE/.turn-quota-error.log"
CACHE_FILE="$STATE/.turn-quota-cache.json"
AGY_CACHE_FILE="$STATE/.turn-quota-agy-cache.json"
CACHE_TTL_SECONDS=15
PROBE_TIMEOUT_SECONDS=3
MAX_LOG_LINES=10000

log_err() {
  printf '%s [error] %s\n' "$(date +%s)" "$1" >> "$ERR_LOG" 2>/dev/null || true
}

# Portable SHA-256 over stdin. Returns non-zero (and prints nothing) when no
# hasher exists, so callers can record an honest absent marker.
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

stat_field() {
  stat -c "$1" "$3" 2>/dev/null || stat -f "$2" "$3" 2>/dev/null || echo 0
}

run_timeout() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$secs" "$@"
  else
    return 1
  fi
}

# Refresh <cache> from a bounded probe unless it is younger than the TTL, so a
# burst of turn ends costs at most one subprocess round trip.
probe_cached() {
  local cache=$1
  shift
  local mtime now
  if [ -f "$cache" ]; then
    mtime=$(stat_field %Y %m "$cache")
    now=$(date +%s)
    if [ $((now - mtime)) -lt "$CACHE_TTL_SECONDS" ]; then
      return 0
    fi
  fi
  if run_timeout "$PROBE_TIMEOUT_SECONDS" "$@" > "$cache.tmp" 2>/dev/null; then
    mv "$cache.tmp" "$cache" 2>/dev/null || true
  fi
  rm -f "$cache.tmp" 2>/dev/null || true
  return 0
}

record_turn_quota() {
  local wake_kind fp fp_changed last_fp
  local claude_5h="absent" claude_7d="absent" claude_gen_at="absent"
  local gemini_used="absent" gemini_gen_at="absent"
  local parsed=""
  local epoch record line_count parsed_gemini
  local c_5h c_7d c_gen g_used g_gen

  # Verify primary scope
  if [ -f "$SCRIPT_DIR/fm-primary-scope-lib.sh" ]; then
    # shellcheck source=bin/fm-primary-scope-lib.sh
    . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
    fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 0
  fi

  # Determine wake kind from durable state
  wake_kind="captain"
  if [ -f "$STATE/.turn-wake-kind" ]; then
    raw_kind=$(cat "$STATE/.turn-wake-kind" 2>/dev/null || true)
    case "$raw_kind" in
      signal|stale|check|heartbeat|captain) wake_kind="$raw_kind" ;;
      *) wake_kind="captain" ;;
    esac
  fi

  # Compute proxy fingerprint of fleet state
  fp=$(
    meta_stat=$(
      for meta in "$STATE"/*.meta; do
        [ -f "$meta" ] || continue
        printf '%s %s %s\n' "${meta##*/}" \
          "$(stat_field %s %z "$meta")" "$(stat_field %Y %m "$meta")"
      done
    )
    backlog="$FM_HOME/data/backlog.md"
    if [ -f "$backlog" ]; then
      backlog_hash=$(sha256_stdin < "$backlog" 2>/dev/null || true)
      [ -n "$backlog_hash" ] || backlog_hash="backlog-unhashable"
    else
      backlog_hash="no-backlog"
    fi
    head_rev=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null || echo "no-head")
    printf '%s\n%s\n%s\n' "$meta_stat" "$backlog_hash" "$head_rev" | sha256_stdin | cut -c1-16
  )
  # An unhashable state is absent, never a constant: a fabricated fingerprint
  # would compare equal on every later turn and manufacture a 100% no-op ratio.
  [ -n "$fp" ] || fp="absent"

  # Check if fingerprint changed from last record
  if [ "$fp" = "absent" ]; then
    fp_changed="absent"
  else
    fp_changed=1
    if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
      last_fp=$(tail -n 1 "$LOG_FILE" 2>/dev/null | awk -F '\t' '{print $3}' || true)
      if [ "$last_fp" = "$fp" ]; then
        fp_changed=0
      fi
    fi
  fi

  # Query quota-axi if available
  if command -v quota-axi >/dev/null 2>&1; then
    probe_cached "$CACHE_FILE" quota-axi --json
    if [ -f "$CACHE_FILE" ] && [ -s "$CACHE_FILE" ]; then
      parsed=$(jq -r '
        .generatedAt as $gen |
        (.providers[]? | select(.provider=="claude")) as $c |
        (($c.windows[]? | select(.id=="five_hour") | .percentUsed) // "absent") as $h5 |
        (($c.windows[]? | select(.id=="seven_day") | .percentUsed) // "absent") as $d7 |
        "\($h5)\t\($d7)\t\($gen // "absent")"
      ' "$CACHE_FILE" 2>/dev/null || true)
      if [ -n "$parsed" ]; then
        IFS=$'\t' read -r c_5h c_7d c_gen <<< "$parsed"
        [ -n "$c_5h" ] && claude_5h="$c_5h"
        [ -n "$c_7d" ] && claude_7d="$c_7d"
        [ -n "$c_gen" ] && claude_gen_at="$c_gen"
      fi
    fi
  fi

  # Query antigravity-usage if available (explicit absent marker if absent)
  if command -v antigravity-usage >/dev/null 2>&1; then
    probe_cached "$AGY_CACHE_FILE" antigravity-usage --json
    if [ -f "$AGY_CACHE_FILE" ] && [ -s "$AGY_CACHE_FILE" ]; then
      # Dispatch-eligible gemini models only (autocomplete-only pools are never
      # spent by the fleet), and the scarcest of them, so the recorded delta can
      # never track a different budget just because the tool reordered .models.
      parsed_gemini=$(jq -r '
        .timestamp as $ts |
        ([.models[]?
          | select((.modelId | contains("gemini")) and (.isAutocompleteOnly != true))
          | .remainingPercentage] | min) as $rem |
        if $rem == null then "absent\tabsent"
        else
          (if $rem <= 1.0 then (1.0 - $rem) * 100.0 else (100.0 - $rem) end) as $used |
          "\($used)\t\($ts // "absent")"
        end
      ' "$AGY_CACHE_FILE" 2>/dev/null || true)
      if [ -n "$parsed_gemini" ]; then
        IFS=$'\t' read -r g_used g_gen <<< "$parsed_gemini"
        [ -n "$g_used" ] && gemini_used="$g_used"
        [ -n "$g_gen" ] && gemini_gen_at="$g_gen"
      fi
    fi
  fi

  epoch=$(date +%s)
  record=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$epoch" "$wake_kind" "$fp" "$fp_changed" \
    "$claude_5h" "$claude_7d" "$claude_gen_at" \
    "$gemini_used" "$gemini_gen_at")

  mkdir -p "$STATE" 2>/dev/null || true
  printf '%s\n' "$record" >> "$LOG_FILE" 2>/dev/null || log_err "failed writing to log file"

  # Bound log size
  if [ -f "$LOG_FILE" ]; then
    line_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$line_count" -gt "$MAX_LOG_LINES" ]; then
      tail -n 5000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || true
    fi
  fi

  # Reset wake kind marker to captain after recording
  printf 'captain\n' > "$STATE/.turn-wake-kind" 2>/dev/null || true
}

(record_turn_quota) || exit 0
