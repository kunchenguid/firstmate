#!/usr/bin/env bash
# Behavior tests for the private model-attempt ledger owner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TELEMETRY="$ROOT/bin/fm-model-telemetry.sh"
TMP_ROOT=$(fm_test_tmproot fm-model-telemetry)
CANDIDATE_NOW=2026-08-02T12:00:00Z

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

intake_payload() {
  local model=${1:-gpt-5} effort=${2:-high} root=${3:-} parent=${4:-}
  jq -cn --arg model "$model" --arg effort "$effort" --arg root "$root" --arg parent "$parent" '{attemptClass:"real",source:"firstmate",taskRootId:(if $root=="" then null else $root end),parentAttemptId:(if $parent=="" then null else $parent end),projectRef:"project_0123456789abcdef",taskClass:"bounded-implementation-proven-root-fix",tuple:{harness:"codex",provider:"openai",model:$model,effort:$effort,modelVersion:$model,cliVersion:"codex-cli 1.2.3"},selection:{matchedRule:"rule-1",configSha256:"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",fitReasons:["task-class"],candidateAssessments:[{tuple:{harness:"codex",provider:"openai",model:$model,effort:$effort,modelVersion:$model,cliVersion:"codex-cli 1.2.3"},eligibility:"selected",reasons:["class-fit"]}],quota:{decision:"selected",headroom:"sufficient",runway:"sufficient",observedAt:"2026-08-02T00:00:00Z"}},neutralExecution:{correlation:null,capabilityProfile:"not-applicable",owner:"not-applicable",phase:null,behavioralResult:"not-applicable"},evaluation:{kind:"none",fixtureId:null,fixtureManifestSha256:null,oracleId:null,oracleSha256:null,sourceCommit:null},startedAt:"2026-08-02T00:00:00Z",privacy:{classification:"operational-minimized",contentPolicy:"ids-codes-hashes-bounded-evidence-only"}}'
}

terminal_payload() {
  local classification=$1 quality=${2:-not-applicable} failure=${3:-none}
  jq -cn --arg classification "$classification" --arg quality "$quality" --arg failure "$failure" '{classification:$classification,refusalQuality:$quality,endedAt:"2026-08-02T00:01:00Z",wallSeconds:60,firstPassAccepted:($classification=="accepted"),correctionCount:0,interventionCount:0,evidence:{tests:(if $classification=="accepted" then "pass" else "fail" end),reviewer:"not-run",oracle:"not-run",refs:[{kind:"test",id:"focused-suite"}]},outcomeLink:{kind:"commit",id:"0123456789abcdef"},usage:{inputTokens:null,outputTokens:null,cost:null,currency:null},primaryFailureClass:$failure,flags:{tool:false,transport:false,environment:false,externalWait:false,scopeChange:false,quota:($classification=="quota-stopped")},reclassification:{fromTaskClass:null,toTaskClass:null,reasonCodes:["none"],escalated:false}}'
}

exploration_intake_payload() {
  intake_payload "$@" | jq -c '. + {exploration:{kind:"deliberate",machineCondition:{observedAt:"2026-08-02T00:00:00Z",loadAverage1m:7.25,logicalCpuCount:12}}}'
}

terminal_facts_payload() {
  local result=$1 reruns=$2 cost=${3:-null} currency=${4:-null}
  jq -cn --arg result "$result" --argjson reruns "$reruns" --argjson cost "$cost" --argjson currency "$currency" '{gate:{source:"no-mistakes",result:$result,stepReruns:$reruns},outcomeLink:{kind:"commit",id:"0123456789abcdef"},usage:{inputTokens:null,outputTokens:null,cost:$cost,currency:$currency},wallSeconds:60}'
}

run_intake() {
  local home=$1 task=$2 payload=$3
  FM_HOME="$home" "$TELEMETRY" intake --state "$home/state" --task "$task" --payload "$payload"
}

test_terminals_and_retry_links() {
  local home result attempt root retry terminal row spec
  home=$(make_home terminals)
  result=$(run_intake "$home" accepted-a "$(intake_payload)") || fail "accepted intake failed"
  [ "$(file_mode "$home/data/routing-outcomes.jsonl")" = 600 ] || fail "model telemetry ledger is not private"
  attempt=$(printf '%s' "$result" | jq -r .attemptId)
  root=$(printf '%s' "$result" | jq -r .taskRootId)
  terminal=$(terminal_payload accepted not-applicable none)
  FM_HOME="$home" "$TELEMETRY" terminal --state "$home/state" --task accepted-a --payload "$terminal" >/dev/null || fail "accepted terminal failed"
  row=$(tail -n 1 "$home/data/routing-outcomes.jsonl")
  printf '%s' "$row" | jq -e '.terminal.classification=="accepted" and .terminal.evidence.tests=="pass" and .terminal.evidence.refs[0].id=="focused-suite"' >/dev/null || fail "accepted terminal lost evidence"

  for spec in 'failed:not-applicable:capability' 'refused:compliant:refusal' 'refused:noncompliant:refusal' 'timed-out:not-applicable:timeout' 'quota-stopped:not-applicable:quota' 'cancelled:not-applicable:unknown'; do
    IFS=: read -r classification quality failure <<< "$spec"
    run_intake "$home" "case-$classification-$quality" "$(intake_payload)" >/dev/null || fail "$classification intake failed"
    FM_HOME="$home" "$TELEMETRY" terminal --state "$home/state" --task "case-$classification-$quality" --payload "$(terminal_payload "$classification" "$quality" "$failure")" >/dev/null || fail "$classification terminal failed"
  done

  retry=$(run_intake "$home" retry-b "$(intake_payload gpt-5.6-sol xhigh "$root" "$attempt")") || fail "linked retry intake failed"
  printf '%s' "$retry" | jq -e --arg root "$root" '.taskRootId==$root and .attemptId!=null' >/dev/null || fail "retry did not retain task root"
  jq -e --arg parent "$attempt" 'select(.eventType=="attempt-intake" and .intake.parentAttemptId==$parent and .intake.tuple.model=="gpt-5.6-sol" and .intake.tuple.effort=="xhigh")' "$home/data/routing-outcomes.jsonl" >/dev/null || fail "retry linkage was not recorded"
  pass "model telemetry records explicit outcomes, refusal quality, evidence, and linked model/effort retries"
}

