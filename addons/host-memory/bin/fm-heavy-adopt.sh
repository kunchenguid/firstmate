#!/usr/bin/env bash
# Move memory-heavy and sustained CPU-heavy pane jobs out of herdr-server.
set -euo pipefail
herdr=${FM_HEAVY_ADOPT_HERDR_CGROUP:-/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/herdr-server.service}
proc=${FM_HEAVY_ADOPT_PROC:-/proc}
state=${FM_HEAVY_ADOPT_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/fm-host-memory}
[ -d "$herdr" ] || exit 0
mkdir -p "$state"
if [ -n "${FM_HEAVY_ADOPT_DEST:-}" ]; then dest=$FM_HEAVY_ADOPT_DEST
else
  if ! systemctl --user is-active --quiet fm-heavy-adopt.scope; then
    systemd-run --user --scope --quiet --unit=fm-heavy-adopt --slice=fm-heavy.slice sleep infinity &
    for _ in 1 2 3 4 5 6 7 8 9 10; do systemctl --user is-active --quiet fm-heavy-adopt.scope && break; sleep 0.3; done
  fi
  dest=/sys/fs/cgroup$(systemctl --user show fm-heavy-adopt.scope -p ControlGroup --value)/cgroup.procs
fi
[ -n "$dest" ] && [ -e "$dest" ] || exit 0
previous=$state/fm-heavy-adopt.cpu
current=$(mktemp "$state/.cpu.XXXXXX")
trap 'rm -f -- "$current"' EXIT
clk=$(getconf CLK_TCK)
declare -A old_ticks=() old_start=() ppid=() ticks=() comm=() cmd=() hot=()
if [ -r "$previous" ]; then
  while read -r p s t; do old_start[$p]=$s; old_ticks[$p]=$t; done <"$previous"
fi
# Read stable process identity and CPU counters; /proc stat fields are counted after its closing comm parenthesis.
while read -r pid; do
  [ -r "$proc/$pid/stat" ] || continue
  read -r parent utime stime born < <(awk '{sub(/^.*\) /,""); print $2, $12, $13, $20}' "$proc/$pid/stat" 2>/dev/null) || continue
  [[ ${utime:-} =~ ^[0-9]+$ && ${stime:-} =~ ^[0-9]+$ && ${born:-} =~ ^[0-9]+$ ]] || continue
  total=$((utime + stime)); printf '%s %s %s\n' "$pid" "$born" "$total" >>"$current"
  ppid[$pid]=$parent; ticks[$pid]=$total
  comm_name=$(<"$proc/$pid/comm") || continue
  comm[$pid]=$comm_name
  cmd[$pid]=$(tr '\0' ' ' <"$proc/$pid/cmdline" 2>/dev/null || true)
  # The threshold is 2 CPU-seconds in the mover's 20-second interval; the 64-worker reproduction drove 66% PSI.
  if [ "${old_start[$pid]:-}" = "$born" ] && [ $((total - ${old_ticks[$pid]:-total})) -gt "$((2 * clk))" ]; then hot[$pid]=1; fi
done < <(find "$herdr" -name cgroup.procs -exec cat {} + 2>/dev/null | sort -un)
protected() {
  case "${comm[$1]:-}" in no-mistakes|herdr|claude|pi|codex|opencode|cursor-agent|gemini) return 0;; esac
  [[ ${cmd[$1]:-} =~ (^|/)(claude|pi|codex|opencode|cursor-agent|gemini)([-./[:space:]]|$) ]]
}
hot_tree() {
  local p=$1
  while [ -n "$p" ] && [ "$p" != 1 ]; do
    if [ "$p" != "$1" ] && protected "$p"; then return 1; fi
    [ -n "${hot[$p]:-}" ] && return 0
    p=${ppid[$p]:-}
  done
  return 1
}
for pid in "${!ticks[@]}"; do
  [ "${comm[$pid]:-}" = herdr ] && continue
  rss=$(awk '/^VmRSS:/{print $2}' "$proc/$pid/status" 2>/dev/null || true)
  case "${comm[$pid]:-}" in
    qemu-system*|emulator*|java|gradle*|ffmpeg|kotlin*|aapt2) move=1 ;;
    *) move=0; [ "${rss:-0}" -gt 3145728 ] && move=1 ;;
  esac
  if [ "$move" -eq 0 ] && hot_tree "$pid"; then move=1; fi
  # Keep an agent CLI in its current cgroup; descendants of a hot process still qualify independently.
  protected "$pid" && move=0
  if [ "$move" -eq 1 ]; then
    echo "$pid" >>"$dest" 2>/dev/null && echo "moved $pid ${comm[$pid]} $((rss / 1024)) MB"
  fi
done
mv -f -- "$current" "$previous"
