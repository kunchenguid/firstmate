#!/usr/bin/env bash
# bin/fm-tool-spool-lib.sh — Tool Output Spooling & Schema Deferral Library
# Prevents context explosion by spooling large outputs (> max-lines or > max-bytes)
# to disk and returning a compact preview with line and byte counters.
set -eu

FM_SPOOL_DEFAULT_MAX_LINES=50
FM_SPOOL_DEFAULT_MAX_BYTES=16384 # 16KB

fm_tool_spool_exec() { # <state_dir> <max_lines> <max_bytes> <command...>
  local state=$1 max_lines=$2 max_bytes=$3
  shift 3
  local out_dir="$state/tool-outputs"
  mkdir -p "$out_dir" 2>/dev/null || out_dir="${TMPDIR:-/tmp}/fm-tool-outputs"
  mkdir -p "$out_dir" 2>/dev/null || true

  local tmp_raw
  tmp_raw=$(mktemp "$out_dir/raw.XXXXXX") || return 1

  local rc=0
  "$@" > "$tmp_raw" 2>&1 || rc=$?

  local total_lines total_bytes
  total_lines=$(wc -l < "$tmp_raw" | tr -d '[:space:]')
  total_bytes=$(wc -c < "$tmp_raw" | tr -d '[:space:]')

  if [ "$total_lines" -le "$max_lines" ] && [ "$total_bytes" -le "$max_bytes" ]; then
    cat "$tmp_raw"
    rm -f "$tmp_raw"
    return "$rc"
  fi

  # Spool to persistent log file
  local log_file
  log_file="$out_dir/spool-$(date +%s%N 2>/dev/null || date +%s).log"
  mv "$tmp_raw" "$log_file"

  echo "=== [Firstmate Tool Spool Guard: output truncated] ==="
  echo "Total lines: $total_lines | Total bytes: $total_bytes"
  echo "Full output saved to: $log_file"
  echo "--- Preview (first $max_lines lines) ---"
  head -n "$max_lines" "$log_file"
  echo "--- [End Preview - use Read or Grep to inspect full log at $log_file] ---"

  return "$rc"
}

fm_tool_discover() { # <tool_name>
  local tool=$1
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Tool: $tool [NOT INSTALLED]"
    return 1
  fi
  local bin_path
  bin_path=$(command -v "$tool")
  echo "Tool: $tool"
  echo "Location: $bin_path"
  echo "--- Usage & Schema Help ---"
  if "$tool" --help >/dev/null 2>&1; then
    "$tool" --help | head -n 30
  elif "$tool" -h >/dev/null 2>&1; then
    "$tool" -h | head -n 30
  elif man -w "$tool" >/dev/null 2>&1; then
    man "$tool" | head -n 30
  else
    echo "(No built-in --help found; execute on-demand)"
  fi
}
