#!/usr/bin/env bash
# Public-interface tests for the attended, one-time migration of Decision OS
# review evidence stranded in Treehouse pool copies.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MIGRATE="$ROOT/bin/fm-decision-os-review-migrate.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-os-review-migrate)
REAL_CP=$(command -v cp)

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = status ] && [ "${2:-}" = --json ] || exit 64
cat "${FM_MIGRATION_POOL_JSON:?}"
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 case_dir project slot1 slot2 fakebin
  case_dir="$TMP_ROOT/$name"
  project="$case_dir/decision-os"
  slot1="$case_dir/pool/1/decision-os"
  slot2="$case_dir/pool/2/decision-os"
  fakebin=$(make_fakebin "$case_dir/fake")
  fm_git_worktree "$project" "$slot1" "slot-1-$name"
  git -C "$project" worktree add --quiet -b "slot-2-$name" "$slot2"
  mkdir -p "$project/data/local/.reviews"
  ln -s .reviews "$project/data/local/reviews"
  printf '%s\n' "$case_dir|$project|$slot1|$slot2|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR PROJECT SLOT1 SLOT2 FAKEBIN_DIR <<EOF
$1
EOF
  POOL_JSON="$CASE_DIR/pool.json"
}

write_pool_json() {
  local status1=${1:-available} status2=${2:-available} processes1 processes2
  processes1='[]'; processes2='[]'
  [ "$status1" = available ] || processes1='[{"pid":123,"name":"reviewer"}]'
  [ "$status2" = available ] || processes2='[{"pid":456,"name":"worker"}]'
  jq -n \
    --arg p1 "$SLOT1" --arg s1 "$status1" --argjson ps1 "$processes1" \
    --arg p2 "$SLOT2" --arg s2 "$status2" --argjson ps2 "$processes2" \
    '[{name:"1",path:$p1,status:$s1,processes:$ps1},{name:"2",path:$p2,status:$s2,processes:$ps2}]' \
    > "$POOL_JSON"
}

run_migrate() {
  FM_MIGRATION_POOL_JSON="$POOL_JSON" PATH="$FAKEBIN_DIR:$PATH" \
    "$MIGRATE" "$@" "$PROJECT" 2>&1
}

test_lane_becoming_active_before_retirement_is_deferred() {
  local rec out status next_json counter
  rec=$(make_case became-active)
  read_case "$rec"
  mkdir -p "$SLOT1/data/local/reviews/run-one"
  printf 'still live\n' > "$SLOT1/data/local/reviews/run-one/frozen.json"
  write_pool_json available available
  next_json="$CASE_DIR/pool-next.json"
  counter="$CASE_DIR/treehouse-count"
  jq --argjson ps '[{"pid":789,"name":"late-reviewer"}]' \
    'map(if .name == "1" then .status="in-use" | .processes=$ps else . end)' \
    "$POOL_JSON" > "$next_json"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = status ] && [ "${2:-}" = --json ] || exit 64
count=0
[ ! -f "${FM_MIGRATION_TREEHOUSE_COUNT:?}" ] || count=$(cat "$FM_MIGRATION_TREEHOUSE_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_MIGRATION_TREEHOUSE_COUNT"
if [ "$count" -eq 1 ]; then
  cat "${FM_MIGRATION_POOL_JSON:?}"
else
  cat "${FM_MIGRATION_POOL_JSON_NEXT:?}"
fi
SH
  chmod +x "$FAKEBIN_DIR/treehouse"

  out=$(FM_MIGRATION_POOL_JSON_NEXT="$next_json" \
    FM_MIGRATION_TREEHOUSE_COUNT="$counter" run_migrate --apply)
  status=$?
  expect_code 0 "$status" "a lane becoming active should defer source retirement"$'\n'"$out"
  assert_contains "$out" "DEFER active-changed" "late activity was not detected"
  assert_present "$SLOT1/data/local/reviews/run-one/frozen.json" \
    "late activity allowed source evidence to be retired"
  pass "migration rechecks lane activity before retiring verified evidence"
}

test_dry_run_inventories_every_copy_and_defers_active_lane() {
  local rec out status
  rec=$(make_case inventory)
  read_case "$rec"
  mkdir -p "$SLOT1/data/local/reviews/run-one" "$SLOT2/data/local/reviews/run-two"
  printf 'one\n' > "$SLOT1/data/local/reviews/run-one/frozen.json"
  printf 'two\n' > "$SLOT2/data/local/reviews/run-two/frozen.json"
  write_pool_json available in-use

  out=$(run_migrate)
  status=$?
  expect_code 0 "$status" "dry-run inventory should succeed"$'\n'"$out"
  assert_contains "$out" "slot=1" "inventory omitted available slot"
  assert_contains "$out" "run=run-one" "inventory omitted available run id"
  assert_contains "$out" "hash=" "inventory omitted exact manifest hash"
  assert_contains "$out" "slot=2" "inventory omitted active slot"
  assert_contains "$out" "DEFER active" "active slot was not explicitly deferred"
  assert_present "$SLOT1/data/local/reviews/run-one/frozen.json" "dry run changed available evidence"
  assert_present "$SLOT2/data/local/reviews/run-two/frozen.json" "dry run changed active evidence"
  assert_absent "$PROJECT/data/local/.reviews/run-one" "dry run copied into canonical store"
  pass "migration dry run inventories all pool copies and defers active lanes without mutation"
}

