#!/usr/bin/env bash
# fm-time.sh - propose, approve, and report the captain's own work hours.
#
# Firstmate orchestrates but never clocks the captain in: this script scans
# this home's own durable records for evidence that work happened, PROPOSES
# candidate work windows from that evidence, and records nothing until the
# captain approves, corrects, or rejects each one. Live start/stop and
# retroactive log entries are recorded immediately because starting, stopping,
# or logging IS the captain's approval.
#
# Usage:
#   fm-time.sh propose [--since "<YYYY-MM-DD HH:MM>"] [--replace]
#   fm-time.sh list
#   fm-time.sh approve <id> [--start "<YYYY-MM-DD HH:MM>"] [--end "<YYYY-MM-DD HH:MM>"]
#                           [--project <name>] [--task <name>] [--desc <text>]
#   fm-time.sh reject <id>...
#   fm-time.sh split <id> --at "<YYYY-MM-DD HH:MM>"
#   fm-time.sh start [--project <name>] [--task <name>] [--desc <text>]
#   fm-time.sh stop [--desc <text>]
#   fm-time.sh log --start "<YYYY-MM-DD HH:MM>" --end "<YYYY-MM-DD HH:MM>"
#                   [--project <name>] [--task <name>] --desc <text>
#   fm-time.sh report [--month YYYY-MM] [--project <name>]
#
# Evidence signals (propose). Investigated candidates and why each is used or
# skipped:
#   - state/<id>.status mtime         used: last-touch ping for that task, tagged
#                                      with the tail status line as its evidence text.
#   - state/<id>.meta mtime           used: a task's earliest activity often
#                                      predates its first status line, but this
#                                      file is also rewritten well after spawn
#                                      (mode changes, control actions, a merged
#                                      PR's pr= field), so its evidence text
#                                      says only "task record touched", never
#                                      "spawned" - that would overclaim what a
#                                      bare mtime can prove.
#   - data/<id>/report.md mtime       used: scout-report-finalized ping.
#   - data/backlog.md, data/done-archive.md
#                                     used: "(done YYYY-MM-DD)", "(reported
#                                      YYYY-MM-DD)" (tasks-axi writes this for a
#                                      task closed with --report), and "(merged
#                                      YYYY-MM-DD)" (tasks-axi writes this for a
#                                      task closed with --pr) entries all become
#                                      day-only pings (noon local), the one
#                                      signal that survives a torn-down task's
#                                      state files.
#   - state/.wake-queue                used opportunistically: it carries real epoch
#                                      seconds, but the queue is drained on
#                                      acknowledgement, so it holds only whatever is
#                                      CURRENTLY undrained, never a durable history.
#   - session lock (state/.lock)       NOT used: one file, one mtime, no history -
#                                      it names only the current holder, so it cannot
#                                      answer "when was work happening" after the fact.
#   - project git commit history       NOT used in this version: firstmate's own
#                                      projects/<name> clones sit on their default
#                                      branch, so this would see only merged work, not
#                                      the in-flight branches a captain most wants
#                                      tracked. Left as a documented future signal.
# Every window's evidence list survives into the proposal so `approve` is an
# informed decision, not a rubber stamp of a guess.
#
# Window merging. Evidence pings for the same (project, task) within the
# time-tracking-gap-minutes config setting (default 45 minutes) of each other
# join one window; a bigger gap starts a new one. 45 minutes, not something
# tighter, because this repo's own crewmates are instructed to append status
# only on sparse phase changes rather than routine progress (AGENTS.md section
# 8), so a continuously-worked task can easily go 30-60 minutes between
# evidence pings without having stopped. A lone ping still costs the
# time-tracking-pad-minutes config setting (default 15 minutes) of credited
# time, because a single commit-sized signal is real work, not zero-duration
# work.
#
# After hours. A window's classification is decided by its START time only:
# any day listed in config/time-tracking-weekend-days (default "6,7", ISO
# weekday numbers 1=Monday..7=Sunday, empty = no weekend rule at all so no work
# week is hardcoded) is after hours regardless of clock time; otherwise a start
# before config/time-tracking-workday-start (default 09:00) or at/after
# config/time-tracking-workday-end (default 18:00) is after hours.
#
# Storage. All state lives under this home's gitignored data/time-tracking/,
# never under state/ (supervision-owned) and never inside a project:
#   data/time-tracking/cursor       epoch through which evidence has been fully
#                                    resolved (approved, rejected, or split); the
#                                    floor for the next propose scan.
#   data/time-tracking/proposals.md the current pending batch, one "## <id>" block
#                                    per candidate window; propose refuses to
#                                    generate a new batch while one is pending
#                                    unless --replace is given.
#   data/time-tracking/entries.md   the durable approved ledger, one "## <id>"
#                                    block per recorded window. Plain
#                                    "key=value" lines and one line per evidence
#                                    entry: diffable, and safe to hand-edit because
#                                    duration and after-hours status are always
#                                    recomputed from start/end at report time,
#                                    never trusted from a stored field.
#   data/time-tracking/active       present only between `start` and `stop`.
#   data/time-tracking/.lock        transient mkdir-based mutex held only for
#                                    the span of a single command's own
#                                    read-modify-write; not part of the durable
#                                    record, and never held across commands.
#
# Configuration (gitignored, one setting per file, absent = default):
#   config/time-tracking-gap-minutes         session-merge gap, minutes (default 45)
#   config/time-tracking-pad-minutes         credited minutes for a lone ping (default 15)
#   config/time-tracking-workday-start       local HH:MM (default 09:00)
#   config/time-tracking-workday-end         local HH:MM (default 18:00)
#   config/time-tracking-weekend-days        comma list, ISO 1-7 (default 6,7)
#
# Environment:
#   FM_HOME   operational home whose state/, data/, and config/ are used.
#
# Never touches state/.lock, state/.wake-queue, or any other supervision file
# except to read it; never writes to projects/.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
TT="$DATA/time-tracking"

