#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness SESSION holds this home's session
# lock, and does the current process run inside that same session?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock and its
# state/.lock-session sidecar; bin/fm-claude-stop-autoarm.sh uses it to prove a
# Stop hook fires inside the lock-owning primary session before it may arm or
# rewake.
#
# A recorded pid is not a session, so the lock's identity has three separable
# parts and every liveness question asks all three:
#
#   process identity - the anchor pid plus fm_session_lock_birth_token, the pid's
#     own start time. Procfs tokens use start ticks and exclude argv because
#     harnesses rewrite it; the ps lstart fallback has a one-second floor.
#     `kill -0` alone proves nothing and is never the whole answer.
#     A legacy sidecar without line 3 retains the pre-token live-harness
#     judgment; new records omit that line when the start time is unreadable.
#   harness identity - FM_HARNESS_IS_DAEMON: a shared long-lived server that
#     hosts sessions without being one (Codex's `codex app-server`, OpenCode's
#     `opencode serve`, Claude's transient `claude daemon run`). Such a process
#     outlives every session it serves, so it is never a lock anchor and its
#     liveness never proves an owner is still there.
#   session identity - the id recorded beside the lock, from the harness that
#     publishes one: Claude's CLAUDE_CODE_SESSION_ID and Codex's thread id are
#     read from this process's own environment, while a session running under a
#     shared server that no longer exposes its own process is identified by the
#     session/tab pane identity that harness passes down to its tool shells.
#
# Ownership is then: ancestry membership in this session's own harness run, or
# an exact match on the recorded session id and harness. Neither signal ever
# fails open: no id, no sidecar, an untrusted id, a different recorded id, or a
# shared server leaves the ancestry verdict exactly as it was.
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

# The same harnesses as exact executable names, longest first so `pi-signed` is
# never read as `pi`. Keep in sync with FM_HARNESS_RE. Used only for the stricter
# path evidence below, where the loose regex would also match ordinary firstmate
# paths such as bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed omp pi)

# Print the harness name a reported command name $1 carries, or return 1.
#
# Only the leading word is read, and only a name followed by a separator that no
# ordinary English word produces, so `codex-code-mode-host`, `claude bg-spare`
# and a bare `pi` are named while `ompd` and `comp` are not. `pi-signed` is
# tried before `pi` so the signed wrapper keeps its own name.
fm_harness_name_from_word() {  # <word>
  local word=$1 name
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "$word" in
      "$name" | "$name"-* | "$name".* | "$name"[[:space:]]*)
        printf '%s' "$name"
        return 0
        ;;
    esac
  done
  return 1
}

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

# True when the verified-harness process described by command name $1 and full
# argument string $2 is a SHARED SERVER rather than a session: the long-lived
# process that hosts sessions without being one.
#
# Only argv[1] - the subcommand slot - and whole-argument flags are read, so a
# brief or prompt that happens to contain the word `serve` inside its text can
# never demote a real session to a daemon. `codex app-server --managed-daemon`
# and `opencode serve --service` are both daemon shapes; `codex-code-mode-host`,
# which carries one session's working directory, is not.
fm_harness_process_is_daemon() {  # <comm> <args>
  local args=$2 rest word flag_args
  case "$args" in
    *' '*) ;;
    *) return 1 ;; # a single-word command line carries no subcommand
  esac
  rest=${args#* }
  word=${rest%% *}
  case "$word" in
    app-server | serve | daemon) return 0 ;;
  esac
  # ps flattens argv, so option-looking text in a prompt cannot be
  # distinguished after the prompt option. Only inspect preceding arguments.
  flag_args=$args
  case " $flag_args " in
    *" --prompt="*) flag_args=${flag_args%% --prompt=*} ;;
    *" -p="*) flag_args=${flag_args%% -p=*} ;;
    *" --instructions="*) flag_args=${flag_args%% --instructions=*} ;;
    *" --prompt "*) flag_args=${flag_args%% --prompt *} ;;
    *" -p "*) flag_args=${flag_args%% -p *} ;;
    *" --instructions "*) flag_args=${flag_args%% --instructions *} ;;
    *" -i "*) flag_args=${flag_args%% -i *} ;;
  esac
  case " $flag_args " in
    *" --managed-daemon "* | *" --service "*) return 0 ;;
  esac
  return 1
}

