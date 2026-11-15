#!/usr/bin/env bash
# ak47/tick.sh - the deterministic tick: sample, self-heal an enumerated table,
# write one line every run so silence is provable.
#
# No model, no tokens, no network. Run by ak47-devops.timer every 5 minutes.
#
# THE TABLE IS THE WHOLE AUTHORITY. A class not in it is reported, never acted
# on. Every acting class is bounded (a per-run entry cap), reversible (moved to
# quarantine, not deleted, for AK47_QUARANTINE_DAYS), and logged with its revert.
#
#   class                 trigger                                    action        default
#   --------------------  -----------------------------------------  ------------  -------
#   tmp-mktemp            tmp[A-Za-z0-9]{8} or tmp.[A-Za-z0-9]{10},   quarantine    armed
#                         idle > tmp_mktemp_min, no live holder
#   tmp-producer          a census-producers.conf prefix, idle >      quarantine    armed
#                         tmp_producer_min, no live holder
#   orphan-task-scratch   /tmp/fm-<id> with no state/<id>.meta,        quarantine    armed
#                         idle > orphan_min, no open handle
#   quarantine-expire     quarantine entry older than                 delete        armed
#                         quarantine_days, at most
#                         quarantine_expire_max per run
#   dead-pane             a tmux pane whose process is gone            report only   report
#   swap-pressure         swap >= 70% and RAM available >= 20 GB       report only   report
#   fat-process           one pid > fat_process_gb for fat_process_min  report/arm    renice 19,
#                         (report until fat_process=1)                  SIGTERM, SIGKILL
#                                                                        after 5 min
#   stale-lock            state/.lock pid not alive                    report only   report
#   disk                  root >= 85%                                  report only   report
#
# swap-pressure and fat-process become acting only when the operator sets
# swap_pressure=1 / fat_process=1 in ~/.config/ak47/devops.conf. That is the
# "dry-run for 24 h, then armed" step, and it is a deliberate second key because
# both act on a live process.
#
# PROTECTED, never touched by any class (checked on the canonical path):
#   /tmp/fm-move, /tmp/ak47-*, /tmp/orcad-*, /tmp/jest_0, /tmp/systemd-*,
#   /tmp/snap*, /tmp/.X11-unix, /tmp/.ICE-unix, /tmp/.font-unix, /tmp/.Test-unix,
#   /tmp/.XIM-unix, /tmp/.X*-lock, any /tmp/*router*.sh, /tmp/*forward*,
#   /tmp/cli-proxy*, /tmp/*.token, any /tmp/fm-<id> with a live state/<id>.meta,
#   and anything any live process holds open (one /proc scan per run).
#
# Usage: tick.sh [--apply|--dry-run] [--print]
#   --apply    the default: acting classes act.
#   --dry-run  every class evaluates and logs what it WOULD do; nothing moves.
#   --print    also print the tick line and the status board to stdout.
#
# Exit: 0 when the tick completed (a breach is a finding, not a failure);
#       2 on a malformed budget or producer table.
set -u

AK47_ROOT=${AK47_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}
# shellcheck source=lib/common.sh
. "$AK47_ROOT/lib/common.sh"
# shellcheck source=lib/safe-delete.sh
. "$AK47_ROOT/lib/safe-delete.sh"
# shellcheck source=lib/protected.sh
. "$AK47_ROOT/lib/protected.sh"

APPLY=1; PRINT=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    --print) PRINT=1 ;;
    *) echo "tick.sh: usage: $0 [--apply|--dry-run] [--print]" >&2; exit 2 ;;
  esac
done

TMP_ROOT=${AK47_TMP_ROOT:-/tmp}
DEVOPS_LOG=$AK47_STATE/devops.log
REAP_LOG=$AK47_STATE/reap.log
FIND_LOG=$AK47_STATE/findings.log
QUAR=$AK47_STATE/quarantine

