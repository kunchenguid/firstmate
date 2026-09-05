#!/usr/bin/env bash
# Shared remote fm-on job-worker protocol.
#
# Source this file from the fixed SSH entrypoint, the long-lived worker, or the
# remote doctor. It owns the per-account queue at
# ~/.firstmate/remote-job (override only with FM_REMOTE_JOB_STATE_ROOT for
# isolated tests), the bounded job record, worker installation, and the remote
# runtime PATH.
#
# A published job directory is mode 0700 and contains root, home, argv
# (NUL-delimited), stdin, seq, stdout, stderr, queue_deadline, timeout, and
# state; deadline and exit are added as execution advances, cancel is an
# optional caller-cancellation marker, and .claim may hold owner, owner_start,
# supervisor, supervisor_start, group, group_start, and armed records while
# work executes.
# Stage writes state=queued last. seq is a queue-wide monotonic staging
# sequence reserved atomically by its persistent .seq-claims directory; the
# counter is only a forward-moving allocation hint. If the bounded hint walk
# is exhausted, allocation rescans the claims for the maximum and continues
# above it. Expired claims are reaped by an independently hourly-rate-limited
# sweep. seq is the worker's FIFO ordering key within a home, with the job id
# as the deterministic tiebreak.
# FIFO is defined over completed stagings: a stage that returns before another
# begins executes first; concurrently overlapping stagings have no relative
# ordering contract.
# The worker atomically claims a job with .claim, establishes its execution
# deadline, changes state to running, writes bounded stdout/stderr and exit,
# then publishes state=done last. Callers wait for done, relay stdout and
# stderr separately, then reap only their completed record. Input, argv,
# stdout, and stderr are each capped at 1048576 bytes.
#
# The worker serves one lane per staged home: jobs for the same home run
# strictly FIFO in seq order while lanes for different homes run concurrently,
# so one home's long job never delays another home's commands. Within a lane a
# deliberately long-blocking poll would still serialize that home's short
# interactive commands behind its wait window.
# fm_remote_job_command_preemptible names the read-only long-poll class
# (fm-remote-delta-read.sh, the reply-log delta read). The worker preempts a
# running preemptible job as soon as a non-preemptible job is queued for the
# same home and publishes exit 76 with emptied stdout and stderr, distinct from
# the poll's exit 75 elapsed-window-with-no-data result. The delta read is
# non-destructive and cursor-anchored, so the caller's normal re-arm re-reads
# the same data and a preempted poll loses nothing.
#
# A caller that disconnects before its job completes cancels it instead of
# abandoning it: fm_remote_job_cancel writes a cancel marker into the record,
# the worker skips a cancelled queued job and terminates a running cancelled
# job's process group, and whichever side observes terminal publication reaps
# the finalized record because no result consumer remains. fm_remote_job_wait
# honors an optional FM_REMOTE_JOB_DISCONNECT_PROBE function name. When set,
# the probe runs about once per second; a failure cancels the job and fails
# the wait. The staging entrypoint arms it with a parent-liveness probe so an
# ssh channel
# that dies without delivering a signal still cancels the abandoned job.
# Abandoned .stage.* staging litter older than
# FM_REMOTE_JOB_STAGE_REAP_SECONDS is reaped by the worker's stale sweep.
#
# The worker accepts only a tracked, non-symlink executable named fm-*.sh below
# its configured FM_ROOT/bin. Every child receives env -i with the composed
# PATH, HOME, FM_HOME, FM_ROOT_OVERRIDE, and FM_REMOTE_JOB_ACTIVE=1. The PATH
# is intentionally filesystem-discovered rather than login-shell-derived:
# ~/.local/bin; nvm, asdf, and mise shims/install bins; Nix; Homebrew; and the
# system tail. No shell startup files are evaluated. Each discovered set is
# appended in the shell's own sorted pathname-expansion order, so which install
# of a multi-version tool wins is fixed by this composition rather than by the
# order the filesystem happens to return.
#
# On macOS the worker is Firstmate's Aqua LaunchAgent
# dev.firstmate.remote-job at ~/Library/LaunchAgents/dev.firstmate.remote-job.plist
# with logs under ~/Library/Logs. Linux starts the same worker process without
# an Aqua requirement. The launch-agent renderer and repair helpers here are
# shared by the entrypoint and remote doctor so their ownership cannot drift.
#
# A Linux supervisor holds supervisor.lock across serving-child restarts.
# The Linux start path puts the worker tree in its own process group, so
# stopping a worker signals its restart supervisor, its serving child, and any
# job descendant together instead of leaving a supervisor to restart what was
# just killed. fm_remote_job_stop_worker_tree owns that stop and refuses to
# signal a group whose leader is not itself a worker, and includes sibling
# supervisors bound to the same executable and queue through /proc on Linux.
# A worker inherited
# from an older build or from launchd's own session is still stopped safely as
# a single process. fm_remote_job_root_is_live is the shared predicate for
# whether a worker's code root still exists; bin/fm-remote-job-worker.sh uses
# it to stop itself once its root is pruned, and
# bin/fm-remote-job-reap-orphans.sh uses it to reap workers that were already
# orphaned that way.

FM_REMOTE_JOB_LABEL=dev.firstmate.remote-job
FM_REMOTE_JOB_MAX_BYTES=${FM_REMOTE_JOB_MAX_BYTES:-1048576}
FM_REMOTE_JOB_QUEUE_TIMEOUT=${FM_REMOTE_JOB_QUEUE_TIMEOUT:-360}
FM_REMOTE_JOB_TIMEOUT=${FM_REMOTE_JOB_TIMEOUT:-360}
FM_REMOTE_JOB_WAIT_GRACE=${FM_REMOTE_JOB_WAIT_GRACE:-30}
FM_REMOTE_JOB_POLL_SECONDS=${FM_REMOTE_JOB_POLL_SECONDS:-0.05}
FM_REMOTE_JOB_REAP_SECONDS=${FM_REMOTE_JOB_REAP_SECONDS:-3600}
FM_REMOTE_JOB_STAGE_REAP_SECONDS=${FM_REMOTE_JOB_STAGE_REAP_SECONDS:-600}
FM_REMOTE_JOB_SEQ_CLAIM_REAP_SECONDS=86400
FM_REMOTE_JOB_SEQ_CLAIM_REAP_INTERVAL=3600
# shellcheck disable=SC2034 # Shared protocol constant consumed by the worker and sourcing callers.
FM_REMOTE_JOB_PREEMPTED_EXIT=76
FM_REMOTE_JOB_OPERATOR_PATH=
FM_REMOTE_JOB_CHILD_PATH=
FM_REMOTE_JOB_STATE=
FM_REMOTE_JOB_JOBS=
FM_REMOTE_JOB_SEQ_CLAIMS=
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

