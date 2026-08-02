#!/usr/bin/env bash
# End-to-end regression for the primary agent's direct closeout-and-refill
# transaction.
#
# The primary agent remains the one lifecycle owner; there is intentionally no
# production coordinator to test here.
# This test stitches together the existing guarded owners exactly as that agent
# must: standing yolo authority selects the existing merge owner by task mode,
# fm-teardown proves landing before cleanup, and fm-spawn fills the newly open
# visible slot in the same transaction.
# It also proves that unlanded and captain-gated lanes remain intact.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
LOCAL_MERGE="$ROOT/bin/fm-merge-local.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
RENDER="$ROOT/bin/fm-supervision-instructions.sh"
TMP_ROOT=$(fm_test_tmproot fm-direct-lifecycle)
CASE="$TMP_ROOT/case"
HOME_DIR="$CASE/home"
PROJECT="$HOME_DIR/projects/project"
ORIGIN="$CASE/origin.git"
COMPLETED_WT="$CASE/completed-wt"
READY_WT="$CASE/ready-wt"
READY_WT2="$CASE/ready-wt-2"
LOCAL_WT="$CASE/local-wt"
UNLANDED_WT="$CASE/unlanded-wt"
GATED_WT="$CASE/gated-wt"
FAKEBIN="$CASE/fakebin"
GH_AXI_LOG="$CASE/gh-axi.log"
TREEHOUSE_LOG="$CASE/treehouse.log"
TMUX_LOG="$CASE/tmux.log"
HEAD_FILE="$CASE/completed-head"
BASE_PATH=$PATH
REAL_GIT=$(command -v git)
ACTIVE_READY_ID=ready-r1
ACTIVE_READY_WT=$READY_WT

mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" \
  "$HOME_DIR/projects" "$FAKEBIN"
touch "$HOME_DIR/state/.last-watcher-beat" "$GH_AXI_LOG" \
  "$TREEHOUSE_LOG" "$TMUX_LOG"

git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git clone -q "$ORIGIN" "$CASE/seed" 2>/dev/null
git -C "$CASE/seed" commit -q --allow-empty -m "origin baseline"
git -C "$CASE/seed" push -q origin main
git clone -q "$ORIGIN" "$PROJECT"
git -C "$PROJECT" remote set-head origin main

git -C "$PROJECT" worktree add -q -b fm/completed-y1 "$COMPLETED_WT" main
printf '%s\n' "completed work" > "$COMPLETED_WT/completed.txt"
git -C "$COMPLETED_WT" add completed.txt
git -C "$COMPLETED_WT" commit -qm "complete routine work"
git -C "$COMPLETED_WT" rev-parse HEAD > "$HEAD_FILE"

git -C "$PROJECT" worktree add -q -b fm/ready-r1 "$READY_WT" main

printf '%s\n' '- project [direct-PR +yolo] - lifecycle fixture (added 2026-07-27)' \
  > "$HOME_DIR/data/projects.md"
printf '%s\n' 1 > "$HOME_DIR/config/supervision-capacity"
mkdir -p "$HOME_DIR/data/ready-r1"
printf '%s\n' '# Task' 'Run the ready lifecycle fixture.' \
  > "$HOME_DIR/data/ready-r1/brief.md"

cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge")
    "$FM_TEST_REAL_GIT" -C "$FM_TEST_COMPLETED_WT" \
      push -q origin HEAD:refs/heads/main
    exit 0
    ;;
  "pr list")
    printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"
    exit 0
    ;;
  "pr view")
    echo "error: pull request not found" >&2
    exit 1
    ;;
esac
exit 0
SH

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *" --json headRefOid "*)
        cat "$FM_TEST_HEAD_FILE"
        exit 0
        ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH

cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
    else
      printf '%s\n' "$FM_TEST_READY_WT"
    fi
    exit 0
    ;;
  return)
    printf '%s\n' "$*" >> "$FM_TEST_TREEHOUSE_LOG"
    "$FM_TEST_REAL_GIT" -C "$FM_TEST_PROJECT" worktree remove --force "$3"
    exit $?
    ;;
  status)
    exit 0
    ;;
