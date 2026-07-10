#!/usr/bin/env bash
# Pull-based stall detector for firstmate supervision.
# Sweeps backlog/state/tmux and prints one line per stalled or ready workstream.
# Silent exit means all clear. Read-only: never mutates backlog or state.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="$FM_HOME/data"
BACKLOG="$DATA/backlog.md"
DONE_ARCHIVE="$DATA/done-archive.md"
IDLE_SECS=${FM_STALL_IDLE_SECS:-600}
ADVISOR_IDLE_SECS=${FM_ADVISOR_IDLE_STALL_SECS:-1800}

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"

if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

now_epoch() {
  date +%s
}

date_epoch() {
  local s=$1 out
  [ -n "$s" ] || return 1
  s=${s/T/ }
  if [ "$(uname)" = Darwin ]; then
    out=$(date -j -f '%Y-%m-%d %H:%M' "$s" +%s 2>/dev/null) \
      || out=$(date -j -f '%Y-%m-%d' "$s" +%s 2>/dev/null) \
      || out=$(date -j -f '%Y/%m/%d %H:%M' "$s" +%s 2>/dev/null) \
      || out=$(date -j -f '%Y/%m/%d' "$s" +%s 2>/dev/null) \
      || return 1
  else
    out=$(date -d "$s" +%s 2>/dev/null) || return 1
  fi
  printf '%s\n' "$out"
}

awk_ids_in_section() { # <section>
  local section=$1
  [ -f "$BACKLOG" ] || return 0
  awk -v want="$section" '
    /^## / { section = $0; next }
    section == want && /^- / {
      line = $0
      sub(/^- /, "", line)
      sub(/^\[[ xX]\][[:space:]]+/, "", line)
      if (match(line, /^\*\*[^*]+\*\*/)) {
        id = substr(line, RSTART + 2, RLENGTH - 4)
        print id
      } else if (match(line, /^[^[:space:]]+/)) {
        print substr(line, RSTART, RLENGTH)
      }
    }
  ' "$BACKLOG"
}

in_flight_ids() {
  awk_ids_in_section "## In flight"
}

done_ids() {
  awk_ids_in_section "## Done"
}

# The live backlog keeps only the 10 most recent Done entries; older completions
# are pruned into data/done-archive.md (tasks-axi done_keep). A blocker resolved
# long ago lives only there, so read it as a fallback source of done ids. The
# archive holds only completed items, so every list entry is a done id.
archive_done_ids() {
  [ -f "$DONE_ARCHIVE" ] || return 0
  awk '
    /^- / {
      line = $0
      sub(/^- /, "", line)
      sub(/^\[[ xX]\][[:space:]]+/, "", line)
      if (match(line, /^\*\*[^*]+\*\*/)) {
        print substr(line, RSTART + 2, RLENGTH - 4)
      } else if (match(line, /^[^[:space:]]+/)) {
        print substr(line, RSTART, RLENGTH)
      }
    }
  ' "$DONE_ARCHIVE"
}

queued_blockers() {
  [ -f "$BACKLOG" ] || return 0
  awk '
    /^## / { section = $0; next }
    section == "## Queued" && /^- / && /blocked-by:[[:space:]]*/ {
      line = $0
      sub(/^- /, "", line)
      sub(/^\[[ xX]\][[:space:]]+/, "", line)
      if (match(line, /^\*\*[^*]+\*\*/)) {
        id = substr(line, RSTART + 2, RLENGTH - 4)
      } else if (match(line, /^[^[:space:]]+/)) {
        id = substr(line, RSTART, RLENGTH)
      } else {
        next
      }
      rest = $0
      sub(/^.*blocked-by:[[:space:]]*/, "", rest)
      if (match(rest, /^[A-Za-z0-9_.-]+/)) {
        blocker = substr(rest, RSTART, RLENGTH)
        print id "\t" blocker
      }
    }
  ' "$BACKLOG"
}

queued_date_gates() {
  [ -f "$BACKLOG" ] || return 0
  awk '
    /^## / { section = $0; next }
    section == "## Queued" && /^- / {
      line = $0
      sub(/^- /, "", line)
      sub(/^\[[ xX]\][[:space:]]+/, "", line)
      if (match(line, /^\*\*[^*]+\*\*/)) {
        id = substr(line, RSTART + 2, RLENGTH - 4)
      } else if (match(line, /^[^[:space:]]+/)) {
        id = substr(line, RSTART, RLENGTH)
      } else {
        next
      }
      gate = ""
      if (match($0, /\[REMIND[[:space:]][^]]+\]/)) {
        gate = substr($0, RSTART + 8, RLENGTH - 9)
      } else if (match($0, /(run-on|run on|run_at|run-at|date-gate|date gate|due):?[[:space:]]+[0-9][0-9][0-9][0-9][-\/][0-9][0-9][-\/][0-9][0-9]([ T][0-9][0-9]:[0-9][0-9])?/)) {
        gate = substr($0, RSTART, RLENGTH)
        sub(/^[^0-9]*/, "", gate)
      }
      if (gate != "") print id "\t" gate
    }
  ' "$BACKLOG"
}

