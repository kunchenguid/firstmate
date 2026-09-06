#!/usr/bin/env bash
# Shared durable wake queue and portable lock helpers.

FM_WAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WAKE_DEFAULT_ROOT="$(cd "$FM_WAKE_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_WAKE_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
FM_WAKE_QUEUE_LOCK="${FM_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"
FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-2}"
# Resolved once at source time: fm_pid_identity and fm_path_mtime run inside 0.2s
# confirm and 0.5s attach polls, and forking uname per call is a measurable cost on
# the platform (Git Bash/MSYS) that already pays the highest fork price.
_FM_UNAME=$(uname 2>/dev/null || echo unknown)
mkdir -p "$STATE"

# Most wake-library consumers need only queue and lock primitives, including
# deliberately minimal recovery fixtures and remote installations.
# Load the classifier only when a status presentation helper is actually used.
_fm_wake_require_classify() {
  command -v status_observed_signature >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-classify-lib.sh
  . "$FM_WAKE_LIB_DIR/fm-classify-lib.sh"
}

# Load the bounded-execution owner only for callers that use the presentation
# lock deadline. Most wake-library consumers need no timeout machinery.
_fm_wake_require_timeout() {
  command -v fm_run_timed >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$FM_WAKE_LIB_DIR/fm-timeout-lib.sh"
}

# Pass a variable name to capture this frame's pid without forking it in $().
# On Bash 3.2, exec a child shell so its PPID identifies this frame, unlike $$.
fm_current_pid() {  # [output-variable]
  local fm_pid
  fm_pid=${BASHPID:-$(exec sh -c 'printf "%s\n" "$PPID"')} || return 1
  case "$fm_pid" in ''|*[!0-9]*|0) return 1 ;; esac
  if [ "$#" -gt 0 ]; then
    printf -v "$1" '%s' "$fm_pid"
  else
    printf '%s\n' "$fm_pid"
  fi
}

fm_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

fm_pid_identity() {
  local pid=$1 out proc_root stat_line starttime cmdline_hex identity_key
  local -a stat_fields
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  # Prefer a Linux-compatible /proc when present: stat field 22 (starttime, clock ticks since boot) is
  # immune to the wall-clock steps that re-render the ps lstart fallback's date
  # (observed as WSL2 btime drift) and would evict a live watcher; combining the
  # full NUL-separated cmdline keeps PID reuse a mismatch even on a tick collision.
  # Git Bash/MSYS exposes these compatible files but its Cygwin ps rejects the
  # portable fallback's -o fields, so capability detection must not key on uname.
  if [ -r "$proc_root/$pid/stat" ] && [ -r "$proc_root/$pid/cmdline" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    # After the final comm delimiter, array index 19 is proc stat field 22.
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in
      ''|*[!0-9]*) return 1 ;;
    esac
    cmdline_hex=$(od -An -v -tx1 "$proc_root/$pid/cmdline" 2>/dev/null | tr -d '[:space:]') || return 1
    [ -n "$cmdline_hex" ] || return 1
    identity_key=proc-starttime
    [ "$_FM_UNAME" != Linux ] || identity_key=linux-starttime
    printf '%s=%s cmdline-hex=%s\n' "$identity_key" "$starttime" "$cmdline_hex"
    return 0
  fi
  # Pin LC_ALL=C so lstart's date format is locale-invariant: the identity is
  # written under one locale but re-read under the machine's ambient locale, which
  # would otherwise mismatch on a non-C locale (e.g. ko_KR) and reject a live watcher.
  out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}

fm_path_mtime() {
  if [ "$_FM_UNAME" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_path_age() {
  local path=$1 m
  m=$(fm_path_mtime "$path") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# fm_watcher_lock_unheld <state>
# True when the watcher lock or its symlinked owner directory is absent, or when
# the existing lock records no pid at all. Any non-empty pid remains held here;
# its syntax, liveness, ownership metadata, and identity are health concerns.
fm_watcher_lock_unheld() {
  local state=$1 lockdir pid
  lockdir="$state/.watch.lock"
  [ ! -e "$lockdir" ] && return 0
  [ ! -e "$lockdir/pid" ] && return 0
  pid=$(cat "$lockdir/pid" 2>/dev/null) || return 1
  [ -z "$pid" ]
}

FM_WATCHER_MATCHED_IDENTITY=
fm_watcher_lock_matches_pid() {
  local state=$1 watch_path=$2 pid=$3 home=${4:-$FM_HOME} lockdir lock_home lock_path lock_identity current_identity
  FM_WATCHER_MATCHED_IDENTITY=
  lockdir="$state/.watch.lock"
  lock_home=$(cat "$lockdir/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$lockdir/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$home" ] || return 1
  [ "$lock_path" = "$watch_path" ] || return 1
  [ -n "$lock_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$current_identity" = "$lock_identity" ] || return 1
  FM_WATCHER_MATCHED_IDENTITY=$lock_identity
}

# Reclaim a watcher lock only when its live pid has provably been reused by an
# unrelated process. The watcher-specific metadata and identity are rechecked
# under the lock's steal mutex before durable recovery evidence precedes removal.
# No process is signalled: the live pid is demonstrably not the recorded watcher.
fm_watcher_reclaim_reused_pid_lock() {  # <state-dir> <watch-path> [home]
  local state=$1 watch_path=$2 home=${3:-$FM_HOME} lockdir steal pid recorded current lock_home lock_path owner steal_owner rc=1
  lockdir="$state/.watch.lock"
  steal="$lockdir.steal"
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  recorded=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  lock_home=$(cat "$lockdir/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$lockdir/watcher-path" 2>/dev/null || true)
  [ "$lock_home" = "$home" ] && [ "$lock_path" = "$watch_path" ] || return 1
  [ -n "$recorded" ] && fm_pid_alive "$pid" || return 1
  current=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -n "$current" ] && [ "$current" != "$recorded" ] || return 1

  owner=
  [ ! -L "$lockdir" ] || owner=$(fm_lock_link_owner "$lockdir" 2>/dev/null) || return 1
  fm_lock_try_acquire "$steal" || return 1
  steal_owner=${FM_LOCK_OWNER_DIR:-}
  if fm_lock_points_to_owner "$steal" "$steal_owner"; then
    if [ -n "$owner" ]; then
      fm_lock_points_to_owner "$lockdir" "$owner" || {
        fm_lock_release "$steal"
        return 1
      }
    elif [ ! -d "$lockdir" ] || [ -L "$lockdir" ]; then
      fm_lock_release "$steal"
      return 1
    fi
    pid=$(cat "$lockdir/pid" 2>/dev/null || true)
    recorded=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
    lock_home=$(cat "$lockdir/fm-home" 2>/dev/null || true)
    lock_path=$(cat "$lockdir/watcher-path" 2>/dev/null || true)
    current=$(fm_pid_identity "$pid" 2>/dev/null || true)
    if [ "$lock_home" = "$home" ] && [ "$lock_path" = "$watch_path" ] \
      && [ -n "$recorded" ] && fm_pid_alive "$pid" \
      && [ -n "$current" ] && [ "$current" != "$recorded" ] \
      && fm_recovery_transition "$state/.watcher-down" clear-stale-lock "$lockdir" downtime; then
      rc=0
    fi
  fi
  fm_lock_release "$steal"
  return "$rc"
}

FM_WATCHER_HEALTHY_PID=
FM_WATCHER_HEALTHY_IDENTITY=
fm_watcher_healthy() {
  local state=$1 watch_path=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME} lockdir beat pid identity age
  FM_WATCHER_HEALTHY_PID=
  FM_WATCHER_HEALTHY_IDENTITY=
  lockdir="$state/.watch.lock"
  beat="$state/.last-watcher-beat"
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  fm_watcher_lock_matches_pid "$state" "$watch_path" "$pid" "$home" || return 1
  identity=$FM_WATCHER_MATCHED_IDENTITY
  age=$(fm_path_age "$beat")
  [ "$age" -lt "$grace" ] || return 1
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_healthy returns.
  FM_WATCHER_HEALTHY_PID=$pid
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_healthy returns.
  FM_WATCHER_HEALTHY_IDENTITY=$identity
  return 0
}

# fm_watcher_healthy above is the PID-STRICT primitive: true only when a live,
# identity-matched watcher PROCESS holds this home's lock with a fresh beacon.
# The arm layer (bin/fm-watch-arm.sh, bin/fm-claude-stop-autoarm.sh) and
# bin/fm-turnend-guard.sh need exactly that at the turn boundary, so a leftover
# beacon must never satisfy them. The model-aware classifiers below remain for
# harness classification and regression compatibility; bin/fm-guard.sh no
# longer asks them to report watcher liveness.

# fm_supervision_model
# Print the supervision model of this home's PRIMARY harness:
#   autoarm     Claude's Stop-hook auto-arm and Cursor's stop-hook park: the
#               watcher is armed at each turn end and exits on its wake, so it
#               runs only BETWEEN turns. Mid-turn a fresh beacon with no live
#               watcher process is the healthy state.
#   extension   Pi (and pi-signed): .pi/extensions/fm-primary-pi-watch.ts owns
#               continuity. It tears the watcher down on every actionable wake and
#               spawns the replacement itself, so a genuinely unheld singleton lock
#               is healthy during that hand-off only with extension ownership and a
#               fresh beacon. Any held but unhealthy lock remains down.
#   persistent  every other harness (codex foreground checkpoint, opencode/grok
#               background arm, tmux, unknown): the watcher runs as a tracked live
#               process, so a live identity-matched pid is the real liveness signal.
# FM_SUPERVISION_MODEL overrides detection (tests, and callers that already know
# the harness). Otherwise bin/fm-harness.sh is the single detection owner, so this
# stays consistent with the harness-specific repair line the guards already emit.
fm_supervision_model() {
  local harness
  case "${FM_SUPERVISION_MODEL:-}" in
    autoarm|extension|persistent) printf '%s\n' "$FM_SUPERVISION_MODEL"; return 0 ;;
  esac
  harness=$("$FM_WAKE_LIB_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
  case "$harness" in
    claude|cursor) printf 'autoarm\n' ;;
    pi|pi-signed|omp) printf 'extension\n' ;;
    *) printf 'persistent\n' ;;
  esac
}

# Pi primary supervision evidence. The Pi extensions record, in their state
# markers, the exact build they loaded and the session process that loaded it, so
# "a live Pi session owns supervision" is provable from durable state without a
# watcher process and without reading any vendor-rendered surface.
#
# fm_pi_extension_version <file>
# Print the marker version string the Pi extensions record for <file>. Must stay
# byte-identical to the "sha256:<hex>" digest .pi/extensions/fm-primary-pi-watch.ts
# and .pi/extensions/fm-primary-turnend-guard.ts compute for themselves; a host
# with no SHA-256 tool falls back to a form no marker can match, which keeps every
# consumer loud rather than silently satisfied.
fm_pi_extension_version() {
  local file=$1
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print "sha256:" $1}'
  else
    cksum "$file" | awk '{print "cksum:" $1 ":" $2}'
  fi
}

