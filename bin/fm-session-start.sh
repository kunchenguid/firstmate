#!/usr/bin/env bash
# fm-session-start.sh - one command for the whole session start.
#
# Collapses AGENTS.md sections 3 (bootstrap) and 5 (recovery) into ONE script
# producing ONE ordered digest, so a session starts in one or two turns
# instead of the six-plus separate reads the old docs required: run
# fm-bootstrap.sh, then separately read data/projects.md, data/secondmates.md,
# data/captain.md, data/captain-shared.md, data/learnings.md, then run
# fm-lock.sh, fm-wake-drain.sh, then read data/backlog.md, every state/*.meta,
# and every state/*.status.
# Every one of those reads is UNCONDITIONAL at every session start, so they
# belong in a script, not in N agent turns.
#
# COMPOSITION, NOT DUPLICATION: this script calls fm-lock.sh, fm-bootstrap.sh,
# and fm-wake-drain.sh as real subprocesses and prints their real output. It
# never re-implements their logic; all sequencing/formatting logic added here
# stays local to this file. Those three scripts remain fully working
# standalone with unchanged default behavior - other flows (fm-bootstrap.sh
# install <tools> after consent, /updatefirstmate, the afk daemon, existing
# tests) still call them directly. The one seam this script needed -
# bootstrap running its detect-only diagnostics without its five mutating
# sweeps - is an opt-in FM_BOOTSTRAP_DETECT_ONLY=1 flag on fm-bootstrap.sh
# itself (default unset/0 = unchanged behavior), not a fork.
#
# ORDERING, and why LOCK now runs before BOOTSTRAP (the old AGENTS.md order
# was bootstrap-then-lock):
#
#   1. lock          - acquire the per-home session lock FIRST, before any
#                       mutating step runs.
#   2. bootstrap      - home-local stale Herdr projection cleanup runs only
#                       when this session actually holds the lock. Detect-only
#                       diagnostics always run. Bootstrap's five MUTATING sweeps
#                       (legacy PR-check migration, secondmate fast-forward,
#                       secondmate liveness, X-mode artifact writes, fleet sync)
#                       also run only when locked.
#   3. wake-drain     - mutates the durable wake queue, so it also only runs
#                       when locked.
#   4. context digest - data/projects.md, data/secondmates.md, data/captain.md,
#                       data/captain-shared.md, data/learnings.md: read-only,
#                       always safe, always runs.
#   5. fleet digest   - a compact data/backlog.md identity/metadata listing,
#                       every state/*.meta, a bounded state/*.status tail,
#                       state/.afk, and a cheap per-task endpoint-liveness read:
#                       read-only, always runs.
#   6. closing reminder - prints the context-specific watcher next step; this
#                       script points back to the emitted harness supervision
#                       block and deliberately never arms the watcher itself.
#
# On a Pi primary, the supervision-block step also checks whether Pi's two
# tracked primary extensions are loaded and prints a PI_WATCH_EXTENSION
# reminder line when one is missing.
#
# Why lock first: the old documented order (bootstrap, THEN lock) let a
# SECOND concurrent session run bootstrap's mutating sweeps - fast-forwarding
# secondmate homes, writing X-mode artifacts, fetching/fast-forwarding every
# project clone - before ever discovering another session already holds the
# lock. Two sessions racing those sweeps is exactly the hazard the lock
# exists to prevent, so locking first closes the hole outright: only the
# session that actually wins the lock ever touches shared mutable state.
#
# The tradeoff this ordering accepts: a refused (read-only) session must not
# go dark. So on refusal, bootstrap still runs (in FM_BOOTSTRAP_DETECT_ONLY=1
# mode) for its read-only detect lines - missing tools, gh auth, the
# worktree-tangle check, the harness override, crew-dispatch validation,
# tasks-axi and quota-axi tool checks, and tasks-axi availability - none of
# which mutate shared state and all of which are safe to compute without
# verified lock ownership.
# Only projection cleanup, the five bootstrap mutating sweeps, and the
# wake-queue drain are skipped.
# The context and fleet-state digests
# below are always read-only, so they run unconditionally in both modes.
#
# BACKLOG DIGEST: FM_SESSION_START_BACKLOG_LIMIT bounds the startup backlog
# listing, default 80 items.
# When compatible tasks-axi is selected and available, the shared tasks-axi
# backend probe remains the compatibility owner and this script asks
# `tasks-axi list` for the compact identity fields plus blocked_by, hold_kind,
# hold_reason, and created where captain-decision age is needed, never body.
# When manual mode is selected, or tasks-axi is unavailable or incompatible,
# this script prints only backlog section headings and item title lines, so
# title-line hold and blocked-by metadata remain visible while indented bodies
# stay out of the startup digest.
# A separate held-captain-decision subsection is still derived from the same
# backlog data, ordered oldest first, with age annotations only for visibility.
# It is not a second obligation store.
# Full bodies are targeted follow-up only: `tasks-axi show <id> --full` when
# compatible tasks-axi is available, or `data/backlog.md` when the file body is
# truly needed.
#
# Usage: fm-session-start.sh
#   Prints the full ordered digest to stdout and always exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud
#   banner inline, never a silent failure or a non-zero exit that would make
#   an agent skip the rest of the digest.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PRIMARY_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

