#!/usr/bin/env bash
# Memory gate for heavy jobs: no heat caps, but guard memory.
# Usage: fm-mem-gate.sh <command...>  - waits until the machine has room, then runs the command.
# Room = MemAvailable >= FM_MEM_MIN_GB (default 12) and memory pressure some avg10 < 40.
# ponytail: one global threshold, per-job sizes if jobs vary a lot.
min=${FM_MEM_MIN_GB:-12}
proc=${FM_MEM_GATE_PROC:-/proc}  # tests point this at fixture meminfo and pressure files
# Emulator cap: an emulator job also waits while FM_EMU_MAX (default 2) emulators already run on this host.
# Lean flags (-memory 2048) and AVDs off /tmp tmpfs cut each to ~3 GB. ponytail: host-wide count, per-home count if homes starve each other.
# A job run as `flock L timeout 60 bash -c "emulator ..."` must still resolve to the real program, or it skips the cap.
# prog prints the real program behind known wrappers (timeout, flock, nice, ionice, env, exec, NAME=VALUE, bash/sh -c
# with the first word of its string); any other first word is the program, as before.
prog() {
  while [ $# -gt 0 ]; do
    case "$1" in [A-Za-z_]*=*) shift; continue;; esac
    p=${1##*/}; shift
    case "$p" in
      exec) ;;
      env) while case "${1:-}" in -u|-C|--unset|--chdir) shift;; -*) ;; *) false;; esac; do shift; done ;;
      nice) while case "${1:-}" in -n|--adjustment) shift;; -*) ;; *) false;; esac; do shift; done ;;
      ionice) while case "${1:-}" in -[cnpPu]|--class|--classdata|--pid|--pgid|--uid) shift;; -*) ;; *) false;; esac; do shift; done ;;
      timeout) while case "${1:-}" in -[ks]|--kill-after|--signal) shift;; -*) ;; *) false;; esac; do shift; done; shift ;;
      flock) while case "${1:-}" in -[wE]|--timeout|--wait|--conflict-exit-code) shift;; -*) ;; *) false;; esac; do shift; done; shift
        case "${1:-}" in -c|--command) read -ra w <<<"${2:-}"; set -- "${w[@]}";; esac ;;
      bash|sh) c=0; while case "${1:-}" in [-+][oO]) shift;; --*|+*) ;; -*c*) c=1;; -*) ;; *) false;; esac; do shift; done
        [ "$c" = 1 ] || { echo "$p"; return; }; read -ra w <<<"${1:-}"; set -- "${w[@]}" ;;
      *) echo "$p"; return ;;
    esac
  done
}
real=$(prog "$@")
emu=0; case "$real" in emulator|qemu-system*) emu=1;; esac  # program name only, not args (emulator-5630 in a proof)
# Build cap: a Gradle job also waits while FM_GRADLE_MAX (default 1) Gradle builds run on this host
# (each build is ~8g gradle + 4g kotlin).
grd=0; case "$real" in gradlew|gradle) grd=1;; esac
# Check-then-start raced when several jobs started together. Emulator and Gradle jobs now take one host lock for the
# check; a 30 s holder keeps it until the new job shows in pgrep.
# A waiting job once held the lock through its sleeps, so a Gradle job with room waited behind an emulator job with
# none. The lock now covers only each check and the start.
while :; do
  [ $((emu + grd)) -gt 0 ] && { exec 9>"${XDG_RUNTIME_DIR:-/tmp}/fm-mem-gate.lock"; flock 9; }
  avail=$(awk '/MemAvailable/{print int($2/1048576)}' "$proc/meminfo")
  # Lower of avg10 and avg60, so 10-30 s spikes do not hold jobs.
  psi=$(awk '/^some/{split($2,a,"=");split($3,b,"=");v=(a[2]+0<b[2]+0)?a[2]:b[2];print int(v)}' "$proc/pressure/memory")
  running=0; [ "$emu" = 1 ] && running=$(pgrep -c '^qemu-system')
  builds=0; [ "$grd" = 1 ] && builds=$(pgrep -cf 'appname=gradle[w]')
  [ "$avail" -ge "$min" ] && [ "$psi" -lt 40 ] && { [ "$emu" = 0 ] || [ "$running" -lt "${FM_EMU_MAX:-2}" ]; } && { [ "$grd" = 0 ] || [ "$builds" -lt "${FM_GRADLE_MAX:-1}" ]; } && break
  [ $((emu + grd)) -gt 0 ] && exec 9>&-  # let go before sleeping
  echo "fm-mem-gate: waiting (free ${avail} GB, pressure ${psi}%, emulators ${running}, builds ${builds})" >&2
  sleep $((20 + RANDOM % 20))
done
[ $# -gt 0 ] || exit 0
[ $((emu + grd)) -gt 0 ] && { sleep 30 & } && exec 9>&-  # holder child keeps the lock 30 s; this process lets go
if command -v systemd-run >/dev/null; then
  if err=$(systemd-run --user --scope --quiet --slice=fm-heavy.slice --collect -- true 2>&1); then
    exec systemd-run --user --scope --quiet --slice=fm-heavy.slice --collect -p MemoryMax="${FM_MEM_JOB_GB:-10}G" -p MemorySwapMax=4G -- "$@"
  fi
  printf 'fm-mem-gate: systemd scope unavailable (%s); running directly\n' "${err:-user manager unavailable}" >&2
else
  echo 'fm-mem-gate: systemd-run missing from PATH; running directly' >&2
fi
exec nice -n 19 ionice -c3 "$@"