# fm_pi_extension_loaded <marker> <expected-version> <session-lock>
# True when <marker> records <expected-version> and names the session process in
# <session-lock>, i.e. the session holding this home loaded exactly this build.
fm_pi_extension_loaded() {
  local marker=$1 expected_version=$2 lock=$3 marker_version marker_pid lock_pid
  [ -f "$marker" ] && [ -f "$lock" ] && [ -n "$expected_version" ] || return 1
  marker_version=$(sed -n '1p' "$marker")
  marker_pid=$(sed -n '2p' "$marker")
  lock_pid=$(sed -n '1p' "$lock")
  [ -n "$marker_pid" ] || return 1
  [ "$marker_version" = "$expected_version" ] && [ "$marker_pid" = "$lock_pid" ]
}

# fm_pi_extension_owns_supervision <state> <root>
# True when a LIVE Pi session owns supervision continuity for this home: both
# primary extensions are loaded at their current on-disk builds by the process
# recorded in this home's session lock, and that process is still alive.
# Requiring the turn-end guard extension too is deliberate - it is the structural
# backstop that catches a cycle the watch extension failed to restore, so a home
# missing it has no benign hand-off to tolerate.
fm_pi_extension_owns_supervision() {
  fm_extension_pair_owns_supervision "$1" "$2/.pi/extensions" \
    "fm-primary-pi-watch.ts:.pi-watch-extension-loaded" \
    "fm-primary-turnend-guard.ts:.pi-turnend-extension-loaded"
}

# fm_omp_extension_owns_supervision <state> <root>
# The omp (Oh My Pi) primary's proof, keyed on its own two tracked extensions
# under .omp/extensions/ and their own state markers. It is a separate proof on
# purpose: omp must never inherit the Pi tolerance by accident, and a Pi home
# never satisfies the omp markers. Both proofs bind to the pid in state/.lock,
# so a session on one harness cannot vouch for a home held by the other.
fm_omp_extension_owns_supervision() {
  fm_extension_pair_owns_supervision "$1" "$2/.omp/extensions" \
    "fm-primary-omp-watch.ts:.omp-watch-extension-loaded" \
    "fm-primary-turnend-guard.ts:.omp-turnend-extension-loaded"
}

# fm_extension_owns_supervision <state> <root>
# The extension-model proof the verdict below consults: whichever extension
# family's markers the lock-owning session recorded. Exactly one family can
# match because both bind to the same lock pid.
fm_extension_owns_supervision() {
  fm_pi_extension_owns_supervision "$1" "$2" || fm_omp_extension_owns_supervision "$1" "$2"
}

fm_extension_pair_owns_supervision() {  # <state> <extension-dir> <source:marker>...
  local state=$1 dir=$2 lock session_pid pair source marker version
  shift 2
  lock="$state/.lock"
  for pair in "$@"; do
    source=${pair%%:*}
    marker=${pair#*:}
    version=$(fm_pi_extension_version "$dir/$source") || return 1
    fm_pi_extension_loaded "$state/$marker" "$version" "$lock" || return 1
  done
  session_pid=$(sed -n '1p' "$lock" 2>/dev/null)
  fm_pid_alive "$session_pid"
}

# Away-mode supervision evidence. While state/.afk exists the away-mode daemon
# (bin/fm-supervise-daemon.sh) owns supervision: it runs bin/fm-watch.sh
# one-shot, so the watcher exits on EVERY wake and the daemon starts its
# replacement. Between those cycles no watcher process holds the watch lock,
# with nothing at all wrong - the supervisor is the daemon, and the watcher is
# its restarting child.
#
# fm_afk_daemon_owns_supervision <state>
# True when away mode is active AND a live, identity-matched daemon holds this
# home's singleton daemon lock. The identity match is the same discipline the
# watcher lock uses (fm_watcher_lock_matches_pid): a recycled pid, a lock left
# by a killed daemon, or a daemon that never recorded its identity all fail it,
# so only a daemon process that is genuinely still running counts as ownership.
# This proves an OWNER, never freshness: callers keep their own beacon test, so
# a daemon that stops restarting its watcher still fails supervision once the
# beacon passes grace.
fm_afk_daemon_owns_supervision() {
  local state=$1 lockdir pid recorded current
  [ -e "$state/.afk" ] || return 1
  lockdir="$state/.supervise-daemon.lock"
  pid=$(cat "$lockdir/pid" 2>/dev/null) || return 1
  fm_pid_alive "$pid" || return 1
  recorded=$(cat "$lockdir/pid-identity" 2>/dev/null) || return 1
  [ -n "$recorded" ] || return 1
  current=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -n "$current" ] || return 1
  [ "$current" = "$recorded" ]
}

# fm_watcher_supervision_verdict <state> <watch-path> [grace] [home] [root]
# Compatibility classifier for the former model-aware pull warning; no current
# guard consumes this verdict. The arm layer and turn-end guard use the strict
# fm_watcher_healthy predicate instead. Sets:
#   FM_WATCHER_VERDICT_OK      true when supervision is healthy for this model
#   FM_WATCHER_VERDICT_REASON  when not ok:
#                              no-watcher   - a live watcher process is the real
#                                             signal for this model but none holds
#                                             the lock while the beacon is fresh
#                              stale-beacon - the beacon is stale beyond grace or
#                                             absent
# autoarm: a fresh beacon within grace is healthy even with no live watcher,
# because the watcher runs only between turns.
# extension: a live identity-matched watcher is healthy; a genuinely unheld lock
# is also healthy while the beacon is fresh and a live Pi or omp session provably
# owns continuity through fm_extension_owns_supervision. A lock with any recorded
# pid is unhealthy if the strict check fails.
# persistent: require a live identity-matched watcher with a fresh beacon; a
# fresh leftover beacon with no live watcher is unhealthy.
# shellcheck disable=SC2034 # Read by callers after the function returns.
FM_WATCHER_VERDICT_OK=false
# shellcheck disable=SC2034 # Read by callers after the function returns.
FM_WATCHER_VERDICT_REASON=stale-beacon
# Exit status bin/fm-watch.sh uses for the one refusal that is NOT a failure:
# the singleton lock is held by a live, identity-matched watcher of this home
# whose beacon has gone stale. It is distinct from every other nonzero exit so
# bin/fm-watch-arm.sh can WAIT for that holder instead of reporting a working
# fleet's supervision as broken.
#
# Before the beacon was beaten at every phase boundary (2026-09-04 supervision
# investigation) this was the routine reading of a perfectly healthy watcher
# whose single poll iteration had simply outgrown the grace, and the arm layer's
# only answer was "auto-arm FAILED - exited 1 without an actionable reason".
# shellcheck disable=SC2034 # Read by bin/fm-watch-arm.sh and bin/fm-claude-stop-autoarm.sh.
FM_WATCHER_BUSY_HOLDER_STATUS=64

# The one lock state that is neither healthy nor free: a LIVE, identity-matched
# watcher for THIS home holds the lock while its beacon is stale or absent.
# Sets FM_WATCHER_BUSY_PID, FM_WATCHER_BUSY_AGE, and
# FM_WATCHER_BUSY_AGE_SOURCE on success.
#
# A stale or absent beacon here is evidence of a SUSPECTED STALL and nothing
# stronger. Identity verification proves WHICH process holds the lock - that it
# is this home's watcher rather than a recycled pid - not that the process is
# stuck. A slow phase, a descheduled process and a genuine wedge are
# indistinguishable from the outside, so no caller may signal, kill or replace
# the holder: the captain ruled on 2026-09-05 that a running monitor is never
# terminated on age alone.
fm_watcher_busy_holder() {  # <state-dir> <watch-path> [grace] [home]
  local state=$1 watch=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME}
  local lockdir beat pid age source
  FM_WATCHER_BUSY_PID=
  FM_WATCHER_BUSY_AGE=
  FM_WATCHER_BUSY_AGE_SOURCE=
  lockdir="$state/.watch.lock"
  beat="$state/.last-watcher-beat"
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  fm_watcher_lock_matches_pid "$state" "$watch" "$pid" "$home" || return 1
  if [ -e "$beat" ]; then
    age=$(fm_path_age "$beat")
    source=beacon
    [ "$age" -ge "$grace" ] || return 1
  else
    # With no beacon there is no healthy reading to defer to, even while the
    # lock itself is young. Report its age honestly while preserving the holder.
    age=$(fm_path_age "$lockdir")
    source=lock
  fi
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_busy_holder returns.
  FM_WATCHER_BUSY_PID=$pid
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_busy_holder returns.
  FM_WATCHER_BUSY_AGE=$age
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_busy_holder returns.
  FM_WATCHER_BUSY_AGE_SOURCE=$source
  return 0
}

fm_watcher_supervision_verdict() {
  local state=$1 watch=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME}
  local root=${5:-$FM_ROOT}
  local beat age fresh=false model
  FM_WATCHER_VERDICT_OK=false
  FM_WATCHER_VERDICT_REASON=stale-beacon
  beat="$state/.last-watcher-beat"
  age=$(fm_path_age "$beat")
  case "$age" in
    ''|*[!0-9]*) ;;
    *) [ "$age" -lt "$grace" ] && fresh=true ;;
  esac
  model=$(fm_supervision_model)
  if [ "$model" = autoarm ]; then
    [ "$fresh" = true ] && FM_WATCHER_VERDICT_OK=true
    return 0
  fi
  if fm_watcher_healthy "$state" "$watch" "$grace" "$home"; then
    # shellcheck disable=SC2034 # Read by callers after the function returns.
    FM_WATCHER_VERDICT_OK=true
  elif [ "$fresh" = true ]; then
    if [ "$model" = extension ] && fm_watcher_lock_unheld "$state" \
      && fm_extension_owns_supervision "$state" "$root"; then
      # shellcheck disable=SC2034 # Read by callers after the function returns.
      FM_WATCHER_VERDICT_OK=true
    else
      # shellcheck disable=SC2034 # Read by callers after the function returns.
      FM_WATCHER_VERDICT_REASON=no-watcher
    fi
  fi
  return 0
}

fm_lock_clean_known_files() {
  local lockdir=$1
  rm -f \
    "$lockdir/pid" \
    "$lockdir/fm-home" \
    "$lockdir/pid-identity" \
    "$lockdir/role" \
    "$lockdir/watcher-path" \
    2>/dev/null || true
}

fm_lock_set_role() {
  local lockdir=$1 role=$2 current pid back
  case "$role" in
    autoarm|terminal-check) : ;;
    *) return 1 ;;
  esac
  fm_current_pid current || return 1
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 1
  printf '%s\n' "$role" > "$lockdir/role" 2>/dev/null || return 1
  back=$(cat "$lockdir/role" 2>/dev/null || true)
  [ "$back" = "$role" ]
}

fm_lock_role() {
  cat "$1/role" 2>/dev/null
}

fm_lock_abs_path() {
  local path=$1 dir base
  dir=$(dirname "$path")
  base=$(basename "$path")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$base"
}

