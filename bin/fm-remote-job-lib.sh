#!/usr/bin/env bash
# Shared remote fm-on job-worker protocol.
#
# Source this file from the fixed SSH entrypoint, the long-lived worker, or the
# remote doctor. It owns the per-account queue at
# ~/.firstmate/remote-job (override only with FM_REMOTE_JOB_STATE_ROOT for
# isolated tests), the bounded job record, worker installation, and the remote
# runtime PATH.
#
# A job directory is mode 0700 and contains root, home, argv (NUL-delimited),
# stdin, stdout, stderr, queue_deadline, timeout, deadline, exit, and state.
# Stage writes state=queued last. The worker atomically claims a job with
# .claim, establishes its execution deadline, changes state to running, writes
# bounded stdout/stderr and exit, then publishes state=done last. Callers wait
# for done, relay stdout and stderr separately, then reap only their completed
# record. Input, argv, stdout, and stderr are each capped at 1048576 bytes.
#
# The worker accepts only a tracked, non-symlink executable named fm-*.sh below
# its configured FM_ROOT/bin. Every child receives env -i with the composed
# PATH, HOME, FM_HOME, FM_ROOT_OVERRIDE, and FM_REMOTE_JOB_ACTIVE=1. The PATH
# is intentionally filesystem-discovered rather than login-shell-derived:
# ~/.local/bin; nvm, asdf, and mise shims/install bins; Nix; Homebrew; and the
# system tail. No shell startup files are evaluated.
#
# On macOS the worker is Firstmate's Aqua LaunchAgent
# dev.firstmate.remote-job at ~/Library/LaunchAgents/dev.firstmate.remote-job.plist
# with logs under ~/Library/Logs. Linux starts the same worker process without
# an Aqua requirement. The launch-agent renderer and repair helpers here are
# shared by the entrypoint and remote doctor so their ownership cannot drift.

FM_REMOTE_JOB_LABEL=dev.firstmate.remote-job
FM_REMOTE_JOB_MAX_BYTES=${FM_REMOTE_JOB_MAX_BYTES:-1048576}
FM_REMOTE_JOB_QUEUE_TIMEOUT=${FM_REMOTE_JOB_QUEUE_TIMEOUT:-360}
FM_REMOTE_JOB_TIMEOUT=${FM_REMOTE_JOB_TIMEOUT:-360}
FM_REMOTE_JOB_WAIT_GRACE=${FM_REMOTE_JOB_WAIT_GRACE:-30}
FM_REMOTE_JOB_POLL_SECONDS=${FM_REMOTE_JOB_POLL_SECONDS:-0.05}
FM_REMOTE_JOB_REAP_SECONDS=${FM_REMOTE_JOB_REAP_SECONDS:-3600}
FM_REMOTE_JOB_OPERATOR_PATH=
FM_REMOTE_JOB_CHILD_PATH=
FM_REMOTE_JOB_STATE=
FM_REMOTE_JOB_JOBS=
FM_REMOTE_JOB_ID=
FM_REMOTE_JOB_STDOUT=
FM_REMOTE_JOB_STDERR=
FM_REMOTE_JOB_EXIT=
FM_REMOTE_JOB_ERROR=
FM_REMOTE_JOB_REPAIRED=0

fm_remote_job_die() {
  printf 'error: %s\n' "$1" >&2
  return 1
}

fm_remote_job_safe_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

fm_remote_job_validate_settings() {
  case "$FM_REMOTE_JOB_MAX_BYTES" in ''|*[!0-9]*|0) return 1 ;; esac
  [ "$FM_REMOTE_JOB_MAX_BYTES" -le 1048576 ] || return 1
  case "$FM_REMOTE_JOB_QUEUE_TIMEOUT" in ''|*[!0-9]*|0) return 1 ;; esac
  [ "$FM_REMOTE_JOB_QUEUE_TIMEOUT" -le 3600 ] || return 1
  case "$FM_REMOTE_JOB_TIMEOUT" in ''|*[!0-9]*|0) return 1 ;; esac
  [ "$FM_REMOTE_JOB_TIMEOUT" -le 3600 ] || return 1
  case "$FM_REMOTE_JOB_WAIT_GRACE" in ''|*[!0-9]*) return 1 ;; esac
  [ "$FM_REMOTE_JOB_WAIT_GRACE" -le 300 ] || return 1
  case "$FM_REMOTE_JOB_REAP_SECONDS" in ''|*[!0-9]*|0) return 1 ;; esac
  return 0
}

fm_remote_job_platform() {
  local raw=${FM_REMOTE_JOB_PLATFORM_OVERRIDE:-}
  [ -n "$raw" ] || raw=$(uname -s 2>/dev/null || true)
  case "$raw" in
    Darwin|darwin) printf 'darwin\n' ;;
    Linux|linux) printf 'linux\n' ;;
    '') printf 'unknown\n' ;;
    *) printf '%s\n' "$raw" ;;
  esac
}

fm_remote_job_path_append() { # <directory>
  case ":$FM_REMOTE_JOB_OPERATOR_PATH:" in *":$1:"*) return 0 ;; esac
  FM_REMOTE_JOB_OPERATOR_PATH="${FM_REMOTE_JOB_OPERATOR_PATH:+$FM_REMOTE_JOB_OPERATOR_PATH:}$1"
}

fm_remote_job_path_append_if_dir() { # <directory>
  [ -d "$1" ] && [ ! -L "$1" ] || return 0
  fm_remote_job_path_append "$1"
}

fm_remote_job_path_append_resolved_dir() { # <directory>
  local directory physical
  directory=$1
  [ -d "$directory" ] || return 0
  if [ ! -L "$directory" ]; then
    fm_remote_job_path_append "$directory"
    return 0
  fi
  physical=$(CDPATH='' cd -- "$directory" 2>/dev/null && pwd -P) || return 0
  [ -d "$physical" ] && [ ! -L "$physical" ] || return 0
  fm_remote_job_path_append "$physical"
}

fm_remote_job_append_glob_dirs() { # <glob whose matches are directories>
  local pattern=$1 directory
  while IFS= read -r directory; do
    fm_remote_job_path_append_if_dir "$directory"
  done < <(compgen -G "$pattern" || true)
}