test_apply_defers_review_link_setup_for_active_lane() {
  local rec out status
  rec=$(make_case active-link)
  read_case "$rec"
  mkdir -p "$SLOT2/data/local/reviews"
  write_pool_json in-use in-use

  out=$(run_migrate --apply)
  status=$?
  expect_code 0 "$status" "apply with only active lanes should defer without failing"$'\n'"$out"
  assert_contains "$out" "DEFER active slot=1" "active lane with a missing review path was not deferred"
  assert_contains "$out" "DEFER active slot=2" "active lane with an empty review directory was not deferred"
  assert_absent "$SLOT1/data/local/reviews" "apply created a review path for an in-use lane"
  [ -d "$SLOT2/data/local/reviews" ] && [ ! -L "$SLOT2/data/local/reviews" ] \
    || fail "apply removed or linked the empty review directory of an in-use lane"
  pass "apply defers review-path creation, removal, and linking for active lanes"
}

test_apply_copies_verifies_removes_then_links_and_reruns_idempotently() {
  local rec out status copied verified removed
  rec=$(make_case apply)
  read_case "$rec"
  mkdir -p "$SLOT1/data/local/reviews/run-one/empty-dir"
  printf 'evidence\n' > "$SLOT1/data/local/reviews/run-one/frozen.json"
  ln -s frozen.json "$SLOT1/data/local/reviews/run-one/latest"
  write_pool_json available available

  out=$(run_migrate --apply)
  status=$?
  expect_code 0 "$status" "guarded apply should succeed"$'\n'"$out"
  assert_present "$PROJECT/data/local/.reviews/run-one/frozen.json" "canonical copy is missing"
  [ "$(cat "$PROJECT/data/local/.reviews/run-one/frozen.json")" = evidence ] \
    || fail "canonical evidence bytes differ"
  [ -L "$SLOT1/data/local/reviews" ] || fail "drained lane was not linked to canonical reviews"
  [ "$(cd "$SLOT1/data/local/reviews" && pwd -P)" = "$(cd "$PROJECT/data/local/reviews" && pwd -P)" ] \
    || fail "drained lane link does not resolve to canonical reviews"
  copied=$(printf '%s\n' "$out" | grep -n 'COPIED slot=1 run=run-one' | cut -d: -f1)
  verified=$(printf '%s\n' "$out" | grep -n 'VERIFIED slot=1 run=run-one' | cut -d: -f1)
  removed=$(printf '%s\n' "$out" | grep -n 'REMOVED slot=1 run=run-one' | cut -d: -f1)
  [ -n "$copied" ] && [ "$copied" -lt "$verified" ] && [ "$verified" -lt "$removed" ] \
    || fail "apply did not report copy-before-verify-before-remove ordering"

  out=$(run_migrate --apply)
  status=$?
  expect_code 0 "$status" "idempotent rerun should succeed"$'\n'"$out"
  assert_contains "$out" "ALREADY-LINKED slot=1" "rerun did not recognize the completed lane"
  pass "migration copies, durably verifies, removes, links, and reruns idempotently"
}

test_nonidentical_collision_refuses_and_identical_collision_resumes() {
  local rec out status
  rec=$(make_case collision)
  read_case "$rec"
  mkdir -p "$SLOT1/data/local/reviews/run-one" "$PROJECT/data/local/.reviews/run-one"
  printf 'source\n' > "$SLOT1/data/local/reviews/run-one/frozen.json"
  printf 'different\n' > "$PROJECT/data/local/.reviews/run-one/frozen.json"
  write_pool_json available available

  out=$(run_migrate --apply)
  status=$?
  [ "$status" -ne 0 ] || fail "non-identical collision should refuse the migration"
  assert_contains "$out" "REFUSE collision" "collision refusal was not explicit"
  [ "$(cat "$SLOT1/data/local/reviews/run-one/frozen.json")" = source ] \
    || fail "collision refusal changed source evidence"
  [ "$(cat "$PROJECT/data/local/.reviews/run-one/frozen.json")" = different ] \
    || fail "collision refusal overwrote destination evidence"

  printf 'source\n' > "$PROJECT/data/local/.reviews/run-one/frozen.json"
  out=$(run_migrate --apply)
  status=$?
  expect_code 0 "$status" "identical destination should permit safe resume"$'\n'"$out"
  assert_contains "$out" "VERIFIED-EXISTING slot=1 run=run-one" \
    "resume did not recognize identical canonical evidence"
  [ -L "$SLOT1/data/local/reviews" ] || fail "identical resume did not link the drained lane"
  pass "migration refuses non-identical collisions and safely resumes identical ones"
}

