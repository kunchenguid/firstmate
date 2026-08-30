# shellcheck shell=bash
# fm-capacity-lib.sh - resource-aware worker slots and compute-host routing.
#
# Source this file. bin/fm-capacity.sh is the CLI, and bin/fm-spawn.sh consults
# fm_capacity_allow_new_worker before a fresh ship or scout launch.
# docs/configuration.md "Compute hosts and worker slots" owns the optional
# config/compute-hosts.json schema. This header owns the slot formula, the
# fresh-probe contract, same-task uniqueness, and the refuse-rather-than-kill
# spawn gate.
#
# What this is not: it does not choose harness, model, or effort, and it does
# not read config/crew-dispatch.json.
#
# Slot formula (local supervisor host, integer arithmetic):
#   cpu_slots    = max(1, nproc / 3)
#   ram_slots    = max(0, (mem_avail_mb - 4096) / 3072) when mem_avail_mb is known;
#                  when RAM cannot be read, ram_slots is the ceiling (CPU and
#                  load still protect the host)
#   load_cap     = 0 when load1 is missing or not a number, or when load1 >= nproc;
#                  1 when load1 >= 0.7 * nproc;
#                  otherwise the ceiling
#   slots        = min(cpu_slots, ram_slots, load_cap, 5)
# The ceiling 5 is a safety cap on the formula, not a rigid agent count.
#
# Occupancy is host-scoped, not home-scoped: the budget protects one physical
# server, so N firstmate homes on this host share one budget instead of taking
# N independent ones. The scanned set is this home, the local primary home it
# was seeded from when it is a secondmate home (.fm-secondmate-parent), and
# every locally routed secondmate registered under that primary
# (data/secondmates.md). Remote secondmates run on another machine and are not
# counted. Home paths are canonicalized before they are deduplicated, so the
# same home reached through a trailing slash, a symlink, or a registry spelling
# that differs from FM_HOME is counted once rather than twice.
# `fm-capacity.sh slots` prints homes_scanned so the measurement is auditable.
#
# A slot is held by a LIVE worker, not by a metadata record: each ship/scout
# record's endpoint is classified through fm-backend.sh's agent-state contract.
# `alive` always keeps the slot and `dead`/`missing` always free it, so a task
# parked on a captain hold or waiting on a merge with no running worker stops
# blocking fresh dispatch and a positively live worker is never freed.
# Every other verdict is a NON-answer, and there are backends where it is the
# only answer available: zellij, orca and cmux have no recovery classifier at
# all, so fm_backend_agent_state always prints `unverified` there and liveness
# can never be proven negative. Treating that as "still live" would let a home
# on those backends accumulate finished records until the budget is
# permanently full. So for a non-answer the task's own DECLARED state decides,
# using the terminal vocabulary bin/fm-classify-lib.sh already owns rather than
# a second copy of it: done, failed, blocked, needs-decision, paused,
# captain-held, and the legacy bare lines that carry no leading verb at all
# (`PR ready ...`, `merged`, `checks green`, each home's own FM_CAPTAIN_RE) all
# mean parked, merge-waiting, or finished with the pane gone, and all release
# the slot. A task that is actively working - or that has declared nothing yet,
# such as a worker one second after launch - keeps it. That second half is the
# fail-closed carve-out: an unknown endpoint on active work is exactly where a
# wrong guess would oversubscribe the host, so it is resolved in favour of
# holding the slot.
# Task identity is separate from that: same-task uniqueness reads the metadata
# records themselves, EVERY regular record in the state dir including kinds
# that never occupy a worker slot. A record that is not an independent worker -
# a live secondmate's endpoint above all - blocks the id for as long as it
# exists, because a fresh spawn would rewrite it out from under its owner. A
# ship or scout record blocks the id only while its worker is still live, so a
# task can never get a second concurrent worker, while one whose pane died with
# its worktree and commits intact stays restartable instead of needing its
# metadata deleted by hand.
# Idle secondmates do not occupy a worker slot. A relaunch replaces one worker
# and does not consume an extra slot. The gate never interrupts another task.
#
# Host routing (recompute-heavy / host-bound work only):
#   Session pins (flags/env) merge over config/compute-hosts.json field by
#   field: pinning only the preferred host keeps the configured fallback, and
#   an unrecognised pinned kind is rejected exactly like an unrecognised kind
#   inside the config file rather than coerced to a default.
#   Probe configured preferred, then fallback, with a bounded SSH call. A host
#   with no run-queue load average (Windows) is asked for several busy-percent
#   samples across a short window, and the mean is gated as a percentage
#   (< FM_CAPACITY_PCT_MAX_BUSY) rather than rescaled into a load1: a
#   one-second burst cannot demote the preferred host, and a host sitting at
#   99% busy is still refused. A sample the host could not actually take is
#   omitted rather than reported as 0%, so a broken CPU counter reads as
#   unmeasurable - and unsuitable - instead of idle.
#   Prefer the preferred host when it is freshly reachable and suitable.
#   Use the fallback only when the preferred is not.
#   Never assign that class of work onto the protected local supervisor
#   just because both remotes failed; route=none in that case.
#   A cpu-kind host is suitable when it has CPU headroom (load1 < nproc, or a
#   mean busy percent below FM_CAPACITY_PCT_MAX_BUSY on a host that reports
#   only a percentage) and mem_avail_mb >= 2048.
#   A gpu-kind host must clear those same host gates AND report nvidia-smi
#   util <= 90 with at least 1024 MiB free: free VRAM on a machine whose CPU is
#   pinned or whose RAM is exhausted is not usable capacity, and the fallback
#   must get its chance. Those host gates also reject an unmeasurable host, on
#   each axis independently: a host that returned no usable CPU sample at all -
#   the POSIX probe omits load1 when /proc/loadavg is unreadable, the Windows
#   probe omits load_pct when the processor query fails - has no headroom
#   measurement to pass, and an unreadable /proc/meminfo reports
#   mem_avail_mb=0, which fails the RAM gate. Neither reads as an idle host.
#   `fm-capacity.sh route` prints the reading each probe actually produced.
#
# Freshness: every probe() call measures again. Nothing here caches a prior
# host snapshot across invocations.
#
# Overrides (tests and session pins; never inferred from a stale file):
#   FM_CAPACITY_NPROC, FM_CAPACITY_MEM_AVAIL_MB, FM_CAPACITY_LOAD1
#   FM_CAPACITY_SKIP_REMOTE=1
#   FM_CAPACITY_PREFERRED_SSH, FM_CAPACITY_PREFERRED_KIND
#   FM_CAPACITY_FALLBACK_SSH, FM_CAPACITY_FALLBACK_KIND
#   FM_CAPACITY_SSH_TIMEOUT (seconds, default 5)

