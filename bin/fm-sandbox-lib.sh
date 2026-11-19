#!/usr/bin/env bash
# shellcheck shell=bash
# fm-sandbox-lib.sh - the worker sandbox seam: config/sandbox grammar, profile
# resolution, and the per-task host-side pieces bin/fm-spawn.sh needs to wrap a
# worker in an operator-supplied sandbox wrapper command.
#
# One owner of the config/sandbox GRAMMAR and RESOLUTION. docs/configuration.md
# "Worker sandbox (config/sandbox)" is the operator reference, bin/fm-spawn.sh
# owns where the seam runs and the task binds it passes, and
# bin/fm-sandbox-relay.sh owns the host-side busy relay this library installs.
# Firstmate ships no sandbox of its own: the wrapper and what a profile isolates
# belong to the operator.
#
# config/sandbox (local, gitignored; absent = no sandbox, today's behavior).
# One setting per line; blank lines and lines beginning with # are ignored;
# every key may appear once:
#   wrapper=<command>       the operator's wrapper: an absolute path, or a bare
#                           name looked up on PATH; required for any profile to apply
#   enforce=off|on|strict   default on when the file exists
#   default=<profile>       profile for any ship or scout no narrower line maps
#   project:<name>=<profile>  <name> is the registered project name (the basename
#                           of its clone directory)
#   kind:ship=<profile>, kind:scout=<profile>
# A profile name is the wrapper's own: [A-Za-z0-9][A-Za-z0-9._-]*; the profile's
# content belongs to the wrapper, never here. Resolution order: explicit
# --sandbox <profile>, then project:, then kind:, then default. Secondmates are
# never mapped.
# enforce=off     mappings are inactive (a kill switch that keeps them on file);
#                 an explicit --sandbox <profile> still applies and is enforced.
# enforce=on      a mapped profile applies and a spawn REFUSES when it cannot be
#                 applied; --sandbox off waives it for one spawn.
# enforce=strict  as on, and a ship or scout with no resolvable profile REFUSES;
#                 --sandbox off is refused.
#
# Wrapper contract consumed:
#   WRAPPER --profile NAME --worktree DIR [--rw|--rw-create|--ro PATH]...
#           [--env NAME]... --host-helper EXECUTABLE [--dry-run] -- COMMAND...
# --dry-run validates the profile and flags, then exits 0 without starting
# COMMAND or minting anything; a non-zero exit means the wrapper cannot apply
# the profile. --host-helper takes ONE executable path, no arguments, and runs
# it as a child with the wrapper's own lifecycle (ends with the worker, also on
# SIGKILL of the launcher). Passing a path rather than a command line holds
# under either way the wrapper may parse it.

# fm_sandbox_profile_valid <name>
fm_sandbox_profile_valid() {
  case "${1:-}" in
  '' | [!A-Za-z0-9]* | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# fm_sandbox_name_valid <name>: a registered project name (clone directory basename).
fm_sandbox_name_valid() {
  case "${1:-}" in
  '' | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# fm_sandbox_config_load <config-dir>
# Parses <config-dir>/sandbox into FM_SANDBOX_PRESENT (0|1), FM_SANDBOX_ENFORCE
# (off|on|strict), FM_SANDBOX_WRAPPER, FM_SANDBOX_DEFAULT, FM_SANDBOX_PROJECTS and
# FM_SANDBOX_KINDS (newline-separated key=profile). A malformed file prints one
# refusal and returns 1, so a typo never silently launches a worker unsandboxed.
# These globals are the library's outputs, read by bin/fm-spawn.sh.
# shellcheck disable=SC2034
fm_sandbox_config_load() {
  local file=$1/sandbox line key val n=0 seen=' ' present
  FM_SANDBOX_PRESENT=0
  FM_SANDBOX_ENFORCE=on
  FM_SANDBOX_WRAPPER=
  FM_SANDBOX_DEFAULT=
  FM_SANDBOX_PROJECTS=
  FM_SANDBOX_KINDS=
  # fm_config_source_present (bin/fm-config-inherit-lib.sh, sourced by the
  # caller) refuses a path inspection error instead of reading it as absent.
  present=$(fm_config_source_present "$file") || return 1
  [ "$present" = 1 ] || return 0
  if [ ! -f "$file" ] || [ -L "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/sandbox must be a readable regular file" >&2
    return 1
  fi
  FM_SANDBOX_PRESENT=1
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in '' | '#'*) continue ;; esac
    case "$line" in
    *=*) ;;
    *)
      echo "error: config/sandbox line $n is not <key>=<value>: $line" >&2
      return 1
      ;;
    esac
    key=${line%%=*}
    val=${line#*=}
    case "$seen" in
    *" $key "*)
      echo "error: config/sandbox sets '$key' twice (line $n)" >&2
      return 1
      ;;
    esac
    seen="$seen$key "
    case "$key" in
    wrapper)
      case "$val" in
      '' | *[[:space:]]*)
        echo "error: config/sandbox wrapper must be one command name or absolute path without whitespace (line $n)" >&2
        return 1
        ;;
      esac
      FM_SANDBOX_WRAPPER=$val
      ;;
    enforce)
      case "$val" in
      off | on | strict) FM_SANDBOX_ENFORCE=$val ;;
      *)
        echo "error: config/sandbox enforce must be off, on or strict (line $n: '$val')" >&2
        return 1
        ;;
      esac
      ;;
    default)
      fm_sandbox_profile_valid "$val" || {
        echo "error: config/sandbox default names an invalid profile (line $n: '$val')" >&2
        return 1
      }
      FM_SANDBOX_DEFAULT=$val
      ;;
    project:*)
      if ! fm_sandbox_name_valid "${key#project:}" || ! fm_sandbox_profile_valid "$val"; then
        echo "error: config/sandbox line $n needs project:<name>=<profile> with simple names: $line" >&2
        return 1
      fi
      FM_SANDBOX_PROJECTS="$FM_SANDBOX_PROJECTS$key=$val"$'\n'
      ;;
    kind:ship | kind:scout)
      fm_sandbox_profile_valid "$val" || {
        echo "error: config/sandbox $key names an invalid profile (line $n: '$val')" >&2
        return 1
      }
      FM_SANDBOX_KINDS="$FM_SANDBOX_KINDS$key=$val"$'\n'
      ;;
    kind:*)
      echo "error: config/sandbox maps only kind:ship and kind:scout; secondmates never run sandboxed (line $n)" >&2
      return 1
      ;;
    *)
      echo "error: config/sandbox has an unknown key '$key' (line $n)" >&2
      return 1
      ;;
    esac
  done <"$file"
  return 0
}

