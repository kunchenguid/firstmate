# shellcheck shell=bash
# Shared tasks-axi backend selection and compatibility probe for bootstrap,
# teardown, and secondmate backlog handoff.
# Usage: . bin/fm-tasks-axi-lib.sh
#
# Compatible means tasks-axi --version reports FM_TASKS_AXI_MIN or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs.
# FM_TASKS_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
# The feature probes are a separate concern and stay as defense in depth for
# stripped or forked builds that advertise a current version without those flags.
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations, but validated secondmate handoffs always use `tasks-axi mv`.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.
# fm_tasks_axi_backend_resolve owns backend precedence: TASKS_AXI_BACKEND when
# set, then a backend in the working root's .tasks.toml, then one in
# $HOME/.tasks-axi/config.toml, then markdown. Lower-priority sources are read
# only when no earlier source supplies a backend; absent files keep that fallback.
# A detected unreadable or nonregular configuration file, including a dangling
# symlink, returns 2 with a path diagnostic on stderr and no backend on stdout.
# fm_tasks_axi_backend delegates to that resolver and preserves its status;
# callers must check it before selecting backend-specific flags or exemptions.
#
# This file is the single owner of FM_TASKS_AXI_MIN. bin/fm-bootstrap.sh turns a
# failing check into the operator-facing MISSING diagnostic.
#
# COMPATIBILITY VERDICT REUSE. fm_tasks_axi_compatible costs three tasks-axi
# subprocesses, and one session start needs the same verdict twice: once in
# bin/fm-session-start.sh's backlog listing and once in the bin/fm-bootstrap.sh
# child it runs. Two reuse layers collapse that to a single probe:
#   - Within a process the first probe's answer is memoised.
#   - Across ONE process hop, a parent that already holds the verdict passes it
#     in FM_TASKS_AXI_COMPATIBLE=0|1. Sourcing this file CONSUMES that variable
#     (it is unset from the environment and kept only as a private shell
#     variable), so the verdict reaches the child that needs it and never leaks
#     onward into a spawned agent's environment, where it could outlive a
#     tasks-axi upgrade. Any value other than exactly 0 or 1 is ignored and the
#     probe runs normally.
# Both layers are bounded by process lifetime, so a tasks-axi install or upgrade
# is picked up by the next process rather than being cached to disk.
#
# DETERMINISTIC BINARY RESOLUTION. Two tasks-axi installs can coexist on one
# machine (a root-owned npm global under /usr/local and a user install under
# ~/.local), and which one a bare `tasks-axi` names then depends on whichever
# shell rc file last reordered PATH: a login shell puts ~/.local/bin first while
# an interactive ~/.bashrc that re-exports the system directories puts
# /usr/local/bin first. The primary and a crew pane can therefore disagree on
# the version, and the crew trips FM_TASKS_AXI_MIN with the required build
# installed (2026-09-12). Sourcing this file resolves ONE binary for the whole
# process tree instead of trusting PATH order:
#   1. an exported FM_TASKS_AXI_BIN that still exists wins without a probe (a
#      parent process already resolved it against the floor);
#   2. otherwise the first `tasks-axi` on PATH is kept when it meets the floor;
#   3. otherwise every other `tasks-axi` on PATH is probed in order and the first
#      that meets the floor is selected: its directory is prepended to PATH and
#      exported, so the bare `tasks-axi` calls in this process and in every child
#      resolve to that same build;
#   4. when no candidate meets the floor, PATH is untouched, FM_TASKS_AXI_BIN is
#      unset, and fm_tasks_axi_compatible reports incompatible exactly as before.
# The version floor is the only selection test; the feature probes remain the
# separate compatibility verdict, so a stripped build that advertises a current
# version is still reported incompatible. The resolution evidence stays in the
# FM_TASKS_AXI_RESOLVED_* variables below for bin/fm-bootstrap.sh to report, and
# bin/fm-spawn.sh exports the resolved build into each crew pane before launch.
# Every candidate probe is one `--version` subprocess; the resolved answer seeds
# fm_tasks_axi_version_parts so the compatibility probe does not repeat it.

FM_TASKS_AXI_MIN=0.2.4

FM_TASKS_AXI_COMPATIBLE_MEMO=${FM_TASKS_AXI_COMPATIBLE:-}
unset FM_TASKS_AXI_COMPATIBLE
case "$FM_TASKS_AXI_COMPATIBLE_MEMO" in
  0|1) ;;
  *) FM_TASKS_AXI_COMPATIBLE_MEMO= ;;
esac

