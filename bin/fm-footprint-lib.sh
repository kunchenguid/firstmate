#!/usr/bin/env bash
# fm-footprint-lib.sh - the single owner of a task's scratch area, its Docker
# label set, and config/footprint parsing.
#
# Sourced, never executed; no side effects on source. bin/fm-spawn.sh sources
# it to create and export a ship or scout task's scratch area and Docker
# labels; bin/fm-footprint.sh sources it for the report, the close-time
# cleanup bin/fm-teardown.sh invokes, the cache cap, and the old-folder
# preview. Functions that need a bound require bin/fm-timeout-lib.sh sourced
# first.
#
# config/footprint is optional and per machine; docs/configuration.md
# "Footprint" owns its keys and defaults. fm_footprint_config_read parses it:
# one "key value" per line, "#" starts a comment, blank lines are ignored, and
# an unknown key, a repeated key, or a malformed value is an error naming the
# line rather than a silently ignored setting.
#
# Layout. A task's scratch area is <scratch-root>/<home-key>/<task-id>/, with
# the redirected temp directory at tmp/ inside it. <home-key> is the first 8
# hex digits of the SHA-256 of this home's physical path, so two homes on one
# machine that reuse a task id never share or remove each other's scratch.
# The key directory carries a .fm-home file naming that physical home path,
# written when the directory is created; fm_footprint_key_dir_trusted is the
# ownership proof every removal requires, so a key directory that is a link,
# lies elsewhere, or names another home is never trusted.
# FM_SCRATCH_ROOT_OVERRIDE, when set, replaces the configured and default root;
# bin/fm-test-run.sh sets it so the suite never writes into a real cache.
#
# Temp redirection. TMPDIR, TMP and TEMP are exported only for a worker tool
# listed by fm_footprint_tmpdir_covered, whose live check is recorded in
# docs/verification/runtime-backends.md and refreshed by
# tests/fm-footprint-tmpdir-live.test.sh, and only while the resulting temp path
# is at most FM_FOOTPRINT_TMPDIR_MAX bytes, because macOS limits a Unix socket
# path to 104 bytes and tests create sockets under TMPDIR. Every other tool
# keeps its inherited temp directory and is reported as not covered.
#
# Docker. Each task area holds a generation, 16 random hex digits written in
# <area>/.fm-generation when spawn first makes the area and reused while it
# exists (a relaunch keeps it). FM_DOCKER_LABEL is the one flag a worker
# passes to docker run, docker create, docker volume create, docker network
# create and docker build: firstmate.task=<home-key>/<task-id>/<generation>.
# COMPOSE_PROJECT_NAME is fm-<home-key>-<task-id lowercased, "." as
# "_">-<generation>, so compose names and labels every container, network,
# volume and built image of the task without the worker doing anything. The
# random generation, not the task id, makes both names unique: two task ids
# that lowercase alike, or a later task reusing an id, never share one.
# Cleanup matches either exact label, never a name or a prefix.

FM_FOOTPRINT_SCRATCH_ROOT_MAX=64
FM_FOOTPRINT_TMPDIR_MAX=90

fm_footprint_os() {
  uname -s 2>/dev/null || printf 'unknown\n'
}

fm_footprint_physical_dir() {  # <dir>
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P)
}

fm_footprint_sha256() {  # <string>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

fm_footprint_home_key() {  # <home>
  local root hash
  root=$(fm_footprint_physical_dir "$1") || root=$1
  hash=$(fm_footprint_sha256 "$root") || return 1
  case "$hash" in ''|*[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "${hash:0:8}"
}

_fm_footprint_onoff() {  # <value>
  case "$1" in on|off) return 0 ;; *) return 1 ;; esac
}

_fm_footprint_number() {  # <value>: non-negative whole or decimal number
  case "$1" in ''|*[!0-9.]*|*.*.*|.*|*.) return 1 ;; esac
}

