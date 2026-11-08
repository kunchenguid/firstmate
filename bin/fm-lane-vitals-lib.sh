#!/usr/bin/env bash
# fm-lane-vitals-lib.sh - the host vitals and per-lane process measurements
# that bin/fm-capacity.sh's auto budget reads, beyond its own base probes.
#
# bin/fm-capacity.sh owns every threshold, the verdict, and the published
# documents; this library only measures and prints. Every function is
# read-only, bounded, and degrades to an empty value rather than failing, so an
# unmeasurable signal is reported unknown and never judged. No side effects on
# source; sourcing requires bin/fm-timeout-lib.sh to be sourced first.
#
# Test seams: FM_PROC_ROOT_OVERRIDE replaces /proc and FM_SYS_ROOT_OVERRIDE
# replaces /sys for every Linux read; every other source is a command found on
# PATH (uname, sysctl, vm_stat, pmset, ioreg, ps, lsof, df, du, nvidia-smi,
# powershell.exe), so a fake bin directory drives the macOS, WSL, and native
# Windows (Git Bash/MSYS, where uname -s is MINGW*/MSYS*) paths.
#
# fm_lane_vitals_probe <os>
#   Sets LV_LOAD5, LV_PSI_CPU10, LV_PSI_MEM10, LV_PSI_MEM60, LV_PSI_MEMFULL10,
#   LV_PSI_IO10, LV_PSI_IO60 (Linux pressure-stall averages, percent),
#   LV_SWAPIN (cumulative pages swapped in), LV_VMPRESS (macOS
#   kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical),
#   LV_ON_AC (true|false), LV_BATT_PCT, LV_THERMAL (ok|limited), LV_WSL (1 inside
#   WSL, else 0), LV_WINDOWS (1 on native Windows, else 0), and LV_GPU (one "name<TAB>util_pct<TAB>used_gb<TAB>total_gb"
#   line per GPU; macOS unified memory leaves the two memory fields empty).
#   Linux reads /proc/loadavg, /proc/pressure/{cpu,memory,io}, /proc/vmstat
#   pswpin, /sys/class/power_supply/*/{type,online,capacity,status}, and
#   /proc/version for WSL; macOS reads sysctl vm.loadavg and
#   kern.memorystatus_vm_pressure_level, vm_stat Swapins, pmset -g batt and
#   -g therm (a CPU_Speed_Limit under 100 or a recorded warning is limited), and
#   ioreg -c IOAccelerator. Native Windows reads the same MSYS /proc files
#   where they exist (loadavg, vmstat) and nothing else; the host view below
#   supplies its memory, cores, load, and power. The GPU probe tries nvidia-smi
#   on PATH, then inside WSL /usr/lib/wsl/lib/nvidia-smi, then nvidia-smi.exe,
#   bounded to 3 s.
#
# fm_lane_vitals_windows_host
#   Prints "avail_gb total_gb commit_pct cpu_pct cores power" for the Windows
#   host (power is ac, battery, or - when the host has no battery) from one
#   powershell.exe CIM query (Win32_PerfFormattedData_PerfOS_Memory,
#   Win32_OperatingSystem, Win32_Processor, Win32_ComputerSystem,
#   Win32_Battery), bounded to 5 s, with stdin closed because powershell.exe
#   otherwise consumes its caller's input. It serves WSL2 through interop and
#   native Git Bash/MSYS directly. Returns 1 when powershell.exe or the query
#   is unavailable.
#
# fm_lane_vitals_processes <os> <out-file>
#   Writes one "pid<TAB>ppid<TAB>mem_kb<TAB>cpu_s<TAB>cwd" line per readable
#   process; the cwd is empty where it cannot be read. Linux reads
#   /proc/<pid>/stat (utime+stime over CLK_TCK, rss pages) and the cwd link;
#   macOS reads ps -axo pid=,ppid=,rss=,time= and
#   lsof -a -d cwd -u <uid> -Fpn, bounded to 8 s. Memory is refined later by
#   fm_lane_vitals_pss for attributed Linux processes only. Returns 1, with the
#   table still written, when no working directory could be read at all (lsof
#   failed or timed out on a loaded host, or /proc is unreadable), so a caller
#   never mistakes an unreadable table for lanes with no processes.
#
# fm_lane_vitals_attribute <lanes-file> <process-file>
#   <lanes-file> holds "key<TAB>worktree" lines. Prints one
#   "key<TAB>pid<TAB>mem_kb<TAB>cpu_s" line per attributed process. A process
#   belongs to the lane whose worktree holds its own cwd (the longest match
#   wins, and the first listed lane on an exact tie), otherwise to its nearest
#   attributed ancestor's lane; an ancestor of processes in two or more lanes -
#   a terminal multiplexer server or a login
#   session - is shared, so it is never attributed and nothing inherits a lane
#   through it.
#
# fm_lane_vitals_pss <os> <attribution-file>
#   Linux only: rewrites each attributed line's mem_kb with the Pss from
#   /proc/<pid>/smaps_rollup when readable, so pages shared between a lane's
#   processes are not counted twice; otherwise the line is unchanged.
#
# fm_lane_vitals_disk_mount <path>
#   Prints "mount<TAB>free_gb" for the filesystem holding <path> (df -Pk).
#
# fm_lane_vitals_du_gb <path> <seconds>
#   Prints the size of <path> in GB from du -sk, bounded to <seconds>; returns
#   1 when it cannot finish.