die() { printf 'fm-time: %s\n' "$*" >&2; exit 1; }

# Count of "## pN" blocks in proposals.md. grep -c already prints 0 and no
# other output on zero matches, so no `|| echo 0` fallback is needed - adding
# one would double-print when grep's own "0" line is followed by the fallback.
proposal_count() {
  [ -r "$TT/proposals.md" ] || { printf 0; return; }
  grep -c '^## p' "$TT/proposals.md" 2>/dev/null || true
}

usage() {
  awk 'NR == 1 { next }
       /^#/ { sub(/^# ?/, ""); print; next }
       { exit }' "${BASH_SOURCE[0]}"
}

# ---------------------------------------------------------------- portable time

fm_time_mtime() {  # <path> -> epoch seconds, or nothing on failure
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

now_epoch() { printf '%s\n' "${FM_TIME_NOW_OVERRIDE:-$(date +%s)}"; }

# epoch -> "YYYY-MM-DD HH:MM" local wall clock.
epoch_to_local() {
  date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null
}

# "YYYY-MM-DD HH:MM" local -> epoch. Empty output on unparseable input.
local_to_epoch() {
  date -j -f '%Y-%m-%d %H:%M' "$1" '+%s' 2>/dev/null || date -d "$1" '+%s' 2>/dev/null
}

epoch_to_dow() {  # ISO weekday, 1=Monday .. 7=Sunday
  date -r "$1" '+%u' 2>/dev/null || date -d "@$1" '+%u' 2>/dev/null
}

epoch_to_hm() {
  date -r "$1" '+%H:%M' 2>/dev/null || date -d "@$1" '+%H:%M' 2>/dev/null
}

epoch_to_yyyymm() {
  date -r "$1" '+%Y-%m' 2>/dev/null || date -d "@$1" '+%Y-%m' 2>/dev/null
}

fmt_minutes() {  # <minutes> -> "1h15m"
  local m=$1 h
  h=$((m / 60)); m=$((m % 60))
  printf '%dh%02dm' "$h" "$m"
}

# ---------------------------------------------------------------- config

read_config() {  # <file-name> <default>
  local path="$CONFIG/$1" line
  if [ -r "$path" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      line=${line#"${line%%[![:space:]]*}"}
      line=${line%"${line##*[![:space:]]}"}
      if [ -n "$line" ]; then
        printf '%s' "$line"
        return 0
      fi
    done < "$path"
  fi
  printf '%s' "$2"
}

GAP_MINUTES=$(read_config time-tracking-gap-minutes 45)
PAD_MINUTES=$(read_config time-tracking-pad-minutes 15)
WORKDAY_START=$(read_config time-tracking-workday-start 09:00)
WORKDAY_END=$(read_config time-tracking-workday-end 18:00)
WEEKEND_DAYS=$(read_config time-tracking-weekend-days 6,7)

is_after_hours() {  # <epoch> -> yes|no
  local epoch=$1 dow hm
  dow=$(epoch_to_dow "$epoch") || { printf 'no'; return; }
  case ",$WEEKEND_DAYS," in
    *",$dow,"*) printf 'yes'; return ;;
  esac
  hm=$(epoch_to_hm "$epoch") || { printf 'no'; return; }
  if [[ "$hm" < "$WORKDAY_START" || "$hm" > "$WORKDAY_END" || "$hm" == "$WORKDAY_END" ]]; then
    printf 'yes'
  else
    printf 'no'
  fi
}

# ---------------------------------------------------------------- own lock

# A tiny mkdir-based mutex over this home's OWN time-tracking files - never
# the supervision session lock (state/.lock), which this script only ever
# reads. mkdir is atomic on every filesystem this script already assumes, so
# this needs no flock dependency (flock is absent on macOS; see
# fm-supervise-daemon.sh's own comment on the same tradeoff). The holder's own
# pid is recorded inside the lock dir the instant it is created, and staleness
# is decided by that pid's liveness (kill -0), not by how long the lock has
# been held: `propose` can legitimately hold this lock across a slow evidence
# scan, and a fixed wall-clock cutoff would let a second command steal the
# lock out from under a still-running one, corrupting proposals.md or entries
# in a lost-update race. LOCK_STALE_SECS is kept only as a narrow fallback for
# the brief window after mkdir succeeds but before the pid file is written
# (e.g. a crash in between): once a pid is on record, its liveness is
# authoritative and the lock is held exactly as long as its owner is alive.
TT_LOCK="$TT/.lock"
LOCK_STALE_SECS="${FM_TIME_LOCK_STALE_OVERRIDE:-10}"

tt_lock() {
  mkdir -p "$TT"
  local tries=0 age owner_pid
  while ! mkdir "$TT_LOCK" 2>/dev/null; do
    owner_pid=$(cat "$TT_LOCK/pid" 2>/dev/null) || owner_pid=""
    if [ -n "$owner_pid" ]; then
      if ! kill -0 "$owner_pid" 2>/dev/null; then
        rm -rf "$TT_LOCK" 2>/dev/null || true
        continue
      fi
    else
      age=$(fm_time_mtime "$TT_LOCK" 2>/dev/null) || age=""
      if [ -n "$age" ] && [ "$(( $(now_epoch) - age ))" -ge "$LOCK_STALE_SECS" ]; then
        rm -rf "$TT_LOCK" 2>/dev/null || true
        continue
      fi
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || die "another fm-time.sh command appears to be running against this home; try again"
    sleep 0.1
  done
  printf '%s\n' "$$" > "$TT_LOCK/pid"
  trap tt_release_if_owner EXIT
}

# Removes the lock only if its recorded pid is still this process's own pid.
# Used both as the ordinary unlock path and as the EXIT trap handler so a
# signal arriving between tt_unlock's own removal and its `trap -` clear can
# never blow away a lock a *different* command has since acquired: by the
# time the trap fires, the pid file either matches this process (safe to
# remove) or belongs to someone else / is already gone (leave it alone).
tt_release_if_owner() {
  local owner_pid
  owner_pid=$(cat "$TT_LOCK/pid" 2>/dev/null) || owner_pid=""
  [ "$owner_pid" = "$$" ] && rm -rf "$TT_LOCK" 2>/dev/null
  return 0
}

tt_unlock() {
  tt_release_if_owner
  trap - EXIT
}

# ---------------------------------------------------------------- cursor

CURSOR_FILE="$TT/cursor"

read_cursor() {
  local c
  if [ -r "$CURSOR_FILE" ]; then
    c=$(head -1 "$CURSOR_FILE" 2>/dev/null)
    case "$c" in *[!0-9]*|'') ;; *) printf '%s' "$c"; return ;; esac
  fi
  # No cursor yet: default floor is 30 days back so a first run is bounded.
  printf '%s' "$(( $(now_epoch) - 30 * 86400 ))"
}

