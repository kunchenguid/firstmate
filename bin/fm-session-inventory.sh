#!/usr/bin/env bash
# fm-session-inventory.sh - structured "what is running right now" inventory.
#
# Output contract: `--json` prints one object with schema
# `fm-session-inventory.v1`. The command is READ-ONLY over this home: it never
# acquires the session lock, drains wakes, arms or signals a watcher, touches
# the backlog, or writes any state record. It never stops, kills, or signals
# anything it reports; every close instruction is data in a `close` field for a
# human to run, never something this command executes.
#
# WHY IT EXISTS. Four unrelated things can be running at once and no single
# surface showed them together: this home's workers, the review pages Lavish is
# serving, the background services that keep the fleet moving, and - the case
# that caused real damage - two concurrent harness background sessions under one
# shared harness daemon, each believing it owned this home.
#
# ONE TRUTH, NOT A SECOND ONE. Worker rows are derived from
# bin/fm-fleet-snapshot.sh --json, which stays the single owner of fleet state;
# this script adds only what that snapshot does not model (Lavish review pages,
# background services, harness sessions) and never re-parses backlog or task
# metadata itself. bin/fm-session-view.sh is the human renderer over this
# output, exactly as bin/fm-fleet-view.sh renders the fleet snapshot.
#
# Top-level fields:
#   schema            stable schema id.
#   generated         UTC observation time; generated_epoch is the same instant.
#   fm_home, fm_root  resolved operational home and tracked code root.
#   stale_after_days  the age at or above which a row is marked stale.
#   rows[]            uniform rows, ordered kind-then-age, described below.
#   counts            {total, stale, notify, by_kind{worker,review,service,harness_session}}.
#   harness_sessions  {root_pid, lock_pid, lock_owner, sessions, spares, unknown}.
#                     lock_owner is the honest answer to "which background
#                     session drives this home": "unique" when exactly one
#                     session owns the recorded lock, "single" when only one
#                     session exists, "ambiguous" when the lock names a shared
#                     harness daemon that parents several sessions and no single
#                     one can be attributed, "stale" when the recorded pid is not
#                     a live harness process, "absent" when no lock is recorded,
#                     and "not_checked" when the ancestry could not be resolved.
#   sources[]         {name, ok, reason} - one per collector, so an unreadable
#                     source is disclosed instead of silently reported as zero.
#
# Row fields:
#   kind          worker | review | service | harness-session.
#   id            stable identifier within the kind.
#   label         short human name.
#   belongs_to    what it belongs to (project, task, home, daemon).
#   detail        one extra descriptive string, or null.
#   pid           process id when the row is a live process, else null.
#   started       UTC start time when known, else null.
#   age_seconds   age in seconds when known, else null. age_days is whole days.
#   age_source    where the age came from: "process", "backlog-since",
#                 "file-mtime", or null.
#   stale         true when age_days >= stale_after_days.
#   notify        true when the row is stale AND has a close command. A row with
#                 no single safe close command is not something a human can act
#                 on by age, so long-lived shared infrastructure stays visible in
#                 the view without occupying the unasked session-start line.
#   close         exact command a human may run to close it, or null.
#   close_safety  safe | confirm | manual. "confirm" means closing it can lose
#                 work in progress and needs an explicit decision first;
#                 "manual" means there is no single safe command here.
#   close_note    why, when close_safety is not "safe".
#
# HARNESS-SESSION IDENTITY is deliberately built on the two most structural
# signals available. Whether a process is a verified harness is decided by
# bin/fm-session-lock-lib.sh, the fleet's single owner of that question; the
# parent/child relation is a kernel fact read from ps. Only the session-vs-spare
# ROLE reads vendor-supplied argv, and it reads two independent tokens rather
# than one: a session-identity token and a spare-pool token. When they conflict,
# or neither appears, the row is reported with role "unknown" and still shown,
# so a renamed vendor flag surfaces loudly instead of silently reclassifying a
# live session as an idle pool process.
#
# Bounds. FM_SESSION_INVENTORY_FLEET_TIMEOUT (default 20s) bounds the fleet
# snapshot and FM_SESSION_INVENTORY_LAVISH_TIMEOUT (default 8s) bounds the Lavish
# listing; a bound that is hit is reported as an unreadable source, never as an
# empty result. FM_SESSION_STALE_DAYS (default 3) sets the stale threshold.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-session-lock-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-session-lock-lib.sh"  # fm_harness_process_matches: the one harness-identity owner
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"  # fm_run_timed: the shared hard bound

