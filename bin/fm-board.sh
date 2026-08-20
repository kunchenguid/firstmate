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
#   fm-board.sh place <project> <task-id> <title> [<body>] [--lands-in <owner/name>]
#   fm-board.sh child-add <project> <parent-issue-url> <title> <body> <task-id>
#   fm-board.sh decomposed <project> <parent-issue-url>
#   fm-board.sh decompositions [<project>]
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
#   queued = Queued              # optional; default: off
#   big-picture-todo = Big Picture Todo              # optional; default: off
#   big-picture-in-progress = Big Picture In Progress  # optional; default: off
#   big-picture-done = Big Picture Done              # optional; default: off
#
# `queued` is optional and off by default. Configured, it names the column a card
# sits in once firstmate has been cleared to launch the work. Unconfigured, no
# card is ever read or written as queued and the adapter behaves exactly as it
# did before the key existed.
#
# The three `big-picture-*` keys are the whole on switch for decomposition and
# default to unset. With none of them set this adapter behaves exactly as it did
# before they existed: no card is ever classified as a container and `decompose`
# is never printed. Setting some but not all three is a configuration error
# rather than a half-enabled feature, and so is naming a column that a
# `todo`, `in-progress`, or `done` key already names.
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
# only files this adapter ever writes are data/board-links.tsv and
# data/board-decompositions.tsv, and an unconfigured home never reads either of
# them into any behavior.
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
# from todo|queued|in-progress|done|other. They differ exactly while a board write is
# outstanding, which is what makes a failed write retryable on the next cycle.
# `other` is a column the captain added that firstmate does not drive; it is
# recorded so their intent is preserved, not so a fourth execution state exists.
# No column is ever empty: `-` is the placeholder, because bash collapses empty
# tab-separated fields when it reads them back.
#
# DECOMPOSITION. A big-picture card is a container: an issue whose children are
# the real work. No worker can ship a container, so a container must never spend
# the one issue-to-task binding above, and this adapter makes that structural
# rather than conventional. `poll` never prints `new` for a card sitting in a
# big-picture column, `import` refuses an issue that holds a decomposition
# record, and `child-add` refuses a parent that holds a link. Neither record can
# therefore be reached from the other's side. `poll` writes a container's record
# the first time it sees the card rather than when it is decomposed, so the
# refusal covers every container the board has ever shown, not only the ones
# already broken down.
#
# `poll` prints `decompose <project> <parent-issue-url>` for a real issue in the
# big-picture Todo column that carries the configured label and is not yet
# recorded as decomposed. Deciding what a container breaks down into is
# judgement, so this script never invents children: firstmate reads that line,
# runs `child-add` once per piece of work, and closes the container with
# `decomposed`. Like `new`, a `decompose` line repeats every cycle until that
# closing command runs, so an interrupted decomposition is finished rather than
# lost; once closed it is never printed again, however long ago it was closed.
#
# data/board-decompositions.tsv is that durable record, alongside the linkage
# record and for the same reason: it must outlive task cleanup, so a parent
# decomposed months ago is never decomposed a second time. One row per parent,
# tab separated, `-` for an empty column:
#   project  parent  state  desired  synced  children
# `state` is open while children are being created and done once `decomposed`
# closed it. `children` is `-`, or a comma-separated list of `task=child-url`
# pairs; neither half can contain a comma or an `=`, so the pair parses back
# unambiguously. `desired` and `synced` carry the parent card's status exactly as
# the linkage record's own two columns do.
#
# PLACEMENT, the inverse of import. `place` puts a task firstmate already holds
# onto the board: it creates the issue, cards it, sets it to Todo, and records
# the link, after which dispatch, PR attachment, and merge all reflect through
# the ordinary events with no further special casing. `child-add` is the same
# operation with a parent - it additionally creates the issue as a native GitHub
# sub-issue of the container and records the child against it - so both verbs run
# one shared implementation rather than two that can drift.
#
# Both create the issue in the board's configured repo (a board with no `repo`
# key uses the parent's repo for a child, and refuses `place` because it has no
# repo to choose), carrying the trigger label. `place` takes an optional
# `--lands-in <owner/name>` that states on the card which repository the change
# actually lands in; pass it whenever that is not the repository the issue itself
# is filed in, so a roadmap never implies a diff is somewhere it is not.
#
# Which tasks belong on a board is an editorial call this script never makes.
# There is deliberately no command that sweeps unlinked tasks onto a board:
# placement is one task at a time, by a caller that decided that task belongs
# there.
#
# Because the created issue carries the label and holds a link before the next
# cycle reads the board, `poll` reports it as `linked` and can never offer it as
# `new`.
#
# The failure contract has two halves, split at the one irreversible step.
# Creating the issue is the command's whole purpose, so a creation that does not
# land writes nothing, reports the failure, and exits 1 - there is nothing to
# converge toward and firstmate must not build a backlog item on it. Every step
# after creation degrades fail-soft: the command prints `placed-partial` or
# `child-partial` naming the first step that did not land, and exits 0.
#
# Repeating either command converges instead of filing a second issue for the
# same work, through three guards in falling order of cost. A task that already
# holds a link is finished, and answers `already-placed` with no network call at
# all - the link is written last precisely so that holding one proves the rest
# landed. A child already recorded against its parent is reused rather than
# created. Otherwise, before creating anything, the repo's most recent issues are
# read and one already carrying this task's `firstmate-task:` marker is adopted;
# that scan is deliberately shallow because the only gap it closes is an issue
# created moments before an interruption.
#
# The link is written as soon as the card exists rather than at the very end, so
# a card on the board is never briefly importable as new work; its `synced` stays
# unconfirmed until the column write lands, which leaves the ordinary outstanding
# -write retry to finish the job on the next cycle.
#
# PARENT STATUS. Once a parent has children, `poll` keeps its card honest from
# their recorded states: any child in progress derives in-progress, all children
# done derives done, and anything else derives todo. A child recorded in a column
# firstmate does not drive is left out of that entirely, because a withdrawn
# child must not hold its parent short of done forever. The derived state moves
# the card through the three big-picture columns exactly as `mark` moves an
# ordinary card, is retried on the next cycle when the write does not land, and
# is reported with the same `synced` and `stale` vocabulary. A parent already
# showing what firstmate recorded prints nothing at all, and one showing anything
# firstmate did not write diverges exactly as any other card does.
#
# FAIL SOFT. Every board write degrades to a stale board instead of blocking
# delivery: `mark`, `pr`, and `note` exit 0 whether or not the write landed,
# reporting the failure on stderr and leaving `mark` and `pr` retryable. `poll`
# retries both outstanding writes - the card move and the PR attachment - and
# reports each with the same `synced` or `stale` line, and it also exits 0 on a
# board read failure, reporting it as an `error` line. A read that cannot tell
# absence from its own limits - a full page, or a board answering with no cards
# at all while links are open - says so and reconciles nothing rather than
# guessing. Exiting non-zero is reserved for the three things a caller must not
# proceed past: a usage or configuration error exits 2, a refused conflicting
# relink or container-versus-task conflict exits 3, and an issue this adapter was
# asked to create but could not exits 1, as PLACEMENT above sets out.
#
# DIRECTION OF AUTHORITY. Firstmate's own durable records are the truth and the
# board is how that truth is shown; chat, not the board, is where the captain
# controls the work. So status flows one way, outward: this adapter writes
# todo, queued, in-progress, and done onto a card from what firstmate already
# recorded, and a card's column never tells firstmate what to do.
#
# That makes a status this adapter did not write a divergence rather than an
# instruction. `poll` prints a `divergence` line, writes nothing to the record,
# writes nothing to the board, and leaves it for firstmate to raise with the
# captain; the deliberate exception is a write still outstanding, which is
# retried because the board is showing the value this adapter last confirmed
# rather than a change to it. A card that appears in the queued column without
# firstmate having put it there can only mean something outside firstmate wrote
# to this board, which is why nothing here reconciles it in either direction and
# nothing about it starts work.
#
# Intake is the one thing the board still states rather than reports: a new
# labelled card is the captain adding work, and `new` continues to mean exactly
# that.
#
# An explicit `mark` is how a divergence is resolved, because it is firstmate
# acting rather than the adapter reconciling behind the captain's back: it writes
# the card and records what it confirmed, and the divergence stops being reported.
#
# An issue that a different configured board already owns is a misconfiguration
# rather than an instruction, so `poll` names it in a `foreign` line carrying the
# owning project and touches neither the card nor the record. Ownership is never
# silently re-homed, because every later event would then resolve the wrong
# board. `import` stays fleet-wide: an issue linked under any project can never
# be imported a second time under another one.
#
# A card that left the board while firstmate was still executing it is reported
# as `cancelled` until `ack` records that it was reconciled. Repeating survives a
# missed cycle; a card that left after reaching Done is ordinary archiving and is
# never reported. Like a divergence it is something to raise, not something this
# adapter acts on, and neither reporting nor acknowledging one ever authorizes
# discarding unlanded work: hard rule 3 stands, and this adapter touches no
# branch, worktree, or repository.
#
# COST. Board and Projects work is GraphQL with its own hourly budget, and a
# full board read inside a per-item loop is what exhausts it. So one
# reconciliation cycle reads the board exactly once and every write it then makes
# reuses a card id from that one read; `place` and `child-add` read no board at
# all, taking their card id from what the add itself returned, because a freshly
# added card is not immediately visible in a board listing anyway. The project,
# field, and option node IDs are resolved once per invocation and cached. Their
# cost is therefore a small constant per card rather than a function of how many
# cards the board carries.
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
DECOMPS="$DATA/board-decompositions.tsv"
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
  local set_count=0 name norm seen_cols=
  [ -n "$project" ] || return 0
  [ "$owner" != - ] || die "config/boards: board \"$project\" has no owner"
  [ "$number" != - ] || die "config/boards: board \"$project\" has no number"
  # The three big-picture columns are one switch, not three independent keys: a
  # partial set would classify some containers and not others, so it is refused
  # here rather than half-enabled.
  for name in "$bp_todo" "$bp_in_progress" "$bp_done"; do
    [ "$name" = - ] || set_count=$((set_count + 1))
  done
  if [ "$set_count" != 0 ] && [ "$set_count" != 3 ]; then
    die "config/boards: board \"$project\" sets some big-picture columns but not all three (big-picture-todo, big-picture-in-progress, big-picture-done)"
  fi
  # Two keys naming one column would make a single card mean two different
  # things, so every configured column name has to be distinct.
  for name in "$todo" "$in_progress" "$done_col" "$queued" "$bp_todo" \
    "$bp_in_progress" "$bp_done"; do
    [ "$name" != - ] || continue
    norm=$(norm_name "$name")
    case "$TAB$seen_cols" in
      *"$TAB$norm$TAB"*)
        die "config/boards: board \"$project\" gives \"$name\" as more than one column"
        ;;
    esac
    seen_cols="$seen_cols$norm$TAB"
  done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$project" "$owner" "$number" "$repo" "$label" "$mention" "$assignee" \
    "$status_field" "$todo" "$in_progress" "$done_col" \
    "$bp_todo" "$bp_in_progress" "$bp_done" "$queued"
}
boards_emit() {
  local line key value project owner number repo label mention assignee
  local status_field todo in_progress done_col lineno=0 seen=
  local bp_todo bp_in_progress bp_done queued
  [ -f "$BOARDS_FILE" ] || return 0

  project=''
  owner=- number=- repo=- label=firstmate mention=- assignee=-
  status_field=Status todo=Todo in_progress='In Progress' done_col=Done
  bp_todo=- bp_in_progress=- bp_done=- queued=-
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
      bp_todo=- bp_in_progress=- bp_done=- queued=-
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
      label | todo | in-progress | done | queued | status-field \
        | big-picture-todo | big-picture-in-progress | big-picture-done)
        [[ $value =~ $CONFIG_VALUE_RE ]] \
          || die "config/boards line $lineno: \"$key\" may use only letters, digits, spaces, dot, underscore, and dash"
        case "$key" in
          label) label=$value ;;
          todo) todo=$value ;;
          in-progress) in_progress=$value ;;
          done) done_col=$value ;;
          status-field) status_field=$value ;;
          queued) queued=$value ;;
          big-picture-todo) bp_todo=$value ;;
          big-picture-in-progress) bp_in_progress=$value ;;
          big-picture-done) bp_done=$value ;;
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