write_cursor() {
  mkdir -p "$TT"
  printf '%s\n' "$1" > "$CURSOR_FILE.tmp"
  mv "$CURSOR_FILE.tmp" "$CURSOR_FILE"
}

# ---------------------------------------------------------------- evidence gathering

# Emits TSV lines: epoch<TAB>project<TAB>task<TAB>source<TAB>text
gather_evidence() {  # <since-epoch> <out-file>
  local since=$1 out=$2 f id mtime meta project text line kind key payload epoch

  : > "$out"

  for f in "$STATE"/*.status; do
    [ -e "$f" ] || break
    id=$(basename "$f" .status)
    mtime=$(fm_time_mtime "$f") || continue
    [ -n "$mtime" ] && [ "$mtime" -gt "$since" ] || continue
    project=-
    meta="$STATE/$id.meta"
    if [ -r "$meta" ]; then
      project=$(sed -n 's/^project=//p' "$meta" | head -1)
      [ -n "$project" ] && project=$(basename "$project") || project=-
    fi
    text=$(tail -1 "$f" 2>/dev/null | tr -d '\t' | cut -c1-140)
    printf '%s\t%s\t%s\tstatus\t%s\n' "$mtime" "$project" "$id" "$text" >> "$out"
  done

  for f in "$STATE"/*.meta; do
    [ -e "$f" ] || break
    id=$(basename "$f" .meta)
    mtime=$(fm_time_mtime "$f") || continue
    [ -n "$mtime" ] && [ "$mtime" -gt "$since" ] || continue
    project=$(sed -n 's/^project=//p' "$f" | head -1)
    [ -n "$project" ] && project=$(basename "$project") || project=-
    printf '%s\t%s\t%s\tmeta\ttask record touched\n' "$mtime" "$project" "$id" >> "$out"
  done

  for f in "$DATA"/*/report.md; do
    [ -e "$f" ] || break
    id=$(basename "$(dirname "$f")")
    mtime=$(fm_time_mtime "$f") || continue
    [ -n "$mtime" ] && [ "$mtime" -gt "$since" ] || continue
    project=-
    meta="$STATE/$id.meta"
    if [ -r "$meta" ]; then
      project=$(sed -n 's/^project=//p' "$meta" | head -1)
      [ -n "$project" ] && project=$(basename "$project") || project=-
    fi
    printf '%s\t%s\t%s\treport\tscout report finalized\n' "$mtime" "$project" "$id" >> "$out"
  done

  local bf
  for bf in "$DATA/backlog.md" "$DATA/done-archive.md"; do
    [ -r "$bf" ] || continue
    while IFS= read -r line; do
      case "$line" in
        '- [x] '*) ;;
        *) continue ;;
      esac
      id=${line#"- [x] "}
      id=${id%% - *}
      [ -n "$id" ] || continue
      case "$line" in
        *'(done '????-??-??')'*)
          text=$(printf '%s' "$line" | sed -n 's/.*(done \([0-9-]\{10\}\)).*/\1/p')
          ;;
        *'(reported '????-??-??')'*)
          # tasks-axi writes "(reported YYYY-MM-DD)" instead of "(done ...)"
          # when a scout task is closed with --report; without this branch
          # every scout completion (roughly a fifth of this repo's own
          # archive) is silently invisible to propose.
          text=$(printf '%s' "$line" | sed -n 's/.*(reported \([0-9-]\{10\}\)).*/\1/p')
          ;;
        *'(merged '????-??-??')'*)
          # tasks-axi writes "(merged YYYY-MM-DD)" instead of "(done ...)"
          # when a task is closed with --pr (verified against this repo's own
          # tasks-axi binary: `done <id> --pr <url>` produces this marker);
          # without this branch every PR-linked completion is silently
          # invisible to propose.
          text=$(printf '%s' "$line" | sed -n 's/.*(merged \([0-9-]\{10\}\)).*/\1/p')
          ;;
        *) continue ;;
      esac
      [ -n "$text" ] || continue
      epoch=$(local_to_epoch "$text 12:00") || continue
      [ -n "$epoch" ] && [ "$epoch" -gt "$since" ] || continue
      project=$(printf '%s' "$line" | sed -n 's/.*(repo: \([^)]*\)).*/\1/p')
      [ -n "$project" ] || project=-
      payload=$(printf '%s' "$line" \
        | sed 's/^- \[x\] [^ ]* - //' \
        | sed -e 's/ (done [0-9-]*)//' -e 's/ (reported [0-9-]*)//' -e 's/ (merged [0-9-]*)//' -e 's/ (repo: [^)]*)//' \
        | cut -c1-140)
      printf '%s\t%s\t%s\tbacklog\t%s\n' "$epoch" "$project" "$id" "$payload" >> "$out"
    done < "$bf"
  done

  if [ -r "$STATE/.wake-queue" ]; then
    while IFS=$'\t' read -r epoch _seq kind key payload; do
      case "$epoch" in ''|*[!0-9]*) continue ;; esac
      [ "$epoch" -gt "$since" ] || continue
      printf '%s\tfirstmate\t%s\twake\t%s: %s\n' "$epoch" "${key:--}" "$kind" "$payload" >> "$out"
    done < "$STATE/.wake-queue"
  fi
}