STALE_DAYS=${FM_SESSION_STALE_DAYS:-3}
case "$STALE_DAYS" in
  ''|*[!0-9]*) echo "fm-session-inventory: FM_SESSION_STALE_DAYS must be a non-negative integer" >&2; exit 2 ;;
esac
FLEET_TIMEOUT=${FM_SESSION_INVENTORY_FLEET_TIMEOUT:-20}
LAVISH_TIMEOUT=${FM_SESSION_INVENTORY_LAVISH_TIMEOUT:-8}
for bound_name in FLEET_TIMEOUT LAVISH_TIMEOUT; do
  case "${!bound_name}" in
    ''|*[!0-9]*|0)
      echo "fm-session-inventory: FM_SESSION_INVENTORY_${bound_name} must be a positive integer" >&2
      exit 2
      ;;
  esac
done

NOW_EPOCH=${FM_SESSION_INVENTORY_NOW_EPOCH:-$(date -u +%s)}
case "$NOW_EPOCH" in ''|*[!0-9]*) NOW_EPOCH=$(date -u +%s) ;; esac

usage() {
  cat <<'EOF'
usage: fm-session-inventory.sh --json
       fm-session-inventory.sh --stale-lines

Print what is running for this firstmate home: workers, open Lavish review
pages, background services, and concurrent harness background sessions.

--json         the stable machine-readable contract (schema fm-session-inventory.v1).
--stale-lines  one short line per row at or over the stale threshold, and
               nothing at all when none is. This is what the session-start
               bootstrap surfaces unasked.

Read-only: it never closes, kills, or signals anything it reports.
EOF
}

MODE=
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --json) MODE=json ;;
  --stale-lines) MODE=stale ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "fm-session-inventory: jq not found" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-session-inventory.XXXXXX") || exit 1
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT
ROWS="$WORK/rows.tsv"
SOURCES="$WORK/sources.tsv"
: > "$ROWS"
: > "$SOURCES"

note_source() {  # <name> <ok:0|1> <reason>
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SOURCES"
}

# One row per line. Empty field = null in JSON.
emit_row() {  # kind id label belongs_to detail pid age_seconds age_source close close_safety close_note
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" >> "$ROWS"
}

# --- the one process-table read ----------------------------------------------
# pid \t ppid \t age_seconds \t args. `etime` is used rather than `lstart`
# because both BSD and procps render it and it needs no timezone parsing;
# macOS has no `etimes` at all.
PSTABLE="$WORK/ps.tsv"
if ps -eo pid=,ppid=,etime=,args= 2>/dev/null | LC_ALL=C awk '
    function etime_secs(s,   n,a,d,hh,mm,ss,p) {
      d = 0
      if (index(s, "-") > 0) { split(s, p, "-"); d = p[1] + 0; s = p[2] }
      n = split(s, a, ":")
      if (n == 3) { hh = a[1] + 0; mm = a[2] + 0; ss = a[3] + 0 }
      else if (n == 2) { hh = 0; mm = a[1] + 0; ss = a[2] + 0 }
      else return -1
      return ((d * 24 + hh) * 60 + mm) * 60 + ss
    }
    {
      pid = $1; ppid = $2; secs = etime_secs($3)
      args = $0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]*/, "", args)
      gsub(/[\t\r\n]/, " ", args)
      if (pid ~ /^[0-9]+$/ && ppid ~ /^[0-9]+$/ && secs >= 0)
        printf "%s\t%s\t%s\t%s\n", pid, ppid, secs, args
    }' > "$PSTABLE" && [ -s "$PSTABLE" ]; then
  note_source process-table 1 ''
