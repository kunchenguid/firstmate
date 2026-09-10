#!/usr/bin/env bash
# Behavior tests for bin/fm-merge-local.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-merge-local)
fm_git_identity fmtest fmtest@example.invalid

make_case() {  # <name> <task-id>
  local case_dir=$TMP_ROOT/$1 id=$2 project home
  project=$case_dir/project
  home=$case_dir/home
  mkdir -p "$project" "$home/data/$id" "$home/state"
  git -C "$project" init -q -b main
  printf 'base\n' > "$project/base.txt"
  git -C "$project" add base.txt
  git -C "$project" commit -qm base
  fm_write_meta "$home/state/$id.meta" \
    "project=$project" "kind=ship" "mode=local-only"
  printf '%s\n' "$case_dir"
}

commit_on() {  # <project> <branch> <file>
  local project=$1 branch=$2 file=$3
  git -C "$project" checkout -qb "$branch"
  printf '%s\n' "$branch" > "$project/$file"
  git -C "$project" add "$file"
  git -C "$project" commit -qm "$branch"
}

run_merge() {  # <case-dir> <task-id>
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$1/home" \
  FM_STATE_OVERRIDE="$1/home/state" \
  FM_DATA_OVERRIDE="$1/home/data" \
    "$ROOT/bin/fm-merge-local.sh" "$2"
}

test_recorded_custom_branch_merges() {
  local case_dir project id=task-custom
  case_dir=$(make_case custom "$id")
  project=$case_dir/project
  commit_on "$project" feature/custom custom.txt
  git -C "$project" checkout -q main
  printf '%s\n' '# Task' 'User text' '# Definition of done' 'Crew branch: branch=main' \
    '# Setup' 'Generated setup' '<!-- fm-generated-contract-boundary -->' '<!-- fm-generated-contract -->' '# Definition of done' \
    'Crew branch: branch=feature/custom' '<!-- fm-generated-contract-end -->' \
    > "$case_dir/home/data/$id/brief.md"
  run_merge "$case_dir" "$id" >/dev/null \
    || fail "merge-local refused the recorded custom crew branch"
  [ "$(git -C "$project" rev-parse main)" = "$(git -C "$project" rev-parse feature/custom)" ] \
    || fail "merge-local did not land the recorded custom crew branch"
  pass "merge-local lands the crew branch recorded by the brief"
}

test_legacy_recorded_custom_branch_merges() {
  local case_dir project id=task-legacy-custom
  case_dir=$(make_case legacy-custom "$id")
  project=$case_dir/project
  commit_on "$project" feature/custom custom.txt
  git -C "$project" checkout -q main
  printf '%s\n' '# Task' 'User text' '# Definition of done' 'Crew branch: branch=main' \
    '# Project memory' 'Generated project memory' '# Definition of done' \
    'Delivery contract: mode=local-only' 'The task is complete only when committed.' \
    'Crew branch: branch=feature/custom' \
    > "$case_dir/home/data/$id/brief.md"
  cat >> "$case_dir/home/data/$id/brief.md" <<'EOF'

## Progress note (2026-09-10T00:00:00Z)
Crew branch: branch=main

# Definition of done
Crew branch: branch=main
EOF
  run_merge "$case_dir" "$id" >/dev/null \
    || fail "merge-local refused the recorded custom crew branch from a legacy brief"
  [ "$(git -C "$project" rev-parse refs/heads/main)" = "$(git -C "$project" rev-parse refs/heads/feature/custom)" ] \
    || fail "merge-local did not land the legacy recorded custom crew branch"
  pass "merge-local preserves a custom crew branch from a pre-marker brief"
}

test_omitted_crew_branch_uses_fm_id() {
  local case_dir project id=task-default
  case_dir=$(make_case default "$id")
  project=$case_dir/project
  commit_on "$project" "fm/$id" work.txt
  git -C "$project" checkout -q main
  run_merge "$case_dir" "$id" >/dev/null \
    || fail "merge-local refused the historical fm/<id> branch"
  [ "$(git -C "$project" rev-parse main)" = "$(git -C "$project" rev-parse fm/$id)" ] \
    || fail "merge-local did not land the historical fm/<id> branch"
  pass "merge-local retains the fm/<id> crew-branch default"
}

test_last_recorded_crew_branch_wins() {
  local case_dir project id=task-last
  case_dir=$(make_case last "$id")
  project=$case_dir/project
  commit_on "$project" feature/first first.txt
  git -C "$project" checkout -q main
  commit_on "$project" feature/last last.txt
  git -C "$project" checkout -q main
  printf '%s\n' '<!-- fm-generated-contract-boundary -->' '<!-- fm-generated-contract -->' '# Definition of done' 'Crew branch: branch=feature/first' 'Crew branch: branch=feature/last' \
    > "$case_dir/home/data/$id/brief.md"
  run_merge "$case_dir" "$id" >/dev/null \
    || fail "merge-local refused the last recorded crew branch"
  [ "$(git -C "$project" rev-parse main)" = "$(git -C "$project" rev-parse feature/last)" ] \
    || fail "merge-local did not use the last crew-branch record"
  pass "merge-local uses the last recorded crew branch"
}

