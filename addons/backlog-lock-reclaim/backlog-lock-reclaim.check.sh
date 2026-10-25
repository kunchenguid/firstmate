#!/usr/bin/env bash
# backlog-lock-reclaim watcher check: reclaims <fm-home>/data/backlog.md.lock when it is a 0-byte file older than
# FM_BACKLOG_LOCK_SAFE_AGE_S seconds (default 60, above tasks-axi's 30 s stale mark) and no process has it open.
# A tasks-axi writer that dies between creating the lock and writing its token leaves exactly that file, and tasks-axi
# never reclaims a lock, so every later backlog write fails LOCKED. Prints one wake line per reclaim and nothing
# otherwise; each reclaim is logged with its path and age to state/backlog-lock-reclaim.log. Usage: check.sh <fm-home>
# Liveness is the procfs open-descriptor table: a writer frozen between open and token write still holds the descriptor,
# and the table is the one signal that names the lock file itself (a process name or cwd match cannot tell which
# backlog a tasks-axi process writes). Descriptors of other users' processes are unreadable; a tasks-axi process we
# cannot read counts as a holder, so it is never reclaimed under.
set -u
FMH=${1:?usage: check.sh <fm-home>}
SAFE_AGE_S=${FM_BACKLOG_LOCK_SAFE_AGE_S:-60}
DATA=$(cd "$FMH/data" 2>/dev/null && pwd -P) || exit 0
LOCK=$DATA/backlog.md.lock
[ -f "$LOCK" ] && [ ! -L "$LOCK" ] || exit 0
read -r ino size mtime < <(stat -c '%i %s %Y' -- "$LOCK") || exit 0
[ "$size" = 0 ] || exit 0
age=$(( $(date +%s) - mtime ))
[ "$age" -gt "$SAFE_AGE_S" ] || exit 0

held() {
  local p fd
  for p in /proc/[0-9]*; do
    if ! ls "$p/fd" >/dev/null 2>&1; then
      grep -qa tasks-axi "$p/cmdline" 2>/dev/null && return 0
      continue
    fi
    for fd in "$p"/fd/*; do
      [ "$(readlink -- "$fd" 2>/dev/null)" = "$LOCK" ] && return 0
    done
  done
  return 1
}
held && exit 0
# Same inode and still empty: a live writer cannot have created a new lock while this file exists (wx fails), so the
# only holder that matters was already seen above.
[ "$(stat -c '%i %s' -- "$LOCK" 2>/dev/null)" = "$ino 0" ] || exit 0
rm -f -- "$LOCK" || exit 0
printf '%s reclaimed %s age=%ss\n' "$(date -u +%FT%TZ)" "$LOCK" "$age" >> "$FMH/state/backlog-lock-reclaim.log"
echo "backlog-lock-reclaim: reclaimed 0-byte backlog lock $LOCK (age ${age}s, no holder); backlog writes are unblocked"
