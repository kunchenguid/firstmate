#!/usr/bin/env bash
# fm-board.sh - the one thin adapter between a configured project board and
# firstmate's existing backlog.
#
# The semantic policy is owned once by
# .agents/skills/board-orchestration/SKILL.md. This script is deterministic
# mechanics only: it reads a board, owns the durable issue-to-task linkage that
# makes import idempotent, and reflects firstmate's own execution events back
# onto the board. It never creates work, never decides what to import, and never
# pushes firstmate's recorded state over a status the captain changed on the
# board. The board owns intent; this script reconciles toward it.
#
# Usage:
#   fm-board.sh boards [<project>]
#   fm-board.sh poll [<project>] [--limit <n>]
#   fm-board.sh import <project> <issue-url> <task-id>
#   fm-board.sh links [<project>]
#   fm-board.sh lookup <issue-url|task-id>
#   fm-board.sh mark <task-id> todo|in-progress|done [--limit <n>]
#   fm-board.sh pr <task-id> <pr-url>
#   fm-board.sh note <task-id> <text>
#   fm-board.sh ack <task-id>
#   fm-board.sh -h | --help
#
# `--limit` caps how many cards one board read returns and defaults to 200, on
# `poll` and on the card lookup `mark` needs. A board carrying more cards than
# the limit needs it raised: `poll` says so with a `truncated` line, and `mark`
# cannot find a card sitting past the limit at all.
#
# CONFIGURATION - config/boards, local and gitignored (docs/configuration.md
# owns the operator-facing description). Plain text, one stanza per board, each
# opened by its `project` key:
#
#   project = harbourlight
#   owner = harbour-collective
#   number = 7
#   repo = harbour-collective/app  # optional; default: every repo on the board
#   label = firstmate            # default: firstmate
#   mention = @firstmate         # optional; default: mention trigger off
#   assignee = some-login        # optional; default: assignee trigger off
#   status-field = Status        # default: Status
#   todo = Todo                  # default: Todo
#   in-progress = In Progress    # default: In Progress
#   done = Done                  # default: Done
#
# INERT UNTIL CONFIGURED. This is a contract, not a side effect. With no
# `config/boards` file, or an empty one, this adapter performs zero board reads
# and zero board writes, invokes no GitHub CLI at all, creates no state, and
# behaves exactly as the home did before it existed - the same shape as Relay's
# opt-in. Every board identity comes from that one local file, so nothing here
# is org-specific or repo-specific.
#
# OFF SWITCH. Deleting or emptying `config/boards` fully disables the bridge and
# leaves no residue: there is no generated poll, watcher check, cadence file,
# daemon, or background process to unwind, because none was ever created. The
# only file this adapter ever writes is data/board-links.tsv, and an unconfigured
# home never reads it into any behavior.
#
# WHAT DISABLING DOES NOT UNDO, by design. Work already done stays done: issues
# and backlog items already imported remain, comments already posted on an issue
# remain posted, and cards already moved stay where they were moved. Disabling
# stops future board reads and writes; it is not an undo.
#
# STRICTLY PER PROJECT. Only a project with its own stanza in `config/boards` is
# ever mapped to a board. Work on any other project has no board coordinates to
# resolve, so `import` refuses to name it and no card, issue, or comment for it
# is ever touched. A home with several boards keeps them separate: an event on
# one project resolves only that project's stanza.
#
# INTAKE. `poll` reports an item as importable only when it is a real issue (not
# a draft card and not a pull request), sits in the configured Todo column, and
# carries the configured trigger. The label is the authoritative trigger; the
# optional mention and assignee triggers are additional and off unless set.
# These are intake filters alone: a card they decline is still a card on the
# board, recorded as present before any of them runs, so declining to import it
# is never mistaken for it having left.
#
# IDEMPOTENCY. data/board-links.tsv is the durable linkage record and the single
# thing consulted before an import. It lives in data/, not state/, so it
# survives task cleanup: an issue whose task was long since torn down is still
# linked and is never imported a second time. The issue URL is the identity, so
# one issue can hold at most one task, and `import` for an issue that already
# links to the same task is a successful no-op. A conflicting relink is refused
# rather than overwritten.
#
# Record columns, tab separated:
#   project  issue  task  desired  synced  pr  pr_synced
# `desired` is the column state firstmate's execution events call for and
# `synced` is the last state this adapter confirmed on the board, both drawn
# from todo|in-progress|done|other. They differ exactly while a board write is
# outstanding, which is what makes a failed write retryable on the next cycle.
# `other` is a column the captain added that firstmate does not drive; it is
# recorded so their intent is preserved, not so a fourth execution state exists.
# No column is ever empty: `-` is the placeholder, because bash collapses empty
# tab-separated fields when it reads them back.
#
# FAIL SOFT. Every board write degrades to a stale board instead of blocking
# delivery: `mark`, `pr`, and `note` exit 0 whether or not the write landed,
# reporting the failure on stderr and leaving `mark` and `pr` retryable. `poll`
# retries both outstanding writes - the card move and the PR attachment - and
# reports each with the same `synced` or `stale` line, and it also exits 0 on a
# board read failure, reporting it as an `error` line. A read that cannot tell
# absence from its own limits - a full page, or a board answering with no cards
# at all while links are open - says so and reconciles nothing rather than
# guessing. Only a usage or
# configuration error exits non-zero, and a refused conflicting relink exits 3.
#
# WHO WINS. When the board disagrees with a record, the board is a captain
# instruction: `poll` adopts the board's state into the record and reports an
# `instruction` line for firstmate to reconcile the backlog to. It never writes
# firstmate's state back over the captain's edit. The one exception is an
# outstanding write the board has not taken yet, which is retried because the
# board still shows the value this adapter last confirmed.
#
# An issue that a different configured board already owns is a misconfiguration
# rather than an instruction, so `poll` names it in a `foreign` line carrying the
# owning project and touches neither the card nor the record. Ownership is never
# silently re-homed, because every later event would then resolve the wrong
# board. `import` stays fleet-wide: an issue linked under any project can never
# be imported a second time under another one.
#
# A card that left the board is the captain withdrawing work firstmate is still
# executing, so `poll` keeps reporting it as `cancelled` until `ack` records that
# the withdrawal was reconciled. Repeating survives a missed cycle; a card that
# left after reaching Done is ordinary archiving and is never reported. Neither
# reporting nor acknowledging a withdrawal ever authorizes discarding unlanded
# work: hard rule 3 stands, and this adapter touches no branch, worktree, or
# repository.
#
# GITHUB CLI. This adapter calls `gh` rather than `gh-axi`, and adds no new
# dependency because `gh` is already part of firstmate's universal toolchain
# (docs/configuration.md, "Toolchain"). gh-axi can perform every read and write
# needed here, but it renders project reads as truncated agent-readable output
# with no machine-stable shape, while the status write needs the exact project,
# field, and option node IDs that only the JSON surface returns - the same
# `gh ... --format json` surface gh-axi itself calls. `gh` also carries an
# embedded jq, so shaping that JSON needs no external jq either. Firstmate's own
# conversational GitHub work stays on gh-axi. Board commands need gh's `project`
# OAuth scope (`gh auth refresh -s project`).
#
# Overrides for tests and specialized setups: FM_HOME, FM_CONFIG_OVERRIDE,
# FM_DATA_OVERRIDE, and FM_BOARD_GH (the GitHub CLI to invoke).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BOARDS_FILE="$CONFIG/boards"
LINKS="$DATA/board-links.tsv"
GH="${FM_BOARD_GH:-gh}"
TAB=$'\t'
# One board read's ceiling, shared by `poll` and the card lookup `mark` needs.
DEFAULT_LIMIT=200
MARK_USAGE='usage: fm-board.sh mark <task-id> todo|in-progress|done [--limit <n>]'