fm_remote_job_nvm_default_selector() { # <account-home>
  local account_home=$1 alias_root selector alias_file next depth=0 suffix
  alias_root="$account_home/.nvm/alias"
  selector=$(fm_remote_job_read_single_line "$alias_root/default" 256 2>/dev/null || true)
  while [ -n "$selector" ] && [ "$depth" -lt 8 ]; do
    case "$selector" in ''|/*|*..*|*[!A-Za-z0-9._*/-]*) return 1 ;; esac
    case "$selector" in
      lts/*) suffix=${selector#lts/}; case "$suffix" in ''|*/*) return 1 ;; esac ;;
      */*) return 1 ;;
    esac
    alias_file="$alias_root/$selector"
    if [ -f "$alias_file" ] && [ ! -L "$alias_file" ]; then
      next=$(fm_remote_job_read_single_line "$alias_file" 256 2>/dev/null || true)
      [ -n "$next" ] && [ "$next" != "$selector" ] || return 1
      selector=$next
      depth=$((depth + 1))
      continue
    fi
    printf '%s\n' "$selector"
    return 0
  done
  return 1
}

fm_remote_job_nvm_selected_bin() { # <account-home>
  local account_home=$1 selector normalized directory base version major minor patch extra
  local selected='' fallback='' selected_major=-1 selected_minor=-1 selected_patch=-1
  local fallback_major=-1 fallback_minor=-1 fallback_patch=-1 matches
  selector=$(fm_remote_job_nvm_default_selector "$account_home" 2>/dev/null || true)
  [ "$selector" != system ] || return 0
  case "$selector" in node|stable|unstable) normalized= ;; v*) normalized=${selector#v} ;; *) normalized=$selector ;; esac
  case "$normalized" in *[!0-9.]*|.*|*.|*..*) normalized=invalid ;; esac
  for directory in "$account_home"/.nvm/versions/node/*/bin; do
    [ -d "$directory" ] && [ ! -L "$directory" ] || continue
    base=${directory%/bin}
    version=${base##*/}
    version=${version#v}
    IFS=. read -r major minor patch extra <<< "$version"
    case "$major:$minor:$patch:$extra" in *[!0-9:]*) continue ;; esac
    [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || continue
    if [ "$major" -gt "$fallback_major" ] ||
      { [ "$major" -eq "$fallback_major" ] && [ "$minor" -gt "$fallback_minor" ]; } ||
      { [ "$major" -eq "$fallback_major" ] && [ "$minor" -eq "$fallback_minor" ] && [ "$patch" -gt "$fallback_patch" ]; }; then
      fallback=$directory
      fallback_major=$major
      fallback_minor=$minor
      fallback_patch=$patch
    fi
    matches=0
    if [ -z "$normalized" ]; then
      matches=1
    elif [ "$normalized" != invalid ]; then
      case ".$version." in
        ."$normalized".|."$normalized".*) matches=1 ;;
      esac
    fi
    [ "$matches" -eq 1 ] || continue
    if [ "$major" -gt "$selected_major" ] ||
      { [ "$major" -eq "$selected_major" ] && [ "$minor" -gt "$selected_minor" ]; } ||
      { [ "$major" -eq "$selected_major" ] && [ "$minor" -eq "$selected_minor" ] && [ "$patch" -gt "$selected_patch" ]; }; then
      selected=$directory
      selected_major=$major
      selected_minor=$minor
      selected_patch=$patch
    fi
  done
  if [ -n "$selected" ]; then
    printf '%s\n' "$selected"
  elif [ -n "$fallback" ]; then
    printf '%s\n' "$fallback"
  fi
}

fm_remote_job_compose_operator_path() { # <account-home>
  local account_home=$1 account_user nvm_bin
  FM_REMOTE_JOB_OPERATOR_PATH=
  fm_remote_job_path_append_if_dir "$account_home/.local/bin"
  nvm_bin=$(fm_remote_job_nvm_selected_bin "$account_home" 2>/dev/null || true)
  [ -z "$nvm_bin" ] || fm_remote_job_path_append "$nvm_bin"
  fm_remote_job_path_append_if_dir "$account_home/.asdf/shims"
  fm_remote_job_append_glob_dirs "$account_home/.asdf/installs/*/*/bin"
  fm_remote_job_path_append_if_dir "$account_home/.local/share/mise/shims"
  fm_remote_job_path_append_if_dir "$account_home/.mise/shims"
  fm_remote_job_append_glob_dirs "$account_home/.local/share/mise/installs/*/*/bin"
  fm_remote_job_append_glob_dirs "$account_home/.mise/installs/*/*/bin"
  fm_remote_job_path_append_resolved_dir "$account_home/.nix-profile/bin"
  account_user=$(id -un 2>/dev/null || true)
  if [ -n "$account_user" ]; then
    fm_remote_job_path_append_resolved_dir "/etc/profiles/per-user/$account_user/bin"
  fi
  fm_remote_job_path_append_resolved_dir /run/current-system/sw/bin
  fm_remote_job_path_append_if_dir /opt/homebrew/bin
  fm_remote_job_path_append_if_dir /usr/local/bin
  fm_remote_job_path_append /usr/bin
  fm_remote_job_path_append /bin
  fm_remote_job_path_append /usr/sbin
  fm_remote_job_path_append /sbin
  printf '%s\n' "$FM_REMOTE_JOB_OPERATOR_PATH"
}

fm_remote_job_build_child_path() { # <remote-root>
  local root=$1 directory old_ifs
  FM_REMOTE_JOB_CHILD_PATH="$root/bin"
  old_ifs=$IFS
  IFS=:
  for directory in $FM_REMOTE_JOB_OPERATOR_PATH; do
    case ":$FM_REMOTE_JOB_CHILD_PATH:" in *":$directory:"*) continue ;; esac
    FM_REMOTE_JOB_CHILD_PATH="$FM_REMOTE_JOB_CHILD_PATH:$directory"
  done
  IFS=$old_ifs
  printf '%s\n' "$FM_REMOTE_JOB_CHILD_PATH"
}

