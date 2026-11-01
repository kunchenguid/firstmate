#!/usr/bin/env bash
# Provision and operate an isolated Herdr Core (`hc`) lab session without
# risking the user's own core state.
#
# Usage:
#   fm-hc-lab.sh name <label>
#   fm-hc-lab.sh provision <session>
#   fm-hc-lab.sh socket <session>
#   fm-hc-lab.sh run <session> <hc arguments...>
#   fm-hc-lab.sh stop <session>
#   fm-hc-lab.sh teardown <session>
#
# A core session is an isolated state/socket domain, so isolation here is an
# owned directory holding scratch XDG_STATE_HOME / XDG_CONFIG_HOME /
# XDG_DATA_HOME plus an explicitly pinned HC_SESSION and HC_SOCKET - every hc
# call this helper makes carries all five, and ambient HC_TERMINAL_* markers
# are stripped, exactly like bin/backends/hc.sh.
#
# Session names must begin with "fm-hclab-" and can never be "default".
# The name command sanitizes the label, caps it at 16 characters, and appends
# process/random suffixes to keep generated paths short.
# Mutating commands require non-symlink, operator-owned lab/socket roots
# without group/other write access; new roots are created mode 0700.
# Provision creates its session directory exclusively, never adopting one.
#
# The run command rejects caller-supplied --session/--socket flags, a leading
# option before the hc subcommand, the `server` lifecycle subcommand (guarded
# stop/teardown own it), and `connect` (raw protocol writes bypass the CLI
# guards).
#
# Provision snapshots the REAL user core state - the file inventory of
# ${XDG_STATE_HOME:-$HOME/.local/state}/herdr-core, /run/user/$UID/herdr-core,
# and, when set, $XDG_RUNTIME_DIR/herdr-core - as a fleet tripwire, recorded inside the
# session's own lab directory as fleet-state.txt plus the resolved root list
# in fleet-roots.txt (recorded once, so a caller that repoints XDG for its own
# children cannot shift what the tripwire watches). The snapshot is file
# metadata only (never an `hc` call: hc auto-starts a stopped core on
# contact, which would itself disturb the state being verified). Teardown
# stops the lab server and sweeps session processes, then requires a complete,
# byte-identical snapshot before removing the session directory and sockets.
# Failed reads or changed real-core metadata refuse verification and retain
# the lab directory for inspection, never reducing the failure to a warning.
set -u

fm_hclab_error() {
  echo "fm-hc-lab: $*" >&2
}

fm_hclab_validate_name() { # <session>
  local name=${1:-}
  [[ "$name" =~ ^fm-hclab-[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] && return 0
  case "$name" in
    default) fm_hclab_error "refusing session name 'default'" ;;
    '') fm_hclab_error "refusing an empty session name" ;;
    *) fm_hclab_error "session name must start with 'fm-hclab-' and contain only letters, digits, underscores, or dashes: $name" ;;
  esac
  return 1
}

fm_hclab_root() {
  printf '%s' "${FM_HC_LAB_DIR:-${TMPDIR:-/tmp}/fm-hc-lab-${UID}}"
}