STATUS_TAIL=${FM_SESSION_START_STATUS_TAIL:-5}
case "$STATUS_TAIL" in ''|*[!0-9]*) STATUS_TAIL=5 ;; esac
BACKLOG_LIMIT=${FM_SESSION_START_BACKLOG_LIMIT:-80}
case "$BACKLOG_LIMIT" in ''|*[!0-9]*|0) BACKLOG_LIMIT=80 ;; esac

RULE='================================================================================'
SUBRULE='--------------------------------------------------------------------------------'

section() { printf '\n%s\n%s\n%s\n' "$RULE" "$1" "$RULE"; }
subsection() { printf '\n%s\n%s\n' "$1" "$SUBRULE"; }

# print_file_or_absent <path> <label>: full contents under a labeled
# subsection, or an explicit ABSENT marker. Absence is semantically
# meaningful for every one of these files (captain.md absent = firstmate
# repo built-in defaults, projects.md absent = rebuild from clones, etc. -
# AGENTS.md section 3) and must never be confused with an empty-but-present
# file, so the two cases print differently.
print_file_or_absent() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      cat "$path"
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

print_backlog_pointer() {
  printf 'Full task bodies remain available on demand: tasks-axi show <id> --full when compatible tasks-axi is available, or data/backlog.md.\n'
}

print_backlog_manual_compact() {
  local path=$1 reason=$2
  printf 'compact backlog listing (%s; max %s item(s); indented task bodies omitted)\n' "$reason" "$BACKLOG_LIMIT"
  awk -v max="$BACKLOG_LIMIT" '
    function state_for_heading(line, heading) {
      heading = line
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      if (heading == "In flight") return "in_flight"
      if (heading == "Queued") return "queued"
      if (heading == "Done") return "done"
      return ""
    }
    /^##[[:space:]]+/ {
      state = state_for_heading($0)
      if (state != "") print $0
      next
    }
    state != "" && /^[-*][[:space:]]+/ {
      total++
      if (shown < max) {
        print $0
        shown++
      }
      next
    }
    END {
      if (total == 0) {
        print "(no backlog item title lines found)"
      } else {
        printf "(shown %d of %d backlog item title line(s))\n", shown, total
        if (total > shown) {
          printf "(truncated %d item(s); increase FM_SESSION_START_BACKLOG_LIMIT for a larger startup listing)\n", total - shown
        }
      }
    }
  ' "$path"
}

