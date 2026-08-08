#!/usr/bin/env bash
# fm-mission-control.sh - render the mission control board as self-contained HTML.
#
# The board is READ-ONLY: it renders live fleet state and writes one HTML file.
# It acquires no lock, drains no wakes, arms no watcher, and mutates no fleet
# state. It reads git metadata from the project clones, which never writes, and
# the only file it writes is its own output.
#
# This command does not parse fleet state itself. Like bin/fm-fleet-view.sh it
# shells out to bin/fm-fleet-snapshot.sh --json once and renders that stable
# contract, so current_state, backlog roles, captain actionability, and
# secondmate current state keep exactly one owner. Three inputs come from
# outside the snapshot because the snapshot does not own them: data/projects.md
# is the delivery-posture registry, `quota-axi --json` is the live allowance
# reading, and each project card's last-change time comes from that project's
# own clone or, for a second mate, from when it last reported.
#
# The board never invents a completion percentage or an ETA. Progress judgement
# belongs to firstmate, so each project card states only what live state can
# prove: what is under way, what waits on the captain, and when it last changed.
#
# A captain decision the captain has consciously set aside leaves "Awaiting your
# decision" and its count, and appears in the quiet, closed-by-default Deferred
# shelf below it. Deferring is not a board action; see "Deferring a decision"
# below for the two commands that set one aside and bring it back.
#
# Paths resolve from the ACTIVE home: the snapshot's own roots.state,
# roots.data, and roots.projects are used verbatim, so FM_HOME and the
# FM_*_OVERRIDE variables are honoured without a second resolution here.
#
# Usage:
#   fm-mission-control.sh                  write <state>/mission-control.html
#   fm-mission-control.sh --out <path>     write to an explicit path
#   fm-mission-control.sh --stdout         print the HTML instead of writing
#   fm-mission-control.sh --no-quota       skip the quota-axi allowance read
#   fm-mission-control.sh --refresh <sec>  self-reload interval (default 25)
#   fm-mission-control.sh --controls       add the captain reply layer
#   fm-mission-control.sh --snapshot <f>   render a captured snapshot JSON file
#   fm-mission-control.sh -h|--help        usage
#
# Environment:
#   FM_MISSION_CONTROL_NOW_EPOCH  fix "now" for deterministic rendering.
#   FM_MISSION_CONTROL_QUOTA_JSON path to a captured quota-axi --json payload,
#                                 used instead of running quota-axi.
#
# Deferring a decision:
#   Firstmate sets a captain decision aside on the captain's word, in the home
#   whose backlog holds it, by changing that item's HOLD KIND alone - from
#   captain to tasks-axi's existing "parked" - and reverses it by restoring
#   captain. The item stays kind: captain throughout, so it remains a captain
#   decision rather than becoming generic future work.
#
#     set aside:   tasks-axi hold <id> --reason "<reason>" --kind parked
#     bring back:  tasks-axi hold <id> --reason "<reason>" --kind captain
#
#   tasks-axi requires --reason on every hold and stores the reason it is given,
#   so read the current reason from the owning home's backlog row and pass that
#   exact stored text back unchanged. For a second mate decision, the owning
#   home is that second mate's own home, not the main home or the board. The
#   reason shown on the board identifies the decision but may be shortened, so
#   it is not safe to copy. A different string silently rewrites the captain's
#   decision text.
#
# Reply controls (--controls):
#   The render stays read-only. --controls adds a reply layer whose every control
#   does exactly one thing: queue ONE request through the Lavish bridge that wakes
#   firstmate. It performs no action, calls no endpoint, and carries no authority;
#   firstmate adjudicates each request under its own contract, exactly as if the
#   captain had said the same words in chat. The surface is reachable by anything
#   that can reach the local Lavish port, so reachability is never authorization.
#
#   The layer is hidden by CSS and revealed only after a script confirms the
#   Lavish bridge is present, so the same file served statically is the read-only
#   board it is without this flag, and no viewer is ever shown a dead control.
#   With --controls the self-reload moves into <noscript> and a managed reload
#   takes over, holding while a control is open so a 25-second refresh cannot
#   discard half-typed text. Without the flag the meta refresh is untouched.
#
#   Each request is one line: FM-BOARD-REQUEST followed by one JSON object.
#   bin/fm-procevent-mission-control.sh owns arming the wake and normalizing what
#   comes back; see docs/mission-control.md for the controls and their limits.
#
# Exit codes: 0 rendered, 1 runtime failure, 2 usage error.
#
# Output is written through a temporary file and renamed into place, so a
# browser refreshing on its own cadence never reads a half-written board.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_CMD="$SCRIPT_DIR/fm-fleet-snapshot.sh"

