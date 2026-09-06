#!/usr/bin/env bash
# tests/fm-nm-run-lib.test.sh - unit tests for the no-mistakes run-attribution
# primitives (bin/fm-nm-run-lib.sh). These drive fm_nm_runs_status_for_worktree
# through its function interface against a real git worktree; no no-mistakes
# binary and no harness are required.
#
# The focus here is the optional PR-URL column of a `no-mistakes axi runs` row:
# a self-hosted Gitea/Forgejo instance can be plain http (bin/fm-pr-lib.sh), so
# a plain-http PR URL in that column must not make the run row read as
# malformed and silently drop the attributed status.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-nm-run-lib.sh
. "$ROOT/bin/fm-nm-run-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-run-lib)

WT="$TMP_ROOT/wt"
fm_git_init_commit "$WT"
git -C "$WT" checkout -q -b fm/nm-run-lib-probe
HEAD=$(git -C "$WT" rev-parse HEAD)
BRANCH=fm/nm-run-lib-probe

runs_row() {  # <pr-column>
  printf 'running %s %s 2026-09-06 12:00 %s\n' "$BRANCH" "$HEAD" "$1"
}

# --- the PR-URL column accepts both schemes ---------------------------------

out=$(fm_nm_runs_status_for_worktree "$WT" "$BRANCH" "$(runs_row 'http://alps:3222/babbarc/server-ops/pulls/1')" "$HEAD")
[ "$out" = "running" ] \
  || fail "a plain-http Gitea PR URL in the runs row dropped the attributed status (got '$out')"
pass "fm_nm_runs_status_for_worktree attributes a run whose PR-URL column is a plain-http Gitea URL"

out=$(fm_nm_runs_status_for_worktree "$WT" "$BRANCH" "$(runs_row 'https://github.com/example/repo/pull/7')" "$HEAD")
[ "$out" = "running" ] \
  || fail "an https PR URL in the runs row dropped the attributed status (got '$out')"
pass "fm_nm_runs_status_for_worktree still attributes a run whose PR-URL column is an https URL"

out=$(fm_nm_runs_status_for_worktree "$WT" "$BRANCH" "$(runs_row '')" "$HEAD")
[ "$out" = "running" ] \
  || fail "a runs row with no PR-URL column dropped the attributed status (got '$out')"
pass "fm_nm_runs_status_for_worktree still attributes a run whose row carries no PR-URL column"

# --- a genuinely malformed PR-URL column still voids the row ---------------

out=$(fm_nm_runs_status_for_worktree "$WT" "$BRANCH" "$(runs_row 'ftp://nope/x')" "$HEAD")
[ -z "$out" ] \
  || fail "a non-http(s) PR-URL column must void the run row, but it attributed '$out'"
pass "fm_nm_runs_status_for_worktree rejects a run row whose PR-URL column is neither http nor https"

echo "# fm-nm-run-lib.test.sh: all assertions passed"
