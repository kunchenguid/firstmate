#!/usr/bin/env bash
# fm-sol-cap-lib.sh - the mechanical ceiling on concurrent capped sessions.
#
# This library owns admission, counting, and claim reconciliation; fm-spawn.sh
# owns the launch hook. docs/configuration.md "Sol session ceiling" owns the
# operator contract, the declaration keys, and exclusions.
#
# The guard is OFF unless the captain declares it. The declaration lives in
# <config-dir>/sol-cap and names both the ceiling and the models it covers:
#
#   max=4
#   ceiling=2
#   models=gpt-6.1-sol
#   model-pattern=^gpt-[0-9.]+-sol$
#
# max is required and is the largest concurrent count the captain allows;
# ceiling is optional and may only lower it; models is a pipe-delimited list
# of exact model ids and model-pattern is one extended regular expression.
# At least one of models or model-pattern is required. Every line is a
# key=value pair: put an explanation on its own comment line, because an
# inline comment becomes part of the value.
#
# An absent declaration leaves the guard inert: no ceiling, no reservation,
# no behaviour change for a home that never opted in. A malformed declaration
# refuses loudly, naming the file and the problem, rather than guessing.
#
# The count: <state-dir>/sol-sessions.tsv, one TSV row per capped session
#
#   <session-id>	<model>	<start-epoch>	<pid>
#

# Registries live in each owning state directory; the claim lock lives in
# the shared local root home's state directory.
# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_SOL_REGISTRY_NAME=sol-sessions.tsv
FM_SOL_LOCK_NAME=.sol-cap.lock

# The refusal message of the refusing call, and FM_SOL_CLAIM_CREATED set to
# the claimed task id after a call that both passed the cap and wrote its
# reserve row.
# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_SOL_CAP_REFUSAL=
FM_SOL_CLAIM_CREATED=

# Set by fm_sol_cap_config (FM_SOL_CAP_ACTIVE, FM_SOL_CAP, FM_SOL_CAP_MAX,
# FM_SOL_CAP_MODELS, FM_SOL_CAP_PATTERN, FM_SOL_CAP_CONFIG_ERROR) and by
# fm_sol_cap_active_count (FM_SOL_COUNT_ERROR, FM_SOL_ACTIVE_LIST,
# FM_SOL_COUNT) and fm_sol_cap_lock_acquire (FM_LOCK_HELD_PID) for their
# caller.
# shellcheck disable=SC2034
FM_SOL_CAP_ACTIVE=0
FM_SOL_CAP=
FM_SOL_CAP_MAX=
FM_SOL_CAP_MODELS=
FM_SOL_CAP_PATTERN=
FM_SOL_CAP_CONFIG_ERROR=
FM_SOL_COUNT_ERROR=

fm_sol_cap_age_text() {  # <seconds>
  local s=$1
  if [ "$s" -ge 86400 ]; then
    printf '%dd%dh' $((s / 86400)) $(((s % 86400) / 3600))
  elif [ "$s" -ge 3600 ]; then
    printf '%dh%dm' $((s / 3600)) $(((s % 3600) / 60))
  elif [ "$s" -ge 60 ]; then
    printf '%dm%ds' $((s / 60)) $((s % 60))
  else
    printf '%ds' "$s"
  fi
}

# fm_sol_cap_config_dir <state-dir>
# The config directory of the home that owns <state-dir>. A parent-route
# state belongs to the parent home; any other state belongs to the home that
# holds it. The dispatching home's own config override wins for its own
# state, so a home that redirects its config is read from where it reads.
fm_sol_cap_config_dir() {  # <state-dir>
  local state=$1 home
  case "$state" in
    */state/parent-route) home=${state%/state/parent-route} ;;
    */state) home=${state%/state} ;;
    *) home=${FM_HOME:-} ;;
  esac
  if [ -n "${FM_CONFIG_OVERRIDE:-}" ] && [ -n "$home" ] && [ "$home" = "${FM_HOME:-}" ]; then
    printf '%s\n' "$FM_CONFIG_OVERRIDE"
    return 0
  fi
  [ -n "$home" ] || return 1
  printf '%s/config\n' "$home"
}

