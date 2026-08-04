#!/usr/bin/env bash
# Behavior-first coverage for automatic pull-request review and feedback ownership.
#
# The closest end-user boundary is the public fm-pr-review command over a
# controlled gh-axi executable and disposable Firstmate homes. The independent
# oracle is each fixture's explicit relevant PR/head/comment set, never a copy of
# the queue algorithm. Crash seams exercise every durable mutation boundary.
# The realistic mutation witnesses are stated at each critical assertion: a
# head-only cursor, actor-type-wide bot exclusion, queue append after cursor
# advance, and post-before-receipt replay would each make that assertion fail.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_REVIEW="$ROOT/bin/fm-pr-review.sh"
ADAPTER="$ROOT/bin/fm-procevent-pr-review.sh"
STATE_ENGINE="$ROOT/bin/fm-pr-review-state.mjs"
TMP=$(fm_test_tmproot fm-pr-review)
mkdir -p "$TMP"
export FM_PROCEVENT_CLAIM_ROOT="$TMP/claims"

[ -x "$PR_REVIEW" ] || fail "automatic pull-request review owner is missing"
[ -x "$ADAPTER" ] || fail "automatic pull-request review process-event adapter is missing"
[ -f "$STATE_ENGINE" ] || fail "automatic pull-request review state owner is missing"
pass "automatic pull-request review owner is installed"

sha_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
sha_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

new_home() {
  mkdir -p "$1/state" "$1/data"
}

run_review() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PR_REVIEW" "$@"
}

poll_fixture() {
  local home=$1 fixture=$2 now=$3
  shift 3
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PR_REVIEW_OBSERVATION_FILE="$fixture" FM_PR_REVIEW_NOW="$now" \
    FM_PR_REVIEW_FORCE_POLL=1 "$PR_REVIEW" poll --force "$@"
}

item_json() {
  local home=$1 type=$2
  run_review "$home" list --json | jq -c --arg type "$type" '[.[]|select(.type==$type)]'
}

item_id_for() {
  local home=$1 type=$2 number=${3:-}
  run_review "$home" list --json | jq -r --arg type "$type" --arg number "$number" \
    '.[]|select(.type==$type and ($number=="" or (.number|tostring)==$number))|.id' | head -1
}

write_observation() {
  local path=$1 now=$2 pulls=$3
  jq -n --argjson now "$now" --argjson pulls "$pulls" \
    '{schema:"fm-pr-review-observation.v1",viewer:"captain",observed_at:$now,pulls:$pulls}' > "$path"
}

pull_json() { # <number> <author> <head> <scopes-json> [reviews] [inline] [conversation]
  jq -cn \
    --argjson number "$1" --arg author "$2" --arg head "$3" --argjson scopes "$4" \
    --argjson reviews "${5:-[]}" --argjson inline "${6:-[]}" --argjson conversation "${7:-[]}" '
    {repository:"acme/widgets",number:$number,url:("https://github.com/acme/widgets/pull/"+($number|tostring)),
     state:"open",draft:false,head:$head,author:$author,scopes:$scopes,
     reviews:$reviews,review_comments:$inline,conversation_comments:$conversation}'
}

# --- Discovery, all inventory scopes, exact heads, and stable silence --------
H_SCOPE="$TMP/scope-home"; new_home "$H_SCOPE"
PULLS_SCOPE=$(jq -cn \
  --argjson a "$(pull_json 1 captain "$sha_a" '["authored","materially-participating"]')" \
  --argjson r "$(pull_json 2 reviewer "$sha_a" '["review-requested","materially-participating"]')" \
  --argjson s "$(pull_json 3 assignee "$sha_a" '["assigned","materially-participating"]')" \
  --argjson m "$(pull_json 4 participant "$sha_a" '["materially-participating"]')" \
  '[$a,$r,$s,$m]')
OBS_SCOPE="$TMP/scope.json"; write_observation "$OBS_SCOPE" 1000 "$PULLS_SCOPE"
out=$(poll_fixture "$H_SCOPE" "$OBS_SCOPE" 1000) || fail "new relevant PR discovery failed"
assert_contains "$out" '"changed":4' "new PRs did not enter the durable queue"
SCOPE_EVENT=$(printf '%s' "$out" | jq -r '.event_id')
run_review "$H_SCOPE" acknowledge-event "$SCOPE_EVENT" >/dev/null || fail "discovery notification acknowledgement failed"
reviews=$(item_json "$H_SCOPE" initial-review)
[ "$(printf '%s' "$reviews" | jq 'length')" -eq 4 ] || fail "expected one review per newly discovered PR"
for row in '1 authored' '2 review-requested' '3 assigned' '4 materially-participating'; do
  IFS=' ' read -r number scope <<EOF
$row
EOF
  printf '%s' "$reviews" | jq -e --argjson number "$number" --arg scope "$scope" \
    'any(.[]; .number==$number and (.scopes|index($scope)!=null))' >/dev/null \
    || fail "inventory scope $scope was not retained"
done
SCOPE_OWNER=$(printf '%s' "$reviews" | jq -r '.[]|select(.number==1)|.id')
run_review "$H_SCOPE" claim "$SCOPE_OWNER" --owner-task scope-owner >/dev/null \
  || fail "scope fixture could not occupy the one-at-a-time lane"
before=$(find "$H_SCOPE/state/pr-review/items" -type f | wc -l | tr -d ' ')
set +e
stable=$(poll_fixture "$H_SCOPE" "$OBS_SCOPE" 1001 2> "$TMP/stable.err")
stable_rc=$?
set -e
[ "$stable_rc" -eq 3 ] || fail "unchanged poll should use the silent no-result exit, got $stable_rc"
[ -z "$stable" ] || fail "unchanged poll emitted output: $stable"
after=$(find "$H_SCOPE/state/pr-review/items" -type f | wc -l | tr -d ' ')
[ "$before" -eq "$after" ] || fail "unchanged poll dispatched durable work"
[ -z "$(find "$H_SCOPE/state" -maxdepth 1 -name '*.meta' -print)" ] || fail "unchanged poll dispatched a model worker"

PULLS_HEAD=$(printf '%s' "$PULLS_SCOPE" | jq --arg head "$sha_b" 'map(if .number==1 then .head=$head else . end)')
OBS_HEAD="$TMP/head.json"; write_observation "$OBS_HEAD" 1002 "$PULLS_HEAD"
poll_fixture "$H_SCOPE" "$OBS_HEAD" 1002 >/dev/null || fail "head-change poll failed"
item_json "$H_SCOPE" initial-review | jq -e --arg head "$sha_b" \
  '([.[]|select(.number==1)]|length)==1 and any(.[]; .number==1 and .head==$head and .generation==2 and .state=="pending")' >/dev/null \
  || fail "a new exact head did not invalidate and re-dispatch the one review owner"
pass "discovery covers authored, requested, assigned, and participating PRs with one review per exact head and unchanged silence"

# --- Feedback identity, bots, self replies, and non-silent dispositions ------
H_FEEDBACK="$TMP/feedback-home"; new_home "$H_FEEDBACK"
REVIEWS=$(jq -cn --arg head "$sha_a" '[
  {id:101,node_id:"R_human",state:"COMMENTED",body:"The retry path can lose the final write.",commit_id:$head,submitted_at:"2026-01-01T00:00:00Z",user:{login:"human",type:"User"}},
  {id:102,node_id:"R_ack",state:"APPROVED",body:"LGTM",commit_id:$head,submitted_at:"2026-01-01T00:00:01Z",user:{login:"human2",type:"User"}}
]')
INLINE=$(jq -cn --arg head "$sha_a" '[
  {id:201,node_id:"IC_human",body:"This null branch reaches production and throws.",commit_id:$head,updated_at:"2026-01-01T00:01:00Z",html_url:"https://github.com/acme/widgets/pull/1#discussion_r201",user:{login:"human",type:"User"}},
  {id:202,node_id:"IC_bot",body:"Potential race: the second callback can overwrite newer state.",commit_id:$head,updated_at:"2026-01-01T00:01:01Z",user:{login:"coderabbitai[bot]",type:"Bot"}},
  {id:203,node_id:"IC_transport",body:"Deployment preview: ready at https://preview.invalid",commit_id:$head,updated_at:"2026-01-01T00:01:02Z",user:{login:"vercel[bot]",type:"Bot"}},
  {id:204,node_id:"IC_self",body:"Corrected at exact head.",commit_id:$head,updated_at:"2026-01-01T00:01:03Z",user:{login:"captain",type:"User"}}
]')
CONVERSATION=$(jq -cn '[
  {id:301,node_id:"C_human",body:"The issue intent also requires preserving the sibling value.",updated_at:"2026-01-01T00:02:00Z",html_url:"https://github.com/acme/widgets/pull/1#issuecomment-301",user:{login:"third",type:"User"}},
  {id:302,node_id:"C_transport",body:"<!-- firstmate-transport --> delivered",updated_at:"2026-01-01T00:02:01Z",user:{login:"otherbot[bot]",type:"Bot"}}
]')
PULL_FEEDBACK=$(pull_json 1 captain "$sha_a" '["authored","materially-participating"]' "$REVIEWS" "$INLINE" "$CONVERSATION")
OBS_FEEDBACK="$TMP/feedback.json"; write_observation "$OBS_FEEDBACK" 1100 "[$PULL_FEEDBACK]"
poll_fixture "$H_FEEDBACK" "$OBS_FEEDBACK" 1100 >/dev/null || fail "feedback discovery failed"
feedback=$(item_json "$H_FEEDBACK" feedback)
[ "$(printf '%s' "$feedback" | jq 'length')" -eq 4 ] || fail "substantive feedback set was not exact: $feedback"
printf '%s' "$feedback" | jq -e 'any(.[]; .feedback.author=="coderabbitai[bot]")' >/dev/null \
  || fail "substantive automated reviewer feedback was dropped merely because it was a bot"
printf '%s' "$feedback" | jq -e 'all(.[]; .feedback.author!="captain" and .feedback.author!="vercel[bot]")' >/dev/null \
  || fail "self reply or transport-only bot noise entered the queue"
pass "feedback includes actionable bodies, inline comments, conversation, and substantive bots without self-reply loops"

