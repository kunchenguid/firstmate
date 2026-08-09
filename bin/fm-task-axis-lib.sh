#!/usr/bin/env bash
# Single owner of a task's THREE identity axes, recorded in state/<task-id>.meta.
# One `kind=` field used to carry all three facts at once, so every consumer
# reconstructed the axis it cared about from a value that also encoded the two
# it did not:
#
#   role=        crew | secondmate                     WHO the worker is.
#                Population membership: a secondmate is a persistent direct
#                report with its own home, a crew worker is a task worker.
#                Consumers that ask "is this a crew task at all" want this axis
#                and nothing else.
#   deliverable= scout | ship                          WHAT the task produces.
#                A scout produces a report and never a PR; a ship produces a
#                project change through its delivery mode. Consumers that gate
#                the validation pipeline or the scout teardown carve-out want
#                this axis.
#   stage=       commissioned | reflagged | delivered  WHERE the task stands.
#                commissioned at spawn, reflagged when bin/fm-reflag.sh changes
#                a scout's contract to a ship's, delivered once its work landed.
#                A field a transition MUTATES is a state, not a type, which is
#                why the old field could not hold it.
#                `delivered` is DECLARED BUT NOT YET WRITTEN by any fleet path.
#                Stamping it belongs after a confirmed landing, inside
#                bin/fm-pr-merge.sh's private metadata rewrite, whose ordering,
#                device, and single-link invariants that path owns - so the
#                writer is a deliberate follow-up rather than something bolted
#                on beside this split. Read it as "no path has reported this
#                task landed", never as "this task did not land".
#
# The axes are ORTHOGONAL: no consumer may infer one from another. A secondmate
# records deliverable=ship because its work lands as project change, not because
# role and deliverable are linked; a future role value would not change that.
#
# The role axis is the home for every role-typed fact about a task, including a
# requested agent role. Adding one is a new value or field ON this axis, never a
# fourth dimension beside it - reconstructing meaning from an overloaded field is
# exactly what the split removed.
#
# `kind=` is a DEPRECATED ALIAS during the migration, dual-written by every
# writer and still the derivation source for a record that predates the split.
# docs/vocabulary-collisions.md owns its retirement condition. Until then this
# file refuses a record whose `kind=` disagrees with its explicit axes rather
# than silently picking one, so a stale writer that flips the old field alone
# cannot desynchronize a task's identity.
#
# Sourced by every meta writer (bin/fm-spawn.sh, bin/fm-reflag.sh) and every
# consumer that branches on a task's identity. Depends on bin/fm-backend.sh for
# fm_meta_get.
#
# Reading an axis:
#   fm_task_role <meta>          crew | secondmate
#   fm_task_deliverable <meta>   scout | ship
#   fm_task_stage <meta>         commissioned | reflagged | delivered
# Each prints the explicit field when the record carries it, and otherwise the
# deterministic derivation below. An absent record reads as the spawn default,
# matching what every consumer already assumed for an absent `kind=`.
#
# Writing:
#   fm_task_axes_emit <kind> [stage]   the meta lines for a dual-writing writer
#   fm_task_axes_backfill <meta>       derive the axes into an existing record
#
# Checking:
#   fm_task_axes_conflict <meta>       0 when the alias disagrees with an axis

# The one meta reader stays bin/fm-backend.sh's fm_meta_get rather than being
# respelled here. Most callers already source that file; the guard is for a
# caller that reaches the axes through a library instead (bin/fm-ff-lib.sh), so
# this file works wherever it is sourced without a second copy of the read.
# fm-backend.sh's own top-level assignments all defer to an already-set value,
# so sourcing it after FM_ROOT and FM_HOME are set changes nothing.
if ! declare -F fm_meta_get >/dev/null 2>&1; then
  # shellcheck source=bin/fm-backend.sh disable=SC1091
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-backend.sh"
fi

# Derivation from the deprecated alias. This table is the whole migration
# contract for records written before the split, and it is total over the three
# values the old field ever took:
#
#   kind=secondmate -> role=secondmate deliverable=ship
#   kind=ship       -> role=crew       deliverable=ship
#   kind=scout      -> role=crew       deliverable=scout
#
# STAGE IS NOT DERIVED FROM THE ALIAS, and this is a real limitation rather
# than an oversight: `kind=ship` was written both by a spawn and by the
# scout-to-ship operation, so a record predating the split cannot distinguish a
# commissioned ship from a reflagged one. Backfill records the lower-information
# value, `commissioned`, and the stage axis is authoritative only for a task
# reflagged after the split. Deriving anything else would invent a fact the old
# field never carried.

FM_TASK_ROLE_DEFAULT=crew
FM_TASK_DELIVERABLE_DEFAULT=ship
FM_TASK_STAGE_DEFAULT=commissioned

fm_task_role_valid() {  # <value>
  case "${1-}" in crew|secondmate) return 0 ;; *) return 1 ;; esac
}

fm_task_deliverable_valid() {  # <value>
  case "${1-}" in scout|ship) return 0 ;; *) return 1 ;; esac
}

fm_task_stage_valid() {  # <value>
  case "${1-}" in commissioned|reflagged|delivered) return 0 ;; *) return 1 ;; esac
}

# fm_task_role_of_kind / fm_task_deliverable_of_kind: the derivation table
# above, applied to one alias value. An empty or unrecognized alias derives the
# spawn default, exactly as every consumer already defaulted an absent `kind=`.
fm_task_role_of_kind() {  # <kind>
  case "${1-}" in
    secondmate) printf 'secondmate' ;;
    *) printf '%s' "$FM_TASK_ROLE_DEFAULT" ;;
  esac
}