# True when $1 is a live verified-harness process that is a shared server.
fm_harness_pid_is_daemon() {  # <pid>
  local pid=$1 comm args
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args" || return 1
  fm_harness_process_is_daemon "$comm" "$args"
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE and FM_HARNESS_IS_DAEMON for
# the callers below, and FM_HARNESS_NAME when the name is readable.
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
FM_HARNESS_IS_DAEMON=0
FM_HARNESS_NAME=
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  FM_HARNESS_NAME=
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    FM_HARNESS_NAME=$(fm_harness_name_from_word "$base" 2>/dev/null || true)
    fm_harness_process_is_daemon "$comm" "$args" && FM_HARNESS_IS_DAEMON=1
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    FM_HARNESS_NAME=$name
    fm_harness_process_is_daemon "$comm" "$args" && FM_HARNESS_IS_DAEMON=1
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node* | *python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        FM_HARNESS_NAME=$(fm_harness_path_name "$args" 2>/dev/null || true)
        fm_harness_process_is_daemon "$comm" "$args" && FM_HARNESS_IS_DAEMON=1
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  if fm_cursor_process_matches "$comm" "$args" "$argv0"; then
    FM_HARNESS_NAME=cursor
    return 0
  fi
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess. A shared server is
# still reported, because it is part of the run and Claude's proven topology
# puts its transient daemon inside one; deciding that a run member may not own
# the lock is fm_harness_pid_is_daemon's job, not this walk's.
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
    # Examine the top of the chain before stopping. Inside a PID namespace the
    # harness itself is pid 1, so stopping as soon as the next pid is 1 hides the
    # very process this walk exists to find. A host's real pid 1 (init, systemd,
    # launchd) is not harness-shaped, so fm_harness_process_matches rejects it.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the outermost pid of this session's contiguous harness run for callers
# that need that ancestry identity. This is not necessarily the pid written to
# the session lock: fm_session_lock_anchor_pid owns that choice and uses a
# trusted Claude session's model-loop pid instead. Every non-Claude harness
# reports a single pid, so this remains its innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  _fm_harness_outermost_pid "$pids"
}

