#!/usr/bin/env bash
# fm-context-ceiling-lib.sh - the conversation size at which a launched worker,
# scout, or secondmate is summarized by its own tool, instead of at the tool's
# own maximum.
#
# Sourced, never executed. This file is the single owner of the home setting's
# format, of the per-spawn value's grammar, of the precedence between them, and
# of which worker tools a ceiling is verified for. docs/configuration.md
# "Context ceiling" is the operator reference; bin/fm-spawn.sh owns where each
# tool's launch carries the value.
#
# WHY. Every model call re-reads the whole conversation so far, so a call late in
# a long session costs several times one near its start. Summarizing at a lower
# size roughly halves the context those late calls re-read; it also loses
# detail, which is why the size is a setting per kind of task.
#
# THE HOME SETTING (config/context-ceiling). Absent means no ceiling: every tool
# keeps its own default and every launch stays byte-identical. A present file,
# even an empty one, sets a ceiling for both kinds; its optional lines are
#   worker=<value>       ship and scout launches (default 250000)
#   secondmate=<value>   secondmate launches (default 250000)
# Blank lines and lines starting with # are ignored. Any other line, a repeated
# key, or an unusable value makes the file unreadable, and fm_context_ceiling_
# resolve then fails with FM_CONTEXT_CEILING_ERROR set so the spawn refuses
# rather than guessing the size that was meant.
#
# A VALUE is either a whole number of tokens from 20000 through 10000000, or
# `off`, which means no ceiling (the tool's own default). The lower bound keeps
# a typo from summarizing a worker before it has read its brief.
#
# THE PER-SPAWN VALUE. bin/fm-spawn.sh --context-ceiling <value> carries the
# value a crew-dispatch profile's `context_ceiling` field selects for one kind
# of task, so a rule may ask for a larger ceiling or for `off` (a very large
# window) where the task needs it.
#
# PRECEDENCE, highest first: the per-spawn value; on a relaunch, the value the
# task recorded at its spawn; the home setting's line for the launch kind;
# otherwise no ceiling.
#
# COVERED TOOLS. A ceiling is applied only where a per-launch setting was
# verified to move the tool's summarizing point:
#   claude  the `autoCompactWindow` settings key, carried in the launch's own
#           --settings value (verified with `/context`, which reports the
#           window as the ceiling, Claude Code 2.1.325)
#   codex   the `model_auto_compact_token_limit` config key, carried as a
#           launch `-c` override (verified by a compaction at that size,
#           codex-cli 0.169.0)
# Every other tool is not covered: the spawn records the value with
# context_ceiling_applied=no and prints one notice, and the tool keeps its own
# default. tests/fm-context-ceiling-live.test.sh is the live check that
# refreshes this list.

FM_CONTEXT_CEILING_DEFAULT=250000
FM_CONTEXT_CEILING_MIN=20000
FM_CONTEXT_CEILING_MAX=10000000
FM_CONTEXT_CEILING_ERROR=
FM_CONTEXT_CEILING_VALUE=

# fm_context_ceiling_valid <value> - true for `off` or an in-range token count.
fm_context_ceiling_valid() {
  local v=${1-}
  [ "$v" = off ] && return 0
  case "$v" in
  '' | *[!0-9]* | 0*) return 1 ;;
  esac
  [ "${#v}" -le 8 ] || return 1
  [ "$v" -ge "$FM_CONTEXT_CEILING_MIN" ] && [ "$v" -le "$FM_CONTEXT_CEILING_MAX" ]
}

# fm_context_ceiling_kind_key <kind> - the home-setting key for a launch kind.
fm_context_ceiling_kind_key() {
  case "${1-}" in
  secondmate) printf 'secondmate' ;;
  *) printf 'worker' ;;
  esac
}

# fm_context_ceiling_config_value <config-dir> <kind>
# Sets FM_CONTEXT_CEILING_VALUE to the home setting's value for <kind>: empty
# when the file is absent, otherwise `off` or a token count. Returns 1 with
# FM_CONTEXT_CEILING_ERROR set when the file is unreadable. Call it directly,
# never in a command substitution, so the error reaches the caller.
fm_context_ceiling_config_value() {
  local config=$1 kind=$2 file key line k v seen=' ' value=
  FM_CONTEXT_CEILING_ERROR=
  FM_CONTEXT_CEILING_VALUE=
  file="$config/context-ceiling"
  [ -e "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_CONTEXT_CEILING_ERROR="config/context-ceiling is not a readable file"
    return 1
  fi
  key=$(fm_context_ceiling_kind_key "$kind")
  value=$FM_CONTEXT_CEILING_DEFAULT
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
    '' | '#'*) continue ;;
    esac
    case "$line" in
    worker=* | secondmate=*) ;;
    *)
      FM_CONTEXT_CEILING_ERROR="config/context-ceiling: unknown line '$line' (expected worker=<tokens|off> or secondmate=<tokens|off>)"
      return 1
      ;;
    esac
    k=${line%%=*}
    v=${line#*=}
    case "$seen" in
    *" $k "*)
      FM_CONTEXT_CEILING_ERROR="config/context-ceiling: $k is set twice"
      return 1
      ;;
    esac
    seen="$seen$k "
    if ! fm_context_ceiling_valid "$v"; then
      FM_CONTEXT_CEILING_ERROR="config/context-ceiling: $k=$v is not off or a token count from $FM_CONTEXT_CEILING_MIN through $FM_CONTEXT_CEILING_MAX"
      return 1
    fi
    [ "$k" != "$key" ] || value=$v
  done <"$file"
  FM_CONTEXT_CEILING_VALUE=$value
}

# fm_context_ceiling_resolve <config-dir> <kind> <flag-set 0|1> <flag-value> <recorded-value>
# Sets FM_CONTEXT_CEILING_VALUE to the effective value under the precedence
# above: empty when nothing applies (absent setting, nothing requested), else
# `off` or a count. Returns 1 with FM_CONTEXT_CEILING_ERROR set on an unusable
# flag, record, or home setting. Call it directly, never in a substitution.
fm_context_ceiling_resolve() {
  local config=$1 kind=$2 flag_set=$3 flag=$4 recorded=$5
  FM_CONTEXT_CEILING_ERROR=
  FM_CONTEXT_CEILING_VALUE=
  if [ "$flag_set" = 1 ]; then
    if ! fm_context_ceiling_valid "$flag"; then
      FM_CONTEXT_CEILING_ERROR="--context-ceiling must be off or a token count from $FM_CONTEXT_CEILING_MIN through $FM_CONTEXT_CEILING_MAX (got '$flag')"
      return 1
    fi
    FM_CONTEXT_CEILING_VALUE=$flag
    return 0
  fi
  if [ -n "$recorded" ]; then
    if ! fm_context_ceiling_valid "$recorded"; then
      FM_CONTEXT_CEILING_ERROR="the task record's context_ceiling=$recorded is unusable; pass --context-ceiling to choose one"
      return 1
    fi
    FM_CONTEXT_CEILING_VALUE=$recorded
    return 0
  fi
  fm_context_ceiling_config_value "$config" "$kind"
}

# fm_context_ceiling_covered <harness> - true for a tool with a verified
# per-launch ceiling (COVERED TOOLS above).
fm_context_ceiling_covered() {
  case "${1-}" in
  claude | codex) return 0 ;;
  esac
  return 1
}
