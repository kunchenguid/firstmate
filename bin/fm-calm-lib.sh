#!/usr/bin/env bash
# Shared home-local Calm preference reader.
#
# The effective config directory is caller-owned. After JavaScript-equivalent
# whitespace trimming, only `on` enables presentation changes; absent,
# unreadable, or any other content is off.
# Callers keep their ordinary output byte-for-byte unchanged while off.
# Claude-only callers additionally use fm_claude_calm_enabled so the shared Pi
# preference does not change another primary harness's shell presentation.

fm_calm_enabled() {  # [config-dir]
  local config value token
  config=${1:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-.}}/config}}
  value=
  local -a whitespace=(
    $'\011' $'\012' $'\013' $'\014' $'\015' $'\040'
    $'\302\240' $'\341\232\200'
    $'\342\200\200' $'\342\200\201' $'\342\200\202' $'\342\200\203'
    $'\342\200\204' $'\342\200\205' $'\342\200\206' $'\342\200\207'
    $'\342\200\210' $'\342\200\211' $'\342\200\212' $'\342\200\250'
    $'\342\200\251' $'\342\200\257' $'\342\201\237' $'\343\200\200'
    $'\357\273\277'
  )
  [ -f "$config/calm" ] || return 1
  if IFS= read -r -d '' value 2>/dev/null < "$config/calm"; then
    return 1
  fi
  while :; do
    for token in "${whitespace[@]}"; do
      if [[ $value == "$token"* ]]; then
        value=${value#"$token"}
        continue 2
      fi
    done
    break
  done
  while :; do
    for token in "${whitespace[@]}"; do
      if [[ $value == *"$token" ]]; then
        value=${value%"$token"}
        continue 2
      fi
    done
    break
  done
  [ "$value" = on ]
}

fm_claude_calm_enabled() {  # [config-dir]
  [ "${CLAUDECODE:-}" = 1 ] && fm_calm_enabled "${1:-}"
}
