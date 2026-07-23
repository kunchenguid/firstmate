#!/usr/bin/env bash
# Shared resource admission for crewmate launches.

fm_resource_meta_value() {
  local meta=$1 key=$2
  sed -n "s/^${key}=//p" "$meta" 2>/dev/null | tail -1
}

fm_resource_heavy_count() {
  local state=$1 exclude=${2:-} meta class kind count=0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$meta" != "$state/$exclude.meta" ] || continue
    kind=$(fm_resource_meta_value "$meta" kind)
    [ "$kind" != secondmate ] || continue
    class=$(fm_resource_meta_value "$meta" resource_class)
    [ -n "$class" ] || class=heavy
    [ "$class" != heavy ] || count=$((count + 1))
  done
  printf '%s\n' "$count"
}

fm_resource_admit() {
  local state=$1 config=$2 class=$3 exclude=${4:-} count probe
  [ "$class" = heavy ] || return 0
  count=$(fm_resource_heavy_count "$state" "$exclude")
  [ "$count" -lt 3 ] && return 0
  [ "$count" -lt 4 ] || return 75
  probe="$config/resource-admission-probe"
  [ -x "$probe" ] || return 75
  "$probe" || return 75
}

fm_resource_queue_write() {
  local state=$1 id=$2
  shift 2
  mkdir -p "$state/resource-queue"
  {
    printf 'queued_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'argv='
    printf '%q ' "$@"
    printf '\n'
  } > "$state/resource-queue/$id.queue"
}