# --- durable decomposition record -------------------------------------------
#
# One row per container, kept for the same reason the linkage record is: a
# parent decomposed long ago must never be offered for decomposition again.

DECOMPS_HEADER="# fm-board.sh durable decompositions: project${TAB}parent${TAB}state${TAB}desired${TAB}synced${TAB}children"

decomps_rows() {
  local row
  [ -f "$DECOMPS" ] || return 0
  while IFS= read -r row || [ -n "$row" ]; do
    case "$row" in
      '' | '#'*) continue ;;
    esac
    printf '%s\n' "$row"
  done < "$DECOMPS"
}

DECOMP_PROJECT=- DECOMP_PARENT=- DECOMP_STATE=-
DECOMP_DESIRED=- DECOMP_SYNCED=- DECOMP_CHILDREN=-

decomp_clear() {
  DECOMP_PROJECT=- DECOMP_PARENT=- DECOMP_STATE=-
  DECOMP_DESIRED=- DECOMP_SYNCED=- DECOMP_CHILDREN=-
}

# decomps_find <parent-issue-url>: leave the matching row in the DECOMP_
# variables and print it, or clear them and return 1. Like links_find, callers
# read the variables, so this never runs inside a command substitution.
decomps_find() {
  local want=$1 found=
  while IFS=$TAB read -r DECOMP_PROJECT DECOMP_PARENT DECOMP_STATE \
    DECOMP_DESIRED DECOMP_SYNCED DECOMP_CHILDREN; do
    [ "$DECOMP_PARENT" = "$want" ] || continue
    found=1
    break
  done < <(decomps_rows)
  if [ -z "$found" ]; then
    decomp_clear
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$DECOMP_PROJECT" "$DECOMP_PARENT" "$DECOMP_STATE" \
    "$DECOMP_DESIRED" "$DECOMP_SYNCED" "$DECOMP_CHILDREN"
}