usage() {
  sed -n '/^# Usage:/,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() { echo "fm-mission-control: $1" >&2; exit "${2:-1}"; }

OUT=""
TO_STDOUT=0
WITH_QUOTA=1
REFRESH=25
SNAPSHOT_FILE=""
CONTROLS=false

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out) [ $# -ge 2 ] || die "--out needs a path" 2; OUT=$2; shift 2 ;;
    --stdout) TO_STDOUT=1; shift ;;
    --no-quota) WITH_QUOTA=0; shift ;;
    --controls) CONTROLS=true; shift ;;
    --refresh)
      [ $# -ge 2 ] || die "--refresh needs seconds" 2
      case "$2" in ''|*[!0-9]*|0) die "--refresh must be a positive integer" 2 ;; esac
      REFRESH=$2; shift 2 ;;
    --snapshot)
      [ $# -ge 2 ] || die "--snapshot needs a file" 2
      SNAPSHOT_FILE=$2; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq not found"

if [ -n "$SNAPSHOT_FILE" ]; then
  [ -r "$SNAPSHOT_FILE" ] || die "snapshot file not readable: $SNAPSHOT_FILE"
  SNAPSHOT=$(cat "$SNAPSHOT_FILE") || die "could not read $SNAPSHOT_FILE"
else
  SNAPSHOT=$("$SNAPSHOT_CMD" --json) || die "fleet snapshot failed"
fi
printf '%s' "$SNAPSHOT" | jq -e 'type == "object" and has("tasks")' >/dev/null 2>&1 \
  || die "fleet snapshot did not return the expected object"

STATE_DIR=$(printf '%s' "$SNAPSHOT" | jq -r '.roots.state // ""')
DATA_DIR=$(printf '%s' "$SNAPSHOT" | jq -r '.roots.data // ""')
PROJECTS_DIR=$(printf '%s' "$SNAPSHOT" | jq -r '.roots.projects // ""')

NOW=${FM_MISSION_CONTROL_NOW_EPOCH:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) NOW=$(date +%s) ;; esac

IS_DARWIN=0
[ "$(uname -s 2>/dev/null)" = Darwin ] && IS_DARWIN=1

# Format one epoch in local time. BSD and GNU date disagree on how an epoch is
# given, and the locale decides whether %p reads "PM" or "p.m.", so the format
# is pinned to the C locale and the platform is chosen up front rather than by
# trying one and falling back.
epoch_fmt() {  # <epoch> <format>
  if [ "$IS_DARWIN" = 1 ]; then
    LC_ALL=C date -r "$1" +"$2" 2>/dev/null
  else
    LC_ALL=C date -d "@$1" +"$2" 2>/dev/null
  fi
}

TODAY=$(epoch_fmt "$NOW" '%Y-%m-%d')
if [ "$IS_DARWIN" = 1 ]; then
  YESTERDAY=$(LC_ALL=C date -r "$NOW" -v-1d '+%Y-%m-%d' 2>/dev/null)
else
  YESTERDAY=$(LC_ALL=C date -d "$TODAY -1 day" '+%Y-%m-%d' 2>/dev/null)
fi

# Modification time of one file, or empty when it is absent or unreadable. BSD
# and GNU stat need separate invocations: `stat -f` asks GNU stat for FILESYSTEM
# status and succeeds with output that is not a timestamp at all, so a "try one,
# fall back to the other" chain reads the wrong thing on Linux rather than
# failing over. A non-numeric answer degrades to no time rather than breaking
# the render.
file_mtime() {  # <path>
  local mtime
  [ -e "$1" ] || return 0
  if [ "$IS_DARWIN" = 1 ]; then
    mtime=$(stat -f '%m' "$1" 2>/dev/null) || return 0
  else
    mtime=$(stat -c '%Y' "$1" 2>/dev/null) || return 0
  fi
  case "$mtime" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s\n' "$mtime"
}

# A last-change time the captain reads at a glance: the clock for anything from
# the last two days, the calendar date beyond that. Relative wording is derived
# from this render's own NOW, never from a second clock reading, so a captured
# snapshot renders identically every time.
when_label() {  # <epoch>
  local epoch=$1 day clock
  case "$epoch" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$epoch" -gt "$NOW" ]; then printf 'just now\n'; return 0; fi
  day=$(epoch_fmt "$epoch" '%Y-%m-%d')
  [ -n "$day" ] || return 0
  if [ "$day" = "$TODAY" ] || [ "$day" = "$YESTERDAY" ]; then
    clock=$(epoch_fmt "$epoch" '%-I:%M%p' | tr '[:upper:]' '[:lower:]')
    [ -n "$clock" ] || return 0
    if [ "$day" = "$TODAY" ]; then
      printf '%s today\n' "$clock"
    else
      printf '%s yesterday\n' "$clock"
    fi
  else
    epoch_fmt "$epoch" '%-d %b'
  fi
}

# A registry name reaches the filesystem, so it is checked against the shape a
# clone directory actually has. A project may legitimately be named for its
# domain (wongsuwarn.com), so dots are allowed inside the name while a leading
# dot, a path separator, and a parent-directory hop are not.
safe_project_name() {  # <name>
  case "$1" in
    ''|.*|*/*|*'..'*) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

PROJECTS_RAW=""
PROJECTS_PRESENT=false
if [ -n "$DATA_DIR" ] && [ -r "$DATA_DIR/projects.md" ]; then
  PROJECTS_RAW=$(cat "$DATA_DIR/projects.md") || PROJECTS_RAW=""
  PROJECTS_PRESENT=true
fi

# The registry is parsed once, here, and passed to the render as data. The
# project names are needed in the shell to read each clone, so parsing it a
# second time inside the render would give the same rule two owners.
REGISTRY=$(printf '%s' "$PROJECTS_RAW" | jq -R -s --argjson present "$PROJECTS_PRESENT" '
  if ($present | not) then []
  else
    split("\n") |
    map(select(test("^- \\S")) |
      (capture("^- (?<name>\\S+) \\[(?<mode>[^\\]]*)\\] - (?<desc>.*)$") // null) |
      select(. != null) |
      {name, mode: (.mode | sub(" *\\+yolo"; "")), yolo: (.mode | test("\\+yolo")), desc}) |
    map(select(.name != null))
  end') || die "could not parse the project registry"

# When each project last changed. A project with a card is dated by its clone's
# last commit, which survives task teardown; a second mate is dated by when it
# last reported, because its own clone can trail the work it advised on and a
# plausible-but-stale time is worse than no time at all. Either source may be
# missing, and a missing source renders as a dash.
updated_rows() {
  local name id epoch label
  printf '%s' "$SNAPSHOT" | jq -r --argjson registry "$REGISTRY" '
    def short_repo:
      if (. // "") == "" then ""
      elif test("/") then (split("/") | map(select(length > 0)) | last // "")
      else . end;
    ($registry | map(.name)) as $registered |
    ([.secondmate_current.records[]?.id // empty] | unique) as $secondmates |
    ([.tasks[]? | select(.kind != "secondmate") |
      ((.backlog.repo // "") | short_repo) as $repo |
      if $repo != "" then $repo else ((.project // "") | short_repo) end] |
      map(. as $name | select($name != "" and (($secondmates | index($name)) == null)))) as $live |
    ($registered + $live | unique[])
  ' | while IFS= read -r name; do
    [ -n "$name" ] || continue
    epoch=""
    if [ -n "$PROJECTS_DIR" ] && safe_project_name "$name"; then
      epoch=$(git --no-optional-locks -C "$PROJECTS_DIR/$name" log -1 --format=%ct \
        2>/dev/null </dev/null) || epoch=""
    fi
    case "$epoch" in *[!0-9]*) epoch="" ;; esac
    label=""
    [ -n "$epoch" ] && label=$(when_label "$epoch")
    printf 'project:%s\t%s\t%s\n' "$name" "$epoch" "$label"
  done
  printf '%s' "$SNAPSHOT" | jq -r '.secondmate_current.records[]?.id // empty' \
    | while IFS= read -r id; do
    [ -n "$id" ] || continue
    epoch=$(file_mtime "$STATE_DIR/$id.status")
    [ -n "$epoch" ] || epoch=$(file_mtime "$STATE_DIR/$id.meta")
    label=""
    [ -n "$epoch" ] && label=$(when_label "$epoch")
    printf 'secondmate:%s\t%s\t%s\n' "$id" "$epoch" "$label"
  done
}

UPDATED=$(updated_rows | jq -R -s '
  split("\n") | map(select(length > 0) | split("\t")) |
  map({key: .[0], value: {
    epoch: (if (.[1] // "") == "" then null else (.[1] | tonumber) end),
    label: (.[2] // "")}}) |
  from_entries') || die "could not read project change times"

# Allowance gauges are best-effort: an absent, failing, or non-JSON quota-axi
# renders as an explicit "unavailable" note, never as an empty zero gauge.
QUOTA='null'
QUOTA_NOTE="not requested"
if [ "$WITH_QUOTA" = 1 ]; then
  quota_raw=""
  if [ -n "${FM_MISSION_CONTROL_QUOTA_JSON:-}" ]; then
    if [ -r "$FM_MISSION_CONTROL_QUOTA_JSON" ]; then
      quota_raw=$(cat "$FM_MISSION_CONTROL_QUOTA_JSON" 2>/dev/null) || quota_raw=""
      QUOTA_NOTE="captured payload unreadable"
    else
      QUOTA_NOTE="captured payload not found"
    fi
  elif command -v quota-axi >/dev/null 2>&1; then
    quota_raw=$(quota-axi --json 2>/dev/null </dev/null) || quota_raw=""
    QUOTA_NOTE="quota-axi returned no usable reading"
  else
    QUOTA_NOTE="quota-axi not installed"
  fi
  if [ -n "$quota_raw" ] && printf '%s' "$quota_raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    QUOTA=$quota_raw
    QUOTA_NOTE=""
  fi
fi

HTML=$(
  printf '%s' "$SNAPSHOT" | jq -r \
    --argjson quota "$QUOTA" \
    --arg quota_note "$QUOTA_NOTE" \
    --argjson registry "$REGISTRY" \
    --argjson updated "$UPDATED" \
    --argjson projects_present "$PROJECTS_PRESENT" \
    --arg today "$TODAY" \
    --argjson controls "$CONTROLS" \
    --argjson refresh "$REFRESH" '

# --------------------------------------------------------------------------
# Escaping rule: every value that came from fleet state, the registry, or the
# allowance reading is interpolated through an @html format string, which
# escapes interpolations but not the surrounding literal markup. Fragments are
# joined with "+" and never interpolated into another @html string, so nothing
# is ever escaped twice.
# --------------------------------------------------------------------------
def dash($v): if ($v // "") == "" then "-" else ($v | tostring) end;

def plural($n; $one; $many): if $n == 1 then $one else $many end;

# A backlog row may record its repo as a bare name or as a full clone path.
# Both name the same project, so both are reduced to the registry name: it is
# what the rollup matches on and what fits inside a card.
def short_repo:
  if (. // "") == "" then ""
  elif test("/") then (split("/") | map(select(length > 0)) | last // "")
  else . end;

def repo_of:
  (.backlog.repo // "" | short_repo) as $r |
  if $r != "" then $r
  elif (.project // "") != "" then (.project | short_repo)
  else "" end;

# ------------------------------------------------------------------ icons ---
# Monochrome line glyphs only. Each is a literal fragment with no interpolation,
# so none of them can carry fleet prose into the page.
def icon_bell: "<svg class=\"ico\" viewBox=\"0 0 24 24\"><path d=\"M18 8A6 6 0 006 8c0 7-3 9-3 9h18s-3-2-3-9\"/><path d=\"M13.7 21a2 2 0 01-3.4 0\"/></svg>";
def icon_pulse: "<svg class=\"ico\" viewBox=\"0 0 24 24\"><polyline points=\"22 12 18 12 15 21 9 3 6 12 2 12\"/></svg>";
def icon_shipped: "<svg class=\"ico\" viewBox=\"0 0 24 24\"><path d=\"M22 11.1V12a10 10 0 11-5.9-9.1\"/><polyline points=\"22 4 12 14 9 11\"/></svg>";
def icon_folder: "<svg class=\"ico\" viewBox=\"0 0 24 24\"><path d=\"M22 19a2 2 0 01-2 2H4a2 2 0 01-2-2V5a2 2 0 012-2h5l2 3h9a2 2 0 012 2z\"/></svg>";
def icon_clock: "<svg viewBox=\"0 0 24 24\"><circle cx=\"12\" cy=\"12\" r=\"9\"/><polyline points=\"12 7 12 12 15 14\"/></svg>";
def icon_check: "<svg class=\"ck\" viewBox=\"0 0 24 24\"><polyline points=\"20 6 9 17 4 12\"/></svg>";
def icon_alert: "<svg class=\"ico\" viewBox=\"0 0 24 24\"><path d=\"M10.3 3.9L1.8 18a2 2 0 001.7 3h17a2 2 0 001.7-3L13.7 3.9a2 2 0 00-3.4 0z\"/><line x1=\"12\" y1=\"9\" x2=\"12\" y2=\"13\"/><line x1=\"12\" y1=\"17\" x2=\"12.01\" y2=\"17\"/></svg>";
def icon_compass: "<svg viewBox=\"0 0 24 24\"><circle cx=\"12\" cy=\"12\" r=\"10\"/><polygon points=\"16.2 7.8 14.1 14.1 7.8 16.2 9.9 9.9\"/></svg>";
def icon_gauge: "<svg class=\"ico\" viewBox=\"0 0 24 24\"><path d=\"M4.9 18.5a9 9 0 1114.2 0\"/><line x1=\"12\" y1=\"14\" x2=\"16\" y2=\"9.5\"/></svg>";

# A project badge gives a card a recognisable identity, so the glyph is picked
# from a set of deliberately neutral shapes by a stable function of the project
# name. It claims nothing about the project, and the name sits beside it, so it
# never has to be read as meaning.
def project_glyph($name):
  ([
    "<svg viewBox=\"0 0 24 24\"><path d=\"M21 16V8a2 2 0 00-1-1.7l-7-4a2 2 0 00-2 0l-7 4A2 2 0 003 8v8a2 2 0 001 1.7l7 4a2 2 0 002 0l7-4A2 2 0 0021 16z\"/><polyline points=\"3.3 7 12 12 20.7 7\"/><line x1=\"12\" y1=\"22\" x2=\"12\" y2=\"12\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><polygon points=\"12 2 22 8.5 12 15 2 8.5\"/><polyline points=\"2 15.5 12 22 22 15.5\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><rect x=\"3\" y=\"3\" width=\"7\" height=\"7\" rx=\"1.5\"/><rect x=\"14\" y=\"3\" width=\"7\" height=\"7\" rx=\"1.5\"/><rect x=\"3\" y=\"14\" width=\"7\" height=\"7\" rx=\"1.5\"/><rect x=\"14\" y=\"14\" width=\"7\" height=\"7\" rx=\"1.5\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><path d=\"M21 19a2 2 0 01-2 2H5a2 2 0 01-2-2V5a2 2 0 012-2h5l2 3h7a2 2 0 012 2z\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><rect x=\"2\" y=\"4\" width=\"20\" height=\"16\" rx=\"2\"/><polyline points=\"7 10 10 13 7 16\"/><line x1=\"13\" y1=\"16\" x2=\"17\" y2=\"16\"/></svg>",
    "<svg viewBox=\"0 0 24 24\"><path d=\"M4 4.5A2.5 2.5 0 016.5 2H20v18H6.5A2.5 2.5 0 004 22z\"/><line x1=\"8\" y1=\"7\" x2=\"16\" y2=\"7\"/></svg>"
  ]) as $set |
  $set[(($name | explode | add // 0) % ($set | length))];

# ---------------------------------------------------------------- inputs ----
($registry | map({key: .name, value: .}) | from_entries) as $registry_by_name |
def yolo_for($repo): ($registry_by_name[$repo // ""].yolo // false);

(.tasks // []) as $tasks |
(.backlog.records // []) as $records |
(.backlog.present == true) as $backlog_present |
($tasks | map(select(.kind != "secondmate"))) as $work_tasks |
(.secondmate_current.records // []) as $sm_records |
(.secondmate_current.registry // {}) as $sm_registry |
(($sm_registry.available == true)
  and ($sm_registry.complete == true)
  and ($sm_registry.input_truncated != true)
  and ($sm_registry.records_truncated != true)) as $sm_registry_complete |

# ------------------------------------------------------- waiting on you ----
# Three canonical sources, each tagged with the home it came from: main-home
# captain-actionable backlog rows, tasks whose PR is recorded and awaiting a
# merge or review call, and captain-held decisions inside a secondmate home
# (which never appear in this home backlog).
($records | map(select(.captain_actionable == true)) | map({
  kind: "decision",
  home: "main",
  id: .id,
  title: (.title // .raw),
  detail: (.hold_reason // .blocked_reason // ""),
  repo: (.repo // "" | short_repo),
  link: (.pr_url // .report_path // (.links // [])[0] // null),
  # A main-home captain decision is always a backlog hold, so both controls
  # apply: it can be answered, and it has a row whose hold kind can be changed.
  ctl: {intents: ["answer", "defer"], home: "main", id: .id, key: ""}
})) as $waiting_decisions |

($work_tasks | map(select((.pr.url // "") != "")) | map(. as $t | {
  kind: "pr",
  home: "main",
  id: $t.id,
  title: ($t.backlog.title // $t.id),
  # The run state is an internal pipeline label, and the row already says what
  # the captain has to do, so it is deliberately left off this row.
  detail: "",
  repo: ($t | repo_of),
  yolo: ($t | repo_of | yolo_for(.)),
  link: $t.pr.url,
  ctl: {intents: ["merge", "reply"], home: "main", id: $t.id, key: ""}
})) as $waiting_prs |

# A secondmate decision row is not one shape. A "backlog" decision is a captain
# hold whose id is that home BACKLOG ITEM, so it can be answered and set aside. A
# "status" decision is a task-level open decision whose id is the TASK and whose
# key is the decision - there is no backlog row behind it, so it has no hold kind
# to change and is answered only, carrying both so two decisions on one task stay
# distinguishable. A row naming neither gets no controls at all, because a
# request firstmate cannot resolve is worse than one the captain makes in chat.
($sm_records | map(. as $sm |
  ($sm.decisions_open // []) | map(
    ((.id // "") | tostring) as $did |
    ((.key // "") | tostring) as $dkey |
    {
    kind: "decision",
    home: ($sm.id // "secondmate"),
    id: (.id // .key),
    title: (.summary // .key // "decision"),
    detail: (.reason // ""),
    repo: "",
    link: null,
    ctl: (if $did == "" and $dkey == "" then null
          else {
            intents: (if (.source // "") == "backlog" then ["answer", "defer"] else ["answer"] end),
            home: ($sm.id // "secondmate"),
            id: $did,
            key: $dkey
          } end)
  })) | add // []) as $waiting_secondmate |

($sm_records | map(. as $sm |
  (($sm.decisions_open // []) | length) as $shown |
  ([($sm.omitted // [])[] | select(.surface == "decisions_open") | (.count // 0)] | add // 0) as $omitted |
  ([($sm.counts.decisions_open // $shown), ($shown + $omitted), $shown] | max) as $total |
  select($total > $shown) |
  {
    kind: "incomplete",
    home: ($sm.id // "secondmate"),
    id: (($sm.id // "secondmate") + "/omitted-decisions"),
    title: "Additional captain decisions are not shown",
    detail: ("Snapshot shows \($shown) of \($total) decisions. Inspect this secondmate home for all \($total - $shown) omitted decisions."),
    repo: "",
    link: null,
    omitted_count: ($total - $shown)
  })) as $waiting_secondmate_omitted |

((.secondmate_current.truncated // 0) | if . < 0 then 0 else . end) as $sm_truncated |
(if $sm_truncated > 0 then [{
  kind: "incomplete",
  home: "secondmates",
  id: "secondmate-current/truncated",
  title: "Secondmate decision scan is incomplete",
  detail: ("Snapshot omitted \($sm_truncated) secondmate record(s). Inspect the full fleet state before concluding that no other captain decisions are waiting."),
  repo: "",
  link: null
}] else [] end) as $waiting_secondmate_truncated |

(if $sm_registry_complete then [] else [{
  kind: "incomplete",
  home: "secondmates",
  id: "secondmate-registry/incomplete",
  title: "Secondmate registry scan is incomplete",
  detail: (if $sm_registry.available != true
    then ("Registered secondmate table is unavailable: \($sm_registry.reason // "unknown reason"). Additional homes and captain decisions may be missing.")
    else ("Registered secondmate table was bounded or incomplete\(if (($sm_registry.reasons // []) | length) > 0 then " (\(($sm_registry.reasons // []) | join(", ")))" else "" end). Additional homes and captain decisions may be missing.")
    end),
  repo: "",
  link: null
}] end) as $waiting_secondmate_registry |

($sm_records | map(select(
  .registered == true
  and ((.provenance.selected // "") != "structured-home")) | {
    kind: "incomplete",
    home: (.id // "secondmate"),
    id: ((.id // "secondmate") + "/decisions-unavailable"),
    title: "Registered secondmate decisions are unavailable",
    detail: ("Captain decisions for this registered secondmate could not be read: \(.current.reason // "structured home unavailable"). Inspect the secondmate home before concluding that nothing is waiting."),
    repo: "",
    link: null
  })) as $waiting_secondmate_unavailable |

(if $backlog_present then [] else [{
  kind: "incomplete",
  home: "main",
  id: "main/backlog-unavailable",
  title: "Main backlog is unavailable",
  detail: "Captain decisions from the main backlog cannot be counted. Restore or inspect the backlog before concluding that nothing is waiting.",
  repo: "",
  link: null
}] end) as $waiting_backlog_unavailable |

($waiting_decisions + $waiting_secondmate) as $waiting_calls |
($waiting_calls + $waiting_prs) as $waiting |
($waiting_secondmate_omitted + $waiting_secondmate_truncated + $waiting_secondmate_registry + $waiting_secondmate_unavailable + $waiting_backlog_unavailable) as $waiting_notices |
(($waiting | length) + ($waiting_secondmate_omitted | map(.omitted_count) | add // 0)) as $waiting_count |
((($backlog_present | not)
  or $sm_truncated > 0
  or ($waiting_secondmate_omitted | length) > 0
  or ($waiting_secondmate_registry | length) > 0
  or ($waiting_secondmate_unavailable | length) > 0)) as $waiting_incomplete |

# ------------------------------------------------------------- deferred ----
# A decision the captain has consciously set aside. The snapshot already keeps
# it out of the actionable set, so it is absent from the waiting list and the
# waiting count without a second rule here; this reads the same rows back so
# setting one aside puts it out of the eyeline rather than out of existence.
($records | map(select(.captain_deferred == true)) | map({
  home: "main",
  id: .id,
  title: (.title // .raw),
  detail: (.hold_reason // ""),
  repo: (.repo // "" | short_repo)
})) as $deferred_main |

($sm_records | map(. as $sm |
  (($sm.queued // []) | map(select(.captain_deferred == true)) | map({
    home: ($sm.id // "secondmate"),
    id: (.id // "decision"),
    title: (.title // .id // "decision"),
    detail: (.hold_reason // ""),
    repo: (.repo // "" | short_repo)
  }))) | add // []) as $deferred_secondmate |

($deferred_main + $deferred_secondmate) as $deferred |
($deferred | length) as $deferred_count |
# A secondmate home reports its queued rows bounded, so a decision deferred
# there can fall outside the reported window. A visible shelf says so rather
# than implying its list is complete. The bound alone never conjures a shelf:
# an empty "0 set aside" panel standing over every busy secondmate is noise the
# captain would learn to skip, and the board claims nothing about deferred work
# when it has none to show.
($sm_records | map([(.omitted // [])[] | select(.surface == "queued") | (.count // 0)] | add // 0)
  | add // 0) as $deferred_bounded |

# ----------------------------------------------------------- fleet health --
($work_tasks | map(select(
  ((.current_state.state // "") | test("block|fail|error|cancel"; "i"))
  or (.hints.blocked_event == true)))) as $unhealthy_raw |
($records | map(select(.state != "done" and ((.unresolved_blocker_ids // []) | length) > 0))) as $blocked_items_raw |
($unhealthy_raw | map(.id)) as $unhealthy_ids |
($unhealthy_raw | map(. as $task |
  ($blocked_items_raw | map(select(.id == $task.id)) | first) as $row |
  $task + {health_blocker_ids: ($row.unresolved_blocker_ids // [])})) as $unhealthy |
($blocked_items_raw | map(. as $row |
  select(($unhealthy_ids | index($row.id)) == null))) as $blocked_items |
($sm_records | map(. as $sm |
  (($sm.decisions_open // []) | map(.id // .key) | map(select(. != null))) as $decision_ids |
  (($sm.holds // []) | map(. as $hold |
    select((($decision_ids | index($hold.id)) == null)
      and (($hold.source // "") == "child-state"
        or (($hold.source // "") == "backlog"
          and ((($hold.unresolved_blocker_ids // []) | length) > 0)))))) as $blocked_shown |
  (($sm.holds // []) | length) as $shown |
  ([($sm.counts.holds // $shown), $shown] | max) as $total |
  ($blocked_shown | length) as $blocked_total |
  {
    id: ($sm.id // "secondmate"),
    blocked_holds: ($blocked_shown | map(. + {home: ($sm.id // "secondmate")})),
    blocked_shown: ($blocked_shown | length),
    blocked_total: $blocked_total,
    unclassified_omitted: ($total - $shown),
    card_held_total: (if ($sm.current.state // "") == "externally_held" then $total else $blocked_total end)
  })) as $secondmate_health |
($secondmate_health | map(.blocked_holds) | add // []) as $secondmate_holds |
($secondmate_health | map(select(.unclassified_omitted > 0))) as $secondmate_holds_omitted |
($sm_records | map(select((.current.state // "unknown") == "unknown"))) as $secondmate_unknown |
($secondmate_health | map(.blocked_total) | add // 0) as $secondmate_hold_count |
((($sm_truncated > 0)
  or ($sm_registry_complete | not)
  or ($secondmate_unknown | length) > 0
  or ($secondmate_holds_omitted | length) > 0)) as $health_incomplete |
(($unhealthy | length) + ($blocked_items | length) + $secondmate_hold_count) as $health_count |

# -------------------------------------------------------- shipped today ----
($records | map(select(.state == "done"))) as $done_all |
($done_all | map(select((.completion.date // "") == $today))) as $shipped |
($done_all | map(select((.completion.date // "") == "")) | length) as $shipped_undated |

# ------------------------------------------------------------ project cards -
# One card per registered project, plus any project that is not in the registry
# but has live work under way: a task the captain can see running must never be
# invisible just because its project was never registered.
($registry | map(. as $p |
  ($records | map(select((.repo // "" | short_repo) == $p.name))) as $rows |
  ($work_tasks | map(select((. | repo_of) == $p.name))) as $live |
  {
    kind: "project",
    key: ("project:" + $p.name),
    name: $p.name,
    mode: $p.mode,
    yolo: $p.yolo,
    registered: true,
    active: ($live | length),
    active_title: (($live | first | .backlog.title) // ($live | first | .id) // ""),
    prs: ($live | map(select((.pr.url // "") != "")) | length),
    queued: ($rows | map(select(.state == "queued")) | length),
    in_flight: ($rows | map(select(.state == "in_flight")) | length),
    waiting: ($rows | map(select(.captain_actionable == true)) | length),
    done: ($rows | map(select(.state == "done")) | length)
  })) as $registered_cards |

($sm_records | map(.id)) as $sm_ids |
($work_tasks | map(repo_of) | map(select(. != "")) | unique
  | map(. as $n | select(($registry_by_name[$n] == null)
                     and (($sm_ids | index($n)) == null)))) as $unregistered_names |

($unregistered_names | map(. as $name |
  ($records | map(select((.repo // "" | short_repo) == $name))) as $rows |
  ($work_tasks | map(select((. | repo_of) == $name))) as $live |
  {
    kind: "project",
    key: ("project:" + $name),
    name: $name,
    mode: "",
    yolo: false,
    registered: false,
    active: ($live | length),
    active_title: (($live | first | .backlog.title) // ($live | first | .id) // ""),
    prs: ($live | map(select((.pr.url // "") != "")) | length),
    queued: ($rows | map(select(.state == "queued")) | length),
    in_flight: ($rows | map(select(.state == "in_flight")) | length),
    waiting: ($rows | map(select(.captain_actionable == true)) | length),
    done: ($rows | map(select(.state == "done")) | length)
  })) as $unregistered_cards |

($sm_records | map(. as $sm |
  (($sm.decisions_open // []) | length) as $shown |
  ([($sm.omitted // [])[] | select(.surface == "decisions_open") | (.count // 0)] | add // 0) as $omitted |
  (($sm.active_children // []) | length) as $children_shown |
  ([($sm.omitted // [])[] | select(.surface == "active_children") | (.count // 0)] | add // 0) as $children_omitted |
  ([($sm.counts.active_children // $children_shown), ($children_shown + $children_omitted), $children_shown] | max) as $children_total |
  ($secondmate_health | map(select(.id == ($sm.id // "secondmate"))) | first) as $health |
  {
    kind: "secondmate",
    key: ("secondmate:" + ($sm.id // "secondmate")),
    name: ($sm.id // "secondmate"),
    state: ($sm.current.state // "unknown"),
    reason: ($sm.current.reason // ""),
    children: $children_total,
    children_shown: $children_shown,
    children_omitted: ($children_total - $children_shown),
    holds: ($health.card_held_total // 0),
    holds_shown: ($health.blocked_shown // 0),
    hold_reason: (($health.blocked_holds | first | .reason) // ""),
    decisions_available: ((($sm.registered != true) or (($sm.provenance.selected // "") == "structured-home"))),
    decisions_shown: $shown,
    decisions: ([($sm.counts.decisions_open // $shown), ($shown + $omitted), $shown] | max)
  })) as $secondmate_cards |

($registered_cards + $unregistered_cards) as $project_cards |
(($project_cards | length) + ($secondmate_cards | length)) as $card_count |
((($projects_present | not) or ($sm_registry_complete | not))) as $card_count_incomplete |
($secondmate_cards | map(.children) | add // 0) as $secondmate_active_count |
(($work_tasks | length) + $secondmate_active_count) as $in_progress_count |
((($sm_truncated > 0)
  or ($sm_registry_complete | not)
  or ($secondmate_unknown | length) > 0)) as $in_progress_incomplete |
($secondmate_cards | map(.children_omitted) | add // 0) as $active_details_omitted |

# ------------------------------------------------------------- fragments ---
# A placeholder for "nothing here", kept as literal markup so it is never
# double-escaped into a visible entity by the surrounding @html format.
def none_mark: "&mdash;";

def updated_line($key):
  ($updated[$key].label // "") as $label |
  "<div class=\"proj-updated\">" + icon_clock + "Updated "
  + (if $label == "" then none_mark else (@html "\($label)") end);

def need_row:
  . as $w |
  ($w.link // "") as $link |
  (if $w.kind == "incomplete" then "Incomplete"
   elif ($w.repo // "") != "" then $w.repo
   elif ($w.home // "main") != "main" then $w.home
   else "Fleet" end) as $tag |
  (if $w.kind == "pr" then (if $w.yolo then "your merge call (autonomous)" else "your review or merge" end)
   elif $w.kind == "incomplete" then ""
   else "" end) as $ask_note |
  (if $link == "" or $link == null
   then "<div class=\"need\(if $w.kind == "incomplete" then " warn" else "" end)\">"
   else (@html "<a class=\"need\(if $w.kind == "incomplete" then " warn" else "" end)\" href=\"\($link)\">") end)
  + "<span class=\"band\"></span>"
  + (@html "<span class=\"tag\">\($tag)</span>")
  + (@html "<span class=\"ask\">\($w.title)")
  + (if ($w.detail // "") == "" then "" else (@html "<span class=\"hint\">\($w.detail)</span>") end)
  + (if $ask_note == "" then "" else (@html "<span class=\"hint\">Awaiting \($ask_note).</span>") end)
  + (if $link == "" or $link == null then "" else (@html "<span class=\"url\">\($link)</span>") end)
  + "</span>"
  + (if $link == "" or $link == null then "<span class=\"go\"></span></div>"
     else "<span class=\"go\">&rsaquo;</span></a>" end);

# A deferred decision is deliberately quieter than a waiting one: no coloured
# band, no link chase, no chevron. It carries only what identifies it.
def deferred_row:
  . as $d |
  (if ($d.repo // "") != "" then $d.repo
   elif ($d.home // "main") != "main" then $d.home
   else "Fleet" end) as $tag |
  "<div class=\"defer\">"
  + (@html "<span class=\"tag\">\($tag)</span>")
  + (@html "<span class=\"ask\">\($d.title)")
  + (if ($d.detail // "") == "" then "" else (@html "<span class=\"hint\">\($d.detail)</span>") end)
  + "</span></div>";

# ------------------------------------------------------- reply controls ----
# Every control below queues ONE request and performs nothing. The markup holds
# no endpoint, no token, and no action; the only thing a tap reaches is the
# Lavish bridge, and the only thing that travels is captain intent for firstmate
# to adjudicate. With $controls false every def here yields the empty string, so
# the default board is byte-identical to the one rendered without the flag.
def rc_button($intent; $label):
  (@html "<button type=\"button\" class=\"rc-b\" data-open=\"\($intent)\">\($label)</button>");

def rc_form($intent; $question; $note_label; $send_label):
  (@html "<form class=\"rc-f\" data-toggle data-intent=\"\($intent)\" hidden>")
  + (@html "<p class=\"rc-q\">\($question)</p>")
  + (if $note_label == "" then ""
     else (@html "<textarea class=\"rc-t\" rows=\"3\" maxlength=\"2000\" aria-label=\"\($note_label)\" placeholder=\"\($note_label)\"></textarea>") end)
  + "<div class=\"rc-row\">"
  + (@html "<button type=\"submit\" class=\"rc-go\">\($send_label)</button>")
  + "<button type=\"button\" class=\"rc-x\">Cancel</button>"
  + "</div>"
  + "<p class=\"rc-hold\">The board holds its refresh while this is open.</p>"
  + "</form>";

def controls_for:
  . as $w |
  ($w.ctl // null) as $c |
  if ($controls | not) or $c == null then "" else
    (@html "<div class=\"rc\" data-home=\"\($c.home)\" data-id=\"\($c.id)\" data-key=\"\($c.key)\" data-what=\"\($w.title)\">")
    + "<div class=\"rc-acts\">"
    + (($c.intents | map(
        if . == "merge" then rc_button("merge"; "Approve merge")
        elif . == "reply" then rc_button("reply"; "Reply")
        elif . == "answer" then rc_button("answer"; "Answer")
        elif . == "defer" then rc_button("defer"; "Set aside")
        else "" end)) | add // "")
    + "<span class=\"rc-sent\" hidden></span></div>"
    + (($c.intents | map(
        if . == "merge" then rc_form("merge";
             "Ask firstmate to merge this? Firstmate runs its own checks first and merges only if they pass.";
             ""; "Send request")
        elif . == "reply" then rc_form("reply";
             "Send firstmate a note about this. It carries no approval on its own.";
             "Your note"; "Send to firstmate")
        elif . == "answer" then rc_form("answer";
             "Your answer goes to firstmate, which applies it through its normal decision flow.";
             "Your answer"; "Send answer")
        elif . == "defer" then rc_form("defer";
             "Set this aside? It leaves this list for the Deferred shelf, and your original reason is kept unchanged.";
             ""; "Set aside")
        else "" end)) | add // "")
    + "</div>"
  end;

def need_item: need_row + controls_for;

def ask_block:
  if ($controls | not) then "" else
    "<div class=\"rc rc-ask\" data-home=\"main\" data-id=\"\" data-key=\"\" data-what=\"\">"
    + "<form class=\"rc-f\" data-intent=\"ask\">"
    + "<p class=\"rc-q\">Ask firstmate for something new, or say what you want changed.</p>"
    + "<textarea class=\"rc-t\" rows=\"3\" maxlength=\"2000\" aria-label=\"Ask firstmate\"></textarea>"
    + "<div class=\"rc-row\"><button type=\"submit\" class=\"rc-go\">Send to firstmate</button>"
    + "<span class=\"rc-sent\" hidden></span></div>"
    # This composer is always open, so text left in it holds the refresh with no
    # form to close. It has to say so, or the board just quietly stops updating.
    + "<p class=\"rc-hold\">The board holds its refresh while there is text here.</p>"
    + "</form></div>"
  end;

def project_card:
  . as $p |
  # Every quiet signal on this card - no decisions, nothing queued, nothing in
  # flight - is read from the backlog. With the backlog unreadable, "Idle" is a
  # claim the board cannot make, so the pill says so instead of guessing calm.
  (if ($p.waiting > 0) or ($p.prs > 0) then "attn"
   elif ($p.active > 0) or ($p.in_flight > 0) then "live"
   elif ($backlog_present | not) then "unknown"
   else "idle" end) as $tone |
  (if $tone == "attn" then "Needs you"
   elif $tone == "live" then "Working"
   elif $tone == "unknown" then "Unconfirmed"
   else "Idle" end) as $pill |
  (if ($backlog_present | not) and ($p.active == 0) then "Live counts are unavailable while the backlog cannot be read."
   elif $p.active == 1 and ($p.active_title // "") != "" then "Under way: \($p.active_title)"
   elif $p.active > 0 then "\($p.active) tasks under way"
   elif $p.in_flight > 0 then "\($p.in_flight) \(plural($p.in_flight; "task"; "tasks")) in flight, none running"
   elif $p.queued > 0 then "\($p.queued) queued, nothing under way"
   else "Nothing in flight." end) as $state_line |
  (if ($backlog_present | not) then "Your decisions here cannot be counted."
   elif $p.waiting > 0 and $p.prs > 0 then "\($p.waiting) \(plural($p.waiting; "decision"; "decisions")) and \($p.prs) \(plural($p.prs; "PR"; "PRs")) await you"
   elif $p.waiting > 0 then "\($p.waiting) \(plural($p.waiting; "decision awaits"; "decisions await")) you"
   elif $p.prs > 0 then "\($p.prs) \(plural($p.prs; "PR awaits"; "PRs await")) your call"
   elif ($p.registered | not) then "Not in the project registry"
   else "" end) as $meta_line |
  (@html "<div class=\"proj s-\($tone)\">
     <div class=\"proj-top\"><span class=\"badge\">")
  + project_glyph($p.name)
  + (@html "</span><span class=\"proj-name\">\($p.name)")
  + (if $p.registered then "" else "<span class=\"sub-role\">&middot; unregistered</span>" end)
  + (@html "</span><span class=\"pill \(if $tone == "attn" then "attn" elif $tone == "live" then "live" elif $tone == "unknown" then "unknown" else "idle" end)\">\($pill)</span></div>
     <div class=\"proj-state\">\($state_line)</div>")
  + "<div class=\"proj-meta\">"
  + (if $meta_line == "" then none_mark else (@html "\($meta_line)") end)
  + "</div>"
  + updated_line($p.key)
  + (if ($p.mode // "") == "" then ""
     else (@html "<span class=\"posture\">\($p.mode)\(if $p.yolo then " +yolo" else "" end)</span>") end)
  + "</div></div>";

def secondmate_card:
  . as $s |
  (if ($s.decisions_available | not) or $s.state == "unknown" then "unknown"
   elif ($s.decisions > 0) or $s.state == "captain_decision" then "attn"
   elif $s.state == "externally_held" or $s.holds > 0 then "attn"
   elif $s.state == "active_child_work" or $s.children > 0 then "live"
   else "idle" end) as $tone |
  (if $s.state == "externally_held" or $s.holds > 0 then "Blocked"
   elif $tone == "attn" then "Needs you"
   elif $tone == "live" then "Working"
   elif $tone == "unknown" then "Unconfirmed"
   else "Ready" end) as $pill |
  (if ($s.reason // "") != "" then $s.reason
   elif $s.state == "externally_held" or $s.holds > 0 then
     (if ($s.hold_reason // "") != "" then $s.hold_reason
      else "\($s.holds) routed \(plural($s.holds; "task is"; "tasks are")) externally held" end)
   elif $s.children > 0 then "\($s.children) \(plural($s.children; "task"; "tasks")) routed and under way"
   elif $s.state == "captain_decision" then "Routed work is waiting for your decision."
   elif $s.state == "no_active_work" then "Idle and healthy, awaiting routed work."
   else "Current secondmate state is unavailable." end) as $state_line |
  (if ($s.decisions_available | not) then "Your decisions here cannot be read."
   elif $s.decisions > $s.decisions_shown then "\($s.decisions) decisions await you (\($s.decisions_shown) shown)"
   elif $s.decisions > 0 then "\($s.decisions) \(plural($s.decisions; "decision awaits"; "decisions await")) you"
   elif $s.children_omitted > 0 then "\($s.children) active tasks (\($s.children_shown) shown)"
   elif $s.holds > $s.holds_shown then "\($s.holds) held tasks (\($s.holds_shown) shown)"
   else "" end) as $meta_line |
  (@html "<div class=\"proj s-\($tone)\">
     <div class=\"proj-top\"><span class=\"badge\">")
  + icon_compass
  + (@html "</span><span class=\"proj-name\">\($s.name)<span class=\"sub-role\">&middot; second mate</span></span>
     <span class=\"pill \(if $tone == "attn" then "attn" elif $tone == "live" then "live" elif $tone == "unknown" then "unknown" else "idle" end)\">\($pill)</span></div>
     <div class=\"proj-state\">\($state_line)</div>")
  + "<div class=\"proj-meta\">"
  + (if $meta_line == "" then none_mark else (@html "\($meta_line)") end)
  + "</div>"
  + updated_line($s.key)
  + "</div></div>";

def stat($icon; $value; $label; $note; $attn):
  (@html "<div class=\"stat\(if $attn then " attn" else "" end)\">")
  + $icon
  + (@html "<div class=\"n\">\($value)</div><div class=\"l\">\($label)</div>")
  + (if $note == "" then "" else (@html "<div class=\"note\">\($note)</div>") end)
  + "</div>";

def gauge($label; $pct; $note):
  (if $pct == null then "muted"
   elif $pct <= 15 then "alert"
   elif $pct <= 35 then "warn"
   else "good" end) as $tone |
  (@html "<div class=\"gauge tone-\($tone)\">
     <div class=\"glabel\"><span>\($label)</span><span class=\"gval\">\(if $pct == null then "-" else "\($pct)%" end)</span></div>
     <div class=\"bar\"><i style=\"width:\(if $pct == null then 0 else $pct end)%\"></i></div>
     <div class=\"gnote\">\($note)</div>
   </div>");

def quota_block:
  if $quota == null then
    (@html "<p class=\"quiet\">Allowance unavailable - \($quota_note).</p>")
  else
    (($quota.providers // []) | map(. as $p |
      $p + {wins: (($p.windows // []) | map(select((.percentRemaining // null) != null)))})) as $providers |
    ($providers | map(select((.wins | length) > 0))) as $measured |
    ($providers | map(select((.wins | length) == 0))) as $unmeasured |
    # A provider with no readable window is a sign-in or reporting gap, not an
    # exhausted allowance, so it never renders as an empty zero gauge.
    (($measured | map(. as $p |
      ($p.wins | map(gauge(("\($p.label // $p.provider) / \(.label // .id)");
                           (.percentRemaining | floor);
                           ("resets \(.resetsAt // "-")"))) | add)) | add) // "")
    + (if ($unmeasured | length) == 0 then ""
       else "<ul class=\"unmeasured\">"
         + (($unmeasured | map(. as $p |
             (@html "<li><span>\($p.label // $p.provider)</span><span class=\"gval\">\($p.state.error // $p.state.status // "no window reported")</span></li>")) | add) // "")
         + "</ul>" end)
    + (if ($providers | length) == 0 then "<p class=\"quiet\">No allowance providers reported.</p>" else "" end)
  end;

# Hidden by CSS, revealed only once a script confirms the Lavish bridge, so the
# same file served statically stays the read-only board and no viewer is ever
# shown a control that cannot reach anything.
def controls_css:
  if ($controls | not) then "" else
"/* ---- captain reply layer (--controls) ---- */
.rc{display:none;}
body.lavish .rc{display:block;border-top:1px solid var(--line);background:#fbfcfe;padding:4px 22px 13px;}
body.lavish .rc-ask{border:1px solid var(--line);border-radius:16px;background:var(--panel);
  box-shadow:var(--shadow);margin-top:14px;padding:15px 22px 17px;}
.rc-acts{display:flex;align-items:center;gap:8px;flex-wrap:wrap;padding:8px 0 0;}
.rc-b{appearance:none;-webkit-appearance:none;border:1px solid var(--line);background:var(--panel);
  color:var(--slate);font:inherit;font-size:12.5px;font-weight:600;padding:6px 13px;
  border-radius:999px;cursor:pointer;}
.rc-b:hover{border-color:#cfd6e0;color:var(--ink);}
.rc-b:focus-visible,.rc-go:focus-visible,.rc-x:focus-visible{outline:2px solid var(--amber);outline-offset:1px;}
.rc-f{margin:11px 0 0;display:flex;flex-direction:column;gap:9px;}
/* An explicit display beats the [hidden] default, so a closed form needs this
   or every control on the board stands open at once. */
.rc-f[hidden]{display:none;}
.rc-q{margin:0;color:var(--muted);font-size:13px;}
.rc-t{font:inherit;font-size:13.5px;color:var(--ink);background:var(--panel);border:1px solid var(--line);
  border-radius:10px;padding:9px 11px;resize:vertical;width:100%;}
.rc-t:focus-visible{outline:2px solid var(--amber);outline-offset:-1px;}
.rc-row{display:flex;align-items:center;gap:10px;flex-wrap:wrap;}
.rc-go{appearance:none;-webkit-appearance:none;border:1px solid transparent;background:var(--ink);
  color:#fff;font:inherit;font-size:12.5px;font-weight:600;padding:7px 15px;border-radius:999px;cursor:pointer;}
.rc-go:hover{background:#2c3648;}
.rc-x{appearance:none;-webkit-appearance:none;border:none;background:none;color:var(--muted);
  font:inherit;font-size:12.5px;padding:7px 2px;cursor:pointer;text-decoration:underline;}
.rc-x:hover{color:var(--ink);}
.rc-hold{margin:0;color:var(--faint);font-size:11.5px;}
.rc-sent{color:var(--green);font-size:12.5px;font-weight:600;overflow-wrap:anywhere;}
.rc-sent.rc-bad{color:var(--red);}
@media(max-width:720px){
  body.lavish .rc,body.lavish .rc-ask{padding-left:16px;padding-right:16px;}
  .rc-b,.rc-go{padding-top:9px;padding-bottom:9px;}
}
"
  end;

def health_block:
  (if ($backlog_present | not) then
     "<p class=\"quiet\">Backlog health is unavailable because the backlog could not be read.</p>"
   else "" end)
  + (if $backlog_present and $health_count == 0 and ($health_incomplete | not) then
    "<p class=\"clear\">Nothing blocked or failed.</p>"
  else
    "<ul class=\"hlist\">"
    + (($unhealthy | map(. as $t |
        (@html "<li><span class=\"hstate\">\($t.current_state.state // "blocked")</span><span class=\"hwhat\">\($t.id)<span class=\"hint\">\(if ($t.health_blocker_ids | length) > 0 then "blocked by \($t.health_blocker_ids | join(", "))" else dash($t.paths.status_log.last_event.raw) end)</span></span></li>")) | add) // "")
    + (($blocked_items | map(. as $r |
        (@html "<li><span class=\"hstate wait\">waiting</span><span class=\"hwhat\">\(dash($r.title // $r.raw))<span class=\"hint\">blocked by \(($r.unresolved_blocker_ids // []) | join(", "))</span></span></li>")) | add) // "")
    + (($secondmate_holds | map(. as $h |
        (@html "<li><span class=\"hstate wait\">held</span><span class=\"hwhat\">\(dash($h.id // $h.title))<span class=\"hint\">\($h.home): \(dash($h.reason // $h.blocked_by))</span></span></li>")) | add) // "")
    + (($secondmate_holds_omitted | map(. as $o |
        (@html "<li><span class=\"hstate wait\">bounded</span><span class=\"hwhat\">\($o.id)<span class=\"hint\">\($o.unclassified_omitted) additional holds could not be classified</span></span></li>")) | add) // "")
    + (($secondmate_unknown | map(. as $s |
        (@html "<li><span class=\"hstate\">unknown</span><span class=\"hwhat\">\($s.id // "secondmate")<span class=\"hint\">\(dash($s.current.reason))</span></span></li>")) | add) // "")
    + (if $sm_truncated > 0 then
        (@html "<li><span class=\"hstate\">incomplete</span><span class=\"hwhat\">Secondmate health scan<span class=\"hint\">\($sm_truncated) secondmate records omitted</span></span></li>")
       else "" end)
    + (if ($sm_registry_complete | not) then
        "<li><span class=\"hstate\">incomplete</span><span class=\"hwhat\">Secondmate registry health could not be fully read</span></li>"
       else "" end)
    + "</ul>"
  end);

# ------------------------------------------------------------------ page ---
"<!doctype html>
<html lang=\"en\"><head>
<meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
"
+ (if $controls
   then "<noscript><meta http-equiv=\"refresh\" content=\"" + ($refresh | tostring) + "\"></noscript>"
   else "<meta http-equiv=\"refresh\" content=\"" + ($refresh | tostring) + "\">" end)
+ "
<title>Mission Control</title>
<style>
:root{
  --bg:#f5f6f8; --panel:#ffffff; --ink:#1a2233; --muted:#6b7688; --faint:#9aa4b2;
  --line:#e9ecf1;
  --amber:#b7791f; --amber-soft:#fdf6e7; --green:#0f8a5f; --green-soft:#e9f6ef;
  --red:#b3382f; --red-soft:#fdefee;
  --slate:#5b6472; --slate-soft:#eef1f5;
  --shadow:0 1px 2px rgba(20,30,50,.04), 0 6px 20px rgba(20,30,50,.05);
  --mono:ui-monospace,SFMono-Regular,\"SF Mono\",Menlo,Consolas,monospace;
}
*{box-sizing:border-box;min-width:0}
body{margin:0;background:var(--bg);color:var(--ink);
  font-family:-apple-system,BlinkMacSystemFont,\"Segoe UI\",Inter,Roboto,Helvetica,Arial,sans-serif;
  line-height:1.5;-webkit-font-smoothing:antialiased;}
.wrap{max-width:1120px;margin:0 auto;padding:40px 32px 64px;}
svg{stroke:currentColor;fill:none;stroke-width:1.9;stroke-linecap:round;stroke-linejoin:round;}
a{color:inherit;text-decoration:none}

/* ---- header ---- */
header{display:flex;align-items:baseline;justify-content:space-between;margin-bottom:8px;flex-wrap:wrap;gap:8px;}
h1{font-size:26px;font-weight:650;letter-spacing:-.02em;margin:0;}
.sub{color:var(--muted);font-size:14px;margin:2px 0 0;}
.live{display:inline-flex;align-items:center;gap:8px;color:var(--muted);font-size:13px;}
.dot{width:9px;height:9px;border-radius:50%;background:var(--green);position:relative;flex:none;}
.dot::after{content:\"\";position:absolute;inset:0;border-radius:50%;background:var(--green);
  animation:pulse 2s ease-out infinite;}
.live.stale .dot{background:var(--amber);}
.live.stale .dot::after{animation:none;background:none;}
@keyframes pulse{0%{transform:scale(1);opacity:.55}70%{transform:scale(3);opacity:0}100%{opacity:0}}
@media(prefers-reduced-motion:reduce){.dot::after{animation:none}}

/* ---- stat strip ---- */
.stats{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:16px;margin:26px 0 22px;}
.stat{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:18px 20px;
  box-shadow:var(--shadow);position:relative;}
.stat .ico{position:absolute;top:17px;right:18px;width:19px;height:19px;color:var(--faint);}
.stat.attn .ico{color:var(--amber);}
.stat .n{font-size:30px;font-weight:680;letter-spacing:-.02em;line-height:1;}
.stat .l{margin-top:8px;color:var(--muted);font-size:12.5px;font-weight:500;text-transform:uppercase;letter-spacing:.06em;}
.stat.attn .n{color:var(--amber);}
.stat .note{margin-top:6px;color:var(--amber);font-size:11.5px;line-height:1.35;}

/* ---- attention bar ---- */
.attnbar{display:flex;align-items:center;gap:11px;margin:0 0 30px;padding:12px 18px;
  background:var(--red-soft);border:1px solid #f3d6d3;border-radius:12px;color:#8f2c25;font-size:13.5px;}
.attnbar .ico{width:17px;height:17px;flex:none;color:var(--red);}
.attnbar .go{margin-left:auto;color:#c08b86;font-size:18px;flex:none;}

/* ---- tabs ----
   The header, the stat strip and the attention bar sit above this and are never
   tabbed away, so \"is anything on fire, and how much awaits me\" is always the
   first thing on the page.

   With no script the tab strip is hidden and every panel stays visible, so the
   board degrades into the single scrolling page it was before. The script in
   <head> adds the .js and .t-<tab> classes to <html> before first paint, so the
   selected panel is the only one ever painted and no other panel flashes. */
.tabs{display:none;}
.js .tabs{display:flex;gap:6px;margin:0 0 22px;padding:5px;background:var(--panel);
  border:1px solid var(--line);border-radius:14px;box-shadow:var(--shadow);}
.tab{flex:1 1 0;display:flex;align-items:center;justify-content:center;gap:7px;
  padding:9px 10px;border-radius:10px;color:var(--muted);font-size:13px;font-weight:560;
  cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;
  transition:background .15s ease,color .15s ease;}
.tab .ico{width:16px;height:16px;flex:none;color:var(--faint);}
.tab:hover{background:#f7f9fc;color:var(--ink);}
.tab:focus-visible{outline:2px solid var(--amber);outline-offset:-2px;}
html.t-decisions #tab-decisions,html.t-projects #tab-projects,
html.t-activity #tab-activity,html.t-system #tab-system{
  background:var(--slate-soft);color:var(--ink);}
html.t-decisions #tab-decisions .ico,html.t-projects #tab-projects .ico,
html.t-activity #tab-activity .ico,html.t-system #tab-system .ico{color:var(--slate);}
.js .panel{display:none;}
html.js.t-decisions #panel-decisions,html.js.t-projects #panel-projects,
html.js.t-activity #panel-activity,html.js.t-system #panel-system{display:block;}
.panel > section:last-child{margin-bottom:0;}
@media(prefers-reduced-motion:reduce){.tab{transition:none}}

/* ---- deferred shelf ----
   Set aside, not lost: closed by default, no colour, no chevron chase. It reads
   as secondary to the waiting list directly above it. */
.shelf{margin-top:14px;border:1px solid var(--line);border-radius:14px;background:var(--panel);}
.shelf summary{display:flex;align-items:center;gap:9px;padding:12px 20px;cursor:pointer;
  color:var(--muted);font-size:13px;list-style:none;border-radius:14px;}
.shelf summary::-webkit-details-marker{display:none;}
.shelf summary:hover{color:var(--ink);}
.shelf summary:focus-visible{outline:2px solid var(--amber);outline-offset:-2px;}
.shelf .stitle{font-weight:600;}
.shelf .scount{color:var(--faint);margin-left:auto;text-align:right;}
.shelf .chev{color:var(--faint);flex:none;width:13px;height:13px;transition:transform .15s ease;}
.shelf[open] .chev{transform:rotate(90deg);}
@media(prefers-reduced-motion:reduce){.shelf .chev{transition:none}}
.shelf-body{border-top:1px solid var(--line);}
.defer{display:flex;align-items:flex-start;gap:14px;padding:13px 20px;border-top:1px solid var(--line);}
.defer:first-child{border-top:none;}
.defer .tag{flex:none;width:132px;font-size:12px;font-weight:600;color:var(--faint);overflow-wrap:anywhere;}
.defer .ask{flex:1;font-size:13.5px;color:var(--muted);overflow-wrap:anywhere;}
.defer .hint{display:block;color:var(--faint);font-size:12px;margin-top:2px;}
.shelf-note{margin:0;padding:12px 20px;border-top:1px solid var(--line);
  color:var(--faint);font-size:12px;}
.shelf-note.warn{color:var(--amber);}

/* ---- sections ---- */
section{margin-bottom:38px;}
.sec-h{display:flex;align-items:baseline;gap:10px;margin:0 0 14px;flex-wrap:wrap;}
.sec-h h2{font-size:15px;font-weight:640;letter-spacing:.01em;margin:0;}
.sec-h .count{color:var(--faint);font-size:13px;font-weight:500;}
.quiet{color:var(--muted);font-size:13.5px;margin:0;padding:15px 22px;background:var(--panel);
  border:1px solid var(--line);border-radius:14px;box-shadow:var(--shadow);}
.clear{color:var(--green);font-size:13.5px;margin:0;}
.quiet + .quiet,.quiet + .projects,.quiet + .needs,.quiet + .shipped{margin-top:14px;}

/* ---- awaiting your decision ---- */
.needs{background:var(--panel);border:1px solid var(--line);border-radius:16px;box-shadow:var(--shadow);overflow:hidden;}
.need{display:flex;align-items:center;gap:14px;padding:15px 22px;border-top:1px solid var(--line);}
.need:first-child{border-top:none;}
.band{width:3px;align-self:stretch;border-radius:3px;background:var(--amber);flex:none;}
.need.warn .band{background:var(--red);}
.tag{flex:none;width:132px;font-size:12.5px;font-weight:600;color:var(--slate);overflow-wrap:anywhere;}
.need.warn .tag{color:var(--red);}
.need .ask{flex:1;font-size:14.5px;color:var(--ink);overflow-wrap:anywhere;}
.need .hint{display:block;color:var(--muted);font-size:12.5px;font-weight:400;margin-top:2px;}
.need .url{display:block;color:var(--faint);font-family:var(--mono);font-size:11.5px;margin-top:4px;overflow-wrap:anywhere;}
.need .go{flex:none;color:var(--faint);font-size:18px;width:10px;text-align:right;}
a.need:hover{background:#fbfcfe;}

/* ---- project grid ---- */
.projects{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px;}
.proj{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:18px 20px 16px;
  box-shadow:var(--shadow);position:relative;display:flex;flex-direction:column;gap:9px;}
.proj::before{content:\"\";position:absolute;left:0;top:14px;bottom:14px;width:3px;border-radius:3px;background:var(--slate-soft);}
.proj.s-live::before{background:var(--green);}
.proj.s-attn::before{background:var(--amber);}
.proj.s-idle::before{background:#d5dae2;}
.proj.s-unknown::before{background:repeating-linear-gradient(180deg,#c9d0da 0 4px,transparent 4px 8px);}
.proj-top{display:flex;align-items:center;gap:12px;}
.badge{width:34px;height:34px;border-radius:9px;background:var(--slate-soft);color:var(--slate);
  display:flex;align-items:center;justify-content:center;flex:none;}
.badge svg{width:19px;height:19px;}
.proj-name{font-size:15px;font-weight:630;letter-spacing:-.01em;flex:1;overflow-wrap:anywhere;}
.sub-role{color:var(--faint);font-weight:500;font-size:12px;margin-left:4px;}
.pill{font-size:11.5px;font-weight:600;padding:3px 10px;border-radius:999px;letter-spacing:.02em;flex:none;}
.pill.live{color:var(--green);background:var(--green-soft);}
.pill.attn{color:var(--amber);background:var(--amber-soft);}
.pill.idle{color:var(--slate);background:var(--slate-soft);}
.pill.unknown{color:var(--muted);background:transparent;border:1px dashed #c3cbd6;padding:2px 9px;}
.proj-state{color:var(--muted);font-size:13.5px;overflow-wrap:anywhere;}
.proj-meta{color:var(--faint);font-size:12.5px;margin-top:1px;}
.proj-updated{display:flex;align-items:center;gap:6px;color:var(--faint);font-size:11.5px;
  margin-top:auto;padding-top:8px;flex-wrap:wrap;}
.proj-updated svg{width:12px;height:12px;flex:none;color:var(--faint);}
.posture{font-family:var(--mono);font-size:10.5px;color:var(--faint);margin-left:auto;overflow-wrap:anywhere;}

/* ---- shipped ---- */
.shipped{background:var(--panel);border:1px solid var(--line);border-radius:16px;box-shadow:var(--shadow);overflow:hidden;}
.ship{display:flex;align-items:center;gap:14px;padding:12px 22px;border-top:1px solid var(--line);font-size:14px;}
.ship:first-child{border-top:none;}
.ship .ck{color:var(--green);flex:none;width:16px;height:16px;}
.ship .what{overflow-wrap:anywhere;}
.ship .who{color:var(--faint);font-size:12.5px;margin-left:auto;flex:none;padding-left:10px;}
a.ship:hover{background:#fbfcfe;}

/* ---- health and allowance strip ---- */
.strip{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px;}
.pane{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:18px 20px;box-shadow:var(--shadow);}
.pane h3{font-size:13px;font-weight:640;margin:0 0 12px;letter-spacing:.01em;}
.pane h3 .count{color:var(--faint);font-weight:500;margin-left:6px;}
.hlist{margin:0;padding:0;list-style:none;}
.hlist li{display:flex;gap:10px;font-size:13px;margin-bottom:10px;}
.hlist li:last-child{margin-bottom:0;}
.hstate{flex:none;font-family:var(--mono);font-size:11px;color:var(--red);background:var(--red-soft);
  border-radius:5px;padding:2px 7px;align-self:flex-start;}
.hstate.wait{color:var(--amber);background:var(--amber-soft);}
.hwhat{color:var(--ink);overflow-wrap:anywhere;}
.hwhat .hint{display:block;color:var(--faint);font-size:11.5px;font-family:var(--mono);margin-top:2px;}
.gauge{margin-bottom:14px;}
.gauge:last-child{margin-bottom:0;}
.glabel{display:flex;justify-content:space-between;gap:10px;font-size:12px;color:var(--muted);margin-bottom:6px;}
.glabel span:first-child{overflow-wrap:anywhere;}
.gval{font-family:var(--mono);color:var(--ink);font-weight:600;flex:none;font-size:11.5px;}
.bar{height:6px;border-radius:4px;background:var(--slate-soft);overflow:hidden;}
.bar i{display:block;height:100%;background:var(--green);}
.tone-warn .bar i{background:var(--amber);}
.tone-alert .bar i{background:var(--red);}
.tone-muted .bar i{background:#d5dae2;}
.gnote{font-size:11px;color:var(--faint);margin-top:5px;font-family:var(--mono);overflow-wrap:anywhere;}
.unmeasured{margin:14px 0 0;padding:12px 0 0;border-top:1px solid var(--line);list-style:none;}
.unmeasured li{display:flex;justify-content:space-between;gap:12px;font-size:12px;color:var(--muted);margin-bottom:7px;}
.unmeasured li:last-child{margin-bottom:0;}
.unmeasured .gval{color:var(--faint);font-size:11px;text-align:right;overflow-wrap:anywhere;}
.pane .quiet{padding:0;border:none;box-shadow:none;background:none;}

footer{color:var(--faint);font-size:12px;text-align:center;margin-top:10px;overflow-wrap:anywhere;}

@media(max-width:720px){
  .stats{grid-template-columns:repeat(2,minmax(0,1fr))}
  .projects,.strip{grid-template-columns:minmax(0,1fr)}
  .wrap{padding:28px 18px 48px}
  .need{align-items:flex-start;flex-wrap:wrap;padding:14px 16px;gap:10px}
  .tag{width:auto}
  .need .go{display:none}
  .ship{padding:12px 16px;align-items:flex-start;flex-wrap:wrap}
  .ship .what{flex:1 1 auto}
  .ship .who{margin-left:0;padding-left:0;flex:1 0 100%}
  .defer{padding:12px 16px;flex-wrap:wrap;gap:8px}
  .defer .tag{width:auto}
  .shelf summary,.shelf-note{padding-left:16px;padding-right:16px}
}
/* Four tabs still have to fit an iPhone without a sideways scroll, so below
   this width the label sits under the glyph rather than beside it. */
@media(max-width:520px){
  .js .tabs{gap:3px;padding:4px}
  .tab{flex-direction:column;gap:3px;padding:8px 4px;font-size:11.5px;letter-spacing:-.01em}
}
" + controls_css + "</style>
<script>
/* Chooses the tab before the body is parsed, so the board opens on the tab it
   was left on with no flash of the default one.

   The self-reload is a meta refresh, which navigates without the fragment, so
   the URL hash cannot be the mechanism that survives a reload - it is only an
   entry point for a hand-typed or copied link. The remembered tab is what
   actually survives, and a browser that refuses storage (a private context, or
   a restricted file:// origin) simply opens on the default tab. */
(function () {
  var keys = [\"decisions\", \"projects\", \"activity\", \"system\"];
  var key = \"decisions\";
  var m = /^#(?:tab=|panel-)([a-z]+)$/.exec(window.location.hash || \"\");
  try {
    if (m && keys.indexOf(m[1]) !== -1) {
      window.localStorage.setItem(\"fm-mission-control-tab\", m[1]);
      key = m[1];
    } else {
      var saved = window.localStorage.getItem(\"fm-mission-control-tab\");
      if (saved && keys.indexOf(saved) !== -1) { key = saved; }
    }
  } catch (e) { /* storage unavailable; the default tab is correct */ }
  document.documentElement.className = \"js t-\" + key;
}());
</script>
</head><body>
<div class=\"wrap\">
  <header>
    <div>
      <h1>Mission Control</h1>
      <p class=\"sub\">Your fleet at a glance, Captain.</p>
    </div>
    <span class=\"live\" id=\"live\"><span class=\"dot\"></span><span id=\"age\">live &middot; rendered "
+ (@html "\(.generated)") + "</span></span>
  </header>

  <div class=\"stats\">"
+ stat(icon_bell;
       "\($waiting_count)\(if $waiting_incomplete then "+" else "" end)";
       "Awaiting you";
       (if $waiting_incomplete then "some sources unavailable" else "" end);
       ($waiting_count > 0 or $waiting_incomplete))
+ stat(icon_pulse;
       "\($in_progress_count)\(if $in_progress_incomplete then "+" else "" end)";
       "In progress";
       (if $in_progress_incomplete then "second mate activity incomplete"
        elif $active_details_omitted > 0 then "\($active_details_omitted) active task details omitted"
        else "" end);
       $in_progress_incomplete)
+ stat(icon_shipped;
       (if $backlog_present then "\($shipped | length)" else "?" end);
       "Shipped today";
       (if ($backlog_present | not) then "backlog unavailable"
        elif $shipped_undated > 0 then "\($shipped_undated) landed with no recorded date"
        else "" end);
       (($backlog_present | not) or $shipped_undated > 0))
+ stat(icon_folder;
       "\($card_count)\(if $card_count_incomplete then "+" else "" end)";
       "Projects";
       (((if ($projects_present | not) then ["project registry unavailable"] else [] end)
         + (if ($sm_registry_complete | not) then ["second mate list incomplete"] else [] end))
        | join(", "));
       $card_count_incomplete)
+ "</div>
"
+ (if ($health_count > 0) or $health_incomplete or ($backlog_present | not)
   then "<a class=\"attnbar\" href=\"#health\" data-tab=\"system\">" + icon_alert
     + (@html "<span>\(if $health_count > 0 then "\(if $secondmate_hold_count > 0 then "\($health_count) fleet health \(plural($health_count; "item needs"; "items need")) attention" else "\($health_count) \(plural($health_count; "item is"; "items are")) blocked or failed" end)\(if $health_incomplete or ($backlog_present | not) then "; health details are incomplete" else "" end)" else "Fleet health cannot be confirmed from the available sources" end)</span>")
     + "<span class=\"go\">&rsaquo;</span></a>"
   else "" end)
+ "
  <nav class=\"tabs\" role=\"tablist\" aria-label=\"Board sections\">
    <a class=\"tab\" id=\"tab-decisions\" role=\"tab\" data-tab=\"decisions\"
       href=\"#panel-decisions\" aria-controls=\"panel-decisions\">"
+ icon_bell + "<span>Decisions</span></a>
    <a class=\"tab\" id=\"tab-projects\" role=\"tab\" data-tab=\"projects\"
       href=\"#panel-projects\" aria-controls=\"panel-projects\">"
+ icon_folder + "<span>Projects</span></a>
    <a class=\"tab\" id=\"tab-activity\" role=\"tab\" data-tab=\"activity\"
       href=\"#panel-activity\" aria-controls=\"panel-activity\">"
+ icon_shipped + "<span>Activity</span></a>
    <a class=\"tab\" id=\"tab-system\" role=\"tab\" data-tab=\"system\"
       href=\"#panel-system\" aria-controls=\"panel-system\">"
+ icon_gauge + "<span>System</span></a>
  </nav>

  <div class=\"panel\" id=\"panel-decisions\" role=\"tabpanel\" aria-labelledby=\"tab-decisions\">
  <section>
    <div class=\"sec-h\"><h2>Awaiting your decision</h2>"
+ (@html "<span class=\"count\">\($waiting_count) \(plural($waiting_count; "item"; "items"))")
+ (if $waiting_incomplete then " &middot; waiting status incomplete" else "" end)
+ "</span></div>"
+ (if $waiting_count == 0 and ($waiting_incomplete | not)
   then "<p class=\"quiet\">Nothing needs your decision right now.</p>"
   else "<div class=\"needs\">"
     + (($waiting_notices | map(need_item) | add) // "")
     + (($waiting_calls | map(need_item) | add) // "")
     + (($waiting_prs | map(need_item) | add) // "") + "</div>" end)
+ ask_block
+ (if $deferred_count == 0 then ""
   else "<details class=\"shelf\"><summary>"
     + "<svg class=\"chev\" viewBox=\"0 0 24 24\"><polyline points=\"9 6 15 12 9 18\"/></svg>"
     + "<span class=\"stitle\">Deferred</span>"
     + (@html "<span class=\"scount\">\($deferred_count) set aside</span>")
     + "</summary><div class=\"shelf-body\">"
     + (($deferred | map(deferred_row) | add) // "")
     + (if $deferred_bounded > 0 then
         (@html "<p class=\"shelf-note warn\">\($deferred_bounded) queued second mate \(plural($deferred_bounded; "row was"; "rows were")) not read, so a decision set aside there may be missing from this list.</p>")
        else "" end)
     + "<p class=\"shelf-note\">Set aside on your word, and brought back the same way - ask firstmate for any of these when you want it in view again.</p>"
     + "</div></details>" end)
+ "  </section>
  </div>

  <div class=\"panel\" id=\"panel-projects\" role=\"tabpanel\" aria-labelledby=\"tab-projects\">
  <section>
    <div class=\"sec-h\"><h2>Projects</h2>"
+ (if $card_count_incomplete then "<span class=\"count\">list incomplete</span>" else "" end)
+ "</div>"
+ (if ($projects_present | not)
   then "<p class=\"quiet\">No project registry found - firstmate rebuilds it from the clones.</p>"
   else "" end)
+ (if $sm_registry_complete and ($secondmate_cards | length) == 0
   then "<p class=\"quiet\">No second mates registered.</p>" else "" end)
+ (if $card_count == 0 then ""
   else "<div class=\"projects\">"
     + (($project_cards | map(project_card) | add) // "")
     + (($secondmate_cards | map(secondmate_card) | add) // "") + "</div>" end)
+ "  </section>
  </div>

  <div class=\"panel\" id=\"panel-activity\" role=\"tabpanel\" aria-labelledby=\"tab-activity\">
  <section>
    <div class=\"sec-h\"><h2>Shipped today</h2>"
+ (if $backlog_present
   then (@html "<span class=\"count\">\($shipped | length) \(plural($shipped | length; "item"; "items"))</span>")
   else "<span class=\"count\">unavailable</span>" end)
+ "</div>"
+ (if ($backlog_present | not)
   then "<p class=\"quiet\">Shipped today is unavailable because the backlog could not be read.</p>"
   elif ($shipped | length) == 0
   then "<p class=\"quiet\">Nothing landed yet today.</p>"
   else "<div class=\"shipped\">" + (($shipped | map(. as $d |
     (($d.pr_url // $d.report_path // ($d.links // [])[0]) // "") as $link |
     (if $link == "" then "<div class=\"ship\">" else (@html "<a class=\"ship\" href=\"\($link)\">") end)
     + icon_check
     + (@html "<span class=\"what\">\(dash($d.title // $d.raw))</span><span class=\"who\">\(dash(($d.repo // "") | short_repo))</span>")
     + (if $link == "" then "</div>" else "</a>" end)) | add) // "") + "</div>" end)
+ "  </section>
  </div>

  <div class=\"panel\" id=\"panel-system\" role=\"tabpanel\" aria-labelledby=\"tab-system\">
  <section class=\"strip\" id=\"health\">
    <div class=\"pane\">"
+ (@html "<h3>Fleet health<span class=\"count\">\(if $health_count > 0 then "\($health_count) \(plural($health_count; "item"; "items"))\(if $health_incomplete or ($backlog_present | not) then "+" else "" end)" elif $health_incomplete or ($backlog_present | not) then "incomplete" else "all clear" end)</span></h3>")
+ health_block
+ "    </div>
    <div class=\"pane\">
      <h3>Allowance</h3>"
+ quota_block
+ "    </div>
  </section>
  </div>

"
+ (@html "<footer>firstmate &middot; mission control &middot; home \(.fm_home) &middot; snapshot \(.schema) &middot; rendered \(.generated) &middot; self-reload \($refresh)s</footer>")
+ "
</div>

<script>
(function () {
  var rendered = " + (.generated | @json | gsub("<"; "\\u003c")) + ";
  var stamp = Date.parse(rendered);
  var age = document.getElementById(\"age\");
  var live = document.getElementById(\"live\");
  function tick() {
    if (isNaN(stamp)) { return; }
    var s = Math.max(0, Math.round((Date.now() - stamp) / 1000));
    var text = s < 60 ? s + \"s ago\"
      : s < 3600 ? Math.floor(s / 60) + \"m ago\"
      : Math.floor(s / 3600) + \"h \" + Math.floor((s % 3600) / 60) + \"m ago\";
    age.textContent = \"live \" + String.fromCharCode(183) + \" updated \" + text;
    live.className = s > " + (($refresh * 4) | tostring) + " ? \"live stale\" : \"live\";
  }
  tick();
  setInterval(tick, 1000);
}());

/* Tab behaviour. The <head> script already painted the right panel; this adds
   the interaction and the state a screen reader reads. */
(function () {
  var keys = [\"decisions\", \"projects\", \"activity\", \"system\"];
  var root = document.documentElement;
  var tabs = keys.map(function (k) { return document.getElementById(\"tab-\" + k); });
  if (tabs.indexOf(null) !== -1) { return; }

  function current() {
    for (var i = 0; i < keys.length; i++) {
      if (root.classList.contains(\"t-\" + keys[i])) { return keys[i]; }
    }
    return keys[0];
  }

  function paint() {
    var key = current();
    tabs.forEach(function (tab, i) {
      var on = keys[i] === key;
      tab.setAttribute(\"aria-selected\", on ? \"true\" : \"false\");
      tab.tabIndex = on ? 0 : -1;
    });
  }

  function select(key, focus) {
    if (keys.indexOf(key) === -1) { return; }
    root.className = \"js t-\" + key;
    try { window.localStorage.setItem(\"fm-mission-control-tab\", key); } catch (e) { /* not remembered */ }
    /* #tab=<key> matches no element, so restoring it never scrolls the header
       off the top. The self-reload drops it regardless; the stored tab is what
       carries across. */
    try { history.replaceState(null, \"\", \"#tab=\" + key); } catch (e) { /* URL left alone */ }
    paint();
    if (focus) { tabs[keys.indexOf(key)].focus(); }
  }

  document.addEventListener(\"click\", function (ev) {
    var el = ev.target;
    if (el && el.nodeType !== 1) { el = el.parentElement; }
    el = el && el.closest ? el.closest(\"[data-tab]\") : null;
    if (!el) { return; }
    var key = el.getAttribute(\"data-tab\");
    if (keys.indexOf(key) === -1) { return; }
    ev.preventDefault();
    select(key, false);
  });

  document.querySelector(\".tabs\").addEventListener(\"keydown\", function (ev) {
    var at = keys.indexOf(current());
    var to = -1;
    if (ev.key === \"ArrowRight\") { to = (at + 1) % keys.length; }
    else if (ev.key === \"ArrowLeft\") { to = (at + keys.length - 1) % keys.length; }
    else if (ev.key === \"Home\") { to = 0; }
    else if (ev.key === \"End\") { to = keys.length - 1; }
    if (to === -1) { return; }
    ev.preventDefault();
    select(keys[to], true);
  });

  paint();

  /* The shelf is held to the same bar as the tabs: opening it to read three
     decisions must not be undone by the next self-reload. It is remembered the
     same way, so it stays shut for a captain who never opens it and stays open
     for one who does, until they close it again. */
  var shelf = document.querySelector(\"details.shelf\");
  if (shelf) {
    try {
      if (window.localStorage.getItem(\"fm-mission-control-deferred\") === \"open\") { shelf.open = true; }
    } catch (e) { /* not remembered; closed is the right default */ }
    shelf.addEventListener(\"toggle\", function () {
      try {
        window.localStorage.setItem(\"fm-mission-control-deferred\", shelf.open ? \"open\" : \"closed\");
      } catch (e) { /* not remembered */ }
    });
  }
}());
</script>
"
+ (if ($controls | not) then "" else
"<script>
/* The captain reply layer. It queues requests and performs nothing: the only
   call it makes is to the Lavish bridge, and the only thing it sends is one
   FM-BOARD-REQUEST line per deliberate tap. There is no endpoint, no token, and
   no action here, so a tap can never be the thing that merges, answers, or sets
   anything aside - firstmate decides all of that under its own contract. */
(function () {
  var tries = 0;

  function bridge() {
    return (window.lavish && typeof window.lavish.queuePrompt === \"function\"
      && typeof window.lavish.sendQueuedPrompts === \"function\") ? window.lavish : null;
  }

  /* The controls stay hidden until the bridge is proved present, so a statically
     served copy of this same file shows the read-only board and nothing else.
     The bridge may be injected just after this runs, so give it a short window
     rather than deciding on the first frame. */
  function reveal() {
    if (bridge()) { document.body.classList.add(\"lavish\"); return; }
    if (++tries < 20) { setTimeout(reveal, 150); }
  }
  reveal();

  function formsIn(block) {
    return Array.prototype.slice.call(block.querySelectorAll(\".rc-f\"));
  }

  function shut(block) {
    formsIn(block).forEach(function (f) {
      if (f.hasAttribute(\"data-toggle\")) { f.hidden = true; }
    });
  }

  function say(block, message, bad) {
    var sent = block.querySelector(\".rc-sent\");
    if (!sent) { return; }
    sent.hidden = false;
    sent.textContent = message;
    if (bad) { sent.classList.add(\"rc-bad\"); } else { sent.classList.remove(\"rc-bad\"); }
  }

  function summary(intent, what) {
    if (intent === \"merge\")  { return \"From the board - please merge: \" + what; }
    if (intent === \"defer\")  { return \"From the board - set aside: \" + what; }
    if (intent === \"answer\") { return \"From the board - answer on: \" + what; }
    if (intent === \"reply\")  { return \"From the board - note on: \" + what; }
    return \"From the board - a new ask\";
  }

  document.addEventListener(\"click\", function (ev) {
    var el = ev.target;
    if (el && el.nodeType !== 1) { el = el.parentElement; }
    if (!el || !el.closest) { return; }

    var opener = el.closest(\"[data-open]\");
    if (opener) {
      var block = opener.closest(\".rc\");
      if (!block) { return; }
      var want = opener.getAttribute(\"data-open\");
      var already = false;
      formsIn(block).forEach(function (f) {
        if (f.getAttribute(\"data-intent\") === want && !f.hidden) { already = true; }
        if (f.hasAttribute(\"data-toggle\")) { f.hidden = true; }
      });
      if (!already) {
        formsIn(block).forEach(function (f) {
          if (f.getAttribute(\"data-intent\") !== want) { return; }
          f.hidden = false;
          var area = f.querySelector(\".rc-t\");
          if (area) { area.focus(); }
        });
      }
      return;
    }

    var cancel = el.closest(\".rc-x\");
    if (cancel) {
      var owner = cancel.closest(\".rc\");
      if (owner) { shut(owner); }
    }
  });

  document.addEventListener(\"submit\", function (ev) {
    var form = ev.target;
    if (!form || !form.classList || !form.classList.contains(\"rc-f\")) { return; }
    ev.preventDefault();
    var block = form.closest(\".rc\");
    if (!block) { return; }

    var area = form.querySelector(\".rc-t\");
    var note = area ? area.value.replace(/^\\s+|\\s+$/g, \"\") : \"\";
    if (area && !note) { area.focus(); return; }

    var request = {
      v: 1,
      intent: form.getAttribute(\"data-intent\"),
      home: block.getAttribute(\"data-home\") || \"main\"
    };
    var id = block.getAttribute(\"data-id\");
    var key = block.getAttribute(\"data-key\");
    if (id) { request.id = id; }
    if (key) { request.key = key; }
    if (note) { request.note = note; }

    var lav = bridge();
    if (!lav) { say(block, \"Not sent - this board is not connected to firstmate.\", true); return; }
    try {
      lav.queuePrompt(\"FM-BOARD-REQUEST \" + JSON.stringify(request), {
        tag: \"board-request\",
        text: summary(request.intent, block.getAttribute(\"data-what\") || \"\")
      });
      lav.sendQueuedPrompts();
    } catch (e) {
      say(block, \"Not sent - the board could not reach firstmate.\", true);
      return;
    }
    if (area) { area.value = \"\"; }
    shut(block);
    say(block, \"Sent to firstmate.\", false);
  });

  /* With the controls on, the meta refresh sits in <noscript> and this owns the
     cadence, so a reload can be held while a control is open or carries typed
     text instead of discarding what the captain is part way through writing. */
  var every = " + (($refresh * 1000) | tostring) + ";
  var due = Date.now() + every;

  function busy() {
    var open = document.querySelectorAll(\".rc-f[data-toggle]\");
    var i;
    for (i = 0; i < open.length; i++) { if (!open[i].hidden) { return true; } }
    var areas = document.querySelectorAll(\".rc-t\");
    for (i = 0; i < areas.length; i++) {
      if (areas[i].value.replace(/^\\s+|\\s+$/g, \"\")) { return true; }
    }
    return false;
  }

  setInterval(function () {
    if (Date.now() < due) { return; }
    if (busy()) { return; }
    window.location.reload();
  }, 1000);
}());
</script>
" end)
+ "</body></html>
"
'
) || die "rendering failed"

if [ "$TO_STDOUT" = 1 ]; then
  printf '%s\n' "$HTML"
  exit 0
fi

if [ -z "$OUT" ]; then
  [ -n "$STATE_DIR" ] || die "snapshot reported no state directory; pass --out"
  OUT="$STATE_DIR/mission-control.html"
fi

OUT_DIR=$(dirname "$OUT")
mkdir -p "$OUT_DIR" || die "could not create $OUT_DIR"
TMP="$OUT_DIR/.$(basename "$OUT").$$.tmp"
printf '%s\n' "$HTML" > "$TMP" || { rm -f "$TMP"; die "could not write $TMP"; }
mv -f "$TMP" "$OUT" || { rm -f "$TMP"; die "could not move board into $OUT"; }
printf '%s\n' "$OUT"