print_backlog_tasks_axi_compact() {
  local path=$1 out rc
  printf 'compact backlog listing (tasks-axi; max %s item(s); task bodies omitted)\n' "$BACKLOG_LIMIT"
  out=$(tasks-axi list --file "$path" --limit "$BACKLOG_LIMIT" --fields blocked_by,hold_kind,hold_reason 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$out"
  else
    printf 'tasks-axi compact listing failed; falling back to title-line rendering.\n'
    printf '%s\n' "$out"
    print_backlog_manual_compact "$path" "fallback"
  fi
}

print_backlog_compact() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      if fm_tasks_axi_backend_available "$CONFIG"; then
        print_backlog_tasks_axi_compact "$path"
      elif fm_backlog_backend_manual "$CONFIG"; then
        print_backlog_manual_compact "$path" "manual backend"
      else
        print_backlog_manual_compact "$path" "tasks-axi unavailable or incompatible"
      fi
      print_backlog_pointer
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

date_to_epoch() {  # <yyyy-mm-dd>
  local day=$1
  case "$day" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
    *) return 1 ;;
  esac
  if date -u -d "$day" +%s >/dev/null 2>&1; then
    date -u -d "$day" +%s
  elif date -u -j -f %F "$day" +%s >/dev/null 2>&1; then
    date -u -j -f %F "$day" +%s
  else
    return 1
  fi
}

captain_decision_age_days() {  # <yyyy-mm-dd>
  local since=$1 today today_epoch since_epoch days
  today=${FM_SESSION_START_TODAY:-$(date -u +%F)}
  today_epoch=$(date_to_epoch "$today") || return 1
  since_epoch=$(date_to_epoch "$since") || return 1
  days=$(( (today_epoch - since_epoch) / 86400 ))
  [ "$days" -ge 0 ] || days=0
  printf '%s\n' "$days"
}

