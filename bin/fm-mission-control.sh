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
# secondmate current state keep exactly one owner. Three concerns come from
# outside the snapshot because the snapshot does not own them: data/projects.md
# is the delivery-posture registry; the local Token Dashboard API owns richer
# allowance history, pace, and balancing with `quota-axi --json` as the live-only
# fallback; each project card's last-change time comes from that project's own
# clone or, for a second mate, from when it last reported; and the narrow,
# forward-only autonomous-actions record supplies the recent action feed.
#
# The board never invents a completion percentage or an ETA. Progress judgement
# belongs to firstmate, so each project card states only what live state can
# prove: what is under way, what waits on the captain, and when it last changed.
#
# A card lists its in-progress work item by item - what each one is, how far it
# has travelled, and the model doing it - because a bare count tells the captain
# something is happening without telling them what. "How far" is the snapshot's
# derived lifecycle stage, drawn as five discrete rungs and always labelled with
# the stage name, so it reads as "this has reached Validating" and never as a
# fraction of the work done. The stage itself is never re-derived here; the
# snapshot owns it, as it owns every other piece of fleet state on this page.
# Setup uses the neutral slate quiet tone because endpoint presence does not prove
# movement; observed work alone uses the green live tone.
# The first six items stay open at a glance and every additional received item
# remains available in the same expandable shelf idiom as Deferred. Rows omitted
# upstream remain disclosed separately and are never presented as shelf contents.
# Only the Deferred shelf persists its open state; project overflow shelves do not
# read or write that preference.
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
#   fm-mission-control.sh --no-quota       skip local allowance reads
#   fm-mission-control.sh --refresh <sec>  self-reload interval (default 25)
#   fm-mission-control.sh --controls       add the captain reply layer
#   fm-mission-control.sh --snapshot <f>   render a captured snapshot JSON file
#   fm-mission-control.sh -h|--help        usage
#
# Environment:
#   FM_MISSION_CONTROL_NOW_EPOCH  fix "now" for deterministic rendering.
#   FM_MISSION_CONTROL_QUOTA_JSON path to a captured quota-axi --json payload,
#                                 used instead of running quota-axi.
#   FM_MISSION_CONTROL_TOKEN_JSON path to a captured Token Dashboard API payload.
#   FM_MISSION_CONTROL_TOKEN_URL  local Token Dashboard API URL (default
#                                 http://127.0.0.1:4173/api/dashboard).
#
# Deferring a decision:
#   Firstmate sets a captain decision aside on the captain's word, in the home
#   whose backlog holds it, by changing that item's HOLD KIND alone - from
#   captain to tasks-axi's existing "parked" - and reverses it by restoring
#   captain. The hold kind, not the item's own kind, marks it as a captain
#   decision, so this preserves ship, scout, and standalone captain work alike.
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
#   does exactly one thing: record ONE request that wakes firstmate. It performs no
#   action, reaches no external host, and carries no authority; firstmate
#   adjudicates each request under its own contract, exactly as if the captain had
#   said the same words in chat. The surface is reachable by anything that can
#   reach the service serving it, so reachability is never authorization.
#
#   A request travels to THIS DOCUMENT'S OWN URL, so the board needs no endpoint
#   and no knowledge of how it is served or proxied. bin/fm-procevent-board-reply.sh
#   owns that service, arming the wake, and normalizing what comes back. The legacy
#   Lavish bridge remains supported for a board served through Lavish and is not
#   extended; see docs/mission-control.md for both and for their limits.
#
#   The layer is hidden by CSS and revealed only after a script PROVES a transport
#   that can reach firstmate, so the same file served statically or opened from
#   disk is the read-only board it is without this flag, and no viewer is ever
#   shown a dead control. An acknowledged control is then replaced in place by a
#   full-width confirmation banner claiming only what the transport proved.
#   With script available, session-scoped presentation memory preserves the
#   active tab and stable reading position across both managed reloads and full
#   document replacement after an external output-file rewrite. --controls also
#   saves every open composer and unsent draft under its exact control identity,
#   and holds the managed timer while a control is open. The no-script fallback
#   keeps the same cadence with a meta refresh and remains the read-only board.
#
#   Each request is one line: FM-BOARD-REQUEST followed by one JSON object.
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

# This deliberately is not a history view.  The append-only record remains
# private state, while the board admits only its eight newest valid entries
# from the previous 12 hours and offers no older-page control.
RECENT_ACTION_WINDOW_SECS=43200
RECENT_ACTION_LIMIT=8
RECENT_ACTIONS_FILE="$STATE_DIR/autonomous-actions.ndjson"
recent_actions_json() {
  [ -r "$RECENT_ACTIONS_FILE" ] || { printf '[]\n'; return 0; }
  jq -R -s --argjson now "$NOW" \
    --argjson cutoff "$((NOW - RECENT_ACTION_WINDOW_SECS))" \
    --argjson limit "$RECENT_ACTION_LIMIT" '
      def text($maximum):
        (type == "string") and (length > 0) and (length <= $maximum)
        and (test("[\u0000-\u001f\u007f]") | not);
      [split("\n")[] | select(length > 0) |
       (fromjson? | select(type == "object")) |
       select((.ts | type == "number") and (.ts | floor == .)
              and .ts >= $cutoff and .ts <= $now) |
       if .kind == "decision" then
         select((.project | text(160)) and (.finding | text(400)) and (.decision | text(400))) |
         {ts, kind, project, finding, decision}
       elif .kind == "merge" then
         select((.project | text(160)) and (.pr_url | text(2048))
                and (.pr_url | startswith("https://"))) |
         {ts, kind, project, pr_url}
       else empty end]
      | sort_by(.ts) | reverse | .[:$limit]
    ' "$RECENT_ACTIONS_FILE" 2>/dev/null || printf '[]\n'
}
RECENT_ACTIONS=$(recent_actions_json)

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