# --- A fake gh-axi boundary with explicit pagination and write replay --------
FAKEBIN=$(fm_fakebin "$TMP/github")
DATASET="$TMP/github/dataset.json"
GITHUB_LOG="$TMP/github/calls.log"
: > "$GITHUB_LOG"
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_GH_LOG"
[ "${FM_FAKE_AUTH_FAIL:-0}" = 0 ] || { printf 'authentication required\n' >&2; exit 1; }
json_body() {
  local data=$1 payload encoded
  payload=$(jq -crn --argjson data "$data" '["fm-pr-review-safe-v1",($data|tojson)]|@tsv')
  encoded=$(jq -Rn --arg value "$payload" '$value')
  printf 'api_response:\n  body: %s\n  truncated: false\n' "$encoded"
}
page_values() {
  local array=$1 endpoint=$2 per page start
  per=$(printf '%s' "$endpoint" | sed -n 's/.*[?&]per_page=\([0-9][0-9]*\).*/\1/p'); per=${per:-25}
  page=$(printf '%s' "$endpoint" | sed -n 's/.*[?&]page=\([0-9][0-9]*\).*/\1/p'); page=${page:-1}
  start=$(( (page - 1) * per ))
  printf '%s' "$array" | jq -c --argjson start "$start" --argjson per "$per" '.[$start:$start+$per]'
}
if [ "${1-}" = pr ] && [ "${2-}" = review ]; then
  number=$3; shift 3
  repo=
  body_file=
  while [ "$#" -gt 0 ]; do
    case "$1" in --repo) repo=$2; shift 2 ;; --body-file) body_file=$2; shift 2 ;; *) shift ;; esac
  done
  [ "${FM_FAKE_POST_FAIL:-0}" = 0 ] || exit 1
  body=$(cat "$body_file")
  tmp="$FM_FAKE_DATASET.tmp"
  jq --argjson number "$number" --arg body "$body" --arg viewer "${FM_FAKE_VIEWER:-captain}" '
    .pulls |= map(if .number==$number then .reviews += [{id:9901,node_id:"posted-review",body:$body,commit_id:.head,submitted_at:"2026-01-01T02:00:00Z",user:{login:$viewer,type:"User"}}] else . end)' \
    "$FM_FAKE_DATASET" > "$tmp" && mv "$tmp" "$FM_FAKE_DATASET"
  printf 'reviewed\n'
  exit 0
fi
[ "${1-}" = api ] || exit 2
shift
method=GET
if [ "${1-}" = POST ]; then method=POST; shift; fi
endpoint=${1-}; shift || true
case "$endpoint" in
  /user) json_body "$(jq -cn --arg login "${FM_FAKE_VIEWER:-captain}" '{login:$login}')" ;;
  /rate_limit)
    json_body "$(jq -cn --argjson core "${FM_FAKE_CORE_REMAINING:-5000}" --argjson search "${FM_FAKE_SEARCH_REMAINING:-30}" '{core:{remaining:$core,reset:2000},search:{remaining:$search,reset:2000}}')" ;;
  /search/issues*)
    case "$endpoint" in
      *author%3A%40me*) scope=authored ;;
      *review-requested%3A%40me*) scope=review-requested ;;
      *assignee%3A%40me*) scope=assigned ;;
      *involves%3A%40me*) scope=materially-participating ;;
      *) scope=none ;;
    esac
    rows=$(jq -c --arg scope "$scope" '[.pulls[]|select(.scopes|index($scope)!=null)|{repository_url:("https://api.github.com/repos/"+.repository),number}]' "$FM_FAKE_DATASET")
    page=$(page_values "$rows" "$endpoint")
    total=$(printf '%s' "$rows" | jq 'length')
    json_body "$(jq -cn --argjson total "$total" --argjson items "$page" '{total:$total,items:$items}')" ;;
  /repos/*/pulls/*/reviews/[0-9]*|/repos/*/pulls/comments/[0-9]*|/repos/*/issues/comments/[0-9]*)
    clean=${endpoint%%\?*}; id=${clean##*/}; expression=${2-}
    start=$(printf '%s' "$expression" | sed -n 's/.*chunk:.*\[\([0-9][0-9]*\):\([0-9][0-9]*\)\].*/\1/p')
    end=$(printf '%s' "$expression" | sed -n 's/.*chunk:.*\[\([0-9][0-9]*\):\([0-9][0-9]*\)\].*/\2/p')
    start=${start:-0}; end=${end:-500}
    case "$clean" in
      */pulls/*/reviews/*) field=reviews ;;
      */pulls/comments/*) field=review_comments ;;
      */issues/comments/*) field=conversation_comments ;;
    esac
    row=$(jq -c --argjson id "$id" --arg field "$field" --argjson start "$start" --argjson end "$end" '
      [.pulls[]|.[$field][]|select(.id==$id)][0]
      |.+{body_length:((.body//"")|length),chunk:((.body//"")[$start:$end])}
      |del(.body)' "$FM_FAKE_DATASET")
    json_body "$row" ;;
  /repos/*/pulls/*/reviews*|/repos/*/pulls/*/comments*|/repos/*/issues/*/comments*)
    clean=${endpoint%%\?*}
    repo_number=${clean#/repos/}; repo=${repo_number%%/pulls/*};
    if [ "$repo" = "$repo_number" ]; then repo=${repo_number%%/issues/*}; fi
    number=$(printf '%s' "$clean" | sed -E 's#^.*/(pulls|issues)/([0-9]+).*$#\2#')
    if [ "$method" = GET ] && [ "${FM_FAKE_READ_FAIL_PR:-}" = "$number" ]; then
      printf 'server error\n' >&2
      exit 1
    fi
    if [ "$method" = POST ]; then
      [ "${FM_FAKE_POST_FAIL:-0}" = 0 ] || exit 1
      body=
      while [ "$#" -gt 0 ]; do
        if [ "$1" = --field ]; then case "$2" in body=*) body=${2#body=} ;; esac; shift 2; else shift; fi
      done
      tmp="$FM_FAKE_DATASET.tmp"
      if printf '%s' "$clean" | grep '/replies$' >/dev/null; then
        parent=$(printf '%s' "$clean" | sed -E 's#^.*/comments/([0-9]+)/replies$#\1#')
        jq --argjson number "$number" --argjson parent "$parent" --arg body "$body" --arg viewer "${FM_FAKE_VIEWER:-captain}" '
          .pulls |= map(if .number==$number then .review_comments += [{id:9902,node_id:"posted-inline",body:$body,commit_id:.head,in_reply_to_id:$parent,updated_at:"2026-01-01T02:00:00Z",user:{login:$viewer,type:"User"}}] else . end)' \
          "$FM_FAKE_DATASET" > "$tmp"
      else
        jq --argjson number "$number" --arg body "$body" --arg viewer "${FM_FAKE_VIEWER:-captain}" '
          .pulls |= map(if .number==$number then .conversation_comments += [{id:9903,node_id:"posted-issue",body:$body,updated_at:"2026-01-01T02:00:00Z",user:{login:$viewer,type:"User"}}] else . end)' \
          "$FM_FAKE_DATASET" > "$tmp"
      fi
      mv "$tmp" "$FM_FAKE_DATASET"
      json_body '{"id":9903,"node_id":"posted","html_url":"https://github.com/acme/widgets/pull/1#posted"}'
    else
      case "$clean" in
        */pulls/*/reviews) field=reviews ;;
        */pulls/*/comments) field=review_comments ;;
        */issues/*/comments) field=conversation_comments ;;
      esac
      rows=$(jq -c --argjson number "$number" --arg field "$field" '
        .pulls[]|select(.number==$number)|.[$field]
        |map(.+{body_length:((.body//"")|length),body:((.body//"")[0:100])})' "$FM_FAKE_DATASET")
      json_body "$(page_values "$rows" "$endpoint")"
    fi ;;
  /repos/*/pulls/*)
    clean=${endpoint%%\?*}; number=${clean##*/}
    row=$(jq -c --argjson number "$number" '.pulls[]|select(.number==$number)|{number,html_url:.url,state,draft,head,author,requested_reviewers:(.requested_reviewers//[]),assignees:(.assignees//[])}' "$FM_FAKE_DATASET")
    # The production jq selection maps head and author from GitHub nesting; the
    # fake returns the already-selected boundary expected by the state owner.
    json_body "$row" ;;
  *) printf 'unknown endpoint %s\n' "$endpoint" >&2; exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/gh-axi"
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_GH_AUTH_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_GH_AUTH_LOG"
case "${1-} ${2-}" in
  'auth status') exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/gh"

make_dataset() {
  local pulls=$1
  jq -n --argjson pulls "$pulls" '{pulls:$pulls}' > "$DATASET"
}

run_fake_poll() {
  local home=$1 now=$2
  shift 2
  PATH="$FAKEBIN:$PATH" FM_FAKE_DATASET="$DATASET" FM_FAKE_GH_LOG="$GITHUB_LOG" \
    FM_PR_REVIEW_PAGE_SIZE=2 FM_PR_REVIEW_FEEDBACK_PAGE_SIZE=2 \
    FM_PR_REVIEW_MAX_PAGES=4 FM_PR_REVIEW_MAX_PULLS=20 \
    FM_PR_REVIEW_NOW="$now" FM_PR_REVIEW_FORCE_POLL=1 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PR_REVIEW" poll --force "$@"
}

# More than one page of PRs, reviews, inline threads, and conversation comments.
H_PAGE="$TMP/page-home"; new_home "$H_PAGE"
PAGED_PULLS='[]'
for number in 1 2 3 4 5; do
  reviews='[]'; inline='[]'; conversation='[]'
  if [ "$number" -eq 1 ]; then
    reviews=$(jq -cn --arg head "$sha_a" '[range(1;6)|{id:(100+.),node_id:("R"+(.|tostring)),body:("Review finding "+(.|tostring)),commit_id:$head,submitted_at:"2026-01-01T00:00:00Z",user:{login:("reviewer"+(.|tostring)),type:"User"}}]')
    inline=$(jq -cn --arg head "$sha_a" '[range(1;6)|{id:(200+.),node_id:("I"+(.|tostring)),body:("Inline finding "+(.|tostring)),commit_id:$head,updated_at:"2026-01-01T00:00:00Z",user:{login:("inline"+(.|tostring)),type:"User"}}]')
    long_body=$(jq -nr '[range(0;900)|"x"]|join("")+" production bug should be fixed"')
    inline=$(printf '%s' "$inline" | jq --arg body "$long_body" '.[0].body=$body')
    conversation=$(jq -cn '[range(1;6)|{id:(300+.),node_id:("C"+(.|tostring)),body:("Conversation finding "+(.|tostring)),updated_at:"2026-01-01T00:00:00Z",user:{login:("commenter"+(.|tostring)),type:"User"}}]')
  fi
  p=$(pull_json "$number" captain "$sha_a" '["authored","materially-participating"]' "$reviews" "$inline" "$conversation")
  PAGED_PULLS=$(jq -cn --argjson pulls "$PAGED_PULLS" --argjson p "$p" '$pulls+[$p]')
done
make_dataset "$PAGED_PULLS"
: > "$GITHUB_LOG"
run_fake_poll "$H_PAGE" 1200 >/dev/null || fail "bounded multi-page live inventory failed"
assert_grep 'page=2' "$GITHUB_LOG" "second pagination page was never read"
assert_grep 'page=3' "$GITHUB_LOG" "third pagination page was never read"
[ "$(item_json "$H_PAGE" initial-review | jq 'length')" -eq 5 ] || fail "multi-page pull inventory dropped PRs"
[ "$(item_json "$H_PAGE" feedback | jq 'length')" -eq 15 ] || fail "multi-page review/comment inventory dropped feedback"
item_json "$H_PAGE" feedback | jq -e 'any(.[]; .feedback.node_id=="I1" and .feedback.body_truncated==true and (.feedback.body|length)==100)' >/dev/null \
  || fail "bounded feedback transport did not disclose a truncated body"
