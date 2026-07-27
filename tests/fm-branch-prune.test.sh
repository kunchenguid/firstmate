#!/usr/bin/env bash
# Tests for bin/fm-branch-prune.sh: the guarded forge-level remote branch prune.
#
# Classification must use PR merge state (not git ancestry), protect long-lived
# refs, refuse base-branch orphaning, keep closed-unmerged and no-PR branches,
# dry-run by default, and append a durable decision log under data/.
#
# Matrix:
#   (a) dry-run classifies merged as candidates and does not call delete
#   (b) protected refs (main) are never candidates even with a merged PR head
#   (c) open PR heads are kept
#   (d) closed-unmerged heads are kept and surfaced
#   (e) no-PR branches are kept and surfaced
#   (f) a merged head that is another open PR's base is kept (orphan guard)
#   (g) --apply --yes deletes only safe candidates and logs them
#   (h) --apply without --yes on a non-tty refuses before any delete
#   (i) missing --repo / bad repo shape fail fast
#   (j) durable log records kept and dry-run decisions
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PRUNE="$ROOT/bin/fm-branch-prune.sh"
TMP_ROOT=$(fm_test_tmproot fm-branch-prune-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/data" "$case_dir/fakebin" "$case_dir/fixtures"
  printf '%s\n' "$case_dir"
}

# Minimal GitHub REST-shaped fixtures covering the classification buckets.
write_fixtures() {
  local case_dir=$1
  cat > "$case_dir/fixtures/prs.json" <<'JSON'
[
  {
    "number": 10,
    "state": "closed",
    "merged_at": "2026-07-01T00:00:00Z",
    "html_url": "https://github.com/example/repo/pull/10",
    "head": { "ref": "fm/landed-feature" },
    "base": { "ref": "main", "repo": { "full_name": "example/repo" } }
  },
  {
    "number": 11,
    "state": "open",
    "merged_at": null,
    "html_url": "https://github.com/example/repo/pull/11",
    "head": { "ref": "fm/open-work" },
    "base": { "ref": "main", "repo": { "full_name": "example/repo" } }
  },
  {
    "number": 12,
    "state": "closed",
    "merged_at": null,
    "html_url": "https://github.com/example/repo/pull/12",
    "head": { "ref": "fm/abandoned" },
    "base": { "ref": "main", "repo": { "full_name": "example/repo" } }
  },
  {
    "number": 13,
    "state": "closed",
    "merged_at": "2026-07-02T00:00:00Z",
    "html_url": "https://github.com/example/repo/pull/13",
    "head": { "ref": "fm/integration-base" },
    "base": { "ref": "main", "repo": { "full_name": "example/repo" } }
  },
  {
    "number": 14,
    "state": "open",
    "merged_at": null,
    "html_url": "https://github.com/example/repo/pull/14",
    "head": { "ref": "fm/stacked-on-integration" },
    "base": { "ref": "fm/integration-base", "repo": { "full_name": "example/repo" } }
  },
  {
    "number": 15,
    "state": "closed",
    "merged_at": "2026-07-03T00:00:00Z",
    "html_url": "https://github.com/example/repo/pull/15",
    "head": { "ref": "main" },
    "base": { "ref": "main", "repo": { "full_name": "example/repo" } }
  }
]
JSON

  cat > "$case_dir/fixtures/branches.json" <<'JSON'
[
  { "name": "main" },
  { "name": "fm/landed-feature" },
  { "name": "fm/open-work" },
  { "name": "fm/abandoned" },
  { "name": "fm/integration-base" },
  { "name": "fm/stacked-on-integration" },
  { "name": "fm/never-proposed" },
  { "name": "develop" }
]
JSON
}

# gh mock that records DELETE calls and succeeds. Live list paths are unused
# when fixtures are provided; still refuse unexpected non-DELETE traffic so a
# regression that drops --prs-file fails loudly.
add_gh_mock() {
  local case_dir=$1 mode=${2:-ok}
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/gh.log"
# Capture method + path for assertions.
if [ "\${1:-}" = "api" ] && [ "\${2:-}" = "--method" ] && [ "\${3:-}" = "DELETE" ]; then
  printf '%s\n' "\$4" >> "$case_dir/gh-delete.log"
  if [ "$mode" = "fail-delete" ]; then
    echo "error: delete failed" >&2
    exit 1
  fi
  exit 0
fi
echo "error: unexpected gh invocation in fixture mode: \$*" >&2
exit 99
SH
  chmod +x "$case_dir/fakebin/gh"
}

