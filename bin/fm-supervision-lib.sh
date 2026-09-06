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
# --include-held` for this home's backlog and `treehouse status` for each
# project's OWN pool, and neither writes anything. This file is deliberately
# self-contained (several tests copy it alone into a fake home), so it shells
# out to those two tools rather than sourcing a backlog or path library. Every
# read fails SOFT: a missing, failing, or unparseable tool prints one WARN
# line, leaves the idle branch of the predicate false, and never blocks a turn
# end.
# PER-PROJECT POOLS. A ready item's `repo` field ("-" for a firstmate item)
# names ITS OWN project; fm_idle_project_root resolves that name to a pool root
# through data/projects.md, never through any other project's registry entry.
# Free slots are computed and reported per project, never summed across
# projects: a firstmate worktree slot cannot host a project's task and vice
# versa, so a single combined total was always wrong once more than one
# project had ready work. One project's pool being unreadable or unregistered
# reports "unknown" for that project alone and never hides, zeroes, or blocks a
# sibling project's own resolved count.
# CONCURRENCY CAP. config/concurrency-cap (a bare integer, default 13) bounds
# how many workers this home runs at once regardless of any project's free
# slots; at or over the cap, FM_IDLE_AT_CAP is true and the report has no idle
# work to propose dispatching right now.
# LANE FLOOR. config/lane-floor (a bare integer, default 10) is the captain's
# standing floor on how many lanes this home keeps running while work exists.
# fm_lane_floor_report renders its breach and fm_dispatchable_work enumerates
# the work behind it; see the LANE FLOOR section below for why that enumeration
# is deliberately broader than the idle-capacity read above.
# state/.dispatch-freeze is the captain's own silencing record. Line 1 is the
# reason, line 2 a YYYY-MM-DD date it stops applying on. Only a captain
# instruction creates it; no script writes it. While it applies, the block
# prints FREEZE instead and FM_IDLE_CAPACITY (the dispatch-now branch) stays
# false, so a frozen home is not forced to dispatch work it was told to hold.
# fm_supervision_status still treats a freeze with ready work as needing a
# watcher (FM_SUP_NEEDED true, FM_SUP_IDLE_CAPACITY false): the freeze silences
# the escalation, not the fleet's only chance to notice when it expires. On and
# after the until date, the record is ignored entirely.
# HOLD_STALE and HOLD_DUE. A hold with no `--until` date and no recheck event
# named in its reason is a decision nobody scheduled; tasks-axi records no hold
# timestamp, so its age is measured from the item's own recorded start date -
# the only field available, and one that over-reports rather than under-reports.
# The recheck-event test over the reason text is deliberately generous for the
# same reason: a hold that states any condition at all is left alone. A DATED
# hold whose `--until` has already passed is reported as HOLD_DUE instead of
# being silently skipped just because it carries a date at all - a captain call
# that has come due needs the same attention as one nobody scheduled.
# HELD ON CAPACITY ONLY. A hold filed --kind load, or whose reason names a
# capacity/slot phrase (fm_idle_reason_is_capacity_phrase: "capacity" or "slot
# frees"), sitting in front of a free slot in its own project's pool, is an
# idle slot in disguise: the captain's rule is that dispatchable capacity never
# sits unused while ready-shaped work is only held because a slot was scarce
# at hold time. This never releases the hold - it only reports it, in its own
# "IDLE CAPACITY: N item(s) held on capacity only ..." line, and folds into the
# same escalation dedupe as the ready-work line so it nags once per unchanged
# state rather than once per poll.
# PARSING. Ready rows read `id` and `repo` from the LEFT (columns one and four
# of `tasks-axi ready`'s own declared `id,state,kind,repo,title` header); only
# the trailing `title` is free text, so both are safe regardless of it. Held
# rows read `hold_until` and `created` from the RIGHT, because a title or a
# hold reason may contain commas and quotes while those two columns are always
# a bare date or "-". That depends on `tasks-axi list --fields` emitting the
# requested extras in the order they were passed, which its own
# `tasks[N]{...}` header declares; a build that reorders them yields a
# non-date in the hold_until position, which reads as undated and is answered
# by the per-row `tasks-axi show` before anything is reported.

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

# Does a hold reason use one of the phrasings firstmate itself writes when a
# hold exists only to wait for a free worktree slot ("pool capacity: dispatch
# when a slot frees ... recheck daily")? Used alongside --kind load below so a
# capacity hold filed under the wrong kind is still caught.
fm_idle_reason_is_capacity_phrase() {  # <reason>
  local lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *capacity*|*"slot frees"*) return 0 ;;
  esac
  return 1
}