# Print the last (outermost) pid of ancestry list $1, or return 1 when empty.
_fm_harness_outermost_pid() {  # <ancestry-pids>
  local pid outermost=''
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$1
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# Print ancestry list $1 outermost first: the reverse of the walk's own order.
_fm_harness_reversed_pids() {  # <ancestry-pids>
  local -a reversed=()
  local pid
  while IFS= read -r pid; do
    [ -n "$pid" ] && reversed+=("$pid")
  done <<EOF
$1
EOF
  local i
  for ((i = ${#reversed[@]} - 1; i >= 0; i--)); do
    printf '%s\n' "${reversed[i]}"
  done
}

# Print the first (innermost) pid of ancestry list $1, or return 1 when empty.
_fm_harness_innermost_pid() {  # <ancestry-pids>
  local pid
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    printf '%s\n' "$pid"
    return 0
  done <<EOF
$1
EOF
  return 1
}

# True if $1 is a live process that looks like a verified harness SESSION. A
# shared server is excluded: it outlives the sessions it hosts, so treating its
# existence as a live owner is exactly the failure this predicate must not have.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args" || return 1
  fm_harness_process_is_daemon "$comm" "$args" && return 1
  return 0
}

# Print the start time of process $1 - its process identity, alongside the pid -
# or return 1. LC_ALL=C pins the format because the token is written under one
# locale and re-read under whatever locale the reading session runs.
# The same lstart reading backs the wake library's fm_pid_identity; this is the
# narrower birth-only form, because a harness rewrites its own argv as its title
# changes, so the command line cannot be part of a long-lived identity.
fm_session_lock_birth_token() {  # <pid>
  local pid=$1 out proc_root stat_line starttime
  local -a stat_fields
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null || true)
    if [ -n "$stat_line" ]; then
      read -r -a stat_fields <<< "${stat_line##*)}"
      if [ "${#stat_fields[@]}" -ge 20 ]; then
        starttime=${stat_fields[19]}
        case "$starttime" in
          '' | *[!0-9]*) ;;
          *)
            case "$(uname 2>/dev/null || true)" in
              Linux) printf 'linux-starttime=%s\n' "$starttime" ;;
              *) printf 'proc-starttime=%s\n' "$starttime" ;;
            esac
            return 0
            ;;
        esac
      fi
    fi
  fi
  out=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  out=${out#"${out%%[![:space:]]*}"}
  out=${out%"${out##*[![:space:]]}"}
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# Print the session/tab identity this process belongs to, as the marker the
# harness passes down to every tool shell it spawns, or return 1.
#
# tmux sets TMUX_PANE in every pane it starts, and Herdr injects HERDR_ENV=1
# plus HERDR_PANE_ID; both are per-tab identifiers, which is what separates two
# sessions that share one long-lived server. macOS Terminal.app's TERM_SESSION_ID
# is deliberately NOT used: it identifies a window, so every tab in one window
# shares it and it cannot tell two sessions apart.
fm_session_lock_pane_identity() {
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'TMUX_PANE=%s' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'HERDR_PANE_ID=%s' "$HERDR_PANE_ID"
    return 0
  fi
  return 1
}

# Print the pid of the session's OWN harness process given pane marker $1: the
# outermost verified-harness process that is not a shared server and whose
# environment carries that marker. Returns 1 when no such process is visible,
# so a caller that cannot resolve its own session fails closed instead of
# anchoring on the shared server that would outlive it.
fm_session_lock_pane_session_pid() {  # <pane-marker>
  local marker=$1 line pid rest parent candidate listing marker_name marker_value args env
  local -a candidates=()
  [ -n "$marker" ] || return 1
  # pgrep cannot select on a process's environment, which is the only place the
  # pane marker exists, so this has to read the full listing and filter itself.
  # shellcheck disable=SC2009
  marker_name=${marker%%=*}
  marker_value=${marker#*=}
  [ "$marker_name" = TMUX_PANE ] || [ "$marker_name" = HERDR_PANE_ID ] || return 1
  [ -n "$marker_value" ] || return 1
  listing=$(ps eww -A -o pid=,args= 2>/dev/null)
  while IFS= read -r line; do
    pid=${line%% *}
    case "$pid" in '' | *[!0-9]*) continue ;; esac
    args=$(ps -o args= -p "$pid" 2>/dev/null) || continue
    rest=${line#* }
    case "$rest" in
      "$args "*) env=${rest#"$args "} ;;
      *) continue ;;
    esac
    case " $env " in
      *" $marker_name=$marker_value "*) ;;
      *) continue ;;
    esac
    fm_harness_process_matches "${args%% *}" "$args" || continue
    fm_harness_process_is_daemon "${args%% *}" "$args" && continue
    candidates+=("$pid")
  done <<EOF
$listing
EOF
  [ "${#candidates[@]}" -gt 0 ] || return 1
  for candidate in "${candidates[@]}"; do
    parent=$(ps -o ppid= -p "$candidate" 2>/dev/null | tr -d '[:space:]')
    case "$parent" in '' | *[!0-9]*) continue ;; esac
    case " ${candidates[*]-} " in
      *" $parent "*) continue ;;
    esac
    printf '%s\n' "$candidate"
    return 0
  done
  # Several unrelated outermost candidates: the identity is ambiguous, so this
  # session cannot claim the lock.
  return 1
}

# --- trusted same-session identity -------------------------------------------
# Claude Code hands every hook and tool shell CLAUDE_CODE_SESSION_ID (the
# session's conversation id) and CLAUDE_PID (the pid of the process running the
# model loop). A background session runs that model loop in a transient helper
# bridged to its front-end by a shared daemon, and when that bridge is recycled
# the contiguous claude-named ancestry from a hook to the recorded lock owner
# breaks while the owner pid stays alive, so ancestry alone reads the session's
# own lock as another live session's. The id is the one identity that survives
# the recycling, so it is accepted as a second ownership signal - but only from
# an environment proven to belong to the current run.
#
# Trust gate: the id's own harness must be this session's innermost harness
# process, and for Claude the CLAUDE_PID named by the environment must itself be
# a claude-shaped member of the contiguous run. An id merely retained in a helper
# environment fails that gate and is ignored: a hand-started Pi or codex primary
# under a Claude pane still carries the pane's CLAUDE_CODE_SESSION_ID and
# CLAUDE_PID, and must never own a lock with them. Codex has no per-process id
# variable, so its thread id is trusted only when the innermost harness process
# of this shell's own run is a codex session rather than a shared server. Ids
# are read from the environment only, never from ps argv, where prompts and
# briefs are visible.
#
# A --fork-session successor mints a new id, so it stays a foreign live owner
# until the pre-fork process exits; that is the safe direction and a documented
# non-goal. Two genuinely different live sessions sharing one id is not a
# supported state (Claude refuses to resume a running session under its id).
#
# A session running under a shared server gets no harness-published id at all -
# the server hides the session's own process from the ancestry - so it is
# identified by the pane marker fm_session_lock_pane_identity prints, which that
# same harness passes down to every tool shell it runs.

