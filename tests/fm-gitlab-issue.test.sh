#!/usr/bin/env bash
# tests/fm-gitlab-issue.test.sh - how firstmate reads and mutates one GitLab
# issue through bin/fm-gitlab-issue.sh, against a fake glab that records every
# request it receives and answers from fixtures. No case reaches the network.
#
# Covered: issue-URL parsing including nested subgroups and the explicit host
# flag; `label` removing only prefixed labels in one PUT, staying idempotent,
# and accepting exactly the closed fm:: vocabulary it advertises while a
# caller-supplied --prefix stays prefix-only;
# `checklist` rewriting exactly one line and refusing a missing or ticked one;
# `show` folding every page of notes and `show --since` dropping system notes,
# the token user's own notes, and older notes down to the fractional second;
# `comment` and `comment-update` sending the body verbatim; every body-carrying
# request declaring a JSON Content-Type; `project` matching https, scp-like,
# and ssh:// origins with and without .git, skipping a plain directory inside a
# repository, and exiting 3 when no clone matches; and glab failure or timeout
# exiting 2.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-gitlab-issue.sh"
TMP_ROOT=$(fm_test_tmproot fm-gitlab-issue)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
command -v jq >/dev/null 2>&1 || fail "these tests need the real jq on PATH"
export PATH="$FAKEBIN:$PATH"

# The fake glab answers from $FM_TEST_GLAB_FIX and appends one line per request
# to $FM_TEST_GLAB_LOG:
# "<method>\t<hostname>\t<paginate>\t<endpoint>\t<headers;joined>\t<body>".
# A PUT on the issue applies add_labels/remove_labels to issue.json so a second
# call sees the new label set; a POST or PUT on a note stores the body so the
# suite can check exactly what would have reached GitLab. A paginated notes GET
# prints notes.json and then, like real glab, a second array from
# notes-page2.json when that fixture exists.
cat > "$FAKEBIN/glab" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = api ] || { echo "fake glab: only 'api' is supported" >&2; exit 1; }
shift
method=GET hostname='<unset>' paginate=no endpoint= body= headers=
while [ $# -gt 0 ]; do
  case "$1" in
    --hostname) hostname=$2; shift 2 ;;
    --method | -X) method=$2; shift 2 ;;
    --input) if [ "$2" = - ]; then body=$(cat); else body=$(cat "$2"); fi; shift 2 ;;
    --header | -H) headers="${headers:+$headers;}$2"; shift 2 ;;
    --paginate) paginate=yes; shift ;;
    -*) echo "fake glab: unexpected flag $1" >&2; exit 1 ;;
    *) endpoint=$1; shift ;;
  esac