LONG_ID=$(run_review "$H_PAGE" list --json | jq -r '.[]|select(.type=="feedback" and .feedback.node_id=="I1")|.id')
run_review "$H_PAGE" claim "$LONG_ID" --owner-task complete-body-owner >/dev/null || fail "truncated feedback could not be claimed"
printf 'Exact-head evidence for %s covers the complete production path and a disconfirming counterexample.\n' "$sha_a" > "$TMP/long-evidence.md"
printf 'Dismissed at exact head %s after exact-node evidence disproved the production-path claim.\n' "$sha_a" > "$TMP/long-reply.md"
set +e
FM_PR_REVIEW_CURRENT_HEAD="$sha_a" run_review "$H_PAGE" resolve-feedback "$LONG_ID" \
  --head "$sha_a" --generation 1 --verdict dismissed --evidence-file "$TMP/long-evidence.md" \
  --reply-file "$TMP/long-reply.md" >/dev/null 2>&1
prefix_only_rc=$?
set -e
[ "$prefix_only_rc" -ne 0 ] || fail "a truncated transport prefix was adjudicated as the complete claim"
complete=$(PATH="$FAKEBIN:$PATH" FM_FAKE_DATASET="$DATASET" FM_FAKE_GH_LOG="$GITHUB_LOG" \
  FM_HOME="$H_PAGE" FM_STATE_OVERRIDE="$H_PAGE/state" run_review "$H_PAGE" fetch-feedback "$LONG_ID") \
  || fail "truncated exact-node feedback body could not be reconstructed"
complete_path=$(printf '%s' "$complete" | jq -r '.path')
jq -e '.schema=="fm-pr-review-feedback-body.v1" and (.body|length)>900 and (.body|endswith("production bug should be fixed"))' "$complete_path" >/dev/null \
  || fail "exact feedback body record did not preserve content beyond the bounded prefix"
FM_PR_REVIEW_CURRENT_HEAD="$sha_a" run_review "$H_PAGE" resolve-feedback "$LONG_ID" \
  --head "$sha_a" --generation 1 --verdict dismissed --evidence-file "$TMP/long-evidence.md" \
  --reply-file "$TMP/long-reply.md" >/dev/null || fail "complete exact-node feedback could not be adjudicated"
pass "bounded pagination covers multiple PR, review, inline-thread, and conversation pages"

# A truncated body whose bounded prefix carries CRLF line endings or leading
# whitespace must still reconstruct. The independent oracle is the exact GitHub
# body text; normalizing before slicing would shift the 100-character window and
# make the reconstructed prefix disagree with the stored one forever.
printf 'Exact-head %s evidence disproves this claim across the complete production path.\n' "$sha_a" > "$TMP/crlf-evidence.md"
printf 'Dismissed at exact head %s after the complete exact-node body was verified.\n' "$sha_a" > "$TMP/crlf-reply.md"
crlf_case() { # <name> <node> <jq-body-expression> <expected-start> <expected-end>
  local name=$1 node=$2 expression=$3 start=$4 tail=$5 home inline id record
  home="$TMP/$name"; new_home "$home"
  inline=$(jq -cn --arg head "$sha_a" --arg node "$node" \
    "[{id:401,node_id:\$node,body:($expression),commit_id:\$head,updated_at:\"2026-01-01T04:00:00Z\",user:{login:\"human\",type:\"User\"}}]")
  make_dataset "[$(pull_json 1 captain "$sha_a" '["authored"]' '[]' "$inline" '[]')]"
  : > "$GITHUB_LOG"
  run_fake_poll "$home" 1210 >/dev/null || fail "$node feedback discovery failed"
  id=$(item_id_for "$home" feedback)
  run_review "$home" show "$id" | jq -e '.feedback.body_truncated==true' >/dev/null \
    || fail "$node was not disclosed as truncated beyond the bounded prefix"
  run_review "$home" claim "$id" --owner-task "$name-owner" >/dev/null || fail "$node could not be claimed"
  record=$(PATH="$FAKEBIN:$PATH" FM_FAKE_DATASET="$DATASET" FM_FAKE_GH_LOG="$GITHUB_LOG" \
    run_review "$home" fetch-feedback "$id") \
    || fail "$node exact body could not be reconstructed through the bounded prefix comparison"
  jq -e --arg start "$start" --arg tail "$tail" '
    .schema=="fm-pr-review-feedback-body.v1" and (.body|test("\r")|not)
    and (.body|startswith($start)) and (.body|endswith($tail)) and (.body|length)>600' \
    "$(printf '%s' "$record" | jq -r '.path')" >/dev/null \
    || fail "$node exact body record did not preserve the complete normalized claim"
  FM_PR_REVIEW_CURRENT_HEAD="$sha_a" run_review "$home" resolve-feedback "$id" \
    --head "$sha_a" --generation 1 --verdict dismissed --evidence-file "$TMP/crlf-evidence.md" \
    --reply-file "$TMP/crlf-reply.md" >/dev/null || fail "$node could not be adjudicated after reconstruction"
}
crlf_case crlf-home IC_crlf \
  '"  \r\nThe retry path drops the final write when the peer closes early.\r\nIt reproduces at this exact head under a slow reader.\r\n" + ([range(0;12)|"Additional exact-head evidence for the same claim.\r\n"]|join(""))' \
  'The retry path' 'same claim.'
crlf_case leading-space-home IC_lead \
  '"    The assignment order still races the cache invalidation on this path.\n" + ([range(0;12)|"Additional exact-head evidence for the same lead.\n"]|join(""))' \
  'The assignment order' 'same lead.'
pass "CRLF and leading-whitespace truncated bodies reconstruct and adjudicate at the exact node"

# A candidate merged or closed between the lagging search index and the detail
# read is omitted only because the live detail read answered closed; the rest of
# the account inventory still reconciles.
H_CLOSED="$TMP/closed-home"; new_home "$H_CLOSED"
CLOSED_PULL=$(pull_json 20 captain "$sha_a" '["authored"]' | jq -c '.state="closed"')
OPEN_PULL=$(pull_json 21 captain "$sha_a" '["authored"]')
make_dataset "[$CLOSED_PULL,$OPEN_PULL]"
: > "$GITHUB_LOG"
run_fake_poll "$H_CLOSED" 1220 >/dev/null || fail "a stale closed search hit aborted the whole account inventory"
item_json "$H_CLOSED" initial-review | jq -e 'length==1 and .[0].number==21' >/dev/null \
  || fail "close-during-search did not isolate to the closed pull request"
jq -e '(.pulls|keys)==["https://github.com/acme/widgets/pull/21"]' "$H_CLOSED/state/pr-review/snapshot.json" >/dev/null \
  || fail "a live-closed pull request stayed in the covered inventory"
pass "a pull request closed between search and detail is omitted after its live closed-state read"

# One pull request's read failure never ends account-wide coverage. Its previous
# durable cursor and queued work survive, the failure is announced once and stays
# durably visible, and unaffected pull requests keep reconciling.
H_ISOLATE="$TMP/isolate-home"; new_home "$H_ISOLATE"
isolate_inline() { # <id> <node> <body>
  jq -cn --arg head "$sha_a" --argjson id "$1" --arg node "$2" --arg body "$3" \
    '[{id:$id,node_id:$node,body:$body,commit_id:$head,updated_at:"2026-01-01T05:00:00Z",user:{login:"human",type:"User"}}]'
}
isolate_dataset() { # <second-pr-inline>
  make_dataset "[$(pull_json 1 captain "$sha_a" '["authored"]' '[]' "$(isolate_inline 601 IC_isolated 'The retained claim must survive an isolated read failure.')" '[]'),$(pull_json 2 captain "$sha_a" '["authored"]' '[]' "$1" '[]')]"
}
isolate_dataset "$(isolate_inline 701 IC_healthy 'The unaffected pull request must keep reconciling.')"
: > "$GITHUB_LOG"
isolate_event=$(run_fake_poll "$H_ISOLATE" 1230) || fail "isolation baseline poll failed"
run_review "$H_ISOLATE" acknowledge-event "$(printf '%s' "$isolate_event" | jq -r '.event_id')" >/dev/null
[ "$(item_json "$H_ISOLATE" feedback | jq 'length')" -eq 2 ] || fail "isolation baseline did not cover both pull requests"
ISOLATE_BASE=$(jq -c '.pulls["https://github.com/acme/widgets/pull/1"]|{covered_head,covered_feedback}' "$H_ISOLATE/state/pr-review/snapshot.json")

isolate_inline_new=$(jq -cn --arg head "$sha_a" \
  '[{id:701,node_id:"IC_healthy",body:"The unaffected pull request must keep reconciling.",commit_id:$head,updated_at:"2026-01-01T05:00:00Z",user:{login:"human",type:"User"}},
    {id:702,node_id:"IC_healthy_new",body:"A later claim on the unaffected pull request.",commit_id:$head,updated_at:"2026-01-01T05:10:00Z",user:{login:"human",type:"User"}}]')
isolate_dataset "$isolate_inline_new"
: > "$GITHUB_LOG"
degraded_event=$(FM_FAKE_READ_FAIL_PR=1 run_fake_poll "$H_ISOLATE" 1231) \
  || fail "one pull request's read failure aborted the whole account inventory"
printf '%s' "$degraded_event" | jq -e '.degraded==1 and (.message|contains("acme/widgets/pull/1"))' >/dev/null \
  || fail "the isolated read failure was hidden instead of announced: $degraded_event"
item_json "$H_ISOLATE" feedback | jq -e 'any(.[]; .feedback.node_id=="IC_healthy_new")' >/dev/null \
  || fail "an isolated read failure blocked coverage of an unaffected pull request"
item_json "$H_ISOLATE" feedback | jq -e 'any(.[]; .feedback.node_id=="IC_isolated")' >/dev/null \
  || fail "an isolated read failure erased previously queued coverage"
jq -c '.pulls["https://github.com/acme/widgets/pull/1"]|{covered_head,covered_feedback}' "$H_ISOLATE/state/pr-review/snapshot.json" \
  | grep -Fqx "$ISOLATE_BASE" || fail "an isolated read failure discarded the previous durable cursor"
jq -e '.pulls["https://github.com/acme/widgets/pull/1"].degraded.category=="github-read"' \
  "$H_ISOLATE/state/pr-review/snapshot.json" >/dev/null \
  || fail "the isolated read failure was silently treated as a complete inventory"
run_review "$H_ISOLATE" acknowledge-event "$(printf '%s' "$degraded_event" | jq -r '.event_id')" >/dev/null
ISOLATE_CLAIM=$(item_id_for "$H_ISOLATE" initial-review 2)
run_review "$H_ISOLATE" claim "$ISOLATE_CLAIM" --owner-task isolation-owner >/dev/null
set +e
repeat_degraded=$(FM_FAKE_READ_FAIL_PR=1 run_fake_poll "$H_ISOLATE" 1232 2>/dev/null)
repeat_degraded_rc=$?
set -e
[ "$repeat_degraded_rc" -eq 3 ] && [ -z "$repeat_degraded" ] \
  || fail "an unchanged isolated read failure re-announced instead of deduplicating"