fm_remote_job_command_preemptible() { # <staged argv command>
  case "${1:-}" in fm-remote-delta-read.sh) return 0 ;; *) return 1 ;; esac
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
  case "$FM_REMOTE_JOB_STAGE_REAP_SECONDS" in ''|*[!0-9]*|0) return 1 ;; esac
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

# Callers pass an already-expanded glob rather than the pattern, because only
# the shell's own pathname expansion sorts its matches: bash sorts
# glob_filename's result in pathexp.c, while `compgen -G` reaches the same
# glob_filename through pcomplete.c, which does not sort. On bash 3.2 (macOS
# /bin/bash) that handed back raw readdir order, so which install of a
# multi-version tool a remote job resolved depended on the filesystem instead
# of on this composition.
fm_remote_job_append_dirs() { # <expanded glob matches>
  local directory
  for directory in "$@"; do
    fm_remote_job_path_append_if_dir "$directory"
  done
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
  fm_remote_job_append_dirs "$account_home"/.asdf/installs/*/*/bin
  fm_remote_job_path_append_if_dir "$account_home/.local/share/mise/shims"
  fm_remote_job_path_append_if_dir "$account_home/.mise/shims"
  fm_remote_job_append_dirs "$account_home"/.local/share/mise/installs/*/*/bin
  fm_remote_job_append_dirs "$account_home"/.mise/installs/*/*/bin
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
  FM_REMOTE_JOB_SEQ_CLAIMS=$(fm_remote_job_safe_child_dir "$FM_REMOTE_JOB_STATE" .seq-claims) || {
    FM_REMOTE_JOB_ERROR="remote job sequence claims are unsafe"
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

fm_remote_job_remove_claim_records() { # <claim-dir>
  local claim=$1 file
  [ -d "$claim" ] && [ ! -L "$claim" ] || return 1
  for file in "$claim"/owner "$claim"/owner_start "$claim"/supervisor \
    "$claim"/supervisor_start "$claim"/group "$claim"/group_start "$claim"/armed \
    "$claim"/.owner.* "$claim"/.owner_start.* "$claim"/.supervisor.* \
    "$claim"/.supervisor_start.* "$claim"/.group.* "$claim"/.group_start.* \
    "$claim"/.armed.*; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    fm_remote_job_regular_bounded "$file" 256 || return 1
    rm -f -- "$file" || return 1
  done
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

fm_remote_job_read_number() { # <job-dir> queue_deadline|timeout|deadline|seq
  local job=$1 field=$2 value
  case "$field" in queue_deadline|timeout|deadline|seq) ;; *) return 1 ;; esac
  fm_remote_job_regular_bounded "$job/$field" 32 || return 1
  value=$(tr -d '\n' < "$job/$field")
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  [ "$value" -gt 0 ] || return 1
  printf '%s\n' "$value"
}

fm_remote_job_write_number() { # <job-dir> queue_deadline|timeout|deadline|seq <value>
  local job=$1 field=$2 value=$3 tmp
  case "$field" in queue_deadline|timeout|deadline|seq) ;; *) return 1 ;; esac
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

fm_remote_job_advance_seq_hint() { # <value>
  local value=$1 counter current tmp
  counter="$FM_REMOTE_JOB_STATE/seq"
  current=$(cat "$counter" 2>/dev/null || true)
  case "$current" in ''|*[!0-9]*) current=0 ;; esac
  [ "$value" -gt "$current" ] || return 0
  tmp=$(umask 077; mktemp "$FM_REMOTE_JOB_STATE/.seqhint.XXXXXX") || return 1
  printf '%s\n' "$value" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  current=$(cat "$counter" 2>/dev/null || true)
  case "$current" in ''|*[!0-9]*) current=0 ;; esac
  if [ "$value" -gt "$current" ]; then
    mv -f -- "$tmp" "$counter" || { rm -f -- "$tmp"; return 1; }
  else
    rm -f -- "$tmp"
  fi
}

fm_remote_job_next_seq() { # [stage-dir destination]
  local stage=${1:-} destination=${2:-} counter value claim attempt=0 recovered=0 maximum entry
  [ -n "$FM_REMOTE_JOB_STATE" ] && [ -n "$FM_REMOTE_JOB_SEQ_CLAIMS" ] || return 1
  counter="$FM_REMOTE_JOB_STATE/seq"
  value=$(cat "$counter" 2>/dev/null || true)
  case "$value" in ''|*[!0-9]*) value=0 ;; esac
  while :; do
    if [ "$attempt" -ge 100000 ]; then
      [ "$recovered" -eq 0 ] || return 1
      maximum=0
      for entry in "$FM_REMOTE_JOB_SEQ_CLAIMS"/*; do
        [ -d "$entry" ] && [ ! -L "$entry" ] || continue
        entry=${entry##*/}
        case "$entry" in ''|*[!0-9]*|0) continue ;; esac
        [ "$entry" -le "$maximum" ] || maximum=$entry
      done
      value=$maximum
      attempt=0
      recovered=1
    fi
    attempt=$((attempt + 1))
    value=$((value + 1))
    claim="$FM_REMOTE_JOB_SEQ_CLAIMS/$value"
    if (umask 077; mkdir "$claim") 2>/dev/null; then
      chmod 700 "$claim" || return 1
      fm_remote_job_advance_seq_hint "$value" || true
      if [ -n "$stage" ]; then
        if ! fm_remote_job_write_number "$stage" seq "$value" \
          || ! fm_remote_job_write_state "$stage" queued \
          || ! mv -- "$stage" "$destination"; then
          rm -f -- "$stage/state" "$stage/seq"
          return 1
        fi
        rm -f -- "$destination/.owner-pid" "$destination/.owner-start" || true
      fi
      printf '%s\n' "$value"
      return 0
    fi
    [ -d "$claim" ] && [ ! -L "$claim" ] || return 1
  done
}

fm_remote_job_cancelled() { # <job-dir>
  [ -f "$1/cancel" ] && [ ! -L "$1/cancel" ]
}

# Mark a job cancelled on behalf of a disconnected or abandoning caller. The
# marker never rewrites state: the worker observes it, skips a cancelled queued
# job, and stops a running cancelled job's process group. The worker reaps after
# terminal publication; if publication already won the race, this function
# reaps instead. Cancelling a job that disappeared is a harmless no-op.
fm_remote_job_cancel() { # <account-home> <id>
  local account_home=$1 id=$2 job state tmp
  fm_remote_job_prepare_state "$account_home" || return 1
  job=$(fm_remote_job_job_dir "$id" 2>/dev/null) || return 0
  state=$(fm_remote_job_read_state "$job" 2>/dev/null || true)
  if [ "$state" = 'done' ]; then
    fm_remote_job_reap "$account_home" "$id" 2>/dev/null || true
    return 0
  fi
  tmp=$(umask 077; mktemp "$job/.cancel.XXXXXX") || return 1
  printf 'cancelled: caller disconnected or abandoned the job\n' > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$job/cancel" || return 1
  state=$(fm_remote_job_read_state "$job" 2>/dev/null || true)
  if [ "$state" = 'done' ]; then
    fm_remote_job_reap "$account_home" "$id" 2>/dev/null || true
  fi
}

