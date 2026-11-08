#!/usr/bin/env bash
# Behavioral coverage for bin/fm-lane-vitals-lib.sh, the probes behind
# bin/fm-capacity.sh's auto budget: Linux vitals from a fixture /proc and /sys
# (load5, pressure stall, swap-in, power supply, WSL detection), macOS vitals
# from fake sysctl, vm_stat, pmset, and ioreg, the GPU probe from a fake
# nvidia-smi, the Windows host view from a fake powershell.exe (ok, failing,
# and malformed), per-process tables on both platforms, lane attribution
# (own cwd, nearest ancestor, longest worktree, and a shared ancestor that is
# never attributed or inherited through), the Linux Pss refinement, and disk.
# shellcheck disable=SC2016 # each snippet is expanded by the child bash that sources the library.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-lane-vitals)
LIB_DIR="$ROOT/bin"

# lv <fakebin> <proc-root> <sys-root> <shell-snippet>: run the snippet with the
# library sourced, under that PATH and those fixture roots.
lv() {
  PATH="$1:$BASE_PATH" FM_PROC_ROOT_OVERRIDE="$2" FM_SYS_ROOT_OVERRIDE="$3" LIB_DIR="$LIB_DIR" \
    bash -c '. "$LIB_DIR/fm-timeout-lib.sh"; . "$LIB_DIR/fm-lane-vitals-lib.sh"; '"$4" 2>&1
}

# A fake bin with a fixed Linux clock tick and page size, so stat fields map
# to the same seconds and KB on every host.
linux_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/getconf" <<'SH'
#!/usr/bin/env bash
case "$1" in CLK_TCK) echo 100 ;; PAGESIZE) echo 4096 ;; *) exit 1 ;; esac
SH
  chmod +x "$fakebin/getconf"
  printf '%s\n' "$fakebin"
}

# A fixture /proc with one process per "pid ppid utime stime rss-pages cwd" row.
make_proc() {  # <dir> [row...]
  local dir=$1 pid ppid ut st rss cwd
  shift
  mkdir -p "$dir/pressure"
  printf '1.50 2.25 3.00 1/100 999\n' > "$dir/loadavg"
  printf 'some avg10=12.50 avg60=4.00 avg300=1.00 total=1\nfull avg10=0.50 avg60=0.10 avg300=0.00 total=1\n' > "$dir/pressure/memory"
  printf 'some avg10=1.00 avg60=1.00 avg300=1.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$dir/pressure/cpu"
  printf 'some avg10=30.00 avg60=25.00 avg300=1.00 total=1\nfull avg10=22.00 avg60=9.00 avg300=0.00 total=1\n' > "$dir/pressure/io"
  printf 'nr_free_pages 1\npswpin 4242\npswpout 7\n' > "$dir/vmstat"
  printf 'Linux version 6.1.0 (builder@host) #1 SMP\n' > "$dir/version"
  for row in "$@"; do
    # shellcheck disable=SC2086
    set -- $row
    pid=$1 ppid=$2 ut=$3 st=$4 rss=$5 cwd=$6
    mkdir -p "$dir/$pid"
    printf '%s (proc %s) S %s 1 1 0 -1 0 0 0 0 0 %s %s 0 0 20 0 1 0 100 1000 %s 0\n' \
      "$pid" "$pid" "$ppid" "$ut" "$st" "$rss" > "$dir/$pid/stat"
    [ "$cwd" = - ] || ln -s "$cwd" "$dir/$pid/cwd"
  done
}