# Print "major minor patch" parsed from a --version output line, or nothing.
fm_tasks_axi_parts_from_output() {  # <version-output>
  printf '%s\n' "$1" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

# Print the version parts reported by the executable at $1, or return 1.
fm_tasks_axi_version_parts_of() {  # <path>
  local output
  [ -n "$1" ] && [ -f "$1" ] && [ -x "$1" ] || return 1
  output=$("$1" --version 2>/dev/null) || return 1
  fm_tasks_axi_parts_from_output "$output"
}

fm_tasks_axi_parts_join() {  # <parts>
  printf '%s\n' "$1" | tr ' ' '.'
}

# True when "$1" (major minor patch) is FM_TASKS_AXI_MIN or newer. An
# unparseable version is never assumed current, so a development or vendored
# build cannot pass a floor it was never checked against.
fm_tasks_axi_parts_meet_floor() {  # <parts>
  local major minor patch extra min_major min_minor min_patch min_extra
  [ -n "$1" ] || return 1
  IFS=' ' read -r major minor patch extra <<< "$1"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_TASKS_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -gt "$min_minor" ]; } ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -eq "$min_minor" ] && [ "$patch" -ge "$min_patch" ]; }
}

# Print every executable named tasks-axi on PATH, in PATH order, one per line,
# each path once.
fm_tasks_axi_path_candidates() {
  local dir p seen=' '
  while IFS= read -r dir; do
    [ -n "$dir" ] || dir=.
    p="$dir/tasks-axi"
    [ -f "$p" ] && [ -x "$p" ] || continue
    case "$seen" in *" $p "*) continue ;; esac
    seen="$seen$p "
    printf '%s\n' "$p"
  done <<EOF
$(printf '%s\n' "$PATH" | tr ':' '\n')
EOF
}

# Make $1 the build a bare `tasks-axi` names in this process and its children.
fm_tasks_axi_prefer_bin() {  # <path>
  local dir current
  current=$(command -v tasks-axi 2>/dev/null || true)
  if [ "$current" != "$1" ]; then
    dir=$(dirname -- "$1")
    PATH="$dir:$PATH"
    export PATH
  fi
  FM_TASKS_AXI_BIN=$1
  export FM_TASKS_AXI_BIN
}

# Resolution evidence. FROM is env, path-first, path-later, or none. These are
# read by bin/fm-bootstrap.sh after sourcing, so they look unused here.
# shellcheck disable=SC2034
FM_TASKS_AXI_RESOLVED_FROM='none'
FM_TASKS_AXI_RESOLVED_VERSION=
FM_TASKS_AXI_RESOLVED_PARTS=
FM_TASKS_AXI_PATH_FIRST=
FM_TASKS_AXI_PATH_FIRST_VERSION=
# Newline-separated "<path> <version-or-unparseable>" for every PATH candidate
# probed and found below the floor, in PATH order.
FM_TASKS_AXI_REJECTED=

# ONE-HOP EVIDENCE HANDOFF. The process that probed exports its evidence in
# FM_TASKS_AXI_RESOLUTION (key=value lines; rejected= repeats), and sourcing
# this file CONSUMES it exactly like FM_TASKS_AXI_COMPATIBLE above: a child
# such as bin/fm-bootstrap.sh reports the parent's resolution without spending
# another --version, and the evidence never leaks past that hop into a spawned
# agent. FM_TASKS_AXI_BIN itself deliberately does propagate (bin/fm-spawn.sh
# pins it into crew panes): an exported build that still exists is trusted
# without a probe, and only a removed one triggers a fresh resolution.
FM_TASKS_AXI_RESOLUTION_MEMO=${FM_TASKS_AXI_RESOLUTION:-}
unset FM_TASKS_AXI_RESOLUTION

fm_tasks_axi_note_rejected() {  # <path> <parts>
  local shown
  if [ -n "$2" ]; then shown=$(fm_tasks_axi_parts_join "$2"); else shown=unparseable; fi
  FM_TASKS_AXI_REJECTED="${FM_TASKS_AXI_REJECTED:+$FM_TASKS_AXI_REJECTED
}$1 $shown"
}

fm_tasks_axi_resolution_export() {
  local line
  FM_TASKS_AXI_RESOLUTION=$(
    printf 'from=%s\nversion=%s\nparts=%s\npath_first=%s\npath_first_version=%s\n' \
      "$FM_TASKS_AXI_RESOLVED_FROM" "$FM_TASKS_AXI_RESOLVED_VERSION" \
      "$FM_TASKS_AXI_RESOLVED_PARTS" "$FM_TASKS_AXI_PATH_FIRST" \
      "$FM_TASKS_AXI_PATH_FIRST_VERSION"
    [ -z "$FM_TASKS_AXI_REJECTED" ] || while IFS= read -r line; do
      printf 'rejected=%s\n' "$line"
    done <<EOF
$FM_TASKS_AXI_REJECTED
EOF
  )
  export FM_TASKS_AXI_RESOLUTION
}

