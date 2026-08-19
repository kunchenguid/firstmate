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
# The strictest of this file's path rules, and used by the `MainThread` branch
# below and nowhere else. That branch has exactly one token of evidence, so it
# takes the strictest reading of it; the sibling interpreter branch reads the same
# token positions under the same stop-at-the-first-flag rule but by whole path
# component, because the only shape it identifies at all is a node-hosted bin
# entry that is NOT named after the harness.
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

# Print the first verified harness name that appears anywhere in string $1, or
# return 1.
#
# This NAMES a match one of the rules below already made; it never decides one,
# and it is only ever handed the one string that match was made against - the
# reported command basename. Over a whole argument string it would outrank the
# token that actually matched and name a harness by table order instead: in
# `node /opt/tools/codex/cli.js --config /etc/claude/x.toml` the first name it
# reaches is claude. Every other rule therefore names its own match from the exact
# path or basename that decided it.
#
# The name is what scopes FM_SESSION_LAUNCH_MARKERS below to the harness whose
# marker was actually verified, so a rule that matched cannot lend its verdict to
# a different harness's marker.
fm_harness_name_in() {  # <string>
  local text=$1 name
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "$text" in
      *"$name"*) printf '%s' "$name"; return 0 ;;
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
# FM_HARNESS_KIND names WHICH harness matched, alongside the FM_HARNESS_IS_CLAUDE
# flag the ancestry walk needs. Both are globals every call clobbers, so a caller
# that needs the kind of a particular pid must capture it at the point of the
# match: fm_harness_pid_kind below is that capture, and reading the global after
# any other matcher call has run in between reads the wrong process's kind.
FM_HARNESS_IS_CLAUDE=0
FM_HARNESS_KIND=
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name script rest
  FM_HARNESS_IS_CLAUDE=0
  FM_HARNESS_KIND=
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    FM_HARNESS_KIND=$(fm_harness_name_in "$base" || true)
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    FM_HARNESS_KIND=$name
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
          if name=$(fm_harness_path_name "$script"); then
            case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
            FM_HARNESS_KIND=$name
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
  # flag in the same way but reads whole path components rather than a basename.
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
            FM_HARNESS_KIND=$name
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
    FM_HARNESS_KIND=cursor
    return 0
  fi
  return 1
}

# Print the verified harness name pid $1 is running as, or return 1 when it is
# not a live harness. Always call it through a command substitution, which is the
# capture the FM_HARNESS_KIND note above requires.
fm_harness_pid_kind() {  # <pid>
  local pid=$1 comm args
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args" || return 1
  [ -n "$FM_HARNESS_KIND" ] || return 1
  printf '%s\n' "$FM_HARNESS_KIND"
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
#      its own pty and the tree reparents to init.
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
  if [ "$launcher" = "$pid" ]; then
    related=1
    relation="launched this session"
  fi
  if [ "$related" -eq 0 ]; then
    while IFS= read -r member; do
      [ -n "$member" ] || continue
      launcher=$(fm_session_launcher_pid "$member" "$kind" 2>/dev/null || true)
      if [ "$launcher" = "$pid" ]; then
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
    if [ -n "$launcher" ]; then
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
# Not competing: a dead or non-harness pid, a pid in this process's own session
# cohort, and a durably suspended harness. Everything else is.
#
# FM_SESSION_HOLDER_YIELD_REASON is a whole clause rather than a noun phrase,
# because the three cases are not the same event and a caller that prefixed one
# verb onto all of them would report the cohort case - one session converging its
# own lock onto its own pid - as a home changing hands.
#
# The dead or non-harness case leaves it EMPTY, because reclaiming that holder has
# always been silent. That keeps one classification deciding both the verdict and
# whether there is anything to say about it, so a caller cannot ask the liveness
# question a second time and disagree with this one about a holder that died in
# between.
# shellcheck disable=SC2034 # Read by bin/fm-lock.sh to report why it did not yield.
FM_SESSION_HOLDER_YIELD_REASON=
fm_session_lock_holder_competes() {  # <pid>
  local pid=$1
  FM_SESSION_HOLDER_YIELD_REASON=
  if ! fm_harness_pid_alive "$pid"; then
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