test_linux_vitals_from_fixtures() {
  local proc sys out
  proc="$TMP_ROOT/linux/proc" sys="$TMP_ROOT/linux/sys"
  make_proc "$proc"
  mkdir -p "$sys/class/power_supply/AC" "$sys/class/power_supply/BAT0"
  printf 'Mains\n' > "$sys/class/power_supply/AC/type"
  printf '0\n' > "$sys/class/power_supply/AC/online"
  printf 'Battery\n' > "$sys/class/power_supply/BAT0/type"
  printf '41\n' > "$sys/class/power_supply/BAT0/capacity"
  printf 'Discharging\n' > "$sys/class/power_supply/BAT0/status"
  out=$(lv "$(fm_fakebin "$TMP_ROOT/linux")" "$proc" "$sys" 'fm_lane_vitals_probe Linux
    echo "$LV_LOAD5|$LV_PSI_MEM10|$LV_PSI_MEM60|$LV_PSI_MEMFULL10|$LV_PSI_CPU10|$LV_PSI_IO10|$LV_PSI_IO60|$LV_SWAPIN|$LV_ON_AC|$LV_BATT_PCT|$LV_WSL|$LV_GPU|$LV_VMPRESS|$LV_THERMAL"')
  assert_equals '2.25|12.50|4.00|0.50|1.00|22.00|9.00|4242|false|41|0|||' "$out" \
    "Linux vitals must come from loadavg, pressure, vmstat, and power_supply"
  printf '1\n' > "$sys/class/power_supply/AC/online"
  printf 'Linux version 6.18.54.1-microsoft-standard-WSL2\n' > "$proc/version"
  rm -rf "$proc/pressure"
  out=$(lv "$(fm_fakebin "$TMP_ROOT/linux")" "$proc" "$sys" 'fm_lane_vitals_probe Linux
    echo "$LV_PSI_MEM10|$LV_ON_AC|$LV_WSL"')
  assert_equals '|true|1' "$out" "missing PSI must read unknown, mains online true, and WSL detected"
  pass "Linux vitals read the fixture /proc and /sys, and missing sources read unknown"
}

test_darwin_vitals_from_fakes() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/darwin")
  cat > "$fakebin/sysctl" <<'SH'
#!/usr/bin/env bash
case "$2" in
  vm.loadavg) echo "{ 3.10 4.20 5.30 }" ;;
  kern.memorystatus_vm_pressure_level) echo 2 ;;
esac
SH
  printf '#!/usr/bin/env bash\nprintf "Mach Virtual Memory Statistics:\\nSwapins:                              16379763.\\nSwapouts: 1.\\n"\n' > "$fakebin/vm_stat"
  cat > "$fakebin/pmset" <<'SH'
#!/usr/bin/env bash
case "$2" in
  batt) printf "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t17%%; discharging; present: true\n" ;;
  therm) printf "Note: No thermal warning level has been recorded\nCPU_Scheduler_Limit = 100\nCPU_Speed_Limit = 70\n" ;;
esac
SH
  cat > "$fakebin/ioreg" <<'SH'