# Create roots privately, or refuse roots another user could control.
fm_hclab_private_root() { # <root>
  local root=$1 mode
  if [ ! -e "$root" ] && [ ! -L "$root" ]; then
    mkdir -m 700 "$root" || return 1
  fi
  if [ "$(uname)" = Darwin ]; then
    mode=$(/usr/bin/stat -f '%Lp' "$root") || return 1
  else
    mode=$(stat -c '%a' "$root") || return 1
  fi
  if [ ! -d "$root" ] || [ -L "$root" ] || [ ! -O "$root" ] || (( (8#$mode & 0022) != 0 )); then
    fm_hclab_error "unsafe root '$root': must be an operator-owned directory, not group/other-writable"
    return 1
  fi
}

fm_hclab_session_dir() { # <session>
  printf '%s/%s' "$(fm_hclab_root)" "$1"
}

# Sockets live under a deliberately short directory - AF_UNIX's sun_path
# ceiling (103 bytes on macOS) rejects a socket nested inside a deep worktree
# path. FM_HC_LAB_SOCK_DIR overrides for hosts where /tmp is not writable.
fm_hclab_sock_dir() {
  printf '%s' "${FM_HC_LAB_SOCK_DIR:-/tmp/fm-hc-lab-${UID}}"
}

fm_hclab_socket() { # <session>
  printf '%s/%s.sock' "$(fm_hclab_sock_dir)" "$1"
}

fm_hclab_tripwire_path() { # <session>
  printf '%s/fleet-state.txt' "$(fm_hclab_session_dir "$1")"
}

fm_hclab_roots_path() { # <session>
  printf '%s/fleet-roots.txt' "$(fm_hclab_session_dir "$1")"
}

# fm_hclab_bin: resolve the same binary the adapter would - FM_HC_BIN wins,
# then `herdr-core`, then the `hc` alias.
fm_hclab_bin() {
  if [ -n "${FM_HC_BIN:-}" ]; then
    [ -x "$FM_HC_BIN" ] || { fm_hclab_error "FM_HC_BIN is not executable: $FM_HC_BIN"; return 1; }
    printf '%s' "$FM_HC_BIN"
    return 0
  fi
  command -v herdr-core 2>/dev/null && return 0
  command -v hc 2>/dev/null && return 0
  fm_hclab_error "herdr-core is required (set FM_HC_BIN or install via bin/fm-install-hc.sh)"
  return 1
}

# fm_hclab_cli: every hc call this helper makes, pinned to the lab session's
# env and socket. Ambient HC_* are stripped in a subshell (env -u is not
# portable), stdin detached.
fm_hclab_cli() { # <session> <hc arguments...>
  local name=$1 dir bin
  shift
  dir=$(fm_hclab_session_dir "$name")
  bin=$(fm_hclab_bin) || return 1
  (
    unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SESSION HC_SOCKET
    XDG_STATE_HOME="$dir/env/xdg-state" \
    XDG_CONFIG_HOME="$dir/env/xdg-config" \
    XDG_DATA_HOME="$dir/env/xdg-data" \
    HC_SESSION="$name" \
    HC_SOCKET="$(fm_hclab_socket "$name")" \
    "$bin" "$@" </dev/null
  )
}

# fm_hclab_real_state_roots: the directories real (non-lab) hc state could
# live in under the ambient environment.
fm_hclab_real_state_roots() {
  local base
  base=${XDG_STATE_HOME:-$HOME/.local/state}
  printf '%s\n' "$base/herdr-core"
  if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    printf '%s\n' "$XDG_RUNTIME_DIR/herdr-core"
  fi
  printf '%s\n' "/run/user/${UID}/herdr-core"
}

# fm_hclab_fleet_state: a sorted metadata inventory of the real core state:
# path, inode, mtime, size for every file under the roots passed as arguments.
# This is a pure filesystem read - deliberately NOT an `hc` call, because
# contacting a stopped core auto-starts it and would itself dirty the
# tripwire. The root list is resolved once at provision and recorded in
# fleet-roots.txt, because a caller may legitimately repoint XDG_STATE_HOME
# (the liveness test does) and the tripwire must always compare the SAME
# real-state roots provision saw.
if [ "$(uname 2>/dev/null)" = Darwin ]; then
  fm_hclab_file_meta() { /usr/bin/stat -f '%N %i %m %z' "$1" 2>/dev/null; }
else
  fm_hclab_file_meta() { stat -c '%n %i %Y %s' "$1" 2>/dev/null; }
fi

fm_hclab_fleet_state() ( # <root>...
  set -o pipefail
  local root files f
  for root in "$@"; do
    [ -d "$root" ] || continue
    files=$(find "$root" \( -type f -o -type s \) -print | LC_ALL=C sort) || return 1
    [ -n "$files" ] || continue
    printf '%s\n' "$files" | while IFS= read -r f; do
      fm_hclab_file_meta "$f" || return 1
    done || return 1
  done | LC_ALL=C sort
)

fm_hclab_fleet_state_recorded() ( # <roots-file>
  set -o pipefail
  cat "$1" | while IFS= read -r root; do
    fm_hclab_fleet_state "$root" || return 1
  done | LC_ALL=C sort
)

fm_hclab_check_tripwire() { # <session>
  local name=$1 tripwire roots_file before after
  tripwire=$(fm_hclab_tripwire_path "$name")
  roots_file=$(fm_hclab_roots_path "$name")
  [ -f "$tripwire" ] || {
    fm_hclab_error "missing fleet-state tripwire for '$name'; refusing unverified teardown"
    return 1
  }
  [ -f "$roots_file" ] || {
    fm_hclab_error "missing fleet-state roots record for '$name'; refusing unverified teardown"
    return 1
  }
  if ! before=$(cat "$tripwire") || ! after=$(fm_hclab_fleet_state_recorded "$roots_file"); then
    fm_hclab_error "could not read complete fleet-state snapshot; refusing unverified teardown"
    return 1
  fi
  [ "$before" = "$after" ] || {
    fm_hclab_error "FLEET-STATE TRIPWIRE FAILED: real herdr-core state changed during lab work"
    fm_hclab_error "before: $(printf '%s' "$before" | wc -l | tr -d ' ') files; after: $(printf '%s' "$after" | wc -l | tr -d ' ') files"
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
    return 1
  }
}

fm_hclab_provision() { # <session>
  local name=$1 dir bin attempt status
  fm_hclab_validate_name "$name" || return 1
  bin=$(fm_hclab_bin) || return 1
  command -v jq >/dev/null 2>&1 || { fm_hclab_error "jq is required"; return 1; }
  dir=$(fm_hclab_session_dir "$name")
  mkdir -m 700 "$dir" || {
    fm_hclab_error "could not create session dir for '$name'; refusing to adopt or overwrite it"
    return 1
  }
  mkdir -p "$dir/env/xdg-state" "$dir/env/xdg-config" "$dir/env/xdg-data" || return 1
  fm_hclab_real_state_roots > "$(fm_hclab_roots_path "$name")" || {
    rm -rf "$dir"
    fm_hclab_error "could not record the fleet-state roots"
    return 1
  }
  fm_hclab_fleet_state_recorded "$(fm_hclab_roots_path "$name")" > "$(fm_hclab_tripwire_path "$name")" || {
    rm -rf "$dir"
    fm_hclab_error "could not record the fleet-state tripwire"
    return 1
  }
  fm_hclab_cli "$name" server start --json >/dev/null 2>&1 || {
    rm -rf "$dir"
    fm_hclab_error "could not start lab core for '$name'"
    return 1
  }
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    status=$(fm_hclab_cli "$name" server status --json 2>/dev/null | jq -r '.pid // empty' 2>/dev/null)
    if [ -n "$status" ]; then
      printf 'lab core session %s ready (server pid %s)\n' "$name" "$status" >&2
      return 0
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done
  fm_hclab_error "lab core session '$name' did not report a server pid within 10 seconds"
  return 1
}

fm_hclab_run() { # <session> <hc arguments...>
  local name=$1 arg
  shift
  fm_hclab_validate_name "$name" || return 1
  [ "$#" -gt 0 ] || { fm_hclab_error "run requires hc arguments"; return 1; }
  [ -f "$(fm_hclab_tripwire_path "$name")" ] || {
    fm_hclab_error "missing fleet-state tripwire for '$name'; refusing to drive a session this lab does not own"
    return 1
  }
  case "$1" in
    -*)
      fm_hclab_error "run forbids a leading option before the hc subcommand; it could shift a lifecycle operation past the guard"
      return 1
      ;;
    server)
      fm_hclab_error "run forbids server operations; use guarded stop or teardown"
      return 1
      ;;
    connect)
      fm_hclab_error "run forbids connect; raw protocol writes bypass the CLI guards"
      return 1
      ;;
  esac
  for arg in "$@"; do
    case "$arg" in
      --session|--session=*|--socket|--socket=*)
        fm_hclab_error "run forbids caller-supplied --session/--socket; the helper pins the lab session and socket"
        return 1
        ;;
    esac
  done
  fm_hclab_cli "$name" "$@"
}

