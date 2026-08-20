#!/usr/bin/env bash
# tests/fm-board.test.sh - the board-to-backlog bridge's correctness properties.
#
# Four of these are load-bearing rather than incidental. Importing an issue twice
# must never produce two tasks, and the record that prevents it has to outlive
# the task it names. A card the captain moved is an instruction, so a sync that
# "corrects" it back is the defect this suite is written to catch. A board write
# that fails must degrade to a stale board instead of blocking delivery. And a
# withdrawn card must stop the work without touching it, so the cancellation case
# runs against a real repository with real unlanded changes and proves they
# survive.
#
# Every board here is invented for the case at hand - different owners, project
# numbers, labels, status fields, and column names - because the adapter is a
# firstmate capability rather than any one project's integration, and a fixture
# that reused one canonical board would not show that.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-board)

# --- fixture plumbing -------------------------------------------------------

# new_home <name>: create an isolated firstmate home with a stub GitHub CLI.
new_home() {
  local home
  home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/bin"
  cat > "$home/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ -n "${GH_FAIL:-}" ]; then
  case "$1 $2" in
    $GH_FAIL)
      printf 'simulated GitHub failure\n' >&2
      exit 1
      ;;
  esac
fi
case "$1 $2" in
  "project item-list") cat "$GH_ITEMS" ;;
  "project view") printf 'PVT_fixture\n' ;;
  "project field-list") cat "$GH_FIELDS" ;;
  "project item-edit")
    # Behave like the real board: the edit is visible to the next read.
    edit_id=''
    edit_option=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --id) edit_id=$2; shift 2 ;;
        --single-select-option-id) edit_option=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    edit_name=$(awk -F'\t' -v o="$edit_option" '$1 == "option" && $2 == o { print $3 }' "$GH_FIELDS")
    edit_tmp=$(mktemp)
    awk -F'\t' -v OFS='\t' -v id="$edit_id" -v s="$edit_name" \
      '$1 == id { $4 = s } { print }' "$GH_ITEMS" > "$edit_tmp"
    mv "$edit_tmp" "$GH_ITEMS"
    ;;
  "issue comment") : ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 9
    ;;
esac
SH
  chmod +x "$home/bin/gh"
  : > "$home/gh.log"
  : > "$home/items"
  : > "$home/fields"
  printf '%s\n' "$home"
}

# board <home> <args...>: run the adapter against that home.
board() {
  local home=$1
  shift
  FM_HOME="$home" \
  FM_CONFIG_OVERRIDE="$home/config" \
  FM_DATA_OVERRIDE="$home/data" \
  FM_BOARD_GH="$home/bin/gh" \
  GH_LOG="$home/gh.log" \
  GH_ITEMS="$home/items" \
  GH_FIELDS="$home/fields" \
  GH_FAIL="${GH_FAIL:-}" \
    "$BOARD" "$@"
}

# item <home> <id> <type> <url> <status> <labels> <assignees> <title> <body>
item() {
  local home=$1
  shift
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$home/items"
}

# fields <home> <field-id> <option-id:option-name>...
fields() {
  local home=$1 field=$2 spec
  shift 2
  printf 'field\t%s\n' "$field" > "$home/fields"
  for spec in "$@"; do
    printf 'option\t%s\t%s\n' "${spec%%:*}" "${spec#*:}" >> "$home/fields"
  done
}

gh_log() {
  cat "$1/gh.log"
}

# --- a board with an ordinary shape, and one with an unusual one -------------

ordinary_board() {
  local home=$1
  cat > "$home/config/boards" <<'EOF'
project = harbourlight
owner = harbour-collective
number = 4
label = firstmate
EOF
  fields "$home" PVTSSF_status opt_todo:Todo 'opt_prog:In Progress' opt_done:Done
}

unusual_board() {
  local home=$1
  cat > "$home/config/boards" <<'EOF'
project = tidewheel
owner = personal-account
number = 91
repo = personal-account/tidewheel
label = take-it-mate
mention = @deckhand
assignee = deckhand-bot
status-field = Lane
todo = Waiting
in-progress = Under Way
done = Landed
EOF
  fields "$home" PVTSSF_lane opt_wait:Waiting 'opt_under:Under Way' opt_landed:Landed
}

# --- configuration is the whole board identity ------------------------------