# ---------------------------------------------------------------- clustering

# Reads evidence TSV on stdin (any order), writes proposal blocks to stdout in
# the "## pN" key=value shape described in the header.
cluster_evidence() {
  sort -t $'\t' -k2,2 -k3,3 -k1,1n "$1" | awk -F'\t' -v gap=$((GAP_MINUTES * 60)) -v pad=$((PAD_MINUTES * 60)) '
    function flush(n) {
      if (n == 0) return
      pid++
      printf "## p%d\n", pid
      printf "start=%s\n", start_disp
      printf "end=%s\n", end_disp
      printf "project=%s\n", cur_project
      printf "task=%s\n", cur_task
      printf "desc=%s\n", last_text
      for (i = 1; i <= n; i++) printf "evidence=%s\n", ev[i]
      printf "\n"
    }
    BEGIN { pid = 0; n = 0 }
    {
      epoch = $1; project = $2; task = $3; source = $4; text = $5
      key = project SUBSEP task
      if (n > 0 && (key != cur_key || (epoch - last_epoch) > gap)) {
        flush(n)
        n = 0
      }
      if (n == 0) {
        cur_key = key; cur_project = project; cur_task = task
        first_epoch = epoch
        cmd = "date -r " epoch " \"+%Y-%m-%d %H:%M\" 2>/dev/null || date -d @" epoch " \"+%Y-%m-%d %H:%M\""
        cmd | getline start_disp
        close(cmd)
      }
      last_epoch = epoch
      last_text = text
      n++
      ev[n] = epoch " | " source " | " text
      end_epoch = epoch + pad
      cmd = "date -r " end_epoch " \"+%Y-%m-%d %H:%M\" 2>/dev/null || date -d @" end_epoch " \"+%Y-%m-%d %H:%M\""
      cmd | getline end_disp
      close(cmd)
    }
    END { flush(n) }
  '
}

