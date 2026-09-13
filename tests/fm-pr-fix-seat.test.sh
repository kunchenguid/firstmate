#!/usr/bin/env bash
# Repair dispatch composes the context writer, trusted monitor, and launch port.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-fix-seat)
export FM_HOME="$TMP_ROOT/owning home"
unset FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_ROOT_OVERRIDE
mkdir -p "$FM_HOME/data" "$FM_HOME/state" "$TMP_ROOT/fakebin"
chmod 700 "$FM_HOME/state"
ln -s "$ROOT/bin" "$FM_HOME/bin"
TOOL="$ROOT/bin/fm-pr-fix-seat.sh"
WATCH="$ROOT/bin/fm-pr-context-watch.sh"
PROJECT="$TMP_ROOT/project"
fm_git_init_commit "$PROJECT"
printf '/data/\n' > "$PROJECT/.gitignore"
git -C "$PROJECT" add .gitignore
git -C "$PROJECT" commit -qm 'Ignore private delivery evidence'
git -C "$PROJECT" remote add origin https://github.com/example/project.git
export FM_TEST_REMOTE="$TMP_ROOT/remote.git"
git clone --bare -q "$PROJECT" "$FM_TEST_REMOTE"
git --git-dir="$FM_TEST_REMOTE" update-ref refs/heads/fm/change HEAD
export FM_TEST_REAL_GIT
FM_TEST_REAL_GIT=$(command -v git)
HEAD_A=$(git -C "$PROJECT" rev-parse HEAD)
URL=https://github.com/example/project/pull/12
export FM_PR_CONTEXT_NOW=1000
export FM_PR_CONTEXT_GH_CMD="$TMP_ROOT/fakebin/gh-axi"
export FM_TEST_PR_PAYLOAD="$TMP_ROOT/pr.json"
export FM_PR_FIX_SPAWN_BIN="$TMP_ROOT/fakebin/spawn"
cat > "$TMP_ROOT/context.json" <<JSON
{"pr_url":"$URL","head":"$HEAD_A","repo":"example/project","branch":"fm/change",
 "oracle":{"name":"acceptance","command":"bin/check"},"tests":[{"command":"bin/check","exit_code":0}],
 "open_review_threads":[],"deferred_items":[],"pre_push_command":"bin/check","merge_authority":"human-merge"}
JSON
cat > "$FM_TEST_PR_PAYLOAD" <<JSON
{"data":{"repository":{"pullRequest":{
 "url":"$URL","state":"OPEN","headRefOid":"$HEAD_A","headRefName":"fm/change",
 "author":{"login":"owner"},"headRepository":{"nameWithOwner":"example/project","defaultBranchRef":{"name":"main"}},
 "comments":{"pageInfo":{"hasNextPage":false},"nodes":[]},
 "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[]},
 "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{
   "id":"T1","isResolved":false,"comments":{"nodes":[{
     "id":"C1","updatedAt":"2026-09-12T12:00:00Z","author":{"login":"reviewer"}}]}},
   {"id":"T0","isResolved":false,"comments":{"nodes":[{
     "id":"C0","updatedAt":"2026-09-12T01:10:00Z","author":{"login":"reviewer"}}]}}]},
 "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}
}}}}
JSON
cat > "$FM_PR_CONTEXT_GH_CMD" <<'SH'
#!/usr/bin/env bash
set -eu
[ "$1 $2 $3" = 'api POST graphql' ] || exit 91
shift 3
filter= query= thread=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq) filter=$2; shift 2 ;;
    --field)
      case "$2" in query=*) query=${2#query=} ;; thread=*) thread=${2#thread=} ;; esac
      shift 2 ;;
    *) exit 92 ;;
  esac
done
if [ "${FM_TEST_MONITOR_DURING_WRITE:-0}" = 1 ] &&
    [[ "$query" == *headRefName* && "$query" != *statusCheckRollup* ]]; then
  callback=0
  [ ! -f "$FM_HOME/write-callback" ] || read -r callback < "$FM_HOME/write-callback"
  callback=$((callback + 1))
  printf '%s\n' "$callback" > "$FM_HOME/write-callback"
  jq --arg id "T$((callback + 2))" --arg comment "C$((callback + 2))" '
    .data.repository.pullRequest.reviewThreads.nodes += [{id:$id,isResolved:false,
      comments:{nodes:[{id:$comment,updatedAt:"2026-09-12T12:03:00Z"}]}}]' \
    "$FM_TEST_PR_PAYLOAD" > "$FM_TEST_PR_PAYLOAD.next"
  mv "$FM_TEST_PR_PAYLOAD.next" "$FM_TEST_PR_PAYLOAD"
  rc=0
  FM_DATA_OVERRIDE="$FM_HOME/data" FM_STATE_OVERRIDE="$FM_HOME/state" \
    "$FM_HOME/bin/fm-pr-context-watch.sh" poll change > "$FM_HOME/write-callback.$callback.out" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$FM_HOME/write-callback.$callback.rc"
