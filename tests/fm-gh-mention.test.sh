#!/usr/bin/env bash
# Behavior tests for bin/fm-gh-mention.sh, the GitHub mention plane.
#
# Every case drives the real executable against a scratch home whose config,
# project clones and fake `gh` decide the outcome, so the safety core is
# exercised the way the watcher exercises it. Nothing here reads the script's
# own source, and no case contacts github.com.
#
# The fake `gh` serves one canned listing per repository and endpoint from
# $FM_TEST_GH_DIR and records the API paths it was asked for, which is how the
# "never reads an unwatched repo" and one-page baseline-cost properties are
# asserted through the interface rather than by inspecting internals.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLANE="$ROOT/bin/fm-gh-mention.sh"
TMP_ROOT=$(fm_test_tmproot fm-gh-mention)
FAKEBIN="$TMP_ROOT/fakebin"

mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'FAKE'
#!/usr/bin/env bash
# Fake gh for the mention plane's tests: canned listings plus a request log.
for arg in "$@"; do last=$arg; done
path=${last%%\?*}
query=${last#*\?}
printf '%s\n' "$path" >> "$FM_TEST_GH_DIR/paths.log"
case "$path" in
  */issues/comments) kind=comments ;;
  */pulls/comments) kind=review ;;
  */issues) kind=issues ;;
  *) printf '[]\n'; exit 0 ;;
esac
repo=$(printf '%s' "$path" | sed -n 's|^repos/\([^/]*\)/\([^/]*\)/.*|\1__\2|p')
if [ -f "$FM_TEST_GH_DIR/unreadable" ] && grep -Fxq "${repo/__//}" "$FM_TEST_GH_DIR/unreadable"; then
  printf '%s\n' '{"message":"Not Found","documentation_url":"https://docs.github.com/rest"}'
  exit 1
fi
if [ -f "$FM_TEST_GH_DIR/ratelimit" ]; then
  printf '%s\n' '{"message":"API rate limit exceeded for user ID 1.","documentation_url":"https://docs.github.com/rest/overview/rate-limits"}'
  exit 1
fi
[ -f "$FM_TEST_GH_DIR/fail" ] && exit 1
page=$(printf '%s\n' "$query" | tr '&' '\n' | sed -n 's/^page=//p')
page=${page:-1}
count_file="$FM_TEST_GH_DIR/$repo.$kind.page-$page.count"
count=$(cat "$count_file" 2>/dev/null || printf '0\n')
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [ -f "$FM_TEST_GH_DIR/$repo.$kind.fail-page-$page" ]; then
  exit 1
fi
if [ -f "$FM_TEST_GH_DIR/$repo.$kind.page-$page.call-$count.json" ]; then
  cat "$FM_TEST_GH_DIR/$repo.$kind.page-$page.call-$count.json"
elif [ -f "$FM_TEST_GH_DIR/$repo.$kind.page-$page.json" ]; then
  cat "$FM_TEST_GH_DIR/$repo.$kind.page-$page.json"
elif [ "$page" = 1 ] && [ -f "$FM_TEST_GH_DIR/$repo.$kind.json" ]; then
  cat "$FM_TEST_GH_DIR/$repo.$kind.json"
else
  printf '[]\n'
fi
FAKE
chmod +x "$FAKEBIN/gh"

# make_home <name> [config-json]: a scratch home, optionally already configured.
make_home() {
  local name=$1 config=${2-} home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/gh"
  [ -z "$config" ] || printf '%s\n' "$config" > "$home/config/gh-mentions.json"
  printf '%s\n' "$home"
}

# canned <home> <owner/name> <endpoint> <json>: what the fake gh serves.
canned() {
  local home=$1 repo=$2 kind=$3 json=$4
  printf '%s\n' "$json" > "$home/gh/${repo%/*}__${repo#*/}.$kind.json"
}

canned_page() {
  local home=$1 repo=$2 kind=$3 page=$4 json=$5
  printf '%s\n' "$json" > "$home/gh/${repo%/*}__${repo#*/}.$kind.page-$page.json"
}

canned_call() {
  local home=$1 repo=$2 kind=$3 page=$4 call=$5 json=$6
  printf '%s\n' "$json" \
    > "$home/gh/${repo%/*}__${repo#*/}.$kind.page-$page.call-$call.json"
}

# comment <id> <login> <body> <html-url> [created-at]: one listing entry in
# GitHub's shape. created_at defaults to now because the body listing admits
# only threads opened inside the poll's window; pass an older stamp to model a
# thread that merely got bumped back into the window.
comment() {
  jq -nc --argjson id "$1" --arg login "$2" --arg body "$3" --arg url "$4" \
    --arg created "${5:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
    '{id:$id,user:{login:$login},body:$body,html_url:$url,
      created_at:$created,updated_at:"2026-09-20T10:00:00Z"}'
}

run_plane() {  # <home> <action...>
  local home=$1
  shift
  FM_TEST_GH_DIR="$home/gh" FM_HOME="$home" PATH="$FAKEBIN:$PATH" "$PLANE" "$@"
}

DEFAULT_CONFIG='{"enabled":true,"trusted_logins":["devGunnin","mengsig"],"repos":["owner/demo"]}'