_FM_CAPACITY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_CAPACITY_LIB_DIR/fm-timeout-lib.sh"
# Endpoint liveness and the local-home topology come from the surfaces that
# already own them; a caller that sourced them first keeps its own copy.
if ! declare -F fm_backend_agent_alive >/dev/null 2>&1; then
  # shellcheck source=bin/fm-backend.sh
  . "$_FM_CAPACITY_LIB_DIR/fm-backend.sh"
fi
if ! declare -F secondmate_registry_parse_line >/dev/null 2>&1; then
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$_FM_CAPACITY_LIB_DIR/fm-secondmate-registry-lib.sh"
fi
if ! declare -F fm_secondmate_parent_record_parse >/dev/null 2>&1; then
  # shellcheck source=bin/fm-secondmate-parent-lib.sh
  . "$_FM_CAPACITY_LIB_DIR/fm-secondmate-parent-lib.sh"
fi
if ! declare -F status_line_verb >/dev/null 2>&1; then
  # shellcheck source=bin/fm-classify-lib.sh
  . "$_FM_CAPACITY_LIB_DIR/fm-classify-lib.sh"
fi

FM_WORK_LOOP_MIN_REAL=3

FM_CAPACITY_SLOT_CEILING=5
FM_CAPACITY_CPU_PER_SLOT=3
FM_CAPACITY_RAM_RESERVE_MB=4096
FM_CAPACITY_RAM_PER_SLOT_MB=3072
FM_CAPACITY_GPU_MIN_FREE_MB=1024
FM_CAPACITY_GPU_MAX_UTIL=90
FM_CAPACITY_CPU_MIN_MEM_MB=2048
FM_CAPACITY_CONFIG_FILE=compute-hosts.json
# A Windows host has no run-queue load average to read, so its busy percentage
# is sampled several times across a short window and averaged. One sample is a
# ~1-second CPU-busy reading: a browser or compile burst pins it at 100 and
# would flip an otherwise healthy Heim-PC to unsuitable, inverting the routing
# preference. Averaging dilutes a burst that short while a genuinely pinned
# machine still reads ~100 across every sample, so the sustained-overload gate
# survives.
FM_CAPACITY_WIN_LOAD_SAMPLES=3
FM_CAPACITY_WIN_LOAD_SAMPLE_MS=1000
# ... and the averaged percentage is then gated as a PERCENTAGE. Rescaling it
# into a load1 equivalent and reusing `load1 < nproc` would mean "refuse only
# at literally 100% busy", which lets a machine sitting at 99% through; a busy
# fraction and a run-queue depth are different measurements and get different
# thresholds. A mean busy percent at or above this is a sustained overload.
FM_CAPACITY_PCT_MAX_BUSY=90

fm_capacity_is_uint() {
  case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac
  return 0
}

fm_capacity_is_number() {
  local v=${1:-}
  case "$v" in
    '' | *[!0-9.]* | .) return 1 ;;
  esac
  case "${v#*.}" in *.*) return 1 ;; esac
  return 0
}

fm_capacity_ssh_alias_ok() {
  case "${1:-}" in
    '' | -* | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

fm_capacity_kind_ok() {
  case "${1:-}" in cpu | gpu) return 0 ;; esac
  return 1
}

fm_capacity_load_hundredths() {
  local v=$1
  fm_capacity_is_number "$v" || return 1
  printf '%s\n' "$v" | awk '{ printf "%d", ($1 + 0) * 100 }'
}

fm_capacity_min() {
  local a=$1 b=$2
  [ "$a" -lt "$b" ] && printf '%s\n' "$a" || printf '%s\n' "$b"
}

fm_capacity_max() {
  local a=$1 b=$2
  [ "$a" -gt "$b" ] && printf '%s\n' "$a" || printf '%s\n' "$b"
}

# Mean of the given numeric samples, to two decimals. Non-numeric samples are
# skipped; returns 1 when nothing numeric was given.
fm_capacity_mean() { # <value>...
  [ "$#" -gt 0 ] || return 1
  printf '%s\n' "$@" | awk '
    $1 ~ /^[0-9]+(\.[0-9]+)?$/ { sum += $1; n++ }
    END { if (n == 0) exit 1; printf "%.2f", sum / n }
  '
}

# Integer slot count from one local measurement triple. Unknown RAM (empty or
# non-numeric mem_avail_mb) skips the RAM axis rather than inventing a size.
# Unknown load (empty or non-numeric load1) yields 0 slots rather than idle.
fm_capacity_slots_from_local() { # <nproc> <mem_avail_mb-or-empty> <load1>
  local nproc=$1 mem=$2 load1=$3 cpu_slots ram_slots load_cap load_h nproc_h slots
  fm_capacity_is_uint "$nproc" || { printf '0\n'; return 0; }
  [ "$nproc" -gt 0 ] || { printf '0\n'; return 0; }
  cpu_slots=$(fm_capacity_max 1 $((nproc / FM_CAPACITY_CPU_PER_SLOT)))
  if fm_capacity_is_uint "$mem"; then
    ram_slots=$(fm_capacity_max 0 \
      $(((mem - FM_CAPACITY_RAM_RESERVE_MB) / FM_CAPACITY_RAM_PER_SLOT_MB)))
  else
    ram_slots=$FM_CAPACITY_SLOT_CEILING
  fi
  load_h=$(fm_capacity_load_hundredths "$load1") || { printf '0\n'; return 0; }
  nproc_h=$((nproc * 100))
  if [ "$load_h" -ge "$nproc_h" ]; then
    load_cap=0
  elif [ "$load_h" -ge $((nproc * 70)) ]; then
    load_cap=1
  else
    load_cap=$FM_CAPACITY_SLOT_CEILING
  fi
  slots=$(fm_capacity_min "$cpu_slots" "$ram_slots")
  slots=$(fm_capacity_min "$slots" "$load_cap")
  slots=$(fm_capacity_min "$slots" "$FM_CAPACITY_SLOT_CEILING")
  [ "$slots" -ge 0 ] || slots=0
  printf '%s\n' "$slots"
}

fm_capacity_read_nproc() {
  if [ -n "${FM_CAPACITY_NPROC:-}" ]; then
    printf '%s\n' "$FM_CAPACITY_NPROC"
    return 0
  fi
  if command -v nproc >/dev/null 2>&1; then
    nproc
    return 0
  fi
  getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || printf '1\n'
}

fm_capacity_read_mem_avail_mb() {
  local kb
  if [ -n "${FM_CAPACITY_MEM_AVAIL_MB:-}" ]; then
    printf '%s\n' "$FM_CAPACITY_MEM_AVAIL_MB"
    return 0
  fi
  if [ -r /proc/meminfo ]; then
    kb=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)
    if fm_capacity_is_uint "$kb"; then
      printf '%s\n' $((kb / 1024))
      return 0
    fi
  fi
  printf '\n'
}