fm_remote_job_stage() { # <account-home> <root> <home> <command> [args...]; stdin is captured
  local account_home=$1 root=$2 home=$3 command=$4 stage id destination bytes queue_deadline owner_start
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
  owner_start=$(fm_remote_job_process_start "$$") || {
    FM_REMOTE_JOB_ERROR="cannot establish remote job staging ownership"
    return 1
  }
  stage=$(umask 077; mktemp -d "$FM_REMOTE_JOB_JOBS/.stage.XXXXXX") || {
    FM_REMOTE_JOB_ERROR="cannot stage remote job"
    return 1
  }
  chmod 700 "$stage" || { rm -rf -- "$stage"; return 1; }
  queue_deadline=$(( $(date +%s) + FM_REMOTE_JOB_QUEUE_TIMEOUT ))
  if ! printf '%s\n' "$$" > "$stage/.owner-pid" ||
    ! printf '%s\n' "$owner_start" > "$stage/.owner-start" ||
    ! chmod 600 "$stage/.owner-pid" "$stage/.owner-start" ||
    ! printf '%s\n' "$root" > "$stage/root" ||
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
  id="job-${stage##*/.stage.}"
  fm_remote_job_safe_id "$id" || { rm -rf -- "$stage"; return 1; }
  destination="$FM_REMOTE_JOB_JOBS/$id"
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || { rm -rf -- "$stage"; return 1; }
  if ! fm_remote_job_next_seq "$stage" "$destination" >/dev/null; then
    rm -rf -- "$stage"
    FM_REMOTE_JOB_ERROR="cannot allocate and publish a remote job staging sequence"
    return 1
  fi
  # shellcheck disable=SC2034 # Sourceable API consumed by callers that do not use command substitution.
  FM_REMOTE_JOB_ID=$id
  printf '%s\n' "$id"
}

fm_remote_job_wait() { # <account-home> <id>; honors FM_REMOTE_JOB_DISCONNECT_PROBE
  local account_home=$1 id=$2 job state queue_deadline execution_timeout wait_deadline exit_value
  local now next_probe=0
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
    now=$(date +%s)
    if [ "$now" -ge "$wait_deadline" ]; then
      FM_REMOTE_JOB_ERROR="remote job did not complete within its bounded wait"
      return 1
    fi
    if [ -n "${FM_REMOTE_JOB_DISCONNECT_PROBE:-}" ] && [ "$now" -ge "$next_probe" ]; then
      next_probe=$((now + 1))
      if ! "$FM_REMOTE_JOB_DISCONNECT_PROBE"; then
        fm_remote_job_cancel "$account_home" "$id" 2>/dev/null || true
        FM_REMOTE_JOB_ERROR="remote job caller disconnected; the job was cancelled"
        return 1
      fi
    fi
    sleep "$FM_REMOTE_JOB_POLL_SECONDS"
  done
}

fm_remote_job_reap() { # <account-home> <id>; only removes an exact completed record
  local account_home=$1 id=$2 job file
  fm_remote_job_prepare_state "$account_home" || return 1
  job=$(fm_remote_job_job_dir "$id") || return 1
  [ "$(fm_remote_job_read_state "$job")" = 'done' ] || return 1
  for file in root home queue_deadline timeout deadline seq cancel argv stdin stdout stderr exit state .owner-pid .owner-start; do
    [ -e "$job/$file" ] || continue
    [ ! -L "$job/$file" ] || return 1
    rm -f -- "$job/$file" || return 1
  done
  if [ -e "$job/.claim" ] || [ -L "$job/.claim" ]; then
    [ -d "$job/.claim" ] && [ ! -L "$job/.claim" ] || return 1
    fm_remote_job_remove_claim_records "$job/.claim" || return 1
    rmdir "$job/.claim" || return 1
  fi
  rmdir "$job"
}

fm_remote_job_path_mtime() { # <path>
  # The platform override controls worker shape in isolated tests, not the host
  # kernel's stat syntax.
  if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

fm_remote_job_stage_owner_alive() { # <stage-dir>
  local stage=$1 pid recorded_start actual_start
  pid=$(fm_remote_job_read_single_line "$stage/.owner-pid" 64 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  recorded_start=$(fm_remote_job_read_single_line "$stage/.owner-start" 256 2>/dev/null) || return 1
  actual_start=$(fm_remote_job_process_start "$pid" 2>/dev/null) || return 1
  fm_remote_job_start_identity_matches "$pid" "$recorded_start" "$actual_start"
}

fm_remote_job_reap_stale() { # <account-home>
  local account_home=$1 job id state mtime now stage claim value marker tmp reap_claims=0
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
  marker="$FM_REMOTE_JOB_STATE/.seq-claims-reaped"
  mtime=$(fm_remote_job_path_mtime "$marker" 2>/dev/null || true)
  case "$mtime" in
    ''|*[!0-9]*) reap_claims=1 ;;
    *) [ $((now - mtime)) -lt "$FM_REMOTE_JOB_SEQ_CLAIM_REAP_INTERVAL" ] || reap_claims=1 ;;
  esac
  if [ "$reap_claims" -eq 1 ]; then
    tmp=$(umask 077; mktemp "$FM_REMOTE_JOB_STATE/.seqreap.XXXXXX") || tmp=
    if [ -n "$tmp" ] && printf '%s\n' "$now" > "$tmp" && chmod 600 "$tmp" \
      && mv -f -- "$tmp" "$marker"; then
      for claim in "$FM_REMOTE_JOB_SEQ_CLAIMS"/*; do
        [ -d "$claim" ] && [ ! -L "$claim" ] || continue
        value=${claim##*/}
        case "$value" in ''|*[!0-9]*|0) continue ;; esac
        mtime=$(fm_remote_job_path_mtime "$claim" 2>/dev/null || true)
        case "$mtime" in ''|*[!0-9]*) continue ;; esac
        [ $((now - mtime)) -ge "$FM_REMOTE_JOB_SEQ_CLAIM_REAP_SECONDS" ] || continue
        rmdir "$claim" 2>/dev/null || true
      done
    else
      [ -z "$tmp" ] || rm -f -- "$tmp"
    fi
  fi
  # Staging litter a killed caller left behind is reaped after its owner is no
  # longer the process that created it and the stage has exceeded the age bound.
  for stage in "$FM_REMOTE_JOB_JOBS"/.stage.*; do
    [ -d "$stage" ] && [ ! -L "$stage" ] || continue
    fm_remote_job_stage_owner_alive "$stage" && continue
    mtime=$(fm_remote_job_path_mtime "$stage" 2>/dev/null || true)
    case "$mtime" in ''|*[!0-9]*) continue ;; esac
    [ $((now - mtime)) -ge "$FM_REMOTE_JOB_STAGE_REAP_SECONDS" ] || continue
    rm -rf -- "$stage"
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

