# shellcheck shell=bash
# Shared "supervision missing" predicate and the idle-capacity read behind it.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision. A home needs it because it
# has in-flight work (a state/<id>.meta exists), an X-mode relay poll
# (state/x-watch.check.sh), a registered process-to-event source, or ready
# backlog work it could dispatch into a free worktree slot right now. That last
# branch is what keeps an idle fleet supervised: without it a home with a full
# queue and empty pool got no watcher, no wake, and no turn.
# It also reports whether the watcher has a fresh liveness beacon
# (state/.last-watcher-beat, touched every poll cycle, within the grace window).
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.
#
# IDLE CAPACITY. fm_idle_capacity_report renders the operator-facing block and
# fm_idle_capacity_compute the fields behind it; both read `tasks-axi ready
# --include-held` for this home's backlog and `treehouse status` for each pool,
# and neither writes anything. This file is deliberately self-contained (several
# tests copy it alone into a fake home), so it shells out to those two tools
# rather than sourcing a backlog or path library. Every read fails SOFT: a
# missing, failing, or unparseable tool prints one WARN line, leaves the idle
# branch of the predicate false, and never blocks a turn end.
# state/.dispatch-freeze is the one silencing record. Line 1 is the captain's
# reason, line 2 a YYYY-MM-DD date it stops applying on. Only a captain
# instruction creates it; no script writes it. While it applies, the block
# prints FREEZE instead and the idle branch of the predicate stays false, so a
# frozen home is not forced to hold a watcher for work it was told not to
# dispatch. On and after the date, the record is ignored.
# HOLD_STALE. A hold with no `--until` date and no recheck event named in its
# reason is a decision nobody scheduled. tasks-axi records no hold timestamp, so
# its age is measured from the item's own recorded start date; that is the only
# field available and it over-reports rather than under-reports. The recheck-event
# test over the reason text is deliberately generous for the same reason: a hold
# that states any condition at all is left alone.
# PARSING. Only two columns of a held row are read, and both are read from the
# RIGHT, because a title or a hold reason may contain commas and quotes while
# `hold_until` and `created` are always a bare date or "-". That depends on
# `tasks-axi list --fields` emitting the requested extras in the order they were
# passed, which its own `tasks[N]{...}` header declares; a build that reorders
# them yields a non-date in the hold_until position, which reads as undated and
# is answered by the per-row `tasks-axi show` before anything is reported. Ready
# ids come from the FIRST column, which is an id and never quoted.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# --- idle capacity ----------------------------------------------------------
# Repo root of THIS file, used as the firstmate pool's own worktree root when a
# caller passes no root. Resolved once at source time so a caller's working
# directory cannot change which pool is read.
FM_IDLE_SELF_ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P) || FM_IDLE_SELF_ROOT=

# How many ready ids the block lists before disclosing the rest as a count.
FM_IDLE_ID_LIMIT=${FM_IDLE_ID_LIMIT:-10}