test_crash_recovery_and_terminal_idempotency() {
  local home payload receipt attempt result terminal before after rc
  home=$(make_home recovery)
  payload=$(intake_payload)
  set +e
  FM_MODEL_TELEMETRY_TEST_CRASH=after-receipt run_intake "$home" crash-before "$payload" >/dev/null 2>&1
  rc=$?
  expect_code 86 "$rc" "after-receipt crash seam"
  receipt="$home/state/model-telemetry-receipts/crash-before.json"
  attempt=$(jq -r .attemptId "$receipt")
  [ "$(file_mode "$receipt")" = 600 ] || fail "recovery receipt is not private"
  [ "$(file_mode "${receipt%/*}")" = 700 ] || fail "recovery receipt directory is not private"
  [ ! -e "$home/data/routing-outcomes.jsonl" ] || fail "before-append crash wrote a ledger row"
  result=$(run_intake "$home" crash-before "$payload") || fail "before-append replay failed"
  [ "$(printf '%s' "$result" | jq -r .attemptId)" = "$attempt" ] || fail "prepared receipt replay changed attempt id"

  set +e
  FM_MODEL_TELEMETRY_TEST_CRASH=after-append run_intake "$home" crash-after "$payload" >/dev/null 2>&1
  rc=$?
  expect_code 87 "$rc" "after-append crash seam"
  attempt=$(jq -r .attemptId "$home/state/model-telemetry-receipts/crash-after.json")
  result=$(run_intake "$home" crash-after "$payload") || fail "after-append replay failed"
  [ "$(printf '%s' "$result" | jq -r .status)" = duplicate ] || fail "after-append replay was not idempotent"
  [ "$(jq -s --arg a "$attempt" 'map(select(.eventType=="attempt-intake" and .attemptId==$a))|length' "$home/data/routing-outcomes.jsonl")" -eq 1 ] || fail "after-append replay duplicated intake"

  terminal=$(terminal_payload failed not-applicable capability)
  FM_HOME="$home" "$TELEMETRY" terminal --state "$home/state" --task crash-after --payload "$terminal" >/dev/null || fail "first terminal failed"
  before=$(wc -l < "$home/data/routing-outcomes.jsonl")
  result=$(FM_HOME="$home" "$TELEMETRY" terminal --state "$home/state" --task crash-after --attempt "$attempt" --payload "$terminal") || fail "identical terminal replay failed"
  [ "$(printf '%s' "$result" | jq -r .status)" = duplicate ] || fail "identical terminal was not duplicate"
  after=$(wc -l < "$home/data/routing-outcomes.jsonl")
  [ "$before" -eq "$after" ] || fail "identical terminal replay appended a row"
  if FM_HOME="$home" "$TELEMETRY" terminal --state "$home/state" --task crash-after --attempt "$attempt" --payload "$(terminal_payload accepted)" >/dev/null 2>&1; then
    fail "conflicting terminal was accepted"
  fi
  pass "model telemetry receipts recover both intake crash windows and terminals are conflict-safe"
}

test_relaunch_supersedes_stale_receipt() {
  local home ledger first second third attempt root relaunch_attempt repeat_attempt
  home=$(make_home relaunch)
  ledger="$home/data/routing-outcomes.jsonl"
  first=$(run_intake "$home" relaunch-a "$(intake_payload gpt-5 high)") || fail "first intake failed"
  attempt=$(printf '%s' "$first" | jq -r .attemptId)
  root=$(printf '%s' "$first" | jq -r .taskRootId)

  second=$(run_intake "$home" relaunch-a "$(intake_payload gpt-5.6-sol xhigh)") || fail "stale receipt locked out relaunch"
  relaunch_attempt=$(printf '%s' "$second" | jq -r .attemptId)
  [ "$relaunch_attempt" != "$attempt" ] || fail "relaunch reused the superseded attempt id"
  [ "$(printf '%s' "$second" | jq -r .taskRootId)" = "$root" ] || fail "relaunch left its task root"
  jq -e --arg a "$relaunch_attempt" --arg p "$attempt" 'select(.eventType=="attempt-intake" and .attemptId==$a and .intake.parentAttemptId==$p)' "$ledger" >/dev/null || fail "relaunch did not link to the superseded attempt"
  jq -e --arg a "$attempt" 'select(.eventType=="attempt-terminal" and .attemptId==$a and .terminal.classification=="incomplete" and .terminal.endedAt==null and .terminal.wallSeconds==null)' "$ledger" >/dev/null || fail "superseded attempt was left open forever"

  third=$(run_intake "$home" relaunch-a "$(intake_payload gpt-5.6-sol xhigh)") || fail "identical relaunch was locked out"
  repeat_attempt=$(printf '%s' "$third" | jq -r .attemptId)
  [ "$repeat_attempt" != "$relaunch_attempt" ] || fail "recorded receipt folded a relaunch into the previous attempt"
  [ "$(printf '%s' "$third" | jq -r .status)" = recorded ] || fail "relaunch did not record its own intake"
  [ "$(jq -s --arg r "$root" 'map(select(.eventType=="attempt-intake" and .intake.taskRootId==$r))|length' "$ledger")" -eq 3 ] || fail "relaunch chain lost an intake"
  [ "$(jq -s 'map(select(.eventType=="attempt-terminal"))|length' "$ledger")" -eq 2 ] || fail "relaunch chain left a superseded attempt unsealed"

  FM_HOME="$home" "$TELEMETRY" terminal --state "$home/state" --task relaunch-a --payload "$(terminal_payload accepted)" >/dev/null || fail "relaunched attempt could not record its own terminal"
  jq -e --arg a "$repeat_attempt" 'select(.eventType=="attempt-terminal" and .attemptId==$a and .terminal.classification=="accepted")' "$ledger" >/dev/null || fail "relaunched attempt lost its terminal outcome"
  pass "a stale receipt never locks out relaunch: every relaunch seals the prior attempt and records its own linked attempt"
}

test_reseal_after_explicit_terminal_never_deadlocks() {
  local home ledger result attempt before after
  home=$(make_home reseal)
  ledger="$home/data/routing-outcomes.jsonl"
  result=$(run_intake "$home" reseal-a "$(intake_payload)") || fail "reseal intake failed"
  attempt=$(printf '%s' "$result" | jq -r .attemptId)
  FM_HOME="$home" "$TELEMETRY" terminal --state "$home/state" --task reseal-a --payload "$(terminal_payload accepted)" >/dev/null || fail "explicit terminal failed"
  before=$(wc -l < "$ledger")
  result=$(FM_HOME="$home" "$TELEMETRY" seal-or-incomplete --state "$home/state" --task reseal-a --attempt "$attempt") || fail "re-seal after an explicit terminal was refused"
  [ "$(printf '%s' "$result" | jq -r .status)" = duplicate ] || fail "re-seal did not report the recorded terminal as duplicate"
  after=$(wc -l < "$ledger")
  [ "$before" -eq "$after" ] || fail "re-seal appended a second terminal"
  jq -e --arg a "$attempt" 'select(.eventType=="attempt-terminal" and .attemptId==$a and .terminal.classification=="accepted")' "$ledger" >/dev/null || fail "re-seal replaced the explicit terminal"
  if FM_HOME="$home" "$TELEMETRY" seal-or-incomplete --state "$home/state" --task reseal-a --attempt "$attempt" --terminal-payload "$(terminal_payload failed not-applicable capability)" >/dev/null 2>&1; then
    fail "an explicit terminal payload contradicting a recorded terminal was accepted"
  fi
  pass "an implicit re-seal of a sealed attempt is a no-op while a contradicting explicit terminal still refuses"
}

test_caller_attempt_outranks_a_diverging_receipt() {
  local home receipt first second attempt_a attempt_b err
  home=$(make_home divergence)
  receipt="$home/state/model-telemetry-receipts/diverge-a.json"
  first=$(run_intake "$home" diverge-a "$(intake_payload)") || fail "first intake failed"
  attempt_a=$(printf '%s' "$first" | jq -r .attemptId)
  second=$(run_intake "$home" diverge-a "$(intake_payload gpt-5.6-sol xhigh)") || fail "relaunch intake failed"
  attempt_b=$(printf '%s' "$second" | jq -r .attemptId)
  [ "$(jq -r .attemptId "$receipt")" = "$attempt_b" ] || fail "receipt did not follow the relaunch"
  err=$(FM_HOME="$home" "$TELEMETRY" seal-or-incomplete --state "$home/state" --task diverge-a --attempt "$attempt_a" 2>&1 >/dev/null) ||
    fail "a receipt naming another attempt blocked the seal"
  assert_contains "$err" "$receipt" "the divergence warning did not name the receipt to inspect"
  [ ! -e "$receipt" ] || fail "the seal left a diverged receipt behind"

  home=$(make_home unreadable-receipt)
  receipt="$home/state/model-telemetry-receipts/unreadable-a.json"
  first=$(run_intake "$home" unreadable-a "$(intake_payload)") || fail "unreadable-receipt intake failed"
  attempt_a=$(printf '%s' "$first" | jq -r .attemptId)
  chmod 0644 "$receipt"
  err=$(FM_HOME="$home" "$TELEMETRY" seal-or-incomplete --state "$home/state" --task unreadable-a --attempt "$attempt_a" 2>&1 >/dev/null) ||
    fail "an unreadable receipt blocked the seal"
  assert_contains "$err" "$receipt" "the unreadable-receipt warning did not name the receipt"
  jq -e --arg a "$attempt_a" 'select(.eventType=="attempt-terminal" and .attemptId==$a and .terminal.classification=="incomplete")' "$home/data/routing-outcomes.jsonl" >/dev/null ||
    fail "the caller's attempt was not sealed"
  pass "a caller-supplied attempt outranks a diverging or unreadable receipt instead of blocking the seal"
}

test_missing_intake_requires_ledger_repair() {
  local home err rc
  home=$(make_home repair-route)
  run_intake "$home" repair-a "$(intake_payload)" >/dev/null || fail "repair-route intake failed"
  rm -f "$home/data/routing-outcomes.jsonl"
  set +e
  err=$(FM_HOME="$home" "$TELEMETRY" seal-or-incomplete --state "$home/state" --task repair-a 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "seal accepted an attempt whose intake row is gone"
  assert_contains "$err" "$home/data/routing-outcomes.jsonl" "seal refusal did not name the ledger to repair"
  assert_contains "$err" "restore that intake row" "seal refusal did not name the repair route"

  printf '%s\n' '{"legacy":true}' 'not-json' > "$home/data/routing-outcomes.jsonl"
  chmod 0600 "$home/data/routing-outcomes.jsonl"
  set +e
  err=$(FM_HOME="$home" "$TELEMETRY" seal-or-incomplete --state "$home/state" --task repair-a 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "seal accepted a malformed ledger"
  assert_contains "$err" "line 2" "malformed-row refusal did not name the line to repair"
  pass "a refused seal names the exact ledger path, line, and attempt an operator must repair"
}

test_validation_privacy_and_private_files() {
  local home payload huge rc ledger receipt_home result attempt
  home=$(make_home validation)
  payload=$(intake_payload)
  if run_intake "$home" unsafe/id "$payload" >/dev/null 2>&1; then fail "unsafe task id accepted"; fi
  if run_intake "$home" unsafe-root "$(printf '%s' "$payload" | jq -c '.taskRootId="mrt_../../secret"')" >/dev/null 2>&1; then fail "unsafe opaque root id accepted"; fi
  if run_intake "$home" unknown "$(printf '%s' "$payload" | jq -c '.prompt="secret"')" >/dev/null 2>&1; then fail "prohibited/unknown prompt field accepted"; fi
  # An explicit null is the one spelling of "no model was selected" (bin/fm-spawn.sh);
  # an empty string is not a second spelling of that sentinel and stays refused.
  result=$(run_intake "$home" unset-model "$(printf '%s' "$payload" | jq -c '.tuple.model=null')") || fail "new intake refused an explicit null model, the unset-model sentinel"
  attempt=$(printf '%s' "$result" | jq -r .attemptId)
  jq -e --arg attempt "$attempt" 'select(.eventType=="attempt-intake" and .attemptId==$attempt and .intake.tuple.model==null)' "$home/data/routing-outcomes.jsonl" >/dev/null \
    || fail "an explicit null model was not recorded verbatim as the unset sentinel"
  if run_intake "$home" empty-model "$(printf '%s' "$payload" | jq -c '.tuple.model=""')" >/dev/null 2>&1; then fail "new intake accepted an empty-string model instead of the null sentinel"; fi
  if run_intake "$home" missing-version "$(printf '%s' "$payload" | jq -c '.tuple.modelVersion=null')" >/dev/null 2>&1; then fail "new intake accepted a row without model version"; fi
  if run_intake "$home" missing-cli-version "$(printf '%s' "$payload" | jq -c '.tuple.cliVersion=null')" >/dev/null 2>&1; then fail "new intake accepted a row without CLI version"; fi
  if run_intake "$home" malformed '{' >/dev/null 2>&1; then fail "malformed payload accepted"; fi
  huge=$(printf '%070000d' 0)
  if run_intake "$home" huge "$(printf '%s' "$payload" | jq -c --arg huge "$huge" '.tuple.model=$huge')" >/dev/null 2>&1; then fail "oversized event accepted"; fi

  ledger="$home/data/routing-outcomes.jsonl"
  printf '%s\n' '{"legacy":true}' > "$ledger"
  chmod 0644 "$ledger"
  run_intake "$home" mode "$payload" >/dev/null || fail "a pre-existing world-readable ledger blocked intake"
  [ "$(file_mode "$ledger")" = 600 ] || fail "intake did not tighten the pre-existing ledger to 600"
  [ "$(sed -n '1p' "$ledger")" = '{"legacy":true}' ] || fail "tightening the ledger mode rewrote legacy bytes"
  rm -f "$ledger"
  ln -s "$home/elsewhere" "$ledger"
  if run_intake "$home" symlink "$payload" >/dev/null 2>&1; then fail "symlink ledger accepted"; fi
  rm -f "$ledger"
  printf '%s\n' 'not-json' > "$ledger"
  chmod 0600 "$ledger"
  set +e
  run_intake "$home" bad-ledger "$payload" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "malformed ledger row accepted"

  receipt_home=$(make_home receipt-mode)
  run_intake "$receipt_home" receipt-mode "$payload" >/dev/null || fail "receipt mode intake failed"
  chmod 0644 "$receipt_home/state/model-telemetry-receipts/receipt-mode.json"
  if FM_HOME="$receipt_home" "$TELEMETRY" seal-or-incomplete --state "$receipt_home/state" --task receipt-mode >/dev/null 2>&1; then
    fail "unsafe receipt mode accepted"
  fi
  receipt_home=$(make_home terminal-unknown)
  run_intake "$receipt_home" terminal-unknown "$payload" >/dev/null || fail "terminal unknown-field intake failed"
  if FM_HOME="$receipt_home" "$TELEMETRY" terminal --state "$receipt_home/state" --task terminal-unknown --payload "$(terminal_payload failed | jq -c '.conversation="secret"')" >/dev/null 2>&1; then
    fail "prohibited terminal content field accepted"
  fi
  pass "model telemetry rejects privacy fields, unknowns, oversize, unsafe ids, malformed rows, symlinks, and unsafe modes"
}

test_mechanical_quality_cost_and_exploration_projection() {
  local home result attempt ledger row sheet root retry retry_attempt md md_row
  home=$(make_home scoreboard)
  ledger="$home/data/routing-outcomes.jsonl"
  result=$(run_intake "$home" exploration-a "$(exploration_intake_payload gpt-5.6-sol low)") || fail "exploration intake failed"
  attempt=$(printf '%s' "$result" | jq -r .attemptId)
  root=$(printf '%s' "$result" | jq -r .taskRootId)
  FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task exploration-a --attempt "$attempt" \
    --payload "$(terminal_facts_payload green 2 10.101 '"USD"')" >/dev/null || fail "terminal facts failed"
  row=$(tail -n 1 "$ledger")
  printf '%s' "$row" | jq -e '
    .terminal.classification=="accepted" and .terminal.firstPassAccepted==false and
    .terminal.correctionCount==2 and .terminal.gateFacts=={source:"no-mistakes",result:"green",stepReruns:2} and
    .terminal.usage.cost==10.101 and .terminal.usage.currency=="USD" and
    .terminal.endedAt!=null and .terminal.wallSeconds==60
  ' >/dev/null || fail "terminal facts did not mechanically derive accepted-after-two-step-reruns quality and reported cost"
  if FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task invalid-prose --payload \
    "$(terminal_facts_payload green 0 | jq -c '.classification="accepted"')" >/dev/null 2>&1; then
    fail "terminal facts accepted a caller-authored classification"
  fi
  run_intake "$home" first-pass "$(intake_payload gpt-5.6-sol low)" >/dev/null || fail "first-pass intake failed"
  FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task first-pass \
    --payload "$(terminal_facts_payload green 0 0 '"USD"')" >/dev/null || fail "first-pass terminal facts failed"
  run_intake "$home" failed-gate "$(intake_payload gpt-5.6-sol low)" >/dev/null || fail "failed-gate intake failed"
  FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task failed-gate \
    --payload "$(terminal_facts_payload failed null)" >/dev/null || fail "failed-gate terminal facts failed"
  run_intake "$home" cancelled-gate "$(intake_payload gpt-5.6-sol low)" >/dev/null || fail "cancelled-gate intake failed"
  FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task cancelled-gate \
    --payload "$(terminal_facts_payload cancelled null)" >/dev/null || fail "cancelled-gate terminal facts failed"
  run_intake "$home" green-unknown-reruns "$(intake_payload gpt-5.6-sol low)" >/dev/null || fail "unknown-step-rerun intake failed"
  FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task green-unknown-reruns \
    --payload "$(terminal_facts_payload green null)" >/dev/null || fail "a green gate with an unreadable step-rerun count was refused"
  run_intake "$home" quota-wall "$(intake_payload gpt-5.6-sol low)" >/dev/null || fail "quota-stopped intake failed"
  FM_HOME="$home" "$TELEMETRY" terminal --state "$home/state" --task quota-wall \
    --payload "$(terminal_payload quota-stopped not-applicable quota)" >/dev/null || fail "quota-stopped terminal failed"
  retry=$(run_intake "$home" exploration-retry "$(exploration_intake_payload gpt-5.6-sol xhigh "$root" "$attempt")") || fail "rotated retry intake failed"
  retry_attempt=$(printf '%s' "$retry" | jq -r .attemptId)
  FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task exploration-retry \
    --payload "$(terminal_facts_payload green 0)" >/dev/null || fail "rotated retry terminal facts failed"
  run_intake "$home" caller-counted "$(intake_payload gpt-5.6-sol low)" >/dev/null || fail "caller-counted intake failed"
  FM_HOME="$home" "$TELEMETRY" terminal --state "$home/state" --task caller-counted \
    --payload "$(terminal_payload accepted | jq -c '.correctionCount=3|.firstPassAccepted=false')" >/dev/null || fail "caller-counted terminal failed"
  run_intake "$home" superseded "$(intake_payload gpt-5.6-sol low)" >/dev/null || fail "superseded intake failed"
  run_intake "$home" superseded "$(intake_payload gpt-5.6-sol low)" >/dev/null || fail "relaunch after supersession failed"
  sheet=$(FM_HOME="$home" "$TELEMETRY" sheet --format json) || fail "scoreboard sheet failed"
  printf '%s' "$sheet" | jq -e '
    .[0].exploration=="deliberate" and .[0].machineLoadAverage1m==7.25 and
    .[0].machineLogicalCpuCount==12 and .[0].quality=="accepted-after-step-reruns" and
    .[0].stepReruns==2 and .[0].gateSource=="no-mistakes" and .[0].wallSeconds==60 and
    .[0].costReported==true and .[0].cost==10.101 and .[0].currency=="USD" and
    .[0].costPerAcceptedDelivery==10.101 and
    .[1].quality=="accepted-first-pass" and .[1].stepReruns==0 and
    .[1].costReported==true and .[1].cost==0 and .[1].costPerAcceptedDelivery==0 and
    .[2].quality=="failed" and .[2].classification=="failed" and
    .[2].costReported==false and .[2].cost==null and .[2].costPerAcceptedDelivery==null and
    .[3].quality=="cancelled" and .[3].classification=="cancelled" and
    .[4].quality=="accepted-step-reruns-unknown" and .[4].classification=="accepted" and .[4].stepReruns==null and
    .[5].quality=="quota-stopped" and .[5].stepReruns==null and
    .[6].taskRootId==.[0].taskRootId and .[6].parentAttemptId==.[0].attemptId and
    .[7].classification=="accepted" and .[7].gateSource==null and
    .[7].stepReruns==null and .[7].quality=="accepted-step-reruns-unknown" and
    .[8].classification=="incomplete" and .[8].gateSource==null and .[8].stepReruns==null
  ' >/dev/null || fail "sheet collapsed a distinct outcome, lost an unknown step-rerun count, or reported a step-rerun count no delivery gate produced"

  # The markdown sheet is a generated read-only projection; parse its cells and
  # assert the rotated retry still shows which attempt and root it escalated from.
  md=$(FM_HOME="$home" "$TELEMETRY" sheet --format md) || fail "markdown sheet failed"
  md_row=$(printf '%s\n' "$md" | awk -F'|' -v a="$retry_attempt" '
    index($3, a) > 0 {
      for (i = 4; i <= 5; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
      print $4 "/" $5
      exit
    }')
  [ "$md_row" = "$root/$attempt" ] || fail "markdown sheet dropped the retry lineage columns for the rotated attempt"
  pass "mechanical gate facts, exploration load, distinct non-accepted outcomes, zero-versus-absent cost and step reruns, and markdown retry lineage stay comparable"
}

candidate_plan() {
  local minimum=${1:-6}
  jq -cn --argjson minimum "$minimum" '{method:"task-class-blocked",candidate:{harness:"codex",model:"gpt-5.6-luna",modelVersion:"gpt-5.6-luna",cliVersion:"codex-cli 1.2.3"},comparator:{harness:"codex",model:"gpt-5.6-sol",modelVersion:"gpt-5.6-sol",cliVersion:"codex-cli 1.2.3"},taskClasses:["bounded-implementation-proven-root-fix"],minimumPerModelClass:$minimum,window:{startedAt:"2026-08-01T00:00:00Z",endedAt:"2026-08-31T23:59:59Z"},rollbackCriteria:{metric:"accepted-first-pass-rate",operator:"below",threshold:0.8}}'
}

record_candidate_observation() {
  local home=$1 task=$2 model=$3 result=$4 reruns=$5
  FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" \
    run_intake "$home" "$task" "$(intake_payload "$model")" >/dev/null || fail "$task intake failed"
  FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task "$task" \
    --payload "$(terminal_facts_payload "$result" "$reruns")" >/dev/null || fail "$task terminal failed"
}

record_candidate_terminal_observation() {
  local home=$1 task=$2 model=$3 classification=$4 failure=$5 ended=${6:-2026-08-02T00:01:00Z} first_pass=${7:-false}
  FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" \
    run_intake "$home" "$task" "$(intake_payload "$model")" >/dev/null || fail "$task intake failed"
  FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" FM_HOME="$home" "$TELEMETRY" terminal \
    --state "$home/state" --task "$task" \
    --payload "$(terminal_payload "$classification" not-applicable "$failure" | jq -c --arg ended "$ended" --argjson firstPass "$first_pass" '.endedAt=$ended | .firstPassAccepted=$firstPass')" >/dev/null || fail "$task terminal failed"
}

test_routing_candidate_verdict_requires_preregistered_comparable_evidence() {
  local home registration comparison err verdict n root attempt output
  home=$(make_home candidate-guard)
  registration=$(FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" FM_HOME="$home" "$TELEMETRY" candidate-register --candidate cheaper-bounded-work \
    --payload "$(candidate_plan 6)") || fail "candidate registration failed"
  comparison=$(printf '%s' "$registration" | jq -r .comparisonId)
  printf '%s' "$comparison" | grep -Eq '^mrc_' || fail "candidate registration did not return an opaque comparison id"
  jq -e --arg comparison "$comparison" 'select(.schemaVersion=="firstmate.model-routing-candidate/v1" and .eventType=="routing-candidate-registered" and .comparisonId==$comparison)' \
    "$home/data/routing-outcomes.jsonl" >/dev/null || fail "candidate registration reused the attempt V1 schema instead of an additive rollback-compatible schema"

  set +e
  err=$(FM_HOME="$home" "$TELEMETRY" candidate-verdict --comparison "$comparison" --verdict adopted \
    --rollback-evidence tested:rollback-fixture 2>&1)
  verdict=$?
  [ "$verdict" -ne 0 ] || fail "candidate was adopted before its predeclared sample existed"
  assert_contains "$err" "insufficient sample" "early verdict refusal did not name the sample deficit"

  n=1
  while [ "$n" -le 6 ]; do
    if [ "$n" -eq 1 ]; then
      record_candidate_terminal_observation "$home" "candidate-a$n" gpt-5.6-luna failed capability "$CANDIDATE_NOW" null
    else
      record_candidate_observation "$home" "candidate-a$n" gpt-5.6-luna green 0
    fi
    record_candidate_observation "$home" "comparator-a$n" gpt-5.6-sol green 0
    n=$((n + 1))
  done

  root=$(jq -r 'select(.eventType=="attempt-intake" and .intake.taskRootId!=null and .intake.tuple.model=="gpt-5.6-luna") | .intake.taskRootId' "$home/data/routing-outcomes.jsonl" | head -1)
  attempt=$(jq -r --arg root "$root" 'select(.eventType=="attempt-intake" and .intake.taskRootId==$root) | .attemptId' "$home/data/routing-outcomes.jsonl" | head -1)
  FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" run_intake "$home" candidate-retry \
    "$(intake_payload gpt-5.6-luna high "$root" "$attempt")" >/dev/null || fail "same-root retry intake failed"
  FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" FM_HOME="$home" "$TELEMETRY" terminal-facts \
    --state "$home/state" --task candidate-retry --payload "$(terminal_facts_payload green 0)" >/dev/null || fail "same-root retry terminal failed"

  output=$(FM_HOME="$home" "$TELEMETRY" candidate-verdict --comparison "$comparison" --verdict adopted \
    --rollback-evidence tested:rollback-fixture) || fail "adequately sampled candidate verdict was refused"
  printf '%s' "$output" | jq -e '.sample.cells|length==2 and
    all(.[]; .observations==6 and (.modelVersion|length)>0 and (.cliVersion|length)>0 and (.taskClass|length)>0) and
    (any(.[]; .arm=="candidate" and .acceptedFirstPass==5 and .acceptedFirstPassRate==(5/6))) and
    (any(.[]; .arm=="comparator" and .acceptedFirstPass==6 and .acceptedFirstPassRate==1))' >/dev/null ||
    fail "verdict did not report self-describing cells or laundered a failed root through its successful retry"
  jq -e --arg comparison "$comparison" 'select(.eventType=="routing-candidate-verdict" and .comparisonId==$comparison and .verdict=="adopted" and .rollbackEvidence=={kind:"tested",id:"rollback-fixture"} and (.sample.cells|length)==2 and all(.sample.cells[]; .observations==6) and any(.sample.cells[]; .arm=="candidate" and .acceptedFirstPass==5))' \
    "$home/data/routing-outcomes.jsonl" >/dev/null || fail "accepted routing verdict was not recorded in the canonical ledger"
  pass "routing candidates require a predeclared method, comparator, per-model/class sample, window, and rollback evidence"
}

test_routing_candidate_guard_rejects_post_outcome_registration_and_missing_plan_fields() {
  local home registration comparison err rc malformed past parameterized
  home=$(make_home candidate-guard-order)
  record_candidate_observation "$home" prior-candidate gpt-5.6-luna green 0
  record_candidate_observation "$home" prior-comparator gpt-5.6-sol green 0
  registration=$(FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" FM_HOME="$home" "$TELEMETRY" candidate-register --candidate late-plan \
    --payload "$(candidate_plan 6)") || fail "late candidate registration failed"
  comparison=$(printf '%s' "$registration" | jq -r .comparisonId)
  set +e
  err=$(FM_HOME="$home" "$TELEMETRY" candidate-verdict --comparison "$comparison" --verdict discarded \
    --rollback-evidence documented:rollback-note 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "post-outcome registration counted evidence that predated the comparison method"
  assert_contains "$err" "insufficient sample" "post-outcome refusal did not exclude pre-registration outcomes"

  malformed=$(candidate_plan 6 | jq -c 'del(.comparator)')
  if FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" FM_HOME="$home" "$TELEMETRY" candidate-register --candidate no-comparator --payload "$malformed" >/dev/null 2>&1; then
    fail "candidate registration accepted a comparison plan with no comparator"
  fi
  malformed=$(candidate_plan 6 | jq -c 'del(.rollbackCriteria)')
  if FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" FM_HOME="$home" "$TELEMETRY" candidate-register --candidate no-rollback --payload "$malformed" >/dev/null 2>&1; then
    fail "candidate registration accepted a comparison plan with no rollback criteria"
  fi
  if FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" FM_HOME="$home" "$TELEMETRY" candidate-register --candidate underpowered --payload "$(candidate_plan 5)" >/dev/null 2>&1; then
    fail "candidate registration accepted the known-insufficient five observations per model/class"
  fi
  malformed=$(candidate_plan 6 | jq -c '.candidate.modelVersion="unreported"')
  if FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" FM_HOME="$home" "$TELEMETRY" candidate-register --candidate unreported-model --payload "$malformed" >/dev/null 2>&1; then
    fail "candidate registration accepted an unreported model version"
  fi
  if FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" FM_HOME="$home" "$TELEMETRY" candidate-register --candidate late-plan --payload "$(candidate_plan 6)" >/dev/null 2>&1; then
    fail "candidate registration accepted a second transition for the same candidate"
  fi
  past=$(candidate_plan 6 | jq -c '.window={startedAt:"2026-07-01T00:00:00Z",endedAt:"2026-07-31T23:59:59Z"}')
  if FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" FM_HOME="$home" "$TELEMETRY" candidate-register --candidate past-window --payload "$past" >/dev/null 2>&1; then
    fail "candidate registration accepted a comparison window that had already ended"
  fi
  parameterized=$(candidate_plan 6 | jq -c '.candidate.model="claude-opus-4-8[context=1m,effort=high,fast=false]" | .candidate.modelVersion=.candidate.model')
  FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" FM_HOME="$home" "$TELEMETRY" candidate-register \
    --candidate parameterized-model --payload "$parameterized" >/dev/null ||
    fail "candidate registration rejected a bounded printable parameterized model selector"
  pass "routing evidence must be pre-registered and every required plan field fails closed"
}

test_candidate_sample_excludes_non_quality_outcomes_and_binds_frozen_verdict() {
  local home registration comparison n rc ledger rewritten output
  home=$(make_home candidate-quality-only)
  registration=$(FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" FM_HOME="$home" "$TELEMETRY" candidate-register \
    --candidate quality-only --payload "$(candidate_plan 6)") || fail "quality-only candidate registration failed"
  comparison=$(printf '%s' "$registration" | jq -r .comparisonId)
  n=1
  while [ "$n" -le 6 ]; do
    record_candidate_observation "$home" "cancelled-candidate-$n" gpt-5.6-luna cancelled null
    record_candidate_observation "$home" "cancelled-comparator-$n" gpt-5.6-sol cancelled null
    n=$((n + 1))
  done
  rc=0
  FM_HOME="$home" "$TELEMETRY" candidate-verdict --comparison "$comparison" --verdict adopted \
    --rollback-evidence documented:rollback-note >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "cancelled attempts satisfied the quality-evidence minimum"

  n=1
  while [ "$n" -le 6 ]; do
    record_candidate_terminal_observation "$home" "quality-candidate-$n" gpt-5.6-luna refused refusal 2026-08-02T13:00:00+02:00
    record_candidate_observation "$home" "quality-comparator-$n" gpt-5.6-sol green 0
    n=$((n + 1))
  done
  rc=0
  FM_HOME="$home" "$TELEMETRY" candidate-verdict --comparison "$comparison" --verdict discarded \
    --rollback-evidence documented:rollback-note >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "outcomes that ended before registration were backfilled into the frozen sample"
  n=1
  while [ "$n" -le 6 ]; do
    record_candidate_observation "$home" "current-candidate-$n" gpt-5.6-luna failed null
    n=$((n + 1))
  done
  rc=0
  FM_HOME="$home" "$TELEMETRY" candidate-verdict --comparison "$comparison" --verdict adopted \
    --rollback-evidence documented:rollback-note >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "refusal-heavy candidate evidence bypassed the frozen adoption threshold"
  output=$(FM_HOME="$home" "$TELEMETRY" candidate-verdict --comparison "$comparison" --verdict discarded \
    --rollback-evidence documented:rollback-note) || fail "adequately sampled discarded verdict was refused"
  printf '%s' "$output" | jq -e '(.sample.cells[] | select(.arm=="candidate") | .observations==6 and .acceptedFirstPass==0 and .acceptedFirstPassRate==0)' >/dev/null ||
    fail "model refusals were excluded instead of counted as first-pass failures"
  ledger="$home/data/routing-outcomes.jsonl"
  rewritten="$home/data/rewritten.jsonl"
  jq -c 'if .eventType=="routing-candidate-verdict" then .candidateId="forged-candidate" else . end' "$ledger" > "$rewritten"
  mv "$rewritten" "$ledger"
  chmod 0600 "$ledger"
  if FM_HOME="$home" "$TELEMETRY" sheet --format json >/dev/null 2>&1; then
    fail "ledger validation accepted a verdict whose candidate identity did not match its frozen registration"
  fi
  pass "only independent quality outcomes count and verdict rows remain bound to the frozen candidate and sample"
}

test_legacy_lossless_and_read_only_sheets() {
  local home ledger legacy foreign checksum result attempt format empty_home n
  home=$(make_home sheets)
  ledger="$home/data/routing-outcomes.jsonl"
  legacy='  { "task" : "old", "note" : "preserve spacing" }  '
  foreign='{"schemaVersion":"other.writer/v9","attemptId":"not-ours","note":"foreign writer"}'
  printf '%s\n' "$legacy" "$foreign" > "$ledger"
  n=3
  while [ "$n" -le 34 ]; do
    printf '{"legacyIndex":%s}\n' "$n" >> "$ledger"
    n=$((n + 1))
  done
  chmod 0600 "$ledger"
  run_intake "$home" sheet-a "$(intake_payload)" >/dev/null || fail "a foreign schema version blocked intake"
  [ "$(sed -n '1p' "$ledger")" = "$legacy" ] || fail "legacy bytes were rewritten"
  [ "$(sed -n '2p' "$ledger")" = "$foreign" ] || fail "foreign schema version bytes were rewritten"
  checksum=$(shasum -a 256 "$ledger" | awk '{print $1}')
  for format in json csv md; do
    result=$(FM_HOME="$home" "$TELEMETRY" sheet --format "$format") || fail "$format sheet failed"
    [ -n "$result" ] || fail "$format sheet was empty"
    [ "$(shasum -a 256 "$ledger" | awk '{print $1}')" = "$checksum" ] || fail "$format sheet changed the ledger"
  done
  result=$(FM_HOME="$home" "$TELEMETRY" sheet --format json)
  printf '%s' "$result" | jq -e 'length==35 and (map(select(.recordType=="legacy"))|length)==34 and .[0].legacyRaw.task=="old" and .[1].legacyRaw.schemaVersion=="other.writer/v9" and .[33].legacyRaw.legacyIndex==34 and .[34].recordType=="attempt"' >/dev/null || fail "JSON sheet did not project all 34 legacy rows unchanged alongside V1"
  attempt=$(printf '%s' "$result" | jq -r '.[34].attemptId')
  printf '%s' "$attempt" | grep -Eq '^mra_' || fail "sheet attempt projection missing id"
  empty_home="$TMP_ROOT/read-only-empty/home"
  mkdir -p "$empty_home/data"
  FM_HOME="$empty_home" "$TELEMETRY" sheet --format json >/dev/null || fail "empty read-only sheet failed"
  [ ! -e "$empty_home/state" ] || fail "read-only sheet created state"
  pass "model telemetry preserves legacy bytes and renders JSON, CSV, and Markdown without ledger mutation"
}

test_account_profile_evidence_is_bound_only_to_claude() {
  local home payload
  home=$(make_home account-profile)
  payload=$(intake_payload | jq -c '
    .tuple.harness="claude" |
    .tuple.provider="anthropic" |
    .tuple.accountProfile="paid-primary" |
    .selection.candidateAssessments[0].tuple=.tuple
  ')
  run_intake "$home" claude-account "$payload" >/dev/null \
    || fail "valid Claude account-profile evidence was refused"

  payload=$(printf '%s' "$payload" | jq -c '
    .tuple.harness="codex" |
    .selection.candidateAssessments[0].tuple.harness="codex"
  ')
  if run_intake "$home" codex-account "$payload" >/dev/null 2>&1; then
    fail "non-Claude telemetry tuple accepted a Claude account profile"
  fi
  pass "account-profile selection evidence is accepted only on Claude tuples"
}

test_terminals_and_retry_links
test_crash_recovery_and_terminal_idempotency
test_relaunch_supersedes_stale_receipt
test_reseal_after_explicit_terminal_never_deadlocks
test_caller_attempt_outranks_a_diverging_receipt
test_missing_intake_requires_ledger_repair
test_validation_privacy_and_private_files
test_mechanical_quality_cost_and_exploration_projection
test_routing_candidate_verdict_requires_preregistered_comparable_evidence
test_routing_candidate_guard_rejects_post_outcome_registration_and_missing_plan_fields
test_candidate_sample_excludes_non_quality_outcomes_and_binds_frozen_verdict
test_legacy_lossless_and_read_only_sheets
test_account_profile_evidence_is_bound_only_to_claude
printf 'All model telemetry tests passed.\n'