fm_remote_job_operator_tool() { # <tool>; resolves only outside the checkout bin
  local tool=$1 resolved
  resolved=$(PATH="$FM_REMOTE_JOB_OPERATOR_PATH" command -v "$tool" 2>/dev/null || true)
  case "$resolved" in
    /*)
      [ -x "$resolved" ] || return 1
      case ":$FM_REMOTE_JOB_OPERATOR_PATH:" in *":${resolved%/*}:"*) printf '%s\n' "$resolved" ;; *) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
}

fm_remote_job_manager_tool() { # <account-home> <tool>
  local account_home=$1 tool=$2 directory candidate
  for directory in \
    "$account_home"/.nvm/versions/node/*/bin \
    "$account_home"/.asdf/shims \
    "$account_home"/.asdf/installs/*/*/bin \
    "$account_home"/.local/share/mise/shims \
    "$account_home"/.mise/shims \
    "$account_home"/.local/share/mise/installs/*/*/bin \
    "$account_home"/.mise/installs/*/*/bin; do
    [ -d "$directory" ] && [ ! -L "$directory" ] || continue
    candidate="$directory/$tool"
    [ -f "$candidate" ] && [ ! -L "$candidate" ] && [ -x "$candidate" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

fm_remote_job_has_forbidden_text_bytes() { # <file>
  LC_ALL=C tr -cd '\000\012\015' < "$1" | LC_ALL=C wc -c | tr -d ' '
}

fm_remote_job_normalize_absolute_path() { # <absolute-path>
  local path=$1 part old_ifs out=/
  case "$path" in /*) ;; *) return 1 ;; esac
  case "$path" in *'//'*) return 1 ;; esac
  old_ifs=$IFS
  IFS=/
  for part in $path; do
    case "$part" in
      '') ;;
      .|..) IFS=$old_ifs; return 1 ;;
      *)
        case "$part" in *$'\n'*|*$'\r'*|*$'\t'*) IFS=$old_ifs; return 1 ;; esac
        if [ "$out" = / ]; then out="/$part"; else out="$out/$part"; fi
        ;;
    esac
  done
  IFS=$old_ifs
  printf '%s\n' "$out"
}

fm_remote_job_canonical_existing_dir() { # <path>
  local path=$1 normalized physical
  normalized=$(fm_remote_job_normalize_absolute_path "$path") || return 1
  [ "$normalized" != / ] || return 1
  [ -d "$normalized" ] && [ ! -L "$normalized" ] || return 1
  physical=$(CDPATH='' cd -- "$normalized" 2>/dev/null && pwd -P) || return 1
  [ "$physical" = "$normalized" ] || return 1
  printf '%s\n' "$physical"
}

fm_remote_job_canonical_home() { # <path>; one absent leaf is allowed
  local path=$1 normalized parent base parent_real
  normalized=$(fm_remote_job_normalize_absolute_path "$path") || return 1
  [ "$normalized" != / ] || return 1
  if [ -e "$normalized" ] || [ -L "$normalized" ]; then
    fm_remote_job_canonical_existing_dir "$normalized"
    return
  fi
  parent=$(dirname "$normalized")
  base=$(basename "$normalized")
  case "$base" in ''|.|..) return 1 ;; esac
  parent_real=$(fm_remote_job_canonical_existing_dir "$parent") || return 1
  [ "$parent_real/$base" = "$normalized" ] || return 1
  printf '%s\n' "$normalized"
}

fm_remote_job_safe_child_dir() { # <canonical-parent> <single child basename>
  local parent=$1 base=$2 candidate physical
  case "$base" in ''|*/*|.|..) return 1 ;; esac
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  candidate="$parent/$base"
  if [ -e "$candidate" ] || [ -L "$candidate" ]; then
    [ -d "$candidate" ] && [ ! -L "$candidate" ] || return 1
  else
    (umask 077; mkdir "$candidate") || return 1
  fi
  chmod 700 "$candidate" 2>/dev/null || return 1
  physical=$(CDPATH='' cd -- "$candidate" 2>/dev/null && pwd -P) || return 1
  [ "$physical" = "$candidate" ] || return 1
  printf '%s\n' "$physical"
}

fm_remote_job_prepare_state() { # <account-home>
  local account_home=$1 root parent base firstmate
  fm_remote_job_validate_settings || {
    FM_REMOTE_JOB_ERROR="remote job bounds or timeout are invalid"
    return 1
  }
  account_home=$(fm_remote_job_canonical_existing_dir "$account_home") || {
    FM_REMOTE_JOB_ERROR="remote account home is unavailable or unsafe"
    return 1
  }
  if [ -n "${FM_REMOTE_JOB_STATE_ROOT:-}" ]; then
    root=$(fm_remote_job_normalize_absolute_path "$FM_REMOTE_JOB_STATE_ROOT") || {
      FM_REMOTE_JOB_ERROR="remote job state root is not a safe absolute path"
      return 1
    }
    parent=$(dirname "$root")
    base=$(basename "$root")
    parent=$(fm_remote_job_canonical_existing_dir "$parent") || {
      FM_REMOTE_JOB_ERROR="remote job state parent is unavailable or unsafe"
      return 1
    }
    [ "$parent/$base" = "$root" ] || return 1
    root=$(fm_remote_job_safe_child_dir "$parent" "$base") || {
      FM_REMOTE_JOB_ERROR="remote job state root is unsafe"
      return 1
    }
  else
    firstmate=$(fm_remote_job_safe_child_dir "$account_home" .firstmate) || {
      FM_REMOTE_JOB_ERROR="cannot prepare $account_home/.firstmate for remote jobs"
      return 1
    }
    root=$(fm_remote_job_safe_child_dir "$firstmate" remote-job) || {
      FM_REMOTE_JOB_ERROR="cannot prepare remote job state"
      return 1
    }
  fi
  FM_REMOTE_JOB_STATE=$root
  FM_REMOTE_JOB_JOBS=$(fm_remote_job_safe_child_dir "$FM_REMOTE_JOB_STATE" jobs) || {
    FM_REMOTE_JOB_ERROR="remote job queue is unsafe"
    return 1
  }
  fm_remote_job_safe_child_dir "$FM_REMOTE_JOB_STATE" logs >/dev/null || {
    FM_REMOTE_JOB_ERROR="remote job log directory is unsafe"
    return 1
  }
}

fm_remote_job_job_dir() { # <id>
  local id=$1 dir physical
  fm_remote_job_safe_id "$id" || return 1
  [ -n "$FM_REMOTE_JOB_JOBS" ] || return 1
  dir="$FM_REMOTE_JOB_JOBS/$id"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  physical=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || return 1
  [ "$physical" = "$dir" ] || return 1
  printf '%s\n' "$physical"
}

fm_remote_job_regular_bounded() { # <file> <max-bytes>
  local file=$1 max=$2 bytes
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  bytes=$(LC_ALL=C wc -c < "$file" | tr -d ' ') || return 1
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le "$max" ]
}

