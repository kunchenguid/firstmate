#!/usr/bin/env bash
# Durable delivery-attempt identity, write-once and receipt-derived.
#
# Single owner of schema fm-attempt.v1: the immutable envelope
# {task_source, task_key, home_id, attempt_id, generation}; write-once
# provider/delivery fields frozen at allocation; effect receipts where each
# effect is observed at most once under its explicit identity (identical
# replay is a no-op, a second different observation refuses); an append-only
# observations journal for provisional evidence that is never authority; and
# named obligations derived solely from missing observed effects. There is NO
# mutable phase field; lifecycle helpers derive from the envelope plus the
# observed effect set.
#
# This record is coordination state only. Decision OS beads remain task truth;
# this file never mirrors live bead state, semantic worker state, endpoint
# liveness, Git refs, cleanliness, ancestry, or forge status.
#
# Records live under $FM_STATE_OVERRIDE/attempts/<attempt_id>.json when
# FM_STATE_OVERRIDE is set (tests), else $FM_HOME/state/attempts/. All
# mutations happen under the attempt lock using the shared primitives from
# bin/fm-wake-lib.sh (fm_lock_try_acquire / fm_lock_release), which are
# non-reentrant: internal _held variants never reacquire. Publication is
# write-temp-then-mv.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

attempts_dir() {
  printf '%s/attempts' "${FM_STATE_OVERRIDE:-$FM_HOME/state}"
}

attempt_path() {  # <attempt_id>
  printf '%s/%s.json' "$(attempts_dir)" "$1"
}

attempt_lock() {  # <attempt_id>
  printf '%s/.%s.lock' "$(attempts_dir)" "$1"
}

# shellcheck disable=SC2034
FM_ATTEMPT_LIB_SOURCED=1

