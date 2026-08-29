#!/usr/bin/env bash
# fm-delivery-continuation-lib.sh - validation-continuation message contract.

FM_DELIVERY_CONTINUATION_SCHEMA='fm-delivery-continuation.v1'

fm_delivery_continuation_id() {  # <task> <head> <spawn-gen>
  printf '%s' "$1:$2:$3:committed-to-validation" | shasum -a 256 | cut -c1-16
}

fm_delivery_continuation_message() {  # <task> <head> <spawn-gen> <delivery-id>
  printf 'FIRSTMATE_DELIVERY schema=%s task=%s spawn_gen=%s head=%s delivery=%s\n' \
    "$FM_DELIVERY_CONTINUATION_SCHEMA" "$1" "$3" "$2" "$4"
  printf 'Begin the already-authorized /no-mistakes validation flow now. Do not merge.'
}

fm_delivery_continuation_parse_record() {  # <record> <task> <spawn-gen>
  local rec=$1 task=$2 spawn_gen=$3 body first rest schema_field task_field spawn_field head_field delivery_field extra
  body=$(fm_task_inbox_body "$rec" 2>/dev/null) || return 1
  case "$body" in
    *$'\n'*) first=${body%%$'\n'*}; rest=${body#*$'\n'} ;;
    *) return 1 ;;
  esac
  [ "$rest" = 'Begin the already-authorized /no-mistakes validation flow now. Do not merge.' ] || return 1
  IFS=' ' read -r first schema_field task_field spawn_field head_field delivery_field extra <<EOF
$first
EOF
  [ "$first" = FIRSTMATE_DELIVERY ] || return 1
  [ "$schema_field" = "schema=$FM_DELIVERY_CONTINUATION_SCHEMA" ] || return 1
  [ "$task_field" = "task=$task" ] || return 1
  [ "$spawn_field" = "spawn_gen=$spawn_gen" ] || return 1
  [ -z "$extra" ] || return 1
  case "$head_field" in head=*) head_field=${head_field#head=} ;; *) return 1 ;; esac
  case "$delivery_field" in delivery=*) delivery_field=${delivery_field#delivery=} ;; *) return 1 ;; esac
  case "$head_field" in ''|*[!0-9A-Fa-f]*) return 1 ;; esac
  case "${#head_field}" in 40|64) ;; *) return 1 ;; esac
  case "$delivery_field" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) return 1 ;;
  esac
  [ "$delivery_field" = "$(fm_delivery_continuation_id "$task" "$head_field" "$spawn_gen")" ] || return 1
  printf '%s\t%s\n' "$head_field" "$delivery_field"
}

fm_delivery_continuation_state() {  # <state-dir> <task> <spawn-gen> [expected-head]
  local state=$1 task=$2 spawn_gen=$3 expected_head=${4:-} dir record parsed parsed_head mismatch=''
  dir="$state/$task.inbox"
  for record in "$dir"/*.msg; do
    [ -f "$record" ] || continue
    parsed=$(fm_delivery_continuation_parse_record "$record" "$task" "$spawn_gen") || continue
    parsed_head=${parsed%%$'\t'*}
    if [ -n "$expected_head" ] && [ "$parsed_head" != "$expected_head" ]; then
      [ -n "$mismatch" ] || mismatch="pending"$'\t'"$parsed"
      continue
    fi
    printf 'pending\t%s\n' "$parsed"
    return 0
  done
  for record in "$dir"/handled/*.msg; do
    [ -f "$record" ] || continue
    parsed=$(fm_delivery_continuation_parse_record "$record" "$task" "$spawn_gen") || continue
    parsed_head=${parsed%%$'\t'*}
    if [ -n "$expected_head" ] && [ "$parsed_head" != "$expected_head" ]; then
      [ -n "$mismatch" ] || mismatch="acknowledged"$'\t'"$parsed"
      continue
    fi
    printf 'acknowledged\t%s\n' "$parsed"
    return 0
  done
  if [ -n "$mismatch" ]; then
    printf 'head-mismatch\t%s\n' "$mismatch"
    return 0
  fi
  return 1
}