fm_remote_job_write_state() { # <job-dir> queued|running|done
  local job=$1 value=$2 tmp
  case "$value" in queued|running|done) ;; *) return 1 ;; esac
  [ -d "$job" ] && [ ! -L "$job" ] || return 1
  tmp=$(umask 077; mktemp "$job/.state.XXXXXX") || return 1
  printf '%s\n' "$value" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$job/state"
}

fm_remote_job_read_state() { # <job-dir>
  local job=$1 value extra
  fm_remote_job_regular_bounded "$job/state" 64 || return 1
  IFS= read -r value < "$job/state" || return 1
  if IFS= read -r extra < <(tail -n +2 "$job/state"); then
    : "$extra"
    return 1
  fi
  case "$value" in queued|running|'done') printf '%s\n' "$value" ;; *) return 1 ;; esac
}

fm_remote_job_read_number() { # <job-dir> queue_deadline|timeout|deadline
  local job=$1 field=$2 value
  case "$field" in queue_deadline|timeout|deadline) ;; *) return 1 ;; esac
  fm_remote_job_regular_bounded "$job/$field" 32 || return 1
  value=$(tr -d '\n' < "$job/$field")
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  [ "$value" -gt 0 ] || return 1
  printf '%s\n' "$value"
}

fm_remote_job_write_number() { # <job-dir> queue_deadline|timeout|deadline <value>
  local job=$1 field=$2 value=$3 tmp
  case "$field" in queue_deadline|timeout|deadline) ;; *) return 1 ;; esac
  case "$value" in ''|*[!0-9]*|0) return 1 ;; esac
  [ -d "$job" ] && [ ! -L "$job" ] || return 1
  tmp=$(umask 077; mktemp "$job/.$field.XXXXXX") || return 1
  printf '%s\n' "$value" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$job/$field"
}

fm_remote_job_read_deadline() { # <job-dir>
  fm_remote_job_read_number "$1" deadline
}

fm_remote_job_stage() { # <account-home> <root> <home> <command> [args...]; stdin is captured
  local account_home=$1 root=$2 home=$3 command=$4 stage id destination bytes queue_deadline
  shift 4
  fm_remote_job_prepare_state "$account_home" || return 1
  root=$(fm_remote_job_canonical_existing_dir "$root") || {
    FM_REMOTE_JOB_ERROR="remote job root is unavailable or unsafe"
    return 1
  }
  home=$(fm_remote_job_canonical_home "$home") || {
    FM_REMOTE_JOB_ERROR="remote job home is unavailable or unsafe"
    return 1
  }
  case "$command" in fm-*.sh) ;; *) FM_REMOTE_JOB_ERROR="remote job command is outside the fm-*.sh namespace"; return 1 ;; esac
  case "$command" in */*|*..*) FM_REMOTE_JOB_ERROR="remote job command contains a path or traversal"; return 1 ;; esac
  stage=$(umask 077; mktemp -d "$FM_REMOTE_JOB_JOBS/.stage.XXXXXX") || {
    FM_REMOTE_JOB_ERROR="cannot stage remote job"
    return 1
  }
  chmod 700 "$stage" || { rm -rf -- "$stage"; return 1; }
  queue_deadline=$(( $(date +%s) + FM_REMOTE_JOB_QUEUE_TIMEOUT ))
  if ! printf '%s\n' "$root" > "$stage/root" ||
    ! printf '%s\n' "$home" > "$stage/home" ||
    ! printf '%s\n' "$queue_deadline" > "$stage/queue_deadline" ||
    ! printf '%s\n' "$FM_REMOTE_JOB_TIMEOUT" > "$stage/timeout" ||
    ! printf '%s\0' "$command" "$@" > "$stage/argv" ||
    ! head -c "$((FM_REMOTE_JOB_MAX_BYTES + 1))" > "$stage/stdin"; then
    rm -rf -- "$stage"
    FM_REMOTE_JOB_ERROR="cannot capture remote job input"
    return 1
  fi
  for bytes in root home queue_deadline timeout argv stdin; do chmod 600 "$stage/$bytes" || { rm -rf -- "$stage"; return 1; }; done
  fm_remote_job_regular_bounded "$stage/argv" "$FM_REMOTE_JOB_MAX_BYTES" || {
    rm -rf -- "$stage"
    FM_REMOTE_JOB_ERROR="remote job argv exceeds the ${FM_REMOTE_JOB_MAX_BYTES}-byte bound"
    return 1
  }
  fm_remote_job_regular_bounded "$stage/stdin" "$FM_REMOTE_JOB_MAX_BYTES" || {
    rm -rf -- "$stage"
    FM_REMOTE_JOB_ERROR="remote job stdin exceeds the ${FM_REMOTE_JOB_MAX_BYTES}-byte bound"
    return 1
  }
  : > "$stage/stdout"
  : > "$stage/stderr"
  chmod 600 "$stage/stdout" "$stage/stderr" || { rm -rf -- "$stage"; return 1; }
  fm_remote_job_write_state "$stage" queued || { rm -rf -- "$stage"; return 1; }
  id="job-${stage##*/.stage.}"
  fm_remote_job_safe_id "$id" || { rm -rf -- "$stage"; return 1; }
  destination="$FM_REMOTE_JOB_JOBS/$id"
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || { rm -rf -- "$stage"; return 1; }
  mv -- "$stage" "$destination" || { rm -rf -- "$stage"; return 1; }
  # shellcheck disable=SC2034 # Sourceable API consumed by callers that do not use command substitution.
  FM_REMOTE_JOB_ID=$id
  printf '%s\n' "$id"
}