MKTEMP_MIN=$(ak47_conf tmp_mktemp_min 1440)
PRODUCER_MIN=$(ak47_conf tmp_producer_min 1440)
ORPHAN_MIN=$(ak47_conf orphan_min 10080)
QUAR_DAYS=$(ak47_conf quarantine_days 7)
# How many expired quarantine entries one tick may delete. The delete path is
# filesystem-bound, so a fixed bound keeps a five-minute tick five minutes long;
# whatever is left waits for the next run, and the line says how much is left.
QUAR_MAX=$(ak47_conf quarantine_expire_max 200)
MAX_ENTRIES=$(ak47_conf tmp_max_entries 5000)
MAX_MOVES=$(ak47_conf tmp_max_moves 2000)
# The class a finding files under in firstmate's inbox. fm-inbox accepts only a
# fixed vocabulary (captain: text|voice; automated: sentry|lane-tick|ci|watch|
# health), and an unknown class exits 1 - which the delivery gate below reads as
# "not delivered" and correctly refuses to commit the dedupe key. That is how
# every ak47 finding went undelivered while the gate kept reporting FAILED
# instead of SILENT: the class was simply not in the vocabulary.
INBOX_CLASS=${AK47_INBOX_CLASS:-health}
SWAP_ARMED=$(ak47_conf_bool swap_pressure 0)
FAT_ARMED=$(ak47_conf_bool fat_process 0)
FAT_GB=$(ak47_conf fat_process_gb 3)
FAT_MIN=$(ak47_conf fat_process_min 10)
INTERVAL=$(ak47_conf interval_seconds 300)

for v in MKTEMP_MIN PRODUCER_MIN ORPHAN_MIN QUAR_DAYS MAX_ENTRIES MAX_MOVES FAT_GB FAT_MIN INTERVAL; do
  case "${!v}" in ''|*[!0-9]*) echo "tick.sh: $v must be a whole number, got '${!v}'" >&2; exit 2 ;; esac
done

today=$(date -u +%Y%m%d)
qdir="$QUAR/$today"
# A dry run must leave no trace at all, including an empty quarantine directory:
# "nothing changed" has to be true of the filesystem, not just of the entries.
if [ "$APPLY" = 1 ]; then
  mkdir -p "$qdir" 2>/dev/null || true
fi

# ---- state for this run --------------------------------------------------------
actions=0; moved=0; deleted=0; skipped_busy=0; skipped_protected=0; failures=0
declare -A class_moved=() class_dry=()
findings=()
finding() { findings+=("$1|$2"); }   # key|plain-English line
act() { ak47_log "$REAP_LOG" "$*"; actions=$((actions + 1)); }

# ---- one snapshot, one busy scan -----------------------------------------------
SNAP=$(mktemp) || exit 1
BUSY=$(mktemp) || exit 1
CLASSED=$(mktemp) || exit 1

# One readdir pass over /tmp: name and mtime for every top-level entry. 2.2 s on
# the 950k-entry box measured 2026-11-10, and every class below reads this file
# rather than walking /tmp again.
find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -printf '%f\t%T@\t%y\n' >"$SNAP" 2>/dev/null || true
# The entry count comes free from the snapshot, and it has to be read BEFORE the
# acting loop: tmp_max_entries is the point at which the tick stops working, not
# a per-run move budget. A tick that keeps nibbling at a tree already under its
# ceiling is a sweeper that never finishes.
before=$(wc -l <"$SNAP" 2>/dev/null || echo 0)

# One /proc pass: the top-level /tmp names any live process holds. A name in
# here is never touched, so the tick cannot pull a directory out from under a
# running test.
ak47_busy_tmp_names >"$BUSY" 2>/dev/null || true

# One /proc pass for the delete path as well. lsof +D is recursive and O(files):
# a quarantine directory big enough to be worth deleting is exactly the size at
# which that scan outlives TimeoutStartSec, so the tick spent every run proving
# something it never got to act on. The set is built once here and reused for
# every candidate; a scan without its completion marker answers "could not
# tell", so a failed scan refuses the delete instead of authorising it.
AK47_INUSE_SET=$AK47_STATE/inuse.set
ak47_inuse_scan "$AK47_INUSE_SET" || true
export AK47_INUSE_SET
# Loaded into an associative array once: a grep fork per candidate is 5,000
# processes per run for a set that never changes mid-run.
declare -A BUSY_SET=()
while IFS= read -r _b; do [ -n "$_b" ] && BUSY_SET["$_b"]=1; done <"$BUSY"
is_busy() { [ -n "${BUSY_SET[$1]:-}" ]; }