test_boards_are_configuration_not_convention() {
  local home out
  home=$(new_home boards_are_configuration_not_convention)
  ordinary_board "$home"
  cat >> "$home/config/boards" <<'EOF'

project = tidewheel
owner = personal-account
number = 91
label = take-it-mate
status-field = Lane
todo = Waiting
in-progress = Under Way
done = Landed
EOF
  out=$(board "$home" boards)
  assert_contains "$out" 'board harbourlight harbour-collective/4' "the first board is not listed"
  assert_contains "$out" 'board tidewheel personal-account/91' "the second board is not listed"
  assert_contains "$out" 'columns=Waiting|Under Way|Landed' "a board's own column names are not carried"
  assert_contains "$out" 'label=take-it-mate' "a board's own trigger label is not carried"

  home=$(new_home unconfigured_home)
  out=$(board "$home" boards)
  [ -z "$out" ] || fail "a home with no board configuration reported a board"
  out=$(board "$home" poll)
  [ -z "$out" ] || fail "a home with no board configuration polled something"
  pass "boards come entirely from local configuration, and an unconfigured home has none"
}

test_the_bridge_is_inert_until_a_board_is_configured() {
  local home out rc verb
  home=$(new_home the_bridge_is_inert_until_a_board_is_configured)
  [ ! -e "$home/config/boards" ] || fail "the fixture home already has board configuration"

  out=$(board "$home" boards)
  [ -z "$out" ] || fail "an unconfigured home listed a board: $out"
  out=$(board "$home" poll)
  [ -z "$out" ] || fail "an unconfigured home polled a board: $out"
  out=$(board "$home" links)
  [ -z "$out" ] || fail "an unconfigured home reported a link: $out"

  # Every verb that needs a board refuses, and none of them reaches GitHub.
  board "$home" lookup fm-nothing >/dev/null 2>&1 && rc=0 || rc=$?
  [ "$rc" != 0 ] || fail "an unconfigured home resolved a link"
  board "$home" import somewhere https://github.com/someone/app/issues/1 fm-x >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "an unconfigured home accepted an import"
  for verb in mark pr note ack; do
    board "$home" "$verb" fm-x https://github.com/someone/app/pull/1 >/dev/null 2>&1 && rc=0 || rc=$?
    [ "$rc" != 0 ] || fail "an unconfigured home accepted \"$verb\""
  done

  [ -z "$(gh_log "$home")" ] || fail "an unconfigured home called the GitHub CLI: $(gh_log "$home")"
  assert_absent "$home/data/board-links.tsv" "an unconfigured home created a link record"
  [ -z "$(ls -A "$home/state")" ] || fail "an unconfigured home created runtime state"

  # An empty configuration file is the same as no file at all.
  : > "$home/config/boards"
  out=$(board "$home" poll)
  [ -z "$out" ] || fail "an empty board configuration polled a board: $out"
  printf '# only a comment\n\n' > "$home/config/boards"
  out=$(board "$home" boards)
  [ -z "$out" ] || fail "a configuration with no stanza reported a board: $out"
  [ -z "$(gh_log "$home")" ] || fail "an empty board configuration called the GitHub CLI"
  pass "with no board configured the bridge reads nothing, writes nothing, and creates nothing"
}

test_removing_the_configuration_is_the_off_switch() {
  local home issue out before
  home=$(new_home removing_the_configuration_is_the_off_switch)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/130
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Runs while configured' -
  board "$home" import harbourlight "$issue" fm-configured >/dev/null
  board "$home" mark fm-configured in-progress >/dev/null
  [ -n "$(gh_log "$home")" ] || fail "the configured board never reached GitHub"

  rm -f "$home/config/boards"
  : > "$home/gh.log"
  out=$(board "$home" poll)
  [ -z "$out" ] || fail "the bridge still polled after its configuration was removed: $out"
  out=$(board "$home" boards)
  [ -z "$out" ] || fail "the bridge still reported a board after its configuration was removed"
  [ -z "$(gh_log "$home")" ] || fail "the bridge called GitHub after its configuration was removed"

  # No residue: the only artifact is the durable link record, and it is inert.
  before=$(cat "$home/data/board-links.tsv")
  [ -z "$(ls -A "$home/state")" ] || fail "disabling left runtime state behind"
  assert_absent "$home/config/x-mode.env" "disabling left a generated cadence file behind"
  board "$home" poll >/dev/null
  [ "$(cat "$home/data/board-links.tsv")" = "$before" ] || fail "a disabled bridge still rewrote its record"

  # And disabling is not an undo: what was already imported is still recorded.
  assert_contains "$before" 'fm-configured' "disabling erased an import that had already happened"
  pass "removing the configuration disables the bridge with no residue, and undoes nothing already done"
}

