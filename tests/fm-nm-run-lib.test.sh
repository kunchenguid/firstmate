#!/usr/bin/env bash
# Characterization coverage for fm-nm-run-lib's attribution and parsing helpers.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-run-lib-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf 'fake stdout\n'
printf 'fake stderr\n' >&2
exit "${FAKE_NO_MISTAKES_STATUS:-0}"
SH
chmod +x "$FAKEBIN/no-mistakes"
PATH="$FAKEBIN:$PATH"

# shellcheck source=bin/fm-nm-run-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-nm-run-lib.sh"

[ "$(fm_nm_trim '  value  ')" = value ] || fail "fm_nm_trim removes surrounding whitespace"
[ "$(fm_nm_strip_quotes '  "value"  ')" = value ] || fail "fm_nm_strip_quotes removes surrounding quotes"
[ "$(fm_nm_field $'state: parked\nstate: ignored' state)" = parked ] \
  || fail "fm_nm_field returns the first matching scalar"

[ "$(fm_nm_run_bounded "$TMP_ROOT" 5 status 2>&1)" = $'fake stdout\nfake stderr' ] \
  || fail "fm_nm_run_bounded preserves command output"
FAKE_NO_MISTAKES_STATUS=7
export FAKE_NO_MISTAKES_STATUS
[ "$(fm_nm_run_checked "$TMP_ROOT" 5 status >/dev/null 2>&1; echo $?)" -eq 7 ] \
  || fail "fm_nm_run_checked preserves the command exit status"
[ "$(fm_nm_run "$TMP_ROOT" 5 status >/dev/null 2>&1; echo $?)" -eq 0 ] \
  || fail "fm_nm_run is fail-open"

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.invalid
printf '%s\n' base > "$REPO/file"
git -C "$REPO" add file
git -C "$REPO" commit -q -m base
printf '%s\n' next >> "$REPO/file"
git -C "$REPO" commit -q -am next
next_sha=$(git -C "$REPO" rev-parse HEAD)
printf '%s\n' future >> "$REPO/file"
git -C "$REPO" commit -q -am future
future_sha=$(git -C "$REPO" rev-parse HEAD)

git -C "$REPO" checkout -q "$next_sha"
fm_nm_head_matches_worktree "$REPO" "$future_sha" \
  || fail "fm_nm_head_matches_worktree accepts an ancestor run head"
fm_nm_head_matches_worktree "$REPO" "$next_sha" \
  || fail "fm_nm_head_matches_worktree accepts the current run head"
if fm_nm_head_matches_worktree "$REPO" ''; then
  fail "fm_nm_head_matches_worktree rejects an empty run head"
fi

pass "fm-nm-run-lib preserves no-mistakes output, fail-open status, parsing, and git attribution"
echo "# fm-nm-run-lib.test.sh: all assertions passed"