# Restore the parent's evidence from the consumed handoff, or return 1 when
# there was none.
fm_tasks_axi_resolution_import() {
  local key value line
  [ -n "$FM_TASKS_AXI_RESOLUTION_MEMO" ] || return 1
  FM_TASKS_AXI_REJECTED=
  while IFS= read -r line; do
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      from) FM_TASKS_AXI_RESOLVED_FROM=$value ;;
      version) FM_TASKS_AXI_RESOLVED_VERSION=$value ;;
      parts) FM_TASKS_AXI_RESOLVED_PARTS=$value ;;
      path_first) FM_TASKS_AXI_PATH_FIRST=$value ;;
      path_first_version) FM_TASKS_AXI_PATH_FIRST_VERSION=$value ;;
      rejected) FM_TASKS_AXI_REJECTED="${FM_TASKS_AXI_REJECTED:+$FM_TASKS_AXI_REJECTED
}$value" ;;
    esac
  done <<EOF
$FM_TASKS_AXI_RESOLUTION_MEMO
EOF
  case "$FM_TASKS_AXI_RESOLVED_FROM" in
    env|path-first|path-later|none) ;;
    *) FM_TASKS_AXI_RESOLVED_FROM='none' ;;
  esac
}

# shellcheck disable=SC2034
fm_tasks_axi_resolve() {
  local candidate parts first
  FM_TASKS_AXI_RESOLVED_FROM='none'
  FM_TASKS_AXI_RESOLVED_VERSION=
  FM_TASKS_AXI_RESOLVED_PARTS=
  FM_TASKS_AXI_PATH_FIRST=
  FM_TASKS_AXI_PATH_FIRST_VERSION=
  FM_TASKS_AXI_REJECTED=
  # A parent already selected this build: trust it without a probe and restore
  # the parent's evidence when it was handed down. Only a process that probed
  # exports evidence, so the handoff really is one hop.
  if [ -n "${FM_TASKS_AXI_BIN:-}" ] && [ -f "$FM_TASKS_AXI_BIN" ] && [ -x "$FM_TASKS_AXI_BIN" ]; then
    fm_tasks_axi_resolution_import || true
    [ "$FM_TASKS_AXI_RESOLVED_FROM" != none ] || FM_TASKS_AXI_RESOLVED_FROM='env'
    fm_tasks_axi_prefer_bin "$FM_TASKS_AXI_BIN"
    return 0
  fi
  # A handed-in path that no longer exists is dropped rather than trusted.
  [ -z "${FM_TASKS_AXI_BIN:-}" ] || unset FM_TASKS_AXI_BIN
  # A handed-in compatibility verdict (COMPATIBILITY VERDICT REUSE above) means
  # the parent probed this same PATH one hop ago, so no --version is spent
  # here: keep the first build on PATH under a compatible verdict, or leave an
  # incompatible one exactly as the parent found it, with its evidence.
  case "$FM_TASKS_AXI_COMPATIBLE_MEMO" in
    1)
      first=$(command -v tasks-axi 2>/dev/null || true)
      if [ -n "$first" ] && [ -f "$first" ] && [ -x "$first" ]; then
        fm_tasks_axi_resolution_import || true
        [ "$FM_TASKS_AXI_RESOLVED_FROM" != none ] || FM_TASKS_AXI_RESOLVED_FROM='path-first'
        [ -n "$FM_TASKS_AXI_PATH_FIRST" ] || FM_TASKS_AXI_PATH_FIRST=$first
        fm_tasks_axi_prefer_bin "$first"
        return 0
      fi
      return 1
      ;;
    0)
      fm_tasks_axi_resolution_import || true
      FM_TASKS_AXI_RESOLVED_FROM='none'
      return 1
      ;;
  esac
  first=$(command -v tasks-axi 2>/dev/null || true)
  if [ -n "$first" ] && [ -f "$first" ] && [ -x "$first" ]; then
    FM_TASKS_AXI_PATH_FIRST=$first
    parts=$(fm_tasks_axi_version_parts_of "$first") || parts=
    [ -z "$parts" ] || FM_TASKS_AXI_PATH_FIRST_VERSION=$(fm_tasks_axi_parts_join "$parts")
    if fm_tasks_axi_parts_meet_floor "$parts"; then
      FM_TASKS_AXI_RESOLVED_FROM='path-first'
      FM_TASKS_AXI_RESOLVED_PARTS=$parts
      FM_TASKS_AXI_RESOLVED_VERSION=$(fm_tasks_axi_parts_join "$parts")
      fm_tasks_axi_prefer_bin "$first"
      fm_tasks_axi_resolution_export
      return 0
    fi
    fm_tasks_axi_note_rejected "$first" "$parts"
  fi
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    [ "$candidate" != "$first" ] || continue
    parts=$(fm_tasks_axi_version_parts_of "$candidate") || parts=
    if fm_tasks_axi_parts_meet_floor "$parts"; then
      FM_TASKS_AXI_RESOLVED_FROM='path-later'
      FM_TASKS_AXI_RESOLVED_PARTS=$parts
      FM_TASKS_AXI_RESOLVED_VERSION=$(fm_tasks_axi_parts_join "$parts")
      fm_tasks_axi_prefer_bin "$candidate"
      fm_tasks_axi_resolution_export
      return 0
    fi
    fm_tasks_axi_note_rejected "$candidate" "$parts"
  done <<EOF
