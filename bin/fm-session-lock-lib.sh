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

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# --- session-lock PID-reuse hardening ---------------------------------------
#
# state/.lock itself stays a bare one-line pid (bin/fm-lock.sh writes it), so
# the dozen-plus call sites across the fleet that read it with a plain `cat`
# expecting exactly one numeric line - bin/fm-sessionstart-run.sh,
# bin/fm-bootstrap.sh, bin/fm-startup-network.sh, bin/fm-session-start.sh,
# bin/fm-turnend-guard-cursor.sh's OWNER_ID, and others - never change. A
# companion sidecar, state/.lock-identity, instead records the process-start
# identity (fm_pid_identity, bin/fm-wake-lib.sh) of whichever pid state/.lock
# currently names, mirroring the hardening bin/fm-wake-lib.sh already applies
# to state/.watch.lock (fm_watcher_lock_matches_pid) and
# state/.claude-autoarm-epoch (fm_autoarm_claim_open) - both of which record
# and verify this same identity to survive a dead owner's pid being reused by
# an unrelated live process. Format, four lines, written via tmp+rename:
#   owner_pid=<pid>
#   <fm_pid_identity output for that pid>
#   token=<unique per-acquisition token>
#   heartbeat_at=<unix seconds of the last renewal>
# The sidecar is self-describing (it names the pid it is evidence for) so a
# reader never depends on write ordering relative to state/.lock: a sidecar
# whose owner_pid no longer matches the pid being tested is simply ignored,
# exactly like a missing sidecar. Best effort throughout: a platform where
# fm_pid_identity cannot resolve (no /proc, ps failure) leaves no evidence,
# and every consumer treats missing evidence as neither proof of life nor
# proof of death - it falls back to the plain fm_harness_pid_alive check that
# was this decision's whole story before this sidecar existed.
#
# token distinguishes a genuine new acquisition from a heartbeat renewal of
# the SAME ownership: fm_session_lock_write_identity mints a fresh one only
# when a pid actually newly acquires state/.lock, and fm_session_lock_renew_
# heartbeat, called from the routine per-turn touchpoints in
# bin/fm-claude-stop-autoarm.sh and bin/fm-turnend-guard-cursor.sh, re-verifies
# the recorded pid+identity first and then rewrites heartbeat_at alone,
# carrying the same token forward untouched. A sidecar missing the token or
# heartbeat_at fields (an older-format sidecar, or one written mid-upgrade)
# is treated exactly like a missing sidecar for that field's own check: never
# proof of death, only a disabled hardening layer.
#
# heartbeat_at backs a THIRD, independent reclaim condition alongside dead-pid
# and identity-mismatch: fm_session_lock_pid_verified_alive also returns false
# once heartbeat_at is older than FM_SESSION_LOCK_LEASE_GRACE (default 21600s
# = 6h), so a genuinely alive, identity-matched owner that has stopped
# renewing its lease - the rarer "hung but alive forever" failure mode, as
# opposed to the dead/reused-pid failure this hardening was first built for -
# is still eventually reclaimable. This grace is deliberately far looser than
# FM_GUARD_GRACE (default 300s, the watcher-beacon and autoarm-epoch staleness
# window used elsewhere in this fleet): a firstmate primary session is
# long-lived and interactive with legitimately unbounded idle gaps between
# turns, so copying the watcher/autoarm grace verbatim would false-evict a
# session that is simply waiting on the next captain message. Nothing renews
# the heartbeat while idle between turns; it renews at the next Stop/park
# event, which is exactly the boundary a hung, unresponsive session can never
# reach.

# fm_session_lock_write_identity <state> <pid>
# Best-effort: record process-start identity for <pid>, the pid about to hold
# (or already holding) state/.lock, so a later reclaim decision elsewhere can
# distinguish it from an unrelated process later assigned the same pid. Mints
# a FRESH token: call this only for a genuine new acquisition, never to renew
# an existing ownership's lease (fm_session_lock_renew_heartbeat does that,
# preserving the token). Never a hard failure for the caller: bin/fm-lock.sh's
# actual lock write is authoritative regardless of whether this best-effort
# sidecar succeeds.
fm_session_lock_write_identity() {  # <state> <pid>
  local state=$1 pid=$2 identity now token tmp
  identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -n "$identity" ] || return 1
  now=$(date +%s 2>/dev/null) || now=0
  token="${pid}.${now}.${BASHPID:-$$}.${RANDOM:-0}.${RANDOM:-0}"
  tmp="$state/.lock-identity.tmp.${BASHPID:-$$}"
  if ! { printf 'owner_pid=%s\n%s\ntoken=%s\nheartbeat_at=%s\n' "$pid" "$identity" "$token" "$now"; } > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$state/.lock-identity" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  return 0
}

