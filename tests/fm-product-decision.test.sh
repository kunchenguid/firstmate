#!/usr/bin/env bash
# Exercise durable project decision creation, replay, answer recovery, and parent reporting.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-repo-concurrency-lib.sh disable=SC1091
. "$ROOT/bin/fm-repo-concurrency-lib.sh"

command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo 'skip: tasks-axi not found'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-product-decision)
ROOT_HOME="$TMP_ROOT/root"
PFA="$TMP_ROOT/pfa"
CHILD="$TMP_ROOT/steward"
PROJECT="$PFA/projects/alpha"
ORIGIN="$TMP_ROOT/alpha.origin.git"
PID_SCRIPT="$ROOT/bin/fm-product-decision.sh"

make_home() {
  local home=$1
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
}

make_home "$ROOT_HOME"
make_home "$PFA"
make_home "$CHILD"
mkdir -p "$PFA/bin" "$CHILD/bin"
cp "$ROOT/AGENTS.md" "$PFA/AGENTS.md"
cp "$ROOT/AGENTS.md" "$CHILD/AGENTS.md"
fm_git_init_commit "$PROJECT"
fm_git_add_origin "$PROJECT" "$ORIGIN"
git clone --quiet "file://$(cd "$ORIGIN" && pwd -P)" "$CHILD/projects/alpha"
repo_identity=$(fm_repo_scope_clone_identity "$PROJECT") || fail 'could not calculate repository identity'
repo_identity="sha256:$repo_identity"
authority_hash=$(printf '%s' "$PFA"$'\n''alpha'$'\n'"$repo_identity" | shasum -a 256 | awk '{print $1}')
authority_id="sha256:$authority_hash"
printf 'schema=fm-project-firstmate.v1\nproject=alpha\nrepo_identity=%s\nauthority_id=%s\nrepo_path=%s\n' \
  "$repo_identity" "$authority_id" "$PROJECT" > "$PFA/.fm-project-firstmate"
printf 'alpha-pfa\n' > "$PFA/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\nparent_role=root\n' \
  "$ROOT_HOME" > "$PFA/.fm-secondmate-parent"
printf -- '- alpha-pfa - Project Firstmate for alpha (home: %s; scope: alpha repository; projects: alpha; added 2026-09-17)\n' \
  "$PFA" > "$ROOT_HOME/data/secondmates.md"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\nparent_role=project-firstmate\nrepo_authority_home=%s\nrepo_authority_id=%s\nrepo_identity=%s\n' \
  "$PFA" "$PFA" "$authority_id" "$repo_identity" > "$CHILD/.fm-secondmate-parent"
printf 'product-decision-steward\n' > "$CHILD/.fm-secondmate-home"
printf -- '- product-decision-steward - Own product implementation decisions (home: %s; scope: project implementation decisions; projects: alpha; added 2026-09-17)\n' \
  "$CHILD" > "$PFA/data/secondmates.md"

FM_HOME="$CHILD" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-tasks-axi.sh" add pid-origin "Implement account recovery" \
  --kind ship --repo alpha --start >/dev/null || fail 'could not create originating work item'
FM_HOME="$CHILD" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-captain-hold.sh" hold pid-origin \
  --reason 'Captain needs to choose the account recovery experience' >/dev/null || fail 'could not captain-hold originating work'

write_input() {
  local request_key=$1 title=${2:-"Email confirmation"} task=${3:-pid-origin} supersedes=${4:-}
  cat > "$TMP_ROOT/$request_key.json" <<EOF
{
  "schema": "fm-product-decision-input.v1",
  "decision_type": "product",
  "project": "alpha",
  "request_key": "$request_key",
  "originating_task": "$task",
  "question": "Should account recovery require email confirmation?",
  "context": "Customers sometimes lose access to their account after changing devices.",
  "user_impact": "The choice changes how quickly customers can regain access and how well we protect accounts.",
  "options": [
    {"label":"A","title":"Require email confirmation","pros":["Adds a familiar safety check."],"cons":["Customers without inbox access wait longer."],"consequences":"Add a confirmation step before recovery completes."},
    {"label":"B","title":"Allow recovery immediately","pros":["Gets customers back in quickly."],"cons":["A person with device access may take over an account."],"consequences":"Complete recovery without an email confirmation step."}
  ],
  "recommendation": "$title",
  "recommended_option": "A",
  "rationale": "A familiar confirmation step balances account safety with a clear recovery path.",
  "consequences": "The chosen flow changes the recovery steps customers see.",
  "affected": {"requirements":["Account recovery"],"docs":["docs/account-recovery.md"],"tasks":["pid-origin"]}
}
EOF
  if [ -n "$supersedes" ]; then
    jq --arg supersedes "$supersedes" '.supersedes=$supersedes' "$TMP_ROOT/$request_key.json" \
      > "$TMP_ROOT/$request_key.tmp" && mv "$TMP_ROOT/$request_key.tmp" "$TMP_ROOT/$request_key.json"
  fi
}