# Resolve the session identity this process may own with into FM_SESSION_LOCK_ID
# and FM_SESSION_LOCK_ID_HARNESS, or return 1. $1 is the ancestry list an earlier
# walk already produced, so a caller that walked once need not walk again.
#
# Both land in globals rather than on stdout because a command substitution runs
# in a subshell and would drop the harness, leaving every reader comparing
# against an empty name. Callers must invoke this directly, never as
# `x=$(...)`, and read the globals; fm_session_lock_trusted_session_id below is
# the printing form for callers that need only the id.
# shellcheck disable=SC2034 # Output globals, read by fm-lock.sh and the callers below.
FM_SESSION_LOCK_ID=
FM_SESSION_LOCK_ID_HARNESS=
fm_session_lock_resolve_trusted_id() {  # [<ancestry-pids>]
  local pids=${1:-} innermost comm args name id claude_pid marker
  FM_SESSION_LOCK_ID=
  FM_SESSION_LOCK_ID_HARNESS=
  [ -n "$pids" ] || pids=$(fm_harness_ancestry_pids) || return 1
  innermost=$(_fm_harness_innermost_pid "$pids") || return 1
  comm=$(ps -o comm= -p "$innermost" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$innermost" 2>/dev/null)
  name=$(fm_harness_process_name "$comm" "$args") || return 1

  if [ "$name" = claude ]; then
    # Claude reference rule: the id is trusted only alongside a CLAUDE_PID that
    # is itself a claude-shaped member of this run.
    claude_pid=${CLAUDE_PID:-}
    case "$claude_pid" in '' | *[!0-9]*) return 1 ;; esac
    printf '%s\n' "$pids" | grep -qx "$claude_pid" || return 1
    id=${CLAUDE_CODE_SESSION_ID:-}
    [ -n "$id" ] || return 1
    case "$id" in *$'\n'* | *$'\r'*) return 1 ;; esac
    FM_SESSION_LOCK_ID=$id
    FM_SESSION_LOCK_ID_HARNESS=claude
    return 0
  fi

  if [ "$name" = codex ]; then
    id=${CODEX_THREAD_ID:-${CODEX_SESSION_ID:-}}
    [ -n "$id" ] || return 1
    case "$id" in *$'\n'* | *$'\r'*) return 1 ;; esac
    FM_SESSION_LOCK_ID=$id
    FM_SESSION_LOCK_ID_HARNESS=codex
    return 0
  fi

  # A shared server is this session's innermost harness process, so the session's
  # own process is not in the ancestry at all: fall back to the session/tab
  # identity the harness passed down to this shell.
  if fm_harness_process_is_daemon "$comm" "$args"; then
    marker=$(fm_session_lock_pane_identity) || return 1
    FM_SESSION_LOCK_ID=$marker
    FM_SESSION_LOCK_ID_HARNESS=$name
    return 0
  fi
  return 1
}

# Print the session identity this process may own with, or return 1. Prints only
# the id; a caller that also needs the harness must call
# fm_session_lock_resolve_trusted_id directly.
fm_session_lock_trusted_session_id() {  # [<ancestry-pids>]
  fm_session_lock_resolve_trusted_id "${1:-}" || return 1
  printf '%s\n' "$FM_SESSION_LOCK_ID"
}