fm_lock_owner_dir() {
  local lockdir=$1 lock_abs
  lock_abs=$(fm_lock_abs_path "$lockdir") || return 1
  mktemp -d "${lock_abs}.owner.XXXXXX" 2>/dev/null
}

fm_lock_prepare_owner() {
  local ownerdir=$1 mypid back
  fm_current_pid mypid || return 1
  printf '%s\n' "$mypid" > "$ownerdir/pid" 2>/dev/null || return 1
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  [ "$back" = "$mypid" ]
}

fm_lock_link_owner() {
  local lockdir=$1 owner
  owner=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ -n "$owner" ] || return 1
  case "$owner" in
    /*) printf '%s\n' "$owner" ;;
    *) printf '%s/%s\n' "$(dirname "$lockdir")" "$owner" ;;
  esac
}

fm_lock_points_to_owner() {
  local lockdir=$1 ownerdir=$2 actual
  actual=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ "$actual" = "$ownerdir" ]
}

fm_lock_discard_owner() {
  local ownerdir=$1
  [ -n "$ownerdir" ] || return 0
  fm_lock_clean_known_files "$ownerdir"
  rmdir "$ownerdir" 2>/dev/null || true
}

fm_lock_remove_stray_owner_link() {
  local lockdir=$1 ownerdir=$2 stray
  stray="$lockdir/$(basename "$ownerdir")"
  if [ -L "$stray" ] && [ "$(readlink "$stray" 2>/dev/null || true)" = "$ownerdir" ]; then
    rm -f "$stray" 2>/dev/null || true
  fi
}

fm_lock_claim_blocked_by_steal() {
  local lockdir=$1 allowed_steal_owner=${2:-} steal
  steal="$lockdir.steal"
  [ -e "$steal" ] || [ -L "$steal" ] || return 1
  if [ -n "$allowed_steal_owner" ] && fm_lock_points_to_owner "$steal" "$allowed_steal_owner"; then
    return 1
  fi
  return 0
}

fm_lock_claim() {
  local lockdir=$1 ownerdir=$2 allowed_steal_owner=${3:-} mypid back
  fm_current_pid mypid || return 1
  if ! { printf '%s\n' "$mypid" > "$ownerdir/pid"; } 2>/dev/null; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  if [ "$back" != "$mypid" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if fm_lock_claim_blocked_by_steal "$lockdir" "$allowed_steal_owner"; then
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  return 0
}

fm_lock_try_create() {
  local lockdir=$1 allowed_steal_owner=${2:-} ownerdir
  FM_LOCK_OWNER_DIR=
  ownerdir=$(fm_lock_owner_dir "$lockdir") || return 1
  if [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_prepare_owner "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ln -s "$ownerdir" "$lockdir" 2>/dev/null && fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    if fm_lock_claim "$lockdir" "$ownerdir" "$allowed_steal_owner"; then
      FM_LOCK_OWNER_DIR=$ownerdir
      return 0
    fi
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
  else
    fm_lock_remove_stray_owner_link "$lockdir" "$ownerdir"
  fi
  fm_lock_discard_owner "$ownerdir"
  return 1
}

fm_lock_remove_path() {
  local lockdir=$1 ownerdir
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    rm -f "$lockdir" 2>/dev/null || return 1
    [ -n "$ownerdir" ] && fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null
}

fm_lock_mid_acquire_is_fresh() {
  local lockdir=$1 pid=$2 mid_acquire_stale
  case "$pid" in
    ''|*[!0-9]*)
      mid_acquire_stale=$FM_LOCK_STALE_AFTER
      [ "$mid_acquire_stale" -lt 2 ] && mid_acquire_stale=2
      [ "$(fm_path_age "$lockdir")" -lt "$mid_acquire_stale" ]
      return
      ;;
  esac
  return 1
}

fm_lock_recheck_stale_owner() {
  local lockdir=$1 expected_owner=$2 expected_pid=$3 actual_pid
  if [ -n "$expected_owner" ]; then
    fm_lock_points_to_owner "$lockdir" "$expected_owner" || return 1
  elif [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    [ -d "$lockdir" ] && [ ! -L "$lockdir" ] || return 1
  fi
  actual_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$actual_pid" = "$expected_pid" ] || return 1
  if fm_pid_alive "$actual_pid"; then
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$actual_pid"; then
    return 1
  fi
  return 0
}

FM_RECOVERY_MARKER_TOKEN=
FM_RECOVERY_MARKER_ACTION='none'

# Token grammar (one owner): <pending|announced|acked>:<handling|downtime>:<generation>
# docs/watcher-continuity.md owns the recovery-episode contract, including the
# once-per-generation announcement rule for unacknowledged downtime.
fm_recovery_marker_read() {
  local marker=$1 line count
  FM_RECOVERY_MARKER_TOKEN=
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  count=$(wc -l < "$marker" 2>/dev/null | tr -d '[:space:]') || return 1
  [ "$count" = 1 ] || return 1
  IFS= read -r line < "$marker" || return 1
  case "$line" in
    pending:handling:*|pending:downtime:*|announced:handling:*|announced:downtime:*|acked:handling:*|acked:downtime:*) ;;
    *) return 1 ;;
  esac
  case "${line##*:}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  FM_RECOVERY_MARKER_TOKEN=$line
}

_fm_atomic_replace() {
  mv -f -- "$1" "$2"
}

_fm_recovery_marker_write_locked() {
  local marker=$1 kind=$2 generation=${3:-} status=${4:-pending} tmp
  case "$kind" in handling|downtime) ;; *) return 1 ;; esac
  case "$status" in pending|announced) ;; *) return 1 ;; esac
  tmp=$(mktemp "${marker}.tmp.XXXXXX") || return 1
  [ -n "$generation" ] || generation="$(fm_current_pid).$(date +%s).${tmp##*.}"
  if ! printf '%s:%s:%s\n' "$status" "$kind" "$generation" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! _fm_atomic_replace "$tmp" "$marker"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Preserve a pending or announced episode's generation across downtime
# republication so its outstanding acknowledgement remains usable, and keep an
# already-announced generation announced so it cannot be re-presented until a
# new down stretch mints a new generation.
# docs/watcher-continuity.md owns the recovery contract and sequence-safety rationale.
FM_RECOVERY_MARKER_ACTIVE_LOCK=

_fm_recovery_marker_lock_acquire() {
  local lock=$1
  FM_RECOVERY_MARKER_ACTIVE_LOCK=$lock
  if ! fm_lock_acquire_wait "$lock"; then
    [ "${FM_RECOVERY_MARKER_ACTIVE_LOCK:-}" != "$lock" ] || FM_RECOVERY_MARKER_ACTIVE_LOCK=
    return 1
  fi
}

_fm_recovery_marker_lock_release() {
  local lock=$1 status=0
  fm_lock_release "$lock" || status=$?
  if [ "${FM_RECOVERY_MARKER_ACTIVE_LOCK:-}" = "$lock" ]; then
    FM_RECOVERY_MARKER_ACTIVE_LOCK=
  fi
  return "$status"
}

fm_recovery_marker_interrupt_release() {
  local lock=${FM_RECOVERY_MARKER_ACTIVE_LOCK:-}
  [ -n "$lock" ] || return 0
  _fm_recovery_marker_lock_release "$lock" || true
}

_fm_recovery_marker_publish() {
  local marker=$1 kind=${2:-downtime} lock saved_token generation='' status=pending
  case "$kind" in handling|downtime) ;; *) return 1 ;; esac
  lock="${marker}.lock"
  _fm_recovery_marker_lock_acquire "$lock" || return 1
  if [ -d "$marker" ] && [ ! -L "$marker" ]; then
    _fm_recovery_marker_lock_release "$lock"
    return 1
  fi
  if [ "$kind" = downtime ]; then
    # Read inline rather than in a command substitution: this runs inside the
    # marker-lock critical section, so it must not add a subshell fork there.
    # The token is restored because publishing owns no snapshot of its own.
    saved_token=$FM_RECOVERY_MARKER_TOKEN
    if fm_recovery_marker_read "$marker"; then
      case "$FM_RECOVERY_MARKER_TOKEN" in
        pending:handling:*|pending:downtime:*)
          generation=${FM_RECOVERY_MARKER_TOKEN##*:}
          status=pending
          ;;
        announced:handling:*|announced:downtime:*)
          generation=${FM_RECOVERY_MARKER_TOKEN##*:}
          status=announced
          ;;
      esac
    fi
    FM_RECOVERY_MARKER_TOKEN=$saved_token
  fi
  if ! _fm_recovery_marker_write_locked "$marker" "$kind" "$generation" "$status"; then
    _fm_recovery_marker_lock_release "$lock"
    return 1
  fi
  _fm_recovery_marker_lock_release "$lock"
}

_fm_recovery_marker_begin_handling() {
  local marker=$1 expected_generation=${2:-} lock line generation
  lock="${marker}.lock"
  _fm_recovery_marker_lock_acquire "$lock" || return 1
  if ! fm_recovery_marker_read "$marker"; then
    _fm_recovery_marker_lock_release "$lock"
    return 1
  fi
  line=$FM_RECOVERY_MARKER_TOKEN
  generation=${line##*:}
  if [ -n "$expected_generation" ] && [ "$generation" != "$expected_generation" ]; then
    _fm_recovery_marker_lock_release "$lock"
    return 3
  fi
  case "$line" in
    pending:handling:*|announced:handling:*) ;;
    pending:downtime:*)
      if ! _fm_recovery_marker_write_locked "$marker" handling "$generation"; then
        _fm_recovery_marker_lock_release "$lock"
        return 1
      fi
      FM_RECOVERY_MARKER_TOKEN="pending:handling:$generation"
      ;;
    announced:downtime:*)
      if ! _fm_recovery_marker_write_locked "$marker" handling "$generation" announced; then
        _fm_recovery_marker_lock_release "$lock"
        return 1
      fi
      FM_RECOVERY_MARKER_TOKEN="announced:handling:$generation"
      ;;
    *) _fm_recovery_marker_lock_release "$lock"; return 1 ;;
  esac
  _fm_recovery_marker_lock_release "$lock"
}

fm_recovery_marker_snapshot() {
  local marker=$1 lock
  FM_RECOVERY_MARKER_TOKEN=
  lock="${marker}.lock"
  _fm_recovery_marker_lock_acquire "$lock" || return 1
  fm_recovery_marker_read "$marker" || true
  _fm_recovery_marker_lock_release "$lock"
}

_fm_recovery_marker_ack() {
  local marker=$1 expected_generation=$2 lock tmp line
  [ -n "$expected_generation" ] || return 2
  lock="${marker}.lock"
  _fm_recovery_marker_lock_acquire "$lock" || return 1
  if ! fm_recovery_marker_read "$marker" \
    || [ "${FM_RECOVERY_MARKER_TOKEN##*:}" != "$expected_generation" ]; then
    _fm_recovery_marker_lock_release "$lock"
    return 3
  fi
  line=$FM_RECOVERY_MARKER_TOKEN
  case "$line" in
    pending:*|announced:*) line="acked:${line#*:}" ;;
    acked:*) _fm_recovery_marker_lock_release "$lock"; return 0 ;;
    *) _fm_recovery_marker_lock_release "$lock"; return 1 ;;
  esac
  tmp=$(mktemp "${marker}.tmp.XXXXXX") || { _fm_recovery_marker_lock_release "$lock"; return 1; }
  if ! printf '%s\n' "$line" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! mv -f -- "$tmp" "$marker"; then
    rm -f -- "$tmp"
    _fm_recovery_marker_lock_release "$lock"
    return 1
  fi
  _fm_recovery_marker_lock_release "$lock"
}

_fm_recovery_marker_arm_check() {
  local marker=$1 lock line quarantine
  FM_RECOVERY_MARKER_ACTION='none'
  lock="${marker}.lock"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  if ! _fm_recovery_marker_lock_acquire "$lock"; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 1
  fi
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    if [ -s "$FM_WAKE_QUEUE" ]; then
      if ! _fm_recovery_marker_write_locked "$marker" downtime "" announced; then
        _fm_recovery_marker_lock_release "$lock"
        fm_lock_release "$FM_WAKE_QUEUE_LOCK"
        return 1
      fi
      FM_RECOVERY_MARKER_ACTION='recover'
    fi
    _fm_recovery_marker_lock_release "$lock"
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  if ! fm_recovery_marker_read "$marker"; then
    quarantine=$(mktemp -d "${marker}.invalid.XXXXXX") \
      || {
        _fm_recovery_marker_lock_release "$lock"
        fm_lock_release "$FM_WAKE_QUEUE_LOCK"
        return 1
      }
    if ! mv -- "$marker" "$quarantine/marker" \
      || ! _fm_recovery_marker_write_locked "$marker" downtime "" announced; then
      rmdir "$quarantine" 2>/dev/null || true
      _fm_recovery_marker_lock_release "$lock"
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return 1
    fi
    FM_RECOVERY_MARKER_ACTION='recover'
    _fm_recovery_marker_lock_release "$lock"
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  line=$FM_RECOVERY_MARKER_TOKEN
  case "$line" in
    pending:handling:*|announced:handling:*|announced:downtime:*)
      FM_RECOVERY_MARKER_ACTION='wait'
      _fm_recovery_marker_lock_release "$lock"
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return 0
      ;;
    pending:downtime:*)
      if ! _fm_recovery_marker_write_locked "$marker" downtime "${line##*:}" announced; then
        _fm_recovery_marker_lock_release "$lock"
        fm_lock_release "$FM_WAKE_QUEUE_LOCK"
        return 1
      fi
      FM_RECOVERY_MARKER_TOKEN="announced:downtime:${line##*:}"
      FM_RECOVERY_MARKER_ACTION='recover'
      ;;
    acked:*)
      if [ -s "$FM_WAKE_QUEUE" ]; then
        if ! _fm_recovery_marker_write_locked "$marker" downtime "" announced; then
          _fm_recovery_marker_lock_release "$lock"
          fm_lock_release "$FM_WAKE_QUEUE_LOCK"
          return 1
        fi
        # shellcheck disable=SC2034 # Output read by callers after this function returns.
        FM_RECOVERY_MARKER_ACTION='recover'
      fi
      ;;
  esac
  _fm_recovery_marker_lock_release "$lock"
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
}

# A non-successor watcher start after an announced-but-unacked episode is a new
# down stretch: mint a fresh pending generation so a still-open decision or
# buried note can be presented once more. Handling successors must not call
# this, because Option B re-arm is not a new down stretch.
_fm_recovery_marker_reopen_announced() {
  local marker=$1 lock
  lock="${marker}.lock"
  _fm_recovery_marker_lock_acquire "$lock" || return 1
  if ! fm_recovery_marker_read "$marker"; then
    _fm_recovery_marker_lock_release "$lock"
    return 0
  fi
  case "$FM_RECOVERY_MARKER_TOKEN" in
    announced:*)
      if ! _fm_recovery_marker_write_locked "$marker" downtime ""; then
        _fm_recovery_marker_lock_release "$lock"
        return 1
      fi
      ;;
  esac
  _fm_recovery_marker_lock_release "$lock"
}

fm_recovery_transition() {
  local marker=$1 action=$2 target=${3:-} value=${4:-}
  case "$action" in
    publish)
      _fm_recovery_marker_publish "$marker" "${target:-downtime}"
      ;;
    acknowledge)
      _fm_recovery_marker_ack "$marker" "$target"
      ;;
    arm-check)
      _fm_recovery_marker_arm_check "$marker"
      ;;
    reopen-announced)
      _fm_recovery_marker_reopen_announced "$marker"
      ;;
    release-lock)
      [ -n "$target" ] || return 1
      _fm_recovery_marker_publish "$marker" "${value:-downtime}" || return 1
      fm_lock_release "$target"
      ;;
    release-lock-existing)
      [ -n "$target" ] || return 1
      local lock="${marker}.lock"
      _fm_recovery_marker_lock_acquire "$lock" || return 1
      if ! fm_recovery_marker_read "$marker"; then
        _fm_recovery_marker_lock_release "$lock"
        return 1
      fi
      fm_lock_release "$target"
      _fm_recovery_marker_lock_release "$lock"
      ;;
    clear-stale-lock)
      [ -n "$target" ] || return 1
      _fm_recovery_marker_publish "$marker" "${value:-downtime}" || return 1
      fm_lock_remove_path "$target"
      ;;
    *) return 2 ;;
  esac
}

fm_recovery_marker_publish() {
  fm_recovery_transition "$1" publish "${2:-downtime}"
}

fm_recovery_marker_ack() {
  fm_recovery_transition "$1" acknowledge "$2"
}

fm_recovery_marker_begin_handling() {
  _fm_recovery_marker_begin_handling "$1" "${2:-}"
}

fm_recovery_marker_arm_check() {
  fm_recovery_transition "$1" arm-check
}

fm_recovery_marker_reopen_announced() {
  fm_recovery_transition "$1" reopen-announced
}

fm_lock_try_acquire() {
  local lockdir=$1 pid steal cur rc steal_owner primary_owner
  FM_LOCK_HELD_PID=
  FM_LOCK_OWNER_DIR=
  FM_LOCK_RECOVERED_PID=

  if fm_lock_try_create "$lockdir"; then
    return 0
  fi

  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi

  steal="$lockdir.steal"
  if ! fm_lock_try_acquire "$steal"; then
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  steal_owner=${FM_LOCK_OWNER_DIR:-}

  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if ! fm_lock_points_to_owner "$steal" "$steal_owner"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  primary_owner=
  if [ -L "$lockdir" ]; then
    primary_owner=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
  fi
  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if ! fm_lock_recheck_stale_owner "$lockdir" "$primary_owner" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  if [ "$lockdir" = "$STATE/.watch.lock" ] \
    && ! _fm_recovery_marker_publish "$STATE/.watcher-down" downtime; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  fm_lock_remove_path "$lockdir" || true
  rc=1
  if fm_lock_try_create "$lockdir" "$steal_owner"; then
    rc=0
    # shellcheck disable=SC2034 # Read by sourcing callers after lock acquisition.
    FM_LOCK_RECOVERED_PID=$cur
  fi
  if [ "$rc" -ne 0 ]; then
    # shellcheck disable=SC2034 # Read by callers after fm_lock_try_acquire returns.
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
  fi
  fm_lock_release "$steal"
  return "$rc"
}

fm_lock_acquire_wait() {
  local lockdir=$1
  while ! fm_lock_try_acquire "$lockdir"; do
    sleep 0.1
  done
}

# Acquire in the timed helper process, then transfer the lock record to the
# waiting caller before exiting. The lock's ordinary stale-owner recovery makes
# every interruption safe: before transfer the helper is the owner; after
# transfer the still-live caller is the owner.
_fm_lock_acquire_wait_handoff() {  # <lockdir> <caller-pid>
  local lockdir=$1 caller_pid=$2 ownerdir current back
  case "$caller_pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_pid_alive "$caller_pid" || return 1
  trap 'fm_lock_release "$lockdir"; exit 143' TERM INT
  fm_lock_acquire_wait "$lockdir" || return 1
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null) || {
      fm_lock_release "$lockdir"
      return 1
    }
  else
    ownerdir=$lockdir
  fi
  fm_current_pid current || { fm_lock_release "$lockdir"; return 1; }
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  if [ "$back" != "$current" ] \
    || ! printf '%s\n' "$caller_pid" > "$ownerdir/pid" 2>/dev/null \
    || [ "$(cat "$ownerdir/pid" 2>/dev/null || true)" != "$caller_pid" ]; then
    fm_lock_release "$lockdir"
    return 1
  fi
  trap - TERM INT
}

# fm_lock_acquire_wait_bounded <lockdir> <positive-seconds>
#
# Bounded acquire variant. It preserves the ordinary wait/reclaim behavior
# until fm-timeout-lib.sh's hard deadline, returns 124 when a live holder still
# owns the lock, and leaves FM_LOCK_HELD_PID naming that holder.
# Use it where a caller must refuse rather than block: wake presentation, and
# the guarded remote link clear, whose whole contract is to return a
# reconciliation refusal instead of wedging an unattended close.
# Mutation-critical callers that can safely block keep fm_lock_acquire_wait.
fm_lock_acquire_wait_bounded() {
  local lockdir=$1 seconds=$2 caller_pid rc owner_pid
  case "$seconds" in ''|*[!0-9]*|0) return 2 ;; esac
  _fm_wake_require_timeout || return 1
  if fm_lock_try_acquire "$lockdir"; then
    return 0
  fi

  fm_current_pid caller_pid || return 1
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  if fm_run_timed "$seconds" env \
    "FM_STATE_OVERRIDE=$STATE" \
    "FM_ROOT_OVERRIDE=$FM_ROOT" \
    "FM_LOCK_STALE_AFTER=$FM_LOCK_STALE_AFTER" \
    bash -c '. "$1"; _fm_lock_acquire_wait_handoff "$2" "$3"' \
      _ "$FM_WAKE_LIB_DIR/fm-wake-lib.sh" "$lockdir" "$caller_pid" \
      </dev/null >/dev/null 2>&1; then
    rc=0
  else
    rc=$?
  fi

  owner_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  if [ "$owner_pid" = "$caller_pid" ]; then
    return 0
  fi
  [ "$rc" -ne 0 ] || rc=1
  # A deadline can kill the helper just after it acquired and before handoff.
  # Give ordinary stale-owner recovery one final non-blocking chance so that
  # helper cleanup cannot manufacture a false contention advisory.
  if fm_lock_try_acquire "$lockdir"; then
    return 0
  fi
  if [ "$rc" -eq 124 ]; then
    owner_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
    case "$owner_pid" in
      ''|*[!0-9]*|0) ;;
      *)
        if [ "$owner_pid" -gt 0 ] 2>/dev/null && fm_pid_alive "$owner_pid"; then
          FM_LOCK_HELD_PID=$owner_pid
          return 124
        fi
        ;;
    esac
    # shellcheck disable=SC2034 # Output read by callers after bounded acquisition.
    FM_LOCK_HELD_PID=
    return 1
  fi
  return "$rc"
}

fm_lock_release() {
  local lockdir=$1 pid current ownerdir
  fm_current_pid current || return 1
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    [ -n "$ownerdir" ] || return 0
    pid=$(cat "$ownerdir/pid" 2>/dev/null || true)
    [ "$pid" = "$current" ] || return 0
    fm_lock_points_to_owner "$lockdir" "$ownerdir" || return 0
    rm -f "$lockdir" 2>/dev/null || return 0
    fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 0
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null || true
}

fm_meta_lock_path() {
  local meta=$1 dir base id
  dir=${meta%/*}
  base=${meta##*/}
  [ "$dir" != "$meta" ] || dir=.
  case "$base" in
    *.meta) id=${base%.meta} ;;
    *) return 1 ;;
  esac
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s/.meta-%s.lock\n' "$dir" "$id"
}

