#!/usr/bin/env bash

canonical_existing_dir() {
  local target=$1
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  ( cd "$target" && pwd -P )
}

# Pids of every process whose CURRENT WORKING
# DIRECTORY is exactly $1 or under it, from one bounded system-wide `lsof -a
# -d cwd` scan (never the recursive +D file-tree walk, which lsof itself
# documents as slow). Never $$ (this script's own pid). Empty output when
# nothing matches; failure means the scan could not establish a safe result.
pids_with_cwd_under() {  # <dir>
  local dir=$1 out pid path line
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  dir=$(cd "$dir" && pwd -P) || return 1
  out=$(lsof -a -d cwd -Fpn 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  pid=
  while IFS= read -r line; do
    case "$line" in
      p*)
        pid=${line#p}
        case "$pid" in ''|*[!0-9]*) return 1 ;; esac
        ;;
      fcwd) [ -n "$pid" ] || return 1 ;;
      n*)
        [ -n "$pid" ] || return 1
        path=${line#n}
        case "$path" in
          "$dir"|"$dir"/*)
            [ -n "$pid" ] && [ "$pid" != "$$" ] && printf '%s\n' "$pid"
            ;;
        esac
        ;;
      '') ;;
      *) return 1 ;;
    esac
  done <<EOF
$out
EOF
}

task_process_identity() {  # <pid>
  local pid=$1 proc_root stat_line starttime value
  local -a stat_fields
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    printf 'starttime=%s\n' "$starttime"
    return 0
  fi
  value=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf 'lstart=%s\n' "$value"
}

task_process_identity_matches() {  # <pid> <identity>
  local current
  current=$(task_process_identity "$1") || return 1
  [ "$current" = "$2" ]
}

task_pid_list_contains() {  # <pid-list> <pid>
  printf '%s\n' "$1" | grep -Fxq "$2"
}

task_pids_under_roots() {  # <dir>...
  TASK_PIDS=
  TASK_PIDS_FAILED_DIR=
  TASK_PIDS_FAIL_REASON="lsof"
  local dir dir_pids pids=""
  for dir in "$@"; do
    [ -n "$dir" ] || continue
    if ! dir_pids=$(pids_with_cwd_under "$dir"); then
      TASK_PIDS_FAILED_DIR=$dir
      return 1
    fi
    pids="$pids
$dir_pids"
  done
  TASK_PIDS=$(printf '%s\n' "$pids" | grep -E '^[0-9]+$' | sort -un || true)
}

reap_task_backend_process_group() {  # <label>
  local label=$1 leader leader_start pgid current_pgid own_pgid
  if [ "$BACKEND" != tmux ]; then
    echo "warning: lsof is unavailable; cannot resolve a process-group fallback for $BACKEND task $ID" >&2
    return 0
  fi
  leader=$(tmux display-message -p -t "$T" '#{pane_pid}' 2>/dev/null) || leader=""
  case "$leader" in ''|*[!0-9]*)
    echo "warning: lsof is unavailable; cannot resolve the tmux pane process group for $ID" >&2
    return 0
    ;;
  esac
  leader_start=$(task_process_identity "$leader") || {
    echo "warning: lsof is unavailable; cannot identify the tmux pane process group for $ID" >&2
    return 0
  }
  pgid=$(ps -o pgid= -p "$leader" 2>/dev/null) || pgid=""
  pgid=$(printf '%s' "$pgid" | tr -d '[:space:]')
  case "$pgid" in ''|*[!0-9]*|0|1)
    echo "warning: lsof is unavailable; cannot resolve the tmux pane process group for $ID" >&2
    return 0
    ;;
  esac
  own_pgid=$(ps -o pgid= -p "$$" 2>/dev/null) || own_pgid=""
  own_pgid=$(printf '%s' "$own_pgid" | tr -d '[:space:]')
  if [ "$pgid" = "$own_pgid" ]; then
    echo "warning: lsof is unavailable; refusing to signal teardown's own process group for $ID" >&2
    return 0
  fi
  task_process_identity_matches "$leader" "$leader_start" || return 0
  current_pgid=$(ps -o pgid= -p "$leader" 2>/dev/null) || current_pgid=""
  current_pgid=$(printf '%s' "$current_pgid" | tr -d '[:space:]')
  [ "$current_pgid" = "$pgid" ] || return 0
  echo "teardown: reaping leaked $label process group for $ID: $pgid" >&2
  kill -TERM -- "-$pgid" 2>/dev/null || true
  sleep 1
  if task_process_identity_matches "$leader" "$leader_start" \
     && [ "$(ps -o pgid= -p "$leader" 2>/dev/null | tr -d '[:space:]')" = "$pgid" ] \
     && kill -0 -- "-$pgid" 2>/dev/null; then
    echo "teardown: force-killing leaked $label process group for $ID: $pgid" >&2
    kill -KILL -- "-$pgid" 2>/dev/null || true
  fi
}

# Directory of chrome-devtools-axi bridge.pid files, ~/.chrome-devtools-axi
# unless FM_BROWSER_HELPER_STATE_OVERRIDE replaces it. The default session file
# is bridge.pid; named sessions are sessions/<name>/bridge.pid. An empty
# FM_BROWSER_HELPER_STATE_OVERRIDE disables the recorded-pid lookup.
browser_helper_state_root() {
  if [ -n "${FM_BROWSER_HELPER_STATE_OVERRIDE+x}" ]; then
    printf '%s\n' "$FM_BROWSER_HELPER_STATE_OVERRIDE"
    return 0
  fi
  if [ -z "${HOME:-}" ]; then
    return 0
  fi
  printf '%s\n' "$HOME/.chrome-devtools-axi"
}

browser_helper_pid_from_file() {  # <file>
  local file=$1 pid
  [ -f "$file" ] || return 1
  pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$file" | head -n 1) || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$pid"
}

# Print one environment value for a pid. Exit 0 with the value, 1 when the
# process is readable but the key is absent, 2 when the environment cannot be
# read. A readable FM_PROC_ROOT_OVERRIDE/<pid>/environ wins, which is how tests
# pin the value; otherwise Linux /proc and a Darwin KERN_PROCARGS2 read.
task_process_env_field() {  # <pid> <key>
  local pid=$1 key=$2 proc_root file rc
  case "$pid" in
    ''|*[!0-9]*) return 2 ;;
  esac
  case "$key" in
    PWD|OLDPWD) ;;
    *) return 2 ;;
  esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  file=$proc_root/$pid/environ
  if [ -r "$file" ]; then
    rc=0
    perl -e '
      my ($path, $wanted) = @ARGV;
      open my $fh, "<:raw", $path or exit 2;
      local $/;
      my $data = <$fh>;
      close $fh;
      my $prefix = $wanted . "=";
      my $found;
      foreach my $part (split /\0/, $data // "") {
        if (index($part, $prefix) == 0) {
          $found = substr($part, length($prefix));
        }
      }
      if (defined $found) {
        print $found;
        exit 0;
      }
      exit 1;
    ' "$file" "$key" || rc=$?
    return "$rc"
  fi
  if [ "$(uname -s)" != Darwin ]; then
    return 2
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    return 2
  fi
  rc=0
  python3 -c '
import ctypes
import ctypes.util
import sys
pid = int(sys.argv[1])
key = sys.argv[2].encode() + b"="
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
mib = (ctypes.c_int * 3)(1, 49, pid)
size = ctypes.c_size_t(1 << 20)
buf = ctypes.create_string_buffer(size.value)
libc.sysctl.argtypes = [
    ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t,
]
if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
    sys.exit(2)
found = None
for part in buf.raw[:size.value].split(b"\x00"):
    if part.startswith(key):
        found = part[len(key):]
if found is None:
    sys.exit(1)
sys.stdout.buffer.write(found)
' "$pid" "$key" || rc=$?
  return "$rc"
}

path_is_under_roots() {  # <path> <newline-separated canonical roots>
  local path=$1 roots=$2 canon root
  canon=$(canonical_existing_dir "$path") || return 1
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$canon" in
      "$root"|"$root"/*) return 0 ;;
    esac
  done <<EOF
$roots
EOF
  return 1
}

# A recorded bridge pid is owned only when it is still the bridge and its own
# PWD or OLDPWD is under this task. Already-cwd-owned pids are left to the
# cwd scan. A recycled pid whose command is no longer the bridge is ignored.
browser_helper_consider_pid_file() {  # <file> <cwd-pids> <roots>
  local file=$1 cwd_pids=$2 roots=$3 pid cmd path field rc unread=0 saw_env=0
  pid=$(browser_helper_pid_from_file "$file") || return 0
  case "$pid" in
    0|1|"$$") return 0 ;;
  esac
  if printf '%s\n' "$cwd_pids" | grep -Fxq "$pid"; then
    return 0
  fi
  cmd=$(ps -p "$pid" -o command= 2>/dev/null) || return 0
  case "$cmd" in
    *chrome-devtools-axi-bridge*) ;;
    *) return 0 ;;
  esac
  for field in PWD OLDPWD; do
    rc=0
    path=$(task_process_env_field "$pid" "$field") || rc=$?
    if [ "$rc" -eq 0 ]; then
      saw_env=1
      if path_is_under_roots "$path" "$roots"; then
        printf '%s\n' "$pid"
        return 0
      fi
    elif [ "$rc" -eq 2 ]; then
      unread=$((unread + 1))
    fi
  done
  if [ "$saw_env" -eq 0 ] && [ "$unread" -gt 0 ]; then
    echo "warning: recorded browser-helper pid $pid could not be checked against this task directory; leaving it untouched" >&2
  fi
  return 0
}

browser_helper_owned_pids() {  # <cwd-pids> <canonical roots>
  local cwd_pids=$1 roots=$2 root file
  root=$(browser_helper_state_root) || return 0
  [ -n "$root" ] && [ -d "$root" ] || return 0
  if [ -f "$root/bridge.pid" ]; then
    browser_helper_consider_pid_file "$root/bridge.pid" "$cwd_pids" "$roots"
  fi
  for file in "$root"/sessions/*/bridge.pid; do
    [ -f "$file" ] || continue
    browser_helper_consider_pid_file "$file" "$cwd_pids" "$roots"
  done
}