# fm_sol_cap_config <config-dir>
# Load the captain's declaration from <config-dir>/sol-cap. Sets
# FM_SOL_CAP_ACTIVE=1 when a declaration exists, FM_SOL_CAP_MAX (the
# declared maximum), FM_SOL_CAP (the effective ceiling), FM_SOL_CAP_MODELS
# (the declared exact model ids), and FM_SOL_CAP_PATTERN (the declared model
# pattern). Returns 0 when the guard is declared and well formed. An absent
# declaration leaves the guard inert: FM_SOL_CAP_ACTIVE=0, no ceiling, and no
# error. A malformed declaration returns 1 with FM_SOL_CAP_CONFIG_ERROR
# naming the file and the problem, so the guard refuses instead of guessing
# a ceiling the captain never wrote.
fm_sol_cap_config() {  # <config-dir>
  local config=$1 file line key value rc
  local max='' ceiling='' models='' pattern=''
  local seen_max=0 seen_ceiling=0 seen_models=0 seen_pattern=0
  FM_SOL_CAP_ACTIVE=0
  FM_SOL_CAP=
  FM_SOL_CAP_MAX=
  FM_SOL_CAP_MODELS=
  FM_SOL_CAP_PATTERN=
  FM_SOL_CAP_CONFIG_ERROR=
  file=$config/sol-cap
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_SOL_CAP_CONFIG_ERROR="$file is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      '' | '#'*) continue ;;
    esac
    case "$line" in
      *=*) ;;
      *)
        FM_SOL_CAP_CONFIG_ERROR="$file declares a line that is not a key=value pair: $line"
        return 1
        ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      max)
        [ "$seen_max" = 0 ] || {
          FM_SOL_CAP_CONFIG_ERROR="$file declares max more than once"
          return 1
        }
        seen_max=1
        max=$value
        ;;
      ceiling)
        [ "$seen_ceiling" = 0 ] || {
          FM_SOL_CAP_CONFIG_ERROR="$file declares ceiling more than once"
          return 1
        }
        seen_ceiling=1
        ceiling=$value
        ;;
      models)
        [ "$seen_models" = 0 ] || {
          FM_SOL_CAP_CONFIG_ERROR="$file declares models more than once"
          return 1
        }
        seen_models=1
        models=$value
        ;;
      model-pattern)
        [ "$seen_pattern" = 0 ] || {
          FM_SOL_CAP_CONFIG_ERROR="$file declares model-pattern more than once"
          return 1
        }
        seen_pattern=1
        pattern=$value
        ;;
      *)
        FM_SOL_CAP_CONFIG_ERROR="$file declares an unknown key: $key"
        return 1
        ;;
    esac
  done < "$file"
  if [ "$seen_max" != 1 ]; then
    FM_SOL_CAP_CONFIG_ERROR="$file must declare max, the largest concurrent session count the captain allows"
    return 1
  fi
  if ! fm_sol_cap_small_int "$max"; then
    FM_SOL_CAP_CONFIG_ERROR="$file must declare max as a positive integer of at most nine digits, not '$max'"
    return 1
  fi
  if [ "$seen_ceiling" = 1 ]; then
    if ! fm_sol_cap_small_int "$ceiling"; then
      FM_SOL_CAP_CONFIG_ERROR="$file must declare ceiling as an integer from 1 through $max, not '$ceiling'"
      return 1
    fi
    if [ "$ceiling" -gt "$max" ]; then
      FM_SOL_CAP_CONFIG_ERROR="$file must declare ceiling as an integer from 1 through $max, not '$ceiling'"
      return 1
    fi
  else
    ceiling=$max
  fi
  if [ "$seen_models" != 1 ] && [ "$seen_pattern" != 1 ]; then
    FM_SOL_CAP_CONFIG_ERROR="$file must declare models or model-pattern, the model ids the ceiling covers"
    return 1
  fi
  if [ "$seen_models" = 1 ]; then
    case "$models" in
      '')
        FM_SOL_CAP_CONFIG_ERROR="$file must declare models as a pipe-delimited list of model ids"
        return 1
        ;;
      *'||'*)
        FM_SOL_CAP_CONFIG_ERROR="$file declares an empty model id in models"
        return 1
        ;;
    esac
  fi
  if [ "$seen_pattern" = 1 ]; then
    case "$pattern" in
      '')
        FM_SOL_CAP_CONFIG_ERROR="$file must declare model-pattern as one extended regular expression"
        return 1
        ;;
    esac
    rc=0
    printf '' | grep -E -e "$pattern" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -gt 1 ]; then
      FM_SOL_CAP_CONFIG_ERROR="$file declares an unusable model-pattern: $pattern"
      return 1
    fi
  fi
  FM_SOL_CAP_ACTIVE=1
  FM_SOL_CAP_MAX=$max
  FM_SOL_CAP=$ceiling
  FM_SOL_CAP_MODELS=$models
  FM_SOL_CAP_PATTERN=$pattern
  return 0
}

# fm_sol_cap_model_capped <model>
# Is <model> one of the models the loaded declaration covers? The declared
# exact ids match literally; the declared pattern matches the model id. A
# model the declaration does not name is not capped.
# fm_sol_cap_small_int <value>
# Zero exit when <value> is a positive integer of at most nine digits, so a
# numeric comparison against it can never overflow: an out-of-range value
# makes bash's comparison error out, and an erroring comparison reads as
# "not greater", which would let a declaration through that the captain
# never wrote.
fm_sol_cap_small_int() {  # <value>
  local value=$1
  case "$value" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "${#value}" -le 9 ] || return 1
  [ "$value" -ge 1 ] || return 1
  return 0
}

fm_sol_cap_model_capped() {  # <model>
  local model=$1
  [ -n "$model" ] || return 1
  case "|$FM_SOL_CAP_MODELS|" in
    *"|$model|"*) return 0 ;;
  esac
  [ -n "$FM_SOL_CAP_PATTERN" ] || return 1
  printf '%s\n' "$model" | grep -Eq -e "$FM_SOL_CAP_PATTERN"
}

# fm_sol_cap_state_model_capped <state-dir> <model>
# Is <model> covered by the declaration that governs <state-dir>? Returns 0
# when it is, 1 when it is not or when no declaration exists, and 2 when that
# declaration is malformed and the question cannot be answered.
fm_sol_cap_state_model_capped() {  # <state-dir> <model>
  local state=$1 model=$2 config
  config=$(fm_sol_cap_config_dir "$state") || {
    printf '%s\n' "error: Sol ceiling unavailable: the config directory of $state could not be resolved" >&2
    return 2
  }
  fm_sol_cap_config "$config" || {
    printf '%s\n' "error: Sol ceiling unavailable: $FM_SOL_CAP_CONFIG_ERROR" >&2
    return 2
  }
  [ "$FM_SOL_CAP_ACTIVE" = 1 ] || return 1
  fm_sol_cap_model_capped "$model"
}

# fm_sol_cap_state_covers <state-dir> <model>
# Does the declaration that governs <state-dir> cover <model>? The
# declaration is read in its own scope, so the caller's loaded declaration is
# left exactly as it was. Returns 0 when it covers the model, 1 when it does
# not or when no declaration exists, and 2 when that declaration is
# malformed and the question cannot be answered.
fm_sol_cap_state_covers() {  # <state-dir> <model>
  local state=$1 model=$2 config
  config=$(fm_sol_cap_config_dir "$state") || return 2
  (
    fm_sol_cap_config "$config" || exit 2
    [ "$FM_SOL_CAP_ACTIVE" = 1 ] || exit 1
    fm_sol_cap_model_capped "$model"
  )
}

# fm_sol_cap_entry_shape <start> <pid>
# Zero exit when a registry row is shaped right: integer start epoch and pid.
fm_sol_cap_entry_shape() {  # <start> <pid>
  local start=$1 pid=$2
  case "$start" in '' | *[!0-9]*) return 1 ;; esac
  # -1 is a confirmed stop, -2 an adopted uncertain claim, -3 a superseded
  # incarnation the next adoption resolves.
  case "$pid" in -1 | -2 | -3) return 0 ;; '' | *[!0-9]*) return 1 ;; esac
}

fm_sol_cap_entry_live() {  # <start> <pid>
  local start=$1 pid=$2
  case "$start" in '' | *[!0-9]*) return 1 ;; esac
  # A superseded row (-3) does not count: the incarnation it names is being
  # replaced, and a replacement that never completes must not consume
  # capacity forever. The next adoption resolves the marker.
  case "$pid" in -2) return 0 ;; -3) return 1 ;; '' | *[!0-9]*) return 1 ;; esac
  [ "$pid" = 0 ] || fm_pid_alive "$pid"
}