done
body_c=$(printf '%s' "$body" | jq -c . 2>/dev/null || printf '%s' "$body")
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$method" "$hostname" "$paginate" "$endpoint" "$headers" "$body_c" >> "$FM_TEST_GLAB_LOG"
fix=$FM_TEST_GLAB_FIX
[ ! -e "$fix/fail" ] || { echo "fake glab: 401 Unauthorized" >&2; exit 1; }
[ ! -e "$fix/hang" ] || sleep 30
case "$method $endpoint" in
  "GET user") cat "$fix/user.json" ;;
  "GET projects/"*"/issues/"*"/notes?"*)
    cat "$fix/notes.json"
    [ "$paginate" = no ] || [ ! -e "$fix/notes-page2.json" ] || cat "$fix/notes-page2.json"
    ;;
  "GET projects/"*"/issues/"*"/notes/"*) cat "$fix/note-${endpoint##*/}.json" ;;
  "GET projects/"*"/issues/"*) cat "$fix/issue.json" ;;
  "PUT projects/"*"/issues/"*"/notes/"*)
    jq --argjson body "$(printf '%s' "$body" | jq -c .body)" '.body = $body' \
      "$fix/note-${endpoint##*/}.json" > "$fix/note-${endpoint##*/}.json.new"
    mv "$fix/note-${endpoint##*/}.json.new" "$fix/note-${endpoint##*/}.json"
    cat "$fix/note-${endpoint##*/}.json"
    ;;
  "PUT projects/"*"/issues/"*)
    printf '%s' "$body" | jq --slurpfile issue "$fix/issue.json" '
      ($issue[0]) as $i
      | ((.remove_labels // "") | split(",") | map(select(. != ""))) as $rm
      | ((.add_labels // "") | split(",") | map(select(. != ""))) as $add
      | $i | .labels = ((.labels - $rm) + $add | unique)' > "$fix/issue.json.new"
    mv "$fix/issue.json.new" "$fix/issue.json"
    cat "$fix/issue.json"
    ;;
  "POST projects/"*"/issues/"*"/notes")
    printf '%s' "$body" | jq -r .body > "$fix/posted-note.body"
    printf '%s' "$body" | jq '{id: 501, body: .body, system: false}'
    ;;
  *) echo "fake glab: unexpected request $method $endpoint" >&2; exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/glab"

URL='https://gitlab.example.test/grp/sub/deep/proj/-/issues/42'
ENC='projects/grp%2Fsub%2Fdeep%2Fproj/issues/42'

# new_case <name>: a fresh fixture directory and request log for one scenario.
new_case() {
  FIX="$TMP_ROOT/$1"
  mkdir -p "$FIX"
  export FM_TEST_GLAB_FIX="$FIX" FM_TEST_GLAB_LOG="$FIX/requests.log"
  : > "$FM_TEST_GLAB_LOG"
  printf '[]\n' > "$FIX/notes.json"
  cat > "$FIX/user.json" <<'JSON'
{"id": 77, "username": "fm-bot", "name": "Firstmate Bot"}
JSON
  cat > "$FIX/issue.json" <<'JSON'
{
  "iid": 42, "project_id": 9, "title": "Login page loops", "state": "opened",
  "description": "Steps to reproduce...",
  "labels": ["fm::todo", "bug", "fm::triage", "priority::high"],
  "author": {"id": 5, "username": "alice", "name": "Alice"},
  "web_url": "https://gitlab.example.test/grp/sub/deep/proj/-/issues/42",
  "references": {"full": "grp/sub/deep/proj#42"}
}
JSON
}

requests() { cat "$FM_TEST_GLAB_LOG"; }
count_method() { grep -c "^$1"$'\t' "$FM_TEST_GLAB_LOG" || true; }
# assert_json_body <method>: at least one <method> request is on record and
# every one of them declared its body as JSON in the headers column.
assert_json_body() {
  awk -F'\t' -v m="$1" '
    $1 == m { n++; if ($5 !~ /(^|;)Content-Type: application\/json(;|$)/) bad++ }
    END { exit !(n && !bad) }' "$FM_TEST_GLAB_LOG" \
    || fail "every $1 request must carry Content-Type: application/json: $(requests)"
}

# --- URL parsing --------------------------------------------------------------

new_case url
out=$("$SCRIPT" show "$URL" 2>&1) || fail "show on a nested-subgroup URL failed: $out"
assert_contains "$(requests)" $'GET\tgitlab.example.test\tno\t'"$ENC"$'\t' \
  "the issue is fetched from the URL's host with the nested path encoded"
assert_contains "$(requests)" $'GET\tgitlab.example.test\tno\tuser\t' \
  "the token user is looked up on the same host"
assert_contains "$(requests)" $'GET\tgitlab.example.test\tyes\t'"$ENC"'/notes?sort=asc&order_by=created_at' \
  "notes are paginated in creation order"
[ "$(grep -vc $'\tgitlab.example.test\t' "$FM_TEST_GLAB_LOG")" = 0 ] \
  || fail "a request went to a host other than the URL's"
pass "show targets the parsed host and URL-encodes the nested project path"

new_case url-variants
"$SCRIPT" show 'https://GitLab.Example.TEST/grp/sub/deep/proj/-/issues/42#note_12' >/dev/null 2>&1 \
  || fail "a fragment or upper-case host must not break parsing"
assert_contains "$(requests)" $'\tgitlab.example.test\t' "the host is lowercased before use"
for bad in \
  'https://github.com/owner/repo/pull/7' \
  'https://gitlab.example.test/grp/proj/-/merge_requests/3' \
  'https://gitlab.example.test/grp/proj/-/issues/' \
  'https://gitlab.example.test/grp/proj/-/issues/0' \
  'https://gitlab.example.test/proj/-/issues/3' \
  'https://gitlab.example.test:8443/grp/proj/-/issues/3' \
  'http://gitlab.example.test/grp/proj/-/issues/3' \
  'https://gitlab.example.test/grp/-/proj/-/issues/3'; do
  : > "$FM_TEST_GLAB_LOG"
  err=$("$SCRIPT" show "$bad" 2>&1); rc=$?
  expect_code 1 "$rc" "refuses '$bad'"
  assert_contains "$err" "not a GitLab issue URL" "refusal names the URL shape: $bad"
  [ ! -s "$FM_TEST_GLAB_LOG" ] || fail "a refused URL still reached glab: $bad"
done
pass "non-issue and malformed URLs are refused before any request"

err=$("$SCRIPT" frobnicate "$URL" 2>&1); rc=$?
expect_code 1 "$rc" "unknown subcommand exits 1"
assert_contains "$err" "unknown subcommand" "unknown subcommand is named"
out=$("$SCRIPT" --help 2>&1) || fail "--help exits 0"
assert_contains "$out" "checklist <issue-url> <note-id> <n> --done <suffix>" "--help lists the subcommands"
pass "usage errors are refusals with one line"

# --- label ---------------------------------------------------------------------

new_case label
out=$("$SCRIPT" label "$URL" fm::accepted 2>&1) || fail "label failed: $out"
[ "$out" = $'fm::accepted\tfm::todo,fm::triage' ] || fail "label output: $out"
put=$(grep $'^PUT\t' "$FM_TEST_GLAB_LOG")
[ "$(count_method PUT)" = 1 ] || fail "label must use exactly one PUT: $(requests)"
assert_contains "$put" $'\t'"$ENC"$'\t' "the PUT addresses the issue itself"
put_body=${put##*$'\t'}
[ "$(printf '%s' "$put_body" | jq -r .add_labels)" = fm::accepted ] || fail "add_labels: $put_body"
[ "$(printf '%s' "$put_body" | jq -r .remove_labels)" = 'fm::todo,fm::triage' ] || fail "remove_labels: $put_body"
[ "$(printf '%s' "$put_body" | jq -r 'keys | join(",")')" = 'add_labels,remove_labels' ] \
  || fail "the PUT carries only label fields: $put_body"
[ "$(jq -c .labels "$FIX/issue.json")" = '["bug","fm::accepted","priority::high"]' ] \
  || fail "labels after PUT: $(jq -c .labels "$FIX/issue.json")"
assert_json_body PUT
pass "label removes only the prefixed labels and adds the new one in a single PUT, declared as JSON"

: > "$FM_TEST_GLAB_LOG"
out=$("$SCRIPT" label "$URL" fm::accepted 2>&1) || fail "idempotent label failed: $out"
[ "$out" = $'fm::accepted\t' ] || fail "idempotent output: $out"
[ "$(count_method PUT)" = 0 ] || fail "an already-set label must not PUT: $(requests)"
pass "label is idempotent when the label is already the only prefixed one"

: > "$FM_TEST_GLAB_LOG"
err=$("$SCRIPT" label "$URL" bug 2>&1); rc=$?
expect_code 1 "$rc" "a label outside the prefix is refused"
assert_contains "$err" "does not start with the prefix 'fm::'" "refusal names the prefix"
[ ! -s "$FM_TEST_GLAB_LOG" ] || fail "a refused label still reached glab"
err=$("$SCRIPT" label "$URL" fm:: 2>&1); rc=$?
expect_code 1 "$rc" "the bare prefix is refused"
err=$("$SCRIPT" label "$URL" 'fm::a,fm::b' 2>&1); rc=$?
expect_code 1 "$rc" "a comma in the label is refused"
pass "label refuses anything outside the prefix without a request"

# The refusal below prints the whole closed vocabulary, so the suite learns the
# seven state names from the script itself instead of keeping a second copy.
: > "$FM_TEST_GLAB_LOG"
err=$("$SCRIPT" label "$URL" fm::rejected 2>&1); rc=$?
expect_code 1 "$rc" "a well-formed fm:: label outside the vocabulary is refused"
assert_contains "$err" "expected one of:" "the refusal lists the whole fm:: vocabulary"
[ ! -s "$FM_TEST_GLAB_LOG" ] || fail "fm::rejected still reached glab: $(requests)"
typo=$("$SCRIPT" label "$URL" fm::rejcted 2>&1); rc=$?
expect_code 1 "$rc" "a near-miss typo is refused"
assert_contains "$typo" "fm::rejcted" "the refusal names the label it refused"
[ "$(count_method PUT)" = 0 ] || fail "a refused label recorded a PUT: $(requests)"
[ ! -s "$FM_TEST_GLAB_LOG" ] || fail "fm::rejcted still reached glab: $(requests)"
pass "label refuses an unknown fm:: state, typo included, before any request"

vocab=${err##*expected one of: }
IFS=' ' read -r -a fm_states <<<"$vocab"
[ "${#fm_states[@]}" = 7 ] || fail "the fm:: vocabulary must hold exactly seven states: $vocab"
for state in "${fm_states[@]}"; do
  new_case "vocab-${state//:/_}"
  out=$("$SCRIPT" label "$URL" "$state" 2>&1) || fail "the advertised state $state was refused: $out"
  [ "${out%%$'\t'*}" = "$state" ] || fail "label $state printed: $out"
  [ "$(jq -r --arg s "$state" '[.labels[] | select(startswith("fm::"))] == [$s]' "$FIX/issue.json")" = true ] \
    || fail "$state is not the only fm:: label after the swap: $(jq -c .labels "$FIX/issue.json")"
done
pass "every state the vocabulary advertises is accepted and becomes the only fm:: label"

new_case label-prefix
out=$("$SCRIPT" label "$URL" --prefix 'priority::' priority::low 2>&1) || fail "prefixed label failed: $out"
[ "$out" = $'priority::low\tpriority::high' ] || fail "custom prefix output: $out"
[ "$(jq -c .labels "$FIX/issue.json")" = '["bug","fm::todo","fm::triage","priority::low"]' ] \
  || fail "labels after custom-prefix PUT: $(jq -c .labels "$FIX/issue.json")"
pass "--prefix scopes the swap to another label family and leaves fm:: alone"

# --- checklist -----------------------------------------------------------------

new_case checklist
printf '%s' '{"id": 300, "system": false, "body": "Plan:\n\n- [ ] 1/ add the test\n- [ ] 2/ fix the loop\n- [x] 3/ done already → !9\n- [ ] 21/ not item two\n\nfooter"}' \
  > "$FIX/note-300.json"
out=$("$SCRIPT" checklist "$URL" 300 2 --done '!12' 2>&1) || fail "checklist failed: $out"
[ "$out" = '- [x] 2/ fix the loop → !12' ] || fail "checklist printed: $out"
new_body=$(jq -c .body "$FIX/note-300.json")
expected='"Plan:\n\n- [ ] 1/ add the test\n- [x] 2/ fix the loop → !12\n- [x] 3/ done already → !9\n- [ ] 21/ not item two\n\nfooter"'
[ "$new_body" = "$expected" ] || fail "checklist rewrote more than one line or changed a byte:"$'\n'"$new_body"
[ "$(count_method PUT)" = 1 ] || fail "checklist must PUT the note once: $(requests)"
assert_contains "$(grep $'^PUT\t' "$FM_TEST_GLAB_LOG")" $'\t'"$ENC"$'/notes/300\t' "the PUT addresses the note"
assert_json_body PUT
pass "checklist ticks exactly the addressed line and appends the suffix"

: > "$FM_TEST_GLAB_LOG"
err=$("$SCRIPT" checklist "$URL" 300 5 --done '!13' 2>&1); rc=$?
expect_code 1 "$rc" "a missing checklist line is refused"
assert_contains "$err" "no line starting with '- [ ] 5/'" "refusal names the missing line"
err=$("$SCRIPT" checklist "$URL" 300 3 --done '!13' 2>&1); rc=$?
expect_code 1 "$rc" "an already-ticked line is refused"
assert_contains "$err" "already ticked" "refusal says the line is already ticked"
[ "$(count_method PUT)" = 0 ] || fail "a refused checklist edit must not PUT: $(requests)"
pass "checklist refuses a missing or already-ticked line without writing"

printf '%s' '{"id": 301, "system": false, "body": "- [ ] 1/ a\r\n- [ ] 1/ b\r\n"}' > "$FIX/note-301.json"
err=$("$SCRIPT" checklist "$URL" 301 1 --done '!1' 2>&1); rc=$?
expect_code 1 "$rc" "two matching lines are refused"
assert_contains "$err" "2 lines starting with" "refusal counts the ambiguity"
printf '%s' '{"id": 302, "system": false, "body": "- [ ] 1/ a\r\n- [ ] 2/ b\r\n"}' > "$FIX/note-302.json"
"$SCRIPT" checklist "$URL" 302 1 --done '!1' >/dev/null 2>&1 || fail "CRLF checklist failed"
[ "$(jq -c .body "$FIX/note-302.json")" = '"- [x] 1/ a → !1\r\n- [ ] 2/ b\r\n"' ] \
  || fail "CRLF body was not preserved: $(jq -c .body "$FIX/note-302.json")"
pass "checklist refuses ambiguity and keeps CRLF endings and the trailing newline"

# --- show --since --------------------------------------------------------------

new_case show
cat > "$FIX/notes.json" <<'JSON'
[
  {"id": 1, "system": true,  "created_at": "2026-09-08T09:00:00.000Z",
   "author": {"id": 5, "username": "alice", "name": "Alice"}, "body": "added fm::todo label"},
  {"id": 2, "system": false, "created_at": "2026-09-08T09:30:00.000Z",
   "author": {"id": 5, "username": "alice", "name": "Alice"}, "body": "old human note"},
  {"id": 3, "system": false, "created_at": "2026-09-08T10:00:00.000Z",
   "author": {"id": 77, "username": "fm-bot", "name": "Firstmate Bot"}, "body": "firstmate's own question"},
  {"id": 4, "system": false, "created_at": "2026-09-08T10:05:00.000Z",
   "author": {"id": 6, "username": "bob", "name": "Bob"}, "body": "answer: option B"},
  {"id": 5, "system": false, "created_at": "2026-09-08T10:05:00.000Z",
   "author": {"id": 6, "username": "bob", "name": "Bob"}, "body": "same second as --since"},
  {"id": 6, "system": false, "created_at": "2026-09-08T10:05:00.900Z",
   "author": {"id": 6, "username": "bob", "name": "Bob"}, "body": "same second, 900ms later"}
]
JSON
out=$("$SCRIPT" show "$URL" 2>&1) || fail "show failed: $out"
[ "$(printf '%s' "$out" | jq -r .title)" = "Login page loops" ] || fail "show title: $out"
[ "$(printf '%s' "$out" | jq -r .iid)" = 42 ] || fail "show iid"
[ "$(printf '%s' "$out" | jq -r .project_id)" = 9 ] || fail "show project_id"
[ "$(printf '%s' "$out" | jq -r .project_path_with_namespace)" = grp/sub/deep/proj ] || fail "show project path"
[ "$(printf '%s' "$out" | jq -r .author.username)" = alice ] || fail "show author"
[ "$(printf '%s' "$out" | jq -c .labels)" = '["fm::todo","bug","fm::triage","priority::high"]' ] || fail "show labels"
[ "$(printf '%s' "$out" | jq -c '[.notes[].id]')" = '[2,4,5,6]' ] \
  || fail "notes without --since must drop only system and own notes: $(printf '%s' "$out" | jq -c .notes)"
[ "$(printf '%s' "$out" | jq -c '.notes[0] | keys')" = '["author","body","created_at","id"]' ] || fail "note shape"
[ "$(count_method GET)" = 3 ] || fail "show must read issue, user, and notes exactly once each: $(requests)"
pass "show assembles the issue and keeps only human notes not written by the token user"

out=$("$SCRIPT" show "$URL" --since 2026-09-08T10:05:00Z 2>&1) || fail "show --since failed: $out"
[ "$(printf '%s' "$out" | jq -c '[.notes[].id]')" = '[6]' ] || fail "--since is strictly after: $out"
out=$("$SCRIPT" show "$URL" --since 2026-09-08T10:04:59Z 2>&1) || fail "show --since failed: $out"
[ "$(printf '%s' "$out" | jq -c '[.notes[].id]')" = '[4,5,6]' ] || fail "--since Z filter: $out"
out=$("$SCRIPT" show "$URL" --since '2026-09-08T16:35:00+07:00' 2>&1) || fail "show --since offset failed: $out"
[ "$(printf '%s' "$out" | jq -c '[.notes[].id]')" = '[4,5,6]' ] || fail "--since with a +07:00 offset: $out"
out=$("$SCRIPT" show "$URL" --since 2026-09-08T10:05:00.500Z 2>&1) || fail "show --since fraction failed: $out"
[ "$(printf '%s' "$out" | jq -c '[.notes[].id]')" = '[6]' ] \
  || fail "--since with a fraction must keep the later same-second note only: $out"
out=$("$SCRIPT" show "$URL" --since 2026-09-08T10:05:00.900Z 2>&1) || fail "show --since fraction failed: $out"
[ "$(printf '%s' "$out" | jq -c '[.notes[].id]')" = '[]' ] \
  || fail "--since equal to a note's fractional created_at is not strictly after: $out"
epoch=$(( $(date -u -d '2026-09-08T09:59:59Z' +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' '2026-09-08T09:59:59Z' +%s) ))
out=$("$SCRIPT" show "$URL" --since "$epoch" 2>&1) || fail "show --since epoch failed: $out"
[ "$(printf '%s' "$out" | jq -c '[.notes[].id]')" = '[4,5,6]' ] || fail "--since epoch: $out"
err=$("$SCRIPT" show "$URL" --since yesterday 2>&1); rc=$?
expect_code 1 "$rc" "an unparseable --since is refused"
pass "show --since filters by instant in ISO-8601 with Z or offset, or by epoch, down to the fraction"

new_case show-pages
cat > "$FIX/notes.json" <<'JSON'
[
  {"id": 101, "system": false, "created_at": "2026-09-08T09:00:00.000Z",
   "author": {"id": 5, "username": "alice", "name": "Alice"}, "body": "first page"},
  {"id": 102, "system": true, "created_at": "2026-09-08T09:01:00.000Z",
   "author": {"id": 5, "username": "alice", "name": "Alice"}, "body": "changed label"}
]
JSON
cat > "$FIX/notes-page2.json" <<'JSON'
[
  {"id": 201, "system": false, "created_at": "2026-09-08T09:02:00.000Z",
   "author": {"id": 77, "username": "fm-bot", "name": "Firstmate Bot"}, "body": "own note on page two"},
  {"id": 202, "system": false, "created_at": "2026-09-08T09:03:00.000Z",
   "author": {"id": 6, "username": "bob", "name": "Bob"}, "body": "human reply on page two"}
]
JSON
out=$("$SCRIPT" show "$URL" 2>&1) || fail "show over two pages failed: $out"
[ "$(printf '%s' "$out" | jq -c '[.notes[].id]')" = '[101,202]' ] \
  || fail "notes from every page must be folded and filtered alike: $(printf '%s' "$out" | jq -c .notes)"
out=$("$SCRIPT" show "$URL" --since 2026-09-08T09:00:30Z 2>&1) || fail "show --since over two pages failed: $out"
[ "$(printf '%s' "$out" | jq -c '[.notes[].id]')" = '[202]' ] || fail "--since applies to the second page: $out"
pass "show folds every page of a paginated notes response"

# --- comment / comment-update -------------------------------------------------

new_case comment
printf 'Plan for #42:\n\n- [ ] 1/ first {not json}\n' > "$FIX/body.md"
out=$("$SCRIPT" comment "$URL" --body-file "$FIX/body.md" 2>&1) || fail "comment failed: $out"
[ "$out" = $'501\t'"$URL"'#note_501' ] || fail "comment output: $out"
[ "$(cat "$FIX/posted-note.body")" = "$(cat "$FIX/body.md")" ] || fail "posted body differs from the file"
[ "$(count_method POST)" = 1 ] || fail "comment must POST once: $(requests)"
assert_contains "$(grep $'^POST\t' "$FM_TEST_GLAB_LOG")" $'\t'"$ENC"$'/notes\t' "the POST creates a note on the issue"
out=$(printf '{"looks":"like json"}\n' | "$SCRIPT" comment "$URL" --body-file - 2>&1) || fail "stdin comment failed: $out"
[ "$(cat "$FIX/posted-note.body")" = '{"looks":"like json"}' ] || fail "stdin body was reinterpreted"
err=$("$SCRIPT" comment "$URL" --body-file /dev/null 2>&1); rc=$?
expect_code 1 "$rc" "an empty body is refused"
assert_json_body POST
pass "comment posts the body verbatim from a file or stdin, declared as JSON"

printf '%s' '{"id": 501, "system": false, "body": "old"}' > "$FIX/note-501.json"
: > "$FM_TEST_GLAB_LOG"
printf 'updated plan\n' > "$FIX/body2.md"
out=$("$SCRIPT" comment-update "$URL" 501 --body-file "$FIX/body2.md" 2>&1) || fail "comment-update failed: $out"
[ "$out" = $'501\t'"$URL"'#note_501' ] || fail "comment-update output: $out"
[ "$(jq -r .body "$FIX/note-501.json")" = 'updated plan' ] || fail "note body not replaced"
[ "$(count_method PUT)" = 1 ] && [ "$(count_method POST)" = 0 ] || fail "comment-update must PUT once: $(requests)"
assert_json_body PUT
err=$("$SCRIPT" comment-update "$URL" abc --body-file "$FIX/body2.md" 2>&1); rc=$?
expect_code 1 "$rc" "a non-numeric note id is refused"
pass "comment-update replaces one note body in place"

# --- hard limits across every mutating request ---------------------------------

for log in "$TMP_ROOT"/*/requests.log; do
  ! grep -E $'^(PUT|POST|DELETE)\t' "$log" | grep -Ev $'\t'"$ENC"'(/notes(/[0-9]+)?)?'$'\t' >/dev/null \
    || fail "a mutating request left the issue and its notes: $log"
  ! grep -E $'^PUT\t[^\t]*\t[^\t]*\t'"$ENC"$'\t' "$log" | grep -E 'state_event|assignee|milestone|"labels"' >/dev/null \
    || fail "an issue PUT carried a field other than add_labels/remove_labels: $log"
  ! grep -E $'^(PUT|POST)\t' "$log" | grep -Ev $'^[^\t]*\t[^\t]*\t[^\t]*\t[^\t]*\t([^\t]*;)?Content-Type: application/json(;[^\t]*)?\t' >/dev/null \
    || fail "a body-carrying request went out without a JSON Content-Type: $log"
done
pass "every mutating request stays on the issue's labels and notes and declares its JSON body"

# --- glab failure and timeout --------------------------------------------------

new_case failure
: > "$FIX/fail"
err=$("$SCRIPT" show "$URL" 2>&1); rc=$?
expect_code 2 "$rc" "a glab failure exits 2"
assert_contains "$err" "failed (glab exit 1)" "the failure names the request"
new_case timeout
: > "$FIX/hang"
err=$(FM_GITLAB_TIMEOUT=1 "$SCRIPT" show "$URL" 2>&1); rc=$?
expect_code 2 "$rc" "a hung glab exits 2"
assert_contains "$err" "timed out after 1s" "the timeout is reported"
pass "glab failures and timeouts are bounded and reported as exit 2"

# --- project -------------------------------------------------------------------

new_case project
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/projects" "$HOME_DIR/data"
add_clone() {  # <name> <origin-url>
  fm_git_init_commit "$HOME_DIR/projects/$1"
  git -C "$HOME_DIR/projects/$1" remote add origin "$2"
}
add_clone backend-app 'https://gitlab.example.test/grp/sub/backend-app.git'
add_clone frontend-app 'git@gitlab.example.test:grp/sub/frontend-app.git'
add_clone tools 'ssh://git@GitLab.Example.Test:2222/grp/sub/Tools'
add_clone elsewhere 'https://other.example.test/grp/sub/backend-app.git'
fm_git_init_commit "$HOME_DIR/projects/no-origin"
mkdir -p "$HOME_DIR/projects/not-a-repo"
cat > "$HOME_DIR/data/projects.md" <<'MD'
# Projects

- backend-app [direct-PR +yolo] - the API (added 2026-09-01)
- tools [no-mistakes-prod-only] - internal tooling (added 2026-09-02)
MD

out=$(FM_HOME="$HOME_DIR" "$SCRIPT" project 'https://gitlab.example.test/grp/sub/backend-app/-/issues/1' 2>&1) \
  || fail "project failed for the https origin: $out"
[ "$out" = "$HOME_DIR/projects/backend-app"$'\t''direct-PR on' ] || fail "https match: $out"
out=$(FM_HOME="$HOME_DIR" "$SCRIPT" project 'https://gitlab.example.test/grp/sub/frontend-app/-/issues/2' 2>&1) \
  || fail "project failed for the scp-like origin: $out"
[ "$out" = "$HOME_DIR/projects/frontend-app"$'\t''unregistered' ] || fail "scp-like match: $out"
out=$(FM_HOME="$HOME_DIR" "$SCRIPT" project 'https://gitlab.example.test/grp/sub/tools/-/issues/3' 2>&1) \
  || fail "project failed for the ssh:// origin: $out"
[ "$out" = "$HOME_DIR/projects/tools"$'\t''no-mistakes-prod-only off' ] || fail "ssh:// match with port and case: $out"
[ ! -s "$FM_TEST_GLAB_LOG" ] || fail "project must not call glab: $(requests)"
pass "project matches https, scp-like, and ssh:// origins and reports the raw registered posture"

err=$(FM_HOME="$HOME_DIR" "$SCRIPT" project 'https://gitlab.example.test/grp/sub/unknown-app/-/issues/4' 2>&1); rc=$?
expect_code 3 "$rc" "no matching clone exits 3"
assert_contains "$err" "no clone under $HOME_DIR/projects has an origin matching gitlab.example.test/grp/sub/unknown-app" \
  "the miss names the host and path"
err=$(FM_HOME="$HOME_DIR" "$SCRIPT" project 'https://other.example.test/grp/sub/frontend-app/-/issues/5' 2>&1); rc=$?
expect_code 3 "$rc" "a same-path clone on another host is not a match"
err=$(FM_HOME="$TMP_ROOT/empty-home" "$SCRIPT" project 'https://gitlab.example.test/grp/sub/backend-app/-/issues/6' 2>&1); rc=$?
expect_code 3 "$rc" "a home with no projects directory exits 3"
pass "project exits 3 with a clear message when nothing matches"

add_clone backend-app-copy 'https://gitlab.example.test/grp/sub/backend-app'
err=$(FM_HOME="$HOME_DIR" "$SCRIPT" project 'https://gitlab.example.test/grp/sub/backend-app/-/issues/7' 2>&1); rc=$?
expect_code 1 "$rc" "two matching clones are refused"
assert_contains "$err" "2 clones match" "the ambiguity is named"
pass "project refuses to guess between two clones of one project"

NESTED_HOME="$TMP_ROOT/nested-home"
fm_git_init_commit "$NESTED_HOME"
git -C "$NESTED_HOME" remote add origin 'https://gitlab.example.test/grp/sub/mate-home.git'
mkdir -p "$NESTED_HOME/projects/plain-dir" "$NESTED_HOME/data"
err=$(FM_HOME="$NESTED_HOME" "$SCRIPT" project 'https://gitlab.example.test/grp/sub/mate-home/-/issues/8' 2>&1); rc=$?
expect_code 3 "$rc" "a plain directory under projects/ must not resolve to the enclosing repository's origin"
assert_contains "$err" "no clone under $NESTED_HOME/projects" "the miss is reported as no clone"
pass "project skips a projects/ entry that is not a repository of its own"

echo "all fm-gitlab-issue tests passed"
