# shellcheck shell=bash
# fm-resgate-lib.sh - weekly clock-window resource governance for the captain's
# two Windows hosts, plus GPU exclusivity between Qwen and the JARVIS voice
# worker on the home PC.
#
# Sourced, never executed. bin/fm-resgate.sh is the CLI.
#
# Two fixed roles, not a configurable host list: `work` is the Arbeits-PC
# (default SSH alias Valentino-Arbeit) and `home` is the Heim-PC, RTX 4080
# Super (default SSH alias Valentino). FM_RESGATE_WORK_SSH / FM_RESGATE_HOME_SSH
# override the alias for tests or a renamed host.
#
# Captain's policy (verbatim intent, data/captain.md 02.09.2026):
#   Arbeits-PC: Mo-Fr 19:30-10:00 and the whole weekend fully free for the
#   fleet; Mo-Fr 10:00-19:30 at most 50% of resources.
#   Heim-PC: Mo-Fr 04:00-19:00 free; Mo-Fr 19:00-04:00 and the whole weekend
#   at most 50%.
# Both windows are same-calendar-day spans, so the schedule is expressed as the
# CAPPED window for work (weekday 10:00-19:30) and the FREE window for home
# (weekday 04:00-19:00), with the opposite state as the default. That default
# is what makes the Friday-evening-through-Monday-morning free span on work,
# and the symmetric always-capped weekend on home, fall out of the two small
# per-weekday windows below without separate weekend-boundary code: nothing
# outside a weekday's stated window is ever in either list, weekday or not.
#
# Authoritative clock: this library never asks a remote host for its own
# clock. The schedule decision is computed once, here, against THIS host's
# wall clock forced into Europe/Berlin regardless of the host's configured
# default zone, and only the resulting capped/uncapped state and percentage
# travel to whichever host is being gated. A remote host's local clock can be
# wrong or drifted and must never be able to loosen or defeat the gate.
# FM_RESGATE_NOW_OVERRIDE="<dow 1-7 Mon..Sun> <HH> <MM>" replaces the `date`
# read for tests.
#
# Fail-closed discipline: every measurement this library cannot read - the
# clock, an SSH probe, a port check, a GPU query - yields the MOST restrictive
# answer, never a guess and never "permissive by default". For the schedule
# gate that is capacity_pct=0 ("blocked", stricter than the ordinary 50% cap).
# For the GPU exclusivity check that is "not available" for either workload.
#
# Manual override: state/.resgate-cap-<role> is a plain presence-based marker,
# written the same way state/.afk is (mktemp + mv, so a reader never observes
# a half-written file). Its presence forces capped state immediately,
# independent of which window the clock lands in - but strictly BELOW the
# fail-closed rule above: an unreadable clock stays blocked at 0% even with the
# marker armed, because a control whose whole purpose is to restrict must never
# be able to hand out capacity no measurement supports. docs/configuration.md
# "Fleet resource governance" owns the exact marker paths, the "Kappung" /
# "Kappung auf" trigger words, and which host each form arms.
#
# GPU exclusivity (home PC only): JARVIS voice is detected by its gateway PORT
# (currently 7414, data/learnings.md 23.08.2026), never by process name -
# process-name detection has broken this fleet's integration before. That port
# reading is AUTHORITATIVE and is decided first: a listening gateway means the
# voice worker owns the card, full stop, and the Qwen signals below are never
# even consulted. The aggregate memory reading cannot say WHOSE memory it is,
# so an idle-but-resident Qwen service plus the voice worker's own VRAM would
# otherwise read as contention and refuse the very workload that legitimately
# holds the card - blocking JARVIS voice against itself. Deciding on the port
# first is what makes that misreading impossible rather than merely unlikely.
#
# Qwen detection does NOT use `nvidia-smi --query-compute-apps`, even though
# that looks like the stabler per-process signal on paper. Live-verified
# against the real home host: on Windows/WDDM that query lists every process
# holding an ordinary desktop GPU context - dwm.exe, explorer.exe, every open
# browser - not just genuine compute workloads, and reports `[N/A]` for their
# per-process memory, so there is no field left to filter the noise out by.
# Treating any non-empty row as "Qwen is active" would read as busy any time
# the desktop itself is on. Qwen is instead detected by a named-process check
# (`Get-Process -Name ollama`, the exact identity live-confirmed for today's
# Qwen work; a fresh probe against another engine's name is a config change,
# not a design change) corroborated by AGGREGATE GPU memory
# (`nvidia-smi --query-gpu=memory.used`) clearing FM_RESGATE_GPU_BUSY_MB
# (default 4096 MiB): live-verified idle-ish desktop baseline was ~9 GiB used
# with a loaded model and process present, comfortably clear of ordinary
# desktop compositing. The process check alone would treat an installed-but-
# idle service as "active"; the memory check alone cannot name what is using
# the card; requiring both is the more stable combination the process name
# check alone is not. All three readings (port, process, aggregate memory)
# come from one bounded SSH round trip so a slow host cannot multiply the
# timeout.
#
# Overrides (tests and session pins):
#   FM_RESGATE_WORK_SSH, FM_RESGATE_HOME_SSH
#   FM_RESGATE_NOW_OVERRIDE
#   FM_RESGATE_VOICE_PORT (default 7414)
#   FM_RESGATE_GPU_BUSY_MB (default 4096)
#   FM_RESGATE_SSH_TIMEOUT (seconds, default 5; must be a positive integer)
#   FM_RESGATE_SKIP_REMOTE=1 (never probe, always fail closed - tests only)