# fm_sol_cap_active_count <first-state>
# Count the live capped-session registry rows in every local home's state
# directory on this machine. Sets FM_SOL_COUNT to the
# count and FM_SOL_ACTIVE_LIST to a "; "-joined listing "<id> (<model>, age
# N)"; an entry in a state directory other than <first-state> is qualified
# with " in <state-dir>". Returns 1 with FM_SOL_COUNT_ERROR when the local
# homes cannot be enumerated, a registry cannot be read, or a row is
# malformed, because skipping a home could claim a free slot that another
# home holds.
fm_sol_cap_home() {
  case "$1" in
    */state/parent-route) printf '%s\n' "${1%/state/parent-route}" ;;
    *) printf '%s\n' "$FM_HOME" ;;
  esac
}

fm_sol_cap_adopt_workers() (
  local state=$1 now=$2 meta id model file home target backend verdict absence host pid lifecycle_lock='' owner current config lifecycle_held
  trap '[ -z "$lifecycle_lock" ] || fm_lock_release "$lifecycle_lock"' EXIT
  file=$state/$FM_SOL_REGISTRY_NAME
  case "$state" in
    */state/parent-route) home=${state%/state/parent-route} ;;
    */state) home=${state%/state} ;;
    *) home=$FM_HOME ;;
  esac
  # The model set is the declaring home's own: a home that declared no
  # ceiling adopts nothing and owns no occupancy.
  config=$(fm_sol_cap_config_dir "$state") || return 1
  fm_sol_cap_config "$config" || return 1
  [ "$FM_SOL_CAP_ACTIVE" = 1 ] || return 0
  for meta in "$state"/*.meta; do
    if [ -n "$lifecycle_lock" ]; then
      fm_lock_release "$lifecycle_lock" || return 1
      lifecycle_lock=
    fi
    [ -e "$meta" ] || continue
    [ -f "$meta" ] && [ -r "$meta" ] && [ ! -L "$meta" ] || return 1
    id=${meta##*/}
    id=${id%.meta}
    model=$(awk -F= '$1 == "model" {sub(/^[^=]*=/, ""); print; exit}' "$meta") || return 1
    if ! fm_sol_cap_model_capped "$model"; then
      # This incarnation claims no slot, but it may be replacing a capped
      # one: its uncertain or superseded row must be resolved here, or the
      # prior incarnation's occupancy counts forever. A replacement in
      # flight owns this task's spawn lock, and its row is not resolved
      # while that replacement runs.
      if [ -f "$file" ] && awk -F'\t' -v id="$id" '$1 == id && ($4 == -2 || $4 == -3) {found=1; exit} END {exit !found}' "$file"; then
        owner=$(cat "$state/.spawn-$id.lock/pid" 2>/dev/null || true)
        fm_current_pid current || return 1
        [ "$owner" != "$current" ] || continue
        if ! fm_lock_try_acquire "$state/.spawn-$id.lock"; then
          continue
        fi
        fm_sol_cap_registry_remove_row "$file" "$id" || {
          fm_lock_release "$state/.spawn-$id.lock" || return 1
          return 1
        }
        fm_lock_release "$state/.spawn-$id.lock" || return 1
      fi
      continue
    fi
    pid=
    if [ -f "$file" ] && awk -F'\t' -v id="$id" '$1 == id {found=1; exit} END {exit !found}' "$file"; then
      pid=$(awk -F'\t' -v id="$id" '$1 == id {print $4; exit}' "$file") || return 1
      case "$pid" in
        -2 | -3) ;;
        *) continue ;;
      esac
    fi
    # The lifecycle boundary: a replacement in flight owns this task's spawn
    # lock. The metadata it is replacing must not be read as a stopped
    # worker, and the worker must not go uncounted either, so it is adopted
    # as an uncertain claim rather than recorded as a stop.
    lifecycle_held=0
    owner=$(cat "$state/.spawn-$id.lock/pid" 2>/dev/null || true)
    fm_current_pid current || return 1
    if [ "$owner" = "$current" ]; then
      lifecycle_held=1
    elif ! fm_lock_try_acquire "$state/.spawn-$id.lock"; then
      lifecycle_held=1
    else
      lifecycle_lock=$state/.spawn-$id.lock
    fi
    if [ "$lifecycle_held" = 1 ]; then
      # A superseded marker is preserved until lifecycle ownership permits
      # its resolution: it still counts, and resolving it here would lose
      # the marker the next adoption needs.
      [ "$pid" = -3 ] && continue
      fm_sol_cap_registry_claim "$file" "$id" "$model" "$now" -2 || return 1
      continue
    fi
    verdict=unreadable
    host=$(awk -F= '$1 == "remote_host" {sub(/^[^=]*=/, ""); print; exit}' "$meta") || return 1
    if [ -n "$host" ]; then
      verdict=$(FM_HOME="$home" "$FM_WAKE_LIB_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh state "$id" </dev/null 2>/dev/null) || verdict=unreadable
      verdict=$(printf '%s\n' "$verdict" | tail -1)
    elif command -v fm_backend_of_meta >/dev/null 2>&1; then
      backend=$(fm_backend_of_meta "$meta") || return 1
      target=$(fm_backend_target_of_meta "$meta") || return 1
      if [ -n "$target" ]; then
        verdict=$(FM_HOME="$home" fm_backend_agent_state "$backend" "$target") || verdict=unreadable
        if [ "$verdict" = missing ]; then
          if command -v fm_control_endpoint_absence_verdict >/dev/null 2>&1; then
            absence=$(FM_HOME="$home" fm_control_endpoint_absence_verdict "$backend" "$target") || absence=unknown
            case "${absence%%$'\t'*}" in gone|dead) verdict=dead ;; *) verdict=unreadable ;; esac
          else
            verdict=unreadable
          fi
        fi
      fi
    fi
    case "$verdict" in
      dead|missing) fm_sol_cap_registry_claim "$file" "$id" "$model" "$now" -1 || return 1; continue ;;
    esac
    fm_sol_cap_registry_claim "$file" "$id" "$model" "$now" -2 || return 1
  done
)

