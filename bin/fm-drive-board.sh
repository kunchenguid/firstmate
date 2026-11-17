#!/usr/bin/env bash
# fm-drive-board.sh - the generic drive board: a Lavish page that renders a
# home's goals (stage, target, owner, state per item) and lets the captain pick
# items with a target stage, then turns that one keyed answer into a goal
# record and, when asked, the away entry, through the existing guarded scripts.
#
# WHY. The captain should pick "drive these items until stage X" on a phone,
# for every project, not only where a bespoke cockpit exists. bin/fm-goal.sh
# owns the record (items carry project= and target=), bin/fm-afk-launch.sh owns
# the away entry, and bin/fm-lavish-board-lib.sh owns the Lavish session and
# the keyed-answer binding. This script is only the page generator and the one
# translator from a drive answer to those scripts; it never writes a goal
# record or an away record itself.
#
# Usage:
#   fm-drive-board.sh snapshot [--candidates <file>] [--new-goal-id <id>]
#   fm-drive-board.sh render [<payload.json>] [--candidates <file>] [--new-goal-id <id>] [--name <slug>]
#   fm-drive-board.sh build  [<payload.json>] [--candidates <file>] [--new-goal-id <id>] [--name <slug>]
#   fm-drive-board.sh apply (--answer <text> | --result <lavish-result-file>) [--name <slug>] [--dry-run]
#   fm-drive-board.sh path [--name <slug>]
#
# snapshot   Print the fm-drive-board.v1 payload (INPUT CONTRACT below) composed
#            from this home's live state: `fm-goal.sh export`, the away record,
#            and the stage ladders (config/stage-ladders/<project>).
# render     Validate a payload (given, or a fresh snapshot) and write the page
#            and its payload copy under data/drive-board/. Prints `board: <path>`.
# build      render, then establish and prove the Lavish session, bind the
#            keyed-answer source, and arm it (fm_lavish_board_serve), so the
#            page opens in the captain's browser. Rebuild after every apply so
#            the page shows the new goal state; the page path is stable, which
#            keeps the same Lavish session and source id.
# apply      Act on one drive answer (KEYED ANSWER below). Main actor only:
#            fm-goal.sh refuses start and edit anywhere else.
# path       Print the stable page path for the name (default `drive-board`).
#
# PAGE ARTIFACTS live only under persistent data/drive-board/ (<name>.html and
# <name>.payload.json), never under a temp or .lavish directory, so a reboot
# does not lose the page or the payload apply reads.
#
# INPUT CONTRACT (fm-drive-board.v1; the one place it is stated; a renderer
# other than this one, for example the Miko cockpit panel, consumes the same
# payload and sends the same keyed answer). One JSON object:
#   schema        "fm-drive-board.v1"
#   home          non-empty string, shown in the header
#   generated     non-empty string (UTC ISO 8601), shown in the header
#   now_epoch     integer seconds; ages on the page are computed from it
#   away          {state: "away"|"quiet"|"attended", entered, expected_return,
#                  spend_cap, drive_goals: [id...]}; entered, expected_return
#                  and spend_cap are null when absent
#   goals         the `goals` array of fm-goal.sh export (schema
#                 fm-goal-export.v1), unchanged: each goal has id, title,
#                 state, done_when, progress {total, closed, at_target,
#                 with_target}, last_progress_epoch, and items, each with id,
#                 owner, class, title, state, project, target, stage,
#                 startable, target_reached, waiting_on
#   candidates    [{id, title, owner, project, task}] items not yet in any
#                 goal that the captain may add. id and owner are path-safe
#                 ([A-Za-z0-9._-], no leading dot); title is one line; project
#                 and task are a path-safe string or null. A candidate whose id
#                 is already an item of an active goal is dropped at snapshot.
#                 Where candidates come from is the caller's choice (a backlog
#                 query, a plan); `--candidates <file>` takes this array.
#   ladders       {<project>: [stage...]} the rungs of each referenced
#                 project's ladder, lowest first; a project with no ladder file
#                 is absent and its items can be picked with no target
#   new_goal      {id, title, done_when} the defaults used when the answer names
#                 a goal id that has no active record, or null
# Validation is fail-closed: a payload that breaks any rule above refuses
# before the existing page is touched.
#
# KEYED ANSWER. The page queues one Lavish choice with queueKey and question
# `drive.go` and a one-line answer:
#   goal=<id> pick=<item>@<stage>[,<item>@<stage>...] away=<yes|no>
# <item> is an item id of that goal (edit) or a candidate id (add), <stage> a
# rung of that item's project ladder or `-` for no target, and the answer stays
# under 512 bytes. The keyed-answer intake in bin/fm-captain-hold.sh skips the
# key (it is no captain-held task), so the answer is announced as a board wake
# and the main agent runs `apply`, the way it routes `dispatch.charted`. apply:
#   - refuses a malformed answer, an unknown item, a captain-class or finished
#     item, a target on an item with no project, and a stage off the ladder;
#   - for a goal with an active record, rewrites that goal's items through
#     `fm-goal.sh edit` (every existing item kept, picked targets set, picked
#     candidates added), which preserves every mark; for any other id, which
#     must be the payload's new_goal id, runs `fm-goal.sh start` with the
#     picks as its items and the answer as the captain's words (--named-by);
#   - with away=yes runs `fm-afk-launch.sh enter --drive-goal <id>`: with the
#     standing away record it is a refresh that names the goal, otherwise it
#     writes the away record with the drive-board words. The entry's daemon or
#     host step stays the afk skill's, so apply prints a `next:` line saying so.
# --dry-run prints the items it would write and the commands it would run and
# changes nothing.
#
# FM_DRIVE_BOARD_TEMPLATE overrides the shipped template path (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