fm_task_deliverable_of_kind() {  # <kind>
  case "${1-}" in
    scout) printf 'scout' ;;
    *) printf '%s' "$FM_TASK_DELIVERABLE_DEFAULT" ;;
  esac
}

fm_task_role() {  # <meta-file>
  local v
  v=$(fm_meta_get "${1-}" role)
  if fm_task_role_valid "$v"; then printf '%s' "$v"; return 0; fi
  fm_task_role_of_kind "$(fm_meta_get "${1-}" kind)"
}

fm_task_deliverable() {  # <meta-file>
  local v
  v=$(fm_meta_get "${1-}" deliverable)
  if fm_task_deliverable_valid "$v"; then printf '%s' "$v"; return 0; fi
  fm_task_deliverable_of_kind "$(fm_meta_get "${1-}" kind)"
}

fm_task_stage() {  # <meta-file>
  local v
  v=$(fm_meta_get "${1-}" stage)
  if fm_task_stage_valid "$v"; then printf '%s' "$v"; return 0; fi
  printf '%s' "$FM_TASK_STAGE_DEFAULT"
}

# fm_task_axes_emit: the axis lines a dual-writing meta writer appends beside
# its own `kind=` line, so one writer never spells the derivation itself.
# <stage> defaults to the spawn stage; pass it explicitly at a transition.
fm_task_axes_emit() {  # <kind> [stage]
  local kind=${1-} stage=${2:-$FM_TASK_STAGE_DEFAULT}
  fm_task_stage_valid "$stage" || stage=$FM_TASK_STAGE_DEFAULT
  printf 'role=%s\n' "$(fm_task_role_of_kind "$kind")"
  printf 'deliverable=%s\n' "$(fm_task_deliverable_of_kind "$kind")"
  printf 'stage=%s\n' "$stage"
}

# fm_task_axes_conflict: 0 when the record carries BOTH the deprecated alias
# and an explicit axis that the alias does not derive to. That state means a
# writer changed one and not the other - the exact failure the dual-write
# window exists to catch - and every caller treats it as refusal rather than
# resolving it, because either value could be the stale one. Sets
# FM_TASK_AXES_CONFLICT to a one-line description.
FM_TASK_AXES_CONFLICT=''
fm_task_axes_conflict() {  # <meta-file>
  local meta=${1-} kind role deliverable
  FM_TASK_AXES_CONFLICT=''
  [ -f "$meta" ] || return 1
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || return 1
  role=$(fm_meta_get "$meta" role)
  deliverable=$(fm_meta_get "$meta" deliverable)
  if fm_task_role_valid "$role" && [ "$role" != "$(fm_task_role_of_kind "$kind")" ]; then
    FM_TASK_AXES_CONFLICT="kind=$kind derives role=$(fm_task_role_of_kind "$kind") but the record says role=$role"
    return 0
  fi
  if fm_task_deliverable_valid "$deliverable" \
    && [ "$deliverable" != "$(fm_task_deliverable_of_kind "$kind")" ]; then
    FM_TASK_AXES_CONFLICT="kind=$kind derives deliverable=$(fm_task_deliverable_of_kind "$kind") but the record says deliverable=$deliverable"
    return 0
  fi
  return 1
}

# fm_task_axes_write_before_pr: rewrite <meta> so <lines> land BEFORE its first
# `pr=` line, keeping every other line in order.
#
# The position is a hard contract, not tidiness. A task's metadata doubles as PR
# identity, and fm_pr_metadata_identity_parse (bin/fm-pr-lib.sh) refuses any
# unrecognized key that appears AFTER `pr=` - which is what keeps a tampered
# record from smuggling a second identity past an armed merge poll. Appending an
# axis to the end of a record carrying `pr=` therefore does not merely look
# untidy: it invalidates the record, and the watcher stops honoring that task's
# poll. A record with no `pr=` line simply gets the lines appended.
fm_task_axes_write_before_pr() {  # <meta-file> <line>...
  local meta=$1 tmp line seen_pr=0
  shift
  tmp="$meta.axis.$$"
  {
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        pr=*)
          if [ "$seen_pr" -eq 0 ]; then
            seen_pr=1
            printf '%s\n' "$@"
          fi
          ;;
      esac
      printf '%s\n' "$line"
    done < "$meta"
    [ "$seen_pr" -eq 1 ] || printf '%s\n' "$@"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$meta" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# fm_task_axes_backfill: derive the axes INTO an existing record, forward-only
# and idempotent. Never rewrites an axis the record already states, never
# rewrites the alias, and never touches any other field - a record it has
# already converged through is left byte-identical, so repeated sweeps are
# free. Refuses a conflicted record rather than papering over it. Returns 0
# when the record is converged (whether or not this call wrote), 1 on refusal
# or write failure.
fm_task_axes_backfill() {  # <meta-file>
  local meta=${1-} kind
  local -a add=()
  [ -f "$meta" ] || return 1
  if fm_task_axes_conflict "$meta"; then
    printf 'fm_task_axes_backfill: refusing conflicted record %s: %s\n' \
      "$meta" "$FM_TASK_AXES_CONFLICT" >&2
    return 1
  fi
  kind=$(fm_meta_get "$meta" kind)
  fm_task_role_valid "$(fm_meta_get "$meta" role)" \
    || add+=("role=$(fm_task_role_of_kind "$kind")")
  fm_task_deliverable_valid "$(fm_meta_get "$meta" deliverable)" \
    || add+=("deliverable=$(fm_task_deliverable_of_kind "$kind")")
  fm_task_stage_valid "$(fm_meta_get "$meta" stage)" \
    || add+=("stage=$FM_TASK_STAGE_DEFAULT")
  [ "${#add[@]}" -gt 0 ] || return 0
  fm_task_axes_write_before_pr "$meta" "${add[@]}"
}
