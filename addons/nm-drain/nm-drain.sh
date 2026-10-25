#!/usr/bin/env bash
# Planned drain for a no-mistakes update: Main starts a drain, the watcher check asks for go once no pipeline run is
# active, and go updates without --force, restarts the daemon only through its own idle guard, and verifies.
# Usage: nm-drain.sh start|status|go|stop|check <fm-home>
# The drain record is <fm-home>/state/.nm-drain ("<start-epoch> [asked]"); go logs to <fm-home>/state/.nm-drain.log.
# Active means what `no-mistakes update` itself refuses on: a run in status pending or running, PR/CI monitoring
# included, because without --force the update refuses on those too. The state DB is read only from a copy.
set -u
CAP=${NM_DRAIN_CAP_SECS:-3600} TARGET=${NM_DRAIN_TARGET:-v1.84.0}
NMROOT=${NM_HOME:-$HOME/.no-mistakes}
[ "$#" -eq 2 ] && [ -d "$2/state" ] || { echo "usage: nm-drain.sh start|status|go|stop|check <fm-home>" >&2; exit 2; }
CMD=$1 F=$2/state/.nm-drain LOG=$2/state/.nm-drain.log

die() { printf 'nm-drain: %s\n' "$*" >&2; exit 1; }
ver() { no-mistakes --version 2>/dev/null | grep -o -m1 'v[0-9][0-9.]*' | head -1; }
daemon_pid() { grep -o '"pid":[0-9]*' "$NMROOT/daemon.pid" 2>/dev/null | cut -d: -f2; }
daemon_up() { no-mistakes daemon status 2>/dev/null | grep -q 'daemon running'; }

# active: one line per active run, "<id> <status> <branch> <current step>", from a backup copy of the state DB.
active() {
  local db=$NMROOT/state.sqlite tmp rc
  [ -f "$db" ] || return 0 # no-mistakes counts a missing DB as no runs
  mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}" && tmp=$(mktemp "${XDG_CACHE_HOME:-$HOME/.cache}/nm-drain.XXXXXX") || return 1
  sqlite3 "file:$db?mode=ro" ".backup '$tmp'" && sqlite3 -separator ' ' "$tmp" "select r.id, r.status, r.branch,
    coalesce((select s.step_name from step_results s where s.run_id = r.id and s.status not in ('pending', 'completed', 'skipped')
      order by s.step_order limit 1), '-')
    from runs r where r.status in ('pending', 'running') order by r.created_at"
  rc=$?
  rm -f -- "$tmp"
  return "$rc"
}

# summary <active-lines>: "N active (M only in PR/CI monitoring)".
summary() {
  local n m
  n=$(printf '%s' "$1" | grep -c .) m=$(printf '%s' "$1" | grep -cE ' (pr|ci)$')
  echo "$n active pipeline run(s) ($m only in PR/CI monitoring)"
}

case $CMD in
  start)
    [ ! -f "$F" ] || die "a drain is already running since $(date -u -d "@$(cut -d' ' -f1 "$F")" +%FT%TZ)"
    date +%s > "$F"
    echo "nm-drain: drain started; cap $((CAP / 60)) min. Tell the leads to start no new pipeline run; the watcher asks for go at 0."
    ;;
  stop)
    [ -f "$F" ] || die "no drain is running"
    rm -f -- "$F" && echo "nm-drain: drain stopped; the leads may start pipeline runs again"
    ;;
  status)
    list=$(active) || die "cannot count active pipeline runs (state DB copy failed)"
    if [ -f "$F" ]; then echo "drain: running for $(( ($(date +%s) - $(cut -d' ' -f1 "$F")) / 60 )) min of $((CAP / 60))"; else echo "drain: none"; fi
    echo "no-mistakes: $(ver) (target $TARGET)"
    summary "$list"
    [ -z "$list" ] || printf '%s\n' "$list" | sed 's/^/  /'
    ;;
  check)
    [ -f "$F" ] || exit 0
    read -r start asked < "$F"
    age=$(( $(date +%s) - start ))
    if ! list=$(active 2>&1); then echo "nm-drain: cannot count active pipeline runs: $list"; exit 0; fi
    if [ "$age" -ge "$CAP" ]; then
      rm -f -- "$F"
      echo "nm-drain: drain ended after $((age / 60)) min with no go ($(summary "$list")); cleared, the leads may start pipeline runs again"
    elif [ -z "$list" ] && [ -z "${asked:-}" ]; then
      echo "$start asked" > "$F"
      echo "nm-drain: 0 active pipeline runs after $((age / 60)) min of drain; run '$0 go $2' now to update no-mistakes $(ver) -> $TARGET"
    fi
    ;;
  go)
    list=$(active) || die "cannot count active pipeline runs (state DB copy failed)"
    [ -z "$list" ] || die "refusing: $(summary "$list"):"$'\n'"$list"
    from=$(ver) old=$(daemon_pid)
    [ "$from" != "$TARGET" ] || { rm -f -- "$F"; echo "nm-drain: no-mistakes is already $TARGET"; exit 0; }
    latest=$(grep -o '"latest_version":"[^"]*"' "$NMROOT/update-check.json" 2>/dev/null | cut -d'"' -f4)
    [ -z "$latest" ] || [ "$latest" = "$TARGET" ] || die "latest release is $latest, not the approved $TARGET; set NM_DRAIN_TARGET=$latest to accept it"
    echo "== $(date -u +%FT%TZ) go: no-mistakes update -y ($from -> $TARGET)" >> "$LOG"
    timeout 600 no-mistakes update -y < /dev/null 2>&1 | tee -a "$LOG"
    rc=${PIPESTATUS[0]} now=$(ver)
    [ "$now" = "$TARGET" ] || die "update exited $rc and no-mistakes is ${now:-unknown}, not $TARGET (log $LOG)"
    if [ "$(daemon_pid)" = "$old" ] || ! daemon_up; then
      # The update did not reset the daemon. daemon restart refuses by itself while any run is active.
      no-mistakes daemon restart < /dev/null 2>&1 | tee -a "$LOG"
    fi
    daemon_up && [ "$(daemon_pid)" != "$old" ] \
      || die "no-mistakes is $now but the daemon was not restarted onto it (log $LOG); run 'no-mistakes daemon restart' once no run is active"
    rm -f -- "$F"
    echo "nm-drain: no-mistakes $from -> $now, daemon restarted (pid $(daemon_pid)). Run no-mistakes doctor, then tell the leads new pipeline runs may start."
    ;;
  *) echo "usage: nm-drain.sh start|status|go|stop|check <fm-home>" >&2; exit 2 ;;
esac