fi
case "$query" in
  *addPullRequestReviewThreadReply*)
    [ "$thread" = T1 ] || exit 95
    printf '%s\n' "$thread" >> "$FM_HOME/replies"
    jq '.data.repository.pullRequest.reviewThreads.nodes |= map(if .id=="T1" then
      .comments.nodes=[{id:"OWN-C1",updatedAt:"2026-09-12T12:02:00Z",author:{login:"owner"}}] else . end)' \
      "$FM_TEST_PR_PAYLOAD" > "$FM_TEST_PR_PAYLOAD.next"
    mv "$FM_TEST_PR_PAYLOAD.next" "$FM_TEST_PR_PAYLOAD"
    printf '%s\n' '{"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"OWN-C1","url":"https://github.com/example/project/pull/12#discussion_r1","pullRequest":{"url":"https://github.com/example/project/pull/12"},"pullRequestReview":{"id":"OWN-R1"}}}}}' |
      jq -e "$filter" | jq -r 'to_entries[] | .key + ": " + (.value | tojson)'
    ;;
  *) jq -e "$filter" "$FM_TEST_PR_PAYLOAD" | jq -r 'to_entries[] | .key + ": " + (.value | tojson)' ;;
esac
SH
cat > "$FM_PR_FIX_SPAWN_BIN" <<'SH'
#!/usr/bin/env bash
set -eu
id=$1
[ -s "$FM_HOME/data/$id/brief.md" ] || exit 93
printf '%s\n' "$id" >> "$FM_HOME/launched"
printf '%s\n' "$@" > "$FM_HOME/launch-args"
copy="$FM_HOME/copies/$id"
mkdir -p "$FM_HOME/copies"
git -C "$2" worktree add -q --detach "$copy" HEAD
printf 'kind=ship\nproject=%s\nworktree=%s\n' "$2" "$copy" > "$FM_HOME/state/$id.meta"
SH
chmod +x "$FM_PR_CONTEXT_GH_CMD" "$FM_PR_FIX_SPAWN_BIN"
"$ROOT/bin/fm-pr-context.sh" write change < "$TMP_ROOT/context.json" >/dev/null
TZ=UTC touch -t 202609121159.00 "$FM_HOME/data/change/pr-context.md"
"$WATCH" install "$FM_HOME" change >/dev/null
event=$("$WATCH" poll change)
"$WATCH" ack change "$event"

if "$TOOL" change --project "$PROJECT" -- --harness pi > "$TMP_ROOT/unattested.out" 2>&1; then
  fail "repair intake accepted an unattested dispatch"
fi
[ ! -e "$FM_HOME/state/pr-fix-seat-12.json" ] || fail "unattested dispatch reserved a repair"
out=$("$TOOL" change --project "$PROJECT" -- --harness pi --dispatch-resolved --model example/model 2>&1) \
  || fail "context-driven repair launch failed: $out"
[ "$(wc -l < "$FM_HOME/launched" | tr -d ' ')" = 1 ] || fail "first feedback did not launch exactly one worker"
seat=$(cat "$FM_HOME/launched")
assert_grep '--dispatch-resolved' "$FM_HOME/launch-args" "launch lost its dispatch attestation"
assert_grep 'example/model' "$FM_HOME/launch-args" "launch changed the selected model"
"$ROOT/bin/fm-brief.sh" --validate-bookends "$FM_HOME/data/$seat/brief.md" >/dev/null \
  || fail "repair brief violated the standard scaffold's bookend contract"
# Exercise the same public content parser that fm-spawn applies before allocation.
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"
fm_brief_task_content_valid "$FM_HOME/data/$seat/brief.md" || fail "spawn refused the repair brief's task content"
assert_grep "$HEAD_A" "$FM_HOME/data/$seat/brief.md" "repair brief omitted the validated context"
assert_grep 'T1' "$FM_HOME/data/$seat/brief.md" "repair brief omitted the new thread identity"
if grep -Fq '"T0"' "$FM_HOME/data/$seat/repair-input.md"; then
  fail "repair input relabeled a pre-delivery thread as new feedback"
fi
assert_grep 'Never force-push' "$FM_HOME/data/$seat/brief.md" "repair brief lost the force-push prohibition"
assert_grep "$URL" "$FM_HOME/data/$seat/brief.md" "repair brief lost its single PR binding"
pass "a validated context and acknowledged monitor event launch one explicitly attested repair worker"

"$TOOL" change --project "$PROJECT" -- --harness pi --dispatch-resolved >/dev/null
[ "$(wc -l < "$FM_HOME/launched" | tr -d ' ')" = 1 ] || fail "replaying the same event launched a second worker"
jq -e '.pending|length==0' "$FM_HOME/state/pr-fix-seat-12.json" >/dev/null \
  || fail "replaying an already-active generation fabricated pending work"
export FM_PR_CONTEXT_NOW=1100
jq '.data.repository.pullRequest.reviewThreads.nodes += [{id:"T2",isResolved:false,
  comments:{nodes:[{id:"C2",updatedAt:"2026-09-12T12:01:00Z",author:{login:"reviewer"}}]}}]' \
  "$FM_TEST_PR_PAYLOAD" > "$TMP_ROOT/next.json"
mv "$TMP_ROOT/next.json" "$FM_TEST_PR_PAYLOAD"
[ -z "$("$WATCH" poll change)" ] || fail "active-round feedback escaped the ten-minute debounce"
jq -e 'any(.pending[]; any(.observed.threads[]; .id=="T2"))' \
  "$FM_HOME/state/pr-fix-seat-12.json" >/dev/null || fail "debounced feedback was not retained while the worker was active"
"$TOOL" change --project "$PROJECT" -- --harness pi --dispatch-resolved >/dev/null
[ "$(wc -l < "$FM_HOME/launched" | tr -d ' ')" = 1 ] || fail "new feedback launched a concurrent worker"
jq -e '.pending|length==1' "$FM_HOME/state/pr-fix-seat-12.json" >/dev/null \
  || fail "replaying a pending generation duplicated its durable batch"