# ---------------------------------------------------------------- propose / list

cmd_propose() {
  local replace=0 since_opt="" since_epoch out
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --replace) replace=1; shift ;;
      --since) since_opt=$2; shift 2 ;;
      *) die "propose: unknown argument: $1" ;;
    esac
  done

  mkdir -p "$TT"
  tt_lock
  if [ "$(proposal_count)" -gt 0 ] && [ "$replace" -ne 1 ]; then
    die "a pending proposal batch already exists; resolve it with approve/reject/split, or pass --replace to discard it and rescan"
  fi

  if [ -n "$since_opt" ]; then
    since_epoch=$(local_to_epoch "$since_opt") || die "propose: unparseable --since value: $since_opt"
  else
    since_epoch=$(read_cursor)
  fi

  local now
  now=$(now_epoch)
  out=$(mktemp "$TT/.evidence.XXXXXX")
  trap 'rm -f "$out"' RETURN
  gather_evidence "$since_epoch" "$out"

  {
    printf '# time-tracking proposals\n'
    printf '# scan_from=%s scan_to=%s generated=%s\n' "$since_epoch" "$now" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '#\n'
    cluster_evidence "$out"
  } > "$TT/proposals.md.tmp"
  mv "$TT/proposals.md.tmp" "$TT/proposals.md"
  rm -f "$out"
  trap - RETURN

  local count
  count=$(proposal_count)
  if [ "$count" -eq 0 ]; then
    # Nothing to resolve, so nothing blocks the cursor from moving forward;
    # otherwise every future propose would keep rescanning this same dead range.
    # Only do this when the scan used the persisted cursor: an explicit --since
    # is a one-off query and must never silently move the standing cursor.
    [ -n "$since_opt" ] || write_cursor "$now"
    : > "$TT/proposals.md"
    printf 'no work windows found in evidence since %s\n' "$(epoch_to_local "$since_epoch")"
  else
    printf '%s proposed window(s) since %s - review with: fm-time.sh list\n' "$count" "$(epoch_to_local "$since_epoch")"
  fi
  tt_unlock
}

cmd_list() {
  if [ ! -s "$TT/proposals.md" ] || [ "$(proposal_count)" -eq 0 ]; then
    printf 'no pending proposals. Run: fm-time.sh propose\n'
    return 0
  fi
  awk '
    /^## / { if (id != "") print ""; id = substr($0, 4); print "[" id "]"; next }
    /^evidence=/ { print "  evidence: " substr($0, 10); next }
    /^(start|end|project|task|desc)=/ { split($0, kv, "="); printf "  %-8s %s\n", kv[1], substr($0, length(kv[1]) + 2); next }
  ' "$TT/proposals.md"
}

# Extracts the "## <id> ... (blank line or EOF)" block for <id> from <file>.
extract_block() {  # <file> <id>
  awk -v want="## $2" '
    $0 == want { found = 1; next }
    found && /^## / { exit }
    found && NF == 0 { exit }
    found { print }
  ' "$1"
}

block_field() {  # <block-text> <field>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

remove_block() {  # <file> <id> -> rewrites file without that block
  awk -v want="## $2" '
    BEGIN { skip = 0 }
    $0 == want { skip = 1; next }
    skip && /^## / { skip = 0 }
    skip && NF == 0 { skip = 0; next }
    !skip { print }
  ' "$1"
}

# True (0) once no "## p" block remains in proposals.md.
batch_empty() {
  [ "$(proposal_count)" -eq 0 ]
}

advance_cursor_if_batch_done() {
  if batch_empty; then
    local scan_to
    scan_to=$(sed -n 's/.*scan_to=\([0-9]*\).*/\1/p' "$TT/proposals.md" | head -1)
    [ -n "$scan_to" ] && write_cursor "$scan_to"
    : > "$TT/proposals.md"
  fi
}

next_entry_id() {
  printf 'e-%s-%s\n' "$(now_epoch)" "$$"
}

append_entry() {  # start end project task desc
  mkdir -p "$TT"
  {
    printf '## %s\n' "$(next_entry_id)"
    printf 'start=%s\n' "$1"
    printf 'end=%s\n' "$2"
    printf 'project=%s\n' "${3:--}"
    printf 'task=%s\n' "${4:--}"
    printf 'desc=%s\n' "$5"
    printf '\n'
  } >> "$TT/entries.md"
}

cmd_approve() {
  local id=${1:-} start_ov="" end_ov="" project_ov="" task_ov="" desc_ov=""
  [ -n "$id" ] || die "approve: usage: fm-time.sh approve <id> [--start ..] [--end ..] [--project ..] [--task ..] [--desc ..]"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --start) start_ov=$2; shift 2 ;;
      --end) end_ov=$2; shift 2 ;;
      --project) project_ov=$2; shift 2 ;;
      --task) task_ov=$2; shift 2 ;;
      --desc) desc_ov=$2; shift 2 ;;
      *) die "approve: unknown argument: $1" ;;
    esac
  done

  tt_lock
  [ -s "$TT/proposals.md" ] || die "approve: no pending proposals"
  local block
  block=$(extract_block "$TT/proposals.md" "$id")
  [ -n "$block" ] || die "approve: no pending proposal named $id"

  local start end project task desc
  start=${start_ov:-$(block_field "$block" start)}
  end=${end_ov:-$(block_field "$block" end)}
  project=${project_ov:-$(block_field "$block" project)}
  task=${task_ov:-$(block_field "$block" task)}
  desc=${desc_ov:-$(block_field "$block" desc)}

  local s e
  s=$(local_to_epoch "$start") || die "approve: unparseable start: $start"
  e=$(local_to_epoch "$end") || die "approve: unparseable end: $end"
  [ "$e" -gt "$s" ] || die "approve: end must be after start ($start -> $end)"

  append_entry "$start" "$end" "$project" "$task" "$desc"
  remove_block "$TT/proposals.md" "$id" > "$TT/proposals.md.tmp"
  mv "$TT/proposals.md.tmp" "$TT/proposals.md"
  advance_cursor_if_batch_done
  tt_unlock
  printf 'approved %s: %s (%s -> %s)\n' "$id" "$desc" "$start" "$end"
}

