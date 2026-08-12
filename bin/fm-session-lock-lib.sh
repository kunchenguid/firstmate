#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# Classify process execution state.
# Return 0 for active, 1 for absent or terminal, 2 for unknown, and 3 for stopped.
#
# Linux procps and macOS BSD ps both expose the process state through `stat`.
# Their first state character is structural: D/I/R/S/U/W are active or waiting,
# T/t are stopped, and X/Z are terminal; any other or unreadable value is
# unknown and must not authorize lock takeover.
fm_pid_execution_state() {
  local pid=$1 process_state probe_error
  if ! probe_error=$(LC_ALL=C kill -0 "$pid" 2>&1); then
    case "$probe_error" in
      *"No such process"*) return 1 ;;
      *) return 2 ;;
    esac
  fi
  process_state=$(LC_ALL=C ps -o stat= -p "$pid" 2>/dev/null) || return 2
  process_state=${process_state#"${process_state%%[![:space:]]*}"}
  case "$process_state" in
    [DIRSUW]*) return 0 ;;
    [XZ]*) return 1 ;;
    [Tt]*) return 3 ;;
    *) return 2 ;;
  esac
}

# Apply the same state vocabulary to a process that must also match a verified
# harness identity; a non-harness process returns 1.
fm_harness_pid_alive() {
  local pid=$1 comm args process_state
  if fm_pid_execution_state "$pid"; then
    process_state=0
  else
    process_state=$?
  fi
  case "$process_state" in 0|3) ;; *) return "$process_state" ;; esac
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 2
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 2
  fm_harness_process_matches "$comm" "$args" || return 1
  return "$process_state"
}

FM_SESSION_LOCK_OWNER_IDENTITY=
FM_SESSION_LOCK_GROUP_LEADER_PID=
FM_SESSION_LOCK_GROUP_LEADER_IDENTITY=
fm_session_lock_recorded_lease() {
  local state=$1 pid=$2 identity_file recorded_pid identity group_leader group_leader_identity extra
  FM_SESSION_LOCK_OWNER_IDENTITY=
  FM_SESSION_LOCK_GROUP_LEADER_PID=
  FM_SESSION_LOCK_GROUP_LEADER_IDENTITY=
  identity_file="$state/.lock.pid-identity"
  [ -f "$identity_file" ] && [ ! -L "$identity_file" ] || return 1
  {
    IFS= read -r recorded_pid \
      && IFS= read -r identity \
      && IFS= read -r group_leader \
      && IFS= read -r group_leader_identity \
      && ! IFS= read -r extra
  } < "$identity_file" 2>/dev/null || return 1
  [ "$recorded_pid" = "$pid" ] && [ -n "$identity" ] || return 1
  case "$group_leader" in
    ''|*[!0-9]*|0|1) return 1 ;;
  esac
  [ -n "$group_leader_identity" ] || return 1
  FM_SESSION_LOCK_OWNER_IDENTITY=$identity
  FM_SESSION_LOCK_GROUP_LEADER_PID=$group_leader
  FM_SESSION_LOCK_GROUP_LEADER_IDENTITY=$group_leader_identity
}

fm_session_lock_recorded_identity() {
  fm_session_lock_recorded_lease "$1" "$2" || return 1
  printf '%s\n' "$FM_SESSION_LOCK_OWNER_IDENTITY"
}

fm_session_lock_legacy_recorded_identity() {
  local state=$1 pid=$2 identity_file recorded_pid identity extra
  identity_file="$state/.lock.pid-identity"
  [ -f "$identity_file" ] && [ ! -L "$identity_file" ] || return 1
  {
    IFS= read -r recorded_pid \
      && IFS= read -r identity \
      && ! IFS= read -r extra
  } < "$identity_file" 2>/dev/null || return 1
  [ "$recorded_pid" = "$pid" ] && [ -n "$identity" ] || return 1
  printf '%s\n' "$identity"
}

fm_process_group_execution_state() {
  local pgid=$1 rows member_pgid member_state extra stopped=0
  case "$pgid" in
    ''|*[!0-9]*|0|1) return 2 ;;
  esac
  rows=$(LC_ALL=C ps -axo pgid=,stat= 2>/dev/null) || return 2
  while read -r member_pgid member_state extra; do
    [ "$member_pgid" = "$pgid" ] || continue
    [ -z "$extra" ] || return 2
    case "$member_state" in
      [XZ]*) ;;
      [DIRSUW]*) return 0 ;;
      [Tt]*) stopped=1 ;;
      *) return 2 ;;
    esac
  done <<< "$rows"
  [ "$stopped" -eq 0 ] || return 3
  return 1
}

