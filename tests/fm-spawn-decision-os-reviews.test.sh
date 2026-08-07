#!/usr/bin/env bash
# Public-interface regressions for the Decision OS review-store contract at the
# fm-spawn lane-setup boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-decision-os-reviews)

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse sleep
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/decision-os"
  wt="$case_dir/lane"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

expose_contract() {
  mkdir -p "$PROJ_DIR/data/local/.reviews"
  ln -s .reviews "$PROJ_DIR/data/local/reviews"
}

run_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

assert_correct_link() {
  local lane_link="$WT_DIR/data/local/reviews" canonical
  canonical=$(cd "$PROJ_DIR/data/local/reviews" && pwd -P)
  [ -L "$lane_link" ] || fail "lane review path is not a symlink: $lane_link"
  [ "$(cd "$lane_link" && pwd -P)" = "$canonical" ] \
    || fail "lane review link does not resolve to canonical store"
}

test_clean_setup_and_idempotent_repeat() {
  local rec out status id=doscleanz1 id2=dosrepeatz2
  rec=$(make_case clean "$id")
  read_case "$rec"
  expose_contract

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "clean Decision OS spawn should succeed"$'\n'"$out"
  assert_correct_link
  mkdir -p "$HOME_DIR/data/$id2"
  printf 'brief for %s\n' "$id2" > "$HOME_DIR/data/$id2/brief.md"
  out=$(run_spawn "$id2")
  status=$?
  expect_code 0 "$status" "repeated setup should remain idempotent"$'\n'"$out"
  assert_correct_link
  pass "Decision OS lane setup creates the canonical review link and repeats idempotently"
}

test_preexisting_correct_link_is_preserved() {
  local rec out status id=dosexistingz3 before
  rec=$(make_case existing "$id")
  read_case "$rec"
  expose_contract
  mkdir -p "$WT_DIR/data/local"
  ln -s "$PROJ_DIR/data/local/reviews" "$WT_DIR/data/local/reviews"
  before=$(readlink "$WT_DIR/data/local/reviews")

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "pre-linked Decision OS spawn should succeed"$'\n'"$out"
  [ "$(readlink "$WT_DIR/data/local/reviews")" = "$before" ] \
    || fail "setup rewrote the pre-existing correct link"
  assert_correct_link
  pass "Decision OS lane setup preserves a pre-existing correct link"
}

test_conflicting_evidence_directory_refuses_without_hiding_bytes() {
  local rec out status id=dosconflictz4 evidence
  rec=$(make_case conflict "$id")
  read_case "$rec"
  expose_contract
  evidence="$WT_DIR/data/local/reviews/run-a/frozen.json"
  mkdir -p "$(dirname "$evidence")"
  printf 'unique evidence\n' > "$evidence"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse a conflicting real review directory"
  assert_contains "$out" "refusing" "conflict refusal should be explicit"
  [ "$(cat "$evidence")" = "unique evidence" ] || fail "conflict refusal changed evidence bytes"
  [ ! -L "$WT_DIR/data/local/reviews" ] || fail "conflict refusal hid evidence behind a symlink"
  assert_absent "$HOME_DIR/state/$id.meta" "conflict refusal must happen before launch metadata"
  pass "Decision OS lane setup refuses a conflicting evidence directory without hiding bytes"
}

test_missing_and_wrong_canonical_targets_refuse() {
  local rec out status id=dosmissingz5 outside
  rec=$(make_case missing "$id")
  read_case "$rec"
  mkdir -p "$PROJ_DIR/data/local"
  ln -s .reviews "$PROJ_DIR/data/local/reviews"
  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse a dangling canonical review target"
  assert_contains "$out" "canonical" "missing-target refusal should name the canonical store"
  assert_absent "$WT_DIR/data/local/reviews" "missing-target refusal should not create a lane link"

  rm "$PROJ_DIR/data/local/reviews"
  outside="$CASE_DIR/other-project/reviews"
  mkdir -p "$outside"
  fm_git_init_commit "$CASE_DIR/other-project/repo"
  ln -s "$outside" "$PROJ_DIR/data/local/reviews"
  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse a canonical target outside the project"
  assert_contains "$out" "canonical" "wrong-project refusal should name the canonical store"
  assert_absent "$WT_DIR/data/local/reviews" "wrong-project refusal should not create a lane link"
  pass "Decision OS lane setup refuses missing and wrong-project canonical targets"
}

test_non_decision_os_project_is_unchanged() {
  local rec out status id=ordinaryz6
  rec=$(make_case ordinary "$id")
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "ordinary project spawn should retain existing behavior"$'\n'"$out"
  assert_absent "$WT_DIR/data/local/reviews" "ordinary project unexpectedly received a review-store link"
  pass "projects without the Decision OS review-store contract remain unchanged"
}

test_clean_setup_and_idempotent_repeat
test_preexisting_correct_link_is_preserved
test_conflicting_evidence_directory_refuses_without_hiding_bytes
test_missing_and_wrong_canonical_targets_refuse
test_non_decision_os_project_is_unchanged

echo "# all fm-spawn Decision OS review-store tests passed"
