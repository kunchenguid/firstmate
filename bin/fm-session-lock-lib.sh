#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-sessionstart-nudge.sh uses it to recognize a completed session start;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
#
# state/.lock remains one numeric harness pid for cross-harness liveness.
# Codex 0.146.0 launches each command as a separate POSIX session/process-group
# leader but injects a distinct stable CODEX_THREAD_ID into every command child.
# A Codex acquisition therefore also publishes state/.lock.codex-thread as
# "<lock-pid>:<thread-id>". When that sidecar exists, ownership requires its
# regular non-symlink shape, its pid to match state/.lock, its thread id to match
# the current command environment, the numeric holder to remain a live verified
# harness, and any resolvable harness ancestry to still name that same holder.
# The sidecar narrows ancestry instead of replacing it: only a command whose
# harness ancestry cannot be resolved at all may rely on the thread id alone, so
# an unrelated harness nested inside a Codex session never inherits ownership
# from the environment. A mismatch fails closed instead of falling back to
# ancestry, and the holder's own next acquisition rebinds the sidecar so a Codex
# process that moved to another thread recovers instead of staying read-only.
# Locks without the sidecar retain the verified ancestry behavior for older
# Codex sessions and every other harness.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# Print the validated Codex thread id. Command children are the empirically
# verified carriers of this variable; any other child shape that never receives
# it simply fails closed to the ancestry contract.
# Codex uses lowercase UUID-shaped ids. Treat every other shape as absent so
# malformed ambient state can never become lock authority. The match is anchored
# against the whole value, not per line, so an embedded newline cannot smuggle a
# UUID-shaped line past validation.
fm_codex_thread_id() {
  local thread_id=${CODEX_THREAD_ID:-}
  [[ $thread_id =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || return 1
  printf '%s\n' "$thread_id"
}

# Walk the current process ancestry (up to 16 hops) and print a harness pid.
# For every harness except Claude, the first match wins (innermost pid), which
# is where e.g. Pi's shared signed-wrapper ancestry actually holds the session:
# a "pi-signed" launcher can be the direct parent of the inner "pi" engine
# pid that owns the lock, and the wrapper pid above it is not that owner.
# Claude Code's bg-spare hook worker chain is the opposite shape: it nests
# several claude-named processes directly parent-child with no non-harness
# process between them, and the lock is held by the outermost pid of that
# run. So once a claude-named match is found, this keeps walking past it
# looking for a still-more-ancestral claude-named match, and stops the
# instant a non-match follows - never walking past that gap to an unrelated
# claude-named process further up the real process tree (e.g. the live
# session that launched a test as its own subprocess). The harness pid lives
# as long as the session, unlike the transient subshell pid of any one tool
# call.
fm_harness_ancestry_pid() {
  local pid=$$ comm args best='' bc extending=0 hit=0 is_claude=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    bc=$(basename -- "$comm")
    hit=0; is_claude=0
    if printf '%s' "$bc" | grep -qE "$FM_HARNESS_RE"; then
      hit=1
      case "$bc" in *claude*) is_claude=1 ;; esac
    else
      # Bare interpreter (e.g. node): match the harness name in its script path.
      case "$comm" in
        *node*|*python*)
          if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
            hit=1
            case "$args" in *claude*) is_claude=1 ;; esac
          fi
          ;;
      esac
    fi
    if [ "$hit" -eq 1 ]; then
      best="$pid"
      if [ "$is_claude" -eq 1 ]; then
        extending=1
      else
        break
      fi
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ -n "$best" ] && { echo "$best"; return 0; }
  return 1
}

# True if $1 is a live process whose command name matches ERE $2, or whose
# script path matches it when the command is a bare interpreter. ONE owner of
# the "is this pid still that harness?" probe, so the generic and Codex-specific
# callers below cannot drift apart.
fm_pid_alive_matching() {
  local pid=$1 re=$2 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  if printf '%s' "$(basename -- "$comm")" | grep -qE "$re"; then
    return 0
  fi
  case "$comm" in
    *node*|*python*)
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      printf '%s' "$args" | grep -qE "$re"
      ;;
    *) return 1 ;;
  esac
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  fm_pid_alive_matching "$1" "$FM_HARNESS_RE"
}

# True if $1 is the live Codex harness process that may be paired with a
# CODEX_THREAD_ID sidecar. A thread id inherited by another nested harness is
# not enough to make that harness a Codex lock owner.
fm_codex_pid_alive() {
  fm_pid_alive_matching "$1" 'codex'
}

# Print the "<pid>:<thread-id>" payload of state dir $1's Codex identity sidecar
# when it is a usable regular file carrying exactly the published shape; fail
# closed on anything else. ONE owner of the sidecar's on-disk format, so the
# ownership predicate and the human-facing status line cannot disagree about
# which files are well-formed.
fm_codex_lock_identity_read() {
  local state=$1 identity_file identity identity_pid
  identity_file="$state/.lock.codex-thread"
  [ -f "$identity_file" ] && [ ! -L "$identity_file" ] || return 1
  identity=$(cat "$identity_file" 2>/dev/null) || return 1
  case "$identity" in
    *$'\n'*|*:*:*) return 1 ;;
    *:*) ;;
    *) return 1 ;;
  esac
  identity_pid=${identity%%:*}
  case "$identity_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$identity"
}

