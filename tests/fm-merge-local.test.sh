#!/usr/bin/env bash
# Behavioral checks for guarded local continuation landings and reconciliation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-merge-local)
FAKE_ROOT="$TMP_ROOT/root"
mkdir -p "$FAKE_ROOT/bin"
ln -s "$ROOT/bin/fm-guard.sh" "$FAKE_ROOT/bin/fm-guard.sh"

make_case() { # <name>
  local name=$1 home="$TMP_ROOT/$1/home" project="$TMP_ROOT/$1/project" id="task-$1"
  mkdir -p "$home/state" "$home/data"
  fm_git_init_commit "$project"
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" add "$id" "Local merge $name" \
    --kind ship --body "Local merge fixture $name." --start >/dev/null || fail "could not create $name task"
  fm_write_meta "$home/state/$id.meta" "project=$project" 'mode=local-only' 'spawn_gen=g-one'
  git -C "$project" checkout -qb "fm/$id"
  printf '%s first\n' "$name" >> "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm first
  git -C "$project" checkout -q main
}

add_candidate() { # <project> <id> <label>
  local project=$1 id=$2 label=$3
  git -C "$project" checkout -q "fm/$id"
  printf '%s\n' "$label" >> "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$label"
  git -C "$project" checkout -q main
}

run_merge() { # <home> <id>
  FM_HOME="$1" FM_ROOT_OVERRIDE="$FAKE_ROOT" "$ROOT/bin/fm-merge-local.sh" "$2"
}

test_descendant_landings_and_retry() {
  local name=sequence home="$TMP_ROOT/sequence/home" project="$TMP_ROOT/sequence/project" id=task-sequence
  local first second out rows
  make_case "$name"
  first=$(git -C "$project" rev-parse "fm/$id")
  out=$(run_merge "$home" "$id" 2>&1) || fail "first local landing failed: $out"
  assert_equals "$first" "$(git -C "$project" rev-parse main)" 'first landing missed the candidate'
  jq -e --arg head "$first" --arg source "refs/heads/fm/$id" \
    'select(.head==$head and .source==$source)' "$home/state/$id.merge-receipts.jsonl" >/dev/null \
    || fail 'first landing did not record its exact source and head'

  out=$(run_merge "$home" "$id" 2>&1) || fail "identical local retry failed: $out"
  rows=$(wc -l < "$home/state/$id.merge-receipts.jsonl" | tr -d ' ')
  assert_equals 1 "$rows" 'identical retry duplicated its receipt'

  add_candidate "$project" "$id" second
  second=$(git -C "$project" rev-parse "fm/$id")
  out=$(run_merge "$home" "$id" 2>&1) || fail "descendant local landing failed: $out"
  assert_equals "$second" "$(git -C "$project" rev-parse main)" 'descendant landing missed the candidate'
  rows=$(wc -l < "$home/state/$id.merge-receipts.jsonl" | tr -d ' ')
  assert_equals 2 "$rows" 'descendant landing did not preserve both receipts'
  sed -n '1p' "$home/state/$id.merge-receipts.jsonl" | jq -e --arg head "$first" '.head==$head' >/dev/null \
    || fail 'descendant landing rewrote first-landing evidence'
  FM_HOME="$home" bash -c '. "$1"; fm_merge_receipt_current "$2" "$3"' \
    _ "$ROOT/bin/fm-merge-receipt-lib.sh" "$id" g-one | jq -e --arg head "$second" '.head==$head' >/dev/null \
    || fail 'current receipt did not resolve to the newest same-target landing'
  pass 'local merge records first and descendant landings and deduplicates identical retries'
}

test_landed_effect_reconciliation() {
  local name=reconcile home="$TMP_ROOT/reconcile/home" project="$TMP_ROOT/reconcile/project" id=task-reconcile
  local candidate before out
  make_case "$name"
  run_merge "$home" "$id" >/dev/null 2>&1 || fail 'reconciliation first landing failed'
  jq -c 'del(.source)' "$home/state/$id.merge-receipts.jsonl" > "$home/state/$id.merge-receipts.jsonl.tmp"
  mv "$home/state/$id.merge-receipts.jsonl.tmp" "$home/state/$id.merge-receipts.jsonl"
  add_candidate "$project" "$id" interrupted
  candidate=$(git -C "$project" rev-parse "fm/$id")
  git -C "$project" merge --ff-only "$candidate" >/dev/null || fail 'could not seed landed-unreceipted effect'
  before=$(git -C "$project" rev-parse main)
  out=$(run_merge "$home" "$id" 2>&1) || fail "landed effect did not reconcile: $out"
  assert_equals "$before" "$(git -C "$project" rev-parse main)" 'reconciliation changed an already landed target'
  jq -se --arg head "$candidate" '[.[] | select(.head==$head)] | length==1' \
    "$home/state/$id.merge-receipts.jsonl" >/dev/null || fail 'reconciliation did not record the read-back effect once'
  pass 'local merge reconciles a landed descendant only after exact target and source readback'
}