# decomps_put <project> <parent> <state> <desired> <synced> <children>
decomps_put() {
  local project=$1 parent=$2 state=$3 desired=$4 synced=$5 children=$6
  local tmp r_project r_parent r_state r_desired r_synced r_children
  mkdir -p "$DATA" || die "cannot create $DATA" 1
  tmp=$(umask 077; mktemp "$DATA/.board-decompositions.XXXXXX") \
    || die "cannot write the decomposition record" 1
  printf '%s\n' "$DECOMPS_HEADER" > "$tmp"
  while IFS=$TAB read -r r_project r_parent r_state r_desired \
    r_synced r_children; do
    [ "$r_parent" != "$parent" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$r_project" "$r_parent" "$r_state" "$r_desired" \
      "$r_synced" "$r_children" >> "$tmp"
  done < <(decomps_rows)
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$project" "$parent" "$state" "$desired" "$synced" "$children" >> "$tmp"
  mv -f "$tmp" "$DECOMPS" || { rm -f "$tmp"; die "cannot replace the decomposition record" 1; }
}

# The children column packs one `task=child-url` pair per child, comma
# separated. Neither half can hold a comma or an `=`, so splitting on those two
# characters recovers the pairs exactly.

# children_pairs <children>: print one `task=url` pair per line.
children_pairs() {
  local children=${1:--} pair rest
  [ "$children" != - ] || return 0
  rest=$children
  while [ -n "$rest" ]; do
    pair=${rest%%,*}
    if [ "$pair" = "$rest" ]; then
      rest=
    else
      rest=${rest#*,}
    fi
    [ -z "$pair" ] || printf '%s\n' "$pair"
  done
}

# children_child_for <children> <task-id>: print that task's recorded child URL.
children_child_for() {
  local children=$1 task=$2 pair
  while IFS= read -r pair; do
    [ "${pair%%=*}" = "$task" ] || continue
    printf '%s\n' "${pair#*=}"
    return 0
  done < <(children_pairs "$children")
  return 1
}

# children_add <children> <task-id> <child-url>: print the list with that pair
# added, replacing any pair the same task already holds.
children_add() {
  local children=$1 task=$2 url=$3 pair out=
  while IFS= read -r pair; do
    [ "${pair%%=*}" != "$task" ] || continue
    out="${out:+$out,}$pair"
  done < <(children_pairs "$children")
  printf '%s\n' "${out:+$out,}$task=$url"
}

# children_tasks <children>: print one child task id per line.
children_tasks() {
  local pair
  while IFS= read -r pair; do
    printf '%s\n' "${pair%%=*}"
  done < <(children_pairs "${1:--}")
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

# board_item_add <owner> <number> <issue-url>: card an issue and print the item
# id the add itself returned. The id is taken from the add's own answer and
# never by re-reading the board, because a freshly added card is not immediately
# visible in a board listing.
board_item_add() {
  local owner=$1 number=$2 issue=$3 id
  id=$("$GH" project item-add "$number" --owner "$owner" --url "$issue" \
    --format json --jq '.id' </dev/null) || {
    warn "could not add $issue to project $owner/$number"
    return 1
  }
  [ -n "$id" ] || {
    warn "adding $issue to project $owner/$number returned no card id"
    return 1
  }
  printf '%s\n' "$id"
}

# Every issue this adapter creates carries this marker line in its body, so an
# issue created moments before an interruption can be recognized rather than
# filed a second time.
MARKER_PREFIX='firstmate-task:'
# How far back the recovery scan looks. Deliberately shallow: the only gap it
# closes is an issue created seconds ago, which is necessarily among the newest.
MARKER_SCAN_LIMIT=30

issue_marker() {
  printf '%s %s\n' "$MARKER_PREFIX" "$1"
}

# issue_find_by_marker <repo> <task-id>: print the URL of a recent issue already
# carrying this task's marker, or fail. The match is made here rather than in the
# query so the scan stays one plain listing of recent issues.
issue_find_by_marker() {
  local repo=$1 task=$2 marker tmp url body found=
  marker=$(issue_marker "$task")
  tmp=$(mktemp) || return 1
  if "$GH" issue list --repo "$repo" --state all --limit "$MARKER_SCAN_LIMIT" \
    --json url,body \
    --jq '.[] | [(.url // ""), ((.body // "") | gsub("[\\n\\t\\r]+"; " "))] | @tsv' \
    > "$tmp" </dev/null; then
    while IFS=$TAB read -r url body; do
      case "$body" in
        *"$marker"*) ;;
        *) continue ;;
      esac
      found=$(issue_canonical "$url") || continue
      break
    done < "$tmp"
  else
    rm -f "$tmp"
    warn "could not read the recent issues of $repo"
    return 2
  fi
  rm -f "$tmp"
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# issue_body <body> <task-id> <lands-in|->: the issue body actually filed.
issue_body() {
  local body=$1 task=$2 lands_in=$3 out=
  [ "$body" = - ] || out=$body
  if [ "$lands_in" != - ]; then
    out="${out:+$out

}Lands in: $lands_in"
  fi
  printf '%s\n' "${out:+$out

}$(issue_marker "$task")"
}