fm_process_elapsed_seconds() {
  local pid=$1 elapsed days=0 clock field
  local -a fields
  elapsed=$(LC_ALL=C ps -o etime= -p "$pid" 2>/dev/null) || return 1
  elapsed=${elapsed//[[:space:]]/}
  case "$elapsed" in
    *-*)
      days=${elapsed%%-*}
      clock=${elapsed#*-}
      ;;
    *) clock=$elapsed ;;
  esac
  case "$days" in ''|*[!0-9]*) return 1 ;; esac
  IFS=: read -r -a fields <<< "$clock"
  case "${#fields[@]}" in
    2) fields=(0 "${fields[0]}" "${fields[1]}") ;;
    3) ;;
    *) return 1 ;;
  esac
  for field in "${fields[@]}"; do
    case "$field" in ''|*[!0-9]*) return 1 ;; esac
  done
  [ "$((10#${fields[1]}))" -lt 60 ] && [ "$((10#${fields[2]}))" -lt 60 ] || return 1
  [ "$days" -eq 0 ] || [ "$((10#${fields[0]}))" -lt 24 ] || return 1
  printf '%s\n' "$((10#$days * 86400 + 10#${fields[0]} * 3600 + 10#${fields[1]} * 60 + 10#${fields[2]}))"
}

fm_session_lock_legacy_owner_corroborated() {
  local state=$1 pid=$2 lock_pid completion_pid extra lock_mtime completion_mtime now elapsed
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  [ -f "$state/.session-start-complete" ] && [ ! -L "$state/.session-start-complete" ] || return 1
  {
    IFS= read -r lock_pid \
      && ! IFS= read -r extra
  } < "$state/.lock" 2>/dev/null || return 1
  {
    IFS= read -r completion_pid \
      && ! IFS= read -r extra
  } < "$state/.session-start-complete" 2>/dev/null || return 1
  [ "$lock_pid" = "$pid" ] && [ "$completion_pid" = "$pid" ] || return 1
  lock_mtime=$(fm_path_mtime "$state/.lock") || return 1
  completion_mtime=$(fm_path_mtime "$state/.session-start-complete") || return 1
  now=$(date +%s) || return 1
  elapsed=$(fm_process_elapsed_seconds "$pid") || return 1
  case "$lock_mtime:$completion_mtime:$now:$elapsed" in
    *[!0-9:]*) return 1 ;;
  esac
  [ "$lock_mtime" -le "$completion_mtime" ] \
    && [ "$completion_mtime" -le "$now" ] \
    && [ "$((now - elapsed))" -lt "$completion_mtime" ]
}