fm_sol_cap_active_count() {  # <first-state>
  local first=$1 state file id model start pid now age entry home covered
  FM_SOL_COUNT=0
  FM_SOL_ACTIVE_LIST=
  FM_SOL_COUNT_ERROR=
  home=$(fm_sol_cap_home "$first") || return 1
  FM_HOME=$home fm_local_firstmate_state_dirs "$first" || {
    FM_SOL_COUNT_ERROR=$FM_LOCAL_FIRSTMATE_ERROR
    return 1
  }
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    [ "$state" != "$home/state/parent-route" ] || continue
    [ "$state/parent-route" != "$first" ] && [ ! "$state/parent-route" -ef "$first" ] || continue
    [ ! -d "$state/parent-route" ] || FM_LOCAL_FIRSTMATE_STATES+=("$state/parent-route")
  done
  fm_epoch_seconds_to FM_SOL_CAP_NOW
  now=$FM_SOL_CAP_NOW
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    file=$state/$FM_SOL_REGISTRY_NAME
    if ! fm_sol_cap_adopt_workers "$state" "$now"; then
      FM_SOL_COUNT_ERROR="cannot reconcile pre-existing capped workers in $state"
      return 1
    fi
    [ -e "$file" ] || [ -L "$file" ] || continue
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
      FM_SOL_COUNT_ERROR="Sol registry $file is not a readable regular file"
      return 1
    fi
    while :; do
      # A blank or hand-edited inert line is skipped, so a registry note
      # cannot stop the fleet; any nonblank row that fails the shape test is
      # malformed and refuses loudly, because silently skipping a
      # home could give away a slot another home holds.
      IFS=$'\t' read -r id model start pid || break
      [ -n "$id" ] || continue
      if [ -z "$model" ] || [ -z "$start" ] || ! fm_sol_cap_entry_shape "$start" "$pid"; then
        FM_SOL_COUNT_ERROR="Sol registry $file has a malformed row: ${id:-<empty>} ${model:-<empty>} ${start:-<empty>} ${pid:-<empty>}"
        return 1
      fi
      # Each home's own declaration decides which of its rows count: a home
      # that declared no ceiling owns no capped occupancy, and a home that
      # narrowed its declaration no longer counts the models it dropped. The
      # rows themselves stay as evidence.
      covered=0
      fm_sol_cap_state_covers "$state" "$model" || covered=$?
      case "$covered" in
        0) ;;
        1) continue ;;
        *)
          FM_SOL_COUNT_ERROR="the Sol declaration of $state could not be read"
          return 1
          ;;
      esac
      fm_sol_cap_entry_live "$start" "$pid" || continue
      age=$((now > start ? now - start : 0))
      entry="$id ($model, age $(fm_sol_cap_age_text "$age"))"
      [ "$state" = "$first" ] || entry="$entry in $state"
      FM_SOL_COUNT=$((FM_SOL_COUNT + 1))
      FM_SOL_ACTIVE_LIST="${FM_SOL_ACTIVE_LIST:+$FM_SOL_ACTIVE_LIST; }$entry"
    done < "$file"
  done
  return 0
}

# fm_sol_cap_lock_acquire <lock-dir> <what>
# Ceiling-claim lock contention between two simultaneous dispatches is
# transient, not fleet breakage: retry briefly, then refuse naming the
# problem, because the dispatch contract refuses rather than queues an
# unbounded wait. Sets FM_SOL_CAP_REFUSAL on refusal.
fm_sol_cap_lock_acquire() {  # <lock-dir> <what>
  local lock=$1 what=$2 tries=40 i=0
  while :; do
    fm_lock_try_acquire "$lock" && return 0
    i=$((i + 1))
    [ "$i" -lt "$tries" ] || break
    sleep 0.25
  done
  FM_SOL_CAP_REFUSAL="error: Sol ceiling: another dispatch has held the ceiling claim lock for over 10s$([ -n "${FM_LOCK_HELD_PID:-}" ] && printf ' (pid %s)' "$FM_LOCK_HELD_PID"); $what was not dispatched - retry shortly"
  return 1
}

# fm_sol_cap_registry_claim <registry-file> <id> <model> <now> [owner-pid]
# While the ceiling lock is held, replace only this task id's row, retaining
# every other task's row. Admission defaults to the calling process's pid;
# adoption supplies its occupancy or stop marker. The
# rewrite lands in one atomic mv, so a parallel reader never sees a
# half-written file.
fm_sol_cap_registry_claim() {  # <registry-file> <id> <model> <now>
  local file=$1 id=$2 model=$3 now=$4 owner=${5:-$$} tmp row rc
  tmp=$file.tmp.$$
  if [ -f "$file" ]; then
    awk -F'\t' -v id="$id" '$1 != id' "$file" > "$tmp" 2>/dev/null
    rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || {
      rm -f -- "$tmp"
      echo "error: Sol ceiling: Sol registry $file could not be read" >&2
      return 1
    }
  elif : >> "$file" 2>/dev/null; then
    : > "$tmp"
  else
    echo "error: Sol ceiling: Sol registry $file cannot be claimed" >&2
    return 1
  fi
  row="${id}"$'\t'"${model}"$'\t'"${now}"$'\t'"$owner"
  if ! printf '%s\n' "${row}" >> "$tmp"; then
    rm -f -- "$tmp"
    echo "error: Sol ceiling: Sol registry $file could not record the claim of $id" >&2
    return 1
  fi
  mv -- "$tmp" "$file" || {
    rm -f -- "$tmp"
    echo "error: Sol ceiling: Sol registry $file could not be rewritten" >&2
    return 1
  }
  return 0
}

# fm_sol_cap_lock_try_briefly <lock-dir>
# Take the admission boundary if it is free within a short wait. The
# invalidation path uses it: a dispatch that reserves no slot must not wait
# long on a boundary it does not need, but it must not lose the invalidation
# to ordinary contention either.
fm_sol_cap_lock_try_briefly() {  # <lock-dir>
  local lock=$1 i=0
  while :; do
    fm_lock_try_acquire "$lock" && return 0
    i=$((i + 1))
    [ "$i" -lt 8 ] || break
    sleep 0.25
  done
  return 1
}

# fm_sol_cap_registry_remove_row <registry-file> <id>
# Remove this task id's row, keeping every other row. Used to resolve a
# superseded row whose current incarnation claims no slot, so the prior
# incarnation's occupancy does not count forever.
fm_sol_cap_registry_remove_row() {  # <registry-file> <id>
  local file=$1 id=$2 tmp rc
  [ -f "$file" ] || return 0
  tmp=$file.tmp.remove.$$
  awk -F'\t' -v id="$id" '$1 != id' "$file" > "$tmp" 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || {
    rm -f -- "$tmp"
    return 1
  }
  mv -- "$tmp" "$file" || {
    rm -f -- "$tmp"
    return 1
  }
  return 0
}