# The producer table decides what is a candidate; a name matching no row is
# never printed, so the tick cannot act on a class nobody enumerated. The age,
# busy and protected gates run in the same pass because they have to run 800,000
# times; the loop below re-verifies the canonical path of every candidate it is
# actually about to move.
prot_args=()
for p in "${AK47_PROTECTED_EXACT[@]}"; do prot_args+=(--protected-exact "$p"); done
for p in "${AK47_PROTECTED_GLOB[@]}"; do prot_args+=(--protected-glob "$p"); done
classify_err=$(mktemp) || exit 1
trap 'rm -f "$SNAP" "$BUSY" "$CLASSED" "$classify_err"' EXIT
python3 "$AK47_ROOT/lib/classify.py" \
  --producers "$AK47_PRODUCERS" --snapshot "$SNAP" --now "$(ak47_epoch)" \
  --busy "$BUSY" \
  --mktemp-min "$MKTEMP_MIN" --producer-min "$PRODUCER_MIN" \
  --orphan-min "$ORPHAN_MIN" --fm-home "$FM_HOME" --tmp-root "$TMP_ROOT" \
  "${prot_args[@]}" \
  >"$CLASSED" 2>"$classify_err" || { echo "tick.sh: producer table is malformed; refusing to act" >&2; exit 2; }
# The classifier's own skip counts, so the tick line reports what it declined.
skipped_busy=$(sed -n 's/.*skipped_busy=\([0-9]*\).*/\1/p' "$classify_err")
skipped_protected=$(sed -n 's/.*skipped_protected=\([0-9]*\).*/\1/p' "$classify_err")
skipped_busy=${skipped_busy:-0}; skipped_protected=${skipped_protected:-0}

# ---- quarantine move -----------------------------------------------------------
# Move one top-level entry into today's quarantine. A rename, so it is atomic and
# reversible with a single mv back; the revert is printed on the log line.
quarantine() {
  local name=$1 class=$2 path="$TMP_ROOT/$1" dest="$qdir/$1" kib n=1
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    while [ -e "$dest" ] || [ -L "$dest" ]; do
      dest="$qdir/$name.$n"
      n=$((n + 1))
    done
  fi
  if [ "$APPLY" -eq 0 ]; then
    class_dry[$class]=$(( ${class_dry[$class]:-0} + 1 ))
    # A dry run logs a bounded sample, not 650,000 lines.
    if [ "${class_dry[$class]}" -le 5 ]; then
      act "DRY-RUN would quarantine class=$class $path -> $dest revert='mv $dest $path'"
    fi
    moved=$((moved + 1))
    return 0
  fi
  kib=$(du -sk -- "$path" 2>/dev/null | awk '{print $1}') || kib=0
  if mv -f -- "$path" "$dest" 2>/dev/null; then
    act "quarantine class=$class $path -> $dest kib=${kib:-0} revert='mv $dest $path'"
    moved=$((moved + 1))
    class_moved[$class]=$(( ${class_moved[$class]:-0} + 1 ))
  else
    act "WARN could-not-quarantine class=$class $path"
    failures=$((failures + 1))
  fi
}

# ---- the acting classes --------------------------------------------------------
# One loop over the classified snapshot. Order is the classifier's, which sorts
# the producer table longest-prefix-first, so a specific row always wins.
while IFS=$'\t' read -r class name _age; do
  [ -n "${class:-}" ] || continue
  # Two separate stops. The tree is already under its ceiling: stop, the job is
  # done. The run has moved its per-run budget: stop, the next tick continues.
  [ $((before - moved)) -le "$MAX_ENTRIES" ] && break
  [ "$moved" -ge "$MAX_MOVES" ] && break
  path="$TMP_ROOT/$name"
  # Re-verify on the canonical path: the classifier's pass is a prefilter.
  if ak47_is_protected "$path"; then skipped_protected=$((skipped_protected + 1)); continue; fi
  if is_busy "$name"; then skipped_busy=$((skipped_busy + 1)); continue; fi
  # The busy set and the in-use set are both tick-start snapshots. A process
  # that starts using this path during the run is caught by the quarantine
  # expiry scan, which matches held paths by prefix against the new name.
  rc=0; ak47_has_open_handles "$path" || rc=$?
  if [ "$rc" -ne 1 ]; then skipped_busy=$((skipped_busy + 1)); continue; fi
  quarantine "$name" "$class"