pass "active work coalesces repeated intake while retaining new feedback before any debounced wake"

cat > "$TMP_ROOT/fakebin/git" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = -C ] && [ "${3:-}" = fetch ]; then
  [ "$#" -eq 5 ] && [ "$4" = origin ] && [ "$5" = refs/heads/fm/change ] || exit 94
  exec "$FM_TEST_REAL_GIT" -C "$2" fetch "$FM_TEST_REMOTE" "$5"
fi
if [ "${1:-}" = -C ] && [ "${3:-}" = push ]; then
  [ "$#" -eq 7 ] && [ "$4 $5 $6" = '--no-follow-tags --recurse-submodules=no origin' ] &&
    [ "$7" = HEAD:refs/heads/fm/change ] || exit 96
  printf '%s\n' "$7" >> "$FM_HOME/pushes"
  "$FM_TEST_REAL_GIT" -C "$2" push "$4" "$5" "$FM_TEST_REMOTE" "$7"
  head=$("$FM_TEST_REAL_GIT" --git-dir="$FM_TEST_REMOTE" rev-parse refs/heads/fm/change)
  jq --arg head "$head" '.data.repository.pullRequest.headRefOid=$head' "$FM_TEST_PR_PAYLOAD" > "$FM_TEST_PR_PAYLOAD.next"
  mv "$FM_TEST_PR_PAYLOAD.next" "$FM_TEST_PR_PAYLOAD"
  [ "${FM_TEST_AMBIGUOUS_PUSH:-0}" != 1 ] || exit 73
  exit 0
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
chmod +x "$TMP_ROOT/fakebin/git"
export PATH="$TMP_ROOT/fakebin:$PATH"
copy="$FM_HOME/copies/$seat"
if (cd "$PROJECT" && "$TOOL" prepare change "$seat") > "$TMP_ROOT/primary-prepare.out" 2>&1; then
  fail "repair preparation accepted the primary checkout"
fi
(cd "$copy" && "$TOOL" prepare change "$seat") > "$TMP_ROOT/prepare.out" 2>&1 \
  || fail "isolated repair preparation failed: $(cat "$TMP_ROOT/prepare.out")"
[ "$(git -C "$copy" rev-parse HEAD)" = "$HEAD_A" ] || fail "repair did not start at the exact observed PR head"
[ "$(git -C "$copy" symbolic-ref --short HEAD)" = "fm/$seat" ] || fail "repair did not get its own local branch"
[ "$(git --git-dir="$FM_TEST_REMOTE" rev-parse refs/heads/fm/change)" = "$HEAD_A" ] \
  || fail "preparation changed the remote PR branch"
(cd "$copy" && "$TOOL" prepare change "$seat") >/dev/null 2>&1 || fail "safe preparation did not converge on retry"
pass "repair checkout is isolated, exact-head, idempotent, and does not rewrite the remote branch"

printf 'Addressed the recorded feedback in this bounded round.\n' > "$TMP_ROOT/reply.md"
for thread in T0 T2; do
  if (cd "$copy" && "$TOOL" reply change "$seat" "$thread" < "$TMP_ROOT/reply.md") > "$TMP_ROOT/wrong-thread.out" 2>&1; then
    fail "repair replied to feedback outside its assigned round: $thread"
  fi
done
[ ! -e "$FM_HOME/replies" ] || fail "refused thread reached publication"
jq -e '.active.replies==null' "$FM_HOME/state/pr-fix-seat-12.json" >/dev/null \
  || fail "unassigned thread reached the publication-intent boundary"
(cd "$copy" && "$TOOL" reply change "$seat" T1 < "$TMP_ROOT/reply.md") > "$TMP_ROOT/reply.out" 2>&1 \
  || fail "bound inline reply failed: $(cat "$TMP_ROOT/reply.out")"
(cd "$copy" && "$TOOL" reply change "$seat" T1 < "$TMP_ROOT/reply.md") >/dev/null 2>&1 \
  || fail "confirmed inline reply was not idempotent"
[ "$(wc -l < "$FM_HOME/replies" | tr -d ' ')" = 1 ] || fail "inline reply was published more than once"
jq -e '.active.replies.T1.id=="OWN-C1" and .active.replies.T1.review_id=="OWN-R1"' \
  "$FM_HOME/state/pr-fix-seat-12.json" >/dev/null || fail "confirmed reply identities were not retained"
pass "inline replies are scoped to assigned threads, publication-gated, and retained for replay suppression"

printf 'bounded correction\n' > "$copy/fix.txt"
git -C "$copy" add fix.txt
git -C "$copy" commit -qm 'Apply bounded correction'
HEAD_B=$(git -C "$copy" rev-parse HEAD)
git -C "$copy" tag -a local-delivery-evidence -m 'Local verification only'
git -C "$copy" config push.followTags true
mkdir -p "$copy/data/$seat"
printf 'Repaired the recorded feedback; exact-head oracle and pre-push evidence are in the context.\n' > "$copy/data/$seat/debrief.md"
jq --arg head "$HEAD_B" '.head=$head' "$TMP_ROOT/context.json" > "$TMP_ROOT/repaired-context.json"
cp "$FM_HOME/data/change/pr-context.md" "$TMP_ROOT/context-before-finish.md"
jq '.merge_authority="fm-merge"' "$TMP_ROOT/repaired-context.json" > "$TMP_ROOT/promoted-context.json"
if (cd "$copy" && "$TOOL" finish change "$seat" < "$TMP_ROOT/promoted-context.json") > "$TMP_ROOT/promoted.out" 2>&1; then
  fail "repair promoted human merge authority"
