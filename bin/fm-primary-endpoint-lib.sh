#!/usr/bin/env bash
# fm-primary-endpoint-lib.sh - identity-bound primary endpoint and Kiro wake ring.
#
# A Kiro V3 primary cannot be continued from its Stop hook, so its background
# watcher needs one structural way to start the next turn after it appends an
# actionable row to the existing durable wake queue. This library records the
# primary pane and rings one constant line after publication.
# It creates no second queue, acknowledgement, retry ladder, or control plane.
#
# Record: state/.primary-endpoint, exactly eight lines:
#   schema=fm-primary-endpoint.v1
#   harness=kiro-cli
#   backend=tmux|herdr
#   target=<backend target>
#   pid=<outer Kiro session pid, also the fleet-lock pid>
#   pid_identity=<fm_pid_identity output>
#   root=<absolute Firstmate code root>
#   home=<absolute effective Firstmate home>
#
# Publication happens only for the session that holds the fleet lock: once at
# SessionStart, then idempotently every turn through fm_primary_endpoint_ensure.
# A ring revalidates the home, root, exact lock pid, process identity, outer
# `kiro-cli` process name, backend target, and empty Kiro composer. Any stale,
# malformed, moved, busy, pending, dead, or unsupported record is a quiet
# refusal; the durable wake remains queued, and the watcher's poll loop rings
# again for the queue's newest unrung row once the pane is idle
# (state/.primary-doorbell-rung records the sequence last rung). Away mode keeps
# its existing daemon injection owner, and a foreground checkpoint sets
# FM_WATCH_FOREGROUND_CHECKPOINT=1 so watcher stdout remains its only delivery.
#
# Requires no caller-prepared globals. Sourcing is side-effect-free apart from
# the existing fm-wake-lib state-directory behavior reached by its dependencies.

FM_PRIMARY_ENDPOINT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$FM_PRIMARY_ENDPOINT_LIB_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$FM_PRIMARY_ENDPOINT_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_PRIMARY_ENDPOINT_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_PRIMARY_ENDPOINT_LIB_DIR/fm-session-lock-lib.sh"

FM_PRIMARY_ENDPOINT_SCHEMA=fm-primary-endpoint.v1
FM_PRIMARY_ENDPOINT_BACKEND=
FM_PRIMARY_ENDPOINT_TARGET=
FM_PRIMARY_ENDPOINT_ROOT=
FM_PRIMARY_ENDPOINT_HOME=
FM_PRIMARY_ENDPOINT_PID=
FM_PRIMARY_ENDPOINT_ERROR=

fm_primary_endpoint_fail() {
  FM_PRIMARY_ENDPOINT_ERROR=$1
  return 1
}

fm_primary_endpoint_path() {  # <state-dir>
  printf '%s/.primary-endpoint' "${1%/}"
}

fm_primary_endpoint_abs_dir() {  # <directory>
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P)
}

fm_primary_endpoint_kiro_pid() {
  local pid comm base
  pid=$(fm_session_lock_anchor_pid) || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  base=${comm##*/}
  [ "$base" = kiro-cli ] || return 1
  printf '%s' "$pid"
}

# Resolve what the record should say for this session right now, or fail with
# FM_PRIMARY_ENDPOINT_ERROR. Sets the FM_PRIMARY_ENDPOINT_OBS_* globals. Local
# and cheap: environment, one backend target probe, and the ancestry walk.
FM_PRIMARY_ENDPOINT_OBS_STATE=
FM_PRIMARY_ENDPOINT_OBS_ROOT=
FM_PRIMARY_ENDPOINT_OBS_HOME=
FM_PRIMARY_ENDPOINT_OBS_BACKEND=
FM_PRIMARY_ENDPOINT_OBS_TARGET=
FM_PRIMARY_ENDPOINT_OBS_PID=
fm_primary_endpoint_observe() {  # <state-dir> <root> <home>
  local state root home backend target pid lock_pid
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_PRIMARY_ENDPOINT_ERROR=
  state=$(fm_primary_endpoint_abs_dir "$1") || { fm_primary_endpoint_fail "state directory is absent, symlinked, or unresolved"; return 1; }
  root=$(fm_primary_endpoint_abs_dir "$2") || { fm_primary_endpoint_fail "Firstmate code root is absent, symlinked, or unresolved"; return 1; }
  home=$(fm_primary_endpoint_abs_dir "$3") || { fm_primary_endpoint_fail "effective Firstmate home is absent, symlinked, or unresolved"; return 1; }
  backend=$(discover_supervisor_backend) || { fm_primary_endpoint_fail "supervisor backend was not structurally discoverable"; return 1; }
  target=$(discover_supervisor_target) || { fm_primary_endpoint_fail "supervisor target was not structurally discoverable"; return 1; }
  case "$backend" in
    tmux|herdr) ;;
    *) fm_primary_endpoint_fail "supervisor backend '$backend' is not supported by the Kiro doorbell"; return 1 ;;
  esac
  case "$target" in
    ''|*$'\n'*|*$'\r'*|*[![:print:]]*)
      fm_primary_endpoint_fail "supervisor target is empty or contains unsafe bytes"
      return 1
      ;;
  esac
  fm_backend_target_exists "$backend" "$target" || { fm_primary_endpoint_fail "supervisor target '$target' is not readable on backend '$backend'"; return 1; }
  pid=$(fm_primary_endpoint_kiro_pid) || { fm_primary_endpoint_fail "outer Kiro session pid could not be resolved from hook ancestry"; return 1; }
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  if [ "$lock_pid" != "$pid" ]; then
    fm_primary_endpoint_fail "fleet lock pid '${lock_pid:-absent}' does not match outer Kiro pid '$pid'"
    return 1
  fi
  FM_PRIMARY_ENDPOINT_OBS_STATE=$state
  FM_PRIMARY_ENDPOINT_OBS_ROOT=$root
  FM_PRIMARY_ENDPOINT_OBS_HOME=$home
  FM_PRIMARY_ENDPOINT_OBS_BACKEND=$backend
  FM_PRIMARY_ENDPOINT_OBS_TARGET=$target
  FM_PRIMARY_ENDPOINT_OBS_PID=$pid
}

