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
#                         quarantine_days
#   dead-pane             a tmux pane whose process is gone            report only   report
#   swap-pressure         swap >= 70% and RAM available >= 20 GB       report only   report
#   fat-process           one pid > fat_process_gb for fat_process_min report only   report
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
MAX_ENTRIES=$(ak47_conf tmp_max_entries 5000)
MAX_MOVES=$(ak47_conf tmp_max_moves 2000)
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

# ---- the protected set ---------------------------------------------------------
# A path is protected when its canonical spelling is one of these, or lives under
# one of these. Both sides are canonicalised by ak47_path_identity before the
# comparison, so /tmp//fm-move/ and /tmp/fm-move are the same path.
PROTECTED_EXACT=(
  "$TMP_ROOT/fm-move"
  "$TMP_ROOT/jest_0"
  "$TMP_ROOT/.X11-unix" "$TMP_ROOT/.ICE-unix" "$TMP_ROOT/.font-unix"
  "$TMP_ROOT/.Test-unix" "$TMP_ROOT/.XIM-unix"
)
PROTECTED_GLOB=(
  "$TMP_ROOT/ak47-*" "$TMP_ROOT/orcad-*" "$TMP_ROOT/systemd-*" "$TMP_ROOT/snap*"
  "$TMP_ROOT/.X*-lock" "$TMP_ROOT/*router*.sh" "$TMP_ROOT/*forward*"
  "$TMP_ROOT/cli-proxy*" "$TMP_ROOT/*.token"
)

# Both spellings are checked. A symlink named /tmp/ak47-foo resolves to its
# target under realpath, so a canonical-only check would miss it; a literal-only
# check would miss /tmp//ak47-foo. Checking both is the only way to be sure the
# two sides of the comparison spell the path the same way.
#
# The protected roots are canonicalised ONCE here, not per candidate: the loop
# below runs 5,000 times and a realpath fork per comparison cost 24 minutes on
# the first measurement. After this, every comparison is a string test.
PROTECTED_EXACT_CANON=()
for p in "${PROTECTED_EXACT[@]}"; do
  PROTECTED_EXACT_CANON+=("$(ak47_path_identity "$p" || echo "$p")")
done
PROTECTED_GLOB_CANON=()
for p in "${PROTECTED_GLOB[@]}"; do
  # Only the directory part can be a symlink; the pattern tail is literal.
  dir=${p%/*}; tail=${p##*/}
  PROTECTED_GLOB_CANON+=("$(ak47_path_identity "$dir" || echo "$dir")/$tail")
done