fm_remote_job_process_kernel_start() { # <pid>
  local pid=$1 value boot
  local fields=()
  [ -r "/proc/$pid/stat" ] && [ -r /proc/sys/kernel/random/boot_id ] || return 1
  IFS= read -r value < "/proc/$pid/stat" || return 1
  IFS=' ' read -r -a fields <<< "${value##*) }"
  [ "${#fields[@]}" -gt 19 ] || return 1
  value=${fields[19]}
  IFS= read -r boot < /proc/sys/kernel/random/boot_id || return 1
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  case "$boot" in ''|*[!a-f0-9-]*) return 1 ;; esac
  printf 'linux:%s:%s\n' "$boot" "$value"
}

fm_remote_job_process_start() {
  local pid=$1 ps_bin value
  if [ "${FM_REMOTE_JOB_TEST_DISABLE_KERNEL_CLAIM_IDENTITY:-0}" != 1 ] &&
    [ -r "/proc/$pid/stat" ] && [ -r /proc/sys/kernel/random/boot_id ]; then
    fm_remote_job_process_kernel_start "$pid"
    return
  fi
  if [ -x /bin/ps ]; then ps_bin=/bin/ps; elif [ -x /usr/bin/ps ]; then ps_bin=/usr/bin/ps; else return 1; fi
  value=$(LC_ALL=C TZ=UTC "$ps_bin" -p "$pid" -o lstart= 2>/dev/null) || return 1
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$value"
}

fm_remote_job_start_identity_matches() { # <pid> <recorded> <actual>
  local pid=$1 recorded=$2 actual=$3 ps_bin value entry
  local process_timezone='' process_lc_all='' process_lc_time='' process_lang=''
  local process_language='' process_locpath='' process_tzdir=''
  local locale_environment=(env -i)
  [ "$recorded" = "$actual" ] && return 0
  # Accept existing lstart records while old workers/jobs drain during an
  # upgrade. New kernel identities never take this compatibility path.
  case "$recorded" in linux:*) return 1 ;; esac
  if [ -x /bin/ps ]; then ps_bin=/bin/ps; elif [ -x /usr/bin/ps ]; then ps_bin=/usr/bin/ps; else return 1; fi
  value=$("$ps_bin" -p "$pid" -o lstart= 2>/dev/null) || return 1
  [ "$recorded" = "$value" ] && return 0
  value=$(LC_ALL=C TZ=UTC "$ps_bin" -p "$pid" -o lstart= 2>/dev/null) || return 1
  [ "$recorded" = "$value" ] && return 0
  if [ -r "/proc/$pid/environ" ]; then
    while IFS= read -r -d '' entry; do
      case "$entry" in
        TZ=*) process_timezone=${entry#*=} ;;
        LC_ALL=*) process_lc_all=${entry#*=} ;;
        LC_TIME=*) process_lc_time=${entry#*=} ;;
        LANG=*) process_lang=${entry#*=} ;;
        LANGUAGE=*) process_language=${entry#*=} ;;
        LOCPATH=*) process_locpath=${entry#*=} ;;
        TZDIR=*) process_tzdir=${entry#*=} ;;
      esac
    done < "/proc/$pid/environ" 2>/dev/null
    case "$process_timezone:$process_lc_all:$process_lc_time:$process_lang:$process_language:$process_locpath:$process_tzdir" in
      *$'\n'*|*$'\r'*) return 1 ;;
    esac
    [ -z "$process_timezone" ] || locale_environment+=("TZ=$process_timezone")
    [ -z "$process_lc_all" ] || locale_environment+=("LC_ALL=$process_lc_all")
    [ -z "$process_lc_time" ] || locale_environment+=("LC_TIME=$process_lc_time")
    [ -z "$process_lang" ] || locale_environment+=("LANG=$process_lang")
    [ -z "$process_language" ] || locale_environment+=("LANGUAGE=$process_language")
    [ -z "$process_locpath" ] || locale_environment+=("LOCPATH=$process_locpath")
    [ -z "$process_tzdir" ] || locale_environment+=("TZDIR=$process_tzdir")
    value=$("${locale_environment[@]}" "$ps_bin" -p "$pid" -o lstart= 2>/dev/null) || return 1
    [ "$recorded" = "$value" ] && return 0
  fi
  value=$(env -u TZ "$ps_bin" -p "$pid" -o lstart= 2>/dev/null) || return 1
  [ "$recorded" = "$value" ]
}

fm_remote_job_process_command() {
  local pid=$1 ps_bin value
  if [ -x /bin/ps ]; then ps_bin=/bin/ps; elif [ -x /usr/bin/ps ]; then ps_bin=/usr/bin/ps; else return 1; fi
  value=$("$ps_bin" -p "$pid" -o command= 2>/dev/null) || return 1
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$value"
}

fm_remote_job_process_pgid() { # <pid>
  local pid=$1 ps_bin value
  if [ -x /bin/ps ]; then ps_bin=/bin/ps; elif [ -x /usr/bin/ps ]; then ps_bin=/usr/bin/ps; else return 1; fi
  value=$("$ps_bin" -p "$pid" -o pgid= 2>/dev/null) || return 1
  value=$(printf '%s' "$value" | tr -d '[:space:]')
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$value"
}

# The code root a worker serves is still a genuine Firstmate checkout. A worker
# whose root fails this can never claim, validate, or execute another job, so
# the same predicate decides both self-termination and orphan reaping.
fm_remote_job_root_is_live() { # <remote-root>
  local root=$1
  [ -n "$root" ] || return 1
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  [ -f "$root/AGENTS.md" ] && [ ! -L "$root/AGENTS.md" ] || return 1
  [ -f "$root/bin/fm-remote-job-worker.sh" ] && [ ! -L "$root/bin/fm-remote-job-worker.sh" ]
}