test_identity_and_lineage_changes_refuse_before_effect() {
  local name=identity home="$TMP_ROOT/identity/home" project="$TMP_ROOT/identity/project" id=task-identity
  local before out status url first sibling
  make_case "$name"
  run_merge "$home" "$id" >/dev/null 2>&1 || fail 'identity first landing failed'
  first=$(git -C "$project" rev-parse main)
  add_candidate "$project" "$id" incompatible
  before=$(git -C "$project" rev-parse main)
  url="local:$project#main"
  jq -cn --arg id "$id" --arg url "$url" --arg head "$first" \
    '{schema:"fm-merge-receipt.v1",task_id:$id,execution_generation:"g-one",url:$url,
      source:"refs/heads/fm/another-task",head:$head}' >> "$home/state/$id.merge-receipts.jsonl"
  out=$(run_merge "$home" "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail 'changed source identity was accepted'
  assert_contains "$out" 'incompatible local merge receipt identity' 'changed source refusal lost its reason'
  assert_equals "$before" "$(git -C "$project" rev-parse main)" 'changed source mutated the target before refusal'

  sed -i '$d' "$home/state/$id.merge-receipts.jsonl"
  jq -cn --arg id "$id" --arg head "$first" \
    '{schema:"fm-merge-receipt.v1",task_id:$id,execution_generation:"g-one",
      url:"local:/different/project#main",source:("refs/heads/fm/"+$id),head:$head}' \
    >> "$home/state/$id.merge-receipts.jsonl"
  out=$(run_merge "$home" "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail 'changed target identity was accepted'
  assert_equals "$before" "$(git -C "$project" rev-parse main)" 'changed target mutated the project before refusal'

  sed -i '$d' "$home/state/$id.merge-receipts.jsonl"
  git -C "$project" checkout -qb incompatible-history 'main^'
  printf 'sibling\n' >> "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm sibling
  sibling=$(git -C "$project" rev-parse HEAD)
  git -C "$project" checkout -q main
  jq -cn --arg id "$id" --arg url "$url" --arg head "$sibling" \
    '{schema:"fm-merge-receipt.v1",task_id:$id,execution_generation:"g-one",url:$url,
      source:("refs/heads/fm/"+$id),head:$head}' >> "$home/state/$id.merge-receipts.jsonl"
  out=$(run_merge "$home" "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail 'candidate unrelated to prior landing was accepted'
  assert_contains "$out" 'does not continue every prior landing' 'lineage refusal lost its reason'
  assert_equals "$before" "$(git -C "$project" rev-parse main)" 'lineage refusal changed the target'
  pass 'local merge refuses changed source, target, or prior-landing lineage before mutation'
}

test_generation_dirty_and_non_ff_boundaries() {
  local name=generation home="$TMP_ROOT/generation/home" project="$TMP_ROOT/generation/project" id=task-generation
  local candidate before out status
  make_case "$name"
  run_merge "$home" "$id" >/dev/null 2>&1 || fail 'generation first landing failed'
  add_candidate "$project" "$id" new-generation
  sed -i 's/^spawn_gen=.*/spawn_gen=g-two/' "$home/state/$id.meta"
  candidate=$(git -C "$project" rev-parse "fm/$id")
  out=$(run_merge "$home" "$id" 2>&1) || fail "new generation landing failed: $out"
  jq -se --arg head "$candidate" '[.[] | select(.execution_generation=="g-two" and .head==$head)] | length==1' \
    "$home/state/$id.merge-receipts.jsonl" >/dev/null || fail 'new generation reused the old receipt identity'

  add_candidate "$project" "$id" dirty-candidate
  before=$(git -C "$project" rev-parse main)
  printf 'dirty\n' > "$project/untracked"
  out=$(run_merge "$home" "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail 'dirty target was merged'
  assert_equals "$before" "$(git -C "$project" rev-parse main)" 'dirty refusal changed the target'
  rm "$project/untracked"

  printf 'main divergence\n' >> "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm divergence
  before=$(git -C "$project" rev-parse main)
  out=$(run_merge "$home" "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail 'non-fast-forward candidate was merged'
  assert_contains "$out" 'is not a fast-forward' 'non-fast-forward refusal lost its reason'
  assert_equals "$before" "$(git -C "$project" rev-parse main)" 'non-fast-forward refusal changed the target'
  pass 'local merge binds new generations independently and preserves dirty and non-FF guards'
}

test_descendant_landings_and_retry
test_landed_effect_reconciliation
test_identity_and_lineage_changes_refuse_before_effect
test_generation_dirty_and_non_ff_boundaries