FM_LANE_VITALS_PROC=${FM_PROC_ROOT_OVERRIDE:-/proc}
FM_LANE_VITALS_SYS=${FM_SYS_ROOT_OVERRIDE:-/sys}

_fm_lv_num() {  # <value>: succeed for a non-negative decimal
  case "$1" in ''|*[!0-9.]*|*.*.*|.*|*.) return 1 ;; esac
}

_fm_lv_psi() {  # <file> <some|full> <avg10|avg60>
  [ -r "$1" ] || return 0
  awk -v kind="$2" -v key="$3" '$1 == kind { for (i = 2; i <= NF; i++) { split($i, kv, "="); if (kv[1] == key) { print kv[2]; exit } } }' "$1" 2>/dev/null
}

fm_lane_vitals_probe() {  # <os>
  local os=$1 v line dir type online status any_mains=0 mains_on=0
  LV_LOAD5='' LV_PSI_CPU10='' LV_PSI_MEM10='' LV_PSI_MEM60='' LV_PSI_MEMFULL10=''
  LV_PSI_IO10='' LV_PSI_IO60='' LV_SWAPIN='' LV_VMPRESS='' LV_ON_AC='' LV_BATT_PCT=''
  LV_THERMAL='' LV_WSL=0 LV_WINDOWS=0 LV_GPU=''
  case "$os" in MINGW*|MSYS*) LV_WINDOWS=1 ;; esac
  if [ "$os" = Darwin ]; then
    v=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $2}')
    _fm_lv_num "$v" && LV_LOAD5=$v
    v=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)
    case "$v" in ''|*[!0-9]*) ;; *) LV_VMPRESS=$v ;; esac
    v=$(vm_stat 2>/dev/null | awk '/^Swapins:/ {gsub(/\./, "", $2); print $2; exit}')
    case "$v" in ''|*[!0-9]*) ;; *) LV_SWAPIN=$v ;; esac
    v=$(pmset -g batt 2>/dev/null) || v=
    case "$v" in
      *"'AC Power'"*) LV_ON_AC=true ;;
      *"'Battery Power'"*) LV_ON_AC=false ;;
    esac
    case "$v" in
      *InternalBattery*)
        line=$(printf '%s\n' "$v" | sed -n 's/.*[^0-9]\([0-9][0-9]*\)%.*/\1/p' | head -1)
        case "$line" in ''|*[!0-9]*) ;; *) LV_BATT_PCT=$line ;; esac
        ;;
    esac
    v=$(pmset -g therm 2>/dev/null) || v=
    if [ -n "$v" ]; then
      LV_THERMAL=ok
      line=$(printf '%s\n' "$v" | sed -n 's/.*CPU_Speed_Limit[^0-9]*\([0-9][0-9]*\).*/\1/p' | head -1)
      case "$line" in ''|*[!0-9]*) ;; *) [ "$line" -ge 100 ] || LV_THERMAL=limited ;; esac
      if printf '%s\n' "$v" | grep -i 'warning level' | grep -qvi 'no .*warning level'; then
        LV_THERMAL=limited
      fi
    fi
    v=$(ioreg -r -d 1 -c IOAccelerator 2>/dev/null | awk '
      /"model" = / { m = $0; sub(/.*"model" = "/, "", m); sub(/".*/, "", m) }
      /"Device Utilization %"=/ { u = $0; sub(/.*"Device Utilization %"=/, "", u); sub(/[^0-9].*/, "", u) }
      END { if (m != "" || u != "") printf "%s\t%s\t\t\n", (m == "" ? "gpu" : m), u }')
    LV_GPU=$v
    return 0
  fi
  v=$(awk '{print $2}' "$FM_LANE_VITALS_PROC/loadavg" 2>/dev/null)
  _fm_lv_num "$v" && LV_LOAD5=$v
  LV_PSI_CPU10=$(_fm_lv_psi "$FM_LANE_VITALS_PROC/pressure/cpu" some avg10)
  LV_PSI_MEM10=$(_fm_lv_psi "$FM_LANE_VITALS_PROC/pressure/memory" some avg10)
  LV_PSI_MEM60=$(_fm_lv_psi "$FM_LANE_VITALS_PROC/pressure/memory" some avg60)
  LV_PSI_MEMFULL10=$(_fm_lv_psi "$FM_LANE_VITALS_PROC/pressure/memory" full avg10)
  LV_PSI_IO10=$(_fm_lv_psi "$FM_LANE_VITALS_PROC/pressure/io" full avg10)
  LV_PSI_IO60=$(_fm_lv_psi "$FM_LANE_VITALS_PROC/pressure/io" full avg60)
  for v in LV_PSI_CPU10 LV_PSI_MEM10 LV_PSI_MEM60 LV_PSI_MEMFULL10 LV_PSI_IO10 LV_PSI_IO60; do
    _fm_lv_num "${!v}" || printf -v "$v" '%s' ''
  done
  v=$(awk '$1 == "pswpin" {print $2; exit}' "$FM_LANE_VITALS_PROC/vmstat" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) ;; *) LV_SWAPIN=$v ;; esac
  for dir in "$FM_LANE_VITALS_SYS"/class/power_supply/*; do
    [ -d "$dir" ] || continue
    IFS= read -r type < "$dir/type" 2>/dev/null || type=
    case "$type" in
      Mains|USB*)
        IFS= read -r online < "$dir/online" 2>/dev/null || online=
        case "$online" in
          1) any_mains=1 mains_on=1 ;;
          0) any_mains=1 ;;
        esac
        ;;
      Battery)
        IFS= read -r v < "$dir/capacity" 2>/dev/null || v=
        case "$v" in ''|*[!0-9]*) ;; *) LV_BATT_PCT=$v ;; esac
        IFS= read -r status < "$dir/status" 2>/dev/null || status=
        [ "$status" != Discharging ] || [ "$any_mains" -eq 1 ] || LV_ON_AC=false
        ;;
    esac
  done
  if [ "$any_mains" -eq 1 ]; then
    if [ "$mains_on" -eq 1 ]; then LV_ON_AC=true; else LV_ON_AC=false; fi
  fi
  if grep -qi microsoft "$FM_LANE_VITALS_PROC/version" 2>/dev/null; then
    LV_WSL=1
  fi
  LV_GPU=$(_fm_lv_nvidia)
}

_fm_lv_nvidia() {
  local bin=
  if command -v nvidia-smi >/dev/null 2>&1; then
    bin=$(command -v nvidia-smi)
  elif [ "$LV_WSL" = 1 ] && [ -x /usr/lib/wsl/lib/nvidia-smi ]; then
    bin=/usr/lib/wsl/lib/nvidia-smi
  elif command -v nvidia-smi.exe >/dev/null 2>&1; then
    bin=$(command -v nvidia-smi.exe)
  else
    return 0
  fi
  fm_run_timed 3 "$bin" --query-gpu=name,utilization.gpu,memory.used,memory.total \
    --format=csv,noheader,nounits </dev/null 2>/dev/null | tr -d '\r' | awk -F', *' '
    NF >= 4 && $2 ~ /^[0-9.]+$/ && $3 ~ /^[0-9.]+$/ && $4 ~ /^[0-9.]+$/ {
      gsub(/\t/, " ", $1); printf "%s\t%s\t%.2f\t%.2f\n", $1, $2, $3 / 1024, $4 / 1024 }'
}

fm_lane_vitals_windows_host() {
  local ps out
  if command -v powershell.exe >/dev/null 2>&1; then
    ps=$(command -v powershell.exe)
  elif [ -x /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ]; then
    ps=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  elif [ -x /c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ]; then
    ps=/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  else
    return 1
  fi
  # One line: AvailableMBytes TotalVisibleMemorySize(KB) PercentCommittedBytesInUse
  # LoadPercentage NumberOfLogicalProcessors power (ac|battery|-).
  # Win32_Battery.BatteryStatus 1, 4, 5 discharge; 2, 3, 6-9, 11 run on AC.
  # shellcheck disable=SC2016 # a PowerShell program: its $names are PowerShell variables.
  out=$(fm_run_timed 5 "$ps" -NoProfile -NonInteractive -Command \
    '$m=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory; $o=Get-CimInstance Win32_OperatingSystem; $c=(Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average; $n=(Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors; $b=Get-CimInstance Win32_Battery | Select-Object -First 1; $p="-"; if ($b) { if (@(1,4,5) -contains $b.BatteryStatus) { $p="battery" } elseif (@(2,3,6,7,8,9,11) -contains $b.BatteryStatus) { $p="ac" } }; "{0} {1} {2} {3} {4} {5}" -f $m.AvailableMBytes,$o.TotalVisibleMemorySize,$m.PercentCommittedBytesInUse,[int]$c,[int]$n,$p' \
    </dev/null 2>/dev/null | tr -d '\r' | tail -1) || return 1
  printf '%s\n' "$out" | awk 'NF == 6 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ && $6 ~ /^(ac|battery|-)$/ {
    printf "%.2f %.2f %d %d %d %s\n", $1 / 1024, $2 / 1048576, $3, $4, $5, $6; ok = 1 } END { exit !ok }'
}

fm_lane_vitals_processes() {  # <os> <out-file>
  local os=$1 out=$2 tmp d pid cwd tck page uid
  : > "$out" || return 1
  if [ "$os" = Darwin ]; then
    tmp="$out.cwd"
    uid=$(id -u 2>/dev/null) || uid=
    [ -n "$uid" ] || return 0
    fm_run_timed 8 lsof -b -w -a -d cwd -u "$uid" -Fpn 2>/dev/null </dev/null |
      awk '/^p/ { p = substr($0, 2) } /^n/ { print p "\t" substr($0, 2) }' > "$tmp" 2>/dev/null || : > "$tmp"
    ps -axo pid=,ppid=,rss=,time= 2>/dev/null | awk -v OFS='\t' '
      FILENAME == ARGV[1] { cwd[$1] = substr($0, index($0, "\t") + 1); next }
      $1 ~ /^[0-9]+$/ {
        t = $4; d = 0
        if (t ~ /-/) { split(t, x, "-"); d = x[1]; t = x[2] }
        n = split(t, a, ":")
        if (n == 3) s = a[1] * 3600 + a[2] * 60 + a[3]; else if (n == 2) s = a[1] * 60 + a[2]; else s = a[1]
        print $1, $2, $3, s + d * 86400, ($1 in cwd ? cwd[$1] : "")
      }' "$tmp" - > "$out" 2>/dev/null
    if [ -s "$tmp" ]; then rm -f "$tmp"; return 0; fi
    rm -f "$tmp"
    return 1
  fi
  tck=$(getconf CLK_TCK 2>/dev/null) || tck=
  case "$tck" in ''|*[!0-9]*|0) tck=100 ;; esac
  page=$(getconf PAGESIZE 2>/dev/null) || page=
  case "$page" in ''|*[!0-9]*|0) page=4096 ;; esac
  tmp="$out.cwd"
  for d in "$FM_LANE_VITALS_PROC"/[0-9]*; do
    pid=${d##*/}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    cwd=$(readlink "$d/cwd" 2>/dev/null) || cwd=
    printf '%s\t%s\n' "$pid" "$cwd"
  done > "$tmp"
  # stat is "pid (comm) state ppid ...": the fields after the last ')' start at
  # state, so ppid is the 2nd, utime and stime the 12th and 13th, rss the 22nd.
  cat "$FM_LANE_VITALS_PROC"/[0-9]*/stat 2>/dev/null | awk -v tck="$tck" -v page="$page" '
    FILENAME == ARGV[1] { cwd[$1] = substr($0, index($0, "\t") + 1); next }
    {
      line = $0; i = 0
      for (k = length(line); k > 0; k--) if (substr(line, k, 1) == ")") { i = k; break }
      if (i == 0 || $1 !~ /^[0-9]+$/) next
      n = split(substr(line, i + 2), f, " ")
      if (n < 22) next
      printf "%s\t%s\t%d\t%.2f\t%s\n", $1, f[2], f[22] * page / 1024, (f[12] + f[13]) / tck, ($1 in cwd ? cwd[$1] : "")
    }' "$tmp" - > "$out" 2>/dev/null
  if awk -F'\t' '$2 != "" { found = 1; exit } END { exit !found }' "$tmp"; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"
  return 1
}