fm_remote_job_wait() { # <account-home> <id>
  local account_home=$1 id=$2 job state queue_deadline execution_timeout wait_deadline exit_value
  fm_remote_job_prepare_state "$account_home" || return 1
  job=$(fm_remote_job_job_dir "$id") || {
    FM_REMOTE_JOB_ERROR="remote job record disappeared or became unsafe"
    return 1
  }
  queue_deadline=$(fm_remote_job_read_number "$job" queue_deadline) || {
    FM_REMOTE_JOB_ERROR="remote job queue deadline is invalid"
    return 1
  }
  execution_timeout=$(fm_remote_job_read_number "$job" timeout) || {
    FM_REMOTE_JOB_ERROR="remote job execution timeout is invalid"
    return 1
  }
  [ "$execution_timeout" -le 3600 ] || {
    FM_REMOTE_JOB_ERROR="remote job execution timeout is invalid"
    return 1
  }
  wait_deadline=$((queue_deadline + execution_timeout + FM_REMOTE_JOB_WAIT_GRACE))
  while :; do
    state=$(fm_remote_job_read_state "$job" 2>/dev/null || true)
    case "$state" in
      'done')
        if ! fm_remote_job_regular_bounded "$job/stdout" "$FM_REMOTE_JOB_MAX_BYTES" ||
          ! fm_remote_job_regular_bounded "$job/stderr" "$FM_REMOTE_JOB_MAX_BYTES" ||
          ! fm_remote_job_regular_bounded "$job/exit" 32; then
          FM_REMOTE_JOB_ERROR="remote job result is unsafe or exceeds its byte bound"
          return 1
        fi
        exit_value=$(tr -d '\n' < "$job/exit")
        case "$exit_value" in ''|*[!0-9]*) FM_REMOTE_JOB_ERROR="remote job exit status is invalid"; return 1 ;; esac
        [ "$exit_value" -le 255 ] || { FM_REMOTE_JOB_ERROR="remote job exit status is invalid"; return 1; }
        # shellcheck disable=SC2034 # Sourceable API consumed by the entrypoint after this function returns.
        FM_REMOTE_JOB_STDOUT="$job/stdout"
        # shellcheck disable=SC2034 # Sourceable API consumed by the entrypoint after this function returns.
        FM_REMOTE_JOB_STDERR="$job/stderr"
        # shellcheck disable=SC2034 # Sourceable API consumed by the entrypoint after this function returns.
        FM_REMOTE_JOB_EXIT=$exit_value
        return 0
        ;;
      queued|running) ;;
      *) FM_REMOTE_JOB_ERROR="remote job state is invalid"; return 1 ;;
    esac
    if [ "$(date +%s)" -ge "$wait_deadline" ]; then
      FM_REMOTE_JOB_ERROR="remote job did not complete within its bounded wait"
      return 1
    fi
    sleep "$FM_REMOTE_JOB_POLL_SECONDS"
  done
}

fm_remote_job_reap() { # <account-home> <id>; only removes an exact completed record
  local account_home=$1 id=$2 job file
  fm_remote_job_prepare_state "$account_home" || return 1
  job=$(fm_remote_job_job_dir "$id") || return 1
  [ "$(fm_remote_job_read_state "$job")" = 'done' ] || return 1
  for file in root home queue_deadline timeout deadline argv stdin stdout stderr exit state; do
    [ -e "$job/$file" ] || continue
    [ ! -L "$job/$file" ] || return 1
    rm -f -- "$job/$file" || return 1
  done
  if [ -e "$job/.claim" ] || [ -L "$job/.claim" ]; then
    [ -d "$job/.claim" ] && [ ! -L "$job/.claim" ] || return 1
    rm -f -- "$job/.claim/owner" "$job/.claim/supervisor" "$job/.claim/group" "$job/.claim/armed" || return 1
    rmdir "$job/.claim" || return 1
  fi
  rmdir "$job"
}

fm_remote_job_path_mtime() { # <path>
  # The platform override controls worker shape in isolated tests, not the host
  # kernel's stat syntax.
  if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

fm_remote_job_reap_stale() { # <account-home>
  local account_home=$1 job id state mtime now
  fm_remote_job_prepare_state "$account_home" || return 1
  now=$(date +%s)
  for job in "$FM_REMOTE_JOB_JOBS"/job-*; do
    [ -d "$job" ] && [ ! -L "$job" ] || continue
    id=${job##*/}
    fm_remote_job_safe_id "$id" || continue
    state=$(fm_remote_job_read_state "$job" 2>/dev/null || true)
    [ "$state" = 'done' ] || continue
    mtime=$(fm_remote_job_path_mtime "$job" 2>/dev/null || true)
    case "$mtime" in ''|*[!0-9]*) continue ;; esac
    [ $((now - mtime)) -ge "$FM_REMOTE_JOB_REAP_SECONDS" ] || continue
    fm_remote_job_reap "$account_home" "$id" || true
  done
}

fm_remote_job_launchagent_paths() { # <account-home>
  local account_home=$1
  FM_REMOTE_JOB_LAUNCH_AGENT_DIR="$account_home/Library/LaunchAgents"
  FM_REMOTE_JOB_LAUNCH_AGENT_PLIST="$FM_REMOTE_JOB_LAUNCH_AGENT_DIR/$FM_REMOTE_JOB_LABEL.plist"
  FM_REMOTE_JOB_LAUNCH_AGENT_LOG_DIR="$account_home/Library/Logs"
  FM_REMOTE_JOB_LAUNCH_AGENT_LOG="$FM_REMOTE_JOB_LAUNCH_AGENT_LOG_DIR/$FM_REMOTE_JOB_LABEL.log"
}

fm_remote_job_plist_safe_path() {
  case "$1" in *'&'*|*'<'*|*'>'*|*'"'*|*"'"*) return 1 ;; esac
}