# fm_sol_cap_registry_supersede <registry-file> <id>
# Mark this task id's row as superseded: the row names an incarnation that
# is being replaced, so it must not be read as this task's current claim. The
# row keeps its model and start epoch and still counts, so a replacement
# never hands the same capacity to two sessions before the next adoption
# resolves the marker. A no-op when the id has no row.
fm_sol_cap_registry_supersede() {  # <registry-file> <id>
  local file=$1 id=$2 tmp rc
  [ -f "$file" ] || return 0
  tmp=$file.tmp.supersede.$$
  awk -F'\t' -v OFS='\t' -v id="$id" '$1 == id { $4 = -3 } {print}' "$file" > "$tmp" 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || {
    rm -f -- "$tmp"
    return 1
  }
  mv -- "$tmp" "$file" || {
    rm -f -- "$tmp"
    return 1
  }
  return 0
}

# fm_sol_cap_refuse_and_claim <id> <kind> <harness> <model> <config-dir> <state-dir>
# The guard bin/fm-spawn.sh calls once a spawn's harness/model axis is fully
# resolved and before any endpoint, worktree, or record exists. A home that
# declared no ceiling never touches the registry and returns 0. A model the
# declaration does not cover returns 0. A dispatch at the ceiling is refused
# with one actionable message in FM_SOL_CAP_REFUSAL and return 1, and
# otherwise claims this task's row atomically in one locked critical section
# (count under the lock, then commit), with the calling process's pid as the
# reservation. A malformed declaration, an unavailable count, or a claim lock
# refuses loudly rather than launching possibly uncounted.
fm_sol_cap_refuse_and_claim() {  # <id> <kind> <harness> <model> <config-dir> <state-dir>
  local id=$1 harness=$3 model=$4 config=$5 state=$6 reuse=${7:-} registry now lock root local_home existing_pid existing_start existing_model covered row_start row_pid
  FM_SOL_CAP_REFUSAL=
  FM_SOL_CLAIM_CREATED=
  [ -n "$id" ] || return 0
  # The declaration is read before the model is judged: a malformed
  # declaration means the guard cannot know which models it covers, so it
  # refuses the dispatch instead of guessing a scope the captain never wrote.
  fm_sol_cap_config "$config" || {
    FM_SOL_CAP_REFUSAL="error: Sol ceiling unavailable: $FM_SOL_CAP_CONFIG_ERROR; task $id with model $model was not dispatched rather than launched against an undeclared ceiling"
    return 1
  }
  # A dispatch that reserves no slot covers three cases: the home declared
  # no ceiling, the model the declaration names is not this dispatch's
  # model, and the dispatch carries no explicit model pin. None of them
  # claims a slot.
  covered=0
  if [ "$FM_SOL_CAP_ACTIVE" = 1 ] && [ -n "$model" ] && [ "$model" != default ] &&
    fm_sol_cap_model_capped "$model"; then
    covered=1
  fi
  root=$(fm_firstmate_root_home "$(fm_sol_cap_home "$state")") || return 1
  lock=$root/state/$FM_SOL_LOCK_NAME
  if [ "$covered" = 0 ]; then
    # A genuine endpoint reuse keeps its row: the same session continues, and
    # the release that ends it is decided at its own publication.
    [ "$reuse" = reuse ] && return 0
    # Any other replacement marks the prior incarnation's row superseded: a
    # row an earlier incarnation left behind names this task's id while
    # describing a session that is being replaced, and adoption skips it, so
    # a later declaration would leave this worker uncounted. The row still
    # counts until the next adoption resolves the marker, so a replacement
    # never hands the same capacity to two sessions. A first dispatch has no
    # prior incarnation to mark, and a home with no row to mark never waits
    # on the admission boundary at all.
    # The task id still has a row, so this dispatch reuses an id whose
    # earlier incarnation left evidence behind. That is true whether the
    # earlier incarnation's metadata is still published or a confirmed
    # cleanup already removed it.
    grep -Fq "$(printf '%s\t' "$id")" "$state/$FM_SOL_REGISTRY_NAME" 2>/dev/null || return 0
    # Only a row that holds no live occupancy may be superseded. A row whose
    # session is still live or still uncertain holds its slot, and this
    # dispatch has not displaced that session yet: superseding it would
    # release a live worker's occupancy.
    row_start=$(awk -F'\t' -v id="$id" '$1 == id {print $3; exit}' "$state/$FM_SOL_REGISTRY_NAME" 2>/dev/null || true)
    row_pid=$(awk -F'\t' -v id="$id" '$1 == id {print $4; exit}' "$state/$FM_SOL_REGISTRY_NAME" 2>/dev/null || true)
    if fm_sol_cap_entry_live "$row_start" "$row_pid"; then
      return 0
    fi
    # The invalidation waits only briefly for the admission boundary, and it
    # never aborts this dispatch: a dispatch that reserves no slot must not
    # be refused by ceiling contention, and the row it marks keeps counting
    # until the next adoption resolves it.
    fm_sol_cap_lock_try_briefly "$lock" || return 0
    if ! fm_sol_cap_registry_supersede "$state/$FM_SOL_REGISTRY_NAME" "$id"; then
      fm_lock_release "$lock" || true
      return 0
    fi
    fm_lock_release "$lock" || true
    return 0
  fi
  if ! fm_sol_cap_lock_acquire "$lock" "task $id"; then
    return 1
  fi
  registry=$state/$FM_SOL_REGISTRY_NAME
  # The count again under the lock, so two spawns racing the count cannot
  # both take the last slot (active_count is this ceiling's decision pass).
  if ! fm_sol_cap_active_count "$state"; then
    FM_SOL_CAP_REFUSAL="error: Sol ceiling could not count its sessions: $FM_SOL_COUNT_ERROR; task $id with model $model was not dispatched rather than launched possibly uncounted"
    fm_lock_release "$lock" || true
    return 1
  fi
  existing_pid=$(awk -F'\t' -v id="$id" '$1 == id {print $4; exit}' "$registry" 2>/dev/null || true)
  existing_start=$(awk -F'\t' -v id="$id" '$1 == id {print $3; exit}' "$registry" 2>/dev/null || true)
  existing_model=$(awk -F'\t' -v id="$id" '$1 == id {print $2; exit}' "$registry" 2>/dev/null || true)
  if fm_sol_cap_entry_live "$existing_start" "$existing_pid"; then
    if [ "$reuse" = reuse ]; then
      if fm_sol_cap_model_capped "$existing_model"; then
        # The slot is already held by a session the declaration still
        # covers. Reconcile the row's model to the model this dispatch
        # claims, under the admission lock already held, so the row keeps
        # naming the model that actually holds the slot.
        if [ "$existing_model" != "$model" ]; then
          if ! fm_sol_cap_registry_claim "$registry" "$id" "$model" "$existing_start" "$existing_pid"; then
            FM_SOL_CAP_REFUSAL="error: Sol ceiling: the reuse of task $id could not be recorded in $registry; the dispatch was refused rather than launched uncounted"
            fm_lock_release "$lock" || true
            return 1
          fi
        fi
        FM_SOL_CLAIM_CREATED=$id
        fm_lock_release "$lock" || true
        return 0
      fi
      # The row's model is no longer covered by the declaration, so that row
      # holds no capacity. The claim goes through the count like any other,
      # and the row's model is reconciled by that claim.
    else
      FM_SOL_CAP_REFUSAL="error: Sol ceiling: task $id already holds a live or uncertain session; confirm its worker stopped through teardown before replacing it"
      fm_lock_release "$lock" || true
      return 1
    fi
  fi
  if [ "$FM_SOL_COUNT" -ge "$FM_SOL_CAP" ]; then
    FM_SOL_CAP_REFUSAL="error: Sol ceiling reached: $FM_SOL_COUNT concurrent capped session(s) already active and this ceiling is $FM_SOL_CAP (declared in config/sol-cap); the dispatch of task $id ($harness, $model) was refused. Active sessions: $FM_SOL_ACTIVE_LIST. A session frees its slot when its worker's process ends; the dispatch contract refuses at the ceiling instead of queueing"
    fm_lock_release "$lock" || true
    return 1
  fi
  now=$(fm_epoch_seconds_to FM_SOL_CAP_NOW; printf '%s' "$FM_SOL_CAP_NOW")
  # Prune stopped rows only after their metadata disappears; until then they
  # preserve stop evidence against adoption. A malformed row is deliberately
  # left in place for its loud refusal.
  for local_home in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    fm_sol_cap_registry_prune "$local_home/$FM_SOL_REGISTRY_NAME"
  done
  if ! fm_sol_cap_registry_claim "$registry" "$id" "$model" "$now"; then
    FM_SOL_CAP_REFUSAL="error: Sol ceiling: the claim of task $id in $registry could not be written; the dispatch was refused rather than launched uncounted"
    fm_lock_release "$lock" || true
    return 1
  fi
  FM_SOL_CLAIM_CREATED=$id
  fm_lock_release "$lock" || true
  return 0
}