is_in_set() { # <needle> <newline-set>
  local needle=$1 set=$2
  printf '%s\n' "$set" | grep -Fx "$needle" >/dev/null 2>&1
}

terminal_status_ids() {
  local f id last
  for f in "$STATE"/*.status; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .status)
    last=$(awk 'NF { line = $0 } END { print line }' "$f" 2>/dev/null || true)
    case "$last" in
      done:*|failed:*) printf '%s\n' "$id" ;;
    esac
  done
}

window_for_meta() {
  grep '^window=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

worktree_for_meta() {
  grep '^worktree=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

kind_for_meta() {
  local kind
  kind=$(grep '^kind=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$kind" ] || kind=ship
  printf '%s\n' "$kind"
}

mode_for_meta() {
  grep '^mode=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

home_for_secondmate_meta() { # <id> <meta>
  local id=$1 meta=$2 home
  home=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  if [ -n "$home" ]; then
    printf '%s\n' "$home"
    return 0
  fi
  [ -f "$DATA/secondmates.md" ] || return 1
  awk -v id="$id" '
    index($0, "- " id " - ") == 1 {
      start = index($0, "(home: ")
      if (start == 0) next
      rest = substr($0, start + 7)
      end = index(rest, ";")
      if (end == 0) next
      print substr(rest, 1, end - 1)
      exit
    }
  ' "$DATA/secondmates.md"
}

last_status_line() { # <status-file>
  awk 'NF { line = $0 } END { print line }' "$1" 2>/dev/null || true
}

terminal_status_line() { # <line>
  case "$1" in
    done:*|result:*|failed:*) return 0 ;;
    *) return 1 ;;
  esac
}

child_has_active_work() { # <child-state> <meta>
  local child_state=$1 meta=$2 id window status m age last
  window=$(window_for_meta "$meta")
  if [ -n "$window" ] && fm_pane_is_busy "$window"; then
    return 0
  fi

  id=$(basename "$meta" .meta)
  status="$child_state/$id.status"
  [ -f "$status" ] || return 1
  last=$(last_status_line "$status")
  terminal_status_line "$last" && return 1
  m=$(stat_mtime "$status") || return 1
  age=$(( $(now_epoch) - m ))
  [ "$age" -lt "$ADVISOR_IDLE_SECS" ]
}

secondmate_has_child_work() { # <home>
  local child_state=$1/state meta
  [ -d "$child_state" ] || return 1
  for meta in "$child_state"/*.meta; do
    [ -e "$meta" ] || continue
    child_has_active_work "$child_state" "$meta" && return 0
  done
  return 1
}

advisor_terminal_status() { # <status-file>
  local last
  last=$(last_status_line "$1")
  case "$last" in
    done:*|result:*) return 0 ;;
    *) return 1 ;;
  esac
}

# A task whose meta records pr= is a PR-ready task parked awaiting the captain's
# merge; its advancement is already tracked by the merge poll fm-pr-check armed,
# so it is externally supervised, not dormant. Skip it in both stall checks.
meta_has_pr() { # <id>
  grep -q '^pr=' "$STATE/$1.meta" 2>/dev/null
}

check_finished_not_advanced() {
  local inflight terminal id
  inflight=$(in_flight_ids)
  [ -n "$inflight" ] || return 0
  terminal=$(terminal_status_ids)
  [ -n "$terminal" ] || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    meta_has_pr "$id" && continue
    if is_in_set "$id" "$inflight"; then
      printf 'advance: %s - done but still in-flight; next leg not triggered\n' "$id"
    fi
  done <<EOF
$terminal
EOF
}

check_unblocked_queued() {
  local done_set id blocker
  done_set=$( done_ids; archive_done_ids )
  [ -n "$done_set" ] || return 0
  queued_blockers | while IFS=$(printf '\t') read -r id blocker; do
    [ -n "$id" ] || continue
    if is_in_set "$blocker" "$done_set"; then
      printf 'ready: %s - blocker %s is done; dispatchable\n' "$id" "$blocker"
    fi
  done
}

check_date_gates() {
  local id gate due now
  now=$(now_epoch)
  queued_date_gates | while IFS=$(printf '\t') read -r id gate; do
    [ -n "$id" ] || continue
    due=$(date_epoch "$gate" 2>/dev/null || true)
    [ -n "$due" ] || continue
    if [ "$due" -le "$now" ]; then
      printf 'ready: %s - date gate %s reached\n' "$id" "$gate"
    fi
  done
}

check_idle_stalls() {
  local meta id kind status m age window
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(kind_for_meta "$meta")
    [ "$kind" = secondmate ] && continue
    meta_has_pr "$id" && continue
    status="$STATE/$id.status"
    [ -f "$status" ] || continue
    m=$(stat_mtime "$status") || continue
    age=$(( $(now_epoch) - m ))
    [ "$age" -ge "$IDLE_SECS" ] || continue
    window=$(window_for_meta "$meta")
    [ -n "$window" ] || continue
    # Confirm the pane is readable. fm_pane_is_busy returns non-zero both for
    # "not busy" and unreadable panes, so capture a bounded peek first to avoid
    # reporting missing/dead tmux targets as idle work.
    FM_GUARD_STALL_CHECK=0 "$SCRIPT_DIR/fm-peek.sh" "$window" 40 >/dev/null 2>&1 || continue
    if ! fm_pane_is_busy "$window"; then
      printf 'stall?: %s - idle %ss, no status advance\n' "$id" "$age"
    fi
  done
}

check_advisor_idle_stalls() {
  local meta id kind status m age window home
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(kind_for_meta "$meta")
    [ "$kind" = secondmate ] || continue
    status="$STATE/$id.status"
    [ -f "$status" ] || continue
    advisor_terminal_status "$status" || continue
    m=$(stat_mtime "$status") || continue
    age=$(( $(now_epoch) - m ))
    [ "$age" -ge "$ADVISOR_IDLE_SECS" ] || continue
    window=$(window_for_meta "$meta")
    [ -n "$window" ] || continue
    home=$(home_for_secondmate_meta "$id" "$meta" || true)
    [ -n "$home" ] || continue
    secondmate_has_child_work "$home" && continue
    # Confirm the pane is readable before treating a non-busy result as idle.
    FM_GUARD_STALL_CHECK=0 "$SCRIPT_DIR/fm-peek.sh" "$window" 40 >/dev/null 2>&1 || continue
    if ! fm_pane_is_busy "$window"; then
      printf 'advisor-idle?: %s - idle %ss, no active child work, route its next program step or confirm intentionally parked\n' "$id" "$age"
    fi
  done
}

# True while a rebase is in progress in the worktree. .git is a pointer file in
# a worktree, so the rebase state dir is resolved via git rather than $wt/.git.
rebase_in_progress() { # <worktree>
  local wt=$1 d
  for d in rebase-merge rebase-apply; do
    local p
    p=$(git -C "$wt" rev-parse --git-path "$d" 2>/dev/null) || continue
    case "$p" in /*) : ;; *) p="$wt/$p" ;; esac
    [ -d "$p" ] && return 0
  done
  return 1
}

# Unlanded-work sweep. Flags an in-flight crew whose worktree HEAD carries
# commits reachable from no remote-tracking branch at all - committed work living
# only in a disposable worktree, which teardown would discard. This matches
# teardown's own landed-definition (git log HEAD --not --remotes): work reachable
# from ANY remote (origin, the no-mistakes gate remote during validation, or a
# contributor fork for upstream contributions) is teardown-safe and not flagged,
# which also removes any default-branch-name dependence. Local remote-tracking
# refs only (no network), so it is cheap enough to run on the fast path. It is a
# verify-candidate ("unlanded?:"): a squash-merged branch whose remote copy was
# deleted can also match, so the finding says push-it-or-confirm-merged rather
# than asserting loss.
check_unlanded_work() {
  local meta id kind wt unpushed
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(kind_for_meta "$meta")
    [ "$kind" = secondmate ] && continue
    [ "$kind" = scout ] && continue          # scout deliverable is the report, not a branch
    [ "$(mode_for_meta "$meta")" = local-only ] && continue  # no remote by design; landed = merged to local main, checked at teardown
    meta_has_pr "$id" && continue            # PR-parked: already tracked by the merge poll
    wt=$(worktree_for_meta "$meta")
    [ -n "$wt" ] || continue
    [ -d "$wt" ] || continue
    rebase_in_progress "$wt" && continue     # mid-rebase: HEAD is detached, branch temporarily empty
    unpushed=$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)
    [ "${unpushed:-0}" -gt 0 ] 2>/dev/null || continue
    printf 'unlanded?: %s - %s commit(s) not on any remote, lost on teardown; push it or confirm it is a merged branch\n' "$id" "$unpushed"
  done
}

# --fast skips checks that spawn a tmux peek per pane. fm-guard runs in this
# mode on the hot supervision path, where it only needs the presence of a
# finding from the cheap backlog/state reads; a full sweep (including the pane
# peeks) still runs at heartbeats and wakes.
FAST=false
case "${1:-}" in
  --fast) FAST=true ;;
esac

check_finished_not_advanced
check_unblocked_queued
check_date_gates
check_unlanded_work
if ! "$FAST"; then
  check_idle_stalls
  check_advisor_idle_stalls
fi
