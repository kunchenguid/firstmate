# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# True exactly when a firstmate home has in-flight work (a state/<id>.meta
# exists) but no watcher has a fresh liveness beacon (state/.last-watcher-beat,
# touched every poll cycle, within the grace window). bin/fm-guard.sh uses this
# grace-based warning predicate directly; bin/fm-turnend-guard.sh uses the status
# fields here for its banner but performs its end-of-turn block decision with the
# live watcher lock check in bin/fm-wake-lib.sh, plus the actionable-work
# predicate below for harnesses (Codex) with no persistent watcher between turns.

# shellcheck source=bin/fm-classify-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-classify-lib.sh"

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# Portable size:mtime signature - mirrors bin/fm-watch.sh's own stat_sig
# byte-for-byte, so a marker written by one is comparable against the other.
fm_sup_stat_sig() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%z:%Fm' "$1" 2>/dev/null
  else
    stat -c '%s:%Y' "$1" 2>/dev/null
  fi
}

fm_sup_path_age() {  # seconds since mtime; large sentinel if missing/unreadable
  local f=$1 m
  m=$(fm_sup_stat_mtime "$f") || { echo 999999; return; }
  [ -n "$m" ] || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly in the dangerous state: in-flight work exists and no
# watcher has a fresh beacon. Exit 1 (false) otherwise, including zero in-flight.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_IN_FLIGHT" -gt 0 ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}

# fm_supervision_actionable_status <state-dir> [grace-seconds]
# Populates:
#   FM_SUP_ACTIONABLE      count of state/*.meta entries that are genuinely
#                          actionable RIGHT NOW - i.e. worth forcing another
#                          live checkpoint over.
#   FM_SUP_ACTIONABLE_IDS  space-separated task ids counted actionable, plus
#                          the literal token "wake-queue" when an undrained
#                          wake queue alone forced the count - diagnostic only.
#
# Why this exists: FM_SUP_IN_FLIGHT (above) is a raw count of state/*.meta and
# says nothing about whether any of those tasks can actually progress. A
# harness with no persistent watcher between turns (Codex's bounded foreground
# checkpoint model - fm-watch-checkpoint.sh, docs/turnend-guard.md) re-runs
# fm_watcher_healthy on every single turn end, which is essentially always
# false for that model (the checkpoint's watcher lock releases the moment its
# bounded run ends), so FM_SUP_IN_FLIGHT alone forced a fresh checkpoint on
# every turn even when every direct report was done/idle/parked/blocked with
# nothing left to observe - a busy-loop of useless checkpoints. This predicate
# is the "is there actually something a checkpoint could still catch" gate
# fm-turnend-guard.sh applies before requiring one.
#
# A task counts as actionable when:
#   - its status file's content has not yet been through a watcher scan (its
#     current stat_sig differs from the state/.seen-<id>_status marker
#     bin/fm-watch.sh's scan_signals writes - the SAME marker convention, so a
#     transition already seen by one real checkpoint is not re-forced by the
#     next). This is what covers "newly unknown, needing reconciliation" - a
#     freshly spawned task with no status yet, and any status transition
#     (including a terminal one) that has not yet been through even one
#     watcher pass - AND what covers "actively working" the instant a crew
#     reports it, without waiting on the verb-based fallback below;
#   - once a status file HAS been seen, its last verb is `working` (still
#     self-reported active);
#   - once seen, its last verb is a declared `paused:` external wait that is
#     now DUE for recheck (status file age >= the pause resurface cadence,
#     the same FM_PAUSE_RESURFACE_SECS cadence fm-watch.sh's own
#     handle_paused_stale uses);
#   - once seen, its last verb is anything unrecognized (not one of
#     working/done/needs-decision/blocked/failed/paused/resolved) - fail-closed
#     on ambiguous data, matching "genuinely running agents still require
#     supervision".
#
# A task counts as NOT actionable when, once its current content has already
# been through a watcher scan:
#   - its last verb is done, failed, needs-decision, or blocked - a terminal or
#     captain-parked state that already got its one-time surface and will not
#     change without external action (a captain decision, a fresh spawn);
#   - its last verb is `paused:` and not yet due for recheck;
#   - its last verb is the decision-closing `resolved:` marker - not new work
#     on its own; the crew's next real transition arrives unseen and re-arms;
#   - kind=secondmate and it has NEVER written any status at all - the
#     documented idle-by-default healthy resting state (AGENTS.md section 7).
#
# A non-empty state/.wake-queue always counts as at least one actionable item
# on its own, regardless of any task classification: an undrained queued wake
# is durable work this predicate must never hide (wake durability is not
# weakened by this relaxation).
#
# This is a CHEAP, pure status-file/stat read: no pane capture, no backend
# call, no bin/fm-crew-state.sh invocation (which can shell out to
# no-mistakes per ship task) - the fast, fail-closed-on-ambiguity classification
# a supervisor can already see from the durable record, safe to run on every
# primary turn-end check across every harness.
fm_supervision_actionable_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}}
  local meta id kind status_file marker cur_sig seen_sig last verb age pause_secs
  FM_SUP_ACTIONABLE=0
  FM_SUP_ACTIONABLE_IDS=""

  if [ -s "$state/.wake-queue" ]; then
    FM_SUP_ACTIONABLE=$((FM_SUP_ACTIONABLE + 1))
    FM_SUP_ACTIONABLE_IDS="wake-queue"
  fi

  pause_secs=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
  case "$pause_secs" in ''|*[!0-9]*) pause_secs=$FM_PAUSE_RESURFACE_SECS_DEFAULT ;; esac

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    status_file="$state/$id.status"

    if [ -e "$status_file" ]; then
      marker="$state/.seen-$(basename "$status_file" | tr '.' '_')"
      cur_sig=$(fm_sup_stat_sig "$status_file")
      seen_sig=$(cat "$marker" 2>/dev/null || true)
      if [ -z "$cur_sig" ] || [ "$cur_sig" != "$seen_sig" ]; then
        FM_SUP_ACTIONABLE=$((FM_SUP_ACTIONABLE + 1))
        FM_SUP_ACTIONABLE_IDS="$FM_SUP_ACTIONABLE_IDS $id"
        continue
      fi
    elif [ "$kind" != secondmate ]; then
      # No status yet, and not the idle-by-default secondmate case: a freshly
      # spawned crewmate/scout has proven nothing yet.
      FM_SUP_ACTIONABLE=$((FM_SUP_ACTIONABLE + 1))
      FM_SUP_ACTIONABLE_IDS="$FM_SUP_ACTIONABLE_IDS $id"
      continue
    else
      # kind=secondmate, never any status: idle-by-default, not actionable.
      continue
    fi

    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    if status_is_paused "$last"; then
      age=$(fm_sup_path_age "$status_file")
      [ "$age" -lt "$pause_secs" ] && continue
    else
      case "$verb" in
        done|failed|needs-decision|blocked|resolved) continue ;;
      esac
    fi

    FM_SUP_ACTIONABLE=$((FM_SUP_ACTIONABLE + 1))
    FM_SUP_ACTIONABLE_IDS="$FM_SUP_ACTIONABLE_IDS $id"
  done

  FM_SUP_ACTIONABLE_IDS=${FM_SUP_ACTIONABLE_IDS# }
  return 0
}
