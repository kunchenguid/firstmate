#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which live, non-zombie verified-harness process holds this
# home's session lock, and does the current process prove that same session by
# ancestry or the authenticated Claude daemon bridge?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook belongs to the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

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
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
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
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
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

fm_session_resolve_dir() {  # <dir>
  CDPATH='' cd -- "$1" 2>/dev/null && pwd -P
}

fm_claude_process_argv_json() {  # <process-pid>
  local pid=$1 proc_path platform
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  command -v node >/dev/null 2>&1 || return 1
  if [ -n "${FM_PROC_ROOT:-}" ]; then
    proc_path="$FM_PROC_ROOT/$pid/cmdline"
  else
    platform=$(uname -s 2>/dev/null) || return 1
    case "$platform" in
      Linux) proc_path="/proc/$pid/cmdline" ;;
      Darwin)
        [ -x /usr/bin/ruby ] || return 1
        /usr/bin/ruby - "$pid" <<'RB'
require "fiddle/import"
require "json"

module LibC
  extend Fiddle::Importer
  dlload Fiddle.dlopen(nil)
  extern "int sysctl(int*, unsigned int, void*, size_t*, void*, size_t)"
end

pid = Integer(ARGV.fetch(0), 10)
raise unless pid.positive?
mib = [1, 49, pid].pack("i*")
size = [0].pack("J")
raise unless LibC.sysctl(mib, 3, nil, size, nil, 0).zero?
length = size.unpack1("J")
raise unless length > 4 && length <= 8 * 1024 * 1024
buffer = "\0" * length
raise unless LibC.sysctl(mib, 3, buffer, size, nil, 0).zero?
raw = buffer.byteslice(0, size.unpack1("J"))
argc = raw.unpack1("i")
raise unless argc.positive? && argc <= 65_536
offset = raw.index("\0", 4) + 1
offset += 1 while offset < raw.bytesize && raw.getbyte(offset).zero?
argv = []
argc.times do
  finish = raw.index("\0", offset)
  raise unless finish
  value = raw.byteslice(offset, finish - offset).force_encoding(Encoding::UTF_8)
  raise unless value.valid_encoding?
  argv << value
  offset = finish + 1
end
STDOUT.write(JSON.generate(argv))
RB
        return $?
        ;;
      *) return 1 ;;
    esac
  fi
  node -e '
const fs = require("fs");
try {
  const raw = fs.readFileSync(process.argv[1]);
  if (raw.length === 0 || raw[raw.length - 1] !== 0) throw new Error();
  const decoder = new TextDecoder("utf-8", { fatal: true });
  const argv = [];
  let start = 0;
  for (let index = 0; index < raw.length; index += 1) {
    if (raw[index] !== 0) continue;
    argv.push(decoder.decode(raw.subarray(start, index)));
    start = index + 1;
  }
  process.stdout.write(JSON.stringify(argv));
} catch (_) {
  process.exit(1);
}
' "$proc_path"
}

fm_claude_process_is_daemon() {  # <process-pid>
  local process_pid=$1 args=${2:-} argv_json
  if argv_json=$(fm_claude_process_argv_json "$process_pid"); then
    printf '%s' "$argv_json" | node -e '
const fs = require("fs");
try {
  const argv = JSON.parse(fs.readFileSync(0, "utf8"));
  if (!Array.isArray(argv) || argv.some(value => typeof value !== "string")) throw new Error();
  if (argv.length < 3 || argv[1] !== "daemon" || argv[2] !== "run") throw new Error();
} catch (_) {
  process.exit(1);
}
'
    return $?
  fi
  [ -n "$args" ] || args=$(ps -o args= -p "$process_pid" 2>/dev/null) || return 1
  case " $args " in
    *' daemon run '*) return 0 ;;
  esac
  return 1
}

