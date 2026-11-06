#!/usr/bin/env bash
# Home-local supervision tuning.
#
# The watcher's poll cadence and its escalation ceilings are home-local POLICY,
# not code policy: a home that wants fewer supervision turns must not need a
# code change to get them, and a shared template must not carry one home's
# cadence. This library reads config/supervision-tuning (local, gitignored) and
# exports the knobs it names, so bin/fm-watch.sh, bin/fm-supervise-daemon.sh
# and bin/fm-brief.sh all honour the same file.
#
# File format: one KEY=VALUE per line.
#   - blank lines and '#' comments are ignored (a '#' starts a comment anywhere)
#   - an unknown key is ignored
#   - a value must be a plain digit string; anything else is ignored
#   - nothing is evaluated as shell, so the file cannot execute anything
#   - an environment variable of the same name always WINS, so a one-off launch
#     override beats the file
#
# Keys:
#   wedge_max_escalations  consecutive idle escalations for one window before
#                           the cap publishes a single PERMANENTLY-WEDGED wake
#                           and silences that window until its cap horizon
#                           elapses (0 = no cap, the shipped default)
#   escalate_batch_secs    buffer window for batched escalation digests
#                           (0 = flush immediately)
#   idle_poll_secs         poll cadence while no work is in flight; the watcher
#                           still polls, only less often (0 = off)
#   stale_escalate_secs    idle seconds before a stale pane escalates
#   max_fix_rounds         validation fix rounds a task may spend before the
#                           remainder becomes follow-up work
#   brief_gate_policy      1 = include the validation gate-policy section in
#                           scaffolded ship briefs (0 = off, the shipped
#                           default; the shared brief stays captain-agnostic)
#
# Every knob defaults to the shipped behaviour when the file is absent, so a
# home that never writes this file behaves exactly as before.

# fm_supervision_tuning_int <value> <fallback> -> prints a validated integer.
fm_supervision_tuning_int() {
  local v=${1:-} fallback=${2:-0}
  case "$v" in
    ''|*[!0-9]*) printf '%s\n' "$fallback" ;;
    *) printf '%s\n' "$((10#$v))" ;;
  esac
}

# fm_supervision_tuning_load
# Read config/supervision-tuning and set the knobs it names. An environment
# variable of the same name is never overridden. Returns 0 always: a home that
# misconfigures its own tuning file still gets a working watcher on the
# shipped defaults.
fm_supervision_tuning_load() {
  local cfg line key val
  # A set -u caller with neither override nor FM_HOME set must not abort here:
  # the loader is sourced by every surface that reads the tuning file, and an
  # unset home simply means there is no tuning file to read.
  if [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
    cfg=$FM_CONFIG_OVERRIDE
  elif [ -n "${FM_HOME:-}" ]; then
    cfg=$FM_HOME/config
  else
    return 0
  fi
  # Same normalization fm-brief.sh applies before reading every other config
  # file: a relative override resolves against the launch cwd, so the tuning
  # file read here is the same one every consumer of the resolved path reads.
  case "$cfg" in
    /*) ;;
    *) cfg=$PWD/$cfg ;;
  esac
  cfg=$cfg/supervision-tuning
  [ -f "$cfg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    case "$val" in ''|*[!0-9]*) continue ;; esac
    # Normalize a leading-zero value (e.g. "090") to decimal before any caller
    # does Bash arithmetic with it: $((...)) would read it as invalid octal.
    val=$((10#$val))
    case "$key" in
      wedge_max_escalations)
        [ -n "${FM_WEDGE_MAX_ESCALATIONS:-}" ] || FM_WEDGE_MAX_ESCALATIONS=$val ;;
      escalate_batch_secs)
        [ -n "${FM_ESCALATE_BATCH_SECS:-}" ] || FM_ESCALATE_BATCH_SECS=$val ;;
      idle_poll_secs)
        [ -n "${FM_IDLE_POLL:-}" ] || FM_IDLE_POLL=$val ;;
      stale_escalate_secs)
        [ -n "${FM_STALE_ESCALATE_SECS:-}" ] || FM_STALE_ESCALATE_SECS=$val ;;
      max_fix_rounds)
        [ -n "${FM_MAX_FIX_ROUNDS:-}" ] || FM_MAX_FIX_ROUNDS=$val ;;
      brief_gate_policy)
        [ -n "${FM_BRIEF_GATE_POLICY:-}" ] || FM_BRIEF_GATE_POLICY=$val ;;
      *) continue ;;
    esac
  done < "$cfg"
  return 0
}
