#!/usr/bin/env bash
# Tests for the context-contract gate in bin/fm-merge-local.sh: a local-only
# landing whose branch carries project-code changes for a KNOWN slug (explicit
# repo->slug map: lia=>lia-core, lia-mascot=>lia-mascot, kg-hpmor=>kg-hpmor)
# must have that slug's detail record with its 4-key frontmatter
# (milestone/focus/blocker/next_move) in the home's data/projects/ dir.
#
# Matrix (each case drives the real script against a fixture project repo):
#   (a) code change with no detail record at all is REFUSED, naming the file
#   (b) code change with a detail record missing frontmatter keys is REFUSED
#   (c) code change with a complete frontmatter record lands (exit 0, merged)
#   (d) code change in an unknown repo warns and lands (warn-only, exit 0)
#   (e) a branch with no code changes lands without needing any record
#   (f) a failed diff probe refuses before the landing
#   (g) non-code-only changes (LICENSE, lockfile, image, metadata) land
#       without needing any record
#   (h) comment-valued or non-plain-scalar frontmatter values are REFUSED
#   (i) the body pointer must be a URL or an existing path; a slash-bearing
#       token that resolves nowhere is REFUSED, while a URL body lands
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-ctx-tests)

# make_repo <case-dir> <repo-name>: fixture project repo with a base commit on
# main and a fm/task-x1 branch carrying one code change. Leaves the checkout
# on main and clean, the way the merge gate expects. Echoes the repo path.
make_repo() {
  local case_dir=$1 name=$2 repo
  repo="$case_dir/$name"
  git init -q -b main "$repo"
  printf 'base\n' > "$repo/code.txt"
  git -C "$repo" add code.txt
  git -C "$repo" commit -qm base
  git -C "$repo" checkout -qb fm/task-x1
  printf 'change\n' >> "$repo/code.txt"
  git -C "$repo" commit -qam change
  git -C "$repo" checkout -q main
  printf '%s\n' "$repo"
}

# make_case <name> <repo-name>: state dir with a local-only task meta pointing
# at the fixture repo, plus an empty home detail dir. Echoes the case dir.
make_case() {
  local name=$1 repo_name=$2 case_dir repo
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/home/data/projects"
  repo=$(make_repo "$case_dir" "$repo_name")
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$repo" \
    "kind=ship" \
    "mode=local-only"
  printf '%s\n' "$case_dir"
}

run_merge_local() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" task-x1
}

test_lands_when_body_is_url() {
  local case_dir rc
  case_dir=$(make_case body-url lia-mascot)
  printf '%s\n' '---' 'milestone: m1' 'focus: things' 'blocker: none' 'next_move: ship' '---' 'Source: https://example.com/evidence.md' \
    > "$case_dir/home/data/projects/lia-mascot.md"

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "body-url: a body with a URL source pointer should be accepted"
  pass "fm-merge-local accepts a URL body pointer"
}

test_refuses_when_body_token_resolves_nowhere() {
  local case_dir rc
  case_dir=$(make_case body-fake-slash-token lia-mascot)
  printf '%s\n' '---' 'milestone: m1' 'focus: things' 'blocker: none' 'next_move: ship' '---' 'Source: fm/task-x1/notes' \
    > "$case_dir/home/data/projects/lia-mascot.md"

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "body-fake-slash-token: a slash token that resolves nowhere should be refused"
  assert_grep 'invalid frontmatter/detail record' "$case_dir/stderr" \
    "body-fake-slash-token: refusal did not identify the invalid record"
  pass "fm-merge-local refuses a slash token that resolves to no existing file"
}