# fm_task_set_lock_path: the per-home lock guarding WHICH tasks exist in a home,
# as opposed to fm_meta_lock_path, which guards one task's record.
#
# A per-task lock cannot protect a task that does not exist yet. Forced
# secondmate teardown enumerates a home's task set, locks what it found, and
# then re-enumerates while removing; a fresh spawn publishing a record inside
# that window is invisible to the first enumeration and visible to the second,
# so it gets destructively processed while never lifecycle-locked (reproduced
# with real agents: a record published 0.249s after teardown began was removed
# and its worktree returned to the pool, with both commands reporting success).
# Holding this lock from enumeration through cleanup makes the two operations
# serialize: either the spawn publishes first and the teardown's preflight
# covers it, or the teardown owns the set and the spawn refuses. Both directions
# fail closed.
fm_task_set_lock_path() {  # <state-dir>
  local state=$1
  [ -n "$state" ] || return 1
  case "$state" in *[$'\n\r\t']*) return 1 ;; esac
  printf '%s/.task-set.lock\n' "$state"
}

fm_firstmate_root_home() {
  local home=${1:-$FM_HOME} marker parent seen="|" depth=0
  home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  while [ -e "$home/.fm-secondmate-parent" ] || [ -L "$home/.fm-secondmate-parent" ]; do
    marker="$home/.fm-secondmate-parent"
    if ! command -v fm_secondmate_parent_record_parse >/dev/null 2>&1; then
      # shellcheck source=bin/fm-secondmate-parent-lib.sh
      . "$FM_WAKE_LIB_DIR/fm-secondmate-parent-lib.sh"
    fi
    fm_secondmate_parent_record_parse "$marker" || return 1
    [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || return 1
    parent=$(CDPATH='' cd -- "$FM_SECONDMATE_PARENT_HOME" 2>/dev/null && pwd -P) || return 1
    case "$seen" in *"|$parent|"*) return 1 ;; esac
    seen="$seen$home|"
    home=$parent
    depth=$((depth + 1))
    [ "$depth" -le 64 ] || return 1
  done
  printf '%s\n' "$home"
}