fi
cmp -s "$FM_HOME/data/change/pr-context.md" "$TMP_ROOT/context-before-finish.md" || fail "refused context replaced the durable handoff"
[ ! -e "$FM_HOME/pushes" ] || fail "invalid completion reached publication"
for expression in '.oracle.name="different oracle"' '.repo="example/other"' '.head="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'; do
  jq "$expression" "$TMP_ROOT/repaired-context.json" > "$TMP_ROOT/invalid-completion.json"
  if (cd "$copy" && "$TOOL" finish change "$seat" < "$TMP_ROOT/invalid-completion.json") > "$TMP_ROOT/binding.out" 2>&1; then
    fail "completion accepted changed evidence binding: $expression"
  fi
done
printf 'uncommitted\n' > "$copy/dirty.txt"
if (cd "$copy" && "$TOOL" finish change "$seat" < "$TMP_ROOT/repaired-context.json") > "$TMP_ROOT/dirty.out" 2>&1; then
  fail "dirty completion reached publication"
fi
rm "$copy/dirty.txt"
mv "$copy/data/$seat/debrief.md" "$TMP_ROOT/debrief.md"
if (cd "$copy" && "$TOOL" finish change "$seat" < "$TMP_ROOT/repaired-context.json") > "$TMP_ROOT/no-debrief.out" 2>&1; then
  fail "completion accepted missing debrief"
fi
mv "$TMP_ROOT/debrief.md" "$copy/data/$seat/debrief.md"
git -C "$copy" remote set-url --push origin https://github.com/example/other.git
if (cd "$copy" && "$TOOL" finish change "$seat" < "$TMP_ROOT/repaired-context.json") > "$TMP_ROOT/push-url.out" 2>&1; then
  fail "completion accepted a different publication repository"
fi
git -C "$copy" config --unset-all remote.origin.pushurl
jq '.data.repository.pullRequest.headRepository.defaultBranchRef.name="fm/change"' "$FM_TEST_PR_PAYLOAD" > "$FM_TEST_PR_PAYLOAD.next"
mv "$FM_TEST_PR_PAYLOAD.next" "$FM_TEST_PR_PAYLOAD"
if (cd "$copy" && "$TOOL" finish change "$seat" < "$TMP_ROOT/repaired-context.json") > "$TMP_ROOT/default-branch.out" 2>&1; then
  fail "completion accepted the default branch"
fi
jq '.data.repository.pullRequest.headRepository.defaultBranchRef.name="main"' "$FM_TEST_PR_PAYLOAD" > "$FM_TEST_PR_PAYLOAD.next"
mv "$FM_TEST_PR_PAYLOAD.next" "$FM_TEST_PR_PAYLOAD"
[ ! -e "$FM_HOME/pushes" ] || fail "refused completion reached publication"
cmp -s "$FM_HOME/data/change/pr-context.md" "$TMP_ROOT/context-before-finish.md" || fail "refused completion replaced evidence"
pass "dirty copies, missing debriefs, changed evidence, push-URL drift and default-branch targets refuse before publication"
jq '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.state="PENDING"' "$FM_TEST_PR_PAYLOAD" > "$FM_TEST_PR_PAYLOAD.next"
mv "$FM_TEST_PR_PAYLOAD.next" "$FM_TEST_PR_PAYLOAD"
if (cd "$copy" && FM_TEST_AMBIGUOUS_PUSH=1 "$TOOL" finish change "$seat" < "$TMP_ROOT/repaired-context.json") > "$TMP_ROOT/ambiguous-push.out" 2>&1; then
  fail "ambiguous accepted push reported completion"
fi
[ "$(git --git-dir="$FM_TEST_REMOTE" rev-parse refs/heads/fm/change)" = "$HEAD_B" ] || fail "fixture did not accept the ambiguous push"
if (cd "$copy" && "$TOOL" finish change "$seat" < "$TMP_ROOT/repaired-context.json") > "$TMP_ROOT/pending-ci.out" 2>&1; then
  fail "pending checks reported completion"
fi
assert_grep 'checks are not successful' "$TMP_ROOT/pending-ci.out" "retry did not reach the current CI gate"
[ "$(wc -l < "$FM_HOME/pushes" | tr -d ' ')" = 1 ] || fail "retry repeated an already accepted push"
if grep -q '^done:' "$FM_HOME/state/$seat.status" 2>/dev/null; then fail "unverified publication signalled done"; fi
cmp -s "$FM_HOME/data/change/pr-context.md" "$TMP_ROOT/context-before-finish.md" || fail "pending CI replaced delivery evidence"
jq '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.state="SUCCESS"' "$FM_TEST_PR_PAYLOAD" > "$FM_TEST_PR_PAYLOAD.next"
mv "$FM_TEST_PR_PAYLOAD.next" "$FM_TEST_PR_PAYLOAD"
pass "ambiguous accepted pushes recover without republishing while pending CI preserves the reservation and original context"
[ ! -e "$FM_HOME/state/$seat.status" ] || fail "fixture masked completion without a status file"
(cd "$copy" && FM_TEST_MONITOR_DURING_WRITE=1 "$TOOL" finish change "$seat" < "$TMP_ROOT/repaired-context.json") > "$TMP_ROOT/finish.out" 2>&1 \
  || fail "one-round completion failed: $(cat "$TMP_ROOT/finish.out")"