# fm_sol_cap_has_owned_occupancy <id> <state-dir>
# Does this task hold a capped session occupancy that must be released or
# reconciled? A registry row answers it by its pid alone. Without a row the
# task's recorded model is classified against the declaring home's own
# declaration, so a home that declared no ceiling owns no occupancy.
# Returns 0 when the task owns occupancy, 1 when it does not, and 2 when the
# declaration is malformed and the question cannot be answered.
fm_sol_cap_has_owned_occupancy() {  # <id> <state-dir>
  local id=$1 state=$2 model registry occupancy config row_model
  registry=$state/$FM_SOL_REGISTRY_NAME
  # The owning home's own declaration decides whether it holds capped
  # occupancy at all: a home that declared no ceiling owns none, and a home
  # that narrowed its declaration no longer owns the models it dropped. The
  # stored rows stay as evidence either way.
  config=$(fm_sol_cap_config_dir "$state") || return 1
  fm_sol_cap_config "$config" || {
    printf '%s\n' "error: Sol ceiling unavailable: $FM_SOL_CAP_CONFIG_ERROR" >&2
    return 2
  }
  [ "$FM_SOL_CAP_ACTIVE" = 1 ] || return 1
  occupancy=$(awk -F'\t' -v id="$id" '$1 == id {print "pid:" $4; exit}' "$registry" 2>/dev/null || true)
  if [ -n "$occupancy" ]; then
    occupancy=${occupancy#pid:}
    # A row whose model the declaration no longer covers holds no capacity:
    # the count does not see that row either, so treating it as occupancy
    # would make the release path wait on the admission boundary for a
    # slot that does not exist.
    row_model=$(awk -F'\t' -v id="$id" '$1 == id {print $2; exit}' "$registry" 2>/dev/null || true)
    if [ -n "$row_model" ] && ! fm_sol_cap_model_capped "$row_model"; then
      return 1
    fi
    case "$occupancy" in
      # -1 is a confirmed stop and -3 a superseded incarnation: neither
      # holds a slot, exactly as the count treats them.
      -1 | -3) return 1 ;;
      -2 | 0 | '' | *[!0-9]*) return 0 ;;
    esac
    fm_pid_alive "$occupancy"
    return $?
  fi
  [ -f "$state/$id.meta" ] && [ ! -L "$state/$id.meta" ] || return 1
  model=$(awk -F= '$1 == "model" {sub(/^[^=]*=/, ""); print; exit}' "$state/$id.meta") || return 1
  fm_sol_cap_model_capped "$model"
}

fm_sol_cap_reconcile_local() {
  local id=$1 state=$2 meta backend target verdict absence owned
  meta=$state/$id.meta
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  owned=0
  fm_sol_cap_has_owned_occupancy "$id" "$state" || owned=$?
  [ "$owned" -ne 2 ] || return 1
  [ "$owned" -eq 0 ] || return 0
  backend=$(fm_backend_of_meta "$meta") || return 1
  target=$(fm_backend_target_of_meta "$meta") || return 1
  [ -n "$target" ] || return 0
  verdict=$(fm_backend_agent_state "$backend" "$target") || return 0
  if [ "$verdict" = missing ]; then
    absence=$(fm_control_endpoint_absence_verdict "$backend" "$target") || return 0
    case "${absence%%$'\t'*}" in
      gone) verdict=missing ;;
      dead) verdict=dead ;;
      *) return 0 ;;
    esac
  fi
  case "$verdict" in
    dead | missing) fm_sol_cap_promote "$id" remove "$state" ;;
  esac
}

fm_sol_cap_reconcile_remote() {
  local id=$1 state=$2 scripts=$3 remote_state owned
  owned=0
  fm_sol_cap_has_owned_occupancy "$id" "$state" || owned=$?
  [ "$owned" -ne 2 ] || return 1
  [ "$owned" -eq 0 ] || return 0
  remote_state=$("$scripts/fm-on.sh" "$id" fm-remote-secondmate-control.sh state "$id" </dev/null 2>/dev/null) || return 0
  remote_state=$(printf '%s\n' "$remote_state" | tail -1)
  case "$remote_state" in
    dead | missing) fm_sol_cap_promote "$id" remove "$state" ;;
  esac
}

