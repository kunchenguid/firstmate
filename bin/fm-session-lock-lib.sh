#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and is the current process part of that same session?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh and bin/fm-turnend-guard-cursor.sh use it to
# prove a turn-end hook fires inside the lock-owning primary session before it
# may arm or rewake.
# This file is sourced by scripts and has no side effects on source.
#
# Two independent kinds of same-session evidence are accepted, because the
# process tree alone is not the session:
#
#   Ancestry (below): the lock names a process in this one's contiguous
#   verified-harness ancestry. This is the original evidence and still the
#   primary one.
#
#   Session cohort (further below): the lock names a live harness process that
#   provably STARTED this session and is co-located with it. A harness can put a
#   session's work in a process tree that never reaches the pid holding the lock
#   - a background session rehosted under its own pty reparents to init - and
#   ancestry then reports one genuine session as two competing ones.
#
# Neither kind vetoes the other: each is a positive proof on its own, and the
# absence of cohort evidence leaves the ancestry verdict exactly as it was.
# Within the cohort proof the signals are AND-ed, not OR-ed, because the one
# property that must survive is that a genuinely separate concurrent session is
# still refused.
#
# The cohort proof is per-harness and currently reaches only Claude; every other
# adapter is decided by ancestry alone. FM_SESSION_LAUNCH_MARKERS below owns that
# scope limit, why it is safe, and what extending it requires.

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
#   4. node's own `MainThread` exec name, resolved from argv by whole path
#      component only.
#   5. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name script
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
  # Node renames its own main thread, so an npm-installed harness can report
  # `MainThread` as its exec name and carry no interpreter name for the case
  # above to catch: codex-cli 0.139.0 under nvm on Linux reports comm
  # `MainThread` with argv `node .../bin/codex`, and without this it is not a
  # harness at all, which leaves a codex primary unable to acquire its own home.
  #
  # Identity then has to come from the interpreter's SCRIPT PATH - argv[1], the
  # one token after the interpreter - matched by the STRICT whole-path-component
  # rule rather than the loose regex above. Both narrowings matter: `MainThread`
  # is a name any node program can present, so neither an unrelated script under
  # a harness-shaped directory nor a passing `--profile codex` argument may
  # carry a harness verdict.
  if [ "$base" = MainThread ]; then
    script=${args#* }
    script=${script%% *}
    if [ "$script" != "$args" ] && name=$(fm_harness_path_name "$script"); then
      case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
      return 0
    fi
  fi
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
# Pure liveness: a STOPPED harness satisfies this, because it exists. Whether a
# stopped holder still holds the lock is a separate question, decided by
# fm_harness_pid_suspended and fm_session_lock_holder_competes below.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# --- session cohort: same-session evidence the process tree cannot carry -----
#
# Runtime session containers, in the innermost-first order owned by
# bin/fm-backend.sh's fm_backend_detect. Each row is
# "<runtime> <guard-var> <pane-var>": the guard proves a process runs inside
# that runtime, and the pane variable names ONE pane or surface within it.
#
# Only PANE-scoped identifiers appear here. A session-scoped or workspace-scoped
# identifier would make two panes of one workspace look like one session, which
# is the opposite of what this table is for. That is why zellij and orca have no
# row: neither injects a verified pane-scoped identifier into the processes it
# starts, so a home under them keeps the ancestry-only verdict. cmux's five keys
# are injected and non-overridable, so its per-surface id is usable.
#
# Innermost-first matters as much as pane scope. tmux started inside a herdr
# pane puts two independent sessions in one herdr pane, so once a process is
# proven inside a runtime, only THAT runtime's pane id may be compared; falling
# through to an outer container would merge those two sessions into one.
FM_SESSION_CONTAINERS='tmux TMUX TMUX_PANE
herdr HERDR_ENV HERDR_PANE_ID
cmux CMUX_WORKSPACE_ID CMUX_SURFACE_ID'

# Print the value environment variable $2 carried into pid $1, or return 1.
#
# A Linux-compatible /proc is the only source portable enough to trust: macOS
# has no /proc, and `ps -E` is both privileged there and ambiguous to parse for
# values containing spaces. A host without it simply produces no container
# evidence, which leaves the ancestry and controlling-terminal evidence to
# decide rather than widening anything.
fm_session_pid_env() {  # <pid> <var>
  local pid=$1 var=$2 proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} entry
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -r "$proc_root/$pid/environ" ] || return 1
  while IFS= read -r -d '' entry || [ -n "$entry" ]; do
    case "$entry" in
      "$var="*) printf '%s\n' "${entry#*=}"; return 0 ;;
    esac
  done < "$proc_root/$pid/environ"
  return 1
}

# Print "<runtime>=<pane-id>" for the innermost runtime container the process
# runs inside, or return 1 when there is no usable container evidence.
# fm_session_container_self reads this process's own live environment, which is
# what any child of it inherits; fm_session_container_of_pid reads another
# process's inherited environment.
#
# A runtime whose guard is present but whose pane id is missing returns 1 rather
# than falling through to the next row, so a half-populated inner runtime can
# never be answered with an outer container's id.
fm_session_container_self() {
  local runtime guard panevar guardval paneval
  while read -r runtime guard panevar; do
    [ -n "$runtime" ] || continue
    guardval=${!guard:-}
    [ -n "$guardval" ] || continue
    paneval=${!panevar:-}
    [ -n "$paneval" ] || return 1
    printf '%s=%s\n' "$runtime" "$paneval"
    return 0
  done <<EOF
$FM_SESSION_CONTAINERS
EOF
  return 1
}