_FM_RESGATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_RESGATE_LIB_DIR/fm-timeout-lib.sh"

FM_RESGATE_WORK_SSH_DEFAULT=Valentino-Arbeit
FM_RESGATE_HOME_SSH_DEFAULT=Valentino
FM_RESGATE_VOICE_PORT_DEFAULT=7414
FM_RESGATE_GPU_BUSY_MB_DEFAULT=4096
FM_RESGATE_SSH_TIMEOUT_DEFAULT=5
FM_RESGATE_GPU_PROCESS_NAME=ollama
FM_RESGATE_WORK_CAP_START_MIN=$((10 * 60))       # 10:00
FM_RESGATE_WORK_CAP_END_MIN=$((19 * 60 + 30))    # 19:30
FM_RESGATE_HOME_FREE_START_MIN=$((4 * 60))       # 04:00
FM_RESGATE_HOME_FREE_END_MIN=$((19 * 60))        # 19:00
FM_RESGATE_CAPPED_PCT=50
FM_RESGATE_UNCAPPED_PCT=100
FM_RESGATE_BLOCKED_PCT=0
FM_RESGATE_BERLIN_STANDARD='CET +0100'
FM_RESGATE_BERLIN_SUMMER='CEST +0200'

fm_resgate_role_ok() {
  case "${1:-}" in work | home) return 0 ;; esac
  return 1
}

fm_resgate_ssh_alias() { # <role>
  case "$1" in
    work) printf '%s\n' "${FM_RESGATE_WORK_SSH:-$FM_RESGATE_WORK_SSH_DEFAULT}" ;;
    home) printf '%s\n' "${FM_RESGATE_HOME_SSH:-$FM_RESGATE_HOME_SSH_DEFAULT}" ;;
  esac
}

fm_resgate_is_uint() {
  case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac
  return 0
}