jq -e '.pulls["https://github.com/acme/widgets/pull/1"].degraded.category=="github-read"' \
  "$H_ISOLATE/state/pr-review/snapshot.json" >/dev/null \
  || fail "a deduplicated isolated read failure stopped being durably visible"
run_fake_poll "$H_ISOLATE" 1233 >/dev/null 2>&1 || true
jq -e '.pulls["https://github.com/acme/widgets/pull/1"]|has("degraded")|not' \
  "$H_ISOLATE/state/pr-review/snapshot.json" >/dev/null \
  || fail "a recovered pull request stayed marked degraded"
pass "one pull request's read failure stays isolated, announced once, durable, and non-destructive"

# The isolated-read notice must stay inside the window its own consumer enforces.
# The independent oracle is the adapter's verdict on the emitted result, not a
# copy of the message-building code.
H_CLAMP="$TMP/clamp-home"; new_home "$H_CLAMP"
CLAMP_REPO="$(jq -rn '[range(0;100)|"a"]|join("")')/$(jq -rn '[range(0;100)|"b"]|join("")')"
CLAMP_DEGRADED=$(jq -cn --arg repo "$CLAMP_REPO" \
  '[range(1;6)|{repository:$repo,number:.,category:"pagination-bound",message:"GitHub pagination exceeded the configured page bound."}]')
CLAMP_OBS="$TMP/clamp.json"
jq -n --argjson pulls "[$(pull_json 1 captain "$sha_a" '["authored"]')]" --argjson degraded "$CLAMP_DEGRADED" \
  '{schema:"fm-pr-review-observation.v1",viewer:"captain",observed_at:1900,pulls:$pulls,degraded:$degraded}' > "$CLAMP_OBS"
clamp_event=$(poll_fixture "$H_CLAMP" "$CLAMP_OBS" 1900) || fail "a wide isolated-read diagnostic failed the poll"
printf '%s' "$clamp_event" | jq -e '.degraded==5 and (.message|length)>0 and (.message|length)<=1000' >/dev/null \
  || fail "the isolated-read diagnostic left its bounded message window: $(printf '%s' "$clamp_event" | jq -r '.message|length')"
printf '%s\n' "$clamp_event" > "$TMP/clamp-result.json"
[ "$("$ADAPTER" classify "$TMP/clamp-result.json")" = work ] \
  || fail "the bounded diagnostic became unactionable at its own consumer"
pass "a wide isolated-read diagnostic stays inside the adapter's bounded message window"

# --- Resolution helper driven through the fake GitHub write boundary --------
write_proof_files() {
  local dir=$1 head=$2
  printf 'Adversarial exact-head verification inspected the full diff, production path, tests, history, and a disconfirming counterexample at %s.\n' "$head" > "$dir/evidence.md"
}

write_validation() {
  local file=$1 head=$2 owner=$3
  jq -n --arg head "$head" --arg owner "$owner" \
    '{schema:"fm-pr-review-validation.v1",owner_task:$owner,head:$head,result:"checks-green",proof:"focused production-path regression and selected lifecycle checks passed"}' > "$file"
}

claim_item() {
  local home=$1 id=$2 owner=${3:-owner-task}
  run_review "$home" claim "$id" --owner-task "$owner"
}

fake_deliver() {
  local home=$1 id=$2
  shift 2
  PATH="$FAKEBIN:$PATH" FM_FAKE_DATASET="$DATASET" FM_FAKE_GH_LOG="$GITHUB_LOG" \
    FM_PR_REVIEW_CURRENT_HEAD="$sha_a" FM_PR_REVIEW_VIEWER=captain \
    FM_PR_REVIEW_PAGE_SIZE=2 FM_PR_REVIEW_FEEDBACK_PAGE_SIZE=2 FM_PR_REVIEW_MAX_PAGES=4 \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PR_REVIEW" deliver "$id" "$@"
}

# A pending notification is re-announced instead of reconciled, so a fixture that
# needs the next poll to actually reconcile drains the outstanding one first.
drain_pending_event() { # <home> <fixture> <now>
  local out id
  out=$(poll_fixture "$1" "$2" "$3" 2>/dev/null) || true
  id=$(printf '%s' "$out" | jq -r '.event_id // empty' 2>/dev/null || true)
  [ -z "$id" ] || run_review "$1" acknowledge-event "$id" >/dev/null
}

make_inline_home() { # <name> <node-id> <body>
  local name=$1 node=$2 body=$3 home inline pull obs
  home="$TMP/$name"
  new_home "$home"
  inline=$(jq -cn --arg head "$sha_a" --arg node "$node" --arg body "$body" \
    '[{id:201,node_id:$node,body:$body,commit_id:$head,updated_at:"2026-01-01T00:00:00Z",user:{login:"human",type:"User"}}]')
  pull=$(pull_json 1 captain "$sha_a" '["authored"]' '[]' "$inline" '[]')
  obs="$TMP/$name.json"; write_observation "$obs" 1300 "[$pull]"
  poll_fixture "$home" "$obs" 1300 >/dev/null || fail "$name fixture poll failed"
  printf '%s\n' "$home"
}

# Supported inline feedback is fixed, validation-proven, and replied once.
H_FIXED=$(make_inline_home fixed-home IC_fixed 'The null branch throws in production.')
FIXED_ID=$(item_id_for "$H_FIXED" feedback)
claim_item "$H_FIXED" "$FIXED_ID" > /dev/null || fail "supported feedback claim failed"
write_proof_files "$TMP" "$sha_a"
write_validation "$TMP/validation.md" "$sha_a" owner-task
printf 'Fixed on exact head %s. Focused regression proof now exercises the production null branch and fails under the old behavior.\n' "$sha_a" > "$TMP/fixed-reply.md"
FM_PR_REVIEW_CURRENT_HEAD="$sha_a" run_review "$H_FIXED" resolve-feedback "$FIXED_ID" \
  --head "$sha_a" --generation 1 --verdict fixed --evidence-file "$TMP/evidence.md" \
  --validation-evidence "$TMP/validation.md" --reply-file "$TMP/fixed-reply.md" >/dev/null \
  || fail "supported feedback could not stage its validated reply"
make_dataset "[$(pull_json 1 captain "$sha_a" '["authored"]' '[]' '[]' '[]')]"
: > "$GITHUB_LOG"
fake_deliver "$H_FIXED" "$FIXED_ID" >/dev/null || fail "supported feedback reply failed"
item=$(run_review "$H_FIXED" show "$FIXED_ID")
printf '%s' "$item" | jq -e '.state=="terminal" and .outcome=="fixed-and-replied" and .response.state=="delivered"' >/dev/null \
  || fail "supported feedback lacked its exact terminal outcome"
posts=$(grep -c 'POST .*replies' "$GITHUB_LOG" || true)
[ "$posts" -eq 1 ] || fail "supported inline feedback posted $posts replies"
set +e
fake_deliver "$H_FIXED" "$FIXED_ID" >/dev/null 2>&1
repeat_rc=$?
set -e
[ "$repeat_rc" -ne 0 ] || fail "terminal feedback delivery ran twice"
[ "$(grep -c 'POST .*replies' "$GITHUB_LOG" || true)" -eq 1 ] || fail "terminal replay posted a second reply"
pass "supported inline feedback is fixed, validated, and replied exactly once"

# Unsupported and superseded findings still receive evidence-bound replies.
for verdict in dismissed duplicate superseded; do
  home=$(make_inline_home "$verdict-home" "IC_$verdict" "Claim requiring $verdict adjudication.")
  id=$(item_id_for "$home" feedback)
  claim_item "$home" "$id" > /dev/null || fail "$verdict feedback claim failed"
  printf 'Exact-head %s evidence disproves or supersedes this claim through the complete production path and relevant history.\n' "$sha_a" > "$TMP/$verdict-reply.md"
  FM_PR_REVIEW_CURRENT_HEAD="$sha_a" run_review "$home" resolve-feedback "$id" \
    --head "$sha_a" --generation 1 --verdict "$verdict" --evidence-file "$TMP/evidence.md" \
    --reply-file "$TMP/$verdict-reply.md" >/dev/null || fail "$verdict response did not stage"
  make_dataset "[$(pull_json 1 captain "$sha_a" '["authored"]' '[]' '[]' '[]')]"
  : > "$GITHUB_LOG"
  fake_deliver "$home" "$id" >/dev/null || fail "$verdict response did not deliver"
  expected="$verdict-and-replied"
  [ "$verdict" != dismissed ] || expected=dismissed-and-replied
  run_review "$home" show "$id" | jq -e --arg expected "$expected" '.outcome==$expected and .response.state=="delivered"' >/dev/null \
    || fail "$verdict finding was silently dropped"
done
pass "unsupported, duplicate, outdated, and superseded findings receive one evidence reply"

# Captain decisions stage no GitHub response and release the review lane.
H_DECISION=$(make_inline_home decision-home IC_decision 'This asks for a new destructive data contract.')
DECISION_ID=$(item_id_for "$H_DECISION" feedback)
claim_item "$H_DECISION" "$DECISION_ID" > /dev/null
: > "$GITHUB_LOG"
FM_PR_REVIEW_CURRENT_HEAD="$sha_a" run_review "$H_DECISION" resolve-feedback "$DECISION_ID" \
  --head "$sha_a" --generation 1 --verdict captain-decision-pending --evidence-file "$TMP/evidence.md" >/dev/null \
  || fail "captain decision could not be recorded"
run_review "$H_DECISION" show "$DECISION_ID" | jq -e '.state=="captain-decision-pending" and .response==null' >/dev/null \
  || fail "captain decision staged a premature response"
[ ! -s "$GITHUB_LOG" ] || fail "captain-decision escalation reached GitHub"
pass "scope expansion and stronger boundaries wait for the captain without a premature response"

# A distinct-author foreign PR receives one COMMENT review and never a branch mutation.
H_FOREIGN="$TMP/foreign-home"; new_home "$H_FOREIGN"
FOREIGN_PULL=$(pull_json 9 outsider "$sha_a" '["review-requested","materially-participating"]')
FOREIGN_OBS="$TMP/foreign.json"; write_observation "$FOREIGN_OBS" 1400 "[$FOREIGN_PULL]"
poll_fixture "$H_FOREIGN" "$FOREIGN_OBS" 1400 >/dev/null
FOREIGN_ID=$(item_id_for "$H_FOREIGN" initial-review)
claim_item "$H_FOREIGN" "$FOREIGN_ID" foreign-review-owner >/dev/null
printf 'Comment-only exact-head review %s reports the supported issue with focused proof and no branch mutation.\n' "$sha_a" > "$TMP/foreign-reply.md"
FM_PR_REVIEW_CURRENT_HEAD="$sha_a" run_review "$H_FOREIGN" complete-review "$FOREIGN_ID" \
  --head "$sha_a" --generation 1 --outcome findings --evidence-file "$TMP/evidence.md" --reply-file "$TMP/foreign-reply.md" >/dev/null \
  || fail "foreign comment-only review did not stage"