run_pid() {
  FM_HOME="$CHILD" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$CHILD/state" \
    FM_DATA_OVERRIDE="$CHILD/data" "$PID_SCRIPT" "$@"
}

summary=$(FM_HOME="$PFA" FM_ROOT_OVERRIDE="$ROOT" "$PID_SCRIPT" summary) \
  || fail 'bounded open-decision summary command failed'
printf '%s' "$summary" | jq -e '.total == 0 and .open == [] and .omitted == 0' >/dev/null \
  || fail 'summary exposed a decision before any record was created'

write_input pid-create
perl -e 'print "{\"padding\":\"", "x" x 70000, "\"}\n"' > "$TMP_ROOT/pid-oversized.json"
if run_pid create --input "$TMP_ROOT/pid-oversized.json" > /dev/null 2> "$TMP_ROOT/pid-oversized.err"; then
  fail 'the schema accepted an oversized product-decision input'
fi
grep -F 'input exceeds 65536 bytes' "$TMP_ROOT/pid-oversized.err" > /dev/null \
  || fail 'the oversized-input refusal did not explain its durable-record bound'
jq '.decision_type="technical"' "$TMP_ROOT/pid-create.json" > "$TMP_ROOT/pid-invalid.json"
if run_pid create --input "$TMP_ROOT/pid-invalid.json" >/dev/null 2>&1; then
  fail 'the schema accepted a technical execution question as a product decision'
fi
[ ! -e "$PFA/data/product-decisions/pid-1.json" ] \
  || fail 'a rejected non-product decision consumed a durable PID'
first=$(run_pid create --input "$TMP_ROOT/pid-create.json") || fail 'initial PID creation failed'
[ "$first" = PID-1 ] || fail "first PID was not PID-1: $first"
summary=$(FM_HOME="$PFA" FM_ROOT_OVERRIDE="$ROOT" "$PID_SCRIPT" summary) \
  || fail 'bounded open-decision summary command failed after create'
printf '%s' "$summary" | jq -e '.total == 1 and .open[0].key == "alpha/pid-1" and .open[0].options[0].pros[0] == "Adds a familiar safety check." and ((.open[0] | has("request_key")) | not)' >/dev/null \
  || { printf 'summary output: %s\n' "$summary" >&2; fail 'summary did not expose bounded user-facing content without internal request fields'; }
home_summary=$(FM_HOME="$PFA" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary) \
  || fail 'structured home snapshot did not include the PID summary'
printf '%s' "$home_summary" | jq -e '.product_decision_count == 1 and .product_decisions[0].key == "alpha/pid-1"' >/dev/null \
  || fail 'fleet summary dropped repository-local open decisions'
second=$(run_pid create --input "$TMP_ROOT/pid-create.json") || fail 'idempotent create replay failed'
[ "$second" = PID-1 ] || fail "idempotent replay allocated a second PID: $second"
[ "$(run_pid list | wc -l | tr -d ' ')" = 1 ] || fail 'list did not render the open PID exactly once'
run_pid show pid-1 | jq -e '.question == "Should account recovery require email confirmation?" and .status == "open" and .options[0].label == "A"' >/dev/null \
  || fail 'targeted PID read omitted the durable decision content'
pass 'create, idempotent replay, list, and targeted show use one durable repository record'

# Two independent creators contend only on the allocator and receive distinct IDs.
for task in pid-origin-a pid-origin-b; do
  FM_HOME="$CHILD" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-tasks-axi.sh" add "$task" \
    "Implement recovery path $task" --kind ship --repo alpha --start >/dev/null \
    || fail "could not create the independent source task $task"
  FM_HOME="$CHILD" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-captain-hold.sh" hold "$task" \
    --reason "Captain needs to choose the recovery product behavior for $task" >/dev/null \
    || fail "could not hold the independent source task $task"