TEMPLATE="${FM_DRIVE_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/drive-goal/assets/drive-board-template.html}"
PLACEHOLDER='__FM_DRIVE_BOARD_DATA__'
BOARD_SCHEMA=fm-drive-board.v1
DEFAULT_NAME=drive-board
GOAL="$SCRIPT_DIR/fm-goal.sh"
CONTRACT="$SCRIPT_DIR/fm-afk-contract.sh"
LAUNCH="$SCRIPT_DIR/fm-afk-launch.sh"
ADAPTER="$SCRIPT_DIR/fm-procevent-lavish.sh"

# shellcheck source=bin/fm-lavish-board-lib.sh
. "$SCRIPT_DIR/fm-lavish-board-lib.sh"
# shellcheck source=bin/fm-stage-ladder-lib.sh
. "$SCRIPT_DIR/fm-stage-ladder-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-drive-board: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  printf 'fm-drive-board: %s\n' "$*" >&2
  exit 2
}

safe_word() {  # <value> - path-safe like a goal id: no leading dot, [A-Za-z0-9._-] only
  case "${1-}" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

board_dir() { printf '%s/drive-board\n' "$DATA_DIR"; }

name_valid() { safe_word "$1" && [ "${#1}" -le 64 ]; }

board_path() { printf '%s/%s.html\n' "$(board_dir)" "$1"; }
payload_path() { printf '%s/%s.payload.json\n' "$(board_dir)" "$1"; }

# --- the payload -----------------------------------------------------------

validate_payload() {  # <payload.json>
  jq -e --arg schema "$BOARD_SCHEMA" '
    def nonempty: type == "string" and length > 0;
    def oneline: nonempty and (test("[\n\r]") | not);
    def safe: type == "string" and test("^[A-Za-z0-9._-]+$") and (startswith(".") | not);
    def safe_or_null: . == null or safe;
    def num_or_null: . == null or type == "number";
    def strs: type == "array" and ([.[] | type == "string"] | all);
    def item:
      type == "object" and (.id | safe) and (.owner | safe) and (.title | oneline)
      and (.class == "drive" or .class == "captain")
      and (.state | nonempty)
      and (.project | safe_or_null) and (.target | safe_or_null) and (.stage | safe_or_null)
      and (.task | safe_or_null)
      and (.after | strs) and (.waiting_on | strs) and (.stop_on | strs)
      and (.until | num_or_null) and (.stage_at | num_or_null) and (.since | num_or_null)
      and (.startable | type == "boolean") and (.target_reached | type == "boolean");
    def goal:
      type == "object" and (.id | safe) and (.title | oneline) and (.state | nonempty)
      and (.done_when | oneline)
      and (.last_progress_epoch | num_or_null)
      and (.progress | type == "object"
        and ([.total, .closed, .at_target, .with_target] | map(type == "number") | all))
      and (.items | type == "array") and ([.items[] | item] | all);
    def candidate:
      type == "object" and (.id | safe) and (.owner | safe) and (.title | oneline)
      and (.project | safe_or_null) and (.task | safe_or_null);
    def away_ok:
      type == "object"
      and (.state == "away" or .state == "quiet" or .state == "attended")
      and (.entered == null or (.entered | nonempty))
      and (.expected_return == null or (.expected_return | nonempty))
      and (.spend_cap | num_or_null)
      and (.drive_goals | strs);
    def ladders_ok:
      type == "object" and ([to_entries[] | (.key | safe) and (.value | type == "array")
        and ([.value[] | safe] | all)] | all);
    def new_goal_ok:
      . == null or (type == "object" and (.id | safe) and (.title | oneline) and (.done_when | oneline));
    type == "object" and .schema == $schema
    and (.home | nonempty) and (.generated | nonempty) and (.now_epoch | type == "number")
    and (.away | away_ok)
    and (.goals | type == "array") and ([.goals[] | goal] | all)
    and (.candidates | type == "array") and ([.candidates[] | candidate] | all)
    and (.ladders | ladders_ok)
    and (.new_goal | new_goal_ok)
  ' "$1" >/dev/null 2>&1
}

away_json() {
  local mode entered ret spend goals
  mode=$("$CONTRACT" mode 2>/dev/null) || mode=''
  case "$mode" in away|quiet) ;; *) mode=attended ;; esac
  entered='' ret='' spend='' goals=''
  if [ "$mode" != attended ]; then
    entered=$("$CONTRACT" field entered 2>/dev/null) || entered=''
    ret=$("$CONTRACT" field expected_return 2>/dev/null) || ret=''
    spend=$("$CONTRACT" field spend_max_concurrent_workers 2>/dev/null) || spend=''
    goals=$("$CONTRACT" field drive_goals 2>/dev/null) || goals=''
  fi
  case "$ret" in '-') ret='' ;; esac
  case "$spend" in ''|*[!0-9]*) spend='' ;; esac
  jq -cn --arg state "$mode" --arg entered "$entered" --arg ret "$ret" --arg spend "$spend" --arg goals "$goals" '
    {state: $state,
     entered: (if $entered == "" then null else $entered end),
     expected_return: (if $ret == "" then null else $ret end),
     spend_cap: (if $spend == "" then null else ($spend | tonumber) end),
     drive_goals: ($goals | split(" ") | map(select(length > 0)))}'
}