limit_valid() {
  case "${1:-}" in
    '' | *[!0-9]* | 0) return 1 ;;
  esac
  return 0
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-2}"
}

warn() {
  printf 'board: %s\n' "$1" >&2
}

print_help() {
  sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "$0"
}

# --- configuration ----------------------------------------------------------
#
# boards_emit prints one tab-separated stanza per configured board:
#   project owner number repo label mention assignee status_field todo in_progress done
# Optional values that are unset print as `-`. Malformed configuration is an
# actionable error rather than something to guess around.

CONFIG_VALUE_RE='^[A-Za-z0-9 ._-]+$'
CONFIG_SLUG_RE='^[A-Za-z0-9._-]+$'

# Emits the stanza being accumulated by boards_emit. Called only from there, and
# deliberately reads that caller's locals rather than taking eleven arguments.
boards_flush() {
  [ -n "$project" ] || return 0
  [ "$owner" != - ] || die "config/boards: board \"$project\" has no owner"
  [ "$number" != - ] || die "config/boards: board \"$project\" has no number"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$project" "$owner" "$number" "$repo" "$label" "$mention" "$assignee" \
    "$status_field" "$todo" "$in_progress" "$done_col"
}

boards_emit() {
  local line key value project owner number repo label mention assignee
  local status_field todo in_progress done_col lineno=0 seen=
  [ -f "$BOARDS_FILE" ] || return 0

  project=''
  owner=- number=- repo=- label=firstmate mention=- assignee=-
  status_field=Status todo=Todo in_progress='In Progress' done_col=Done
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    case "$line" in
      '' | '#'*) continue ;;
      *=*) ;;
      *) die "config/boards line $lineno: expected \"key = value\"" ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    # Trim surrounding whitespace from both halves.
    key=${key#"${key%%[![:space:]]*}"}
    key=${key%"${key##*[![:space:]]}"}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    [ -n "$value" ] || die "config/boards line $lineno: \"$key\" has no value"
    case "$value" in
      *"$TAB"*) die "config/boards line $lineno: \"$key\" must not contain a tab" ;;
    esac

    if [ "$key" = project ]; then
      boards_flush
      case "$value" in
        *' '*) die "config/boards line $lineno: project name must not contain a space" ;;
      esac
      case " $seen " in
        *" $value "*) die "config/boards: project \"$value\" is configured twice" ;;
      esac
      seen="$seen $value"
      project=$value
      owner=- number=- repo=- label=firstmate mention=- assignee=-
      status_field=Status todo=Todo in_progress='In Progress' done_col=Done
      continue
    fi
    [ -n "$project" ] || die "config/boards line $lineno: \"$key\" appears before any project"

    case "$key" in
      owner)
        [[ $value =~ $CONFIG_SLUG_RE ]] || die "config/boards line $lineno: owner \"$value\" is not a login"
        owner=$value
        ;;
      number)
        case "$value" in
          *[!0-9]*) die "config/boards line $lineno: number \"$value\" is not a project number" ;;
        esac
        number=$value
        ;;
      repo)
        case "$value" in
          */*/* | */ | /* | *' '*) die "config/boards line $lineno: repo \"$value\" is not owner/name" ;;
          */*) repo=$value ;;
          *) die "config/boards line $lineno: repo \"$value\" is not owner/name" ;;
        esac
        ;;
      label | todo | in-progress | done | status-field)
        [[ $value =~ $CONFIG_VALUE_RE ]] \
          || die "config/boards line $lineno: \"$key\" may use only letters, digits, spaces, dot, underscore, and dash"
        case "$key" in
          label) label=$value ;;
          todo) todo=$value ;;
          in-progress) in_progress=$value ;;
          done) done_col=$value ;;
          status-field) status_field=$value ;;
        esac
        ;;
      mention)
        case "$value" in
          @*) [[ ${value#@} =~ $CONFIG_SLUG_RE ]] || die "config/boards line $lineno: mention \"$value\" is not @login" ;;
          *) die "config/boards line $lineno: mention \"$value\" must start with @" ;;
        esac
        mention=$value
        ;;
      assignee)
        [[ $value =~ $CONFIG_SLUG_RE ]] || die "config/boards line $lineno: assignee \"$value\" is not a login"
        assignee=$value
        ;;
      *) die "config/boards line $lineno: unknown key \"$key\"" ;;
    esac
  done < "$BOARDS_FILE"
  boards_flush
}