run_prune() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_BRANCH_PRUNE_LOG="$case_dir/data/branch-prune.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PRUNE" "$@"
}

run_prune_fixtures() {
  local case_dir=$1
  shift
  run_prune "$case_dir" \
    --repo example/repo \
    --prs-file "$case_dir/fixtures/prs.json" \
    --branches-file "$case_dir/fixtures/branches.json" \
    "$@"
}

test_dry_run_classifies_without_deleting() {
  local case_dir rc out
  case_dir=$(make_case dry-run-classify)
  write_fixtures "$case_dir"
  add_gh_mock "$case_dir"
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-delete.log"

  set +e
  run_prune_fixtures "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "dry-run-classify: should succeed"
  out=$(cat "$case_dir/stdout")
  assert_contains "$out" "mode: dry-run" "dry-run-classify: mode"
  assert_contains "$out" "fm/landed-feature" "dry-run-classify: merged candidate listed"
  assert_contains "$out" "SAFE TO DELETE" "dry-run-classify: safe section"
  assert_contains "$out" "candidates: 1" "dry-run-classify: only one safe candidate"
  assert_contains "$out" "KEPT closed-unmerged" "dry-run-classify: closed-unmerged surfaced"
  assert_contains "$out" "fm/abandoned" "dry-run-classify: abandoned branch named"
  assert_contains "$out" "KEPT with no PR" "dry-run-classify: no-pr surfaced"
  assert_contains "$out" "fm/never-proposed" "dry-run-classify: never-proposed named"
  # Open heads and open-PR bases are kept quietly in the durable log (not a
  # captain-facing "investigate" bucket like closed-unmerged / no-PR).
  assert_grep "reason=open_pr" "$case_dir/data/branch-prune.log" \
    "dry-run-classify: open_pr not logged"
  assert_grep "fm/open-work" "$case_dir/data/branch-prune.log" \
    "dry-run-classify: open-work branch not logged"
  assert_grep "reason=open_pr_base" "$case_dir/data/branch-prune.log" \
    "dry-run-classify: open_pr_base not logged for integration-base"
  if [ -s "$case_dir/gh-delete.log" ]; then
    fail "dry-run-classify: delete was invoked in dry-run"
  fi
  assert_grep "dry-run" "$case_dir/data/branch-prune.log" \
    "dry-run-classify: log missing dry-run entry"
  assert_grep "fm/landed-feature" "$case_dir/data/branch-prune.log" \
    "dry-run-classify: log missing candidate branch"
  pass "dry-run classifies merged vs kept buckets without deleting"
}

test_protected_and_orphan_base_kept() {
  local case_dir rc out
  case_dir=$(make_case protect-orphan)
  write_fixtures "$case_dir"
  add_gh_mock "$case_dir"

  set +e
  run_prune_fixtures "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "protect-orphan: should succeed"
  out=$(cat "$case_dir/stdout")

  # main and develop are protected - never candidates even if a PR head is main.
  assert_contains "$out" "candidates: 1" "protect-orphan: only landed-feature is safe"
  # integration-base is merged but is base of open PR 14 -> kept, not candidate.
  assert_no_grep $'delete\tfm/integration-base' "$case_dir/stdout" \
    "protect-orphan: integration-base must not be listed as SAFE alone wrongly"
  # Log should record protected + open_pr_base keeps.
  assert_grep "reason=protected_ref" "$case_dir/data/branch-prune.log" \
    "protect-orphan: protected_ref not logged"
  assert_grep "reason=open_pr_base" "$case_dir/data/branch-prune.log" \
    "protect-orphan: open_pr_base not logged for integration-base"
  assert_grep "reason=open_pr" "$case_dir/data/branch-prune.log" \
    "protect-orphan: open_pr not logged"
  pass "protected refs and open-PR bases are kept, not deleted"
}

