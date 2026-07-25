#!/usr/bin/env bash
# Enter away mode and run the sub-supervisor daemon in a harness-tracked
# foreground process when one is not already alive.
#
# Usage: fm-afk-start.sh
#   Sets state/.afk unless FM_AFK_STATE_PREPARED=1, checks
#   state/.supervise-daemon.lock, and:
#     - prints "afk: daemon already running pid=<pid>" then exits 0 when that
#       lock is held by a live daemon (a REFRESH: no stale-artifact clear);
#     - otherwise clears any prior away session's stale escalation artifacts
#       (fm_afk_clear_stale_artifacts) for a direct, non-prepared start, selects
#       reap-wake delivery when the launch record identifies a native tracked
#       background task, then execs bin/fm-supervise-daemon.sh in the foreground.
#       A prepared start was already cleared transactionally by
#       bin/fm-afk-launch.sh.
#
# This file is sourceable: its BASH_SOURCE guard keeps main from running, while
# exposing the daemon-lock helpers and fm_afk_clear_stale_artifacts. Sourcing it
# enables nounset and errexit; callers that need different shell options must
# restore them explicitly.
#
# This is the COMMON daemon entry for every backend. HOW it becomes a tracked
# background process differs by harness/backend and is owned elsewhere:
#   - Harnesses with a native in-pane tracked-background tool (e.g. claude, grok)
#     run this directly via that tool.
#     The native launch record selects reap-wake delivery, so a captain-relevant
#     escalation completes this process and lets the harness's own background-task
#     notification wake the parked LLM without reading or typing into its pane.
#   - Harnesses with NO native background mechanism (e.g. pi) run this THROUGH
#     bin/fm-afk-launch.sh, which creates a non-visible tracked terminal per
#     backend (herdr tab/workspace, tmux detached session) and passes the
#     captain pane in as FM_SUPERVISOR_TARGET so injection targets it, not the
#     daemon's own new pane.
# Do not wrap this in `nohup ... &`: Codex/herdr can reap fire-and-forget shell
# children after the tool call returns, while a tracked background terminal stays
# attached and has a real lifecycle.
set -eu

FM_AFK_START_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_START_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_AFK_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_AFK_LOCK="$FM_AFK_STATE/.supervise-daemon.lock"
FM_AFK_DAEMON="$FM_AFK_START_DIR/fm-supervise-daemon.sh"
FM_AFK_NATIVE_PROCESS="$FM_AFK_STATE/.afk-native-process"
FM_AFK_NATIVE_HANDOFF_LOCK="$FM_AFK_STATE/.afk-native-handoff.lock"
FM_AFK_LAUNCH_RECORD="$FM_AFK_STATE/.afk-daemon-terminal"
FM_AFK_NATIVE_PROCESS_UNSAFE=0
FM_AFK_NATIVE_PROCESS_MAX_BYTES=4096