esac
exit 0
SH

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
# shellcheck source=/dev/null
. "$(dirname "$0")/pane-shell.sh"
printf '%s\n' "$*" >> "$FM_TEST_TMUX_LOG"
if [ "${1:-}" = display-message ]; then
  case "$*" in
    *"#{pane_current_path}"*)
      printf '%s\n' "$FM_TEST_READY_WT"
      exit 0
      ;;
    *"#{window_name}"*)
      printf '%s\n' "fm-$FM_TEST_READY_ID"
      exit 0
      ;;
    *"#{pane_id}"*)
      printf '%s\n' '%1'
      exit 0
      ;;
    *"#S"*)
      printf '%s\n' firstmate
      exit 0
      ;;
  esac
fi
case "${1:-}" in
  new-window)
    case "$FM_TEST_READY_ID" in
      ready-r1) printf '%s\n' '@17' ;;
      ready-r2) printf '%s\n' '@18' ;;
      *) exit 1 ;;
    esac
    exit 0
    ;;
  list-windows|has-session|new-session|set-window-option|kill-window)
    exit 0
    ;;
  capture-pane)
    fm_fake_pane_capture
    exit 0
    ;;
  send-keys)
    fm_fake_pane_send "$@"
    exit 0
    ;;
esac
exit 0
SH

chmod +x "$FAKEBIN/gh-axi" "$FAKEBIN/gh" "$FAKEBIN/treehouse" "$FAKEBIN/tmux"
fm_fake_pane_shell "$FAKEBIN"

fixture_cmd() {
  FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 \
    FM_TEST_COMPLETED_WT="$COMPLETED_WT" \
    FM_TEST_READY_WT="$ACTIVE_READY_WT" \
    FM_TEST_PROJECT="$PROJECT" \
    FM_TEST_HEAD_FILE="$HEAD_FILE" \
    FM_TEST_GH_AXI_LOG="$GH_AXI_LOG" \
    FM_TEST_TREEHOUSE_LOG="$TREEHOUSE_LOG" \
    FM_TEST_TMUX_LOG="$TMUX_LOG" \
    FM_TEST_READY_ID="$ACTIVE_READY_ID" \
    FM_TEST_REAL_GIT="$REAL_GIT" \
    TMUX="fake,1,0" \
    PATH="$FAKEBIN:$BASE_PATH" \
    "$@"
}

write_ship_meta() {
  local id=$1 worktree=$2 yolo=$3 mode=$4
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$worktree" \
    "project=$PROJECT" \
    "harness=opencode" \
    "kind=ship" \
    "treehouse_lease=1" \
    "mode=$mode" \
    "yolo=$yolo" \
    "model=default" \
    "effort=default"
  chmod 0600 "$HOME_DIR/state/$id.meta"
}

configured_capacity() {
  local capacity rendered
  rendered=$(fixture_cmd "$RENDER" --harness codex)
  capacity=$(printf '%s\n' "$rendered" \
    | sed -n 's/.*configured capacity \([1-9][0-9]*\) .*/\1/p')
  [ -n "$capacity" ] || {
    echo "configured capacity unavailable" >&2
    return 1
  }
  printf '%s\n' "$capacity"
}

ordinary_lane_count() {
  local count=0 kind meta
  for meta in "$HOME_DIR"/state/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(sed -n 's/^kind=//p' "$meta" | tail -1)
    [ "$kind" = secondmate ] || count=$(( count + 1 ))
  done
  printf '%s\n' "$count"
}

select_ready_fixture() {
  ACTIVE_READY_ID=$1
  case "$1" in
    ready-r1) ACTIVE_READY_WT=$READY_WT ;;
    ready-r2) ACTIVE_READY_WT=$READY_WT2 ;;
    *) return 1 ;;
  esac
}

refill_to_configured_capacity() {
  local candidate capacity count out
  capacity=$(configured_capacity) || return
  for candidate in "$@"; do
    count=$(ordinary_lane_count)
    [ "$count" -lt "$capacity" ] || break
    select_ready_fixture "$candidate" || return
    out=$(fixture_cmd "$SPAWN" "$candidate" "$PROJECT" --harness opencode) \
      || return
    printf '%s\n' "$out"
  done
  count=$(ordinary_lane_count)
  [ "$count" -eq "$capacity" ] || {
    printf 'refill-incomplete: running=%s capacity=%s\n' "$count" "$capacity" >&2
    return 5
  }
}

