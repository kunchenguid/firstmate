#!/usr/bin/env bash
# fm-heavy-admission.sh - the single owner of "may a heavy validation phase
# start now" on this machine.
#
# A heavy phase is a dependency install, a whole-repo test run, a production
# build, a browser matrix, or the start of a fresh no-mistakes validation run.
# Reasoning, editing, and targeted checks are light and never consult this.
# The default thresholds are proposed starting points, not validated
# boundaries.
# bin/fm-capacity.sh (lane headroom for queued dispatch) and
# bin/fm-project-capacity-lib.sh (workers a project admits at spawn) own
# different decisions and are not consulted here.
#
# Usage:
#   fm-heavy-admission.sh check [--peak-gib <n>] [--dry-run]
#   fm-heavy-admission.sh wait [--peak-gib <n>] [--timeout <secs>] [--dry-run]
#   fm-heavy-admission.sh policy
#   fm-heavy-admission.sh defaults
#   fm-heavy-admission.sh -h | --help
#
# check samples the host now and then every sample_interval_secs until
# window_secs have passed (60 and 10 take seven samples) and admits only when
# every admit condition held in every sample:
#   load1 < admit_load1_below and load5 < admit_load5_below
#   MemAvailable > admit_mem_available_above_gib and, with --peak-gib (the
#     job's measured peak), MemAvailable > peak + reserve_gib
#   memory PSI "some avg60" < admit_mem_psi_some_avg60_below (percent)
#   I/O PSI "full avg60" < admit_io_psi_full_avg60_below (percent)
#   free space on disk_path > admit_disk_free_above_gib
#   no kernel hung-task report and no systemd-journald watchdog timeout in the
#     journal within the last warning_lookback_secs
# An unknown peak is never estimated: the serial ramp below already admits
# such jobs one at a time. The first failing sample ends the window early.
# A reading at a hold trigger (load1 >= hold_load1_at, MemAvailable <=
# hold_mem_available_at_gib, I/O full avg60 >= hold_io_psi_full_avg60_at, or
# any such warning) is reported as trip:, which stops new heavy admissions
# while running work drains naturally; any other missed admit condition is
# reported as below-admit:. Either way the next admit needs the full window of
# admit conditions again, so a trip clears only after the stricter admit
# conditions recover. Holding never stops, throttles, or shrinks running or
# required work: a caller that holds queues its phase and asks again later.
#
# Serial ramp: an admit records its time as the modification time of
# state/heavy-admission.last in the root Firstmate home (the home that
# bin/fm-wake-lib.sh's fm_firstmate_root_home resolves), so every local home
# on this machine shares one ramp. A check within ramp_secs of the last
# admission holds with ramp:, so concurrent workers cannot all spend the same
# measured headroom. The ramp is re-read and the record written under
# state/.heavy-admission.lock in that same root home.
#
# Fail closed: an unreadable loadavg, meminfo, or pressure file; a df query
# that fails, returns unusable output, or exceeds its ten-second bound; a
# journal query that fails, cannot see system messages, or outlives its bound;
# an unresolvable root home; or a ramp record or lock that cannot be used holds
# with unreadable:<reading>. A malformed config holds with
# config-invalid:<detail>.
#
# Policy and config: this home's config/heavy-admission, or when absent the
# root Firstmate home's config/heavy-admission, turns the policy on; its
# key=value lines override the defaults printed by `defaults`, so the root home
# sets the machine's policy and any home can override it. Blank lines and lines
# starting with # are ignored; an unknown key or a malformed value is invalid.
# When the root resolves and neither file is present, the policy is off and
# check admits at once with reason=policy-off. An unresolved root is unknown.
# `fm-heavy-admission.sh defaults > config/heavy-admission`
# enables the approved policy. `policy` prints on, off, or unknown when the root
# home cannot be resolved; bin/fm-brief.sh keeps the rule for on and unknown.
# jest_max_workers and playwright_workers carry the initial validator-internal
# parallelism bound: a caller running Jest or Playwright itself passes them as
# --maxWorkers and --workers.
#
# Evidence: every decision prints one line on stdout and, with the policy on,
# appends it best effort under a file lock to the root home's
# state/heavy-admission.log (trimmed to its newest 2000 lines past 256 KiB).
# If the evidence operation exceeds two seconds, the write is skipped with a
# stderr note so evidence never holds up the admission decision:
#   heavy-admission: decision=<admit|hold> reason=<token>[,<token>...]
#     policy=<on|off|unknown> config=<path|none> peak_gib=<n|unknown> samples=<n>
#     load1=<x> load5=<x> mem_available_gib=<x> mem_psi_some_avg60=<x>
#     io_psi_full_avg60=<x> disk_free_gib=<x> warnings=<n> dry_run=<0|1>
#     jest_max_workers=<n> playwright_workers=<n> home=<path> ts=<epoch>
# (one physical line). A reading that was not taken prints na and one that
# could not be read prints unknown. reason is ok on an admit.
#
# --dry-run takes the same readings and prints the same decision but never
# records an admission, so it consumes no ramp slot and launches nothing.
# wait repeats check until it admits or --timeout seconds pass (default 540,
# inside a ten-minute command limit), printing a line only when the reason
# changes. Each wait attempt has a hard window_secs plus 15-second ceiling, and
# it starts a retry only while that complete attempt fits before the timeout, so
# after its first attempt it never runs past --timeout; when no retry fits it
# prints a stderr note with the last hold reason and exits 1.
#
# Environment: FM_HOME and FM_CONFIG_OVERRIDE resolve this home as the other
# bin/ scripts do; FM_PROC_ROOT_OVERRIDE replaces /proc, mainly for tests.
#
# Exit status: 0 admit, 1 hold, 2 usage error.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROC_ROOT="${FM_PROC_ROOT_OVERRIDE:-/proc}"
JOURNAL_TIMEOUT_SECS=10
DISK_TIMEOUT_SECS=10
LOCK_TIMEOUT_SECS=10
EVIDENCE_TIMEOUT_SECS=2
LOG_MAX_BYTES=262144
LOG_KEEP_LINES=2000
WAIT_TIMEOUT_DEFAULT=540
WAIT_ATTEMPT_MARGIN_SECS=15

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die_usage() {
  echo "fm-heavy-admission: $*" >&2
  exit 2
}