fm_session_container_of_pid() {  # <pid>
  local pid=$1 runtime guard panevar guardval paneval
  while read -r runtime guard panevar; do
    [ -n "$runtime" ] || continue
    guardval=$(fm_session_pid_env "$pid" "$guard") || continue
    [ -n "$guardval" ] || continue
    paneval=$(fm_session_pid_env "$pid" "$panevar") || return 1
    [ -n "$paneval" ] || return 1
    printf '%s=%s\n' "$runtime" "$paneval"
    return 0
  done <<EOF
$FM_SESSION_CONTAINERS
EOF
  return 1
}

# Print pid $1's controlling terminal, or return 1 when it has none.
#
# "No controlling terminal" is reported as "?" by procps and "??" or "-" by BSD
# ps. Those mean the ABSENCE of a terminal, never a shared one, so two detached
# sessions must never be matched through them.
fm_session_tty_of_pid() {  # <pid>
  local pid=$1 tty
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 1
  case "$tty" in
    ''|'?'|'??'|'-') return 1 ;;
  esac
  printf '%s\n' "$tty"
}

# Environment variables a verified harness exports into EVERY process it starts,
# naming its own session pid. This is the launch relationship the process tree
# loses: it is written at exec time, so it survives the child being reparented,
# rehosted under a fresh pty, or orphaned to init.
#
# SCOPE LIMIT, stated because it is easy to assume away: this table has exactly
# ONE entry, so the cohort proof below can only ever fire for Claude. codex,
# opencode, pi, pi-signed, grok, kimi, and cursor have no verified marker, so on
# those harnesses fm_session_lock_owned_by_self is decided by ancestry alone and
# a session the harness rehosted outside its own process tree still refuses its
# own home and degrades that session start to read-only. That is the unfixed
# half of the defect for those adapters, not a fixed one.
#
# Why leaving it that way is safe rather than merely incomplete: a missing marker
# removes an ACCEPT path and never a refusal, so a marker-less harness lands
# exactly on the behavior it had before this mechanism existed. The alternative
# is worse in both directions. A guessed variable name that no harness sets is
# indistinguishable from no entry, so it buys nothing while reading as coverage;
# a guessed name a harness does set for some other purpose would be believed,
# and a launch marker is one half of the proof that keeps a genuinely separate
# concurrent session out of this home.
#
# Extending it is therefore a verification task, not an editing one: observe the
# variable in a real child of a real session of that harness, add the row, and
# refresh the per-harness record in docs/verification/runtime-backends.md, whose
# opt-in guard reports the marker it actually observed for every installed
# harness. Do not add a row from documentation or inference.
FM_SESSION_LAUNCH_MARKERS='CLAUDE_PID'

# Print the harness session pid recorded in pid $1's inherited environment, or
# return 1 when no verified marker is present.
fm_session_launcher_pid() {  # <pid>
  local pid=$1 var val
  for var in $FM_SESSION_LAUNCH_MARKERS; do
    val=$(fm_session_pid_env "$pid" "$var") || continue
    case "$val" in
      ''|*[!0-9]*) continue ;;
    esac
    printf '%s\n' "$val"
    return 0
  done
  return 1
}

# True when live harness pid $1 is this process's OWN session reached through a
# different process tree, recording the evidence in FM_SESSION_COHORT_EVIDENCE.
#
# TWO independent signals from different sources must BOTH hold, so that neither
# is load-bearing on its own and the absence of either falls back to the
# ancestry verdict rather than opening ownership up:
#
#   1. Relationship. Some process in this session - this one, or a member of its
#      harness ancestry - carries a launch marker naming the holder as the
#      harness session that started it. This is what makes the holder OUR
#      session rather than merely a neighbour, and it is the signal the process
#      tree destroys when a harness rehosts a session under its own pty and the
#      tree reparents to init.
#   2. Co-location. Both processes are in the same innermost runtime container,
#      or on the same controlling terminal. Two providers, either sufficient,
#      because a rehosted session keeps its pane and loses its terminal.
#
# Requiring the relationship is what preserves the property the lock exists for.
# Co-location alone would accept a genuinely separate session that merely shares
# a pane - a second agent started by hand in the captain's own terminal is
# exactly that, and it must still be refused. Co-location alone would also be
# the only thing standing between an unrelated harness and this home if the
# holder's pid were recycled, which is why it corroborates rather than decides.
FM_SESSION_COHORT_EVIDENCE=
fm_session_same_cohort() {  # <pid>
  local pid=$1 mine theirs pids member launcher related=0 located=
  FM_SESSION_COHORT_EVIDENCE=
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  # A dead or recycled pid must never be matched, so the holder has to be a live
  # harness before any of its recorded identity is consulted.
  fm_harness_pid_alive "$pid" || return 1

  launcher=$(fm_session_launcher_pid "$$" 2>/dev/null || true)
  [ "$launcher" = "$pid" ] && related=1
  if [ "$related" -eq 0 ] && pids=$(fm_harness_ancestry_pids 2>/dev/null); then
    while IFS= read -r member; do
      [ -n "$member" ] || continue
      launcher=$(fm_session_launcher_pid "$member" 2>/dev/null || true)
      if [ "$launcher" = "$pid" ]; then
        related=1
        break
      fi
    done <<EOF
$pids
EOF
  fi
  [ "$related" -eq 1 ] || return 1

  if theirs=$(fm_session_container_of_pid "$pid") \
    && mine=$(fm_session_container_self) \
    && [ "$mine" = "$theirs" ]; then
    located="same container $mine"
  elif theirs=$(fm_session_tty_of_pid "$pid") \
    && mine=$(fm_session_tty_of_pid "$$") \
    && [ "$mine" = "$theirs" ]; then
    located="same terminal $mine"
  else
    return 1
  fi

  FM_SESSION_COHORT_EVIDENCE="launched this session; $located"
  return 0
}