$(fm_tasks_axi_path_candidates)
EOF
  fm_tasks_axi_resolution_export
  return 1
}

fm_tasks_axi_resolve >/dev/null 2>&1 || true

fm_tasks_axi_version_parts() {
  local output current
  current=$(command -v tasks-axi 2>/dev/null) || return 1
  if [ -n "$FM_TASKS_AXI_RESOLVED_PARTS" ] && [ "$current" = "${FM_TASKS_AXI_BIN:-}" ]; then
    printf '%s\n' "$FM_TASKS_AXI_RESOLVED_PARTS"
    return 0
  fi
  output=$(tasks-axi --version 2>/dev/null) || return 1
  fm_tasks_axi_parts_from_output "$output"
}

fm_tasks_axi_compatible() {
  case "$FM_TASKS_AXI_COMPATIBLE_MEMO" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  if fm_tasks_axi_compatible_probe; then
    FM_TASKS_AXI_COMPATIBLE_MEMO=1
    return 0
  fi
  FM_TASKS_AXI_COMPATIBLE_MEMO=0
  return 1
}

fm_tasks_axi_compatible_probe() {
  local parts
  parts=$(fm_tasks_axi_version_parts) || return 1
  fm_tasks_axi_parts_meet_floor "$parts" || return 1
  fm_tasks_axi_update_has_archive_body && fm_tasks_axi_mv_has_multi_id
}

fm_tasks_axi_update_has_archive_body() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

fm_tasks_axi_mv_has_multi_id() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

fm_tasks_axi_backend_from_toml() {  # <toml-path>
  local toml=$1
  [ -f "$toml" ] || return 1
  LC_ALL=C awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    BEGIN { root=1; found=0; single=sprintf("%c", 39) }
    {
      line=$0
      sub(/[[:space:]]*#.*/, "", line)
      line=trim(line)
      if (line ~ /^\[[^]]+\]$/) {
        root=0
        next
      }
      if (root && line ~ /^backend[[:space:]]*=/) {
        sub(/^backend[[:space:]]*=[[:space:]]*/, "", line)
        line=trim(line)
        if ((substr(line, 1, 1) == "\"" && substr(line, length(line), 1) == "\"") ||
            (substr(line, 1, 1) == single && substr(line, length(line), 1) == single)) {
          print substr(line, 2, length(line) - 2)
          found=1
          exit
        }
      }
    }
    END { if (!found) exit 1 }
  ' "$toml"
}

# Resolve the active tasks-axi backend with the same precedence as tasks-axi.
fm_tasks_axi_backend_resolve() {  # <tasks-axi-working-directory>
  local root=$1 backend
  if [ "${TASKS_AXI_BACKEND+x}" = x ]; then
    printf '%s\n' "$TASKS_AXI_BACKEND"
    return 0
  fi
  local config="$root/.tasks.toml"
  if { [ -d "${config%/*}" ] && [ ! -x "${config%/*}" ]; } ||
    { { [ -e "$config" ] || [ -L "$config" ]; } && { [ ! -f "$config" ] || [ ! -r "$config" ]; }; }; then
    printf 'tasks-axi backend configuration cannot be read at %s\n' "$config" >&2
    return 2
  fi
  if backend=$(fm_tasks_axi_backend_from_toml "$config"); then
    printf '%s\n' "$backend"
    return 0
  fi
  if [ -n "${HOME:-}" ]; then
    config="$HOME/.tasks-axi/config.toml"
    if { [ -d "${config%/*}" ] && [ ! -x "${config%/*}" ]; } ||
      { { [ -e "$config" ] || [ -L "$config" ]; } && { [ ! -f "$config" ] || [ ! -r "$config" ]; }; }; then
      printf 'tasks-axi backend configuration cannot be read at %s\n' "$config" >&2
      return 2
    fi
    if backend=$(fm_tasks_axi_backend_from_toml "$config"); then
      printf '%s\n' "$backend"
      return 0
    fi
  fi
  printf '%s\n' markdown
}

fm_tasks_axi_backend() {  # <tasks-axi-working-directory>
  fm_tasks_axi_backend_resolve "$1"
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}