# The richer local Token Dashboard already owns normalization, history, pace
# thresholds, and the balancing feed. Mission Control reads that public API and
# immediately narrows it to the fields this board renders. Session rows, task
# details, reasons, and unknown future fields never enter the generated page.
# If that service is absent, the existing quota-axi read remains the reversible
# fallback and is labelled as a live-only view rather than fabricated history.
sanitize_token_dashboard() {
  jq -c '
    if type != "object" then empty else
    {
      latest: (if (.latest | type) == "object" then {
        capturedAt: .latest.capturedAt,
        windows: [(.latest.windows // [])[] | {
          key, provider, providerLabel, id, label, shortLabel,
          percentUsed, percentRemaining, resetsAt, windowSeconds,
          pace: {status: .pace.status, elapsedPercent: .pace.elapsedPercent,
                 reservePercentPoints: .pace.reservePercentPoints,
                 burnMultiple: .pace.burnMultiple,
                 projectedExhaustedAt: .pace.projectedExhaustedAt}
        }]
      } else null end),
      historyCount: ((.history // []) | length),
      history: ([((.history // [])[] | {
        capturedAt,
        windows: [(.windows // [])[] | {key, percentUsed, resetsAt}]
      })] | if length > 672 then .[-672:] else . end),
      settings: {paceThresholds: {
        fiveHour: {comfortable: .settings.paceThresholds.fiveHour.comfortable,
                   edge: .settings.paceThresholds.fiveHour.edge},
        weekly: {comfortable: .settings.paceThresholds.weekly.comfortable,
                 edge: .settings.paceThresholds.weekly.edge}
      }},
      lastError: (if (.lastError | type) == "object" then {at: .lastError.at} else null end),
      balancing: {
        error: .balancing.error,
        actions: [(.balancing.actions // [])[:20][] | {
          ts, action, providerEased, auto
        }]
      },
      refreshIntervalMs: .refreshIntervalMs
    }
    end
  '
}

TOKEN_DASH='null'
TOKEN_DASH_NOTE="not requested"
QUOTA='null'
QUOTA_NOTE="not requested"
if [ "$WITH_QUOTA" = 1 ]; then
  token_raw=""
  token_candidate=""
  try_token=1

  # A captured raw quota payload is an explicit fixture or operator override.
  # Do not let a live local service make that deterministic input non-deterministic.
  if [ -z "${FM_MISSION_CONTROL_TOKEN_JSON:-}" ] && [ -n "${FM_MISSION_CONTROL_QUOTA_JSON:-}" ]; then
    try_token=0
    TOKEN_DASH_NOTE="captured quota payload selected"
  fi

  if [ "$try_token" = 1 ] && [ -n "${FM_MISSION_CONTROL_TOKEN_JSON:-}" ]; then
    if [ -r "$FM_MISSION_CONTROL_TOKEN_JSON" ]; then
      token_raw=$(cat "$FM_MISSION_CONTROL_TOKEN_JSON" 2>/dev/null) || token_raw=""
      TOKEN_DASH_NOTE="captured token payload unreadable"
    else
      TOKEN_DASH_NOTE="captured token payload not found"
    fi
  elif [ "$try_token" = 1 ]; then
    token_url=${FM_MISSION_CONTROL_TOKEN_URL:-http://127.0.0.1:4173/api/dashboard}
    token_authority=${token_url#http://}
    token_authority=${token_authority%%/*}
    token_host=${token_authority%:*}
    token_port=${token_authority##*:}
    case "$token_host:$token_port" in
      127.0.0.1:*|localhost:*)
        case "$token_port" in
          ''|*[!0-9]*) TOKEN_DASH_NOTE="token dashboard URL must be local" ;;
          *)
            if command -v curl >/dev/null 2>&1; then
              token_raw=$(curl --disable --proto '=http' --noproxy '*' --fail --silent \
                --max-filesize 8388608 --max-time 2 "$token_url" 2>/dev/null) || token_raw=""
              TOKEN_DASH_NOTE="local token dashboard not reachable"
            else
              TOKEN_DASH_NOTE="curl not installed for the local token dashboard read"
            fi
            ;;
        esac
        ;;
      *) TOKEN_DASH_NOTE="token dashboard URL must be local" ;;
    esac
  fi

  if [ -n "$token_raw" ]; then
    token_candidate=$(printf '%s' "$token_raw" | sanitize_token_dashboard 2>/dev/null) || token_candidate=""
    if [ -n "$token_candidate" ] && printf '%s' "$token_candidate" | jq -e 'type == "object"' >/dev/null 2>&1; then
      TOKEN_DASH=$token_candidate
      if printf '%s' "$TOKEN_DASH" | jq -e '.latest | type == "object"' >/dev/null 2>&1; then
        TOKEN_DASH_NOTE=""
      else
        TOKEN_DASH_NOTE="local token history has no successful reading"
      fi
    else
      TOKEN_DASH_NOTE="token dashboard returned no usable reading"
    fi
  fi

  # The richer service may be absent or may not have its first successful
  # snapshot yet. Preserve the old direct allowance view in either case.
  if ! printf '%s' "$TOKEN_DASH" | jq -e '.latest | type == "object"' >/dev/null 2>&1; then
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
fi

render_html() {
  printf '%s' "$SNAPSHOT" | jq -L "$SCRIPT_DIR" -r \
    --argjson quota "$QUOTA" \
    --arg quota_note "$QUOTA_NOTE" \
    --argjson token_dash "$TOKEN_DASH" \
    --arg token_dash_note "$TOKEN_DASH_NOTE" \
    --argjson now "$NOW" \
    --argjson registry "$REGISTRY" \
    --argjson updated "$UPDATED" \
    --argjson recent_actions "$RECENT_ACTIONS" \
    --argjson projects_present "$PROJECTS_PRESENT" \
    --arg today "$TODAY" \
    --argjson controls "$CONTROLS" \
    --argjson refresh "$REFRESH" -f /dev/fd/3 3<<'FM_MISSION_CONTROL_JQ'

include "fm-web-url";

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

def cap_word: (.[0:1] | ascii_upcase) + .[1:];

# A recorded model id is a dispatch identifier, not a name the captain reads, so
# it is reduced to the shortest thing that still names the model. The rules are
# general rather than a table of known models, because a table goes stale the
# day a new model ships:
#   - a provider or namespace prefix is dropped, since the card has room for the
#     model and not for who serves it (openai-codex/gpt-5.6-terra);
#   - a tagged local model keeps its exact tag, which is how it is addressed and
#     the only form its operator would recognise (ollama/qwen3.6:35b-fm);
#   - otherwise a vendor token and a trailing release stamp are dropped, a split
#     version is rejoined, and the remaining words are capitalised, so
#     claude-opus-5 reads Opus 5 and claude-haiku-4-5-20251001 reads Haiku 4.5.
# Nothing is invented: a model the rules do not recognise keeps its recorded
# words, so an unfamiliar model stays identifiable rather than being guessed at.
def readable_model($raw):
  (($raw // "") | tostring | gsub("^\\s+|\\s+$"; "")) as $m |
  if $m == "" then null
  else
    (if ($m | test("/")) then ($m | split("/") | last) else $m end) as $base |
    if ($base | test(":")) then $base
    elif ($base | test("-") | not) then ($base | cap_word)
    else
      ($base | split("-") | map(select(length > 0))) as $split |
      (if ($split | length) > 1 and ($split | last | test("^[0-9]{6,}$"))
       then $split[0:-1] else $split end) as $undated |
      (if ($undated | length) > 1
          and (["claude","anthropic","openai","google","meta","mistral","xai","moonshot","ollama","deepseek"]
               | index($undated[0] | ascii_downcase)) != null
       then $undated[1:] else $undated end) as $parts |
      # A bare number following a number is one version that the separator split
      # in two, so haiku-4-5 reads 4.5 rather than as two unrelated words.
      ($parts | reduce .[] as $p ([];
         if (length > 0) and (.[-1] | test("^[0-9]+(\\.[0-9]+)*$")) and ($p | test("^[0-9]+$"))
         then .[0:-1] + [.[-1] + "." + $p]
         else . + [$p] end)) as $joined |
      ($joined | map(
         (ascii_downcase) as $d |
         if test("^[0-9]") then {t: ., acr: false}
         elif $d == "gpt" or $d == "glm" then {t: ascii_upcase, acr: true}
         else {t: cap_word, acr: false} end)) as $words |
      # An acronym keeps its version attached (GPT-5.6); everything else reads as
      # separate words (Opus 5).
      ($words | reduce .[] as $w ({s: "", acr: false};
         {s: (if .s == "" then $w.t elif .acr then .s + "-" + $w.t else .s + " " + $w.t end),
          acr: $w.acr}) | .s)
    end
  end;

# The most in-progress items one card keeps open before moving additional
# received rows into an expandable shelf. No row the board receives is hidden.
6 as $items_per_card |

# One in-progress item as the card renders it: what it is, how far along the
# delivery ladder live state can prove it is, and which model is doing it. The
# stage is taken from the derived lifecycle position in the snapshot and never
# re-derived here, so the ladder keeps exactly one owner.
def work_item($t):
  {
    id: ($t.id // ""),
    title: (($t.title // $t.id // "") | tostring),
    model: readable_model($t.model),
    stage: ($t.stage // null)
  };

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
($recent_actions // []) as $recent_actions |

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
  question: (.decision_question // null),
  decision_url: (.decision_url // null),
  why: (.decision_why // null),
  affects: (.decision_affects // null),
  recommendation: (.decision_recommendation // null),
  no_surface: (.decision_no_surface // null),
  repo: (.repo // "" | short_repo),
  link: (.pr_url // .report_path // null),
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
  question: null,
  decision_url: null,
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
    question: (.question // (if (.source // "") == "status" then (.summary // null) else null end)),
    decision_url: (.decision_url // null),
    why: (.why // null),
    affects: (.affects // null),
    recommendation: (.recommendation // null),
    no_surface: (.no_surface // null),
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
    question: null,
    decision_url: null,
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
  question: null,
  decision_url: null,
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
  question: null,
  decision_url: null,
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
    question: null,
    decision_url: null,
    repo: "",
    link: null
  })) as $waiting_secondmate_unavailable |

(if $backlog_present then [] else [{
  kind: "incomplete",
  home: "main",
  id: "main/backlog-unavailable",
  title: "Main backlog is unavailable",
  detail: "Captain decisions from the main backlog cannot be counted. Restore or inspect the backlog before concluding that nothing is waiting.",
  question: null,
  decision_url: null,
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

# ------------------------------------------------ recent autonomous actions -
# The writer emits only these two shapes.  The shell boundary has already
# rejected malformed or stale entries, and this renderer keeps no archive view.
($recent_actions | length) as $recent_action_count |

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
    items: ($live | map(work_item({id: .id, title: (.backlog.title // .id),
                                   model: .model, stage: .current_state.stage}))),
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
    items: ($live | map(work_item({id: .id, title: (.backlog.title // .id),
                                   model: .model, stage: .current_state.stage}))),
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
  (($sm.counts // {}) | has("active_children")) as $children_count_present |
  ($sm.counts.active_children // null) as $children_count_raw |
  ($children_count_raw
    | if type == "number" and . >= 0 and floor == . then . else null end) as $children_count |
  # A missing count is an older-producer shape whose complete received rows and
  # omission record still establish the total. A present malformed value proves
  # no count at all, so it is ignored rather than converted and disclosed below.
  ($children_count_present and $children_count == null) as $children_count_invalid |
  ([($children_count // 0), ($children_shown + $children_omitted), $children_shown] | max) as $children_total |
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
    children_count_invalid: $children_count_invalid,
    # The title, model, and stage on a routed task are additive in the secondmate
    # home summary, so a home running an older firstmate reports the task with
    # those absent. work_item leaves each one unrecorded rather than empty, and
    # the row says so instead of showing a blank where a fact should be.
    items: (($sm.active_children // []) | map(work_item(.))),
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
($secondmate_cards | any(.children_count_invalid)) as $secondmate_count_incomplete |
((($sm_truncated > 0)
  or ($sm_registry_complete | not)
  or ($secondmate_unknown | length) > 0
  or $secondmate_count_incomplete)) as $in_progress_incomplete |
($secondmate_cards | map(.children_omitted) | add // 0) as $active_details_omitted |

# ------------------------------------------------------------- fragments ---
# A placeholder for "nothing here", kept as literal markup so it is never
# double-escaped into a visible entity by the surrounding @html format.
def none_mark: "&mdash;";

# Project labels are ordinary fragment links without script, and the same card
# anchors are the reading-position identifiers used by the scripted board.
# Only render a link when the corresponding card exists in this snapshot, so a
# stale backlog name cannot create a dead destination.
def project_card_anchor($repo; $home):
  (($repo // "") | tostring | short_repo) as $repo_name |
  (if $repo_name != "" then "project:" + $repo_name
   elif (($home // "main") | tostring) != "main" then "secondmate:" + (($home // "main") | tostring)
   else "" end) as $candidate |
  if $candidate != ""
     and ((($project_cards + $secondmate_cards) | map(.key) | index($candidate)) != null)
  then $candidate else "" end;

def project_jump($label; $anchor; $class):
  if $anchor == "" then (@html "<span class=\"\($class)\">\($label)</span>")
  else (@html "<a href=\"#\($anchor)\" data-project-anchor=\"\($anchor)\" class=\"\($class)\">\($label)</a>")
  end;

def updated_line($key):
  ($updated[$key].label // "") as $label |
  "<div class=\"proj-updated\">" + icon_clock + "Updated "
  + (if $label == "" then none_mark else (@html "\($label)") end);

# One in-progress item: its name, its position on the delivery ladder, and the
# model doing it.
#
# The ladder is drawn as five discrete rungs rather than a smooth fill because
# discrete rungs are exactly what live state can prove. There is no per-file or
# percentage signal behind any of this, and a segmented bar promises none: it
# says "this has reached Validating", not "this is 65% done". The stage label
# beside it carries the meaning and the rungs are only the glance, so the bar is
# never the sole claim. Colour states how the item is MOVING, which is a
# different question from how far it has come: an item stopped at rung four is
# still stopped.
# A stage on a routed task crosses a home boundary - for a remote second mate,
# a host boundary - and the summary validator type-checks the surfaces it carries
# rather than the fields inside each row. So every number here is bounded before
# it is drawn, and an unrecognised motion falls back to unknown rather than
# reaching the page as a class with no colour rule behind it. The failure that
# would cause is the exact one this ladder exists to prevent: rungs rendering
# unfilled while the label beside them still claims a rung was reached.
def work_row:
  . as $w |
  ($w.stage // null) as $st |
  ((if $st == null then 5 else ($st.of // 5) end)
   | if type != "number" then 5 else (floor | if . < 1 then 1 elif . > 5 then 5 else . end) end) as $of |
  ((if $st == null then 0 else ($st.ordinal // 0) end)
   | if type != "number" then 0 else (floor | if . < 0 then 0 elif . > $of then $of else . end) end) as $ord |
  (if $st == null then "Stage unavailable"
   else (($st.label // "Stage unconfirmed") | if type == "string" and . != "" then . else "Stage unconfirmed" end) end) as $label |
  ((if $st == null then "unknown" else ($st.motion // "unknown") end)
   | if IN("quiet", "live", "ready", "waiting", "stopped", "done", "unknown") then . else "unknown" end) as $motion |
  (if $ord > 0 then "Stage \($ord) of \($of): \($label)" else $label end) as $bar_label |
  "<div class=\"wi\">"
  + "<div class=\"wi-head\">"
  + (@html "<span class=\"wi-what\">\(if ($w.title // "") == "" then $w.id else $w.title end)</span>")
  + (if ($w.model // null) == null
     then "<span class=\"wi-model none\">model not recorded</span>"
     else (@html "<span class=\"wi-model\">\($w.model)</span>") end)
  + "</div><div class=\"wi-run\">"
  + (@html "<span class=\"wi-bar m-\($motion)\" role=\"img\" aria-label=\"\($bar_label)\">")
  + ([range(1; $of + 1) | if . <= $ord then "<i class=\"on\"></i>" else "<i></i>" end] | add // "")
  + "</span>"
  + (@html "<span class=\"wi-stage m-\($motion)\">\($label)</span>")
  + "</div></div>";

# The list a card shows beneath its count. The first rows stay visible and every
# additional row received by the board remains available in an expandable shelf.
# A second mate home can bound its own reported children before this board sees
# them, so any difference from the authoritative total is disclosed as upstream
# omission rather than being mixed into the received-row shelf count.
def work_list($items; $total):
  ($items // []) as $all |
  # The total reaching this list belongs to another producer, so it is proven to
  # be a number before anything is counted against it.
  (($total // 0) | if type == "number" then floor else 0 end) as $claimed |
  ([$claimed, ($all | length)] | max) as $count |
  ($all[0:$items_per_card]) as $visible |
  ($all[$items_per_card:]) as $shelved |
  if ($all | length) == 0 then ""
  else
    "<div class=\"wi-list\">"
    + (($visible | map(work_row) | add) // "")
    + (if ($shelved | length) > 0 then
         "<details class=\"shelf\"><summary>"
         + "<svg class=\"chev\" viewBox=\"0 0 24 24\"><polyline points=\"9 6 15 12 9 18\"/></svg>"
         + "<span class=\"stitle\">More in progress</span>"
         + (@html "<span class=\"scount\">\($shelved | length) more</span>")
         + "</summary><div class=\"shelf-body\"><div class=\"shelf-note\"><div class=\"wi-list\">"
         + (($shelved | map(work_row) | add) // "")
         + "</div></div></div></details>"
       else "" end)
    + (if $count > ($all | length)
       then (@html "<p class=\"wi-more\">\($count - ($all | length)) more active tasks were not included in this snapshot.</p>")
       else "" end)
    + "</div>"
  end;

# The placeholder dash stands in for a meta line the card had nothing to put in.
# Above an item list there is nothing left for it to stand in for - the list
# already says what is happening - and a lone dash trailing a rich list reads as
# a stray mark rather than as "nothing waiting", so the slot is dropped instead
# of being filled with one. A card with no items keeps the dash it always had.
def meta_block($line; $items):
  if $line == "" and (($items // []) | length) > 0 then ""
  else
    "<div class=\"proj-meta\">"
    + (if $line == "" then none_mark else (@html "\($line)") end)
    + "</div>"
  end;

# Fleet records may name local evidence paths for an operator, but the generated
# board is not a file server. Only an explicit web URL can navigate; everything
# else stays escaped presentation context so a mobile tap cannot leave /mission
# for a route that does not exist.
# URL validation stays inside jq, the required Mission Control renderer runtime,
# so a missing optional browser/test runtime can never erase valid links.
def need_row:
  . as $w |
  (($w.link // "") | if type == "string" then . else "" end) as $raw_link |
  ($raw_link | web_url_or_empty) as $link |
  (($w.decision_url // "") | https_url_or_empty) as $aid |
  (if $raw_link != "" and $link == "" and $aid == "" then $raw_link else "" end) as $local_ref |
  (if $w.kind == "incomplete" then "Incomplete"
   elif ($w.repo // "") != "" then $w.repo
   elif ($w.home // "main") != "main" then $w.home
   else "Fleet" end) as $tag |
  (project_card_anchor($w.repo; $w.home)) as $project_anchor |
  (if $w.kind == "pr" then (if $w.yolo then "your merge call (autonomous)" else "your review or merge" end)
   elif $w.kind == "incomplete" then ""
   else "" end) as $ask_note |
  "<div class=\"need\(if $w.kind == "incomplete" then " warn" else "" end)\">"
  + "<span class=\"band\"></span>"
  + project_jump($tag; $project_anchor; "tag")
  + (if $link == "" then "<span class=\"need-main\">"
     else (@html "<a class=\"need-main\" href=\"\($link)\">") end)
  + (@html "<span class=\"ask\">\($w.title)")
  + (if ($w.detail // "") == "" then "" else (@html "<span class=\"hint\">\($w.detail)</span>") end)
  + (if $ask_note == "" then "" else (@html "<span class=\"hint\">Awaiting \($ask_note).</span>") end)
  + (if $link != "" then (@html "<span class=\"url\">\($link)</span>")
     elif $local_ref != "" then (@html "<span class=\"url local-ref\">Local report: \($local_ref)</span>")
     else "" end)
  + "</span>"
  + (if $link == "" then "<span class=\"go\"></span></span>"
     else "<span class=\"go\">&rsaquo;</span></a>" end)
  + (if $aid == "" then ""
     else (@html "<a class=\"decision-aid\" href=\"\($aid)\" target=\"_blank\" rel=\"noreferrer\">Open decision aid</a>") end)
  + "</div>";

# A deferred decision is deliberately quieter than a waiting one: no coloured
# band, no link chase, no chevron. It carries only what identifies it.
def deferred_row:
  . as $d |
  (if ($d.repo // "") != "" then $d.repo
   elif ($d.home // "main") != "main" then $d.home
   else "Fleet" end) as $tag |
  (project_card_anchor($d.repo; $d.home)) as $project_anchor |
  "<div class=\"defer\">"
  + project_jump($tag; $project_anchor; "tag")
  + (@html "<span class=\"ask\">\($d.title)")
  + (if ($d.detail // "") == "" then "" else (@html "<span class=\"hint\">\($d.detail)</span>") end)
  + "</span></div>";

# The recent-action feed is fleet-wide, bounded before this render, and names
# only an autonomous finding decision or PR merge.  It never tries to infer an
# action from task-status prose.
def recent_action_age($ts):
  ($now - $ts) as $age |
  if $age < 60 then "just now"
  elif $age < 3600 then "\(($age / 60) | floor) min ago"
  else "\(($age / 3600) | floor) hr ago" end;

def recent_action_row:
  . as $action |
  (@html "<div class=\"recent-action\"><span class=\"recent-project\">\($action.project)</span>")
  + (if $action.kind == "decision"
     then (@html "<span class=\"recent-what\">Decided: \($action.finding) - \($action.decision)</span>")
     else (@html "<span class=\"recent-what\">Merged <a href=\"\($action.pr_url)\">PR</a><span class=\"recent-url\">\($action.pr_url)</span></span>")
     end)
  + (@html "<time class=\"recent-when\">\(recent_action_age($action.ts))</time>")
  + "</div>";

# ------------------------------------------------------- reply controls ----
# Every control below queues ONE request and performs nothing. The markup holds
# no endpoint, no token, and no action; the only thing a tap reaches is the
# Lavish bridge, and the only thing that travels is captain intent for firstmate
# to adjudicate. With $controls false every def here yields the empty string, so
# the default board is byte-identical to the one rendered without the flag.
def rc_button($intent; $label):
  (@html "<button type=\"button\" class=\"rc-b rc-\($intent)\" data-open=\"\($intent)\">\($label)</button>");

# The confirmed state one control leaves behind. It ships hidden and carries no
# text: only the script that saw a transport actually accept the request fills in
# what was proved, so a statically served copy can never show a false confirmation.
def rc_confirm($intent):
  (@html "<div class=\"rc-ok\" data-ok=\"\($intent)\" hidden role=\"status\">")
  + icon_check
  + "<span class=\"rc-ok-t\"><strong class=\"rc-ok-h\"></strong>"
  + "<span class=\"rc-ok-s\">Recorded for firstmate, which applies it under its own"
  + " checks. It stays here until the call clears.</span></span></div>";

def rc_form($intent; $question; $note_label; $placeholder; $send_label):
  (@html "<form class=\"rc-f\" data-toggle data-intent=\"\($intent)\" hidden>")
  + (@html "<p class=\"rc-q\">\($question)</p>")
  + (if $note_label == "" then ""
     else (@html "<textarea class=\"rc-t\" rows=\"3\" maxlength=\"2000\" aria-label=\"\($note_label)\" placeholder=\"\($placeholder)\"></textarea>") end)
  + "<div class=\"rc-row\">"
  + (@html "<button type=\"submit\" class=\"rc-go\">\($send_label)</button>")
  + "<button type=\"button\" class=\"rc-x\">Cancel</button>"
  + "</div>"
  + "<p class=\"rc-hold\">The board holds its refresh while this is open.</p>"
  + "</form>";

def answer_prompt($w):
  (($w.question // "") | if type == "string" then gsub("^[[:space:]]+|[[:space:]]+$"; "") else "" end) as $question |
  (($w.title // "") | if type == "string" then gsub("^[[:space:]]+|[[:space:]]+$"; "") else "" end) as $title |
  (($w.detail // "") | if type == "string" then gsub("^[[:space:]]+|[[:space:]]+$"; "") else "" end) as $detail |
  if $question != "" then $question
  elif $title != "" and $detail != "" then $title + " - " + $detail
  elif $title != "" then $title
  elif $detail != "" then $detail
  else "Your answer" end;

def controls_for:
  . as $w |
  ($w.ctl // null) as $c |
  if ($controls | not) or $c == null then "" else
    (@html "<div class=\"rc\" data-home=\"\($c.home)\" data-id=\"\($c.id)\" data-key=\"\($c.key)\" data-what=\"\($w.title)\">")
    + "<div class=\"rc-acts\">"
    # The confirmations lead, so a row the captain has already answered reads as
    # answered at a glance and whatever it can still resolve sits under that.
    + (($c.intents
        | map(select(. == "merge" or . == "reply" or . == "answer" or . == "defer"))
        | map(rc_confirm(.))) | add // "")
    + (($c.intents | map(
        if . == "merge" then rc_button("merge"; "Approve merge")
        elif . == "reply" then rc_button("reply"; "Reply")
        elif . == "answer" then rc_button("answer"; "Answer")
        elif . == "defer" then rc_button("defer"; "Set aside")
        else "" end)) | add // "")
    + "<span class=\"rc-sent\" hidden></span>"
    + "</div>"
    + (($c.intents | map(
        if . == "merge" then rc_form("merge";
             "Ask firstmate to merge this? Firstmate runs its own checks first and merges only if they pass.";
             ""; ""; "Send request")
        elif . == "reply" then rc_form("reply";
             "Send firstmate a note about this. It carries no approval on its own.";
             "Your note"; "Your note"; "Send to firstmate")
        elif . == "answer" then rc_form("answer";
             "Your answer goes to firstmate, which applies it through its normal decision flow.";
             "Your answer"; answer_prompt($w); "Send answer")
        elif . == "defer" then rc_form("defer";
             "Set this aside? It leaves this list for the Deferred shelf, and your original reason is kept unchanged.";
             ""; ""; "Set aside")
        else "" end)) | add // "")
    + "</div>"
  end;

# The decision context a filed decision now carries as separate fields. Each
# dimension is a labelled row of its own, because the whole point of storing them
# apart is that the captain can find the recommendation without reading a
# paragraph to look for it. A decision filed before this schema existed has none
# of these fields and renders exactly as it always has, from its reason alone.
#
# This block sits OUTSIDE the row anchor deliberately. The row title is wrapped in
# a link whenever the decision has one, and putting three lines of readable
# context inside that link would make reading or selecting the recommendation
# navigate away instead - worst on a phone, where the tap target is the whole row.
def ctx_row($label; $value):
  (($value // "") | if type == "string" then gsub("^[[:space:]]+|[[:space:]]+$"; "") else "" end) as $v |
  if $v == "" then ""
  else (@html "<div class=\"ctx-r\"><span class=\"ctx-l\">\($label)</span><span class=\"ctx-v\">\($v)</span></div>")
  end;

def need_ctx:
  . as $w |
  (ctx_row("Why now"; $w.why)
   + ctx_row("What it affects"; $w.affects)
   + ctx_row("Recommendation"; $w.recommendation)) as $rows |
  # The conscious "no built surface" choice is shown to the captain too. It is the
  # difference between a decision nobody prepared a surface for and one where the
  # filer established that none applies, and only the second is ready to answer.
  ((($w.no_surface // "") | if type == "string" then gsub("^[[:space:]]+|[[:space:]]+$"; "") else "" end)) as $none |
  if $rows == "" and $none == "" then ""
  else
    "<div class=\"need-ctx\">"
    + $rows
    + (if $none == "" then ""
       else (@html "<div class=\"ctx-r ctx-none\"><span class=\"ctx-l\">No built surface</span><span class=\"ctx-v\">\($none)</span></div>")
       end)
    + "</div>"
  end;

def need_item:
  . as $w |
  (@html "<div class=\"need-wrap\" data-scroll-anchor=\"call:\($w.home // "main"):\($w.id // ""):\($w.ctl.key // ""):\($w.kind // "")\">")
  + ($w | need_row)
  + ($w | need_ctx)
  + ($w | controls_for)
  + "</div>";

def ask_block:
  if ($controls | not) then "" else
    "<div class=\"rc rc-ask\" data-home=\"main\" data-id=\"\" data-key=\"\" data-what=\"\">"
    + "<form class=\"rc-f\" data-intent=\"ask\">"
    + "<p class=\"rc-q\">Ask firstmate for something new, or say what you want changed.</p>"
    + "<textarea class=\"rc-t\" rows=\"3\" maxlength=\"2000\" aria-label=\"Ask firstmate\"></textarea>"
    + "<div class=\"rc-row\"><button type=\"submit\" class=\"rc-go\">Send to firstmate</button>"
    + "<span class=\"rc-sent\" hidden></span>"
    + rc_confirm("ask")
    + "</div>"
    # This composer is always open, so text left in it holds the refresh with no
    # form to close. It has to say so, or the board just quietly stops updating.
    + "<p class=\"rc-hold\">The board holds its refresh while there is text here.</p>"
    + "</form></div>"
  end;

# What firstmate said back, and what the captain said before it. This is the ONLY
# control on the board that carries a conversation; every other one resolves in a
# single action and stays that way.
#
# It is display and only display: no control, no target, no intent, and nothing
# derived from a firstmate message is ever actionable. It also ships EMPTY and
# hidden, like the confirmation banner, so a statically served copy of this file
# can never show a conversation - only the script that reached the reply service
# puts anything here.
#
# Deliberately a sibling of the composer rather than a child of it: the refresh
# hold counts any `.rc-t` holding unsent text, so conversation text living inside
# that block would read as a draft and stop the board updating for good.
def thread_block:
  if ($controls | not) then "" else
    "<section class=\"thr\" id=\"ask-thread\" hidden>"
    + "<h3 class=\"thr-h\">Your thread with firstmate</h3>"
    + "<ol class=\"thr-list\" aria-live=\"polite\"></ol>"
    + "<p class=\"thr-more\" hidden>Older messages in this thread are outside the"
    + " window the board keeps.</p>"
    + "</section>"
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
   elif $p.active > 0 then "\($p.active) \(plural($p.active; "task"; "tasks")) under way"
   elif $p.in_flight > 0 then "\($p.in_flight) \(plural($p.in_flight; "task"; "tasks")) in flight, none running"
   elif $p.queued > 0 then "\($p.queued) queued, nothing under way"
   else "Nothing in flight." end) as $state_line |
  (if ($backlog_present | not) then "Your decisions here cannot be counted."
   elif $p.waiting > 0 and $p.prs > 0 then "\($p.waiting) \(plural($p.waiting; "decision"; "decisions")) and \($p.prs) \(plural($p.prs; "PR"; "PRs")) await you"
   elif $p.waiting > 0 then "\($p.waiting) \(plural($p.waiting; "decision awaits"; "decisions await")) you"
   elif $p.prs > 0 then "\($p.prs) \(plural($p.prs; "PR awaits"; "PRs await")) your call"
   elif ($p.registered | not) then "Not in the project registry"
   else "" end) as $meta_line |
  (@html "<div id=\"\($p.key)\" class=\"proj s-\($tone)\" data-scroll-anchor=\"\($p.key)\">
     <div class=\"proj-top\"><span class=\"badge\">")
  + project_glyph($p.name)
  + "</span>"
  + project_jump($p.name; $p.key; "proj-name")
  + (if $p.registered then "" else "<span class=\"sub-role\">&middot; unregistered</span>" end)
  + (@html "<span class=\"pill \(if $tone == "attn" then "attn" elif $tone == "live" then "live" elif $tone == "unknown" then "unknown" else "idle" end)\">\($pill)</span></div>
     <div class=\"proj-state\">\($state_line)</div>")
  + work_list($p.items; $p.active)
  + meta_block($meta_line; $p.items)
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
   elif $s.children_count_invalid and $s.children > 0 then "At least \($s.children) \(plural($s.children; "task"; "tasks")) routed and under way"
   elif $s.children_count_invalid and $s.state == "active_child_work" then "Routed work is under way; active task count unavailable."
   elif $s.children > 0 then "\($s.children) \(plural($s.children; "task"; "tasks")) routed and under way"
   elif $s.state == "captain_decision" then "Routed work is waiting for your decision."
   elif $s.state == "no_active_work" then "Idle and healthy, awaiting routed work."
   else "Current secondmate state is unavailable." end) as $state_line |
  (if ($s.decisions_available | not) then "Your decisions here cannot be read."
   elif $s.decisions > $s.decisions_shown then "\($s.decisions) decisions await you (\($s.decisions_shown) shown)"
   elif $s.decisions > 0 then "\($s.decisions) \(plural($s.decisions; "decision awaits"; "decisions await")) you"
   elif $s.children_count_invalid and $s.children_shown > 0 then "Active task count unavailable (\($s.children_shown) shown)"
   elif $s.children_count_invalid then "Active task count unavailable"
   elif $s.children_omitted > 0 then "\($s.children) active tasks (\($s.children_shown) shown)"
   elif $s.holds > $s.holds_shown then "\($s.holds) held tasks (\($s.holds_shown) shown)"
   else "" end) as $meta_line |
  (@html "<div id=\"\($s.key)\" class=\"proj s-\($tone)\" data-scroll-anchor=\"\($s.key)\">
     <div class=\"proj-top\"><span class=\"badge\">")
  + icon_compass
  + "</span>"
  + project_jump($s.name; $s.key; "proj-name")
  + (@html "<span class=\"sub-role\">&middot; second mate</span>
     <span class=\"pill \(if $tone == "attn" then "attn" elif $tone == "live" then "live" elif $tone == "unknown" then "unknown" else "idle" end)\">\($pill)</span></div>
     <div class=\"proj-state\">\($state_line)</div>")
  + work_list($s.items; $s.children)
  + meta_block($meta_line; $s.items)
  + updated_line($s.key)
  + "</div></div>";

def stat($icon; $value; $label; $note; $attn):
  (@html "<div class=\"stat\(if $attn then " attn" else "" end)\">")
  + $icon
  + (@html "<div class=\"n\">\($value)</div><div class=\"l\">\($label)</div>")
  + (if $note == "" then "" else (@html "<div class=\"note\">\($note)</div>") end)
  + "</div>";

# Token Dashboard timestamps are normalized ISO strings, but fractional seconds
# vary. Strip only that fraction before jq parses the epoch; every malformed
# value remains unavailable rather than becoming a plausible local time.
def iso_epoch:
  if type != "string" then null
  else try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null end;

def clamp($value; $minimum; $maximum):
  if $value < $minimum then $minimum elif $value > $maximum then $maximum else $value end;

def local_time($iso; $format):
  ($iso | iso_epoch) as $epoch |
  if $epoch == null then "unavailable"
  else (@html "<time class=\"qtime\" datetime=\"\($iso)\" data-format=\"\($format)\">\($iso)</time>") end;

def age_copy($seconds):
  if $seconds == null then "age unavailable"
  elif $seconds < 60 then "just now"
  elif $seconds < 3600 then "\(($seconds / 60) | floor)m ago"
  elif $seconds < 86400 then "\(($seconds / 3600) | floor)h ago"
  else "\(($seconds / 86400) | floor)d ago" end;

def token_age:
  ($token_dash.latest.capturedAt | iso_epoch) as $captured |
  if $captured == null then null else ([$now - $captured, 0] | max) end;

def token_is_stale:
  token_age as $age |
  (($token_dash.refreshIntervalMs // 900000) |
    if type == "number" and . > 0 then (. / 1000) else 900 end) as $cadence |
  $age != null and $age > ($cadence * 4);

def pace_band($window):
  (if $window.id == "five_hour"
   then $token_dash.settings.paceThresholds.fiveHour
   else $token_dash.settings.paceThresholds.weekly end) as $thresholds |
  ($window.pace.reservePercentPoints // null) as $reserve |
  if ($reserve | type) != "number" then {tone: "muted", label: "Pace unavailable"}
  elif (($thresholds.comfortable | type) == "number") and $reserve >= $thresholds.comfortable
    then {tone: "good", label: "Comfortably under pace"}
  elif (($thresholds.edge | type) == "number") and $reserve >= $thresholds.edge
    then {tone: "warn", label: "Near your pace edge"}
  elif (($thresholds.edge | type) == "number")
    then {tone: "alert", label: "Past your pace edge"}
  elif $reserve >= 0 then {tone: "good", label: "Under straight-line pace"}
  else {tone: "alert", label: "Over straight-line pace"} end;

def cycle_points($window):
  [($token_dash.history // [])[]? as $snapshot |
   ($snapshot.windows // [])[]? |
   select(.key == $window.key and .resetsAt == $window.resetsAt) |
   (.percentUsed // null) as $used |
   ($snapshot.capturedAt | iso_epoch) as $epoch |
   select(($used | type) == "number" and $epoch != null) |
   {epoch: $epoch, used: clamp($used; 0; 100)}] |
  sort_by(.epoch);

def trend_chart($window; $band):
  cycle_points($window) as $all |
  ($window.resetsAt | iso_epoch) as $reset |
  ($window.windowSeconds // null) as $duration |
  if $reset == null or ($duration | type) != "number" or $duration <= 0 then
    "<div class=\"qtrend-empty\">Trend timing unavailable.</div>"
  else
    ($reset - $duration) as $start |
    ($all | if length > 48 then .[-48:] else . end) as $draw |
    ($draw | map(
      (clamp(((.epoch - $start) / $duration * 100); 0; 100)) as $x |
      (30 - (.used * 0.28)) as $y |
      "\($x),\($y)") | join(" ")) as $points |
    (($window.pace.elapsedPercent // null) |
      if type == "number" then clamp(.; 0; 100) else null end) as $now_x |
    ($draw | last // null) as $last |
    (@html "<svg class=\"qtrend tone-\($band.tone)\" viewBox=\"0 0 100 32\" role=\"img\" aria-label=\"\($all | length) saved allowance readings in this cycle\">")
    + "<line class=\"qbudget\" x1=\"0\" y1=\"30\" x2=\"100\" y2=\"2\"></line>"
    + (if $now_x == null then ""
       else (@html "<line class=\"qnow\" x1=\($now_x) y1=\"1\" x2=\($now_x) y2=\"31\"></line>") end)
    + (if ($draw | length) > 1 then (@html "<polyline class=\"qactual\" points=\"\($points)\"></polyline>") else "" end)
    + (if $last == null then ""
       else (clamp((($last.epoch - $start) / $duration * 100); 0; 100)) as $last_x |
            (30 - ($last.used * 0.28)) as $last_y |
            (@html "<circle class=\"qlatest\" cx=\"\($last_x)\" cy=\"\($last_y)\" r=\"2.4\"></circle>") end)
    + "</svg>"
  end;

def trend_note($window):
  cycle_points($window) as $points |
  if ($points | length) < 2 then "Collecting history for this cycle"
  else (($points | last | .used) - ($points | first | .used) | round) as $change |
    "\($points | length) saved rounds · \(if $change > 0 then "+" else "" end)\($change) pts observed"
  end;

def runway_copy($window):
  ($window.pace.projectedExhaustedAt | iso_epoch) as $projected |
  ($window.resetsAt | iso_epoch) as $reset |
  if $projected == null or $reset == null then "Projected runway unavailable"
  elif $projected >= $reset then "Projected runway reaches reset"
  else "Projected exhaustion " + local_time($window.pace.projectedExhaustedAt; "short") end;

def reserve_copy($window):
  ($window.pace.reservePercentPoints // null) as $reserve |
  if ($reserve | type) != "number" then "pace buffer unavailable"
  elif $reserve >= 0 then "\($reserve | round) pt pace buffer"
  else "\(($reserve | -.) | round) pt over pace" end;

def token_window:
  . as $window |
  pace_band($window) as $band |
  (($window.percentRemaining // null) |
    if type == "number" then (clamp(.; 0; 100) | round) else null end) as $remaining |
  (($window.percentUsed // null) |
    if type == "number" then (clamp(.; 0; 100) | round) else null end) as $used |
  (($window.pace.elapsedPercent // null) |
    if type == "number" then (clamp(.; 0; 100) | round) else null end) as $elapsed |
  (@html "<article class=\"qwindow tone-\($band.tone)\">
    <div class=\"qw-head\"><span class=\"qw-name\">\($window.shortLabel // $window.label // $window.key // "Allowance window")</span><span class=\"qw-provider\">\($window.providerLabel // $window.provider // "")</span></div>
    <div class=\"qw-reading\"><strong>\(if $remaining == null then "-" else $remaining end)\(if $remaining == null then "" else "%" end)</strong><span>remaining</span></div>
    <div class=\"qw-verdict\">\($band.label)</div>")
  + (@html "<div class=\"qw-context\">\(if $used == null then "Usage unavailable" else "\($used)% used" end) · \(if $elapsed == null then "cycle position unavailable" else "\($elapsed)% through cycle" end) · \(reserve_copy($window))</div>")
  + trend_chart($window; $band)
  + (@html "<div class=\"qw-trend-note\">\(trend_note($window))</div>")
  + "<div class=\"qw-foot\"><span>" + runway_copy($window) + "</span><span>reset "
  + local_time($window.resetsAt; "reset") + "</span></div></article>";

def human_action($value):
  (($value // "") | tostring | gsub("[_-]+"; " ") | gsub("  +"; " ")) as $text |
  if $text == "" then "Balancing adjustment"
  else (($text[0:1] | ascii_upcase) + $text[1:]) end;

def eased_provider($value):
  (($value // "") | tostring | ascii_downcase) as $provider |
  if ($provider | contains("claude")) then "Claude Max"
  elif ($provider | test("chatgpt|codex|openai")) then "ChatGPT Pro"
  elif $provider == "" then "provider not recorded"
  else $value end;

def balancing_row:
  (@html "<li><time class=\"qtime\" datetime=\"\(.ts // "")\" data-format=\"action\">\(.ts // "time unavailable")</time><span>\(human_action(.action))</span><small>eased \(eased_provider(.providerEased))</small></li>");

def balancing_block:
  (($token_dash.balancing.actions // []) | map(select(.auto == true))) as $automatic |
  if ($token_dash.balancing.error // null) != null and ($automatic | length) == 0 then
    "<p class=\"qbalance-empty\">Automatic balancing activity is unavailable.</p>"
  elif ($automatic | length) == 0 then
    "<p class=\"qbalance-empty\">No automatic balancing activity recorded.</p>"
  else
    "<details class=\"qbalance\" id=\"quota-balancing\"><summary><span><strong>Automatic balancing</strong> · "
    + (@html "\($automatic | length) recent \(plural($automatic | length; "shift"; "shifts"))")
    + "</span><span class=\"qbalance-last\">latest "
    + local_time(($automatic | first | .ts); "action")
    + "</span></summary><ul>"
    + (($automatic[0:3] | map(balancing_row) | add) // "")
    + "</ul></details>"
  end;

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

def quota_fallback:
  if $quota == null then
    (([$token_dash_note, $quota_note] | map(select(. != "" and . != "not requested")) | unique | join("; ")) // "") as $reason |
    (@html "<p class=\"quiet\">Allowance unavailable\(if $reason == "" then "." else " - \($reason)." end)</p>")
  else
    (($quota.providers // []) | map(. as $p |
      $p + {wins: (($p.windows // []) | map(select((.percentRemaining // null) != null)))})) as $providers |
    ($providers | map(select((.wins | length) > 0))) as $measured |
    ($providers | map(select((.wins | length) == 0))) as $unmeasured |
    (@html "<p class=\"qfallback\">Live allowance only. Pace history, projected runway, and balancing activity are unavailable - \(if $token_dash_note == "" then "local token history has no successful reading" else $token_dash_note end).</p>")
    # A provider with no readable window is a sign-in or reporting gap, not an
    # exhausted allowance, so it never renders as an empty zero gauge.
    + (($measured | map(. as $p |
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

def quota_block:
  if ($token_dash.latest | type) != "object" then quota_fallback
  else
    ($token_dash.latest.windows // []) as $windows |
    (($token_dash.historyCount // ($token_dash.history | length)) |
      if type == "number" then floor else 0 end) as $history_count |
    token_age as $age |
    "<div class=\"qmeta\"><span>Local allowance history</span>"
    + (@html "<span>\($history_count) saved \(plural($history_count; "snapshot"; "snapshots"))</span>")
    + "<span>updated " + local_time($token_dash.latest.capturedAt; "updated") + "</span></div>"
    + (if $age == null then
         "<p class=\"qalert\">Allowance freshness is unavailable.</p>"
       elif token_is_stale then
         "<p class=\"qalert\">Allowance data is stale - the last successful reading was "
         + (@html "\(age_copy($age))") + ".</p>"
       elif ($token_dash.lastError | type) == "object" then
         "<p class=\"qalert\">The latest local collection failed; showing the last successful reading.</p>"
       else "" end)
    + (if ($windows | length) == 0 then
         "<p class=\"quiet\">No allowance windows were reported by the local token dashboard.</p>"
       else "<div class=\"quota-grid\">" + (($windows | map(token_window) | add) // "") + "</div>" end)
    + (if ([$windows[]? | select(.key == "claude:five_hour" or .key == "claude:seven_day" or .key == "codex:weekly")] | length) < 3
       then "<p class=\"qmissing\">One or more primary allowance windows are unavailable.</p>" else "" end)
    + balancing_block
  end;

# Hidden by CSS, revealed only once a script proves a transport that can actually
# reach firstmate - the direct reply service, or the legacy Lavish bridge - so the
# same file served statically stays the read-only board and no viewer is ever
# shown a control that cannot reach anything.
def controls_css:
  if ($controls | not) then "" else
"/* ---- captain reply layer (--controls) ---- */
.rc{display:none;}
body.board-reply .rc,body.lavish .rc{display:block;border-top:1px solid var(--line);
  background:#fbfcfe;padding:4px 22px 13px;}
body.board-reply .rc-ask,body.lavish .rc-ask{border:1px solid var(--line);border-radius:16px;
  background:var(--panel);box-shadow:var(--shadow);margin-top:14px;padding:15px 22px 17px;}
.rc-acts{display:flex;align-items:center;gap:8px;flex-wrap:wrap;padding:8px 0 0;}
.rc-b{appearance:none;-webkit-appearance:none;border:1px solid var(--line);background:var(--panel);
  color:var(--slate);font:inherit;font-size:12.5px;font-weight:600;padding:6px 13px;min-height:34px;
  border-radius:999px;cursor:pointer;}
.rc-b:hover{border-color:#cfd6e0;color:var(--ink);}
.rc-b.rc-answer{color:#936218;background:var(--amber-soft);border-color:#ead7ae;}
.rc-b.rc-answer:hover{color:#724b10;background:#f8eccf;border-color:#dfc58e;}
.rc-b.rc-defer{color:var(--slate);background:var(--slate-soft);border-color:#dce1e8;}
.rc-b.rc-defer:hover{color:var(--ink);background:#e5e9ef;border-color:#cbd2dc;}
.rc-b:disabled,.rc-go:disabled{opacity:.66;cursor:default;}
.rc-b.rc-submitted{color:var(--green);background:var(--green-soft);border-color:#cfe7da;}
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
/* The confirmed state. A small coloured label was missable, so an acknowledged
   control is replaced in place by a full-width banner: the row cannot be read as
   still waiting for the captain. Siblings that can still be resolved stay, and a
   row whose every control is acknowledged becomes the banner alone. */
.rc-ok{flex-basis:100%;display:flex;align-items:flex-start;gap:10px;margin:3px 0 1px;
  padding:11px 14px;border:1px solid #bfe0cf;border-left:4px solid var(--green);
  border-radius:13px;background:var(--green-soft);}
.rc-ok[hidden]{display:none;}
.rc-ok .ck{flex:none;width:19px;height:19px;color:var(--green);margin-top:1px;stroke-width:2.4;}
.rc-ok-t{display:flex;flex-direction:column;gap:1px;min-width:0;}
.rc-ok-h{color:#0b6b49;font-size:13.5px;font-weight:700;overflow-wrap:anywhere;}
.rc-ok-s{color:var(--slate);font-size:12px;overflow-wrap:anywhere;}
/* Recorded, but nothing is collecting it. The board proved only the first half,
   so this keeps the needs-you tone rather than reading as a clean success. */
.rc-ok.rc-warn{border-color:#ead7ae;border-left-color:var(--amber);background:var(--amber-soft);}
.rc-ok.rc-warn .ck{color:var(--amber);}
.rc-ok.rc-warn .rc-ok-h{color:#936218;}
/* The Ask-firstmate thread. Every message is inert text, so nothing here borrows
   a control's shape: no pill, no button tone, no underlined action. */
.thr{margin:13px 0 0;padding:0 22px;}
.thr[hidden]{display:none;}
.thr-h{margin:0 0 9px;font-size:11px;font-weight:700;letter-spacing:.07em;
  text-transform:uppercase;color:var(--faint);}
.thr-list{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:9px;}
/* Who said it has to survive a glance, so the two sides differ in fill AND in
   edge: adjacent bubbles that shared a treatment would read as one long note. */
.thr-m{min-width:0;border:1px solid var(--line);border-left:3px solid var(--line);
  border-radius:4px 13px 13px 4px;padding:9px 13px;background:var(--panel);}
.thr-m.thr-captain{background:var(--slate-soft);border-color:#dce1e8;border-left-color:var(--slate);}
.thr-m.thr-firstmate{border-left-color:var(--amber);}
.thr-head{display:flex;align-items:baseline;gap:8px;flex-wrap:wrap;min-width:0;margin:0 0 2px;}
.thr-who{font-size:12px;font-weight:700;color:var(--ink);}
.thr-m.thr-captain .thr-who{color:var(--slate);}
.thr-at{font-size:11.5px;color:var(--faint);}
.thr-t{margin:0;font-size:13.5px;line-height:1.5;color:var(--ink);
  white-space:pre-wrap;overflow-wrap:anywhere;}
.thr-more{margin:9px 0 0;color:var(--faint);font-size:11.5px;}
.thr-more[hidden]{display:none;}
@media(max-width:720px){
  body.board-reply .rc,body.lavish .rc,
  body.board-reply .rc-ask,body.lavish .rc-ask{padding-left:16px;padding-right:16px;}
  .rc-b,.rc-go{min-height:44px;padding-top:9px;padding-bottom:9px;}
  .thr{padding-left:16px;padding-right:16px;}
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
+ "<noscript><meta http-equiv=\"refresh\" content=\"" + ($refresh | tostring) + "\"></noscript>"
+ "
<title>Mission Control</title>
<link rel=\"icon\" type=\"image/svg+xml\" sizes=\"any\" href=\"data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 viewBox=%270 0 32 32%27%3E%3Ccircle cx=%2716%27 cy=%2716%27 r=%2715%27 fill=%27%231a2233%27/%3E%3Cpath d=%27M16 4.5 21.2 17.8 16 15.5 10.8 17.8Z%27 fill=%27white%27/%3E%3Cpath d=%27M16 27.5 10.8 14.2 16 16.5 21.2 14.2Z%27 fill=%27%230f8a5f%27/%3E%3C/svg%3E\">
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
.need-wrap{border-top:1px solid var(--line);}
.need-wrap:first-child{border-top:none;}
.need{display:flex;align-items:center;gap:14px;padding:15px 22px;}
.need-main{display:flex;align-items:center;gap:14px;flex:1;min-width:0;}
.band{width:3px;align-self:stretch;border-radius:3px;background:var(--amber);flex:none;}
.need.warn .band{background:var(--red);}
.tag{flex:none;width:132px;font-size:12.5px;font-weight:600;color:var(--slate);overflow-wrap:anywhere;}
.need.warn .tag{color:var(--red);}
.need .ask{flex:1;font-size:14.5px;color:var(--ink);overflow-wrap:anywhere;}
.need .hint{display:block;color:var(--muted);font-size:12.5px;font-weight:400;margin-top:2px;}
.need .url{display:block;color:var(--faint);font-family:var(--mono);font-size:11.5px;margin-top:4px;overflow-wrap:anywhere;}
.need .go{flex:none;color:var(--faint);font-size:18px;width:10px;text-align:right;}
a.need-main:hover .ask{color:var(--amber);}
/* The left padding and the label column repeat the .need padding + band + gap and
   the .tag width + gap, so a label lands in the project-tag column and its value
   lands exactly under the decision title rather than near it. */
.need-ctx{padding:0 22px 15px 39px;display:grid;gap:7px;}
.ctx-r{display:grid;grid-template-columns:132px minmax(0,1fr);gap:14px;align-items:baseline;}
.ctx-l{font-size:11px;font-weight:660;letter-spacing:.04em;text-transform:uppercase;
  color:var(--faint);}
.ctx-v{font-size:13px;line-height:1.5;color:var(--muted);overflow-wrap:anywhere;}
.ctx-none .ctx-v{color:var(--faint);font-style:italic;}
.decision-aid{flex:none;color:var(--amber);background:var(--amber-soft);border:1px solid #ead7ae;
  border-radius:999px;padding:7px 12px;font-size:12px;font-weight:650;white-space:nowrap;}
.decision-aid:hover{background:#f8eccf;border-color:#dfc58e;}
.decision-aid:focus-visible{outline:2px solid var(--amber);outline-offset:2px;}

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
[data-project-anchor]{cursor:pointer;}
[data-project-anchor]:hover{color:var(--amber);text-decoration:underline;text-underline-offset:2px;}
[data-project-anchor]:focus-visible{outline:2px solid var(--amber);outline-offset:2px;border-radius:2px;}
.sub-role{color:var(--faint);font-weight:500;font-size:12px;margin-left:4px;}
@keyframes project-arrival{
  0%{background:var(--amber-soft);box-shadow:0 0 0 0 rgba(183,121,31,.55),var(--shadow);}
  35%{background:#fffaf0;box-shadow:0 0 0 8px rgba(183,121,31,0),var(--shadow);}
  100%{background:var(--panel);box-shadow:var(--shadow);}
}
.proj.project-arrived{animation:project-arrival 1.8s ease-out both;}
@media(prefers-reduced-motion:reduce){.proj.project-arrived{animation:none;background:var(--amber-soft);outline:2px solid var(--amber);outline-offset:2px;}}
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

/* ---- in-progress items on a card ----
   Five discrete rungs, not a smooth fill: the board has no percentage signal, so
   a segmented ladder is the honest shape for one. Filled rungs say how far the
   item has come and their colour says whether it is still moving, which are two
   different facts and are allowed to disagree - a stopped item keeps the rungs
   it earned and turns red. The stage label beside the rungs always carries the
   meaning, so the bar is never read alone. */
.wi-list{display:flex;flex-direction:column;gap:11px;margin:2px 0 1px;}
.wi{display:flex;flex-direction:column;gap:6px;padding-top:10px;border-top:1px dashed var(--line);}
.wi:first-child{padding-top:0;border-top:none;}
.wi-head{display:flex;align-items:baseline;gap:9px;flex-wrap:wrap;}
.wi-what{flex:1 1 auto;font-size:13px;color:var(--ink);overflow-wrap:anywhere;}
/* margin-left:auto rather than order in the flow, so the model stays a trailing
   tag on the title even at the narrow width where it wraps onto its own line
   and would otherwise read as a label on the ladder below it. */
.wi-model{flex:none;margin-left:auto;font-family:var(--mono);font-size:10.5px;color:var(--slate);
  background:var(--slate-soft);border-radius:6px;padding:2px 7px;overflow-wrap:anywhere;}
.wi-model.none{background:none;color:var(--faint);padding:2px 0;}
.wi-run{display:flex;align-items:center;gap:10px;flex-wrap:wrap;}
.wi-bar{display:flex;gap:3px;flex:0 0 92px;}
.wi-bar i{flex:1 1 0;height:5px;border-radius:2px;background:#e3e7ee;}
.wi-bar.m-quiet i{background:var(--slate-soft);}
.wi-bar.m-quiet i.on{background:var(--slate);}
.wi-bar.m-live i.on,.wi-bar.m-done i.on{background:var(--green);}
.wi-bar.m-ready i.on,.wi-bar.m-waiting i.on{background:var(--amber);}
.wi-bar.m-stopped i.on{background:var(--red);}
/* Nothing is proven about an unconfirmed stage, so no rung is filled and the
   empty ladder is hatched rather than left looking like honest zero progress. */
.wi-bar.m-unknown i{background:repeating-linear-gradient(90deg,#c9d0da 0 2px,transparent 2px 5px);}
.wi-stage{flex:1 1 auto;font-size:11.5px;color:var(--muted);overflow-wrap:anywhere;}
.wi-stage.m-quiet{color:var(--slate);}
.wi-stage.m-ready,.wi-stage.m-waiting{color:var(--amber);}
.wi-stage.m-stopped{color:var(--red);}
.wi-more{margin:0;font-size:11.5px;color:var(--faint);}

/* ---- shipped ---- */
.shipped{background:var(--panel);border:1px solid var(--line);border-radius:16px;box-shadow:var(--shadow);overflow:hidden;}
.ship{display:flex;align-items:center;gap:14px;padding:12px 22px;border-top:1px solid var(--line);font-size:14px;}
.ship:first-child{border-top:none;}
.ship .ck{color:var(--green);flex:none;width:16px;height:16px;}
.ship .what{overflow-wrap:anywhere;}
.ship .who{color:var(--faint);font-size:12.5px;margin-left:auto;flex:none;padding-left:10px;}
a.ship:hover{background:#fbfcfe;}

/* ---- recent autonomous actions ---- */
.recent-actions{background:var(--panel);border:1px solid var(--line);border-radius:16px;box-shadow:var(--shadow);overflow:hidden;}
.recent-action{display:flex;align-items:baseline;gap:14px;padding:13px 22px;border-top:1px solid var(--line);font-size:13.5px;}
.recent-action:first-child{border-top:none;}
.recent-project{flex:none;width:132px;font-size:12.5px;font-weight:600;color:var(--slate);overflow-wrap:anywhere;}
.recent-what{flex:1;overflow-wrap:anywhere;}
.recent-what a{color:var(--green);font-weight:650;}
.recent-what a:hover{text-decoration:underline;}
.recent-url{display:block;color:var(--faint);font-family:var(--mono);font-size:11.5px;margin-top:2px;overflow-wrap:anywhere;}
.recent-when{flex:none;color:var(--faint);font-size:11.5px;white-space:nowrap;}

/* ---- health and allowance strip ---- */
.strip{display:grid;grid-template-columns:minmax(240px,.72fr) minmax(0,1.8fr);gap:16px;align-items:start;}
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

/* The local token service owns collection and history; this pane is its calm
   Mission Control summary. One allowance number leads each card, with pace,
   runway, observed trend, and balancing activity subordinate to that number. */
.allowance-pane{padding:18px 18px 16px;}
.qmeta{display:flex;align-items:center;gap:8px 14px;flex-wrap:wrap;margin:-3px 0 12px;
  color:var(--faint);font-size:11px;}
.qmeta span:first-child{color:var(--slate);font-weight:600;}
.qalert,.qfallback,.qmissing{margin:0 0 12px;padding:9px 11px;border-radius:9px;font-size:11.5px;}
.qalert{color:var(--amber);background:var(--amber-soft);border:1px solid #f1dfb9;}
.qfallback{color:var(--muted);background:var(--slate-soft);}
.qmissing{margin-top:10px;color:var(--amber);background:var(--amber-soft);}
.quota-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px;}
.qwindow{min-width:0;padding:12px 11px 10px;border:1px solid var(--line);border-radius:11px;background:#fbfcfe;
  display:flex;flex-direction:column;}
.qwindow.tone-good{border-color:#d8eadf;}
.qwindow.tone-warn{border-color:#efdfb8;}
.qwindow.tone-alert{border-color:#efd1ce;}
.qw-head{display:flex;align-items:baseline;gap:7px;min-height:30px;}
.qw-name{flex:1;font-size:11.5px;font-weight:650;color:var(--ink);overflow-wrap:anywhere;}
.qw-provider{flex:none;max-width:45%;font-size:9px;color:var(--faint);text-align:right;overflow-wrap:anywhere;}
.qw-reading{display:flex;align-items:baseline;gap:5px;margin-top:3px;}
.qw-reading strong{font-size:27px;line-height:1;font-weight:680;letter-spacing:-.03em;}
.qw-reading span{font-size:10px;color:var(--muted);}
.qw-verdict{margin-top:6px;font-size:12px;font-weight:640;line-height:1.25;}
.tone-good .qw-verdict{color:var(--green);}
.tone-warn .qw-verdict{color:var(--amber);}
.tone-alert .qw-verdict{color:var(--red);}
.tone-muted .qw-verdict{color:var(--muted);}
.qw-context{min-height:31px;margin-top:3px;font-size:9.5px;line-height:1.4;color:var(--faint);overflow-wrap:anywhere;}
.qtrend{display:block;width:100%;height:54px;margin:7px 0 2px;overflow:visible;}
.qbudget{stroke:#b7bec8;stroke-width:.7;stroke-dasharray:2 2;}
.qnow{stroke:#c9ced6;stroke-width:.65;stroke-dasharray:1.5 1.5;}
.qactual{fill:none;stroke:var(--slate);stroke-width:1.5;stroke-linecap:round;stroke-linejoin:round;}
.qlatest{fill:var(--slate);stroke:#fff;stroke-width:.7;}
.qtrend.tone-good .qactual{stroke:var(--green);}.qtrend.tone-good .qlatest{fill:var(--green);}
.qtrend.tone-warn .qactual{stroke:var(--amber);}.qtrend.tone-warn .qlatest{fill:var(--amber);}
.qtrend.tone-alert .qactual{stroke:var(--red);}.qtrend.tone-alert .qlatest{fill:var(--red);}
.qtrend-empty{height:54px;margin:7px 0 2px;display:flex;align-items:center;justify-content:center;
  border-top:1px dashed var(--line);border-bottom:1px dashed var(--line);color:var(--faint);font-size:9.5px;text-align:center;}
.qw-trend-note{font-size:9px;color:var(--faint);overflow-wrap:anywhere;}
.qw-foot{display:flex;flex-direction:column;gap:2px;margin-top:auto;padding-top:7px;border-top:1px solid var(--line);
  color:var(--muted);font-size:9.5px;overflow-wrap:anywhere;}
.qbalance{margin-top:12px;border-top:1px solid var(--line);}
.qbalance summary{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:10px 2px 0;
  color:var(--muted);font-size:11px;cursor:pointer;list-style:none;}
.qbalance summary::-webkit-details-marker{display:none;}
.qbalance summary strong{color:var(--slate);font-weight:640;}
.qbalance-last{color:var(--faint);text-align:right;}
.qbalance ul{margin:9px 0 0;padding:0;list-style:none;border:1px solid var(--line);border-radius:9px;overflow:hidden;}
.qbalance li{display:grid;grid-template-columns:118px minmax(0,1fr) auto;gap:8px;padding:8px 10px;
  border-top:1px solid var(--line);font-size:10.5px;align-items:baseline;}
.qbalance li:first-child{border-top:none;}
.qbalance li time{color:var(--faint);font-family:var(--mono);font-size:9px;overflow-wrap:anywhere;}
.qbalance li span{overflow-wrap:anywhere;}.qbalance li small{color:var(--muted);text-align:right;overflow-wrap:anywhere;}
.qbalance-empty{margin:12px 0 0;padding-top:10px;border-top:1px solid var(--line);color:var(--faint);font-size:11px;}

footer{color:var(--faint);font-size:12px;text-align:center;margin-top:10px;overflow-wrap:anywhere;}

@media(max-width:920px){
  .strip{grid-template-columns:minmax(0,1fr)}
}
@media(max-width:720px){
  .stats{grid-template-columns:repeat(2,minmax(0,1fr))}
  .projects,.strip,.quota-grid{grid-template-columns:minmax(0,1fr)}
  .wrap{padding:28px 18px 48px}
  .need{align-items:flex-start;flex-wrap:wrap;padding:14px 16px;gap:10px}
  .need-main{align-items:flex-start;flex:1 1 calc(100% - 18px);gap:10px}
  .tag{width:auto}
  .decision-aid{margin-left:13px;min-height:44px;display:inline-flex;align-items:center;white-space:normal}
  .need .go{display:none}
  /* A 132px label column leaves too little for the value at phone widths, so the
     label sits above what it labels rather than squeezing it to a few words. */
  .need-ctx{padding:0 16px 14px 29px;gap:9px}
  .ctx-r{grid-template-columns:minmax(0,1fr);gap:1px}
  .ship{padding:12px 16px;align-items:flex-start;flex-wrap:wrap}
  .ship .what{flex:1 1 auto}
  .ship .who{margin-left:0;padding-left:0;flex:1 0 100%}
  .recent-action{padding:12px 16px;align-items:flex-start;flex-wrap:wrap;gap:8px}
  .recent-project{width:auto;}
  .recent-what{flex:1 1 calc(100% - 18px);}
  .recent-when{flex:1 0 100%;}
  .defer{padding:12px 16px;flex-wrap:wrap;gap:8px}
  .defer .tag{width:auto}
  .shelf summary,.shelf-note{padding-left:16px;padding-right:16px}
  .allowance-pane{padding:16px}
  .qwindow{padding:13px 12px 11px}
  .qw-head{min-height:0}
  .qtrend{height:72px}
  .qbalance summary{align-items:flex-start;flex-direction:column;gap:2px}
  .qbalance-last{text-align:left}
  .qbalance li{grid-template-columns:minmax(0,1fr) auto}
  .qbalance li time{grid-column:1 / -1}
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

   The managed self-reload navigates without the fragment, so the URL hash
   cannot be the mechanism that survives a reload - it is only an
   entry point for a hand-typed or copied link. The remembered tab is what
   actually survives, and a browser that refuses storage (a private context, or
   a restricted file:// origin) simply opens on the default tab. */
(function () {
  var keys = [\"decisions\", \"projects\", \"activity\", \"system\"];
  var boardHome = " + (.fm_home | @json | gsub("<"; "\\u003c")) + ";
  var origin = window.location.origin || \"\";
  var path = window.location.pathname || \"\";
  var scope = encodeURIComponent(boardHome) + \"|\" + encodeURIComponent(origin + path);
  var tabKey = \"fm-mission-control-tab-v2:\" + scope;
  var key = \"decisions\";
  var m = /^#(?:tab=|panel-)([a-z]+)$/.exec(window.location.hash || \"\");
  window.__fmBoardScope = scope;
  window.__fmTabKey = tabKey;
  window.__fmViewKey = \"fm-mission-control-view-v1:\" + scope;
  window.__fmReloadKey = \"fm-mission-control-reload-v1:\" + scope;
  window.__fmExplicitEntry = !!(m && !(window.history && window.history.state
    && window.history.state.fmBoardScope === scope && window.history.state.fmBoardTab === m[1]));
  try { if (window.history) { window.history.scrollRestoration = \"manual\"; } }
  catch (e) { /* browser-native restoration remains the fallback */ }
  try {
    if (m && keys.indexOf(m[1]) !== -1) {
      window.localStorage.setItem(tabKey, m[1]);
      try { window.sessionStorage.setItem(tabKey, m[1]); } catch (e) { /* session memory unavailable */ }
      key = m[1];
    } else {
      var saved = null;
      try { saved = window.sessionStorage.getItem(tabKey); } catch (e) { /* session memory unavailable */ }
      if (!saved) { saved = window.localStorage.getItem(tabKey); }
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
  <section id=\"awaiting-decisions\" data-scroll-anchor=\"section:decisions\">
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
+ thread_block
+ (if $deferred_count == 0 then ""
   else "<details class=\"shelf\" id=\"deferred-shelf\"><summary>"
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
  <section id=\"projects\" data-scroll-anchor=\"section:projects\">
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
  <section id=\"activity\" data-scroll-anchor=\"section:activity\">
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
     ((($d.pr_url // $d.report_path // ($d.links // [])[0]) // "") | web_url_or_empty) as $link |
     (if $link == "" then "<div class=\"ship\">" else (@html "<a class=\"ship\" href=\"\($link)\">") end)
     + icon_check
     + (@html "<span class=\"what\">\(dash($d.title // $d.raw))</span><span class=\"who\">\(dash(($d.repo // "") | short_repo))</span>")
     + (if $link == "" then "</div>" else "</a>" end)) | add) // "") + "</div>" end)
+ "  </section>
  <section id=\"recent-autonomous-actions\" data-scroll-anchor=\"section:recent-actions\">
    <div class=\"sec-h\"><h2>Recent autonomous actions</h2><span class=\"count\">last 12 hours</span></div>"
+ (if $recent_action_count == 0
   then "<p class=\"quiet\">No autonomous actions were recorded in the last 12 hours.</p>"
   else "<div class=\"recent-actions\">" + (($recent_actions | map(recent_action_row) | add) // "") + "</div>" end)
+ "  </section>
  </div>

  <div class=\"panel\" id=\"panel-system\" role=\"tabpanel\" aria-labelledby=\"tab-system\">
  <section class=\"strip\" id=\"health\">
    <div class=\"pane health-pane\">"
+ (@html "<h3>Fleet health<span class=\"count\">\(if $health_count > 0 then "\($health_count) \(plural($health_count; "item"; "items"))\(if $health_incomplete or ($backlog_present | not) then "+" else "" end)" elif $health_incomplete or ($backlog_present | not) then "incomplete" else "all clear" end)</span></h3>")
+ health_block
+ "    </div>
    <div class=\"pane allowance-pane\">
      <h3>Allowance &amp; pace</h3>"
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
    window.__fmExplicitNavigation = true;
    root.className = \"js t-\" + key;
    try { window.localStorage.setItem(window.__fmTabKey, key); } catch (e) { /* not remembered */ }
    try { window.sessionStorage.setItem(window.__fmTabKey, key); } catch (e) { /* session memory unavailable */ }
    /* #tab=<key> matches no element, so restoring it never scrolls the header
       off the top. The self-reload drops it regardless; the stored tab is what
       carries across. */
    try { history.replaceState({fmBoardScope:window.__fmBoardScope,fmBoardTab:key}, \"\", \"#tab=\" + key); }
    catch (e) { /* URL left alone */ }
    paint();
    window.scrollTo(0, 0);
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

  /* Project tags use the same card anchors and reading-position memory as the
     rest of the board. Without script their href reaches the card directly;
     with script this selects Projects first, then preserves that card as the
     current reading position through the next managed reload. */
  var arrivalTimer = null;
  var arrivalTarget = null;
  document.addEventListener(\"click\", function (ev) {
    var el = ev.target;
    if (el && el.nodeType !== 1) { el = el.parentElement; }
    el = el && el.closest ? el.closest(\"[data-project-anchor]\") : null;
    if (!el) { return; }
    var anchor = el.getAttribute(\"data-project-anchor\");
    var candidates = document.querySelectorAll(\"[data-scroll-anchor]\");
    var target = null;
    for (var i = 0; i < candidates.length; i++) {
      if (candidates[i].getAttribute(\"data-scroll-anchor\") === anchor) { target = candidates[i]; break; }
    }
    if (!target) { return; }
    ev.preventDefault();
    select(\"projects\", false);
    target.scrollIntoView({block:\"center\"});
    if (arrivalTimer) { window.clearTimeout(arrivalTimer); }
    if (arrivalTarget) { arrivalTarget.classList.remove(\"project-arrived\"); }
    target.classList.remove(\"project-arrived\");
    void target.offsetWidth;
    target.classList.add(\"project-arrived\");
    arrivalTarget = target;
    arrivalTimer = window.setTimeout(function () {
      target.classList.remove(\"project-arrived\");
      if (arrivalTarget === target) { arrivalTarget = null; }
      arrivalTimer = null;
    }, 1800);
    if (window.__fmSaveView) { window.__fmSaveView(target); }
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
  var shelf = document.getElementById(\"deferred-shelf\");
  var shelfKey = \"fm-mission-control-deferred-v2:\" + window.__fmBoardScope;
  if (shelf) {
    try {
      if (window.localStorage.getItem(shelfKey) === \"open\") { shelf.open = true; }
    } catch (e) { /* not remembered; closed is the right default */ }
    shelf.addEventListener(\"toggle\", function () {
      try {
        window.localStorage.setItem(shelfKey, shelf.open ? \"open\" : \"closed\");
      } catch (e) { /* not remembered */ }
    });
  }

  /* The compact balancing shelf is useful only if the board does not snap it
     shut on the next reload, so it keeps its own preference just like Deferred. */
  var balancing = document.getElementById(\"quota-balancing\");
  var balancingKey = \"fm-mission-control-quota-balancing-v2:\" + window.__fmBoardScope;
  if (balancing) {
    try {
      if (window.localStorage.getItem(balancingKey) === \"open\") { balancing.open = true; }
    } catch (e) { /* not remembered; closed is the right default */ }
    balancing.addEventListener(\"toggle\", function () {
      try {
        window.localStorage.setItem(balancingKey, balancing.open ? \"open\" : \"closed\");
      } catch (e) { /* not remembered */ }
    });
  }

  /* Token history remains useful with script disabled because ISO timestamps
     stay visible. With script, render those same values in the viewer local
     timezone without introducing a second collection or freshness clock. */
  var formats = {
    reset: {weekday: \"short\", hour: \"numeric\", minute: \"2-digit\"},
    short: {day: \"numeric\", month: \"short\", hour: \"numeric\", minute: \"2-digit\"},
    action: {day: \"numeric\", month: \"short\", hour: \"numeric\", minute: \"2-digit\"},
    updated: {day: \"numeric\", month: \"short\", hour: \"numeric\", minute: \"2-digit\"}
  };
  Array.prototype.forEach.call(document.querySelectorAll(\"time.qtime\"), function (time) {
    var date = new Date(time.dateTime);
    if (isNaN(date.valueOf())) { return; }
    var options = formats[time.getAttribute(\"data-format\")] || formats.short;
    try { time.textContent = new Intl.DateTimeFormat([], options).format(date); }
    catch (e) { /* ISO fallback stays visible */ }
  });
}());

/* Preserve the paragraph or card being read across this board own refresh.
   Browser storage is presentation memory only: it never changes fleet state or
   decides whether an item is still actionable. */
(function () {
  var viewKey = window.__fmViewKey;
  var reloadKey = window.__fmReloadKey;
  var explicitHash = window.location.hash || \"\";
  var loadStateRaw = null;
  var restoringView = true;
  try { loadStateRaw = window.sessionStorage.getItem(viewKey); } catch (e) { /* no saved view */ }

  function anchors() {
    return Array.prototype.slice.call(document.querySelectorAll(\"[data-scroll-anchor]\"));
  }

  function visibleAnchor() {
    var crossing = null;
    var below = null;
    anchors().forEach(function (row) {
      var style = window.getComputedStyle(row);
      if (style.display === \"none\" || style.visibility === \"hidden\") { return; }
      var rect = row.getBoundingClientRect();
      if (rect.height <= 0) { return; }
      if (rect.top <= 16 && rect.bottom > 16) { crossing = row; }
      else if (!below && rect.top > 16) { below = row; }
    });
    return crossing || below;
  }

  function saveView(preferredAnchor) {
    var anchor = preferredAnchor || visibleAnchor();
    var state = {y: Math.max(0, window.scrollY || 0)};
    if (anchor) {
      state.anchor = anchor.getAttribute(\"data-scroll-anchor\");
      state.offset = anchor.getBoundingClientRect().top;
    }
    try { window.sessionStorage.setItem(viewKey, JSON.stringify(state)); }
    catch (e) { /* scroll memory unavailable */ }
  }
  window.__fmSaveView = saveView;

  function restoreView() {
    try { window.sessionStorage.removeItem(reloadKey); } catch (e) { /* no managed-reload marker */ }
    if ((explicitHash && window.__fmExplicitEntry) || window.__fmExplicitNavigation) {
      if (/^#(?:tab=|panel-)[a-z]+$/.test(explicitHash)) { window.scrollTo(0, 0); }
      restoringView = false;
      saveView();
      return;
    }
    var state = null;
    try { state = JSON.parse(loadStateRaw || \"null\"); }
    catch (e) { state = null; }
    if (!state || typeof state.y !== \"number\") { restoringView = false; return; }

    var target = null;
    if (typeof state.anchor === \"string\") {
      anchors().some(function (row) {
        if (row.getAttribute(\"data-scroll-anchor\") === state.anchor) { target = row; return true; }
        return false;
      });
    }
    var y = state.y;
    if (target && typeof state.offset === \"number\") {
      y = window.scrollY + target.getBoundingClientRect().top - state.offset;
    }
    var max = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
    window.scrollTo(0, Math.max(0, Math.min(y, max)));
    restoringView = false;
    saveView();
  }

  window.addEventListener(\"scroll\", function () {
    if (!restoringView) { saveView(); }
  }, {passive: true});
  window.addEventListener(\"pagehide\", saveView);
  window.__fmRestoreView = restoreView;
  if (!document.querySelector(\".rc\")) { restoreView(); }

  var every = " + (($refresh * 1000) | tostring) + ";
  var due = Date.now() + every;
  setInterval(function () {
    if (Date.now() < due) { return; }
    if (typeof window.__fmMissionControlBusy === \"function\" && window.__fmMissionControlBusy()) { return; }
    saveView();
    try { window.sessionStorage.setItem(reloadKey, \"reload\"); } catch (e) { /* fallback is top */ }
    if (/^#(?:tab=|panel-)[a-z]+$/.test(window.location.hash || \"\")) {
      try { history.replaceState(null, \"\", window.location.pathname + window.location.search); }
      catch (e) { /* harmless: explicit hash wins over restoration */ }
    }
    window.location.reload();
  }, 1000);
}());
</script>
"
+ (if ($controls | not) then "" else
"<script>
/* The captain reply layer. It records requests and performs nothing: the only
   call it makes is to the reply service serving this board (or, on the legacy path,
   to the Lavish bridge), and the only thing it sends is one FM-BOARD-REQUEST line
   per deliberate tap. There is no external host, no token, and no action here, so
   a tap can never be the thing that merges, answers, or sets anything aside -
   firstmate decides all of that under its own contract. */
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

  /* The direct transport. Every request goes to the URL THIS DOCUMENT WAS LOADED
     FROM, so the
     board needs no endpoint, no path convention, and no knowledge of how it is
     being served or proxied. A page opened from a file, or served by any plain
     static server, gets no answer to the probe below and therefore stays the
     read-only board with no dead controls. */
  function ownUrl() { return window.location.pathname || \"/\"; }

  var COLLECTED = \"Recorded for firstmate, which applies it under its own checks. It stays here until the call clears.\";
  var UNCOLLECTED = \"Recorded, but firstmate is not collecting replies from this board yet.\";
  var collecting = true;

  /* A confirmation restored on load is written before the probe can answer, so
     once it does, any panel already on screen is corrected rather than left
     claiming a collection that is not happening. */
  function noteCollecting(ok) {
    collecting = ok;
    Array.prototype.forEach.call(document.querySelectorAll(\".rc-ok\"), function (panel) {
      var note = panel.querySelector(\".rc-ok-s\");
      if (ok) {
        if (note) { note.textContent = COLLECTED; }
        panel.classList.remove(\"rc-warn\");
      } else if (!panel.hidden) {
        if (note) { note.textContent = UNCOLLECTED; }
        panel.classList.add(\"rc-warn\");
      }
    });
  }

  var receiverReady = (function () {
    if (!window.fetch || !window.AbortController) { return Promise.resolve(false); }
    var stop, timer;
    try {
      stop = new AbortController();
      /* A hung service must not make the first tap look dead, which is the whole
         failure this transport exists to remove, so the probe is bounded. */
      timer = setTimeout(function () { stop.abort(); }, 2000);
    } catch (e) { return Promise.resolve(false); }
    return window.fetch(ownUrl() + \"?fm-board-reply=probe\",
        {method: \"GET\", cache: \"no-store\", signal: stop.signal})
      .then(function (res) { return res.ok ? res.text() : \"\"; })
      .then(function (text) {
        var data = null;
        try { data = JSON.parse(text); } catch (e) { return null; }
        return (data && data.service === \"fm-board-reply\") ? data : null;
      })
      .catch(function () { return null; })
      .then(function (data) {
        try { clearTimeout(timer); } catch (e) { /* already fired */ }
        if (!data) { return false; }
        document.body.classList.add(\"board-reply\");
        noteCollecting(data.armed !== false);
        return true;
      });
  }());

  /* The Ask-firstmate thread. This reads and renders; it is not a second way to
     ask for anything. Nothing firstmate says here carries an intent, a target, or
     a control, so a reply arriving on the board can never become an action - it
     is the answer to a question the captain already asked, shown where they asked
     it. Every value lands through textContent, so a reply is text and stays text. */
  var thread = document.getElementById(\"ask-thread\");
  var threadList = thread ? thread.querySelector(\".thr-list\") : null;
  var threadMore = thread ? thread.querySelector(\".thr-more\") : null;
  var threadReading = false;
  var threadFirst = true;

  function threadWhen(at) {
    if (typeof at !== \"string\" || !at) { return \"\"; }
    var when = new Date(at);
    if (isNaN(when.getTime())) { return at; }
    try { return when.toLocaleTimeString([], {hour: \"numeric\", minute: \"2-digit\"}); }
    catch (e) { return at; }
  }

  function renderThread(data) {
    if (!threadList || !data || !data.messages) { return; }
    if (threadFirst) { threadList.setAttribute(\"aria-live\", \"off\"); }
    var existing = {};
    Array.prototype.forEach.call(threadList.children, function (row) {
      if (row._fmThreadKey) { existing[row._fmThreadKey] = row; }
    });
    var wanted = {};
    var place = threadList.firstChild;
    Array.prototype.forEach.call(data.messages, function (message) {
      if (!message || typeof message.text !== \"string\" || !message.text) { return; }
      var key = (typeof message.id === \"string\" && message.id) ? message.id
        : (message.from + \" \" + message.at + \" \" + message.text);
      if (wanted[key]) { return; }
      wanted[key] = true;
      var mine = message.from === \"captain\";
      var row = existing[key];
      if (!row) {
        row = document.createElement(\"li\");
        row._fmThreadKey = key;
        row.className = mine ? \"thr-m thr-captain\" : \"thr-m thr-firstmate\";
        var head = document.createElement(\"div\");
        head.className = \"thr-head\";
        var who = document.createElement(\"span\");
        who.className = \"thr-who\";
        who.textContent = mine ? \"You\" : \"Firstmate\";
        head.appendChild(who);
        var when = threadWhen(message.at);
        if (when) {
          var stamp = document.createElement(\"time\");
          stamp.className = \"thr-at\";
          stamp.textContent = when;
          if (typeof message.at === \"string\") { stamp.setAttribute(\"datetime\", message.at); }
          head.appendChild(stamp);
        }
        var body = document.createElement(\"p\");
        body.className = \"thr-t\";
        body.textContent = message.text;
        row.appendChild(head);
        row.appendChild(body);
      }
      if (row !== place) { threadList.insertBefore(row, place); }
      place = row.nextSibling;
    });
    Array.prototype.forEach.call(Array.prototype.slice.call(threadList.children), function (row) {
      if (!row._fmThreadKey || !wanted[row._fmThreadKey]) { threadList.removeChild(row); }
    });
    /* Announce what ARRIVES, not what was already there: reading back the whole
       conversation on load would bury the one line the captain is waiting for. */
    if (threadFirst) {
      threadFirst = false;
      setTimeout(function () { threadList.setAttribute(\"aria-live\", \"polite\"); }, 0);
    }
    if (threadMore) { threadMore.hidden = data.truncated !== true; }
    if (thread) { thread.hidden = !threadList.children.length && data.truncated !== true; }
  }

  function readThread() {
    if (!thread || threadReading || !window.fetch || !window.AbortController) { return; }
    var stop, timer;
    try {
      stop = new AbortController();
      timer = setTimeout(function () { stop.abort(); }, 4000);
    } catch (e) { return; }
    threadReading = true;
    window.fetch(ownUrl() + \"?fm-board-reply=thread\",
        {method: \"GET\", cache: \"no-store\", signal: stop.signal})
      .then(function (res) { return res.ok ? res.text() : \"\"; })
      .then(function (text) {
        var data = null;
        try { data = JSON.parse(text); } catch (e) { data = null; }
        if (data && data.service === \"fm-board-reply\") { renderThread(data); }
      })
      .catch(function () { /* a poll that failed simply asks again on the next tick */ })
      .then(function () {
        try { clearTimeout(timer); } catch (e) { /* already fired */ }
        threadReading = false;
      });
  }

  /* The document refresh is deliberately held while a composer holds unsent text -
     exactly when the captain is mid-follow-up and firstmate's answer is most
     likely to land - so the thread keeps a tick of its own on the board's own
     cadence rather than riding the reload. */
  receiverReady.then(function (live) {
    if (!live || !thread) { return; }
    readThread();
    setInterval(readThread, " + (($refresh * 1000) | tostring) + ");
  });

  /* One request, recorded or refused. A 200 means the service validated it and
     stored it durably, which is the only thing the confirmed state ever claims.
     The attempt identity is what makes a retry after an interrupted send replace
     that exact attempt instead of recording one captain answer twice. */
  async function postRequest(wire, attempt) {
    var res = await window.fetch(ownUrl(), {
      method: \"POST\",
      cache: \"no-store\",
      headers: {\"Content-Type\": \"application/json\", \"X-Fm-Board-Reply\": \"1\"},
      body: JSON.stringify({wire: wire, attempt: attempt})
    });
    var text = \"\";
    if (!res.ok) {
      try { text = await res.text(); } catch (e) { text = \"\"; }
      var refusalData = null;
      try { refusalData = JSON.parse(text); } catch (e) { refusalData = null; }
      var refusal = new Error((refusalData && typeof refusalData.reason === \"string\"
        && refusalData.reason) || \"firstmate did not accept it\");
      refusal.definite = !!(refusalData && refusalData.ok === false
        && typeof refusalData.reason === \"string\");
      throw refusal;
    }
    text = await res.text();
    var data = null;
    try { data = JSON.parse(text); } catch (e) { data = null; }
    if (data && data.ok === true) { return data; }
    throw new Error((data && typeof data.reason === \"string\" && data.reason)
      || \"firstmate did not confirm receipt\");
  }

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

  /* Keep the outcome readable to anything reading the text of this row without adding
     a second green line beside the confirmation banner that already says it. */
  function noteOnly(block, message) {
    var sent = block.querySelector(\".rc-sent\");
    if (!sent) { return; }
    sent.textContent = message;
    sent.hidden = true;
    sent.classList.remove(\"rc-bad\");
  }

  function confirmPanel(block, intent) {
    return block.querySelector(\"[data-ok=\\\"\" + intent + \"\\\"]\");
  }

  function showConfirm(block, intent, label, warning) {
    var panel = confirmPanel(block, intent);
    if (!panel) { return; }
    /* Unhide first: a live region mutated while hidden is often not announced. */
    panel.hidden = false;
    var head = panel.querySelector(\".rc-ok-h\");
    if (head) { head.textContent = label; }
    var note = panel.querySelector(\".rc-ok-s\");
    if (note && warning) { note.textContent = warning; }
    if (warning) { panel.classList.add(\"rc-warn\"); }
  }

  function hideConfirm(block, intent) {
    var panel = confirmPanel(block, intent);
    if (panel) { panel.hidden = true; }
  }

  function summary(intent, what) {
    if (intent === \"merge\")  { return \"From the board - please merge: \" + what; }
    if (intent === \"defer\")  { return \"From the board - set aside: \" + what; }
    if (intent === \"answer\") { return \"From the board - answer on: \" + what; }
    if (intent === \"reply\")  { return \"From the board - note on: \" + what; }
    return \"From the board - a new ask\";
  }

  var ackPrefix = \"fm-mission-control-ack-v1:\" + window.__fmBoardScope + \":\";
  function ackKey(block, intent) {
    return ackPrefix + [block.getAttribute(\"data-home\") || \"main\",
      block.getAttribute(\"data-id\") || \"\", block.getAttribute(\"data-key\") || \"\", intent]
      .map(encodeURIComponent).join(\":\");
  }
  var draftKey = \"fm-mission-control-drafts-v1:\" + window.__fmBoardScope;
  var requestState = {};
  var requestInFlight = {};
  function draftIdentity(block, intent) {
    return [block.getAttribute(\"data-home\") || \"main\",
      block.getAttribute(\"data-id\") || \"\", block.getAttribute(\"data-key\") || \"\", intent]
      .map(encodeURIComponent).join(\":\");
  }
  function storedDrafts() {
    var records = [];
    try { records = JSON.parse(window.sessionStorage.getItem(draftKey) || \"[]\"); }
    catch (e) { records = []; }
    return Array.isArray(records) ? records : [];
  }
  function saveDrafts(skipView) {
    var records = {};
    storedDrafts().forEach(function (record) {
      if (record && typeof record.identity === \"string\") { records[record.identity] = record; }
    });
    Array.prototype.forEach.call(document.querySelectorAll(\".rc\"), function (block) {
      formsIn(block).forEach(function (form) {
        var intent = form.getAttribute(\"data-intent\") || \"\";
        if (!intent) { return; }
        var identity = draftIdentity(block, intent);
        var area = form.querySelector(\".rc-t\");
        var note = area ? area.value : \"\";
        var open = form.hasAttribute(\"data-toggle\") ? !form.hidden : note !== \"\";
        var pending = requestState[identity];
        var retry = records[identity] && records[identity].retry;
        if (!open && !note) { delete records[identity]; return; }
        records[identity] = {identity:identity,open:open,note:note};
        if (retry && typeof retry.payload === \"string\"
            && typeof retry.attempt === \"string\" && retry.attempt) {
          records[identity].retry = {payload:retry.payload,attempt:retry.attempt};
        }
        if (pending) {
          records[identity].queued = {status:pending.status,payload:pending.payload,
            note:pending.note,attempt:pending.attempt};
        }
      });
    });
    records = Object.keys(records).map(function (identity) { return records[identity]; });
    try {
      if (records.length) { window.sessionStorage.setItem(draftKey, JSON.stringify(records)); }
      else { window.sessionStorage.removeItem(draftKey); }
    } catch (e) { /* draft memory unavailable */ }
    if (!skipView && window.__fmSaveView) { window.__fmSaveView(); }
  }
  function storedRetry(identity) {
    var record = storedDrafts().find(function (candidate) {
      return candidate && candidate.identity === identity;
    });
    var retry = record && record.retry;
    return retry && typeof retry.payload === \"string\"
      && typeof retry.attempt === \"string\" && retry.attempt ? retry : null;
  }
  function rememberRetry(identity, retry) {
    var records = storedDrafts();
    var found = false;
    records.forEach(function (record) {
      if (!record || record.identity !== identity) { return; }
      found = true;
      if (retry) { record.retry = {payload:retry.payload,attempt:retry.attempt}; }
      else { delete record.retry; }
    });
    if (!found && retry) {
      records.push({identity:identity,open:true,note:\"\",
        retry:{payload:retry.payload,attempt:retry.attempt}});
    }
    try { window.sessionStorage.setItem(draftKey, JSON.stringify(records)); }
    catch (e) { /* retry memory unavailable */ }
  }
  function restoreDrafts() {
    var records = storedDrafts();
    records.forEach(function (record) {
      Array.prototype.some.call(document.querySelectorAll(\".rc\"), function (block) {
        var form = formsIn(block).find(function (candidate) {
          return draftIdentity(block, candidate.getAttribute(\"data-intent\") || \"\") === record.identity;
        });
        if (!form) { return false; }
        var opener = form.hasAttribute(\"data-toggle\")
          ? block.querySelector(\"[data-open=\\\"\" + form.getAttribute(\"data-intent\") + \"\\\"]\") : null;
        if (opener && opener.disabled) { return true; }
        var area = form.querySelector(\".rc-t\");
        if (area && typeof record.note === \"string\") { area.value = record.note; }
        if (record.open && form.hasAttribute(\"data-toggle\")) { shut(block); form.hidden = false; }
        if (record.queued && typeof record.queued.payload === \"string\"
            && typeof record.queued.note === \"string\"
            && typeof record.queued.attempt === \"string\" && record.queued.attempt) {
          var status = record.queued.status === \"queuing\" ? \"queuing\"
            : (record.queued.status === \"sending\" ? \"sending\" : \"queued\");
          requestState[record.identity] = {
            status:status, payload:record.queued.payload, note:record.queued.note,
            attempt:record.queued.attempt
          };
          keepQueuedPayload(block, form, requestState[record.identity]);
        }
        return true;
      });
    });
    saveDrafts(true);
  }

  /* Say only what the transport actually proved. The direct service answers after
     it has validated and stored the request, so \"received\" is a fact; the pinned
     Lavish bridge returns before delivery completes, so it can only claim
     \"queued\" unless it confirmed the send itself. */
  function ackLabel(intent, delivery) {
    var verb = delivery === \"received\" ? \"received\" : (delivery === \"sent\" ? \"sent\" : \"queued\");
    if (intent === \"merge\") { return \"Merge request \" + verb; }
    if (intent === \"answer\") { return \"Answer \" + verb; }
    if (intent === \"reply\") { return \"Reply \" + verb; }
    if (intent === \"defer\") { return \"Set-aside request \" + verb; }
    return \"Request \" + verb;
  }
  function ackSentence(label, delivery) {
    return label + (delivery === \"received\" ? \" by firstmate.\" : \" for firstmate.\");
  }
  /* An acknowledged control is REPLACED by its confirmation banner rather than
     just recoloured, because a small label beside an unchanged row was missed.
     The button keeps its acknowledged text and disabled state while hidden, so
     anything reading the row still sees which intent was acknowledged, and a
     sibling control the board can still resolve stays available. */
  function applyAck(block, intent, delivery, warning) {
    var label = ackLabel(intent, delivery);
    var opener = block.querySelector(\"[data-open=\\\"\" + intent + \"\\\"]\");
    if (opener) {
      opener.disabled = true;
      opener.textContent = label;
      opener.classList.add(\"rc-submitted\");
      if (confirmPanel(block, intent)) { opener.hidden = true; }
    }
    formsIn(block).forEach(function (form) {
      if (form.getAttribute(\"data-intent\") !== intent) { return; }
      var submit = form.querySelector(\".rc-go\");
      if (submit) { submit.disabled = true; submit.textContent = label; }
    });
    showConfirm(block, intent, label, warning);
    if (confirmPanel(block, intent)) { noteOnly(block, ackSentence(label, delivery)); }
    else { say(block, ackSentence(label, delivery), false); }
  }
  function restoreAcks() {
    var current = {};
    Array.prototype.forEach.call(document.querySelectorAll(\".rc\"), function (block) {
      formsIn(block).forEach(function (form) {
        var intent = form.getAttribute(\"data-intent\") || \"\";
        if (!intent || intent === \"ask\") { return; }
        var key = ackKey(block, intent);
        current[key] = true;
        try {
          var delivery = window.localStorage.getItem(key);
          if (delivery === \"sent\" || delivery === \"queued\" || delivery === \"received\") {
            applyAck(block, intent, delivery);
          }
        }
        catch (e) { /* acknowledgement memory unavailable */ }
      });
    });
    try {
      var stale = [];
      for (var i = 0; i < window.localStorage.length; i++) {
        var key = window.localStorage.key(i);
        if (key && key.indexOf(ackPrefix) === 0 && !current[key]) { stale.push(key); }
      }
      stale.forEach(function (key) { window.localStorage.removeItem(key); });
    } catch (e) { /* stale presentation memory retires on a later load */ }
  }
  restoreAcks();
  restoreDrafts();
  if (window.__fmRestoreView) { window.__fmRestoreView(); }

  function freezePayload(block, form, state) {
    var area = form.querySelector(\".rc-t\");
    var close = form.querySelector(\".rc-x\");
    var submit = form.querySelector(\".rc-go\");
    if (area) { area.value = state.note || \"\"; area.disabled = true; }
    if (close) { close.disabled = true; }
    if (submit) { submit.disabled = true; }
  }

  function releasePayload(form) {
    var area = form.querySelector(\".rc-t\");
    var close = form.querySelector(\".rc-x\");
    var submit = form.querySelector(\".rc-go\");
    if (area) { area.disabled = false; }
    if (close) { close.disabled = false; }
    if (submit) { submit.disabled = false; }
  }

  /* An interrupted send is genuinely ambiguous, so the exact payload is frozen and
     offered for retry under its own attempt identity rather than being edited or
     silently re-sent as newer text. */
  function keepQueuedPayload(block, form, state) {
    freezePayload(block, form, state);
    var submit = form.querySelector(\".rc-go\");
    if (submit) { submit.disabled = false; }
    say(block, state.status === \"queuing\"
      ? \"Queue interrupted - retry this saved answer.\"
      : (state.status === \"sending\"
        ? \"Sending was interrupted - retry to send this saved answer.\"
        : \"Queued but not sent - retry to send this saved answer.\"), true);
  }

  function newAttempt() {
    var values = null;
    try {
      values = new Uint32Array(4);
      window.crypto.getRandomValues(values);
    } catch (e) { values = [Date.now(), Math.floor(Math.random() * 4294967296)]; }
    return \"fm-board:\" + Array.prototype.map.call(values, function (value) {
      return Number(value).toString(16);
    }).join(\"-\");
  }

  document.addEventListener(\"click\", function (ev) {
    var el = ev.target;
    if (el && el.nodeType !== 1) { el = el.parentElement; }
    if (!el || !el.closest) { return; }

    var opener = el.closest(\"[data-open]\");
    if (opener) {
      var block = opener.closest(\".rc\");
      if (!block || opener.disabled) { return; }
      window.__fmExplicitNavigation = true;
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
      saveDrafts();
      return;
    }

    var cancel = el.closest(\".rc-x\");
    if (cancel) {
      var owner = cancel.closest(\".rc\");
      if (owner) {
        var form = cancel.closest(\".rc-f\");
        var intent = form && (form.getAttribute(\"data-intent\") || \"\");
        var pending = form && requestState[draftIdentity(owner, intent)];
        if (pending) {
          if (pending.status === \"queued\") { keepQueuedPayload(owner, form, pending); }
          else { say(owner, \"Sending - this answer cannot be changed yet.\", false); }
          return;
        }
        var area = form && form.querySelector(\".rc-t\");
        if (area) { area.value = \"\"; }
        shut(owner);
        saveDrafts();
      }
    }
  });

  document.addEventListener(\"submit\", async function (ev) {
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

    var persistent = request.intent !== \"ask\";
    var identity = persistent ? ackKey(block, request.intent) : \"\";
    var requestIdentity = draftIdentity(block, request.intent);
    try {
      var rememberedDelivery = persistent ? window.localStorage.getItem(identity) : null;
      if (rememberedDelivery === \"sent\" || rememberedDelivery === \"queued\"
        || rememberedDelivery === \"received\") {
        applyAck(block, request.intent, rememberedDelivery);
        shut(block);
        return;
      }
    } catch (e) { /* duplicate prevention continues for this page */ }

    var wire = \"FM-BOARD-REQUEST \" + JSON.stringify(request);
    if (await receiverReady) {
      /* The direct path is one step: the service either recorded the request or
         it did not. There is no queued-but-undelivered middle state to recover
         from, so a clean failure leaves the composer open and editable. */
      if (requestInFlight[requestIdentity]) { return; }
      var retry = storedRetry(requestIdentity);
      var attempting = {payload:wire,note:note,
        attempt:retry && retry.payload === wire ? retry.attempt : newAttempt()};
      requestInFlight[requestIdentity] = true;
      freezePayload(block, form, attempting);
      saveDrafts(true);
      rememberRetry(requestIdentity, attempting);
      var recorded = null;
      var refused = \"\";
      var definiteRefusal = false;
      try { recorded = await postRequest(wire, attempting.attempt); }
      catch (e) {
        refused = (e && e.message) || \"\";
        definiteRefusal = !!(e && e.definite === true);
      }
      delete requestInFlight[requestIdentity];
      if (!recorded) {
        if (definiteRefusal) { rememberRetry(requestIdentity, null); }
        releasePayload(form);
        say(block, \"Not sent - \" + (refused || \"the board could not reach firstmate\")
          + \". Try again.\", true);
        saveDrafts();
        return;
      }
      rememberRetry(requestIdentity, null);
      releasePayload(form);
      if (area) { area.value = \"\"; }
      noteCollecting(recorded.armed !== false);
      var uncollected = collecting ? \"\" : UNCOLLECTED;
      if (persistent) {
        try { window.localStorage.setItem(identity, \"received\"); }
        catch (e) { /* page state still prevents a duplicate */ }
        applyAck(block, request.intent, \"received\", uncollected);
      } else {
        var askLabel = ackLabel(request.intent, \"received\");
        showConfirm(block, request.intent, askLabel, uncollected);
        noteOnly(block, ackSentence(askLabel, \"received\"));
      }
      shut(block);
      saveDrafts();
      /* Read the thread back rather than drawing the captain's own message from
         here: what appears in the conversation is then only ever what the service
         actually stored, so the board cannot show a message that was never kept. */
      readThread();
      return;
    }

    var lav = bridge();
    if (!lav) {
      say(block, \"Not sent - this board is not connected to firstmate.\", true);
      saveDrafts();
      return;
    }
    var pending = requestState[requestIdentity];
    if (requestInFlight[requestIdentity]) { return; }
    if (pending && pending.payload !== wire) {
      keepQueuedPayload(block, form, pending);
      saveDrafts();
      return;
    }
    requestInFlight[requestIdentity] = true;
    try {
      if (!pending || pending.status !== \"queued\") {
        if (!pending) {
          pending = {status:\"queuing\",payload:wire,note:note,attempt:newAttempt()};
          requestState[requestIdentity] = pending;
        } else { pending.status = \"queuing\"; }
        freezePayload(block, form, pending);
        saveDrafts(true);
        var queued = lav.queuePrompt(wire, {
          tag: \"board-request\",
          text: summary(request.intent, block.getAttribute(\"data-what\") || \"\"),
          queueKey: pending.attempt
        });
        if (queued && typeof queued.then === \"function\") { queued = await queued; }
        if (queued === false) { throw new Error(\"queue refused\"); }
        pending.status = \"queued\";
        saveDrafts(true);
      }
      pending.status = \"sending\";
      freezePayload(block, form, pending);
      var accepted = lav.sendQueuedPrompts();
      if (accepted && typeof accepted.then === \"function\") { accepted = await accepted; }
      if (accepted === false) { throw new Error(\"send refused\"); }
      var delivery = accepted === true ? \"sent\" : \"queued\";
      delete requestState[requestIdentity];
      delete requestInFlight[requestIdentity];
    } catch (e) {
      delete requestInFlight[requestIdentity];
      if (pending && pending.status === \"queuing\") {
        delete requestState[requestIdentity];
        releasePayload(form);
      }
      else if (pending) { pending.status = \"queued\"; keepQueuedPayload(block, form, pending); }
      if (!pending || pending.status !== \"queued\") {
        say(block, \"Not sent - the board could not reach firstmate.\", true);
      }
      saveDrafts();
      return;
    }
    if (area) { area.value = \"\"; }
    releasePayload(form);
    if (persistent) {
      try { window.localStorage.setItem(identity, delivery); } catch (e) { /* page state still prevents a duplicate */ }
      applyAck(block, request.intent, delivery);
    } else {
      var bridgedLabel = ackLabel(request.intent, delivery);
      showConfirm(block, request.intent, bridgedLabel);
      noteOnly(block, ackSentence(bridgedLabel, delivery));
    }
    shut(block);
    saveDrafts();
  });

  document.addEventListener(\"input\", function (ev) {
    var area = ev.target;
    if (!area || !area.closest) { return; }
    var form = area.closest(\".rc-f\");
    var block = form && form.closest(\".rc\");
    var pending = block && form && requestState[draftIdentity(block, form.getAttribute(\"data-intent\") || \"\")];
    if (pending) {
      if (pending.status === \"queued\") { keepQueuedPayload(block, form, pending); }
      else { freezePayload(block, form, pending); }
      saveDrafts();
      return;
    }
    var ask = area.closest(\".rc-ask\");
    if (ask) {
      var submit = ask.querySelector(\".rc-go\");
      if (submit) { submit.disabled = false; submit.textContent = \"Send to firstmate\"; }
      var sent = ask.querySelector(\".rc-sent\");
      if (sent) { sent.hidden = true; }
      /* A new ask is a new request, so the previous confirmation stops standing
         over text that has not been sent. */
      hideConfirm(ask, \"ask\");
    }
    if (area.classList && area.classList.contains(\"rc-t\")) { saveDrafts(); }
  });
  window.addEventListener(\"pagehide\", saveDrafts);

  /* The common managed refresh consults this only to avoid discarding an open
     control or text the captain has not sent. */
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

  window.__fmMissionControlBusy = busy;
}());
</script>
" end)
+ "</body></html>
"
FM_MISSION_CONTROL_JQ
}

HTML=$(render_html) || die "rendering failed"

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
