#!/usr/bin/env bash
# Spawn behavior for an addendum fill-in token. A project addendum
# (config/brief-addenda/<repo>.md) may write `{FILL:NAME}` where the task must
# supply a value; bin/fm-spawn.sh refuses a ship or scout brief that still
# carries one (bin/fm-dod-lib.sh owns the match). These drive the real spawn
# path with a fake terminal.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-brief-addenda-fill-token)

# make_case <name> <id> <addendum-text> [<fill-name> <value>]: a home whose
# addendum for `project` holds the text, a project with a pooled worktree, and
# a scaffolded ship brief with Task filled. When <fill-name> is given, that
# token is replaced by <value> in the brief. Sets CASE_DIR, HOME_DIR,
# PROJECT_DIR, POOL_DIR, FAKEBIN_DIR.
make_case() {
  local name=$1 id=$2 addendum=$3 content
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJECT_DIR="$CASE_DIR/project"
  POOL_DIR="$CASE_DIR/pool"
  FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake")
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config/brief-addenda"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  printf -- '- project [no-mistakes] - fixture (added 2026-01-01)\n' > "$HOME_DIR/data/projects.md"
  printf '%s\n' "$addendum" > "$HOME_DIR/config/brief-addenda/project.md"
  touch "$HOME_DIR/state/.last-watcher-beat"
  git init --quiet -b main "$PROJECT_DIR"
  printf 'base\n' > "$PROJECT_DIR/README.md"
  git -C "$PROJECT_DIR" add README.md
  git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR" "$(git -C "$PROJECT_DIR" rev-parse HEAD)"
  FM_HOME="$HOME_DIR" "$BRIEF" "$id" project --mode no-mistakes >/dev/null \
    || fail "the brief for $id should scaffold"
  content=$(cat "$HOME_DIR/data/$id/brief.md")
  content=${content//'{TASK}'/Exercise the spawn path.}
  content=${content//'{FIRSTMATE_SPEC}'/Exercise the spawn path.}
  printf '%s\n' "$content" > "$HOME_DIR/data/$id/brief.md"
}

run_spawn() {  # <id> <args...>
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" "$@"
}

test_spawn_refuses_an_unfilled_token_and_names_it() {
  local id out status
  id=fill-token-r1
  make_case unfilled "$id" 'Route: {FILL:ROUTE_LINE}'
  assert_grep '{FILL:ROUTE_LINE}' "$HOME_DIR/data/$id/brief.md" "the addendum token did not reach the brief"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off); status=$?
  [ "$status" -ne 0 ] || fail "a brief with an unfilled token launched"$'\n'"$out"
  assert_contains "$out" '{FILL:ROUTE_LINE}' "the refusal did not name the token"
  assert_contains "$out" 'fill it in the brief' "the refusal did not say how to proceed"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the refused spawn still published a task record"
  pass "fm-spawn: a brief with an unfilled addendum token is refused and the token is named"
}

test_spawn_launches_once_the_token_is_filled() {
  local id out status content
  id=fill-token-f1
  make_case filled "$id" 'Route: {FILL:ROUTE_LINE}'
  content=$(cat "$HOME_DIR/data/$id/brief.md")
  content=${content//'{FILL:ROUTE_LINE}'/step one}
  printf '%s\n' "$content" > "$HOME_DIR/data/$id/brief.md"
  assert_no_grep '{FILL:' "$HOME_DIR/data/$id/brief.md" "the fixture left a token behind"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off); status=$?
  expect_code 0 "$status" "a brief with its token filled should launch"$'\n'"$out"
  pass "fm-spawn: a brief whose addendum token is filled launches"
}

test_spawn_ignores_text_that_is_not_a_token() {
  local id out status
  id=fill-token-n1
  make_case plain "$id" 'Plain standing instruction, and {FILL:lower}, {FILL:} or {FILL:A-B} are not tokens.'
  out=$(run_spawn "$id" --mode no-mistakes --yolo off); status=$?
  expect_code 0 "$status" "a brief with no token should launch"$'\n'"$out"

  id=fill-token-n2
  make_case noaddendum "$id" ''
  rm -f "$HOME_DIR/config/brief-addenda/project.md"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off); status=$?
  expect_code 0 "$status" "a brief with no addendum should launch"$'\n'"$out"
  pass "fm-spawn: a brief with no token, or no addendum, is unaffected"
}

test_spawn_refuses_an_unfilled_token_and_names_it
test_spawn_launches_once_the_token_is_filled
test_spawn_ignores_text_that_is_not_a_token

echo "# all fm-brief-addenda-fill-token tests passed"
