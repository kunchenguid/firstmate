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
#   Session cohort (further below): the lock names a live harness process tied to
#   this one by a launch relationship in EITHER direction - it started this
#   session, or this session started it - and co-located with it. A harness can
#   put a session's work in a process tree that never reaches the pid holding the
#   lock - a background session rehosted under its own pty reparents to init -
#   and ancestry then reports one genuine session as two competing ones.
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

# Print the exact harness name when path $1's BASENAME is exactly a verified
# harness name, or return 1.
#
# The strictest of this file's rules, and the single owner of the exact-equality
# test. Two callers reach it, and they hand it different things. The `MainThread`
# branch below passes a SCRIPT PATH from argv, its only token of evidence, so it
# takes the strictest reading of it; the sibling interpreter branch reads the same
# token positions under the same stop-at-the-first-flag rule but by whole path
# component, because the only shape it identifies at all is a node-hosted bin
# entry that is NOT named after the harness. fm_harness_comm_name below passes a
# REPORTED COMMAND NAME, and normalizes the reporter's own artifacts out of it
# first; that normalization is stated there and deliberately does not reach the
# script-path caller, which sees neither of those artifacts.
#
# Exact equality is deliberate, and under `MainThread` it is the ONLY evidence
# there is: the command path is literally `MainThread` and argv[0] is the
# interpreter, so neither the command-path nor the argv[0] rule above can see the
# script at all. A harness whose script basename is not exactly the harness name
# - a version-suffixed name, or a `.js` bin entry - is therefore deliberately not
# identified in that branch. Teaching it such a shape is a verification task
# against a real release, the same as extending FM_SESSION_LAUNCH_MARKERS, and
# not a reason to loosen this rule.
fm_harness_basename_name() {  # <path>
  local path=$1 base name
  [ -n "$path" ] || return 1
  base=${path##*/}
  for name in "${FM_HARNESS_NAMES[@]}"; do
    if [ "$base" = "$name" ]; then
      printf '%s' "$name"
      return 0
    fi
  done
  return 1
}

# Print the exact harness name that COMMAND NAME $1 reports, or return 1.
#
# The same exact-equality test as fm_harness_basename_name, applied to a command
# name after two reporting artifacts are undone. Both are properties of how the
# name reaches us rather than of the program, so leaving them in place refuses a
# harness its own home while it is the only session alive:
#
#   1. A command name is not always one word, and it is truncated to 15
#      characters. Linux reports the kernel task name, which node and Bun
#      harnesses rename to label a worker role, so Claude Code's background pty
#      worker `claude bg-pty-host` arrives as `claude bg-pty-h` - one executable
#      word, one role label, and a cut that lands mid-word. The executable is the
#      FIRST word, so only that word is compared and the cut cannot reach it: no
#      verified harness name is longer than 15 characters.
#   2. Claude Code's installed executable is literally named `claude.exe` on
#      every platform, because it is a single-file Bun build, so a process that
#      execs it reports that name verbatim. `.exe` is the only executable suffix
#      any verified harness carries.
#
# Neither step loosens the comparison itself, which is still exact equality
# against FM_HARNESS_NAMES, and that is what keeps this from becoming a prefix
# rule: `claude-code` has neither a space nor a suffix, so it is still not a
# harness, and neither are `claudette` or `claude_code`. Path components are
# untouched here, so `pi` keeps the basename anchoring that stops an interior
# `/home/pi` component from naming a harness.
fm_harness_comm_name() {  # <comm>
  local base=${1##*/}
  base=${base%% *}
  base=${base%.exe}
  fm_harness_basename_name "$base"
}

# Print the exact harness name carried by an ARGV token $1, or return 1.
#
# A whole path component, as fm_harness_path_name reads it, except that `pi` and
# `pi-signed` must be the token's own basename. FM_HARNESS_RE anchors those two
# names as `^pi$` and `^pi-signed$` because they are too short and too ordinary
# to survive an unanchored reading, and a two-character interior component is
# exactly where that bites: `/home/pi` is the default home directory on Raspberry
# Pi OS, so `node /home/pi/app.js` would otherwise be a verified Pi harness, and
# as a recycled recorded holder it would refuse a real session its own home.
# The command path and argv[0] rule above reads those names as components too and
# is deliberately left alone here; this anchoring covers only the argv tokens,
# which the rule this replaced could never match for these two names at all.
fm_harness_argv_path_name() {  # <path>
  local path=$1 base name
  [ -n "$path" ] || return 1
  base=${path##*/}
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "$name" in
      pi|pi-signed)
        if [ "$base" = "$name" ]; then
          printf '%s' "$name"
          return 0
        fi
        ;;
      *)
        case "/$path/" in
          */"$name"/*) printf '%s' "$name"; return 0 ;;
        esac
        ;;
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
#   3. a bare interpreter (node, python) running a harness script path, taken
#      from the argv tokens before the first flag by whole path component.
#   4. node's own `MainThread` exec name, resolved from the one argv token after
#      the interpreter by exact basename only, and refused outright when that
#      token is a flag.
#   5. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
#
# Rules 3 and 4 read an ARGUMENT LIST, which is data the process was handed rather
# than the program it is running, so they identify a recorded pid for the ancestry
# walk and the liveness predicate and they carry no weight in the cohort's
# acceptance decision. fm_harness_exec_kind below is that stricter reading, and
# the difference between the two is stated there.
#
# This answers WHETHER, not WHICH. FM_HARNESS_IS_CLAUDE is the one thing it also
# reports, because the ancestry walk needs it to know when to keep climbing a
# nested worker chain; it is a global every call clobbers. Which harness a
# particular pid IS belongs to fm_harness_exec_kind below, which reads only
# executable identity and is the only naming the cohort proof may act on.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name script rest
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
  # Bare interpreter (e.g. node, python) that reports its OWN name as the exec
  # name: identity comes from the interpreter's script path in argv, read under
  # the same discipline the MainThread branch below uses. The tokens after the
  # interpreter are read in order and the scan STOPS at the first one beginning
  # with `-`, because from there on a path-shaped token may be an interpreter flag
  # or the VALUE of one, and a flag's value can be named anything at all. A token
  # before that boundary carries a verdict only when a whole path component of it
  # is exactly a harness name.
  #
  # Reading the whole argument string is what this rule used to do, and it
  # identified shapes that are not harnesses at all, because that test was an
  # unanchored regex with no path-component requirement in it: an unrelated
  # service carrying any ordinary `~/.claude/...` hook, settings, log or
  # transcript argument reported itself as Claude, as did
  # `node --require /opt/hooks/claude/instrument.js /srv/app/server.js` and
  # `python3 /srv/app.py --config /etc/claude/x.toml`. None of the three is
  # identified now.
  #
  # Stopping at the first flag gives up the inferred
  # `node --experimental-foo /path/to/claude/cli.js` shape on purpose, which is
  # the same trade the MainThread branch takes: the alternative is an allowlist of
  # value-taking interpreter flags that would rot silently every time a vendor
  # adds one, and silently stale recorded state is the failure this whole
  # mechanism exists to remove. Both outputs are derived from the token that
  # matched and never from the whole argv, so a harness name sitting elsewhere in
  # the arguments can neither name the kind nor raise the Claude flag.
  #
  # Two limits of this rule are known and stated rather than left implied. It
  # reads EVERY token before that flag rather than the script token alone, so a
  # positional path argument can decide the verdict and this rule and the
  # MainThread branch disagree on identical argv: `node /srv/app/server.js
  # /opt/claude/agent.json` is Claude here and is nothing there. And the component
  # it needs is an exact one, so a real npm layout whose package directory is
  # `claude-code` or `opencode-ai` rather than the bare harness name is not
  # identified at all. Both bound identification for the ancestry walk and the
  # liveness predicate only; neither can reach the cohort's acceptance decision,
  # which fm_harness_exec_kind below settles from executable identity alone.
  #
  # The npm-layout limit runs in BOTH directions, and the second direction is
  # stated here because this lands on a running fleet by in-place update. The
  # liveness predicate also judges a RECORDED holder, so a session lock an older
  # firstmate wrote for a still-live session of one of those unidentified shapes
  # now reads as not-a-harness and is reclaimed while that session is still
  # running. It is bounded to that adoption window rather than being a standing
  # hole, because this rule refuses to record such a holder in the first place,
  # and it is not closed.
  #
  # That shape is one INSTANCE of a wider condition rather than its cause. Any
  # live process occupying the recorded pid that these rules cannot type reads
  # the same way, and the ordinary trigger is an unrelated process that inherited
  # a recycled pid from a lock nobody released. fm_harness_pid_state's header
  # below is the single owner of that condition rather than this block restating
  # it. The mitigation covers all of it: fm_session_lock_holder_competes
  # classifies a live-but-unidentified holder apart from a gone one, so the
  # reclaim announces itself rather than moving the lock out from under a visible
  # process in silence.
  case "$comm" in
    *node*|*python*)
      rest=${args#* }
      if [ "$rest" != "$args" ]; then
        while [ -n "$rest" ]; do
          script=${rest%% *}
          case "$rest" in
            *' '*) rest=${rest#* } ;;
            *) rest='' ;;
          esac
          [ -n "$script" ] || continue
          case "$script" in
            -*) break ;;
          esac
          if name=$(fm_harness_argv_path_name "$script"); then
            case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
            return 0
          fi
        done
      fi
      ;;
  esac
  # Node renames its own main thread, so an npm-installed harness can report
  # `MainThread` as its exec name and carry no interpreter name for the case
  # above to catch: codex-cli 0.139.0 under nvm on Linux reports comm
  # `MainThread` with argv `node .../bin/codex`, and without this it is not a
  # harness at all, which leaves a codex primary unable to acquire its own home.
  #
  # Identity then has to come from the interpreter's SCRIPT PATH, and the ONLY
  # candidate is the single token immediately after the interpreter, matched by
  # the strictest rule this file has, exact basename. `MainThread` is a name any
  # node program can present, and the rest of an interpreter's argv is not the
  # script: it also carries the values of the interpreter's own flags, and those
  # values are paths that can be named anything, `/opt/vendor/claude` included.
  #
  # So the branch REFUSES to identify anything as soon as that first token is a
  # flag, rather than trying to work out where the flags end. An interpreter that
  # reports its own name is decided by the rule above, which stops at the first
  # flag in the same way but reads every token up to it, by whole path component
  # rather than by basename. Neither reading reaches the cohort's acceptance
  # decision, which fm_harness_exec_kind settles from executable identity alone.
  #
  # The refusal gives up the inferred `node --enable-source-maps .../bin/codex`
  # shape on purpose: the alternative is an allowlist of value-taking interpreter
  # flags, which would rot silently every time a vendor adds one, and silently
  # stale recorded state is the exact failure this whole mechanism exists to
  # remove. Refusing to guess is the intended behaviour, and only the plain
  # `node <script>` shape - the one actually observed from a real codex install -
  # is identified here.
  if [ "$base" = MainThread ]; then
    script=${args#* }
    if [ "$script" != "$args" ]; then
      script=${script%% *}
      case "$script" in
        -*) : ;;
        */*)
          if name=$(fm_harness_basename_name "$script"); then
            case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
            return 0
          fi
          ;;
      esac
    fi
  fi
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  if fm_cursor_process_matches "$comm" "$args" "$argv0"; then
    return 0
  fi
  return 1
}