# Days since the civil epoch for a YYYY-MM-DD date, so two dates can be
# subtracted without GNU-only `date -d`. Howard Hinnant's days_from_civil.
fm_idle_days_from_civil() {  # <yyyy-mm-dd>
  local y m d era yoe doy doe
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  y=$((10#${1:0:4})); m=$((10#${1:5:2})); d=$((10#${1:8:2}))
  { [ "$m" -ge 1 ] && [ "$m" -le 12 ] && [ "$d" -ge 1 ] && [ "$d" -le 31 ]; } || return 1
  [ "$m" -le 2 ] && y=$((y - 1))
  era=$((y / 400))
  yoe=$((y - era * 400))
  if [ "$m" -gt 2 ]; then doy=$(((153 * (m - 3) + 2) / 5 + d - 1))
  else doy=$(((153 * (m + 9) + 2) / 5 + d - 1)); fi
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  printf '%s\n' $((era * 146097 + doe - 719468))
}

# Whole days between a recorded YYYY-MM-DD and today, or nothing when either
# date is unreadable. Local dates on both sides, so the comparison never drifts
# by a timezone.
fm_idle_days_since() {  # <yyyy-mm-dd>
  local was now
  was=$(fm_idle_days_from_civil "$1") || return 1
  now=$(fm_idle_days_from_civil "$(date +%Y-%m-%d)") || return 1
  printf '%s\n' $((now - was))
}

# The captain's silencing record, if it currently applies. Prints the FREEZE
# line and returns 0; returns 1 when absent, expired, or malformed, so an
# unreadable record can never hide idle capacity.
fm_idle_freeze_line() {  # <state-dir>
  local record="$1/.dispatch-freeze" reason until_date days
  [ -f "$record" ] || return 1
  IFS= read -r reason < "$record" || return 1
  until_date=$(sed -n '2p' "$record" 2>/dev/null)
  reason=${reason%$'\r'}; until_date=${until_date%$'\r'}
  [ -n "$reason" ] || return 1
  days=$(fm_idle_days_since "$until_date") || return 1
  [ "$days" -lt 0 ] || return 1
  printf 'FREEZE: %s until %s\n' "$reason" "$until_date"
}

# Free worktree slots across one pool. Prints an integer, or nothing when
# treehouse is absent or the pool cannot be read. A `dirty` worktree is NOT
# free: it holds uncommitted work firstmate may not discard.
fm_idle_pool_free() {  # <repo-root>
  local root=$1 out
  [ -n "$root" ] && [ -d "$root" ] || return 1
  command -v treehouse >/dev/null 2>&1 || return 1
  out=$(cd -- "$root" 2>/dev/null && treehouse status 2>/dev/null) || return 1
  printf '%s\n' "$out" | awk '
    /^[^[:space:]]/ && $2 == "available" { n++ }
    END { print n + 0 }'
}

# Every worktree root this home can dispatch into: each registered project's
# repository plus firstmate itself. Canonicalized and deduplicated, because two
# registry entries naming one repository - or a project registered at the
# firstmate root itself - would otherwise have their pool counted twice and
# report free slots this home does not have.
fm_idle_pool_roots() {  # <data-dir> <root>
  local data=$1 root=$2 registry="$1/projects.md" line canonical seen=''
  {
    [ -n "$root" ] && printf '%s\n' "$root"
    [ -f "$registry" ] && sed -n 's/^[^:]*repository: \([^ ][^ ]*\).*/\1/p' \
      "$registry" 2>/dev/null
  } | while IFS= read -r line; do
    [ -n "$line" ] || continue
    canonical=$(CDPATH='' cd -- "$line" 2>/dev/null && pwd -P) || canonical=$line
    case "$seen" in *"|$canonical|"*) continue ;; esac
    seen="$seen|$canonical|"
    printf '%s\n' "$canonical"
  done
}

# Does a hold reason name a recheck event? Generous by design (see the header):
# any stated condition counts, so only a hold with no condition at all is named.
fm_idle_reason_names_event() {  # <reason>
  local lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *recheck*|*"when "*|*"until "*|*"after "*|*"once "*|*"blocked by"*) return 0 ;;
  esac
  return 1
}