# _protected_spelling <path> - the string tests, no forks.
_protected_spelling() {
  local id=$1 p task
  for p in "${PROTECTED_EXACT_CANON[@]}"; do
    [ "$id" = "$p" ] && return 0
    case "$id" in "$p"/*) return 0 ;; esac
  done
  for p in "${PROTECTED_GLOB_CANON[@]}"; do
    # shellcheck disable=SC2053  # the glob is the pattern, deliberately unquoted
    # shellcheck disable=SC2254 # The producer table is deliberately globs.
    case "$id" in $p) return 0 ;; esac
  done
  # A live task's scratch root is protected for as long as its metadata exists.
  case "$id" in
    "$TMP_ROOT"/fm-*)
      task=${id#"$TMP_ROOT"/fm-}
      task=${task%%/*}
      [ -f "$FM_HOME/state/$task.meta" ] && return 0
      ;;
  esac
  return 1
}

# is_protected <path> - 0 when the path must not be touched.
# The literal spelling is checked first and costs nothing. Only a symlink can
# spell itself differently from its canonical path here, because every candidate
# is a direct child of a real /tmp, so the canonical pass runs at most once per
# symlink instead of once per candidate.
is_protected() {
  local path=$1 id
  _protected_spelling "$path" && return 0
  [ -L "$path" ] || return 1
  id=$(ak47_path_identity "$path") || return 0   # cannot canonicalise -> protect
  _protected_spelling "$id" && return 0
  return 1
}

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
for p in "${PROTECTED_EXACT[@]}"; do prot_args+=(--protected-exact "$p"); done
for p in "${PROTECTED_GLOB[@]}"; do prot_args+=(--protected-glob "$p"); done
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
  local name=$1 class=$2 path="$TMP_ROOT/$1" dest="$qdir/$1" kib
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
  [ "$before" -le "$MAX_ENTRIES" ] && break
  [ "$moved" -ge "$MAX_MOVES" ] && break
  path="$TMP_ROOT/$name"
  # Re-verify on the canonical path: the classifier's pass is a prefilter.
  if is_protected "$path"; then skipped_protected=$((skipped_protected + 1)); continue; fi
  if is_busy "$name"; then skipped_busy=$((skipped_busy + 1)); continue; fi
  # The small class gets a real per-path handle scan as well as the busy set.
  if [ "$class" = orphan-task-scratch ]; then
    rc=0; ak47_has_open_handles "$path" || rc=$?
    if [ "$rc" -ne 1 ]; then skipped_busy=$((skipped_busy + 1)); continue; fi
  fi
  quarantine "$name" "$class"
done <"$CLASSED"

# ---- class: quarantine-expire --------------------------------------------------
# Quarantine is a 7-day holding pen, not a second /tmp. Anything still there
# after quarantine_days is deleted; the revert window has closed.
while IFS= read -r d; do
  [ -n "$d" ] || continue
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    path="$d/$name"
    if [ "$APPLY" -eq 0 ]; then
      class_dry[quarantine-expire]=$(( ${class_dry[quarantine-expire]:-0} + 1 ))
      [ "${class_dry[quarantine-expire]}" -le 5 ] && \
        act "DRY-RUN would delete expired-quarantine $path revert='none: quarantine window closed'"
      deleted=$((deleted + 1)); continue
    fi
    if kib=$(ak47_safe_delete "$path"); then
      act "delete class=quarantine-expire $path kib=${kib:-0} revert='none: quarantine window closed'"
      deleted=$((deleted + 1))
    else
      act "WARN could-not-delete class=quarantine-expire $path reason='${AK47_SD_ERROR}'"
      failures=$((failures + 1))
    fi
  done < <(find "$d" -mindepth 1 -maxdepth 1 -mtime +"$QUAR_DAYS" -printf '%f\n' 2>/dev/null)
done < <(find "$QUAR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

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
      if swapoff -a 2>/dev/null && swapon -a 2>/dev/null; then
        act "swap-pressure swap=${sw}% mem=${mem}G action='swapoff -a && swapon -a' revert='none needed: pages back in'"
      else
        act "WARN swap-pressure swap=${sw}% action failed; left alone"
        failures=$((failures + 1))
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
      act "fat-process pid=$pid comm=$comm rss=$((rss / 1048576))G action='renice 19 + SIGTERM' revert='process restarts from its own supervisor'"
    else
      finding fat-process "pid $pid ($comm) holding $((rss / 1048576)) GB for $((FAT_MIN)) min; arm fat_process=1 to reap it"
    fi
  done < <(ps -eo pid,rss,comm --sort=-rss --no-headers 2>/dev/null | awk -v g="$FAT_GB" '$2 > g*1048576 {print $1, $2, $3}' | head -5)
  if [ "$newhold" != /dev/null ]; then mv -f "$newhold" "$holdf" 2>/dev/null || rm -f "$newhold" 2>/dev/null || true; fi

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
ak47_log "$AK47_STATE/samples.log" "$(ak47_epoch) $sample"

# Per-class counts, so the line says what moved without reading reap.log.
byclass=""
for c in tmp-mktemp tmp-producer orphan-task-scratch quarantine-expire; do
  n=${class_moved[$c]:-0}
  [ "$APPLY" -eq 0 ] && n=${class_dry[$c]:-0}
  [ "$n" -gt 0 ] && byclass="${byclass}${byclass:+,}${c}:${n}"
done

# One line, every run. Silence is provable because this line is always here.
line="tick mode=$([ "$APPLY" -eq 1 ] && echo apply || echo dry-run) tmp_before=$before tmp_after=$after moved=$moved deleted=$deleted busy=$skipped_busy protected=$skipped_protected failures=$failures actions=$actions loop_gap=${loop_gap}s classes=${byclass:-none} breaches=${breaches:-none} top=$top"
ak47_log "$DEVOPS_LOG" "$line"

# Findings the table cannot settle: durable, rate-limited, and delivered to the
# chair's inbox so a lane can pick them up. One key per finding per 6 h.
if [ "${#findings[@]}" -gt 0 ]; then
  mkdir -p "$AK47_STATE/keys" 2>/dev/null || true
  fresh=()
  for f in "${findings[@]}"; do
    key=${f%%|*}; msg=${f#*|}
    kf="$AK47_STATE/keys/$key"
    if [ ! -f "$kf" ] || [ $(( $(ak47_epoch) - $(stat -c %Y "$kf" 2>/dev/null || echo 0) )) -gt 21600 ]; then
      touch "$kf"
      ak47_log "$FIND_LOG" "$key $msg"
      fresh+=("$msg")
    fi
  done
  if [ "${#fresh[@]}" -gt 0 ] && [ -x "$FM_HOME/bin/fm-inbox.sh" ]; then
    body=$(printf '%s; ' "${fresh[@]}")
    "$FM_HOME/bin/fm-inbox.sh" note --source ak47-devops \
      "ak47 hygiene: ${body}board $AK47_STATE/status.md" >/dev/null 2>&1 || true
  fi
fi

# Refresh the board every run so status.md is never older than one interval.
"$AK47_ROOT/status.sh" >/dev/null 2>&1 || true

[ "$PRINT" = 1 ] && { echo "$line"; echo; cat "$AK47_STATE/status.md" 2>/dev/null; }
exit 0
