#!/usr/bin/env bash
set -u

TIMESTAMP_FILE=${1:-${FM_LIVENESS_PROCESS_TIMESTAMP_FILE:-}}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-liveness-process.XXXXXX") || exit 1
trap 'rm -rf -- "$TMP"' EXIT HUP INT TERM
command -v lsof >/dev/null 2>&1 || exit 1

LC_ALL=C ps -Ao pid=,time=,comm= > "$TMP/ps.raw" 2>/dev/null || exit 1
LC_ALL=C ps eww -Ao pid=,command= > "$TMP/env.raw" 2>/dev/null || exit 1
if [ -n "$TIMESTAMP_FILE" ]; then
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'printf "%.0f\n", clock_gettime(CLOCK_MONOTONIC) * 1000' \
      > "$TIMESTAMP_FILE" || exit 1
  elif [ -r /proc/uptime ]; then
    awk '{printf "%.0f\n", $1 * 1000}' /proc/uptime > "$TIMESTAMP_FILE" || exit 1
  else
    exit 1
  fi
fi
awk '
  function ms(t, a,n,d,h,m,s) {
    d=0
    if (t ~ /-/) { split(t,a,"-"); d=a[1]+0; t=a[2] }
    n=split(t,a,":")
    if (n==3) { h=a[1]+0; m=a[2]+0; s=a[3]+0 }
    else if (n==2) { h=0; m=a[1]+0; s=a[2]+0 }
    else { h=0; m=0; s=a[1]+0 }
    return int((((d*24+h)*60+m)*60+s)*1000+0.5)
  }
  { pid=$1; cpu=$2; $1=$2=""; sub(/^[[:space:]]+/,""); print pid "\t" ms(cpu) "\t" $0 }
' "$TMP/ps.raw" > "$TMP/ps.tsv"
awk '
  {
    for (i=2; i<=NF; i++) {
      if ($i ~ /^FM_WORKER_TOKEN=[0-9a-f]+$/) {
        token=substr($i,17)
        if (length(token)==32) print $1 "\t" token
        break
      }
    }
  }
' "$TMP/env.raw" > "$TMP/token.tsv" || exit 1
# A nonempty token table proves this observer can see the task-identity marker
# on at least one live process. Without that witness, downstream absence is
# unverified even if cwd rows exist: process visibility alone cannot bind a
# worker to a task.
[ -s "$TMP/token.tsv" ] && printf '__FM_LIVENESS_OBSERVER__\tworker-token-visible\n'
pid_list=$(awk -F '\t' 'BEGIN{sep=""} {printf "%s%s",sep,$1; sep=","}' "$TMP/ps.tsv")
[ -n "$pid_list" ] || exit 0
lsof -a -d cwd -p "$pid_list" -Fn > "$TMP/lsof.raw" 2>/dev/null || true
[ -s "$TMP/lsof.raw" ] || exit 1
awk '
  /^p[0-9]+$/ { pid=substr($0,2); next }
  /^n/ && pid != "" { print pid "\t" substr($0,2) }
' "$TMP/lsof.raw" > "$TMP/cwd.tsv"
awk -F '\t' '
  NR==FNR { cwd[$1]=$2; next }
  ($1 in cwd) { print $1 "\t" $2 "\t" $3 "\t" cwd[$1] }
' "$TMP/cwd.tsv" "$TMP/ps.tsv" > "$TMP/process.tsv"
awk -F '\t' '
  FILENAME==ARGV[1] { token[$1]=$2; next }
  { print $0 "\t" token[$1] }
' "$TMP/token.tsv" "$TMP/process.tsv"
