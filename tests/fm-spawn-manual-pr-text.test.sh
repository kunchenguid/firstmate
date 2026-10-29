#!/usr/bin/env bash
# Spawn behavior for a pr=manual project, whose worker writes the pull request
# title and body itself while the pipeline's pr and ci steps are skipped
# (bin/fm-project-mode.sh owns the registry token, bin/fm-dod-lib.sh the
# contract). These drive the real spawn path with a fake terminal: the task
# spawn launches only when the brief and the registry agree on the token.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-manual-pr-text)

# make_case <name> <id> <registry-tokens> [<brief-flags>...]: a home whose
# registry holds the tokens, a project with a pooled worktree, and a brief
# scaffolded with the flags. Sets CASE_DIR, HOME_DIR, PROJECT_DIR, POOL_DIR,
# FAKEBIN_DIR.
make_case() {
  local name=$1 id=$2 tokens=$3 content
  shift 3
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJECT_DIR="$CASE_DIR/project"
  POOL_DIR="$CASE_DIR/pool"
  FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake")
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  printf -- '- project [%s] - fixture (added 2026-01-01)\n' "$tokens" > "$HOME_DIR/data/projects.md"
  touch "$HOME_DIR/state/.last-watcher-beat"
  git init --quiet -b main "$PROJECT_DIR"
  printf 'base\n' > "$PROJECT_DIR/README.md"
  git -C "$PROJECT_DIR" add README.md
  git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR" "$(git -C "$PROJECT_DIR" rev-parse HEAD)"
  FM_HOME="$HOME_DIR" "$BRIEF" "$id" project --mode no-mistakes "$@" >/dev/null \
    || fail "the brief for $id should scaffold"
  content=$(cat "$HOME_DIR/data/$id/brief.md")
  content=${content//'{TASK}'/Write the PR text by hand.}
  content=${content//'{FIRSTMATE_SPEC}'/Exercise the spawn path.}
  printf '%s\n' "$content" > "$HOME_DIR/data/$id/brief.md"
}

run_spawn() {  # <id> <args...>
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" "$@"
}

test_spawn_launches_when_brief_and_registry_agree_on_pr_text() {
  local id out status
  id=pr-text-s1
  make_case record "$id" "no-mistakes pr=manual" --pr manual
  out=$(run_spawn "$id" --mode no-mistakes --yolo off); status=$?
  expect_code 0 "$status" "a pr=manual no-mistakes spawn should launch"$'\n'"$out"

  id=pr-text-s2
  make_case plain "$id" "no-mistakes"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off); status=$?
  expect_code 0 "$status" "an ordinary no-mistakes spawn should launch"$'\n'"$out"
  pass "fm-spawn: a brief and registry that agree on pr=manual or on no token both launch"
}

test_spawn_refuses_a_pr_text_mismatch_before_launch() {
  local id out status
  id=pr-text-m1
  make_case missing "$id" "no-mistakes pr=manual"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off); status=$?
  [ "$status" -ne 0 ] || fail "a pr=manual project launched on a brief without the token"$'\n'"$out"
  assert_contains "$out" "PR-text mismatch" "the refusal did not name the drift"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the refused spawn still published a task record"

  id=pr-text-m2
  make_case extra "$id" "no-mistakes" --pr manual
  out=$(run_spawn "$id" --mode no-mistakes --yolo off); status=$?
  [ "$status" -ne 0 ] || fail "a project with no pr token launched on a pr=manual brief"$'\n'"$out"
  assert_contains "$out" "PR-text mismatch" "the refusal did not name the drift"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the refused spawn still published a task record"
  pass "fm-spawn: a brief and registry that disagree on pr=manual refuse before launch in both directions"
}

test_spawn_launches_when_brief_and_registry_agree_on_pr_text
test_spawn_refuses_a_pr_text_mismatch_before_launch

echo "# all fm-spawn-manual-pr-text tests passed"
