#!/usr/bin/env bash
# fm-delivery-continuation-lib.sh - validation-continuation message contract.

FM_DELIVERY_CONTINUATION_SCHEMA='fm-delivery-continuation.v1'

fm_delivery_committed_receipt_contract() {
  printf '%s\n' 'Delivery receipt contract: committed-head-v1'
}

fm_delivery_historical_receipt_contract() {
  # shellcheck disable=SC2016 # Backticks are literal historical brief text.
  printf '%s\n' 'When you believe it is complete, append `done: {summary}` to the status file and stop.'
}

fm_delivery_receipt_contract_kind() {  # <brief>
  local brief=$1
  if grep -Fqx "$(fm_delivery_committed_receipt_contract)" "$brief"; then
    printf '%s\n' canonical
  elif grep -Fqx "$(fm_delivery_historical_receipt_contract)" "$brief"; then
    printf '%s\n' historical
  else
    return 1
  fi
}

fm_delivery_receipt_state() {  # <status> <canonical|historical> [spawn-gen]
  local status=$1 kind=$2 spawn_gen=${3:-} line parsed parsed_head parsed_gen state='' head=''
  case "$kind" in canonical|historical) ;; *) return 1 ;; esac
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      'done: PR '*|'done: merged'*) state=terminal; head=; continue ;;
      'failed:'*|'failed ['*']:'*) state=failed; head=; continue ;;
    esac
    if [ "$kind" = canonical ]; then
      parsed=$(printf '%s\n' "$line" | sed -n 's/^done:[[:space:]]*committed[[:space:]]\([0-9A-Fa-f][0-9A-Fa-f]*\)[[:space:]]\[spawn-gen=\([A-Za-z0-9._-][A-Za-z0-9._-]*\)\]\([[:space:]].*\)\{0,1\}$/\1|\2/p')
      if [ -n "$parsed" ]; then
        parsed_head=${parsed%%|*}
        parsed_gen=${parsed#*|}
        if [ -n "$spawn_gen" ] && [ "$parsed_gen" = "$spawn_gen" ]; then
          state=committed
          head=$parsed_head
        else
          state=incarnation-mismatch
          head=
        fi
      fi
    else
      case "$line" in
        'done: '*) state=historical; head= ;;
      esac
    fi
  done < "$status"
  case "$state" in
    committed) printf 'committed\t%s\n' "$head" ;;
    historical|terminal|failed|incarnation-mismatch) printf '%s\n' "$state" ;;
    *) return 1 ;;
  esac
}

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