fm_attempt_alloc() {  # <task_source> <task_key> <home_id> -> prints <attempt_id>
  local task_source=$1 task_key=$2 home_id=$3
  local dir gen attempt_id tmp f g
  dir="$(attempts_dir)"
  mkdir -p "$dir"
  fm_lock_try_acquire "$dir/.alloc.lock" || {
    echo "attempt-alloc: allocation lock busy" >&2
    return 1
  }
  gen=0
  for f in "$dir"/"$task_key"-a*.json; do
    [ -e "$f" ] || continue
    g=${f##*-a}
    g=${g%.json}
    case "$g" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$g" -gt "$gen" ] && gen=$g
  done
  gen=$((gen + 1))
  attempt_id="$task_key-a$gen"
  tmp="$dir/.$attempt_id.tmp.$$"
  jq -n \
    --arg schema fm-attempt.v1 \
    --arg task_source "$task_source" --arg task_key "$task_key" \
    --arg home_id "$home_id" --arg attempt_id "$attempt_id" \
    --argjson generation "$gen" \
    '{schema:$schema,envelope:{task_source:$task_source,task_key:$task_key,home_id:$home_id,attempt_id:$attempt_id,generation:$generation},receipts:{},observations:[],created_at:(now|todateiso8601)}' \
    > "$tmp" || { fm_lock_release "$dir/.alloc.lock"; return 1; }
  mv -f "$tmp" "$(attempt_path "$attempt_id")" || {
    fm_lock_release "$dir/.alloc.lock"
    return 1
  }
  fm_lock_release "$dir/.alloc.lock"
  printf '%s\n' "$attempt_id"
}

fm_attempt_load() {  # <attempt_id> -> JSON on stdout; nonzero when absent
  local f
  f="$(attempt_path "$1")"
  [ -f "$f" ] || return 1
  cat "$f"
}

fm_attempt_generation() {  # <attempt_id>
  fm_attempt_load "$1" | jq -r '.envelope.generation'
}

# --- lock ownership (non-reentrant) ----------------------------------------

fm_attempt_lock_acquire() {  # <attempt_id>
  fm_lock_try_acquire "$(attempt_lock "$1")"
}

fm_attempt_lock_release() {  # <attempt_id>
  fm_lock_release "$(attempt_lock "$1")"
}

# --- lock-held internal primitives (never reacquire) -----------------------

fm_attempt_generation_held() {  # <attempt_id>
  fm_attempt_load "$1" | jq -r '.envelope.generation'
}

fm_attempt_effect_observe_held() {  # <attempt_id> <generation> <name> <evidence-json>
  local attempt=$1 gen=$2 name=$3 evidence=$4
  local path tmp live_gen seq existing_evidence existing_norm
  path="$(attempt_path "$attempt")"
  live_gen=$(fm_attempt_generation_held "$attempt") || return 1
  [ "$live_gen" = "$gen" ] || {
    echo "stale generation: $attempt expects gen $gen, record is gen $live_gen" >&2
    return 1
  }
  # write-once: an existing observed entry with different evidence refuses;
  # identical replay is a no-op. Both sides are normalized through jq -cS so
  # semantically identical evidence (key order differences) is replay equality.
  existing_evidence=$(jq -r --arg name "$name" \
    '[.receipts[$name][]? | select(.state == "observed")][0].evidence // ""' "$path")
  if [ -n "$existing_evidence" ]; then
    existing_norm=$(printf '%s' "$existing_evidence" | jq -cS . 2>/dev/null || printf '%s' "$existing_evidence")
    local ev_norm
    ev_norm=$(printf '%s' "$evidence" | jq -cS . 2>/dev/null || printf '%s' "$evidence")
    if [ "$existing_norm" = "$ev_norm" ]; then
      return 0
    fi
    echo "contradiction: effect $name already observed on $attempt with different evidence" >&2
    return 1
  fi
  seq=$(jq -r --arg name "$name" '[.receipts[$name][]? | .seq] | (max // 0) + 1' "$path")
  tmp="$(attempts_dir)/.$attempt.tmp.$$"
  jq --arg name "$name" --argjson seq "$seq" --argjson evidence "$evidence" \
    '.receipts[$name] += [{seq:$seq,state:"observed",generation:.envelope.generation,observed_at:(now|todateiso8601),evidence:$evidence}]' \
    "$path" > "$tmp" || return 1
  mv -f "$tmp" "$path" || return 1
}

fm_attempt_effect_pending_held() {  # <attempt_id> <generation> <name> <reason-json>
  local attempt=$1 gen=$2 name=$3 reason=$4
  local path tmp live_gen seq
  path="$(attempt_path "$attempt")"
  live_gen=$(fm_attempt_generation_held "$attempt") || return 1
  [ "$live_gen" = "$gen" ] || return 1
  seq=$(jq -r --arg name "$name" '[.receipts[$name][]? | .seq] | (max // 0) + 1' "$path")
  tmp="$(attempts_dir)/.$attempt.tmp.$$"
  jq --arg name "$name" --argjson seq "$seq" --argjson reason "$reason" \
    '.receipts[$name] += [{seq:$seq,state:"pending",generation:.envelope.generation,observed_at:(now|todateiso8601),reason:$reason}]' \
    "$path" > "$tmp" || return 1
  mv -f "$tmp" "$path" || return 1
}

fm_attempt_freeze_allocation_held() {  # <attempt_id> <generation> <provider-json> <delivery-json>
  local attempt=$1 gen=$2 provider=$3 delivery=$4
  local path tmp live_gen existing_p existing_d
  path="$(attempt_path "$attempt")"
  live_gen=$(fm_attempt_generation_held "$attempt") || return 1
  [ "$live_gen" = "$gen" ] || {
    echo "stale generation at freeze: $attempt" >&2
    return 1
  }
  existing_p=$(jq -r '.provider // empty' "$path")
  existing_d=$(jq -r '.delivery // empty' "$path")
  if [ -n "$existing_p" ] || [ -n "$existing_d" ]; then
    # Normalize both sides through jq -cS (compact, sorted keys): jq -r prints
    # stored objects pretty-printed, so raw textual comparison would refuse an
    # identical replay; semantically identical JSON is replay equality.
    local existing_p_norm existing_d_norm p_norm d_norm
    existing_p_norm=$(printf '%s' "$existing_p" | jq -cS . 2>/dev/null || printf '%s' "$existing_p")
    existing_d_norm=$(printf '%s' "$existing_d" | jq -cS . 2>/dev/null || printf '%s' "$existing_d")
    p_norm=$(printf '%s' "$provider" | jq -cS . 2>/dev/null || printf '%s' "$provider")
    d_norm=$(printf '%s' "$delivery" | jq -cS . 2>/dev/null || printf '%s' "$delivery")
    if [ "$existing_p_norm" = "$p_norm" ] && [ "$existing_d_norm" = "$d_norm" ]; then
      return 0
    fi
    echo "contradiction: provider/delivery already frozen on $attempt with different values" >&2
    return 1
  fi
  tmp="$(attempts_dir)/.$attempt.tmp.$$"
  # The successful first freeze IS the provider effect: the frozen provider
  # copy identity is observed as the provider receipt, so the release
  # obligation derives from the missing launch effect (plan: a crash after
  # allocation leaves the provider effect in place). The receipt is written
  # only on the first freeze; the identical-replay and contradiction paths
  # above return before this write.
  jq --argjson provider "$provider" --argjson delivery "$delivery" \
    '.provider=$provider | .delivery=$delivery | .receipts.provider += [{seq:1,state:"observed",generation:.envelope.generation,observed_at:(now|todateiso8601),evidence:$provider}]' \
    "$path" > "$tmp" || return 1
  mv -f "$tmp" "$path" || return 1
}

fm_attempt_observe_held() {  # <attempt_id> <generation> <name> <evidence-json> (journal)
  local attempt=$1 gen=$2 name=$3 evidence=$4
  local path tmp live_gen
  path="$(attempt_path "$attempt")"
  live_gen=$(fm_attempt_generation_held "$attempt") || return 1
  [ "$live_gen" = "$gen" ] || return 1
  tmp="$(attempts_dir)/.$attempt.tmp.$$"
  jq --arg name "$name" --argjson evidence "$evidence" \
    '.observations += [{name:$name,observed_at:(now|todateiso8601),generation:.envelope.generation,evidence:$evidence}]' \
    "$path" > "$tmp" || return 1
  mv -f "$tmp" "$path" || return 1
}

fm_attempt_obligations_held() {  # <attempt_id> -> missing observed effect names
  local attempt=$1 disp required
  # derived solely from receipts; no phase
  disp=$(jq -r --arg name landing \
    '[.receipts[$name][]? | select(.state == "observed")][0].evidence.disposition // ""' \
    "$(attempt_path "$attempt")")
  if jq -e --arg name claim \
    '[.receipts[$name][]? | select(.state == "observed")][0].evidence.status == "refused"' \
    "$(attempt_path "$attempt")" >/dev/null 2>&1; then
    return 0
  fi
  required="claim provider launch landing"
  case "$disp" in
    landed) required="$required tracker cleanup.endpoint cleanup.branch cleanup.provider cleanup.runtime" ;;
    preserved_unlanded) required="$required cleanup.endpoint cleanup.branch cleanup.preservation cleanup.provider cleanup.runtime" ;;
  esac
  jq -r --argjson required "$(printf '%s' "$required" | jq -R 'split(" ")')" \
    '. as $root |
     [ $required[] as $name | select(([$root.receipts[$name][]? | select(.state == "observed")] | length) == 0) | $name ] | join(" ")' \
    "$(attempt_path "$attempt")"
}