# The one table of keys, kinds, and defaults; `defaults` prints it as the
# documented config file.
DEFAULTS='window_secs int 60
sample_interval_secs posint 10
ramp_secs int 120
warning_lookback_secs int 900
admit_load1_below num 16
admit_load5_below num 20
admit_mem_available_above_gib num 16
reserve_gib num 8
admit_mem_psi_some_avg60_below num 1
admit_io_psi_full_avg60_below num 5
admit_disk_free_above_gib num 20
hold_load1_at num 20
hold_mem_available_at_gib num 12
hold_io_psi_full_avg60_at num 10
disk_path path /
jest_max_workers posint 2
playwright_workers posint 1'

print_defaults() {
  printf '%s\n' \
    '# config/heavy-admission - heavy validation phase admission policy (bin/fm-heavy-admission.sh).' \
    '# Present = policy on. Each line overrides one default; a removed line keeps its default.' \
    '# Proposed starting thresholds, not validated boundaries.'
  printf '%s\n' "$DEFAULTS" | while read -r key _ value; do
    printf '%s=%s\n' "$key" "$value"
  done
}

valid_value() {  # <kind> <value>
  case "$1" in
    int) case "$2" in ''|*[!0-9]*) return 1 ;; esac; [ "${#2}" -le 9 ] ;;
    posint) case "$2" in ''|*[!0-9]*) return 1 ;; esac; [ "${#2}" -le 9 ] && [ "$((10#$2))" -gt 0 ] ;;
    num) printf '%s\n' "$2" | grep -Eq '^[0-9]{1,9}(\.[0-9]{1,6})?$' ;;
    path) case "$2" in /*) ! printf '%s' "$2" | grep -q '[[:space:]]' ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}

set_cfg() { printf -v "CFG_$1" '%s' "$2"; }
cfg() { local v="CFG_$1"; printf '%s' "${!v}"; }

load_defaults() {
  local key kind value
  while read -r key kind value; do
    set_cfg "$key" "$value"
  done <<EOF
$DEFAULTS
EOF
}

CONFIG_ERROR=
load_config() {  # <file>
  local file=$1 line key value kind n=0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    CONFIG_ERROR="config-invalid:unreadable"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$line" in ''|'#'*) continue ;; *=*) ;; *) CONFIG_ERROR="config-invalid:line$n"; return 1 ;; esac
    key=${line%%=*}
    value=${line#*=}
    kind=$(printf '%s\n' "$DEFAULTS" | awk -v k="$key" '$1 == k { print $2; exit }')
    if [ -z "$kind" ]; then
      CONFIG_ERROR="config-invalid:unknown-key-line$n"
      return 1
    fi
    if ! valid_value "$kind" "$value"; then
      CONFIG_ERROR="config-invalid:$key"
      return 1
    fi
    case "$kind" in int|posint) value=$((10#$value)) ;; esac
    set_cfg "$key" "$value"
  done < "$file"
}

# --- arguments ---------------------------------------------------------------
CMD=${1:-}
case "$CMD" in
  -h|--help) usage; exit 0 ;;
  defaults) [ "$#" -eq 1 ] || die_usage "defaults takes no arguments"; print_defaults; exit 0 ;;
  policy) [ "$#" -eq 1 ] || die_usage "policy takes no arguments"; shift ;;
  check|wait) shift ;;
  "") usage >&2; exit 2 ;;
  *) die_usage "unknown command: $CMD" ;;
esac

PEAK_GIB=
DRY_RUN=0
WAIT_TIMEOUT=$WAIT_TIMEOUT_DEFAULT
while [ "$#" -gt 0 ]; do
  case "$1" in
    --peak-gib)
      if [ "$#" -lt 2 ] || ! valid_value num "$2"; then die_usage "--peak-gib needs a non-negative number"; fi
      PEAK_GIB=$2; shift 2 ;;
    --timeout)
      [ "$CMD" = wait ] || die_usage "--timeout applies only to wait"
      if [ "$#" -lt 2 ] || ! valid_value int "$2"; then die_usage "--timeout needs a whole number of seconds"; fi
      WAIT_TIMEOUT=$((10#$2)); shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

load_defaults
ROOT_RESOLVED=1
ROOT_HOME=$(fm_firstmate_root_home "$FM_HOME" 2>/dev/null) || { ROOT_HOME=; ROOT_RESOLVED=0; }
POLICY=off
CONFIG_FILE=none
if [ -e "$CONFIG/heavy-admission" ] || [ -L "$CONFIG/heavy-admission" ]; then
  CONFIG_FILE="$CONFIG/heavy-admission"
elif [ "$ROOT_RESOLVED" = 0 ]; then
  POLICY=unknown
elif [ -e "$ROOT_HOME/config/heavy-admission" ] || [ -L "$ROOT_HOME/config/heavy-admission" ]; then
  CONFIG_FILE="$ROOT_HOME/config/heavy-admission"
fi
if [ "$CONFIG_FILE" != none ]; then
  POLICY=on
  load_config "$CONFIG_FILE" || true
fi
if [ "$CMD" = policy ]; then
  printf '%s\n' "$POLICY"
  exit 0
fi

# --- readings ------------------------------------------------------------------
# Each sample sets the R_* readings ("unknown" when unreadable) and S_REASONS.
R_LOAD1=na R_LOAD5=na R_MEM_KB=na R_MEM_PSI=na R_IO_PSI=na R_DISK_KB=na R_WARN=na
SAMPLES=0

num_ok() { printf '%s\n' "$1" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; }
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }
le() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a <= b) }'; }
kb_to_gib() { awk -v k="$1" 'BEGIN { printf "%.1f", k / 1048576 }'; }
gib_to_kb() { awk -v g="$1" 'BEGIN { printf "%.0f", g * 1048576 }'; }

psi_avg60() {  # <file> <some|full>
  awk -v kind="$2" '$1 == kind { for (i = 2; i <= NF; i++) if ($i ~ /^avg60=/) { sub(/^avg60=/, "", $i); print $i; exit } }' "$1" 2>/dev/null
}

# Prints the matching warning count, or returns 1 when the journal cannot be
# trusted to have answered. journalctl must run without -q, which would also
# silence its stderr notice that system messages are hidden; only stdout is
# counted.
journal_matches() {  # <since-epoch> <pattern> <journalctl selector...>
  local since=$1 pattern=$2 out err errf rc
  shift 2
  command -v journalctl >/dev/null 2>&1 || return 1
  errf=$(mktemp "${TMPDIR:-/tmp}/fm-heavy-admission.XXXXXX" 2>/dev/null) || return 1
  out=$(fm_run_timed "$JOURNAL_TIMEOUT_SECS" journalctl --no-pager -o cat --since "@$since" "$@" 2>"$errf") && rc=0 || rc=$?
  err=$(cat "$errf" 2>/dev/null) || err=
  rm -f "$errf" 2>/dev/null
  [ "$rc" -eq 0 ] || return 1
  [ -z "$err" ] || return 1
  printf '%s\n' "$out" | grep -Ec "$pattern" || true
}

add_reason() { S_REASONS=${S_REASONS:+$S_REASONS,}$1; }

take_sample() {
  local v w1 w2 since peak_kb need_kb disk_out
  S_REASONS=
  SAMPLES=$((SAMPLES + 1))

  v=$(cat "$PROC_ROOT/loadavg" 2>/dev/null) || v=
  R_LOAD1=$(printf '%s\n' "$v" | awk '{ print $1 }')
  R_LOAD5=$(printf '%s\n' "$v" | awk '{ print $2 }')
  if num_ok "$R_LOAD1" && num_ok "$R_LOAD5"; then
    if ge "$R_LOAD1" "$(cfg hold_load1_at)"; then
      add_reason "trip:load1=$R_LOAD1>=$(cfg hold_load1_at)"
    elif ge "$R_LOAD1" "$(cfg admit_load1_below)"; then
      add_reason "below-admit:load1=$R_LOAD1>=$(cfg admit_load1_below)"
    fi
    ge "$R_LOAD5" "$(cfg admit_load5_below)" && add_reason "below-admit:load5=$R_LOAD5>=$(cfg admit_load5_below)"
  else
    R_LOAD1=unknown R_LOAD5=unknown
    add_reason "unreadable:loadavg"
  fi

  R_MEM_KB=$(awk '$1 == "MemAvailable:" { print $2; exit }' "$PROC_ROOT/meminfo" 2>/dev/null)
  if num_ok "$R_MEM_KB"; then
    if le "$R_MEM_KB" "$(gib_to_kb "$(cfg hold_mem_available_at_gib)")"; then
      add_reason "trip:mem_available_gib=$(kb_to_gib "$R_MEM_KB")<=$(cfg hold_mem_available_at_gib)"
    elif le "$R_MEM_KB" "$(gib_to_kb "$(cfg admit_mem_available_above_gib)")"; then
      add_reason "below-admit:mem_available_gib=$(kb_to_gib "$R_MEM_KB")<=$(cfg admit_mem_available_above_gib)"
    elif [ -n "$PEAK_GIB" ]; then
      peak_kb=$(gib_to_kb "$(awk -v p="$PEAK_GIB" -v r="$(cfg reserve_gib)" 'BEGIN { print p + r }')")
      need_kb=$peak_kb
      le "$R_MEM_KB" "$need_kb" && add_reason "below-admit:mem_available_gib=$(kb_to_gib "$R_MEM_KB")<=peak+reserve=$(kb_to_gib "$need_kb")"
    fi
  else
    R_MEM_KB=unknown
    add_reason "unreadable:meminfo"
  fi

  R_MEM_PSI=$(psi_avg60 "$PROC_ROOT/pressure/memory" some)
  if num_ok "$R_MEM_PSI"; then
    ge "$R_MEM_PSI" "$(cfg admit_mem_psi_some_avg60_below)" \
      && add_reason "below-admit:mem_psi_some_avg60=$R_MEM_PSI>=$(cfg admit_mem_psi_some_avg60_below)"
  else
    R_MEM_PSI=unknown
    add_reason "unreadable:memory_pressure"
  fi

  R_IO_PSI=$(psi_avg60 "$PROC_ROOT/pressure/io" full)
  if num_ok "$R_IO_PSI"; then
    if ge "$R_IO_PSI" "$(cfg hold_io_psi_full_avg60_at)"; then
      add_reason "trip:io_psi_full_avg60=$R_IO_PSI>=$(cfg hold_io_psi_full_avg60_at)"
    elif ge "$R_IO_PSI" "$(cfg admit_io_psi_full_avg60_below)"; then
      add_reason "below-admit:io_psi_full_avg60=$R_IO_PSI>=$(cfg admit_io_psi_full_avg60_below)"
    fi
  else
    R_IO_PSI=unknown
    add_reason "unreadable:io_pressure"
  fi

  if disk_out=$(fm_run_timed "$DISK_TIMEOUT_SECS" df -Pk -- "$(cfg disk_path)" 2>/dev/null); then
    R_DISK_KB=$(printf '%s\n' "$disk_out" | awk 'NR == 2 { print $4 }')
  else
    R_DISK_KB=unknown
  fi
  if num_ok "$R_DISK_KB"; then
    le "$R_DISK_KB" "$(gib_to_kb "$(cfg admit_disk_free_above_gib)")" \
      && add_reason "below-admit:disk_free_gib=$(kb_to_gib "$R_DISK_KB")<=$(cfg admit_disk_free_above_gib)"
  else
    R_DISK_KB=unknown
    add_reason "unreadable:disk"
  fi

  since=$(( $(date +%s) - $(cfg warning_lookback_secs) ))
  if w1=$(journal_matches "$since" 'blocked for more than [0-9]+ seconds|hung_task|hung task' -k) \
    && w2=$(journal_matches "$since" '[Ww]atchdog timeout|[Tt]imed out' -u systemd-journald.service); then
    R_WARN=$((w1 + w2))
    [ "$R_WARN" -eq 0 ] || add_reason "trip:warnings=$R_WARN"
  else
    R_WARN=unknown
    add_reason "unreadable:journal"
  fi
  [ -z "$S_REASONS" ]
}

# --- ramp ---------------------------------------------------------------------
RAMP_RECORD=
RAMP_LOCK=
if [ -n "$ROOT_HOME" ]; then
  RAMP_RECORD="$ROOT_HOME/state/heavy-admission.last"
  RAMP_LOCK="$ROOT_HOME/state/.heavy-admission.lock"
fi

# Sets RAMP_REASON to empty when the ramp allows an admission now.
ramp_check() {
  local last now remaining ramp
  RAMP_REASON=
  ramp=$(cfg ramp_secs)
  if [ -z "$RAMP_RECORD" ]; then
    RAMP_REASON="unreadable:root-home"
    return 1
  fi
  [ -e "$RAMP_RECORD" ] || [ -L "$RAMP_RECORD" ] || return 0
  if [ -L "$RAMP_RECORD" ] || [ ! -f "$RAMP_RECORD" ]; then
    RAMP_REASON="unreadable:ramp-record"
    return 1
  fi
  last=$(fm_path_mtime "$RAMP_RECORD")
  case "$last" in ''|*[!0-9]*) RAMP_REASON="unreadable:ramp-record"; return 1 ;; esac
  now=$(date +%s)
  remaining=$((last + ramp - now))
  if [ "$remaining" -gt 0 ]; then
    [ "$remaining" -le "$ramp" ] || remaining=$ramp
    RAMP_REASON="ramp:remaining=${remaining}s"
    return 1
  fi
  return 0
}

record_admission() {
  local tmp
  tmp="$RAMP_RECORD.tmp.$$"
  date +%s > "$tmp" 2>/dev/null && mv -f "$tmp" "$RAMP_RECORD" 2>/dev/null && return 0
  rm -f "$tmp" 2>/dev/null
  return 1
}

# --- decision -----------------------------------------------------------------
record_evidence() {  # <line>
  local line=$1 log tmp rc
  [ "$POLICY" = on ] && [ -n "$ROOT_HOME" ] || return 0
  log="$ROOT_HOME/state/heavy-admission.log"
  tmp="$log.tmp.$$"
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  if fm_run_timed "$EVIDENCE_TIMEOUT_SECS" bash -c '
    line=$1 log=$2 tmp=$3 max_bytes=$4 keep_lines=$5
    exec 9>> "$log" || exit 0
    flock -x 9 || exit 0
    if printf "%s\n" "$line" >&9; then
      if [ "$(wc -c < "$log" 2>/dev/null || echo 0)" -gt "$max_bytes" ]; then
        { tail -n "$keep_lines" "$log" > "$tmp" && cat "$tmp" > "$log"; } 2>/dev/null || true
        rm -f "$tmp" 2>/dev/null
      fi
    fi
  ' _ "$line" "$log" "$tmp" "$LOG_MAX_BYTES" "$LOG_KEEP_LINES" 2>/dev/null; then
    return 0
  else
    rc=$?
  fi
  if fm_timed_out "$rc"; then
    echo "fm-heavy-admission: evidence log operation exceeded its ${EVIDENCE_TIMEOUT_SECS}s deadline; skipped this log write" >&2
  fi
  return 0
}

emit() {  # <decision> <reason>
  local line peak mem disk
  peak=${PEAK_GIB:-unknown}
  mem=$R_MEM_KB; num_ok "$mem" && mem=$(kb_to_gib "$mem")
  disk=$R_DISK_KB; num_ok "$disk" && disk=$(kb_to_gib "$disk")
  line="heavy-admission: decision=$1 reason=$2 policy=$POLICY config=$CONFIG_FILE peak_gib=$peak samples=$SAMPLES load1=$R_LOAD1 load5=$R_LOAD5 mem_available_gib=$mem mem_psi_some_avg60=$R_MEM_PSI io_psi_full_avg60=$R_IO_PSI disk_free_gib=$disk warnings=$R_WARN dry_run=$DRY_RUN jest_max_workers=$(cfg jest_max_workers) playwright_workers=$(cfg playwright_workers) home=$FM_HOME ts=$(date +%s)"
  printf '%s\n' "$line"
  [ "${FM_HEAVY_ATTEMPT_CHILD:-0}" = 1 ] || record_evidence "$line"
}

# Sets DECISION and REASON for one admission attempt.
decide() {
  local elapsed now sleep_for window_start
  SAMPLES=0
  R_LOAD1=na R_LOAD5=na R_MEM_KB=na R_MEM_PSI=na R_IO_PSI=na R_DISK_KB=na R_WARN=na
  if [ "$POLICY" = unknown ]; then
    DECISION=hold REASON=unreadable:root-home
    return 1
  fi
  if [ "$POLICY" = off ]; then
    DECISION=admit REASON=policy-off
    return 0
  fi
  if [ -n "$CONFIG_ERROR" ]; then
    DECISION=hold REASON=$CONFIG_ERROR
    return 1
  fi
  if ! ramp_check; then
    DECISION=hold REASON=$RAMP_REASON
    return 1
  fi
  window_start=$(date +%s)
  elapsed=0
  while :; do
    if ! take_sample; then
      DECISION=hold REASON=$S_REASONS
      return 1
    fi
    now=$(date +%s)
    [ $((now - window_start)) -le "$elapsed" ] || elapsed=$((now - window_start))
    [ "$elapsed" -ge "$(cfg window_secs)" ] && break
    sleep_for=$(cfg sample_interval_secs)
    [ "$sleep_for" -le $(($(cfg window_secs) - elapsed)) ] || sleep_for=$(($(cfg window_secs) - elapsed))
    [ "$sleep_for" -gt 0 ] || break
    sleep "$sleep_for"
    elapsed=$((elapsed + sleep_for))
  done
  if ! fm_lock_acquire_wait_bounded "$RAMP_LOCK" "$LOCK_TIMEOUT_SECS" >/dev/null 2>&1; then
    DECISION=hold REASON=unreadable:ramp-lock
    return 1
  fi
  if ! ramp_check; then
    fm_lock_release "$RAMP_LOCK" >/dev/null 2>&1 || true
    DECISION=hold REASON=$RAMP_REASON
    return 1
  fi
  if [ "$DRY_RUN" != 1 ] && ! record_admission; then
    fm_lock_release "$RAMP_LOCK" >/dev/null 2>&1 || true
    DECISION=hold REASON=unreadable:ramp-record
    return 1
  fi
  fm_lock_release "$RAMP_LOCK" >/dev/null 2>&1 || true
  DECISION=admit REASON=ok
  return 0
}

if [ "$CMD" = check ]; then
  decide && rc=0 || rc=1
  emit "$DECISION" "$REASON"
  exit "$rc"
fi

# wait
wait_deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
attempt_ceiling=$(( $(cfg window_secs) + WAIT_ATTEMPT_MARGIN_SECS ))
attempt_bound=$((attempt_ceiling - 1))
attempt_args=(check)
[ -z "$PEAK_GIB" ] || attempt_args+=(--peak-gib "$PEAK_GIB")
[ "$DRY_RUN" = 0 ] || attempt_args+=(--dry-run)
last_reason=
while :; do
  attempt_out=$(fm_run_timed "$attempt_bound" env FM_HEAVY_ATTEMPT_CHILD=1 "$0" "${attempt_args[@]}") && rc=0 || rc=$?
  if fm_timed_out "$rc"; then
    DECISION=hold REASON=unreadable:timeout
    emit "$DECISION" "$REASON"
    echo "fm-heavy-admission: admission attempt exceeded its ${attempt_ceiling}s ceiling" >&2
    exit 1
  fi
  DECISION=$(printf '%s\n' "$attempt_out" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^decision=/) { sub(/^decision=/, "", $i); print $i; exit } }')
  REASON=$(printf '%s\n' "$attempt_out" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^reason=/) { sub(/^reason=/, "", $i); print $i; exit } }')
  if [ "$rc" -eq 0 ] && [ "$DECISION" = admit ]; then
    printf '%s\n' "$attempt_out"
    record_evidence "$attempt_out"
    exit 0
  fi
  if [ "$REASON" != "$last_reason" ]; then
    printf '%s\n' "$attempt_out"
    record_evidence "$attempt_out"
    last_reason=$REASON
  fi
  now=$(date +%s)
  pause=$(cfg sample_interval_secs)
  case "$REASON" in
    ramp:remaining=*)
      pause=${REASON#ramp:remaining=}
      pause=${pause%s}
      ;;
  esac
  [ "$pause" -gt 0 ] || pause=1
  if [ $((now + pause + attempt_ceiling)) -gt "$wait_deadline" ]; then
    echo "fm-heavy-admission: still holding within the ${WAIT_TIMEOUT}s timeout (reason=$REASON); queue the phase and wait again" >&2
    exit 1
  fi
  sleep "$pause"
  now=$(date +%s)
  if [ $((now + attempt_ceiling)) -gt "$wait_deadline" ]; then
    echo "fm-heavy-admission: still holding within the ${WAIT_TIMEOUT}s timeout (reason=$REASON); queue the phase and wait again" >&2
    exit 1
  fi
done
