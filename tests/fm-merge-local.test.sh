#!/usr/bin/env bash
# Behavior tests for bin/fm-merge-local.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-merge-local)
fm_git_identity fmtest fmtest@example.invalid

make_local_only_project() {
  local project=$1
  mkdir -p "$project"
  git -C "$project" init -q -b main
  printf 'base\n' > "$project/base.txt"
  git -C "$project" add base.txt
  git -C "$project" commit -qm base
}

test_recorded_custom_branch_merges() {
  local case_dir home project before after
  case_dir="$TMP_ROOT/custom-branch"
  home="$case_dir/home"
  project="$case_dir/project"
  mkdir -p "$home/data/task-custom" "$home/state"

  make_local_only_project "$project"
  git -C "$project" checkout -qb feature/custom-task
  printf 'custom work\n' > "$project/custom.txt"
  git -C "$project" add custom.txt
  git -C "$project" commit -qm custom
  git -C "$project" checkout -qb "fm/task-custom"
  printf 'stale reconstructed branch\n' > "$project/stale.txt"
  git -C "$project" add stale.txt
  git -C "$project" commit -qm stale-fm-id
  git -C "$project" checkout -q main
  before=$(git -C "$project" rev-parse HEAD)

  fm_write_meta "$home/state/task-custom.meta" \
    "project=$project" "kind=ship" "mode=local-only"
  printf '%s\n' 'Crew branch: branch=feature/custom-task' > "$home/data/task-custom/brief.md"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-merge-local.sh" task-custom >/dev/null \
    || fail "fm-merge-local.sh should merge the branch recorded by fm-brief.sh"
  after=$(git -C "$project" rev-parse HEAD)
  [ "$after" != "$before" ] || fail "local default branch did not advance to the recorded custom branch"
  git -C "$project" merge-base --is-ancestor feature/custom-task main \
    || fail "recorded custom branch was not fast-forwarded into local main"
  git -C "$project" merge-base --is-ancestor "fm/task-custom" main \
    && fail "fm-merge-local.sh merged reconstructed fm/<id> instead of the recorded branch"
  pass "fm-merge-local.sh merges a local-only brief's recorded custom branch"
}

test_omitted_crew_branch_still_merges_fm_id() {
  local case_dir home project after
  case_dir="$TMP_ROOT/default-branch"
  home="$case_dir/home"
  project="$case_dir/project"
  mkdir -p "$home/data/task-default" "$home/state"

  make_local_only_project "$project"
  git -C "$project" checkout -qb "fm/task-default"
  printf 'default work\n' > "$project/default.txt"
  git -C "$project" add default.txt
  git -C "$project" commit -qm default-fm-id
  git -C "$project" checkout -q main

  fm_write_meta "$home/state/task-default.meta" \
    "project=$project" "kind=ship" "mode=local-only"
  printf '%s\n' 'Delivery contract: mode=local-only' > "$home/data/task-default/brief.md"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-merge-local.sh" task-default >/dev/null \
    || fail "fm-merge-local.sh should keep fm/<id> when no crew branch is recorded"
  after=$(git -C "$project" rev-parse HEAD)
  git -C "$project" merge-base --is-ancestor "fm/task-default" main \
    || fail "omitted crew-branch line did not merge fm/<id>"
  [ "$after" = "$(git -C "$project" rev-parse fm/task-default)" ] \
    || fail "omitted crew-branch merge did not land on the fm/<id> tip"
  pass "fm-merge-local.sh still merges fm/<id> when no crew branch is recorded"
}

test_invalid_recorded_branch_refuses() {
  local case_dir home project out status before
  case_dir="$TMP_ROOT/invalid-branch"
  home="$case_dir/home"
  project="$case_dir/project"
  mkdir -p "$home/data/task-bad" "$home/state"

  make_local_only_project "$project"
  git -C "$project" checkout -qb "fm/task-bad"
  printf 'should not merge\n' > "$project/bad.txt"
  git -C "$project" add bad.txt
  git -C "$project" commit -qm should-not-merge
  git -C "$project" checkout -q main
  before=$(git -C "$project" rev-parse HEAD)

  fm_write_meta "$home/state/task-bad.meta" \
    "project=$project" "kind=ship" "mode=local-only"
  printf '%s\n' 'Crew branch: branch=bad..name' > "$home/data/task-bad/brief.md"

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-merge-local.sh" task-bad 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "fm-merge-local.sh accepted an invalid recorded crew branch"
  assert_contains "$out" "records an invalid crew branch" \
    "invalid recorded crew branch did not refuse clearly"
  [ "$(git -C "$project" rev-parse HEAD)" = "$before" ] \
    || fail "invalid recorded crew branch still moved local main"
  pass "fm-merge-local.sh refuses an invalid recorded crew branch"
}

test_last_crew_branch_line_wins_over_earlier_mention() {
  local case_dir home project after
  case_dir="$TMP_ROOT/last-line-wins"
  home="$case_dir/home"
  project="$case_dir/project"
  mkdir -p "$home/data/task-last" "$home/state"

  make_local_only_project "$project"
  git -C "$project" checkout -qb feature/decoy-first
  printf 'decoy\n' > "$project/decoy.txt"
  git -C "$project" add decoy.txt
  git -C "$project" commit -qm decoy-first
  git -C "$project" checkout -q main
  git -C "$project" checkout -qb feature/authoritative-last
  printf 'authoritative\n' > "$project/authoritative.txt"
  git -C "$project" add authoritative.txt
  git -C "$project" commit -qm authoritative-last
  git -C "$project" checkout -q main

  fm_write_meta "$home/state/task-last.meta" \
    "project=$project" "kind=ship" "mode=local-only"
  cat > "$home/data/task-last/brief.md" <<'EOF'
# Task
Crew branch: branch=feature/decoy-first

# Definition of done
Crew branch: branch=feature/authoritative-last
EOF

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-merge-local.sh" task-last >/dev/null \
    || fail "fm-merge-local.sh should merge the last recorded crew branch"
  after=$(git -C "$project" rev-parse HEAD)
  git -C "$project" merge-base --is-ancestor feature/authoritative-last main \
    || fail "last Crew branch line was not merged"
  git -C "$project" merge-base --is-ancestor feature/decoy-first main \
    && fail "an earlier Crew branch mention was merged instead of the last line"
  [ "$after" = "$(git -C "$project" rev-parse feature/authoritative-last)" ] \
    || fail "merge did not land on the last recorded crew branch tip"
  pass "fm-merge-local.sh uses the last Crew branch line, not an earlier mention"
}

test_recorded_custom_branch_merges
test_omitted_crew_branch_still_merges_fm_id
test_invalid_recorded_branch_refuses
test_last_crew_branch_line_wins_over_earlier_mention
