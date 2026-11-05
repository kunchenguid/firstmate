#!/usr/bin/env bash
# fm-projects-view.sh - build, serve, and act on the Bearings Projects view.
#
# The Projects view is the captain's one-page tracker of high-level projects:
# per project, what needs the captain, what is in progress, what is done, and
# what is left. Unlike the agent-composed fleet board (bin/fm-bearings-board.sh)
# it is a pure function of structured state, so it is rebuilt automatically.
#
# Usage:
#   fm-projects-view.sh check
#   fm-projects-view.sh model [--snapshot <fleet-snapshot.json>]
#   fm-projects-view.sh build [--snapshot <fleet-snapshot.json>]
#   fm-projects-view.sh serve
#   fm-projects-view.sh refresh [--full]
#   fm-projects-view.sh add <project-id> <words...>
#   fm-projects-view.sh correct <task-id> <words...>
#   fm-projects-view.sh path
#
# check    Validate config/projects.json against fm-projects.v1 and print
#          `ok: <n> projects`. Exit 1 with the reason on a missing or
#          malformed file. docs/configuration.md "Projects view" owns the
#          schema.
# model    Print the fm-projects-view.v1 JSON model. Inputs are structured
#          only: the canonical bin/fm-fleet-snapshot.sh --json (run fresh unless
#          --snapshot names a captured copy), config/projects.json, and the Done
#          rows of the configured backlog archive inside the window, parsed by
#          the snapshot's own backlog parser. Report, status, and chat prose are
#          never read. Membership is deterministic, first hit wins: a
#          `Project: <id>` task body line naming a configured project, then the
#          first project in config order whose `match` glob matches the task id,
#          then a repo listed by exactly one project; anything else lands in
#          `unassigned`. Each item lands in exactly one group:
#            needs   - captain holds in the live or aged bucket
#            moving  - in-flight work, and a secondmate's active children
#            done    - delivered Done rows (bin/fm-landed-lib.sh's rule) whose
#                      completion date falls inside window_days
#            next    - queued work, plus dated or blocked captain holds
#          counts.needs is the per-project counter the page always shows.
#          Main-home items carry local=true and are the only ones the page
#          offers actions on; secondmate items are read-only here. A
#          secondmate row joins a project by the same rules, through the
#          project_hint and repo its home summary carries, and one task id in a
#          home lands in one group (needs, then moving, then next, then done).
#          `homes` lists every registered secondmate with how its rows were
#          read (fresh, cached with an age, partial, or not read with the
#          reason) and how many rows its summary omitted, so missing or old
#          records never read as completed work.
#          The snapshot runs in one of two scopes. A full snapshot
#          (`fm-fleet-snapshot.sh --json`) fetches every remote secondmate's
#          ledger over ssh and probes each local worker's crew state; only an
#          explicit `serve` (/bearings projects), `model`, `build`, or a
#          `refresh --full` pays for it. A local-only snapshot
#          (`fm-fleet-snapshot.sh --local-only`) reads this machine's files
#          alone: secondmate rows come from the parent-side cached ledgers and
#          no worker is probed, so an in-progress item keeps the status the
#          page last published for it until the next full pass. Plain
#          `refresh`, the routine trigger, always uses the local-only scope.
# build    Write the model into a fresh copy of the shipped template
#          (.agents/skills/bearings/assets/projects-template.html) at the stable
#          path $FM_HOME/.lavish/projects.html with the same one-slot injection
#          and `<` escaping as the fleet board. The write is skipped when the
#          model, apart from its generated time, equals the one already
#          published, so an open page only reloads on a real change. Prints
#          `projects: <path>` and `unchanged` or `written`.
# serve    Build, then establish the page's Lavish session, bind its answer
#          source, and arm its listener through bin/fm-lavish-board-lib.sh (the
#          same proved-live sequence as the fleet board). Only an explicit
#          request serves; refresh never opens or reopens a session.
# refresh  The cheap trigger called by bin/fm-wake-drain.sh and
#          bin/fm-teardown.sh. It does nothing unless config/projects.json
#          exists, marks the view dirty, and starts one detached rebuild that
#          holds a home-scoped lock and loops while the view is still dirty, so
#          concurrent triggers coalesce. It never prints, never fails its
#          caller, and logs to state/projects-view.log.
#          Plain `refresh` is the routine mode: local-only scope, and at most
#          one rebuild per FM_PROJECTS_VIEW_COOLDOWN_SECS (default 600, the
#          floor a routine wake may run at; lower values are for tests). A
#          trigger inside the cooldown leaves the view dirty and the detached
#          rebuild waits out the remainder, so the page still catches up
#          without another trigger, and a routine wake never fans out over
#          ssh. `refresh --full` is the heartbeat mode: the wake drain asks for
#          it when it presents a heartbeat row, it uses the full scope, and it
#          bypasses the cooldown (a waiting rebuild picks it up within a few
#          seconds). `serve` always publishes a full snapshot inline.
# add      File the captain's words as a new Queued backlog item for that
#          project through bin/fm-tasks-axi.sh, with a `Project: <id>` body
#          line and the words verbatim. The repo is the project's only repo when
#          it lists exactly one. Prints the new task id. Dispatch stays with
#          firstmate's normal intake and bin/fm-spawn.sh.
# correct  Steer a live local task with the captain's words through
#          bin/fm-send.sh, which records them in the task's steering inbox.
#          Refuses a task with no state/<id>.meta record in this home and a
#          secondmate's own record.
# path     Print the stable page path for this home.
#
# Page answers ride the fleet board's fm-bearings-answer.v1 capture under the
# keys `pv.add.<project-id>` and `pv.fix.<task-id>`, and firstmate routes them
# (.agents/skills/bearings/SKILL.md, "Projects view"). Task ids share the answer
# key alphabet, so no prefix alone can keep a key from naming a task: `serve`
# therefore never binds the page to the keyed-answer intake (it removes any
# binding instead), and the model publishes a key only when it equals no task
# id the snapshot knows, leaving that action off the page otherwise. A
# needs-you card is read-only; the captain answers in chat.
#
# FM_PROJECTS_VIEW_TEMPLATE overrides the shipped template path (tests only).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS_CONFIG="$CONFIG/projects.json"