cmd_reject() {
  [ "$#" -gt 0 ] || die "reject: usage: fm-time.sh reject <id>..."
  tt_lock
  [ -s "$TT/proposals.md" ] || die "reject: no pending proposals"
  local id
  for id in "$@"; do
    local block
    block=$(extract_block "$TT/proposals.md" "$id")
    [ -n "$block" ] || { printf 'reject: no pending proposal named %s (skipped)\n' "$id"; continue; }
    remove_block "$TT/proposals.md" "$id" > "$TT/proposals.md.tmp"
    mv "$TT/proposals.md.tmp" "$TT/proposals.md"
    printf 'rejected %s\n' "$id"
  done
  advance_cursor_if_batch_done
  tt_unlock
}

cmd_split() {
  local id=${1:-} at=""
  [ -n "$id" ] || die "split: usage: fm-time.sh split <id> --at \"<YYYY-MM-DD HH:MM>\""
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --at) at=$2; shift 2 ;;
      *) die "split: unknown argument: $1" ;;
    esac
  done
  [ -n "$at" ] || die "split: --at is required"

  tt_lock
  [ -s "$TT/proposals.md" ] || die "split: no pending proposals"
  local block
  block=$(extract_block "$TT/proposals.md" "$id")
  [ -n "$block" ] || die "split: no pending proposal named $id"

  local start end project task desc split_epoch start_epoch end_epoch
  start=$(block_field "$block" start)
  end=$(block_field "$block" end)
  project=$(block_field "$block" project)
  task=$(block_field "$block" task)
  desc=$(block_field "$block" desc)
  start_epoch=$(local_to_epoch "$start") || die "split: unparseable stored start: $start"
  end_epoch=$(local_to_epoch "$end") || die "split: unparseable stored end: $end"
  split_epoch=$(local_to_epoch "$at") || die "split: unparseable --at value: $at"
  [ "$split_epoch" -gt "$start_epoch" ] && [ "$split_epoch" -lt "$end_epoch" ] \
    || die "split: --at must fall strictly between $start and $end"

  local evidence before after
  evidence=$(printf '%s\n' "$block" | sed -n 's/^evidence=//p')
  before=""
  after=""
  local line ep
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ep=${line%% | *}
    ep=$(local_to_epoch "$ep" 2>/dev/null || printf '%s' "$ep")
    case "$ep" in
      *[!0-9]*) before="$before$line"$'\n' ;;
      *) if [ "$ep" -lt "$split_epoch" ]; then before="$before$line"$'\n'; else after="$after$line"$'\n'; fi ;;
    esac
  done <<< "$evidence"

  remove_block "$TT/proposals.md" "$id" > "$TT/proposals.md.tmp"
  {
    cat "$TT/proposals.md.tmp"
    printf '## %s-a\n' "$id"
    printf 'start=%s\n' "$start"
    printf 'end=%s\n' "$at"
    printf 'project=%s\n' "$project"
    printf 'task=%s\n' "$task"
    printf 'desc=%s\n' "$desc"
    printf '%s' "$before" | sed 's/^/evidence=/'
    printf '\n'
    printf '## %s-b\n' "$id"
    printf 'start=%s\n' "$at"
    printf 'end=%s\n' "$end"
    printf 'project=%s\n' "$project"
    printf 'task=%s\n' "$task"
    printf 'desc=%s\n' "$desc"
    printf '%s' "$after" | sed 's/^/evidence=/'
    printf '\n'
  } > "$TT/proposals.md.new"
  mv "$TT/proposals.md.new" "$TT/proposals.md"
  rm -f "$TT/proposals.md.tmp"
  tt_unlock
  printf 'split %s into %s-a (%s -> %s) and %s-b (%s -> %s)\n' "$id" "$id" "$start" "$at" "$id" "$at" "$end"
}