fm_session_lock_capture_active_lease() {
  local pid=$1 expected_identity=$2 owner_state group_leader leader_state group_state
  local current_identity current_group_leader current_leader_identity
  if fm_harness_pid_alive "$pid"; then
    owner_state=0
  else
    owner_state=$?
  fi
  [ "$owner_state" -eq 0 ] || return 1
  current_identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$current_identity" = "$expected_identity" ] || return 1
  group_leader=$(LC_ALL=C ps -o pgid= -p "$pid" 2>/dev/null) || return 1
  group_leader=${group_leader//[[:space:]]/}
  case "$group_leader" in ''|*[!0-9]*|0|1) return 1 ;; esac
  if fm_pid_execution_state "$group_leader"; then
    leader_state=0
  else
    leader_state=$?
  fi
  [ "$leader_state" -eq 0 ] || return 1
  current_leader_identity=$(fm_pid_identity "$group_leader" 2>/dev/null) || return 1
  if fm_process_group_execution_state "$group_leader"; then
    group_state=0
  else
    group_state=$?
  fi
  [ "$group_state" -eq 0 ] || return 1
  current_identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$current_identity" = "$expected_identity" ] || return 1
  current_group_leader=$(LC_ALL=C ps -o pgid= -p "$pid" 2>/dev/null) || return 1
  current_group_leader=${current_group_leader//[[:space:]]/}
  [ "$current_group_leader" = "$group_leader" ] || return 1
  [ "$(fm_pid_identity "$group_leader" 2>/dev/null || true)" = "$current_leader_identity" ] || return 1
  FM_SESSION_LOCK_OWNER_IDENTITY=$expected_identity
  FM_SESSION_LOCK_GROUP_LEADER_PID=$group_leader
  FM_SESSION_LOCK_GROUP_LEADER_IDENTITY=$current_leader_identity
}

fm_session_lock_capture_stopped_lease() {
  local pid=$1 expected_identity=${2:-} owner_state group_leader leader_state group_state caller_pgid
  local current_identity current_group_leader current_leader_identity
  if fm_harness_pid_alive "$pid"; then
    return 1
  else
    owner_state=$?
  fi
  [ "$owner_state" -eq 3 ] || return 1
  current_identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -z "$expected_identity" ] || [ "$current_identity" = "$expected_identity" ] || return 1
  group_leader=$(LC_ALL=C ps -o pgid= -p "$pid" 2>/dev/null) || return 1
  group_leader=${group_leader//[[:space:]]/}
  case "$group_leader" in ''|*[!0-9]*|0|1) return 1 ;; esac
  if fm_pid_execution_state "$group_leader"; then
    return 1
  else
    leader_state=$?
  fi
  [ "$leader_state" -eq 3 ] || return 1
  current_leader_identity=$(fm_pid_identity "$group_leader" 2>/dev/null) || return 1
  if fm_process_group_execution_state "$group_leader"; then
    return 1
  else
    group_state=$?
  fi
  [ "$group_state" -eq 3 ] || return 1
  caller_pgid=$(LC_ALL=C ps -o pgid= -p "${BASHPID:-$$}" 2>/dev/null) || return 1
  caller_pgid=${caller_pgid//[[:space:]]/}
  [ "$caller_pgid" != "$group_leader" ] || return 1
  current_identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -z "$expected_identity" ] || [ "$current_identity" = "$expected_identity" ] || return 1
  current_group_leader=$(LC_ALL=C ps -o pgid= -p "$pid" 2>/dev/null) || return 1
  current_group_leader=${current_group_leader//[[:space:]]/}
  [ "$current_group_leader" = "$group_leader" ] || return 1
  if fm_harness_pid_alive "$pid"; then
    return 1
  else
    owner_state=$?
  fi
  [ "$owner_state" -eq 3 ] || return 1
  [ "$(fm_pid_identity "$group_leader" 2>/dev/null || true)" = "$current_leader_identity" ] || return 1
  if fm_process_group_execution_state "$group_leader"; then
    return 1
  else
    group_state=$?
  fi
  [ "$group_state" -eq 3 ] || return 1
  FM_SESSION_LOCK_OWNER_IDENTITY=$current_identity
  FM_SESSION_LOCK_GROUP_LEADER_PID=$group_leader
  FM_SESSION_LOCK_GROUP_LEADER_IDENTITY=$current_leader_identity
}

fm_harness_pid_fence_stopped() {
  local pid=$1 expected_identity=${2:-} group_leader=${3:-} expected_leader_identity=${4:-}
  local owner_state attempt=0 caller_pgid current_identity current_owner_identity owner_group_leader
  local group_state probe_error leader_state owner_generation_present=0
  if [ -z "$group_leader" ] || [ -z "$expected_leader_identity" ]; then
    if fm_harness_pid_alive "$pid"; then
      return 1
    else
      owner_state=$?
    fi
    [ "$owner_state" -eq 1 ] || return 1
    if fm_process_group_execution_state "$pid"; then
      return 1
    else
      group_state=$?
    fi
    [ "$group_state" -eq 1 ]
    return $?
  fi
  [ -n "$expected_identity" ] || return 1
  case "$group_leader" in ''|*[!0-9]*|0|1) return 1 ;; esac
  current_owner_identity=$(fm_pid_identity "$pid" 2>/dev/null || true)
  if [ "$current_owner_identity" = "$expected_identity" ]; then
    owner_group_leader=$(LC_ALL=C ps -o pgid= -p "$pid" 2>/dev/null) || return 1
    owner_group_leader=${owner_group_leader//[[:space:]]/}
    [ "$owner_group_leader" = "$group_leader" ] || return 1
    owner_generation_present=1
  fi
  current_identity=$(fm_pid_identity "$group_leader" 2>/dev/null || true)
  if [ -n "$current_identity" ]; then
    if [ "$current_identity" != "$expected_leader_identity" ]; then
      [ "$owner_generation_present" -eq 0 ] || return 1
      return 0
    fi
    if fm_pid_execution_state "$group_leader"; then
      return 1
    else
      leader_state=$?
    fi
    [ "$leader_state" -eq 3 ] || return 1
  else
    if probe_error=$(LC_ALL=C kill -0 "$group_leader" 2>&1); then
      return 1
    fi
    case "$probe_error" in *"No such process"*) ;; *) return 1 ;; esac
  fi
  if fm_process_group_execution_state "$group_leader"; then
    return 1
  else
    group_state=$?
  fi
  case "$group_state" in
    1) return 0 ;;
    3) ;;
    *) return 1 ;;
  esac
  caller_pgid=$(LC_ALL=C ps -o pgid= -p "${BASHPID:-$$}" 2>/dev/null) || return 1
  caller_pgid=${caller_pgid//[[:space:]]/}
  [ "$caller_pgid" != "$group_leader" ] || return 1
  current_identity=$(fm_pid_identity "$group_leader" 2>/dev/null || true)
  if [ -n "$current_identity" ]; then
    if [ "$current_identity" != "$expected_leader_identity" ]; then
      [ "$owner_generation_present" -eq 0 ] || return 1
      return 0
    fi
    if fm_pid_execution_state "$group_leader"; then
      return 1
    else
      leader_state=$?
    fi
    [ "$leader_state" -eq 3 ] || return 1
  else
    if probe_error=$(LC_ALL=C kill -0 "$group_leader" 2>&1); then
      return 1
    fi
    case "$probe_error" in *"No such process"*) ;; *) return 1 ;; esac
  fi
  if fm_process_group_execution_state "$group_leader"; then
    return 1
  else
    group_state=$?
  fi
  [ "$group_state" -eq 3 ] || return 1
  kill -KILL -"$group_leader" 2>/dev/null || return 1
  while [ "$attempt" -lt 100 ]; do
    if fm_process_group_execution_state "$group_leader"; then
      group_state=0
    else
      group_state=$?
    fi
    case "$group_state" in
      1) return 0 ;;
      0|3) ;;
      *) return 1 ;;
    esac
    sleep 0.02
    attempt=$((attempt + 1))
  done
  return 1
}