[ "$(git --git-dir="$FM_TEST_REMOTE" rev-parse refs/heads/fm/change)" = "$HEAD_B" ] || fail "repair did not publish its exact head"
if git --git-dir="$FM_TEST_REMOTE" show-ref --verify --quiet refs/tags/local-delivery-evidence; then
  fail "single-branch publication included an implicitly followed tag"
fi
"$ROOT/bin/fm-pr-context.sh" validate change --json | jq -e --arg head "$HEAD_B" \
  '.head==$head and .branch=="fm/change" and .merge_authority=="human-merge"' >/dev/null || fail "repair did not rewrite the original context"
assert_grep "done: PR $URL" "$FM_HOME/state/$seat.status" "verified completion did not stop the worker"
(cd "$copy" && "$TOOL" finish change "$seat" < "$TMP_ROOT/repaired-context.json") >/dev/null 2>&1 \
  || fail "completed round did not converge on retry"
[ "$(wc -l < "$FM_HOME/pushes" | tr -d ' ')" = 1 ] || fail "completed round pushed again"
[ "$(grep -c '^done:' "$FM_HOME/state/$seat.status")" = 1 ] || fail "completion signal was duplicated"
cp "$FM_HOME/state/$seat.status" "$TMP_ROOT/status-before"
for unsafe_status in symlink hardlink public; do
  mv "$FM_HOME/state/$seat.status" "$TMP_ROOT/saved-status"
  case "$unsafe_status" in
    symlink) ln -s "$TMP_ROOT/saved-status" "$FM_HOME/state/$seat.status" ;;
    hardlink) ln "$TMP_ROOT/saved-status" "$FM_HOME/state/$seat.status" ;;
    public) cp "$TMP_ROOT/saved-status" "$FM_HOME/state/$seat.status"; chmod 644 "$FM_HOME/state/$seat.status" ;;
  esac
  if (cd "$copy" && "$TOOL" finish change "$seat" < "$TMP_ROOT/repaired-context.json") > "$TMP_ROOT/unsafe-status.out" 2>&1; then
    fail "completion accepted $unsafe_status status"
  fi
  assert_grep 'unsafe repair status' "$TMP_ROOT/unsafe-status.out" "unsafe status missed its guard"
  cmp -s "$TMP_ROOT/status-before" "$TMP_ROOT/saved-status" || fail "completion changed a linked status target"
  rm "$FM_HOME/state/$seat.status"
  mv "$TMP_ROOT/saved-status" "$FM_HOME/state/$seat.status"
done
pass "one-round completion creates private status, refuses unsafe files, publishes one ref, and stops once on replay"
[ "$(cat "$FM_HOME/write-callback")" = 2 ] || fail "test did not exercise both context writer lookups"
for callback in 1 2; do
  [ "$(cat "$FM_HOME/write-callback.$callback.rc")" = 0 ] || fail "context branch lookup blocked concurrent monitor intake"
done
jq -e 'any(.pending[]; any(.feedback.threads[]; .id=="T3")) and
  any(.pending[]; any(.feedback.threads[]; .id=="T4"))' \
  "$FM_HOME/state/pr-fix-seat-12.json" >/dev/null || fail "context rewrite lost concurrently observed feedback"
pass "context-writer forge reads leave pending intake available throughout completion"

cp "$FM_HOME/state/pr-fix-seat-12.json" "$TMP_ROOT/before-retirement.json"
cp "$copy/data/$seat/debrief.md" "$FM_HOME/data/$seat/debrief.md"
chmod 600 "$FM_HOME/data/$seat/debrief.md"
"$TOOL" retirement-stage "$seat"
git -C "$copy" checkout -q --detach "$HEAD_A"
"$TOOL" ready "$seat" "$URL" "$HEAD_B" "$copy" || fail "staged retirement inspected a returned/reallocated pool copy"
printf 'changed evidence\n' >> "$FM_HOME/data/$seat/debrief.md"
if "$TOOL" ready "$seat" "$URL" "$HEAD_B" "$copy" >/dev/null 2>&1; then fail "staged retirement accepted changed preserved evidence"; fi
cp "$copy/data/$seat/debrief.md" "$FM_HOME/data/$seat/debrief.md"
git -C "$copy" checkout -q "fm/$seat"
cp "$TMP_ROOT/before-retirement.json" "$FM_HOME/state/pr-fix-seat-12.json"
pass "staged retirement uses its durable receipt after pool return changes the checkout"

cat > "$TMP_ROOT/fakebin/gh" <<'SH'
#!/bin/sh
printf 'OPEN\n'
SH
cat > "$TMP_ROOT/fakebin/teardown" <<'SH'
#!/usr/bin/env bash
set -eu
[ "$#" -eq 1 ] && [ "$FM_TEARDOWN_GUARD_DONE" = 1 ] || exit 97
id=$1
[ -s "$FM_HOME/data/$id/debrief.md" ] || exit 98
copy=$(awk -F= '$1=="worktree" {sub(/^[^=]*=/, ""); print}' "$FM_HOME/state/$id.meta")
project=$(awk -F= '$1=="project" {sub(/^[^=]*=/, ""); print}' "$FM_HOME/state/$id.meta")
first=0
if [ -d "$copy" ]; then
  [ "$("$FM_TEST_REAL_GIT" -C "$copy" rev-parse HEAD)" = \
    "$("$FM_TEST_REAL_GIT" --git-dir="$FM_TEST_REMOTE" rev-parse refs/heads/fm/change)" ] || exit 99
  "$FM_TEST_REAL_GIT" -C "$project" worktree remove "$copy"
  first=1