# ---------------------------------------------------------------- start / stop / log

cmd_start() {
  local project=- task=- desc=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project) project=$2; shift 2 ;;
      --task) task=$2; shift 2 ;;
      --desc) desc=$2; shift 2 ;;
      *) die "start: unknown argument: $1" ;;
    esac
  done
  mkdir -p "$TT"
  tt_lock
  [ -e "$TT/active" ] && die "start: a live session is already running; run: fm-time.sh stop"
  {
    printf 'start=%s\n' "$(epoch_to_local "$(now_epoch)")"
    printf 'project=%s\n' "$project"
    printf 'task=%s\n' "$task"
    printf 'desc=%s\n' "$desc"
  } > "$TT/active"
  tt_unlock
  printf 'started tracking%s\n' "$([ -n "$desc" ] && printf ': %s' "$desc")"
}

cmd_stop() {
  local desc_ov=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --desc) desc_ov=$2; shift 2 ;;
      *) die "stop: unknown argument: $1" ;;
    esac
  done
  tt_lock
  [ -e "$TT/active" ] || die "stop: no live session is running; run: fm-time.sh start"
  local start project task desc end start_epoch end_epoch
  start=$(sed -n 's/^start=//p' "$TT/active" | head -1)
  project=$(sed -n 's/^project=//p' "$TT/active" | head -1)
  task=$(sed -n 's/^task=//p' "$TT/active" | head -1)
  desc=$(sed -n 's/^desc=//p' "$TT/active" | head -1)
  [ -n "$desc_ov" ] && desc=$desc_ov
  end=$(epoch_to_local "$(now_epoch)")
  start_epoch=$(local_to_epoch "$start") || die "stop: unparseable stored start: $start"
  end_epoch=$(local_to_epoch "$end") || die "stop: unparseable end: $end"
  # A start/stop within the same wall-clock minute would otherwise record an
  # entry whose stored start and end are identical once truncated to minute
  # granularity - report then silently discards it as invalid, losing the
  # tracked session. Refuse it up front instead, leaving the active session
  # in place so the captain can just wait a moment and stop again.
  [ "$end_epoch" -gt "$start_epoch" ] || die "stop: wait until the current minute has elapsed before stopping"
  append_entry "$start" "$end" "$project" "$task" "$desc"
  rm -f "$TT/active"
  tt_unlock
  printf 'stopped: %s (%s -> %s)\n' "${desc:-(no description)}" "$start" "$end"
}

cmd_log() {
  local start="" end="" project=- task=- desc=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --start) start=$2; shift 2 ;;
      --end) end=$2; shift 2 ;;
      --project) project=$2; shift 2 ;;
      --task) task=$2; shift 2 ;;
      --desc) desc=$2; shift 2 ;;
      *) die "log: unknown argument: $1" ;;
    esac
  done
  [ -n "$start" ] && [ -n "$end" ] || die "log: --start and --end are required"
  [ -n "$desc" ] || die "log: --desc is required"
  local s e
  s=$(local_to_epoch "$start") || die "log: unparseable --start: $start"
  e=$(local_to_epoch "$end") || die "log: unparseable --end: $end"
  [ "$e" -gt "$s" ] || die "log: --end must be after --start"
  tt_lock
  append_entry "$start" "$end" "$project" "$task" "$desc"
  tt_unlock
  printf 'logged: %s (%s -> %s)\n' "$desc" "$start" "$end"
}

# ---------------------------------------------------------------- report