test_malformed_configuration_is_an_actionable_error() {
  local home out rc
  home=$(new_home malformed_configuration_is_an_actionable_error)
  printf 'project = alpha\nowner = someone\n' > "$home/config/boards"
  out=$(board "$home" poll 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "a board with no project number was accepted"
  assert_contains "$out" 'has no number' "the missing project number was not named"

  printf 'project = alpha\nowner = someone\nnumber = 4\ncolumn = Todo\n' > "$home/config/boards"
  out=$(board "$home" poll 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "an unknown configuration key was accepted"
  assert_contains "$out" 'unknown key "column"' "the unknown key was not named"

  printf 'project = alpha\nowner = someone\nnumber = four\n' > "$home/config/boards"
  out=$(board "$home" poll 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "a non-numeric project number was accepted"
  pass "malformed board configuration is refused with the reason, not guessed around"
}

# --- intake -----------------------------------------------------------------

test_only_projects_with_a_board_are_ever_mapped() {
  local home issue out rc log
  home=$(new_home only_projects_with_a_board_are_ever_mapped)
  # Two projects in one home: one has a board, the other deliberately does not.
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/140
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'On the board' -
  board "$home" import harbourlight "$issue" fm-onboard >/dev/null
  : > "$home/gh.log"

  # Work on a project with no board has nowhere to go, and nothing is touched.
  out=$(board "$home" import elsewhere https://github.com/other-org/elsewhere/issues/1 fm-elsewhere 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "a project with no configured board was mapped to one"
  assert_contains "$out" 'no board configured for project "elsewhere"' \
    "the refusal did not name the unconfigured project"
  board "$home" mark fm-elsewhere in-progress >/dev/null 2>&1 && rc=0 || rc=$?
  [ "$rc" != 0 ] || fail "a task from a project with no board was moved on a board"
  board "$home" note fm-elsewhere 'Blocked: nothing' >/dev/null 2>&1 && rc=0 || rc=$?
  [ "$rc" != 0 ] || fail "a task from a project with no board commented on an issue"
  [ -z "$(gh_log "$home")" ] || fail "work on a project with no board reached GitHub: $(gh_log "$home")"
  out=$(board "$home" poll)
  assert_not_contains "$out" 'elsewhere' "polling reported a project that has no board"

  # A second, differently configured board never receives the first one's work.
  cat >> "$home/config/boards" <<'EOF'

project = tidewheel
owner = personal-account
number = 91
EOF
  : > "$home/gh.log"
  board "$home" mark fm-onboard in-progress >/dev/null
  log=$(gh_log "$home")
  assert_contains "$log" '--owner harbour-collective' "the event did not resolve its own project's board"
  assert_not_contains "$log" 'personal-account' "the event reached another project's board"
  assert_not_contains "$log" 'project item-list 91' "the event read another project's board"
  pass "only a project with a configured board is mapped, and boards never cross"
}

test_only_tagged_todo_issues_are_importable() {
  local home out
  home=$(new_home only_tagged_todo_issues_are_importable)
  unusual_board "$home"
  item "$home" PVTI_a Issue https://github.com/personal-account/tidewheel/issues/1 \
    Waiting take-it-mate - 'Tagged and waiting' 'ordinary body'
  item "$home" PVTI_b DraftIssue - Waiting take-it-mate - 'A draft card' -
  item "$home" PVTI_c PullRequest https://github.com/personal-account/tidewheel/pull/2 \
    Waiting take-it-mate - 'A pull request' -
  item "$home" PVTI_d Issue https://github.com/personal-account/tidewheel/issues/3 \
    'Under Way' take-it-mate - 'Tagged but already moved' -
  item "$home" PVTI_e Issue https://github.com/personal-account/tidewheel/issues/4 \
    Waiting - - 'Waiting but untagged' 'no trigger here'
  item "$home" PVTI_f Issue https://github.com/personal-account/tidewheel/issues/5 \
    Waiting - - 'Mentioned instead' 'hey @deckhand take this'
  item "$home" PVTI_g Issue https://github.com/personal-account/tidewheel/issues/6 \
    Waiting - deckhand-bot 'Assigned instead' -
  item "$home" PVTI_h Issue https://github.com/other-org/elsewhere/issues/7 \
    Waiting take-it-mate - 'Another repo on the same board' -

  out=$(board "$home" poll)
  assert_contains "$out" 'new tidewheel https://github.com/personal-account/tidewheel/issues/1 label' \
    "a tagged issue waiting in the first column is not importable"
  assert_contains "$out" 'issues/5 mention' "the optional mention trigger did not fire"
  assert_contains "$out" 'issues/6 assignee' "the optional assignee trigger did not fire"
  assert_not_contains "$out" 'A draft card' "a draft card was offered as importable work"
  assert_not_contains "$out" 'pull/2' "a pull request was offered as importable work"
  assert_not_contains "$out" 'issues/3' "an issue already past the first column was offered for import"
  assert_not_contains "$out" 'issues/4' "an untagged issue was offered for import"
  assert_not_contains "$out" 'other-org' "an issue outside the configured repo was offered for import"
  pass "intake takes real issues, in the first column, carrying the configured trigger"
}

test_mention_and_assignee_triggers_are_off_by_default() {
  local home out
  home=$(new_home mention_and_assignee_triggers_are_off_by_default)
  ordinary_board "$home"
  item "$home" PVTI_a Issue https://github.com/harbour-collective/app/issues/1 \
    Todo - - 'Only mentioned' 'please @firstmate take this'
  item "$home" PVTI_b Issue https://github.com/harbour-collective/app/issues/2 \
    Todo - firstmate 'Only assigned' -
  out=$(board "$home" poll)
  [ -z "$out" ] || fail "an unconfigured mention or assignee trigger fired anyway: $out"
  pass "the label is the authoritative trigger; mention and assignee stay off unless configured"
}

# --- idempotent import ------------------------------------------------------

test_importing_the_same_issue_twice_is_a_no_op() {
  local home out rc issue
  home=$(new_home importing_the_same_issue_twice_is_a_no_op)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/12
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Add a mooring' -

  out=$(board "$home" import harbourlight "$issue" fm-mooring)
  assert_contains "$out" "linked harbourlight $issue fm-mooring" "the first import did not link"

  out=$(board "$home" import harbourlight "$issue" fm-mooring) && rc=0 || rc=$?
  expect_code 0 "$rc" "re-importing an already-linked issue failed instead of being a no-op"
  assert_contains "$out" 'already-linked' "the repeat import was not reported as already linked"
  [ "$(board "$home" links | wc -l)" = 1 ] || fail "re-importing produced a second linkage record"

  out=$(board "$home" poll)
  assert_not_contains "$out" 'new harbourlight' "an already-linked issue was offered for import again"
  assert_contains "$out" "linked harbourlight $issue fm-mooring todo" "the linked issue was not reported as linked"

  out=$(board "$home" import harbourlight "$issue" fm-different 2>&1) && rc=0 || rc=$?
  expect_code 3 "$rc" "relinking an issue to a different task was allowed"
  assert_contains "$out" 'already linked to task fm-mooring' "the refusal did not name the existing task"
  [ "$(board "$home" links | wc -l)" = 1 ] || fail "a refused relink still wrote a record"
  pass "one issue holds one task: repeat import is a no-op and a conflicting relink is refused"
}

test_the_link_outlives_the_task_it_names() {
  local home out issue
  home=$(new_home the_link_outlives_the_task_it_names)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/20
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Long-lived work' -
  board "$home" import harbourlight "$issue" fm-longlived >/dev/null

  # Everything a finished task leaves in state/ goes away at cleanup.
  printf 'window=x\n' > "$home/state/fm-longlived.meta"
  printf 'done: shipped\n' > "$home/state/fm-longlived.status"
  rm -rf "$home/state"

  out=$(board "$home" lookup "$issue") || fail "the link did not survive task cleanup"
  assert_contains "$out" 'fm-longlived' "the surviving link lost its task identity"
  out=$(board "$home" poll)
  assert_not_contains "$out" 'new harbourlight' "a torn-down task's issue became importable again"
  pass "the linkage record lives with the durable fleet records and survives task cleanup"
}

# --- status transitions driven by execution events --------------------------

test_transitions_follow_firstmate_execution_events() {
  local home issue out log
  home=$(new_home transitions_follow_firstmate_execution_events)
  unusual_board "$home"
  issue=https://github.com/personal-account/tidewheel/issues/8
  item "$home" PVTI_a Issue "$issue" Waiting take-it-mate - 'Ship it' -
  board "$home" import tidewheel "$issue" fm-ship >/dev/null
  assert_contains "$(board "$home" lookup fm-ship)" "	todo	todo	" "a fresh import did not start in the first column"

  # Dispatch.
  out=$(board "$home" mark fm-ship in-progress)
  assert_contains "$out" "synced tidewheel $issue fm-ship in-progress" "dispatch did not move the card"
  log=$(gh_log "$home")
  assert_contains "$log" 'project item-edit --id PVTI_a --project-id PVT_fixture --field-id PVTSSF_lane --single-select-option-id opt_under' \
    "the dispatch write did not set this board's own In Progress option"

  # Merge.
  : > "$home/gh.log"
  out=$(board "$home" mark fm-ship 'done')
  assert_contains "$out" "synced tidewheel $issue fm-ship done" "the merge did not move the card"
  assert_contains "$(gh_log "$home")" '--single-select-option-id opt_landed' \
    "the merge write did not set this board's own Done option"
  assert_contains "$(board "$home" lookup fm-ship)" "	done	done	" "the record did not follow the card"
  pass "Todo, In Progress, and Done are driven by dispatch and merge, on the board's own column names"
}

test_a_column_firstmate_does_not_drive_is_recorded_not_invented() {
  local home issue out rc
  home=$(new_home a_column_firstmate_does_not_drive_is_recorded_not_invented)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/30
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Parked work' -
  board "$home" import harbourlight "$issue" fm-parked >/dev/null

  : > "$home/items"
  item "$home" PVTI_a Issue "$issue" 'Needs Review' firstmate - 'Parked work' -
  out=$(board "$home" poll)
  assert_contains "$out" "instruction harbourlight $issue fm-parked todo other Needs Review" \
    "a column outside the three did not surface as an instruction carrying its own name"
  assert_contains "$(board "$home" lookup fm-parked)" "	other	other	" \
    "the captain's own column was not recorded"

  out=$(board "$home" mark fm-parked blocked 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "the adapter accepted a fourth execution state"
  pass "a column the captain added is recorded as the board's own, never as a fourth state to drive"
}

# --- PR linkage -------------------------------------------------------------

test_the_pull_request_is_attached_to_the_originating_issue() {
  local home issue pr out
  home=$(new_home the_pull_request_is_attached_to_the_originating_issue)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/40
  pr=https://github.com/harbour-collective/app/pull/41
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Needs a PR' -
  board "$home" import harbourlight "$issue" fm-pr >/dev/null

  out=$(board "$home" pr fm-pr "$pr")
  assert_contains "$out" "attached harbourlight $issue fm-pr $pr" "the PR was not attached"
  assert_contains "$(gh_log "$home")" "issue comment $issue --body Working PR: $pr" \
    "the PR link did not land on the originating issue"
  assert_contains "$(board "$home" lookup fm-pr)" "$pr" "the PR was not recorded against the link"

  : > "$home/gh.log"
  out=$(board "$home" pr fm-pr "$pr")
  assert_contains "$out" 'already-attached' "re-attaching the same PR was not a no-op"
  [ -z "$(gh_log "$home")" ] || fail "re-attaching the same PR commented on the issue a second time"
  pass "the working PR is attached to the issue that started the work, once"
}

test_a_blocker_is_recorded_on_the_issue() {
  local home issue out
  home=$(new_home a_blocker_is_recorded_on_the_issue)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/50
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Will block' -
  board "$home" import harbourlight "$issue" fm-blocked >/dev/null
  board "$home" mark fm-blocked in-progress >/dev/null

  out=$(board "$home" note fm-blocked 'Blocked: the staging credential expired')
  assert_contains "$out" "noted harbourlight $issue fm-blocked" "the blocker was not recorded"
  assert_contains "$(gh_log "$home")" 'issue comment '"$issue"' --body Blocked: the staging credential expired' \
    "the blocker did not land on the issue"
  out=$(board "$home" poll)
  assert_contains "$out" "linked harbourlight $issue fm-blocked in-progress" \
    "a blocked item stopped being visible on the board"
  pass "a blocker is recorded on the issue while the item stays visible where it is"
}

# --- the board owns intent --------------------------------------------------

test_a_captain_board_edit_is_an_instruction_never_a_correction() {
  local home issue out log
  home=$(new_home a_captain_board_edit_is_an_instruction_never_a_correction)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/60
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Reprioritized work' -
  board "$home" import harbourlight "$issue" fm-repri >/dev/null
  board "$home" mark fm-repri in-progress >/dev/null

  # The captain pulls the card back to the first column.
  : > "$home/items"
  : > "$home/gh.log"
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Reprioritized work' -
  out=$(board "$home" poll)
  assert_contains "$out" "instruction harbourlight $issue fm-repri in-progress todo Todo" \
    "the captain's move backwards was not surfaced as an instruction"
  log=$(gh_log "$home")
  assert_not_contains "$log" 'item-edit' "the sync tried to correct the captain's own board edit"
  assert_contains "$(board "$home" lookup fm-repri)" "	todo	todo	" \
    "the record did not reconcile to the captain's board"

  # And it stays reconciled rather than drifting back on the next cycle.
  out=$(board "$home" poll)
  assert_contains "$out" "linked harbourlight $issue fm-repri todo" "the reconciled state did not hold"
  pass "a captain's board edit reconciles the record and is never written back over"
}

test_a_withdrawn_card_stops_the_work_without_touching_it() {
  local home issue out repo before after
  home=$(new_home a_withdrawn_card_stops_the_work_without_touching_it)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/70
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Withdrawn work' -
  board "$home" import harbourlight "$issue" fm-withdrawn >/dev/null
  board "$home" mark fm-withdrawn in-progress >/dev/null

  # A real worktree with real unlanded work, exactly what a cancellation must
  # never cost.
  repo="$home/work"
  fm_git_init_commit "$repo"
  git -C "$repo" checkout -q -b fm/withdrawn-work
  printf 'half-finished\n' > "$repo/feature.txt"
  before=$(git -C "$repo" status --porcelain)

  : > "$home/items"
  : > "$home/gh.log"
  item "$home" PVTI_other Issue https://github.com/harbour-collective/app/issues/71 \
    Done - - 'Something else on the board' -
  out=$(board "$home" poll)
  assert_contains "$out" "cancelled harbourlight $issue fm-withdrawn in-progress" \
    "a card that left the board was not reported as withdrawn"
  assert_not_contains "$(gh_log "$home")" 'item-edit' "the withdrawal triggered a board write"

  board "$home" ack fm-withdrawn >/dev/null
  after=$(git -C "$repo" status --porcelain)
  [ "$before" = "$after" ] || fail "unlanded work changed while reconciling a withdrawn card"
  assert_present "$repo/feature.txt" "unlanded work was removed while reconciling a withdrawn card"
  git -C "$repo" rev-parse --verify -q fm/withdrawn-work >/dev/null \
    || fail "the branch was removed while reconciling a withdrawn card"

  out=$(board "$home" poll)
  assert_not_contains "$out" 'cancelled' "an acknowledged withdrawal kept being reported"
  out=$(board "$home" lookup "$issue") || fail "the link was dropped when the card was withdrawn"
  pass "a withdrawn card is reported until reconciled, and never costs unlanded work"
}

test_a_completed_card_leaving_the_board_is_not_a_withdrawal() {
  local home issue out
  home=$(new_home a_completed_card_leaving_the_board_is_not_a_withdrawal)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/80
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Finished work' -
  board "$home" import harbourlight "$issue" fm-finished >/dev/null
  board "$home" mark fm-finished 'done' >/dev/null
  : > "$home/items"
  item "$home" PVTI_other Issue https://github.com/harbour-collective/app/issues/81 \
    Todo - - 'Something else on the board' -
  out=$(board "$home" poll)
  assert_not_contains "$out" 'cancelled' "archiving a finished card was reported as a withdrawal"
  pass "archiving a finished card is ordinary housekeeping, not a withdrawal"
}

# --- fail soft --------------------------------------------------------------

test_a_failed_board_write_never_blocks_delivery() {
  local home issue out rc
  home=$(new_home a_failed_board_write_never_blocks_delivery)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/90
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Ships anyway' -
  board "$home" import harbourlight "$issue" fm-ships >/dev/null

  out=$(GH_FAIL='project item-edit' board "$home" mark fm-ships in-progress 2>/dev/null) && rc=0 || rc=$?
  expect_code 0 "$rc" "a failed board write stopped the dispatch"
  assert_contains "$out" "stale harbourlight $issue fm-ships in-progress" \
    "the failed write was not reported as a stale board"
  assert_contains "$(board "$home" lookup fm-ships)" "	in-progress	todo	" \
    "the failed write was not left outstanding for the next cycle"

  out=$(GH_FAIL='issue comment' board "$home" pr fm-ships https://github.com/harbour-collective/app/pull/91 2>/dev/null) && rc=0 || rc=$?
  expect_code 0 "$rc" "a failed PR comment stopped the delivery report"
  assert_contains "$out" 'stale' "the failed PR comment was not reported as a stale board"

  out=$(GH_FAIL='issue comment' board "$home" note fm-ships 'Blocked: nothing' 2>/dev/null) && rc=0 || rc=$?
  expect_code 0 "$rc" "a failed blocker note stopped the cycle"

  # The next cycle reconciles what the failed write left behind.
  out=$(board "$home" poll)
  assert_contains "$out" "synced harbourlight $issue fm-ships in-progress" \
    "the next cycle did not retry the outstanding board write"
  assert_contains "$(board "$home" lookup fm-ships)" "	in-progress	in-progress	" \
    "the retried write was not recorded as confirmed"
  pass "board writes degrade to a stale board and reconcile on the next cycle"
}

test_a_failed_board_read_never_blocks_the_cycle() {
  local home out rc
  home=$(new_home a_failed_board_read_never_blocks_the_cycle)
  ordinary_board "$home"
  item "$home" PVTI_a Issue https://github.com/harbour-collective/app/issues/100 \
    Todo firstmate - 'Unreadable today' -
  out=$(GH_FAIL='project item-list' board "$home" poll 2>/dev/null) && rc=0 || rc=$?
  expect_code 0 "$rc" "a board read failure stopped the cycle"
  assert_contains "$out" 'error harbourlight could not read project harbour-collective/4' \
    "the board read failure was not reported"
  assert_not_contains "$out" 'cancelled' "an unreadable board was mistaken for withdrawn work"
  pass "an unreadable board is reported and retried, never mistaken for withdrawn work"
}

test_an_empty_board_is_not_taken_as_mass_withdrawal() {
  local home out
  home=$(new_home an_empty_board_is_not_taken_as_mass_withdrawal)
  ordinary_board "$home"
  item "$home" PVTI_a Issue https://github.com/harbour-collective/app/issues/120 \
    Todo firstmate - 'Still open' -
  board "$home" import harbourlight https://github.com/harbour-collective/app/issues/120 fm-open >/dev/null

  # The board answers successfully with nothing at all - a changed project
  # number or a lost permission looks exactly like this.
  : > "$home/items"
  out=$(board "$home" poll)
  assert_contains "$out" 'error harbourlight the board returned no cards while links are open' \
    "an empty board read was not reported"
  assert_not_contains "$out" 'cancelled' "an empty board read was taken as withdrawing every card"
  assert_contains "$(board "$home" lookup fm-open)" '	todo	todo	' "an empty board read changed a record"
  pass "a board that answers with nothing while links are open is reported, not obeyed"
}

test_a_truncated_read_reconciles_nothing() {
  local home out
  home=$(new_home a_truncated_read_reconciles_nothing)
  ordinary_board "$home"
  item "$home" PVTI_a Issue https://github.com/harbour-collective/app/issues/110 \
    Todo firstmate - 'First' -
  item "$home" PVTI_b Issue https://github.com/harbour-collective/app/issues/111 \
    Todo firstmate - 'Second' -
  board "$home" import harbourlight https://github.com/harbour-collective/app/issues/999 fm-offpage >/dev/null
  out=$(board "$home" poll --limit 2)
  assert_contains "$out" 'truncated harbourlight 2' "a full page was not reported as possibly truncated"
  assert_not_contains "$out" 'cancelled' "a page boundary was mistaken for a withdrawn card"
  pass "a page boundary is never mistaken for absence"
}

test_a_card_an_intake_filter_skips_is_not_a_withdrawal() {
  local home issue out
  home=$(new_home a_card_an_intake_filter_skips_is_not_a_withdrawal)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/150
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Filtered but plainly there' -
  board "$home" import harbourlight "$issue" fm-filtered >/dev/null
  board "$home" mark fm-filtered in-progress >/dev/null

  # The captain narrows the board to one repository after the import, so the
  # intake repo filter now skips a card that has not moved at all.
  cat > "$home/config/boards" <<'EOF'
project = harbourlight
owner = harbour-collective
number = 4
repo = harbour-collective/somewhere-else
label = firstmate
EOF
  out=$(board "$home" poll)
  assert_not_contains "$out" 'cancelled' "a card the repo filter skips was reported as withdrawn"
  assert_contains "$out" "linked harbourlight $issue fm-filtered in-progress" \
    "a card the repo filter skips stopped being reconciled"

  # A card whose type intake does not recognize is still a card on the board.
  ordinary_board "$home"
  : > "$home/items"
  item "$home" PVTI_a ISSUE "$issue" 'In Progress' firstmate - 'Filtered but plainly there' -
  out=$(board "$home" poll)
  assert_not_contains "$out" 'cancelled' "a card the type filter skips was reported as withdrawn"
  assert_contains "$(board "$home" lookup fm-filtered)" "	in-progress	in-progress	" \
    "a skipped card's record was changed"
  pass "an intake filter decides what is importable, never what is still on the board"
}

test_an_issue_another_board_owns_is_skipped_not_re_homed() {
  local home issue out log
  home=$(new_home an_issue_another_board_owns_is_skipped_not_re_homed)
  ordinary_board "$home"
  cat >> "$home/config/boards" <<'EOF'

project = tidewheel
owner = personal-account
number = 91
EOF
  issue=https://github.com/harbour-collective/app/issues/160
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'The first board owns this' -
  board "$home" import harbourlight "$issue" fm-owned >/dev/null
  board "$home" mark fm-owned in-progress >/dev/null

  # Both boards now answer with the same card, which is the misconfiguration.
  : > "$home/gh.log"
  out=$(board "$home" poll)
  assert_contains "$out" "foreign tidewheel $issue harbourlight fm-owned" \
    "a card another board owns was not reported with the project that owns it"
  assert_not_contains "$out" 'new tidewheel' "a card another board owns was offered for import"
  assert_not_contains "$out" 'cancelled' "a card another board owns was read as a withdrawal"
  assert_not_contains "$(gh_log "$home")" 'item-edit' "polling a card another board owns wrote to a board"
  assert_contains "$(board "$home" lookup fm-owned)" "harbourlight	$issue" \
    "the link was re-homed to the board that does not own the issue"

  # And every later event still resolves the board that does own it.
  : > "$home/gh.log"
  board "$home" mark fm-owned 'done' >/dev/null
  log=$(gh_log "$home")
  assert_contains "$log" '--owner harbour-collective' "a later event stopped resolving the owning board"
  assert_not_contains "$log" 'personal-account' "a later event reached the board that does not own the issue"
  pass "an issue another board owns is named and left alone, never silently re-homed"
}

test_an_outstanding_pr_attachment_is_retried_on_the_next_cycle() {
  local home issue pr out
  home=$(new_home an_outstanding_pr_attachment_is_retried_on_the_next_cycle)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/170
  pr=https://github.com/harbour-collective/app/pull/171
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'Reports a PR' -
  board "$home" import harbourlight "$issue" fm-latepr >/dev/null

  out=$(GH_FAIL='issue comment' board "$home" pr fm-latepr "$pr" 2>/dev/null)
  assert_contains "$out" "stale harbourlight $issue fm-latepr $pr" \
    "the failed attachment was not reported as a stale board"
  assert_contains "$(board "$home" lookup fm-latepr)" "$pr	0" \
    "the failed attachment was not left outstanding for the next cycle"

  : > "$home/gh.log"
  out=$(board "$home" poll)
  assert_contains "$out" "synced harbourlight $issue fm-latepr $pr" \
    "the next cycle did not retry the outstanding PR attachment"
  assert_contains "$(gh_log "$home")" "issue comment $issue --body Working PR: $pr" \
    "the retry did not land the PR link on the originating issue"
  assert_contains "$(board "$home" lookup fm-latepr)" "$pr	1" \
    "the retried attachment was not recorded as confirmed"

  : > "$home/gh.log"
  board "$home" poll >/dev/null
  assert_not_contains "$(gh_log "$home")" 'issue comment' \
    "a confirmed attachment was posted onto the issue again"
  pass "an outstanding PR attachment is retried until the issue has it, then left alone"
}

test_mark_reads_the_board_under_the_limit_it_is_given() {
  local home issue out rc
  home=$(new_home mark_reads_the_board_under_the_limit_it_is_given)
  ordinary_board "$home"
  issue=https://github.com/harbour-collective/app/issues/180
  item "$home" PVTI_a Issue "$issue" Todo firstmate - 'On a crowded board' -
  board "$home" import harbourlight "$issue" fm-crowded >/dev/null

  : > "$home/gh.log"
  board "$home" mark fm-crowded in-progress >/dev/null
  assert_contains "$(gh_log "$home")" 'project item-list 4 --owner harbour-collective --limit 200' \
    "the default card lookup limit changed"

  : > "$home/gh.log"
  board "$home" mark fm-crowded 'done' --limit 500 >/dev/null
  assert_contains "$(gh_log "$home")" '--limit 500' "mark ignored the lookup limit it was given"

  out=$(board "$home" mark fm-crowded todo --limit 0 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "mark accepted a lookup limit of zero"
  assert_contains "$out" 'positive number' "the refused lookup limit was not explained"
  pass "mark looks a card up under a limit it exposes, the same way poll does"
}

# --- run --------------------------------------------------------------------

test_boards_are_configuration_not_convention
test_the_bridge_is_inert_until_a_board_is_configured
test_removing_the_configuration_is_the_off_switch
test_malformed_configuration_is_an_actionable_error
test_only_projects_with_a_board_are_ever_mapped
test_only_tagged_todo_issues_are_importable
test_mention_and_assignee_triggers_are_off_by_default
test_importing_the_same_issue_twice_is_a_no_op
test_the_link_outlives_the_task_it_names
test_transitions_follow_firstmate_execution_events
test_a_column_firstmate_does_not_drive_is_recorded_not_invented
test_the_pull_request_is_attached_to_the_originating_issue
test_a_blocker_is_recorded_on_the_issue
test_a_captain_board_edit_is_an_instruction_never_a_correction
test_a_withdrawn_card_stops_the_work_without_touching_it
test_a_completed_card_leaving_the_board_is_not_a_withdrawal
test_a_failed_board_write_never_blocks_delivery
test_a_failed_board_read_never_blocks_the_cycle
test_an_empty_board_is_not_taken_as_mass_withdrawal
test_a_truncated_read_reconciles_nothing
test_a_card_an_intake_filter_skips_is_not_a_withdrawal
test_an_issue_another_board_owns_is_skipped_not_re_homed
test_an_outstanding_pr_attachment_is_retried_on_the_next_cycle
test_mark_reads_the_board_under_the_limit_it_is_given