fi
queued=$(awk 'END {print NR}' "$FM_HOME/state/.wake-queue" 2>/dev/null || printf 0)
"$FM_HOME/bin/fm-pr-fix-seat.sh" retirement-stage "$id"
if "$FM_HOME/bin/fm-pr-fix-seat.sh" retired "$id" >/dev/null 2>&1; then exit 100; fi
[ "$(awk 'END {print NR}' "$FM_HOME/state/.wake-queue" 2>/dev/null || printf 0)" = "$queued" ] || exit 101
if [ "$first" = 1 ]; then
  printf 'endpoint busy after physical cleanup and staged receipt\n' >&2
  exit 1
fi
# Simulate an interruption after metadata removal, before the final callback.
rm "$FM_HOME/state/$id.meta" "$FM_HOME/state/$id.status"
printf '%s\n' "$id" >> "$FM_HOME/retired"
SH
chmod +x "$TMP_ROOT/fakebin/gh" "$TMP_ROOT/fakebin/teardown"
FM_TEARDOWN_BIN="$TMP_ROOT/fakebin/teardown" "$ROOT/bin/fm-auto-retire.sh" > "$TMP_ROOT/retire-interrupted.out" 2>&1
[ -s "$FM_HOME/state/$seat.meta" ] && [ ! -d "$copy" ] || fail "fixture missed the staged cleanup interruption"
FM_TEARDOWN_BIN="$TMP_ROOT/fakebin/teardown" "$ROOT/bin/fm-auto-retire.sh" > "$TMP_ROOT/retire.out" 2>&1
[ -f "$FM_HOME/retired" ] || fail "completed repair was not selected for ordinary automatic retirement"
[ ! -d "$copy" ] || fail "repair copy survived ordinary retirement"
jq -e '.active==null and (.pending_feedback.threads|map(.id)|sort)==["T2","T3","T4"]' \
  "$FM_HOME/state/pr-fix-seat-12.json" >/dev/null || fail "retirement lost pending feedback or retained its active reservation"
[ -s "$FM_HOME/data/change/pr-context.md" ] && [ -s "$FM_HOME/state/pr-fix-change.check.sh" ] \
  || fail "open repair retirement removed the original context or monitor"
queue_count=$(wc -l < "$FM_HOME/state/.wake-queue")
FM_TEARDOWN_BIN="$TMP_ROOT/fakebin/teardown" "$ROOT/bin/fm-auto-retire.sh" >/dev/null
[ "$(wc -l < "$FM_HOME/state/.wake-queue")" = "$queue_count" ] || fail "retirement recovery queued the same pending batch again"
queue=$("$ROOT/bin/fm-wake-drain.sh")
assert_contains "$queue" "pr-fix: 12 $HEAD_B comment $URL" "retirement did not re-emit pending feedback"
pass "ordinary retirement releases its reservation only after metadata removal and re-emits pending work once"

export FM_PR_CONTEXT_NOW=1700
[ -z "$("$WATCH" poll change)" ] || fail "delivered repair head or its own replies created another monitor event"
"$TOOL" change --project "$PROJECT" -- --harness pi --dispatch-resolved >/dev/null
[ "$(wc -l < "$FM_HOME/launched" | tr -d ' ')" = 2 ] || fail "pending feedback did not launch one subsequent round"
next_seat=$(tail -1 "$FM_HOME/launched")
[ "$next_seat" != "$seat" ] || fail "next round reused the retired task identity"
jq -e '.active.snapshot.observed.head==.active.context.head and
  (.active.snapshot.feedback.threads|map(.id)|sort)==["T2","T3","T4"] and (.pending|length)==0' \
  "$FM_HOME/state/pr-fix-seat-12.json" >/dev/null || fail "next round lost pending identities or replayed handled replies"
pass "the next round resumes only pending feedback on the rewritten head, without replaying its own replies"

jq '.data.repository.pullRequest.state="CLOSED"' "$FM_TEST_PR_PAYLOAD" > "$FM_TEST_PR_PAYLOAD.next"
mv "$FM_TEST_PR_PAYLOAD.next" "$FM_TEST_PR_PAYLOAD"
event=$("$WATCH" poll change)
"$WATCH" ack change "$event"
if "$TOOL" archive change > "$TMP_ROOT/active-archive.out" 2>&1; then fail "active repair context was archived"; fi
assert_grep 'active repair' "$TMP_ROOT/active-archive.out" "archive refusal did not identify the active reservation"
[ -s "$FM_HOME/data/change/pr-context.md" ] && [ -s "$FM_HOME/state/pr-fix-change.check.sh" ] \
  || fail "active archive refusal removed context or monitor"
jq '.data.repository.pullRequest.state="OPEN"' "$FM_TEST_PR_PAYLOAD" > "$FM_TEST_PR_PAYLOAD.next"
mv "$FM_TEST_PR_PAYLOAD.next" "$FM_TEST_PR_PAYLOAD"
"$WATCH" poll change >/dev/null
pass "acknowledged closure cannot archive evidence still owned by an active repair"

next_copy="$FM_HOME/copies/$next_seat"
(cd "$next_copy" && "$TOOL" prepare change "$next_seat") >/dev/null 2>&1
reason='Cannot reproduce the reported failure with the supplied oracle; an input example is required.'
mkdir -p "$next_copy/data/$next_seat"
printf '%s\n' "$reason" > "$next_copy/data/$next_seat/debrief.md"
(cd "$next_copy" && printf '%s\n' "$reason" | "$TOOL" defer change "$next_seat") > "$TMP_ROOT/defer.out" 2>&1 \
  || fail "unfixable round could not record its reason: $(cat "$TMP_ROOT/defer.out")"