# A plausible TCP port. Every tunable that reaches a measurement is validated
# before it is used, so a mistyped session pin cannot silently turn into a
# permissive reading (an invalid threshold that makes the -ge comparison error
# out, or an invalid port that probes something other than the gateway).
fm_resgate_is_port() {
  fm_resgate_is_uint "${1:-}" || return 1
  [ "${#1}" -le 5 ] || return 1
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# Sets FM_RESGATE_NOW_DOW (1=Monday..7=Sunday) and FM_RESGATE_NOW_MOD (minutes
# since local midnight, 0-1439), read from ONE `date` call so a rollover
# between day-of-week and time-of-day cannot be observed straddling midnight.
# Returns 1 on any unreadable or malformed clock; callers must fail closed on
# that, never fall back to a default time.
#
# The same read also carries the resolved zone abbreviation and UTC offset,
# because a non-zero exit is NOT the failure mode that matters here: `date`
# never fails on a zone it cannot resolve, it silently falls back to UTC and
# exits 0. On a host without tzdata the gate would then read Berlin 10:30 CEST
# as 08:30, land outside the work PC's 10:00-19:30 window, and hand the fleet
# 100% of the captain's machine in the middle of his working hours - a wrong
# permissive answer from an effectively unreadable clock. Requiring the
# abbreviation and offset to be a matching Europe/Berlin pair proves the zone
# database entry actually loaded; anything else is unreadable and fails closed.
fm_resgate_now_fields() {
  local raw dow hh mm
  FM_RESGATE_NOW_DOW=
  FM_RESGATE_NOW_MOD=
  if [ -n "${FM_RESGATE_NOW_OVERRIDE:-}" ]; then
    raw=$FM_RESGATE_NOW_OVERRIDE
  else
    raw=$(TZ=Europe/Berlin date +'%u %H %M %Z %z' 2>/dev/null) || return 1
    # shellcheck disable=SC2086
    set -- $raw
    [ "$#" -eq 5 ] || return 1
    case "$4 $5" in
      "$FM_RESGATE_BERLIN_STANDARD" | "$FM_RESGATE_BERLIN_SUMMER") ;;
      *) return 1 ;;
    esac
    raw="$1 $2 $3"
  fi
  # shellcheck disable=SC2086
  set -- $raw
  [ "$#" -eq 3 ] || return 1
  dow=$1 hh=$2 mm=$3
  fm_resgate_is_uint "$dow" || return 1
  fm_resgate_is_uint "$hh" || return 1
  fm_resgate_is_uint "$mm" || return 1
  [ "$dow" -ge 1 ] && [ "$dow" -le 7 ] || return 1
  [ "$hh" -le 23 ] || return 1
  [ "$mm" -le 59 ] || return 1
  FM_RESGATE_NOW_DOW=$dow
  FM_RESGATE_NOW_MOD=$((10#$hh * 60 + 10#$mm))
  return 0
}

# Schedule state for <role> at the current moment, ignoring any manual
# override. Sets FM_RESGATE_SCHEDULE_STATE to one of:
#   uncapped  - full resources
#   capped    - the 50% window applies
#   blocked   - the authoritative clock could not be read; fail closed to 0%,
#               stricter than an ordinary capped window, because a schedule
#               decision cannot be made at all.
# and FM_RESGATE_SCHEDULE_REASON to a short human-readable reason.
fm_resgate_schedule_state() { # <role>
  local role=$1 dow mod weekday
  fm_resgate_role_ok "$role" || {
    FM_RESGATE_SCHEDULE_STATE=blocked
    FM_RESGATE_SCHEDULE_REASON="unknown role: $role"
    return 1
  }
  if ! fm_resgate_now_fields; then
    FM_RESGATE_SCHEDULE_STATE=blocked
    FM_RESGATE_SCHEDULE_REASON='authoritative clock unreadable; refusing to guess the schedule window'
    return 0
  fi
  dow=$FM_RESGATE_NOW_DOW
  mod=$FM_RESGATE_NOW_MOD
  weekday=0
  [ "$dow" -ge 1 ] && [ "$dow" -le 5 ] && weekday=1
  case "$role" in
    work)
      if [ "$weekday" -eq 1 ] \
        && [ "$mod" -ge "$FM_RESGATE_WORK_CAP_START_MIN" ] \
        && [ "$mod" -lt "$FM_RESGATE_WORK_CAP_END_MIN" ]; then
        FM_RESGATE_SCHEDULE_STATE=capped
        FM_RESGATE_SCHEDULE_REASON='Mo-Fr 10:00-19:30 on the work PC (captain working hours)'
      else
        FM_RESGATE_SCHEDULE_STATE=uncapped
        FM_RESGATE_SCHEDULE_REASON='outside Mo-Fr 10:00-19:30 on the work PC (evening, night, or weekend)'
      fi
      ;;
    home)
      if [ "$weekday" -eq 1 ] \
        && [ "$mod" -ge "$FM_RESGATE_HOME_FREE_START_MIN" ] \
        && [ "$mod" -lt "$FM_RESGATE_HOME_FREE_END_MIN" ]; then
        FM_RESGATE_SCHEDULE_STATE=uncapped
        FM_RESGATE_SCHEDULE_REASON='Mo-Fr 04:00-19:00 on the home PC'
      else
        FM_RESGATE_SCHEDULE_STATE=capped
        FM_RESGATE_SCHEDULE_REASON='outside Mo-Fr 04:00-19:00 on the home PC (evening, night, or weekend)'
      fi
      ;;
  esac
  return 0
}