# Print the harness name that the EXECUTABLE IDENTITY of command name $1 with
# argument string $2 names, or return 1.
#
# The strict reading, and the only one the cohort proof below is allowed to use:
# the reported command name's own basename is exactly a verified harness name, or
# a whole path component of that command name or of argv[0] is. An argument list
# is never read here.
#
# The cohort needs identity, and an argument list does not carry identity. A
# launch marker proves a LAUNCH relationship and nothing more, so a codex session
# the captain started from inside a Claude session carries a truthful CLAUDE_PID
# naming that Claude holder. The evidence for that pair and for the rehosted
# Claude background session the marker path exists to accept is otherwise
# identical - same marker, same value, same container, holder outside the asking
# ancestry in both - and the process name is the only thing that differs. So the
# name has to be the thing the acceptance turns on, and it has to come from what
# the process IS rather than from a path it was handed on its command line.
fm_harness_exec_kind() {  # <comm> <args>
  local comm=$1 args=$2
  fm_harness_comm_name "$comm" && return 0
  fm_harness_path_name "$comm" && return 0
  fm_harness_path_name "${args%% *}"
}

# Print the harness name live pid $1 is running as under that strict reading, or
# return 1. Always call it through a command substitution.
fm_harness_pid_kind() {  # <pid>
  local pid=$1 comm args kind
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  kind=$(fm_harness_exec_kind "$comm" "$args") || return 1
  [ -n "$kind" ] || return 1
  printf '%s\n' "$kind"
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
    if fm_harness_process_matches "$comm" "$args" >/dev/null; then
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

# Classify recorded pid $1 and print exactly one of three words. This is the
# single place the question is answered, so no caller can ask it a second time
# and disagree with the classification that already ran about a holder that died
# in between.
#
#   gone          not a live process, or it vanished before its command NAME
#                 could be read
#   unidentified  a live process whose command WAS read and which the identity
#                 rules above then declined to type as a harness
#   harness       a live process typed as a harness
#
# The middle word exists because those first two are not the same event for a
# pid recorded in a session lock: reclaiming a holder that is simply gone has
# always been silent, while reclaiming one that is still visibly running has to
# be able to name itself.
#
# The `gone` verdict is NOT complete, and that is stated here rather than left
# to read as closed. A process that disappears before its command NAME can be
# read is caught and stays silent, but the argument list is read separately and
# its status is discarded, so a holder that exits in the window between those
# two reads is classified from the command name alone - and for the bare
# interpreter shape this whole distinction exists for, that yields
# `unidentified` and mislabels an otherwise-silent acquisition line. The window
# is left open because both available tightenings are worse than a wrong clause:
# reading a failed argument list as `gone` would SILENTLY reclaim a live harness
# holder's home wherever `ps -o args=` fails while `ps -o comm=` succeeds, and
# re-probing liveness after the read is the duplicate liveness question this
# single classifier exists to prevent. The verdict, the reclaim, and which
# session wins are identical either way.
fm_harness_pid_state() {  # <pid>
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || { printf 'gone\n'; return 0; }
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || { printf 'gone\n'; return 0; }
  [ -n "$comm" ] || { printf 'gone\n'; return 0; }
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  if fm_harness_process_matches "$comm" "$args" >/dev/null; then
    printf 'harness\n'
  else
    printf 'unidentified\n'
  fi
}

# True if $1 is a live process that looks like a verified harness.
# Pure liveness: a STOPPED harness satisfies this, because it exists. Whether a
# stopped holder still holds the lock is a separate question, decided by
# fm_harness_pid_suspended and fm_session_lock_holder_competes below.
fm_harness_pid_alive() {
  [ "$(fm_harness_pid_state "$1")" = harness ]
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
# Each row is "<harness> <var>": the harness that was VERIFIED to export it, and
# the variable. The harness column is load-bearing, not documentation. A marker
# variable is an ordinary environment variable, so every descendant of a session
# inherits it, including a different harness the captain started from inside that
# session. Scoping each row to its own harness is what stops that inherited value
# being read as a launch relationship between two genuinely separate sessions.
#
# SCOPE LIMIT, stated because it is easy to assume away: this table has exactly
# ONE row, so the cohort proof below can only ever fire when BOTH sides of the
# pair are Claude. codex, opencode, pi, pi-signed, grok, kimi, and cursor have no
# verified marker, so on those harnesses fm_session_lock_owned_by_self is decided
# by ancestry alone and a session the harness rehosted outside its own process
# tree still refuses its own home and degrades that session start to read-only.
# That is the unfixed half of the defect for those adapters, not a fixed one.
#
# The same unfixed half reaches Claude itself whenever a Claude session's own
# executable identity does not name it, because fm_harness_exec_kind is what
# opens the marker path and it reads only the command name and argv[0]. Two
# shapes lose the accept path and land on the ancestry-only verdict: a
# node-hosted launch identified only by its script argument, `node
# /path/to/claude/cli.js`, and an npm install reporting comm `MainThread` with
# the harness named nowhere but in argv. That is the fail-closed direction rather
# than a regression, because the alternative accepts a different harness that
# merely inherited the marker, but it is a real limit and not a closed one.
#
# One recognition limit sits underneath all of that and is stated rather than
# fixed here, and it is narrower than it first looks. The npm layout whose
# package directory is `claude-code` was observed rather than imagined: the
# install in use reports its own executable, `claude.exe` under
# .../node_modules/@anthropic-ai/claude-code/bin/, and fm_harness_comm_name types
# that by name, so for that shape the package directory never has to be read at
# all. What stays unidentified is the node-hosted variant of the same layout,
# where the command name is the interpreter or `MainThread` and `claude-code` is
# the only place the harness is named: no rule here matches a path component that
# is not exactly a harness name, so such a session resolves no harness ancestry,
# fm_session_lock_owned_by_self returns false, and its session start degrades to
# read-only against its own home - the exact false-refusal lockout this mechanism
# exists to remove. Closing it means observing the command name and argv a real
# node-hosted install reports rather than inventing them, which is the same
# verification this file demands for a marker row. The opt-in guard in
# docs/verification/runtime-backends.md records exactly that for every installed
# harness, so a real one produces the evidence a later fix needs.
#
# Why leaving it that way is safe rather than merely incomplete: a row is
# consulted only when the asking session and the holder are both the harness that
# row was verified for, so a marker a different harness merely inherited is never
# believed, and a harness with no row of its own is decided by ancestry alone. The
# alternative is worse in both directions. A guessed variable name that no harness
# sets is indistinguishable from no row, so it buys nothing while reading as
# coverage; a guessed name a harness does set for some other purpose would be
# believed, and a launch marker is one half of the proof that keeps a genuinely
# separate concurrent session out of this home.
#
# Extending it is therefore a verification task, not an editing one: observe the
# variable in a real child of a real session of that harness, add the row with
# that harness in the first column, and refresh the per-harness record in
# docs/verification/runtime-backends.md, whose opt-in guard reports the marker it
# actually observed. Do not add a row from documentation or inference.
FM_SESSION_LAUNCH_MARKERS='claude CLAUDE_PID'

# True when the table has a row for harness $1. Asking this first keeps the
# cohort proof from resolving any process kind it will not end up using.
fm_session_launch_marker_exists() {  # <harness>
  local want=$1 harness var
  [ -n "$want" ] || return 1
  while read -r harness var; do
    [ -n "$var" ] || continue
    [ "$harness" = "$want" ] && return 0
  done <<EOF
$FM_SESSION_LAUNCH_MARKERS
EOF
  return 1
}

# Print the harness session pid recorded in pid $1's inherited environment by a
# row belonging to harness $2, or return 1. A row for any other harness is not
# consulted, however present its variable happens to be in that environment.
fm_session_launcher_pid() {  # <pid> <harness>
  local pid=$1 want=$2 harness var val
  [ -n "$want" ] || return 1
  while read -r harness var; do
    [ -n "$var" ] || continue
    [ "$harness" = "$want" ] || continue
    val=$(fm_session_pid_env "$pid" "$var") || continue
    case "$val" in
      ''|*[!0-9]*) continue ;;
    esac
    printf '%s\n' "$val"
    return 0
  done <<EOF
$FM_SESSION_LAUNCH_MARKERS
EOF
  return 1
}

# Print the start time of pid $1 in clock ticks since boot, or return 1.
#
# Field 22 of /proc/<pid>/stat. It is fixed for the whole life of a pid and is
# reassigned when the pid is reused, which is what lets a marker's named pid be
# ORDERED against the process whose environment carried that marker.
#
# The parse deliberately discards everything through the LAST ')' rather than
# taking field 22 of the raw line. Field 2 is the command name in parentheses and
# it CAN contain spaces, which shifts every later field: a real background worker
# reports `<pid> (claude bg-pty-h) S ...`, where a whole-line field 22 reads 0.
# Zero is the earliest start time expressible, so it would satisfy every forward
# comparison below - a silent fail-open on exactly the process shape this file
# exists to identify. Do not simplify this back to a whole-line field index.
#
# FM_PROC_ROOT_OVERRIDE is honoured exactly as fm_session_pid_env honours it, so
# one fixture drives both reads.
fm_session_pid_start_time() {  # <pid>
  local pid=$1 proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} raw rest value
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  raw=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
  case "$raw" in
    *')'*) rest=${raw##*)} ;;
    *) return 1 ;;
  esac
  value=$(printf '%s\n' "$rest" | awk '{print $20}')
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$value"
}