fm_hclab_stop() { # <session>
  local name=$1
  fm_hclab_validate_name "$name" || return 1
  [ -f "$(fm_hclab_tripwire_path "$name")" ] || {
    fm_hclab_error "missing fleet-state tripwire for '$name'; refusing stop"
    return 1
  }
  fm_hclab_cli "$name" server stop --json
}

# fm_hclab_caller_pids: the sweeper's own pid, its ancestor chain, and its
# process group (as a `g<pid>` token), cached once per teardown. A caller (a
# test shell, say) exports HC_SESSION for adapter calls, so that env token
# legitimately appears in the caller and every child it spawns - including the
# sweep's own ps/grep/awk transients. Those are not session daemons and must
# never be signaled; session daemons are setsid'd (reparented to init in their
# own session), so a shared process group cannot hide them.
FM_HCLAB_CALLER_PIDS=""
fm_hclab_caller_pids() {
  [ -n "$FM_HCLAB_CALLER_PIDS" ] && return 0
  local pid=$PPID pgid
  pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
  FM_HCLAB_CALLER_PIDS=" $$ g${pgid:-0}"
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    FM_HCLAB_CALLER_PIDS="$FM_HCLAB_CALLER_PIDS $pid"
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
}

# fm_hclab_session_pids: pids of processes carrying HC_SESSION=<name> in their
# environment - the session's own `serve`/`hold` daemons and anything they
# spawned. `ps ewwax` exposes the environment of same-uid processes on both
# macOS (BSD ps) and Linux (procps). The match is anchored on env-token
# boundaries on both sides so a longer assignment or a name suffix can never
# match. The caller tree (ancestor chain, their children, and everything in
# the caller's process group) is excluded.
fm_hclab_session_pids() { # <session>
  local name=$1
  fm_hclab_caller_pids
  # shellcheck disable=SC2009 # the match is on the process ENVIRONMENT (HC_SESSION), which pgrep -f cannot read.
  ps ewwax -o pid=,ppid=,pgid=,command= 2>/dev/null \
    | grep -E "(^|[[:space:]])HC_SESSION=${name}([[:space:]]|$)" \
    | awk -v excl="$FM_HCLAB_CALLER_PIDS" \
      'index(excl, " "$1" ") == 0 && index(excl, " "$2" ") == 0 && index(excl, " g"$3" ") == 0 { print $1 }'
}