# <state-dir> for the override marker files; overridable for tests exactly
# like every other script in this repo.
fm_resgate_override_path() { # <state-dir> <role>
  printf '%s/.resgate-cap-%s\n' "$1" "$2"
}

fm_resgate_override_active() { # <state-dir> <role>
  local path
  path=$(fm_resgate_override_path "$1" "$2")
  [ -e "$path" ]
}

# Arm the manual override for <role>. Atomic write (mktemp + mv), matching
# state/.afk, so a concurrent reader never observes a half-written marker.
fm_resgate_override_set() { # <state-dir> <role> [note]
  local state=$1 role=$2 note=${3:-} path pending
  fm_resgate_role_ok "$role" || return 1
  [ -d "$state" ] || mkdir -p "$state" || return 1
  path=$(fm_resgate_override_path "$state" "$role")
  pending=$(mktemp "$path.pending.XXXXXX") || return 1
  {
    printf 'armed_at=%s\n' "$(TZ=Europe/Berlin date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || printf unknown)"
    printf 'note=%s\n' "${note:-Kappung}"
  } > "$pending" && mv -f "$pending" "$path" && return 0
  rm -f "$pending" 2>/dev/null || true
  return 1
}

# Release the manual override for <role>. Returns 1 when the marker is still
# there afterwards (an unwritable state directory, a stale mount): reporting a
# clear that did not happen would leave the role pinned at the 50% cap while
# everyone believes "Kappung auf" took effect.
fm_resgate_override_clear() { # <state-dir> <role>
  local path
  fm_resgate_role_ok "$2" || return 1
  path=$(fm_resgate_override_path "$1" "$2")
  rm -f "$path" 2>/dev/null
  [ ! -e "$path" ]
}

# Effective state for <role>: an active override forces "capped" immediately,
# regardless of which window a READABLE clock lands in. Sets FM_RESGATE_STATE
# and FM_RESGATE_REASON.
#
# The schedule is computed FIRST and "blocked" wins outright, because the
# override and the fail-closed rule collide when the authoritative clock is
# unreadable: the override loosens 0% to 50%, and the whole point of the
# override is to restrict, never to grant capacity a measurement could not
# justify. Fail-closed takes precedence, so arming the cap can only ever
# tighten the gate.
# shellcheck disable=SC2034
fm_resgate_effective_state() { # <state-dir> <role>
  local state=$1 role=$2
  fm_resgate_schedule_state "$role"
  if [ "$FM_RESGATE_SCHEDULE_STATE" = blocked ]; then
    FM_RESGATE_STATE=$FM_RESGATE_SCHEDULE_STATE
    FM_RESGATE_REASON=$FM_RESGATE_SCHEDULE_REASON
    return 0
  fi
  if fm_resgate_override_active "$state" "$role"; then
    FM_RESGATE_STATE=capped
    FM_RESGATE_REASON='manual override armed (Kappung); forced capped regardless of the clock window'
    return 0
  fi
  FM_RESGATE_STATE=$FM_RESGATE_SCHEDULE_STATE
  FM_RESGATE_REASON=$FM_RESGATE_SCHEDULE_REASON
  return 0
}