# boards_load caches the validated stanzas once. boards_emit refuses malformed
# configuration by exiting, but it runs in a substitution subshell, so its status
# has to be turned back into a real exit here.
BOARDS_CACHE=
BOARDS_LOADED=0
boards_load() {
  local rc=0
  if [ "$BOARDS_LOADED" = 1 ]; then
    return 0
  fi
  BOARDS_CACHE=$(boards_emit) || rc=$?
  if [ "$rc" != 0 ]; then
    exit "$rc"
  fi
  BOARDS_LOADED=1
}

boards_rows() {
  [ -n "$BOARDS_CACHE" ] || return 0
  printf '%s\n' "$BOARDS_CACHE"
}

# board_for <project>: print that one board stanza, or fail with a usable error.
board_for() {
  local want=$1 row found=
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    case "$row" in
      "$want$TAB"*)
        found=$row
        break
        ;;
    esac
  done < <(boards_rows)
  [ -n "$found" ] || die "no board configured for project \"$want\" in config/boards"
  printf '%s\n' "$found"
}

# --- durable linkage record -------------------------------------------------

LINKS_HEADER="# fm-board.sh durable issue-to-task links: project${TAB}issue${TAB}task${TAB}desired${TAB}synced${TAB}pr${TAB}pr_synced"

links_rows() {
  local row
  [ -f "$LINKS" ] || return 0
  while IFS= read -r row || [ -n "$row" ]; do
    case "$row" in
      '' | '#'*) continue ;;
    esac
    printf '%s\n' "$row"
  done < "$LINKS"
}

# A row is seven tab-separated columns and no column is ever empty, so one
# `read` splits it into named variables without a subprocess per field. The
# record is kept forever by design, so a scan that forked per field would cost
# more on every cycle than the one before it.
LINK_PROJECT=- LINK_ISSUE=- LINK_TASK=- LINK_DESIRED=- LINK_SYNCED=-
LINK_PR=- LINK_PR_SYNCED=-

link_clear() {
  LINK_PROJECT=- LINK_ISSUE=- LINK_TASK=- LINK_DESIRED=- LINK_SYNCED=-
  LINK_PR=- LINK_PR_SYNCED=-
}

# links_find issue|task <value>: leave the matching record in the LINK_
# variables and print it, or clear them and return 1. Callers read the
# variables, so this is never run inside a command substitution.
links_find() {
  local by=$1 want=$2 found=
  while IFS=$TAB read -r LINK_PROJECT LINK_ISSUE LINK_TASK LINK_DESIRED \
    LINK_SYNCED LINK_PR LINK_PR_SYNCED; do
    case "$by" in
      issue) [ "$LINK_ISSUE" = "$want" ] || continue ;;
      *) [ "$LINK_TASK" = "$want" ] || continue ;;
    esac
    found=1
    break
  done < <(links_rows)
  if [ -z "$found" ]; then
    link_clear
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$LINK_PROJECT" "$LINK_ISSUE" "$LINK_TASK" "$LINK_DESIRED" "$LINK_SYNCED" \
    "$LINK_PR" "$LINK_PR_SYNCED"
}