records_in() { find "$1/state/gh-mention-inbox" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
# field <record-file> <jq-path>: read one recorded field through jq, so a case
# asserts the record's contract rather than its formatting.
field() { jq -r "$2" "$1"; }
wakes_in() { grep -c 'check: gh-mention' "$1/state/.wake-queue" 2>/dev/null || printf '0\n'; }
# iso_ago <seconds>: a UTC stamp that many seconds before now, so a fixture can
# sit inside or outside the poll's own backfill window whenever the suite runs.
iso_ago() { jq -nr --argjson back "$1" '(now - $back | floor) | todateiso8601'; }

# Ordering is by attempt, not by success, so repositories this host cannot read
# cost their slot once per rotation instead of pinning themselves to the front
# of every sweep and starving the healthy ones behind them.
test_unreadable_repos_do_not_starve_a_healthy_one() {
  local home n repos
  repos='"o/bad1","o/bad2","o/bad3","o/bad4","o/bad5","o/good"'
  home=$(make_home starvation \
    "{\"enabled\":true,\"trusted_logins\":[\"mengsig\"],\"repos\":[$repos]}")
  # Only o/good serves a listing; the fake gh 404s on a repo with no canned file.
  canned "$home" o/good comments \
    "[$(comment 771 mengsig '@firstmate urgent' \
      'https://github.com/o/good/issues/1#issuecomment-771')]"
  for n in 1 2 3 4 5; do
    printf '%s\n' "o/bad$n" >> "$home/gh/unreadable"
  done

  # Sweep 1 spends all five slots on the unreadable repositories.
  run_plane "$home" poll >/dev/null 2>&1
  assert_equals 0 "$(records_in "$home")" "the first sweep reaches only the unreadable repositories"
  assert_equals '' "$(jq -r '.repos["o/good"] // ""' "$home/state/gh-mention-cursor.json")" \
    "a repository that was never read has no read cursor"

  # Sweep 2 must reach it, because the failures were stamped as attempted.
  run_plane "$home" poll >/dev/null 2>&1
  assert_present "$home/state/gh-mention-inbox/comment-771.json" \
    "a healthy repository must be read once the failures rotate to the back"
  assert_equals 1 "$(wakes_in "$home")" "the mention in the healthy repository is queued"
  pass "fm-gh-mention: repositories that cannot be read never starve a healthy one"
}

# GitHub filters the issues listing on updated_at, which any thread activity
# moves, so a thread tagged long ago and bumped today would otherwise be filed
# as if it were newly asked - and answered publicly on a months-old thread.
test_an_old_body_bumped_by_new_activity_is_not_a_new_mention() {
  local home out
  home=$(make_home bumped-body '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/r"]}')
  canned "$home" o/r issues \
    "[$(comment 10 mengsig '@firstmate please handle the parser' \
      'https://github.com/o/r/issues/10' '2026-06-01T09:00:00Z')]"

  out=$(run_plane "$home" poll 2>&1)
  assert_equals 0 "$(records_in "$home")" \
    "a body opened before the window must not be filed on a first arm"
  assert_equals 0 "$(wakes_in "$home")" "no wake is queued for a thread nobody newly asked about"
  assert_equals '' "$out" "the poll stays silent about a thread it correctly ignored"

  # Tagging a thread that already exists is done by commenting on it.
  canned "$home" o/r comments \
    "[$(comment 11 mengsig '@firstmate the parser is still wrong' \
      'https://github.com/o/r/issues/10#issuecomment-11')]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_present "$home/state/gh-mention-inbox/comment-11.json" \
    "a comment posted on that thread is what tags it, and it is picked up"
  assert_equals 1 "$(records_in "$home")" \
    "the old body is still not filed once the thread is genuinely tagged"
  pass "fm-gh-mention: an old body bumped by new activity is not filed as a new mention"
}

# Body admission is bounded by the poll's own backfill floor, not by the read
# cursor: those are different clocks, and a busy repository whose first listing
# page overflows advances the cursor past a thread that was opened inside the
# window but never read.
test_a_newly_opened_body_cut_off_from_page_one_is_still_filed() {
  local home page bumped created
  home=$(make_home page-overflow '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/busy"]}')
  bumped=$(iso_ago 600)
  created=$(iso_ago 1200)
  # A full first page of untagged threads, all bumped after the tagged one was
  # opened, so the overflow leaves the cursor ahead of that opening.
  page=$(jq -nc --arg created "$created" --arg updated "$bumped" '[range(100) |
    {id:(800 + .),user:{login:"someone-else"},body:"routine \(.)",
     html_url:"https://github.com/o/busy/issues/\(800 + .)",
     created_at:$created,updated_at:$updated}]')
  canned_page "$home" o/busy issues 1 "$page"
  canned_page "$home" o/busy issues 2 \
    "[$(comment 942 mengsig '@firstmate please take this' \
      'https://github.com/o/busy/issues/942' "$created")]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_present "$home/state/gh-mention-inbox/issue-942.json" \
    "a thread opened inside the window must still be filed once the page no longer hides it"
  assert_equals 1 "$(wakes_in "$home")" "the recovered mention queues its wake"
  pass "fm-gh-mention: a newly opened body cut off from page one is still filed"
}

# The window a poll reads starts at the earlier of the backfill floor and the
# repository's read cursor. A home that was not polling for longer than the
# backfill window reads from its cursor, so a tag opened in that gap must still
# be admitted rather than stepped over when the cursor advances past it.
test_a_body_opened_while_the_cursor_was_behind_is_still_filed() {
  local home behind created
  home=$(make_home offline-gap '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/r"]}')
  behind=$(iso_ago 36000)
  created=$(iso_ago 10800)
  jq -n --arg s fm-gh-mention-cursor.v1 --arg behind "$behind" \
    '{schema:$s,repos:{"o/r":$behind},processed:[],grants:{},lapsed:[],attempted:{}}' \
    > "$home/state/gh-mention-cursor.json"
  canned "$home" o/r issues \
    "[$(comment 77 mengsig '@firstmate please fix the parser' \
      'https://github.com/o/r/issues/77' "$created")]"

  run_plane "$home" poll >/dev/null 2>&1

  assert_present "$home/state/gh-mention-inbox/issue-77.json" \
    "a body opened while the cursor was behind must be filed, not stepped over"
  assert_equals 1 "$(wakes_in "$home")" "the recovered mention queues its wake"
  assert_equals body "$(field "$home/state/gh-mention-inbox/issue-77.json" .comment_kind)" \
    "it is recorded as the thread body it is"
  pass "fm-gh-mention: a body opened while the cursor was behind is still filed"
}

# firstmate answers a mention by commenting on the thread, and a reply that
# restates the ask carries a marker, so without the stamp the next sweep would
# read that reply back as a fresh mention and answer itself in public. The stamp
# is what the poll enforces, and it works whichever account this home posts as.
test_a_stamped_reply_never_qualifies() {
  local home stamp
  home=$(make_home stamped '{"enabled":true,"trusted_logins":["mengsig","devGunnin"],"repos":["o/r"]}')
  stamp=$(run_plane "$home" status | sed -n 's/^publish stamp: //p')
  [ -n "$stamp" ] || fail "status must publish the stamp the responder has to write"
  canned "$home" o/r comments \
    "[$(comment 501 mengsig "$stamp

Picked up the request above; a fix branch is pushed and @captain owns the merge." \
      'https://github.com/o/r/issues/1#issuecomment-501')]"

  run_plane "$home" poll >/dev/null 2>&1

  assert_equals 0 "$(records_in "$home")" \
    "a reply that begins with the stamp must never be read back as a request"
  assert_equals 0 "$(wakes_in "$home")" "and queues no wake"
  pass "fm-gh-mention: a reply that begins with the stamp never qualifies"
}

# The exclusion is by what firstmate writes, not by who posts it, so every
# authorized account stays able to tag however this home is signed in.
test_every_authorized_account_can_still_tag() {
  local home
  home=$(make_home every-account '{"enabled":true,"trusted_logins":["mengsig","devGunnin"],"repos":["o/r"]}')
  canned "$home" o/r comments \
    "[$(comment 511 mengsig '@firstmate please fix the parser' \
      'https://github.com/o/r/issues/1#issuecomment-511'),
      $(comment 512 devGunnin '@firstmate and please look at this one' \
        'https://github.com/o/r/issues/2#issuecomment-512')]"

  run_plane "$home" poll >/dev/null 2>&1

  assert_present "$home/state/gh-mention-inbox/comment-511.json" \
    "the first authorized account can tag"
  assert_present "$home/state/gh-mention-inbox/comment-512.json" \
    "the second authorized account can tag too"
  assert_equals 2 "$(wakes_in "$home")" "each tag queues its own wake"
  pass "fm-gh-mention: every authorized account can still tag"
}

# The stamp counts only at the start of a body, so it protects the reply it
# opens and nothing else: quoting that reply and adding a real request is the
# ordinary way a thread continues, and it must still be heard.
test_a_stamped_reply_quoted_inside_a_request_still_qualifies() {
  local home stamp
  home=$(make_home stamp-quoted '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/r"]}')
  stamp=$(run_plane "$home" status | sed -n 's/^publish stamp: //p')
  canned "$home" o/r comments \
    "[$(comment 521 mengsig "> $stamp
> Picked up the request above.

That fix missed the nested case - @firstmate please take another look." \
      'https://github.com/o/r/issues/3#issuecomment-521')]"

  run_plane "$home" poll >/dev/null 2>&1

  assert_present "$home/state/gh-mention-inbox/comment-521.json" \
    "quoting a stamped reply and adding a real request is still a request"
  assert_equals 1 "$(wakes_in "$home")" "the quoted-and-asked request queues its wake"
  pass "fm-gh-mention: a stamped reply quoted inside a request still qualifies"
}

# The poll reads issue and pull-request bodies from the same listing, so the
# pull request firstmate opens for the work is a candidate like any other. An
# unstamped description saying the merge is the captain's call is a trusted
# account posting a marker on a watched repository - a new mention, which is
# firstmate answering its own pull request.
test_a_stamped_pull_request_body_never_qualifies() {
  local home stamp
  home=$(make_home stamped-pr '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/r"]}')
  stamp=$(run_plane "$home" status | sed -n 's/^publish stamp: //p')
  [ -n "$stamp" ] || fail "status must publish the stamp the responder has to write"

  # Positive control first: without the stamp that body IS a mention, which is
  # what makes the stamped case below evidence rather than a vacuous pass.
  canned "$home" o/r issues \
    "[$(comment 701 mengsig "Fixes #10. The merge is @captain's call." \
      'https://github.com/o/r/pull/11')]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_present "$home/state/gh-mention-inbox/issue-701.json" \
    "an unstamped pull-request body carrying a marker does reach the plane"

  canned "$home" o/r issues \
    "[$(comment 702 mengsig "$stamp

Fixes #12. The merge is @captain's call." \
      'https://github.com/o/r/pull/13')]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_absent "$home/state/gh-mention-inbox/issue-702.json" \
    "a pull-request body firstmate opened must not be read back as a request"
  assert_equals 1 "$(wakes_in "$home")" "only the unstamped one ever queued a wake"
  pass "fm-gh-mention: a stamped pull-request body never qualifies"
}