done <"$CLASSED"

# ---- class: quarantine-expire --------------------------------------------------
# Quarantine is a 7-day holding pen, not a second /tmp. The age is measured from
# the dated directory (the move day), never from the entry's mtime: mv preserves
# mtime, so an old leak would otherwise be deleted on the first tick after it was
# quarantined instead of getting its full revert window.
quar_cutoff=$(date -u -d "$QUAR_DAYS days ago" +%Y%m%d 2>/dev/null) || quar_cutoff=
quar_moved=0; quar_pending=0
while IFS= read -r d; do
  [ -n "$d" ] || continue
  quar_day=${d##*/}
  case "$quar_day" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) continue ;;
  esac
  [ -n "$quar_cutoff" ] && [ "$quar_day" -lt "$quar_cutoff" ] || continue
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$quar_moved" -ge "$QUAR_MAX" ]; then
      quar_pending=$((quar_pending + 1))
      continue
    fi
    path="$d/$name"
    if [ "$APPLY" -eq 0 ]; then
      class_dry[quarantine-expire]=$(( ${class_dry[quarantine-expire]:-0} + 1 ))
      [ "${class_dry[quarantine-expire]}" -le 5 ] && \
        act "DRY-RUN would delete expired-quarantine $path revert='none: quarantine window closed'"
      deleted=$((deleted + 1)); quar_moved=$((quar_moved + 1)); continue
    fi
    if kib=$(ak47_safe_delete "$path"); then
      act "delete class=quarantine-expire $path kib=${kib:-0} revert='none: quarantine window closed'"
      deleted=$((deleted + 1)); quar_moved=$((quar_moved + 1))
    else
      act "WARN could-not-delete class=quarantine-expire $path reason='${AK47_SD_ERROR}'"
      failures=$((failures + 1)); quar_moved=$((quar_moved + 1))
    fi
  done < <(find "$d" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null)