fm_afk_safe_control_read() {  # <path> <maximum-bytes>
  python3 - "$1" "$2" <<'PY'
import os
import stat
import sys
import time

source = os.path.abspath(sys.argv[1])
maximum = int(sys.argv[2])
parent_path, name = os.path.split(source)
parent = os.open(parent_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
descriptor = None
try:
    before = os.stat(name, dir_fd=parent, follow_symlinks=False)
    if not stat.S_ISREG(before.st_mode) or before.st_size > maximum:
        raise OSError("unsafe control file")
    ready = os.environ.get("FM_AFK_CONTROL_READ_TEST_READY")
    proceed = os.environ.get("FM_AFK_CONTROL_READ_TEST_PROCEED")
    if ready and proceed:
        marker = os.open(ready, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.close(marker)
        deadline = time.monotonic() + 5
        while not os.path.exists(proceed):
            if time.monotonic() >= deadline:
                raise OSError("control read test gate timed out")
            time.sleep(0.01)
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    opened = os.fstat(descriptor)
    if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
        raise OSError("control file changed while opening")
    data = bytearray()
    while len(data) <= maximum:
        chunk = os.read(descriptor, maximum + 1 - len(data))
        if not chunk:
            break
        data.extend(chunk)
    finished = os.fstat(descriptor)
    current = os.stat(name, dir_fd=parent, follow_symlinks=False)
    if len(data) > maximum or not stat.S_ISREG(finished.st_mode) or (
        finished.st_dev, finished.st_ino, finished.st_size, finished.st_mtime_ns, finished.st_ctime_ns
    ) != (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns) or (
        current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns, current.st_ctime_ns
    ) != (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns):
        raise OSError("control file changed while reading")
    sys.stdout.buffer.write(data)
finally:
    if descriptor is not None:
        os.close(descriptor)
    os.close(parent)
PY
}

fm_afk_safe_control_copy() {  # <source> <destination> <maximum-bytes>
  python3 - "$1" "$2" "$3" <<'PY'
import os
import stat
import sys
import time

source = os.path.abspath(sys.argv[1])
destination = os.path.abspath(sys.argv[2])
maximum = int(sys.argv[3])
source_parent_path, source_name = os.path.split(source)
destination_parent_path, destination_name = os.path.split(destination)
source_parent = os.open(source_parent_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
destination_parent = os.open(destination_parent_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
source_fd = destination_fd = None
try:
    before = os.stat(source_name, dir_fd=source_parent, follow_symlinks=False)
    if not stat.S_ISREG(before.st_mode) or before.st_size > maximum:
        raise OSError("unsafe source control file")
    ready = os.environ.get("FM_AFK_COPY_TEST_READY")
    proceed = os.environ.get("FM_AFK_COPY_TEST_PROCEED")
    if ready and proceed:
        with open(ready, "x", encoding="utf-8") as marker:
            marker.write("ready\n")
        while not os.path.exists(proceed):
            time.sleep(0.01)
    source_fd = os.open(source_name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=source_parent)
    opened = os.fstat(source_fd)
    if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
        raise OSError("source control file changed while opening")
    destination_before = os.stat(destination_name, dir_fd=destination_parent, follow_symlinks=False)
    if not stat.S_ISREG(destination_before.st_mode):
        raise OSError("unsafe destination control file")
    destination_fd = os.open(destination_name, os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=destination_parent)
    destination_opened = os.fstat(destination_fd)
    if (destination_opened.st_dev, destination_opened.st_ino) != (destination_before.st_dev, destination_before.st_ino):
        raise OSError("destination control file changed while opening")
    os.ftruncate(destination_fd, 0)
    copied = 0
    while copied < opened.st_size:
        chunk = os.pread(source_fd, min(65536, opened.st_size - copied), copied)
        if not chunk:
            raise OSError("source control file ended early")
        written = 0
        while written < len(chunk):
            count = os.write(destination_fd, chunk[written:])
            if count <= 0:
                raise OSError("destination control file write failed")
            written += count
        copied += written
    finished = os.fstat(source_fd)
    current = os.stat(source_name, dir_fd=source_parent, follow_symlinks=False)
    if (finished.st_dev, finished.st_ino, finished.st_size, finished.st_mtime_ns, finished.st_ctime_ns) != (
        opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns
    ) or (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns, current.st_ctime_ns) != (
        opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns
    ):
        raise OSError("source control file changed while copying")
    os.fsync(destination_fd)
    os.utime(destination_name, ns=(opened.st_atime_ns, opened.st_mtime_ns), dir_fd=destination_parent, follow_symlinks=False)
finally:
    for descriptor in (source_fd, destination_fd, source_parent, destination_parent):
        if descriptor is not None:
            os.close(descriptor)
PY
}
FM_AFK_NATIVE_RECORD_PID=
FM_AFK_NATIVE_RECORD_IDENTITY=

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$FM_AFK_START_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_AFK_START_DIR/fm-wake-lib.sh"

fm_afk_start_usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# fm_afk_clear_stale_artifacts: on a FRESH away-session entry (the daemon is not
# already running), drop the previous away session's leftover escalation-delivery
# artifacts so they cannot surface as stale escalations under the new session.
# These are session-scoped by timing: a fresh entry owns a new supervision
# session and the new daemon has not produced anything yet, so anything present
# here belongs to a PRIOR session. This never drops a genuinely-pending
# escalation - the delivery buffer is a transient cache, and any condition still
# true (a crewmate still blocked, a check still firing) is re-derived and re-escalated
# fresh by the daemon's heartbeat catch-all scan and the durable
# state/.wake-queue replay (see docs/herdr-backend.md "Away-mode stale-artifact
# lifecycle" and bin/fm-supervise-daemon.sh's escalate_add/inject_wedge_alarm).
# NOT called on a refresh (daemon already alive), so the current session's own
# buffered escalations are preserved.
fm_afk_clear_stale_artifacts() {  # <state-dir>
  local state=$1
  rm -f "$state/.subsuper-escalations" \
        "$state/.subsuper-escalations.since" \
        "$state/.subsuper-inject-wedged" 2>/dev/null
}

daemon_lock_owner() {
  local owner
  if [ -L "$FM_AFK_LOCK" ]; then
    owner=$(readlink "$FM_AFK_LOCK" 2>/dev/null) || return 1
    [ -n "$owner" ] || return 1
    case "$owner" in
      /*) printf '%s\n' "$owner" ;;
      *) printf '%s/%s\n' "$(dirname "$FM_AFK_LOCK")" "$owner" ;;
    esac
    return 0
  fi
  [ -d "$FM_AFK_LOCK" ] || return 1
  printf '%s\n' "$FM_AFK_LOCK"
}

daemon_pid_matches() {
  local pid=$1 owner=$2 identity current command
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  if [ -n "$identity" ]; then
    current=$(fm_pid_identity "$pid") || return 1
    [ "$current" = "$identity" ]
    return
  fi
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  fm_afk_command_runs_script "$command" "$FM_AFK_DAEMON"
}

daemon_lock_pid() {
  local owner
  owner=$(daemon_lock_owner) || return 1
  cat "$owner/pid" 2>/dev/null || true
}

daemon_lock_held_by_live_daemon() {
  local owner pid
  owner=$(daemon_lock_owner) || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  daemon_pid_matches "$pid" "$owner"
}

fm_afk_native_process_write() {
  local pending identity
  if fm_afk_native_process_live && [ "$FM_AFK_NATIVE_PID" != "$$" ]; then
    return 1
  fi
  [ "$FM_AFK_NATIVE_PROCESS_UNSAFE" != 1 ] || return 1
  if [ -e "$FM_AFK_NATIVE_PROCESS" ] || [ -L "$FM_AFK_NATIVE_PROCESS" ]; then
    [ ! -d "$FM_AFK_NATIVE_PROCESS" ] || return 1
    rm -f "$FM_AFK_NATIVE_PROCESS" || return 1
  fi
  identity=$(fm_afk_native_process_identity "$$") || return 1
  pending=$(mktemp "$FM_AFK_STATE/.afk-native-process.pending.XXXXXX") || return 1
  if ! printf '%s\n%s\n' "$$" "$identity" > "$pending"; then
    rm -f "$pending"
    return 1
  fi
  if [ -L "$FM_AFK_NATIVE_PROCESS" ] || { [ -e "$FM_AFK_NATIVE_PROCESS" ] && [ ! -f "$FM_AFK_NATIVE_PROCESS" ]; }; then
    rm -f "$pending"
    return 1
  fi
  mv "$pending" "$FM_AFK_NATIVE_PROCESS" || { rm -f "$pending"; return 1; }
}

fm_afk_start_state_prepare() {
  mkdir -p "$FM_AFK_STATE" || return 1
  [ -d "$FM_AFK_STATE" ] && [ ! -L "$FM_AFK_STATE" ]
}

fm_afk_start_flag_write() {
  local destination="$FM_AFK_STATE/.afk" pending
  pending=$(mktemp "$FM_AFK_STATE/.afk.pending.XXXXXX") || return 1
  date '+%s' > "$pending" || { rm -f "$pending"; return 1; }
  if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
    rm -f "$pending"
    return 1
  fi
  mv "$pending" "$destination" || { rm -f "$pending"; return 1; }
}

fm_afk_start_select_delivery() {
  local record
  if [ "${FM_AFK_STATE_PREPARED:-0}" = 1 ]; then
    record=$(fm_afk_safe_control_read "$FM_AFK_LAUNCH_RECORD" "$FM_AFK_NATIVE_PROCESS_MAX_BYTES" 2>/dev/null) || return 1
    case "$record" in
      $'none\t-\tnative') FM_AFK_DELIVERY=reap-wake ;;
      $'tmux\t'*|$'herdr\t'*) FM_AFK_DELIVERY=inject ;;
      *) return 1 ;;
    esac
  else
    : "${FM_AFK_DELIVERY:=inject}"
  fi
  export FM_AFK_DELIVERY
}

fm_afk_native_process_identity() {
  local pid=$1 out
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  out=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

fm_afk_command_runs_script() {  # <command> <script>
  local command=$1 script=$2 first second script_base
  command=${command#"${command%%[![:space:]]*}"}
  IFS=$' \t' read -r first second _ <<< "$command"
  script_base=${script##*/}
  case "$first" in
    "$script"|"$script_base") return 0 ;;
  esac
  case "${first##*/}" in
    bash|dash|ksh|sh|zsh) ;;
    *) return 1 ;;
  esac
  case "$second" in
    "$script"|"$script_base") return 0 ;;
  esac
  return 1
}

