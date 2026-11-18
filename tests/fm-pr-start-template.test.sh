#!/usr/bin/env bash
# PR shape generation and verification through the public executable.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP=$(fm_test_tmproot fm-pr-start-template)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"
export FM_HOME="$TMP/home" SNAPSHOT="$TMP/pr.json"
export FM_PR_START_DEBOUNCE_SECS=3600
cat > "$TMP/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -eu
[ "$1 $2 $3" = 'api POST graphql' ] || exit 2
[ "$4" = --raw-field ] && [ "$6" = --jq ] || exit 2
[ "$7" = '.data.repository.pullRequest | ["pr-start", .state, (.isDraft | tostring), .headRefOid, .mergeable] | @tsv' ] || exit 2
jq -r '["pr-start", .state, (.isDraft | tostring), .headRefOid, .mergeable] | @tsv' "$SNAPSHOT"
SH
chmod +x "$TMP/bin/gh-axi"
export PATH="$TMP/bin:$PATH"
TOOL="$ROOT/bin/fm-pr-start-template.sh"
URL=https://github.com/example/project/pull/1
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
snapshot() {
  jq -cn --arg head "$1" --arg mergeable "${2:-MERGEABLE}" --arg state "${3:-OPEN}" --argjson draft "${4:-false}" \
    '{headRefOid:$head,mergeable:$mergeable,state:$state,isDraft:$draft}' > "$SNAPSHOT"
}
run() { RC=0; bash "$TOOL" "$@" > "$TMP/out" 2>&1 || RC=$?; OUT=$(< "$TMP/out"); }
expect_rc() { [ "$RC" -eq "$1" ] || fail "expected exit $1, got $RC: $OUT"; }
snapshot "$A"
run render review "$URL"; expect_rc 75
assert_contains "$OUT" "head $A needs 3600s quiet" 'review was not debounced'
export FM_PR_START_DEBOUNCE_SECS=0
run render review "$URL"; expect_rc 0
assert_contains "$OUT" "PR start: review $URL $A" 'review missing exact-head binding'
assert_contains "$OUT" "Reviewed head: $A" 'review report missing provenance'
run render review "$URL"; expect_rc 0
assert_contains "$OUT" 'skip: template already emitted' 'same head was emitted twice'
snapshot "$B"
export FM_PR_START_DEBOUNCE_SECS=3600
run render review "$URL"; expect_rc 75
assert_contains "$OUT" "head $B" 'push did not reset debounce'
run verify "$URL" "$A"; expect_rc 2
assert_contains "$OUT" 'superseded PR head' 'stale head accepted'
run verify "$URL" "$B"; expect_rc 0
run render conflict "$URL"; expect_rc 2
snapshot "$B" UNKNOWN
run render conflict "$URL"; expect_rc 2
snapshot "$B" CONFLICTING
run render conflict "$URL"; expect_rc 0
assert_contains "$OUT" "PR start: conflict $URL $B" 'confirmed conflict missing binding'
run verify "$URL" "$B" conflict; expect_rc 0
printf 'Reviewed head: %s\nFinding: regression at file:1\n' "$A" > "$TMP/findings"
run render follow-up "$URL" "$TMP/findings"; expect_rc 2
printf 'Reviewed head: %s\nFinding: regression at file:1\n' "$B" > "$TMP/findings"
run render follow-up "$URL" "$TMP/findings"; expect_rc 0
assert_contains "$OUT" 'Finding: regression at file:1' 'follow-up lost findings'
first_id=$(printf '%s\n' "$OUT" | grep '^PR task id:')
run render follow-up "$URL" "$TMP/findings"; expect_rc 0
assert_contains "$OUT" 'skip: template already emitted' 'same findings emitted twice'
printf 'Reviewed head: %s\nFinding: another regression at file:2\n' "$B" > "$TMP/findings"
run render follow-up "$URL" "$TMP/findings"; expect_rc 0
second_id=$(printf '%s\n' "$OUT" | grep '^PR task id:')
[ "$first_id" != "$second_id" ] || fail 'new findings reused an existing task identity'
snapshot "$B" MERGEABLE CLOSED
run verify "$URL" "$B"; expect_rc 2
snapshot "$B" MERGEABLE OPEN true
run render review "$URL"; expect_rc 2
snapshot "$B"
run drop "$URL"; expect_rc 0
run render review "$URL"; expect_rc 75
pass 'PR shapes bind exact heads, debounce changed heads, dedupe emissions, and refuse stale findings/unknown conflicts/closed or draft PRs'