# fm_sol_cap_admission_lock_path <state-dir>
# The shared admission boundary's lock directory, underneath the local root
# home's state directory. A caller that must present a route-record publication
# and the occupancy reconcile derived from it as one transition acquires this
# lock itself with fm_sol_cap_lock_acquire, then drives the locked core below,
# instead of doing either half of the transition outside the boundary.
fm_sol_cap_admission_lock_path() {  # <state-dir>
  local root
  root=$(fm_firstmate_root_home "$(fm_sol_cap_home "$1")") || return 1
  printf '%s/state/%s\n' "$root" "$FM_SOL_LOCK_NAME"
}

# fm_sol_cap_record_actual <id> <actual-model> <state-dir>
# The admission-locked reconcile of the model the endpoint's own record
# reports after an accepted remote launch. Sets FM_SOL_CAP_REFUSAL on failure.
fm_sol_cap_record_actual() {  # <id> <actual-model> <state-dir>
  local id=$1 model=$2 state=$3 lock rc=0 config owned
  FM_SOL_CAP_REFUSAL=
  config=$(fm_sol_cap_config_dir "$state") || return 1
  fm_sol_cap_config "$config" || {
    FM_SOL_CAP_REFUSAL="error: Sol ceiling unavailable: $FM_SOL_CAP_CONFIG_ERROR; the reported model of task $id could not be reconciled"
    return 1
  }
  [ "$FM_SOL_CAP_ACTIVE" = 1 ] || return 0
  if ! fm_sol_cap_model_capped "$model"; then
    owned=0
    fm_sol_cap_has_owned_occupancy "$id" "$state" || owned=$?
    [ "$owned" -ne 2 ] || {
      FM_SOL_CAP_REFUSAL="error: Sol ceiling unavailable: $FM_SOL_CAP_CONFIG_ERROR; the reported model of task $id could not be reconciled"
      return 1
    }
    [ "$owned" -eq 0 ] || return 0
  fi
  lock=$(fm_sol_cap_admission_lock_path "$state") || return 1
  fm_sol_cap_lock_acquire "$lock" "the reported model of task $id" || return 1
  fm_sol_cap_record_actual_locked "$@" || rc=$?
  fm_lock_release "$lock" || true
  return "$rc"
}

# fm_sol_cap_record_actual_locked <id> <actual-model> <state-dir>
# The locked core of fm_sol_cap_record_actual; requires the shared admission
# lock already held, so a publication-and-reconcile transition stays one step
# of the boundary. A capped report claims the task's live occupancy when no
# live or uncertain claim exists, and an uncapped report releases the task's
# capped claim. A live or uncertain claim keeps its own reconciliation
# semantics - it is never rewritten, so adopted claims stay recheckable and
# occupied claims keep their released shape only through proven stops. Sets
# FM_SOL_CAP_REFUSAL on failure.
fm_sol_cap_record_actual_locked() {  # <id> <actual-model> <state-dir>
  local id=$1 model=$2 state=$3 registry existing_pid existing_start existing_model
  FM_SOL_CAP_REFUSAL=
  if ! fm_sol_cap_model_capped "$model"; then
    fm_sol_cap_has_owned_occupancy "$id" "$state" || return 0
    fm_sol_cap_registry_promote "$id" remove "$state" || return 1
    return 0
  fi
  registry=$state/$FM_SOL_REGISTRY_NAME
  existing_pid=$(awk -F'\t' -v id="$id" '$1 == id {print $4; exit}' "$registry" 2>/dev/null || true)
  existing_start=$(awk -F'\t' -v id="$id" '$1 == id {print $3; exit}' "$registry" 2>/dev/null || true)
  existing_model=$(awk -F'\t' -v id="$id" '$1 == id {print $2; exit}' "$registry" 2>/dev/null || true)
  if fm_sol_cap_entry_live "$existing_start" "$existing_pid"; then
    if [ "$existing_model" != "$model" ]; then
      # The endpoint's own record names the model this session runs, so the
      # row must name it too. A row that kept a model the declaration no
      # longer covers would hold capacity the count never sees, and the
      # next admission would exceed the ceiling. The claim itself is
      # untouched: the same pid and the same start epoch.
      if ! fm_sol_cap_registry_claim "$registry" "$id" "$model" "$existing_start" "$existing_pid"; then
        FM_SOL_CAP_REFUSAL="error: Sol ceiling: the reported model of task $id could not be recorded in $registry; the confirmed route's record stands for the next admission to reconcile"
        return 1
      fi
    fi
    return 0
  fi
  fm_epoch_seconds_to FM_SOL_CAP_NOW
  if ! fm_sol_cap_registry_claim "$registry" "$id" "$model" "$FM_SOL_CAP_NOW" 0; then
    FM_SOL_CAP_REFUSAL="error: Sol ceiling: the reported model of task $id could not be recorded in $registry; the confirmed route's record stands for the next admission to reconcile"
    return 1
  fi
  return 0
}

fm_sol_cap_registry_promote() {
  local id=$1 pid=$2 state=$3 registry tmp stopped=0 recorded_model now config
  registry=$state/$FM_SOL_REGISTRY_NAME
  config=$(fm_sol_cap_config_dir "$state") || return 1
  fm_sol_cap_config "$config" || {
    echo "error: Sol ceiling unavailable: $FM_SOL_CAP_CONFIG_ERROR; the occupancy of task $id was retained rather than released against an undeclared ceiling" >&2
    return 1
  }
  if [ "$pid" = remove ] && [ -f "$state/$id.meta" ]; then
    recorded_model=$(awk -F= '$1 == "model" {sub(/^[^=]*=/, ""); print; exit}' "$state/$id.meta") || return 1
    fm_sol_cap_model_capped "$recorded_model" && stopped=1
  fi
  if [ "$stopped" = 1 ] &&
    { [ ! -f "$registry" ] || ! awk -F'\t' -v id="$id" '$1 == id {found=1; exit} END {exit !found}' "$registry"; }; then
    fm_epoch_seconds_to now
    fm_sol_cap_registry_claim "$registry" "$id" "$recorded_model" "$now" -1
    return $?
  fi
  [ -f "$registry" ] || return 0
  tmp=$registry.tmp.$$
  if ! awk -F'\t' -v OFS='\t' -v id="$id" -v pid="$pid" -v stopped="$stopped" '
    $1 == id { if (pid == "remove") { if (stopped) $4 = -1; else next } else $4 = pid }
    {print}
  ' "$registry" > "$tmp" || ! mv -- "$tmp" "$registry"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_sol_cap_promote() {
  local id=$1 pid=$2 state=$3 registry root lock rc=0 owned
  registry=$state/$FM_SOL_REGISTRY_NAME
  if [ "$pid" = remove ]; then
    owned=0
    fm_sol_cap_has_owned_occupancy "$id" "$state" || owned=$?
    [ "$owned" -ne 2 ] || return 1
    [ "$owned" -eq 0 ] || return 0
  else
    [ -f "$registry" ] || return 0
    awk -F'\t' -v id="$id" '$1 == id {found=1; exit} END {exit !found}' "$registry" || return 0
  fi
  root=$(fm_firstmate_root_home "$(fm_sol_cap_home "$state")") || return 1
  lock=$root/state/$FM_SOL_LOCK_NAME
  fm_sol_cap_lock_acquire "$lock" "the promotion of task $id" || return 1
  fm_sol_cap_registry_promote "$id" "$pid" "$state" || rc=$?
  fm_lock_release "$lock" || return 1
  return "$rc"
}