fm_attempt_retire_held() {  # <attempt_id> <generation> <audit-json>
  local attempt=$1 gen=$2 audit=$3
  local path tmp live_gen missing seq
  path="$(attempt_path "$attempt")"
  live_gen=$(fm_attempt_generation_held "$attempt") || return 1
  [ "$live_gen" = "$gen" ] || {
    echo "stale generation at retirement: $attempt" >&2
    return 1
  }
  missing=$(fm_attempt_obligations_held "$attempt")
  [ -z "$missing" ] || {
    echo "retirement blocked: missing observed effects: $missing" >&2
    return 1
  }
  seq=$(jq -r --arg name retirement '[.receipts[$name][]? | .seq] | (max // 0) + 1' "$path")
  tmp="$(attempts_dir)/.$attempt.tmp.$$"
  jq --argjson seq "$seq" --argjson audit "$audit" \
    '.receipts.retirement += [{seq:$seq,state:"observed",generation:.envelope.generation,observed_at:(now|todateiso8601),evidence:$audit}]' \
    "$path" > "$tmp" || return 1
  mv -f "$tmp" "$path" || return 1
}

# --- public wrappers (acquire once, call held, release) --------------------

fm_attempt_effect_observe() {  # <attempt_id> <generation> <name> <evidence-json>
  local attempt=$1 rc
  fm_attempt_lock_acquire "$attempt" || return 1
  fm_attempt_effect_observe_held "$@"
  rc=$?
  fm_attempt_lock_release "$attempt"
  return $rc
}