# True when pid $1 is durably STOPPED (SIGSTOP, or a shell job suspended with
# Ctrl-Z), confirmed over several samples so a momentary stop is not mistaken
# for a suspended session.
#
# The decision this encodes: a stopped holder does not hold the lock. `kill -0`
# succeeds on a stopped process, so treating stopped as holding turns one
# suspended session into a permanent lockout of the whole home - a strictly
# worse and less recoverable failure than the race the lock prevents, since a
# stopped process mutates nothing while stopped and nothing guarantees it ever
# resumes. The takeover stays bounded rather than silent: the suspended session
# is no longer the recorded owner, so on resume its own turn-end hooks fail the
# ownership test and go inert instead of competing, and bin/fm-lock.sh reports
# the reclaim on the acquiring side.
#
# Only `T` counts. Linux also reports `t` for a tracing stop, which is routinely
# transient inside a debugger or strace, and reclaiming a home from it would be
# a reflex rather than a decision.
FM_SESSION_STOP_SAMPLES=${FM_SESSION_STOP_SAMPLES:-3}
FM_SESSION_STOP_SAMPLE_SLEEP=${FM_SESSION_STOP_SAMPLE_SLEEP:-0.2}
fm_harness_pid_suspended() {  # <pid>
  local pid=$1 i=0 state
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  while [ "$i" -lt "$FM_SESSION_STOP_SAMPLES" ]; do
    state=$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 1
    case "$state" in
      T*) : ;;
      *) return 1 ;;
    esac
    i=$((i + 1))
    if [ "$i" -lt "$FM_SESSION_STOP_SAMPLES" ]; then
      sleep "$FM_SESSION_STOP_SAMPLE_SLEEP"
    fi
  done
  return 0
}

# True when session-lock holder $1 is a COMPETING session the caller must yield
# to. This is the question every caller of the old bare liveness check was
# actually asking, and it is the single owner of the answer.
#
# Not competing: a dead or non-harness pid, a pid in this process's own session
# cohort, and a durably suspended harness. Everything else is.
# shellcheck disable=SC2034 # Read by bin/fm-lock.sh to report why it did not yield.
FM_SESSION_HOLDER_YIELD_REASON=
fm_session_lock_holder_competes() {  # <pid>
  local pid=$1
  FM_SESSION_HOLDER_YIELD_REASON=
  if ! fm_harness_pid_alive "$pid"; then
    FM_SESSION_HOLDER_YIELD_REASON="dead or non-harness holder pid $pid"
    return 1
  fi
  if fm_session_same_cohort "$pid"; then
    FM_SESSION_HOLDER_YIELD_REASON="this session's own holder pid $pid ($FM_SESSION_COHORT_EVIDENCE)"
    return 1
  fi
  if fm_harness_pid_suspended "$pid"; then
    # shellcheck disable=SC2034 # Read by bin/fm-lock.sh to report why it did not yield.
    FM_SESSION_HOLDER_YIELD_REASON="suspended harness pid $pid"
    return 1
  fi
  return 0
}

# True when state dir $1 holds a session lock this process's own session owns.
#
# Ancestry membership is the primary proof, and is the honest test for it,
# because the lock owner sits at an unknown depth in a contiguous Claude run -
# it is the outermost pid when the hook fires inside the session's own nested
# worker chain, and an inner pid when a harness-named daemon parents the session.
# When the lock names a harness OUTSIDE that ancestry, the session-cohort proof
# above decides, which is what keeps a session whose work the harness moved into
# a separate process tree from reporting itself as a competitor.
#
# A missing lock, a malformed lock, an ancestry that cannot be resolved, and a
# lock held by a harness that is neither an ancestor nor in this session's
# cohort all still fail closed. Requiring a resolvable ancestry before the
# cohort proof is deliberate: ownership stays a claim only a harness session can
# make, never one an ordinary script sharing the captain's terminal can make.
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
  fm_session_same_cohort "$lock_pid"
}
