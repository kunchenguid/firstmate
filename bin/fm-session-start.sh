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
# bootstrap running its detect-only diagnostics without its six mutating
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
#                       diagnostics always run. Bootstrap's six MUTATING sweeps
#                       (legacy PR-check migration, secondmate convergence,
#                       secondmate liveness, pending remote handoff retry,
#                       X-mode artifact writes, fleet sync) also run only when
#                       locked.
#   3. wake-drain     - mutates the durable wake queue, so it also only runs
#                       when locked.
#   4. context digest - data/projects.md, data/secondmates.md, data/captain.md,
#                       data/captain-shared.md, data/learnings.md: read-only,
#                       always safe, always runs.
#   5. fleet digest   - a compact data/backlog.md identity/metadata listing,
#                       every state/*.meta, a byte-bounded structured
#                       state/*.status projection, state/.afk, and a cheap
#                       per-task endpoint-liveness read: read-only, always runs.
#   6. closing reminder - prints the context-specific watcher next step; this
#                       script points back to the emitted harness supervision
#                       block and deliberately never arms the watcher itself.
#
# On a Pi primary, the supervision-block step also checks whether Pi's two
# tracked primary extensions are loaded and prints a PI_WATCH_EXTENSION
# reminder line when one is missing.
#
# Why lock first: the old documented order (bootstrap, THEN lock) let a
# SECOND concurrent session run bootstrap's mutating sweeps - converging
# secondmate homes, retrying pending handoff outboxes, writing X-mode artifacts,
# and fetching or fast-forwarding every project clone - before ever discovering
# another session already holds the lock. Two sessions racing those sweeps is
# exactly the hazard the lock exists to prevent, so locking first closes the
# hole outright: only the session that actually wins the lock ever touches
# shared mutable state.
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
# and hold_reason, never body.
# When manual mode is selected, or tasks-axi is unavailable or incompatible,
# this script prints only backlog section headings and item title lines, so
# title-line hold and blocked-by metadata remain visible while indented bodies
# stay out of the startup digest.
# Full bodies are targeted follow-up only: `tasks-axi show <id> --full` when
# compatible tasks-axi is available, or `data/backlog.md` when the file body is
# truly needed.
#
# STATUS PROJECTION: raw state/*.status logs remain unchanged. For each present
# log, this script emits the newest recognized lifecycle event and every open
# keyed decision returned by fm-classify-lib.sh's authoritative
# status_open_decisions fold. When the newest recognized event IS one of those
# open decisions, it is emitted once and back-referenced rather than repeated and
# charged twice. A newest line carrying no lifecycle verb - a legacy free-text
# event such as "PR ready" or "merged" - is projected separately so such a log
# still contributes its most recent prose. It also emits source/recognized/
# omitted counts (omitted counts every event NOT projected here) and the exact
# full-log path. Event text is bounded independently per record, per
# task, and across the whole fleet; the fixed recovery fields and truncation
# receipts do not consume those text budgets and therefore remain visible after
# text is exhausted. A receipt records original text bytes, emitted bytes, the
# limiting scopes, and source path. Before truncating text, the projection lifts
# the state verb, decision key, canonical GitHub/GitLab PR URL tokens, 40/64-hex
# exact-head tokens, and run-identity tokens into structured fields. This is
# historical recovery evidence only and never replaces a targeted
# fm-crew-state.sh read when current state matters.
#
# Usage: fm-session-start.sh
#   Prints the full ordered digest to stdout and always exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud
#   banner inline, never a silent failure or a non-zero exit that would make
#   an agent skip the rest of the digest.
set -u

# Status-file glob order, byte counts, and byte truncation must not vary with
# the launching session's locale.
LC_ALL=C
export LC_ALL

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
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-trace-context-lib.sh
. "$SCRIPT_DIR/fm-trace-context-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

# Status projection budgets apply to emitted event/decision text. Recovery
# fields, omitted counts, truncation receipts, and exact source paths remain
# visible even after the text budget is exhausted. The defaults retain routine
# one-line events, allow two saturated records per task, and cap fleet-wide
# status prose at 12 KiB.
STATUS_EVENT_BYTES=${FM_SESSION_START_STATUS_EVENT_BYTES:-768}
case "$STATUS_EVENT_BYTES" in ''|*[!0-9]*|0|??????????*) STATUS_EVENT_BYTES=768 ;; esac
STATUS_TASK_BYTES=${FM_SESSION_START_STATUS_TASK_BYTES:-1536}
case "$STATUS_TASK_BYTES" in ''|*[!0-9]*|0|??????????*) STATUS_TASK_BYTES=1536 ;; esac
STATUS_TOTAL_BYTES=${FM_SESSION_START_STATUS_TOTAL_BYTES:-12288}
case "$STATUS_TOTAL_BYTES" in ''|*[!0-9]*|0|??????????*) STATUS_TOTAL_BYTES=12288 ;; esac
STATUS_TOTAL_TEXT_USED=0
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