# Linux's adoption parent is not ownership evidence. Bind sibling supervisors
# to the same executable and queue using their kernel environment.
# Never print the environment: it can contain unrelated private values.
fm_remote_job_process_scope() { # <pid>; sets FM_REMOTE_JOB_PROCESS_ROOT/STATE
  local pid=$1 entry root='' state='' account='' argument cwd='' readlink_bin anchored=0
  [ -O "/proc/$pid" ] && [ -r "/proc/$pid/environ" ] || return 1
  while IFS= read -r -d '' entry; do
    case "$entry" in
      FM_ROOT_OVERRIDE=*) root=${entry#*=} ;;
      FM_REMOTE_JOB_STATE_ROOT=*) state=${entry#*=} ;;
      HOME=*) account=${entry#*=} ;;
    esac
  done < "/proc/$pid/environ" 2>/dev/null
  [ -n "$state" ] || state="$account/.firstmate/remote-job"
  case "$root:$state" in *$'\n'*|*$'\r'*) return 1 ;; esac
  case "$root" in /*) ;; *) return 1 ;; esac
  case "$state" in /*) ;; *) return 1 ;; esac
  while IFS= read -r -d '' argument; do
    [ "$argument" != "$root/bin/fm-remote-job-worker.sh" ] || anchored=1
  done < "/proc/$pid/cmdline" 2>/dev/null
  if [ "$anchored" -eq 0 ]; then
    if [ -x /usr/bin/readlink ]; then readlink_bin=/usr/bin/readlink
    elif [ -x /bin/readlink ]; then readlink_bin=/bin/readlink
    else return 1
    fi
    cwd=$("$readlink_bin" "/proc/$pid/cwd" 2>/dev/null) || return 1
    case "$cwd" in
      "$root"|"$root"/*|"$root (deleted)"|"$root"/*" (deleted)") ;;
      *) return 1 ;;
    esac
  fi
  FM_REMOTE_JOB_PROCESS_ROOT=$root
  FM_REMOTE_JOB_PROCESS_STATE=$state
}

fm_remote_job_process_non_zombie() { # <pid>
  local pid=$1 value state
  [ -r "/proc/$pid/stat" ] || return 1
  IFS= read -r value < "/proc/$pid/stat" || return 1
  value=${value##*) }
  state=${value%% *}
  [ -n "$state" ] && [ "$state" != Z ]
}

fm_remote_job_scoped_process_identity() { # <pid> <root> <state>
  local pid=$1 root=$2 state=$3 start group
  fm_remote_job_process_non_zombie "$pid" || return 1
  fm_remote_job_process_scope "$pid" || return 1
  [ "$FM_REMOTE_JOB_PROCESS_ROOT" = "$root" ] &&
    [ "$FM_REMOTE_JOB_PROCESS_STATE" = "$state" ] || return 1
  start=$(fm_remote_job_process_start "$pid") || return 1
  group=$(fm_remote_job_process_pgid "$pid") || return 1
  printf '%s\t%s\n' "$start" "$group"
}

fm_remote_job_scope_snapshot() { # <root> <state>
  local root=$1 state=$2 candidate identity
  for candidate in /proc/[0-9]*; do
    candidate=${candidate##*/}
    [ "$candidate" != "$$" ] || continue
    identity=$(fm_remote_job_scoped_process_identity "$candidate" "$root" "$state" 2>/dev/null || true)
    [ -n "$identity" ] || continue
    printf '%s\t%s\n' "$candidate" "$identity"
  done
}

fm_remote_job_active_claim_identity() { # <job> <state>
  local job=$1 state=$2 record pid recorded_start actual_start group
  record=$(fm_remote_job_claim_record "$job" "$state") || return 1
  IFS=$'\t' read -r pid recorded_start <<< "$record"
  actual_start=$(fm_remote_job_process_start "$pid") || return 1
  fm_remote_job_start_identity_matches "$pid" "$recorded_start" "$actual_start" || return 1
  group=$(fm_remote_job_process_pgid "$pid") || return 1
  [ "$group" = "$pid" ] || return 1
  printf '%s\t%s\t%s\t%s\n' "$pid" "$actual_start" "$group" "$recorded_start"
}

fm_remote_job_claim_record() { # <job> <state>
  local job=$1 state=$2 jobs claim pid recorded_start physical
  jobs="$state/jobs"
  [ -d "$jobs" ] && [ ! -L "$jobs" ] || return 1
  case "$job" in "$jobs"/job-*) ;; *) return 1 ;; esac
  [ -d "$job" ] && [ ! -L "$job" ] || return 1
  physical=$(CDPATH='' cd -- "$job" 2>/dev/null && pwd -P) || return 1
  [ "$physical" = "$job" ] || return 1
  [ "$(fm_remote_job_read_state "$job" 2>/dev/null || true)" = running ] || return 1
  claim="$job/.claim"
  [ -d "$claim" ] && [ ! -L "$claim" ] || return 1
  fm_remote_job_regular_bounded "$claim/armed" 1 || return 1
  pid=$(fm_remote_job_read_single_line "$claim/group" 64) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  recorded_start=$(fm_remote_job_read_single_line "$claim/group_start" 256) || return 1
  printf '%s\t%s\n' "$pid" "$recorded_start"
}

fm_remote_job_active_claim_snapshot() { # <state>
  local state=$1 job record pid recorded_start actual_start group id identity
  for job in "$state"/jobs/job-*; do
    record=$(fm_remote_job_claim_record "$job" "$state" 2>/dev/null || true)
    [ -n "$record" ] || continue
    IFS=$'\t' read -r pid recorded_start <<< "$record"
    actual_start=-
    identity=$(fm_remote_job_active_claim_identity "$job" "$state" 2>/dev/null || true)
    if [ -n "$identity" ]; then
      IFS=$'\t' read -r _ actual_start group _ <<< "$identity"
    else
      group=$pid
    fi
    id=${job##*/}
    fm_remote_job_safe_id "$id" || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$actual_start" "$group" "$recorded_start" "$id"
  done
}

fm_remote_job_invalid_armed_claim_snapshot() { # <state>
  local state=$1 job claim record
  for job in "$state"/jobs/job-*; do
    [ -d "$job" ] && [ ! -L "$job" ] || continue
    [ "$(fm_remote_job_read_state "$job" 2>/dev/null || true)" = running ] || continue
    claim="$job/.claim"
    [ -e "$claim/armed" ] || [ -L "$claim/armed" ] || continue
    record=$(fm_remote_job_claim_record "$job" "$state" 2>/dev/null || true)
    [ -z "$record" ] || continue
    printf '%s\t%s\n' "$claim" 'armed claim record is unreadable or malformed'
  done
}

fm_remote_job_invalid_claim_snapshot_merge() { # <existing> <additional>
  printf '%s\n%s\n' "$1" "$2" | awk -F '\t' 'NF == 2 && !seen[$0]++'
}

fm_remote_job_report_invalid_claims() { # <snapshot>
  local snapshot=$1 claim reason
  while IFS=$'\t' read -r claim reason; do
    [ -n "$claim" ] && [ -n "$reason" ] || continue
    printf 'remote-job: NEEDING MANUAL CLEANUP: invalid armed claim %s: %s\n' "$claim" "$reason" >&2
  done <<< "$snapshot"
}

fm_remote_job_claim_snapshot_merge() { # <existing> <additional>
  printf '%s\n%s\n' "$1" "$2" |
    awk -F '\t' 'NF == 5 && !seen[$1 FS $2]++'
}

fm_remote_job_stop_guard_matches() { # <pid> <start>
  local pid=$1 start=$2 actual_start
  actual_start=$(fm_remote_job_process_start "$pid" 2>/dev/null || true)
  [ -n "$actual_start" ] || return 1
  fm_remote_job_start_identity_matches "$pid" "$start" "$actual_start"
}

fm_remote_job_guarded_signal() { # <guard-pid> <guard-start> <signal> <target>
  local guard_pid=$1 guard_start=$2 signal=$3 target=$4
  if [ -n "$guard_start" ]; then
    fm_remote_job_stop_guard_matches "$guard_pid" "$guard_start" || {
      fm_remote_job_report_stop_guard_mismatch "$guard_pid" "$guard_start"
      return 1
    }
  fi
  kill -"$signal" -- "$target" 2>/dev/null || true
}

fm_remote_job_report_stop_guard_mismatch() { # <pid> <start>
  printf 'remote-job: NEEDING MANUAL CLEANUP: pid %s no longer matches validated identity %s; refusing signal\n' \
    "$1" "$2" >&2
}

fm_remote_job_signal_claim_snapshot() { # <snapshot> <state> <signal> [guard-pid] [guard-start]
  local snapshot=$1 state=$2 signal=$3 guard_pid=${4:-} guard_start=${5:-}
  local pid actual_start group recorded_start id job identity own_group
  own_group=$(fm_remote_job_process_pgid "$$") || return 1
  while IFS=$'\t' read -r pid actual_start group recorded_start id; do
    [ -n "$pid" ] || continue
    case "$recorded_start" in linux:*:*) ;; *) continue ;; esac
    fm_remote_job_safe_id "$id" || continue
    job="$state/jobs/$id"
    identity=$(fm_remote_job_active_claim_identity "$job" "$state" 2>/dev/null || true)
    [ "$identity" = "$pid"$'\t'"$actual_start"$'\t'"$group"$'\t'"$recorded_start" ] || continue
    [ "$group" != "$own_group" ] || continue
    fm_remote_job_guarded_signal "$guard_pid" "$guard_start" "$signal" "-$group" || return 1
  done <<< "$snapshot"
}