# issue_create <repo> <label> <title> <body> <parent|-> : print the new issue URL.
# A child is created as a native sub-issue in this same call, so a parent link is
# never a separate step that can be left half-done.
issue_create() {
  local repo=$1 label=$2 title=$3 body=$4 parent=$5
  local args url line
  args=(issue create --repo "$repo" --title "$title" --body "$body" --label "$label")
  [ "$parent" = - ] || args+=(--parent "$parent")
  url=''
  while IFS= read -r line; do
    case "$line" in
      https://*/issues/*) url=$line ;;
    esac
  done < <("$GH" "${args[@]}" </dev/null)
  [ -n "$url" ] || return 1
  issue_canonical "$url"
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
# Todo, In Progress, and Done are always drivable, and a configured queued column
# joins them. Firstmate writes all four from its own records. A column that is
# none of them is read as "other": the adapter neither drives it nor pretends to
# understand it, and a card sitting in one diverges from what firstmate recorded.

state_column() {
  local state=$1 todo=$2 in_progress=$3 done_col=$4 queued=${5:--}
  case "$state" in
    todo) printf '%s\n' "$todo" ;;
    in-progress) printf '%s\n' "$in_progress" ;;
    done) printf '%s\n' "$done_col" ;;
    queued)
      [ "$queued" != - ] || return 1
      printf '%s\n' "$queued"
      ;;
    *) return 1 ;;
  esac
}

column_state() {
  local raw=$1 todo=$2 in_progress=$3 done_col=$4 queued=${5:--} want
  want=$(norm_name "$raw")
  if [ "$want" = "$(norm_name "$todo")" ]; then
    printf 'todo\n'
  elif [ "$want" = "$(norm_name "$in_progress")" ]; then
    printf 'in-progress\n'
  elif [ "$want" = "$(norm_name "$done_col")" ]; then
    printf 'done\n'
  elif [ "$queued" != - ] && [ "$want" = "$(norm_name "$queued")" ]; then
    printf 'queued\n'
  else
    printf 'other\n'
  fi
}

# The big-picture columns carry the same three states, on a parallel set of
# column names. They are the container lane, never a fourth execution state.