make_dataset "[$FOREIGN_PULL]"
: > "$GITHUB_LOG"
fake_deliver "$H_FOREIGN" "$FOREIGN_ID" >/dev/null || fail "foreign comment-only review did not deliver"
assert_grep 'api /user' "$GITHUB_LOG" "foreign review did not re-read the authenticated actor at the write boundary"
assert_grep 'api /repos/acme/widgets/pulls/9' "$GITHUB_LOG" "foreign review did not re-read the live pull-request author at the write boundary"
[ "$(grep -c 'pr review 9 --repo acme/widgets --comment' "$GITHUB_LOG" || true)" -eq 1 ] \
  || fail "distinct-author foreign review was not submitted exactly once"
assert_no_grep 'approve' "$GITHUB_LOG" "foreign PR was approved automatically"
assert_no_grep 'merge' "$GITHUB_LOG" "foreign PR reached a merge path"
set +e
fake_deliver "$H_FOREIGN" "$FOREIGN_ID" >/dev/null 2>&1
foreign_replay_rc=$?
set -e
[ "$foreign_replay_rc" -ne 0 ] || fail "terminal foreign review delivery ran twice"
[ "$(grep -c 'pr review 9 --repo acme/widgets --comment' "$GITHUB_LOG" || true)" -eq 1 ] \
  || fail "foreign review replay submitted a duplicate"
pass "distinct-author foreign PR review is comment-only and submits exactly once"

# Fleet-authored findings remain private and route to the implementation owner.
H_AUTHORED="$TMP/authored-review-home"; new_home "$H_AUTHORED"
fm_write_meta "$H_AUTHORED/state/existing-owner.meta" \
  'window=firstmate:fm-existing-owner' \
  'pr=https://github.com/acme/widgets/pull/10'
AUTH_PULL=$(pull_json 10 captain "$sha_a" '["authored"]')
AUTH_OBS="$TMP/authored-review.json"; write_observation "$AUTH_OBS" 1450 "[$AUTH_PULL]"
poll_fixture "$H_AUTHORED" "$AUTH_OBS" 1450 >/dev/null
AUTH_ID=$(item_id_for "$H_AUTHORED" initial-review)
run_review "$H_AUTHORED" show "$AUTH_ID" | jq -e '.owning_task=="existing-owner"' >/dev/null \
  || fail "authored PR did not correlate to its existing task metadata"
claim_item "$H_AUTHORED" "$AUTH_ID" authored-review-worker >/dev/null
: > "$GITHUB_LOG"
FM_PR_REVIEW_CURRENT_HEAD="$sha_a" run_review "$H_AUTHORED" complete-review "$AUTH_ID" \
  --head "$sha_a" --generation 1 --outcome findings --evidence-file "$TMP/evidence.md" >/dev/null \
  || fail "authored findings were not routed privately"
run_review "$H_AUTHORED" show "$AUTH_ID" | jq -e '
  .state=="private-findings-pending" and .outcome==null and .response==null
  and .independent_review==false and .private_route.status=="pending"
  and .private_route.owner_task=="existing-owner"' >/dev/null \
  || fail "authored findings did not remain private for the implementation owner"
[ ! -s "$GITHUB_LOG" ] || fail "private authored findings reached GitHub"
FM_PR_REVIEW_CURRENT_HEAD="$sha_a" run_review "$H_AUTHORED" complete-review "$AUTH_ID" \
  --head "$sha_a" --generation 1 --outcome findings-corrected --evidence-file "$TMP/evidence.md" >/dev/null \
  || fail "privately routed authored findings could not complete after correction"
run_review "$H_AUTHORED" show "$AUTH_ID" | jq -e '
  .outcome=="reviewed-findings-corrected" and .response==null
  and .independent_review==false and .private_route.status=="corrected"' >/dev/null \
  || fail "private authored correction was counted as independent review evidence"
[ ! -s "$GITHUB_LOG" ] || fail "authored correction completion made an outward GitHub call"

H_AUTHORED_CLEAN="$TMP/authored-clean-home"; new_home "$H_AUTHORED_CLEAN"
AUTH_CLEAN_PULL=$(pull_json 13 captain "$sha_a" '["authored"]')
AUTH_CLEAN_OBS="$TMP/authored-clean.json"; write_observation "$AUTH_CLEAN_OBS" 1451 "[$AUTH_CLEAN_PULL]"
poll_fixture "$H_AUTHORED_CLEAN" "$AUTH_CLEAN_OBS" 1451 >/dev/null
AUTH_CLEAN_ID=$(item_id_for "$H_AUTHORED_CLEAN" initial-review)
claim_item "$H_AUTHORED_CLEAN" "$AUTH_CLEAN_ID" clean-review-worker >/dev/null
FM_PR_REVIEW_CURRENT_HEAD="$sha_a" run_review "$H_AUTHORED_CLEAN" complete-review "$AUTH_CLEAN_ID" \
  --head "$sha_a" --generation 1 --outcome clean --evidence-file "$TMP/evidence.md" >/dev/null \
  || fail "unsupported authored leads could not complete privately"
run_review "$H_AUTHORED_CLEAN" show "$AUTH_CLEAN_ID" | jq -e '
  .outcome=="reviewed-clean" and .state=="terminal" and .response==null
  and .independent_review==false' >/dev/null \
  || fail "unsupported authored leads became public or independent evidence"
[ ! -s "$GITHUB_LOG" ] || fail "unsupported authored leads reached GitHub"
pass "fleet-authored findings route privately, unsupported leads stay private, and neither counts as independent review"

# Incident regression: a stale foreign classification cannot publish after the
# live author becomes the authenticated actor. The formal review and a legacy
# fallback-comment artifact both fail at the final write boundary and preserve
# one private route to the existing implementation owner.
make_stale_self_review_home() { # <name> <number>
  local name=$1 number=$2 home pull obs id
  home="$TMP/$name"; new_home "$home"
  fm_write_meta "$home/state/stale-implementation-owner.meta" \
    'window=firstmate:fm-stale-owner' \
    "pr=https://github.com/acme/widgets/pull/$number"
  pull=$(pull_json "$number" outsider "$sha_a" '["review-requested"]')
  obs="$TMP/$name.json"; write_observation "$obs" 1460 "[$pull]"
  poll_fixture "$home" "$obs" 1460 >/dev/null
  id=$(item_id_for "$home" initial-review "$number")
  claim_item "$home" "$id" stale-review-worker >/dev/null
  FM_PR_REVIEW_CURRENT_HEAD="$sha_a" run_review "$home" complete-review "$id" \
    --head "$sha_a" --generation 1 --outcome findings --evidence-file "$TMP/evidence.md" \
    --reply-file "$TMP/foreign-reply.md" >/dev/null || fail "$name could not stage stale review"
  printf '%s\t%s\n' "$home" "$id"
}

IFS="$(printf '\t')" read -r H_SELF_GUARD SELF_GUARD_ID <<EOF
$(make_stale_self_review_home self-guard-home 11)
EOF
SELF_LIVE_PULL=$(pull_json 11 captain "$sha_a" '["authored"]')
make_dataset "[$SELF_LIVE_PULL]"
: > "$GITHUB_LOG"
set +e
FM_PR_REVIEW_TEST_CRASH_AT=after-publication-refusal fake_deliver "$H_SELF_GUARD" "$SELF_GUARD_ID" >/dev/null 2> "$TMP/self-guard.err"
self_guard_rc=$?
set -e
[ "$self_guard_rc" -eq 99 ] || fail "self-review refusal crash seam did not cut after durable private routing"
assert_no_grep 'pr review 11' "$GITHUB_LOG" "live author equality still submitted a formal review"
assert_no_grep 'POST ' "$GITHUB_LOG" "live author equality posted a replacement comment"
run_review "$H_SELF_GUARD" show "$SELF_GUARD_ID" | jq -e '
  .authored==true and .state=="private-findings-pending" and .outcome==null and .response==null
  and .independent_review==false and .private_route.owner_task=="stale-implementation-owner"
  and .publication_guard.actor=="captain" and .publication_guard.author=="captain"' >/dev/null \
  || fail "crashed formal self-review refusal did not preserve its private owner route"
set +e
fake_deliver "$H_SELF_GUARD" "$SELF_GUARD_ID" >/dev/null 2>&1
self_guard_replay_rc=$?
set -e
[ "$self_guard_replay_rc" -ne 0 ] || fail "refused self-review remained deliverable on crash replay"
assert_no_grep 'pr review 11' "$GITHUB_LOG" "refused self-review crash replay reached GitHub"

IFS="$(printf '\t')" read -r H_FALLBACK_GUARD FALLBACK_GUARD_ID <<EOF
$(make_stale_self_review_home fallback-guard-home 12)
EOF
fallback_item="$H_FALLBACK_GUARD/state/pr-review/items/$FALLBACK_GUARD_ID.json"
fallback_tmp="$fallback_item.tmp"
if ! jq '.response.method="fallback-comment"' "$fallback_item" > "$fallback_tmp" \
  || ! chmod 0600 "$fallback_tmp" || ! mv "$fallback_tmp" "$fallback_item"; then
  fail "could not create the legacy fallback-comment crash artifact"
fi
FALLBACK_LIVE_PULL=$(pull_json 12 captain "$sha_a" '["authored"]')
make_dataset "[$FALLBACK_LIVE_PULL]"
: > "$GITHUB_LOG"
set +e
fallback_guard_out=$(fake_deliver "$H_FALLBACK_GUARD" "$FALLBACK_GUARD_ID" 2> "$TMP/fallback-guard.err")
fallback_guard_rc=$?
set -e
[ "$fallback_guard_rc" -eq 6 ] || fail "live author equality did not refuse fallback self-comment"
assert_contains "$fallback_guard_out" 'self-review-publication-refused' "fallback refusal did not expose its private route result"
assert_no_grep 'pr review 12' "$GITHUB_LOG" "fallback self-review submitted a formal review"
assert_no_grep 'POST ' "$GITHUB_LOG" "fallback self-review posted a replacement comment"
run_review "$H_FALLBACK_GUARD" show "$FALLBACK_GUARD_ID" | jq -e '
  .state=="private-findings-pending" and .response==null and .private_route.status=="pending"
  and .publication_guard.method=="fallback-comment"' >/dev/null \
  || fail "refused fallback self-comment did not preserve a private route"
pass "live author equality refuses formal and fallback self-review publication across stale state and replay"