fm_remote_job_claim_snapshot_unsafe_groups() { # <snapshot>
  local snapshot=$1 pid actual_start group recorded_start id groups=''
  while IFS=$'\t' read -r pid actual_start group recorded_start id; do
    [ -n "$pid" ] && [ -n "$actual_start" ] && [ -n "$id" ] || continue
    if [ "$actual_start" != - ]; then
      case "$recorded_start" in linux:*:*) continue ;; esac
    fi
    case " $groups " in *" $group "*) ;; *) groups="$groups $group" ;; esac
  done <<< "$snapshot"
  printf '%s\n' "${groups# }"
}

fm_remote_job_report_unsafe_claim_survivors() { # <snapshot>
  local snapshot=$1 pid actual_start group recorded_start id seen='' process_snapshot
  local survivor survivor_group status survivor_start cwd readlink_bin reported=1
  process_snapshot=$(/bin/ps -e -o pid= -o pgid= -o stat= 2>/dev/null) || return 0
  if [ -x /usr/bin/readlink ]; then readlink_bin=/usr/bin/readlink
  elif [ -x /bin/readlink ]; then readlink_bin=/bin/readlink
  else readlink_bin=; fi
  while IFS=$'\t' read -r pid actual_start group recorded_start id; do
    [ -n "$pid" ] && [ -n "$actual_start" ] && [ -n "$id" ] || continue
    if [ "$actual_start" != - ]; then
      case "$recorded_start" in linux:*:*) continue ;; esac
    fi
    while read -r survivor survivor_group status; do
      [ "$survivor_group" = "$group" ] && [[ "$status" != Z* ]] || continue
      case " $seen " in *" $survivor "*) continue ;; esac
      seen="$seen $survivor"
      survivor_start=$(fm_remote_job_process_start "$survivor" 2>/dev/null || printf 'unavailable')
      cwd=unavailable
      [ -z "$readlink_bin" ] || cwd=$("$readlink_bin" "/proc/$survivor/cwd" 2>/dev/null || printf 'unavailable')
      printf 'remote-job: NEEDING MANUAL CLEANUP: active claim pid %s recorded identity %s; surviving pid %s start %s cwd %s\n' \
        "$pid" "$recorded_start" "$survivor" "$survivor_start" "$cwd" >&2
      reported=0
    done <<< "$process_snapshot"
  done <<< "$snapshot"
  return "$reported"
}

fm_remote_job_claim_snapshot_has_live_identity() { # <snapshot>
  local snapshot=$1 process_snapshot pid group status actual_start
  local claim_pid recorded_start recorded_group claim_start _ recorded_boot recorded_ticks actual_boot actual_ticks
  process_snapshot=$(/bin/ps -e -o pid= -o pgid= -o stat= 2>/dev/null) || return 0
  while IFS=$'\t' read -r claim_pid recorded_start recorded_group claim_start _; do
    [ -n "$claim_pid" ] && [ "$recorded_group" = "$claim_pid" ] || continue
    [ "$recorded_start" != - ] || continue
    case "$claim_start" in linux:*:*) ;; *) continue ;; esac
    case "$recorded_start" in linux:*:*) ;; *) return 0 ;; esac
    recorded_boot=${recorded_start#linux:}
    recorded_ticks=${recorded_boot##*:}
    recorded_boot=${recorded_boot%:*}
    case "$recorded_ticks" in ''|*[!0-9]*) return 0 ;; esac
    while read -r pid group status; do
      [ "$group" = "$recorded_group" ] && [[ "$status" != Z* ]] || continue
      actual_start=$(fm_remote_job_process_start "$pid" 2>/dev/null || true)
      case "$actual_start" in linux:*:*) ;; *) return 0 ;; esac
      actual_boot=${actual_start#linux:}
      actual_ticks=${actual_boot##*:}
      actual_boot=${actual_boot%:*}
      case "$actual_ticks" in ''|*[!0-9]*) return 0 ;; esac
      [ "$actual_boot" != "$recorded_boot" ] || [ "$actual_ticks" -lt "$recorded_ticks" ] || return 0
    done <<< "$process_snapshot"
  done <<< "$snapshot"
  return 1
}

fm_remote_job_snapshot_merge() { # <existing> <additional>
  printf '%s\n%s\n' "$1" "$2" |
    awk -F '\t' 'NF == 3 && !seen[$1 FS $2]++'
}

fm_remote_job_snapshot_has_live_identity() { # <snapshot>
  local snapshot=$1 pid recorded_start actual_start
  while IFS=$'\t' read -r pid recorded_start _; do
    [ -n "$pid" ] && [ -n "$recorded_start" ] || continue
    fm_remote_job_process_non_zombie "$pid" || continue
    actual_start=$(fm_remote_job_process_start "$pid" 2>/dev/null || true)
    [ "$actual_start" != "$recorded_start" ] || return 0
  done <<< "$snapshot"
  return 1
}

fm_remote_job_snapshot_group_has_identity() { # <snapshot> <group> <root> <state>
  local snapshot=$1 group=$2 root=$3 state=$4 pid recorded_start recorded_group identity
  while IFS=$'\t' read -r pid recorded_start recorded_group; do
    [ "$recorded_group" = "$group" ] || continue
    identity=$(fm_remote_job_scoped_process_identity "$pid" "$root" "$state" 2>/dev/null || true)
    [ "$identity" = "$recorded_start"$'\t'"$recorded_group" ] && return 0
  done <<< "$snapshot"
  return 1
}