# fm_sandbox_lookup <kind> <project-name>
# Prints the mapped profile (project, then kind, then default), or nothing.
fm_sandbox_lookup() {
  local kind=$1 project=$2 line
  while IFS= read -r line; do
    [ "${line%%=*}" = "project:$project" ] && { printf '%s' "${line#*=}"; return 0; }
  done <<EOF
$FM_SANDBOX_PROJECTS
EOF
  while IFS= read -r line; do
    [ "${line%%=*}" = "kind:$kind" ] && { printf '%s' "${line#*=}"; return 0; }
  done <<EOF
$FM_SANDBOX_KINDS
EOF
  printf '%s' "$FM_SANDBOX_DEFAULT"
}

# fm_sandbox_wrapper_ready <profile> <probe-worktree>
# Prints the absolute path of the config/sandbox wrapper when it accepts this
# profile and --host-helper, else prints a one-line reason on stderr and fails.
# The probe is the wrapper's own --dry-run: it mints and binds nothing. A bare
# wrapper name is resolved on PATH here, so the launch text carries the absolute
# path and does not depend on the pane's PATH.
fm_sandbox_wrapper_ready() {
  local profile=$1 worktree=$2 bin true_bin
  bin=$FM_SANDBOX_WRAPPER
  if [ -z "$bin" ]; then
    echo "config/sandbox names no wrapper (add wrapper=<command>)" >&2
    return 1
  fi
  case "$bin" in
  /*) ;;
  */*)
    echo "config/sandbox wrapper '$bin' must be an absolute path or a bare command name" >&2
    return 1
    ;;
  *) bin=$(type -P "$bin" 2>/dev/null) || bin= ;;
  esac
  if [ -z "$bin" ] || [ ! -x "$bin" ]; then
    echo "the sandbox wrapper '$FM_SANDBOX_WRAPPER' is not installed (not executable at '${bin:-PATH}')" >&2
    return 1
  fi
  true_bin=$(type -P true 2>/dev/null) || true_bin=/bin/true
  "$bin" --profile "$profile" --worktree "$worktree" --host-helper "$true_bin" --dry-run -- true >/dev/null 2>&1 || {
    echo "the sandbox wrapper '$bin' does not accept --profile $profile with --host-helper (profile unknown or wrapper too old)" >&2
    return 1
  }
  printf '%s' "$bin"
}

# fm_sandbox_sq: single-quote one value for the launch text.
fm_sandbox_sq() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# fm_sandbox_path_plain <path>: the helper path travels as one word, so it may
# carry no whitespace, quote or shell metacharacter, whichever way the wrapper
# parses it.
fm_sandbox_path_plain() {
  case "$1" in
  /*) ;;
  *) return 1 ;;
  esac
  case "$1" in
  *[!A-Za-z0-9._/+:@%=,-]*) return 1 ;;
  esac
  return 0
}

# fm_sandbox_events_dir <state-real> <id>: the relay spool, the ONLY writable
# path the sandbox gets under state/.
fm_sandbox_events_dir() {
  printf '%s/%s.sbx/events' "$1" "$2"
}

# fm_sandbox_prepare_task <state-real> <id> <gen> <fm-root>
# Creates state/<id>.sbx/{events/,inflight/,relay-helper} for this incarnation and prints
# the helper path. A relaunch reaches here with the previous incarnation's files
# on disk: the old relay is gone with its worker, so its spool is emptied and
# the helper is rewritten with the new busy gen. The sandbox sees only events/.
fm_sandbox_prepare_task() {
  local state=$1 id=$2 gen=$3 root=$4 sbx events helper tmp
  sbx="$state/$id.sbx"
  events=$(fm_sandbox_events_dir "$state" "$id")
  helper="$sbx/relay-helper"
  fm_sandbox_path_plain "$helper" || {
    echo "error: sandbox helper path '$helper' carries characters the wrapper cannot take as one word; move the home to a plain path" >&2
    return 1
  }
  (umask 077 && mkdir -p "$events" "$sbx/inflight") || return 1
  chmod 700 "$sbx" "$events" "$sbx/inflight" || return 1
  find "$events" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  tmp="$sbx/.relay-helper.$$"
  (
    umask 077
    {
      printf '#!/bin/sh\n'
      printf 'exec %s run --state %s --id %s --gen %s --events %s\n' \
        "$(fm_sandbox_sq "$root/bin/fm-sandbox-relay.sh")" "$(fm_sandbox_sq "$state")" \
        "$(fm_sandbox_sq "$id")" "$(fm_sandbox_sq "$gen")" "$(fm_sandbox_sq "$events")"
    } >"$tmp"
  ) || return 1
  chmod 700 "$tmp" && mv -f "$tmp" "$helper" || return 1
  printf '%s' "$helper"
}