fm_afk_native_process_command_matches() {
  local pid=$1 command
  command=$(LC_ALL=C ps -p "$pid" -o command= 2>/dev/null) || return 1
  fm_afk_command_runs_script "$command" "$FM_AFK_START_DIR/fm-afk-start.sh" \
    || fm_afk_command_runs_script "$command" "$FM_AFK_DAEMON"
}

fm_afk_native_process_read() {
  local snapshot bytes
  FM_AFK_NATIVE_RECORD_PID=
  FM_AFK_NATIVE_RECORD_IDENTITY=
  snapshot=$({
    fm_afk_safe_control_read "$FM_AFK_NATIVE_PROCESS" "$FM_AFK_NATIVE_PROCESS_MAX_BYTES" 2>/dev/null || exit 1
    printf '\034'
  }) || return 1
  case "$snapshot" in *$'\034') ;; *) return 1 ;; esac
  snapshot=${snapshot%$'\034'}
  bytes=$(printf '%s' "$snapshot" | LC_ALL=C wc -c | tr -d '[:space:]') || return 1
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le "$FM_AFK_NATIVE_PROCESS_MAX_BYTES" ] || return 1
  case "$snapshot" in *$'\n') snapshot=${snapshot%$'\n'} ;; esac
  case "$snapshot" in
    *$'\n'*) ;;
    *) return 1 ;;
  esac
  FM_AFK_NATIVE_RECORD_PID=${snapshot%%$'\n'*}
  FM_AFK_NATIVE_RECORD_IDENTITY=${snapshot#*$'\n'}
  case "$FM_AFK_NATIVE_RECORD_IDENTITY" in *$'\n'*) return 1 ;; esac
  [ -n "$FM_AFK_NATIVE_RECORD_PID" ] && [ -n "$FM_AFK_NATIVE_RECORD_IDENTITY" ]
}