# True when a marker naming pid $2 could actually have been carried by pid $1.
#
# ONE invariant, applied at every site a marker is accepted rather than as two
# rules that can drift apart: A MARKER'S NAMED PID MUST NOT HAVE STARTED AFTER
# THE PROCESS WHOSE ENVIRONMENT CARRIED IT. A launcher necessarily exists before
# anything that inherited its environment, so this is a monotonic fact about the
# pair rather than another name heuristic, and it is precisely what numeric
# equality cannot tell: an environment snapshot naming pid 100 says nothing about
# whether the process now holding pid 100 is the one it named.
#
# Callers supply the ACTUAL carrier, never $$ blindly, so the one invariant
# produces both directions. Forward, where our own marker names the holder, the
# carrier is this process or the ancestry member whose environ was read and the
# holder must predate it. Reverse, where the holder's marker names us, the
# carrier is the holder and the pid it names must predate the holder.
#
# The comparison is <=, not strict <. Clock ticks are coarse - commonly 10ms - so
# a real launcher and the child it spawns can land on one tick value, and
# refusing those would be a false refusal of a legitimate launch, which is the
# failure class this whole mechanism exists to remove.
#
# Either start time being unreadable or unparseable REFUSES the relationship,
# which degrades this path to the ancestry verdict rather than handing the home
# to a session that merely inherited a recycled pid.
fm_session_marker_ordered() {  # <carrier-pid> <named-pid>
  local carrier named
  carrier=$(fm_session_pid_start_time "$1") || return 1
  named=$(fm_session_pid_start_time "$2") || return 1
  [ "$named" -le "$carrier" ]
}

