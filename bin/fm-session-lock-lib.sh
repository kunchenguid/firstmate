#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

# Known harness command names; extend when a new adapter is verified. omp is
# anchored exactly like pi: its process name is the bare word `omp` (verified,
# omp 18.1.11), and a substring match would claim ompd or comp.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$|^omp$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi omp)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1. With $2 given, only THAT harness is
# considered, so a path carrying some other harness's name cannot answer for it.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path> [only-this-harness]
  local path=$1 wanted=${2:-} name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    [ -z "$wanted" ] || [ "$name" = "$wanted" ] || continue
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# Print the FM_HARNESS_RE alternative that names harness $1 - anchors included -
# or return 1 when the tables above cannot name that harness at all. Derived
# from FM_HARNESS_RE itself rather than restating it, so the per-name and
# whole-table views can never disagree, and it doubles as the fleet's answer to
# "is this a harness whose processes can be identified?".
fm_harness_name_pattern() {  # <harness>
  local harness=${1:-} alt stripped
  [ -n "$harness" ] || return 1
  local IFS='|'
  for alt in $FM_HARNESS_RE; do
    stripped=${alt#^}
    stripped=${stripped%$}
    [ "$stripped" = "$harness" ] || continue
    printf '%s' "$alt"
    return 0
  done
  return 1
}

# Whole path components that positively name harness $1 inside an installed
# PROGRAM path: the harness name itself, plus the canonical package directory
# its own published CLI ships as. Claude Code's npm package installs its entry
# point at .../node_modules/@anthropic-ai/claude-code/cli.js, where no `claude`
# component exists, while ~/.claude/... is that harness's CONFIG tree - hooks,
# settings, MCP wrappers - and names a running harness for nobody. Extend only
# with a package directory an adapter's own CLI is verified to install as.
fm_harness_program_components() {  # <harness>
  printf '%s\n' "$1"
  case "$1" in
    claude) printf '%s\n' claude-code ;;
  esac
}

# Print the script path a bare interpreter is running - the first argument that
# is neither the interpreter itself nor an option - or return 1. Only that one
# argument is program evidence: any later path is data the program was pointed
# at, and reading it as identity is how a config or hook path is mistaken for a
# running harness.
fm_harness_interpreter_script() {  # <args>
  local args=$1 token i=1
  local -a tokens=()
  IFS=' ' read -r -a tokens <<EOF
$args
EOF
  while [ "$i" -lt "${#tokens[@]}" ]; do
    token=${tokens[$i]}
    i=$((i + 1))
    case "$token" in
      ''|-*) continue ;;
    esac
    printf '%s' "$token"
    return 0
  done
  return 1
}

# True when the process described by command name <comm> and full argument
# string <args> is the NAMED harness. Same evidence and same tables as
# fm_harness_process_matches, which stays the "is this ANY harness" owner:
#   1. the basename of the reported command name,
#   2. an exact harness component in that command path or in argv[0],
#   3. a bare interpreter (node, python) whose SCRIPT PATH carries one of that
#      harness's program components as a whole path component - how an
#      npm-installed Claude Code (`node .../@anthropic-ai/claude-code/cli.js`)
#      is identified, since neither its comm nor its argv[0] carries a `claude`
#      path component.
# Witness 3 is structurally anchored rather than a substring of the argument
# string because callers COUNT the processes this names: `node
# ~/.claude/hooks/notify.js` shares the harness's name without being it, and
# counting it would both refuse a healthy single replacement and let an
# unrelated helper stand in for a replacement that never started.
# Every witness is asked about the harness in question, so a witness naming some
# OTHER harness can never short-circuit the rest.
fm_harness_process_is() {  # <harness> <comm> <args>
  local harness=${1:-} comm=${2:-} args=${3:-} re argv0 script component
  re=$(fm_harness_name_pattern "$harness") || return 1
  if printf '%s' "$(basename -- "$comm")" | grep -qE "$re"; then
    return 0
  fi
  argv0=${args%% *}
  fm_harness_path_name "$comm" "$harness" >/dev/null && return 0
  fm_harness_path_name "$argv0" "$harness" >/dev/null && return 0
  case "$comm" in
    *node*|*python*)
      script=$(fm_harness_interpreter_script "$args") || return 1
      while IFS= read -r component; do
        [ -n "$component" ] || continue
        case "/$script/" in
          */"$component"/*) return 0 ;;
        esac
      done <<EOF
$(fm_harness_program_components "$harness")
EOF
      ;;
  esac
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

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
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
  return 1
}