else
  : > "$PSTABLE"
  note_source process-table 0 'ps produced no readable process table'
fi

ps_field() {  # <pid> <1=ppid|2=age|3=args>
  LC_ALL=C awk -F'\t' -v want="$1" -v col="$2" '$1 == want { print $(col + 1); exit }' "$PSTABLE"
}
ps_alive() { [ -n "$(ps_field "$1" 1)" ]; }
ps_children() { LC_ALL=C awk -F'\t' -v parent="$1" '$2 == parent { print $1 }' "$PSTABLE"; }

file_age_seconds() {  # <path>
  local mtime
  if [ "$(uname)" = Darwin ]; then
    mtime=$(stat -f %m -- "$1" 2>/dev/null) || return 1
  else
    mtime=$(stat -c %Y -- "$1" 2>/dev/null) || return 1
  fi
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$((NOW_EPOCH - mtime))"
}

# --- 1. workers, from the fleet snapshot (the single owner of fleet state) ----
collect_workers() {
  local snapshot_file="$WORK/fleet.json" rc=0
  fm_run_timed "$FLEET_TIMEOUT" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json \
    > "$snapshot_file" 2>"$WORK/fleet.err" || rc=$?
  if [ "$rc" = 124 ]; then
    note_source fleet-snapshot 0 "fleet snapshot exceeded ${FLEET_TIMEOUT}s"
    return 0
  fi
  if [ "$rc" != 0 ] || ! jq -e . "$snapshot_file" >/dev/null 2>&1; then
    note_source fleet-snapshot 0 "fleet snapshot failed (exit $rc)"
    return 0
  fi
  note_source fleet-snapshot 1 ''
  local id kind repo window worktree since meta_path state busy close safety cnote age age_source
  while IFS=$'\t' read -r id kind repo window worktree since meta_path state; do
    [ -n "$id" ] || continue
    age=''
    age_source=''
    if [ -n "$since" ]; then
      # tasks-axi records a date; midnight UTC is the honest floor for its age.
      age=$(date -u -j -f '%Y-%m-%d %H:%M:%S' "$since 00:00:00" +%s 2>/dev/null \
        || date -u -d "$since 00:00:00" +%s 2>/dev/null || true)
      if [ -n "$age" ]; then
        age=$((NOW_EPOCH - age))
        [ "$age" -ge 0 ] || age=0
        age_source=backlog-since
      fi
    fi
    if [ -z "$age" ] && [ -n "$meta_path" ] && age=$(file_age_seconds "$meta_path"); then
      age_source="file-mtime"
    fi
    busy=$state
    if [ "$kind" = secondmate ]; then
      close=''
      safety=manual
      cnote='persistent second mate; retire only through an explicit decision'
    else
      close="$(close_prefix)bin/fm-teardown.sh $id"
      case "$busy" in
        busy|working|running|fixing)
          safety=confirm
          cnote='work in progress; cleanup refuses while anything is unlanded'
          ;;
        *)
          safety=safe
          cnote='refuses rather than discarding unlanded work'
          ;;
      esac
    fi
    emit_row worker "$id" "$kind" "${repo:-$id}" "${window:+window $window}${worktree:+ in $worktree}" \
      '' "${age:-}" "$age_source" "$close" "$safety" "$cnote"
  done < <(jq -r '
      .tasks[]? |
      [ .id,
        (.kind // "task"),
        (.backlog.repo // .project // ""),
        (.endpoint.target // ""),
        (.paths.worktree.path // .paths.home.path // ""),
        (.backlog.since // ""),
        (.paths.meta.path // ""),
        (.current_state.state // "")
      ] | @tsv' "$snapshot_file")
}

# Commands are written to be pasted from the firstmate root. A home that is not
# the code root needs its FM_HOME stated, or the command would act on the wrong
# home.
close_prefix() {
  [ "$FM_HOME" = "$FM_ROOT" ] || printf 'FM_HOME=%s ' "$FM_HOME"
}

# --- 2. open Lavish review pages ---------------------------------------------
# The bare `lavish-axi` listing is the authoritative set of OPEN review pages.
# Age comes from the poll process actually serving that page when one is
# running, and from the artifact's own mtime otherwise.
collect_reviews() {
  local out="$WORK/lavish.txt" rc=0 file status url pending sid age age_source pid safety cnote
  if ! command -v lavish-axi >/dev/null 2>&1; then
    note_source lavish 0 'lavish-axi is not installed'
    return 0
  fi
  fm_run_timed "$LAVISH_TIMEOUT" lavish-axi > "$out" 2>/dev/null || rc=$?
  if [ "$rc" = 124 ]; then
    note_source lavish 0 "lavish-axi listing exceeded ${LAVISH_TIMEOUT}s"
    return 0
  fi
  if ! LC_ALL=C grep -q '^sessions\[' "$out" 2>/dev/null; then
    note_source lavish 0 'lavish-axi printed no sessions listing'
    return 0
  fi
  note_source lavish 1 ''
  while IFS=$'\t' read -r file status url pending; do
    [ -n "$file" ] || continue
    sid=${url##*/session/}
    [ -n "$sid" ] && [ "$sid" != "$url" ] || sid=$(basename -- "$file")
    age=''
    age_source=''
    pid=$(LC_ALL=C awk -F'\t' -v needle="$file" '
      index($4, "lavish-axi") && index($4, "poll") && index($4, needle) { print $1; exit }' "$PSTABLE")
    if [ -n "$pid" ]; then
      age=$(ps_field "$pid" 2)
      age_source=process
    elif age=$(file_age_seconds "$file"); then
      age_source="file-mtime"
    fi
    if [ "${pending:-0}" != 0 ]; then
      safety=confirm
      cnote="$pending queued note(s) from the captain would be lost"
    else
      safety=safe
      cnote=''
    fi
    emit_row review "$sid" "$(basename -- "$file")" "$(dirname -- "$file")" \
      "${status:-open}${url:+ $url}" "$pid" "${age:-}" "$age_source" \
      "lavish-axi end $file" "$safety" "$cnote"
  done < <(LC_ALL=C awk '
      /^sessions\[/ { inblock = 1; next }
      inblock && /^[^[:space:]]/ { inblock = 0 }
      inblock {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        if (line == "") next
        # file,status,"url",pending - the file path never contains a comma in a
        # Lavish artifact path, and the url is the only quoted field.
        n = split(line, f, ",")
        if (n < 4) next
        url = f[3]; gsub(/^"|"$/, "", url)
        printf "%s\t%s\t%s\t%s\n", f[1], f[2], url, f[n]
      }' "$out")
}

# --- 3. background services keeping this home running ------------------------
# Home-scoped by construction: every service is found through THIS home's own
# state records or through an argv that names a shared machine-wide service.
# Nothing here matches a sibling firstmate home's watcher.
service_row() {  # <id> <label> <belongs_to> <pid> <close> <safety> <note>
  local age='' age_source=''
  if [ -n "$4" ] && ps_alive "$4"; then
    age=$(ps_field "$4" 2)
    age_source=process
  fi
  emit_row service "$1" "$2" "$3" '' "$4" "$age" "$age_source" "$5" "$6" "$7"
}

collect_services() {
  local pid src id
  note_source services 1 ''

  pid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) pid='' ;; esac
  if [ -n "$pid" ] && ps_alive "$pid"; then
    service_row watcher 'fleet monitoring' "$FM_HOME" "$pid" \
      '' manual 'closing it stops supervision of every running worker'
  fi

  pid=$(cat "$STATE/.supervise-daemon.lock/pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) pid='' ;; esac
  if [ -n "$pid" ] && ps_alive "$pid"; then
    service_row away-supervisor 'away-mode supervision' "$FM_HOME" "$pid" \
      '' manual 'ends when away mode ends; do not close it by hand'
  fi

  # Registered process-event listeners this home owns. Lavish sources are
  # already reported as review rows, so they are not repeated here.
  for src in "$STATE"/procevent/*.runner; do
    [ -e "$src" ] || continue
    id=${src##*/}; id=${id%.runner}
    case "$id" in lavish-*) continue ;; esac
    pid=$(cat "$src" 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    ps_alive "$pid" || continue
    service_row "listener-$id" "waiting on $id" "$FM_HOME" "$pid" \
      "$(close_prefix)bin/fm-procevent.sh retire $id" safe \
      'retiring it stops the wait; it never touches worker code'
  done

  pid=$(LC_ALL=C awk -F'\t' '
    index($4, "lavish-axi") && index($4, " server") { print $1; exit }' "$PSTABLE")
  if [ -n "$pid" ]; then
    service_row lavish-server 'review page server' 'shared on this machine' "$pid" \
      '' manual 'stops by itself once the last review page is closed'
  fi

  pid=$(LC_ALL=C awk -F'\t' '
    index($4, "no-mistakes") && index($4, "daemon run") { print $1; exit }' "$PSTABLE")
  if [ -n "$pid" ]; then
    service_row no-mistakes-daemon 'validation service' 'shared on this machine' "$pid" \
      '' manual 'one shared instance; closing it kills every running validation'
  fi
}

# --- 4. concurrent harness background sessions -------------------------------
# Role signals. Two independent tokens per verdict so no single vendor string is
# load-bearing, and a conflict or a miss reports "unknown" rather than guessing.
session_role() {  # <args>
  local args=$1 session=0 spare=0
  case "$args" in *--session-id*) session=$((session + 1)) ;; esac
  case "$args" in *' --agent '*) session=$((session + 1)) ;; esac
  case "$args" in *--bg-spare*) spare=$((spare + 1)) ;; esac
  case "$args" in */spare/*) spare=$((spare + 1)) ;; esac
  if [ "$session" -gt 0 ] && [ "$spare" -eq 0 ]; then
    printf 'session\n'
  elif [ "$spare" -gt 0 ] && [ "$session" -eq 0 ]; then
    printf 'spare\n'
  else
    printf 'unknown\n'
  fi
}

is_harness_pid() {  # <pid>
  local pid=$1 comm args
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  [ -n "$comm" ] || return 1
  args=$(ps_field "$pid" 3)
  fm_harness_process_matches "$comm" "$args"
}

# The outermost contiguous harness ancestor of <pid>, which is the shared daemon
# when one parents this session and the session itself when none does.
harness_root_of() {  # <pid>
  local pid=$1 parent hop=0
  local outermost=$pid
  while [ "$hop" -lt 16 ]; do
    parent=$(ps_field "$pid" 1)
    case "$parent" in ''|0|1) break ;; esac
    is_harness_pid "$parent" || break
    outermost=$parent
    pid=$parent
    hop=$((hop + 1))
  done
  printf '%s\n' "$outermost"
}

pid_is_descendant_of() {  # <pid> <ancestor>
  local pid=$1 ancestor=$2 hop=0
  while [ "$hop" -lt 32 ]; do
    pid=$(ps_field "$pid" 1)
    case "$pid" in ''|0|1) return 1 ;; esac
    [ "$pid" = "$ancestor" ] && return 0
    hop=$((hop + 1))
  done
  return 1
}

HARNESS_ROOT=
HARNESS_LOCK_PID=
HARNESS_LOCK_OWNER=not_checked

collect_harness_sessions() {
  local lock_pid root child args role drives close safety cnote age
  local candidates=0 owner_rows=0 i
  local -a sessions=() roles=() drive_of=()
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$lock_pid" in ''|*[!0-9]*) lock_pid='' ;; esac
  HARNESS_LOCK_PID=$lock_pid
  if [ ! -s "$PSTABLE" ]; then
    HARNESS_LOCK_OWNER=not_checked
    note_source harness-sessions 0 'no readable process table'
    return 0
  fi
  if [ -z "$lock_pid" ]; then
    HARNESS_LOCK_OWNER=absent
    note_source harness-sessions 0 'this home records no session lock, so its harness cannot be scoped'
    return 0
  fi
  if ! ps_alive "$lock_pid" || ! is_harness_pid "$lock_pid"; then
    HARNESS_LOCK_OWNER=stale
    note_source harness-sessions 0 "recorded session lock pid $lock_pid is not a live harness process"
    return 0
  fi
  root=$(harness_root_of "$lock_pid")
  HARNESS_ROOT=$root
  note_source harness-sessions 1 ''

  while IFS= read -r child; do
    [ -n "$child" ] || continue
    is_harness_pid "$child" || continue
    sessions+=("$child")
  done < <(ps_children "$root")
  # A root with no harness children is itself the only session.
  [ "${#sessions[@]}" -gt 0 ] || sessions=("$root")

  # First pass: role, and whether this row can be attributed the recorded lock.
  # A pooled spare is running no session at all, so it drives no home whatever
  # the ancestry says; only a session or an unclassified row is a candidate.
  for child in "${sessions[@]}"; do
    args=$(ps_field "$child" 3)
    role=$(session_role "$args")
    roles+=("$role")
    if [ "$role" = spare ]; then
      drive_of+=(no)
      continue
    fi
    candidates=$((candidates + 1))
    if [ "$child" = "$lock_pid" ] || pid_is_descendant_of "$lock_pid" "$child"; then
      drive_of+=(yes)
      owner_rows=$((owner_rows + 1))
    elif [ "$lock_pid" = "$root" ] || pid_is_descendant_of "$child" "$lock_pid"; then
      # The measured failure mode: the lock names the shared harness daemon, so
      # every session under it reads as the owner and none can be told apart.
      drive_of+=(ambiguous)
    else
      drive_of+=(no)
    fi
  done

  if [ "$owner_rows" = 1 ]; then
    HARNESS_LOCK_OWNER=unique
  elif [ "$candidates" = 0 ]; then
    HARNESS_LOCK_OWNER=none
  elif [ "$candidates" = 1 ]; then
    HARNESS_LOCK_OWNER=single
  else
    HARNESS_LOCK_OWNER=ambiguous
  fi
  # One live candidate under the lock-owning daemon is the session this home is
  # driven from, even when the lock itself names the daemon. Several candidates
  # and no attributable owner is the ambiguity worth showing on every row.
  i=0
  while [ "$i" -lt "${#drive_of[@]}" ]; do
    if [ "${drive_of[$i]}" != no ]; then
      case "$HARNESS_LOCK_OWNER" in
        single) drive_of[i]=yes ;;
        ambiguous) drive_of[i]=ambiguous ;;
      esac
    fi
    i=$((i + 1))
  done

  i=0
  for child in "${sessions[@]}"; do
    role=${roles[$i]}
    drives=${drive_of[$i]}
    i=$((i + 1))
    age=$(ps_field "$child" 2)
    case "$role" in
      spare)
        close="kill $child"
        safety=safe
        cnote='idle pool process; the harness starts a fresh one when it needs it'
        ;;
      *)
        close="kill $child"
        safety=confirm
        cnote='a live session: closing it can lose an unfinished turn'
        ;;
    esac
    emit_row harness-session "$child" "$role" "harness daemon $root" \
      "drives this home: $drives" "$child" "$age" process "$close" "$safety" "$cnote"
  done
}

collect_workers
collect_reviews
collect_services
collect_harness_sessions

JSON=$(
  jq -R -s \
    --arg schema fm-session-inventory.v1 \
    --arg home "$FM_HOME" \
    --arg root "$FM_ROOT" \
    --argjson now "$NOW_EPOCH" \
    --argjson stale_days "$STALE_DAYS" \
    --arg harness_root "$HARNESS_ROOT" \
    --arg lock_pid "$HARNESS_LOCK_PID" \
    --arg lock_owner "$HARNESS_LOCK_OWNER" \
    --rawfile sources_raw "$SOURCES" \
    '
    def blank_null: if . == "" then null else . end;
    def as_num: blank_null | if . == null then null else tonumber end;
    def rows_of:
      split("\n") | map(select(length > 0)) | map(split("\t")) | map(
        {kind: .[0],
         id: .[1],
         label: (.[2] | blank_null),
         belongs_to: (.[3] | blank_null),
         detail: (.[4] | blank_null),
         pid: (.[5] | as_num),
         age_seconds: (.[6] | as_num),
         age_source: (.[7] | blank_null),
         close: (.[8] | blank_null),
         close_safety: (.[9] // "manual"),
         close_note: (.[10] | blank_null)}
        | .age_days = (if .age_seconds == null then null else (.age_seconds / 86400 | floor) end)
        | .stale = (.age_days != null and .age_days >= $stale_days)
        | .notify = (.stale and .close != null)
        | .started = (if .age_seconds == null then null
                      else (($now - .age_seconds) | strftime("%Y-%m-%dT%H:%M:%SZ")) end)
      );
    def kind_order: {"worker": 0, "harness-session": 1, "review": 2, "service": 3};
    (rows_of) as $rows
    | ($sources_raw | split("\n") | map(select(length > 0)) | map(split("\t"))
       | map({name: .[0], ok: (.[1] == "1"), reason: (.[2] | blank_null)})) as $sources
    | ($rows | sort_by([(kind_order[.kind] // 9), -(.age_seconds // -1), .id])) as $ordered
    | {schema: $schema,
       generated: ($now | strftime("%Y-%m-%dT%H:%M:%SZ")),
       generated_epoch: $now,
       fm_home: $home,
       fm_root: $root,
       stale_after_days: $stale_days,
       rows: $ordered,
       counts: {
         total: ($ordered | length),
         stale: ([$ordered[] | select(.stale)] | length),
         notify: ([$ordered[] | select(.notify)] | length),
         by_kind: {
           worker: ([$ordered[] | select(.kind == "worker")] | length),
           review: ([$ordered[] | select(.kind == "review")] | length),
           service: ([$ordered[] | select(.kind == "service")] | length),
           harness_session: ([$ordered[] | select(.kind == "harness-session")] | length)
         }
       },
       harness_sessions: {
         root_pid: ($harness_root | as_num),
         lock_pid: ($lock_pid | as_num),
         lock_owner: $lock_owner,
         sessions: ([$ordered[] | select(.kind == "harness-session" and .label == "session")] | length),
         spares: ([$ordered[] | select(.kind == "harness-session" and .label == "spare")] | length),
         unknown: ([$ordered[] | select(.kind == "harness-session" and .label == "unknown")] | length)
       },
       sources: $sources}
    ' < "$ROWS"
) || { echo "fm-session-inventory: could not assemble the inventory" >&2; exit 1; }

if [ "$MODE" = json ]; then
  printf '%s\n' "$JSON"
  exit 0
fi

# --stale-lines: nothing at all when nothing is old. One short line each,
# bounded, because a session start pays for every line it prints.
printf '%s\n' "$JSON" | jq -r --argjson cap 8 '
  def row_label($r): if $r.kind == "harness-session" then "background session (\($r.label))"
                 elif $r.kind == "worker" then "worker \($r.id)"
                 elif $r.kind == "review" then "review page \($r.label)"
                 else "service \($r.label // $r.id)" end;
  [.rows[] | select(.notify)] as $stale
  | if ($stale | length) == 0 then empty
    else
      ($stale[:$cap][] |
        "SESSIONS_STALE: \(row_label(.)) - \(.age_days)d, \(.belongs_to // "-") - close: \(.close)" +
        (if .close_safety == "safe" then "" else " (\(.close_safety): \(.close_note // "check before closing"))" end)),
      (if ($stale | length) > $cap then
         "SESSIONS_STALE: and \(($stale | length) - $cap) more - see bin/fm-session-view.sh"
       else empty end)
    end'
