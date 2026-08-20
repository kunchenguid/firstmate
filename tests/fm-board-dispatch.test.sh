#!/usr/bin/env bash
# tests/fm-board-dispatch.test.sh - firstmate's own execution events reach a
# configured board without anyone remembering to run a second command.
#
# The property under test is deliberately narrow and load-bearing: dispatching
# work for a board-mapped project must leave a card on the board, in one
# operation, and a home with no board configured must be completely unaffected -
# no card, no issue, and not one call to the GitHub CLI. The board write must
# also never be able to fail, delay, or alter the dispatch itself, so the failure
# case here drives a board that refuses every write and asserts the crew launched
# anyway.
#
# The spawn is driven through a fake tmux pane and a real isolated git worktree,
# the same way the other fm-spawn behavior tests do, so no harness ever starts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
BOARD="$ROOT/bin/fm-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-board-dispatch)

# --- fixture ----------------------------------------------------------------

# A GitHub CLI that behaves like a real board: issues are filed into a store,
# adding a card returns the id the add itself minted, and a status write is
# visible to the next read.
make_gh_stub() {
  cat > "$1/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ -n "${GH_REFUSE_WRITES:-}" ]; then
  case "$1 $2" in
    "project item-add" | "project item-edit" | "issue create") exit 1 ;;
  esac
fi
case "$1 $2" in
  "project view") printf 'PVT_fixture\n' ;;
  "project field-list")
    printf 'field\tPVTSSF_status\n'
    printf 'option\topt_todo\tTodo\n'
    printf 'option\topt_prog\tIn Progress\n'
    printf 'option\topt_done\tDone\n'
    ;;
  "project item-list") cat "$GH_ITEMS" ;;
  "issue list")
    prev=''
    repo=''
    for arg in "$@"; do
      [ "$prev" != --repo ] || repo=$arg
      prev=$arg
    done
    awk -F'\t' -v OFS='\t' -v r="$repo" '$1 == r { print $2, $3 }' "$GH_ISSUES"
    ;;
  "issue create")
    repo=''; title=''; body=''
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --repo) repo=$2; shift 2 ;;
        --title) title=$2; shift 2 ;;
        --body) body=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    url="https://github.com/$repo/issues/$(( $(wc -l < "$GH_ISSUES") + 500 ))"
    printf '%s\t%s\t%s\t%s\n' "$repo" "$url" \
      "$(printf '%s' "$body" | tr '\n' ' ')" "$title" >> "$GH_ISSUES"
    printf '%s\n' "$url"
    ;;
  "project item-add")
    url=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --url) url=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    id="PVTI_card$(wc -l < "$GH_ITEMS")"
    printf '%s\tIssue\t%s\t-\t-\t-\tcard\t-\n' "$id" "$url" >> "$GH_ITEMS"
    printf '%s\n' "$id"
    ;;
  "project item-edit")
    eid=''; eopt=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --id) eid=$2; shift 2 ;;
        --single-select-option-id) eopt=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    case "$eopt" in
      opt_todo) name=Todo ;;
      opt_prog) name='In Progress' ;;
      *) name=Done ;;
    esac
    tmp=$(mktemp)
    awk -F'\t' -v OFS='\t' -v id="$eid" -v s="$name" '$1 == id { $4 = s } { print }' \
      "$GH_ITEMS" > "$tmp"
    mv "$tmp" "$GH_ITEMS"
    ;;
  "issue comment") : ;;
esac
exit 0
SH
  chmod +x "$1/gh"
}

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  make_gh_stub "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_case <name> <task-id>: an isolated home with one project clone whose
# directory name is the project name a board stanza would have to match.
make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/harbourlight"
  wt="$case_dir/wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' claude > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  : > "$case_dir/gh.log"
  : > "$case_dir/items"
  : > "$case_dir/issues"
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin"
}

configure_board() {
  cat > "$1/config/boards" <<'EOF'
project = harbourlight
owner = harbour-collective
number = 4
repo = harbour-collective/app
label = firstmate
EOF
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN <<EOF
$1
EOF
}

run_spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_BACKEND=tmux CLAUDE_CONFIG_DIR='' \
    GH_LOG="$CASE_DIR/gh.log" GH_ITEMS="$CASE_DIR/items" \
    GH_ISSUES="$CASE_DIR/issues" GH_REFUSE_WRITES="${GH_REFUSE_WRITES:-}" \
    PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$@" --mode direct-PR --yolo off 2>&1
}

run_board() {
  FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_BOARD_GH="$FAKEBIN/gh" \
    GH_LOG="$CASE_DIR/gh.log" GH_ITEMS="$CASE_DIR/items" \
    GH_ISSUES="$CASE_DIR/issues" \
    "$BOARD" "$@"
}

# --- cases ------------------------------------------------------------------