# links_put <project> <issue> <task> <desired> <synced> <pr> <pr_synced>
# Atomically rewrites the record file, replacing any row for the same issue.
links_put() {
  local project=$1 issue=$2 task=$3 desired=$4 synced=$5 pr=$6 pr_synced=$7
  local tmp r_project r_issue r_task r_desired r_synced r_pr r_pr_synced
  mkdir -p "$DATA" || die "cannot create $DATA" 1
  tmp=$(umask 077; mktemp "$DATA/.board-links.XXXXXX") || die "cannot write the linkage record" 1
  printf '%s\n' "$LINKS_HEADER" > "$tmp"
  while IFS=$TAB read -r r_project r_issue r_task r_desired r_synced r_pr \
    r_pr_synced; do
    [ "$r_issue" != "$issue" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$r_project" "$r_issue" "$r_task" "$r_desired" "$r_synced" "$r_pr" \
      "$r_pr_synced" >> "$tmp"
  done < <(links_rows)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$project" "$issue" "$task" "$desired" "$synced" "${pr:--}" "${pr_synced:--}" >> "$tmp"
  mv -f "$tmp" "$LINKS" || { rm -f "$tmp"; die "cannot replace the linkage record" 1; }
}

# --- identifiers ------------------------------------------------------------

# issue_canonical <url>: print the canonical issue URL, or fail.
issue_canonical() {
  local url=${1:-} rest number
  url=${url%%\#*}
  url=${url%%\?*}
  url=${url%/}
  case "$url" in
    https://*/*/*/issues/*) ;;
    *) return 1 ;;
  esac
  rest=${url#https://}
  number=${rest##*/}
  case "$number" in
    '' | *[!0-9]*) return 1 ;;
  esac
  case "$url" in
    *"$TAB"* | *' '*) return 1 ;;
  esac
  printf '%s\n' "$url"
}

# issue_repo <canonical-url>: print owner/name.
issue_repo() {
  local rest=${1#https://}
  rest=${rest#*/}
  printf '%s/%s\n' "${rest%%/*}" "$(printf '%s' "${rest#*/}" | cut -d/ -f1)"
}

task_id_valid() {
  case "${1:-}" in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

pr_url_valid() {
  case "${1:-}" in
    https://*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *"$TAB"* | *' '*) return 1 ;;
  esac
  return 0
}

# --- board reads ------------------------------------------------------------

# Normalize a field, option, label, or login the way any JSON export may spell
# it, so a "Status"/"status" or "In Progress"/"inProgress" difference is not a
# behavioral difference.
norm_name() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d ' '
}

# json_string <text>: emit a JSON string literal for safe jq interpolation.
# Configuration already restricts these names to letters, digits, spaces, dot,
# underscore, and dash, so this is defence in depth rather than the only guard.
json_string() {
  printf '"%s"' "$(printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

# The board read's columns, in order:
#   item_id  type  issue_url  status  labels  assignees  title  body
# Every column falls back to `-` so the reader never sees an empty field.
items_jq() {
  local status_key
  status_key=$(json_string "$(norm_name "$1")")
  cat <<JQ
def dash: if (. == null or . == "") then "-" else . end;
def clean: (. // "") | tostring | gsub("[\\\\t\\\\n\\\\r]+"; " ") | dash;
def names:
  (. // [])
  | if type == "array" then map(if type == "object" then (.name // .login // "") else tostring end) else [] end
  | join(",") | dash;
.items[]
| . as \$i
| ((\$i.content // {}) | if type == "object" then . else {} end) as \$c
| [ (\$i.id // "" | tostring | dash),
    (\$c.type // \$i.type // "" | tostring | dash),
    (\$c.url // \$i.url // "" | tostring | dash),
    ( \$i | to_entries
         | map(select((.key | ascii_downcase | gsub(" "; "")) == $status_key))
         | (.[0].value // "")
         | (if type == "object" then (.name // "") else tostring end)
         | dash ),
    ((\$c.labels // \$i.labels) | names),
    ((\$c.assignees // \$i.assignees) | names),
    ((\$c.title // \$i.title) | clean),
    ((\$c.body // \$i.body) | clean)
  ] | @tsv
JQ
}

# The field read's columns: "field"<TAB>id, then "option"<TAB>id<TAB>name.
fields_jq() {
  local field_key
  field_key=$(json_string "$(norm_name "$1")")
  cat <<JQ
.fields[]
| select((.name | ascii_downcase | gsub(" "; "")) == $field_key)
| (["field", (.id // "" | tostring)] | @tsv),
  ((.options // [])[] | ["option", (.id // "" | tostring), (.name // "" | tostring)] | @tsv)
JQ
}

# board_items <owner> <number> <status_field> <limit> <outfile>
board_items() {
  local owner=$1 number=$2 status_field=$3 limit=$4 out=$5
  "$GH" project item-list "$number" --owner "$owner" --limit "$limit" \
    --format json --jq "$(items_jq "$status_field")" > "$out"
}

# --- board writes -----------------------------------------------------------

# board_item_id <owner> <number> <status_field> <limit> <issue-url>
board_item_id() {
  local owner=$1 number=$2 status_field=$3 limit=$4 issue=$5
  local tmp id url canonical rc=1
  tmp=$(mktemp) || return 1
  if board_items "$owner" "$number" "$status_field" "$limit" "$tmp"; then
    while IFS=$'\t' read -r id _ url _ _ _ _ _; do
      canonical=$(issue_canonical "$url" 2>/dev/null) || continue
      [ "$canonical" = "$issue" ] || continue
      printf '%s\n' "$id"
      rc=0
      break
    done < "$tmp"
  fi
  rm -f "$tmp"
  return "$rc"
}

# The project, field, and option node IDs are the same for every card on one
# board, so they are read once per board and reused by every write in this run.
# Resolving them per write would turn a cheap cycle into three project reads for
# each outstanding write it retries.
BOARD_IDS_KEY=
BOARD_PROJECT_ID=
BOARD_FIELD_ID=
BOARD_OPTIONS=

# board_status_ids <owner> <number> <status_field>: resolve and cache them.
# A failure caches nothing, so the next write retries the read.
board_status_ids() {
  local owner=$1 number=$2 status_field=$3
  local key project_id field_id options tmp kind a b
  key="$owner$TAB$number$TAB$status_field"
  if [ "$BOARD_IDS_KEY" = "$key" ]; then
    return 0
  fi
  project_id=$("$GH" project view "$number" --owner "$owner" --format json --jq '.id' </dev/null) || {
    warn "could not read project $owner/$number"
    return 1
  }
  [ -n "$project_id" ] || {
    warn "project $owner/$number reported no id"
    return 1
  }
  tmp=$(mktemp) || return 1
  if ! "$GH" project field-list "$number" --owner "$owner" --limit 100 \
    --format json --jq "$(fields_jq "$status_field")" > "$tmp" </dev/null; then
    rm -f "$tmp"
    warn "could not read the fields of project $owner/$number"
    return 1
  fi
  field_id=''
  options=''
  while IFS=$TAB read -r kind a b; do
    case "$kind" in
      field) field_id=$a ;;
      option) options="$options$(norm_name "${b:-}")$TAB$a"$'\n' ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  if [ -z "$field_id" ]; then
    warn "project $owner/$number has no \"$status_field\" field"
    return 1
  fi
  BOARD_PROJECT_ID=$project_id
  BOARD_FIELD_ID=$field_id
  BOARD_OPTIONS=$options
  BOARD_IDS_KEY=$key
  return 0
}

# board_option_id <option-name>: the cached single-select option id, or fail.
board_option_id() {
  local want name id
  want=$(norm_name "$1")
  while IFS=$TAB read -r name id; do
    [ "$name" = "$want" ] || continue
    printf '%s\n' "$id"
    return 0
  done <<< "$BOARD_OPTIONS"
  return 1
}

# board_write_status <owner> <number> <status_field> <item-id> <issue-url> <option-name>
# For a caller that already holds the card's item id, which the board read hands
# it. Any failing step returns non-zero so the write stays outstanding.
board_write_status() {
  local owner=$1 number=$2 status_field=$3 item_id=$4 issue=$5 option_name=$6
  local option_id
  board_status_ids "$owner" "$number" "$status_field" || return 1
  option_id=$(board_option_id "$option_name") || {
    warn "field \"$status_field\" has no \"$option_name\" option"
    return 1
  }
  "$GH" project item-edit --id "$item_id" --project-id "$BOARD_PROJECT_ID" \
    --field-id "$BOARD_FIELD_ID" --single-select-option-id "$option_id" \
    >/dev/null </dev/null || {
    warn "could not move $issue to \"$option_name\""
    return 1
  }
  return 0
}

# board_set_status <owner> <number> <status_field> <limit> <issue-url> <option-name>
# For a caller that holds only the issue URL and has to find its card first.
board_set_status() {
  local owner=$1 number=$2 status_field=$3 limit=$4 issue=$5 option_name=$6
  local item_id
  item_id=$(board_item_id "$owner" "$number" "$status_field" "$limit" "$issue") || {
    warn "$issue is not a card on project $owner/$number"
    return 1
  }
  board_write_status "$owner" "$number" "$status_field" "$item_id" "$issue" "$option_name"
}

# board_comment <issue-url> <body>
# Runs from inside poll's item loop, so it never inherits the board read on
# stdin.
board_comment() {
  "$GH" issue comment "$1" --body "$2" >/dev/null </dev/null || {
    warn "could not comment on $1"
    return 1
  }
  return 0
}

# --- state vocabulary -------------------------------------------------------
#
# Todo, In Progress, and Done are the whole mapping. A column the captain added
# is recorded as "other" so their intent survives, never as a fourth state
# firstmate drives.

state_column() {
  local state=$1 todo=$2 in_progress=$3 done_col=$4
  case "$state" in
    todo) printf '%s\n' "$todo" ;;
    in-progress) printf '%s\n' "$in_progress" ;;
    done) printf '%s\n' "$done_col" ;;
    *) return 1 ;;
  esac
}

column_state() {
  local raw=$1 todo=$2 in_progress=$3 done_col=$4 want
  want=$(norm_name "$raw")
  if [ "$want" = "$(norm_name "$todo")" ]; then
    printf 'todo\n'
  elif [ "$want" = "$(norm_name "$in_progress")" ]; then
    printf 'in-progress\n'
  elif [ "$want" = "$(norm_name "$done_col")" ]; then
    printf 'done\n'
  else
    printf 'other\n'
  fi
}

# text_has <haystack> <needle>: normalized substring test.
text_has() {
  local hay needle
  hay=$(norm_name "$1")
  needle=$(norm_name "$2")
  case "$hay" in
    *"$needle"*) return 0 ;;
  esac
  return 1
}

# list_has <comma-list> <needle>: normalized membership test.
list_has() {
  local list needle
  list=",$(norm_name "$1"),"
  needle=",$(norm_name "$2"),"
  case "$list" in
    *"$needle"*) return 0 ;;
  esac
  return 1
}

# --- verbs ------------------------------------------------------------------

cmd_boards() {
  local want=${1:-} project owner number repo label mention assignee
  local status_field todo in_progress done_col
  while IFS=$'\t' read -r project owner number repo label mention assignee \
    status_field todo in_progress done_col; do
    [ -n "$project" ] || continue
    if [ -n "$want" ] && [ "$want" != "$project" ]; then
      continue
    fi
    printf 'board %s %s/%s repo=%s label=%s mention=%s assignee=%s field=%s columns=%s|%s|%s\n' \
      "$project" "$owner" "$number" "$repo" "$label" "$mention" "$assignee" \
      "$status_field" "$todo" "$in_progress" "$done_col"
  done < <(boards_rows)
}

cmd_links() {
  local want=${1:-} row
  while IFS= read -r row; do
    if [ -n "$want" ]; then
      case "$row" in
        "$want$TAB"*) ;;
        *) continue ;;
      esac
    fi
    printf '%s\n' "$row"
  done < <(links_rows)
}

cmd_lookup() {
  local want=${1:?usage: fm-board.sh lookup <issue-url|task-id>} canonical
  if canonical=$(issue_canonical "$want"); then
    links_find issue "$canonical" || return 1
  else
    links_find task "$want" || return 1
  fi
}

cmd_import() {
  local project=${1:?usage: fm-board.sh import <project> <issue-url> <task-id>}
  local raw_issue=${2:?usage: fm-board.sh import <project> <issue-url> <task-id>}
  local task=${3:?usage: fm-board.sh import <project> <issue-url> <task-id>}
  local issue board repo

  board=$(board_for "$project")
  repo=$(printf '%s' "$board" | cut -f4)
  issue=$(issue_canonical "$raw_issue") || die "\"$raw_issue\" is not an issue URL"
  task_id_valid "$task" || die "\"$task\" is not a task id"
  if [ "$repo" != - ] && [ "$(issue_repo "$issue")" != "$repo" ]; then
    die "$issue is not in $repo, the repo configured for board \"$project\""
  fi

  # This duplicate check is deliberately fleet-wide rather than scoped to one
  # board: an issue holds at most one task no matter which board carries it.
  if links_find issue "$issue" >/dev/null; then
    if [ "$LINK_TASK" = "$task" ]; then
      printf 'already-linked %s %s %s\n' "$project" "$issue" "$task"
      return 0
    fi
    die "$issue is already linked to task $LINK_TASK; refusing to relink it to $task" 3
  fi
  if links_find task "$task" >/dev/null; then
    die "task $task is already linked to $LINK_ISSUE" 3
  fi

  links_put "$project" "$issue" "$task" todo todo - -
  printf 'linked %s %s %s\n' "$project" "$issue" "$task"
}

cmd_mark() {
  local task='' state='' limit=$DEFAULT_LIMIT
  local project issue synced pr pr_synced board
  local owner number status_field todo in_progress done_col column

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --limit)
        [ "$#" -gt 1 ] || die "--limit needs a value"
        limit=$2
        shift 2
        ;;
      --limit=*)
        limit=${1#--limit=}
        shift
        ;;
      -*) die "unknown option \"$1\"" ;;
      *)
        if [ -z "$task" ]; then
          task=$1
        elif [ -z "$state" ]; then
          state=$1
        else
          die "$MARK_USAGE"
        fi
        shift
        ;;
    esac
  done
  if [ -z "$task" ] || [ -z "$state" ]; then
    die "$MARK_USAGE"
  fi
  limit_valid "$limit" || die "--limit must be a positive number"
  case "$state" in
    todo | in-progress | done) ;;
    *) die "unknown board state \"$state\" (use todo, in-progress, or done)" ;;
  esac
  links_find task "$task" >/dev/null || die "task $task is not linked to a board issue"
  project=$LINK_PROJECT
  issue=$LINK_ISSUE
  synced=$LINK_SYNCED
  pr=$LINK_PR
  pr_synced=$LINK_PR_SYNCED
  board=$(board_for "$project")
  owner=$(printf '%s' "$board" | cut -f2)
  number=$(printf '%s' "$board" | cut -f3)
  status_field=$(printf '%s' "$board" | cut -f8)
  todo=$(printf '%s' "$board" | cut -f9)
  in_progress=$(printf '%s' "$board" | cut -f10)
  done_col=$(printf '%s' "$board" | cut -f11)
  column=$(state_column "$state" "$todo" "$in_progress" "$done_col")

  links_put "$project" "$issue" "$task" "$state" "$synced" "$pr" "$pr_synced"
  if board_set_status "$owner" "$number" "$status_field" "$limit" "$issue" "$column"; then
    links_put "$project" "$issue" "$task" "$state" "$state" "$pr" "$pr_synced"
    printf 'synced %s %s %s %s\n' "$project" "$issue" "$task" "$state"
  else
    printf 'stale %s %s %s %s\n' "$project" "$issue" "$task" "$state"
  fi
  return 0
}

cmd_pr() {
  local task=${1:?usage: fm-board.sh pr <task-id> <pr-url>}
  local url=${2:?usage: fm-board.sh pr <task-id> <pr-url>}
  local project issue desired synced pr pr_synced

  pr_url_valid "$url" || die "\"$url\" is not a pull request URL"
  links_find task "$task" >/dev/null || die "task $task is not linked to a board issue"
  project=$LINK_PROJECT
  issue=$LINK_ISSUE
  desired=$LINK_DESIRED
  synced=$LINK_SYNCED
  pr=$LINK_PR
  pr_synced=$LINK_PR_SYNCED
  if [ "$pr" = "$url" ] && [ "$pr_synced" = 1 ]; then
    printf 'already-attached %s %s %s %s\n' "$project" "$issue" "$task" "$url"
    return 0
  fi

  links_put "$project" "$issue" "$task" "$desired" "$synced" "$url" 0
  if board_comment "$issue" "Working PR: $url"; then
    links_put "$project" "$issue" "$task" "$desired" "$synced" "$url" 1
    printf 'attached %s %s %s %s\n' "$project" "$issue" "$task" "$url"
  else
    printf 'stale %s %s %s %s\n' "$project" "$issue" "$task" "$url"
  fi
  return 0
}

cmd_note() {
  local task=${1:?usage: fm-board.sh note <task-id> <text>}
  local text=${2:?usage: fm-board.sh note <task-id> <text>}
  local project issue
  links_find task "$task" >/dev/null || die "task $task is not linked to a board issue"
  project=$LINK_PROJECT
  issue=$LINK_ISSUE
  # A note is a point-in-time record, so it is never queued for retry: a blocker
  # posted three cycles late would be noise, and firstmate escalates the blocker
  # to the captain either way.
  if board_comment "$issue" "$text"; then
    printf 'noted %s %s %s\n' "$project" "$issue" "$task"
  else
    printf 'stale %s %s %s\n' "$project" "$issue" "$task"
  fi
  return 0
}

cmd_ack() {
  local task=${1:?usage: fm-board.sh ack <task-id>}
  local project issue pr pr_synced
  links_find task "$task" >/dev/null || die "task $task is not linked to a board issue"
  project=$LINK_PROJECT
  issue=$LINK_ISSUE
  pr=$LINK_PR
  pr_synced=$LINK_PR_SYNCED
  # The link stays forever so the issue can never be imported twice; only its
  # active execution state retires.
  links_put "$project" "$issue" "$task" other other "$pr" "$pr_synced"
  printf 'acknowledged %s %s %s\n' "$project" "$issue" "$task"
}

# poll_board <board-row> <limit> <items-file>
# Classifies every card, adopts captain edits, and retries outstanding writes.
poll_board() {
  local board=$1 limit=$2 items=$3
  local project owner number repo label mention assignee status_field todo in_progress done_col
  local id type url status labels assignees title body
  local canonical task desired synced pr pr_synced board_state count=0
  local seen_file trigger column
  local l_project l_issue l_task l_desired

  project=$(printf '%s' "$board" | cut -f1)
  owner=$(printf '%s' "$board" | cut -f2)
  number=$(printf '%s' "$board" | cut -f3)
  repo=$(printf '%s' "$board" | cut -f4)
  label=$(printf '%s' "$board" | cut -f5)
  mention=$(printf '%s' "$board" | cut -f6)
  assignee=$(printf '%s' "$board" | cut -f7)
  status_field=$(printf '%s' "$board" | cut -f8)
  todo=$(printf '%s' "$board" | cut -f9)
  in_progress=$(printf '%s' "$board" | cut -f10)
  done_col=$(printf '%s' "$board" | cut -f11)

  seen_file=$(mktemp) || return 1
  while IFS=$TAB read -r id type url status labels assignees title body; do
    [ -n "$id" ] || continue
    count=$((count + 1))
    canonical=$(issue_canonical "$url") || continue
    # Presence on the board is established before any intake filter runs: a card
    # this cycle declines to import is still a card that has not left, and the
    # withdrawal scan below reads absence from this file.
    printf '%s\n' "$canonical" >> "$seen_file"
    board_state=$(column_state "$status" "$todo" "$in_progress" "$done_col")

    if links_find issue "$canonical" >/dev/null; then
      # An issue another configured board already owns is a misconfiguration,
      # not an instruction. Re-homing it would point every later event at the
      # wrong board, so this one is named and left entirely alone.
      if [ "$LINK_PROJECT" != "$project" ]; then
        printf 'foreign %s %s %s %s\n' \
          "$project" "$canonical" "$LINK_PROJECT" "$LINK_TASK"
        continue
      fi
      task=$LINK_TASK
      desired=$LINK_DESIRED
      synced=$LINK_SYNCED
      pr=$LINK_PR
      pr_synced=$LINK_PR_SYNCED
      if [ "$desired" = "$synced" ]; then
        if [ "$board_state" = "$desired" ]; then
          printf 'linked %s %s %s %s\n' "$project" "$canonical" "$task" "$desired"
        else
          links_put "$project" "$canonical" "$task" "$board_state" "$board_state" "$pr" "$pr_synced"
          printf 'instruction %s %s %s %s %s %s\n' \
            "$project" "$canonical" "$task" "$desired" "$board_state" "$status"
          desired=$board_state
          synced=$board_state
        fi
      # A write is outstanding. The board still showing the last confirmed value
      # is this adapter's own lag, not a captain edit.
      elif [ "$board_state" = "$desired" ]; then
        links_put "$project" "$canonical" "$task" "$desired" "$desired" "$pr" "$pr_synced"
        synced=$desired
        printf 'linked %s %s %s %s\n' "$project" "$canonical" "$task" "$desired"
      elif [ "$board_state" = "$synced" ]; then
        column=$(state_column "$desired" "$todo" "$in_progress" "$done_col") || column=
        if [ -n "$column" ] && board_write_status "$owner" "$number" "$status_field" "$id" "$canonical" "$column"; then
          links_put "$project" "$canonical" "$task" "$desired" "$desired" "$pr" "$pr_synced"
          synced=$desired
          printf 'synced %s %s %s %s\n' "$project" "$canonical" "$task" "$desired"
        else
          printf 'stale %s %s %s %s\n' "$project" "$canonical" "$task" "$desired"
        fi
      else
        links_put "$project" "$canonical" "$task" "$board_state" "$board_state" "$pr" "$pr_synced"
        printf 'instruction %s %s %s %s %s %s\n' \
          "$project" "$canonical" "$task" "$desired" "$board_state" "$status"
        desired=$board_state
        synced=$board_state
      fi
      # An outstanding PR attachment is retried exactly like an outstanding card
      # move, because `pr` promised the next cycle would reconcile it.
      if [ "$pr" != - ] && [ "$pr_synced" != 1 ]; then
        if board_comment "$canonical" "Working PR: $pr"; then
          links_put "$project" "$canonical" "$task" "$desired" "$synced" "$pr" 1
          printf 'synced %s %s %s %s\n' "$project" "$canonical" "$task" "$pr"
        else
          printf 'stale %s %s %s %s\n' "$project" "$canonical" "$task" "$pr"
        fi
      fi
      continue
    fi

    # Not linked yet, so from here on this is intake alone. A draft card or a
    # pull request is not a real issue, and an issue outside the configured repo
    # is not this board's work to take.
    [ "$type" = Issue ] || continue
    if [ "$repo" != - ] && [ "$(issue_repo "$canonical")" != "$repo" ]; then
      continue
    fi
    [ "$board_state" = todo ] || continue
    trigger=
    if list_has "$labels" "$label"; then
      trigger=label
    elif [ "$assignee" != - ] && list_has "$assignees" "$assignee"; then
      trigger=assignee
    elif [ "$mention" != - ] && text_has "$title $body" "$mention"; then
      trigger=mention
    fi
    [ -n "$trigger" ] || continue
    printf 'new %s %s %s %s\n' "$project" "$canonical" "$trigger" "$title"
  done < "$items"

  # A card that vanished from the board is the captain withdrawing the work.
  # Two reads cannot tell absence apart from something else and so reconcile
  # nothing: a full page may have another page behind it, and a board that
  # answers with no cards at all while links are open is far more likely to be
  # a changed project number or a lost permission than the captain clearing
  # every card by hand.
  if [ "$count" -ge "$limit" ]; then
    printf 'truncated %s %s\n' "$project" "$count"
  elif [ "$count" -eq 0 ] && [ -n "$(cmd_links "$project")" ]; then
    printf 'error %s the board returned no cards while links are open\n' "$project"
  else
    while IFS=$TAB read -r l_project l_issue l_task l_desired _ _ _; do
      [ "$l_project" = "$project" ] || continue
      if grep -Fqx -- "$l_issue" "$seen_file"; then
        continue
      fi
      # Leaving the board after Done is archiving, and an acknowledged
      # withdrawal is already reconciled; neither is an open instruction.
      case "$l_desired" in
        todo | in-progress) ;;
        *) continue ;;
      esac
      printf 'cancelled %s %s %s %s\n' "$project" "$l_issue" "$l_task" "$l_desired"
    done < <(links_rows)
  fi
  rm -f "$seen_file"
}

cmd_poll() {
  local want='' limit=$DEFAULT_LIMIT board items project owner number status_field
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --limit)
        [ "$#" -gt 1 ] || die "--limit needs a value"
        limit=$2
        shift 2
        ;;
      --limit=*)
        limit=${1#--limit=}
        shift
        ;;
      -*) die "unknown option \"$1\"" ;;
      *)
        want=$1
        shift
        ;;
    esac
  done
  limit_valid "$limit" || die "--limit must be a positive number"
  if [ -n "$want" ]; then
    board_for "$want" >/dev/null
  fi

  while IFS= read -r board; do
    [ -n "$board" ] || continue
    project=$(printf '%s' "$board" | cut -f1)
    owner=$(printf '%s' "$board" | cut -f2)
    number=$(printf '%s' "$board" | cut -f3)
    status_field=$(printf '%s' "$board" | cut -f8)
    if [ -n "$want" ] && [ "$want" != "$project" ]; then
      continue
    fi
    items=$(mktemp) || die "cannot stage the board read" 1
    if board_items "$owner" "$number" "$status_field" "$limit" "$items"; then
      poll_board "$board" "$limit" "$items"
    else
      # A read failure never halts the cycle; the next one reconciles.
      printf 'error %s could not read project %s/%s\n' "$project" "$owner" "$number"
    fi
    rm -f "$items"
  done < <(boards_rows)
  return 0
}

# --- dispatch ---------------------------------------------------------------

case "${1:-}" in
  -h | --help | help | '')
    print_help
    exit 0
    ;;
esac
VERB=$1
shift
# Load and validate board configuration in this shell, before any verb runs, so
# a malformed file is one actionable error rather than a command that quietly
# behaves as though no board were configured.
boards_load
case "$VERB" in
  boards) cmd_boards "$@" ;;
  poll) cmd_poll "$@" ;;
  import) cmd_import "$@" ;;
  links) cmd_links "$@" ;;
  lookup) cmd_lookup "$@" ;;
  mark) cmd_mark "$@" ;;
  pr) cmd_pr "$@" ;;
  note) cmd_note "$@" ;;
  ack) cmd_ack "$@" ;;
  *) die "unknown command \"$VERB\" (see fm-board.sh --help)" ;;
esac
