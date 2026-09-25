#!/usr/bin/env bash
# tests/fm-branch-name-lib.test.sh - behavior tests for the ship branch name
# derived from a task id (bin/fm-branch-name-lib.sh). Pure function, no backend.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-branch-name-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-branch-name)
OFF="$TMP_ROOT/config-off"
ON="$TMP_ROOT/config-on"
mkdir -p "$OFF" "$ON"
: >"$ON/ship-branch-ticket-case"

# --- without the opt-in flag the id is used verbatim -------------------------

for id in 've-1263-deploy-uat' 've1262-backoff-retry' 'gh-5682-fix'; do
  [ "$(fm_ship_branch_name 'fm/' "$id" "$OFF")" = "fm/$id" ] ||
    fail "a home without the flag must keep the id verbatim: $id -> $(fm_ship_branch_name 'fm/' "$id" "$OFF")"
  [ "$(fm_ship_branch_name 'fm/' "$id")" = "fm/$id" ] ||
    fail "a caller passing no config dir must keep the id verbatim: $id"
done
pass "ticket normalization is off unless the home opts in"

# --- a ticket token is canonicalized to uppercase KEY-NNN --------------------

[ "$(fm_ship_branch_name 'fm/' 've-1263-deploy-uat' "$ON")" = "fm/VE-1263-deploy-uat" ] ||
  fail "already-dashed ticket was not uppercased: $(fm_ship_branch_name 'fm/' 've-1263-deploy-uat' "$ON")"
pass "a leading ve-1263 ticket becomes VE-1263"

[ "$(fm_ship_branch_name 'fm/' 've1262-backoff-retry' "$ON")" = "fm/VE-1262-backoff-retry" ] ||
  fail "dashless ticket was not canonicalized: $(fm_ship_branch_name 'fm/' 've1262-backoff-retry' "$ON")"
pass "a dashless ve1262 ticket gains its canonical dash and case"

[ "$(fm_ship_branch_name 'fm/' 'visto-pipelines-ve1262-backoff-retry' "$ON")" = "fm/visto-pipelines-VE-1262-backoff-retry" ] ||
  fail "an embedded ticket was not normalized in place: $(fm_ship_branch_name 'fm/' 'visto-pipelines-ve1262-backoff-retry' "$ON")"
pass "a ticket embedded mid-id is normalized without moving it"

[ "$(fm_ship_branch_name 'fm/' 'es-pipelines-ve1247-mysql2-tls' "$ON")" = "fm/es-pipelines-VE-1247-mysql2-tls" ] ||
  fail "ticket next to a version-like slug was mishandled: $(fm_ship_branch_name 'fm/' 'es-pipelines-ve1247-mysql2-tls' "$ON")"
pass "mysql2 in the same id is left alone while the ticket is normalized"

[ "$(fm_ship_branch_name 'fm/' 'dark1063-token' "$ON")" = "fm/DARK-1063-token" ] ||
  fail "a second Jira project key was not canonicalized: $(fm_ship_branch_name 'fm/' 'dark1063-token' "$ON")"
pass "another Jira project key (dark) is canonicalized the same way"

[ "$(fm_ship_branch_name 'fm/' 'VE-1263-already' "$ON")" = "fm/VE-1263-already" ] ||
  fail "an already-canonical ticket must be idempotent: $(fm_ship_branch_name 'fm/' 'VE-1263-already' "$ON")"
pass "an already-canonical ticket is unchanged"

# --- ids that are not tickets are returned unchanged -------------------------

for plain in 'pim-ci-tag-slug-fix' 'fm-opencode-arm-not-needed-falso-falha' 'pim-sdk-release-v121' 'bmsantander'; do
  got=$(fm_ship_branch_name 'fm/' "$plain" "$ON")
  [ "$got" = "fm/$plain" ] || fail "a ticketless id must be unchanged: $plain -> $got"
done
pass "ticketless ids (including the v121 version-like slug) are returned unchanged"

# A version-like fragment must not be mistaken for a ticket: v121 is one letter,
# php8 is one digit, mysql2 is five letters, api could be a real slug.
[ "$(fm_ship_branch_name 'fm/' 'pim-sdk-release-v121' "$ON")" = "fm/pim-sdk-release-v121" ] ||
  fail "v121 was rewritten as a ticket"
[ "$(fm_ship_branch_name 'fm/' 'upgrade-php8' "$ON")" = "fm/upgrade-php8" ] ||
  fail "php8 was rewritten as a ticket"
pass "short slug fragments that only look ticket-shaped are not rewritten"

# --- the prefix is a plain concatenation, including the empty prefix ---------

[ "$(fm_ship_branch_name '' 've-1263-x' "$ON")" = "VE-1263-x" ] ||
  fail "an empty prefix must yield a bare normalized id: $(fm_ship_branch_name '' 've-1263-x' "$ON")"
[ "$(fm_ship_branch_name 'release/' 've-1263-x' "$ON")" = "release/VE-1263-x" ] ||
  fail "a custom prefix must be preserved: $(fm_ship_branch_name 'release/' 've-1263-x' "$ON")"
pass "any prefix is concatenated verbatim in front of the normalized id"

# --- the expected branch is the recorded one that no-mistakes consumes -------

# This pins the exact string a `commit.fix_message`/`pr.title_format`
# `{{.Branch}}` sees, which is why the case is canonicalized at all.
BRANCH=$(fm_ship_branch_name 'fm/' 'visto-system-ve1263-deploy-uat' "$ON")
case "$BRANCH" in
  *'VE-1263'*) : ;;
  *) fail "the derived branch must carry the canonical ticket: $BRANCH" ;;
esac
pass "the derived branch carries the canonical ticket token no-mistakes reads"