# True when live harness pid $1 is this process's OWN session reached through a
# different process tree, recording the evidence in FM_SESSION_COHORT_EVIDENCE.
#
# TWO independent signals from different sources must BOTH hold, so that neither
# is load-bearing on its own and the absence of either falls back to the
# ancestry verdict rather than opening ownership up:
#
#   1. Relationship, satisfied by EITHER direction of one launch pair, and only
#      between two sessions of the SAME harness: the marker row consulted is the
#      one belonging to the holder's own harness, and it is consulted only when
#      that harness also appears in this session's harness ancestry, because a
#      marker variable is inherited by every descendant including a different
#      harness the captain started from inside that session. Forward: some
#      process in this session - this one, or a member of its harness ancestry -
#      carries that marker naming the holder as the harness session that started
#      it. Reverse: the holder's own exec-time marker names this process or a
#      member of this session's harness ancestry. Both
#      directions are required because acquisition converges the lock onto the
#      acquiring session's own pid, so either member of a launcher/launched pair
#      can end up recorded as the holder while the other one asks; testing only
#      the forward direction would move the read-only degradation onto the
#      launching session instead of removing it. Either way this is what makes
#      the holder OUR session rather than merely a neighbour, and it is the
#      signal the process tree destroys when a harness rehosts a session under
#      its own pty and the tree reparents to init. Either direction must also be
#      ORDERED, per fm_session_marker_ordered above: the pid a marker names must
#      not have started after the process that carried that marker, which is what
#      stops a recycled pid from satisfying a stale marker.
#   2. Co-location. Both processes are in the same innermost runtime container,
#      or on the same controlling terminal. Two providers, either sufficient,
#      because a rehosted session keeps its pane and loses its terminal.
#
# Requiring the relationship is what preserves the property the lock exists for.
# Co-location alone would accept a genuinely separate session that merely shares
# a pane - a second agent started by hand in the captain's own terminal is
# exactly that, and it must still be refused.
#
# The two signals are NOT fully independent under pid recycling, and that is
# stated rather than implied away. A marker is an environment snapshot taken at
# exec time and matched against the holder by numeric equality, so a marker
# naming pid 100 keeps matching once pid 100 has been recycled onto an unrelated
# session of the same harness: the relationship itself is stale-satisfied there,
# and co-location alone would be what was left. What restores the relationship's
# meaning is the start-time ordering every acceptance site below requires, since
# a recycled occupant started after the process that carried the marker and so
# cannot be the launcher that marker names.
# $2 and $3 are internal fast paths for callers that have already done the same
# work, and change no verdict: $2 is this session's harness ancestry when the
# caller has already resolved it, and $3 is 1 only when the caller has already
# proven the holder is a live harness. Every other caller passes one argument and
# gets both checks here, so the liveness precondition still runs before any
# recorded identity of the holder is consulted in either direction.
FM_SESSION_COHORT_EVIDENCE=
fm_session_same_cohort() {  # <pid> [<ancestry-pids>] [<holder-alive-verified>]
  local pid=$1 pids=${2-} verified=${3:-0} mine theirs member launcher kind
  local related=0 relation='' located='' same_kind=0
  FM_SESSION_COHORT_EVIDENCE=
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  # A dead or recycled pid must never be matched, so the holder has to be a live
  # harness before any of its recorded identity is consulted.
  if [ "$verified" != 1 ]; then
    fm_harness_pid_alive "$pid" || return 1
  fi

  # The harness kind of BOTH sides has to be settled before any marker is read,
  # so this session's ancestry is resolved first even on the call path that did
  # not pass it in. An asking side with no resolvable harness ancestry gets no
  # marker path at all: ownership stays a claim only a harness session can make,
  # never one an ordinary script sharing the captain's terminal can make.
  if [ -z "$pids" ]; then
    pids=$(fm_harness_ancestry_pids 2>/dev/null || true)
  fi
  [ -n "$pids" ] || return 1

  # The holder's kind comes from the holder itself, captured at its own match.
  # This session's kind comes from its harness ANCESTRY rather than from the pid
  # whose environment is read, because that pid is an ordinary shell which merely
  # inherited the marker. Requiring the row's harness on both sides is what stops
  # a marker one harness exported from being believed by another that inherited
  # it, which would let a second, genuinely separate session take this home.
  kind=$(fm_harness_pid_kind "$pid" 2>/dev/null || true)
  fm_session_launch_marker_exists "$kind" || return 1
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    if [ "$(fm_harness_pid_kind "$member" 2>/dev/null || true)" = "$kind" ]; then
      same_kind=1
      break
    fi
  done <<EOF
$pids
EOF
  [ "$same_kind" -eq 1 ] || return 1

  launcher=$(fm_session_launcher_pid "$$" "$kind" 2>/dev/null || true)
  if [ "$launcher" = "$pid" ] && fm_session_marker_ordered "$$" "$pid"; then
    related=1
    relation="launched this session"
  fi
  if [ "$related" -eq 0 ]; then
    while IFS= read -r member; do
      [ -n "$member" ] || continue
      launcher=$(fm_session_launcher_pid "$member" "$kind" 2>/dev/null || true)
      if [ "$launcher" = "$pid" ] && fm_session_marker_ordered "$member" "$pid"; then
        related=1
        relation="launched this session"
        break
      fi
    done <<EOF
$pids
EOF
  fi
  if [ "$related" -eq 0 ]; then
    launcher=$(fm_session_launcher_pid "$pid" "$kind" 2>/dev/null || true)
    if [ -n "$launcher" ] && fm_session_marker_ordered "$pid" "$launcher"; then
      if [ "$launcher" = "$$" ]; then
        related=1
      else
        while IFS= read -r member; do
          [ -n "$member" ] || continue
          if [ "$launcher" = "$member" ]; then
            related=1
            break
          fi
        done <<EOF
$pids
EOF
      fi
      if [ "$related" -eq 1 ]; then
        relation="was launched by this session"
      fi
    fi
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

  FM_SESSION_COHORT_EVIDENCE="$relation; $located"
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
#
# The verdict fails CLOSED - NOT suspended - on every state it cannot confirm,
# because reporting a live holder as suspended is what lets an acquisition take
# over a genuinely separate concurrent session's home. So the sample count and
# the gap between samples reject empty, non-numeric and zero values back to their
# defaults instead of being trusted from the environment, an unreadable process
# state is not a stop, and a sample sequence that cannot be completed is not a
# confirmation.
FM_SESSION_STOP_SAMPLES_DEFAULT=3
FM_SESSION_STOP_SAMPLE_SLEEP_DEFAULT=0.2
FM_SESSION_STOP_SAMPLES=${FM_SESSION_STOP_SAMPLES:-$FM_SESSION_STOP_SAMPLES_DEFAULT}
FM_SESSION_STOP_SAMPLE_SLEEP=${FM_SESSION_STOP_SAMPLE_SLEEP:-$FM_SESSION_STOP_SAMPLE_SLEEP_DEFAULT}
fm_harness_pid_suspended() {  # <pid>
  local pid=$1 samples nap i=0 confirmed=0 state
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  samples=${FM_SESSION_STOP_SAMPLES:-$FM_SESSION_STOP_SAMPLES_DEFAULT}
  case "$samples" in
    ''|*[!0-9]*|0) samples=$FM_SESSION_STOP_SAMPLES_DEFAULT ;;
  esac
  # The gap is a fractional number of seconds, so it also has to admit one
  # decimal point while still rejecting any zero-valued gap, which would collapse
  # the confirmation window a momentary stop is separated by.
  nap=${FM_SESSION_STOP_SAMPLE_SLEEP:-$FM_SESSION_STOP_SAMPLE_SLEEP_DEFAULT}
  case "$nap" in
    ''|.|*[!0-9.]*|*.*.*) nap=$FM_SESSION_STOP_SAMPLE_SLEEP_DEFAULT ;;
    *)
      case "${nap//./}" in
        *[!0]*) : ;;
        *) nap=$FM_SESSION_STOP_SAMPLE_SLEEP_DEFAULT ;;
      esac
      ;;
  esac
  while [ "$i" -lt "$samples" ]; do
    state=$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    case "$state" in
      T*) confirmed=$((confirmed + 1)) ;;
      *) return 1 ;;
    esac
    i=$((i + 1))
    if [ "$i" -lt "$samples" ]; then
      sleep "$nap" || return 1
    fi
  done
  [ "$confirmed" -gt 0 ] && [ "$confirmed" -eq "$samples" ]
}