bp_state_column() {
  local state=$1 bp_todo=$2 bp_in_progress=$3 bp_done=$4
  case "$state" in
    todo) printf '%s\n' "$bp_todo" ;;
    in-progress) printf '%s\n' "$bp_in_progress" ;;
    done) printf '%s\n' "$bp_done" ;;
    *) return 1 ;;
  esac
}

# bp_column_state <raw> <bp_todo> <bp_in_progress> <bp_done>: the container state
# that column names, or nothing at all when it names no big-picture column.
bp_column_state() {
  local raw=$1 bp_todo=$2 bp_in_progress=$3 bp_done=$4 want
  [ "$bp_todo" != - ] || return 1
  want=$(norm_name "$raw")
  if [ "$want" = "$(norm_name "$bp_todo")" ]; then
    printf 'todo\n'
  elif [ "$want" = "$(norm_name "$bp_in_progress")" ]; then
    printf 'in-progress\n'
  elif [ "$want" = "$(norm_name "$bp_done")" ]; then
    printf 'done\n'
  else
    return 1
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
  local status_field todo in_progress done_col bp_todo bp_in_progress bp_done
  local queued big
  while IFS=$'\t' read -r project owner number repo label mention assignee \
    status_field todo in_progress done_col bp_todo bp_in_progress bp_done queued; do
    [ -n "$project" ] || continue
    if [ -n "$want" ] && [ "$want" != "$project" ]; then
      continue
    fi
    if [ "$bp_todo" = - ]; then
      big=off
    else
      big="$bp_todo|$bp_in_progress|$bp_done"
    fi
    printf 'board %s %s/%s repo=%s label=%s mention=%s assignee=%s field=%s columns=%s|%s|%s queued=%s big-picture=%s\n' \
      "$project" "$owner" "$number" "$repo" "$label" "$mention" "$assignee" \
      "$status_field" "$todo" "$in_progress" "$done_col" "$queued" "$big"
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

  # A container's children are the real work, so the container itself must never
  # spend the one binding an issue has. With poll never offering a big-picture
  # card for import, this closes the other direction.
  if decomps_find "$issue" >/dev/null; then
    die "$issue is a decomposition container on board \"$DECOMP_PROJECT\"; its children hold the work" 3
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

# --- shared placement -------------------------------------------------------
#
# `place` and `child-add` are one operation with different parents, so they run
# the same two steps here rather than two implementations that can drift.

CARD_STEP=

# card_ensure <project> <owner> <number> <status_field> <todo-column> <issue> <task>
# Card the issue, record the issue-to-task link, and set it to the ordinary Todo
# column. The link is written the moment the card exists so the next cycle can
# never offer it as new work, and its `synced` stays unconfirmed until the column
# write lands, which leaves poll's ordinary outstanding-write retry to finish it.
card_ensure() {
  local project=$1 owner=$2 number=$3 status_field=$4 column=$5 issue=$6 task=$7
  local item_id pr=- pr_synced=-
  CARD_STEP=
  item_id=$(board_item_add "$owner" "$number" "$issue") || {
    CARD_STEP=card
    return 1
  }
  if links_find issue "$issue" >/dev/null; then
    pr=$LINK_PR
    pr_synced=$LINK_PR_SYNCED
  fi
  links_put "$project" "$issue" "$task" todo other "$pr" "$pr_synced"
  if ! board_write_status "$owner" "$number" "$status_field" "$item_id" "$issue" "$column"; then
    CARD_STEP=status
    return 1
  fi
  links_put "$project" "$issue" "$task" todo todo "$pr" "$pr_synced"
  return 0
}

# issue_ensure <repo> <label> <title> <body> <task> <parent|-> <known-url|->
# Print the issue that carries this task's work, creating it only when neither
# the caller's own record nor a shallow scan of the repo's newest issues already
# holds one. A scan that cannot run stops the command instead of creating, so a
# transient read failure can never file the same work twice.
issue_ensure() {
  local repo=$1 label=$2 title=$3 body=$4 task=$5 parent=$6 known=$7 url rc=0
  if [ "$known" != - ]; then
    printf '%s\n' "$known"
    return 0
  fi
  url=$(issue_find_by_marker "$repo" "$task") || rc=$?
  case "$rc" in
    0)
      printf '%s\n' "$url"
      return 0
      ;;
    # A scan that could not run is not the same answer as one that found
    # nothing, so it refuses rather than risk filing a second issue.
    1) ;;
    *) return 1 ;;
  esac
  issue_create "$repo" "$label" "$title" "$body" "$parent"
}