status_projection_is_recognized_verb() {  # <verb>
  case "$1" in
    working|done|needs-decision|blocked|failed) return 0 ;;
    "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}") return 0 ;;
    "${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}") return 0 ;;
    "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}") return 0 ;;
    *) return 1 ;;
  esac
}

# Drop a trailing incomplete UTF-8 sequence left by a byte-exact cut, so a
# truncated crew note can never emit a partial code point. LC_ALL=C keeps every
# expansion here byte-indexed, and the receipt still reports the bytes actually
# emitted rather than switching the budget to characters.
status_projection_trim_partial_utf8_into() {  # <var> <byte-truncated text>
  local __text=$2 __len=${#2} __i=1 __byte __need
  while [ "$__i" -le 4 ] && [ "$__i" -le "$__len" ]; do
    __byte=${__text:__len-__i:1}
    case "$__byte" in
      [$'\x80'-$'\xbf']) __i=$((__i + 1)); continue ;;
      [$'\xc2'-$'\xdf']) __need=2 ;;
      [$'\xe0'-$'\xef']) __need=3 ;;
      [$'\xf0'-$'\xf4']) __need=4 ;;
      *) __need=1 ;;
    esac
    [ "$__need" -le "$__i" ] || __text=${__text:0:__len-__i}
    break
  done
  printf -v "$1" '%s' "$__text"
}

status_projection_identity_fields() {  # <full, untruncated event text>
  local text=$1 token value restore_glob=0 seen_pr=$'\n' seen_head=$'\n' seen_run=$'\n'
  case $- in *f*) : ;; *) set -f; restore_glob=1 ;; esac
  for token in $text; do
    token=${token#\(}; token=${token#\[}; token=${token#\{}; token=${token#<}
    token=${token#\"}; token=${token#\'}; token=${token#\`}
    token=${token%\)}; token=${token%\]}; token=${token%\}}; token=${token%>}
    token=${token%,}; token=${token%.}; token=${token%\;}; token=${token%:}
    token=${token%\"}; token=${token%\'}; token=${token%\`}
    case "$token" in
      https://*/pull/[0-9]*|https://*/merge_requests/[0-9]*)
        case "$seen_pr" in *$'\n'"$token"$'\n'*) : ;; *)
          printf '  pr_url=%s\n' "$token"
          seen_pr="${seen_pr}${token}"$'\n'
          ;;
        esac
        ;;
      exact-head=*|exact_head=*|head=*|pr_head=*)
        value=${token#*=}
        case "${#value}:$value" in
          40:*|64:*)
            case "$value" in *[!0-9A-Fa-f]*) : ;; *)
              case "$seen_head" in *$'\n'"$value"$'\n'*) : ;; *)
                printf '  exact_head=%s\n' "$value"
                seen_head="${seen_head}${value}"$'\n'
                ;;
              esac
              ;;
            esac
            ;;
        esac
        ;;
      run=*|run_id=*|run-id=*|run_identity=*|run-identity=*)
        value=${token#*=}
        case "$value" in ''|*[!A-Za-z0-9._:-]*) : ;; *)
          case "$seen_run" in *$'\n'"$value"$'\n'*) : ;; *)
            printf '  run_id=%s\n' "$value"
            seen_run="${seen_run}${value}"$'\n'
            ;;
          esac
          ;;
        esac
        ;;
    esac
  done
  [ "$restore_glob" -eq 0 ] || set +f
}