# Print the harness name carried by process described by command name $1 and
# argument string $2, or return 1 when the name is not readable (Cursor's own
# owner does not report one).
fm_harness_process_name() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  base=$(basename -- "$comm")
  name=$(fm_harness_name_from_word "$base" 2>/dev/null || true)
  if [ -z "$name" ]; then
    argv0=${args%% *}
    name=$(fm_harness_name_from_word "$argv0" 2>/dev/null || true)
  fi
  if [ -z "$name" ]; then
    name=$(fm_harness_path_name "$comm" 2>/dev/null || true)
  fi
  if [ -z "$name" ]; then
    argv0=${args%% *}
    name=$(fm_harness_path_name "$argv0" 2>/dev/null || true)
  fi
  [ -n "$name" ] || return 1
  printf '%s\n' "$name"
}

# Print the session id recorded beside the lock in state dir $1, or return 1.
# bin/fm-lock.sh is the only writer of state/.lock-session; a missing,
# symlinked, unreadable, or empty sidecar, or one whose first line contains a
# newline or carriage return, is simply no recorded id.
fm_session_lock_recorded_session_id() {  # <state>
  local state=$1 recorded
  [ -f "$state/.lock-session" ] && [ ! -L "$state/.lock-session" ] || return 1
  recorded=$(head -n 1 "$state/.lock-session" 2>/dev/null) || return 1
  [ -n "$recorded" ] || return 1
  case "$recorded" in *$'\n'* | *$'\r'*) return 1 ;; esac
  printf '%s\n' "$recorded"
}

# Print the harness that recorded the session id in state dir $1, or return 1.
# Line 2 of the sidecar; absent in a record written before harness identity was
# recorded, which is treated as Claude's - the only harness that wrote one.
fm_session_lock_recorded_harness() {  # <state>
  local state=$1 recorded
  [ -f "$state/.lock-session" ] && [ ! -L "$state/.lock-session" ] || return 1
  recorded=$(sed -n '2p' "$state/.lock-session" 2>/dev/null) || return 1
  [ -n "$recorded" ] || return 1
  printf '%s\n' "$recorded"
}

# Print the birth token recorded beside the lock in state dir $1, or return 1.
# Line 3 of the sidecar; absent in a record written before process identity was
# recorded, which is judged the way such a record always was.
fm_session_lock_recorded_birth() {  # <state>
  local state=$1 recorded
  [ -f "$state/.lock-session" ] && [ ! -L "$state/.lock-session" ] || return 1
  recorded=$(sed -n '3p' "$state/.lock-session" 2>/dev/null) || return 1
  [ -n "$recorded" ] || return 1
  printf '%s\n' "$recorded"
}

# True when the lock in state dir $1 records this same session: the recorded
# session id and harness match what this process may own with. No trusted id, no
# sidecar, or a different recorded id or harness is false.
fm_session_lock_same_session() {  # <state> [<ancestry-pids>]
  local state=$1 recorded recorded_harness
  fm_session_lock_resolve_trusted_id "${2:-}" || return 1
  recorded=$(fm_session_lock_recorded_session_id "$state") || return 1
  [ "$recorded" = "$FM_SESSION_LOCK_ID" ] || return 1
  # A record written before harness identity was recorded was necessarily Claude's,
  # so an absent second line cannot be read as a wildcard.
  recorded_harness=$(fm_session_lock_recorded_harness "$state" 2>/dev/null || true)
  if [ -n "$recorded_harness" ] && [ "$recorded_harness" != "$FM_SESSION_LOCK_ID_HARNESS" ]; then
    return 1
  fi
  return 0
}

# True when the owner recorded beside the lock in state dir $1 is still a live
# session: the recorded pid is a live harness session (never a shared server),
# and a recorded birth token still matches that pid's own start time, so a
# recycled pid cannot pass as the owner. A record with no birth token is judged
# exactly as it was before process identity was recorded.
fm_session_lock_recorded_owner_live() {  # <state>
  local state=$1 pid recorded current recorded_harness comm args current_harness
  pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  fm_harness_pid_alive "$pid" || return 1
  recorded=$(fm_session_lock_recorded_birth "$state" 2>/dev/null || true)
  [ -n "$recorded" ] || return 0 # legacy compatibility: pre-token liveness
  current=$(fm_session_lock_birth_token "$pid" 2>/dev/null || true)
  case "$recorded" in
    proc-starttime=* | linux-starttime=*) ;;
    *)
      recorded_harness=$(fm_session_lock_recorded_harness "$state" 2>/dev/null || true)
      if [ -n "$recorded_harness" ]; then
        comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
        args=$(ps -o args= -p "$pid" 2>/dev/null)
        current_harness=$(fm_harness_process_name "$comm" "$args" 2>/dev/null || true)
        [ "$current_harness" = "$recorded_harness" ] || return 1
      fi
      ;;
  esac
  [ "$current" = "$recorded" ]
}