# Seeds plus every descendant by parent pid. Does not walk upward, and never
# emits pid 0, pid 1, or this process. A snapshot failure is a hard failure:
# guessing ownership from a name is not a fallback.
task_pids_with_descendants() {  # <newline-separated seeds>
  local seeds=$1 snapshot
  snapshot=$(ps -axo pid=,ppid= 2>/dev/null) || return 1
  [ -n "$snapshot" ] || return 1
  printf '%s\n---\n%s\n' "$seeds" "$snapshot" | awk -v self="$$" '
    $0 == "---" { phase = 1; next }
    phase == 0 {
      if ($0 ~ /^[0-9]+$/) owned[$0] = 1
      next
    }
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      child[$2] = child[$2] " " $1
    }
    END {
      nq = 0
      for (p in owned) {
        nq++
        q[nq] = p
      }
      qi = 1
      while (qi <= nq) {
        p = q[qi]
        qi++
        n = split(child[p], kids, " ")
        for (i = 1; i <= n; i++) {
          k = kids[i]
          if (k == "" || k == "0" || k == "1" || k == self) continue
          if (!(k in owned)) {
            owned[k] = 1
            nq++
            q[nq] = k
          }
        }
      }
      for (p in owned) {
        if (p ~ /^[0-9]+$/ && p != "0" && p != "1" && p != self) print p
      }
    }
  '
}