# Populate the idle-capacity fields for one home. Never prints, never writes.
#   FM_IDLE_READY   ready (dispatchable now) item count
#   FM_IDLE_HELD    held item count
#   FM_IDLE_FREE    free worktree slots, or -1 when the pools cannot be read
#   FM_IDLE_LIVE    tasks in flight in this home
#   FM_IDLE_IDS     ready ids, newline separated
#   FM_IDLE_STALE   "<id> <age>" lines for holds with neither date nor event
#   FM_IDLE_FREEZE  the FREEZE line when the captain's record applies
#   FM_IDLE_WARN    one line naming the tool that could not be read
#   FM_IDLE_READY_READ  true only when the ready listing itself was read; a
#                   caller with its own fallback wording branches on this rather
#                   than on FM_IDLE_WARN, which also fires for a pool that could
#                   not be read while the backlog read succeeded
#   FM_IDLE_CAPACITY  true only when ready work exists with a free slot and no
#                     freeze applies - the idle branch of the predicate
fm_idle_capacity_compute() {  # <state-dir> [data-dir] [root]
  local state=$1 data=${2:-} root=${3:-$FM_IDLE_SELF_ROOT}
  local backlog ready_out held_out meta pool free total unread row id until_date reason days
  FM_IDLE_READY=0; FM_IDLE_HELD=0; FM_IDLE_FREE=-1; FM_IDLE_LIVE=0
  FM_IDLE_IDS=''; FM_IDLE_STALE=''; FM_IDLE_FREEZE=''; FM_IDLE_WARN=''
  FM_IDLE_CAPACITY=false
  FM_IDLE_READY_READ=false
  FM_IDLE_DATA=''


  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_IDLE_LIVE=$((FM_IDLE_LIVE + 1))
  done

  [ -n "$data" ] || data=$(dirname -- "$state")/data
  FM_IDLE_DATA=$data
  backlog="$data/backlog.md"
  [ -f "$backlog" ] || return 0
  if ! command -v tasks-axi >/dev/null 2>&1; then
    FM_IDLE_WARN='IDLE CAPACITY WARN: tasks-axi is not installed, so ready work could not be read.'
    return 0
  fi
  if ! ready_out=$(tasks-axi ready --file "$backlog" --include-held 2>/dev/null); then
    FM_IDLE_WARN='IDLE CAPACITY WARN: tasks-axi could not read this home backlog, so ready work is unknown.'
    return 0
  fi
  # shellcheck disable=SC2034 # Read by callers (fm-teardown.sh) after sourcing.
  FM_IDLE_READY_READ=true

  FM_IDLE_READY=$(printf '%s\n' "$ready_out" | sed -n 's/^ready\[\([0-9][0-9]*\)\].*/\1/p' | head -1)
  FM_IDLE_HELD=$(printf '%s\n' "$ready_out" | sed -n 's/^held\[\([0-9][0-9]*\)\].*/\1/p' | head -1)
  [ -n "$FM_IDLE_READY" ] || FM_IDLE_READY=0
  [ -n "$FM_IDLE_HELD" ] || FM_IDLE_HELD=0
  # The id is the first column of each indented row under the ready header and
  # never contains a comma or a quote, so only that column is parsed here.
  FM_IDLE_IDS=$(printf '%s\n' "$ready_out" | awk '
    /^ready\[/ { rows = 1; next }
    /^[^[:space:]]/ { rows = 0 }
    rows && /^[[:space:]]/ { sub(/^[[:space:]]+/, ""); sub(/,.*/, ""); if ($0 != "") print }')

  FM_IDLE_FREEZE=$(fm_idle_freeze_line "$state") || FM_IDLE_FREEZE=''

  if [ "$FM_IDLE_HELD" -gt 0 ]; then
    # hold_until and created are date-or-"-" columns with no comma or quote, so
    # the two rightmost columns are read from the right and the id from the left.
    if held_out=$(tasks-axi list --file "$backlog" --state held --fields hold_until,created 2>/dev/null); then
      while IFS= read -r row; do
        [ -n "$row" ] || continue
        id=${row%%,*}
        days=${row##*,}
        until_date=${row%,*}; until_date=${until_date##*,}
        case "$until_date" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) continue ;; esac
        days=$(fm_idle_days_since "$days") || continue
        [ "$days" -ge 1 ] || continue
        reason=$(tasks-axi show "$id" --file "$backlog" --full 2>/dev/null |
          sed -n 's/^[[:space:]]*hold_reason:[[:space:]]*//p' | head -1)
        reason=${reason#\"}; reason=${reason%\"}
        fm_idle_reason_names_event "$reason" && continue
        FM_IDLE_STALE="${FM_IDLE_STALE}HOLD_STALE: $id ${days}d"$'\n'
      done < <(printf '%s\n' "$held_out" | awk '
        /^tasks\[/ { rows = 1; next }
        /^[^[:space:]]/ { rows = 0 }
        rows && /^[[:space:]]/ { sub(/^[[:space:]]+/, ""); print }')
    else
      FM_IDLE_WARN='IDLE CAPACITY WARN: held rows could not be read, so stale holds are unknown.'
    fi
  fi

  [ "$FM_IDLE_READY" -gt 0 ] || return 0

  total=''
  unread=0
  while IFS= read -r pool; do
    [ -n "$pool" ] || continue
    if free=$(fm_idle_pool_free "$pool"); then
      total=$((${total:-0} + free))
    else
      unread=$((unread + 1))
    fi
  done < <(fm_idle_pool_roots "$data" "$root")
  # A pool that could not be read is never treated as zero free slots. Summing
  # only the readable ones would report a confident free_slots too low to fire
  # the line, which is the exact failure this whole report exists to prevent.
  if [ -z "$total" ] || [ "$unread" -gt 0 ]; then
    [ -n "$FM_IDLE_WARN" ] || FM_IDLE_WARN="IDLE CAPACITY WARN: $unread worktree pool(s) could not be read, so free slots are unknown."
    [ -n "$total" ] || FM_IDLE_WARN='IDLE CAPACITY WARN: no worktree pool could be read, so free slots are unknown.'
    return 0
  fi
  FM_IDLE_FREE=$total
  [ "$FM_IDLE_FREE" -gt 0 ] || return 0
  [ -z "$FM_IDLE_FREEZE" ] || return 0
  FM_IDLE_CAPACITY=true
  return 0
}

# Render the block from the fields fm_idle_capacity_compute already populated.
# Split from the report below so a caller that must branch on the compute result
# first - bin/fm-teardown.sh keeps its own wording when the backlog is
# unreadable - renders without paying for a second backlog read.
# Prints nothing when there is neither ready work nor a hold to reconcile.
# Always returns 0: this is a report, never a gate.
fm_idle_capacity_render() {
  local data=$FM_IDLE_DATA shown=0 id
  [ -z "$FM_IDLE_WARN" ] || printf '%s\n' "$FM_IDLE_WARN"
  if [ -n "$FM_IDLE_FREEZE" ]; then
    printf '%s\n' "$FM_IDLE_FREEZE"
    return 0
  fi
  if [ "$FM_IDLE_READY" -eq 0 ]; then
    [ "$FM_IDLE_HELD" -gt 0 ] && printf 'FRONTIER EMPTY, HELD=%s\n' "$FM_IDLE_HELD"
  elif [ "$FM_IDLE_FREE" -ge 0 ]; then
    printf 'IDLE CAPACITY: ready=%s held=%s free_slots=%s live=%s\n' \
      "$FM_IDLE_READY" "$FM_IDLE_HELD" "$FM_IDLE_FREE" "$FM_IDLE_LIVE"
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      if [ "$shown" -ge "$FM_IDLE_ID_LIMIT" ]; then
        printf '  (%s more ready - tasks-axi ready --file %s)\n' \
          "$((FM_IDLE_READY - shown))" "$data/backlog.md"
        break
      fi
      printf '  %s\n' "$id"
      shown=$((shown + 1))
    done <<< "$FM_IDLE_IDS"
    printf '  dispatch, hold with a due date or recheck event, or record the exact blocking rule on the item\n'
  fi
  [ -z "$FM_IDLE_STALE" ] || printf '%s' "$FM_IDLE_STALE"
  return 0
}

# Compute and render in one call: the form every site uses that has no branch of
# its own to take between the two halves.
fm_idle_capacity_report() {  # <state-dir> [data-dir] [root]
  fm_idle_capacity_compute "$@"
  fm_idle_capacity_render
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata),
#                         or ready backlog work with a free worktree slot
#   FM_SUP_IDLE_CAPACITY  true/false - the idle branch alone carried FM_SUP_NEEDED
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# data-dir defaults to the state directory's sibling and root to this file's own
# repo, so no existing caller changes; both feed the idle branch only.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} data=${3:-} root=${4:-}
  local meta source beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_IDLE_CAPACITY=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  FM_SUP_SOURCES=0
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
  done
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ -f "$state/x-watch.check.sh" ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ]; then
    FM_SUP_NEEDED=true
  else
    # Only reached when the cheap records say this home is idle, so the two
    # subprocess reads behind the idle branch are never paid by a busy fleet.
    fm_idle_capacity_compute "$state" "$data" "${root:-$FM_IDLE_SELF_ROOT}"
    if [ "$FM_IDLE_CAPACITY" = true ]; then
      # shellcheck disable=SC2034 # Read by callers (fm-turnend-guard.sh) after sourcing.
      FM_SUP_IDLE_CAPACITY=true
      FM_SUP_NEEDED=true
    fi
  fi

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

# fm_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the home needs a watcher.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