# Resolve one project's own worktree pool root, so a ready item is weighed
# only against ITS project's free slots, never a sibling's. "-"/empty is a
# firstmate item: its pool is this home's own root, no registry lookup. A
# named project resolves through the first data/projects.md entry whose name
# ($2, the same key fm-project-mode.sh keys mode lookups on) matches, reading
# the "repository:" token off that same line. Echoes nothing and returns 1
# when the project has no such entry, or the registry itself is absent -
# never a guessed path.
fm_idle_project_root() {  # <data-dir> <root> <project-label>
  local data=$1 root=$2 project=$3 registry="$1/projects.md" hit
  if [ -z "$project" ] || [ "$project" = '-' ]; then
    [ -n "$root" ] && [ -d "$root" ] || return 1
    printf '%s\n' "$root"
    return 0
  fi
  [ -f "$registry" ] || return 1
  hit=$(awk -v n="$project" '
    $1 == "-" && $2 == n {
      if (match($0, /repository: [^ ]+/)) {
        print substr($0, RSTART + 12, RLENGTH - 12)
        exit
      }
    }
  ' "$registry" 2>/dev/null)
  [ -n "$hit" ] || return 1
  printf '%s\n' "$hit"
}

# The ceiling on concurrent workers in this home, or the default when the file
# is absent, unreadable, or not a bare integer. The one owner of that read:
# both the idle-capacity block and the lane floor below weigh work against it.
FM_CONCURRENCY_CAP_DEFAULT=13
fm_concurrency_cap_value() {  # [config-dir]
  local config=${1:-} cap=$FM_CONCURRENCY_CAP_DEFAULT
  if [ -n "$config" ] && [ -f "$config/concurrency-cap" ]; then
    IFS= read -r cap < "$config/concurrency-cap" 2>/dev/null || cap=$FM_CONCURRENCY_CAP_DEFAULT
    cap=${cap%$'\r'}
    case "$cap" in ''|*[!0-9]*) cap=$FM_CONCURRENCY_CAP_DEFAULT ;; esac
  fi
  printf '%s\n' "$cap"
}