# --- Head movement, response retry, duplicate notification, and crash cuts ---
H_MOVE=$(make_inline_home moved-head-home IC_move 'The exact-head behavior may be stale.')
MOVE_ID=$(item_id_for "$H_MOVE" feedback)
claim_item "$H_MOVE" "$MOVE_ID" move-owner >/dev/null
set +e
move_out=$(FM_PR_REVIEW_CURRENT_HEAD="$sha_b" run_review "$H_MOVE" resolve-feedback "$MOVE_ID" \
  --head "$sha_a" --generation 1 --verdict dismissed --evidence-file "$TMP/evidence.md" --reply-file "$TMP/dismissed-reply.md" 2>/dev/null)
move_rc=$?
set -e
[ "$move_rc" -eq 5 ] || fail "head movement did not invalidate stale verification"
assert_contains "$move_out" "$sha_b" "head movement did not name the requeued head"
run_review "$H_MOVE" show "$MOVE_ID" | jq -e --arg head "$sha_b" '.state=="pending" and .head==$head and .generation==2 and .response==null' >/dev/null \
  || fail "head movement retained stale evidence or response state"
pass "head movement during verification invalidates evidence and requeues the same finding generation"

# --- Closure or merge ends the item at every completion boundary ------------
# The independent oracle is the live lifecycle answer plus three separately
# checked effects: the durable outcome, the freed one-at-a-time lane, and the
# GitHub operation log. Treating closure as an unrecoverable error would leave
# the item claimed and the single lane occupied forever.
closed_lane_free() { # <home> <label>
  [ ! -e "$1/state/pr-review/lane.json" ] || fail "$2 kept the one-at-a-time lane after closure"
}
# Every closure boundary answers through the real gh-axi read against a dataset
# whose pull request is closed, never through a head override.
close_dataset() {
  make_dataset "[$(pull_json 1 captain "$sha_a" '["authored"]' '[]' '[]' '[]' | jq -c '.state="closed"')]"
  : > "$GITHUB_LOG"
}
fake_review() { # <home> <args...>
  local home=$1
  shift
  PATH="$FAKEBIN:$PATH" FM_FAKE_DATASET="$DATASET" FM_FAKE_GH_LOG="$GITHUB_LOG" \
    FM_PR_REVIEW_VIEWER=captain \
    FM_PR_REVIEW_PAGE_SIZE=2 FM_PR_REVIEW_FEEDBACK_PAGE_SIZE=2 FM_PR_REVIEW_MAX_PAGES=4 \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PR_REVIEW" "$@"
}
assert_closed_item() { # <home> <item-id> <label>
  run_review "$1" show "$2" | jq -e --arg head "$sha_a" '
    .state=="terminal" and .outcome=="pull-closed-without-response" and .response==null
    and .closure.live_state=="closed" and .closure.covered_head==$head and .head==$head' >/dev/null \
    || fail "$3 did not reach a durable pull-closed-without-response outcome"
}

H_CLOSE=$(make_inline_home closed-boundary-home IC_closed 'This claim outlives its own pull request.')
CLOSE_FEEDBACK_ID=$(item_id_for "$H_CLOSE" feedback)
claim_item "$H_CLOSE" "$CLOSE_FEEDBACK_ID" closed-feedback-owner >/dev/null
close_dataset
set +e
close_resolve_out=$(fake_review "$H_CLOSE" resolve-feedback "$CLOSE_FEEDBACK_ID" --head "$sha_a" --generation 1 \
  --verdict dismissed --evidence-file "$TMP/evidence.md" --reply-file "$TMP/dismissed-reply.md" 2>/dev/null)
close_resolve_rc=$?
set -e
[ "$close_resolve_rc" -eq 7 ] || fail "resolve-feedback on a closed pull request did not end the item, got $close_resolve_rc"
assert_contains "$close_resolve_out" '"response":"withheld"' "closed-pull resolution did not report a withheld response"
assert_closed_item "$H_CLOSE" "$CLOSE_FEEDBACK_ID" "closed-pull feedback resolution"
closed_lane_free "$H_CLOSE" "closed-pull feedback resolution"
assert_no_grep 'POST ' "$GITHUB_LOG" "closed-pull feedback resolution wrote to GitHub"

CLOSE_REVIEW_ID=$(item_id_for "$H_CLOSE" initial-review)
claim_item "$H_CLOSE" "$CLOSE_REVIEW_ID" closed-review-owner >/dev/null \
  || fail "a closed pull request wedged the lane against the next queued item"
close_dataset
set +e
fake_review "$H_CLOSE" complete-review "$CLOSE_REVIEW_ID" --head "$sha_a" --generation 1 \
  --outcome clean --evidence-file "$TMP/evidence.md" >/dev/null 2>&1
close_review_rc=$?
set -e
[ "$close_review_rc" -eq 7 ] || fail "complete-review on a closed pull request did not end the item, got $close_review_rc"
assert_closed_item "$H_CLOSE" "$CLOSE_REVIEW_ID" "closed-pull initial review"
closed_lane_free "$H_CLOSE" "closed-pull initial review"
set +e
run_review "$H_CLOSE" claim "$CLOSE_REVIEW_ID" --owner-task closed-review-owner >/dev/null 2>&1
close_reclaim_rc=$?
set -e
[ "$close_reclaim_rc" -ne 0 ] || fail "a closed pull request's terminal item was handed out again"

# Delivery never posts after closure, and the crash seam proves a stale lane
# pointing at a terminal item self-heals instead of wedging the queue.
H_CLOSE_DELIVER=$(make_inline_home closed-deliver-home IC_closed_deliver 'A staged reply must not survive closure.')
drain_pending_event "$H_CLOSE_DELIVER" "$TMP/closed-deliver-home.json" 1301
CLOSE_DELIVER_ID=$(item_id_for "$H_CLOSE_DELIVER" feedback)
claim_item "$H_CLOSE_DELIVER" "$CLOSE_DELIVER_ID" closed-deliver-owner >/dev/null
FM_PR_REVIEW_CURRENT_HEAD="$sha_a" run_review "$H_CLOSE_DELIVER" resolve-feedback "$CLOSE_DELIVER_ID" \
  --head "$sha_a" --generation 1 --verdict dismissed --evidence-file "$TMP/evidence.md" \
  --reply-file "$TMP/dismissed-reply.md" >/dev/null || fail "closed-delivery fixture could not stage its reply"
close_dataset
set +e
FM_PR_REVIEW_TEST_CRASH_AT=after-pull-closed fake_review "$H_CLOSE_DELIVER" deliver "$CLOSE_DELIVER_ID" >/dev/null 2>&1
close_deliver_crash_rc=$?
set -e
[ "$close_deliver_crash_rc" -eq 99 ] || fail "closed-pull delivery crash seam did not cut after the durable outcome"
assert_closed_item "$H_CLOSE_DELIVER" "$CLOSE_DELIVER_ID" "closed-pull delivery"
assert_no_grep 'POST ' "$GITHUB_LOG" "closed-pull delivery posted a response after closure"
assert_present "$H_CLOSE_DELIVER/state/pr-review/lane.json" "closed-pull delivery crash seam cut too late to prove lane recovery"
# The poll's actionability must read the lane the same way every other command
# does. A stale lane naming a terminal item would otherwise hide the still-queued
# review behind an occupancy that no longer exists, and the commands that would
# have repaired it are exactly the ones the suppressed wake never prompts.
STALE_LANE_OBS="$TMP/stale-lane-inventory.json"; write_observation "$STALE_LANE_OBS" 1310 '[]'
stale_lane_event=$(poll_fixture "$H_CLOSE_DELIVER" "$STALE_LANE_OBS" 1310) \
  || fail "a stale lane naming a terminal item silenced still-pending queue work"
printf '%s' "$stale_lane_event" | jq -e '.pending>=1' >/dev/null \
  || fail "the pending-work wake did not report the queued item behind the stale lane"
run_review "$H_CLOSE_DELIVER" acknowledge-event "$(printf '%s' "$stale_lane_event" | jq -r '.event_id')" >/dev/null
closed_lane_free "$H_CLOSE_DELIVER" "a crash between the terminal write and the lane release"
set +e
fake_review "$H_CLOSE_DELIVER" deliver "$CLOSE_DELIVER_ID" >/dev/null 2>&1
close_deliver_replay_rc=$?
set -e
[ "$close_deliver_replay_rc" -ne 0 ] || fail "a closed pull request's discarded response became deliverable again"
assert_no_grep 'POST ' "$GITHUB_LOG" "closed-pull delivery replay posted after closure"

# A response GitHub already accepted before closure is still reconciled, not
# reported as withheld, and is never posted a second time.
H_CLOSE_ACCEPT=$(make_inline_home closed-accepted-home IC_closed_accepted 'An accepted reply must survive later closure.')
CLOSE_ACCEPT_ID=$(item_id_for "$H_CLOSE_ACCEPT" feedback)
claim_item "$H_CLOSE_ACCEPT" "$CLOSE_ACCEPT_ID" closed-accept-owner >/dev/null
FM_PR_REVIEW_CURRENT_HEAD="$sha_a" run_review "$H_CLOSE_ACCEPT" resolve-feedback "$CLOSE_ACCEPT_ID" \
  --head "$sha_a" --generation 1 --verdict dismissed --evidence-file "$TMP/evidence.md" \
  --reply-file "$TMP/dismissed-reply.md" >/dev/null || fail "closed-acceptance fixture could not stage its reply"
make_dataset "[$(pull_json 1 captain "$sha_a" '["authored"]' '[]' '[]' '[]')]"; : > "$GITHUB_LOG"
set +e
FM_PR_REVIEW_TEST_CRASH_AT=after-post fake_deliver "$H_CLOSE_ACCEPT" "$CLOSE_ACCEPT_ID" >/dev/null 2>&1
close_accept_rc=$?
set -e
[ "$close_accept_rc" -eq 99 ] || fail "closed-acceptance fixture did not cut after GitHub acceptance"
CLOSE_ACCEPT_DATASET=$(jq -c '.pulls |= map(.state="closed")' "$DATASET")
printf '%s\n' "$CLOSE_ACCEPT_DATASET" > "$DATASET"
fake_review "$H_CLOSE_ACCEPT" deliver "$CLOSE_ACCEPT_ID" >/dev/null \
  || fail "closure discarded a response GitHub had already accepted"
run_review "$H_CLOSE_ACCEPT" show "$CLOSE_ACCEPT_ID" | jq -e '
  .state=="terminal" and .outcome=="dismissed-and-replied" and .response.state=="delivered"' >/dev/null \
  || fail "an accepted response was reported as withheld after closure"
[ "$(grep -c 'POST .*replies' "$GITHUB_LOG" || true)" -eq 1 ] \
  || fail "post-acceptance closure reconciliation posted a second reply"
closed_lane_free "$H_CLOSE_ACCEPT" "post-acceptance closure reconciliation"
pass "a closed or merged pull request ends its item without a response and frees the lane at every boundary"