test_apply_deletes_only_safe_candidate() {
  local case_dir rc out
  case_dir=$(make_case apply-safe)
  write_fixtures "$case_dir"
  add_gh_mock "$case_dir"
  : > "$case_dir/gh-delete.log"

  set +e
  run_prune_fixtures "$case_dir" --apply --yes \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "apply-safe: should succeed"
  out=$(cat "$case_dir/stdout")
  assert_contains "$out" "mode: apply" "apply-safe: mode"
  assert_contains "$out" "deleted: 1" "apply-safe: one delete"
  assert_contains "$out" "deleted: fm/landed-feature" "apply-safe: landed-feature deleted"
  # Exactly one DELETE path, and it is the safe branch.
  lines=$(wc -l < "$case_dir/gh-delete.log" | tr -d ' ')
  [ "$lines" = "1" ] || fail "apply-safe: expected 1 delete call, got $lines"
  assert_grep "git/refs/heads/fm%2Flanded-feature" "$case_dir/gh-delete.log" \
    "apply-safe: delete path missing encoded branch"
  assert_grep $'deleted\texample/repo\tfm/landed-feature' "$case_dir/data/branch-prune.log" \
    "apply-safe: durable deleted log missing"
  # Must not delete open / abandoned / integration-base / never-proposed / main.
  assert_no_grep "fm%2Fopen-work" "$case_dir/gh-delete.log" "apply-safe: open deleted"
  assert_no_grep "fm%2Fabandoned" "$case_dir/gh-delete.log" "apply-safe: abandoned deleted"
  assert_no_grep "fm%2Fintegration-base" "$case_dir/gh-delete.log" "apply-safe: base deleted"
  assert_no_grep "fm%2Fnever-proposed" "$case_dir/gh-delete.log" "apply-safe: no-pr deleted"
  assert_no_grep "heads/main" "$case_dir/gh-delete.log" "apply-safe: main deleted"
  pass "apply --yes deletes only the safe merged candidate and logs it"
}

test_apply_without_yes_refuses_nontty() {
  local case_dir rc
  case_dir=$(make_case apply-no-yes)
  write_fixtures "$case_dir"
  add_gh_mock "$case_dir"
  : > "$case_dir/gh-delete.log"

  set +e
  # stdin is not a tty in the test harness.
  run_prune_fixtures "$case_dir" --apply \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "apply-no-yes: should refuse without --yes on non-tty"
  assert_grep "requires an interactive confirm" "$case_dir/stderr" \
    "apply-no-yes: missing confirm error"
  if [ -s "$case_dir/gh-delete.log" ]; then
    fail "apply-no-yes: delete ran despite missing --yes"
  fi
  pass "apply without --yes refuses on non-tty before any delete"
}

test_missing_repo_fails_fast() {
  local case_dir rc
  case_dir=$(make_case missing-repo)
  write_fixtures "$case_dir"
  add_gh_mock "$case_dir"

  set +e
  run_prune "$case_dir" \
    --prs-file "$case_dir/fixtures/prs.json" \
    --branches-file "$case_dir/fixtures/branches.json" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "missing-repo: should exit 2"
  assert_grep "--repo" "$case_dir/stderr" "missing-repo: should mention --repo"
  pass "missing --repo fails fast"
}

test_bad_repo_shape_fails_fast() {
  local case_dir rc
  case_dir=$(make_case bad-repo)
  write_fixtures "$case_dir"
  add_gh_mock "$case_dir"

  set +e
  run_prune "$case_dir" --repo "not-a-pair" \
    --prs-file "$case_dir/fixtures/prs.json" \
    --branches-file "$case_dir/fixtures/branches.json" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "bad-repo: should exit 2"
  assert_grep "OWNER/REPO" "$case_dir/stderr" "bad-repo: should mention OWNER/REPO"
  pass "bad --repo shape fails fast"
}

test_delete_failure_propagates() {
  local case_dir rc
  case_dir=$(make_case delete-fail)
  write_fixtures "$case_dir"
  add_gh_mock "$case_dir" fail-delete

  set +e
  run_prune_fixtures "$case_dir" --apply --yes \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "delete-fail: should exit 1 on delete failure"
  assert_grep "delete_failed" "$case_dir/data/branch-prune.log" \
    "delete-fail: delete_failed not logged"
  pass "delete failure is logged and non-zero"
}

test_help_exits_zero() {
  local case_dir rc
  case_dir=$(make_case help)
  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir" \
    "$PRUNE" --help > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "help: should exit 0"
  assert_contains "$(cat "$case_dir/stderr")" "Usage:" "help: usage on stderr"
  pass "help exits zero"
}

test_dry_run_classifies_without_deleting
test_protected_and_orphan_base_kept
test_apply_deletes_only_safe_candidate
test_apply_without_yes_refuses_nontty
test_missing_repo_fails_fast
test_bad_repo_shape_fails_fast
test_delete_failure_propagates
test_help_exits_zero