strip_csv_quotes() {  # <value>
  local value=$1
  case "$value" in
    \"*\")
      value=${value#\"}
      value=${value%\"}
      value=${value//\"\"/\"}
      ;;
  esac
  printf '%s\n' "$value"
}

tasks_axi_captain_decision_records() {  # <backlog-path>
  local path=$1 out rc
  out=$(tasks-axi list --file "$path" --state held --kind captain --limit "$BACKLOG_LIMIT" --fields created,blocked_by,hold_kind,hold_reason 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'tasks-axi held-decision listing failed; falling back to title-line rendering.\n%s\n' "$out" >&2
    return "$rc"
  fi
  printf '%s\n' "$out" | awk '
    function csv_split(line, out,    i, c, nextc, field, n, in_quote) {
      n = 1
      field = ""
      in_quote = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (in_quote) {
          if (c == "\"") {
            nextc = substr(line, i + 1, 1)
            if (nextc == "\"") {
              field = field c
              i++
            } else {
              in_quote = 0
            }
          } else {
            field = field c
          }
        } else if (c == ",") {
          out[n++] = field
          field = ""
        } else if (c == "\"") {
          in_quote = 1
        } else {
          field = field c
        }
      }
      out[n] = field
      return n
    }
    /^tasks\[[0-9]+\]\{/ { in_table = 1; next }
    /^help\[/ { in_table = 0 }
    in_table && /^  / {
      line = $0
      sub(/^  /, "", line)
      delete f
      n = csv_split(line, f)
      if (n < 9 || f[8] != "captain") next
      printf "%s\t%s\t%s\t%s\t%s\n", f[6], f[1], f[5], f[9], f[7]
    }
  '
}

backlog_title_metadata() {  # <title-rest> <metadata-key>
  local rest=$1 key=$2 pattern
  pattern="\\($key:[[:space:]]*([^)]*)\\)"
  if [[ $rest =~ $pattern ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

backlog_title_since() {  # <title-rest>
  local rest=$1
  if [[ $rest =~ \(since[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

clean_backlog_title() {  # <title-rest>
  printf '%s\n' "$1" \
    | sed -E 's/[[:space:]]+blocked-by:[^[:space:])]+.*$//; s/[[:space:]]*\([^)]*\)//g; s/[[:space:]]+$//'
}

manual_captain_decision_records() {  # <backlog-path>
  local path=$1 section='' line id rest kind hold_kind hold_reason since title blocked_by
  while IFS= read -r line; do
    case "$line" in
      '## In flight') section=in_flight; continue ;;
      '## Queued') section=queued; continue ;;
      '## Done') section='done'; continue ;;
      '## '*) section=''; continue ;;
    esac
    [ "$section" != 'done' ] || continue
    [[ $line =~ ^[-*][[:space:]]+\[[[:space:]xX]\][[:space:]]+([^[:space:]]+)[[:space:]]+-[[:space:]]+(.*)$ ]] || continue
    id=${BASH_REMATCH[1]}
    rest=${BASH_REMATCH[2]}
    kind=$(backlog_title_metadata "$rest" kind)
    hold_kind=$(backlog_title_metadata "$rest" hold-kind)
    hold_reason=$(backlog_title_metadata "$rest" hold)
    [ "$kind" = captain ] && [ "$hold_kind" = captain ] && [ -n "$hold_reason" ] || continue
    since=$(backlog_title_since "$rest")
    title=$(clean_backlog_title "$rest")
    blocked_by=$(printf '%s\n' "$rest" | sed -nE 's/.*blocked-by:[[:space:]]*([^[:space:])]+).*/\1/p' | head -1)
    [ -n "$blocked_by" ] || blocked_by=none
    printf '%s\t%s\t%s\t%s\t%s\n' "$since" "$id" "$title" "$hold_reason" "$blocked_by"
  done < "$path"
}

render_captain_decision_records() {
  local records=$1 rows='' day id title reason blocked days sort_key age_label date_label line tab
  tab=$(printf '\t')
  while IFS=$'\t' read -r day id title reason blocked; do
    [ -n "$id" ] || continue
    reason=$(strip_csv_quotes "${reason:--}")
    blocked=$(strip_csv_quotes "${blocked:-none}")
    if days=$(captain_decision_age_days "$day"); then
      sort_key=$days
      age_label="age: ${days}d"
      date_label="since $day"
    else
      sort_key=-1
      age_label="age: unknown"
      date_label="since unknown"
    fi
    rows="${rows}${sort_key}${tab}${id}${tab}${age_label}${tab}${date_label}${tab}${title}${tab}${reason}${tab}${blocked}"$'\n'
  done <<< "$records"

  if [ -z "$rows" ]; then
    printf '(no held captain decisions found)\n'
    return 0
  fi

  printf '%s' "$rows" | LC_ALL=C sort -t "$tab" -k1,1nr -k2,2 | while IFS=$'\t' read -r _sort id age_label date_label title reason blocked; do
    line="- $id ($age_label, $date_label) - $title"
    [ -n "$reason" ] && [ "$reason" != "-" ] && line="$line; reason: $reason"
    case "$blocked" in
      ''|none|\"-\"|-) : ;;
      *) line="$line; blocked by: $blocked" ;;
    esac
    printf '%s\n' "$line"
  done
}

print_captain_decision_ages() {  # <backlog-path>
  local path=$1 records
  subsection "Held captain decisions (age-ordered)"
  if [ ! -f "$path" ]; then
    printf '(no backlog file; no held captain decisions found)\n'
    return 0
  fi
  if [ ! -s "$path" ]; then
    printf '(present, empty)\n'
    return 0
  fi
  printf 'single source: data/backlog.md; oldest held captain decision first\n'
  if fm_tasks_axi_backend_available "$CONFIG"; then
    if records=$(tasks_axi_captain_decision_records "$path" 2>/dev/null); then
      render_captain_decision_records "$records"
      return 0
    fi
  fi
  records=$(manual_captain_decision_records "$path")
  render_captain_decision_records "$records"
}

print_status_tail() {
  local status=$1
  printf 'status tail (last %s line(s), wake-EVENT history, not current state; full log: %s):\n' "$STATUS_TAIL" "$status"
  tail -n "$STATUS_TAIL" "$status"
}

hash_file() {
  local file=$1
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print "sha256:" $1}'
  else
    cksum "$file" | awk '{print "cksum:" $1 ":" $2}'
  fi
}

pi_extension_loaded() {
  local marker=$1 expected_version=$2 lock=$3 marker_version marker_pid lock_pid
  [ -f "$marker" ] && [ -f "$lock" ] && [ -n "$expected_version" ] || return 1
  marker_version=$(sed -n '1p' "$marker")
  marker_pid=$(sed -n '2p' "$marker")
  lock_pid=$(sed -n '1p' "$lock")
  [ -n "$marker_pid" ] || return 1
  [ "$marker_version" = "$expected_version" ] && [ "$marker_pid" = "$lock_pid" ]
}

section "SESSION START - $FM_HOME"

# --- 1. lock -----------------------------------------------------------
subsection "LOCK"
LOCK_OUT=$("$SCRIPT_DIR/fm-lock.sh" 2>&1)
LOCK_RC=$?
printf '%s\n' "$LOCK_OUT"
READ_ONLY=0
if [ "$LOCK_RC" -ne 0 ]; then
  READ_ONLY=1
  BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '%s\n' "$BAR"
    printf '●  READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED\n'
    printf '●  %s\n' "$LOCK_OUT"
    printf '●  Skipping every mutating step: PR-check migration, stale Herdr child cleanup,\n'
    printf '●  secondmate sync, X-mode artifacts, fleet sync, and wake-queue drain. Detect-only bootstrap\n'
    printf '●  diagnostics and the rest of this read-only-safe digest still ran below.\n'
    printf '●  Operate read-only until this resolves - do not spawn, steer, merge, or\n'
    printf '●  otherwise mutate fleet state from this session.\n'
    printf '%s\n' "$BAR"
  }
fi

# --- 2. bootstrap --------------------------------------------------------
subsection "BOOTSTRAP"
if [ "$READ_ONLY" -eq 1 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
else
  BOOT_OUT=$(
    "$SCRIPT_DIR/fm-herdr-session-cleanup.sh" 2>&1 || true
    "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1
  )
fi
if [ -n "$BOOT_OUT" ]; then
  printf '%s\n' "$BOOT_OUT"
else
  printf '(silent - all good)\n'
fi

# --- 3. wake-drain -------------------------------------------------------
# Drained records are this turn's first work queue (AGENTS.md section 8); the
# drain also runs fm-guard.sh internally on the locked path, so the
# tangle/watcher-liveness alarms land right here too, ahead of the bulk digest
# below. The read-only path never touches the queue because it lacks mutation
# authority, and another session may be actively draining it. It still runs
# fm-guard.sh directly with non-mutating advisory text, so the same alarms
# surface without repair commands.
subsection "WAKE QUEUE"
if [ "$READ_ONLY" -eq 1 ]; then
  QLEN=0
  [ -s "$STATE/.wake-queue" ] && QLEN=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || printf '0')
  printf 'skipped (read-only session) - %s record(s) remain queued because this session lacks verified fleet-lock ownership.\n' "$QLEN"
  GUARD_OUT=$(FM_GUARD_READ_ONLY=1 "$SCRIPT_DIR/fm-guard.sh" 2>&1)
  [ -n "$GUARD_OUT" ] && printf '%s\n' "$GUARD_OUT"
else
  DRAIN_OUT=$("$SCRIPT_DIR/fm-wake-drain.sh" 2>&1)
  if [ -n "$DRAIN_OUT" ]; then
    printf '%s\n' "$DRAIN_OUT"
  else
    printf '(no queued wakes)\n'
  fi
fi

# --- 4. supervision operating instructions ----------------------------------
AFK_PRESENT=0
[ -e "$STATE/.afk" ] && AFK_PRESENT=1
X_MODE_PRESENT=0
[ -f "$CONFIG/x-mode.env" ] && X_MODE_PRESENT=1

if [ "$PRIMARY_HARNESS" = pi ]; then
  PI_EXT="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  PI_TURNEND_EXT="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  PI_WATCH_MARKER="$STATE/.pi-watch-extension-loaded"
  PI_TURNEND_MARKER="$STATE/.pi-turnend-extension-loaded"
  PI_LOCK="$STATE/.lock"
  PI_WATCH_VERSION=$(hash_file "$PI_EXT" || printf '')
  PI_TURNEND_VERSION=$(hash_file "$PI_TURNEND_EXT" || printf '')
  if ! pi_extension_loaded "$PI_WATCH_MARKER" "$PI_WATCH_VERSION" "$PI_LOCK" \
    || ! pi_extension_loaded "$PI_TURNEND_MARKER" "$PI_TURNEND_VERSION" "$PI_LOCK"; then
    printf 'PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart plain pi so %s and %s auto-load for turn-end guard and background wake coverage; use -e %s -e %s only if project hooks are not trusted\n' "$PI_TURNEND_EXT" "$PI_EXT" "$PI_TURNEND_EXT" "$PI_EXT"
  fi
fi
"$SCRIPT_DIR/fm-supervision-instructions.sh" \
  --harness "$PRIMARY_HARNESS" \
  --read-only "$READ_ONLY" \
  --afk "$AFK_PRESENT" \
  --x-mode "$X_MODE_PRESENT"

# --- 4. context digest -----------------------------------------------------
section "CONTEXT"
print_file_or_absent "$DATA/projects.md" "data/projects.md"
print_file_or_absent "$DATA/secondmates.md" "data/secondmates.md"
print_file_or_absent "$DATA/captain.md" "data/captain.md"
print_file_or_absent "$DATA/captain-shared.md" "data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)"
print_file_or_absent "$DATA/learnings.md" "data/learnings.md"

# --- 5. fleet-state digest ---------------------------------------------
section "FLEET STATE"
print_backlog_compact "$DATA/backlog.md" "data/backlog.md"
print_captain_decision_ages "$DATA/backlog.md"

subsection "Work under way (state/*.meta)"
META_FOUND=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  META_FOUND=1
  id=$(basename "$meta" .meta)
  printf '\n--- %s ---\n' "$id"
  cat "$meta"

  window=$(fm_meta_get "$meta" window)
  target=$(fm_backend_target_of_meta "$meta")
  if [ -n "$window" ]; then
    backend=$(fm_backend_of_meta "$meta")
    if fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id"; then
      printf 'endpoint: alive (backend=%s window=%s)\n' "$backend" "$window"
    else
      printf 'endpoint: dead (backend=%s window=%s)\n' "$backend" "$window"
    fi
  else
    printf 'endpoint: unknown (no window recorded)\n'
  fi

  status="$STATE/$id.status"
  if [ -f "$status" ]; then
    print_status_tail "$status"
  else
    printf 'status tail: (no status file yet: %s)\n' "$status"
  fi
done
[ "$META_FOUND" -eq 1 ] || printf '(none)\n'

subsection "Orphan status logs (state/*.status without matching .meta)"
ORPHAN_STATUS_FOUND=0
for status in "$STATE"/*.status; do
  [ -f "$status" ] || continue
  id=$(basename "$status" .status)
  [ -f "$STATE/$id.meta" ] && continue
  ORPHAN_STATUS_FOUND=1
  printf '\n--- %s ---\n' "$id"
  print_status_tail "$status"
done
[ "$ORPHAN_STATUS_FOUND" -eq 1 ] || printf '(none)\n'

subsection "AFK"
if [ -e "$STATE/.afk" ]; then
  printf 'present - away-mode supervision is active; the daemon owns the watcher.\n'
else
  printf 'absent\n'
fi

# --- 6. closing reminder -----------------------------------------------
section "NEXT STEP"
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. Only a session
with verified fleet-lock ownership may perform mutable follow-up.

EOF
elif [ "$AFK_PRESENT" -eq 1 ]; then
  cat <<'EOF'
Away mode is active. Follow the supervision operating instructions block above:
load /afk and ensure the daemon is running, because the daemon owns watcher
supervision.

EOF
elif [ -f "$CONFIG/x-mode.env" ]; then
  cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
X mode is active, so the emitted block's cadence instruction applies.
This script never starts supervision itself.

EOF
else
cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
This script never starts supervision itself.

EOF
fi
cat <<'EOF'
The digest above is complete for this session start. Do NOT re-read
data/projects.md, data/secondmates.md, data/captain.md,
data/captain-shared.md, data/learnings.md,
or state/*.meta now - they were just printed in full.
Do NOT bulk-read data/backlog.md now either: the compact identity/metadata
listing was just printed with a pointer for targeted full-body follow-up.
Do NOT bulk-read state/*.status now either: their bounded tails were just
printed with full log paths for targeted follow-up when older wake-event
history is actually needed. Re-reading everything defeats the entire point
of this command. Re-read a file only if this digest flagged it ABSENT (then
rebuild or create it per AGENTS.md), its contents looked unparseable/corrupt,
or an individual full status log is needed for older wake-event history.
EOF

exit 0
