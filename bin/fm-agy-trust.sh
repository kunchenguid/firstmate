#!/usr/bin/env bash
# Pre-register Antigravity CLI's workspace trust for the isolated task worktree
# a ship/scout spawn is about to launch an agy crewmate into, so the worker
# reaches its brief instead of wedging on the trust dialog.
#
# Usage: fm-agy-trust.sh <worktree> <project>
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the primary checkout that worktree belongs to
# Prints one line naming what it registered; refuses loudly on anything else.
#
# WHY THIS EXISTS. agy gates a folder it has never seen behind an interactive
# trust dialog ("Do you trust the contents of this project?", verified on agy
# 1.1.28), and neither --dangerously-skip-permissions nor -y covers it: the
# dialog still appeared on a launch carrying both. Every fresh task worktree
# therefore hits it. Its default selection is the SAFE one ("Yes, I trust this
# folder"), so unlike Claude's dialog firstmate could answer it with Enter -
# but a pre-registration is deterministic where a timed key press is a race,
# so the registration is preferred the same way bin/fm-claude-trust.sh is for
# claude. Accepting persists the path in the launching user's own
# ~/.gemini/antigravity-cli/settings.json under trustedWorkspaces (verified
# live: the accepted probe path was appended there), so this writes exactly
# that entry before launch and leaves no dialog to answer.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY, and it is STRUCTURAL rather than a
# path policy, mirroring bin/fm-claude-trust.sh: <worktree> must be a LINKED
# git worktree sharing <project>'s common dir whose top level is exactly the
# resolved argument. A primary checkout, a worktree of an unrelated repo, a
# subdirectory, a plain directory, and a home directory are each refused.
#
# Only the launching user's own store is written. Every unrelated key and entry
# is preserved and the replacement is atomic. A directory lock serializes
# Firstmate writers across the read, merge, and publish sequence. Fingerprint
# checks retry detected external changes; external writers do not share the lock.
set -u
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

[ "$#" -eq 2 ] || { echo "usage: fm-agy-trust.sh <worktree> <project>" >&2; exit 2; }
WT_ARG=$1
PROJ_ARG=$2

refuse() { echo "error: refusing to pre-register Antigravity trust: $1" >&2; exit 1; }

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

WT_REAL=$(real_dir "$WT_ARG") || true
[ -n "$WT_REAL" ] || refuse "worktree '$WT_ARG' is not an accessible directory"
PROJ_REAL=$(real_dir "$PROJ_ARG") || true
[ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"

command -v jq >/dev/null 2>&1 || refuse "jq is required to record workspace trust and was not found on PATH"

[ -n "${HOME:-}" ] || refuse "HOME is not set, so the store cannot be located"
HOME_REAL=$(real_dir "$HOME") || true
[ "$WT_REAL" != "${HOME_REAL:-}" ] || refuse "'$WT_REAL' is the home directory, not a task worktree"

WT_TOP=$(git -C "$WT_REAL" rev-parse --show-toplevel 2>/dev/null) || true
[ -n "$WT_TOP" ] || refuse "'$WT_REAL' is not inside a git repository"
WT_TOP_REAL=$(real_dir "$WT_TOP") || true
[ "$WT_TOP_REAL" = "$WT_REAL" ] || refuse "'$WT_REAL' is not a worktree root (its root is '${WT_TOP_REAL:-unresolvable}')"

WT_GIT_DIR=$(git -C "$WT_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has no resolvable git directory"
WT_GIT_DIR=$(real_dir "$WT_GIT_DIR") || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has an unresolvable git directory"
WT_COMMON=$(common_dir_of "$WT_REAL") || true
[ -n "$WT_COMMON" ] || refuse "'$WT_REAL' has no resolvable git common directory"
[ "$WT_GIT_DIR" != "$WT_COMMON" ] || refuse "'$WT_REAL' is a primary checkout, not an isolated worktree"

PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
[ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
[ "$WT_COMMON" = "$PROJ_COMMON" ] || refuse "'$WT_REAL' is not a worktree of project '$PROJ_REAL'"

STORE_DIR="$HOME/.gemini/antigravity-cli"
STORE="$STORE_DIR/settings.json"
mkdir -p "$STORE_DIR" 2>/dev/null || true
[ -d "$STORE_DIR" ] || refuse "Antigravity config directory '$STORE_DIR' does not exist and could not be created"
LOCK="$STORE_DIR/.fm-trust.lock"
# Stale-proof mutual exclusion for concurrent spawns. The lock directory
# carries an owner file with "<pid>:<epoch>"; mkdir stays the single atomic
# arbiter. A contender breaks only a lock whose owner pid is dead, whose
# timestamp is older than a legitimate hold can ever be (a hold is a single
# read-modify-rename of one small file), or whose directory is older than any
# legitimate mkdir-to-owner write with no owner file at all. A SIGKILLed or
# OOM-killed holder therefore blocks the next writer for at most one grace
# window rather than permanently. A break verdict is revalidated immediately
# before removal, so a contender that renewed the lock in between is waited
# on instead of removed; whatever slips the residual microsecond window still
# converges, because the following mkdir admits exactly one winner.
lock_owner() { cat "$LOCK/owner" 2>/dev/null; }
# Portable directory mtime in epoch seconds. macOS (BSD) stat uses `-f`,
# Linux (GNU) stat uses `-c`; detect the platform once rather than chaining
# fallbacks, because GNU `-f` is filesystem stat and exits 0 with garbage.
# Same contract as bin/fm-busy-event.sh's lock_mtime.
if [ "$(uname)" = Darwin ]; then
  lock_dir_mtime() { /usr/bin/stat -f %m "$LOCK" 2>/dev/null; }
else
  lock_dir_mtime() { stat -c %Y "$LOCK" 2>/dev/null; }
fi
lock_stale() {  # <owner-line> -> 0 when the lock may be broken
  local owner=$1 opid ots now
  case "$owner" in
    *:*) opid=${owner%%:*}; ots=${owner##*:} ;;
    *) return 0 ;;
  esac
  case "$opid" in ''|*[!0-9]*) return 0 ;; esac
  case "$ots" in ''|*[!0-9]*) return 0 ;; esac
  if kill -0 "$opid" 2>/dev/null; then
    now=$(date +%s)
    [ $((now - ots)) -gt 60 ] && return 0
    return 1
  fi
  return 0
}
# lock_breakable: 0 when the lock may be removed right now. A present owner
# decides it (live waits, stale breaks); an ownerless lock breaks only once
# its directory is older than any legitimate mkdir-to-owner write, so a
# racing contender's fresh directory always waits instead.
lock_breakable() {
  local owner now mtime
  owner=$(lock_owner)
  if [ -n "$owner" ]; then
    lock_stale "$owner" || return 1
    return 0
  fi
  now=$(date +%s)
  mtime=$(lock_dir_mtime || true)
  case "$mtime" in ''|*[!0-9]*) mtime=$now ;; esac
  [ $((now - mtime)) -ge "${FM_AGY_TRUST_OWNERLESS_STALE_SECS:-10}" ]
}
lock_wait() {
  # Every wait budget comfortably outlasts the 10s ownerless-stale threshold
  # above, so a waiter can never exhaust its retries just before an abandoned
  # lock becomes breakable.
  lock_attempt=$((lock_attempt + 1))
  [ "$lock_attempt" -lt 300 ] || refuse "timed out waiting for '$LOCK'"
  sleep 0.1
}
lock_attempt=0
while :; do
  if mkdir "$LOCK" 2>/dev/null; then
    printf '%s:%s\n' "$$" "$(date +%s)" > "$LOCK/owner" 2>/dev/null || {
      rmdir "$LOCK" 2>/dev/null || true
      refuse "could not record trust lock ownership in '$LOCK'"
    }
    break
  fi
  # Fast path: a live lock waits without further checks.
  lock_breakable || { lock_wait; continue; }
  # Slow path: the verdict above may predate a racing contender's renewal, so
  # revalidate immediately before removing. A renewed lock waits instead; only
  # a verdict that survives revalidation removes. Whatever slips the residual
  # microsecond window still converges: mkdir stays the single atomic arbiter,
  # so exactly one contender wins the replacement and the other waits on it.
  lock_breakable || { lock_wait; continue; }
  rmdir "$LOCK" 2>/dev/null || rm -rf "$LOCK" 2>/dev/null || true
  lock_attempt=$((lock_attempt + 1))
  [ "$lock_attempt" -lt 300 ] || refuse "timed out waiting for '$LOCK'"
  sleep 0.1