fm_remote_job_render_launchagent() { # <remote-root> <account-home>
  local root=$1 account_home=$2 worker
  worker="$root/bin/fm-remote-job-worker.sh"
  fm_remote_job_launchagent_paths "$account_home"
  fm_remote_job_plist_safe_path "$worker" && fm_remote_job_plist_safe_path "$account_home" &&
    fm_remote_job_plist_safe_path "$FM_REMOTE_JOB_LAUNCH_AGENT_LOG" || return 1
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$FM_REMOTE_JOB_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$worker</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>HOME</key>
		<string>$account_home</string>
		<key>FM_ROOT_OVERRIDE</key>
		<string>$root</string>
	</dict>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$FM_REMOTE_JOB_LAUNCH_AGENT_LOG</string>
	<key>StandardErrorPath</key>
	<string>$FM_REMOTE_JOB_LAUNCH_AGENT_LOG</string>
</dict>
</plist>
XML
}

fm_remote_job_launchagent_contract_matches() { # <remote-root> <account-home>
  local root=$1 account_home=$2 actual expected
  fm_remote_job_launchagent_paths "$account_home"
  [ -f "$FM_REMOTE_JOB_LAUNCH_AGENT_PLIST" ] && [ ! -L "$FM_REMOTE_JOB_LAUNCH_AGENT_PLIST" ] || return 1
  actual=$(tr -d ' \t\r\n' < "$FM_REMOTE_JOB_LAUNCH_AGENT_PLIST" 2>/dev/null) || return 1
  expected=$(fm_remote_job_render_launchagent "$root" "$account_home" | tr -d ' \t\r\n') || return 1
  [ "$actual" = "$expected" ]
}

fm_remote_job_gui_available() { # <uid>
  local uid=$1
  command -v launchctl >/dev/null 2>&1 && launchctl print "gui/$uid" >/dev/null 2>&1
}

fm_remote_job_launchagent_loaded() { # <remote-root> <account-home> <uid>
  local root=$1 account_home=$2 uid=$3 worker loaded compact
  fm_remote_job_launchagent_paths "$account_home"
  worker="$root/bin/fm-remote-job-worker.sh"
  loaded=$(launchctl print "gui/$uid/$FM_REMOTE_JOB_LABEL" 2>/dev/null) || return 1
  compact=$(printf '%s' "$loaded" | tr -d ' \t\r\n') || return 1
  [[ "$compact" == *"$FM_REMOTE_JOB_LABEL"* ]] || return 1
  [[ "$compact" == *"$worker"* ]] || return 1
  [[ "$compact" == *"$FM_REMOTE_JOB_LAUNCH_AGENT_PLIST"* ]] || return 1
}

fm_remote_job_worker_pid_path() { printf '%s\n' "$FM_REMOTE_JOB_STATE/worker.pid"; }
fm_remote_job_worker_ready_path() { printf '%s\n' "$FM_REMOTE_JOB_STATE/worker.ready"; }
fm_remote_job_worker_identity_path() { printf '%s\n' "$FM_REMOTE_JOB_STATE/worker.identity"; }
fm_remote_job_worker_lock_path() { printf '%s\n' "$FM_REMOTE_JOB_STATE/worker.lock"; }

fm_remote_job_process_start() {
  local pid=$1 ps_bin value
  if [ -x /bin/ps ]; then ps_bin=/bin/ps; elif [ -x /usr/bin/ps ]; then ps_bin=/usr/bin/ps; else return 1; fi
  value=$("$ps_bin" -p "$pid" -o lstart= 2>/dev/null) || return 1
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$value"
}

fm_remote_job_process_command() {
  local pid=$1 ps_bin value
  if [ -x /bin/ps ]; then ps_bin=/bin/ps; elif [ -x /usr/bin/ps ]; then ps_bin=/usr/bin/ps; else return 1; fi
  value=$("$ps_bin" -p "$pid" -o command= 2>/dev/null) || return 1
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$value"
}