test_metadata_base_is_authoritative() {
  local case_dir project meta id=task-named main_before
  case_dir=$(make_case named "$id")
  project=$case_dir/project
  meta=$case_dir/home/state/$id.meta
  commit_on "$project" develop develop.txt
  commit_on "$project" "fm/$id" crew.txt
  git -C "$project" checkout -q main
  main_before=$(git -C "$project" rev-parse refs/heads/main)
  git -C "$project" tag develop refs/heads/main
  git -C "$project" tag "fm/$id" refs/heads/develop
  printf '%s\n' 'base_branch=develop' >> "$meta"
  printf '%s\n' 'Base branch contract: base_branch=release' \
    > "$case_dir/home/data/$id/brief.md"
  run_merge "$case_dir" "$id" >/dev/null \
    || fail "merge-local refused the metadata-recorded base"
  [ "$(git -C "$project" rev-parse refs/heads/main)" = "$main_before" ] \
    || fail "merge-local moved main instead of the metadata-recorded base"
  [ "$(git -C "$project" rev-parse refs/heads/develop)" = "$(git -C "$project" rev-parse refs/heads/fm/$id)" ] \
    || fail "merge-local did not land on the metadata-recorded base"
  pass "merge-local treats task metadata as the landing-base authority"
}

test_absent_metadata_base_uses_default() {
  local case_dir project id=task-no-base
  case_dir=$(make_case no-base "$id")
  project=$case_dir/project
  commit_on "$project" develop develop.txt
  git -C "$project" checkout -q main
  commit_on "$project" "fm/$id" crew.txt
  git -C "$project" checkout -q main
  printf '%s\n' 'Base branch contract: base_branch=develop' \
    > "$case_dir/home/data/$id/brief.md"
  run_merge "$case_dir" "$id" >/dev/null \
    || fail "merge-local refused the default landing base"
  [ "$(git -C "$project" rev-parse main)" = "$(git -C "$project" rev-parse fm/$id)" ] \
    || fail "brief prose overrode the absent metadata base"
  pass "merge-local defaults to the project default when metadata omits a base"
}

test_recorded_base_without_default_branch_merges() {
  local case_dir project id=task-no-default
  case_dir=$(make_case no-default "$id")
  project=$case_dir/project
  git -C "$project" checkout -qb develop
  git -C "$project" branch -D main >/dev/null
  commit_on "$project" "fm/$id" work.txt
  git -C "$project" checkout -q develop
  printf '%s\n' 'base_branch=develop' >> "$case_dir/home/state/$id.meta"

  run_merge "$case_dir" "$id" >/dev/null \
    || fail "merge-local required a default branch before using the recorded base"
  [ "$(git -C "$project" rev-parse develop)" = "$(git -C "$project" rev-parse "fm/$id")" ] \
    || fail "merge-local did not land on the recorded base without a default branch"
  pass "merge-local lands a recorded base without a conventional default branch"
}

test_invalid_metadata_base_refuses() {
  local case_dir project id=task-invalid out rc before
  case_dir=$(make_case invalid "$id")
  project=$case_dir/project
  commit_on "$project" "fm/$id" work.txt
  git -C "$project" checkout -q main
  before=$(git -C "$project" rev-parse main)
  printf '%s\n' 'base_branch=bad..name' >> "$case_dir/home/state/$id.meta"
  set +e
  out=$(run_merge "$case_dir" "$id" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "merge-local accepted an invalid metadata base"
  assert_contains "$out" 'records an invalid base branch' \
    "merge-local did not clearly reject the invalid metadata base"
  [ "$(git -C "$project" rev-parse main)" = "$before" ] \
    || fail "invalid metadata moved the default branch"
  pass "merge-local rejects an invalid metadata base"
}

test_diverged_branch_refuses() {
  local case_dir project id=task-diverged out rc before
  case_dir=$(make_case diverged "$id")
  project=$case_dir/project
  commit_on "$project" "fm/$id" crew.txt
  git -C "$project" checkout -q main
  printf 'main-only\n' > "$project/main.txt"
  git -C "$project" add main.txt
  git -C "$project" commit -qm main-only
  before=$(git -C "$project" rev-parse main)
  set +e
  out=$(run_merge "$case_dir" "$id" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "merge-local accepted a diverged crew branch"
  assert_contains "$out" 'is not a fast-forward' \
    "merge-local did not explain the divergence"
  [ "$(git -C "$project" rev-parse main)" = "$before" ] \
    || fail "divergence refusal moved the landing branch"
  pass "merge-local preserves its fast-forward-only safety gate"
}

test_recorded_custom_branch_merges
test_legacy_recorded_custom_branch_merges
test_omitted_crew_branch_uses_fm_id
test_last_recorded_crew_branch_wins
test_metadata_base_is_authoritative
test_absent_metadata_base_uses_default
test_recorded_base_without_default_branch_merges
test_invalid_metadata_base_refuses
test_diverged_branch_refuses

echo "# all fm-merge-local tests passed"