# Write the observed record atomically.
fm_primary_endpoint_write_observed() {
  local state=$FM_PRIMARY_ENDPOINT_OBS_STATE pid=$FM_PRIMARY_ENDPOINT_OBS_PID identity path tmp
  identity=$(fm_pid_identity "$pid") || { fm_primary_endpoint_fail "outer Kiro pid identity could not be read"; return 1; }
  case "$identity" in
    ''|*$'\n'*|*$'\r'*)
      fm_primary_endpoint_fail "outer Kiro pid identity is empty or multiline"
      return 1
      ;;
  esac
  path=$(fm_primary_endpoint_path "$state")
  tmp=$(umask 077; mktemp "$state/.primary-endpoint.XXXXXXXXXXXX") || { fm_primary_endpoint_fail "endpoint record temporary file could not be created"; return 1; }
  if ! {
    printf 'schema=%s\n' "$FM_PRIMARY_ENDPOINT_SCHEMA"
    printf 'harness=kiro-cli\n'
    printf 'backend=%s\n' "$FM_PRIMARY_ENDPOINT_OBS_BACKEND"
    printf 'target=%s\n' "$FM_PRIMARY_ENDPOINT_OBS_TARGET"
    printf 'pid=%s\n' "$pid"
    printf 'pid_identity=%s\n' "$identity"
    printf 'root=%s\n' "$FM_PRIMARY_ENDPOINT_OBS_ROOT"
    printf 'home=%s\n' "$FM_PRIMARY_ENDPOINT_OBS_HOME"
  } > "$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp" 2>/dev/null || true
    fm_primary_endpoint_fail "endpoint record could not be published atomically"
    return 1
  fi
  return 0
}

fm_primary_endpoint_publish() {  # <state-dir> <root> <home>
  fm_primary_endpoint_observe "$1" "$2" "$3" || return 1
  fm_primary_endpoint_write_observed
}

# fm_primary_endpoint_ensure: the per-turn owner. Kiro fires SessionStart only
# for a conversation's first prompt, so a primary whose hooks arrived later, whose
# pane moved, or whose outer pid changed would otherwise keep a missing or stale
# doorbell for the rest of the session. The primary's UserPromptSubmit and Stop
# hooks call this every turn. It converges on the record this session would
# publish: a record that already loads and names this session's backend, target,
# and pid is left untouched; anything else is republished. It refuses exactly
# where publication refuses - above all when the fleet lock is not this
# session's, so another session's record is never overwritten.
# Sets FM_PRIMARY_ENDPOINT_ENSURED=current|published on success.
FM_PRIMARY_ENDPOINT_ENSURED=
fm_primary_endpoint_ensure() {  # <state-dir> <root> <home>
  FM_PRIMARY_ENDPOINT_ENSURED=
  fm_primary_endpoint_observe "$1" "$2" "$3" || return 1
  if fm_primary_endpoint_load "$FM_PRIMARY_ENDPOINT_OBS_STATE" "$FM_PRIMARY_ENDPOINT_OBS_ROOT" "$FM_PRIMARY_ENDPOINT_OBS_HOME" \
    && [ "$FM_PRIMARY_ENDPOINT_BACKEND" = "$FM_PRIMARY_ENDPOINT_OBS_BACKEND" ] \
    && [ "$FM_PRIMARY_ENDPOINT_TARGET" = "$FM_PRIMARY_ENDPOINT_OBS_TARGET" ] \
    && [ "$FM_PRIMARY_ENDPOINT_PID" = "$FM_PRIMARY_ENDPOINT_OBS_PID" ]; then
    # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
    FM_PRIMARY_ENDPOINT_ENSURED=current
    return 0
  fi
  fm_primary_endpoint_write_observed || return 1
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_PRIMARY_ENDPOINT_ENSURED=published
}