cmd_place() {
  local project='' task='' title='' body=- lands_in=-
  local board owner number repo label status_field todo issue
  local PLACE_USAGE='usage: fm-board.sh place <project> <task-id> <title> [<body>] [--lands-in <owner/name>]'

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --lands-in)
        [ "$#" -gt 1 ] || die "--lands-in needs a value"
        lands_in=$2
        shift 2
        ;;
      --lands-in=*)
        lands_in=${1#--lands-in=}
        shift
        ;;
      -*) die "unknown option \"$1\"" ;;
      *)
        if [ -z "$project" ]; then
          project=$1
        elif [ -z "$task" ]; then
          task=$1
        elif [ -z "$title" ]; then
          title=$1
        elif [ "$body" = - ]; then
          body=$1
        else
          die "$PLACE_USAGE"
        fi
        shift
        ;;
    esac
  done
  if [ -z "$project" ] || [ -z "$task" ] || [ -z "$title" ]; then
    die "$PLACE_USAGE"
  fi
  task_id_valid "$task" || die "\"$task\" is not a task id"
  if [ "$lands_in" != - ]; then
    case "$lands_in" in
      */*/* | */ | /* | *' '*) die "--lands-in \"$lands_in\" is not owner/name" ;;
      */*) ;;
      *) die "--lands-in \"$lands_in\" is not owner/name" ;;
    esac
  fi

  board=$(board_for "$project")
  owner=$(printf '%s' "$board" | cut -f2)
  number=$(printf '%s' "$board" | cut -f3)
  repo=$(printf '%s' "$board" | cut -f4)
  label=$(printf '%s' "$board" | cut -f5)
  status_field=$(printf '%s' "$board" | cut -f8)
  todo=$(printf '%s' "$board" | cut -f9)

  # A task that already holds a link is finished, and says so without a single
  # network call: the link is written last precisely so that holding one proves
  # every earlier step landed.
  if links_find task "$task" >/dev/null; then
    printf 'already-placed %s %s %s\n' "$LINK_PROJECT" "$LINK_ISSUE" "$task"
    return 0
  fi
  [ "$repo" != - ] \
    || die "board \"$project\" has no repo key, so there is no repository to file a card in"

  issue=$(issue_ensure "$repo" "$label" "$title" \
    "$(issue_body "$body" "$task" "$lands_in")" "$task" - -) || {
    printf 'error: could not create the issue for task %s in %s\n' "$task" "$repo" >&2
    return 1
  }
  if card_ensure "$project" "$owner" "$number" "$status_field" "$todo" "$issue" "$task"; then
    printf 'placed %s %s %s\n' "$project" "$issue" "$task"
  else
    printf 'placed-partial %s %s %s %s\n' "$project" "$issue" "$task" "$CARD_STEP"
  fi
  return 0
}

cmd_child_add() {
  local project=${1:?usage: fm-board.sh child-add <project> <parent-issue-url> <title> <body> <task-id>}
  local raw_parent=${2:?usage: fm-board.sh child-add <project> <parent-issue-url> <title> <body> <task-id>}
  local title=${3:?usage: fm-board.sh child-add <project> <parent-issue-url> <title> <body> <task-id>}
  local body=${4:?usage: fm-board.sh child-add <project> <parent-issue-url> <title> <body> <task-id>}
  local task=${5:?usage: fm-board.sh child-add <project> <parent-issue-url> <title> <body> <task-id>}
  local board owner number repo label status_field todo bp_todo
  local parent known child state desired synced children

  board=$(board_for "$project")
  owner=$(printf '%s' "$board" | cut -f2)
  number=$(printf '%s' "$board" | cut -f3)
  repo=$(printf '%s' "$board" | cut -f4)
  label=$(printf '%s' "$board" | cut -f5)
  status_field=$(printf '%s' "$board" | cut -f8)
  todo=$(printf '%s' "$board" | cut -f9)
  bp_todo=$(printf '%s' "$board" | cut -f12)
  [ "$bp_todo" != - ] \
    || die "board \"$project\" has no big-picture columns configured, so it has no containers to decompose"
  parent=$(issue_canonical "$raw_parent") || die "\"$raw_parent\" is not an issue URL"
  task_id_valid "$task" || die "\"$task\" is not a task id"
  # A container is work nobody can ship, so it must never hold the one binding an
  # issue has. Refusing here is the other half of poll never offering a
  # big-picture card for import.
  if links_find issue "$parent" >/dev/null; then
    die "$parent is linked to task $LINK_TASK, so it is ordinary work rather than a container" 3
  fi
  [ "$repo" != - ] || repo=$(issue_repo "$parent")

  if decomps_find "$parent" >/dev/null; then
    [ "$DECOMP_PROJECT" = "$project" ] \
      || die "$parent is already decomposed under project $DECOMP_PROJECT" 3
    state=$DECOMP_STATE
    desired=$DECOMP_DESIRED
    synced=$DECOMP_SYNCED
    children=$DECOMP_CHILDREN
  else
    state=open desired=- synced=- children=-
  fi

  known=$(children_child_for "$children" "$task") || known=-
  if [ "$known" = - ] && links_find task "$task" >/dev/null; then
    die "task $task is already linked to $LINK_ISSUE" 3
  fi
  if [ "$known" != - ] && links_find task "$task" >/dev/null; then
    printf 'already-child %s %s %s %s\n' "$project" "$parent" "$known" "$task"
    return 0
  fi

  child=$(issue_ensure "$repo" "$label" "$title" \
    "$(issue_body "$body" "$task" -)" "$task" "$parent" "$known") || {
    printf 'error: could not create the child issue for task %s under %s\n' "$task" "$parent" >&2
    return 1
  }
  # Recorded against the parent the instant it exists, so a run interrupted
  # before the card lands is resumed rather than repeated.
  children=$(children_add "$children" "$task" "$child")
  decomps_put "$project" "$parent" "$state" "$desired" "$synced" "$children"

  if card_ensure "$project" "$owner" "$number" "$status_field" "$todo" "$child" "$task"; then
    printf 'child %s %s %s %s\n' "$project" "$parent" "$child" "$task"
  else
    printf 'child-partial %s %s %s %s %s\n' "$project" "$parent" "$child" "$task" "$CARD_STEP"
  fi
  return 0
}