done < <(find "$QUAR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
[ "$quar_pending" -gt 0 ] && \
  act "deferred class=quarantine-expire pending=$quar_pending reason='per-run bound quarantine_expire_max=$QUAR_MAX; the next tick continues where this one stopped'"

# ---- report-only classes -------------------------------------------------------
report_only() {
  # dead-pane: a tmux pane whose process is gone. Never signalled, never killed.
  if command -v tmux >/dev/null 2>&1; then
    local dead
    dead=$(tmux list-panes -a -F '#{pane_dead}' 2>/dev/null | grep -c '^1$' || true)
    [ "${dead:-0}" -gt 0 ] && finding dead-pane "$dead tmux pane(s) report dead; the tick never signals the tmux server"
  fi

  # swap-pressure: the 2026-11-10 lockup shape.
  local sw mem
  sw=$(ak47_swap_pct); mem=$(ak47_mem_avail_gb)
  if [ "${sw:-0}" -ge 70 ] && [ "${mem:-0}" -ge 20 ]; then
    if [ "$SWAP_ARMED" = 1 ] && [ "$APPLY" -eq 1 ]; then
      # This runs as a user unit, and swapoff/swapon are root-only. Arming the
      # reclaim without saying so is a capability the tick does not have: it
      # would WARN and count a failure every tick while swap stayed full. So it
      # proves it can swap before it tries, and files the one line Aaron needs.
      if ! swap_privileged; then
        finding swap-unprivileged "swap ${sw}% full with ${mem} GB RAM free; reclaiming it needs root - grant it with the sudoers rule in ak47/README.md, or run: sudo swapoff -a && sudo swapon -a"
      else
        # swapoff -a on a full swap takes tens of minutes, far longer than this
        # unit's own start timeout, so the reclaim is a unit of its own and the
        # tick only rings it. Anything the tick did inline here would be killed
        # halfway, which is the one state this whole design exists to avoid.
        if ak47_unit_active ak47-swap-reclaim.service; then
          act "swap-pressure swap=${sw}% mem=${mem}G action='swap-reclaim already running' revert='none needed: pages back in'"
        elif ak47_unit_start ak47-swap-reclaim.service; then
          act "swap-pressure swap=${sw}% mem=${mem}G action='started ak47-swap-reclaim.service' revert='none needed: pages back in; swap is restored when it finishes'"
        else
          act "WARN swap-pressure swap=${sw}% could not start ak47-swap-reclaim.service; left alone"
          failures=$((failures + 1))
        fi
      fi
    else
      finding swap-pressure "swap ${sw}% full with ${mem} GB RAM free; arm swap_pressure=1 in $AK47_CONFIG/devops.conf to reclaim it"
    fi
  fi

  # fat-process: one pid over the ceiling for the whole hold window. The hold
  # clock lives in its own state file, never in the operator's config.
  local pid rss comm held holdf="$AK47_STATE/fat.hold" newhold
  newhold=$(mktemp) || newhold=/dev/null
  while read -r pid rss comm; do
    [ -n "${pid:-}" ] || continue
    case "$comm" in
      tmux|orca-serve|cli-proxy-api|kube-tunnel*|pi|systemd|sshd) continue ;;
    esac
    held=$(awk -v p="$pid" '$1==p{print $2;exit}' "$holdf" 2>/dev/null)
    if [ -z "${held:-}" ]; then
      printf '%s %s\n' "$pid" "$(ak47_epoch)" >>"$newhold" 2>/dev/null || true
      continue
    fi
    printf '%s %s\n' "$pid" "$held" >>"$newhold" 2>/dev/null || true
    [ $(( $(ak47_epoch) - held )) -ge $((FAT_MIN * 60)) ] || continue
    if [ "$FAT_ARMED" = 1 ] && [ "$APPLY" -eq 1 ]; then
      renice 19 -p "$pid" >/dev/null 2>&1 || true
      kill -TERM "$pid" 2>/dev/null || true
      # The escalation clock, so a SIGTERM the process ignores becomes a
      # SIGKILL five minutes later even though the next tick is a new process.
      printf '%s %s\n' "$pid" "$(ak47_epoch)" >>"$AK47_STATE/fat.term" 2>/dev/null || true
      act "fat-process pid=$pid comm=$comm rss=$((rss / 1048576))G action='renice 19 + SIGTERM' revert='process restarts from its own supervisor'"
    else
      finding fat-process "pid $pid ($comm) holding $((rss / 1048576)) GB for $((FAT_MIN)) min; arm fat_process=1 to reap it"
    fi
  done < <(ps -eo pid,rss,comm --sort=-rss --no-headers 2>/dev/null | awk -v g="$FAT_GB" '$2 > g*1048576 {print $1, $2, $3}' | head -5)
  if [ "$newhold" != /dev/null ]; then mv -f "$newhold" "$holdf" 2>/dev/null || rm -f "$newhold" 2>/dev/null || true; fi

  # fat-process escalation: a SIGTERM that was ignored becomes a SIGKILL after
  # five minutes. The clock is $AK47_STATE/fat.term, so it survives across
  # ticks; a dry run must not consume the record, or the next applying tick
  # would find nothing to escalate and the process would survive.
  local termf="$AK47_STATE/fat.term" tpid tepoch keepf
  if [ -s "$termf" ]; then
    keepf=$(mktemp) || keepf=/dev/null
    while read -r tpid tepoch; do
      [ -n "${tpid:-}" ] || continue
      case "${tepoch:-}" in ''|*[!0-9]*) continue ;; esac
      kill -0 "$tpid" 2>/dev/null || continue          # it died: drop the record
      if [ $(( $(ak47_epoch) - tepoch )) -ge 300 ]; then
        if [ "$APPLY" -eq 1 ]; then
          kill -KILL "$tpid" 2>/dev/null || true
          act "fat-process pid=$tpid action='SIGKILL after 5 min of ignored SIGTERM' revert='process restarts from its own supervisor'"
        else
          printf '%s %s\n' "$tpid" "$tepoch" >>"$keepf" 2>/dev/null || true
          finding fat-process "pid $tpid ignored SIGTERM for 5 min; a real tick would SIGKILL it"
        fi
      else
        printf '%s %s\n' "$tpid" "$tepoch" >>"$keepf" 2>/dev/null || true
      fi
    done <"$termf"
    if [ "$keepf" != /dev/null ]; then mv -f "$keepf" "$termf" 2>/dev/null || rm -f "$keepf" 2>/dev/null || true; fi
  fi

  # dry-run expiry: a class left report-only past its 24 h dry run is a
  # finding, not an action. The tick never arms itself; it only refuses to let
  # the "dry-run for 24 h, then armed" step be forgotten.
  local first_epoch age_h
  first_epoch=$(head -n 1 "$DEVOPS_LOG" 2>/dev/null | cut -d' ' -f1)
  first_epoch=$(date -u -d "${first_epoch:-}" +%s 2>/dev/null || echo 0)
  if [ "${first_epoch:-0}" -gt 0 ]; then
    age_h=$(( ( $(ak47_epoch) - first_epoch ) / 3600 ))
    if [ "$age_h" -ge 24 ]; then
      [ "$SWAP_ARMED" = 1 ] || finding swap-unarmed "swap-pressure has been report-only for ${age_h} h; arm it with swap_pressure=1 in $AK47_CONFIG/devops.conf"
      [ "$FAT_ARMED" = 1 ] || finding fat-unarmed "fat-process has been report-only for ${age_h} h; arm it with fat_process=1 in $AK47_CONFIG/devops.conf"
    fi
  fi

  # stale-lock: report only. Clearing a lock is firstmate's decision, never ours.
  local lock="$FM_HOME/state/.lock" lpid
  if [ -f "$lock" ]; then
    lpid=$(tr -dc 0-9 <"$lock" 2>/dev/null | head -c 12)
    if [ -n "${lpid:-}" ] && ! kill -0 "$lpid" 2>/dev/null; then
      finding stale-lock "state/.lock names pid $lpid which is not alive; report only, never cleared by the tick"
    fi
  fi

  # disk: report only.
  local disk; disk=$(ak47_root_disk_pct)
  [ -n "${disk:-}" ] && [ "$disk" -ge 85 ] && finding disk "root filesystem ${disk}% full"
}