# Print the pid bin/fm-lock.sh records on lock line 1 for this session.
#
# A Claude session with a trusted id records CLAUDE_PID, the model-loop process,
# so a shared transient daemon or a front-end that outlives the session never
# keeps a dead session's lock alive. Any other session records its own process
# from the ancestry: the innermost match when that process belongs to the
# session, or the session's own process located by the pane identity when the
# session's ancestry holds only a shared server. A shared server is never the
# answer, so a session that cannot resolve its own process returns 1 and the
# caller refuses rather than anchoring on a process that outlives it.
fm_session_lock_anchor_pid() {
  local pids pid comm args
  pids=$(fm_harness_ancestry_pids) || return 1
  if fm_session_lock_resolve_trusted_id "$pids"; then
    case "$FM_SESSION_LOCK_ID_HARNESS" in
      claude)
        printf '%s\n' "$CLAUDE_PID"
        return 0
        ;;
    esac
  fi
  # Outermost first: the outermost member of a contiguous run lives at least as
  # long as any member below it, so an inner worker that is recycled mid-session
  # cannot make the session's own lock read stale. A shared server is skipped
  # rather than accepted, which is the whole point - `codex app-server` and
  # `opencode serve` are outermost precisely because they parent everything, and
  # anchoring on either outlives the session that recorded it.
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || continue
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if ! fm_harness_process_is_daemon "$comm" "$args"; then
      printf '%s\n' "$pid"
      return 0
    fi
  done <<EOF
$(_fm_harness_reversed_pids "$pids")
EOF
  # Nothing but shared servers above this shell: the session's own process is
  # not visible in the ancestry, so it is located by the pane identity that
  # harness passes down to its tool shells.
  fm_session_lock_pane_session_pid "$(fm_session_lock_pane_identity || true)"
}

# True when state dir $1 holds a session lock that this process's session owns:
# the recorded pid is a session-shaped (never a shared server) member of this
# process's own contiguous harness run, or the lock was recorded by this same
# session id and its recorded pid is still a live session with the recorded
# process identity. Membership is the honest ancestry test, because the lock
# owner sits at an unknown depth in a contiguous Claude run - it is the outermost
# pid when the hook fires inside the session's own nested worker chain, and an
# inner pid when a harness-named server parents the session. The same-session
# path requires the recorded owner to still be live so that a dead one is
# reclaimed through bin/fm-lock.sh's ordinary stale-owner path, which refreshes
# line 1, rather than silently owned with a dead anchor. A missing lock, a
# malformed lock, a lock held by a shared server or by a harness outside this
# ancestry under another (or no) session id, or an ancestry that cannot be
# resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] || continue
    # A shared server is in everyone's ancestry, so it is never this session's
    # own lock owner.
    fm_harness_pid_is_daemon "$lock_pid" && return 1
    return 0
  done <<EOF
$pids
EOF
  fm_session_lock_same_session "$state" "$pids" || return 1
  fm_session_lock_recorded_owner_live "$state"
}

# True when state dir $1 records a live verified-harness session outside this
# process's contiguous harness ancestry that was not recorded by this same
# session. Sets FM_SESSION_LOCK_FOREIGN_OWNER_PID for a diagnostic caller.
# Malformed, missing, dead, pid-recycled, shared-server, and ancestry-uncertain
# locks are not foreign-owner evidence.
# shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
FM_SESSION_LOCK_FOREIGN_OWNER_PID=
fm_session_lock_foreign_owner_live() {
  local state=$1 lock_pid pids pid
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  fm_session_lock_recorded_owner_live "$state" || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 1
  done <<EOF
$pids
EOF
  fm_session_lock_same_session "$state" "$pids" && return 1
  # shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=$lock_pid
  return 0
}