cmd_decomposed() {
  local project=${1:?usage: fm-board.sh decomposed <project> <parent-issue-url>}
  local raw_parent=${2:?usage: fm-board.sh decomposed <project> <parent-issue-url>}
  local parent
  board_for "$project" >/dev/null
  parent=$(issue_canonical "$raw_parent") || die "\"$raw_parent\" is not an issue URL"
  if decomps_find "$parent" >/dev/null; then
    [ "$DECOMP_PROJECT" = "$project" ] \
      || die "$parent is decomposed under project $DECOMP_PROJECT" 3
    decomps_put "$project" "$parent" 'done' "$DECOMP_DESIRED" \
      "$DECOMP_SYNCED" "$DECOMP_CHILDREN"
  else
    decomps_put "$project" "$parent" 'done' - - -
  fi
  printf 'decomposed %s %s\n' "$project" "$parent"
}

cmd_decompositions() {
  local want=${1:-} row
  while IFS= read -r row; do
    if [ -n "$want" ]; then
      case "$row" in
        "$want$TAB"*) ;;
        *) continue ;;
      esac
    fi
    printf '%s\n' "$row"
  done < <(decomps_rows)
}

cmd_mark() {
  local task='' state='' limit=$DEFAULT_LIMIT
  local project issue synced pr pr_synced board
  local owner number status_field todo in_progress done_col queued column

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
    todo | in-progress | 'done') ;;
    queued) ;;
    *) die "unknown board state \"$state\" (use todo, queued, in-progress, or done)" ;;
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
  queued=$(printf '%s' "$board" | cut -f15)
  column=$(state_column "$state" "$todo" "$in_progress" "$done_col" "$queued") \
    || die "board \"$project\" has no queued column configured"

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
# Classifies every card from the one board read it is handed, reports what
# firstmate has to act on, and retries writes the board has not taken yet. Every
# write below reuses a card id from that same read, so nothing here refetches the
# board per item.
poll_board() {
  local board=$1 limit=$2 items=$3
  local project owner number repo label mention assignee status_field todo in_progress done_col
  local bp_todo bp_in_progress bp_done queued
  local id type url status labels assignees title body
  local canonical task desired synced pr pr_synced board_state count=0
  local seen_file trigger column container
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
  bp_todo=$(printf '%s' "$board" | cut -f12)
  bp_in_progress=$(printf '%s' "$board" | cut -f13)
  bp_done=$(printf '%s' "$board" | cut -f14)
  queued=$(printf '%s' "$board" | cut -f15)

  seen_file=$(mktemp) || return 1
  while IFS=$TAB read -r id type url status labels assignees title body; do
    [ -n "$id" ] || continue
    count=$((count + 1))
    canonical=$(issue_canonical "$url") || continue
    # Presence on the board is established before any intake filter runs: a card
    # this cycle declines to import is still a card that has not left, and the
    # withdrawal scan below reads absence from this file.
    printf '%s\n' "$canonical" >> "$seen_file"
    board_state=$(column_state "$status" "$todo" "$in_progress" "$done_col" "$queued")

    if links_find issue "$canonical" >/dev/null; then
      # An issue another configured board already owns is a misconfiguration,
      # not something to reconcile. Re-homing it would point every later event at
      # the wrong board, so this one is named and left entirely alone.
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
      if [ "$board_state" = "$desired" ]; then
        # The board agrees. Record it as confirmed if a write was outstanding.
        if [ "$synced" != "$desired" ]; then
          links_put "$project" "$canonical" "$task" "$desired" "$desired" "$pr" "$pr_synced"
          synced=$desired
        fi
        printf 'linked %s %s %s %s\n' "$project" "$canonical" "$task" "$desired"
      elif [ "$desired" != "$synced" ] && [ "$board_state" = "$synced" ]; then
        # A write is outstanding and the board still shows the value this adapter
        # last confirmed, so this is its own lag rather than a change to it.
        column=$(state_column "$desired" "$todo" "$in_progress" "$done_col" "$queued") || column=
        if [ -n "$column" ] && board_write_status "$owner" "$number" "$status_field" "$id" "$canonical" "$column"; then
          links_put "$project" "$canonical" "$task" "$desired" "$desired" "$pr" "$pr_synced"
          synced=$desired
          printf 'synced %s %s %s %s\n' "$project" "$canonical" "$task" "$desired"
        else
          printf 'stale %s %s %s %s\n' "$project" "$canonical" "$task" "$desired"
        fi
      else
        # The card shows a status firstmate did not write. Firstmate's records are
        # the truth here, so this changes nothing on either side and is reported
        # for the captain rather than reconciled behind them.
        printf 'divergence %s %s %s %s %s %s\n' \
          "$project" "$canonical" "$task" "$desired" "$board_state" "$status"
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

    # Not linked. A card in a big-picture column is a container: its children
    # hold the work, so it is never intake and never binds a task.
    if container=$(bp_column_state "$status" "$bp_todo" "$bp_in_progress" "$bp_done"); then
      poll_container "$board" "$id" "$canonical" "$container" "$status" "$labels"
      continue
    fi

    # From here on this is intake alone. A draft card or a pull request is not a
    # real issue, and an issue outside the configured repo is not this board's
    # work to take.
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

  # A card that vanished from the board while firstmate was still executing it.
  # Two reads cannot tell absence apart from something else and so reconcile
  # nothing: a full page may have another page behind it, and a board that
  # answers with no cards at all while links are open is far more likely to be
  # a changed project number or a lost permission than every card being cleared
  # by hand.
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
      # withdrawal is already reconciled; neither is open.
      case "$l_desired" in
        todo | queued | in-progress) ;;
        *) continue ;;
      esac
      printf 'cancelled %s %s %s %s\n' "$project" "$l_issue" "$l_task" "$l_desired"
    done < <(links_rows)
  fi
  rm -f "$seen_file"
}