"$ROOT/bin/fm-pr-context.sh" validate change --json | jq -e --arg reason "$reason" --arg head "$HEAD_B" '
  .head==$head and .merge_authority=="human-merge" and any(.deferred_items[]; contains($reason))' >/dev/null \
  || fail "deferral lost its reason or changed the delivered head/merge authority"
(cd "$next_copy" && printf '%s\n' "$reason" | "$TOOL" defer change "$next_seat") >/dev/null
[ "$(wc -l < "$FM_HOME/pushes" | tr -d ' ')" = 1 ] || fail "deferral published a commit"
[ "$(grep -c '^done: ' "$FM_HOME/state/$next_seat.status")" = 1 ] || fail "deferral repeated its completion signal"
"$TOOL" ready "$next_seat" "$URL" "$HEAD_B" "$next_copy" || fail "recorded deferral was not eligible for ordinary cleanup"
pass "unfixable rounds preserve a context reason and merge authority without pushing or duplicating completion"
FM_TEARDOWN_BIN="$TMP_ROOT/fakebin/teardown" "$ROOT/bin/fm-auto-retire.sh" > "$TMP_ROOT/defer-retire-interrupted.out" 2>&1
FM_TEARDOWN_BIN="$TMP_ROOT/fakebin/teardown" "$ROOT/bin/fm-auto-retire.sh" > "$TMP_ROOT/defer-retire.out" 2>&1
jq -e --arg reason "$reason" '.active==null and .escalation.reason==$reason and .last_outcome.outcome=="deferred"' \
  "$FM_HOME/state/pr-fix-seat-12.json" >/dev/null || fail "deferral retirement lost its escalation"
jq '.data.repository.pullRequest.comments.nodes += [{id:"NEW-AFTER-DEFER",updatedAt:"2050-01-01T00:00:00Z"}]' \
  "$FM_TEST_PR_PAYLOAD" > "$FM_TEST_PR_PAYLOAD.next"
mv "$FM_TEST_PR_PAYLOAD.next" "$FM_TEST_PR_PAYLOAD"
export FM_PR_CONTEXT_NOW=2300
event=$("$WATCH" poll change)
"$WATCH" ack change "$event"
if "$TOOL" change --project "$PROJECT" -- --harness pi --dispatch-resolved > "$TMP_ROOT/blocked.out" 2>&1; then
  fail "new feedback restarted a deferred repair without owner reconciliation"
fi
[ "$(wc -l < "$FM_HOME/launched" | tr -d ' ')" = 2 ] || fail "deferral created another worker"
pass "retiring an unfixable round preserves its escalation and blocks automatic retry"

jq '.data.repository.pullRequest.state="MERGED"' "$FM_TEST_PR_PAYLOAD" > "$FM_TEST_PR_PAYLOAD.next"
mv "$FM_TEST_PR_PAYLOAD.next" "$FM_TEST_PR_PAYLOAD"
export FM_PR_CONTEXT_NOW=3000
event=$("$WATCH" poll change)
"$ROOT/bin/fm-auto-retire.sh" >/dev/null
[ -s "$FM_HOME/data/change/pr-context.md" ] && [ -s "$FM_HOME/state/pr-fix-change.check.sh" ] \
  || fail "unacknowledged terminal event was archived prematurely"
"$WATCH" ack change "$event"
cp "$FM_HOME/data/change/pr-context.md" "$TMP_ROOT/archive-context.md"
cp "$FM_HOME/state/pr-fix-change.snapshot.json" "$TMP_ROOT/archive-snapshot.json"
"$ROOT/bin/fm-auto-retire.sh" > "$TMP_ROOT/archive.out" 2>&1
[ ! -e "$FM_HOME/data/change/pr-context.md" ] || fail "automatic retirement did not archive the merged context"
[ ! -e "$FM_HOME/state/pr-fix-change.snapshot.json" ] && [ ! -e "$FM_HOME/state/pr-fix-change.check.sh" ] \
  || fail "terminal snapshot or monitor remained in live state"
archived=$(find "$FM_HOME/data/change" -mindepth 2 -name pr-context.md -print)
[ -n "$archived" ] || fail "archived context is missing"
cmp "$TMP_ROOT/archive-context.md" "$archived" || fail "archived context bytes changed"
cmp "$TMP_ROOT/archive-snapshot.json" "${archived%/*}/snapshot.json" || fail "archived snapshot bytes changed"
"$ROOT/bin/fm-auto-retire.sh" >/dev/null
[ "$(find "$FM_HOME/data/change" -mindepth 2 -name pr-context.md | wc -l | tr -d ' ')" = 1 ] \
  || fail "terminal archival was repeated"
pass "acknowledged terminal context and snapshot archive together after the original metadata is gone"

jq --arg url 'https://github.com/example/project/pull/13' '.data.repository.pullRequest.url=$url' \
  "$FM_TEST_PR_PAYLOAD" > "$FM_TEST_PR_PAYLOAD.next"
mv "$FM_TEST_PR_PAYLOAD.next" "$FM_TEST_PR_PAYLOAD"
jq --arg head "$HEAD_B" '.pr_url="https://github.com/example/project/pull/13" | .head=$head' "$TMP_ROOT/context.json" |
  "$ROOT/bin/fm-pr-context.sh" write standalone >/dev/null