fm_claude_daemon_in_session_ancestry() {
  local pids pid comm args
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || continue
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    fm_harness_process_matches "$comm" "$args" || continue
    [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || continue
    fm_claude_process_is_daemon "$pid" "$args" && return 0
  done <<EOF
$pids
EOF
  return 1
}

fm_claude_daemon_spawned_by_owner_for_process() {  # <process-pid> <root-real>
  local process_pid=$1 root_real=$2 argv_json fields spawned_pid spawned_cwd spawned_real
  argv_json=$(fm_claude_process_argv_json "$process_pid") || return 1
  fields=$(printf '%s' "$argv_json" | node -e '
const fs = require("fs");
try {
  const argv = JSON.parse(fs.readFileSync(0, "utf8"));
  if (!Array.isArray(argv) || argv.some(value => typeof value !== "string")) throw new Error();
  if (argv.length < 4 || argv[1] !== "daemon" || argv[2] !== "run") throw new Error();
  const positions = [];
  argv.forEach((value, index) => { if (value === "--spawned-by") positions.push(index); });
  if (positions.length !== 1 || positions[0] + 1 >= argv.length) throw new Error();
  const raw = argv[positions[0] + 1];
  let index = 0;
  const skip = () => { while (/[ \t\n\r]/.test(raw[index] || "")) index += 1; };
  const string = () => {
    skip();
    if (raw[index] !== "\"") throw new Error();
    const start = index++;
    while (index < raw.length) {
      const code = raw.charCodeAt(index);
      if (code < 0x20) throw new Error();
      if (raw[index] === "\"") {
        index += 1;
        return JSON.parse(raw.slice(start, index));
      }
      if (raw[index] === "\\") {
        index += 1;
        if (index >= raw.length || !/["\\/bfnrtu]/.test(raw[index])) throw new Error();
        if (raw[index] === "u") {
          if (!/^[0-9a-fA-F]{4}$/.test(raw.slice(index + 1, index + 5))) throw new Error();
          index += 4;
        }
      }
      index += 1;
    }
    throw new Error();
  };
  skip();
  if (raw[index++] !== "{") throw new Error();
  const values = Object.create(null);
  const keys = new Set();
  while (true) {
    skip();
    if (raw[index] === "}") { index += 1; break; }
    const key = string();
    if (keys.has(key) || !["label", "cwd", "pid"].includes(key)) throw new Error();
    keys.add(key);
    skip();
    if (raw[index++] !== ":") throw new Error();
    skip();
    if (key === "pid") {
      const match = raw.slice(index).match(/^(0|[1-9][0-9]*)/);
      if (!match) throw new Error();
      values.pid = Number(match[0]);
      index += match[0].length;
    } else {
      values[key] = string();
    }
    skip();
    if (raw[index] === ",") {
      index += 1;
      skip();
      if (raw[index] === "}") throw new Error();
      continue;
    }
    if (raw[index] === "}") { index += 1; break; }
    throw new Error();
  }
  skip();
  if (index !== raw.length || keys.size !== 3 || values.label !== "claude") throw new Error();
  if (!values.cwd || /[\0\n\r\t]/.test(values.cwd)) throw new Error();
  if (!Number.isSafeInteger(values.pid) || values.pid <= 0) throw new Error();
  process.stdout.write(String(values.pid) + "\n" + values.cwd);
} catch (_) {
  process.exit(1);
}
  ') || return 1
  spawned_pid=${fields%%$'\n'*}
  [ "$fields" != "$spawned_pid" ] || return 1
  spawned_cwd=${fields#*$'\n'}
  [ -n "$spawned_cwd" ] || return 1
  spawned_real=$(fm_session_resolve_dir "$spawned_cwd") || return 1
  [ "$spawned_real" = "$root_real" ] || return 1
  fm_harness_pid_alive "$spawned_pid" || return 1
  [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 1
  printf '%s\n' "$spawned_pid"
}

fm_claude_daemon_spawned_by_matches() {  # <process-pid> <lock-pid> <root-real>
  local process_pid=$1 lock_pid=$2 root_real=$3 spawned_pid
  spawned_pid=$(fm_claude_daemon_spawned_by_owner_for_process \
    "$process_pid" "$root_real") || return 1
  [ "$spawned_pid" = "$lock_pid" ]
}

fm_claude_daemon_spawned_by_session_owner() {  # <root>
  local root=$1 root_real pids pid comm args candidate owner=''
  root_real=$(fm_session_resolve_dir "$root") || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || continue
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    fm_harness_process_matches "$comm" "$args" || continue
    [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || continue
    candidate=$(fm_claude_daemon_spawned_by_owner_for_process \
      "$pid" "$root_real" 2>/dev/null) || continue
    if [ -n "$owner" ] && [ "$candidate" != "$owner" ]; then
      return 1
    fi
    owner=$candidate
  done <<EOF
$pids
EOF
  [ -n "$owner" ] || return 1
  printf '%s\n' "$owner"
}

fm_claude_daemon_spawned_by_lock_owner() {  # <lock-pid> <root>
  local lock_pid=$1 root=${2:-} owner
  [ -n "$root" ] || return 1
  owner=$(fm_claude_daemon_spawned_by_session_owner "$root") || return 1
  [ "$owner" = "$lock_pid" ]
}

fm_harness_pid_zombie() {  # <pid>
  local pid=$1 proc_root stat_line state
  local -a stat_fields
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${stat_fields[0]:-}" = Z ]
    return
  fi
  state=$(ps -o stat= -p "$pid" 2>/dev/null) || return 1
  state=${state#"${state%%[![:space:]]*}"}
  case "$state" in Z*) return 0 ;; esac
  return 1
}

# True if $1 is a live, non-zombie process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  fm_harness_pid_zombie "$pid" && return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# True when state dir $1 holds a session lock whose pid is a harness ancestor of
# the current process or the live Claude owner named by an authenticated daemon
# bridge. Ancestry membership is the ordinary proof, because the lock owner
# sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, or ownership that neither ancestry nor the optional
# bridge can prove all fail closed.
# Claude Code 2.1 can also fire Stop hooks from a daemon/bg-spare process tree
# whose pid is not below the foreground session process that wrote state/.lock.
# When the optional root argument is supplied, the daemon's own --spawned-by
# JSON may bridge that gap, but only when it names the live Claude lock owner
# and the same resolved project root.
fm_session_lock_owned_by_self() {  # <state-dir> [root]
  local state=$1 root=${2:-} lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  fm_claude_daemon_spawned_by_lock_owner "$lock_pid" "$root" && return 0
  return 1
}