_fm_footprint_whole() {  # <value>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

# shellcheck disable=SC2034 # FP_* are output globals read by the sourcing script.
# fm_footprint_config_read <config-dir>
#   Sets FP_SCRATCH_ROOT_CFG, FP_TASK_CLEANUP, FP_TASK_TMPDIR, FP_DOCKER_LABELS,
#   FP_CACHE_CAP_GB (empty means no cap), FP_ORPHAN_GRACE_HOURS,
#   FP_OLD_TASK_DAYS, FP_KEEP_WARN_MB and FP_REMOVAL_GRACE_SECONDS. Returns 1 with FP_CONFIG_ERROR set for an unsafe,
#   unreadable or malformed file, leaving the defaults in place.
fm_footprint_config_read() {  # <config-dir>
  local file="$1/footprint" line key value rest n=0 seen=' '
  FP_SCRATCH_ROOT_CFG=
  FP_TASK_CLEANUP=on
  FP_TASK_TMPDIR=on
  FP_DOCKER_LABELS=on
  FP_CACHE_CAP_GB=
  FP_ORPHAN_GRACE_HOURS=24
  FP_OLD_TASK_DAYS=30
  FP_KEEP_WARN_MB=200
  FP_REMOVAL_GRACE_SECONDS=5
  FP_CONFIG_ERROR=
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ -L "$file" ] || [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FP_CONFIG_ERROR="$file is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%%#*}
    set -f
    # shellcheck disable=SC2086 # deliberate field split of one config line
    set -- $line
    set +f
    [ "$#" -gt 0 ] || continue
    key=$1
    value=${2-}
    shift
    [ "$#" -gt 0 ] && shift
    rest=$*
    if [ -z "$value" ] || [ -n "$rest" ]; then
      FP_CONFIG_ERROR="$file line $n: expected one value for '$key'"
      return 1
    fi
    case "$seen" in *" $key "*)
      FP_CONFIG_ERROR="$file line $n: '$key' is set more than once"
      return 1
      ;;
    esac
    seen="$seen$key "
    case "$key" in
      scratch-root)
        FP_SCRATCH_ROOT_CFG=$value ;;
      task-cleanup|task-tmpdir|docker-labels)
        _fm_footprint_onoff "$value" || {
          FP_CONFIG_ERROR="$file line $n: '$key' must be on or off"
          return 1
        }
        case "$key" in
          task-cleanup) FP_TASK_CLEANUP=$value ;;
          task-tmpdir) FP_TASK_TMPDIR=$value ;;
          docker-labels) FP_DOCKER_LABELS=$value ;;
        esac
        ;;
      cache-cap-gb)
        _fm_footprint_number "$value" || {
          FP_CONFIG_ERROR="$file line $n: 'cache-cap-gb' must be a number of GB"
          return 1
        }
        FP_CACHE_CAP_GB=$value
        ;;
      orphan-grace-hours|old-task-days|keep-warn-mb)
        _fm_footprint_whole "$value" || {
          FP_CONFIG_ERROR="$file line $n: '$key' must be a whole number"
          return 1
        }
        case "$key" in
          orphan-grace-hours) FP_ORPHAN_GRACE_HOURS=$value ;;
          old-task-days) FP_OLD_TASK_DAYS=$value ;;
          keep-warn-mb) FP_KEEP_WARN_MB=$value ;;
        esac
        ;;
      removal-grace-seconds)
        if ! _fm_footprint_whole "$value" || [ "$value" -lt 1 ] || [ "$value" -gt 600 ]; then
          FP_CONFIG_ERROR="$file line $n: 'removal-grace-seconds' must be a whole number from 1 to 600"
          return 1
        fi
        FP_REMOVAL_GRACE_SECONDS=$value
        ;;
      *)
        FP_CONFIG_ERROR="$file line $n: unknown key '$key'"
        return 1
        ;;
    esac
  done < "$file"
  return 0
}

fm_footprint_default_scratch_root() {
  case "$(fm_footprint_os)" in
    Darwin) printf '%s\n' "$HOME/Library/Caches/firstmate/scratch" ;;
    *) printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/firstmate/scratch" ;;
  esac
}