test_help_and_usage() {
  local out rc=0
  out=$("$PLANE" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  for action in poll pending ack status arm disarm; do
    assert_contains "$out" "fm-gh-mention.sh $action" "--help lists the $action action"
  done
  rc=0
  out=$("$PLANE" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "an unknown action must exit 2"
  assert_contains "$out" "unknown action" "an unknown action is refused loudly"
  pass "fm-gh-mention: help and usage plumbing"
}

test_absent_config_is_completely_inert() {
  local home out rc=0
  home=$(make_home inert)
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "an unconfigured poll must exit 0"
  [ -z "$out" ] || fail "an unconfigured poll must print nothing: $out"
  assert_absent "$home/state/gh-mention-inbox" "an unconfigured poll creates no inbox"
  assert_absent "$home/state/gh-mention-cursor.json" "an unconfigured poll creates no cursor"
  assert_absent "$home/state/.wake-queue" "an unconfigured poll queues no wake"
  assert_absent "$home/gh/paths.log" "an unconfigured poll makes no forge read"
  out=$(run_plane "$home" status 2>&1)
  assert_contains "$out" "gh mentions: off" "status names the plane as off without a config"
  pass "fm-gh-mention: an absent config leaves the plane completely inert"
}

test_malformed_config_stops_the_plane_loudly() {
  local home out rc=0
  home=$(make_home malformed 'this is not json')
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" "is not valid JSON" "a malformed config is reported by the poll"
  out=$(run_plane "$home" poll 2>&1)
  assert_equals '' "$out" "a config that stays malformed is not re-reported every cycle"
  assert_absent "$home/gh/paths.log" "a malformed config makes no forge read"
  assert_absent "$home/state/gh-mention-inbox" "a malformed config files no record"
  out=$(run_plane "$home" status 2>&1) || rc=$?
  expect_code 1 "$rc" "status must fail on a malformed config"
  assert_contains "$out" "stopped" "status reports the plane as stopped"
  rc=0
  out=$(run_plane "$home" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must refuse a malformed config"
  assert_absent "$home/state/gh-mention.check.sh" "a refused arm writes no shim"
  pass "fm-gh-mention: a malformed config stops the plane instead of guessing a default"
}

test_unknown_config_key_is_refused() {
  local home out
  home=$(make_home typo '{"enabled":true,"trusted_login":["devGunnin"]}')
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" "unknown key" "a mistyped trust list is named, not silently ignored"
  assert_contains "$out" "trusted_login" "the refusal names the offending key"
  pass "fm-gh-mention: a mistyped configuration key is refused rather than ignored"
}

test_a_trusted_marked_comment_is_accepted_once() {
  local home out record
  home=$(make_home accept "$DEFAULT_CONFIG")
  canned "$home" owner/demo comments \
    "[$(comment 11 DevGunnin 'hey @firstmate please look at this' \
      'https://github.com/owner/demo/issues/5#issuecomment-11')]"
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" "record comment-11" "the poll names the record it filed"
  assert_equals 1 "$(records_in "$home")" "exactly one record is filed"
  assert_equals 1 "$(wakes_in "$home")" "exactly one durable wake is queued"
  assert_grep "check: gh-mention comment-11" "$home/state/.wake-queue" "the wake carries the record id"
  record="$home/state/gh-mention-inbox/comment-11.json"
  assert_equals 'owner/demo' "$(field "$record" .repository)" "the record carries its repository"
  assert_equals 'issue' "$(field "$record" .subject_type)" "the record carries the subject type"
  assert_equals 'https://github.com/owner/demo/issues/5' "$(field "$record" .subject_url)" \
    "the record carries the subject URL"
  assert_equals 5 "$(field "$record" .subject_number)" "the record carries the subject number"
  assert_equals 'DevGunnin' "$(field "$record" .author)" "the record carries the trusted author"
  assert_equals '@firstmate' "$(field "$record" .marker)" "the record carries the matched marker"
  assert_equals 11 "$(field "$record" .comment_id)" "the record carries the comment identity"
  assert_equals 'https://github.com/owner/demo/issues/5#issuecomment-11' \
    "$(field "$record" .comment_url)" "the record carries the comment URL"
  assert_contains "$(field "$record" .body)" 'please look at this' "the record carries the comment body"
  assert_not_equals 'null' "$(field "$record" .accepted_at)" "the record carries the time it was accepted"
  pass "fm-gh-mention: a trusted, marked comment is accepted into one record and one wake"
}

test_an_untrusted_author_with_a_marker_is_ignored() {
  local home out
  home=$(make_home untrusted "$DEFAULT_CONFIG")
  canned "$home" owner/demo comments \
    "[$(comment 21 stranger '@firstmate ship this for me' \
      'https://github.com/owner/demo/issues/5#issuecomment-21')]"
  out=$(run_plane "$home" poll 2>&1)
  [ -z "$out" ] || fail "an untrusted marked comment must be ignored silently: $out"
  assert_equals 0 "$(records_in "$home")" "an untrusted author files no record"
  assert_equals 0 "$(wakes_in "$home")" "an untrusted author queues no wake"
  pass "fm-gh-mention: a marker from an untrusted account is ignored"
}

test_a_trusted_author_without_a_marker_is_ignored() {
  local home out
  home=$(make_home unmarked "$DEFAULT_CONFIG")
  canned "$home" owner/demo comments \
    "[$(comment 31 mengsig 'looks good to me, merging tomorrow' \
      'https://github.com/owner/demo/pull/7#issuecomment-31')]"
  out=$(run_plane "$home" poll 2>&1)
  [ -z "$out" ] || fail "an unmarked comment must be ignored silently: $out"
  assert_equals 0 "$(records_in "$home")" "ordinary conversation by a trusted account files no record"
  pass "fm-gh-mention: a trusted account's ordinary comment is ignored without a marker"
}

test_a_quoted_marker_never_qualifies_on_its_own() {
  local home out
  home=$(make_home quoted "$DEFAULT_CONFIG")
  # The marker text is present, but the body's own author is untrusted; quoting
  # a trusted account must not lend that comment the trusted account's standing.
  canned "$home" owner/demo comments \
    "[$(comment 41 stranger '> devGunnin wrote: @firstmate fix the parser

+1 to that' 'https://github.com/owner/demo/issues/9#issuecomment-41')]"
  out=$(run_plane "$home" poll 2>&1)
  [ -z "$out" ] || fail "a quoted marker must not qualify: $out"
  assert_equals 0 "$(records_in "$home")" "text quoted from a trusted account files no record"
  pass "fm-gh-mention: a marker quoted inside an untrusted comment never qualifies"
}

test_a_repeated_poll_does_not_duplicate_the_record() {
  local home
  home=$(make_home repeat "$DEFAULT_CONFIG")
  canned "$home" owner/demo comments \
    "[$(comment 51 mengsig '@captain please investigate' \
      'https://github.com/owner/demo/issues/3#issuecomment-51')]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_equals 1 "$(records_in "$home")" "the first poll files the record"
  [ -z "$(run_plane "$home" poll 2>&1)" ] || fail "a repeated poll must stay silent"
  assert_equals 1 "$(records_in "$home")" "a repeated poll does not duplicate the record"
  assert_equals 1 "$(wakes_in "$home")" "a repeated poll does not duplicate the wake"
  pass "fm-gh-mention: a repeated poll re-derives the same mention without duplicating it"
}

test_ack_moves_the_record_into_handled() {
  local home out
  home=$(make_home ack "$DEFAULT_CONFIG")
  canned "$home" owner/demo comments \
    "[$(comment 61 mengsig '@firstmate review this' \
      'https://github.com/owner/demo/pull/8#issuecomment-61')]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_contains "$(run_plane "$home" pending)" 'comment-61' "pending lists the unhandled record"
  out=$(run_plane "$home" ack comment-61 2>&1)
  assert_contains "$out" "acked comment-61" "ack names the record it acknowledged"
  assert_absent "$home/state/gh-mention-inbox/comment-61.json" "ack clears the pending record"
  assert_present "$home/state/gh-mention-inbox/handled/comment-61.json" "ack keeps the record under handled/"
  assert_contains "$(run_plane "$home" ack comment-61 2>&1)" "already-acked" "a repeated ack is a no-op"
  assert_equals '[]' "$(run_plane "$home" pending | tr -d ' \n')" "nothing stays pending after ack"
  pass "fm-gh-mention: ack moves a handled record out of the pending inbox"
}

test_an_unwatched_repo_is_never_read() {
  local home out
  home=$(make_home unwatched "$DEFAULT_CONFIG")
  canned "$home" other/elsewhere comments \
    "[$(comment 71 devGunnin '@firstmate do this' \
      'https://github.com/other/elsewhere/issues/1#issuecomment-71')]"
  out=$(run_plane "$home" poll 2>&1)
  [ -z "$out" ] || fail "an unwatched repo must produce nothing: $out"
  assert_equals 0 "$(records_in "$home")" "a mention in an unwatched repo files no record"
  assert_no_grep 'other/elsewhere' "$home/gh/paths.log" "an unwatched repo is never read at all"
  pass "fm-gh-mention: a qualifying mention in an unwatched repository is never read"
}

test_every_one_page_repo_makes_progress_at_the_baseline_cost() {
  local home out repo id=200
  home=$(make_home many \
    '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/one","o/two","o/three"]}')
  for repo in one two three; do
    id=$((id + 1))
    canned "$home" "o/$repo" comments \
      "[$(comment "$id" mengsig "@firstmate handle $repo" \
        "https://github.com/o/$repo/issues/1#issuecomment-$id")]"
  done
  out=$(run_plane "$home" poll 2>&1)
  assert_equals 3 "$(records_in "$home")" "each watched repo files its own record"
  for repo in one two three; do
    assert_contains "$out" "https://github.com/o/$repo/issues/1" "the poll reports the mention in o/$repo"
    assert_equals 3 "$(grep -c "^repos/o/$repo/" "$home/gh/paths.log")" \
      "one-page o/$repo costs exactly three reads per poll"
  done
  assert_equals 3 "$(jq -r '.repos | length' "$home/state/gh-mention-cursor.json")" \
    "every watched repo carries its own cursor"
  pass "fm-gh-mention: every one-page repo makes progress at three baseline reads"
}

# The read cursors below are deliberately the reverse of the attempt clock, so
# this pins which of the two decides the order.
test_the_least_recently_attempted_repo_goes_first() {
  local home first
  home=$(make_home order '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/fresh","o/stale"]}')
  jq -n '{schema:"fm-gh-mention-cursor.v1",
          repos:{"o/fresh":"2026-09-20T09:00:00Z","o/stale":"2026-09-20T11:00:00Z"},
          processed:[],
          attempted:{"o/fresh":"2026-09-20T11:00:00Z","o/stale":"2026-09-20T09:00:00Z"}}' \
    > "$home/state/gh-mention-cursor.json"
  run_plane "$home" poll >/dev/null 2>&1
  first=$(sed -n '1p' "$home/gh/paths.log")
  assert_contains "$first" "repos/o/stale/" "the repo attempted longest ago is read first"
  pass "fm-gh-mention: the least recently attempted repository is polled first"
}

test_a_registered_project_contributes_its_github_origin() {
  local home out
  home=$(make_home registry '{"enabled":true,"trusted_logins":["mengsig"]}')
  mkdir -p "$home/data" "$home/projects/demo"
  printf '%s\n' '# Projects' '' '- demo [no-mistakes] - the demo project (added 2026-09-20)' \
    > "$home/data/projects.md"
  git -C "$home/projects/demo" init -q
  git -C "$home/projects/demo" remote add origin https://github.com/owner/demo.git
  canned "$home" owner/demo comments \
    "[$(comment 81 mengsig '@firstmate look here' \
      'https://github.com/owner/demo/issues/2#issuecomment-81')]"
  out=$(run_plane "$home" status 2>&1)
  assert_contains "$out" "owner/demo" "a registered project's clone origin becomes a watched repo"
  run_plane "$home" poll >/dev/null 2>&1
  assert_present "$home/state/gh-mention-inbox/comment-81.json" \
    "a mention in a registered project's repo is accepted"
  pass "fm-gh-mention: a registered project's clone contributes its GitHub origin to the watched set"
}

test_an_unresolvable_project_is_reported_not_dropped() {
  local home out
  home=$(make_home noclone '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/one"]}')
  mkdir -p "$home/data"
  printf '%s\n' '- ghost - a project with no clone here (added 2026-09-20)' \
    > "$home/data/projects.md"
  out=$(run_plane "$home" status 2>&1)
  assert_contains "$out" "ghost" "status names the registered project it cannot watch"
  assert_contains "$out" "no clone here" "status says why that project is not watched"

  # Session start hears it when the set changes, not on every single start.
  out=$(run_plane "$home" arm 2>&1)
  assert_contains "$out" "ghost" "the first arm reports the project it cannot watch"
  out=$(run_plane "$home" arm 2>&1)
  assert_not_contains "$out" "ghost" \
    "an unchanged skip set is a steady state and says nothing on a later arm"
  assert_contains "$(run_plane "$home" status 2>&1)" "ghost" \
    "status still lists the whole set on demand"

  printf '%s\n' '- ghost - a project with no clone here (added 2026-09-20)' \
    '- phantom - another one (added 2026-09-20)' > "$home/data/projects.md"
  out=$(run_plane "$home" arm 2>&1)
  assert_contains "$out" "phantom" "a changed skip set is reported again"
  pass "fm-gh-mention: a registered project that resolves to no repository is reported"
}

test_an_empty_watched_set_says_there_is_nothing_to_watch() {
  local home out
  home=$(make_home empty '{"enabled":true,"trusted_logins":["mengsig"]}')
  out=$(run_plane "$home" status 2>&1)
  assert_contains "$out" "nothing to watch" "status says plainly that there is nothing to watch"
  out=$(run_plane "$home" arm 2>&1)
  assert_contains "$out" "nothing to watch" "the first arm says plainly that there is nothing to watch"
  assert_present "$home/state/gh-mention.check.sh" "the shim is still armed for repos registered later"
  out=$(run_plane "$home" arm 2>&1)
  assert_not_contains "$out" "nothing to watch" \
    "an unchanged empty watched set is a steady state and says nothing on a later arm"
  assert_contains "$(run_plane "$home" status 2>&1)" "nothing to watch" \
    "status still says it on demand"
  out=$(run_plane "$home" poll 2>&1)
  [ -z "$out" ] || fail "a poll with nothing to watch must stay silent: $out"
  assert_absent "$home/gh/paths.log" "a poll with nothing to watch makes no forge read"

  printf '%s\n' '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/one"]}' \
    > "$home/config/gh-mentions.json"
  out=$(run_plane "$home" arm 2>&1)
  assert_not_contains "$out" "nothing to watch" \
    "a watched set that filled up says nothing about having been empty"
  pass "fm-gh-mention: an empty watched set is reported rather than polled silently"
}

test_arm_binds_the_shim_and_disarm_removes_it() {
  local home out
  home=$(make_home arming "$DEFAULT_CONFIG")
  run_plane "$home" poll >/dev/null 2>&1
  out=$(run_plane "$home" arm 2>&1)
  assert_contains "$out" "armed: state/gh-mention.check.sh" "arm names the shim it wrote"
  assert_present "$home/state/gh-mention.check.sh" "arm writes the check shim"
  assert_present "$home/state/gh-mention.check-trust" "arm binds the shim for the watcher"
  assert_contains "$(cat "$home/state/gh-mention.check.sh")" "fm-gh-mention.sh check" \
    "the shim dispatches the poll"
  assert_contains "$(cat "$home/state/gh-mention.check.sh")" "FM_HOME=$home" \
    "the shim pins the absolute home"
  out=$(run_plane "$home" arm 2>&1)
  assert_contains "$out" "armed" "re-arming stays armed"
  assert_contains "$(run_plane "$home" status 2>&1)" "armed: yes" "status reports the armed plane"
  : > "$home/gh/fail"
  run_plane "$home" poll >/dev/null 2>&1
  rm -f "$home/gh/fail"
  assert_present "$home/state/gh-mention.reported" "a reported failure is recorded"
  out=$(run_plane "$home" disarm 2>&1)
  assert_contains "$out" "disarmed" "disarm names what it retired"
  assert_absent "$home/state/gh-mention.check.sh" "disarm removes the shim"
  assert_absent "$home/state/gh-mention.check-trust" "disarm removes the trust binding"
  assert_absent "$home/state/gh-mention.reported" \
    "disarm forgets what was reported so a standing condition is reported again after a re-arm"
  assert_present "$home/state/gh-mention-cursor.json" \
    "disarm keeps the read cursor so a re-arm resumes where the plane left off"
  pass "fm-gh-mention: arm writes and binds the shim, and disarm removes every trace"
}

test_a_disabled_config_arms_nothing() {
  local home out rc=0
  home=$(make_home disabled '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/one"]}')
  canned "$home" o/one comments \
    "[$(comment 91 mengsig '@firstmate do this' 'https://github.com/o/one/issues/1#issuecomment-91')]"
  run_plane "$home" arm >/dev/null 2>&1
  assert_present "$home/state/gh-mention.check.sh" "an enabled plane arms its shim"
  printf '%s\n' '{"enabled":false,"trusted_logins":["mengsig"],"repos":["o/one"]}' \
    > "$home/config/gh-mentions.json"
  out=$(run_plane "$home" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must refuse a disabled plane so its caller retires the shim"
  assert_equals '' "$out" \
    "pausing the plane is a steady state, so it reports nothing every session"
  out=$(run_plane "$home" poll 2>&1)
  [ -z "$out" ] || fail "a disabled poll must stay silent: $out"
  assert_absent "$home/gh/paths.log" "a disabled poll makes no forge read"
  pass "fm-gh-mention: a disabled config arms nothing and reads nothing"
}

test_review_comments_and_bodies_qualify_too() {
  local home
  home=$(make_home kinds "$DEFAULT_CONFIG")
  canned "$home" owner/demo review \
    "[$(comment 101 mengsig '@firstmate this line is wrong' \
      'https://github.com/owner/demo/pull/4#discussion_r101')]"
  canned "$home" owner/demo issues \
    "[$(comment 102 devGunnin '@captain please triage this issue' \
      'https://github.com/owner/demo/issues/12')]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_present "$home/state/gh-mention-inbox/review-comment-101.json" "a PR review comment qualifies"
  assert_present "$home/state/gh-mention-inbox/issue-102.json" "an issue or PR body qualifies"
  assert_equals pull "$(field "$home/state/gh-mention-inbox/review-comment-101.json" .subject_type)" \
    "a review comment resolves to its pull request"
  assert_equals body "$(field "$home/state/gh-mention-inbox/issue-102.json" .comment_kind)" \
    "a subject body is recorded as a body"
  pass "fm-gh-mention: review comments and issue or PR bodies qualify alongside comments"
}

test_a_plain_login_entry_is_a_permanent_authorization() {
  local home
  home=$(make_home permanent "$DEFAULT_CONFIG")
  canned "$home" owner/demo comments \
    "[$(comment 301 mengsig '@firstmate one' 'https://github.com/owner/demo/issues/1#issuecomment-301')]"
  run_plane "$home" poll >/dev/null 2>&1
  canned "$home" owner/demo comments \
    "[$(comment 302 mengsig '@firstmate two' 'https://github.com/owner/demo/issues/1#issuecomment-302')]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_equals 2 "$(records_in "$home")" "a plain login keeps qualifying with no bound to spend"
  assert_equals '{}' "$(jq -c '.grants // {}' "$home/state/gh-mention-cursor.json")" \
    "a plain login spends nothing"
  assert_contains "$(run_plane "$home" status)" "mengsig - permanent" \
    "status names a plain login as a permanent authorization"
  pass "fm-gh-mention: a plain login entry stays a permanent authorization"
}

test_an_expiry_in_the_past_never_qualifies() {
  local home out
  home=$(make_home expired \
    '{"enabled":true,"trusted_logins":[{"login":"guest","until":"2020-01-01T00:00:00Z"}],"repos":["o/r"]}')
  canned "$home" o/r comments \
    "[$(comment 311 guest '@firstmate please look' 'https://github.com/o/r/issues/1#issuecomment-311')]"
  out=$(run_plane "$home" poll 2>&1)
  assert_equals 0 "$(records_in "$home")" "an expired authorization files no record"
  assert_equals 0 "$(wakes_in "$home")" "an expired authorization queues no wake"
  assert_contains "$out" "has lapsed" "the lapsed authorization is reported"
  assert_contains "$out" "expired at 2020-01-01T00:00:00Z" "the report names the expiry it passed"
  pass "fm-gh-mention: an authorization whose expiry has passed never qualifies"
}

test_a_count_bounded_grant_stops_at_zero() {
  local home out id=400
  home=$(make_home counted \
    '{"enabled":true,"trusted_logins":[{"login":"guest","remaining":2}],"repos":["o/r"]}')
  canned "$home" o/r comments \
    "[$(comment 401 guest '@firstmate first' 'https://github.com/o/r/issues/1#issuecomment-401'),
      $(comment 402 guest '@firstmate second' 'https://github.com/o/r/issues/2#issuecomment-402'),
      $(comment 403 guest '@firstmate third' 'https://github.com/o/r/issues/3#issuecomment-403')]"
  out=$(run_plane "$home" poll 2>&1)
  assert_equals 2 "$(records_in "$home")" "a grant of two funds exactly two accepted mentions"
  assert_absent "$home/state/gh-mention-inbox/comment-403.json" \
    "the mention past the bound is refused inside the same poll"
  assert_equals 2 "$(jq -r '.grants.guest.spent_on | length' "$home/state/gh-mention-cursor.json")" \
    "the spend is recorded durably, once per accepted mention"
  pass "fm-gh-mention: a count-bounded authorization stops qualifying at zero"
}

test_the_count_decrements_only_on_acceptance() {
  local home
  home=$(make_home spend-once \
    '{"enabled":true,"trusted_logins":[{"login":"guest","remaining":5}],"repos":["o/r"]}')
  # One qualifying comment, plus two that are scanned but never accepted: an
  # unmarked comment from the same account, and a marked one from a stranger.
  canned "$home" o/r comments \
    "[$(comment 411 guest '@firstmate do this' 'https://github.com/o/r/issues/1#issuecomment-411'),
      $(comment 412 guest 'just chatting' 'https://github.com/o/r/issues/1#issuecomment-412'),
      $(comment 413 stranger '@firstmate do this too' 'https://github.com/o/r/issues/1#issuecomment-413')]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_equals 1 "$(records_in "$home")" "only the qualifying comment is accepted"
  assert_equals 1 "$(jq -r '.grants.guest.spent_on | length' "$home/state/gh-mention-cursor.json")" \
    "the count spends once per accepted mention, not per comment scanned"
  # A second poll re-scans the same comments and must not spend again.
  run_plane "$home" poll >/dev/null 2>&1
  assert_equals 1 "$(jq -r '.grants.guest.spent_on | length' "$home/state/gh-mention-cursor.json")" \
    "a repeated poll over the same comments spends nothing further"
  pass "fm-gh-mention: a bounded count decrements only on an accepted mention"
}

test_a_lapsed_grant_is_reported_once() {
  local home out
  home=$(make_home lapse-once \
    '{"enabled":true,"trusted_logins":[{"login":"guest","remaining":1}],"repos":["o/r"]}')
  canned "$home" o/r comments \
    "[$(comment 421 guest '@firstmate only one' 'https://github.com/o/r/issues/1#issuecomment-421')]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_equals 1 "$(records_in "$home")" "the single authorized request is accepted"
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" "has lapsed" "the exhausted authorization is reported when it lapses"
  out=$(run_plane "$home" poll 2>&1)
  assert_not_contains "$out" "has lapsed" "a lapsed authorization is reported once, not every poll"
  # Renewing it makes it live again, and reportable again if it lapses later.
  printf '%s\n' '{"enabled":true,"trusted_logins":[{"login":"guest","remaining":2}],"repos":["o/r"]}' \
    > "$home/config/gh-mentions.json"
  canned "$home" o/r comments \
    "[$(comment 422 guest '@firstmate renewed' 'https://github.com/o/r/issues/2#issuecomment-422')]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_present "$home/state/gh-mention-inbox/comment-422.json" "a renewed authorization qualifies again"
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" "has lapsed" "a renewed authorization is reportable again once it lapses"
  pass "fm-gh-mention: a lapsed authorization is reported once and again after renewal"
}

test_a_retried_mention_is_never_charged_twice() {
  local home
  home=$(make_home recharge \
    '{"enabled":true,"trusted_logins":[{"login":"guest","remaining":2}],"repos":["o/r"]}')
  canned "$home" o/r comments \
    "[$(comment 441 guest '@firstmate once' 'https://github.com/o/r/issues/1#issuecomment-441')]"
  run_plane "$home" poll >/dev/null 2>&1
  assert_equals 1 "$(jq -r '.grants.guest.spent_on | length' "$home/state/gh-mention-cursor.json")" \
    "the accepted mention is charged once"
  # A poll that died after charging but before remembering the mention leaves
  # exactly this state; the retry must re-derive the same mention and charge
  # nothing further, or a crash would quietly spend a bounded trial twice.
  jq '.repos = {} | .processed = []' "$home/state/gh-mention-cursor.json" > "$home/c.json"
  mv "$home/c.json" "$home/state/gh-mention-cursor.json"
  rm -f "$home/state/gh-mention-inbox"/*.json
  run_plane "$home" poll >/dev/null 2>&1
  assert_present "$home/state/gh-mention-inbox/comment-441.json" "the retry re-files the same mention"
  assert_equals 1 "$(jq -r '.grants.guest.spent_on | length' "$home/state/gh-mention-cursor.json")" \
    "a retried mention is charged once, not twice"
  assert_contains "$(run_plane "$home" status)" "1 of 2 requests left" \
    "the grant still has its second request"
  pass "fm-gh-mention: a retried mention is never charged to a grant twice"
}

test_an_expired_grant_finishes_an_already_charged_mention() {
  local home
  home=$(make_home charged-expired \
    '{"enabled":true,"trusted_logins":[{"login":"guest","until":"2020-01-01T00:00:00Z","remaining":1}],"repos":["o/r"]}')
  canned "$home" o/r comments \
    "[$(comment 451 guest '@firstmate finish this' 'https://github.com/o/r/issues/1#issuecomment-451')]"
  jq -n '{schema:"fm-gh-mention-cursor.v1",repos:{},listings:{},processed:[],
    grants:{guest:{spent_on:["comment-451"]}},lapsed:[],attempted:{}}' \
    > "$home/state/gh-mention-cursor.json"

  run_plane "$home" poll >/dev/null 2>&1

  assert_present "$home/state/gh-mention-inbox/comment-451.json" \
    "a charged mention is filed even after its grant expires"
  assert_equals 1 "$(wakes_in "$home")" "the interrupted acceptance finishes its durable wake"
  assert_equals 1 "$(jq -r '.grants.guest.spent_on | length' "$home/state/gh-mention-cursor.json")" \
    "finishing the retry does not spend the expired grant again"
  pass "fm-gh-mention: an expired grant finishes an already charged mention"
}

# The lapse line is news, so nothing suppresses a repeat of it. That makes its
# report-once state load-bearing: an announcement this home cannot remember
# would print on every poll, and every printed line is another wake.
test_a_lapse_that_cannot_be_recorded_is_never_announced() {
  local home out
  home=$(make_home lapse-unrecordable \
    '{"enabled":true,"trusted_logins":[{"login":"guest","until":"2020-01-01T00:00:00Z"}],"repos":["o/r"]}')
  mkdir -p "$home/elsewhere"
  jq -n '{schema:"fm-gh-mention-cursor.v1",repos:{},processed:[],grants:{},lapsed:[]}' \
    > "$home/elsewhere/cursor.json"
  ln -s "$home/elsewhere/cursor.json" "$home/state/gh-mention-cursor.json"
  out=$(run_plane "$home" poll 2>&1)
  assert_not_contains "$out" "has lapsed" \
    "a lapse whose report-once state cannot be recorded must not be announced"
  out=$(run_plane "$home" poll 2>&1)
  assert_not_contains "$out" "has lapsed" \
    "an unrecordable lapse must not wake the supervisor on any later cycle either"
  assert_equals '[]' "$(jq -c '.lapsed' "$home/elsewhere/cursor.json")" \
    "a lapse that was never announced is never marked as reported"
  assert_contains "$(run_plane "$home" status 2>&1)" "LAPSED" \
    "status still shows the lapsed authorization the poll stayed silent about"
  pass "fm-gh-mention: a lapse that cannot be recorded is never announced"
}

test_an_unspendable_bound_refuses_the_mention() {
  local home out
  home=$(make_home unspendable \
    '{"enabled":true,"trusted_logins":[{"login":"guest","remaining":3}],"repos":["o/r"]}')
  canned "$home" o/r comments \
    "[$(comment 431 guest '@firstmate urgent' 'https://github.com/o/r/issues/1#issuecomment-431')]"
  # A cursor the plane refuses to write through - here a symlink out of the
  # state directory - means the spend cannot be made durable. Accepting anyway
  # would act on a bound nobody can verify, so the mention must be refused.
  mkdir -p "$home/elsewhere"
  jq -n '{schema:"fm-gh-mention-cursor.v1",repos:{},processed:[],grants:{},lapsed:[]}' \
    > "$home/elsewhere/cursor.json"
  ln -s "$home/elsewhere/cursor.json" "$home/state/gh-mention-cursor.json"
  out=$(run_plane "$home" poll 2>&1)
  assert_equals 0 "$(records_in "$home")" "a spend that cannot be made durable accepts nothing"
  assert_equals 0 "$(wakes_in "$home")" "a refused spend queues no wake"
  assert_contains "$out" "not accepted" "the refusal says the mention was not accepted"
  assert_equals 0 "$(jq -r '(.grants.guest.spent_on // []) | length' "$home/elsewhere/cursor.json")" \
    "a refused spend leaves the grant untouched"
  pass "fm-gh-mention: a bound that cannot be durably spent refuses the mention"
}

test_a_malformed_grant_is_refused() {
  local home out
  home=$(make_home badgrant '{"enabled":true,"trusted_logins":[{"login":"guest","until":"whenever"}]}')
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" 'not an ISO 8601 timestamp' "an unreadable expiry stops the plane"
  home=$(make_home badcount '{"enabled":true,"trusted_logins":[{"login":"guest","remaining":-2}]}')
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" 'not a whole number of requests' "an unreadable count stops the plane"
  pass "fm-gh-mention: a malformed bound stops the plane instead of being ignored"
}

test_the_plane_requests_a_fast_watcher_cadence() {
  local home
  home=$(make_home cadence "$DEFAULT_CONFIG")
  assert_equals 30 "$(run_plane "$home" cadence)" "an enabled plane asks for the fixed fast cadence"
  printf '%s\n' '{"enabled":false,"trusted_logins":["mengsig"],"repos":["owner/demo"]}' \
    > "$home/config/gh-mentions.json"
  assert_equals '' "$(run_plane "$home" cadence)" "a disabled plane asks for no speed-up"
  printf '%s\n' '{"enabled":true,"trusted_logins":["mengsig"]}' \
    > "$home/config/gh-mentions.json"
  assert_equals '' "$(run_plane "$home" cadence)" "a plane with nothing to watch asks for no speed-up"
  printf '%s\n' '{"enabled":true,"trusted_logins":["mengsig"],"check_interval":90}' \
    > "$home/config/gh-mentions.json"
  assert_contains "$(run_plane "$home" poll 2>&1)" 'unknown key' \
    "the interval is not a configuration option, so naming one stops the plane"
  pass "fm-gh-mention: the plane requests a fixed fast watcher cadence"
}

test_a_full_listing_is_exhausted_before_the_cursor_advances() {
  local home page cursor
  home=$(make_home paged '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/busy"]}')
  # A repo with exactly one full page must read the following page before its
  # cursor advances.
  page=$(jq -nc '[range(100) | {id:(500 + .),user:{login:"mengsig"},
    body:"@firstmate item \(.)",
    html_url:"https://github.com/o/busy/issues/1#issuecomment-\(500 + .)",
    updated_at:"2026-09-19T0\(. % 10):00:00Z"}]')
  canned "$home" o/busy comments "$page"
  run_plane "$home" poll >/dev/null 2>&1
  cursor=$(jq -r '.repos["o/busy"]' "$home/state/gh-mention-cursor.json")
  assert_equals "$cursor" "$(jq -r '.listings["o/busy"].comments.since' \
    "$home/state/gh-mention-cursor.json")" "a completed listing advances its timestamp cursor"
  assert_equals 4 "$(grep -c '^repos/o/busy/issues/comments$' "$home/gh/paths.log")" \
    "a full listing is traversed twice before its cursor advances"
  pass "fm-gh-mention: a full listing is exhausted before its cursor advances"
}

test_a_full_page_timestamp_tie_is_exhausted_in_one_poll() {
  local home page tagged
  home=$(make_home page-tie '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/busy"]}')
  page=$(jq -nc '[range(100) | {id:(600 + .),user:{login:"someone-else"},body:"routine",
    html_url:"https://github.com/o/busy/issues/1#issuecomment-\(600 + .)",
    updated_at:"2026-09-19T09:00:00Z"}]')
  tagged=$(jq -nc '[{id:700,user:{login:"mengsig"},body:"@firstmate do not lose this",
    html_url:"https://github.com/o/busy/issues/1#issuecomment-700",
    updated_at:"2026-09-19T09:00:00Z"}]')
  canned_page "$home" o/busy comments 1 "$page"
  canned_page "$home" o/busy comments 2 "$tagged"

  run_plane "$home" poll >/dev/null 2>&1

  assert_present "$home/state/gh-mention-inbox/comment-700.json" \
    "the tagged item after 100 identical timestamps is eventually filed"
  assert_equals 1 "$(wakes_in "$home")" "the tied item queues exactly one wake"
  assert_equals null "$(jq -r '.listings["o/busy"].comments.page // "null"' \
    "$home/state/gh-mention-cursor.json")" "no numeric page position survives the poll"
  pass "fm-gh-mention: a full-page timestamp tie is exhausted in one poll"
}

test_a_reordered_listing_restarts_before_advancing() {
  local home first shifted tail tagged
  home=$(make_home reordered '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/busy"]}')
  first=$(jq -nc '[range(100) | {id:(800 + .),user:{login:"someone-else"},body:"routine",
    html_url:"https://github.com/o/busy/issues/1#issuecomment-\(800 + .)",
    updated_at:"2026-09-19T09:00:00Z"}]')
  tagged=$(jq -nc '{id:900,user:{login:"mengsig"},body:"@firstmate shifted request",
    html_url:"https://github.com/o/busy/issues/1#issuecomment-900",
    updated_at:"2026-09-19T09:00:00Z"}')
  canned_page "$home" o/busy comments 1 "$first"
  canned_page "$home" o/busy comments 2 "[$tagged]"
  : > "$home/gh/o__busy.comments.fail-page-2"

  run_plane "$home" poll >/dev/null 2>&1
  assert_equals '' "$(jq -r '.repos["o/busy"] // ""' "$home/state/gh-mention-cursor.json")" \
    "an interrupted traversal does not advance the read cursor"

  shifted=$(jq -nc --argjson tagged "$tagged" '[range(1;100) | {id:(800 + .),
    user:{login:"someone-else"},body:"routine",
    html_url:"https://github.com/o/busy/issues/1#issuecomment-\(800 + .)",
    updated_at:"2026-09-19T09:00:00Z"}] + [$tagged]')
  tail=$(jq -nc '[{id:800,user:{login:"someone-else"},body:"edited",
    html_url:"https://github.com/o/busy/issues/1#issuecomment-800",
    updated_at:"2026-09-20T09:00:00Z"}]')
  canned_page "$home" o/busy comments 1 "$shifted"
  canned_page "$home" o/busy comments 2 "$tail"
  rm "$home/gh/o__busy.comments.fail-page-2"
  run_plane "$home" poll >/dev/null 2>&1

  assert_present "$home/state/gh-mention-inbox/comment-900.json" \
    "a tagged item shifted onto page one is filed after the traversal restarts"
  assert_equals 1 "$(wakes_in "$home")" "the shifted request queues exactly one wake"
  pass "fm-gh-mention: a reordered listing restarts before cursor advancement"
}

test_a_listing_reordered_between_pages_is_rescanned() {
  local home first shifted tail tagged
  home=$(make_home reorder-within '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/busy"]}')
  first=$(jq -nc '[range(100) | {id:(1000 + .),user:{login:"someone-else"},body:"routine",
    html_url:"https://github.com/o/busy/issues/1#issuecomment-\(1000 + .)",
    updated_at:"2026-09-19T09:00:00Z"}]')
  tagged=$(jq -nc '{id:1100,user:{login:"mengsig"},body:"@firstmate shifted request",
    html_url:"https://github.com/o/busy/issues/1#issuecomment-1100",
    updated_at:"2026-09-19T09:00:00Z"}')
  shifted=$(jq -nc --argjson tagged "$tagged" '[range(1;100) | {id:(1000 + .),
    user:{login:"someone-else"},body:"routine",
    html_url:"https://github.com/o/busy/issues/1#issuecomment-\(1000 + .)",
    updated_at:"2026-09-19T09:00:00Z"}] + [$tagged]')
  tail=$(jq -nc '[{id:1000,user:{login:"someone-else"},body:"edited",
    html_url:"https://github.com/o/busy/issues/1#issuecomment-1000",
    updated_at:"2026-09-20T09:00:00Z"}]')
  canned_page "$home" o/busy comments 1 "$shifted"
  canned_page "$home" o/busy comments 2 "$tail"
  canned_call "$home" o/busy comments 1 1 "$first"

  run_plane "$home" poll >/dev/null 2>&1

  assert_present "$home/state/gh-mention-inbox/comment-1100.json" \
    "a tagged item shifted onto an already-read page is recovered by the rescan"
  assert_equals 1 "$(wakes_in "$home")" "the intra-traversal shift queues exactly one wake"
  assert_equals 6 "$(grep -c '^repos/o/busy/issues/comments$' "$home/gh/paths.log")" \
    "the changed identity boundary is traversed again until stable"
  pass "fm-gh-mention: an intra-traversal reorder is rescanned before cursor advancement"
}

test_a_failed_read_keeps_the_repo_cursor() {
  local home out before
  home=$(make_home failing "$DEFAULT_CONFIG")
  canned "$home" owner/demo comments \
    "[$(comment 111 mengsig '@firstmate urgent' \
      'https://github.com/owner/demo/issues/1#issuecomment-111')]"
  run_plane "$home" poll >/dev/null 2>&1
  before=$(jq -r '.repos["owner/demo"]' "$home/state/gh-mention-cursor.json")
  : > "$home/gh/fail"
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" "could not read owner/demo" "a failed read is reported, not swallowed"
  assert_equals "$before" "$(jq -r '.repos["owner/demo"]' "$home/state/gh-mention-cursor.json")" \
    "a repo whose read failed keeps its cursor so nothing is skipped"
  pass "fm-gh-mention: a repository whose read fails keeps its cursor and is reported"
}

# The watcher wakes firstmate on ANY output from this check, so a condition that
# outlives one poll must be reported once rather than on every cycle.
test_a_persistent_failure_is_reported_once() {
  local home out
  home=$(make_home repeat "$DEFAULT_CONFIG")
  canned "$home" owner/demo comments \
    "[$(comment 222 mengsig '@firstmate urgent' \
      'https://github.com/owner/demo/issues/2#issuecomment-222')]"
  run_plane "$home" poll >/dev/null 2>&1
  : > "$home/gh/fail"
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" "could not read owner/demo" "the first poll of a new failure reports it"
  out=$(run_plane "$home" poll 2>&1)
  assert_equals '' "$out" \
    "a failure that persists must stay silent instead of waking the supervisor every cycle"
  rm -f "$home/gh/fail"
  out=$(run_plane "$home" poll 2>&1)
  assert_equals '' "$out" "a recovered repo with nothing new says nothing"
  : > "$home/gh/fail"
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" "could not read owner/demo" \
    "a failure that returns after clearing is reported again"
  pass "fm-gh-mention: a persistent failure is reported once, and again only if it returns"
}

# A sweep evaluates only the repositories the cap let it reach, so a standing
# failure in the rotating tail must not alternate between present and absent:
# the watcher wakes firstmate on any output at all, so a flapping diagnostic is
# a wake every other sweep forever.
test_a_standing_failure_survives_the_sweep_rotation() {
  local home out n standing=0 fresh=0
  home=$(make_home rotating-failure \
    '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/bad","o/good"]}')
  printf '%s\n' o/bad > "$home/gh/unreadable"
  for n in 1 2 3 4; do
    out=$(FM_GH_MENTION_MAX_REPOS=1 run_plane "$home" poll 2>&1)
    case "$out" in *'could not read o/bad'*) standing=$((standing + 1)) ;; esac
  done
  assert_equals 1 "$standing" \
    "a standing failure the sweep cap keeps skipping is reported once, not once per rotation"

  # Retaining that report must not silence a repository that starts failing now.
  printf '%s\n' o/good >> "$home/gh/unreadable"
  standing=0
  for n in 1 2 3 4; do
    out=$(FM_GH_MENTION_MAX_REPOS=1 run_plane "$home" poll 2>&1)
    case "$out" in *'could not read o/good'*) fresh=$((fresh + 1)) ;; esac
    case "$out" in *'could not read o/bad'*) standing=$((standing + 1)) ;; esac
  done
  assert_equals 1 "$fresh" "a failure that appears in another repository is still reported"
  assert_equals 0 "$standing" "the older failure stays silent while the new one is reported"
  pass "fm-gh-mention: a standing failure is reported once across the sweep rotation"
}

# A mention that qualified but could not be filed must be genuinely re-derived,
# which only happens if its repo's cursor does not step over the window it was in.
test_an_unfiled_mention_keeps_the_repo_cursor() {
  local home out
  home=$(make_home unfiled "$DEFAULT_CONFIG")
  canned "$home" owner/demo comments \
    "[$(comment 333 mengsig '@firstmate please look' \
      'https://github.com/owner/demo/issues/3#issuecomment-333')]"
  mkdir -p "$home/state/gh-mention-inbox"
  ln -s "$home/state/elsewhere.json" "$home/state/gh-mention-inbox/comment-333.json"
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" "could not file a mention" "a mention that cannot be filed is reported"
  assert_absent "$home/state/elsewhere.json" "a linked record destination is never written through"
  assert_equals 0 "$(wakes_in "$home")" "an unfiled mention queues no wake"
  assert_equals null \
    "$(jq -r '.repos["owner/demo"] // "null"' "$home/state/gh-mention-cursor.json")" \
    "a repo holding an unfiled mention must not advance past the window it was in"
  rm -f "$home/state/gh-mention-inbox/comment-333.json"
  run_plane "$home" poll >/dev/null 2>&1
  assert_present "$home/state/gh-mention-inbox/comment-333.json" \
    "the unfiled mention is re-derived and filed once it can be written"
  assert_equals 1 "$(wakes_in "$home")" "the re-derived mention queues its wake"
  pass "fm-gh-mention: a mention that could not be filed is re-derived rather than lost"
}

# The kind segment names the subject, not the whole URL: a repository literally
# named `pull` would otherwise hand the responder an issue labelled as a PR.
test_subject_type_comes_from_the_kind_segment() {
  local home record
  home=$(make_home kind-segment \
    '{"enabled":true,"trusted_logins":["mengsig"],"repos":["wei/pull"]}')
  canned "$home" wei/pull comments \
    "[$(comment 901 mengsig '@firstmate look at this issue' \
      'https://github.com/wei/pull/issues/42#issuecomment-901')]"
  canned "$home" wei/pull review \
    "[$(comment 902 mengsig '@firstmate review this' \
      'https://github.com/wei/pull/pull/7#discussion_r902')]"
  run_plane "$home" poll >/dev/null 2>&1
  record="$home/state/gh-mention-inbox/comment-901.json"
  assert_equals issue "$(field "$record" .subject_type)" \
    "an issue in a repository named pull must not be recorded as a pull request"
  assert_equals 42 "$(field "$record" .subject_number)" "the issue keeps its own number"
  record="$home/state/gh-mention-inbox/review-comment-902.json"
  assert_equals pull "$(field "$record" .subject_type)" \
    "a real pull request in the same repository is still a pull request"
  assert_equals 7 "$(field "$record" .subject_number)" "the pull request keeps its own number"
  pass "fm-gh-mention: the subject type comes from the kind segment, not the whole URL"
}

# The hourly GitHub allowance is shared with every other gh-backed plane on this
# host, so a sweep's cost must be bounded by the cap rather than by how many
# projects happen to be registered here.
test_a_sweep_reads_at_most_the_capped_number_of_repositories() {
  local home repos n id=300 swept
  repos='"o/r1","o/r2","o/r3","o/r4","o/r5","o/r6","o/r7"'
  home=$(make_home capped \
    "{\"enabled\":true,\"trusted_logins\":[\"mengsig\"],\"repos\":[$repos]}")
  for n in 1 2 3 4 5 6 7; do
    id=$((id + 1))
    canned "$home" "o/r$n" comments \
      "[$(comment "$id" mengsig "@firstmate handle r$n" \
        "https://github.com/o/r$n/issues/1#issuecomment-$id")]"
  done

  run_plane "$home" poll >/dev/null 2>&1
  swept=$(awk -F/ '{print $2"/"$3}' "$home/gh/paths.log" | sort -u | wc -l | tr -d ' ')
  assert_equals 5 "$swept" "one sweep must read at most the capped number of repositories"
  assert_equals 15 "$(wc -l < "$home/gh/paths.log" | tr -d ' ')" \
    "the per-sweep call count is three per capped repository, not three per watched one"
  assert_equals 5 "$(records_in "$home")" "the repositories that were read file their mentions"

  # The tail has no cursor yet, so it sorts first and is read on the next sweep.
  run_plane "$home" poll >/dev/null 2>&1
  assert_equals 7 "$(records_in "$home")" \
    "a watched set larger than the cap rotates across sweeps instead of starving its tail"
  pass "fm-gh-mention: a sweep reads at most the capped number of repositories and rotates"
}

# An exhausted allowance is a whole-host condition; reporting it as one
# unreadable repository sends the captain after the wrong fault.
test_a_refused_allowance_is_named_as_itself() {
  local home out
  home=$(make_home rate-limited \
    '{"enabled":true,"trusted_logins":["mengsig"],"repos":["o/a","o/b","o/c"]}')
  : > "$home/gh/ratelimit"
  out=$(run_plane "$home" poll 2>&1)
  assert_contains "$out" "refused this host's API allowance" \
    "a refused allowance must be named as itself, not as one unreadable repository"
  assert_not_contains "$out" "could not read o/" \
    "a refused allowance must not be reported as a per-repository read failure"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c 'API allowance')" \
    "the whole-host condition is reported once, not once per watched repository"
  assert_equals 1 "$(wc -l < "$home/gh/paths.log" | tr -d ' ')" \
    "a refused allowance stops at the call that was refused instead of spending more"
  out=$(run_plane "$home" poll 2>&1)
  assert_equals '' "$out" "a standing allowance refusal keeps report-once semantics"
  pass "fm-gh-mention: a refused API allowance is named as itself and stops the sweep"
}

test_help_and_usage
test_absent_config_is_completely_inert
test_malformed_config_stops_the_plane_loudly
test_unknown_config_key_is_refused
test_a_trusted_marked_comment_is_accepted_once
test_an_untrusted_author_with_a_marker_is_ignored
test_a_trusted_author_without_a_marker_is_ignored
test_a_quoted_marker_never_qualifies_on_its_own
test_a_repeated_poll_does_not_duplicate_the_record
test_ack_moves_the_record_into_handled
test_an_unwatched_repo_is_never_read
test_every_one_page_repo_makes_progress_at_the_baseline_cost
test_the_least_recently_attempted_repo_goes_first
test_a_registered_project_contributes_its_github_origin
test_an_unresolvable_project_is_reported_not_dropped
test_an_empty_watched_set_says_there_is_nothing_to_watch
test_arm_binds_the_shim_and_disarm_removes_it
test_a_disabled_config_arms_nothing
test_review_comments_and_bodies_qualify_too
test_a_plain_login_entry_is_a_permanent_authorization
test_an_expiry_in_the_past_never_qualifies
test_a_count_bounded_grant_stops_at_zero
test_the_count_decrements_only_on_acceptance
test_a_lapsed_grant_is_reported_once
test_a_retried_mention_is_never_charged_twice
test_an_expired_grant_finishes_an_already_charged_mention
test_an_unspendable_bound_refuses_the_mention
test_a_lapse_that_cannot_be_recorded_is_never_announced
test_a_malformed_grant_is_refused
test_the_plane_requests_a_fast_watcher_cadence
test_a_full_listing_is_exhausted_before_the_cursor_advances
test_a_full_page_timestamp_tie_is_exhausted_in_one_poll
test_a_reordered_listing_restarts_before_advancing
test_a_listing_reordered_between_pages_is_rescanned
test_a_failed_read_keeps_the_repo_cursor
test_a_persistent_failure_is_reported_once
test_a_standing_failure_survives_the_sweep_rotation
test_an_unfiled_mention_keeps_the_repo_cursor
test_subject_type_comes_from_the_kind_segment
test_a_sweep_reads_at_most_the_capped_number_of_repositories
test_a_refused_allowance_is_named_as_itself
test_unreadable_repos_do_not_starve_a_healthy_one
test_an_old_body_bumped_by_new_activity_is_not_a_new_mention
test_a_newly_opened_body_cut_off_from_page_one_is_still_filed
test_a_body_opened_while_the_cursor_was_behind_is_still_filed
test_a_stamped_reply_never_qualifies
test_every_authorized_account_can_still_tag
test_a_stamped_reply_quoted_inside_a_request_still_qualifies
test_a_stamped_pull_request_body_never_qualifies