# Populate the idle-capacity fields for one home. Never prints, never writes.
#   FM_IDLE_READY   ready (dispatchable now) item count, across every project
#   FM_IDLE_HELD    held item count
#   FM_IDLE_LIVE    tasks in flight in this home
#   FM_IDLE_IDS     ready ids, newline separated
#   FM_IDLE_PROJECTS  one "<label>\t<ready>\t<free-or-unknown>" line per
#                   distinct project referenced by ready work, in first-seen
#                   order; label "-" is this home's own (firstmate) pool. A
#                   ready item counts only against free slots in ITS OWN
#                   project's pool - never a sibling's, and never a project
#                   with no ready work of its own.
#   FM_IDLE_STALE   "<id> <age>d" HOLD_STALE lines for holds with neither date
#                   nor event, and "<id> <age>d overdue" HOLD_DUE lines for
#                   holds whose --until date has already passed
#   FM_IDLE_CAPACITY_HELD  one "<repo>\t<id>\t<free>" line per held item whose
#                   hold is --kind load, or whose reason names a capacity/slot
#                   phrase (fm_idle_reason_is_capacity_phrase), sitting in
#                   front of a free slot in ITS OWN project's pool. Never a
#                   hold is released automatically - this only surfaces it.
#                   Independent of FM_IDLE_READY, since the whole point is a
#                   queue that is entirely held still reports free capacity;
#                   left empty while at cap or frozen, since there is nothing
#                   to dispatch into either way
#   FM_IDLE_FREEZE  the FREEZE line when the captain's record applies
#   FM_IDLE_WARN    one line naming a tool that could not be read at all
#                   (tasks-axi itself, or the backlog); one unresolvable
#                   PROJECT pool is reported per-project in FM_IDLE_PROJECTS
#                   as "unknown" instead, so a bad or unregistered project
#                   never hides a healthy sibling's own count
#   FM_IDLE_READY_READ  true only when the ready listing itself was read; a
#                   caller with its own fallback wording branches on this rather
#                   than on FM_IDLE_WARN, which also fires when the backlog read
#                   itself failed
#   FM_IDLE_AT_CAP  true when this home's live worker count is already at or
#                   over config/concurrency-cap (default 13) - dispatching more
#                   work right now is not an option regardless of free slots
#   FM_IDLE_CAPACITY  true only when some project has ready work with a free
#                     slot in that SAME project's pool, this home is under its
#                     concurrency cap, and no freeze applies - the idle branch
#                     of the predicate
fm_idle_capacity_compute() {  # <state-dir> [data-dir] [root] [config-dir]
  local state=$1 data=${2:-} root=${3:-$FM_IDLE_SELF_ROOT} config=${4:-}
  local backlog ready_out held_out due_out meta row id until_date reason days due_days
  local cap project_ready_lines label ready_n project_root free
  local repo hold_kind is_capacity
  FM_IDLE_READY=0; FM_IDLE_HELD=0; FM_IDLE_LIVE=0
  FM_IDLE_IDS=''; FM_IDLE_STALE=''; FM_IDLE_FREEZE=''; FM_IDLE_WARN=''
  FM_IDLE_PROJECTS=''
  FM_IDLE_CAPACITY_HELD=''
  FM_IDLE_AT_CAP=false
  FM_IDLE_CAPACITY=false
  FM_IDLE_READY_READ=false
  FM_IDLE_DATA=''


  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_IDLE_LIVE=$((FM_IDLE_LIVE + 1))
  done

  [ -n "$data" ] || data=$(dirname -- "$state")/data
  [ -n "$config" ] || config=$(dirname -- "$state")/config
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
  # Ready rows are "id,state,kind,repo,title" (tasks-axi ready's own header
  # declares the order); only title is free text, so id (leftmost) and repo
  # (fourth column) are both safe to read positionally regardless of it.
  FM_IDLE_IDS=$(printf '%s\n' "$ready_out" | awk -F',' '
    /^ready\[/ { rows = 1; next }
    /^[^[:space:]]/ { rows = 0 }
    rows && /^[[:space:]]/ { sub(/^[[:space:]]+/, ""); if ($1 != "") print $1 }')

  FM_IDLE_FREEZE=$(fm_idle_freeze_line "$state") || FM_IDLE_FREEZE=''

  cap=$(fm_concurrency_cap_value "$config")
  [ "$FM_IDLE_LIVE" -lt "$cap" ] || FM_IDLE_AT_CAP=true

  if [ "$FM_IDLE_HELD" -gt 0 ]; then
    # hold_until and created are date-or-"-" columns with no comma or quote, so
    # the two rightmost columns are read from the right and the id from the left.
    # tasks-axi's own held listing already excludes any row whose hold_until
    # has passed (it reads as resumed, not held, from the moment its own due
    # date arrives) - so every dated row seen here is still-future and correctly
    # left alone; only an undated row can ever be stale in this listing.
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

  # Held-on-capacity-only items: a hold filed --kind load, or one whose reason
  # names a capacity/slot phrase, sitting in front of a free slot in its OWN
  # project's pool. Independent of FM_IDLE_READY (these items are held, not
  # ready, so a fully-held queue must still surface them) and skipped outright
  # while at cap or frozen, since there is nothing to dispatch into either way.
  # held[ rows are "id,state,kind,repo,title,hold_reason,hold_kind,hold_until"
  # (tasks-axi ready --include-held's own declared header). id (leftmost) and
  # repo (fourth column, reached by stripping id/state/kind off the front) are
  # both safe positionally because state and kind never contain commas; hold_kind
  # is read by stripping hold_until (the true last field) off the END of the row
  # first, for the same reason PARSING above reads hold_until/created that way -
  # immune to a comma inside title or hold_reason, the two free-text fields in
  # between, because suffix removal is anchored to the actual end of the string
  # rather than a counted field.
  if [ "$FM_IDLE_HELD" -gt 0 ] && [ "$FM_IDLE_AT_CAP" != true ] && [ -z "$FM_IDLE_FREEZE" ]; then
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      id=${row%%,*}
      repo=${row#*,}; repo=${repo#*,}; repo=${repo#*,}; repo=${repo%%,*}
      repo=${repo#\"}; repo=${repo%\"}
      hold_kind=${row%,*}; hold_kind=${hold_kind##*,}
      hold_kind=${hold_kind#\"}; hold_kind=${hold_kind%\"}
      is_capacity=false
      [ "$hold_kind" = load ] && is_capacity=true
      if [ "$is_capacity" != true ]; then
        reason=$(tasks-axi show "$id" --file "$backlog" --full 2>/dev/null |
          sed -n 's/^[[:space:]]*hold_reason:[[:space:]]*//p' | head -1)
        reason=${reason#\"}; reason=${reason%\"}
        fm_idle_reason_is_capacity_phrase "$reason" && is_capacity=true
      fi
      [ "$is_capacity" = true ] || continue
      project_root=$(fm_idle_project_root "$data" "$root" "$repo") || continue
      free=$(fm_idle_pool_free "$project_root") || continue
      case "$free" in ''|*[!0-9]*) continue ;; esac
      [ "$free" -gt 0 ] || continue
      FM_IDLE_CAPACITY_HELD="${FM_IDLE_CAPACITY_HELD}${repo}$(printf '\t')${id}$(printf '\t')${free}"$'\n'
    done < <(printf '%s\n' "$ready_out" | awk '
      /^held\[/ { rows = 1; next }
      /^[^[:space:]]/ { rows = 0 }
      rows && /^[[:space:]]/ { sub(/^[[:space:]]+/, ""); print }')
  fi

  [ "$FM_IDLE_READY" -gt 0 ] || return 0

  # A hold whose --until date has arrived reads as resumed (queued, not held)
  # from that moment on - tasks-axi's own dynamic read, not this file's doing -
  # but the hold_reason/hold_kind/hold_until it carried are left on the row.
  # Scan the queued listing itself for that residue, or a due hold would go
  # from "captain hasn't ruled" straight to invisible, ordinary ready work with
  # nobody ever told the captain's own recheck date had arrived.
  if due_out=$(tasks-axi list --file "$backlog" --state queued --fields hold_until,created 2>/dev/null); then
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      id=${row%%,*}
      until_date=${row%,*}; until_date=${until_date##*,}
      case "$until_date" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) continue ;; esac
      due_days=$(fm_idle_days_since "$until_date") || continue
      [ "$due_days" -ge 0 ] || continue
      FM_IDLE_STALE="${FM_IDLE_STALE}HOLD_DUE: $id ${due_days}d overdue"$'\n'
    done < <(printf '%s\n' "$due_out" | awk '
      /^tasks\[/ { rows = 1; next }
      /^[^[:space:]]/ { rows = 0 }
      rows && /^[[:space:]]/ { sub(/^[[:space:]]+/, ""); print }')
  else
    [ -n "$FM_IDLE_WARN" ] || FM_IDLE_WARN='IDLE CAPACITY WARN: queued rows could not be read, so due holds are unknown.'
  fi

  # One "<label>\tready=<n>" per distinct project referenced by a ready item,
  # first-seen order, from a single awk pass over the same rows FM_IDLE_IDS
  # read. repo ("-" for a firstmate item) arrives quoted only when it is the
  # bare literal "-"; gsub strips that so "-" compares equal either way.
  project_ready_lines=$(printf '%s\n' "$ready_out" | awk -F',' '
    /^ready\[/ { rows = 1; next }
    /^[^[:space:]]/ { rows = 0 }
    rows && /^[[:space:]]/ {
      sub(/^[[:space:]]+/, "")
      repo = $4
      gsub(/^"|"$/, "", repo)
      if (!(repo in seen)) { order[++n] = repo; seen[repo] = 1 }
      count[repo]++
    }
    END { for (i = 1; i <= n; i++) print order[i] "\t" count[order[i]] }')

  while IFS="$(printf '\t')" read -r label ready_n; do
    [ -n "$label" ] || continue
    if ! project_root=$(fm_idle_project_root "$data" "$root" "$label"); then
      free=unknown
      if [ "$label" = '-' ]; then
        [ -n "$FM_IDLE_WARN" ] || FM_IDLE_WARN='IDLE CAPACITY WARN: this home'"'"'s own pool could not be read, so its free slots are unknown.'
      else
        [ -n "$FM_IDLE_WARN" ] || FM_IDLE_WARN="IDLE CAPACITY WARN: no pool is registered for project $label, so its free slots are unknown."
      fi
    elif free=$(fm_idle_pool_free "$project_root"); then
      :
    else
      free=unknown
      if [ "$label" = '-' ]; then
        [ -n "$FM_IDLE_WARN" ] || FM_IDLE_WARN='IDLE CAPACITY WARN: this home'"'"'s own pool could not be read, so its free slots are unknown.'
      else
        [ -n "$FM_IDLE_WARN" ] || FM_IDLE_WARN="IDLE CAPACITY WARN: the pool for project $label could not be read, so its free slots are unknown."
      fi
    fi
    FM_IDLE_PROJECTS="${FM_IDLE_PROJECTS}${label}$(printf '\t')${ready_n}$(printf '\t')${free}"$'\n'
  done <<< "$project_ready_lines"

  if [ "$FM_IDLE_AT_CAP" = true ] || [ -n "$FM_IDLE_FREEZE" ]; then
    return 0
  fi
  while IFS="$(printf '\t')" read -r label ready_n free; do
    [ -n "$label" ] || continue
    [ "$free" != unknown ] || continue
    if [ "$ready_n" -le 0 ] || [ "$free" -le 0 ]; then
      continue
    fi
    FM_IDLE_CAPACITY=true
    break
  done <<< "$FM_IDLE_PROJECTS"
  return 0
}

# Render the block from the fields fm_idle_capacity_compute already populated.
# Split from the report below so a caller that must branch on the compute result
# first - bin/fm-teardown.sh keeps its own wording when the backlog is
# unreadable - renders without paying for a second backlog read.
# Prints nothing when there is neither ready work nor a hold to reconcile, and
# nothing beyond WARN/STALE when this home is already at its concurrency cap -
# dispatching more work is not on the table regardless of any project's free
# slots, so there is no ready-work line to show.
# The single-project case keeps the exact legacy "IDLE CAPACITY: ready=N
# held=M free_slots=K live=L" line several call sites assert verbatim; a
# second project adds its own indented "<label>: ready=N free_slots=K" line
# instead of trying to force multiple pools into that one free_slots number.
# show-idle (default true) omits just the IDLE CAPACITY block - the header, any
# per-project lines, the ready ids, the disposition line, and the held-on-
# capacity line below - while WARN, FRONTIER EMPTY, and STALE/DUE lines still
# print regardless; a push-escalating caller passes false once
# fm_idle_capacity_should_escalate below says this exact (ready ids, free
# counts, capacity-held ids) tuple already escalated.
# Always returns 0: this is a report, never a gate.
# shellcheck disable=SC2120 # show-idle is optional; every existing caller
# correctly omits it and gets the default true (full render, unchanged).
fm_idle_capacity_render() {  # [show-idle]
  local show_idle=${1:-true}
  local data=$FM_IDLE_DATA shown=0 id project_count label ready_n free_n
  local held_block=''
  [ -z "$FM_IDLE_WARN" ] || printf '%s\n' "$FM_IDLE_WARN"
  if [ -n "$FM_IDLE_FREEZE" ]; then
    printf '%s\n' "$FM_IDLE_FREEZE"
    return 0
  fi

  # FM_IDLE_CAPACITY_HELD rows are "<repo>\t<id>\t<free>"; group into one line
  # per project so one pool's free count is never presented as if it covered a
  # sibling's own capacity holds. Never set while at cap or frozen (the compute
  # step already leaves it empty then), matching "silent when no slots are free".
  if [ "$show_idle" = true ] && [ -n "$FM_IDLE_CAPACITY_HELD" ]; then
    held_block=$(printf '%s\n' "$FM_IDLE_CAPACITY_HELD" | awk -F'\t' '
      NF >= 3 {
        if (!(($1) in seen)) { order[++n] = $1; seen[$1] = 1 }
        free[$1] = $3
        ids[$1] = ids[$1] $2 " "
        count[$1]++
      }
      END {
        for (i = 1; i <= n; i++) {
          label = order[i]
          idlist = ids[label]
          sub(/ $/, "", idlist)
          printf "IDLE CAPACITY: %s item(s) held on capacity only while %s slot(s) are free: %s\n", count[label], free[label], idlist
        }
      }')
  fi
  [ -z "$held_block" ] || printf '%s\n' "$held_block"

  if [ "$FM_IDLE_READY" -eq 0 ]; then
    [ "$FM_IDLE_HELD" -gt 0 ] && printf 'FRONTIER EMPTY, HELD=%s\n' "$FM_IDLE_HELD"
    [ -z "$FM_IDLE_STALE" ] || printf '%s' "$FM_IDLE_STALE"
    return 0
  fi
  if [ "$FM_IDLE_AT_CAP" = true ]; then
    [ -z "$FM_IDLE_STALE" ] || printf '%s' "$FM_IDLE_STALE"
    return 0
  fi
  if [ "$show_idle" != true ]; then
    [ -z "$FM_IDLE_STALE" ] || printf '%s' "$FM_IDLE_STALE"
    return 0
  fi

  project_count=$(printf '%s\n' "$FM_IDLE_PROJECTS" | sed '/^$/d' | wc -l | tr -d '[:space:]')

  if [ "${project_count:-0}" -le 1 ]; then
    IFS="$(printf '\t')" read -r label ready_n free_n <<< "$FM_IDLE_PROJECTS"
    if [ "${free_n:-unknown}" != unknown ]; then
      printf 'IDLE CAPACITY: ready=%s held=%s free_slots=%s live=%s\n' \
        "$FM_IDLE_READY" "$FM_IDLE_HELD" "$free_n" "$FM_IDLE_LIVE"
    fi
  else
    printf 'IDLE CAPACITY: ready=%s held=%s live=%s\n' \
      "$FM_IDLE_READY" "$FM_IDLE_HELD" "$FM_IDLE_LIVE"
    while IFS="$(printf '\t')" read -r label ready_n free_n; do
      [ -n "$label" ] || continue
      printf '  %s: ready=%s free_slots=%s\n' "$label" "$ready_n" "$free_n"
    done <<< "$FM_IDLE_PROJECTS"
  fi

  if [ "${project_count:-0}" -le 1 ] && [ "${free_n:-unknown}" = unknown ]; then
    [ -z "$FM_IDLE_STALE" ] || printf '%s' "$FM_IDLE_STALE"
    return 0
  fi

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
  [ -z "$FM_IDLE_STALE" ] || printf '%s' "$FM_IDLE_STALE"
  return 0
}

# Compute and render in one call: the form every site uses that has no branch of
# its own to take between the two halves.
fm_idle_capacity_report() {  # <state-dir> [data-dir] [root] [config-dir]
  fm_idle_capacity_compute "$@"
  fm_idle_capacity_render
}

# A deterministic one-line signature of the CURRENT (ready ids, per-project
# free counts, capacity-held ids) tuple, from the fields
# fm_idle_capacity_compute already populated. Two calls with the same ready
# work, the same free slots, and the same capacity-held ids always produce the
# same signature, regardless of WARN or STALE/DUE noise around it.
fm_idle_capacity_signature() {
  printf '%s|%s|%s' "$FM_IDLE_IDS" "$FM_IDLE_PROJECTS" "$FM_IDLE_CAPACITY_HELD" | tr '\n\t' ';:'
}

# fm_idle_capacity_should_escalate <state-dir>
# True only when FM_IDLE_CAPACITY is true OR some item is held on capacity
# alone with a free slot (FM_IDLE_CAPACITY_HELD non-empty), AND its (ready ids,
# free counts, capacity-held ids) tuple differs from the last one this state
# dir actually escalated - so a daemon polling every heartbeat nags once per
# real change, never once per poll. Call after fm_idle_capacity_compute. Never
# writes the marker itself: a caller must call fm_idle_capacity_mark_escalated
# only once the escalation it gates has actually landed (e.g. after
# fm_wake_append succeeds), or a failed escalation would be recorded as
# delivered and never retried.
fm_idle_capacity_should_escalate() {  # <state-dir>
  local state=$1 marker="$1/.idle-capacity-last-escalated" sig
  { [ "$FM_IDLE_CAPACITY" = true ] || [ -n "$FM_IDLE_CAPACITY_HELD" ]; } || return 1
  sig=$(fm_idle_capacity_signature)
  [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$sig" ] && return 1
  return 0
}

# fm_idle_capacity_mark_escalated <state-dir>
# Records the current (ready ids, free counts, capacity-held ids) tuple as
# escalated. Call only after the escalation fm_idle_capacity_should_escalate
# gated has actually been delivered.
fm_idle_capacity_mark_escalated() {  # <state-dir>
  printf '%s\n' "$(fm_idle_capacity_signature)" > "$1/.idle-capacity-last-escalated" 2>/dev/null || true
}

# --- lane floor -------------------------------------------------------------
# The captain's standing rule that dispatchable capacity never sits idle while
# work exists: a home running fewer than config/lane-floor unpaused lanes while
# ANY work is dispatchable without a captain decision is in breach, and both the
# wake drain and the Claude turn-end guard say so. This is deliberately BROADER
# than the idle-capacity block above, which only counts backlog items whose hold
# is a capacity hold and only while a worktree slot is provably free: the fleet
# sat at 3-6 lanes for an hour because the work that could have filled the rest
# was held under non-capacity reasons or lived in a project's own openspec
# Changes, neither of which that block can see.
# EVERY read here fails SOFT to "no breach": a missing tasks-axi, an unreadable
# registry, an absent projects/ directory, an unreadable project, or a malformed
# floor contributes no work and never manufactures a breach. A breach is only
# ever asserted from work this home positively read.
FM_LANE_FLOOR_DEFAULT=10

# How many dispatchable items the block lists before disclosing the rest as a count.
FM_LANE_FLOOR_LIST_LIMIT=${FM_LANE_FLOOR_LIST_LIMIT:-20}

# The configured floor, or the default when the file is absent, unreadable, or
# not a bare integer - the same "malformed reads as unconfigured" rule
# config/concurrency-cap uses above, so a typo can never disable enforcement by
# reading as zero.
fm_lane_floor_value() {  # [config-dir]
  local config=${1:-} floor=$FM_LANE_FLOOR_DEFAULT
  if [ -n "$config" ] && [ -f "$config/lane-floor" ]; then
    IFS= read -r floor < "$config/lane-floor" 2>/dev/null || floor=$FM_LANE_FLOOR_DEFAULT
    floor=${floor%$'\r'}
    case "$floor" in ''|*[!0-9]*) floor=$FM_LANE_FLOOR_DEFAULT ;; esac
  fi
  printf '%s\n' "$floor"
}

# Lanes this home is actually running: one per state/<id>.meta, minus every task
# whose newest status event declares a bounded external wait. A paused lane is
# not progress the floor can count, and it is not a lane the captain's rule
# wants replaced either - it is simply not occupying dispatch attention.
# bin/fm-classify-lib.sh's status_is_paused owns the pause-verb contract; this is
# a deliberate local read of the same leading verb, because this file is
# self-contained by design (see the header) and the Stop hook path may not pay
# for that library.
fm_lane_floor_live() {  # <state-dir>
  local state=$1 meta id last verb live=0
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename -- "$meta" .meta)
    last=$(grep -v '^[[:space:]]*$' "$state/$id.status" 2>/dev/null | tail -1)
    # Verb before the first colon, with any correlation bracket and surrounding
    # whitespace stripped, so "paused [key=x]: ..." reads the same as "paused:".
    verb=${last%%:*}
    verb=${verb%%\[*}
    verb=${verb#"${verb%%[![:space:]]*}"}
    verb=${verb%"${verb##*[![:space:]]}"}
    [ "$verb" = paused ] && continue
    live=$((live + 1))
  done
  printf '%s\n' "$live"
}

# Every openspec Change in one project clone that still carries unticked task
# boxes and is not already named by a live task's brief. Prints
# "<change>\t<open-box-count>" lines, or nothing. openspec/changes/archive/ is
# the landed history and is excluded; the glob's own depth already skips it, and
# the explicit case below keeps that true if a tasks.md is ever added there.
fm_lane_floor_project_changes() {  # <project-root> <live-brief-text>
  local root=$1 brief_text=$2 tasks change open_boxes
  [ -n "$root" ] && [ -d "$root/openspec/changes" ] || return 0
  for tasks in "$root"/openspec/changes/*/tasks.md; do
    [ -f "$tasks" ] || continue
    change=$(basename -- "$(dirname -- "$tasks")")
    case "$change" in ''|archive) continue ;; esac
    open_boxes=$(awk '/^[[:space:]]*- \[ \]/ { n++ } END { print n + 0 }' "$tasks" 2>/dev/null) || continue
    case "$open_boxes" in ''|*[!0-9]*) continue ;; esac
    [ "$open_boxes" -gt 0 ] || continue
    # A Change a live worker is already implementing is not idle capacity. The
    # substring match is deliberately generous: over-excluding a Change costs
    # one unfilled lane, while under-excluding one dispatches a second worker
    # onto work already under way.
    case "$brief_text" in *"$change"*) continue ;; esac
    printf '%s\t%s\n' "$change" "$open_boxes"
  done
}

# fm_dispatchable_work <state-dir> [data-dir] [root]
# Every item firstmate could dispatch RIGHT NOW without a captain decision, one
# per line, or nothing at all. Never prints a diagnostic and never writes.
#   backlog <id>                     a ready backlog item (tasks-axi's own ready
#                                    listing already reads a hold whose --until
#                                    has passed as queued rather than held, so an
#                                    expired hold of any kind arrives here), or a
#                                    held item whose hold kind is anything but
#                                    captain, external, parked, or future - a
#                                    load, blocked, or unkinded hold is
#                                    firstmate's own call to make
#   openspec <project>:<change>:<n>  an openspec Change under a registered
#                                    project clone with n unticked task boxes
#                                    that no live task's brief names
# A captain-kind hold is excluded because it is a question the captain owns.
# An external, parked, or future hold is excluded too, but only while still
# actually held: tasks-axi's own ready listing already reads a hold whose
# --until has passed as queued rather than held (see backlog above), so a row
# that still reaches the held[ scan below is, by construction, one whose named
# event has not yet fired - there is nothing here for firstmate to act on.
fm_dispatchable_work() {  # <state-dir> [data-dir] [root]
  local state=$1 data=${2:-} root=${3:-$FM_IDLE_SELF_ROOT}
  local backlog ready_out row id hold_kind
  local meta brief brief_text='' name project_root change open_boxes

  [ -n "$data" ] || data=$(dirname -- "$state")/data
  backlog="$data/backlog.md"
  if [ -f "$backlog" ] && command -v tasks-axi >/dev/null 2>&1 \
    && ready_out=$(tasks-axi ready --file "$backlog" --include-held 2>/dev/null); then
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      id=${row%%,*}
      [ -n "$id" ] && printf 'backlog %s\n' "$id"
    done < <(printf '%s\n' "$ready_out" | awk '
      /^ready\[/ { rows = 1; next }
      /^[^[:space:]]/ { rows = 0 }
      rows && /^[[:space:]]/ { sub(/^[[:space:]]+/, ""); print }')
    # hold_kind is read by stripping hold_until (the true last field) off the
    # END of the row, the same right-anchored idiom the capacity-held block
    # above uses and for the same reason: title and hold_reason are free text
    # that may contain commas, so a counted-field read would silently misread.
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      id=${row%%,*}
      [ -n "$id" ] || continue
      hold_kind=${row%,*}; hold_kind=${hold_kind##*,}
      hold_kind=${hold_kind#\"}; hold_kind=${hold_kind%\"}
      case "$hold_kind" in captain | external | parked | future) continue ;; esac
      printf 'backlog %s\n' "$id"
    done < <(printf '%s\n' "$ready_out" | awk '
      /^held\[/ { rows = 1; next }
      /^[^[:space:]]/ { rows = 0 }
      rows && /^[[:space:]]/ { sub(/^[[:space:]]+/, ""); print }')
  fi

  # Every live task's brief in one read, so the per-Change exclusion below is a
  # substring test rather than a grep per Change.
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    brief="$data/$(basename -- "$meta" .meta)/brief.md"
    [ -f "$brief" ] || continue
    brief_text="$brief_text"$'\n'"$(cat "$brief" 2>/dev/null)"
  done

  # Registered project clones only: data/projects.md is the one registry, and
  # fm_idle_project_root above is the one resolver from a project name to its
  # recorded repository path.
  [ -f "$data/projects.md" ] || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    project_root=$(fm_idle_project_root "$data" "$root" "$name") || continue
    while IFS="$(printf '\t')" read -r change open_boxes; do
      [ -n "$change" ] || continue
      printf 'openspec %s:%s:%s\n' "$name" "$change" "$open_boxes"
    done < <(fm_lane_floor_project_changes "$project_root" "$brief_text")
  done < <(awk '$1 == "-" && $2 != "" && /repository: / { print $2 }' "$data/projects.md" 2>/dev/null)
  return 0
}

# Populate the lane-floor fields for one home. Never prints, never writes.
#   FM_LANE_FLOOR        the configured floor (config/lane-floor, default 10)
#   FM_LANE_FLOOR_LIVE   unpaused lanes this home is running
#   FM_LANE_FLOOR_WORK   fm_dispatchable_work's lines, newline separated - the
#                        evidence for a breach, so it is left EMPTY whenever
#                        there is none, including when the enumeration was
#                        skipped because this home is already at its floor or at
#                        its concurrency cap
#   FM_LANE_FLOOR_COUNT  how many of them
#   FM_LANE_FLOOR_BREACH true only when this home runs fewer than the floor and
#                        some work is dispatchable without a captain decision
fm_lane_floor_compute() {  # <state-dir> [data-dir] [root] [config-dir]
  local state=$1 data=${2:-} root=${3:-$FM_IDLE_SELF_ROOT} config=${4:-}
  local meta running=0
  [ -n "$data" ] || data=$(dirname -- "$state")/data
  [ -n "$config" ] || config=$(dirname -- "$state")/config
  FM_LANE_FLOOR=$(fm_lane_floor_value "$config")
  FM_LANE_FLOOR_LIVE=$(fm_lane_floor_live "$state")
  FM_LANE_FLOOR_WORK=''
  FM_LANE_FLOOR_COUNT=0
  FM_LANE_FLOOR_BREACH=false
  # Two cheap exits before the enumeration, which reads a backlog and walks
  # every registered project. A home at or above its floor is the ordinary busy
  # case and must not pay for that walk on every turn end.
  [ "$FM_LANE_FLOOR_LIVE" -lt "$FM_LANE_FLOOR" ] || return 0
  # A home already at its concurrency cap cannot spawn another worker, so there
  # is no breach to assert: enforcing one would block a turn on a condition the
  # session has no way to clear. The cap counts every worker, paused included,
  # because a paused lane still holds its slot.
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    running=$((running + 1))
  done
  [ "$running" -lt "$(fm_concurrency_cap_value "$config")" ] || return 0
  FM_LANE_FLOOR_WORK=$(fm_dispatchable_work "$state" "$data" "$root")
  FM_LANE_FLOOR_COUNT=$(printf '%s\n' "$FM_LANE_FLOOR_WORK" | sed '/^$/d' | wc -l | tr -d '[:space:]')
  case "$FM_LANE_FLOOR_COUNT" in ''|*[!0-9]*) FM_LANE_FLOOR_COUNT=0 ;; esac
  [ "$FM_LANE_FLOOR_COUNT" -gt 0 ] && FM_LANE_FLOOR_BREACH=true
  return 0
}

# Render the breach from the fields fm_lane_floor_compute already populated, or
# nothing at all when there is no breach. Bounded to FM_LANE_FLOOR_LIST_LIMIT
# listed items with the rest disclosed as a count. Always returns 0: like the
# idle-capacity block above, this is a report, never a gate.
fm_lane_floor_render() {
  local shown=0 item
  [ "${FM_LANE_FLOOR_BREACH:-false}" = true ] || return 0
  printf 'LANE FLOOR: live=%s floor=%s dispatchable=%s - load the lane-floor skill and dispatch before ending this turn\n' \
    "$FM_LANE_FLOOR_LIVE" "$FM_LANE_FLOOR" "$FM_LANE_FLOOR_COUNT"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    if [ "$shown" -ge "$FM_LANE_FLOOR_LIST_LIMIT" ]; then
      printf '  (%s more dispatchable)\n' "$((FM_LANE_FLOOR_COUNT - shown))"
      break
    fi
    printf '  %s\n' "$item"
    shown=$((shown + 1))
  done <<< "$FM_LANE_FLOOR_WORK"
  return 0
}

# Compute and render in one call, for the sites with no branch of their own to
# take between the two halves.
fm_lane_floor_report() {  # <state-dir> [data-dir] [root] [config-dir]
  fm_lane_floor_compute "$@"
  fm_lane_floor_render
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata),
#                         ready backlog work with a free worktree slot in its
#                         own project's pool, an item held on capacity alone
#                         with a free slot in its own project's pool
#                         (FM_IDLE_CAPACITY_HELD), or ready work sitting behind
#                         a freeze that still needs a watcher alive for the
#                         recheck once the freeze's own until date passes
#   FM_SUP_IDLE_CAPACITY  true/false - the dispatch-now or held-on-capacity
#                         branch alone carried FM_SUP_NEEDED; false while
#                         frozen even when FM_SUP_NEEDED is true for the
#                         recheck above
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# data-dir defaults to the state directory's sibling and root to this file's own
# repo, so no existing caller changes; both feed the idle branch only.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} data=${3:-} root=${4:-} config=${5:-}
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
    fm_idle_capacity_compute "$state" "$data" "${root:-$FM_IDLE_SELF_ROOT}" "$config"
    if [ "$FM_IDLE_CAPACITY" = true ] || [ -n "$FM_IDLE_CAPACITY_HELD" ]; then
      # shellcheck disable=SC2034 # Read by callers (fm-turnend-guard.sh) after sourcing.
      FM_SUP_IDLE_CAPACITY=true
      FM_SUP_NEEDED=true
    elif [ -n "$FM_IDLE_FREEZE" ] && [ "$FM_IDLE_READY" -gt 0 ]; then
      # A freeze silences the dispatch-now escalation, never the fleet's only
      # chance to notice the freeze has expired - keep a watcher armed for
      # that recheck without re-opening the idle-capacity nag while it holds.
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