closeout_with_standing_authority() {
  local id=$1 url=$2 meta="$HOME_DIR/state/$1.meta" kind mode status yolo
  shift 2
  kind=$(sed -n 's/^kind=//p' "$meta" | tail -1)
  mode=$(sed -n 's/^mode=//p' "$meta" | tail -1)
  yolo=$(sed -n 's/^yolo=//p' "$meta" | tail -1)
  status=$(tail -1 "$HOME_DIR/state/$id.status" 2>/dev/null || true)
  if [ "$kind" != ship ]; then
    printf 'ambiguous-or-incomplete: %s\n' "$id"
    return 4
  fi
  case "$mode" in
    local-only)
      printf '%s\n' "$status" | grep -Fq 'done: local branch ready' || {
        printf 'ambiguous-or-incomplete: %s\n' "$id"
        return 4
      }
      ;;
    no-mistakes|direct-PR)
      printf '%s\n' "$status" | grep -Fq 'done: PR checks green' || {
        printf 'ambiguous-or-incomplete: %s\n' "$id"
        return 4
      }
      ;;
    *)
      printf 'ambiguous-mode: %s\n' "$id"
      return 4
      ;;
  esac
  if [ "$yolo" != on ]; then
    printf 'captain-gated: %s\n' "$id"
    return 3
  fi
  case "$mode" in
    local-only)
      fixture_cmd "$LOCAL_MERGE" "$id" || return
      ;;
    no-mistakes|direct-PR)
      fixture_cmd "$PR_MERGE" "$id" "$url" || return
      ;;
  esac
  fixture_cmd "$TEARDOWN" "$id" || return
  refill_to_configured_capacity "$@"
}