TEMPLATE="${FM_PROJECTS_VIEW_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/projects-template.html}"
PLACEHOLDER='__FM_PROJECTS_VIEW_DATA__'
CONFIG_SCHEMA=fm-projects.v1
MODEL_SCHEMA=fm-projects-view.v1
LIST_CAP=30
SNAPSHOT_SCOPE=${SNAPSHOT_SCOPE:-full}
COOLDOWN_SECS=${FM_PROJECTS_VIEW_COOLDOWN_SECS:-600}
case "$COOLDOWN_SECS" in ''|*[!0-9]*) COOLDOWN_SECS=600 ;; esac

# shellcheck source=bin/fm-landed-lib.sh
. "$SCRIPT_DIR/fm-landed-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-projects-view: %s\n' "$*" >&2
  exit 1
}

page_path() { printf '%s/.lavish/projects.html\n' "$FM_HOME"; }

# The fm-projects.v1 contract. Unknown keys refuse so a typo cannot silently
# drop a project's rules.
validate_config() {  # <config.json>
  jq -e --arg schema "$CONFIG_SCHEMA" '
    def slug: type == "string" and test("^[a-z0-9][a-z0-9-]{0,63}$");
    def name: type == "string" and length > 0 and length <= 80 and (explode | all(.[]; . >= 32));
    def glob: type == "string" and test("^[A-Za-z0-9._*?-]{1,128}$");
    def repo: type == "string" and test("^[A-Za-z0-9._-]{1,128}$");
    def project:
      type == "object"
      and ((keys - ["id", "name", "color", "repos", "match"]) | length) == 0
      and (.id | slug)
      and (.name | name)
      and ((has("color") | not) or (.color | type == "string" and test("^#[0-9A-Fa-f]{6}$")))
      and ((has("repos") | not) or (.repos | type == "array" and all(.[]; repo)))
      and ((has("match") | not) or (.match | type == "array" and all(.[]; glob)));
    type == "object"
    and ((keys - ["schema", "window_days", "projects"]) | length) == 0
    and .schema == $schema
    and ((has("window_days") | not)
      or (.window_days | type == "number" and . == floor and . >= 1 and . <= 365))
    and (.projects | type == "array" and length >= 1 and length <= 50)
    and all(.projects[]; project)
    and ([.projects[].id] | length == (unique | length))
  ' "$1" >/dev/null 2>&1
}