fm_remote_job_group_all_members_scoped() { # <group> <root> <state>
  local group=$1 root=$2 state=$3 process_snapshot pid member_group status found=1 identity
  process_snapshot=$(/bin/ps -e -o pid= -o pgid= -o stat= 2>/dev/null) || return 1
  while read -r pid member_group status; do
    [ "$member_group" = "$group" ] && [[ "$status" != Z* ]] || continue
    identity=$(fm_remote_job_scoped_process_identity "$pid" "$root" "$state" 2>/dev/null || true)
    [ -n "$identity" ] && [ "${identity##*$'\t'}" = "$group" ] || return 1
    found=0
  done <<< "$process_snapshot"
  return "$found"
}

fm_remote_job_signal_scope_snapshot() { # <snapshot> <root> <state> <signal> [excluded-groups] [guard-pid] [guard-start]
  local snapshot=$1 root=$2 state=$3 signal=$4 excluded_groups=${5:-}
  local guard_pid=${6:-} guard_start=${7:-}
  local pid recorded_start group identity own_group
  local groups='' signalled_groups=''
  own_group=$(fm_remote_job_process_pgid "$$") || return 1
  while IFS=$'\t' read -r _ _ group; do
    case " $groups " in *" $group "*) ;; *) groups="$groups $group" ;; esac
  done <<< "$snapshot"
  for group in $groups; do
    if [ "$group" != "$own_group" ] && [[ " $excluded_groups " != *" $group "* ]] &&
      fm_remote_job_group_all_members_scoped "$group" "$root" "$state" &&
      fm_remote_job_snapshot_group_has_identity "$snapshot" "$group" "$root" "$state"; then
      fm_remote_job_guarded_signal "$guard_pid" "$guard_start" "$signal" "-$group" || return 1
      signalled_groups="$signalled_groups $group"
    fi
  done
  while IFS=$'\t' read -r pid recorded_start group; do
    case " $signalled_groups " in *" $group "*) continue ;; esac
    identity=$(fm_remote_job_scoped_process_identity "$pid" "$root" "$state" 2>/dev/null || true)
    [ "$identity" = "$recorded_start"$'\t'"$group" ] || continue
    fm_remote_job_guarded_signal "$guard_pid" "$guard_start" "$signal" "$pid" || return 1
  done <<< "$snapshot"
}