status_projection_record() {  # <label> <verb> <key> <text> <source-path>
  local label=$1 verb=$2 key=$3 text=$4 source=$5 original emitted allowance
  local task_remaining total_remaining causes='' truncated=''
  original=${#text}
  task_remaining=$((STATUS_TASK_BYTES - STATUS_TASK_TEXT_USED))
  [ "$task_remaining" -ge 0 ] || task_remaining=0
  total_remaining=$((STATUS_TOTAL_BYTES - STATUS_TOTAL_TEXT_USED))
  [ "$total_remaining" -ge 0 ] || total_remaining=0
  allowance=$STATUS_EVENT_BYTES
  [ "$task_remaining" -ge "$allowance" ] || allowance=$task_remaining
  [ "$total_remaining" -ge "$allowance" ] || allowance=$total_remaining

  printf '%s:\n' "$label"
  printf '  state_verb=%s\n' "$verb"
  printf '  decision_key=%s\n' "$key"
  status_projection_identity_fields "$text"
  if [ "$original" -le "$allowance" ]; then
    emitted=$original
    truncated=$text
  else
    truncated=${text:0:allowance}
    status_projection_trim_partial_utf8_into truncated "$truncated"
    emitted=${#truncated}
  fi
  printf '  event_text=%s\n' "$truncated"
  STATUS_TASK_TEXT_USED=$((STATUS_TASK_TEXT_USED + emitted))
  STATUS_TOTAL_TEXT_USED=$((STATUS_TOTAL_TEXT_USED + emitted))

  if [ "$emitted" -lt "$original" ]; then
    [ "$original" -le "$STATUS_EVENT_BYTES" ] || causes=per-event
    if [ "$original" -gt "$task_remaining" ]; then
      causes=${causes:+$causes,}per-task
    fi
    if [ "$original" -gt "$total_remaining" ]; then
      causes=${causes:+$causes,}total
    fi
    printf '  truncation=original_bytes:%s emitted_bytes:%s causes:%s source_path:%s\n' \
      "$original" "$emitted" "$causes" "$source"
  fi
}

print_status_projection() {
  local status=$1 line stripped verb key note open decision_text
  local open_count=0 decision_index=0 event_count=0 recognized_count=0 omitted projected
  local newest='' newest_verb='' newest_key='' newest_note='' newest_dup=0
  local tail_line='' tail_recognized=1 tail_key
  STATUS_TASK_TEXT_USED=0

  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    event_count=$((event_count + 1))
    tail_line=$line
    _fm_status_line_verb_into verb "$line"
    if status_projection_is_recognized_verb "$verb"; then
      recognized_count=$((recognized_count + 1))
      newest=$line
      tail_recognized=1
    else
      tail_recognized=0
    fi
  done < "$status"

  open=$(status_open_decisions "$status")
  if [ -n "$newest" ]; then
    _fm_status_line_verb_into newest_verb "$newest"
    _fm_decision_key_into newest_key "$newest" || newest_key=invalid
    _fm_status_line_note_into newest_note "$newest"
  fi

  # The newest recognized event is frequently the very decision the fold already
  # reports as open. Locate that overlap before printing anything so the text is
  # emitted once, charged once, and counted once as projected.
  while IFS=$'\t' read -r key verb note; do
    [ -n "$key" ] || continue
    open_count=$((open_count + 1))
    if [ "$newest_dup" -eq 0 ] && [ -n "$newest" ] && [ "$key" = "$newest_key" ] &&
      [ "$verb" = "$newest_verb" ] && [ "$note" = "$newest_note" ]; then
      newest_dup=$open_count
    fi
  done <<EOF
$open
EOF

  projected=$open_count
  if [ -n "$newest" ] && [ "$newest_dup" -eq 0 ]; then
    projected=$((projected + 1))
  fi
  if [ -n "$tail_line" ] && [ "$tail_recognized" -eq 0 ]; then
    projected=$((projected + 1))
  fi
  omitted=$((event_count - projected))
  [ "$omitted" -ge 0 ] || omitted=0

  printf 'status projection (wake-EVENT history, not current state; full log: %s):\n' "$status"
  printf '  source_event_count=%s recognized_event_count=%s omitted_event_count=%s open_decision_count=%s\n' \
    "$event_count" "$recognized_count" "$omitted" "$open_count"
  printf '  text_limits_bytes=event:%s task:%s total:%s\n' \
    "$STATUS_EVENT_BYTES" "$STATUS_TASK_BYTES" "$STATUS_TOTAL_BYTES"

  while IFS=$'\t' read -r key verb note; do
    [ -n "$key" ] || continue
    decision_index=$((decision_index + 1))
    if [ "$key" = default ]; then
      decision_text="$verb: $note"
    else
      decision_text="$verb [key=$key]: $note"
    fi
    status_projection_record "open_decision_$decision_index" "$verb" "$key" "$decision_text" "$status"
  done <<EOF
$open
EOF

  if [ -z "$newest" ]; then
    printf 'newest_recognized_event: (none)\n'
  elif [ "$newest_dup" -ne 0 ]; then
    printf 'newest_recognized_event:\n'
    printf '  state_verb=%s\n' "$newest_verb"
    printf '  decision_key=%s\n' "$newest_key"
    printf '  same_as=open_decision_%s\n' "$newest_dup"
  else
    status_projection_record newest_recognized_event "$newest_verb" "$newest_key" "$newest" "$status"
  fi

  # A legacy free-text line ("PR ready", "merged upstream at abc") carries no
  # lifecycle verb, so it can never be the newest recognized event or open a
  # keyed decision. Project the newest line whenever it is one of those, so a
  # legacy-shaped log still contributes its most recent prose instead of only
  # counts.
  if [ -n "$tail_line" ] && [ "$tail_recognized" -eq 0 ]; then
    _fm_decision_key_into tail_key "$tail_line" || tail_key=invalid
    status_projection_record newest_unrecognized_event unrecognized "$tail_key" "$tail_line" "$status"
  fi

  printf '  task_text_budget_used_bytes=%s task_text_budget_limit_bytes=%s\n' \
    "$STATUS_TASK_TEXT_USED" "$STATUS_TASK_BYTES"
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
    printf '●  secondmate convergence, secondmate liveness, pending remote handoff retry,\n'
    printf '●  X-mode artifacts, fleet sync, and wake-queue drain. Detect-only bootstrap\n'
    printf '●  diagnostics and the rest of this read-only-safe digest still ran below.\n'
    printf '●  Operate read-only until this resolves - do not spawn, steer, merge, or\n'
    printf '●  otherwise mutate fleet state from this session.\n'
    printf '%s\n' "$BAR"
  }
fi
if [ "$READ_ONLY" -eq 0 ]; then
  fm_trace_context_session_start "$CONFIG" "$STATE/.trace-context-effective"
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
# Drained records are this turn's first work queue, and the drain's separate
# OPEN DECISIONS section remains actionable even when that queue is empty
# (AGENTS.md sections 3 and 8).
# The drain also runs fm-guard.sh internally on the locked path, so the
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

if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
  PI_EXT="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  PI_TURNEND_EXT="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  PI_WATCH_MARKER="$STATE/.pi-watch-extension-loaded"
  PI_TURNEND_MARKER="$STATE/.pi-turnend-extension-loaded"
  PI_LOCK="$STATE/.lock"
  PI_RESTART_COMMAND=$PRIMARY_HARNESS
  [ "$PRIMARY_HARNESS" != pi ] || PI_RESTART_COMMAND='plain pi'
  PI_WATCH_VERSION=$(hash_file "$PI_EXT" || printf '')
  PI_TURNEND_VERSION=$(hash_file "$PI_TURNEND_EXT" || printf '')
  if ! pi_extension_loaded "$PI_WATCH_MARKER" "$PI_WATCH_VERSION" "$PI_LOCK" \
    || ! pi_extension_loaded "$PI_TURNEND_MARKER" "$PI_TURNEND_VERSION" "$PI_LOCK"; then
    printf 'PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart %s so %s and %s auto-load for turn-end guard and background wake coverage; use -e %s -e %s only if project hooks are not trusted\n' "$PI_RESTART_COMMAND" "$PI_TURNEND_EXT" "$PI_EXT" "$PI_TURNEND_EXT" "$PI_EXT"
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
    print_status_projection "$status"
  else
    printf 'status projection: (no status file yet; full log path: %s)\n' "$status"
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
  print_status_projection "$status"
done
[ "$ORPHAN_STATUS_FOUND" -eq 1 ] || printf '(none)\n'
printf '\nstartup_status_text_budget_used_bytes=%s startup_status_text_budget_limit_bytes=%s\n' \
  "$STATUS_TOTAL_TEXT_USED" "$STATUS_TOTAL_BYTES"

subsection "AFK"
if [ -e "$STATE/.afk" ]; then
  printf 'present - away-mode supervision is active; the daemon owns the watcher.\n'
else
  printf 'absent\n'
fi

# Public commitments made through the myfirstmate relay. A promise to reply in a
# public thread must survive compaction and restart, so it is surfaced from disk
# here rather than from conversation memory. fm-public-followup-lib.sh owns both
# gates: a home that never opted into the relay runs one [ -f ] test, prints no
# subsection, and never reaches fm-public-followup.sh.
if fm_pf_relay_active "$FM_HOME" \
  && { fm_pf_has_registrations "$STATE" || fm_pf_has_events "$STATE"; }; then
  PUBLIC_FOLLOWUP=$("$SCRIPT_DIR/fm-public-followup.sh" pending 2>/dev/null) || PUBLIC_FOLLOWUP=
  if [ -n "$PUBLIC_FOLLOWUP" ]; then
    subsection "Public commitments awaiting delivery"
    printf '%s\n' "$PUBLIC_FOLLOWUP"
    printf '\nEach line is a public reply this home still owes. Reconcile terminal results with\n'
    printf '%s/bin/fm-public-followup.sh consume, then deliver a ready one with\n' "$FM_ROOT"
    printf '%s/bin/fm-public-followup.sh deliver <id>. Load fmx-respond for the procedure.\n' "$FM_ROOT"
  fi
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
Do NOT bulk-read state/*.status now either: their byte-bounded structured
projections were just printed with full log paths for targeted follow-up when
older wake-event history is actually needed. Re-reading everything defeats the entire point
of this command. Re-read a file only if this digest flagged it ABSENT (then
rebuild or create it per AGENTS.md), its contents looked unparseable/corrupt,
or an individual full status log is needed for older wake-event history.
EOF

exit 0