# fm_footprint_scratch_root <home>
#   Sets FP_SCRATCH_ROOT after fm_footprint_config_read. Returns 1 with
#   FP_CONFIG_ERROR for a configured root that is relative, too long, holds a
#   "." or ".." component, or lies under this home's data/ or projects/.
fm_footprint_scratch_root() {  # <home>
  local root home_real
  FP_SCRATCH_ROOT=
  if [ -n "${FM_SCRATCH_ROOT_OVERRIDE:-}" ]; then
    FP_SCRATCH_ROOT=$FM_SCRATCH_ROOT_OVERRIDE
    return 0
  fi
  if [ -z "${FP_SCRATCH_ROOT_CFG:-}" ]; then
    FP_SCRATCH_ROOT=$(fm_footprint_default_scratch_root)
    return 0
  fi
  root=${FP_SCRATCH_ROOT_CFG%/}
  case "$root" in
    /*) ;;
    *) FP_CONFIG_ERROR="scratch-root must be an absolute path: $root"; return 1 ;;
  esac
  case "/$root/" in
    */../*|*/./*) FP_CONFIG_ERROR="scratch-root must not contain . or .. components: $root"; return 1 ;;
  esac
  if [ "${#root}" -gt "$FM_FOOTPRINT_SCRATCH_ROOT_MAX" ]; then
    FP_CONFIG_ERROR="scratch-root is ${#root} bytes, longer than $FM_FOOTPRINT_SCRATCH_ROOT_MAX; temp paths under it would overflow the 104-byte Unix socket limit on macOS: $root"
    return 1
  fi
  home_real=$(fm_footprint_physical_dir "$1") || home_real=$1
  case "$root/" in
    "$home_real/data/"*|"$home_real/projects/"*|"$1/data/"*|"$1/projects/"*)
      FP_CONFIG_ERROR="scratch-root must be outside this home's data/ and projects/: $root"
      return 1
      ;;
  esac
  FP_SCRATCH_ROOT=$root
}

# fm_footprint_private_dir <dir>
#   Creates <dir> and any missing parents with mode 0700, or accepts an
#   existing one only when it is a real directory owned by this user and
#   writable by nobody else, then tightens it to 0700. Returns 1 otherwise.
fm_footprint_private_dir() {  # <dir>
  local dir=$1
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    (umask 077 && mkdir -p -- "$dir") 2>/dev/null || return 1
  fi
  [ ! -L "$dir" ] && [ -d "$dir" ] && [ -O "$dir" ] || return 1
  [ -z "$(find "$dir" -prune \( -perm -g=w -o -perm -o=w \) -print 2>/dev/null)" ] || return 1
  chmod 700 "$dir" 2>/dev/null
}

# The worker tools verified live to start, run a command, and keep their own
# temp files under a redirected TMPDIR (tests/fm-footprint-tmpdir-live.test.sh).
FM_FOOTPRINT_TMPDIR_HARNESSES="claude codex"

fm_footprint_tmpdir_covered() {  # <harness>
  case " $FM_FOOTPRINT_TMPDIR_HARNESSES " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

fm_footprint_docker_label() {  # <home-key> <task-id> <generation>
  printf 'firstmate.task=%s/%s/%s\n' "$1" "$2" "$3"
}

fm_footprint_compose_project() {  # <home-key> <task-id> <generation>
  printf 'fm-%s-%s-%s\n' "$1" "$(printf '%s' "$2" | tr 'A-Z.' 'a-z_')" "$3"
}

fm_footprint_generation_valid() {  # <generation>: exactly 16 lowercase hex digits
  case "$1" in
    ????????????????) case "$1" in *[!0-9a-f]*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}

# fm_footprint_task_generation <area>: prints the generation recorded in the
# area, or returns 1 when there is none or it is not a regular file owned by
# this user holding exactly one valid generation.
fm_footprint_task_generation() {  # <area>
  local f="$1/.fm-generation" g
  [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ] || return 1
  IFS= read -r g < "$f" || return 1
  fm_footprint_generation_valid "$g" || return 1
  printf '%s\n' "$g"
}

# fm_footprint_generation_ensure <area>: the area's generation, written from
# /dev/urandom when the area has none yet. Returns 1 when one exists but is
# not valid, or none could be written.
fm_footprint_generation_ensure() {  # <area>
  local f="$1/.fm-generation" g
  if [ -e "$f" ] || [ -L "$f" ]; then
    fm_footprint_task_generation "$1"
    return
  fi
  g=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  fm_footprint_generation_valid "$g" || return 1
  (umask 077 && printf '%s\n' "$g" > "$f.$$" && mv -f "$f.$$" "$f") 2>/dev/null || { rm -f "$f.$$"; return 1; }
  fm_footprint_task_generation "$1"
}

# fm_footprint_key_dir_bind <key-dir> <home>
#   Records <home>'s physical path in <key-dir>/.fm-home when absent, and
#   returns 1 when the file is not a regular file or names another home.
fm_footprint_key_dir_bind() {  # <key-dir> <home>
  local marker="$1/.fm-home" home_real current
  home_real=$(fm_footprint_physical_dir "$2") || return 1
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    (umask 077 && printf '%s\n' "$home_real" > "$marker.$$" && mv -f "$marker.$$" "$marker") 2>/dev/null || {
      rm -f "$marker.$$"
      return 1
    }
  fi
  [ -f "$marker" ] && [ ! -L "$marker" ] && [ -O "$marker" ] || return 1
  IFS= read -r current < "$marker" || return 1
  [ "$current" = "$home_real" ]
}

# fm_footprint_key_dir_trusted <root> <key> <home>
#   The ownership proof for <root>/<key>: a real directory, not a link, owned
#   by this user and writable by nobody else, physically a direct child of
#   the root, whose .fm-home names <home>'s physical path. Returns 1 otherwise.
fm_footprint_key_dir_trusted() {  # <root> <key> <home>
  local dir="$1/$2" root_real dir_real home_real current marker
  marker="$dir/.fm-home"
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || return 1
  [ -z "$(find "$dir" -prune \( -perm -g=w -o -perm -o=w \) -print 2>/dev/null)" ] || return 1
  root_real=$(fm_footprint_physical_dir "$1") || return 1
  dir_real=$(fm_footprint_physical_dir "$dir") || return 1
  [ "$dir_real" = "$root_real/$2" ] || return 1
  [ -f "$marker" ] && [ ! -L "$marker" ] && [ -O "$marker" ] || return 1
  home_real=$(fm_footprint_physical_dir "$3") || return 1
  IFS= read -r current < "$marker" || return 1
  [ "$current" = "$home_real" ]
}

# fm_footprint_task_env <config-dir> <home> <task-id> <harness>
#   Creates the task's private scratch area and prints the exports for it as
#   NAME=VALUE lines: FM_TASK_SCRATCH always; FM_DOCKER_LABEL and
#   COMPOSE_PROJECT_NAME unless docker-labels is off; TMPDIR, TMP and TEMP
#   only for a covered tool within the path limit and unless task-tmpdir is
#   off. Prints "#" note lines for anything left uncovered. Returns 1 with a
#   reason on stderr for a malformed config or an unsafe scratch path.
fm_footprint_task_env() {  # <config-dir> <home> <task-id> <harness>
  local config=$1 home=$2 id=$3 harness=$4 root key dir tmp gen
  if ! fm_footprint_config_read "$config"; then
    printf 'error: %s\n' "$FP_CONFIG_ERROR" >&2
    return 1
  fi
  if ! fm_footprint_scratch_root "$home"; then
    printf 'error: %s\n' "$FP_CONFIG_ERROR" >&2
    return 1
  fi
  root=$FP_SCRATCH_ROOT
  key=$(fm_footprint_home_key "$home") || {
    printf 'error: cannot hash the home path for its scratch key (shasum or sha256sum is required)\n' >&2
    return 1
  }
  dir="$root/$key/$id"
  tmp="$dir/tmp"
  if ! fm_footprint_private_dir "$root" || ! fm_footprint_private_dir "$root/$key" ||
    ! fm_footprint_key_dir_bind "$root/$key" "$home" ||
    ! fm_footprint_private_dir "$dir" || ! fm_footprint_private_dir "$tmp" ||
    ! gen=$(fm_footprint_generation_ensure "$dir"); then
    printf 'error: task scratch area %s is not a private directory owned by this user with a valid .fm-generation; inspect and remove it, then retry\n' "$dir" >&2
    return 1
  fi
  printf 'FM_TASK_SCRATCH=%s\n' "$dir"
  if [ "$FP_DOCKER_LABELS" = on ]; then
    printf 'FM_DOCKER_LABEL=%s\n' "$(fm_footprint_docker_label "$key" "$id" "$gen")"
    printf 'COMPOSE_PROJECT_NAME=%s\n' "$(fm_footprint_compose_project "$key" "$id" "$gen")"
  fi
  if [ "$FP_TASK_TMPDIR" != on ]; then
    printf '# task-tmpdir off: temp stays where the worker inherits it\n'
  elif ! fm_footprint_tmpdir_covered "$harness"; then
    printf '# %s is not verified with a redirected TMPDIR: temp stays where it inherits it\n' "$harness"
  elif [ "${#tmp}" -gt "$FM_FOOTPRINT_TMPDIR_MAX" ]; then
    printf '# %s is %s bytes, over %s: temp stays where the worker inherits it\n' "$tmp" "${#tmp}" "$FM_FOOTPRINT_TMPDIR_MAX"
  else
    printf 'TMPDIR=%s\nTMP=%s\nTEMP=%s\n' "$tmp" "$tmp" "$tmp"
  fi
}
