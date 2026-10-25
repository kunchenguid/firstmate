# shellcheck shell=bash disable=SC2034
# fm-parked-homes-lib.sh - the shared parked-home reader. Source only.
#
# The captain parks a secondmate home by listing its home id, one per line, in
# the supervising home's config/parked-homes ('#' comments and blank lines
# ignored). A parked home gets no message, steer, answer, nudge or relaunch,
# and no config push. Every supervision producer gates on this one reader
# instead of carrying its own copy of the rule.
#
# Predicates (source-only; no side effects, safe to source twice):
#   fm_parked_homes_file              -> prints the parked-homes config path
#   fm_parked_home <id>               -> 0 when <id> is parked
#   fm_parked_meta_id <meta> [task]   -> prints the home id a task meta
#                                        belongs to (empty when unknown)
#   fm_parked_meta <meta> [task]      -> 0 when that meta's home is parked
#   fm_parked_refuse_meta <meta> <task> <action>
#                                      -> reports an attempted action and returns 1
#                                      when parked; returns 0 otherwise
#   fm_parked_skip_meta <meta> <task> <action>
#                                      -> reports an existing skip (if any) and
#                                      returns 0 when parked; returns 1 otherwise
#
# Home-id resolution (fm_parked_meta_id): a meta belongs to a parked home only
# when its kind is secondmate. A local secondmate's home path carries
# .fm-secondmate-home with the id; a remote secondmate's home lives on its
# host, so the recorded task id stands in. Crewmate and lead lanes in this
# home are never parked, whatever their task id spells.

fm_parked_homes_file() {
  # FM_CONFIG_OVERRIDE is the config directory itself (the fork-wide override
  # convention); FM_HOME is the home, so its config lives at $FM_HOME/config.
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-${FM_HOME:-}/config}/parked-homes"
}

fm_parked_home() {  # <id> -> 0 when parked
  local id=$1 file line trimmed
  [ -n "$id" ] || return 1
  file=$(fm_parked_homes_file) || return 1
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%\#*}
    trimmed=${line#"${line%%[![:space:]]*}"}
    trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
    [ "$trimmed" = "$id" ] && return 0
  done < "$file"
  return 1
}

fm_parked_meta_id() {  # <meta-file> [task-id] -> home id on stdout
  local meta=$1 task=${2:-} kind='' home='' id='' line
  [ -f "$meta" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      kind=*) kind=${line#kind=} ;;
      home=*) home=${line#home=} ;;
    esac
  done < "$meta"
  [ "$kind" = secondmate ] || return 1
  if [ -n "$home" ] && [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ]; then
    id=$(tr -d '[:space:]' < "$home/.fm-secondmate-home" 2>/dev/null)
  fi
  [ -n "$id" ] || id=$task
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

fm_parked_meta() {  # <meta-file> [task-id] -> 0 when that home is parked
  local id
  id=$(fm_parked_meta_id "$@") || return 1
  fm_parked_home "$id"
}

fm_parked_refuse_meta() {  # <meta> <task> <send|relaunch>
  local meta=$1 task=$2 action=$3
  fm_parked_meta "$meta" "$task" || return 0
  case "$action" in
    send) printf 'error: nothing sent to %s: its home is parked (config/parked-homes); a parked home gets no message, steer, answer or nudge\n' "${task:+fm-$task}" >&2 ;;
    relaunch) printf 'error: relaunch refused for %s: its home is parked (config/parked-homes); a parked home gets no relaunch\n' "$task" >&2 ;;
    *) return 2 ;;
  esac
  return 1
}

fm_parked_skip_meta() {  # <meta> <task> <action>
  local meta=$1 task=$2 action=$3
  fm_parked_meta "$meta" "$task" || return 1
  case "$action" in
    config-reread) echo "CONFIG_REREAD: secondmate $task: skipped - its home is parked (config/parked-homes)" ;;
    sync) echo "SECONDMATE_SYNC: secondmate $task: skipped - its home is parked (config/parked-homes)" ;;
    bootstrap-liveness) echo "SECONDMATE_LIVENESS: secondmate $task: skipped: its home is parked (config/parked-homes)" ;;
    config-push) printf 'secondmate %s: skipped - its home is parked (config/parked-homes)\n' "$task" ;;
    model-outage|pending-reply|wake-doorbell) : ;;
    reconcile) printf 'skipped: %s parked\n' "$task" ;;
    restart) printf 'parked: %s: its home is parked (config/parked-homes); the restart pass skipped it\n' "$task" ;;
    watch-wake-stall|watch-liveness) : ;;
    *) return 2 ;;
  esac
  return 0
}