fm_lane_vitals_attribute() {  # <lanes-file> <process-file>
  awk -F'\t' -v OFS='\t' '
    FILENAME == ARGV[1] { if ($2 != "" && $2 != "-") { n++; key[n] = $1; wt[n] = $2 } next }
    {
      pp[$1] = $2; mem[$1] = $3; cpu[$1] = $4
      best = ""; bl = 0
      for (i = 1; i <= n; i++) { w = wt[i]; if (($5 == w || index($5, w "/") == 1) && length(w) > bl) { best = key[i]; bl = length(w) } }
      if (best != "") own[$1] = best
    }
    END {
      for (p in own) {
        q = pp[p]; guard = 0
        while (q != "" && q != 0 && q != p && guard++ < 256) {
          k = q SUBSEP own[p]
          if (!(k in seen)) { seen[k] = 1; lanes[q]++ }
          q = pp[q]
        }
      }
      for (p in pp) {
        if (lanes[p] >= 2) continue
        lane = ""
        if (p in own) lane = own[p]
        else {
          q = pp[p]; guard = 0
          while (q != "" && q != 0 && guard++ < 256) {
            if (lanes[q] >= 2) break
            if (q in own) { lane = own[q]; break }
            q = pp[q]
          }
        }
        if (lane != "") print lane, p, mem[p], cpu[p]
      }
    }' "$1" "$2"
}