fm_capacity_read_load1() {
  if [ -n "${FM_CAPACITY_LOAD1:-}" ]; then
    printf '%s\n' "$FM_CAPACITY_LOAD1"
    return 0
  fi
  if [ -r /proc/loadavg ]; then
    awk '{ print $1; exit }' /proc/loadavg
    return 0
  fi
  sysctl -n vm.loadavg 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]/) { print $i; exit } }'
}

# Every regular task record in one home, whatever its kind. Prints one task id
# per line. This is the task-IDENTITY view: a fresh spawn that reused any of
# these ids would overwrite a durable record that something else owns, so the
# uniqueness gate must see all of them - including a live secondmate's, which
# is the one kind the occupancy view below deliberately drops.
fm_capacity_recorded_ids() { # <state-dir>
  local state=$1 file id
  [ -d "$state" ] || return 0
  for file in "$state"/*.meta; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    id=$(basename "$file" .meta)
    case "$id" in '' | *[!A-Za-z0-9._-]*) continue ;; esac
    printf '%s\n' "$id"
  done
}

# Independent-worker records in one home: ship and scout metadata. Prints one
# task id per line. This is the slot-BUDGET view, so a record counts here
# whether or not its worker is still running; fm_capacity_live_ids applies
# liveness on top. Secondmates are persistent specialists and never occupy an
# independent worker slot, so they are excluded from the count - but never from
# fm_capacity_recorded_ids, which is what protects their id.
fm_capacity_occupied_ids() { # <state-dir>
  local state=$1 id kind
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    kind=$(grep -E '^kind=' "$state/$id.meta" 2>/dev/null | head -n 1 | cut -d= -f2-)
    case "$kind" in
      scout | ship | '') printf '%s\n' "$id" ;;
      *) continue ;;
    esac
  done < <(fm_capacity_recorded_ids "$state")
}

# Is <state-dir>/<task-id>.status's last declaration ACTIVE work rather than a
# finished or held task? `working` and a just-`resolved` decision are active;
# done, failed, blocked, needs-decision, and the two declared-wait verbs
# (paused, captain-held) are not. Fail closed on anything else: a missing,
# blank, or unrecognised declaration reads as ACTIVE, so a worker that has not
# written its first status line yet still holds its slot.
#
# The four standard verbs are matched here directly so they always release,
# even in a home that overrides FM_CAPTAIN_RE. Beyond them, the terminal
# vocabulary is NOT this library's to define: bin/fm-classify-lib.sh already
# owns it for the watcher and the away-mode daemon, including the legacy bare
# lines that carry no leading verb at all (`PR ready ...`, `checks green`,
# `merged`) and each home's own FM_CAPTAIN_RE. Restating a narrower list here
# would let exactly those lines pin a slot forever on a backend whose liveness
# can never be proven negative, so the shared classifier is consulted instead
# of a second copy of the vocabulary. It answers "not relevant" for working,
# resolved, paused and captain-held, so an active crew is never released by it.
fm_capacity_task_active() { # <state-dir> <task-id>
  local state=$1 id=$2 line verb
  declare -F last_status_line >/dev/null 2>&1 || return 0
  line=$(last_status_line "$state/$id.status")
  [ -n "$line" ] || return 0
  status_is_paused_or_captain_held "$line" && return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    done | failed | blocked | needs-decision) return 1 ;;
  esac
  if declare -F status_is_captain_relevant >/dev/null 2>&1; then
    status_is_captain_relevant "$line" && return 1
  fi
  return 0
}

# Does <meta-file>'s recorded endpoint still hold a worker slot?
# fm-backend.sh's agent-state contract answers first and its POSITIVE answers
# are final: `alive` always keeps the slot (a running worker is never freed)
# and `dead`/`missing` always free it. Everything else is a non-answer, and on
# a backend with no recovery classifier (zellij, orca, cmux always print
# `unverified`) it is the only answer that will ever come, so deciding it
# "still live" would occupy the slot forever and permanently block dispatch on
# those homes. For a non-answer the task's own declared state decides, and only
# a task that is actively working or has declared nothing yet keeps its slot -
# the fail-closed half, because that is the case where a wrong guess would
# oversubscribe the host.
fm_capacity_worker_live() { # <meta-file>
  local meta=$1 backend target endpoint_state
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  declare -F fm_backend_agent_state >/dev/null 2>&1 || return 0
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 0
  endpoint_state=$(fm_backend_agent_state "$backend" "$target")
  case "$endpoint_state" in
    alive) return 0 ;;
    dead | missing) return 1 ;;
  esac
  fm_capacity_task_active "$(dirname "$meta")" "$(basename "$meta" .meta)"
}

# Independent workers in one home that still hold a slot.
fm_capacity_live_ids() { # <state-dir>
  local state=$1 id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    fm_capacity_worker_live "$state/$id.meta" || continue
    printf '%s\n' "$id"
  done < <(fm_capacity_occupied_ids "$state")
}

fm_capacity_occupied_count() { # <state-dir>
  local n=0
  while IFS= read -r _; do
    n=$((n + 1))
  done < <(fm_capacity_live_ids "$1")
  printf '%s\n' "$n"
}

# Independent workers in one home that are actively working: a live worker slot
# holder that bin/fm-crew-state.sh classifies as provably working (busy pane or
# active run-step). Idle done-panes with a live endpoint do not count.
fm_capacity_real_worker_ids() { # <state-dir>
  local state=$1 id
  declare -F crew_is_provably_working >/dev/null 2>&1 || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    fm_capacity_worker_live "$state/$id.meta" || continue
    crew_is_provably_working "$id" || continue
    printf '%s\n' "$id"
  done < <(fm_capacity_occupied_ids "$state")
}

fm_capacity_real_worker_count() { # <state-dir>
  local n=0
  while IFS= read -r _; do
    n=$((n + 1))
  done < <(fm_capacity_real_worker_ids "$1")
  printf '%s\n' "$n"
}

# Real workers across every local home on this host. Sets FM_CAPACITY_REAL and
# leaves FM_CAPACITY_HOMES_SCANNED unchanged (call fm_capacity_measure_host_occupancy
# first when both occupancy and real counts are needed).
fm_capacity_measure_host_real_workers() { # <state-dir> <home-dir>
  local state=$1 home=$2 peer peer_state canon_home canon_state
  FM_CAPACITY_REAL=$(fm_capacity_real_worker_count "$state")
  [ -n "$home" ] || return 0
  canon_home=$(fm_capacity_canonical_path "$home")
  canon_state=$(fm_capacity_canonical_path "$state")
  while IFS= read -r peer; do
    [ -n "$peer" ] || continue
    [ "$peer" != "$canon_home" ] || continue
    peer_state="$peer/state"
    [ "$(fm_capacity_canonical_path "$peer_state")" != "$canon_state" ] || continue
    [ -d "$peer_state" ] || continue
    FM_CAPACITY_REAL=$((FM_CAPACITY_REAL + $(fm_capacity_real_worker_count "$peer_state")))
  done < <(fm_capacity_host_homes "$home")
}

# How many more real workers the section-7 loop should try to launch right now.
fm_capacity_work_loop_shortfall() { # <real-count> [min-real]
  local real=$1 min=${2:-$FM_WORK_LOOP_MIN_REAL}
  fm_capacity_is_uint "$real" || real=0
  fm_capacity_is_uint "$min" || min=$FM_WORK_LOOP_MIN_REAL
  if [ "$real" -ge "$min" ]; then
    printf '0\n'
    return 0
  fi
  printf '%s\n' $((min - real))
}

# Plan limit for bin/fm-work-loop.sh plan: refill every free slot once the real
# floor is met; below the floor, spawn only enough to reach it.
fm_capacity_work_loop_plan_limit() { # <free-slots> <real-count> [min-real]
  local free=$1 real=$2 min=${3:-$FM_WORK_LOOP_MIN_REAL} shortfall
  fm_capacity_is_uint "$free" || free=0
  fm_capacity_is_uint "$real" || real=0
  shortfall=$(fm_capacity_work_loop_shortfall "$real" "$min")
  if [ "$shortfall" -gt 0 ]; then
    fm_capacity_min "$free" "$shortfall"
    return 0
  fi
  printf '%s\n' "$free"
}

# The kind recorded for <task-id> in this home; `ship` when the record omits it,
# matching the spawn default, and empty when there is no record at all.
fm_capacity_record_kind() { # <state-dir> <task-id>
  local meta=$1/$2.meta kind
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  kind=$(grep -E '^kind=' "$meta" 2>/dev/null | head -n 1 | cut -d= -f2-)
  printf '%s\n' "${kind:-ship}"
}

# 0 when <task-id>'s record is an independent worker (ship or scout) rather
# than some other durable record that merely shares the id space.
fm_capacity_id_is_worker_record() { # <state-dir> <task-id>
  case "$(fm_capacity_record_kind "$1" "$2")" in
    ship | scout) return 0 ;;
  esac
  return 1
}

# 0 when a fresh ship or scout must NOT take <task-id>, because taking it would
# either put a second worker on a task that already has a live one or overwrite
# a durable record that something else owns.
#
# The two halves are deliberately different. A record whose kind is not an
# independent worker - a live secondmate's endpoint above all - is refused for
# as long as it exists: a fresh spawn would rewrite state/<id>.meta out from
# under whoever owns it, and this library is not the surface that decides when
# such a record may be retired. A ship or scout record is refused only while it
# still holds its slot: once its worker is positively gone, the record is a
# durable history entry, not a running worker, and sequential replacement of a
# task whose pane died (a reboot, a killed server) is exactly what the intake
# contract allows. Refusing those too would leave a task with an intact
# worktree and unlanded commits restartable only by deleting its metadata by
# hand, because fm-control.sh's relaunch also refuses a `missing` endpoint.
# fm_capacity_worker_live is the same fail-closed predicate the slot budget
# uses, so an ambiguous or unreadable endpoint still refuses.
fm_capacity_task_occupies_slot() { # <state-dir> <task-id>
  local state=$1 want=$2 id
  [ -n "$want" ] || return 1
  while IFS= read -r id; do
    [ "$id" = "$want" ] || continue
    fm_capacity_id_is_worker_record "$state" "$id" || return 0
    fm_capacity_worker_live "$state/$id.meta" && return 0
    return 1
  done < <(fm_capacity_recorded_ids "$state")
  return 1
}

# Physically resolved form of <path>, or the trimmed input when it cannot be
# resolved (a home recorded for a directory that no longer exists still has to
# compare equal to itself). Home paths reach this library from three
# independent sources - FM_HOME verbatim from the environment,
# data/secondmates.md, and .fm-secondmate-parent - so the same home routinely
# arrives spelled three ways. Deduplicating on the raw strings counts it once
# per spelling and inflates occupancy, which refuses fresh dispatch while slots
# are actually free.
fm_capacity_canonical_path() { # <path>
  local p=$1 resolved
  [ -n "$p" ] || return 0
  if resolved=$(cd -- "$p" 2>/dev/null && pwd -P); then
    printf '%s\n' "$resolved"
    return 0
  fi
  while [ "$p" != / ] && [ "${p%/}" != "$p" ]; do
    p=${p%/}
  done
  printf '%s\n' "$p"
}

# Every local firstmate home that shares this physical host with <home-dir>:
# this home, the local primary home it was seeded from when it is a secondmate
# home, and every locally routed secondmate registered under that primary. A
# remote secondmate lives on another machine and is left out. Unparsable
# registry lines are skipped rather than trusted.
fm_capacity_host_homes() { # <home-dir>
  local home=$1 root reg line seen peer
  [ -n "$home" ] || return 0
  home=$(fm_capacity_canonical_path "$home")
  root=$home
  if fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" 2>/dev/null; then
    if [ "${FM_SECONDMATE_PARENT_ROUTE:-}" = local ] && [ -n "${FM_SECONDMATE_PARENT_HOME:-}" ]; then
      root=$(fm_capacity_canonical_path "$FM_SECONDMATE_PARENT_HOME")
    fi
  fi
  seen=$'\n'
  for peer in "$home" "$root"; do
    case "$seen" in *$'\n'"$peer"$'\n'*) continue ;; esac
    seen="$seen$peer"$'\n'
    printf '%s\n' "$peer"
  done
  reg="$root/data/secondmates.md"
  [ -f "$reg" ] && [ ! -L "$reg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
    case "$SECONDMATE_REGISTRY_HOME" in /*) ;; *) continue ;; esac
    peer=$(fm_capacity_canonical_path "$SECONDMATE_REGISTRY_HOME")
    case "$seen" in *$'\n'"$peer"$'\n'*) continue ;; esac
    seen="$seen$peer"$'\n'
    printf '%s\n' "$peer"
  done < "$reg"
}

# Live independent workers across every local home on this host. Sets
# FM_CAPACITY_OCCUPIED and the auditable FM_CAPACITY_HOMES_SCANNED.
# shellcheck disable=SC2034
fm_capacity_measure_host_occupancy() { # <state-dir> <home-dir>
  local state=$1 home=$2 peer peer_state canon_home canon_state
  FM_CAPACITY_OCCUPIED=$(fm_capacity_occupied_count "$state")
  FM_CAPACITY_HOMES_SCANNED=1
  [ -n "$home" ] || return 0
  canon_home=$(fm_capacity_canonical_path "$home")
  canon_state=$(fm_capacity_canonical_path "$state")
  while IFS= read -r peer; do
    [ -n "$peer" ] || continue
    [ "$peer" != "$canon_home" ] || continue
    peer_state="$peer/state"
    [ "$(fm_capacity_canonical_path "$peer_state")" != "$canon_state" ] || continue
    [ -d "$peer_state" ] || continue
    FM_CAPACITY_HOMES_SCANNED=$((FM_CAPACITY_HOMES_SCANNED + 1))
    FM_CAPACITY_OCCUPIED=$((FM_CAPACITY_OCCUPIED + $(fm_capacity_occupied_count "$peer_state")))
  done < <(fm_capacity_host_homes "$home")
}

# Is a freshly probed host suitable for host-bound work of <kind>?
# Both kinds must first clear the same HOST gates the local slot formula uses -
# CPU headroom and at least FM_CAPACITY_CPU_MIN_MEM_MB available - because
# host-bound work still needs a CPU and RAM to run on wherever it lands. A gpu
# host then adds its accelerator gates on top; free VRAM behind a pinned CPU or
# an exhausted RAM is not usable capacity, and treating it as capacity would
# short-circuit routing and hide a healthy configured fallback.
# Those host gates are also what rejects an UNMEASURABLE host, on each axis
# independently. A fabricated 0 load must never read as headroom, so no probe
# fabricates one: an unreadable /proc/loadavg omits load1 entirely, and an
# empty load fails the headroom gate here whether or not the host's RAM was
# readable. An unreadable /proc/meminfo reports mem_avail_mb=0, which fails the
# RAM gate on its own.
# CPU headroom is read from whichever measurement the host can actually
# produce. A host with a run-queue load average is gated on load1 < nproc. A
# host that only reports a busy percentage (Windows) passes that averaged
# percentage as <mean_busy_pct> and is gated on it directly, against
# FM_CAPACITY_PCT_MAX_BUSY: the two are different measurements and the load1
# rescaling of a percentage can only reach nproc at exactly 100%, which would
# wave a host sitting at 99% straight through.
fm_capacity_host_suitable() { # <kind> <nproc> <mem_avail_mb> <load1> <gpu_free_mb> <gpu_util> [mean_busy_pct]
  local kind=$1 nproc=$2 mem=$3 load1=$4 gpu_free=$5 gpu_util=$6 pct=${7:-}
  local load_h nproc_h pct_h max_pct_h
  fm_capacity_kind_ok "$kind" || return 1
  fm_capacity_is_uint "$nproc" || return 1
  [ "$nproc" -gt 0 ] || return 1
  if [ -n "$pct" ]; then
    pct_h=$(fm_capacity_load_hundredths "$pct") || return 1
    max_pct_h=$((FM_CAPACITY_PCT_MAX_BUSY * 100))
    [ "$pct_h" -lt "$max_pct_h" ] || return 1
  else
    load_h=$(fm_capacity_load_hundredths "$load1") || return 1
    nproc_h=$((nproc * 100))
    [ "$load_h" -lt "$nproc_h" ] || return 1
  fi
  fm_capacity_is_uint "$mem" || return 1
  [ "$mem" -ge "$FM_CAPACITY_CPU_MIN_MEM_MB" ] || return 1
  case "$kind" in
    gpu)
      fm_capacity_is_uint "$gpu_free" || return 1
      fm_capacity_is_uint "$gpu_util" || return 1
      [ "$gpu_free" -ge "$FM_CAPACITY_GPU_MIN_FREE_MB" ] || return 1
      [ "$gpu_util" -le "$FM_CAPACITY_GPU_MAX_UTIL" ] || return 1
      return 0
      ;;
    cpu)
      return 0
      ;;
  esac
  return 1
}

fm_capacity_parse_gpu_csv() { # <csv> -> sets FM_CAPACITY_GPU_FREE_MB FM_CAPACITY_GPU_UTIL
  local csv=$1 free util
  FM_CAPACITY_GPU_FREE_MB=
  FM_CAPACITY_GPU_UTIL=
  csv=$(printf '%s' "$csv" | tr -d ' \r' | head -n 1)
  [ -n "$csv" ] || return 1
  free=${csv%%,*}
  util=${csv#*,}
  util=${util%%,*}
  fm_capacity_is_uint "$free" || return 1
  fm_capacity_is_uint "$util" || return 1
  FM_CAPACITY_GPU_FREE_MB=$free
  FM_CAPACITY_GPU_UTIL=$util
  return 0
}

# An unreadable /proc/loadavg emits NO load1 line, exactly as the Windows probe
# omits a failed CPU sample rather than reporting 0%: a fabricated zero is
# indistinguishable from a genuinely idle host and would route host-bound work
# onto a machine whose CPU was never measured. The absent line leaves
# FM_CAPACITY_PROBE_LOAD1 empty, which fails fm_capacity_host_suitable's
# headroom gate on its own, without depending on the RAM half also failing.
# <proc-dir> defaults to /proc and exists so the emitted command is testable
# against a constructed /proc.
fm_capacity_posix_probe_cmd() { # [proc-dir]
  local proc=${1:-/proc} cmd
  case $proc in *[!A-Za-z0-9._/-]*) proc=/proc ;; esac
  cmd=$(cat <<'CMD'
printf 'FM_CAP nproc=%s\n' "$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || printf 0)"
if [ -r @PROC@/meminfo ]; then awk '/^MemAvailable:/ { printf "FM_CAP mem_avail_mb=%d\n", $2/1024; exit }' @PROC@/meminfo; else printf 'FM_CAP mem_avail_mb=0\n'; fi
if [ -r @PROC@/loadavg ]; then awk '{ printf "FM_CAP load1=%s\n", $1; exit }' @PROC@/loadavg; fi
printf 'FM_CAP gpu=%s\n' "$(nvidia-smi --query-gpu=memory.free,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -n 1 | tr -d ' ')"
CMD
  )
  printf '%s\n' "${cmd//@PROC@/$proc}"
}

# Emits one `load_pct` line per SUCCESSFUL sample; fm_capacity_absorb_probe_text
# averages them. The shell side owns the averaging so the durability of the
# reading is testable without a Windows host. A sample whose processor query
# errors or whose processors all report a null LoadPercentage emits NO line
# rather than a zero (Measure-Object averages a null property as 0, so the
# nulls are filtered out before the mean, not after): a
# fabricated 0% would be indistinguishable from a genuinely idle host and would
# route work onto a machine whose CPU was never measured. With no samples at
# all the mean stays empty, no CPU-headroom measurement exists, and the host is
# unsuitable.
fm_capacity_windows_probe_cmd() {
  local cmd
  cmd=$(cat <<'CMD'
$n = [Environment]::ProcessorCount; $os = Get-CimInstance Win32_OperatingSystem; $avail = 0; if ($os -and $os.FreePhysicalMemory) { $avail = [int]($os.FreePhysicalMemory / 1024) }; $gpu = ''; try { $gpu = (& nvidia-smi --query-gpu=memory.free,utilization.gpu --format=csv,noheader,nounits 2>$null | Select-Object -First 1) } catch {}; Write-Output ("FM_CAP nproc=" + $n); Write-Output ("FM_CAP mem_avail_mb=" + $avail); Write-Output ("FM_CAP gpu=" + $gpu); for ($i = 0; $i -lt @SAMPLES@; $i++) { if ($i -gt 0) { Start-Sleep -Milliseconds @SLEEPMS@ }; $load = $null; try { $cpu = @(Get-CimInstance Win32_Processor -ErrorAction Stop | Where-Object { $null -ne $_.LoadPercentage }); if ($cpu.Count -gt 0) { $avg = ($cpu | Measure-Object -Property LoadPercentage -Average).Average; if ($null -ne $avg) { $load = [int]$avg } } } catch {}; if ($null -ne $load) { Write-Output ("FM_CAP load_pct=" + $load) } }
CMD
  )
  cmd=${cmd//@SAMPLES@/$FM_CAPACITY_WIN_LOAD_SAMPLES}
  cmd=${cmd//@SLEEPMS@/$FM_CAPACITY_WIN_LOAD_SAMPLE_MS}
  printf '%s\n' "$cmd"
}

# Seconds the Windows sampling window adds to a probe, so its SSH call is not
# cut short by the bound that fits the single-shot POSIX probe.
fm_capacity_win_probe_extra_secs() {
  local ms=$((FM_CAPACITY_WIN_LOAD_SAMPLES * FM_CAPACITY_WIN_LOAD_SAMPLE_MS))
  printf '%s\n' $(((ms + 999) / 1000))
}

fm_capacity_ssh_raw() { # <host> <remote-cmd> [extra-seconds]
  local host=$1 cmd=$2 extra=${3:-0} bound
  fm_capacity_is_uint "$extra" || extra=0
  bound=$((${FM_CAPACITY_SSH_TIMEOUT:-5} + 3))
  [ "$bound" -gt 3 ] || bound=8
  bound=$((bound + extra))
  fm_run_timed "$bound" ssh \
    -o BatchMode=yes \
    -o ConnectTimeout="${FM_CAPACITY_SSH_TIMEOUT:-5}" \
    -o ServerAliveInterval=2 \
    -o ServerAliveCountMax=2 \
    -o ForwardAgent=no \
    "$host" "$cmd"
}

# Parse FM_CAP lines from a probe transcript into the FM_CAPACITY_PROBE_* vars.
fm_capacity_absorb_probe_text() {
  local text=$1 line key val
  local -a load_pct=()
  FM_CAPACITY_PROBE_NPROC=
  FM_CAPACITY_PROBE_MEM_MB=
  FM_CAPACITY_PROBE_LOAD1=
  FM_CAPACITY_PROBE_GPU_FREE=
  FM_CAPACITY_PROBE_GPU_UTIL=
  FM_CAPACITY_PROBE_LOAD_PCT=
  FM_CAPACITY_PROBE_LOAD_SAMPLES=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      FM_CAP\ *)
        key=${line#FM_CAP }
        val=${key#*=}
        key=${key%%=*}
        case "$key" in
          nproc) FM_CAPACITY_PROBE_NPROC=$val ;;
          mem_avail_mb) FM_CAPACITY_PROBE_MEM_MB=$val ;;
          load1) FM_CAPACITY_PROBE_LOAD1=$val ;;
          load_pct) fm_capacity_is_number "$val" && load_pct+=("$val") ;;
          gpu) fm_capacity_parse_gpu_csv "$val" && {
            FM_CAPACITY_PROBE_GPU_FREE=$FM_CAPACITY_GPU_FREE_MB
            FM_CAPACITY_PROBE_GPU_UTIL=$FM_CAPACITY_GPU_UTIL
          } ;;
        esac
        ;;
    esac
  done <<EOF
$text
EOF
  # A percentage-derived load is the mean of every sample the probe returned,
  # never a single reading: one ~1-second sample cannot distinguish a burst
  # from a pinned host, and treating it as a 1-minute average would refuse the
  # preferred host for the length of a browser tab. It stays a PERCENTAGE all
  # the way to fm_capacity_host_suitable, which gates it as one; there is no
  # rescaling into a load1, because a busy fraction rescaled that way can only
  # reach nproc at exactly 100% and would wave a pinned host through.
  if [ "${#load_pct[@]}" -gt 0 ]; then
    FM_CAPACITY_PROBE_LOAD_PCT=$(fm_capacity_mean "${load_pct[@]}") \
      || FM_CAPACITY_PROBE_LOAD_PCT=
    FM_CAPACITY_PROBE_LOAD_SAMPLES=${#load_pct[@]}
  fi
  fm_capacity_is_uint "$FM_CAPACITY_PROBE_NPROC" || return 1
  [ "$FM_CAPACITY_PROBE_NPROC" -gt 0 ] || return 1
  return 0
}

# Probe one SSH alias. Sets measurement vars when reachable. Does not cache.
# FM_CAPACITY_PROBE_LOAD_PCT and FM_CAPACITY_PROBE_LOAD_SAMPLES record how CPU
# headroom was measured on a host with no run-queue load average: the mean
# busy percent, and how many samples it was averaged over.
# shellcheck disable=SC2034
fm_capacity_probe_ssh() { # <ssh-alias>
  local host=$1 out
  FM_CAPACITY_PROBE_NPROC=
  FM_CAPACITY_PROBE_MEM_MB=
  FM_CAPACITY_PROBE_LOAD1=
  FM_CAPACITY_PROBE_GPU_FREE=
  FM_CAPACITY_PROBE_GPU_UTIL=
  FM_CAPACITY_PROBE_LOAD_PCT=
  FM_CAPACITY_PROBE_LOAD_SAMPLES=0
  fm_capacity_ssh_alias_ok "$host" || return 1
  if [ "${FM_CAPACITY_SKIP_REMOTE:-}" = 1 ]; then
    return 1
  fi
  out=$(fm_capacity_ssh_raw "$host" "$(fm_capacity_posix_probe_cmd)" 2>/dev/null) || out=
  if fm_capacity_absorb_probe_text "$out"; then
    return 0
  fi
  out=$(fm_capacity_ssh_raw "$host" "$(fm_capacity_windows_probe_cmd)" \
    "$(fm_capacity_win_probe_extra_secs)" 2>/dev/null) || out=
  if fm_capacity_absorb_probe_text "$out"; then
    return 0
  fi
  return 1
}

fm_capacity_config_path() { # <config-dir>
  printf '%s/%s\n' "$1" "$FM_CAPACITY_CONFIG_FILE"
}

# Load preferred/fallback from flags/env/config into FM_CAPACITY_PREF_* and
# FM_CAPACITY_FALL_*. Each session pin merges over its own config-derived
# counterpart, so pinning one host never discards the other configured one; a
# pinned kind is validated exactly like a configured kind. Returns 1 for a
# rejected pin or a present but malformed config file.
# shellcheck disable=SC2034
fm_capacity_load_hosts() { # <config-dir>
  local config_dir=$1 path ssh kind json
  local pin_pref_ssh=${FM_CAPACITY_PREFERRED_SSH:-} pin_pref_kind=${FM_CAPACITY_PREFERRED_KIND:-}
  local pin_fall_ssh=${FM_CAPACITY_FALLBACK_SSH:-} pin_fall_kind=${FM_CAPACITY_FALLBACK_KIND:-}
  local cfg_pref_ssh='' cfg_pref_kind='' cfg_fall_ssh='' cfg_fall_kind=''
  FM_CAPACITY_PREF_SSH=
  FM_CAPACITY_PREF_KIND=gpu
  FM_CAPACITY_FALL_SSH=
  FM_CAPACITY_FALL_KIND=cpu
  FM_CAPACITY_CONFIG_ERROR=
  if [ -n "$pin_pref_ssh" ]; then
    fm_capacity_ssh_alias_ok "$pin_pref_ssh" || {
      FM_CAPACITY_CONFIG_ERROR="preferred SSH alias is not a safe host token"
      return 1
    }
  fi
  if [ -n "$pin_fall_ssh" ]; then
    fm_capacity_ssh_alias_ok "$pin_fall_ssh" || {
      FM_CAPACITY_CONFIG_ERROR="fallback SSH alias is not a safe host token"
      return 1
    }
  fi
  if [ -n "$pin_pref_kind" ]; then
    fm_capacity_kind_ok "$pin_pref_kind" || {
      FM_CAPACITY_CONFIG_ERROR="preferred kind must be gpu or cpu"
      return 1
    }
  fi
  if [ -n "$pin_fall_kind" ]; then
    fm_capacity_kind_ok "$pin_fall_kind" || {
      FM_CAPACITY_CONFIG_ERROR="fallback kind must be gpu or cpu"
      return 1
    }
  fi
  path=$(fm_capacity_config_path "$config_dir")
  # Both hosts pinned leaves the file nothing to contribute; any partial pin
  # still needs its configured counterpart.
  if { [ -z "$pin_pref_ssh" ] || [ -z "$pin_fall_ssh" ]; } && [ -e "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || {
      FM_CAPACITY_CONFIG_ERROR="config/compute-hosts.json must be a regular file"
      return 1
    }
    command -v jq >/dev/null 2>&1 || {
      FM_CAPACITY_CONFIG_ERROR="jq is required to read config/compute-hosts.json"
      return 1
    }
    json=$(cat "$path") || {
      FM_CAPACITY_CONFIG_ERROR="could not read config/compute-hosts.json"
      return 1
    }
    printf '%s\n' "$json" | jq -e . >/dev/null 2>&1 || {
      FM_CAPACITY_CONFIG_ERROR="config/compute-hosts.json is not valid JSON"
      return 1
    }
    ssh=$(printf '%s\n' "$json" | jq -r '.preferred.ssh // empty')
    kind=$(printf '%s\n' "$json" | jq -r '.preferred.kind // "gpu"')
    if [ -n "$ssh" ]; then
      fm_capacity_ssh_alias_ok "$ssh" || {
        FM_CAPACITY_CONFIG_ERROR="preferred.ssh is not a safe host token"
        return 1
      }
      fm_capacity_kind_ok "$kind" || {
        FM_CAPACITY_CONFIG_ERROR="preferred.kind must be gpu or cpu"
        return 1
      }
      cfg_pref_ssh=$ssh
      cfg_pref_kind=$kind
    fi
    ssh=$(printf '%s\n' "$json" | jq -r '.fallback.ssh // empty')
    kind=$(printf '%s\n' "$json" | jq -r '.fallback.kind // "cpu"')
    if [ -n "$ssh" ]; then
      fm_capacity_ssh_alias_ok "$ssh" || {
        FM_CAPACITY_CONFIG_ERROR="fallback.ssh is not a safe host token"
        return 1
      }
      fm_capacity_kind_ok "$kind" || {
        FM_CAPACITY_CONFIG_ERROR="fallback.kind must be gpu or cpu"
        return 1
      }
      cfg_fall_ssh=$ssh
      cfg_fall_kind=$kind
    fi
  fi
  FM_CAPACITY_PREF_SSH=${pin_pref_ssh:-$cfg_pref_ssh}
  FM_CAPACITY_PREF_KIND=${pin_pref_kind:-${cfg_pref_kind:-gpu}}
  FM_CAPACITY_FALL_SSH=${pin_fall_ssh:-$cfg_fall_ssh}
  FM_CAPACITY_FALL_KIND=${pin_fall_kind:-${cfg_fall_kind:-cpu}}
  return 0
}

# How the last probe measured CPU headroom, as one auditable token for the
# routing report: the run-queue average a host with /proc/loadavg gave, the
# mean busy percent and sample count a host without one gave, or `unmeasured`
# when neither arrived - which is also the reading that makes a host
# unsuitable, so an operator can see WHY a preferred host was passed over.
fm_capacity_cpu_headroom_reading() {
  if [ -n "${FM_CAPACITY_PROBE_LOAD_PCT:-}" ]; then
    printf 'busy_pct=%s/samples=%s\n' \
      "$FM_CAPACITY_PROBE_LOAD_PCT" "${FM_CAPACITY_PROBE_LOAD_SAMPLES:-0}"
    return 0
  fi
  if fm_capacity_is_number "${FM_CAPACITY_PROBE_LOAD1:-}"; then
    printf 'load1=%s\n' "$FM_CAPACITY_PROBE_LOAD1"
    return 0
  fi
  printf 'unmeasured\n'
}

# Fill FM_CAPACITY_ROUTE* from a freshly loaded host pair. Probes live.
# shellcheck disable=SC2034
fm_capacity_route_hosts() {
  FM_CAPACITY_ROUTE=none
  FM_CAPACITY_ROUTE_HOST=
  FM_CAPACITY_ROUTE_REASON='no configured compute host was freshly reachable and suitable'
  FM_CAPACITY_PREF_REACHABLE=no
  FM_CAPACITY_PREF_SUITABLE=no
  FM_CAPACITY_PREF_LOAD=unmeasured
  FM_CAPACITY_FALL_REACHABLE=no
  FM_CAPACITY_FALL_SUITABLE=no
  FM_CAPACITY_FALL_LOAD=unmeasured
  if [ -n "${FM_CAPACITY_PREF_SSH:-}" ]; then
    if fm_capacity_probe_ssh "$FM_CAPACITY_PREF_SSH"; then
      FM_CAPACITY_PREF_REACHABLE=yes
      FM_CAPACITY_PREF_LOAD=$(fm_capacity_cpu_headroom_reading)
      if fm_capacity_host_suitable "$FM_CAPACITY_PREF_KIND" \
        "$FM_CAPACITY_PROBE_NPROC" "$FM_CAPACITY_PROBE_MEM_MB" \
        "$FM_CAPACITY_PROBE_LOAD1" "$FM_CAPACITY_PROBE_GPU_FREE" \
        "$FM_CAPACITY_PROBE_GPU_UTIL" "${FM_CAPACITY_PROBE_LOAD_PCT:-}"; then
        FM_CAPACITY_PREF_SUITABLE=yes
        FM_CAPACITY_ROUTE=preferred
        FM_CAPACITY_ROUTE_HOST=$FM_CAPACITY_PREF_SSH
        FM_CAPACITY_ROUTE_REASON='preferred host is reachable and suitable'
        return 0
      fi
    fi
  fi
  if [ -n "${FM_CAPACITY_FALL_SSH:-}" ]; then
    if fm_capacity_probe_ssh "$FM_CAPACITY_FALL_SSH"; then
      FM_CAPACITY_FALL_REACHABLE=yes
      FM_CAPACITY_FALL_LOAD=$(fm_capacity_cpu_headroom_reading)
      if fm_capacity_host_suitable "$FM_CAPACITY_FALL_KIND" \
        "$FM_CAPACITY_PROBE_NPROC" "$FM_CAPACITY_PROBE_MEM_MB" \
        "$FM_CAPACITY_PROBE_LOAD1" "$FM_CAPACITY_PROBE_GPU_FREE" \
        "$FM_CAPACITY_PROBE_GPU_UTIL" "${FM_CAPACITY_PROBE_LOAD_PCT:-}"; then
        FM_CAPACITY_FALL_SUITABLE=yes
        FM_CAPACITY_ROUTE=fallback
        FM_CAPACITY_ROUTE_HOST=$FM_CAPACITY_FALL_SSH
        FM_CAPACITY_ROUTE_REASON='preferred host was not usable; fallback is reachable and suitable'
        return 0
      fi
    fi
  fi
  if [ -z "${FM_CAPACITY_PREF_SSH:-}" ] && [ -z "${FM_CAPACITY_FALL_SSH:-}" ]; then
    FM_CAPACITY_ROUTE_REASON='no preferred or fallback compute host is configured'
  fi
  return 0
}

# Snapshot local measurements plus occupied/free into FM_CAPACITY_* vars.
# Occupancy is host-scoped: <home-dir> anchors the local-home set and defaults
# to FM_HOME.
fm_capacity_measure_local() { # <state-dir> [home-dir]
  FM_CAPACITY_LOCAL_NPROC=$(fm_capacity_read_nproc)
  FM_CAPACITY_LOCAL_MEM_MB=$(fm_capacity_read_mem_avail_mb)
  FM_CAPACITY_LOCAL_LOAD1=$(fm_capacity_read_load1)
  fm_capacity_is_uint "$FM_CAPACITY_LOCAL_NPROC" || FM_CAPACITY_LOCAL_NPROC=1
  # A missing or non-numeric load is left as-is. slots_from_local then yields 0
  # rather than treating the failed query as idle (load1=0).
  FM_CAPACITY_SLOTS=$(fm_capacity_slots_from_local \
    "$FM_CAPACITY_LOCAL_NPROC" "$FM_CAPACITY_LOCAL_MEM_MB" "$FM_CAPACITY_LOCAL_LOAD1")
  fm_capacity_measure_host_occupancy "$1" "${2:-${FM_HOME:-}}"
  FM_CAPACITY_FREE=$((FM_CAPACITY_SLOTS - FM_CAPACITY_OCCUPIED))
  [ "$FM_CAPACITY_FREE" -ge 0 ] || FM_CAPACITY_FREE=0
}

# Allow a fresh independent worker. Relaunch and secondmate skip the slot
# budget. Never interrupts another task. Prints nothing on allow; one error
# line on refuse.
fm_capacity_allow_new_worker() { # <state-dir> <task-id> <kind> <relaunch> [home-dir]
  local state=$1 id=$2 kind=$3 relaunch=$4 home=${5:-${FM_HOME:-}}
  [ "$relaunch" != 1 ] || return 0
  [ "$kind" != secondmate ] || return 0
  # Identity first: it is a pure metadata read and its refusal quotes no
  # measured value, so an id collision never pays for a host-wide occupancy
  # scan (one backend agent-state probe per record across every local home).
  if fm_capacity_task_occupies_slot "$state" "$id"; then
    if fm_capacity_id_is_worker_record "$state" "$id"; then
      printf 'error: capacity: task %s already has a worker; sequential replacement uses relaunch, never a second concurrent worker\n' "$id" >&2
    else
      printf 'error: capacity: id %s already has a %s record in this home; a fresh worker must not reuse it and overwrite that record\n' \
        "$id" "$(fm_capacity_record_kind "$state" "$id")" >&2
    fi
    return 1
  fi
  fm_capacity_measure_local "$state" "$home"
  if [ "$FM_CAPACITY_FREE" -ge 1 ]; then
    return 0
  fi
  if [ "$FM_CAPACITY_SLOTS" -eq 0 ]; then
    printf 'error: capacity: supervisor host is at measured capacity (slots=0 occupied=%s homes_scanned=%s nproc=%s load1=%s mem_avail_mb=%s); refusing a new independent worker rather than overloading this host\n' \
      "$FM_CAPACITY_OCCUPIED" "$FM_CAPACITY_HOMES_SCANNED" "$FM_CAPACITY_LOCAL_NPROC" "${FM_CAPACITY_LOCAL_LOAD1:-unknown}" "${FM_CAPACITY_LOCAL_MEM_MB:-unknown}" >&2
    return 1
  fi
  printf 'error: capacity: no free worker slot (occupied=%s slots=%s homes_scanned=%s); independent work waits until a live worker on this host finishes; running workers were left running\n' \
    "$FM_CAPACITY_OCCUPIED" "$FM_CAPACITY_SLOTS" "$FM_CAPACITY_HOMES_SCANNED" >&2
  return 1
}