# True when session-lock holder $1 is a COMPETING session the caller must yield
# to. This is the question every caller of the old bare liveness check was
# actually asking, and it is the single owner of the answer.
#
# Not competing: a pid that is gone, a live pid the identity rules decline to
# type as a harness, a pid in this process's own session cohort, and a durably
# suspended harness. Everything else is.
#
# FM_SESSION_HOLDER_YIELD_REASON is a whole clause rather than a noun phrase,
# because those cases are not the same event and a caller that prefixed one
# verb onto all of them would report the cohort case - one session converging its
# own lock onto its own pid - as a home changing hands.
#
# Only the GONE case leaves it EMPTY, because reclaiming a holder that no longer
# exists has always been silent and is the ordinary path every session start
# takes. The other three reclaim a process that was still present when the
# classification read it, so each says so. The verdict and the reason both come
# from ONE classification of the recorded pid, so a caller cannot ask the
# liveness question again and disagree with this one about a holder that died in
# between. That classification's own gone-versus-unidentified limit is open
# rather than closed, and fm_harness_pid_state's header above is the single
# owner of the statement of it rather than this one repeating it.
# shellcheck disable=SC2034 # Read by bin/fm-lock.sh to report why it did not yield.
FM_SESSION_HOLDER_YIELD_REASON=
fm_session_lock_holder_competes() {  # <pid>
  local pid=$1 state
  FM_SESSION_HOLDER_YIELD_REASON=
  state=$(fm_harness_pid_state "$pid")
  if [ "$state" = gone ]; then
    return 1
  fi
  if [ "$state" != harness ]; then
    # shellcheck disable=SC2034 # Read by bin/fm-lock.sh to report why it did not yield.
    FM_SESSION_HOLDER_YIELD_REASON="reclaimed from pid $pid, which is alive but not recognised as a harness"
    return 1
  fi
  if fm_session_same_cohort "$pid" '' 1; then
    FM_SESSION_HOLDER_YIELD_REASON="converged onto this session's own holder pid $pid ($FM_SESSION_COHORT_EVIDENCE)"
    return 1
  fi
  if fm_harness_pid_suspended "$pid"; then
    # shellcheck disable=SC2034 # Read by bin/fm-lock.sh to report why it did not yield.
    FM_SESSION_HOLDER_YIELD_REASON="took over from suspended harness pid $pid"
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
  fm_session_same_cohort "$lock_pid" "$pids"
}