fm_afk_native_process_live() {
  local pid identity current
  FM_AFK_NATIVE_PROCESS_UNSAFE=0
  fm_afk_native_process_read || return 1
  pid=$FM_AFK_NATIVE_RECORD_PID
  identity=$FM_AFK_NATIVE_RECORD_IDENTITY
  current=$(fm_afk_native_process_identity "$pid") || return 1
  [ "$current" = "$identity" ] || return 1
  if ! fm_afk_native_process_command_matches "$pid"; then
    FM_AFK_NATIVE_PROCESS_UNSAFE=1
    return 1
  fi
  FM_AFK_NATIVE_PID=$pid
}

fm_afk_start_main() {
  local prepared=0
  case "${1:-}" in
    '' ) ;;
    -h|--help) fm_afk_start_usage; return 0 ;;
    * ) echo "usage: $(basename "${BASH_SOURCE[1]:-fm-afk-start.sh}")" >&2; return 2 ;;
  esac

  fm_afk_start_state_prepare || return 1
  fm_lock_acquire_wait "$FM_AFK_NATIVE_HANDOFF_LOCK"
  if [ "${FM_AFK_STATE_PREPARED:-0}" = 1 ]; then
    prepared=1
    if [ ! -f "$FM_AFK_STATE/.afk" ]; then
      fm_lock_release "$FM_AFK_NATIVE_HANDOFF_LOCK"
      echo "afk: launcher-prepared state is missing" >&2
      return 1
    fi
  elif ! fm_afk_start_flag_write; then
    fm_lock_release "$FM_AFK_NATIVE_HANDOFF_LOCK"
    return 1
  fi

  local pid
  pid=$(daemon_lock_pid 2>/dev/null || true)
  if daemon_lock_held_by_live_daemon; then
    fm_lock_release "$FM_AFK_NATIVE_HANDOFF_LOCK"
    echo "afk: daemon already running pid=$pid"
    return 0
  fi

  if fm_pid_alive "$pid" && [ -n "$pid" ]; then
    fm_lock_remove_path "$FM_AFK_LOCK" 2>/dev/null || true
  fi

  # Fresh start: clear the previous away session's stale delivery artifacts
  # before the new daemon can surface them (fix for the leaked-artifact defect).
  if [ "$prepared" -eq 0 ] && ! fm_afk_clear_stale_artifacts "$FM_AFK_STATE"; then
    fm_lock_release "$FM_AFK_NATIVE_HANDOFF_LOCK"
    return 1
  fi

  if ! fm_afk_start_select_delivery; then
    fm_lock_release "$FM_AFK_NATIVE_HANDOFF_LOCK"
    echo "afk: prepared launch record is missing, unsafe, or malformed" >&2
    return 1
  fi

  if ! fm_afk_native_process_write; then
    fm_lock_release "$FM_AFK_NATIVE_HANDOFF_LOCK"
    echo "afk: could not register native process" >&2
    return 1
  fi
  fm_lock_release "$FM_AFK_NATIVE_HANDOFF_LOCK"

  echo "afk: starting supervise daemon in foreground; keep this command as a tracked background session"
  exec "$FM_AFK_DAEMON"
}

# Run only when executed, not when sourced (tests source fm_afk_clear_stale_artifacts
# and the lock helpers directly).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_start_main "$@"
fi