# fm_sol_cap_registry_prune <registry-file> <now>
fm_sol_cap_registry_prune() {  # <registry-file>
  local file=$1 tmp rc id model start pid row state
  [ -f "$file" ] && [ -r "$file" ] || return 0
  state=${file%/*}
  tmp=$file.tmp.prune.$$
  (
    while IFS= read -r row || [ -n "$row" ]; do
      IFS=$'\t' read -r id model start pid <<< "$row"
      [ -n "$id" ] || continue
      if [ ! -e "$state/$id.meta" ] && fm_sol_cap_entry_shape "$start" "$pid" &&
        ! fm_sol_cap_entry_live "$start" "$pid"; then
        continue
      fi
      printf '%s\n' "$row" || exit 1
    done < "$file"
  ) > "$tmp"
  rc=$?
  [ "$rc" -eq 0 ] || {
    rm -f -- "$tmp"
    echo "error: Sol ceiling: Sol registry $file could not be pruned" >&2
    return 1
  }
  mv -- "$tmp" "$file" || {
    rm -f -- "$tmp"
    echo "error: Sol ceiling: Sol registry $file could not be rewritten during pruning" >&2
    return 1
  }
  return 0
}

# --- CLI ---------------------------------------------------------------------
# Operator and test seam: drive the same contract from a fresh process, so a
# declaration or a refusal can be inspected and reproduced without sourcing.
# Requires FM_HOME to select the dispatching Firstmate home; the local-home
# walk resolves the rest. modes:
#   status <config-dir>
#                prints the declaration, or "inert" when none exists.
#   models <config-dir>
#                prints the declared exact model ids.
#   ceiling <config-dir>
#                prints the effective ceiling, or "inert" when none exists.
#   refuse-claim <id> <kind> <harness> <model> <config-dir> <state-dir>
#                prints "claimed" or the refusal, exits 0/1.
#   record-actual <id> <actual-model> <state-dir>
#                prints "recorded" or the refusal, exits 0/1.
#   run <id> <state-dir> <command> [args...]
#                transfers the reservation to this process, then execs command.

fm_sol_cap_cli() {
  local mode=$1
  case "$mode" in
  status)
    fm_sol_cap_config "${2:?params: status <config-dir>}" || {
      printf '%s\n' "$FM_SOL_CAP_CONFIG_ERROR" >&2
      return 1
    }
    if [ "$FM_SOL_CAP_ACTIVE" = 1 ]; then
      printf 'active max=%s ceiling=%s models=%s pattern=%s\n' \
        "$FM_SOL_CAP_MAX" "$FM_SOL_CAP" "$FM_SOL_CAP_MODELS" "$FM_SOL_CAP_PATTERN"
    else
      printf '%s\n' inert
    fi
    ;;
  models)
    fm_sol_cap_config "${2:?params: models <config-dir>}" || {
      printf '%s\n' "$FM_SOL_CAP_CONFIG_ERROR" >&2
      return 1
    }
    printf '%s\n' "$FM_SOL_CAP_MODELS"
    ;;
  ceiling)
    fm_sol_cap_config "${2:?params: ceiling <config-dir>}" || {
      printf '%s\n' "$FM_SOL_CAP_CONFIG_ERROR" >&2
      return 1
    }
    if [ "$FM_SOL_CAP_ACTIVE" = 1 ]; then
      printf '%s\n' "$FM_SOL_CAP"
    else
      printf '%s\n' inert
    fi
    ;;
  run)
    local id=$2 state=$3
    shift 3
    fm_sol_cap_promote "$id" "$$" "$state" || return 1
    exec "$@"
    ;;
  refuse-claim)
    [ "$#" -eq 7 ] || {
      echo "usage: fm-sol-cap-lib.sh refuse-claim <id> <kind> <harness> <model> <config-dir> <state-dir>" >&2
      return 2
    }
    fm_sol_cap_refuse_and_claim "$2" "$3" "$4" "$5" "$6" "$7" && {
      # "claimed" means a reservation row was written; "not-capped" means the
      # declaration does not cover that model, so the guard never applied.
      if [ "$FM_SOL_CLAIM_CREATED" = "$2" ]; then
        printf '%s\n' claimed
      else
        printf '%s\n' not-capped
      fi
      return 0
    }
    [ -z "$FM_SOL_CAP_REFUSAL" ] || printf '%s\n' "$FM_SOL_CAP_REFUSAL"
    return 1
    ;;
  record-actual)
    [ "$#" -eq 4 ] || {
      echo "usage: fm-sol-cap-lib.sh record-actual <id> <actual-model> <state-dir>" >&2
      return 2
    }
    fm_sol_cap_record_actual "$2" "$3" "$4" && {
      printf '%s\n' recorded
      return 0
    }
    [ -z "$FM_SOL_CAP_REFUSAL" ] || printf '%s\n' "$FM_SOL_CAP_REFUSAL"
    return 1
    ;;
  *)
    echo "unknown fm-sol-cap-lib.sh mode: $mode (try: status | models | ceiling | refuse-claim | record-actual)" >&2
    return 2
    ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if ! [ -n "${FM_HOME:-}" ]; then
    echo "error: fm-sol-cap-lib.sh needs FM_HOME to select the dispatching Firstmate home" >&2
    exit 2
  fi
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  # shellcheck disable=SC1091 # the CLI resolves its siblings at runtime.
  . "$(cd -- "$(dirname -- "$0")" && pwd)/fm-wake-lib.sh"
  # shellcheck disable=SC1091 # the CLI resolves its sibling at runtime.
  . "$(cd -- "$(dirname -- "$0")" && pwd)/fm-secondmate-registry-lib.sh"
  fm_sol_cap_cli "$@"
  exit $?
fi