fm_hclab_teardown() { # <session>
  local name=$1 dir pids sig i
  fm_hclab_validate_name "$name" || return 1
  dir=$(fm_hclab_session_dir "$name")
  [ -f "$(fm_hclab_tripwire_path "$name")" ] || {
    fm_hclab_error "missing fleet-state tripwire for '$name'; refusing destructive calls"
    return 1
  }
  fm_hclab_cli "$name" server stop --json >/dev/null 2>&1 || true
  sleep 0.3
  # `server stop` closes the listener, but the session's `serve`/`hold`
  # daemons stay by design (a core's terminals are meant to survive a stopped
  # server). The lab owns the whole session, so every process still carrying
  # its HC_SESSION marker is terminated - TERM first, KILL for the stubborn.
  i=0
  while [ "$i" -lt 16 ]; do
    pids=$(fm_hclab_session_pids "$name")
    [ -z "$pids" ] && break
    if [ "$i" -lt 8 ]; then sig=TERM; else sig=KILL; fi
    printf '%s\n' "$pids" | while IFS= read -r p; do
      [ -n "$p" ] && kill -"$sig" "$p" 2>/dev/null || true
    done
    i=$((i + 1))
    sleep 0.2
  done
  # Signaled daemons take a while to finish exiting - measured ~30-60s while
  # they drain terminal state (their exit also removes the session's state
  # dir). Keep polling well past that envelope before giving up.
  i=0
  while [ "$i" -lt 180 ]; do
    pids=$(fm_hclab_session_pids "$name")
    [ -z "$pids" ] && break
    sleep 0.5
    i=$((i + 1))
  done
  pids=$(fm_hclab_session_pids "$name")
  [ -z "$pids" ] || {
    fm_hclab_error "session processes for '$name' did not exit: $pids; refusing to remove state they still hold"
    return 1
  }
  # The tripwire must pass while its record still exists: it lives inside the
  # session dir, so a failed check keeps the whole lab dir for inspection.
  fm_hclab_check_tripwire "$name" || return 1
  # The lab owns every byte under $dir (scratch XDG roots, tripwire) plus the
  # sockets this session's name covers - its <name>.sock plus any
  # <name>.holder.<hash>.sock the session's hold daemon bound. Remove only
  # those, never the shared lab or socket roots.
  rm -f "$(fm_hclab_socket "$name")" 2>/dev/null || true
  local holder_sock
  for holder_sock in "$(fm_hclab_sock_dir)/$name".holder.*.sock; do
    [ -e "$holder_sock" ] || continue
    rm -f "$holder_sock" 2>/dev/null || true
  done
  case "${dir##*/}" in
    fm-hclab-*) rm -rf "$dir" ;;
    *)
      fm_hclab_error "refusing to remove an unexpected session dir path: $dir"
      return 1
      ;;
  esac
}

cmd=${1:-}
# All commands that can write or remove lab state share the root checks.
case "$cmd" in
  provision|run|stop|teardown)
    fm_hclab_private_root "$(fm_hclab_root)" || exit 1
    fm_hclab_private_root "$(fm_hclab_sock_dir)" || exit 1
    ;;
esac
case "$cmd" in
  name)
    label=${2:-}
    sanitized=$(printf '%s' "$label" | tr -c 'a-zA-Z0-9_-' '-' | cut -c1-16 | sed 's/-*$//')
    [ -n "$sanitized" ] || sanitized=x
    printf 'fm-hclab-%s-%s-%s\n' "$sanitized" "$$" "$RANDOM"
    ;;
  provision) fm_hclab_provision "${2:-}" ;;
  socket)
    fm_hclab_validate_name "${2:-}" || exit 1
    fm_hclab_socket "${2:-}"
    ;;
  run)
    shift
    fm_hclab_run "$@"
    ;;
  stop) fm_hclab_stop "${2:-}" ;;
  teardown) fm_hclab_teardown "${2:-}" ;;
  *)
    fm_hclab_error "unknown command: $cmd (use name, provision, socket, run, stop, or teardown)"
    exit 2
    ;;
esac