# fm_session_lock_renew_heartbeat <state> <pid>
# Renew the lease on an ownership that already exists: re-derive the sidecar's
# own recorded owner_pid, identity, and token - never trust a caller-supplied
# value for any of them - and refuse unless they still describe <pid> exactly
# as it stands right now, then rewrite only heartbeat_at, carrying the same
# token forward. Called from the routine per-turn touchpoints (Claude Stop,
# Cursor park) of a session that already owns its lock, so a healthy, still-
# owning session is never evicted by FM_SESSION_LOCK_LEASE_GRACE merely for
# having gone quiet between turns.
fm_session_lock_renew_heartbeat() {  # <state> <pid>
  local state=$1 pid=$2 sidecar recorded_owner recorded_identity token current_identity now tmp
  sidecar="$state/.lock-identity"
  [ -r "$sidecar" ] || return 1
  recorded_owner=$(sed -n '1s/^owner_pid=//p' "$sidecar" 2>/dev/null || true)
  [ "$recorded_owner" = "$pid" ] || return 1
  recorded_identity=$(sed -n '2p' "$sidecar" 2>/dev/null || true)
  [ -n "$recorded_identity" ] || return 1
  token=$(sed -n '3s/^token=//p' "$sidecar" 2>/dev/null || true)
  [ -n "$token" ] || return 1
  current_identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$current_identity" = "$recorded_identity" ] || return 1
  now=$(date +%s 2>/dev/null) || return 1
  tmp="$state/.lock-identity.tmp.${BASHPID:-$$}"
  if ! { printf 'owner_pid=%s\n%s\ntoken=%s\nheartbeat_at=%s\n' "$pid" "$recorded_identity" "$token" "$now"; } > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$sidecar" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  return 0
}

# fm_session_lock_release <state> <pid>
# Token-gated release for a normal exit: remove state/.lock and its identity
# sidecar only when <pid> is THIS process (fm_current_pid) and the sidecar's
# own recorded owner_pid, identity, and token still describe it - never a
# bare pid-number check, so a late release call from a process that has
# already been superseded (its old pid reused, or a successor already
# reclaimed and rewrote the sidecar with a fresh token) can never remove a
# successor's live lock. Refuses on any mismatch, a missing sidecar, or a
# sidecar with no token (an older-format record this process itself could
# not have written). No call site invokes this yet: this harness surface has
# no session-exit lifecycle hook to call it from, so it is the primitive
# alone, tested in isolation, pending that separate hook-wiring change.
fm_session_lock_release() {  # <state> <pid>
  local state=$1 pid=$2 self sidecar recorded_owner recorded_identity token current_identity lock_pid
  fm_current_pid self || return 1
  [ "$self" = "$pid" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  [ "$lock_pid" = "$pid" ] || return 1
  sidecar="$state/.lock-identity"
  [ -r "$sidecar" ] || return 1
  recorded_owner=$(sed -n '1s/^owner_pid=//p' "$sidecar" 2>/dev/null || true)
  [ "$recorded_owner" = "$pid" ] || return 1
  recorded_identity=$(sed -n '2p' "$sidecar" 2>/dev/null || true)
  [ -n "$recorded_identity" ] || return 1
  token=$(sed -n '3s/^token=//p' "$sidecar" 2>/dev/null || true)
  [ -n "$token" ] || return 1
  current_identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$current_identity" = "$recorded_identity" ] || return 1
  rm -f "$sidecar" 2>/dev/null
  rm -f "$state/.lock" 2>/dev/null
  return 0
}

# fm_session_lock_pid_verified_alive <state> <pid>
# The PID-reuse-hardened replacement for a bare fm_harness_pid_alive check at
# a reclaim decision. True when <pid> is alive AND either no identity
# evidence exists for it (a missing sidecar, or one whose recorded owner_pid
# does not match <pid> - a stale leftover from a prior owner) - the same
# conservative "still defer to it" answer fm_harness_pid_alive alone always
# gave - or the recorded identity for <pid> matches its CURRENT live
# identity AND its recorded lease has not expired. False when <pid> is dead,
# when identity evidence for exactly this pid is present and proves a
# mismatch (a reused pid), OR when heartbeat_at is present and older than
# FM_SESSION_LOCK_LEASE_GRACE - a live, identity-matched owner that has
# stopped renewing its lease is still eventually reclaimable. Missing
# identity OR heartbeat evidence never turns a live pid into a reclaimable
# one - each missing field only disables that field's own hardening, the
# same "never block on absent evidence" contract bin/fm-wake-lib.sh's legacy
# autoarm-abandonment proof uses.
fm_session_lock_pid_verified_alive() {  # <state> <pid>
  local state=$1 pid=$2 sidecar recorded_owner recorded_identity current_identity
  local heartbeat_at grace now
  fm_harness_pid_alive "$pid" || return 1
  sidecar="$state/.lock-identity"
  [ -r "$sidecar" ] || return 0
  recorded_owner=$(sed -n '1s/^owner_pid=//p' "$sidecar" 2>/dev/null || true)
  [ "$recorded_owner" = "$pid" ] || return 0
  recorded_identity=$(sed -n '2p' "$sidecar" 2>/dev/null || true)
  [ -n "$recorded_identity" ] || return 0
  current_identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 0
  [ -n "$current_identity" ] || return 0
  [ "$current_identity" = "$recorded_identity" ] || return 1
  heartbeat_at=$(sed -n '4s/^heartbeat_at=//p' "$sidecar" 2>/dev/null || true)
  case "$heartbeat_at" in
    ''|*[!0-9]*) return 0 ;;
  esac
  grace=${FM_SESSION_LOCK_LEASE_GRACE:-21600}
  case "$grace" in ''|*[!0-9]*) grace=21600 ;; esac
  now=$(date +%s 2>/dev/null) || return 0
  [ $((now - heartbeat_at)) -lt "$grace" ]
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