done
write_input pid-concurrent-a 'Use the existing account settings page' pid-origin-a
write_input pid-concurrent-b 'Add a dedicated recovery page' pid-origin-b
(run_pid create --input "$TMP_ROOT/pid-concurrent-a.json" > "$TMP_ROOT/a.out") &
pid_a=$!
(run_pid create --input "$TMP_ROOT/pid-concurrent-b.json" > "$TMP_ROOT/b.out") &
pid_b=$!
wait "$pid_a" || fail 'concurrent creator A failed'
wait "$pid_b" || fail 'concurrent creator B failed'
sort -u "$TMP_ROOT/a.out" "$TMP_ROOT/b.out" > "$TMP_ROOT/concurrent.out"
[ "$(wc -l < "$TMP_ROOT/concurrent.out" | tr -d ' ')" = 2 ] \
  || fail 'concurrent create calls reused a repository PID'
[ "$(jq -r '.last_id' "$PFA/data/product-decisions/.allocator.json")" = 3 ] \
  || fail 'allocator high-water mark did not persist the greatest ID'
concurrent_b_id=$(jq -r 'select(.request_key == "pid-concurrent-b") | .key' \
  "$PFA"/data/product-decisions/pid-*.json)
[ -n "$concurrent_b_id" ] || fail 'could not identify the second concurrent decision record'
pass 'concurrent creators serialize allocation without sharing a mutable decision log'

# A pending answer is a durable recovery journal before the guarded task transition.
printf 'Approved option A.\nKeep the fallback available while customer support handles edge cases.' > "$TMP_ROOT/answer.txt"
n=$(run_pid show pid-1 | jq -r '.id')
answer_digest=$(shasum -a 256 "$TMP_ROOT/answer.txt" | awk '{print $1}')
jq --rawfile answer "$TMP_ROOT/answer.txt" --arg digest "$answer_digest" \
  '.status="answer-pending" | .resolution={answer_verbatim:$answer,answer_digest:$digest,mode:"done",consequences:.consequences,answered_at:"2026-09-17T00:00:00Z"}' \
  "$PFA/data/product-decisions/pid-$n.json" > "$TMP_ROOT/pending.json"
mv "$TMP_ROOT/pending.json" "$PFA/data/product-decisions/pid-$n.json"
FM_HOME="$PFA" FM_ROOT_OVERRIDE="$ROOT" "$PID_SCRIPT" retry pid-1 > "$TMP_ROOT/retry.out" \
  || fail 'answer retry did not recover a durable answer-pending record'
grep -F 'PID-1 resolved; documentation sync queued' "$TMP_ROOT/retry.out" >/dev/null \
  || fail 'retry did not report answer plus queued docs sync'
final=$(run_pid show pid-1)
[ "$(printf '%s' "$final" | jq -r '.resolution.answer_verbatim')" = "$(cat "$TMP_ROOT/answer.txt")" ] \
  || fail 'captain answer did not survive byte-for-byte through a fresh process'
[ "$(printf '%s' "$final" | jq -r '.docs_sync.task_id')" = pid-docs-1 ] \
  || fail 'affected documentation did not produce its deterministic tracked docs task'
[ "$(FM_HOME="$CHILD" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-captain-hold.sh" open pid-origin >/dev/null 2>&1; echo $?)" = 1 ] \
  || fail 'answer transition did not resolve the existing held task'
grep -F 'resolved [key=pid-1-answer]' "$ROOT_HOME/state/alpha-pfa.status" >/dev/null \
  || fail 'concise project-decision summary did not reach the root parent channel'
resolved_replay=$(run_pid create --input "$TMP_ROOT/pid-create.json") \
  || fail 'resolved create replay stopped being idempotent after its source task closed'
[ "$resolved_replay" = PID-1 ] || fail 'resolved idempotent replay minted a replacement PID'
pass 'a later answer survives process restart, resolves through captain-hold, queues docs sync, and publishes upward'

# The create transaction is durable and resumes after interruption between reservation and record publish.
FM_HOME="$CHILD" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-tasks-axi.sh" add pid-origin-recovery "Confirm recovery copy" \
  --kind docs --repo alpha --start >/dev/null || fail 'could not create recovery fixture task'
FM_HOME="$CHILD" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-captain-hold.sh" hold pid-origin-recovery \
  --reason 'Captain needs to choose the recovery wording' >/dev/null || fail 'could not captain-hold recovery fixture task'
write_input pid-recovery 'Email confirmation' pid-origin-recovery
recovery_hash=$(printf pid-recovery | shasum -a 256 | awk '{print $1}')
mkdir -p "$PFA/data/product-decisions"
printf '{"schema":"fm-product-decision-create-txn.v1","request_key":"pid-recovery","request_digest":"%s","id":4,"created_at":"2026-09-17T00:00:00Z"}\n' \
  "$(jq -cS 'del(.request_key)' "$TMP_ROOT/pid-recovery.json" | shasum -a 256 | awk '{print $1}')" \
  > "$PFA/data/product-decisions/.create-$recovery_hash.json"