test_lands_when_body_path_exists_in_repo() {
  local case_dir rc repo
  case_dir="$TMP_ROOT/body-existing-path"
  mkdir -p "$case_dir/state" "$case_dir/home/data/projects"
  repo="$case_dir/lia-mascot"
  git init -q -b main "$repo"
  mkdir -p "$repo/evidence"
  printf 'base\n' > "$repo/code.txt"
  printf 'notes\n' > "$repo/evidence/notes.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm base
  git -C "$repo" checkout -qb fm/task-x1
  printf 'change\n' >> "$repo/code.txt"
  git -C "$repo" commit -qam change
  git -C "$repo" checkout -q main
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$repo" \
    "kind=ship" \
    "mode=local-only"
  printf '%s\n' '---' 'milestone: m1' 'focus: things' 'blocker: none' 'next_move: ship' '---' 'Source: evidence/notes.md' \
    > "$case_dir/home/data/projects/lia-mascot.md"

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "body-existing-path: a body pointing at an existing repo file should be accepted"
  pass "fm-merge-local accepts a body pointer that resolves to an existing file"
}

test_non_code_only_diff_needs_no_record() {
  local case_dir rc repo
  case_dir="$TMP_ROOT/non-code-only"
  mkdir -p "$case_dir/state" "$case_dir/home/data/projects"
  repo="$case_dir/lia-mascot"
  git init -q -b main "$repo"
  printf 'base\n' > "$repo/code.txt"
  printf 'MIT\n' > "$repo/LICENSE"
  printf 'lock\n' > "$repo/package-lock.json"
  printf 'logs/\n' > "$repo/.gitignore"
  git -C "$repo" add -A
  git -C "$repo" commit -qm base
  git -C "$repo" checkout -qb fm/task-x1
  printf 'year\n' > "$repo/LICENSE"
  printf 'lock2\n' > "$repo/package-lock.json"
  printf 'dist/\n' > "$repo/.gitignore"
  git -C "$repo" commit -qam metadata
  git -C "$repo" checkout -q main
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$repo" \
    "kind=ship" \
    "mode=local-only"

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "non-code-only: LICENSE/lockfile/metadata-only changes should not require a detail record"
  [ "$(git -C "$repo" rev-parse main)" = "$(git -C "$repo" rev-parse fm/task-x1)" ] \
    || fail "non-code-only: main was not fast-forwarded to the branch"
  pass "fm-merge-local lands non-code-only changes without demanding a record"
}

test_refuses_when_record_missing() {
  local case_dir rc
  case_dir=$(make_case record-missing lia-mascot)

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "record-missing: landing without a detail record should be refused"
  assert_grep 'REFUSED' "$case_dir/stderr" "record-missing: refusal did not say REFUSED"
  assert_grep "$case_dir/home/data/projects/lia-mascot.md" "$case_dir/stderr" \
    "record-missing: refusal did not name the missing detail file"
  [ "$(git -C "$case_dir/lia-mascot" rev-parse main)" != "$(git -C "$case_dir/lia-mascot" rev-parse fm/task-x1)" ] \
    || fail "record-missing: refused landing still moved main"
  pass "fm-merge-local refuses code-without-record and names the detail file"
}

test_refuses_when_frontmatter_incomplete() {
  local case_dir rc
  case_dir=$(make_case frontmatter-incomplete lia-mascot)
  printf '%s\n' '---' 'milestone: m1' 'focus: things' '---' 'body' > "$case_dir/home/data/projects/lia-mascot.md"

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "frontmatter-incomplete: landing with a stale record should be refused"
  assert_grep 'lia-mascot.md' "$case_dir/stderr" \
    "frontmatter-incomplete: refusal did not name the detail file"
  assert_grep "blocker" "$case_dir/stderr" \
    "frontmatter-incomplete: refusal did not name the missing frontmatter key"
  pass "fm-merge-local refuses code-without-frontmatter and names the missing key"
}