# --- Reopening restores coverage for exactly the closed items ---------------
# The independent oracle is the fixture's own relevant identity set: an open PR
# at a relevant exact head owes one queued review and one response per still
# unanswered external claim. Recreating by id alone, or reactivating on any
# terminal outcome, would each make one of these assertions fail.
drop_from_inventory() { # <home> <now>
  local empty="$TMP/empty-inventory.json"
  write_observation "$empty" "$2" '[]'
  drain_pending_event "$1" "$empty" "$2"
  drain_pending_event "$1" "$empty" "$(($2 + 1))"
}

# H_CLOSE ended both its review and its feedback item through the live closed
# read above, so it is the realistic close-then-reopen subject.
drop_from_inventory "$H_CLOSE" 1320
jq -e '(.pulls|length)==0' "$H_CLOSE/state/pr-review/snapshot.json" >/dev/null \
  || fail "a closed pull request stayed in the covered inventory"
reopen_event=$(poll_fixture "$H_CLOSE" "$TMP/closed-boundary-home.json" 1321) \
  || fail "a reopened pull request produced no coverage"
assert_contains "$reopen_event" '"changed":2' "reopening did not restore both the review and the unanswered claim"
for id in "$CLOSE_REVIEW_ID" "$CLOSE_FEEDBACK_ID"; do
  run_review "$H_CLOSE" show "$id" | jq -e --arg head "$sha_a" '
    .state=="pending" and .outcome==null and .head==$head and .generation==2
    and (has("closure")|not) and .reopened_from.closure.live_state=="closed"' >/dev/null \
    || fail "reopened item $id did not resume as a new durable generation at the same head"
done
[ "$(item_json "$H_CLOSE" initial-review | jq 'length')" -eq 1 ] || fail "reopening duplicated the review item"
[ "$(item_json "$H_CLOSE" feedback | jq 'length')" -eq 1 ] || fail "reopening duplicated the feedback item"
closed_lane_free "$H_CLOSE" "reopening"

# A repeated poll of the same reopened pull request must not bump the generation
# again, and a crash between item publication and the covered cursor must replay
# into exactly one reactivation.
run_review "$H_CLOSE" acknowledge-event "$(printf '%s' "$reopen_event" | jq -r '.event_id')" >/dev/null
poll_fixture "$H_CLOSE" "$TMP/closed-boundary-home.json" 1322 >/dev/null 2>&1 || true
run_review "$H_CLOSE" show "$CLOSE_REVIEW_ID" | jq -e '.generation==2 and .state=="pending"' >/dev/null \
  || fail "an unchanged reopened pull request reactivated twice"

H_REOPEN_CRASH=$(make_inline_home reopen-crash-home IC_reopen_crash 'A reopened claim must replay exactly once.')
REOPEN_CRASH_ID=$(item_id_for "$H_REOPEN_CRASH" feedback)
claim_item "$H_REOPEN_CRASH" "$REOPEN_CRASH_ID" reopen-crash-owner >/dev/null
close_dataset
set +e
fake_review "$H_REOPEN_CRASH" resolve-feedback "$REOPEN_CRASH_ID" --head "$sha_a" --generation 1 \
  --verdict dismissed --evidence-file "$TMP/evidence.md" --reply-file "$TMP/dismissed-reply.md" >/dev/null 2>&1
reopen_crash_close_rc=$?
set -e
[ "$reopen_crash_close_rc" -eq 7 ] || fail "reopen crash fixture could not reach a closed outcome"
drop_from_inventory "$H_REOPEN_CRASH" 1330
set +e
FM_PR_REVIEW_TEST_CRASH_AT=after-items poll_fixture "$H_REOPEN_CRASH" "$TMP/reopen-crash-home.json" 1331 >/dev/null 2>&1
reopen_crash_rc=$?
set -e
[ "$reopen_crash_rc" -eq 99 ] || fail "reopen crash seam did not cut before the covered cursor"
run_review "$H_REOPEN_CRASH" show "$REOPEN_CRASH_ID" | jq -e '.state=="pending" and .generation==2' >/dev/null \
  || fail "the reopen crash seam cut before the item was durable"
poll_fixture "$H_REOPEN_CRASH" "$TMP/reopen-crash-home.json" 1332 >/dev/null 2>&1 || true
run_review "$H_REOPEN_CRASH" show "$REOPEN_CRASH_ID" | jq -e '.state=="pending" and .generation==2' >/dev/null \
  || fail "reopen replay reactivated the same item twice"

# Every other terminal disposition survives a reopen untouched: an answered claim
# is never reopened and never re-created as a fresh duplicate.
H_ANSWERED=$(make_inline_home answered-reopen-home IC_answered 'An answered claim must stay answered across a reopen.')
ANSWERED_ID=$(item_id_for "$H_ANSWERED" feedback)
claim_item "$H_ANSWERED" "$ANSWERED_ID" answered-reopen-owner >/dev/null
FM_PR_REVIEW_CURRENT_HEAD="$sha_a" run_review "$H_ANSWERED" resolve-feedback "$ANSWERED_ID" \
  --head "$sha_a" --generation 1 --verdict dismissed --evidence-file "$TMP/evidence.md" \
  --reply-file "$TMP/dismissed-reply.md" >/dev/null || fail "answered-reopen fixture could not stage its reply"
make_dataset "[$(pull_json 1 captain "$sha_a" '["authored"]' '[]' '[]' '[]')]"; : > "$GITHUB_LOG"
fake_deliver "$H_ANSWERED" "$ANSWERED_ID" >/dev/null || fail "answered-reopen fixture could not deliver"
drop_from_inventory "$H_ANSWERED" 1340
poll_fixture "$H_ANSWERED" "$TMP/answered-reopen-home.json" 1341 >/dev/null 2>&1 || true
run_review "$H_ANSWERED" show "$ANSWERED_ID" | jq -e '
  .state=="terminal" and .outcome=="dismissed-and-replied" and .generation==1
  and (has("reopened_from")|not)' >/dev/null \
  || fail "a reopen reactivated an already-answered claim"
[ "$(item_json "$H_ANSWERED" feedback | jq 'length')" -eq 1 ] \
  || fail "a reopen re-created an already-answered claim as a duplicate"
[ "$(grep -c 'POST .*replies' "$GITHUB_LOG" || true)" -eq 1 ] \
  || fail "a reopen produced a second response for an already-answered claim"
pass "reopening restores coverage for closed items only and leaves every other terminal disposition intact"

# Queue-before-snapshot crash replay creates one item, not zero or two.
for cut in after-items after-snapshot; do
  home="$TMP/crash-$cut"; new_home "$home"
  obs="$TMP/crash-$cut.json"; write_observation "$obs" 1500 "[$AUTH_PULL]"
  set +e
  FM_PR_REVIEW_TEST_CRASH_AT="$cut" poll_fixture "$home" "$obs" 1500 >/dev/null 2>&1
  crash_rc=$?
  set -e
  [ "$crash_rc" -eq 99 ] || fail "$cut seam did not cut the poll"
  poll_fixture "$home" "$obs" 1501 >/dev/null || fail "$cut replay failed"
  [ "$(item_json "$home" initial-review | jq 'length')" -eq 1 ] || fail "$cut replay lost or duplicated review work"
done
pass "poll crashes before and after snapshot publication replay without lost or duplicate work"

# Claim crash replay retains one owner and lane.
H_CLAIM="$TMP/claim-crash"; new_home "$H_CLAIM"
poll_fixture "$H_CLAIM" "$OBS_SCOPE" 1510 >/dev/null
CLAIM_ID=$(run_review "$H_CLAIM" list --json | jq -r '[.[]|select(.type=="initial-review")]|sort_by(.number)|.[0].id')
set +e
FM_PR_REVIEW_TEST_CRASH_AT=after-claim run_review "$H_CLAIM" claim "$CLAIM_ID" --owner-task same-owner >/dev/null 2>&1
claim_rc=$?
set -e
[ "$claim_rc" -eq 99 ] || fail "claim crash seam did not cut"
claim_replay=$(run_review "$H_CLAIM" claim "$CLAIM_ID" --owner-task same-owner) || fail "same-owner claim replay failed"
assert_contains "$claim_replay" '"replay":true' "claim replay did not converge on its existing owner"
second=$(run_review "$H_CLAIM" list --json | jq -r '[.[]|select(.type=="initial-review")]|sort_by(.number)|.[1].id')
set +e
run_review "$H_CLAIM" claim "$second" --owner-task other-owner >/dev/null 2>&1
lane_rc=$?
set -e
[ "$lane_rc" -ne 0 ] || fail "one-at-a-time lane admitted a second review"
pass "duplicate notifications and claim replay preserve one review worker per lane"

# Reply failure after a completed fix keeps the bound response and evidence.
H_RETRY=$(make_inline_home retry-home IC_retry 'A supported fix needs a retrying reply.')
RETRY_ID=$(item_id_for "$H_RETRY" feedback)
claim_item "$H_RETRY" "$RETRY_ID" retry-owner >/dev/null
write_validation "$TMP/validation.md" "$sha_a" retry-owner
printf 'Fixed at %s with focused validation evidence; this is the same bound response on every retry.\n' "$sha_a" > "$TMP/retry-reply.md"
FM_PR_REVIEW_CURRENT_HEAD="$sha_a" run_review "$H_RETRY" resolve-feedback "$RETRY_ID" \
  --head "$sha_a" --generation 1 --verdict fixed --evidence-file "$TMP/evidence.md" \
  --validation-evidence "$TMP/validation.md" --reply-file "$TMP/retry-reply.md" >/dev/null
make_dataset "[$(pull_json 1 captain "$sha_a" '["authored"]' '[]' '[]' '[]')]"; : > "$GITHUB_LOG"
set +e
FM_FAKE_POST_FAIL=1 fake_deliver "$H_RETRY" "$RETRY_ID" >/dev/null 2>&1
retry_rc=$?
set -e
[ "$retry_rc" -ne 0 ] || fail "reply failure was reported as success"
run_review "$H_RETRY" show "$RETRY_ID" | jq -e '.state=="response-pending" and .outcome=="fixed-and-replied" and .evidence!=null and .response.attempt_count==1' >/dev/null \
  || fail "reply failure reran or discarded the completed correction"
fake_deliver "$H_RETRY" "$RETRY_ID" >/dev/null || fail "bound reply did not recover"
[ "$(grep -c 'POST .*replies' "$GITHUB_LOG" || true)" -eq 2 ] || fail "retry boundary did not make one failed and one successful attempt"
pass "reply failure after correction retries the same response without duplicating the fix"

# Crash after GitHub accepted the response is reconciled by exact self/body/thread search.
H_POST=$(make_inline_home post-crash-home IC_post 'A reply receipt crash must not duplicate this fix.')
POST_ID=$(item_id_for "$H_POST" feedback)
claim_item "$H_POST" "$POST_ID" post-owner >/dev/null
write_validation "$TMP/validation.md" "$sha_a" post-owner
printf 'Fixed at %s; focused proof exercises the original thread and exact production path.\n' "$sha_a" > "$TMP/post-reply.md"
FM_PR_REVIEW_CURRENT_HEAD="$sha_a" run_review "$H_POST" resolve-feedback "$POST_ID" \
  --head "$sha_a" --generation 1 --verdict fixed --evidence-file "$TMP/evidence.md" \
  --validation-evidence "$TMP/validation.md" --reply-file "$TMP/post-reply.md" >/dev/null