fm_remote_job_recorded_worker_scope() { # <pid>; sets FM_REMOTE_JOB_PROCESS_ROOT/STATE
  local pid=$1 account_home=${HOME:-} lock pid_file recorded_pid recorded_start actual_start supervisor state
  [ -n "$account_home" ] || return 1
  fm_remote_job_prepare_state "$account_home" || return 1
  state=$FM_REMOTE_JOB_STATE
  lock=$(fm_remote_job_worker_lock_path)
  [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
  pid_file=$(fm_remote_job_worker_pid_path)
  recorded_pid=$(fm_remote_job_read_single_line "$pid_file" 64) || return 1
  [ "$recorded_pid" = "$pid" ] || return 1
  recorded_pid=$(fm_remote_job_read_single_line "$lock/pid" 64) || return 1
  [ "$recorded_pid" = "$pid" ] || return 1
  recorded_start=$(fm_remote_job_read_single_line "$lock/start" 256) || return 1
  actual_start=$(fm_remote_job_process_start "$pid" 2>/dev/null || true)
  [ -n "$actual_start" ] || return 1
  fm_remote_job_start_identity_matches "$pid" "$recorded_start" "$actual_start" || return 1
  fm_remote_job_process_non_zombie "$pid" && return 1
  fm_remote_job_lock_owner_matches_process "$account_home" "$state/supervisor.lock" || return 1
  supervisor=$FM_REMOTE_JOB_OWNER_PID
  fm_remote_job_process_scope "$supervisor" || return 1
  [ "$FM_REMOTE_JOB_PROCESS_STATE" = "$state" ] || return 1
}

fm_remote_job_stop_worker_tree() { # <pid> [validated-start]
  local pid=$1 expected_start=${2:-} root state signal current known='' claim_current claim_known='' legacy_groups
  local invalid_current invalid_known='' current_groups kill_current kill_groups i actual_start recorded_start
  local snapshot_waited=0 snapshot_fifo=${FM_REMOTE_JOB_TEST_STOP_SNAPSHOT_FIFO:-}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  if [ -n "$expected_start" ] && ! fm_remote_job_stop_guard_matches "$pid" "$expected_start"; then
    fm_remote_job_report_stop_guard_mismatch "$pid" "$expected_start"
    return 1
  fi
  if fm_remote_job_process_scope "$pid" || fm_remote_job_recorded_worker_scope "$pid"; then
    root=$FM_REMOTE_JOB_PROCESS_ROOT
    state=$FM_REMOTE_JOB_PROCESS_STATE
    for signal in TERM KILL; do
      current=$(fm_remote_job_scope_snapshot "$root" "$state") || return 1
      known=$(fm_remote_job_snapshot_merge "$known" "$current") || return 1
      claim_current=$(fm_remote_job_active_claim_snapshot "$state") || return 1
      claim_known=$(fm_remote_job_claim_snapshot_merge "$claim_known" "$claim_current") || return 1
      invalid_current=$(fm_remote_job_invalid_armed_claim_snapshot "$state") || return 1
      invalid_known=$(fm_remote_job_invalid_claim_snapshot_merge "$invalid_known" "$invalid_current") || return 1
      legacy_groups=$(fm_remote_job_claim_snapshot_unsafe_groups "$claim_known") || return 1
      if [ -n "$invalid_known" ]; then
        current_groups=$(printf '%s\n' "$current" |
          awk -F '\t' 'NF == 3 && !seen[$3]++ { groups = groups separator $3; separator = " " } END { print groups }')
        legacy_groups="${legacy_groups:+$legacy_groups }$current_groups"
      fi
      if [ "$snapshot_waited" -eq 0 ] && [ -n "$snapshot_fifo" ]; then
        case "$snapshot_fifo" in /*) ;; *) return 1 ;; esac
        [ -p "$snapshot_fifo" ] || return 1
        IFS= read -r _ < "$snapshot_fifo" || return 1
        snapshot_waited=1
      fi
      if [ -n "$expected_start" ] && ! fm_remote_job_stop_guard_matches "$pid" "$expected_start"; then
        fm_remote_job_report_stop_guard_mismatch "$pid" "$expected_start"
        return 1
      fi
      if [ -n "$current" ] &&
        ! fm_remote_job_signal_scope_snapshot "$current" "$root" "$state" "$signal" "$legacy_groups" \
          "$pid" "$expected_start"; then
        return 1
      fi
      if [ -n "$invalid_known" ]; then
        kill_current=$(fm_remote_job_scope_snapshot "$root" "$state") || return 1
        kill_groups=$(printf '%s\n' "$kill_current" |
          awk -F '\t' 'NF == 3 && !seen[$3]++ { groups = groups separator $3; separator = " " } END { print groups }')
        if [ -n "$kill_current" ] &&
          ! fm_remote_job_signal_scope_snapshot "$kill_current" "$root" "$state" KILL "$kill_groups" \
            "$pid" "$expected_start"; then
          return 1
        fi
        fm_remote_job_report_invalid_claims "$invalid_known"
        return 1
      fi
      if [ -n "$claim_current" ] &&
        ! fm_remote_job_signal_claim_snapshot "$claim_current" "$state" "$signal" "$pid" "$expected_start"; then
        return 1
      fi
      i=0
      while [ "$i" -lt 50 ]; do
        current=$(fm_remote_job_scope_snapshot "$root" "$state") || return 1
        known=$(fm_remote_job_snapshot_merge "$known" "$current") || return 1
        claim_current=$(fm_remote_job_active_claim_snapshot "$state") || return 1
        claim_known=$(fm_remote_job_claim_snapshot_merge "$claim_known" "$claim_current") || return 1
        invalid_current=$(fm_remote_job_invalid_armed_claim_snapshot "$state") || return 1
        invalid_known=$(fm_remote_job_invalid_claim_snapshot_merge "$invalid_known" "$invalid_current") || return 1
        if [ -n "$invalid_known" ]; then
          fm_remote_job_report_invalid_claims "$invalid_known"
          return 1
        fi
        if ! fm_remote_job_snapshot_has_live_identity "$known" &&
          ! fm_remote_job_claim_snapshot_has_live_identity "$claim_known"; then
          if fm_remote_job_report_unsafe_claim_survivors "$claim_known"; then
            return 1
          fi
          return 0
        fi
        i=$((i + 1))
        sleep 0.1
      done
    done
    return 1
  fi
  if [ -n "$expected_start" ]; then
    recorded_start=$expected_start
  else
    recorded_start=$(fm_remote_job_process_start "$pid") || return 1
  fi
  for signal in TERM KILL; do
    actual_start=$(fm_remote_job_process_start "$pid" 2>/dev/null || true)
    if ! fm_remote_job_start_identity_matches "$pid" "$recorded_start" "$actual_start"; then
      if [ -n "$expected_start" ]; then
        fm_remote_job_report_stop_guard_mismatch "$pid" "$expected_start"
        return 1
      fi
      return 0
    fi
    fm_remote_job_guarded_signal "$pid" "$expected_start" "$signal" "$pid" || return 1
    i=0
    while [ "$i" -lt 50 ]; do
      actual_start=$(fm_remote_job_process_start "$pid" 2>/dev/null || true)
      [ "$actual_start" = "$recorded_start" ] || return 0
      i=$((i + 1))
      sleep 0.1
    done
  done
  return 1
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
  lock=${2:-$(fm_remote_job_worker_lock_path)}
  [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
  pid=$(fm_remote_job_read_single_line "$lock/pid" 64) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  recorded_start=$(fm_remote_job_read_single_line "$lock/start" 256) || return 1
  actual_start=$(fm_remote_job_process_start "$pid") || return 1
  fm_remote_job_start_identity_matches "$pid" "$recorded_start" "$actual_start" || return 1
  recorded_command=$(fm_remote_job_read_single_line "$lock/command" 8192) || return 1
  actual_command=$(fm_remote_job_process_command "$pid") || return 1
  [ "$recorded_command" = "$actual_command" ] || return 1
  FM_REMOTE_JOB_OWNER_PID=$pid
  FM_REMOTE_JOB_OWNER_START=$recorded_start
}

fm_remote_job_supervisor_lease_root_matches() { # <remote-root> <account-home>
  local root=$1 account_home=$2 lock recorded_root
  fm_remote_job_prepare_state "$account_home" || return 1
  lock="$FM_REMOTE_JOB_STATE/supervisor.lock"
  fm_remote_job_lock_owner_matches_process "$account_home" "$lock" || return 1
  recorded_root=$(fm_remote_job_read_single_line "$lock/root" 8192) || return 1
  [ "$recorded_root" = "$root" ]
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
  # Ownership is process identity, not readiness. A delayed heartbeat must not
  # authorize a second supervisor for the same live owner.
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
  local root=$1 account_home=$2 worker pid owner_start
  worker="$root/bin/fm-remote-job-worker.sh"
  [ -f "$worker" ] && [ ! -L "$worker" ] && [ -x "$worker" ] || {
    FM_REMOTE_JOB_ERROR="remote job worker is not a genuine executable in the configured code root"
    return 1
  }
  fm_remote_job_prepare_state "$account_home" || return 1
  if fm_remote_job_worker_owned_alive "$root" "$account_home"; then
    if fm_remote_job_worker_identity_matches "$root" "$account_home"; then return 0; fi
    # The owner pid is the serving child; its restart supervisor sits above it
    # and would immediately replace a lone process kill, so stop the whole
    # worker tree through its isolated group.
    pid=$FM_REMOTE_JOB_OWNER_PID
    fm_remote_job_stop_worker_tree "$pid" || {
      FM_REMOTE_JOB_ERROR="stale remote job worker did not stop safely"
      return 1
    }
    wait "$pid" 2>/dev/null || true
    FM_REMOTE_JOB_REPAIRED=1
  elif fm_remote_job_lock_owner_matches_process "$account_home" "$FM_REMOTE_JOB_STATE/supervisor.lock"; then
    pid=$FM_REMOTE_JOB_OWNER_PID
    owner_start=$FM_REMOTE_JOB_OWNER_START
    if fm_remote_job_supervisor_lease_root_matches "$root" "$account_home"; then return 0; fi
    fm_remote_job_stop_worker_tree "$pid" "$owner_start" || {
      FM_REMOTE_JOB_ERROR="stale remote job supervisor did not stop safely"
      return 1
    }
    wait "$pid" 2>/dev/null || true
    FM_REMOTE_JOB_REPAIRED=1
  fi
  # Job control puts the worker tree in its own process group, so a later stop
  # can signal every descendant at once without ever reaching the caller's own
  # group. Without this the group of a leaked worker is the launching command's.
  set -m
  (
    cd "$root" || exit 1
    exec nohup env \
      HOME="$account_home" \
      FM_ROOT_OVERRIDE="$root" \
      FM_REMOTE_JOB_STATE_ROOT="$FM_REMOTE_JOB_STATE" \
      FM_REMOTE_JOB_PLATFORM_OVERRIDE="${FM_REMOTE_JOB_PLATFORM_OVERRIDE:-}" \
      "$worker" >> "$FM_REMOTE_JOB_STATE/logs/$FM_REMOTE_JOB_LABEL.log" 2>&1 < /dev/null
  ) &
  pid=$!
  set +m
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