# Percentage of resources <role> may use right now: 100 (uncapped), 50
# (capped), or 0 (blocked - the clock or role was unreadable). Sets
# FM_RESGATE_PCT and FM_RESGATE_REASON.
# shellcheck disable=SC2034
fm_resgate_capacity_pct() { # <state-dir> <role>
  fm_resgate_effective_state "$1" "$2"
  case "$FM_RESGATE_STATE" in
    uncapped) FM_RESGATE_PCT=$FM_RESGATE_UNCAPPED_PCT ;;
    capped) FM_RESGATE_PCT=$FM_RESGATE_CAPPED_PCT ;;
    *) FM_RESGATE_PCT=$FM_RESGATE_BLOCKED_PCT ;;
  esac
  return 0
}

# Apply a percentage to a raw resource/slot count. Integer floor division;
# fails closed to 0 on a non-numeric raw count or an out-of-range percentage
# rather than passing either through unchecked.
fm_resgate_apply_pct() { # <raw-count> <pct 0-100>
  local raw=$1 pct=$2
  fm_resgate_is_uint "$raw" || { printf '0\n'; return 0; }
  fm_resgate_is_uint "$pct" || { printf '0\n'; return 0; }
  [ "$pct" -le 100 ] || { printf '0\n'; return 0; }
  printf '%s\n' $(((10#$raw * 10#$pct) / 100))
}

fm_resgate_voice_port() {
  printf '%s\n' "${FM_RESGATE_VOICE_PORT:-$FM_RESGATE_VOICE_PORT_DEFAULT}"
}

# The validated SSH connect timeout in seconds, or exit 1 when the pin is
# unusable. Zero is rejected alongside the non-numeric and negative forms
# because bin/fm-timeout-lib.sh's header states a non-positive bound is not a
# bound at all - `timeout 0` and the perl fallback's `alarm 0` both DISABLE the
# deadline - so a pin of 0 or -5 would compute a bound of 5 or 0 seconds and
# hand an unreachable host an unbounded probe instead of a bounded one.
fm_resgate_ssh_timeout() {
  local secs=${FM_RESGATE_SSH_TIMEOUT:-$FM_RESGATE_SSH_TIMEOUT_DEFAULT}
  fm_resgate_is_uint "$secs" || return 1
  [ "$secs" -ge 1 ] || return 1
  printf '%s\n' "$secs"
}

fm_resgate_ssh_raw() { # <host> <remote-cmd>
  local host=$1 cmd=$2 bound secs
  secs=$(fm_resgate_ssh_timeout) || return 1
  bound=$((secs + 5))
  fm_run_timed "$bound" ssh \
    -o BatchMode=yes \
    -o ConnectTimeout="$secs" \
    -o ServerAliveInterval=2 \
    -o ServerAliveCountMax=2 \
    -o ForwardAgent=no \
    "$host" "$cmd"
}

fm_resgate_gpu_busy_mb() {
  printf '%s\n' "${FM_RESGATE_GPU_BUSY_MB:-$FM_RESGATE_GPU_BUSY_MB_DEFAULT}"
}

# One PowerShell round trip: the JARVIS-voice gateway port's listen state, the
# Qwen-identifying named process, and aggregate GPU memory used (see the file
# header for why aggregate memory + named process, not per-process
# compute-apps attribution). Every line is emitted unconditionally, including
# on failure (<reading>=probe-failed), so absorption can tell "this specific
# reading failed" apart from "no probe output arrived at all".
#
# All three readings run under -ErrorAction Stop inside try/catch rather than
# -ErrorAction SilentlyContinue, because silencing the error makes an absent
# result indistinguishable from a failed measurement: a missing NetTCPIP
# module or an unhealthy CIM service would otherwise read as the fully
# permissive "voice_port=not-listening" while the gateway is in fact up. Only
# the one error identity that genuinely means "nothing matched"
# (CmdletizationQuery_NotFound* for the port, NoProcessFoundForGivenName* for
# the process) is reported as a negative reading; every other failure,
# including the cmdlet not existing at all, reports probe-failed, which
# absorption maps to unknown and the owner decision fails closed on.
fm_resgate_home_gpu_probe_cmd() { # <port> <process-name>
  local port=$1 proc=$2 cmd
  cmd=$(cat <<'CMD'
try {
  $conn = Get-NetTCPConnection -LocalPort @PORT@ -State Listen -ErrorAction Stop
  if ($conn) { Write-Output 'FM_RESGATE voice_port=listening' } else { Write-Output 'FM_RESGATE voice_port=not-listening' }
} catch {
  if ($_.FullyQualifiedErrorId -like 'CmdletizationQuery_NotFound*') { Write-Output 'FM_RESGATE voice_port=not-listening' }
  else { Write-Output 'FM_RESGATE voice_port=probe-failed' }
}
try {
  $proc = Get-Process -Name '@PROCESS@' -ErrorAction Stop
  if ($proc) { Write-Output 'FM_RESGATE gpu_process=running' } else { Write-Output 'FM_RESGATE gpu_process=not-running' }
} catch {
  if ($_.FullyQualifiedErrorId -like 'NoProcessFoundForGivenName*') { Write-Output 'FM_RESGATE gpu_process=not-running' }
  else { Write-Output 'FM_RESGATE gpu_process=probe-failed' }
}
try {
  $used = & nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null
  if ($LASTEXITCODE -eq 0 -and $used) { Write-Output ('FM_RESGATE gpu_used_mb=' + ($used | Select-Object -First 1).Trim()) }
  else { Write-Output 'FM_RESGATE gpu_used_mb=probe-failed' }
} catch {
  Write-Output 'FM_RESGATE gpu_used_mb=probe-failed'
}
CMD
  )
  cmd=${cmd//@PORT@/$port}
  printf '%s\n' "${cmd//@PROCESS@/$proc}"
}

# Parses fm_resgate_home_gpu_probe_cmd's output into FM_RESGATE_GPU_VOICE,
# FM_RESGATE_GPU_PROCESS, and FM_RESGATE_GPU_USED_MB ("yes"/"no", or a MiB
# integer; empty/unset when that line never arrived or read "probe-failed" -
# both mean "unknown", never a guessed permissive value). Returns 1 when NOT
# EVEN ONE line arrived at all (SSH itself failed).
# The remote host is Windows PowerShell, whose Write-Output terminates every
# line with CRLF; `read` only strips the trailing LF, so each line keeps a
# trailing CR that would otherwise make every exact-match case pattern below
# fail silently and fall through to "unknown" - live-verified against the
# real home host, not a hypothetical.
fm_resgate_absorb_gpu_probe() { # <text>
  local text=$1 line key val seen=0
  FM_RESGATE_GPU_VOICE=
  FM_RESGATE_GPU_PROCESS=
  FM_RESGATE_GPU_USED_MB=
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      FM_RESGATE\ *)
        seen=1
        key=${line#FM_RESGATE }
        val=${key#*=}
        key=${key%%=*}
        case "$key" in
          voice_port)
            case "$val" in
              listening) FM_RESGATE_GPU_VOICE=yes ;;
              not-listening) FM_RESGATE_GPU_VOICE=no ;;
            esac
            ;;
          gpu_process)
            case "$val" in
              running) FM_RESGATE_GPU_PROCESS=yes ;;
              not-running) FM_RESGATE_GPU_PROCESS=no ;;
            esac
            ;;
          gpu_used_mb)
            fm_resgate_is_uint "$val" && FM_RESGATE_GPU_USED_MB=$val
            ;;
        esac
        ;;
    esac
  done <<EOF