# ---- the loop's own freshness --------------------------------------------------
# A loop that dies silently is worse than no loop. If the previous tick line is
# older than three intervals, this run says so in its own line and as a finding.
loop_gap=0
if [ -r "$DEVOPS_LOG" ]; then
  prev=$(tail -n 1 "$DEVOPS_LOG" | cut -d' ' -f1)
  prev_epoch=$(date -u -d "$prev" +%s 2>/dev/null || echo 0)
  if [ "${prev_epoch:-0}" -gt 0 ]; then
    loop_gap=$(( $(ak47_epoch) - prev_epoch ))
    [ "$loop_gap" -gt $((INTERVAL * 3)) ] && \
      finding loop-gap "the tick did not run for ${loop_gap}s (interval ${INTERVAL}s); the timer or the unit is failing"
  fi
fi

# ---- run -----------------------------------------------------------------------
# `before` was read from the snapshot above; re-reading it here would cost a
# second readdir and would report the post-move count as the pre-move one.
report_only
after=$(ak47_tmp_entries)

# Top-10 name prefixes, so a new runaway producer is visible as a trend.
top=$(python3 - "$TMP_ROOT" <<'PY' 2>/dev/null
import collections, os, re, sys
root = sys.argv[1]
c = collections.Counter()
for n in os.listdir(root):
    m = re.match(r'^([A-Za-z][A-Za-z0-9]*(?:[._-][A-Za-z0-9]+)?)', n)
    c[m.group(1) if m else n] += 1
print(','.join(f'{k}:{v}' for k, v in c.most_common(10)))
PY
)

# Budget breaches, so the tick line carries the verdict without a second read.
# The same pass writes the numeric sample the weekly review reads: a review that
# has to re-derive history from prose cannot propose a threshold.
breaches=""; sample=""
while IFS=$'\t' read -r key ceil dir _unit _reason; do
  val=$(ak47_metric "$key" 2>/dev/null) || continue
  [ -n "$val" ] || continue
  sample="${sample}${sample:+ }${key}=${val}"
  ak47_breach "$val" "$ceil" "$dir" && breaches="${breaches}${breaches:+,}${key}=${val}>${ceil}"
done < <(ak47_budget_rows)
printf '%s %s\n' "$(ak47_epoch)" "$sample" >>"$AK47_STATE/samples.log" 2>/dev/null || true

