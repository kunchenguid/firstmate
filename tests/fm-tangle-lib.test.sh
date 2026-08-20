#!/usr/bin/env bash
# Characterization coverage for the shared worktree-tangle classification helpers.
set -u

# shellcheck source=tests/lib.sh disable=SC1091,SC2153
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tangle-lib)
REPO="$TMP_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" commit -q --allow-empty -m base
base_sha=$(git -C "$REPO" rev-parse refs/heads/main)

# shellcheck source=bin/fm-tangle-lib.sh disable=SC1091
# shellcheck disable=SC2153
. "$ROOT/bin/fm-tangle-lib.sh"

[ "$(fm_default_branch "$REPO")" = main ] \
  || fail "fm_default_branch must fall back to the local main branch"
[ -z "$(fm_primary_tangle_branch "$REPO" || true)" ] \
  || fail "the primary default branch must not be reported as tangled"

git -C "$REPO" checkout -q -b feature
[ "$(fm_primary_tangle_branch "$REPO")" = feature ] \
  || fail "a named non-default branch must report its exact branch name"

git -C "$REPO" checkout -q main
git -C "$REPO" commit -q --allow-empty -m advance
default_sha=$(git -C "$REPO" rev-parse refs/heads/main)
git -C "$REPO" checkout -q --detach "$base_sha"
lag=$(fm_checkout_lag "$REPO")
[ "$lag" = "$base_sha main $default_sha" ] \
  || fail "a detached checkout behind local main must report both SHAs (got '$lag')"
[ -z "$(fm_checkout_lag "$TMP_ROOT" || true)" ] \
  || fail "a non-git directory must not be classified as checkout lag"

pass "fm-tangle-lib classifies default branches, tangled branches, and checkout lag"
echo "# fm-tangle-lib.test.sh: all assertions passed"