fm_attempt_effect_pending() {  # <attempt_id> <generation> <name> <reason-json>
  local attempt=$1 rc
  fm_attempt_lock_acquire "$attempt" || return 1
  fm_attempt_effect_pending_held "$@"
  rc=$?
  fm_attempt_lock_release "$attempt"
  return $rc
}

fm_attempt_freeze_allocation() {  # <attempt_id> <generation> <provider-json> <delivery-json>
  local attempt=$1 rc
  fm_attempt_lock_acquire "$attempt" || return 1
  fm_attempt_freeze_allocation_held "$@"
  rc=$?
  fm_attempt_lock_release "$attempt"
  return $rc
}

fm_attempt_observe() {  # <attempt_id> <generation> <name> <evidence-json>
  local attempt=$1 rc
  fm_attempt_lock_acquire "$attempt" || return 1
  fm_attempt_observe_held "$@"
  rc=$?
  fm_attempt_lock_release "$attempt"
  return $rc
}

fm_attempt_retire() {  # <attempt_id> <generation> <audit-json>
  local attempt=$1 rc
  fm_attempt_lock_acquire "$attempt" || return 1
  fm_attempt_retire_held "$@"
  rc=$?
  fm_attempt_lock_release "$attempt"
  return $rc
}

fm_attempt_obligations() {  # <attempt_id>
  local attempt=$1
  fm_attempt_lock_acquire "$attempt" || return 1
  fm_attempt_obligations_held "$attempt"
  local rc=$?
  fm_attempt_lock_release "$attempt"
  return $rc
}

# --- derived lifecycle helpers (no mutable phase) --------------------------

fm_attempt_is_allocated() {  # 0 when the provider effect is observed
  jq -e --arg name provider \
    '[.receipts[$name][]? | select(.state == "observed")] | length > 0' \
    "$(attempt_path "$1")" >/dev/null 2>&1
}

fm_attempt_is_launched() {  # 0 when the launch effect is observed
  jq -e --arg name launch \
    '[.receipts[$name][]? | select(.state == "observed")] | length > 0' \
    "$(attempt_path "$1")" >/dev/null 2>&1
}

fm_attempt_is_retired() {  # 0 when the retirement effect is observed
  jq -e --arg name retirement \
    '[.receipts[$name][]? | select(.state == "observed")] | length > 0' \
    "$(attempt_path "$1")" >/dev/null 2>&1
}

fm_attempt_landing_disposition() {  # prints landed | preserved_unlanded | unknown | ""
  jq -r --arg name landing \
    '[.receipts[$name][]? | select(.state == "observed")][0].evidence.disposition // ""' \
    "$(attempt_path "$1")" 2>/dev/null || true
}