# Cwd-owned processes, recorded bridge pids proved by path, and their
# descendants. TASK_PIDS_FAIL_REASON names which lookup failed.
task_owned_pids() {  # <dir>...
  local cwd_pids roots_canon="" dir canon recorded seeds expanded
  TASK_PIDS=
  TASK_PIDS_FAILED_DIR=
  TASK_PIDS_FAIL_REASON="lsof"
  if [ "${TASK_PROCESS_SCOPE:-task}" != browser ] && ! task_pids_under_roots "$@"; then
    return 1
  fi
  cwd_pids=$TASK_PIDS
  for dir in "$@"; do
    [ -n "$dir" ] || continue
    if ! canon=$(canonical_existing_dir "$dir"); then
      continue
    fi
    roots_canon="${roots_canon}${canon}
"
  done
  if ! recorded=$(browser_helper_owned_pids "$cwd_pids" "$roots_canon"); then
    TASK_PIDS_FAIL_REASON="ps"
    return 1
  fi
  seeds=$(printf '%s\n%s\n' "$cwd_pids" "$recorded" | grep -E '^[0-9]+$' | sort -un || true)
  if [ -z "$seeds" ]; then
    TASK_PIDS=
    return 0
  fi
  if ! expanded=$(task_pids_with_descendants "$seeds"); then
    TASK_PIDS_FAIL_REASON="ps"
    if [ -z "$TASK_PIDS_FAILED_DIR" ]; then
      TASK_PIDS_FAILED_DIR=${1:-<missing>}
    fi
    return 1
  fi
  TASK_PIDS=$(printf '%s\n' "$expanded" | grep -E '^[0-9]+$' | sort -un || true)
}