done
trap 'rm -f "$LOCK/owner" 2>/dev/null; rmdir "$LOCK" 2>/dev/null' EXIT
trap 'exit 1' HUP INT TERM
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "'$STORE' is not writable"
fi

fingerprint() {
  if [ -e "$STORE" ]; then sha256sum "$STORE" 2>/dev/null | awk '{print $1}';
  else printf 'absent'; fi
}

attempt=0
while [ "$attempt" -lt 3 ]; do
  attempt=$((attempt + 1))
  before=$(fingerprint)
  if [ "$before" = absent ]; then
    tmp=$(mktemp "$STORE_DIR/.settings.fm-trust.XXXXXX") || refuse "could not stage trust for '$WT_REAL'"
    if ! jq -n --arg wt "$WT_REAL" '{"trustedWorkspaces": [$wt]}' > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      refuse "could not stage trust for '$WT_REAL'"
    fi
  else
    if ! jq -e . "$STORE" >/dev/null 2>&1; then
      refuse "'$STORE' is not valid JSON; will not rewrite a store this does not own the format of"
    fi
    tmp=$(mktemp "$STORE_DIR/.settings.fm-trust.XXXXXX") || refuse "could not stage trust for '$WT_REAL'"
    if ! jq --arg wt "$WT_REAL" '.trustedWorkspaces = ((.trustedWorkspaces // []) + [$wt] | unique)' "$STORE" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      refuse "could not stage trust for '$WT_REAL'"
    fi
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  if [ "$(fingerprint)" != "$before" ]; then
    rm -f "$tmp"
    [ "$attempt" -ge 3 ] && refuse "'$STORE' was modified while trust was being recorded; refusing to overwrite it"
    continue
  fi
  if ! mv -f "$tmp" "$STORE" 2>/dev/null; then
    rm -f "$tmp"
    refuse "could not publish trust for '$WT_REAL' in '$STORE'"
  fi
  if jq -e --arg wt "$WT_REAL" '.trustedWorkspaces // [] | index($wt)' "$STORE" >/dev/null 2>&1; then
    echo "trusted: $WT_REAL"
    exit 0
  fi
  [ "$attempt" -ge 3 ] && refuse "'$STORE' did not retain trust for '$WT_REAL' after 3 attempts"
done
refuse "'$STORE' did not retain trust for '$WT_REAL' after 3 attempts"
