#!/usr/bin/env bash
# Characterization coverage for fm-ff-lib's primary default-branch resolution.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
# shellcheck disable=SC2153
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ff-lib-tests)
REPO="$TMP_ROOT/repo"
mkdir -p "$REPO"

git -C "$REPO" init -q -b main
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.invalid
printf '%s\n' base > "$REPO/file"
git -C "$REPO" add file
git -C "$REPO" commit -q -m base
main_sha=$(git -C "$REPO" rev-parse refs/heads/main)
git -C "$REPO" checkout -q -b feature
printf '%s\n' feature >> "$REPO/file"
git -C "$REPO" commit -q -am feature
feature_sha=$(git -C "$REPO" rev-parse HEAD)

FM_ROOT="$REPO"
FM_HOME="$REPO"
# shellcheck source=bin/fm-ff-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-ff-lib.sh"

[ "$feature_sha" != "$main_sha" ] || fail "fixture branches must differ"
[ "$(primary_head_commit "$REPO")" = "$main_sha" ] \
  || fail "primary_head_commit must resolve the default branch, not feature HEAD"
pass "primary_head_commit follows the local default branch while checkout HEAD is feature work"

echo "# fm-ff-lib.test.sh: all assertions passed"