make_dataset "[$(pull_json 1 captain "$sha_a" '["authored"]' '[]' '[]' '[]')]"; : > "$GITHUB_LOG"
set +e
FM_PR_REVIEW_TEST_CRASH_AT=after-post fake_deliver "$H_POST" "$POST_ID" >/dev/null 2>&1
post_rc=$?
set -e
[ "$post_rc" -eq 99 ] || fail "post crash seam did not cut after GitHub acceptance"
fake_deliver "$H_POST" "$POST_ID" >/dev/null || fail "post crash replay did not reconcile"
[ "$(grep -c 'POST .*replies' "$GITHUB_LOG" || true)" -eq 1 ] || fail "post-before-receipt replay posted a second reply"
pass "crash after GitHub acceptance reconciles one original-thread reply instead of duplicating it"

# --- Durable opt-out and restoration against the last covered cursor --------
H_OPT="$TMP/opt-home"; new_home "$H_OPT"
OPT_BASE="$TMP/opt-base.json"; write_observation "$OPT_BASE" 1600 "[$AUTH_PULL]"
opt_base_event=$(poll_fixture "$H_OPT" "$OPT_BASE" 1600) || fail "opt-out baseline failed"
run_review "$H_OPT" acknowledge-event "$(printf '%s' "$opt_base_event" | jq -r '.event_id')" >/dev/null
run_review "$H_OPT" opt-out 'https://github.com/acme/widgets/pull/10' >/dev/null
OPT_INLINE=$(jq -cn --arg head "$sha_b" '[{id:501,node_id:"IC_intervening",body:"Intervening feedback while captain owned the PR.",commit_id:$head,updated_at:"2026-01-01T03:00:00Z",user:{login:"human",type:"User"}}]')
OPT_MOVED=$(pull_json 10 captain "$sha_b" '["authored"]' '[]' "$OPT_INLINE" '[]')
OPT_DURING="$TMP/opt-during.json"; write_observation "$OPT_DURING" 1601 "[$OPT_MOVED]"
set +e
poll_fixture "$H_OPT" "$OPT_DURING" 1601 >/dev/null 2>&1
opt_rc=$?
set -e
[ "$opt_rc" -eq 3 ] || fail "opted-out PR should stay silent"
run_review "$H_OPT" opt-in 'https://github.com/acme/widgets/pull/10' >/dev/null
poll_fixture "$H_OPT" "$OPT_DURING" 1602 >/dev/null || fail "coverage restoration poll failed"
opt_items=$(run_review "$H_OPT" list --json)
printf '%s' "$opt_items" | jq -e --arg head "$sha_b" 'any(.[]; .type=="initial-review" and .head==$head and .state=="pending")' >/dev/null \
  || fail "opt-in lost the intervening exact head"
printf '%s' "$opt_items" | jq -e 'any(.[]; .type=="feedback" and .feedback.node_id=="IC_intervening")' >/dev/null \
  || fail "opt-in lost intervening feedback"
pass "captain takeover opt-out is durable and later restoration covers intervening heads and feedback"

# --- Process-event registration, restart, supervision, and home isolation ----
H_ARM1="$TMP/arm-home-1"; H_ARM2="$TMP/arm-home-2"; new_home "$H_ARM1"; new_home "$H_ARM2"
FM_HOME="$H_ARM1" "$ADAPTER" arm >/dev/null || fail "first home could not arm review source"
FM_HOME="$H_ARM2" "$ADAPTER" arm >/dev/null || fail "second home could not arm review source"
SID1=$(FM_HOME="$H_ARM1" "$ADAPTER" source-id)
SID2=$(FM_HOME="$H_ARM2" "$ADAPTER" source-id)
[ "$SID1" != "$SID2" ] || fail "two homes shared one review source identity"
ln -s "$H_ARM1" "$TMP/arm-home-1-alias"
SID1_ALIAS=$(FM_HOME="$TMP/arm-home-1-alias" "$ADAPTER" source-id)
[ "$SID1" = "$SID1_ALIAS" ] || fail "one physical home gained duplicate source identity through a path alias"
assert_present "$H_ARM1/state/procevent/$SID1.source" "first home registration is missing"
assert_present "$H_ARM2/state/procevent/$SID2.source" "second home registration is missing"
printf '%s\n' '{"schema":"fm-pr-review-event.v1","event_id":"1900-0123456789abcdef","category":"inventory","changed":1,"pending":1,"response_pending":0,"message":""}' > "$TMP/pr-review-result.json"
[ "$("$ADAPTER" classify "$TMP/pr-review-result.json")" = work ] || fail "adapter rejected a bounded review result"
"$ADAPTER" terminal "$TMP/pr-review-result.json" || fail "review result did not retire its exact source generation"
printf 'not-json\n' > "$TMP/pr-review-malformed"
"$ADAPTER" terminal "$TMP/pr-review-malformed" >/dev/null 2>&1 && fail "malformed review result retired its source"
FM_HOME="$H_ARM1" "$ADAPTER" arm >/dev/null || fail "restart re-arm failed"
[ "$(find "$H_ARM1/state/procevent" -name '*.source' | wc -l | tr -d ' ')" -eq 1 ] || fail "restart created a second source"
sup=$(bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2" && echo yes || echo no' _ "$ROOT" "$H_ARM1/state")
[ "$sup" = yes ] || fail "review source alone did not retain supervision"
pass "process-event registration is restart-idempotent and isolated per Firstmate home"

# Locked main-home bootstrap registers the source, while a marked secondmate
# skips the account-global poller.
H_BOOT="$TMP/bootstrap-arm"; new_home "$H_BOOT"; mkdir -p "$H_BOOT/config"
printf 'tmux\n' > "$H_BOOT/config/backend"
GH_AUTH_LOG="$TMP/gh-auth.log"; : > "$GH_AUTH_LOG"
PATH="$FAKEBIN:$PATH" FM_HOME="$H_BOOT" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux \
  FM_FAKE_GH_AUTH_LOG="$GH_AUTH_LOG" \
  FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=1 "$ROOT/bin/fm-bootstrap.sh" > "$TMP/bootstrap-arm.out" \
  || fail "main-home bootstrap could not register automatic review"
BOOT_SID=$(FM_HOME="$H_BOOT" "$ADAPTER" source-id)
assert_present "$H_BOOT/state/procevent/$BOOT_SID.source" "locked bootstrap omitted automatic review registration"
[ "$(grep -c '^auth status' "$GH_AUTH_LOG" || true)" -eq 1 ] \
  || fail "locked bootstrap probed GitHub authentication more than once per session start"
for marker in plain symlink dangling; do
  home="$TMP/bootstrap-secondmate-$marker"; new_home "$home"; mkdir -p "$home/config"
  printf 'tmux\n' > "$home/config/backend"
  case "$marker" in
    plain) printf 'review-mate\n' > "$home/.fm-secondmate-home" ;;
    symlink)
      printf 'review-mate\n' > "$TMP/secondmate-identity"
      ln -s "$TMP/secondmate-identity" "$home/.fm-secondmate-home" ;;
    dangling) ln -s "$TMP/secondmate-identity-absent" "$home/.fm-secondmate-home" ;;
  esac
  PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux \
    FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=1 "$ROOT/bin/fm-bootstrap.sh" > "$TMP/bootstrap-secondmate-$marker.out" \
    || fail "secondmate bootstrap failed for a $marker marker"
  [ ! -d "$home/state/procevent" ] \
    || [ -z "$(find "$home/state/procevent" -name 'pr-review-*.source' -print)" ] \
    || fail "a $marker secondmate marker still started a duplicate account-global review source"
done
pass "locked main-home bootstrap arms one account review source with one auth probe and no secondmate duplicates it"

# --- Authentication and rate limits fail boundedly without corrupting state --
H_AUTHFAIL="$TMP/auth-fail"; new_home "$H_AUTHFAIL"; make_dataset '[]'; : > "$GITHUB_LOG"
set +e
auth_event=$(FM_FAKE_AUTH_FAIL=1 run_fake_poll "$H_AUTHFAIL" 1700 2>/dev/null)
auth_rc=$?
set -e
[ "$auth_rc" -eq 0 ] || fail "authentication failure did not become a bounded diagnostic"
assert_contains "$auth_event" '"category":"authentication"' "authentication diagnostic category was lost"
run_review "$H_AUTHFAIL" acknowledge-event "$(printf '%s' "$auth_event" | jq -r '.event_id')" >/dev/null
set +e
auth_repeat=$(FM_FAKE_AUTH_FAIL=1 run_fake_poll "$H_AUTHFAIL" 1701 2>/dev/null)
auth_repeat_rc=$?
set -e
[ "$auth_repeat_rc" -eq 3 ] && [ -z "$auth_repeat" ] || fail "unchanged authentication failure did not deduplicate"
assert_absent "$H_AUTHFAIL/state/pr-review/snapshot.json" "authentication failure published a partial inventory"

H_RATE="$TMP/rate-fail"; new_home "$H_RATE"; : > "$GITHUB_LOG"
set +e
rate_event=$(FM_FAKE_CORE_REMAINING=10 run_fake_poll "$H_RATE" 1800 2>/dev/null)
rate_rc=$?
set -e
[ "$rate_rc" -eq 0 ] || fail "low-rate poll did not return its bounded diagnostic"
assert_contains "$rate_event" '"category":"rate-limit"' "rate-limit diagnostic category was lost"
next_poll=$(jq -r '.next_poll' "$H_RATE/state/pr-review/control.json")
[ "$next_poll" -ge 2005 ] || fail "rate-limit reset did not throttle the next poll"
assert_absent "$H_RATE/state/pr-review/snapshot.json" "rate-limited poll published a partial inventory"
set +e
FM_PR_REVIEW_MAX_PULLS=200 FM_PR_REVIEW_MAX_PAGES=100 run_review "$TMP/unsafe-rate-window" list --json >/dev/null 2>&1
unsafe_window_rc=$?
FM_PR_REVIEW_MIN_CORE_REMAINING=1 run_review "$TMP/weakened-rate-window" list --json >/dev/null 2>&1
weakened_window_rc=$?
set -e
[ "$unsafe_window_rc" -ne 0 ] || fail "configured inventory bounds exceeded one GitHub rate window"
[ "$weakened_window_rc" -ne 0 ] || fail "a headroom override weakened the configured worst-case bound"
pass "authentication and rate-limit failures stay bounded, deduplicated, and preserve the last good inventory"

# No public command or exercised write path may approve or merge.
assert_no_grep 'pr merge' "$GITHUB_LOG" "automatic owner exposed a merge path"
assert_no_grep --approve "$GITHUB_LOG" "automatic owner exposed a self-approval path"

printf '\n# all automatic pull-request review tests passed\n'