# Shared cleanup for task teardown and worker exit. Task scope includes cwd
# under the worktree/tasktmp roots; TASK_PROCESS_SCOPE=browser skips that scan
# and seeds only recorded bridges whose command and PWD or OLDPWD prove task
# ownership. Both scopes include descendants, even after setsid or chdir.
# Callers must supply task-exclusive roots, never a secondmate's shared home.
# Each signal requires both fresh ownership membership and matching process
# identity. TERM precedes KILL after a grace period.
# Missing lsof uses the backend process-group fallback in task scope
# only; scan errors refuse cleanup. Unreadable bridge environments warn and
# leave those bridges untouched. This does not remove Chrome temp files.
reap_task_worktree_processes() {  # <label> <dir>...
  local label=$1 pids pid identity current_pids i pass=1 max_passes=3
  local -a tracked_pids tracked_identities remaining_pids remaining_identities
  shift
  if [ "${TASK_PROCESS_SCOPE:-task}" != browser ] && ! command -v lsof >/dev/null 2>&1; then
    reap_task_backend_process_group "$label"
    return 0
  fi
  while [ "$pass" -le "$max_passes" ]; do
    if ! task_owned_pids "$@"; then
      echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID (${TASK_PIDS_FAIL_REASON:-lsof} failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
      return 1
    fi
    pids=$TASK_PIDS
    [ -n "$pids" ] || return 0
    tracked_pids=()
    tracked_identities=()
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      if ! identity=$(task_process_identity "$pid"); then
        if ! task_owned_pids "$@"; then
          echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID (${TASK_PIDS_FAIL_REASON:-lsof} failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
          return 1
        fi
        if task_pid_list_contains "$TASK_PIDS" "$pid"; then
          echo "REFUSED: cannot verify leaked process $pid identity for $ID; preserving the worktree/tasktmp for manual inspection or retry." >&2
          return 1
        fi
        continue
      fi
      tracked_pids+=("$pid")
      tracked_identities+=("$identity")
    done <<EOF
$pids
EOF
    if [ "${#tracked_pids[@]}" -eq 0 ]; then
      pass=$((pass + 1))
      continue
    fi
    if ! task_owned_pids "$@"; then
      echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID (${TASK_PIDS_FAIL_REASON:-lsof} failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
      return 1
    fi
    current_pids=$TASK_PIDS
    echo "teardown: reaping leaked $label process(es) for $ID: $(printf '%s' "$pids" | tr '\n' ' ')" >&2
    for i in "${!tracked_pids[@]}"; do
      pid=${tracked_pids[$i]}
      identity=${tracked_identities[$i]}
      if task_pid_list_contains "$current_pids" "$pid" \
         && task_process_identity_matches "$pid" "$identity"; then
        kill -TERM "$pid" 2>/dev/null || true
      fi
    done
    sleep 1
    if ! task_owned_pids "$@"; then
      echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID (${TASK_PIDS_FAIL_REASON:-lsof} failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
      return 1
    fi
    current_pids=$TASK_PIDS
    remaining_pids=()
    remaining_identities=()
    for i in "${!tracked_pids[@]}"; do
      pid=${tracked_pids[$i]}
      identity=${tracked_identities[$i]}
      if task_pid_list_contains "$current_pids" "$pid" \
         && task_process_identity_matches "$pid" "$identity"; then
        remaining_pids+=("$pid")
        remaining_identities+=("$identity")
      fi
    done
    if [ "${#remaining_pids[@]}" -gt 0 ]; then
      echo "teardown: force-killing leaked $label process(es) for $ID: ${remaining_pids[*]}" >&2
      if ! task_owned_pids "$@"; then
        echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID (${TASK_PIDS_FAIL_REASON:-lsof} failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
        return 1
      fi
      current_pids=$TASK_PIDS
      for i in "${!remaining_pids[@]}"; do
        pid=${remaining_pids[$i]}
        identity=${remaining_identities[$i]}
        if task_pid_list_contains "$current_pids" "$pid" \
           && task_process_identity_matches "$pid" "$identity"; then
          kill -KILL "$pid" 2>/dev/null || true
        fi
      done
    fi
    pass=$((pass + 1))
  done
  if ! task_owned_pids "$@"; then
    echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID (${TASK_PIDS_FAIL_REASON:-lsof} failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
    return 1
  fi
  [ -z "$TASK_PIDS" ] && return 0
  echo "REFUSED: leaked $label processes for $ID remain after $max_passes reap attempts; preserving the worktree/tasktmp for manual inspection or retry." >&2
  return 1
}