# A size the walk could not finish is itself a finding. The budget still scores
# the last known value, which is the right call for a slow sample - but if that
# value is old, the sweep is choosing entries from a picture of a tree that is
# no longer the tree, and that is exactly how a hygiene loop goes wrong quietly.
tmp_age=$(ak47_cache_age tmp_gb_ok 2>/dev/null) || tmp_age=""
if [ -n "$tmp_age" ] && [ "$tmp_age" -gt $(( 2 * ${AK47_DU_TTL:-1800} )) ]; then
  # One finding per episode, not one per tick. The 6 h key below already spaces
  # repeats, but the key is cleared the moment the tree is measurable again, so a
  # new episode reports immediately instead of waiting out the old window.
  covered=$(ak47_cache_get tmp_gb_partial 345600 2>/dev/null) || covered=""
  finding tmp-gb-stale "/tmp has not been measured for $(( tmp_age / 60 )) min: the ${AK47_DU_BUDGET:-300}s size walk did not finish${covered:+ (covered $covered entries)}, so the budget is scoring a stale number. Measure by hand: find /tmp -maxdepth 1 -type d -printf '%p\\0' | xargs -0 du -sx --block-size=1M | sort -rn | head -20"
else
  # Measurable again: end the episode so the next one is not silenced by it.
  rm -f "$AK47_STATE/keys/tmp-gb-stale" 2>/dev/null || true
fi

# Per-class counts, so the line says what moved without reading reap.log.
byclass=""
for c in tmp-mktemp tmp-producer orphan-task-scratch quarantine-expire; do
  n=${class_moved[$c]:-0}
  [ "$APPLY" -eq 0 ] && n=${class_dry[$c]:-0}
  [ "$n" -gt 0 ] && byclass="${byclass}${byclass:+,}${c}:${n}"
done

# One line, every run. Silence is provable because this line is always here.
line="tick mode=$([ "$APPLY" -eq 1 ] && echo apply || echo dry-run) tmp_before=$before tmp_after=$after moved=$moved deleted=$deleted busy=$skipped_busy protected=$skipped_protected failures=$failures actions=$actions loop_gap=${loop_gap}s classes=${byclass:-none} expire_pending=$quar_pending breaches=${breaches:-none} top=$top"
ak47_log "$DEVOPS_LOG" "$line"

# Findings the table cannot settle: durable, rate-limited, and delivered to the
# chair's inbox so a lane can pick them up. One key per finding per 6 h.
if [ "${#findings[@]}" -gt 0 ]; then
  mkdir -p "$AK47_STATE/keys" 2>/dev/null || true
  # The dedupe key is committed only after the note is actually delivered. A
  # key touched before a failed send silences the finding for six hours: the
  # same defect the health beat had, in the other half of the same system.
  fresh=(); freshkeys=()
  for f in "${findings[@]}"; do
    key=${f%%|*}; msg=${f#*|}
    kf="$AK47_STATE/keys/$key"
    if [ ! -f "$kf" ] || [ $(( $(ak47_epoch) - $(stat -c %Y "$kf" 2>/dev/null || echo 0) )) -gt 21600 ]; then
      ak47_log "$FIND_LOG" "$key $msg"
      fresh+=("$msg"); freshkeys+=("$kf")
    fi
  done
  if [ "${#fresh[@]}" -gt 0 ]; then
    body=$(printf '%s; ' "${fresh[@]}")
    if [ -x "$FM_HOME/bin/fm-inbox.sh" ] && \
       "$FM_HOME/bin/fm-inbox.sh" note --source "$INBOX_CLASS" \
         "ak47 hygiene: ${body}board $AK47_STATE/status.md" >/dev/null 2>&1; then
      for kf in "${freshkeys[@]}"; do touch "$kf" 2>/dev/null || true; done
    else
      ak47_log "$FIND_LOG" "DELIVERY-FAILED ${#fresh[@]} finding(s) not delivered; dedupe keys not committed"
    fi
  fi
fi

# Refresh the board every run so status.md is never older than one interval.
"$AK47_ROOT/status.sh" >/dev/null 2>&1 || true

[ "$PRINT" = 1 ] && { echo "$line"; echo; cat "$AK47_STATE/status.md" 2>/dev/null; }
exit 0
