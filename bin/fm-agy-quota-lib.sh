#!/usr/bin/env bash
# fm-agy-quota-lib.sh - Quota memory observation and read helpers.
# Usage: . bin/fm-agy-quota-lib.sh

# fm_agy_parse_reset_time: converts '4h 24m', '1d 2h', etc to seconds.
fm_agy_parse_reset_time() {
  local ts="$1"
  local total=0
  local d=0 h=0 m=0 s=0

  case "$ts" in
    *d*) d="${ts%%d*}"; d="${d##* }"; total=$((total + d * 86400)) ;;
  esac
  case "$ts" in
    *h*) h="${ts%%h*}"; h="${h##* }"; total=$((total + h * 3600)) ;;
  esac
  case "$ts" in
    *m*) m="${ts%%m*}"; m="${m##* }"; total=$((total + m * 60)) ;;
  esac
  case "$ts" in
    *s*) s="${ts%%s*}"; s="${s##* }"; total=$((total + s)) ;;
  esac
  echo "$total"
}

# fm_agy_quota_observe: extract and record quota from agy pane footer.
# Format: Gemini 3.1 Pro (High) | ctx: 10.5% | quota: 94.7% (4h 24m)
fm_agy_quota_observe() {  # <text> <state_dir>
  local text="$1" state_dir="$2"
  case "$text" in
    *" | quota: "*) ;;
    *) return 0 ;;
  esac
  
  local pre="${text%% | quota: *}"
  local nl='
'
  local line_start="${pre##*"$nl"}"
  local model="${line_start%% | ctx: *}"
  if [ "$model" = "$line_start" ]; then
    return 0
  fi
  
  local post="${text#* | quota: }"
  local line_end="${post%%"$nl"*}"
  local quota="${line_end%% (*}"
  local reset_time="${line_end#*(}"
  reset_time="${reset_time%)}"
  
  if [ -z "$model" ] || [ -z "$quota" ] || [ -z "$reset_time" ]; then
    return 0
  fi

  local safe_model
  if command -v md5 >/dev/null 2>&1; then
    safe_model=$(printf '%s' "$model" | md5 -q)
  else
    safe_model=$(printf '%s' "$model" | md5sum | cut -d' ' -f1)
  fi
  
  local now
  now=$(date +%s)
  
  # Only write if it actually changed, but doing this requires reading.
  # Since this is already conditionally executed, writing directly is fine.
  printf '%s|%s|%s|%s\n' "$model" "$quota" "$reset_time" "$now" > "$state_dir/.agy-quota-$safe_model"
}

# fm_agy_quota_read: returns the last known value for a model together with its age.
fm_agy_quota_read() {  # <model> <state_dir> [<now>]
  local model="$1" state_dir="$2" now_override="${3:-}"
  local safe_model
  if command -v md5 >/dev/null 2>&1; then
    safe_model=$(printf '%s' "$model" | md5 -q)
  else
    safe_model=$(printf '%s' "$model" | md5sum | cut -d' ' -f1)
  fi
  
  local file="$state_dir/.agy-quota-$safe_model"
  if [ ! -f "$file" ]; then
    echo "unknown"
    return 0
  fi
  
  local line
  line=$(cat "$file" 2>/dev/null || true)
  if [ -z "$line" ]; then
    echo "unknown"
    return 0
  fi
  
  local file_model="${line%%|*}"
  local rest="${line#*|}"
  local quota="${rest%%|*}"
  rest="${rest#*|}"
  local reset_time_str="${rest%%|*}"
  local obs_ts="${rest#*|}"
  
  if [ "$file_model" != "$model" ] || [ -z "$quota" ] || [ -z "$reset_time_str" ] || [ -z "$obs_ts" ]; then
    echo "unknown"
    return 0
  fi
  
  local now
  if [ -n "$now_override" ]; then
    now="$now_override"
  else
    now=$(date +%s)
  fi
  
  local age=$((now - obs_ts))
  if [ "$age" -lt 0 ]; then
    age=0
  fi
  
  local reset_seconds
  reset_seconds=$(fm_agy_parse_reset_time "$reset_time_str")
  if [ "$reset_seconds" -eq 0 ]; then
    echo "unknown"
    return 0
  fi
  
  if [ "$age" -ge "$reset_seconds" ]; then
    echo "unknown"
    return 0
  fi
  
  quota="${quota%%%*}"
  echo "$quota $age"
}