#!/usr/bin/env bash
printf '  "model" = "Apple M9"\n  "PerformanceStatistics" = {"Device Utilization %%"=37,"Renderer Utilization %%"=3}\n'
SH
  chmod +x "$fakebin"/*
  out=$(lv "$fakebin" /nonexistent /nonexistent 'fm_lane_vitals_probe Darwin
    printf "%s|%s|%s|%s|%s|%s|%s\n" "$LV_LOAD5" "$LV_VMPRESS" "$LV_SWAPIN" "$LV_ON_AC" "$LV_BATT_PCT" "$LV_THERMAL" "$LV_GPU"')
  assert_equals "4.20|2|16379763|false|17|limited|Apple M9	37		" "$out" \
    "macOS vitals must come from sysctl, vm_stat, pmset, and ioreg"
  cat > "$fakebin/pmset" <<'SH'
#!/usr/bin/env bash
case "$2" in
  batt) printf "Now drawing from 'AC Power'\n" ;;
  therm) printf "Note: No thermal warning level has been recorded\nNote: No performance warning level has been recorded\n" ;;
esac
SH
  out=$(lv "$fakebin" /nonexistent /nonexistent 'fm_lane_vitals_probe Darwin; printf "%s|%s|%s\n" "$LV_ON_AC" "$LV_BATT_PCT" "$LV_THERMAL"')
  assert_equals 'true||ok' "$out" "a desktop on AC with no recorded warning must read on AC and thermal ok"
  cat > "$fakebin/pmset" <<'SH'
#!/usr/bin/env bash
[ "$2" = therm ] && printf "Thermal warning level 2 has been recorded\n"
exit 0
SH
  out=$(lv "$fakebin" /nonexistent /nonexistent 'fm_lane_vitals_probe Darwin; printf "%s\n" "$LV_THERMAL"')
  assert_equals 'limited' "$out" "a recorded thermal warning must read limited"
  pass "macOS vitals read sysctl, vm_stat, pmset, and ioreg"
}

test_gpu_probe_and_host_view() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/gpu")
  cat > "$fakebin/nvidia-smi" <<'SH'
#!/usr/bin/env bash
printf 'NVIDIA GeForce RTX 5070 Ti, 7, 1736, 16303\r\n'
SH
  cat > "$fakebin/powershell.exe" <<'SH'
#!/usr/bin/env bash
# Prove stdin is closed: a probe that let powershell.exe read it would hang here.
if read -r -t 1 _; then echo "stdin was open" >&2; exit 9; fi
printf '2135 32614400 88 51\r\n'
SH
  chmod +x "$fakebin"/*
  out=$(printf 'caller input\n' | lv "$fakebin" "$TMP_ROOT/gpu/proc" /nonexistent 'fm_lane_vitals_probe Linux; printf "%s\n" "$LV_GPU"; fm_lane_vitals_wsl_host')
  assert_equals "NVIDIA GeForce RTX 5070 Ti	7	1.70	15.92
2.08 31.10 88 51" "$out" "the GPU line and the Windows host view must parse"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/powershell.exe"
  out=$(lv "$fakebin" /nonexistent /nonexistent 'fm_lane_vitals_wsl_host && echo ok || echo unavailable')
  assert_equals unavailable "$out" "a failing host query must report unavailable"
  printf '#!/usr/bin/env bash\necho "Get-CimInstance : Invalid query"\n' > "$fakebin/powershell.exe"
  out=$(lv "$fakebin" /nonexistent /nonexistent 'fm_lane_vitals_wsl_host && echo ok || echo unavailable')
  assert_equals unavailable "$out" "a malformed host answer must report unavailable"
  pass "the GPU probe and the Windows host view parse, close stdin, and degrade"
}

test_attribution_excludes_shared_ancestors() {
  local dir proc out
  dir="$TMP_ROOT/attr"
  mkdir -p "$dir/wt-a/sub" "$dir/wt-b" "$dir/wt-b-nested" "$dir/elsewhere"
  proc="$dir/proc"
  # pid ppid utime stime rss-pages cwd
  make_proc "$proc" \
    "10 1 0 0 100 $dir/wt-a" \
    "11 10 300 100 200 $dir/wt-a/sub" \
    "12 11 50 50 300 $dir/elsewhere" \
    "20 1 0 0 1000 $dir/wt-b" \
    "30 1 0 0 5000 $dir/wt-a" \
    "31 30 0 0 10 $dir/wt-a" \
    "32 30 0 0 20 $dir/wt-b" \
    "33 30 0 0 40 $dir/elsewhere" \
    "40 20 0 0 50 $dir/wt-b-nested" \
    "50 1 0 0 70 -"
  # lane-a-copy names lane-a's worktree again, so the first listed lane must win the tie.
  printf 'lane-a\t%s\nlane-b\t%s\nlane-n\t%s\nlane-x\t\nlane-a-copy\t%s\n' "$dir/wt-a" "$dir/wt-b" "$dir/wt-b-nested" "$dir/wt-a" > "$dir/lanes"
  out=$(lv "$(linux_fakebin "$dir")" "$proc" /nonexistent "fm_lane_vitals_processes Linux '$dir/ps' && fm_lane_vitals_attribute '$dir/lanes' '$dir/ps' | LC_ALL=C sort -t'	' -k2,2n")
  assert_equals "lane-a	10	400	0.00
lane-a	11	800	4.00
lane-a	12	1200	1.00
lane-b	20	4000	0.00
lane-a	31	40	0.00
lane-b	32	80	0.00
lane-n	40	200	0.00" "$out" \
    "attribution must use own cwd, the nearest ancestor, the longest worktree, and the first listed lane, and never a shared ancestor"
  pass "lane attribution follows cwd and ancestry and never crosses a shared ancestor"
}

test_pss_refines_linux_memory() {
  local dir proc out
  dir="$TMP_ROOT/pss"
  mkdir -p "$dir/wt"
  proc="$dir/proc"
  make_proc "$proc" "7 1 0 0 1000 $dir/wt" "8 7 0 0 1000 $dir/wt"
  printf 'Rss:  4000 kB\nPss:  1500 kB\n' > "$proc/7/smaps_rollup"
  printf 'lane\t%s\n' "$dir/wt" > "$dir/lanes"
  out=$(lv "$(linux_fakebin "$dir")" "$proc" /nonexistent "fm_lane_vitals_processes Linux '$dir/ps'; fm_lane_vitals_attribute '$dir/lanes' '$dir/ps' > '$dir/attr'; fm_lane_vitals_pss Linux '$dir/attr'; LC_ALL=C sort -t'	' -k2,2n '$dir/attr'")
  assert_equals "lane	7	1500	0.00
lane	8	4000	0.00" "$out" "Pss must replace rss where smaps_rollup is readable, and rss stand otherwise"
  pass "Linux memory uses Pss where readable and rss otherwise"
}

test_darwin_process_table() {
  local fakebin dir out
  dir="$TMP_ROOT/dps"
  mkdir -p "$dir/wt"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
printf '  100     1  51200   1:02.50\n  101   100   2048 1-02:00:00\n  102   100    512   0:00.25\n'
SH
  cat > "$fakebin/lsof" <<SH
#!/usr/bin/env bash
printf 'p100\nfcwd\nn$dir/wt\np101\nfcwd\nn/tmp/a dir with spaces\n'
SH
  chmod +x "$fakebin"/*
  out=$(lv "$fakebin" /nonexistent /nonexistent "fm_lane_vitals_processes Darwin '$dir/ps'; cat '$dir/ps'")
  assert_equals "100	1	51200	62.5	$dir/wt
101	100	2048	93600	/tmp/a dir with spaces
102	100	512	0.25	" "$out" "the macOS table must join ps times and lsof cwd, days included"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/lsof"
  out=$(lv "$fakebin" /nonexistent /nonexistent "fm_lane_vitals_processes Darwin '$dir/ps' && echo readable || echo unreadable; wc -l < '$dir/ps' | tr -d ' '")
  assert_equals "unreadable
3" "$out" "a failed lsof must report the table unreadable while still listing processes"
  pass "the macOS process table joins ps and lsof, and reports a failed lsof"
}

test_disk_and_du() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/disk")
  cat > "$fakebin/df" <<'SH'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/disk3 960000000 1 14155776 1% /System/Volumes/Data"
SH
  printf '#!/usr/bin/env bash\nprintf "3565158\\t%%s\\n" "$2"\n' > "$fakebin/du"
  chmod +x "$fakebin"/*
  out=$(lv "$fakebin" /nonexistent /nonexistent 'fm_lane_vitals_disk_mount /x; fm_lane_vitals_du_gb /x 3')
  assert_equals "/System/Volumes/Data	13.5
3.40" "$out" "df and du must report free and used GB"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/du"
  out=$(lv "$fakebin" /nonexistent /nonexistent 'fm_lane_vitals_du_gb /x 3 && echo measured || echo unknown')
  assert_equals unknown "$out" "a failed du must read unknown"
  pass "disk free and worktree size read df and du, and degrade"
}

test_real_host_smoke() {
  local out
  out=$(PATH="$BASE_PATH:$PATH" LIB_DIR="$LIB_DIR" bash -c '. "$LIB_DIR/fm-timeout-lib.sh"; . "$LIB_DIR/fm-lane-vitals-lib.sh"
    t=$(mktemp -d); fm_lane_vitals_processes "$(uname -s)" "$t/ps"; awk -F"\t" "NF >= 4" "$t/ps" | wc -l | tr -d " "; rm -rf "$t"' 2>&1)
  case "$out" in ''|*[!0-9]*|0) fail "the real host process table was empty: $out" ;; esac
  pass "the real host's process table is readable ($out processes)"
}

test_linux_vitals_from_fixtures
test_darwin_vitals_from_fakes
test_gpu_probe_and_host_view
test_attribution_excludes_shared_ancestors
test_pss_refines_linux_memory
test_darwin_process_table
test_disk_and_du
test_real_host_smoke

echo '# all fm-lane-vitals tests passed'