test_lands_when_record_current() {
  local case_dir rc
  case_dir=$(make_case record-current lia-mascot)
  printf '%s\n' '---' 'milestone: m1' 'focus: things' 'blocker: none' 'next_move: ship' '---' 'Source: code.txt' \
    > "$case_dir/home/data/projects/lia-mascot.md"

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "record-current: landing with a current record should succeed"
  [ "$(git -C "$case_dir/lia-mascot" rev-parse main)" = "$(git -C "$case_dir/lia-mascot" rev-parse fm/task-x1)" ] \
    || fail "record-current: main was not fast-forwarded to the branch"
  pass "fm-merge-local lands code-with-frontmatter"
}

test_unknown_repo_warns_and_lands() {
  local case_dir rc
  case_dir=$(make_case unknown-repo something-else)

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "unknown-repo: landing for an unmapped repo should succeed"
  assert_grep 'warning' "$case_dir/stderr" "unknown-repo: warn-only path printed no warning"
  assert_grep 'something-else' "$case_dir/stderr" "unknown-repo: warning did not name the repo"
  [ "$(git -C "$case_dir/something-else" rev-parse main)" = "$(git -C "$case_dir/something-else" rev-parse fm/task-x1)" ] \
    || fail "unknown-repo: main was not fast-forwarded to the branch"
  pass "fm-merge-local warns once and lands for an unknown repo"
}

test_docs_only_diff_needs_no_record() {
  local case_dir rc repo
  case_dir="$TMP_ROOT/docs-only"
  mkdir -p "$case_dir/state" "$case_dir/home/data/projects"
  repo="$case_dir/lia-mascot"
  git init -q -b main "$repo"
  mkdir -p "$repo/docs"
  printf '# project\n' > "$repo/README.md"
  printf 'base docs\n' > "$repo/docs/guide.md"
  git -C "$repo" add README.md docs/guide.md
  git -C "$repo" commit -qm base
  git -C "$repo" checkout -qb fm/task-x1
  printf 'updated docs\n' >> "$repo/docs/guide.md"
  git -C "$repo" commit -qam docs
  git -C "$repo" checkout -q main
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$repo" \
    "kind=ship" \
    "mode=local-only"

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "docs-only: documentation changes should not require a detail record"
  [ "$(git -C "$repo" rev-parse main)" = "$(git -C "$repo" rev-parse fm/task-x1)" ] \
    || fail "docs-only: main was not fast-forwarded to the branch"
  pass "fm-merge-local ignores README/docs-only changes for the context gate"
}

test_refuses_malformed_record_shapes() {
  local shape case_dir rc
  for shape in missing-delimiters extra-key duplicate-key empty-value key-in-body extra-body; do
    case_dir=$(make_case "malformed-$shape" lia-mascot)
    case "$shape" in
      missing-delimiters)
        printf '%s\n' 'milestone: m1' 'focus: things' 'blocker: none' 'next_move: ship' '---' 'Source: code.txt' \
          > "$case_dir/home/data/projects/lia-mascot.md" ;;
      extra-key)
        printf '%s\n' '---' 'milestone: m1' 'extra: nope' 'focus: things' 'blocker: none' 'next_move: ship' '---' 'Source: code.txt' \
          > "$case_dir/home/data/projects/lia-mascot.md" ;;
      duplicate-key)
        printf '%s\n' '---' 'milestone: m1' 'milestone: m2' 'focus: things' 'blocker: none' 'next_move: ship' '---' 'Source: code.txt' \
          > "$case_dir/home/data/projects/lia-mascot.md" ;;
      empty-value)
        printf '%s\n' '---' 'milestone:' 'focus: things' 'blocker: none' 'next_move: ship' '---' 'Source: code.txt' \
          > "$case_dir/home/data/projects/lia-mascot.md" ;;
      key-in-body)
        printf '%s\n' '---' 'milestone: m1' 'focus: things' 'blocker: none' 'next_move: ship' '---' 'blocker: stale at code.txt' \
          > "$case_dir/home/data/projects/lia-mascot.md" ;;
      comment-value)
        printf '%s\n' '---' 'milestone: # unknown' 'focus: things' 'blocker: none' 'next_move: ship' '---' 'Source: code.txt' \
          > "$case_dir/home/data/projects/lia-mascot.md" ;;
      flow-value)
        printf '%s\n' '---' 'milestone: m1' 'focus: [' 'blocker: none' 'next_move: ship' '---' 'Source: code.txt' \
          > "$case_dir/home/data/projects/lia-mascot.md" ;;
      extra-body)
        printf '%s\n' '---' 'milestone: m1' 'focus: things' 'blocker: none' 'next_move: ship' '---' 'Source: code.txt' 'extra' \
          > "$case_dir/home/data/projects/lia-mascot.md" ;;
    esac

    set +e
    run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "malformed-$shape: malformed detail record should be refused"
    assert_grep 'invalid frontmatter/detail record' "$case_dir/stderr" \
      "malformed-$shape: refusal did not identify the invalid record"
  done
  pass "fm-merge-local refuses non-strict detail record shapes"
}