"$WATCH" install "$FM_HOME" standalone >/dev/null
event=$("$WATCH" poll standalone)
"$WATCH" ack standalone "$event"
"$WATCH" retire "$FM_HOME" standalone >/dev/null
cp "$FM_HOME/data/standalone/pr-context.md" "$TMP_ROOT/standalone-context.md"
cp "$FM_HOME/state/pr-fix-standalone.snapshot.json" "$TMP_ROOT/standalone-snapshot.json"
export FM_TEST_REAL_RM
FM_TEST_REAL_RM=$(command -v rm)
mkdir "$TMP_ROOT/archivebin"
cat > "$TMP_ROOT/archivebin/rm" <<'SH'
#!/usr/bin/env bash
for arg do
  if [ -n "${FM_TEST_FAIL_ARCHIVE_UNLINK:-}" ] && [ "$arg" = "$FM_TEST_FAIL_ARCHIVE_UNLINK" ]; then exit 77; fi
done
exec "$FM_TEST_REAL_RM" "$@"
SH
chmod +x "$TMP_ROOT/archivebin/rm"
PATH="$TMP_ROOT/archivebin:$PATH" FM_TEST_FAIL_ARCHIVE_UNLINK="$FM_HOME/data/standalone/pr-context.md" \
  "$ROOT/bin/fm-auto-retire.sh" > "$TMP_ROOT/archive-interrupted.out" 2>&1
[ -s "$FM_HOME/data/standalone/pr-context.md" ] && [ ! -e "$FM_HOME/state/pr-fix-standalone.snapshot.json" ] \
  || fail "fixture did not interrupt archival between source removals"
if "$ROOT/bin/fm-pr-context.sh" write standalone < "$TMP_ROOT/context.json" > "$TMP_ROOT/quarantine-write.out" 2>&1; then
  fail "context writer bypassed the unfinished archive"
fi
assert_grep 'archival is in progress' "$TMP_ROOT/quarantine-write.out" "write did not reach the archive quarantine"
if "$WATCH" install "$FM_HOME" standalone > "$TMP_ROOT/quarantine-install.out" 2>&1; then
  fail "monitor reinstalled over an unfinished archive"
fi
printf '\nconcurrent owner evidence\n' >> "$FM_HOME/data/standalone/pr-context.md"
"$ROOT/bin/fm-auto-retire.sh" > "$TMP_ROOT/archive-drift.out" 2>&1
assert_grep 'concurrent owner evidence' "$FM_HOME/data/standalone/pr-context.md" "archival erased a changed source"
[ -s "$FM_HOME/data/standalone/pr-archive.json" ] || fail "source drift discarded the recovery manifest"
cp "$TMP_ROOT/standalone-context.md" "$FM_HOME/data/standalone/pr-context.md"
pass "unfinished archival blocks writes and reinstallation and preserves source drift for review"
"$ROOT/bin/fm-auto-retire.sh" > "$TMP_ROOT/archive-recovered.out" 2>&1
[ ! -e "$FM_HOME/data/standalone/pr-context.md" ] || fail "interrupted archival did not finish"
archived=$(find "$FM_HOME/data/standalone" -mindepth 2 -name pr-context.md -print)
cmp "$TMP_ROOT/standalone-context.md" "$archived" || fail "interrupted archival changed context evidence"
cmp "$TMP_ROOT/standalone-snapshot.json" "${archived%/*}/snapshot.json" || fail "interrupted archival lost the retired snapshot"
pass "an already-retired monitor archives without task metadata and recovers an interrupted context/snapshot move"

jq '.data.repository.pullRequest.url="https://github.com/example/project/pull/14" |
  .data.repository.pullRequest.state="OPEN"' "$FM_TEST_PR_PAYLOAD" > "$FM_TEST_PR_PAYLOAD.next"
mv "$FM_TEST_PR_PAYLOAD.next" "$FM_TEST_PR_PAYLOAD"
jq --arg head "$HEAD_B" '.pr_url="https://github.com/example/project/pull/14" | .head=$head' "$TMP_ROOT/context.json" |
  "$ROOT/bin/fm-pr-context.sh" write failed-launch >/dev/null
TZ=UTC touch -t 202609121159.00 "$FM_HOME/data/failed-launch/pr-context.md"
"$WATCH" install "$FM_HOME" failed-launch >/dev/null
event=$("$WATCH" poll failed-launch)
"$WATCH" ack failed-launch "$event"
cat > "$TMP_ROOT/fakebin/fail-spawn" <<'SH'
#!/usr/bin/env bash
printf 'attempt\n' >> "$FM_HOME/failed-launches"
exit 72
SH
chmod +x "$TMP_ROOT/fakebin/fail-spawn"
if FM_PR_FIX_SPAWN_BIN="$TMP_ROOT/fakebin/fail-spawn" "$TOOL" failed-launch --project "$PROJECT" -- --harness pi --dispatch-resolved > "$TMP_ROOT/failed-launch.out" 2>&1; then
  fail "launcher failure was reported as success"
fi
FM_PR_FIX_SPAWN_BIN="$TMP_ROOT/fakebin/fail-spawn" "$TOOL" failed-launch --project "$PROJECT" -- --harness pi --dispatch-resolved >/dev/null
[ "$(wc -l < "$FM_HOME/failed-launches" | tr -d ' ')" = 1 ] || fail "ambiguous launch was repeated"
jq -e '.active.phase=="launch-failed" and .active.launch_exit==72' "$FM_HOME/state/pr-fix-seat-14.json" >/dev/null || fail "failed launch lost its reservation"
pass "failed launch retains its reservation and never allocates a duplicate on repeated intake"