test_changing_source_is_deferred_without_destination_publication() {
  local rec out status real_cp=$REAL_CP
  rec=$(make_case changing)
  read_case "$rec"
  mkdir -p "$SLOT1/data/local/reviews/run-one"
  printf 'before\n' > "$SLOT1/data/local/reviews/run-one/frozen.json"
  write_pool_json available available
  cat > "$FAKEBIN_DIR/cp" <<SH
#!/usr/bin/env bash
"$real_cp" "\$@" || exit \$?
printf 'changed during copy\n' >> "${SLOT1}/data/local/reviews/run-one/frozen.json"
SH
  chmod +x "$FAKEBIN_DIR/cp"

  out=$(run_migrate --apply)
  status=$?
  expect_code 0 "$status" "changing source should be deferred, not destroyed"$'\n'"$out"
  assert_contains "$out" "DEFER changed" "changing source was not detected"
  assert_present "$SLOT1/data/local/reviews/run-one/frozen.json" "changing source was removed"
  assert_absent "$PROJECT/data/local/.reviews/run-one" "changing source was published canonically"
  pass "migration detects a changing run and leaves source and destination safe"
}

test_interrupted_copy_is_resumable() {
  local rec out status real_cp=$REAL_CP
  rec=$(make_case resume)
  read_case "$rec"
  mkdir -p "$SLOT1/data/local/reviews/run-one"
  printf 'resume me\n' > "$SLOT1/data/local/reviews/run-one/frozen.json"
  write_pool_json available available
  cat > "$FAKEBIN_DIR/cp" <<SH
#!/usr/bin/env bash
"$real_cp" "\$@"
exit 75
SH
  chmod +x "$FAKEBIN_DIR/cp"

  out=$(run_migrate --apply)
  status=$?
  [ "$status" -ne 0 ] || fail "simulated interrupted copy should fail"
  assert_present "$SLOT1/data/local/reviews/run-one/frozen.json" "interruption removed source evidence"
  assert_absent "$PROJECT/data/local/.reviews/run-one" "interruption published an unverified destination"

  rm "$FAKEBIN_DIR/cp"
  out=$(run_migrate --apply)
  status=$?
  expect_code 0 "$status" "rerun after interrupted copy should succeed"$'\n'"$out"
  assert_present "$PROJECT/data/local/.reviews/run-one/frozen.json" "resume did not publish verified evidence"
  [ -L "$SLOT1/data/local/reviews" ] || fail "resume did not finish linking the lane"
  pass "migration safely resumes after an interrupted copy"
}

test_wrong_project_and_invalid_canonical_store_refuse() {
  local rec out status other
  rec=$(make_case invalid)
  read_case "$rec"
  mkdir -p "$SLOT1/data/local/reviews/run-one"
  printf 'safe\n' > "$SLOT1/data/local/reviews/run-one/frozen.json"
  write_pool_json available available
  rm "$PROJECT/data/local/reviews"
  ln -s missing "$PROJECT/data/local/reviews"
  out=$(run_migrate --apply)
  status=$?
  [ "$status" -ne 0 ] || fail "dangling canonical store should refuse"
  assert_contains "$out" "canonical" "canonical refusal should explain the boundary"
  assert_present "$SLOT1/data/local/reviews/run-one/frozen.json" "canonical refusal changed source"

  rm "$PROJECT/data/local/reviews"
  ln -s .reviews "$PROJECT/data/local/reviews"
  other="$CASE_DIR/other-repo"
  fm_git_init_commit "$other"
  jq -n --arg path "$other" '[{name:"wrong",path:$path,status:"available",processes:[]}]' > "$POOL_JSON"
  out=$(run_migrate --apply)
  status=$?
  [ "$status" -ne 0 ] || fail "wrong-project pool path should refuse"
  assert_contains "$out" "wrong project" "wrong-project refusal was not explicit"
  pass "migration refuses invalid canonical stores and wrong-project pool copies"
}

test_dry_run_inventories_every_copy_and_defers_active_lane
test_lane_becoming_active_before_retirement_is_deferred
test_apply_defers_review_link_setup_for_active_lane
test_apply_copies_verifies_removes_then_links_and_reruns_idempotently
test_nonidentical_collision_refuses_and_identical_collision_resumes
test_changing_source_is_deferred_without_destination_publication
test_interrupted_copy_is_resumable
test_wrong_project_and_invalid_canonical_store_refuse

echo "# all Decision OS review migration tests passed"