fm_remote_job_read_single_line() {
  local file=$1 max=$2 value extra
  fm_remote_job_regular_bounded "$file" "$max" || return 1
  IFS= read -r value < "$file" || return 1
  if IFS= read -r extra < <(tail -n +2 "$file"); then
    : "$extra"
    return 1
  fi
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

fm_remote_job_lock_owner_matches_process() {
  local account_home=$1 lock pid recorded_start actual_start recorded_command actual_command
  fm_remote_job_prepare_state "$account_home" || return 1
  lock=$(fm_remote_job_worker_lock_path)
  [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
  pid=$(fm_remote_job_read_single_line "$lock/pid" 64) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  recorded_start=$(fm_remote_job_read_single_line "$lock/start" 256) || return 1
  actual_start=$(fm_remote_job_process_start "$pid") || return 1
  [ "$recorded_start" = "$actual_start" ] || return 1
  recorded_command=$(fm_remote_job_read_single_line "$lock/command" 8192) || return 1
  actual_command=$(fm_remote_job_process_command "$pid") || return 1
  [ "$recorded_command" = "$actual_command" ] || return 1
  FM_REMOTE_JOB_OWNER_PID=$pid
}

fm_remote_job_worker_owned_alive() {
  local root=$1 account_home=$2 lock pid pid_file identity_file command ps_bin
  [ "${FM_REMOTE_JOB_ACTIVE:-}" != 1 ] || return 0
  fm_remote_job_prepare_state "$account_home" || return 1
  lock=$(fm_remote_job_worker_lock_path)
  [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
  [ ! -e "$lock/quarantine" ] && [ ! -L "$lock/quarantine" ] || return 1
  pid_file=$(fm_remote_job_worker_pid_path)
  pid=$(fm_remote_job_read_single_line "$pid_file" 64) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  identity_file=$(fm_remote_job_worker_identity_path)
  fm_remote_job_regular_bounded "$identity_file" 256 || return 1
  fm_remote_job_probe "$account_home" || return 1
  if fm_remote_job_lock_owner_matches_process "$account_home"; then
    [ "$pid" = "$FM_REMOTE_JOB_OWNER_PID" ] || return 1
    return 0
  fi
  [ ! -e "$lock/pid" ] && [ ! -L "$lock/pid" ] &&
    [ ! -e "$lock/start" ] && [ ! -L "$lock/start" ] &&
    [ ! -e "$lock/command" ] && [ ! -L "$lock/command" ] || return 1
  if [ -x /bin/ps ]; then ps_bin=/bin/ps; elif [ -x /usr/bin/ps ]; then ps_bin=/usr/bin/ps; else return 1; fi
  command=$("$ps_bin" -p "$pid" -o command= 2>/dev/null) || return 1
  case "$command" in *"$root/bin/fm-remote-job-worker.sh"*) FM_REMOTE_JOB_OWNER_PID=$pid; return 0 ;; esac
  return 1
}

fm_remote_job_code_identity() { # <remote-root> <account-home>
  local root=$1 account_home=$2 git_bin root_hash library_hash worker_hash
  root=$(fm_remote_job_canonical_existing_dir "$root") || return 1
  [ -f "$root/bin/fm-remote-job-lib.sh" ] && [ ! -L "$root/bin/fm-remote-job-lib.sh" ] || return 1
  [ -f "$root/bin/fm-remote-job-worker.sh" ] && [ ! -L "$root/bin/fm-remote-job-worker.sh" ] || return 1
  fm_remote_job_compose_operator_path "$account_home" >/dev/null
  git_bin=$(fm_remote_job_operator_tool git 2>/dev/null || true)
  [ -n "$git_bin" ] || return 1
  root_hash=$(printf '%s' "$root" | "$git_bin" hash-object --stdin 2>/dev/null) || return 1
  library_hash=$("$git_bin" hash-object -- "$root/bin/fm-remote-job-lib.sh" 2>/dev/null) || return 1
  worker_hash=$("$git_bin" hash-object -- "$root/bin/fm-remote-job-worker.sh" 2>/dev/null) || return 1
  case "$root_hash:$library_hash:$worker_hash" in *[!0-9a-f:]*) return 1 ;; esac
  [ -n "$root_hash" ] && [ -n "$library_hash" ] && [ -n "$worker_hash" ] || return 1
  printf '%s:%s:%s\n' "$root_hash" "$library_hash" "$worker_hash"
}

fm_remote_job_worker_identity_matches() { # <remote-root> <account-home>
  local root=$1 account_home=$2 identity_file expected actual extra
  [ "${FM_REMOTE_JOB_ACTIVE:-}" != 1 ] || return 0
  fm_remote_job_prepare_state "$account_home" || return 1
  identity_file=$(fm_remote_job_worker_identity_path)
  fm_remote_job_regular_bounded "$identity_file" 256 || return 1
  IFS= read -r actual < "$identity_file" || return 1
  if IFS= read -r extra < <(tail -n +2 "$identity_file"); then
    : "$extra"
    return 1
  fi
  expected=$(fm_remote_job_code_identity "$root" "$account_home") || return 1
  [ "$actual" = "$expected" ]
}

fm_remote_job_worker_alive() { # <account-home>
  local account_home=$1 pid
  fm_remote_job_prepare_state "$account_home" || return 1
  pid=$(cat "$(fm_remote_job_worker_pid_path)" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

fm_remote_job_probe() { # <account-home>; a fresh worker heartbeat or active job proves readiness
  local account_home=$1 ready lock mtime now
  [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] && return 0
  fm_remote_job_prepare_state "$account_home" || return 1
  lock=$(fm_remote_job_worker_lock_path)
  [ ! -e "$lock/quarantine" ] && [ ! -L "$lock/quarantine" ] || return 1
  ready=$(fm_remote_job_worker_ready_path)
  [ -f "$ready" ] && [ ! -L "$ready" ] || return 1
  mtime=$(fm_remote_job_path_mtime "$ready" 2>/dev/null || true)
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ $((now - mtime)) -le 10 ]
}

fm_remote_job_wait_for_probe() { # <remote-root> <account-home>
  local root=$1 account_home=$2 i=0
  while [ "$i" -lt 200 ]; do
    fm_remote_job_probe "$account_home" && fm_remote_job_worker_identity_matches "$root" "$account_home" && return 0
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

fm_remote_job_write_launchagent() { # <remote-root> <account-home>
  local root=$1 account_home=$2 tmp
  fm_remote_job_launchagent_paths "$account_home"
  if ! mkdir -p "$FM_REMOTE_JOB_LAUNCH_AGENT_DIR" 2>/dev/null ||
    ! mkdir -p "$FM_REMOTE_JOB_LAUNCH_AGENT_LOG_DIR" 2>/dev/null; then
    FM_REMOTE_JOB_ERROR="cannot create the remote job LaunchAgent directories"
    return 1
  fi
  [ -d "$FM_REMOTE_JOB_LAUNCH_AGENT_DIR" ] && [ ! -L "$FM_REMOTE_JOB_LAUNCH_AGENT_DIR" ] || return 1
  [ -d "$FM_REMOTE_JOB_LAUNCH_AGENT_LOG_DIR" ] && [ ! -L "$FM_REMOTE_JOB_LAUNCH_AGENT_LOG_DIR" ] || return 1
  tmp="$FM_REMOTE_JOB_LAUNCH_AGENT_DIR/.$FM_REMOTE_JOB_LABEL.plist.tmp.$$"
  fm_remote_job_render_launchagent "$root" "$account_home" > "$tmp" || {
    rm -f -- "$tmp"
    FM_REMOTE_JOB_ERROR="remote job paths cannot be embedded safely in a property list"
    return 1
  }
  chmod 0644 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$FM_REMOTE_JOB_LAUNCH_AGENT_PLIST" || {
    rm -f -- "$tmp"
    FM_REMOTE_JOB_ERROR="cannot publish $FM_REMOTE_JOB_LAUNCH_AGENT_PLIST"
    return 1
  }
}

fm_remote_job_reload_launchagent() { # <account-home> <uid>
  local account_home=$1 uid=$2 out
  fm_remote_job_launchagent_paths "$account_home"
  launchctl bootout "gui/$uid/$FM_REMOTE_JOB_LABEL" >/dev/null 2>&1 || true
  if ! out=$(launchctl bootstrap "gui/$uid" "$FM_REMOTE_JOB_LAUNCH_AGENT_PLIST" 2>&1); then
    FM_REMOTE_JOB_ERROR="launchctl bootstrap gui/$uid refused: ${out:-no diagnostic}"
    return 1
  fi
  if ! out=$(launchctl kickstart -k "gui/$uid/$FM_REMOTE_JOB_LABEL" 2>&1); then
    FM_REMOTE_JOB_ERROR="launchctl kickstart gui/$uid/$FM_REMOTE_JOB_LABEL refused: ${out:-no diagnostic}"
    return 1
  fi
}

fm_remote_job_start_linux_worker() { # <remote-root> <account-home>
  local root=$1 account_home=$2 worker pid i
  worker="$root/bin/fm-remote-job-worker.sh"
  [ -f "$worker" ] && [ ! -L "$worker" ] && [ -x "$worker" ] || {
    FM_REMOTE_JOB_ERROR="remote job worker is not a genuine executable in the configured code root"
    return 1
  }
  fm_remote_job_prepare_state "$account_home" || return 1
  if fm_remote_job_worker_owned_alive "$root" "$account_home"; then
    if fm_remote_job_worker_identity_matches "$root" "$account_home"; then return 0; fi
    pid=$FM_REMOTE_JOB_OWNER_PID
    kill -TERM "$pid" 2>/dev/null || {
      FM_REMOTE_JOB_ERROR="could not stop the stale remote job worker"
      return 1
    }
    wait "$pid" 2>/dev/null || true
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
      i=$((i + 1))
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      FM_REMOTE_JOB_ERROR="stale remote job worker did not stop safely"
      return 1
    fi
    FM_REMOTE_JOB_REPAIRED=1
  fi
  nohup env \
    HOME="$account_home" \
    FM_ROOT_OVERRIDE="$root" \
    FM_REMOTE_JOB_STATE_ROOT="$FM_REMOTE_JOB_STATE" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE="${FM_REMOTE_JOB_PLATFORM_OVERRIDE:-}" \
    "$worker" >> "$FM_REMOTE_JOB_STATE/logs/$FM_REMOTE_JOB_LABEL.log" 2>&1 < /dev/null &
  pid=$!
  case "$pid" in ''|*[!0-9]*) FM_REMOTE_JOB_ERROR="could not start the remote job worker"; return 1 ;; esac
  FM_REMOTE_JOB_REPAIRED=1
}

fm_remote_job_ensure_worker() { # <remote-root> <account-home>
  local root=$1 account_home=$2 platform uid identity_matches=0
  FM_REMOTE_JOB_ERROR=
  FM_REMOTE_JOB_REPAIRED=0
  root=$(fm_remote_job_canonical_existing_dir "$root") || {
    FM_REMOTE_JOB_ERROR="configured remote root is unavailable or unsafe"
    return 1
  }
  account_home=$(fm_remote_job_canonical_existing_dir "$account_home") || {
    FM_REMOTE_JOB_ERROR="remote account home is unavailable or unsafe"
    return 1
  }
  [ -f "$root/bin/fm-remote-job-worker.sh" ] && [ ! -L "$root/bin/fm-remote-job-worker.sh" ] &&
    [ -x "$root/bin/fm-remote-job-worker.sh" ] || {
    FM_REMOTE_JOB_ERROR="configured remote root has no safe executable remote job worker"
    return 1
  }
  platform=$(fm_remote_job_platform)
  fm_remote_job_worker_identity_matches "$root" "$account_home" && identity_matches=1
  if [ "$platform" = darwin ]; then
    uid=$(id -u 2>/dev/null || true)
    case "$uid" in ''|*[!0-9]*) FM_REMOTE_JOB_ERROR="remote account uid is unavailable; run fm-on.sh <route> fm-remote-doctor.sh --fix"; return 1 ;; esac
    if ! fm_remote_job_gui_available "$uid"; then
      FM_REMOTE_JOB_ERROR="no Aqua login session exists for uid $uid; log that account in at the console, then run fm-on.sh <route> fm-remote-doctor.sh --fix"
      return 1
    fi
    if ! fm_remote_job_launchagent_contract_matches "$root" "$account_home"; then
      fm_remote_job_write_launchagent "$root" "$account_home" || return 1
      FM_REMOTE_JOB_REPAIRED=1
    fi
    if ! fm_remote_job_launchagent_loaded "$root" "$account_home" "$uid" ||
      [ "$FM_REMOTE_JOB_REPAIRED" -eq 1 ] || [ "$identity_matches" -eq 0 ]; then
      fm_remote_job_reload_launchagent "$account_home" "$uid" || return 1
      FM_REMOTE_JOB_REPAIRED=1
    fi
  else
    fm_remote_job_start_linux_worker "$root" "$account_home" || return 1
  fi
  fm_remote_job_wait_for_probe "$root" "$account_home" && return 0
  if [ "$platform" = darwin ]; then
    fm_remote_job_reload_launchagent "$account_home" "$uid" || return 1
    FM_REMOTE_JOB_REPAIRED=1
    fm_remote_job_wait_for_probe "$root" "$account_home" && return 0
  else
    # A replaced Linux supervisor can lose its first ownership race while the
    # prior supervisor finishes releasing the shared worker lock. Retry the
    # idempotent start once, matching the bounded recovery already used above
    # for launchd, before reporting a startup failure.
    fm_remote_job_start_linux_worker "$root" "$account_home" || return 1
    FM_REMOTE_JOB_REPAIRED=1
    fm_remote_job_wait_for_probe "$root" "$account_home" && return 0
  fi
  # shellcheck disable=SC2034 # Sourceable API consumed by the entrypoint and remote doctor.
  FM_REMOTE_JOB_ERROR="remote job worker did not report ready after startup"
  return 1
}