test_refuses_when_body_is_not_source_pointer() {
  local case_dir rc
  case_dir=$(make_case body-not-source lia-mascot)
  printf '%s\n' '---' 'milestone: m1' 'focus: things' 'blocker: none' 'next_move: ship' '---' 'body' \
    > "$case_dir/home/data/projects/lia-mascot.md"

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "body-not-source: a body without a source pointer should be refused"
  assert_grep 'invalid frontmatter/detail record' "$case_dir/stderr" \
    "body-not-source: refusal did not identify the invalid record"
  pass "fm-merge-local rejects a body without an authoritative source pointer"
}

test_refuses_when_diff_probe_fails() {
  local case_dir rc real_git fake_bin
  case_dir=$(make_case diff-probe-failure lia-mascot)
  real_git=$(command -v git)
  fake_bin="$case_dir/fake-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/git" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = diff ]; then
    for diff_arg in "\$@"; do
      [ "\$diff_arg" = --name-only ] && exit 73
    done
  fi
done
exec "$real_git" "\$@"
EOF
  chmod +x "$fake_bin/git"

  set +e
  PATH="$fake_bin:$PATH" run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "diff-probe-failure: a diff inspection failure should refuse the landing"
  assert_grep 'cannot inspect the project diff' "$case_dir/stderr" \
    "diff-probe-failure: refusal did not report the failed diff probe"
  [ "$(git -C "$case_dir/lia-mascot" rev-parse main)" != "$(git -C "$case_dir/lia-mascot" rev-parse fm/task-x1)" ] \
    || fail "diff-probe-failure: refused landing still moved main"
  pass "fm-merge-local propagates project diff probe failures"
}

test_empty_diff_needs_no_record() {
  local case_dir rc repo
  case_dir="$TMP_ROOT/empty-diff"
  mkdir -p "$case_dir/state" "$case_dir/home/data/projects"
  repo="$case_dir/lia-mascot"
  git init -q -b main "$repo"
  printf 'base\n' > "$repo/code.txt"
  git -C "$repo" add code.txt
  git -C "$repo" commit -qm base
  git -C "$repo" checkout -qb fm/task-x1
  git -C "$repo" checkout -q main
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$repo" \
    "kind=ship" \
    "mode=local-only"

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "empty-diff: a branch with no changes should land without a record"
  pass "fm-merge-local lands an empty branch diff without demanding a record"
}

test_refuses_when_record_missing
test_refuses_when_frontmatter_incomplete
test_lands_when_record_current
test_unknown_repo_warns_and_lands
test_docs_only_diff_needs_no_record
test_refuses_malformed_record_shapes
test_refuses_when_body_is_not_source_pointer
test_lands_when_body_is_url
test_refuses_when_body_token_resolves_nowhere
test_lands_when_body_path_exists_in_repo
test_non_code_only_diff_needs_no_record
test_refuses_when_diff_probe_fails
test_empty_diff_needs_no_record