# The ladder rungs of every project the goals and candidates name, as one
# object. A project with no ladder file, or an unreadable one, is left out.
ladders_json() {  # <goals-json> <candidates-json>
  local projects project out='{}' rc
  projects=$(jq -rn --argjson goals "$1" --argjson cands "$2" '
    ([$goals[].items[].project] + [$cands[].project]) | map(select(. != null)) | unique | .[]')
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    rc=0
    fm_stage_ladder_load "$CONFIG_DIR" "$project" || rc=$?
    [ "$rc" -eq 0 ] || continue
    out=$(jq -cn --argjson out "$out" --arg project "$project" '$out + {($project): $ARGS.positional}' \
      --args "${FM_STAGE_LADDER_NAMES[@]}")
  done <<< "$projects"
  printf '%s\n' "$out"
}

command_snapshot() {
  local candidates_file='' new_id='' exported goals cands ladders now home_name new_goal
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --candidates) [ "$#" -ge 2 ] || usage_error '--candidates needs a file'; candidates_file=$2; shift 2 ;;
      --new-goal-id) [ "$#" -ge 2 ] || usage_error '--new-goal-id needs an id'; new_id=$2; shift 2 ;;
      *) usage_error "unknown flag for snapshot: $1" ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  if [ -z "$new_id" ]; then new_id="drive-$(date -u +%Y%m%d)"; fi
  safe_word "$new_id" || usage_error "unsafe goal id: '$new_id'"
  exported=$("$GOAL" export) || fail "cannot read the goals (fm-goal.sh export failed)"
  goals=$(jq -c '.goals' <<< "$exported")
  if [ -n "$candidates_file" ]; then
    [ -f "$candidates_file" ] || fail "candidates file does not exist: $candidates_file"
    jq -e 'type == "array"' "$candidates_file" >/dev/null 2>&1 || fail "candidates file is not a JSON array: $candidates_file"
    # fill the optional fields and drop any candidate that already is an item of an active goal
    cands=$(jq -c --argjson goals "$goals" '
      ([$goals[].items[].id]) as $taken
      | [.[] | {id, title, owner, project: (.project // null), task: (.task // null)}
         | select(.id as $id | $taken | index($id) | not)]' "$candidates_file") \
      || fail "candidates file does not hold {id, title, owner} rows: $candidates_file"
  else
    cands='[]'
  fi
  ladders=$(ladders_json "$goals" "$cands")
  now=$(date +%s)
  home_name=$(basename "$FM_HOME")
  # the new-goal default exists only while its id is free
  new_goal=$(jq -cn --argjson goals "$goals" --arg id "$new_id" '
    if ($goals | map(.id) | index($id)) != null then null
    else {id: $id, title: "Drive board goal", done_when: "Every picked item has reached its target stage"} end')
  jq -cn --arg schema "$BOARD_SCHEMA" --arg home "$home_name" --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson now "$now" --argjson away "$(away_json)" --argjson goals "$goals" --argjson cands "$cands" \
    --argjson ladders "$ladders" --argjson new_goal "$new_goal" '
    {schema: $schema, home: $home, generated: $generated, now_epoch: $now, away: $away,
     goals: $goals, candidates: $cands, ladders: $ladders, new_goal: $new_goal}'
}

# --- render and serve ------------------------------------------------------

# Compose or take a payload, validate it, and publish the page and its payload
# copy. Sets RENDERED_BOARD.
render_page() {  # <name> <payload-or-empty> [snapshot flags...]
  local name=$1 given=$2 json tmp payload staged extracted board dir pcopy
  shift 2
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "board template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "board template does not carry exactly one data slot: $TEMPLATE"
  dir=$(board_dir)
  (umask 077; mkdir -p "$dir") || fail "cannot create $dir"
  [ -d "$dir" ] && [ ! -L "$dir" ] || fail "the board directory is unsafe: $dir"
  staged=$(umask 077; mktemp "$dir/.payload.XXXXXX") || fail "cannot stage the payload"
  if [ -n "$given" ]; then
    [ -f "$given" ] || { rm -f -- "$staged"; fail "board data does not exist: $given"; }
    jq empty "$given" 2>/dev/null || { rm -f -- "$staged"; fail "board data is not valid JSON: $given"; }
    jq -c . "$given" > "$staged" || { rm -f -- "$staged"; fail "cannot read the board data"; }
  else
    command_snapshot "$@" > "$staged" || { rm -f -- "$staged"; fail "cannot compose the board data"; }
  fi
  validate_payload "$staged" || { rm -f -- "$staged"; fail "board data does not satisfy $BOARD_SCHEMA"; }
  payload=$(jq -c . "$staged")
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${payload//</\\u003c}
  board=$(board_path "$name")
  tmp=$(umask 077; mktemp "$dir/.board.XXXXXX") || { rm -f -- "$staged"; fail "cannot stage the board"; }
  if ! BOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{BOARD_JSON}/" "$TEMPLATE" > "$tmp"; then
    rm -f -- "$staged" "$tmp"
    fail "cannot inject the board data"
  fi
  if grep -qxF "$PLACEHOLDER" "$tmp"; then
    rm -f -- "$staged" "$tmp"
    fail "the board data slot survived injection"
  fi
  extracted=$(sed -n '/<script id="drive-data" type="application\/json">/,/<\/script>/p' "$tmp" | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$staged" "$tmp"
    fail "the built board does not carry a readable $BOARD_SCHEMA payload"
  fi
  pcopy=$(payload_path "$name")
  if ! { chmod 0600 "$tmp" "$staged" && mv -f -- "$staged" "$pcopy" && mv -f -- "$tmp" "$board"; }; then
    rm -f -- "$staged" "$tmp"
    fail "cannot publish the board"
  fi
  RENDERED_BOARD=$board
  printf 'board: %s\n' "$board"
}

parse_render_flags() {  # sets NAME, GIVEN, SNAP_ARGS from the arguments
  NAME=$DEFAULT_NAME GIVEN='' SNAP_ARGS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) [ "$#" -ge 2 ] || usage_error '--name needs a slug'; NAME=$2; shift 2 ;;
      --candidates|--new-goal-id)
        [ "$#" -ge 2 ] || usage_error "$1 needs a value"
        SNAP_ARGS+=("$1" "$2"); shift 2 ;;
      -*) usage_error "unknown flag: $1" ;;
      *) [ -z "$GIVEN" ] || usage_error 'only one payload file'; GIVEN=$1; shift ;;
    esac
  done
  name_valid "$NAME" || usage_error "unsafe board name: '$NAME'"
  [ -z "$GIVEN" ] || [ "${#SNAP_ARGS[@]}" -eq 0 ] || usage_error 'a given payload takes no snapshot flags'
}

command_render() {
  parse_render_flags "$@"
  render_page "$NAME" "$GIVEN" ${SNAP_ARGS[@]+"${SNAP_ARGS[@]}"}
}

command_build() {
  parse_render_flags "$@"
  render_page "$NAME" "$GIVEN" ${SNAP_ARGS[@]+"${SNAP_ARGS[@]}"}
  fm_lavish_board_serve "$RENDERED_BOARD"
}

command_path() {
  local name=$DEFAULT_NAME
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) [ "$#" -ge 2 ] || usage_error '--name needs a slug'; name=$2; shift 2 ;;
      *) usage_error "unknown flag for path: $1" ;;
    esac
  done
  name_valid "$name" || usage_error "unsafe board name: '$name'"
  board_path "$name"
}