fm_primary_endpoint_load() {  # <state-dir> <expected-root> <expected-home>
  local state=$1 expected_root expected_home path line key value extra
  local schema='' harness='' backend='' target='' pid='' identity='' root='' home=''
  local lock_pid='' current='' comm='' base=''
  FM_PRIMARY_ENDPOINT_BACKEND=
  FM_PRIMARY_ENDPOINT_TARGET=
  FM_PRIMARY_ENDPOINT_ROOT=
  FM_PRIMARY_ENDPOINT_HOME=
  FM_PRIMARY_ENDPOINT_PID=
  state=$(fm_primary_endpoint_abs_dir "$state") || return 1
  expected_root=$(fm_primary_endpoint_abs_dir "$2") || return 1
  expected_home=$(fm_primary_endpoint_abs_dir "$3") || return 1
  path=$(fm_primary_endpoint_path "$state")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) return 1 ;;
    esac
    case "$key" in
      schema) [ -z "$schema" ] || return 1; schema=$value ;;
      harness) [ -z "$harness" ] || return 1; harness=$value ;;
      backend) [ -z "$backend" ] || return 1; backend=$value ;;
      target) [ -z "$target" ] || return 1; target=$value ;;
      pid) [ -z "$pid" ] || return 1; pid=$value ;;
      pid_identity) [ -z "$identity" ] || return 1; identity=$value ;;
      root) [ -z "$root" ] || return 1; root=$value ;;
      home) [ -z "$home" ] || return 1; home=$value ;;
      *) return 1 ;;
    esac
  done < "$path"
  [ "$schema" = "$FM_PRIMARY_ENDPOINT_SCHEMA" ] || return 1
  [ "$harness" = kiro-cli ] || return 1
  case "$backend" in tmux|herdr) ;; *) return 1 ;; esac
  case "$target" in ''|*$'\n'*|*$'\r'*|*[![:print:]]*) return 1 ;; esac
  case "$pid" in ''|*[!0-9]*|0) return 1 ;; esac
  [ -n "$identity" ] || return 1
  [ "$root" = "$expected_root" ] || return 1
  [ "$home" = "$expected_home" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  [ "$lock_pid" = "$pid" ] || return 1
  current=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$current" = "$identity" ] || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  base=${comm##*/}
  [ "$base" = kiro-cli ] || return 1
  fm_backend_target_exists "$backend" "$target" || return 1
  FM_PRIMARY_ENDPOINT_BACKEND=$backend
  FM_PRIMARY_ENDPOINT_TARGET=$target
  FM_PRIMARY_ENDPOINT_ROOT=$root
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_PRIMARY_ENDPOINT_HOME=$home
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_PRIMARY_ENDPOINT_PID=$pid
  return 0
}

fm_primary_endpoint_shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

fm_primary_endpoint_doorbell_line() {  # <root>
  local root=$1 drain
  drain=$(fm_primary_endpoint_shell_quote "$root/bin/fm-wake-drain.sh") || return 1
  printf ': Firstmate wake waiting: handle the durable wake context attached by the Kiro UserPromptSubmit hook; if none was attached, run %s now, then run the exact WAKE_ACK_REQUIRED command after handling.' "$drain"
}

fm_primary_endpoint_ring_kiro_wake() {  # <state-dir> <root> <home>
  local state=$1 root=$2 home=$3 composer line verdict
  [ "${FM_WATCH_FOREGROUND_CHECKPOINT:-0}" != 1 ] || return 1
  [ ! -e "$state/.afk" ] || return 1
  fm_primary_endpoint_load "$state" "$root" "$home" || return 1
  composer=$(fm_backend_composer_state "$FM_PRIMARY_ENDPOINT_BACKEND" \
    "$FM_PRIMARY_ENDPOINT_TARGET" '' kiro-cli 2>/dev/null) || return 1
  [ "$composer" = empty ] || return 1
  line=$(fm_primary_endpoint_doorbell_line "$FM_PRIMARY_ENDPOINT_ROOT") || return 1
  verdict=$(fm_backend_send_text_submit "$FM_PRIMARY_ENDPOINT_BACKEND" \
    "$FM_PRIMARY_ENDPOINT_TARGET" "$line" 1 0.4 0.3 2>/dev/null) || return 1
  [ "$verdict" != send-failed ]
}

# fm_primary_endpoint_ring_pending: the re-ring ladder. Ring once for the
# queue's newest row and record its sequence in state/.primary-doorbell-rung, so
# a doorbell refused while the pane was busy is rung again by a later watcher
# poll once the composer is empty, while an idle pane whose newest row was
# already rung is left alone. Both the watcher's wake publication and its poll
# loop call this, so there is one ring owner and one marker. A quiet refusal
# leaves the marker untouched; an empty queue or absent endpoint is a no-op.
fm_primary_endpoint_ring_pending() {  # <state-dir> <root> <home>
  local state=$1 root=$2 home=$3 seq last
  [ -s "$state/.wake-queue" ] || return 1
  [ -f "$state/.primary-endpoint" ] || return 1
  seq=$(tail -n 1 -- "$state/.wake-queue" | cut -f2)
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  last=$(cat "$state/.primary-doorbell-rung" 2>/dev/null || true)
  [ "$seq" != "$last" ] || return 1
  fm_primary_endpoint_ring_kiro_wake "$state" "$root" "$home" || return 1
  printf '%s\n' "$seq" > "$state/.primary-doorbell-rung"
}