# poll_container <board-row> <card-id> <parent-issue> <container-state> <raw-status> <labels>
# A container is offered for decomposition until it is recorded as decomposed,
# and once it has children its own card follows their recorded states. A parent
# whose card already shows what firstmate recorded prints nothing at all, so a
# reconciled board stays silent.
poll_container() {
  local board=$1 id=$2 parent=$3 container=$4 raw=$5 labels=$6
  local project owner number label status_field bp_todo bp_in_progress bp_done
  local state desired synced children now column task child_state pair
  local any_in_progress='' any_open='' any_driven=''

  project=$(printf '%s' "$board" | cut -f1)
  owner=$(printf '%s' "$board" | cut -f2)
  number=$(printf '%s' "$board" | cut -f3)
  label=$(printf '%s' "$board" | cut -f5)
  status_field=$(printf '%s' "$board" | cut -f8)
  bp_todo=$(printf '%s' "$board" | cut -f12)
  bp_in_progress=$(printf '%s' "$board" | cut -f13)
  bp_done=$(printf '%s' "$board" | cut -f14)

  if decomps_find "$parent" >/dev/null; then
    if [ "$DECOMP_PROJECT" != "$project" ]; then
      printf 'foreign %s %s %s -\n' "$project" "$parent" "$DECOMP_PROJECT"
      return 0
    fi
    state=$DECOMP_STATE
    desired=$DECOMP_DESIRED
    synced=$DECOMP_SYNCED
    children=$DECOMP_CHILDREN
  else
    state=open desired=- synced=- children=-
    # Recorded the first time it is seen, not the first time it is decomposed.
    # `import` refuses any issue holding a decomposition record, so recording it
    # here is what makes a container structurally unable to bind a task rather
    # than merely never offered one.
    decomps_put "$project" "$parent" "$state" "$desired" "$synced" "$children"
  fi

  # Offering a container for decomposition repeats until `decomposed` closes it,
  # exactly as `new` repeats until `import` runs, so a decomposition interrupted
  # part way is finished rather than lost.
  if [ "$state" != 'done' ] && [ "$container" = todo ] && list_has "$labels" "$label"; then
    printf 'decompose %s %s\n' "$project" "$parent"
  fi

  [ "$children" != - ] || return 0

  # The parent's own column follows its children. A child recorded in a column
  # firstmate does not drive is left out entirely, so a withdrawn child cannot
  # hold its parent short of done forever.
  while IFS= read -r task; do
    child_state=todo
    if links_find task "$task" >/dev/null; then
      child_state=$LINK_DESIRED
    fi
    case "$child_state" in
      in-progress)
        any_driven=1
        any_in_progress=1
        ;;
      done) any_driven=1 ;;
      todo | queued)
        any_driven=1
        any_open=1
        ;;
      *) ;;
    esac
  done < <(children_tasks "$children")
  [ -n "$any_driven" ] || return 0
  if [ -n "$any_in_progress" ]; then
    now=in-progress
  elif [ -n "$any_open" ]; then
    now=todo
  else
    now='done'
  fi

  # A newly derived state is firstmate's own event, exactly like `mark` on an
  # ordinary card: it says what the card should show from now on.
  if [ "$desired" != "$now" ]; then
    desired=$now
    decomps_put "$project" "$parent" "$state" "$desired" "$synced" "$children"
  fi

  if [ "$container" = "$desired" ]; then
    # The card already shows it. Reconciled boards stay silent.
    if [ "$synced" != "$desired" ]; then
      decomps_put "$project" "$parent" "$state" "$desired" "$desired" "$children"
    fi
    return 0
  fi
  if [ "$desired" != "$synced" ] && { [ "$synced" = - ] || [ "$container" = "$synced" ]; }; then
    # A write this adapter owes: either it has never written this card, or the
    # card still shows the value it last confirmed.
    column=$(bp_state_column "$desired" "$bp_todo" "$bp_in_progress" "$bp_done") || return 0
    if board_write_status "$owner" "$number" "$status_field" "$id" "$parent" "$column"; then
      decomps_put "$project" "$parent" "$state" "$desired" "$desired" "$children"
      printf 'synced %s %s - %s\n' "$project" "$parent" "$desired"
    else
      printf 'stale %s %s - %s\n' "$project" "$parent" "$desired"
    fi
    return 0
  fi
  # The card shows a state firstmate never wrote.
  printf 'divergence %s %s - %s %s %s\n' "$project" "$parent" "$desired" "$container" "$raw"
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
  place) cmd_place "$@" ;;
  child-add) cmd_child_add "$@" ;;
  decomposed) cmd_decomposed "$@" ;;
  decompositions) cmd_decompositions "$@" ;;
  links) cmd_links "$@" ;;
  lookup) cmd_lookup "$@" ;;
  mark) cmd_mark "$@" ;;
  pr) cmd_pr "$@" ;;
  note) cmd_note "$@" ;;
  ack) cmd_ack "$@" ;;
  *) die "unknown command \"$VERB\" (see fm-board.sh --help)" ;;
esac