# --- apply -----------------------------------------------------------------

# Plan the goal's items from the answer: prints one JSON object
# {items, picked, added, error}. A refusal is an `error` string, never a
# partial plan.
plan_items() {  # <current-items-json> <payload.json> <picks-csv>
  jq -cn --argjson cur "$1" --slurpfile payload "$2" --arg picks "$3" '
    $payload[0] as $pl
    | ($picks | split(",") | map(capture("^(?<id>[A-Za-z0-9._-]+)@(?<stage>[A-Za-z0-9._-]+)$"))) as $p
    | if ($p | length) == 0 then {error: "the answer picks nothing"}
      elif ($p | map(.id) | length) != ($p | map(.id) | unique | length) then {error: "the answer picks an item twice"}
      else
        reduce $p[] as $pick ({items: $cur, picked: [], added: [], error: null};
          if .error != null then .
          else
            (.items | map(.id) | index($pick.id)) as $ix
            | (if $ix != null then .items[$ix] else ($pl.candidates | map(select(.id == $pick.id)) | .[0]) end) as $it
            | ($pick.stage) as $stage
            | (if $it == null then null else ($pl.ladders[$it.project // ""] // []) end) as $ladder
            | if $it == null then .error = "unknown item: " + $pick.id
              elif ($it.class // "drive") == "captain" then .error = "item " + $pick.id + " is a captain item and is never driven"
              elif ($it.state // "open") == "done" or ($it.state // "open") == "dropped" then .error = "item " + $pick.id + " is already " + $it.state
              elif $stage != "-" and ($it.project // null) == null then .error = "item " + $pick.id + " has no project, so it cannot carry a target"
              elif $stage != "-" and ($ladder | length) > 0 and ($ladder | index($stage)) == null then .error = "stage " + $stage + " is not on the " + $it.project + " ladder"
              else
                (if $ix != null
                  then .items[$ix] |= (if $stage != "-" then .target = $stage else . end)
                  else .items += [{id: $it.id, owner: $it.owner, class: "drive", title: $it.title,
                         task: ($it.task // null), project: ($it.project // null), after: [], stop_on: [], until: null,
                         target: (if $stage != "-" then $stage else null end)}]
                       | .added += [$pick.id]
                  end)
                | .picked += [$pick.id + "@" + $stage]
              end
          end)
      end'
}

# The items-file text (bin/fm-goal.sh's item grammar) for a planned item list.
items_file_text() {  # <items-json>
  jq -r '.[] | "item [id=\(.id)] [owner=\(.owner)]"
    + (if (.after // []) | length > 0 then " [after=\(.after | join(","))]" else "" end)
    + (if (.class // "drive") != "drive" then " [class=\(.class)]" else "" end)
    + (if .task != null and .task != "" then " [task=\(.task)]" else "" end)
    + (if .project != null and .project != "" then " [project=\(.project)]" else "" end)
    + (if .target != null and .target != "" then " [target=\(.target)]" else "" end)
    + (if .until != null then " [until=\(.until)]" else "" end)
    + (if (.stop_on // []) | length > 0 then " [stop-on=\(.stop_on | join(","))]" else "" end)
    + ": " + .title' <<< "$1"
}

apply_one() {  # <answer> <name> <dry-run 0|1>
  local answer=$1 name=$2 dry=$3 re goal picks away pcopy payload exported current plan err
  local items_text items_file mode words rc=0 verb new_title new_done item
  re='^goal=([A-Za-z0-9._-]+) pick=([A-Za-z0-9._@,-]+) away=(yes|no)$'
  [[ $answer =~ $re ]] || fail "malformed drive.go answer (want: goal=<id> pick=<item>@<stage>,... away=<yes|no>)"
  goal=${BASH_REMATCH[1]} picks=${BASH_REMATCH[2]} away=${BASH_REMATCH[3]}
  safe_word "$goal" || fail "unsafe goal id in the answer: '$goal'"
  pcopy=$(payload_path "$name")
  [ -f "$pcopy" ] && [ ! -L "$pcopy" ] || fail "no payload copy for board '$name' at $pcopy: render the board first"
  validate_payload "$pcopy" || fail "the payload copy does not satisfy $BOARD_SCHEMA: $pcopy"
  payload=$pcopy

  if exported=$("$GOAL" export "$goal" 2>/dev/null); then
    verb=edit
    current=$(jq -c '.goals[0].items' <<< "$exported")
  else
    verb=start
    jq -e --arg id "$goal" '.new_goal != null and .new_goal.id == $id' "$payload" >/dev/null \
      || fail "goal '$goal' has no active record and is not the board's new goal"
    current='[]'
  fi

  plan=$(plan_items "$current" "$payload" "$picks") || fail "cannot plan the items"
  err=$(jq -r '.error // empty' <<< "$plan")
  [ -z "$err" ] || fail "refused: $err"
  items_text=$(items_file_text "$(jq -c '.items' <<< "$plan")")

  mode=$("$CONTRACT" mode 2>/dev/null) || mode=''
  words="Drive board order: drive goal $goal to its target stages ($picks)."

  if [ "$dry" = 1 ]; then
    printf 'dry-run: would %s goal %s with items:\n' "$verb" "$goal"
    printf '%s\n' "$items_text" | sed 's/^/  /'
    if [ "$away" = yes ]; then
      if [ "$mode" = away ]; then printf 'dry-run: would refresh /afk naming goal %s\n' "$goal"
      else printf 'dry-run: would enter /afk with the drive-board words, naming goal %s\n' "$goal"; fi
    fi
    return 0
  fi

  items_file=$(umask 077; mktemp "$(board_dir)/.apply-items.XXXXXX") || fail "cannot stage the items file"
  printf '%s\n' "$items_text" > "$items_file"
  if [ "$verb" = start ]; then
    new_title=$(jq -r '.new_goal.title' "$payload")
    new_done=$(jq -r '.new_goal.done_when' "$payload")
    "$GOAL" start "$goal" --title "$new_title" --done-when "$new_done" \
      --named-by "Drive board press: $answer" --plan "$pcopy" --items-file "$items_file" || rc=$?
  else
    "$GOAL" edit "$goal" --items-file "$items_file" || rc=$?
  fi
  rm -f -- "$items_file"
  [ "$rc" -eq 0 ] || fail "fm-goal.sh $verb refused (exit $rc); the goal is unchanged"
  printf 'goal: %s %s\n' "$([ "$verb" = start ] && printf started || printf edited)" "$goal"
  for item in $(jq -r '.picked[]' <<< "$plan"); do printf 'picked: %s\n' "$item"; done

  if [ "$away" = yes ]; then
    if [ "$mode" = away ]; then
      "$LAUNCH" enter --drive-goal "$goal" || fail "fm-afk-launch.sh enter refused; the goal is recorded but /afk was not entered"
      printf 'away: refreshed, now naming %s\n' "$goal"
    else
      "$LAUNCH" enter --words "$words" --drive-goal "$goal" || fail "fm-afk-launch.sh enter refused; the goal is recorded but /afk was not entered"
      printf 'away: entered, drive goal %s\n' "$goal"
      printf 'next: finish the /afk entry as the afk skill says for this harness (daemon or host start), then rebuild the board\n'
    fi
  else
    printf 'away: not requested\n'
    printf 'next: rebuild the board so it shows the goal\n'
  fi
}

command_apply() {
  local answer='' result='' name=$DEFAULT_NAME dry=0 rows row n=0 rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --answer) [ "$#" -ge 2 ] || usage_error '--answer needs the answer text'; answer=$2; shift 2 ;;
      --result) [ "$#" -ge 2 ] || usage_error '--result needs a file'; result=$2; shift 2 ;;
      --name) [ "$#" -ge 2 ] || usage_error '--name needs a slug'; name=$2; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) usage_error "unknown flag for apply: $1" ;;
    esac
  done
  { [ -n "$answer" ] || [ -n "$result" ]; } || usage_error 'apply needs --answer or --result'
  { [ -z "$answer" ] || [ -z "$result" ]; } || usage_error 'apply takes --answer or --result, not both'
  name_valid "$name" || usage_error "unsafe board name: '$name'"
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  if [ -n "$answer" ]; then
    apply_one "$answer" "$name" "$dry"
    return
  fi
  [ -f "$result" ] || fail "result file does not exist: $result"
  rows=$("$ADAPTER" answers "$result") || fail "the captured result is incomplete or unreadable: $result"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    case "${row%%$'\t'*}" in drive.go) ;; *) continue ;; esac
    answer=${row#*$'\t'}
    answer=${answer%%$'\t'*}
    n=$((n + 1))
    ( apply_one "$answer" "$name" "$dry" ) || rc=1
  done <<< "$rows"
  [ "$n" -gt 0 ] || fail "the result carries no drive.go answer"
  return "$rc"
}

case "${1-}" in
  snapshot) shift; command_snapshot "$@" ;;
  render) shift; command_render "$@" ;;
  build) shift; command_build "$@" ;;
  apply) shift; command_apply "$@" ;;
  path) shift; command_path "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