require_config() {
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$PROJECTS_CONFIG" ] || fail "no projects config: $PROJECTS_CONFIG (docs/configuration.md \"Projects view\")"
  jq empty "$PROJECTS_CONFIG" 2>/dev/null || fail "projects config is not valid JSON: $PROJECTS_CONFIG"
  validate_config "$PROJECTS_CONFIG" \
    || fail "projects config does not satisfy $CONFIG_SCHEMA: $PROJECTS_CONFIG (docs/configuration.md \"Projects view\")"
}

command_check() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  require_config
  printf 'ok: %s projects\n' "$(jq '.projects | length' "$PROJECTS_CONFIG")"
}

archive_path() {
  local configured
  configured=$(awk -F= '
    /^\[/ { section = $0; next }
    section == "[markdown]" && $1 ~ /^[[:space:]]*archive[[:space:]]*$/ {
      v = $2; gsub(/^[[:space:]]*"|"[[:space:]]*$/, "", v); print v; exit
    }' "$FM_HOME/.tasks.toml" 2>/dev/null)
  [ -n "$configured" ] || configured=data/done-archive.md
  case "$configured" in
    /*) printf '%s\n' "$configured" ;;
    data/*) printf '%s/%s\n' "$DATA" "${configured#data/}" ;;
    *) printf '%s/%s\n' "$FM_HOME" "$configured" ;;
  esac
}

# Done rows archived on or after the cutoff, parsed by the canonical snapshot
# backlog parser so this view never owns a second row grammar. A row's archive
# date is never earlier than its completion date, so this bounded read cannot
# miss an in-window completion.
archive_records() {  # <cutoff YYYY-MM-DD> <out.json>
  local cutoff=$1 out=$2 archive scratch
  archive=$(archive_path)
  if [ ! -f "$archive" ]; then
    printf '[]\n' > "$out"
    return 0
  fi
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-projects-archive.XXXXXX") || return 1
  mkdir -p "$scratch/data" "$scratch/state" || { rm -rf -- "$scratch"; return 1; }
  {
    printf '## Done\n'
    awk -v cutoff="$cutoff" '
      /^##[[:space:]]+Archived[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}/ { on = ($3 >= cutoff); next }
      /^##/ { on = 0; next }
      on { print }
    ' "$archive"
  } > "$scratch/data/backlog.md" || { rm -rf -- "$scratch"; return 1; }
  if ! FM_HOME="$scratch" FM_DATA_OVERRIDE="$scratch/data" FM_STATE_OVERRIDE="$scratch/state" \
      FM_CONFIG_OVERRIDE="$scratch/config" FM_PROJECTS_OVERRIDE="$scratch/projects" \
      "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input 2>/dev/null \
      | jq -c '[.backlog.records[]? | select(.structured and .state == "done")]' > "$out"; then
    rm -rf -- "$scratch"
    return 1
  fi
  rm -rf -- "$scratch"
}

snapshot_cutoff() {  # <snapshot.json> <window-days>
  jq -r --argjson days "$2" '
    (.generated | fromdateiso8601) as $now
    | (($now - (($days - 1) * 86400)) | strftime("%Y-%m-%d"))' "$1"
}

build_model() {  # <snapshot.json> <archive.json> <published-model.json>
  jq -c --slurpfile cfg "$PROJECTS_CONFIG" --slurpfile archive "$2" --slurpfile published "$3" \
    --arg schema "$MODEL_SCHEMA" --arg home "$FM_HOME" --argjson cap "$LIST_CAP" \
    --arg scope "$SNAPSHOT_SCOPE" \
    "$FM_LANDED_JQ_DEFS"'
    def palette: ["#ef4444","#0ea5e9","#8b5cf6","#14b8a6","#ec4899","#64748b","#f97316","#84cc16","#6366f1","#c026d3"];
    def glob_re: "^" + (gsub("\\."; "\\.") | gsub("\\*"; ".*") | gsub("\\?"; ".")) + "$";
    def state_label:
      if . == "working" then "Working"
      elif . == "paused" then "Waiting"
      elif . == "blocked" then "Stuck"
      elif . == "done" then "Wrapping up"
      elif . == "failed" then "Stopped"
      else "Started" end;

    ($cfg[0]) as $config
    | ($config.window_days // 30) as $window
    | . as $snap
    | (($snap.generated | fromdateiso8601) - (($window - 1) * 86400) | strftime("%Y-%m-%d")) as $cutoff
    | [$config.projects | to_entries[] | .value + {color:(.value.color // palette[.key % (palette | length)])}] as $projects
    | ([$projects[].id]) as $ids
    | (reduce ($snap.tasks // [])[] as $t ({}; .[$t.id] = $t)) as $tasks
    | (reduce (($snap.backlog.records // [])[] | select(.structured and .id != null)) as $r ({}; .[$r.id] = $r.title)) as $titles
    | (if $scope == "local" then
         reduce (($published[0].projects // [])[] | .moving[]? | select(.local and .status != null)) as $m ({}; .[$m.id] = $m.status)
       else {} end) as $kept
    | def after($ids): if ($ids | length) > 0 then "After " + ($ids | map($titles[.] // .) | join(", ")) else null end;

    # Membership: explicit body line, then id glob, then exclusive repo.
    def project_of:
        . as $item
        | ([(if ($item.project_hint // null) != null then $item.project_hint else empty end),
            (($item.body_lines // [])[]
             | (capture("^Project:[[:space:]]*(?<p>[a-z0-9][a-z0-9-]{0,63})[[:space:]]*$")? | .p))
            | select(. as $p | $ids | index($p) != null)] | first) as $explicit
        | if $explicit != null then $explicit
          else
            ([$projects[] | select(any((.match // [])[]; . as $g | $item.id | test($g | glob_re))) | .id] | first) as $by_id
            | if $by_id != null then $by_id
              else
                ([$projects[] | select(($item.repo // null) != null and ((.repos // []) | index($item.repo) != null)) | .id]) as $by_repo
                | if ($by_repo | length) == 1 then $by_repo[0] else null end
              end
          end;

    # Main-home backlog items.
    def main_items:
      [($snap.backlog.records // [])[]
       | select(.structured and .id != null)
       | . as $r
       | ($tasks[$r.id] // null) as $task
       | if ($r.hold_bucket == "live" or $r.hold_bucket == "aged") then
           {group:"needs",id:$r.id,title:$r.title,repo:$r.repo,local:true,home:null,
            question:($r.hold_reason // ""),age_days:$r.hold_age_days,aged:($r.hold_bucket == "aged"),
            body_lines:$r.body_lines,sort:($r.order)}
         elif $r.state == "in_flight" and $r.hold_bucket == null then
           {group:"moving",id:$r.id,title:$r.title,repo:$r.repo,local:true,home:null,
            status:(if ($task.current_state.source // "none") == "none" and $kept[$r.id] != null then $kept[$r.id]
                    else (($task.current_state.state // "") | state_label) end),since:$r.since,
            correctable:($task != null and ($task.kind // "") != "secondmate"),
            body_lines:$r.body_lines,sort:($r.order)}
         elif $r.state == "in_flight" or $r.state == "queued" then
           {group:"next",id:$r.id,title:$r.title,repo:$r.repo,local:true,home:null,
            reason:(if $r.hold_bucket == "dated" then "Back on " + ($r.hold_until // "")
                    else after($r.unresolved_blocker_ids) end),
            body_lines:$r.body_lines,sort:($r.order)}
         elif $r.state == "done" and ($r | landed_record) and (($r.completion.date // "") >= $cutoff) then
           {group:"done",id:$r.id,title:$r.title,repo:$r.repo,local:true,home:null,
            date:$r.completion.date,body_lines:$r.body_lines,sort:($r.order)}
         else empty end];

    def archive_items($known):
      [($archive[0] // [])[]
       | select(.id != null) | select(.id as $id | $known | index($id) == null)
       | select(landed_record and ((.completion.date // "") >= $cutoff))
       | {group:"done",id,title,repo,local:true,home:null,date:.completion.date,body_lines,sort:0}];

    # Secondmate items, read-only here. One task id per home keeps one group,
    # in the local precedence order.
    def group_rank: {"needs":0,"moving":1,"next":2,"done":3}[.group];
    def mate_items:
      [($snap.secondmate_current.records // [])[]
       | . as $mate
       | [(($mate.queued // [])[]
            | if (.hold_bucket == "live" or .hold_bucket == "aged") then
                {group:"needs",id,title,repo:(.repo // null),project_hint:(.project_hint // null),local:false,home:$mate.id,
                 question:(.hold_reason // ""),age_days:.hold_age_days,aged:(.hold_bucket == "aged"),sort:0}
              else
                {group:"next",id,title,repo:(.repo // null),project_hint:(.project_hint // null),local:false,home:$mate.id,
                 reason:(if .hold_bucket == "dated" then "Back on " + (.hold_until // "")
                         else after(.unresolved_blocker_ids // []) end),sort:0}
              end),
          (($mate.decisions_open // [])[]
            | select(.verb == "captain-hold")
            | {group:"needs",id,title:(.summary // .id),repo:(.repo // null),project_hint:(.project_hint // null),
               local:false,home:$mate.id,
               question:(.reason // ""),age_days:.hold_age_days,aged:(.hold_bucket == "aged"),sort:0}),
          (($mate.active_children // [])[]
            | {group:"moving",id,title:(.name // .id),repo:(.repo // null),project_hint:(.project_hint // null),
               local:false,home:$mate.id,
               status:((.state // "") | state_label),since:null,correctable:false,sort:0}),
          (($mate.landed // [])[]
            | select((.completion.date // "") >= $cutoff)
            | {group:"done",id,title,repo:(.repo // null),project_hint:(.project_hint // null),
               local:false,home:$mate.id,date:.completion.date,sort:0})]
       | group_by(.id) | map(min_by(group_rank)) | .[]];

    # How each secondmate home was read, so a missing or old summary is shown
    # as such rather than as an empty or current project.
    def home_states:
      [($snap.secondmate_current.records // [])[]
       | {id,
          status:(if (.provenance.selected // "") != "structured-home" then "unread"
                  elif (.provenance.trust // "complete") != "complete" then "partial"
                  elif (.freshness.status // "") == "cached" then "cached"
                  else "fresh" end),
          reason:(.current.reason // null),
          age_seconds:(.freshness.age_seconds // null),
          omitted:([(.omitted // [])[] | (.count // 0)] | add // 0)}];

    (main_items) as $main
    | ($main + archive_items([$main[].id]) + mate_items
       | map(. + {project:project_of} | del(.body_lines, .project_hint))) as $items
    # Every task id this snapshot knows; a page key equal to one is withheld.
    | ([$items[].id] + [($snap.backlog.records // [])[] | .id // empty]
       + [($archive[0] // [])[] | .id // empty] | unique) as $task_ids
    | def page_key($k): if ($task_ids | index($k)) == null and ($k | test("^[A-Za-z0-9._-]{1,128}$")) then $k else null end;

    def group_rows($rows; $group):
        [$rows[] | select(.group == $group)]
        | if $group == "done" then sort_by(.date, .id) | reverse
          elif $group == "moving" then sort_by(.since // "") | reverse
          else sort_by(.sort) end
        | map(del(.group, .project, .sort)
              | if .correctable == true then . + {fix_key:page_key("pv.fix." + .id)} else . end);
      def capped($list): {rows:$list[:$cap], more:([($list | length) - $cap, 0] | max)};

    {
      schema:$schema,
      generated:$snap.generated,
      home:$home,
      window_days:$window,
      homes:home_states,
      totals:{
        needs:([$items[] | select(.group == "needs")] | length),
        moving:([$items[] | select(.group == "moving")] | length),
        done:([$items[] | select(.group == "done")] | length)
      },
      projects:[$projects[]
        | . as $p
        | [$items[] | select(.project == $p.id)] as $rows
        | group_rows($rows; "needs") as $needs
        | group_rows($rows; "moving") as $moving
        | group_rows($rows; "done") as $done
        | group_rows($rows; "next") as $next
        | {id:$p.id,name:$p.name,color:$p.color,add_key:page_key("pv.add." + $p.id),
           counts:{needs:($needs | length),moving:($moving | length),done:($done | length),next:($next | length)},
           now:(if ($moving | length) > 0 then $moving[0].title
                elif ($needs | length) > 0 then $needs[0].title
                elif ($next | length) > 0 then $next[0].title
                else null end),
           needs:$needs,
           moving:$moving,
           done:capped($done),
           next:capped($next)}],
      unassigned:(
        [$items[] | select(.project == null)] as $rows
        | {count:($rows | length),
           needs:([$rows[] | select(.group == "needs")] | length),
           rows:([$rows[] | {id,title,group,local}] | .[:$cap])})
    }' "$1"
}

validate_model() {  # <model.json>
  jq -e --arg schema "$MODEL_SCHEMA" '
    type == "object" and .schema == $schema and (.projects | type == "array")
    and all(.projects[]; (.counts.needs | type == "number") and (.needs | type == "array"))
  ' "$1" >/dev/null 2>&1
}

# Writes the model to <out>; the snapshot is captured fresh unless supplied.
produce_model() {  # <out.json> [<snapshot.json>]
  local out=$1 snapshot=${2-} scratch window cutoff rc=0 snapshot_flag
  require_config
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-projects-view.XXXXXX") || fail "cannot stage the model"
  if [ -n "$snapshot" ]; then
    [ -f "$snapshot" ] || { rm -rf -- "$scratch"; fail "snapshot does not exist: $snapshot"; }
    cp -- "$snapshot" "$scratch/snapshot.json" || { rm -rf -- "$scratch"; fail "cannot read the snapshot"; }
  else
    case "$SNAPSHOT_SCOPE" in
      local) snapshot_flag=--local-only ;;
      *) snapshot_flag=--json ;;
    esac
    if ! "$SCRIPT_DIR/fm-fleet-snapshot.sh" "$snapshot_flag" > "$scratch/snapshot.json" 2>"$scratch/snapshot.err"; then
      rm -rf -- "$scratch"
      fail "cannot capture the fleet snapshot"
    fi
  fi
  published_model "$(page_path)" 2>/dev/null | jq -c '.' > "$scratch/published.json" 2>/dev/null || : > "$scratch/published.json"
  jq -e '.schema == "fm-fleet-snapshot.v1" and (.generated | type == "string")' "$scratch/snapshot.json" >/dev/null 2>&1 \
    || { rm -rf -- "$scratch"; fail "the fleet snapshot is not a readable fm-fleet-snapshot.v1 document"; }
  window=$(jq '.window_days // 30' "$PROJECTS_CONFIG")
  cutoff=$(snapshot_cutoff "$scratch/snapshot.json" "$window") \
    || { rm -rf -- "$scratch"; fail "cannot compute the done window"; }
  archive_records "$cutoff" "$scratch/archive.json" \
    || { rm -rf -- "$scratch"; fail "cannot read the backlog archive"; }
  build_model "$scratch/snapshot.json" "$scratch/archive.json" "$scratch/published.json" > "$out" || rc=1
  rm -rf -- "$scratch"
  [ "$rc" -eq 0 ] || fail "cannot build the projects model"
  validate_model "$out" || fail "the built model does not satisfy $MODEL_SCHEMA"
}

parse_snapshot_flag() {  # sets SNAPSHOT_ARG from "$@"
  SNAPSHOT_ARG=
  case "$#" in
    0) ;;
    2) [ "$1" = --snapshot ] || { usage >&2; exit 2; }; SNAPSHOT_ARG=$2 ;;
    *) usage >&2; exit 2 ;;
  esac
}

command_model() {
  local out
  parse_snapshot_flag "$@"
  out=$(mktemp "${TMPDIR:-/tmp}/fm-projects-model.XXXXXX") || fail "cannot stage the model"
  ( produce_model "$out" "$SNAPSHOT_ARG" ) || { rm -f -- "$out"; exit 1; }
  cat -- "$out"
  rm -f -- "$out"
}

published_model() {  # <page>
  [ -f "$1" ] || return 1
  sed -n '/<script id="projects-data" type="application\/json">/,/<\/script>/p' "$1" | sed '1d;$d'
}

# Builds and publishes the page; prints `projects: <path>` then `written` or
# `unchanged`. FORCE_WRITE=1 publishes even an unchanged model.
template_digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$TEMPLATE" | awk '{print $1}'
  else
    sha256sum "$TEMPLATE" | awk '{print $1}'
  fi
}

publish_page() {  # [<snapshot.json>]
  local snapshot=${1-} model json page tmp extracted old new digest
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "projects template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "projects template does not carry exactly one data slot: $TEMPLATE"
  model=$(mktemp "${TMPDIR:-/tmp}/fm-projects-model.XXXXXX") || fail "cannot stage the model"
  ( produce_model "$model" "$snapshot" ) || { rm -f -- "$model"; exit 1; }
  page=$(page_path)
  # The template digest rides in the model so an updated template republishes
  # an otherwise unchanged view.
  digest=$(template_digest) || { rm -f -- "$model"; fail "cannot fingerprint the template"; }
  new=$(jq -cS --arg t "$digest" 'del(.generated) + {template:$t}' "$model")
  old=$(published_model "$page" | jq -cS 'del(.generated)' 2>/dev/null || true)
  if [ "${FORCE_WRITE:-0}" != 1 ] && [ -n "$old" ] && [ "$old" = "$new" ]; then
    rm -f -- "$model"
    printf 'projects: %s\nunchanged\n' "$page"
    return 0
  fi
  json=$(jq -c --arg t "$digest" '. + {template:$t}' "$model") || { rm -f -- "$model"; fail "cannot compact the model"; }
  rm -f -- "$model"
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the model valid JSON while making </script> inert.
  json=${json//</\\u003c}
  (umask 077; mkdir -p "${page%/*}") || fail "cannot create ${page%/*}"
  tmp=$(umask 077; mktemp "${page%/*}/.projects.XXXXXX") || fail "cannot stage the page"
  if ! VIEW_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{VIEW_JSON}/" "$TEMPLATE" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot inject the projects model"
  fi
  extracted=$(published_model "$tmp")
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$MODEL_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "the built page does not carry a readable $MODEL_SCHEMA model"
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$page"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the page"
  fi
  printf 'projects: %s\nwritten\n' "$page"
}

command_build() {
  parse_snapshot_flag "$@"
  publish_page "$SNAPSHOT_ARG"
}

command_serve() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  # shellcheck source=bin/fm-lavish-board-lib.sh
  . "$SCRIPT_DIR/fm-lavish-board-lib.sh"
  FORCE_WRITE=1 publish_page ""
  fm_lavish_board_serve "$(page_path)" --no-intake
}

# --- automatic refresh -------------------------------------------------------

refresh_log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$STATE/projects-view.log" 2>/dev/null || true
}

command_refresh() {
  [ -f "$PROJECTS_CONFIG" ] || return 0
  [ -d "$STATE" ] || return 0
  case "$#" in
    0) ;;
    1) [ "$1" = --full ] || { usage >&2; exit 2; }
       : > "$STATE/.projects-view.full" 2>/dev/null || return 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  : > "$STATE/.projects-view.dirty" 2>/dev/null || return 0
  # Detached three ways (nohup, every stdio stream redirected, background) so
  # the caller never waits on the snapshot or holds a pipe open for it.
  nohup bash "$SCRIPT_DIR/fm-projects-view.sh" refresh-run \
    </dev/null >>"$STATE/projects-view.log" 2>&1 &
  return 0
}

refresh_pass() {  # <scope>
  ( SNAPSHOT_SCOPE=$1 publish_page "" ) >/dev/null 2>"$STATE/.projects-view.err" \
    || refresh_log "$1 refresh failed: $(tr '\n' ' ' < "$STATE/.projects-view.err" 2>/dev/null)"
  rm -f -- "$STATE/.projects-view.err"
  : > "$STATE/.projects-view.refreshed" 2>/dev/null || true
}

command_refresh_run() {
  local lock="$STATE/.projects-view.lock" stamp="$STATE/.projects-view.refreshed" pass=0 age wait
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  while [ -e "$STATE/.projects-view.dirty" ]; do
    fm_lock_try_acquire "$lock" || return 0
    while [ -e "$STATE/.projects-view.dirty" ] && [ "$pass" -lt 20 ]; do
      if [ -e "$STATE/.projects-view.full" ]; then
        rm -f -- "$STATE/.projects-view.full" "$STATE/.projects-view.dirty"
        pass=$((pass + 1))
        refresh_pass full
        continue
      fi
      age=$COOLDOWN_SECS
      [ ! -e "$stamp" ] || age=$(fm_path_age "$stamp")
      if [ "$age" -lt "$COOLDOWN_SECS" ]; then
        wait=$((COOLDOWN_SECS - age))
        [ "$wait" -le 5 ] || wait=5
        sleep "$wait"
        continue
      fi
      rm -f -- "$STATE/.projects-view.dirty"
      pass=$((pass + 1))
      refresh_pass local
    done
    fm_lock_release "$lock"
    [ "$pass" -lt 20 ] || return 0
  done
}

# --- captain actions ---------------------------------------------------------

collapse_words() {  # <words>
  printf '%s' "$1" | tr '\r\n\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//'
}

command_add() {
  local project=${1-} words title repo_args=() repos
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift
  words=$*
  require_config
  jq -e --arg id "$project" 'any(.projects[]; .id == $id)' "$PROJECTS_CONFIG" >/dev/null \
    || fail "no such project in $PROJECTS_CONFIG: $project"
  title=$(collapse_words "$words")
  [ -n "$title" ] || fail "the task words are empty"
  if [ "${#title}" -gt 80 ]; then
    title="${title:0:77}..."
  fi
  repos=$(jq -r --arg id "$project" '.projects[] | select(.id == $id) | (.repos // []) | if length == 1 then .[0] else empty end' "$PROJECTS_CONFIG")
  [ -z "$repos" ] || repo_args=(--repo "$repos")
  "$SCRIPT_DIR/fm-tasks-axi.sh" add --mint --prefix "$project" "$title" \
    ${repo_args[@]+"${repo_args[@]}"} --body "Project: $project
$words" --json \
    | jq -er '.id // .task.id' \
    || fail "cannot file the task through tasks-axi"
}

command_correct() {
  local task=${1-} words
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift
  words=$*
  case "$task" in
    ''|*[!A-Za-z0-9._-]*) fail "not a task id: $task" ;;
  esac
  [ -f "$STATE/$task.meta" ] \
    || fail "$task is not live work in this home; update its backlog note instead"
  ! grep -qx 'kind=secondmate' "$STATE/$task.meta" \
    || fail "$task is a secondmate, not a piece of work; route the correction through it"
  [ -n "$(collapse_words "$words")" ] || fail "the correction is empty"
  FM_HOME="$FM_HOME" exec "$SCRIPT_DIR/fm-send.sh" "$task" "$words"
}

case "${1-}" in
  check) shift; command_check "$@" ;;
  model) shift; command_model "$@" ;;
  build) shift; command_build "$@" ;;
  serve) shift; command_serve "$@" ;;
  refresh) shift; command_refresh "$@" ;;
  refresh-run) command_refresh_run ;;
  add) shift; command_add "$@" ;;
  correct) shift; command_correct "$@" ;;
  path) page_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