# True when state dir $1 holds a session lock whose numeric pid is ANY harness
# ancestor of the current process. Membership is the honest test of that
# question, because the lock owner sits at an unknown depth in a contiguous
# Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_pid_owned_by_self() {
  local state=$1 expected_pid=${2:-} lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -z "$expected_pid" ] || [ "$lock_pid" = "$expected_pid" ] || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}

fm_session_lock_owned_by_self() {
  local state=$1 lock_pid recorded_identity group_leader group_leader_identity
  local current_identity current_group_leader confirmed_identity confirmed_group_leader confirmed_group_leader_identity
  lock_pid=$(cat "$state/.lock" 2>/dev/null) || return 1
  fm_session_lock_pid_owned_by_self "$state" "$lock_pid" || return 1
  fm_session_lock_recorded_lease "$state" "$lock_pid" || return 1
  recorded_identity=$FM_SESSION_LOCK_OWNER_IDENTITY
  group_leader=$FM_SESSION_LOCK_GROUP_LEADER_PID
  group_leader_identity=$FM_SESSION_LOCK_GROUP_LEADER_IDENTITY
  current_identity=$(fm_pid_identity "$lock_pid" 2>/dev/null) || return 1
  [ "$current_identity" = "$recorded_identity" ] || return 1
  current_group_leader=$(LC_ALL=C ps -o pgid= -p "$lock_pid" 2>/dev/null) || return 1
  current_group_leader=${current_group_leader//[[:space:]]/}
  [ "$current_group_leader" = "$group_leader" ] || return 1
  [ "$(fm_pid_identity "$group_leader" 2>/dev/null || true)" = "$group_leader_identity" ] || return 1
  fm_pid_execution_state "$group_leader" || return 1
  [ "$(cat "$state/.lock" 2>/dev/null || true)" = "$lock_pid" ] || return 1
  fm_session_lock_recorded_lease "$state" "$lock_pid" || return 1
  confirmed_identity=$FM_SESSION_LOCK_OWNER_IDENTITY
  confirmed_group_leader=$FM_SESSION_LOCK_GROUP_LEADER_PID
  confirmed_group_leader_identity=$FM_SESSION_LOCK_GROUP_LEADER_IDENTITY
  [ "$confirmed_identity" = "$recorded_identity" ] \
    && [ "$confirmed_group_leader" = "$group_leader" ] \
    && [ "$confirmed_group_leader_identity" = "$group_leader_identity" ]
}