cmd_report() {
  local month="" project_filter=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --month) month=$2; shift 2 ;;
      --project) project_filter=$2; shift 2 ;;
      *) die "report: unknown argument: $1" ;;
    esac
  done
  [ -n "$month" ] || month=$(epoch_to_yyyymm "$(now_epoch)")
  [ -e "$TT/entries.md" ] || { printf 'no time entries recorded yet.\n'; return 0; }

  local tmp
  tmp=$(mktemp "$TT/.report.XXXXXX")
  trap 'rm -f "$tmp"' RETURN

  awk -v RS='' -v FS='\n' '
    /^## / {
      start=""; end=""; project=""; task=""; desc=""
      for (i = 1; i <= NF; i++) {
        line = $i
        if (line ~ /^start=/) start = substr(line, 7)
        else if (line ~ /^end=/) end = substr(line, 5)
        else if (line ~ /^project=/) project = substr(line, 9)
        else if (line ~ /^task=/) task = substr(line, 6)
        else if (line ~ /^desc=/) desc = substr(line, 6)
      }
      if (start != "") print start "\t" end "\t" project "\t" task "\t" desc
    }
  ' "$TT/entries.md" > "$tmp"

  local total=0 after_total=0 count=0 invalid=0
  local -A proj_total proj_after
  local -A key_total key_after key_desc
  local line s e p t d s_epoch e_epoch dur ah ym

  while IFS=$'\t' read -r s e p t d; do
    ym=${s%% *}
    ym=${ym%-*}
    [ "$ym" = "$month" ] || continue
    [ -z "$project_filter" ] || [ "$p" = "$project_filter" ] || continue
    s_epoch=$(local_to_epoch "$s") || { invalid=$((invalid + 1)); continue; }
    e_epoch=$(local_to_epoch "$e") || { invalid=$((invalid + 1)); continue; }
    if [ "$e_epoch" -le "$s_epoch" ]; then invalid=$((invalid + 1)); continue; fi
    dur=$(( (e_epoch - s_epoch) / 60 ))
    ah=$(is_after_hours "$s_epoch")
    total=$((total + dur))
    count=$((count + 1))
    [ "$ah" = yes ] && after_total=$((after_total + dur))
    proj_total[$p]=$(( ${proj_total[$p]:-0} + dur ))
    [ "$ah" = yes ] && proj_after[$p]=$(( ${proj_after[$p]:-0} + dur ))
    key_total["$p"$'\t'"$t"]=$(( ${key_total["$p"$'\t'"$t"]:-0} + dur ))
    [ "$ah" = yes ] && key_after["$p"$'\t'"$t"]=$(( ${key_after["$p"$'\t'"$t"]:-0} + dur ))
    if [ -n "$d" ]; then
      case "${key_desc["$p"$'\t'"$t"]:-}" in
        *"$d"*) ;;
        '') key_desc["$p"$'\t'"$t"]="$d" ;;
        *) key_desc["$p"$'\t'"$t"]="${key_desc["$p"$'\t'"$t"]}; $d" ;;
      esac
    fi
  done < "$tmp"
  rm -f "$tmp"
  trap - RETURN

  printf 'Time tracking report - %s\n' "$month"
  if [ "$count" -eq 0 ]; then
    printf 'no entries recorded for this month%s.\n' "$([ -n "$project_filter" ] && printf ' for project %s' "$project_filter")"
    [ "$invalid" -gt 0 ] && printf '(%d entr%s skipped: end not after start; check hand edits)\n' \
      "$invalid" "$([ "$invalid" -eq 1 ] && printf y || printf ies)"
    return 0
  fi
  printf 'total: %s tracked across %d entr%s\n' "$(fmt_minutes "$total")" "$count" "$([ "$count" -eq 1 ] && printf y || printf ies)"
  printf '  after hours (weekend or outside %s-%s local): %s\n' "$WORKDAY_START" "$WORKDAY_END" "$(fmt_minutes "$after_total")"
  printf '  business hours: %s\n' "$(fmt_minutes "$((total - after_total))")"
  [ "$invalid" -gt 0 ] && printf '(%d entr%s skipped: end not after start; check hand edits)\n' \
    "$invalid" "$([ "$invalid" -eq 1 ] && printf y || printf ies)"
  printf '\nby project / task:\n'

  local p_key kt task_name
  local -a sorted_projects sorted_tasks
  mapfile -t sorted_projects < <(printf '%s\n' "${!proj_total[@]}" | sort)
  for p_key in "${sorted_projects[@]}"; do
    printf '  %s  %s' "$([ "$p_key" = - ] && printf '(unattributed)' || printf '%s' "$p_key")" "$(fmt_minutes "${proj_total[$p_key]}")"
    [ "${proj_after[$p_key]:-0}" -gt 0 ] && printf ' (%s after hours)' "$(fmt_minutes "${proj_after[$p_key]}")"
    printf '\n'
    mapfile -t sorted_tasks < <(
      for kt in "${!key_total[@]}"; do
        case "$kt" in "$p_key"$'\t'*) printf '%s\n' "$kt" ;; esac
      done | sort
    )
    for kt in "${sorted_tasks[@]}"; do
      task_name=${kt#*$'\t'}
      printf '    %s  %s' "$([ "$task_name" = - ] && printf '(unattributed)' || printf '%s' "$task_name")" "$(fmt_minutes "${key_total[$kt]}")"
      [ "${key_after[$kt]:-0}" -gt 0 ] && printf ' (%s after hours)' "$(fmt_minutes "${key_after[$kt]}")"
      printf '\n'
      [ -n "${key_desc[$kt]:-}" ] && printf '      %s\n' "${key_desc[$kt]}"
    done
  done
}

# ---------------------------------------------------------------- dispatch

case "${1:-}" in
  propose) shift; cmd_propose "$@" ;;
  list)    shift; cmd_list "$@" ;;
  approve) shift; cmd_approve "$@" ;;
  reject)  shift; cmd_reject "$@" ;;
  split)   shift; cmd_split "$@" ;;
  start)   shift; cmd_start "$@" ;;
  stop)    shift; cmd_stop "$@" ;;
  log)     shift; cmd_log "$@" ;;
  report)  shift; cmd_report "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown subcommand: $1 (try --help)" ;;
esac