test_complete_land_cleanup_and_visible_refill() {
  local id=completed-y1 out rc
  write_ship_meta "$id" "$COMPLETED_WT" on direct-PR
  printf '%s\n' 'done: PR checks green; routine change complete' \
    > "$HOME_DIR/state/$id.status"

  set +e
  out=$(closeout_with_standing_authority \
    "$id" https://github.com/example/project/pull/41 ready-r1 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "routine yolo closeout should land and clean up"
  assert_contains "$out" "teardown $id complete" \
    "successful closeout did not run the guarded teardown owner"
  assert_grep 'pr merge 41 --repo example/project --squash' "$GH_AXI_LOG" \
    "successful closeout did not run the guarded merge owner"
  [ "$("$REAL_GIT" --git-dir="$ORIGIN" rev-parse refs/heads/main)" \
      = "$(cat "$HEAD_FILE")" ] \
    || fail "successful PR closeout did not land work on the default branch"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "landed work retained task metadata after safe teardown"
  assert_absent "$COMPLETED_WT" \
    "landed leased worktree was not returned"
  assert_grep "return --force $COMPLETED_WT" "$TREEHOUSE_LOG" \
    "safe teardown did not return the exact landed worktree"

  assert_contains "$out" "spawned ready-r1" \
    "same-transaction ready refill was not surfaced as a visible worker"
  assert_grep "worktree=$READY_WT" "$HOME_DIR/state/ready-r1.meta" \
    "refill did not record the isolated ready worktree"
  assert_grep 'yolo=on' "$HOME_DIR/state/ready-r1.meta" \
    "refill did not inherit standing project authority"
  assert_grep ' -n fm-ready-r1 ' "$TMUX_LOG" \
    "refill did not create a visible task window"
  pass "routine PR work lands on default, cleans safely, and visibly refills in one transaction"
}

test_local_only_uses_local_merge_owner_and_refills_to_capacity() {
  local before id=local-y2 local_head out rc
  git -C "$PROJECT" fetch -q origin main
  git -C "$PROJECT" merge -q --ff-only origin/main
  git -C "$PROJECT" worktree add -q -b fm/local-y2 "$LOCAL_WT" main
  printf '%s\n' "local-only work" > "$LOCAL_WT/local.txt"
  git -C "$LOCAL_WT" add local.txt
  git -C "$LOCAL_WT" commit -qm "complete local-only work"
  local_head=$(git -C "$LOCAL_WT" rev-parse HEAD)
  git -C "$PROJECT" worktree add -q -b fm/ready-r2 "$READY_WT2" main
  printf '%s\n' '- project [local-only +yolo] - lifecycle fixture (added 2026-07-27)' \
    > "$HOME_DIR/data/projects.md"
  mkdir -p "$HOME_DIR/data/ready-r2"
  printf '%s\n' '# Task' 'Run the second ready lifecycle fixture.' \
    > "$HOME_DIR/data/ready-r2/brief.md"
  printf '%s\n' 2 > "$HOME_DIR/config/supervision-capacity"
  write_ship_meta "$id" "$LOCAL_WT" on local-only
  printf '%s\n' 'done: local branch ready; routine local change complete' \
    > "$HOME_DIR/state/$id.status"
  before=$(wc -l < "$GH_AXI_LOG")

  set +e
  out=$(closeout_with_standing_authority "$id" "" ready-r2 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "local-only yolo closeout should land and refill"
  assert_contains "$out" "merged fm/$id into local main" \
    "local-only closeout did not run the guarded local merge owner"
  assert_contains "$out" "teardown $id complete" \
    "local-only closeout did not run guarded teardown"
  assert_contains "$out" "spawned ready-r2" \
    "local-only closeout did not visibly refill in the same transaction"
  [ "$(git -C "$PROJECT" rev-parse main)" = "$local_head" ] \
    || fail "local-only closeout did not land on local main"
  [ "$(wc -l < "$GH_AXI_LOG")" -eq "$before" ] \
    || fail "local-only closeout called the PR merge owner"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "local-only landed work retained task metadata"
  assert_absent "$LOCAL_WT" \
    "local-only landed worktree was not returned"
  assert_grep "return --force $LOCAL_WT" "$TREEHOUSE_LOG" \
    "local-only safe teardown did not return the exact worktree"
  assert_grep 'mode=local-only' "$HOME_DIR/state/ready-r2.meta" \
    "capacity refill did not inherit the local-only project mode"
  assert_grep ' -n fm-ready-r2 ' "$TMUX_LOG" \
    "capacity refill did not create the second visible task window"
  pass "local-only yolo work uses its guarded owner and refills to configured capacity"
}

test_unlanded_work_is_preserved() {
  local id=unlanded-u1 before out rc
  git -C "$PROJECT" worktree add -q -b fm/unlanded-u1 "$UNLANDED_WT" main
  printf '%s\n' "unlanded work" > "$UNLANDED_WT/unlanded.txt"
  git -C "$UNLANDED_WT" add unlanded.txt
  git -C "$UNLANDED_WT" commit -qm "unlanded routine work"
  write_ship_meta "$id" "$UNLANDED_WT" on direct-PR
  before=$(wc -l < "$TREEHOUSE_LOG")

  set +e
  out=$(fixture_cmd "$TEARDOWN" "$id" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "unlanded teardown should refuse"
  assert_contains "$out" "REFUSED:" \
    "unlanded teardown did not report its safety refusal"
  assert_contains "$out" "not landed" \
    "unlanded teardown did not identify the failed proof"
  assert_present "$HOME_DIR/state/$id.meta" \
    "unlanded teardown removed recovery metadata"
  assert_present "$UNLANDED_WT" \
    "unlanded teardown removed the worktree"
  [ "$(wc -l < "$TREEHOUSE_LOG")" -eq "$before" ] \
    || fail "unlanded teardown called treehouse return"
  pass "unlanded work fails closed and remains recoverable"
}

test_captain_gated_work_is_untouched() {
  local id=gated-g1 before out rc
  git -C "$PROJECT" worktree add -q -b fm/gated-g1 "$GATED_WT" main
  printf '%s\n' "captain-gated work" > "$GATED_WT/gated.txt"
  git -C "$GATED_WT" add gated.txt
  git -C "$GATED_WT" commit -qm "captain-gated work"
  write_ship_meta "$id" "$GATED_WT" off direct-PR
  printf '%s\n' 'done: PR checks green; waiting for captain authority' \
    > "$HOME_DIR/state/$id.status"
  before=$(wc -l < "$GH_AXI_LOG")

  set +e
  out=$(closeout_with_standing_authority \
    "$id" https://github.com/example/project/pull/42 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "captain-gated closeout should remain parked"
  assert_contains "$out" "captain-gated: $id" \
    "captain-gated closeout did not identify the authority boundary"
  assert_present "$HOME_DIR/state/$id.meta" \
    "captain-gated closeout removed task metadata"
  assert_present "$GATED_WT" \
    "captain-gated closeout removed its worktree"
  [ "$(wc -l < "$GH_AXI_LOG")" -eq "$before" ] \
    || fail "captain-gated closeout called the merge owner"
  pass "captain-gated completed work remains parked without merge or cleanup"
}

test_complete_land_cleanup_and_visible_refill
test_local_only_uses_local_merge_owner_and_refills_to_capacity
test_unlanded_work_is_preserved
test_captain_gated_work_is_untouched

echo "# all direct lifecycle tests passed"