# True when $1/.lock.codex-thread securely binds numeric lock pid $2 to this
# command's Codex thread id.
fm_codex_lock_identity_matches() {
  local state=$1 lock_pid=$2 identity identity_pid identity_thread thread_id
  identity=$(fm_codex_lock_identity_read "$state") || return 1
  identity_pid=${identity%%:*}
  identity_thread=${identity#*:}
  thread_id=$(fm_codex_thread_id) || return 1
  [ "$identity_pid" = "$lock_pid" ] \
    && [ "$identity_thread" = "$thread_id" ] \
    && fm_codex_pid_alive "$lock_pid"
}

# Print one human-facing line describing state dir $1's Codex identity sidecar
# against numeric lock pid $2: whether it exists, whether its pid agrees with
# state/.lock, and whether its thread id is this command's. Read-only diagnosis
# of the state that makes ownership fail closed - it never grants ownership and
# never changes any file, so callers still decide with
# fm_session_lock_owned_by_self.
fm_session_lock_identity_status() {
  local state=$1 lock_pid=$2 identity_file identity identity_pid identity_thread thread_id
  identity_file="$state/.lock.codex-thread"
  if [ ! -e "$identity_file" ] && [ ! -L "$identity_file" ]; then
    printf 'identity: codex sidecar absent; harness ancestry decides ownership\n'
    return 0
  fi
  if ! identity=$(fm_codex_lock_identity_read "$state"); then
    printf 'identity: codex sidecar unusable; ownership fails closed until reacquisition\n'
    return 0
  fi
  identity_pid=${identity%%:*}
  identity_thread=${identity#*:}
  if [ "$identity_pid" != "$lock_pid" ]; then
    printf 'identity: codex sidecar pid %s thread %s; pid does not match lock pid %s\n' \
      "$identity_pid" "$identity_thread" "$lock_pid"
    return 0
  fi
  if ! fm_codex_pid_alive "$identity_pid"; then
    printf 'identity: codex sidecar pid %s thread %s; pid matches lock but is not a live codex process\n' \
      "$identity_pid" "$identity_thread"
    return 0
  fi
  if ! thread_id=$(fm_codex_thread_id); then
    printf 'identity: codex sidecar pid %s thread %s; pid matches lock, this command has no codex thread id\n' \
      "$identity_pid" "$identity_thread"
    return 0
  fi
  if [ "$identity_thread" = "$thread_id" ]; then
    printf 'identity: codex sidecar pid %s thread %s; pid matches lock, thread matches this command\n' \
      "$identity_pid" "$identity_thread"
  else
    printf 'identity: codex sidecar pid %s thread %s; pid matches lock, thread differs from this command\n' \
      "$identity_pid" "$identity_thread"
  fi
}

# Publish or clear the Codex-specific identity sidecar for numeric lock pid $2.
# The caller owns state/.lock.acquire. Publishing before state/.lock is safe:
# readers require both files to name the same pid and otherwise fail closed.
# This is also the recovery path for a mismatched sidecar: an acquisition that
# the numeric holder itself may perform rebinds the file to the current thread,
# and an acquisition with no Codex thread identity clears it, so no stale or
# reused-pid sidecar can keep a live holder permanently read-only.
fm_session_lock_publish_identity() {
  local state=$1 lock_pid=$2 identity_file thread_id tmp
  identity_file="$state/.lock.codex-thread"
  if thread_id=$(fm_codex_thread_id) && fm_codex_pid_alive "$lock_pid"; then
    tmp=$(mktemp "$state/.lock-codex-thread-write.XXXXXX" 2>/dev/null) || return 1
    if ! printf '%s:%s\n' "$lock_pid" "$thread_id" > "$tmp" 2>/dev/null \
      || ! mv -f "$tmp" "$identity_file" 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null || true
      return 1
    fi
    [ -f "$identity_file" ] && [ ! -L "$identity_file" ] \
      && fm_codex_lock_identity_matches "$state" "$lock_pid"
    return
  fi
  rm -f "$identity_file" 2>/dev/null || return 1
  [ ! -e "$identity_file" ] && [ ! -L "$identity_file" ]
}

# True when state dir $1 holds a session lock whose pid is the harness ancestor
# of the current process. When the Codex identity sidecar exists it must also
# match this command's thread, and any harness ancestry that does resolve must
# still name the lock pid; only a command with no resolvable harness ancestry may
# rely on the sidecar alone, so a different harness nested inside the Codex
# session cannot claim ownership from the inherited thread id. A missing lock, a
# malformed or mismatched Codex identity, a lock held by another live harness, or
# unresolved legacy ancestry all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid my_pid identity_file
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  identity_file="$state/.lock.codex-thread"
  if [ -e "$identity_file" ] || [ -L "$identity_file" ]; then
    fm_codex_lock_identity_matches "$state" "$lock_pid" || return 1
    my_pid=$(fm_harness_ancestry_pid) || return 0
    [ "$my_pid" = "$lock_pid" ]
    return
  fi
  my_pid=$(fm_harness_ancestry_pid) || return 1
  [ "$my_pid" = "$lock_pid" ]
}