$text
EOF
  [ "$seen" -eq 1 ]
}

# Which workload currently owns the home PC's GPU, from a fresh probe. Sets
# FM_RESGATE_GPU_OWNER to one of: none, qwen, voice, unknown.
#
# The voice gateway port decides first and alone: a listening port means
# owner=voice, and the Qwen signals are neither computed nor consulted (see
# the file header for why attributing aggregate card memory to Qwen while the
# voice worker holds the card would block that worker against itself). Only
# with the port readably NOT listening does Qwen's own signal decide, and Qwen
# is "active" then only when BOTH the named process is running AND aggregate
# GPU memory clears FM_RESGATE_GPU_BUSY_MB - see the file header for why
# either signal alone is insufficient. There is therefore no "both active at
# once" reading to report: the two signals are consulted in order, never
# weighed against each other.
#
# "unknown" fails closed and covers every unmeasurable case: an unreachable
# host, a probe that returned no lines at all, an out-of-range
# FM_RESGATE_VOICE_PORT, a non-numeric FM_RESGATE_GPU_BUSY_MB, or a
# non-positive FM_RESGATE_SSH_TIMEOUT (which would otherwise probe the wrong
# port, make the threshold comparison error out and read as free, or run the
# probe unbounded), or any individual reading that the decision still needs
# coming back unknown (a failed nvidia-smi call, a port or process check that
# could not be performed) - a partial reading is never completed with a
# guess.
# shellcheck disable=SC2034
fm_resgate_home_gpu_owner() {
  local host out qwen_active port busy
  FM_RESGATE_GPU_OWNER=unknown
  FM_RESGATE_GPU_VOICE=
  FM_RESGATE_GPU_PROCESS=
  FM_RESGATE_GPU_USED_MB=
  if [ "${FM_RESGATE_SKIP_REMOTE:-}" = 1 ]; then
    return 1
  fi
  port=$(fm_resgate_voice_port)
  busy=$(fm_resgate_gpu_busy_mb)
  fm_resgate_is_port "$port" || return 1
  fm_resgate_is_uint "$busy" || return 1
  fm_resgate_ssh_timeout > /dev/null || return 1
  host=$(fm_resgate_ssh_alias home)
  out=$(fm_resgate_ssh_raw "$host" \
    "$(fm_resgate_home_gpu_probe_cmd "$port" "$FM_RESGATE_GPU_PROCESS_NAME")" \
    2>/dev/null) || out=
  fm_resgate_absorb_gpu_probe "$out" || return 1
  case "$FM_RESGATE_GPU_VOICE" in yes | no) ;; *) return 1 ;; esac
  if [ "$FM_RESGATE_GPU_VOICE" = yes ]; then
    FM_RESGATE_GPU_OWNER=voice
    return 0
  fi
  case "$FM_RESGATE_GPU_PROCESS" in yes | no) ;; *) return 1 ;; esac
  fm_resgate_is_uint "${FM_RESGATE_GPU_USED_MB:-}" || return 1
  qwen_active=no
  if [ "$FM_RESGATE_GPU_PROCESS" = yes ] \
    && [ "$FM_RESGATE_GPU_USED_MB" -ge "$busy" ]; then
    qwen_active=yes
  fi
  if [ "$qwen_active" = yes ]; then
    FM_RESGATE_GPU_OWNER=qwen
  else
    FM_RESGATE_GPU_OWNER=none
  fi
  return 0
}

