# shellcheck shell=bash
# Watch-arm telemetry record format; operator behavior: docs/watcher-continuity.md.
# Source after fm-wake-lib.sh so STATE is the arm's resolved state directory.
# fm_telemetry_emit <cycle-reason> writes JSONL with schema="fm-telemetry.v1",
# ts=UTC emission time, event="watch_cycle", source="watch-arm", and signal
# containing the first 64 characters of the lifecycle reason (not an OS signal).
# Callers must tolerate missing records and ignore emitter failure: this stream
# is diagnostic evidence, never wake-delivery or acknowledgement authority.

fm_telemetry_emit() (
  [ "${FM_TELEMETRY:-1}" != 0 ] || exit 0
  umask 077
  local file="$STATE/telemetry.jsonl" lock segment i size json
  mkdir -p "$STATE" || exit 0
  lock="$file.lock"
  i=0
  while ! fm_lock_try_acquire "$lock"; do
    i=$((i + 1)); [ "$i" -lt 20 ] || exit 0
    sleep 0.01
  done
  trap 'fm_lock_release "$lock"' EXIT
  for segment in "$file" "$file.1" "$file.2" "$file.3"; do
    [ ! -L "$segment" ] || exit 0
    if [ -e "$segment" ]; then
      [ -f "$segment" ] && chmod 600 "$segment" || exit 0
    fi
  done
  json=$(jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg signal "${1:0:64}" \
    '{schema:"fm-telemetry.v1",ts:$ts,event:"watch_cycle",signal:$signal,source:"watch-arm"}') || exit 0
  size=0
  if [ -f "$file" ]; then
    size=$(wc -c < "$file") || exit 0
  fi
  if [ "$((size + ${#json} + 1))" -gt 1048576 ]; then
    for i in 2 1; do
      if [ -f "$file.$i" ]; then
        mv -f "$file.$i" "$file.$((i + 1))" || exit 0
      fi
    done
    mv -f "$file" "$file.1" || exit 0
  fi
  printf '%s\n' "$json" >> "$file" || true
) >/dev/null 2>&1
