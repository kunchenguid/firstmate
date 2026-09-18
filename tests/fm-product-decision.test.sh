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
  local request_key=$1 title=${2:-"Email confirmation"} task=${3:-pid-origin}
  cat > "$TMP_ROOT/$request_key.json" <<EOF
{
  "schema": "fm-product-decision-input.v1",
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
write_input pid-concurrent-a 'Use the existing account settings page'
write_input pid-concurrent-b 'Add a dedicated recovery page'
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
pass 'create recovers its durable reserved ID after an interrupted multi-artifact transition'

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
pass 'repo-qualified PID answers route to the authority home and retain durable delivery evidence'