# May <workload> (qwen|voice) start or keep running on the home PC's GPU right
# now? Sets FM_RESGATE_GPU_REASON. Fails closed (returns 1) on unknown: an
# unmeasurable reading must never be read as permission, and must never let one
# side quietly work around the other's reservation.
# shellcheck disable=SC2034
fm_resgate_gpu_available_for() { # <qwen|voice>
  local want=$1
  case "$want" in qwen | voice) ;; *) return 1 ;; esac
  fm_resgate_home_gpu_owner
  case "$FM_RESGATE_GPU_OWNER" in
    none)
      FM_RESGATE_GPU_REASON='GPU is free'
      return 0
      ;;
    qwen)
      if [ "$want" = qwen ]; then
        FM_RESGATE_GPU_REASON='Qwen already holds the GPU'
        return 0
      fi
      FM_RESGATE_GPU_REASON='GPU is reserved for Qwen; JARVIS voice must not start'
      return 1
      ;;
    voice)
      if [ "$want" = voice ]; then
        FM_RESGATE_GPU_REASON='JARVIS voice already holds the GPU'
        return 0
      fi
      FM_RESGATE_GPU_REASON='GPU is reserved for JARVIS voice; Qwen must not start'
      return 1
      ;;
    *)
      FM_RESGATE_GPU_REASON='GPU ownership could not be measured; refusing rather than guessing'
      return 1
      ;;
  esac
}
