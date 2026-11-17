#!/usr/bin/env bash
# ak47-health.sh - recurring box-health check for the firstmate factory host.
# Run every 10 min by ak47-health.timer. Read-mostly: it records a sample,
# applies only SAFE automatic fixes, and reports everything else to the chair.
#
# Safe automatic fixes (each logged):
#   wifi-band   Wi-Fi fell to 2.4 GHz while a 5 GHz AK475g radio is in range
#               -> roam back to the strongest 5 GHz one (1 s blip).
#   spike-snap  load above 1.5x cores -> save the top processes, so the cause of
#               a slowdown is known afterwards (sar keeps only the totals).
# Everything else is REPORTED, never changed: swap nearly full, memory or
# CPU/IO pressure, inotify near its limit, disk or /tmp filling, NVMe heat or
# errors, zero-byte git objects, failed user units, no watcher beat.
#
# The one other PAGE is the user task cap: past 80% of user@<uid>.service
# pids.max the uid cannot fork, and its own watcher is the first thing that
# stops, so the page names the leaf scopes holding the tasks.
#
# Reporting: one line per new finding in ~/.local/state/ak47/health.log, a
# rolling ~/.local/state/ak47/health-latest.md, and a note in the chair's inbox
# (bin/fm-inbox.sh note) at most once per finding key per 6 h.
#
# 2026-11-04 (Fable review + Aaron's "never saturate ak47" rule) load is now
# PAGED, not just noted: a 15-minute load average at or above AK47_PAGE_LOAD15
# (default 64 = 2x the 32 threads) writes ~/.local/state/ak47/page-latest.md,
# appends to pages.log, raises a desktop notification when one can be shown,
# and drops the loudest possible line into the chair's inbox naming the top
# CPU consumers BY CGROUP, so the culprit unit/scope is visible immediately.
# The marker ~/.local/state/ak47/.page-active exists while a page is standing.
# Heavy suites should run through ~/bin/fm-heavy (6-slot gate + fm-workers.slice
# ceiling); 2026-11-04 load hit 452 because several full suites ran at once.
# Usage: ak47-health.sh [--print] [--no-notify]
set -u
export FM_HOME=${FM_HOME:-/home/aaron/Projects/firstmate}
SD=$HOME/.local/state/ak47; mkdir -p "$SD/snaps" "$SD/keys" "$SD/keys/health"
LOG=$SD/health.log
CORES=$(nproc)
SPIKE=$((CORES * 3 / 2))
PAGE_LOAD15=${AK47_PAGE_LOAD15:-64}
# 2026-11-10: the lockup ran at 99% swap for hours while load15 stayed under 64,
# so load alone is not a page. Swap and available RAM page on their own.
PAGE_SWAP_PCT=${AK47_PAGE_SWAP_PCT:-70}
PAGE_MEM_AVAIL_GB=${AK47_PAGE_MEM_AVAIL_GB:-15}
NOTIFY=1; PRINT=0
for a in "$@"; do case $a in --no-notify) NOTIFY=0 ;; --print) PRINT=1; NOTIFY=0 ;; esac; done
now=$(date -u +%FT%TZ); et=$(TZ=America/New_York date '+%-I:%M %p ET')
finds=(); fixes=()
find_() { finds+=("$1|$2"); }   # key|plain-English line
page_() { finds+=("$1|PAGE! $2"); }   # same pipeline, loud delivery
fix_() { fixes+=("$1"); echo "$now FIX $1" >>"$LOG"; }
# the units/scopes actually burning the box right now, so a page is actionable
# grouped by the unit/scope that pays for it, with one example process name
heat() {
  ps -eo pcpu,pid,comm --sort=-pcpu --no-headers 2>/dev/null | head -8 |
  while read -r _ pid comm; do
    cg=$(awk -F: '{print $3}' "/proc/$pid/cgroup" 2>/dev/null); comm=${comm// /_}
    printf '%s|%s\n' "$(basename "${cg:-?}" | sed 's/\.\(service\|scope\|slice\)$//')" "$comm"
  done | awk -F'|' '{n[$1]++; if(!($1 in ex)) ex[$1]=$2} END{for(k in n) printf "%s(x%d,%s) ",k,n[k],ex[k]}'
}

# ---- sample
read -r l1 l5 l15 _ </proc/loadavg
mem_av=$(awk '/MemAvailable/{printf "%d",$2/1048576}' /proc/meminfo)
mem_tot=$(awk '/MemTotal/{printf "%d",$2/1048576}' /proc/meminfo)
sw_tot=$(awk '/SwapTotal/{print $2}' /proc/meminfo); sw_free=$(awk '/SwapFree/{print $2}' /proc/meminfo)
sw_pct=$(( sw_tot > 0 ? (sw_tot - sw_free) * 100 / sw_tot : 0 ))
psi() { awk -v k="$2" '$1==k{split($2,a,"=");print a[2]}' "/proc/pressure/$1"; }
cpu_some=$(psi cpu some); mem_full=$(psi memory full); io_full=$(psi io full)
ino=0; for p in $(pgrep -u "$USER"); do ino=$((ino + $(ls -l /proc/$p/fd 2>/dev/null | grep -c inotify))); done
ino_max=$(cat /proc/sys/fs/inotify/max_user_instances)
root_pct=$(df --output=pcent / | tail -1 | tr -dc 0-9)
tmp_g=$(du -sx --block-size=1G /tmp 2>/dev/null | cut -f1)
tctl=$(sensors 2>/dev/null | awk '/Tctl/{gsub(/[+°C]/,"",$2); printf "%d",$2}')
nvt=$(sensors 2>/dev/null | awk '/^nvme/{f=1} f&&/Composite/{gsub(/[+°C]/,"",$2); printf "%d",$2; exit}')
W="sudo -n wpa_cli -p /run/wpa_supplicant -i wlp99s0"
freq=$($W signal_poll 2>/dev/null | awk -F= '/^FREQUENCY/{print $2}')
rssi=$($W signal_poll 2>/dev/null | awk -F= '/^RSSI/{print $2}')
link=$($W signal_poll 2>/dev/null | awk -F= '/^LINKSPEED/{print $2}')
route_if=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
agents=$(pgrep -c -x pi)
beat=$(( $(date +%s) - $(stat -c %Y "$FM_HOME/state/.last-watcher-beat" 2>/dev/null || echo 0) ))
failed=$(systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')

# ---- the user task cap, sampled and paged
# 2026-11-14: user@1000.service reached pids.max 12000 at 02:49Z and every fork in
# the uid returned EAGAIN until 08:04Z - the watcher, every worker shell and every
# check failed to start for five hours, and this file had no threshold for it, so
# nothing paged. Tasks are cheap, so load, swap and memory all stayed inside their
# ceilings while the uid was already unable to fork.
USLICE=${AK47_USER_SLICE:-"/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service"}
pids_cur=$(cat "$USLICE/pids.current" 2>/dev/null | tr -dc 0-9)
pids_max=$(cat "$USLICE/pids.max" 2>/dev/null | tr -d ' \n')
case "${pids_max:-}" in ''|max|*[!0-9]*) pids_max=0 ;; esac
# the leaf units actually holding the tasks, so a page names who to look at:
# services and transient scopes under the slice's sub-cgroups, never an
# aggregate *.slice that only repeats what its children already hold.
tasks_units() {
  local d
  find "$USLICE" -mindepth 2 -maxdepth 3 \( -name '*.scope' -o -name '*.service' \) -type d 2>/dev/null |
  while IFS= read -r d; do
    [ -r "$d/pids.current" ] || continue
    printf '%s|%s\n' "$(tr -dc 0-9 <"$d/pids.current" 2>/dev/null)" "${d#"$USLICE"/}"
  done
}
tasks_heat() {
  tasks_units | sort -t'|' -k1,1 -rn | head -5 |
    awk -F'|' '{sub(/\.(service|scope)$/,"",$2); printf "%s(%s) ",$2,$1}'
}

echo "$now load=$l1/$l5 memavail=${mem_av}G swap=${sw_pct}% psi_cpu=$cpu_some mem_full=$mem_full io_full=$io_full inotify=$ino/$ino_max disk=${root_pct}% tmp=${tmp_g}G tctl=${tctl} nvme=${nvt} wifi=${freq}MHz/${rssi}dBm/${link} route=$route_if pi=$agents pids=${pids_cur:-0}/${pids_max:-0} beat=${beat}s" >>"$SD/samples.log"

# ---- safe fix: spike snapshot
if [ "${l1%.*}" -ge "$SPIKE" ]; then  # bash needs integers; ${l1%.*} truncates
  f=$SD/snaps/spike-$(date -u +%Y%m%dT%H%MZ).txt
  { echo "load $l1 $l5 $l15 at $now"; ps -eo pid,pcpu,rss,etime,args --sort=-pcpu | head -40 | cut -c1-220
    echo; echo "by command:"; ps -eo comm,pcpu --no-headers | awk '{c[$1]+=$2;n[$1]++} END{for(k in c) printf "%-20s n=%-4d cpu=%.0f%%\n",k,n[k],c[k]}' | sort -t= -k3 -rn | head -12; } >"$f"
  fix_ "spike-snap load=$l1 -> $f"
  SNAP=$f   # named by the finding below, which fires only when no page is standing
fi
ls -t "$SD"/snaps/spike-* 2>/dev/null | tail -n +200 | xargs -r rm -f   # keep the newest 200

# ---- safe fix: Wi-Fi back to 5 GHz (only when Wi-Fi carries traffic)
if [ "$route_if" = wlp99s0 ] && [ -n "$freq" ] && [ "$freq" -lt 5000 ]; then
  $W scan >/dev/null 2>&1; sleep 5
  best=$($W scan_results 2>/dev/null | awk -F'\t' '$5=="AK475g" && $2>=5000 {print $3"\t"$1}' | sort -rn | head -1 | cut -f2)
  if [ -n "$best" ] && $W roam "$best" >/dev/null 2>&1; then
    sleep 5; fix_ "wifi-band: was ${freq}MHz ${rssi}dBm, roamed to 5 GHz $best ($($W signal_poll | awk -F= '/RSSI/{print $2}')dBm)"
  else
    find_ wifi-24 "Wi-Fi is on 2.4 GHz (${rssi} dBm) and no 5 GHz AK475g radio answered; expect ~35 Mbit/s"
  fi
fi

# ---- report-only findings
# ---- the page: a 15-minute load average above 2x threads means the box is not keeping up
if awk -v v="$l15" -v t="$PAGE_LOAD15" 'BEGIN{exit !(v>=t)}'; then
  page_ load-sustain "load15 $l15 on $CORES threads (page threshold $PAGE_LOAD15, 2 per thread) - hottest: $(heat | sed 's/ $//') - gate suites with ~/bin/fm-heavy; detail ~/.local/state/ak47/page-latest.md"
  touch "$SD/.page-active"
else
  rm -f "$SD/.page-active"
  [ "${l1%.*}" -ge "$SPIKE" ] && find_ load-spike "Load hit $l1 on $CORES threads (more than 1.5 jobs per core); top processes saved to ${SNAP:-$SD/snaps}"
fi

# ---- the page: swap or memory pressure, independent of load
# 2026-11-10 the box sat at 99-100% swap with 77 GB RAM free and load15 never
# crossed 64, so the load page never fired. These two page on their own.
if [ "$sw_pct" -ge "$PAGE_SWAP_PCT" ]; then
  page_ swap-sustain "swap ${sw_pct}% (page threshold ${PAGE_SWAP_PCT}%) with ${mem_av} GB RAM available - hottest: $(heat | sed 's/ $//') - reclaim with 'sudo swapoff -a && sudo swapon -a' when RAM is free; detail ~/.local/state/ak47/page-latest.md"
  touch "$SD/.page-active"
fi
if [ "$mem_av" -lt "$PAGE_MEM_AVAIL_GB" ]; then
  page_ mem-sustain "only ${mem_av} of ${mem_tot} GB RAM available (page floor ${PAGE_MEM_AVAIL_GB} GB) - hottest: $(heat | sed 's/ $//') - detail ~/.local/state/ak47/page-latest.md"
  touch "$SD/.page-active"
fi

[ "$sw_pct" -ge 90 ] && find_ swap-full "Swap is ${sw_pct}% full; ${mem_av} GB RAM is free, so 'sudo swapoff -a && sudo swapon -a' would safely reclaim it"
[ "$mem_av" -lt 12 ] && find_ mem-low "Only ${mem_av} of ${mem_tot} GB RAM available"
awk -v v="$mem_full" 'BEGIN{exit !(v>5)}' && find_ mem-pressure "Memory pressure: tasks fully stalled ${mem_full}% of the last 10 s"
awk -v v="$io_full" 'BEGIN{exit !(v>10)}' && find_ io-pressure "Disk pressure: tasks fully stalled on I/O ${io_full}% of the last 10 s"
[ "$ino" -ge $((ino_max * 80 / 100)) ] && find_ inotify "File-watch handles at $ino of $ino_max; new agents may fail to start"
[ "$root_pct" -ge 80 ] && find_ disk "Main disk ${root_pct}% full"
# ---- the page: the uid is running out of things it can fork
# A fork-starved box cannot heal itself: the fix was always outside it (systemd
# drop-ins), and the previous occurrence was found only because Aaron noticed the
# fleet was silent. Page at 80%, before the cap, and name the scopes holding it.
if [ "${pids_max:-0}" -gt 0 ] && [ -n "${pids_cur:-}" ]; then
  pids_pct=$(( pids_cur * 100 / pids_max ))
  if [ "$pids_pct" -ge 80 ]; then
    page_ tasks-sustain "user task cap ${pids_pct}% used (${pids_cur} of ${pids_max} tasks for uid $USER) - holders: $(tasks_heat | sed 's/ $//') - past 100% every fork fails EAGAIN and the fleet stops starting; the slice cap is tasksmax-slice.conf and the per-unit cap is /etc/systemd/user.conf.d/60-ak47-tasksmax-user.conf - find the lane that grew: ~/.local/state/ak47/tasks-latest.md"
    touch "$SD/.page-active"
    { echo "# ak47 task cap $et ($now)"; echo; echo "${pids_cur} of ${pids_max} tasks (${pids_pct}%) for uid $USER"; echo; echo "by unit:"; tasks_heat | sed 's/ $//'; echo; echo "leaf units and their task counts:"; tasks_units | sort -t'|' -k1,1 -rn | head -20 | awk -F'|' '{printf "%-10s %s\n",$1,$2}'; } >"$SD/tasks-latest.md"
  fi
fi
[ "${tmp_g:-0}" -ge 60 ] && find_ tmp "/tmp holds ${tmp_g} GB (it is emptied at every boot)"
[ -n "$tctl" ] && [ "$tctl" -ge 95 ] && find_ cpu-hot "CPU at ${tctl}°C, near its throttle point"
[ -n "$nvt" ] && [ "$nvt" -ge 70 ] && find_ nvme-hot "NVMe at ${nvt}°C"
[ "$beat" -gt 600 ] && [ "$agents" -gt 5 ] && find_ watcher "Fleet monitoring has not checked in for $((beat / 60)) min while $agents agents run"
[ -n "$failed" ] && find_ "failed-$(echo "$failed" | md5sum | cut -c1-8)" "Failed background jobs: $failed"
# ---- the loop's own liveness: a hygiene tick that dies silently is worse than none
# ak47-devops.timer writes one devops.log line every 5 min. 30 min of silence is
# a page, not a finding: the box is then unowned again.
DEVLOG=$SD/devops.log
if [ -f "$DEVLOG" ]; then
  dev_age=$(( $(date +%s) - $(stat -c %Y "$DEVLOG" 2>/dev/null || echo 0) ))
  if [ "$dev_age" -gt 1800 ]; then
    page_ devops-stale "the ak47 hygiene tick has not written a line for $((dev_age / 60)) min (timer ak47-devops.timer, log $DEVLOG) - the box is unowned until it runs again: systemctl --user status ak47-devops.timer"
  fi
else
  find_ devops-absent "no $DEVLOG: the ak47 hygiene tick has never run on this box"
fi
if [ "$(date -u +%M)" -lt 10 ]; then   # hourly: git stores
  z=$(for d in "$FM_HOME"/projects/*/.git "$HOME"/.llm-wiki/.git; do find "$d/objects" -type f -size 0 2>/dev/null; done | wc -l)
  [ "$z" -gt 0 ] && find_ git-zero "$z zero-byte git object(s) in the shared stores; git fetch will fail in their worktrees"
fi

# ---- outputs
{
  echo "# ak47 health $et ($now)"
  echo "load $l1 / $l5 / $l15 on $CORES threads | RAM ${mem_av}/${mem_tot} GB free | swap ${sw_pct}% | pressure cpu $cpu_some mem-full $mem_full io-full $io_full"
  echo "disk ${root_pct}% | /tmp ${tmp_g} GB | inotify $ino/$ino_max | CPU ${tctl}°C NVMe ${nvt}°C | net $route_if ${freq}MHz ${rssi}dBm ${link}Mbit | agents $agents | watcher ${beat}s"
  # the last agent-reclaim run (ak47/guards/agent-reclaim.sh, every 15 min), as one line
  [ -r "$SD/agent-reclaim.line" ] && cut -d' ' -f2- "$SD/agent-reclaim.line"
  echo; echo "## findings"; [ ${#finds[@]} -eq 0 ] && echo "none"; for f in "${finds[@]}"; do echo "- ${f#*|}"; done
  echo; echo "## automatic fixes this run"; [ ${#fixes[@]} -eq 0 ] && echo "none"; for f in "${fixes[@]}"; do echo "- $f"; done
} >"$SD/health-latest.md"
[ "$PRINT" = 1 ] && cat "$SD/health-latest.md"

# a --print/--no-notify run is a dry view: it must not consume a 6 h key, or a
# look at the dashboard would silence the next real page for that finding
new=(); newkeys=()
if [ "$NOTIFY" = 1 ]; then
  for f in "${finds[@]}"; do
    k=${f%%|*}; kf=$SD/keys/health/$k
    if [ ! -f "$kf" ] || [ $(( $(date +%s) - $(stat -c %Y "$kf") )) -gt 21600 ]; then
      new+=("${f#*|}"); newkeys+=("$kf"); echo "$now FIND $k ${f#*|}" >>"$LOG"
    fi
  done
  # clear keys for findings that went away, so a recurrence reports again. Only
  # this beat's own keys: the tick keeps its keys in $SD/keys and prunes them
  # itself. 2026-11-15 - pruning the whole directory here deleted the tick's
  # tmp-gb-stale key every five minutes, so that finding re-paged on every tick
  # (59 notes in a day) instead of once per episode.
  for kf in "$SD"/keys/health/*; do [ -e "$kf" ] || continue; k=$(basename "$kf"); printf '%s\n' "${finds[@]}" | grep -q "^$k|" || rm -f "$kf"; done
fi
if [ "$NOTIFY" = 1 ] && [ ${#new[@]} -gt 0 ]; then
  # a page is delivered like a note but also leaves a durable page record and a
  # desktop notification, so a saturated box cannot be missed in a busy inbox
  paged=$(printf '%s\n' "${new[@]}" | grep -m1 '^PAGE! ' || true)
  printf '%s\n' "${new[@]}" | grep -v '^PAGE! ' | paste -sd'; ' - >"$SD/.note-body" 2>/dev/null || true
  if [ -n "$paged" ]; then
    { echo "# ak47 PAGE $et ($now)"; echo; echo "${paged#PAGE! }"; echo; echo "samples: ~/.local/state/ak47/samples.log | findings: health-latest.md"; } >"$SD/page-latest.md"
    printf '%s PAGE %s\n' "$now" "${paged#PAGE! }" >>"$SD/pages.log"
    command -v notify-send >/dev/null 2>&1 && notify-send -u critical -a ak47 "ak47 box: ${paged#PAGE! }" >/dev/null 2>&1 || true
    rm -f "$SD/.page-active"   # re-armed by this run below
    touch "$SD/.page-active"
  fi
  note="ak47 box health ($et): "
  [ -n "$paged" ] && note="$note${paged#PAGE! }; "
  [ -s "$SD/.note-body" ] && note="$note$(cat "$SD/.note-body"); "
  if "$FM_HOME/bin/fm-inbox.sh" note --source health "${note}details ~/.local/state/ak47/health-latest.md" >/dev/null 2>&1; then
    for kf in "${newkeys[@]}"; do touch "$kf" 2>/dev/null || true; done
  else
    echo "$now DELIVERY-FAILED ${#new[@]} finding(s) not delivered; dedupe keys not committed" >>"$LOG"
  fi
  rm -f "$SD/.note-body"
fi
tail -n 20000 "$SD/samples.log" >"$SD/.s" 2>/dev/null && mv -f "$SD/.s" "$SD/samples.log"
exit 0