fm_lane_vitals_pss() {  # <os> <attribution-file>
  local os=$1 file=$2 tmp key pid mem cpu pss
  [ "$os" != Darwin ] || return 0
  [ -s "$file" ] || return 0
  tmp="$file.pss"
  while IFS='	' read -r key pid mem cpu; do
    pss=$(awk '$1 == "Pss:" {print $2; exit}' "$FM_LANE_VITALS_PROC/$pid/smaps_rollup" 2>/dev/null)
    case "$pss" in ''|*[!0-9]*) pss=$mem ;; esac
    printf '%s\t%s\t%s\t%s\n' "$key" "$pid" "$pss" "$cpu"
  done < "$file" > "$tmp" && mv -f "$tmp" "$file"
}

fm_lane_vitals_disk_mount() {  # <path>
  df -Pk "$1" 2>/dev/null | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { printf "%s\t%.1f\n", $6, $4 / 1048576 }'
}

fm_lane_vitals_du_gb() {  # <path> <seconds>
  local kb
  kb=$(fm_run_timed "$2" du -sk "$1" 2>/dev/null </dev/null | awk 'NR == 1 {print $1}')
  case "$kb" in ''|*[!0-9]*) return 1 ;; esac
  awk -v k="$kb" 'BEGIN { printf "%.2f\n", k / 1048576 }'
}