test_dispatching_board_mapped_work_leaves_a_card() {
  local rec out id
  id=fm-dispatch-card
  rec=$(make_case dispatch-card "$id")
  read_case "$rec"
  configure_board "$HOME_DIR"

  out=$(run_spawn "$id" "$PROJ_DIR")
  assert_contains "$out" "spawned $id harness=claude" "the dispatch itself did not complete"

  # One operation: the card exists and is already in the dispatched column.
  assert_contains "$(run_board lookup "$id")" 'in-progress' \
    "dispatching did not leave the task's card in the dispatched column"
  [ "$(wc -l < "$CASE_DIR/issues")" = 1 ] || fail "dispatching did not file exactly one issue"
  assert_contains "$(cat "$CASE_DIR/gh.log")" '--single-select-option-id opt_prog' \
    "the card was never moved to In Progress"
  pass "dispatching board-mapped work creates its card and marks it, in one operation"
}

test_a_second_dispatch_moves_the_card_it_already_has() {
  local rec out id issues_before
  id=fm-dispatch-again
  rec=$(make_case dispatch-again "$id")
  read_case "$rec"
  configure_board "$HOME_DIR"

  run_spawn "$id" "$PROJ_DIR" >/dev/null
  issues_before=$(wc -l < "$CASE_DIR/issues")
  run_board mark "$id" todo >/dev/null

  rm -f "$HOME_DIR/state/$id.meta"
  out=$(run_spawn "$id" "$PROJ_DIR")
  assert_contains "$out" "spawned $id" "the second dispatch did not complete"
  [ "$(wc -l < "$CASE_DIR/issues")" = "$issues_before" ] \
    || fail "a re-dispatch filed a second issue for work already on the board"
  assert_contains "$(run_board lookup "$id")" 'in-progress' "the re-dispatch did not move the card"
  pass "a task already on the board is moved, never filed a second time"
}

test_a_home_with_no_board_is_completely_unaffected() {
  local rec out id
  id=fm-no-board
  rec=$(make_case no-board "$id")
  read_case "$rec"
  [ ! -e "$HOME_DIR/config/boards" ] || fail "the fixture home already configured a board"

  out=$(run_spawn "$id" "$PROJ_DIR")
  assert_contains "$out" "spawned $id harness=claude" "a dispatch with no board configured did not complete"
  [ ! -s "$CASE_DIR/gh.log" ] || fail "a home with no board called the GitHub CLI: $(cat "$CASE_DIR/gh.log")"
  [ ! -s "$CASE_DIR/issues" ] || fail "a home with no board filed an issue"
  assert_absent "$HOME_DIR/data/board-links.tsv" "a home with no board wrote a linkage record"
  pass "a dispatch in a home with no configured board reads nothing, writes nothing, and files nothing"
}

test_a_project_with_no_stanza_is_never_placed() {
  local rec out id
  id=fm-other-project
  rec=$(make_case other-project "$id")
  read_case "$rec"
  # A board exists in this home, but for a different project entirely.
  cat > "$HOME_DIR/config/boards" <<'EOF'
project = tidewheel
owner = personal-account
number = 91
repo = personal-account/tidewheel
EOF

  out=$(run_spawn "$id" "$PROJ_DIR")
  assert_contains "$out" "spawned $id" "the dispatch did not complete"
  [ ! -s "$CASE_DIR/gh.log" ] || fail "work for an unconfigured project reached a board"
  [ ! -s "$CASE_DIR/issues" ] || fail "work for an unconfigured project filed an issue"
  pass "only a project with its own board stanza is ever placed on a board"
}

test_a_board_that_refuses_every_write_never_fails_the_dispatch() {
  local rec out id
  id=fm-board-down
  rec=$(make_case board-down "$id")
  read_case "$rec"
  configure_board "$HOME_DIR"

  out=$(GH_REFUSE_WRITES=1 run_spawn "$id" "$PROJ_DIR")
  assert_contains "$out" "spawned $id harness=claude" \
    "a board that refused every write blocked the dispatch"
  assert_present "$HOME_DIR/state/$id.meta" "the dispatch did not record the task"
  pass "a board write that cannot land leaves a stale card and never blocks a dispatch"
}

test_dispatching_a_scout_places_nothing() {
  local rec out id
  id=fm-scout-work
  rec=$(make_case scout-work "$id")
  read_case "$rec"
  configure_board "$HOME_DIR"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_BACKEND=tmux CLAUDE_CONFIG_DIR='' \
    GH_LOG="$CASE_DIR/gh.log" GH_ITEMS="$CASE_DIR/items" \
    GH_ISSUES="$CASE_DIR/issues" PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --scout 2>&1)
  assert_contains "$out" "spawned $id" "the scout dispatch did not complete"
  [ ! -s "$CASE_DIR/issues" ] || fail "a scout filed a card for a deliverable that is a report"
  pass "a scout produces a report rather than a card, and places nothing on the board"
}

test_dispatching_board_mapped_work_leaves_a_card
test_a_second_dispatch_moves_the_card_it_already_has
test_a_home_with_no_board_is_completely_unaffected
test_a_project_with_no_stanza_is_never_placed
test_a_board_that_refuses_every_write_never_fails_the_dispatch
test_dispatching_a_scout_places_nothing