run_pid create --input "$TMP_ROOT/pid-recovery.json" > "$TMP_ROOT/recovered-create.out" \
  || fail 'create did not recover its unfinished transaction'
[ "$(cat "$TMP_ROOT/recovered-create.out")" = PID-4 ] \
  || fail 'unfinished create transaction did not keep its already-reserved ID'
[ -f "$PFA/data/product-decisions/pid-4.json" ] \
  || fail 'recovered create did not publish its independent record'
[ "$(jq -r '.last_id' "$PFA/data/product-decisions/.allocator.json")" = 4 ] \
  || fail 'recovered create did not advance its allocator past the reserved ID'
pass 'create recovers its durable reserved ID after an interrupted multi-artifact transition'

write_input pid-supersede 'Refine the recovery confirmation choice' pid-origin-b "$concurrent_b_id"
superseded_number=${concurrent_b_id#pid-}
superseded_lock="$PFA/data/product-decisions/.pid-$superseded_number.lock"
fm_lock_acquire_wait "$superseded_lock" || fail 'could not hold the predecessor PID lock'
(run_pid create --input "$TMP_ROOT/pid-supersede.json" > "$TMP_ROOT/pid-supersede.out") &
supersede_runner=$!
sleep 0.3
kill -0 "$supersede_runner" 2>/dev/null \
  || fail 'supersession did not wait for a concurrent predecessor answer lock'
[ ! -e "$PFA/data/product-decisions/pid-5.json" ] \
  || fail 'supersession published its successor before locking the predecessor'
[ "$(jq -r '.last_id' "$PFA/data/product-decisions/.allocator.json")" = 4 ] \
  || fail 'supersession allocated its successor before locking the predecessor'
fm_lock_release "$superseded_lock" || fail 'could not release the predecessor PID lock'
wait "$supersede_runner" || fail 'an explicit same-owner PID supersession failed'
superseding_pid=$(cat "$TMP_ROOT/pid-supersede.out")
[ "$superseding_pid" = PID-5 ] || fail "supersession did not allocate the next monotonic PID: $superseding_pid"
[ "$(jq -r '.status' "$PFA/data/product-decisions/$concurrent_b_id.json")" = superseded ] \
  || fail 'the predecessor PID remained open after its successor was published'
[ "$(jq -r '.superseded_by' "$PFA/data/product-decisions/$concurrent_b_id.json")" = pid-5 ] \
  || fail 'the predecessor did not preserve its successor identity'
[ "$(jq -r '.supersedes' "$PFA/data/product-decisions/pid-5.json")" = "$concurrent_b_id" ] \
  || fail 'the successor did not preserve its predecessor identity'
[ "$(jq -r '.amendment_history[0].kind' "$PFA/data/product-decisions/$concurrent_b_id.json")" = superseded ] \
  || fail 'the predecessor did not retain supersession history'
pass 'same-owner supersession preserves both records and durable amendment history'

# A real process-event capture routes a PID key through the owner-aware intake.
cat > "$TMP_ROOT/pid-board-result" <<'EOF'
prompts[1]{uid,prompt,selector,tag,text}:
  "1","Account recovery: confirm option B\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"alpha/pid-5\",\n  \"selection\": \"B\",\n  \"note\": \"Keep the support fallback visible\"\n}","section#call > form:nth-of-type(1)",choice,"Account recovery: confirm option B"
EOF
board_source='pid-product-answer'
FM_HOME="$ROOT_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-captain-hold.sh" bind "$board_source" >/dev/null \
  || fail 'could not bind the PID answer source'
FM_HOME="$ROOT_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$ROOT_HOME/state" \
  FM_DATA_OVERRIDE="$ROOT_HOME/data" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/event-claims" \
  "$ROOT/bin/fm-procevent.sh" register lavish "$board_source" -- cat "$TMP_ROOT/pid-board-result" >/dev/null \
  || fail 'could not register the PID answer source'
FM_HOME="$ROOT_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$ROOT_HOME/state" \
  FM_DATA_OVERRIDE="$ROOT_HOME/data" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/event-claims" \
  "$ROOT/bin/fm-procevent.sh" start "$board_source" > "$TMP_ROOT/pid-event.out" 2>&1 \
  || { cat "$TMP_ROOT/pid-event.out" >&2; fail 'captured owner-qualified PID answer did not reach its router'; }
grep -F "answers-fed: $board_source" "$TMP_ROOT/pid-event.out" >/dev/null \
  || { cat "$TMP_ROOT/pid-event.out" >&2; fail 'process-event runner did not report owner-aware answer intake success'; }
[ "$(jq -r '.resolution.answer_verbatim' "$PFA/data/product-decisions/pid-5.json")" = \
  'B: Keep the support fallback visible' ] \
  || fail 'captured PID answer did not preserve the selected option and typed note'
[ "$(jq -r '.status' "$PFA/data/product-decisions/pid-5.json")" = resolved ] \
  || { printf 'record: %s\nrunner: %s\n' "$(jq -c . "$PFA/data/product-decisions/pid-5.json")" "$(cat "$TMP_ROOT/pid-event.out")" >&2; fail 'captured PID answer did not update the authoritative record'; }
pass 'a public process-event capture routes a PID answer through the owner-qualified durable intake'

FM_HOME="$PFA" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-home-summary-refresh.sh" \
  || fail 'project Firstmate home summary refresh failed'
bearings=$(FM_HOME="$ROOT_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_BEARINGS_NOW=2026-09-17T12:00:00Z \
  "$ROOT/bin/fm-bearings-snapshot.sh" --json) || fail 'bounded Bearings snapshot failed'
printf '%s' "$bearings" | jq -e '
  any(.decisions_open[]; .key == "alpha/pid-4" and .verb == "product-decision"
    and .product_decision.options[1].cons[0] == "A person with device access may take over an account.")
' >/dev/null || { printf 'decision rows: %s\nsecondmate state: %s\n' "$(printf '%s' "$bearings" | jq -c '.decisions_open')" "$(printf '%s' "$bearings" | jq -c '.secondmates')" >&2; fail 'Bearings did not render a bounded PID card summary with option tradeoffs'; }
pass 'Bearings projects open PID decisions with user-language context and option tradeoffs'

cat > "$TMP_ROOT/board-result" <<'EOF'
prompts[2]{uid,prompt,selector,tag,text}:
  "1","Confirm the recommended option\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"alpha/pid-2\",\n  \"selection\": \"A\",\n  \"note\": \"Keep the support fallback visible\"\n}","section#call > form:nth-of-type(1)",choice,"A: Confirm by email"
  "2","Reconcile this call\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"alpha/pid-3\",\n  \"selection\": \"reconcile\",\n  \"note\": \"Check the updated customer interviews\"\n}","section#call > form:nth-of-type(2)",choice,"Reconcile"
EOF
board_answers=$(FM_HOME="$ROOT_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-procevent-lavish.sh" \
  answers "$TMP_ROOT/board-result") || fail 'PID board answer adapter failed'
[ "$board_answers" = "$(printf 'alpha/pid-2\tA: Keep the support fallback visible\tA: Confirm by email')" ] \
  || fail 'PID board answer adapter dropped the selection or captain note'
board_reconciles=$(FM_HOME="$ROOT_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-procevent-lavish.sh" \
  reconciles "$TMP_ROOT/board-result") || fail 'PID board reconcile adapter failed'
[ "$board_reconciles" = "$(printf 'alpha/pid-3\tCheck the updated customer interviews')" ] \
  || fail 'PID board reconcile adapter lost its owner-qualified key or note'
pass 'Lavish adapter preserves the PID option choice, exact captain note, and owner-qualified reconcile key'

FM_HOME="$ROOT_HOME" FM_ROOT_OVERRIDE="$ROOT" "$PID_SCRIPT" route-reconcile alpha/pid-4 \
  --source-id board-source-local --source 'captured Bearings board choice' >/dev/null \
  || fail 'repo-qualified reconcile did not reach the held task owner'
[ -f "$CHILD/state/reconcile-requests/pid-origin-recovery.request" ] \
  || fail 'repo-qualified reconcile request was not stored in the task-owning home'
[ ! -e "$ROOT_HOME/state/reconcile-requests/pid-origin-recovery.request" ] \
  || fail 'repo-qualified reconcile created an incorrect main-home request'
pass 'PID reconcile routes through owner binding and the guarded captain-hold request intake'

# The root routes a repo-qualified PID to the project authority, not to a duplicate main-home request.
printf 'Choose option B for the recovery wording.\nKeep the help link visible.' > "$TMP_ROOT/routed-answer.txt"
route_output=$(FM_HOME="$ROOT_HOME" FM_ROOT_OVERRIDE="$ROOT" "$PID_SCRIPT" route-answer alpha/pid-4 \
  --answer-file "$TMP_ROOT/routed-answer.txt" 2> "$TMP_ROOT/route.err") \
  || { cat "$TMP_ROOT/route.err" >&2; printf 'route output: %s\n' "$route_output" >&2; fail 'repo-qualified PID answer did not route to its authority home'; }
grep -F 'Answer delivered to alpha/pid-4.' <<< "$route_output" >/dev/null \
  || fail 'owner-aware route did not confirm the destination key'
[ "$(jq -r '.status' "$PFA/data/product-decisions/pid-4.json")" = resolved ] \
  || fail 'root routed answer did not update the authoritative PID record'
[ "$(jq -r '.resolution.answer_verbatim' "$PFA/data/product-decisions/pid-4.json")" = "$(cat "$TMP_ROOT/routed-answer.txt")" ] \
  || fail 'repo-qualified answer was not preserved verbatim at its owner'
[ "$(jq -r '.status' "$(find "$ROOT_HOME/state/product-decision-routes" -type f -name '*.json' -print -quit)")" = delivered ] \
  || fail 'root owner route did not durably record its delivered result'
if FM_HOME="$ROOT_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-tasks-axi.sh" show pid-origin-recovery --json >/dev/null 2>&1; then
  fail 'owner-qualified answer created a duplicate root-home backlog record'
fi
pass 'repo-qualified PID answers route to the authority home and retain durable delivery evidence'

# Remote secondmate delivery stays queued on transport loss and retries through the real guarded intake.
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
git clone --quiet --local "$ROOT" "$REMOTE_ROOT" || fail 'could not prepare tracked remote code root'
cp "$ROOT/bin/fm-product-decision.sh" "$REMOTE_ROOT/bin/fm-product-decision.sh"
mkdir -p "$REMOTE_HOME/data" "$REMOTE_HOME/state" "$REMOTE_HOME/config" "$REMOTE_HOME/projects"
cp "$ROOT/.tasks.toml" "$REMOTE_HOME/.tasks.toml"
cat > "$REMOTE_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
printf 'remote-owner\n' > "$REMOTE_HOME/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_role=root\nparent_host=portable-fake\n' \
  > "$REMOTE_HOME/.fm-secondmate-parent"
cat > "$REMOTE_ROOT/bin/tasks-axi" <<SH
#!/usr/bin/env bash
exec $(command -v tasks-axi) "\$@"
SH
chmod +x "$REMOTE_ROOT/bin/tasks-axi"
FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" "$REMOTE_ROOT/bin/fm-tasks-axi.sh" \
  add remote-held-task 'Remote account recovery' --kind ship --repo alpha --start >/dev/null \
  || fail 'could not create remote held task'
FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" "$REMOTE_ROOT/bin/fm-captain-hold.sh" \
  hold remote-held-task --reason 'Captain needs to decide the remote recovery behavior' >/dev/null \
  || fail 'could not hold remote task for the captain'
FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" "$REMOTE_ROOT/bin/fm-tasks-axi.sh" \
  add remote-pid-origin 'Implement the chosen account recovery flow' --kind ship --repo alpha --start >/dev/null \
  || fail 'could not create remote PID-origin task'
FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" "$REMOTE_ROOT/bin/fm-captain-hold.sh" \
  hold remote-pid-origin --reason 'Captain needs to choose the recovery experience' >/dev/null \
  || fail 'could not hold remote PID-origin task for the captain'
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\nparent_role=project-firstmate\nrepo_authority_home=%s\nrepo_authority_id=%s\nrepo_identity=%s\n' \
  "$PFA" "$PFA" "$authority_id" "$repo_identity" > "$REMOTE_HOME/.fm-secondmate-parent"
cat >> "$ROOT_HOME/data/secondmates.md" <<EOF
- remote-owner - Remote project work (host: portable-fake; root: $REMOTE_ROOT; home: $REMOTE_HOME; scope: alpha tasks; projects: alpha; added 2026-09-17)
EOF
cat >> "$PFA/data/secondmates.md" <<EOF
- remote-owner - Remote product decision steward (host: portable-fake; root: $REMOTE_ROOT; home: $REMOTE_HOME; scope: alpha tasks; projects: alpha; added 2026-09-17)
EOF
FAKE_SSH="$TMP_ROOT/fake-ssh"
cat > "$FAKE_SSH" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
host=$1
entry=$2
shift 2
[ "$host" = portable-fake ] && [ "$entry" = fm-remote-entrypoint.sh ] || exit 91
if [ "${FM_TEST_SSH_MODE:-offline}" = offline ]; then exit 255; fi
exec "$FM_TEST_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKE_SSH"
write_input pid-remote-owner 'Remote steward recovery flow' remote-pid-origin
remote_pid=$(FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$PID_SCRIPT" create \
  --input "$TMP_ROOT/pid-remote-owner.json") || fail 'remote steward could not create its authority-home PID'
[ "$remote_pid" = PID-6 ] || fail "remote steward received unexpected PID: $remote_pid"
FM_HOME="$ROOT_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$FAKE_SSH" \
  FM_TEST_SSH_MODE=offline FM_TEST_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  "$PID_SCRIPT" route-reconcile alpha/pid-6 --source-id board-source-remote-pid \
  --source 'captured remote PID reconcile selection' > "$TMP_ROOT/remote-pid-reconcile.out" \
  || fail 'offline repo-qualified PID reconcile did not stay durably queued'
grep -F 'durably queued for alpha/pid-6' "$TMP_ROOT/remote-pid-reconcile.out" >/dev/null \
  || fail 'offline PID reconcile did not report its durable owner route'
remote_pid_reconcile_id=$(printf '%s\n%s\n%s' reconcile alpha/pid-6 board-source-remote-pid \
  | shasum -a 256 | awk '{print $1}')
remote_pid_reconcile_file="$ROOT_HOME/state/product-decision-routes/$remote_pid_reconcile_id.json"
[ "$(jq -r '.status' "$remote_pid_reconcile_file")" = pending ] \
  || fail 'offline remote PID reconcile did not retain its route journal'
[ ! -e "$ROOT_HOME/state/reconcile-requests/remote-pid-origin.request" ] \
  || fail 'remote PID reconcile created an incorrect root-home request'
FM_HOME="$ROOT_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$FAKE_SSH" \
  FM_TEST_SSH_MODE=online FM_TEST_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  "$PID_SCRIPT" retry-routes >/dev/null || fail 'remote PID reconcile retry did not reach its task owner'
[ -f "$REMOTE_HOME/state/reconcile-requests/remote-pid-origin.request" ] \
  || fail 'remote PID reconcile retry did not create its request in the owning home'
[ "$(jq -r '.status' "$remote_pid_reconcile_file")" = delivered ] \
  || fail 'remote PID reconcile route did not record delivery after recovery'
printf 'Choose option B for the remote flow.\nKeep the help link visible.' > "$TMP_ROOT/remote-pid-answer.txt"
FM_HOME="$ROOT_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$FAKE_SSH" \
  FM_TEST_SSH_MODE=offline FM_TEST_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  "$PID_SCRIPT" route-answer alpha/pid-6 --answer-file "$TMP_ROOT/remote-pid-answer.txt" \
  > "$TMP_ROOT/remote-pid-answer.out" || fail 'offline PID answer did not reach and persist at its local repository authority'
grep -F 'durably queued for alpha/pid-6' "$TMP_ROOT/remote-pid-answer.out" >/dev/null \
  || fail 'root did not distinguish authority receipt from pending remote-owner delivery'
[ "$(jq -r '.status' "$PFA/data/product-decisions/pid-6.json")" = answer-pending ] \
  || fail 'remote PID answer did not remain pending until its steward received it'
remote_pid_digest=$(shasum -a 256 "$TMP_ROOT/remote-pid-answer.txt" | awk '{print $1}')
remote_pid_route=$(printf '%s\n%s\nrelease' remote-owner/remote-pid-origin "$remote_pid_digest" \
  | shasum -a 256 | awk '{print $1}')
[ "$(jq -r '.status' "$PFA/state/product-decision-routes/$remote_pid_route.json")" = pending ] \
  || fail 'remote steward answer was not durably queued at the authority home'
remote_pid_root_route=$(printf '%s\n%s\nowner-default' alpha/pid-6 "$remote_pid_digest" \
  | shasum -a 256 | awk '{print $1}')
[ "$(jq -r '.status' "$ROOT_HOME/state/product-decision-routes/$remote_pid_root_route.json")" = pending ] \
  || fail 'root route journal falsely claimed the PID was fully delivered'
FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" "$REMOTE_ROOT/bin/fm-captain-hold.sh" \
  open remote-pid-origin >/dev/null 2>&1 \
  || fail 'offline PID answer mutated the remote captain hold before recovery'
FM_HOME="$PFA" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$FAKE_SSH" \
  FM_TEST_SSH_MODE=online FM_TEST_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  "$PID_SCRIPT" retry-routes > "$TMP_ROOT/remote-pid-retry.out" \
  || fail 'authority-home route recovery did not finalize the remote steward PID'
[ "$(jq -r '.status' "$PFA/data/product-decisions/pid-6.json")" = resolved ] \
  || fail 'remote steward delivery did not finalize its durable PID record'
FM_HOME="$ROOT_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$FAKE_SSH" \
  FM_TEST_SSH_MODE=online FM_TEST_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  "$PID_SCRIPT" retry-routes >/dev/null \
  || fail 'root route receipt did not recover after the authority completed remote steward delivery'
[ "$(jq -r '.status' "$ROOT_HOME/state/product-decision-routes/$remote_pid_root_route.json")" = delivered ] \
  || fail 'root route retry did not record completed steward delivery'
[ "$(FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" "$REMOTE_ROOT/bin/fm-captain-hold.sh" \
  open remote-pid-origin >/dev/null 2>&1; echo $?)" = 1 ] \
  || fail 'remote PID answer did not resolve through the actual steward captain-hold intake'
[ ! -e "$REMOTE_HOME/state/reconcile-requests/remote-pid-origin.request" ] \
  || fail 'remote PID answer did not retire the outstanding reconcile request in its owner home'
grep -F 'resolved [key=pid-6-answer]' "$ROOT_HOME/state/alpha-pfa.status" >/dev/null \
  || fail 'remote steward resolution did not return a concise parent summary'
FM_HOME="$ROOT_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$FAKE_SSH" \
  FM_TEST_SSH_MODE=offline FM_TEST_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  "$PID_SCRIPT" route-reconcile remote-owner/remote-held-task --source-id board-source-remote \
  --source 'captured remote Bearings board choice' > "$TMP_ROOT/remote-reconcile-queued.out" \
  || fail 'offline remote reconcile did not remain durably queued'
grep -F 'durably queued for remote-owner/remote-held-task' "$TMP_ROOT/remote-reconcile-queued.out" >/dev/null \
  || fail 'offline remote reconcile did not report durable queuing'
remote_reconcile_digest=$(printf '%s\n%s\n%s' reconcile remote-owner/remote-held-task board-source-remote \
  | shasum -a 256 | awk '{print $1}')
remote_reconcile_file="$ROOT_HOME/state/product-decision-routes/$remote_reconcile_digest.json"
FM_HOME="$ROOT_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$FAKE_SSH" \
  FM_TEST_SSH_MODE=online FM_TEST_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  "$PID_SCRIPT" retry-routes > "$TMP_ROOT/retry-routes.out" \
  || fail 'remote reconcile retry did not recover after the remote came online'
[ -f "$REMOTE_HOME/state/reconcile-requests/remote-held-task.request" ] \
  || fail 'remote reconcile retry did not create its request in the remote owning home'
[ "$(jq -r '.status' "$remote_reconcile_file")" = delivered ] \
  || fail 'remote reconcile route retry did not persist its delivered result'
printf 'Release the captain-held task after adopting option B.\nThe answer must survive the offline window.' > "$TMP_ROOT/remote-answer.txt"
queued=$(FM_HOME="$ROOT_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$FAKE_SSH" \
  FM_TEST_SSH_MODE=offline FM_TEST_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  "$PID_SCRIPT" route-answer remote-owner/remote-held-task --release \
  --answer-file "$TMP_ROOT/remote-answer.txt") || fail 'offline remote answer did not remain durably queued'
grep -F 'durably queued for remote-owner/remote-held-task' <<< "$queued" >/dev/null \
  || fail 'offline remote result did not explain the queued recovery path'
remote_digest=$(shasum -a 256 "$TMP_ROOT/remote-answer.txt" | awk '{print $1}')
remote_route_id=$(printf '%s\n%s\nrelease' remote-owner/remote-held-task "$remote_digest" \
  | shasum -a 256 | awk '{print $1}')
route_file="$ROOT_HOME/state/product-decision-routes/$remote_route_id.json"
[ "$(jq -r '.status' "$route_file")" = pending ] \
  || fail 'offline route did not persist its exact pending answer'
[ "$(FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" "$REMOTE_ROOT/bin/fm-captain-hold.sh" open remote-held-task >/dev/null 2>&1; echo $?)" = 0 ] \
  || fail 'offline route mutated the remote captain hold before transport recovery'
FM_HOME="$ROOT_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$FAKE_SSH" \
  FM_TEST_SSH_MODE=online FM_TEST_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  "$PID_SCRIPT" retry-routes > "$TMP_ROOT/retry-routes.out" \
  || fail 'owner route answer retry did not recover after the remote came online'
[ "$(jq -r '.status' "$route_file")" = delivered ] \
  || fail 'remote answer retry did not durably mark the result delivered'
[ "$(FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" "$REMOTE_ROOT/bin/fm-captain-hold.sh" open remote-held-task >/dev/null 2>&1; echo $?)" = 1 ] \
  || fail 'remote retry did not resolve through the owner home captain-hold intake'
pass 'remote answer and reconcile requests queue offline, retry through fm-on, and update the owning home'