fm_treehouse_project_lock_path() {  # <project-dir>
  local project=$1 root origin identity hash top
  [ -d "$project" ] || return 1
  root=$(fm_firstmate_root_home "$FM_HOME") || return 1
  origin=$(git -C "$project" remote get-url origin 2>/dev/null || true)
  if [ -n "$origin" ]; then
    case "$origin" in
      /*) [ ! -d "$origin" ] || origin=$(CDPATH='' cd -- "$origin" 2>/dev/null && pwd -P) || return 1 ;;
      *://*|*:* ) ;;
      *) [ ! -d "$project/$origin" ] || origin=$(CDPATH='' cd -- "$project/$origin" 2>/dev/null && pwd -P) || return 1 ;;
    esac
    identity=$origin
  else
    top=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null) || return 1
    top=$(CDPATH='' cd -- "$top" 2>/dev/null && pwd -P) || return 1
    identity=$top
  fi
  hash=$(printf '%s' "$identity" | git hash-object --stdin 2>/dev/null) || return 1
  [ -d "$root/state" ] || return 1
  printf '%s/.treehouse-project-%s.lock\n' "$root/state" "$hash"
}

fm_failure_episode_reset() {
  local state=$1 mode=${2:-acquire} lock current pid acquired=0 path
  lock="$state/.turnend-claude-blocks.lock"
  case "$mode" in
    acquire)
      fm_lock_try_acquire "$lock" || return 1
      acquired=1
      ;;
    held)
      fm_current_pid current || return 1
      pid=$(cat "$lock/pid" 2>/dev/null || true)
      [ "$pid" = "$current" ] || return 1
      ;;
    *) return 1 ;;
  esac
  for path in \
    "$state/.turnend-claude-blocks" \
    "$state/.claude-autoarm-failure-notified" \
    "$state/.claude-autoarm-failure-alarmed"
  do
    if [ -d "$path" ] && [ ! -L "$path" ]; then
      [ "$acquired" -eq 0 ] || fm_lock_release "$lock"
      return 1
    fi
  done
  if ! rm -f \
    "$state/.turnend-claude-blocks" \
    "$state/.claude-autoarm-failure-notified" \
    "$state/.claude-autoarm-failure-alarmed" \
    2>/dev/null; then
    [ "$acquired" -eq 0 ] || fm_lock_release "$lock"
    return 1
  fi
  [ "$acquired" -eq 0 ] || fm_lock_release "$lock"
  return 0
}

# --- Claude Stop auto-arm generation claims -----------------------------------
# Both Stop-event participants (bin/fm-claude-stop-autoarm.sh and
# bin/fm-turnend-guard.sh --claude) coordinate through the epoch ledger
# state/.claude-autoarm-epoch, whose monotonic epoch sequence IS the claim
# generation. This is an optimistic, generation-based single-flight design:
#
#   - The CURRENT claim is the ledger's latest entry: line 1 is the classic
#     "epoch=N owner_pid=P outcome=O updated_at=T" record, and line 2 is the
#     claiming process's pid-identity, the same identity every other
#     supervision lock in this repo records (fm_pid_identity above). The
#     identity is MANDATORY: a claimant that cannot record it does not claim
#     (continuity falls to the synchronous guard), and the identity is read
#     from the ledger entry alone - never substituted from any lock - so a
#     reused pid can never authenticate someone else's stale entry.
#   - A claim is OPEN (fm_autoarm_claim_open) while its outcome is "arming",
#     its owner pid is alive, its recorded identity successfully recomputes
#     and matches that pid, and it is not STUCK - stuck meaning both the
#     ledger entry and the watcher beacon (state/.last-watcher-beat) are older
#     than the guard grace, which proves the owner hung mid-arm with nothing
#     supervising (every legitimate arming phase with no watcher is bounded in
#     seconds, while a healthy hours-long cycle keeps the beacon beating).
#   - Every firing DEFERS (exits 0) to an open claim; anything else - a
#     terminal outcome, a dead or identity-mismatched owner, a stuck owner, an
#     identityless entry, or no claim at all - lets the next firing take
#     generation N+1 (fm_autoarm_claim_next). Taking a newer generation IS the
#     reclaim: a steady-state predecessor is never signalled or revoked.
#   - NO mutex is ever held across a blocking step. The owner lock
#     state/.claude-autoarm.lock survives only as a micro-mutex serializing
#     individual ledger reads-then-writes (a few non-blocking file
#     operations); a holder that dies inside the hold is reclaimed by
#     fm_lock_try_acquire's ordinary dead-owner steal.
#   - A superseded owner goes COMPLETELY silent - cleanup only. Ownership is
#     re-verified before every side effect: each arm invocation, each
#     episode-state mutation, each ledger write, and each continuation.
#   - The irrevocable commit point of a translation is the EXIT STATUS: the
#     harness delivers the collected stderr banner only on exit 2 and discards
#     it on exit 0. Markerless outcomes commit with the owned terminal ledger
#     write. The once-per-episode failure notice commits only when its marker is
#     created after the winning "failed" write in the same owned critical
#     section. A superseded generation or failed required-marker creation is
#     refused and exits 0 silently even after printing; a later generation
#     supersedes the terminal entry and retries the notice.
#
# This structurally removes the failure classes the lock-held-across-arm
# design produced: a hung owner deferring every later firing forever (observed
# 2026-08-26: a hook hung mid-arm with its ledger frozen at "arming" kept the
# watcher from ever being auto-re-armed again; and 2026-08-14: a finished
# claim whose leftover lock silenced both participants for 40 beacon-less
# minutes), a reclaim mutex held across a blocking banner write recreating the
# same unreclaimable-live-owner shape, and a reclaimed-but-alive owner racing
# its replacement to translate one close twice.
#
# Two bounded residuals are ACCEPTED INTENT, because closing them absolutely
# would require a mutex held across output or steady-state revocation, both
# deliberately rejected: (1) an owner that dies between its owned terminal
# write and its own process exit leaves a committed outcome whose banner was
# never delivered (process-death territory; the durable wake queue retains the
# underlying event), and (2) a hung old-build owner that resumes during the
# one legacy upgrade window may add one duplicate continuation. Each residual
# costs at most one extra exit-2 continuation turn absorbed by the durable
# idempotent wake queue. A claim misread as stuck in a pathological race
# (e.g. a beacon read right at system wake) likewise yields at most one extra
# arm that the watcher singleton dedupes, while the superseded owner still
# goes silent.
#
# fm_autoarm_claim_abandoned / fm_autoarm_release_abandoned below survive as
# the LEGACY shim for a lock-holding claim from a pre-generation build (the
# lock carries a role file only in that legacy shape, and in the guard's own
# short terminal-check hold): a live legacy owner still defers per the legacy
# proof, and a proven-abandoned one is reclaimed once through the steal mutex
# - with an identity-verified live owner retired via TERM first, because old
# code cannot re-check generations - so an upgrade mid-session can neither
# double-arm nor deadlock behind a hung legacy hook.
_fm_autoarm_epoch_field() {  # <epoch-file> <field>
  local file=$1 field=$2 tok
  local -a toks=()
  [ -r "$file" ] || return 1
  # 2> before <: a failed input redirection reports through whatever stderr is
  # current when it runs, so the suppression has to be established first.
  IFS=' ' read -r -a toks 2>/dev/null < "$file" || return 1
  for tok in ${toks[@]+"${toks[@]}"}; do
    case "$tok" in
      "$field="?*) printf '%s\n' "${tok#*=}"; return 0 ;;
    esac
  done
  return 1
}

# Parse the current ledger claim. Sets FM_AUTOARM_GEN, FM_AUTOARM_OWNER,
# FM_AUTOARM_OUTCOME, and FM_AUTOARM_IDENTITY (line 2 of the entry, and ONLY
# line 2 - identity is never substituted from a lock, so a transient
# micro-mutex hold or a reused pid can never authenticate a stale entry).
fm_autoarm_ledger_read() {  # <state-dir>
  local state=$1 epoch
  epoch="$state/.claude-autoarm-epoch"
  FM_AUTOARM_GEN=
  FM_AUTOARM_OWNER=
  FM_AUTOARM_OUTCOME=
  FM_AUTOARM_IDENTITY=
  FM_AUTOARM_GEN=$(_fm_autoarm_epoch_field "$epoch" epoch) || return 1
  FM_AUTOARM_OWNER=$(_fm_autoarm_epoch_field "$epoch" owner_pid) || return 1
  FM_AUTOARM_OUTCOME=$(_fm_autoarm_epoch_field "$epoch" outcome) || return 1
  case "$FM_AUTOARM_GEN" in
    ''|*[!0-9]*) return 1 ;;
  esac
  FM_AUTOARM_IDENTITY=$(sed -n '2p' "$epoch" 2>/dev/null || true)
  return 0
}

# True while the CURRENT ledger claim is open and healthy - the defer predicate
# both Stop participants use. Open means: outcome "arming", a live owner whose
# mandatory recorded identity recomputes and matches its pid, and not stuck
# (the contract comment above owns the stuck proof). fm_path_age reports an
# absent beacon as ancient, which is exactly right: arming for a full grace
# window without producing a first beat is the same hang. An identityless
# entry is never open: real generation claims always record identity, a legacy
# build's entry gets its deference from its held role-carrying lock through
# the legacy shim, and anything else must not defer.
fm_autoarm_claim_open() {  # <state-dir> [grace]
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} epoch current
  epoch="$state/.claude-autoarm-epoch"
  case "$grace" in
    ''|*[!0-9]*|0) grace=300 ;;
  esac
  fm_autoarm_ledger_read "$state" || return 1
  [ "$FM_AUTOARM_OUTCOME" = arming ] || return 1
  fm_pid_alive "$FM_AUTOARM_OWNER" || return 1
  [ -n "$FM_AUTOARM_IDENTITY" ] || return 1
  current=$(fm_pid_identity "$FM_AUTOARM_OWNER" 2>/dev/null) || return 1
  [ -n "$current" ] || return 1
  [ "$current" = "$FM_AUTOARM_IDENTITY" ] || return 1
  if [ "$(fm_path_age "$epoch")" -ge "$grace" ] \
    && [ "$(fm_path_age "$state/.last-watcher-beat")" -ge "$grace" ]; then
    return 1
  fi
  return 0
}

# Atomically publish this process as the owner of generation N+1, under one
# short micro-mutex hold. Returns 0 with FM_AUTOARM_MY_GEN set on success, 2
# when a competing claimant won the race (the ledger holds an open claim), and
# 1 when the micro-mutex is contended, the mandatory identity cannot be
# computed, or the write failed.
fm_autoarm_claim_next() {  # <state-dir> [grace]
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} lock epoch pid gen identity tmp
  lock="$state/.claude-autoarm.lock"
  epoch="$state/.claude-autoarm-epoch"
  FM_AUTOARM_MY_GEN=
  # Resolve the pid into a variable FIRST: expanding ${BASHPID:-$$} inside a
  # command substitution would resolve it in that subshell, recording the
  # identity of a process that exits immediately.
  pid=${BASHPID:-$$}
  identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -n "$identity" ] || return 1
  fm_lock_try_acquire "$lock" || return 1
  if fm_autoarm_claim_open "$state" "$grace"; then
    fm_lock_release "$lock"
    return 2
  fi
  gen=$(_fm_autoarm_epoch_field "$epoch" epoch 2>/dev/null || true)
  case "$gen" in
    ''|*[!0-9]*) gen=0 ;;
  esac
  gen=$((gen + 1))
  tmp="$epoch.tmp.$pid"
  if ! printf 'epoch=%s owner_pid=%s outcome=arming updated_at=%s\n%s\n' \
      "$gen" "$pid" "$(date +%s)" "$identity" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$epoch" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$lock"
    return 1
  fi
  fm_lock_release "$lock"
  # shellcheck disable=SC2034 # Read by callers after the claim succeeds.
  FM_AUTOARM_MY_GEN=$gen
  return 0
}

# Write a new outcome for a generation this process still owns, re-verified
# under the micro-mutex so a superseded owner can never clobber a newer claim.
# With a fourth argument, create that marker after the ledger rename in the same
# owned critical section (the once-per-episode failure notice). A fifth argument
# appends typed outcome details to the first ledger record. A marker failure
# refuses the commit even though its terminal ledger entry remains; marker-first
# ordering could permanently suppress a notice whose ledger write never won.
# Returns 0 committed, 2 refused (superseded or required-marker failure), and 1
# unable (bounded contention or ledger-write failure).
fm_autoarm_write_owned() {  # <state-dir> <gen> <outcome> [marker-file] [details]
  local state=$1 gen=$2 outcome=$3 marker=${4:-} details=${5:-} lock epoch pid identity tmp i
  lock="$state/.claude-autoarm.lock"
  epoch="$state/.claude-autoarm-epoch"
  pid=${BASHPID:-$$}
  i=0
  while ! fm_lock_try_acquire "$lock"; do
    [ "$i" -lt 20 ] || return 1
    sleep 0.02
    i=$((i + 1))
  done
  if ! fm_autoarm_ledger_read "$state" \
    || [ "$FM_AUTOARM_GEN" != "$gen" ] || [ "$FM_AUTOARM_OWNER" != "$pid" ]; then
    fm_lock_release "$lock"
    return 2
  fi
  identity=$FM_AUTOARM_IDENTITY
  tmp="$epoch.tmp.$pid"
  if ! {
      printf 'epoch=%s owner_pid=%s outcome=%s updated_at=%s%s\n' \
        "$gen" "$pid" "$outcome" "$(date +%s)" "${details:+ $details}"
      [ -z "$identity" ] || printf '%s\n' "$identity"
    } > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$epoch" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$lock"
    return 1
  fi
  if [ -n "$marker" ] && ! : > "$marker" 2>/dev/null; then
    fm_lock_release "$lock"
    return 2
  fi
  fm_lock_release "$lock"
  return 0
}

# Lockless pre-side-effect ownership check: true while the ledger still names
# <gen> owned by this process. A superseded owner must go silent instead of
# arming, mutating shared state, or emitting.
fm_autoarm_still_owner() {  # <state-dir> <gen>
  local state=$1 gen=$2 pid
  pid=${BASHPID:-$$}
  fm_autoarm_ledger_read "$state" || return 1
  [ "$FM_AUTOARM_GEN" = "$gen" ] && [ "$FM_AUTOARM_OWNER" = "$pid" ]
}

fm_autoarm_reset_owned() {  # <state-dir> <gen>
  local state=$1 gen=$2 lock pid
  lock="$state/.claude-autoarm.lock"
  pid=${BASHPID:-$$}
  fm_lock_try_acquire "$lock" || return 2
  if ! fm_autoarm_ledger_read "$state" \
    || [ "$FM_AUTOARM_GEN" != "$gen" ] || [ "$FM_AUTOARM_OWNER" != "$pid" ]; then
    fm_lock_release "$lock"
    return 2
  fi
  if ! fm_failure_episode_reset "$state"; then
    fm_lock_release "$lock"
    return 1
  fi
  fm_lock_release "$lock"
  return 0
}

# LEGACY shim (see the contract comment above): the abandonment proof for a
# lock-holding claim from a pre-generation build, recognizable by the role
# file only such claims and the guard's short terminal-check hold publish.
# A live legacy owner defers per this proof; a finished, identity-mismatched,
# or stuck one is abandoned:
#
#   1. the owner lock exists and carries the auto-arm role,
#   2. its recorded pid is numeric,
#   3. a recorded pid-identity that no longer matches the live pid is
#      abandonment on its own (pid reuse after a group kill), and otherwise
#   4. the ledger's owner_pid is exactly that pid and its outcome is present
#      and either is not "arming", or is "arming" while both the ledger entry
#      and the watcher beacon are older than the guard grace (the same stuck
#      proof as fm_autoarm_claim_open).
fm_autoarm_claim_abandoned() {  # <state-dir> [grace]
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} epoch lock role pid owner outcome recorded current
  lock="$state/.claude-autoarm.lock"
  epoch="$state/.claude-autoarm-epoch"
  case "$grace" in
    ''|*[!0-9]*|0) grace=300 ;;
  esac
  [ -e "$lock" ] || [ -L "$lock" ] || return 1
  role=$(fm_lock_role "$lock")
  [ "$role" = autoarm ] || return 1
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  recorded=$(cat "$lock/pid-identity" 2>/dev/null || true)
  if [ -n "$recorded" ] && current=$(fm_pid_identity "$pid" 2>/dev/null) \
    && [ -n "$current" ] && [ "$current" != "$recorded" ]; then
    return 0
  fi
  owner=$(_fm_autoarm_epoch_field "$epoch" owner_pid) || return 1
  [ "$owner" = "$pid" ] || return 1
  outcome=$(_fm_autoarm_epoch_field "$epoch" outcome) || return 1
  case "$outcome" in
    '') return 1 ;;
    arming)
      [ "$(fm_path_age "$epoch")" -ge "$grace" ] || return 1
      [ "$(fm_path_age "$state/.last-watcher-beat")" -ge "$grace" ] || return 1
      return 0
      ;;
  esac
  return 0
}

# Remove a proven-abandoned legacy claim so the next claimant can arm. The
# proof is re-verified while holding the lock's steal mutex, the same
# serialization fm_lock_try_acquire uses for stale-owner reclaim: while it is
# held no other process can publish the primary lock, so the window between
# proving abandonment and removing the lock cannot swallow a genuine new
# claim.
#
# Old-build code cannot re-check generations, so a LIVE proven-abandoned
# legacy owner whose recorded identity is verified to match its pid is retired
# with TERM before the lock is removed: once the TERM is successfully queued
# the process can never resume normal execution (delivery precedes any further
# user code when it continues), so a short bounded wait for observed exit is a
# courtesy, not a requirement. A pid is never signalled without a verified
# matching identity; when the kill itself fails or the identity stops matching
# mid-procedure (pid reuse), the reclaim refuses. Missing identity evidence
# never blocks the reclaim of a proven-abandoned claim - it only disables the
# TERM and the ledger graft below, keeping the documented bounded
# upgrade-window residual instead of the deadlock.
fm_autoarm_release_abandoned() {  # <state-dir> [grace]
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} lock steal epoch lock_pid recorded current owner line1 tmp i
  lock="$state/.claude-autoarm.lock"
  steal="$lock.steal"
  epoch="$state/.claude-autoarm-epoch"
  fm_autoarm_claim_abandoned "$state" "$grace" || return 1
  fm_lock_try_acquire "$steal" || return 1
  if ! fm_autoarm_claim_abandoned "$state" "$grace"; then
    fm_lock_release "$steal"
    return 1
  fi
  lock_pid=$(cat "$lock/pid" 2>/dev/null || true)
  recorded=$(cat "$lock/pid-identity" 2>/dev/null || true)
  if [ -n "$recorded" ] && fm_pid_alive "$lock_pid" \
    && current=$(fm_pid_identity "$lock_pid" 2>/dev/null) \
    && [ -n "$current" ] && [ "$current" = "$recorded" ]; then
    # A live pid still answering to the recorded identity IS the genuine
    # legacy owner (proven stuck or blocked after a terminal write): retire it
    # before removing its lock, because old-build code cannot re-check
    # generations. A pid the recorded identity does NOT verify - reused,
    # unverifiable, or never recorded - is NEVER signalled; those shapes are
    # reclaimed as-is, which is safe exactly because the recorded owner is
    # gone or was never provably this process.
    if ! kill -TERM "$lock_pid" 2>/dev/null; then
      fm_lock_release "$steal"
      return 1
    fi
    i=0
    while [ "$i" -lt 20 ] && fm_pid_alive "$lock_pid"; do
      sleep 0.05
      i=$((i + 1))
    done
  fi
  # Preserve the legacy lock's identity evidence in the ledger before the lock
  # disappears, keeping the ledger's original mtime so the stuck proof's age
  # window is not silently reopened. Best effort.
  if [ -n "$recorded" ] && [ -n "$lock_pid" ] \
    && owner=$(_fm_autoarm_epoch_field "$epoch" owner_pid 2>/dev/null) \
    && [ "$owner" = "$lock_pid" ] \
    && [ -z "$(sed -n '2p' "$epoch" 2>/dev/null)" ]; then
    line1=$(sed -n '1p' "$epoch" 2>/dev/null || true)
    tmp="$epoch.tmp.${BASHPID:-$$}"
    if [ -n "$line1" ] \
      && printf '%s\n%s\n' "$line1" "$recorded" > "$tmp" 2>/dev/null \
      && touch -r "$epoch" "$tmp" 2>/dev/null \
      && mv -f "$tmp" "$epoch" 2>/dev/null; then
      :
    fi
    rm -f "$tmp" 2>/dev/null || true
  fi
  fm_lock_remove_path "$lock" || true
  fm_lock_release "$steal"
  [ -e "$lock" ] || [ -L "$lock" ] || return 0
  return 1
}

fm_wake_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

fm_wake_append() {
  local kind=$1 key=$2 payload=$3 clean_key clean_payload epoch seq seq_file status
  local recovery_marker
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_append: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac

  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | fm_wake_clean_field)
  epoch=$(date +%s)
  seq_file="$STATE/.wake-queue.seq"
  recovery_marker="$STATE/.watcher-down"
  status=0

  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  _fm_recovery_marker_publish "$recovery_marker" downtime || status=$?
  if [ "$status" -eq 0 ]; then
    seq=$(cat "$seq_file" 2>/dev/null || echo 0)
    case "$seq" in
      ''|*[!0-9]*) seq=0 ;;
    esac
    seq=$((seq + 1))
    printf '%s\n' "$seq" > "$seq_file" || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$clean_key" "$clean_payload" >> "$FM_WAKE_QUEUE" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

# fm_wake_queued_keys <kind>
# Print the distinct keys currently queued for <kind>, oldest first. Read under
# the append lock so a concurrent append is never observed half-written. The
# durable queue stays the authority: a key appears here exactly while a record
# for it is queued and unacknowledged, and disappears only after post-handling
# acknowledgement consumes it.
fm_wake_queued_keys() {
  local kind=$1
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_queued_keys: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  fm_wake_queued_keys_locked "$kind"
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
}

fm_wake_queued_keys_locked() {
  local kind=$1
  awk -F '\t' -v kind="$kind" 'NF >= 5 && $3 == kind && !seen[$4]++ { print $4 }' \
    "$FM_WAKE_QUEUE" 2>/dev/null || true
}

fm_wake_secondmate_stall_marker_write() { # <task> <row-key>
  local task=$1 row_key=$2 marker tmp
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$row_key" in ''|*[!0-9-]*) return 1 ;; esac
  marker="$STATE/.secondmate-wake-stall-$task"
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  fi
  tmp=$(mktemp "$STATE/.secondmate-wake-stall.XXXXXX") || return 1
  if ! printf '%s\n' "$row_key" > "$tmp" || ! chmod 0600 "$tmp" \
    || ! _fm_atomic_replace "$tmp" "$marker"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_wake_secondmate_stall_receipt_write() { # <task> <row-key>
  local task=$1 row_key=$2 root task_dir receipt tmp
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$row_key" in ''|*[!0-9-]*) return 1 ;; esac
  root="$STATE/.secondmate-wake-stall-receipts"
  task_dir="$root/$task"
  if [ -e "$root" ] || [ -L "$root" ]; then
    [ -d "$root" ] && [ ! -L "$root" ] || return 1
  else
    mkdir "$root" || return 1
    chmod 0700 "$root" || return 1
  fi
  if [ -e "$task_dir" ] || [ -L "$task_dir" ]; then
    [ -d "$task_dir" ] && [ ! -L "$task_dir" ] || return 1
  else
    mkdir "$task_dir" || return 1
    chmod 0700 "$task_dir" || return 1
  fi
  receipt="$task_dir/$row_key"
  [ "$(cat "$receipt" 2>/dev/null || true)" != "$row_key" ] || return 0
  tmp=$(mktemp "$task_dir/.receipt.XXXXXX") || return 1
  if ! printf '%s\n' "$row_key" > "$tmp" || ! chmod 0600 "$tmp" \
    || ! _fm_atomic_replace "$tmp" "$receipt"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_wake_commit_secondmate_stall_receipts_through() { # <cutoff> [<rows-file>]
  local cutoff=$1 rows=${2:-} key seq rest epoch task row_key
  while IFS= read -r key; do
    seq=${key##*-}
    rest=${key%-*}
    epoch=${rest##*-}
    task=${rest#secondmate-wake-loop-}
    task=${task%-"$epoch"}
    case "$seq" in ''|*[!0-9]*) return 1 ;; esac
    case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
    case "$task" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
    row_key="$epoch-$seq"
    fm_wake_secondmate_stall_receipt_write "$task" "$row_key" || return 1
  done < <(awk -F '\t' -v cutoff="$cutoff" -v rows="$rows" '
    BEGIN { if (rows != "") while ((getline line < rows) > 0) owned[line]=1 }
    NF >= 5 && $2 ~ /^[0-9]+$/ && $2 <= cutoff \
      && (rows == "" || ($2 in owned)) && $3 == "check" \
      && $4 ~ /^secondmate-wake-loop-[A-Za-z0-9._-]+-[0-9]+-[0-9]+$/ { print $4 }
  ' "$FM_WAKE_QUEUE" 2>/dev/null)
}

fm_wake_restore_queue() {
  local drained=$1 restore
  restore="$STATE/.wake-queue.restore.$(fm_current_pid)"
  if [ -e "$FM_WAKE_QUEUE" ]; then
    cat "$drained" "$FM_WAKE_QUEUE" > "$restore" && mv "$restore" "$FM_WAKE_QUEUE"
  else
    mv "$drained" "$FM_WAKE_QUEUE"
  fi
}

fm_wake_print_deduped() {
  local file=$1
  awk -F '\t' '
    NF >= 5 {
      dedupe = $3 SUBSEP $4
      if ($3 == "heartbeat") {
        dedupe = "heartbeat"
      }
      if (!(dedupe in seen)) {
        order[++count] = dedupe
        seen[dedupe] = 1
      }
      line[dedupe] = $0
    }
    END {
      for (i = 1; i <= count; i++) {
        print line[order[i]]
      }
    }
  ' "$file"
}

# --- signal announcement signatures -----------------------------------------
#
# The watcher's per-file signal scan (bin/fm-watch.sh scan_signals) detects a
# status or turn-ended change by comparing a file signature against a persisted
# state/.seen-* marker.
# fm-classify-lib.sh's header owns the status marker contract, including its
# independent reported signature and classified position.
# These helpers own wake-facing marker routing, the legacy turn-ended signature,
# drain-time staleness checks, and guarded bookkeeping writes.

fm_wake_signal_sig() {  # <file> -> reported-state signature
  case "$1" in
    *.status)
      _fm_wake_require_classify || return 1
      status_observed_signature "$1"
      ;;
    *)
      if [ "$_FM_UNAME" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
      ;;
  esac
}

fm_wake_signal_seen_path() {  # <state> <file>
  local task
  case "$2" in
    *.status)
      task=$(basename "$2"); task=${task%.status}
      printf '%s/.seen-%s' "$1" "$(printf '%s.status' "$task" | tr '.' '_')"
      ;;
    *) printf '%s/.seen-%s' "$1" "$(basename "$2" | tr '.' '_')" ;;
  esac
}

# The byte size recorded in <file>'s seen marker, or 0 when no marker exists, it
# cannot be read, or it does not hold the supported presentation-marker format.
# That size is the position the watcher has already classified, independently of
# the file signature it has already reported. A 0 means "classify the whole
# file", which surfaces events rather than losing them.
fm_wake_signal_seen_size() {  # <state> <file>
  local marker sig size
  marker=$(fm_wake_signal_seen_path "$1" "$2")
  case "$2" in
    *.status)
      _fm_wake_require_classify || { printf '0'; return 0; }
      status_presentation_marker_offset "$marker" "$2"
      ;;
    *)
      sig=$(cat "$marker" 2>/dev/null) || { printf '0'; return 0; }
      case "$sig" in *:*) size=${sig%%:*} ;; *) size=0 ;; esac
      case "$size" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$size" ;; esac
      ;;
  esac
}

# 0 when <file>'s current signature matches its recorded reported state.
# For a status file this means the current state was already reported, not that
# every byte was successfully classified; the separate classified position owns
# that fact.
# A missing marker or unreadable signature is not a match, so uncertainty reads
# as an unreported state.
fm_wake_signal_seen_current() {  # <state> <file>
  local sig marker
  sig=$(fm_wake_signal_sig "$2") || return 1
  [ -n "$sig" ] || return 1
  marker=$(fm_wake_signal_seen_path "$1" "$2")
  case "$2" in
    *.status)
      _fm_wake_require_classify || return 1
      status_presentation_marker_reported_matches "$marker" "$sig"
      ;;
    *) [ "$(cat "$marker" 2>/dev/null)" = "$sig" ] ;;
  esac
}

fm_wake_status_reported_commit() {  # <state> <status-file> <reported-signature>
  _fm_wake_require_classify || return 1
  status_presentation_marker_report "$(fm_wake_signal_seen_path "$1" "$2")" "$3"
}

fm_wake_status_seen_commit() {  # <state> <status-file> <captured-end> <captured-identity>
  _fm_wake_require_classify || return 1
  status_presentation_marker_commit "$(fm_wake_signal_seen_path "$1" "$2")" "$2" "$3" "$4"
}

# Mark the current complete status snapshot as both reported and classified.
# This is the public setup primitive for consumers that adopt an existing log.
fm_wake_status_mark_current() {  # <state> <status-file>
  local size ident
  _fm_wake_require_classify || return 1
  size=$(_fm_status_file_size "$2") || return 1
  ident=$(_fm_open_decisions_file_ident "$2") || return 1
  fm_wake_status_seen_commit "$1" "$2" "$size" "$ident"
}

# Guarded self-announced status append - the one dedup primitive for a status
# line THIS home's own machinery writes as bookkeeping it has already presented
# in the very turn or tick that writes it (an answerer-closes resolved line, a
# pending-reply escalation close, a captain-held transfer). Such a close must
# not wake the session that wrote it, so this appends the line and then
# advances the watcher's seen marker to cover exactly the appended bytes and
# nothing else. The advance is provenance-gated and fails toward waking:
#   - the marker advances ONLY when the file's pre-append signature matched the
#     recorded seen marker (every earlier byte was already announced or
#     deliberately absorbed), AND the post-append size equals the pre-append
#     size plus exactly the appended bytes (no foreign write interleaved);
#   - on ANY other condition - missing marker, pending foreign bytes, an
#     interleaved writer, an unreadable signature - the line is still appended
#     but the marker is left alone, so the watcher surfaces the file normally.
# A later, different line from any other writer grows the size past the marker
# and wakes as before: task identity alone can never suppress new content.
# Returns 0 appended and self-announced, 1 appended but left for the watcher
# (the safe direction), 2 the append itself failed.
fm_wake_status_append_self_announced() {  # <state> <status-file> <line>
  local state=$1 file=$2 line=$3 marker pre_sig='' pre_size='' pre_ident='' post_size post_ident
  local LC_ALL=C
  _fm_wake_require_classify || return 1
  marker=$(fm_wake_signal_seen_path "$state" "$file")
  if [ -e "$file" ]; then
    pre_sig=$(fm_wake_signal_sig "$file") || pre_sig=''
    pre_size=$(_fm_status_file_size "$file") || pre_size=''
    pre_ident=$(_fm_open_decisions_file_ident "$file") || pre_ident=''
  fi
  printf '%s\n' "$line" >> "$file" || return 2
  [ -n "$pre_sig" ] || return 1
  status_presentation_marker_reported_matches "$marker" "$pre_sig" || return 1
  [ "$(status_presentation_marker_offset "$marker" "$file")" = "$pre_size" ] || return 1
  post_size=$(_fm_status_file_size "$file") || return 1
  post_ident=$(_fm_open_decisions_file_ident "$file") || return 1
  case "$pre_size$post_size" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$pre_ident" ] && [ "$post_ident" = "$pre_ident" ] || return 1
  [ "$post_size" -eq $((pre_size + ${#line} + 1)) ] || return 1
  fm_wake_status_seen_commit "$state" "$file" "$post_size" "$post_ident" || return 1
  return 0
}

# Map one structurally valid signal key to its home-local status filename.
# Queue payload text is intentionally ignored: it is display data, not a path
# authority. The caller still verifies the resulting regular file immediately
# before its bounded read.
FM_WAKE_STATUS_KEY=
FM_WAKE_STATUS_HISTORICAL=false
fm_wake_status_key_map() {  # <queue-key>
  local key=$1 id
  FM_WAKE_STATUS_KEY=
  FM_WAKE_STATUS_HISTORICAL=false
  case "$key" in
    *.status)
      id=${key%.status}
      ;;
    *.turn-ended)
      id=${key%.turn-ended}
      FM_WAKE_STATUS_HISTORICAL=true
      ;;
    *)
      return 1
      ;;
  esac
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -le 64 ] || return 1
  FM_WAKE_STATUS_KEY="$id.status"
}

fm_wake_annotation_manifest() {  # <deduped-raw-rows>
  local rows=$1 epoch seq kind key payload
  while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    [ "$kind" = signal ] || continue
    fm_wake_status_key_map "$key" || continue
    if [ "$FM_WAKE_STATUS_HISTORICAL" = true ]; then
      printf '%s\thistorical\n' "$FM_WAKE_STATUS_KEY"
    else
      printf '%s\tdirect\n' "$FM_WAKE_STATUS_KEY"
    fi
  done <<EOF
$rows
EOF
}

FM_WAKE_EVENT_LINE=
FM_WAKE_UNREAD_LINES=
fm_wake_status_cursor_offset() {  # <validated-status-path> -> already-presented byte offset
  local path=$1 offset
  command -v status_presentation_cursor_offset >/dev/null 2>&1 || return 1
  offset=$(status_presentation_cursor_offset "$path" 2>/dev/null) || return 1
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$offset"
}

# O_NOFOLLOW read of every still-unread status byte. min-offset is the
# already-presented cursor from classify-lib. Lines whose bytes begin before
# that offset are not replayed. Prints nothing and returns 1 when no unread
# non-blank line exists.
fm_wake_unread_events() {  # <validated-status-path> <unused-tail-byte-cap> <min-offset> [<end-offset>]
  local path=$1 min_offset=$3 end_offset=${4:-} result size chunk chunk_start
  local LC_ALL=C
  FM_WAKE_EVENT_LINE=
  FM_WAKE_UNREAD_LINES=
  case "$min_offset" in ''|*[!0-9]*) min_offset=0 ;; esac
  result=$(perl -MFcntl=:DEFAULT -e '
    my ($path, $start, $end) = @ARGV;
    sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    my @stat = stat $file or exit 1;
    exit 1 unless -f _;
    my $size = $stat[7];
    exit 1 unless $size =~ /\A\d+\z/ && $start =~ /\A\d+\z/ && $start <= $size;
    $end = $size unless length $end;
    exit 1 unless $end =~ /\A\d+\z/ && $start <= $end && $end <= $size;
    seek($file, $start, 0) or exit 1;
    printf "%s\t", $end or exit 1;
    my $remaining = $end - $start;
    while ($remaining > 0) {
      my $read = read($file, my $buffer, $remaining);
      exit 1 unless defined $read;
      last unless $read;
      print $buffer or exit 1;
      $remaining -= $read;
    }
  ' "$path" "$min_offset" "$end_offset" 2>/dev/null) || return 1
  size=${result%%$'\t'*}
  chunk=${result#*$'\t'}
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$chunk" ] || return 1
  [ "$min_offset" -lt "$size" ] || return 1
  chunk_start=$min_offset
  FM_WAKE_UNREAD_LINES=$(printf '%s' "$chunk" | LC_ALL=C awk -v start="$chunk_start" -v min="$min_offset" '
    BEGIN { pos = start + 0 }
    {
      line_start = pos
      pos += length($0) + 1
      if ($0 ~ /[^[:space:]]/ && line_start >= min) print $0
    }
  ') || return 1
  [ -n "$FM_WAKE_UNREAD_LINES" ] || return 1
  FM_WAKE_EVENT_LINE=$(printf '%s\n' "$FM_WAKE_UNREAD_LINES" | tail -1)
  FM_WAKE_EVENT_LINE=$(printf '%s' "$FM_WAKE_EVENT_LINE" | LC_ALL=C tr '\t\r' '  ')
}

fm_wake_latest_event() {  # <validated-status-path> <tail-byte-cap>
  fm_wake_unread_events "$1" "$2" 0
}

# Print supplemental drain-time context only after the caller has committed the
# raw queue consumption and released the append lock.
fm_wake_print_annotations() {  # <deduped-raw-rows> [<presentation-snapshot>]
  local rows=$1 snapshot=${2:-} manifest status_key mode path prefix line task endpoint
  local snapshot_task snapshot_endpoint _snapshot_ident offset last_event event_line
  local LC_ALL=C

  manifest=$(fm_wake_annotation_manifest "$rows" | awk -F '\t' '
    {
      key = $1
      if (!(key in seen)) {
        order[++count] = key
        seen[key] = 1
        mode[key] = $2
      } else if ($2 == "direct") {
        mode[key] = "direct"
      }
    }
    END {
      for (i = 1; i <= count; i++) print order[i] "\t" mode[order[i]]
    }
  ') || return 0

  # Test-only latency seam for proving that queue appends remain independent of
  # a slow best-effort annotation phase.
  case "${FM_WAKE_ENRICH_TEST_DELAY:-0}" in
    0) ;;
    ''|*[!0-9]*) ;;
    *) sleep "$FM_WAKE_ENRICH_TEST_DELAY" ;;
  esac

  while IFS=$(printf '\t') read -r status_key mode; do
    [ -n "$status_key" ] || continue
    path="$STATE/$status_key"
    # A turn-ended-only (historical) row's annotation would show unread status
    # lines even when those bytes are fully covered by the seen marker - already
    # surfaced to firstmate or deliberately absorbed by the signal triage.
    # Presenting such an already-announced line again makes a bare turn-end look
    # like fresh progress, so skip the annotation when the status file's
    # signature still matches its marker (a proven replay). Any uncertainty -
    # missing marker, unreadable signature - keeps the annotation with its
    # existing historical caveat. A direct status row is annotated for every
    # still-unread line since the last drain presentation; already-presented
    # bytes are not replayed.
    if [ "$mode" = historical ] && fm_wake_signal_seen_current "$STATE" "$path"; then
      continue
    fi
    offset=$(fm_wake_status_cursor_offset "$path") || return 1
    endpoint=
    if [ -n "$snapshot" ]; then
      task=${status_key%.status}
      while IFS=$(printf '\t') read -r snapshot_task snapshot_endpoint _snapshot_ident; do
        if [ "$snapshot_task" = "$task" ]; then endpoint=$snapshot_endpoint; break; fi
      done <<EOF
$snapshot
EOF
      [ -n "$endpoint" ] || continue
    fi
    if [ -n "$endpoint" ] && [ "$offset" -ge "$endpoint" ]; then continue; fi
    if ! fm_wake_unread_events "$path" 0 "$offset" "$endpoint"; then
      # Annotation enrichment is supplemental to the already-printed durable
      # wake rows. A file that disappears, rotates, or becomes unreadable after
      # the snapshot must not suppress annotations for other status files; the
      # presentation commit will reject a changed snapshot identity.
      continue
    fi
    last_event=$FM_WAKE_EVENT_LINE
    while IFS= read -r event_line || [ -n "$event_line" ]; do
      [ -n "$event_line" ] || continue
      event_line=$(printf '%s' "$event_line" | LC_ALL=C tr '\t\r' '  ')
      prefix="wake annotation: latest wake-EVENT observed at drain, not current state"
      if [ "$event_line" != "$last_event" ]; then
        prefix="wake annotation: unread wake-EVENT since last drain, not current state"
      fi
      if [ "$mode" = historical ]; then
        prefix="$prefix; historical / not necessarily the triggering event"
      fi
      line="$prefix: $status_key: $event_line"
      printf '%s\n' "$line" || return 1
    done <<EOF
$FM_WAKE_UNREAD_LINES
EOF
  done <<EOF
$manifest
EOF

  return 0
}
