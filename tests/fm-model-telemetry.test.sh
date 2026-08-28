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
  local result=$1 reruns=$2 cost=${3:-null} currency=${4:-null} failure=${5:-}
  jq -cn --arg result "$result" --argjson reruns "$reruns" --argjson cost "$cost" --argjson currency "$currency" --arg failure "$failure" \
    '{gate:{source:"no-mistakes",result:$result,stepReruns:$reruns},outcomeLink:{kind:"commit",id:"0123456789abcdef"},usage:{inputTokens:null,outputTokens:null,cost:$cost,currency:$currency},wallSeconds:60} + (if $failure=="" then {} else {primaryFailureClass:$failure} end)'
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

  for spec in 'failed:not-applicable:capability' 'refused:compliant:refusal' 'refused:noncompliant:refusal' 'timed-out:not-applicable:timeout' 'quota-stopped:not-applicable:quota' 'cancelled:not-applicable:scope-change'; do
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
  jq -e --arg a "$attempt" 'select(.eventType=="attempt-terminal" and .attemptId==$a and .terminal.primaryFailureClass=="lease-conflict")' "$ledger" >/dev/null || fail "superseded attempt was sealed with the legacy unknown failure class instead of a typed one"

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
  receipt_home=$(make_home terminal-failure-class-unknown)
  run_intake "$receipt_home" terminal-failure-class-unknown "$payload" >/dev/null || fail "terminal failure-class-unknown intake failed"
  err=$(FM_HOME="$receipt_home" "$TELEMETRY" terminal --state "$receipt_home/state" --task terminal-failure-class-unknown --payload "$(terminal_payload failed not-applicable unknown)" 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a new terminal write with the legacy unknown failure class was accepted"
  assert_contains "$err" "typed primaryFailureClass" "the refusal did not name the typed-failure-class requirement"
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
    --payload "$(terminal_facts_payload green 2 10.101 '"USD"' none)" >/dev/null || fail "terminal facts failed"
  row=$(tail -n 1 "$ledger")
  printf '%s' "$row" | jq -e '
    .terminal.classification=="accepted" and .terminal.firstPassAccepted==false and
    .terminal.correctionCount==2 and .terminal.gateFacts=={source:"no-mistakes",result:"green",stepReruns:2} and
    .terminal.usage.cost==10.101 and .terminal.usage.currency=="USD" and
    .terminal.endedAt!=null and .terminal.wallSeconds==60
  ' >/dev/null || fail "terminal facts did not mechanically derive accepted-after-two-step-reruns quality and reported cost"
  if FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task invalid-prose --payload \
    "$(terminal_facts_payload green 0 null null none | jq -c '.classification="accepted"')" >/dev/null 2>&1; then
    fail "terminal facts accepted a caller-authored classification"
  fi
  run_intake "$home" first-pass "$(intake_payload gpt-5.6-sol low)" >/dev/null || fail "first-pass intake failed"
  FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task first-pass \
    --payload "$(terminal_facts_payload green 0 0 '"USD"' none)" >/dev/null || fail "first-pass terminal facts failed"
  run_intake "$home" failed-gate "$(intake_payload gpt-5.6-sol low)" >/dev/null || fail "failed-gate intake failed"
  FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task failed-gate \
    --payload "$(terminal_facts_payload failed null null null capability)" >/dev/null || fail "failed-gate terminal facts failed"
  run_intake "$home" cancelled-gate "$(intake_payload gpt-5.6-sol low)" >/dev/null || fail "cancelled-gate intake failed"
  FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task cancelled-gate \
    --payload "$(terminal_facts_payload cancelled null null null external-wait)" >/dev/null || fail "cancelled-gate terminal facts failed"
  jq -e 'select(.eventType=="attempt-terminal" and .terminal.classification=="cancelled" and .terminal.primaryFailureClass=="external-wait")' "$ledger" >/dev/null || fail "a cancelled gate did not preserve its observed typed failure class"
  run_intake "$home" green-unknown-reruns "$(intake_payload gpt-5.6-sol low)" >/dev/null || fail "unknown-step-rerun intake failed"
  FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task green-unknown-reruns \
    --payload "$(terminal_facts_payload green null null null none)" >/dev/null || fail "a green gate with an unreadable step-rerun count was refused"
  run_intake "$home" quota-wall "$(intake_payload gpt-5.6-sol low)" >/dev/null || fail "quota-stopped intake failed"
  FM_HOME="$home" "$TELEMETRY" terminal --state "$home/state" --task quota-wall \
    --payload "$(terminal_payload quota-stopped not-applicable quota)" >/dev/null || fail "quota-stopped terminal failed"
  retry=$(run_intake "$home" exploration-retry "$(exploration_intake_payload gpt-5.6-sol xhigh "$root" "$attempt")") || fail "rotated retry intake failed"
  retry_attempt=$(printf '%s' "$retry" | jq -r .attemptId)
  FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task exploration-retry \
    --payload "$(terminal_facts_payload green 0 null null none)" >/dev/null || fail "rotated retry terminal facts failed"
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

  run_intake "$home" no-signal-gate "$(intake_payload gpt-5.6-sol low)" >/dev/null || fail "no-signal-gate intake failed"
  FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task no-signal-gate \
    --payload "$(jq -cn '{gate:{source:"delivery",result:"incomplete",stepReruns:null},outcomeLink:{kind:"none",id:null},usage:{inputTokens:null,outputTokens:null,cost:null,currency:null},wallSeconds:null,primaryFailureClass:"state-divergence"}')" >/dev/null || fail "no-signal-gate terminal facts failed"
  jq -e 'select(.eventType=="attempt-terminal" and .terminal.classification=="incomplete" and .terminal.primaryFailureClass=="state-divergence")' "$ledger" >/dev/null || fail "a signal-less gate did not preserve its observed typed failure class"

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

test_terminal_facts_require_observed_failure_classes() {
  local home ledger err rc
  home=$(make_home terminal-facts-failure-class)
  ledger="$home/data/routing-outcomes.jsonl"

  run_intake "$home" missing-failure-class "$(intake_payload)" >/dev/null || fail "missing-failure-class intake failed"
  err=$(FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task missing-failure-class \
    --payload "$(terminal_facts_payload failed null)" 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a non-green terminal fact without an observed failure class was accepted"
  assert_contains "$err" "primaryFailureClass" "missing observed failure class refusal did not name the requirement"

  run_intake "$home" legacy-unknown-failure-class "$(intake_payload)" >/dev/null || fail "legacy-unknown-failure-class intake failed"
  err=$(FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task legacy-unknown-failure-class \
    --payload "$(terminal_facts_payload cancelled null | jq -c '.primaryFailureClass="unknown"')" 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a non-green terminal fact with legacy unknown was accepted"
  assert_contains "$err" "observed typed class" "legacy unknown refusal did not name the typed-failure-class requirement"

  run_intake "$home" failed-tool "$(intake_payload)" >/dev/null || fail "failed-tool intake failed"
  FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task failed-tool \
    --payload "$(terminal_facts_payload failed null | jq -c '.primaryFailureClass="tool"')" >/dev/null || fail "failed tool terminal facts failed"
  jq -e 'select(.eventType=="attempt-terminal" and .terminal.classification=="failed" and .terminal.primaryFailureClass=="tool")' "$ledger" >/dev/null || fail "failed terminal facts did not retain its observed tool class"

  run_intake "$home" cancelled-external-wait "$(intake_payload)" >/dev/null || fail "cancelled-external-wait intake failed"
  FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task cancelled-external-wait \
    --payload "$(terminal_facts_payload cancelled null | jq -c '.primaryFailureClass="external-wait"')" >/dev/null || fail "cancelled external-wait terminal facts failed"
  jq -e 'select(.eventType=="attempt-terminal" and .terminal.classification=="cancelled" and .terminal.primaryFailureClass=="external-wait")' "$ledger" >/dev/null || fail "cancelled terminal facts did not retain its observed external-wait class"

  run_intake "$home" green-none "$(intake_payload)" >/dev/null || fail "green-none intake failed"
  FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task green-none \
    --payload "$(terminal_facts_payload green null | jq -c '.primaryFailureClass="none"')" >/dev/null || fail "green terminal facts failed"
  jq -e 'select(.eventType=="attempt-terminal" and .terminal.classification=="accepted" and .terminal.primaryFailureClass=="none")' "$ledger" >/dev/null || fail "green terminal facts did not preserve none"

  pass "terminal facts require observed typed non-green failure classes and retain green none"
}

candidate_plan() {
  local minimum=${1:-6}
  jq -cn --argjson minimum "$minimum" '{method:"task-class-blocked",candidate:{harness:"codex",model:"gpt-5.6-luna",modelVersion:"gpt-5.6-luna",cliVersion:"codex-cli 1.2.3"},comparator:{harness:"codex",model:"gpt-5.6-sol",modelVersion:"gpt-5.6-sol",cliVersion:"codex-cli 1.2.3"},taskClasses:["bounded-implementation-proven-root-fix"],minimumPerModelClass:$minimum,window:{startedAt:"2026-08-01T00:00:00Z",endedAt:"2026-08-31T23:59:59Z"},rollbackCriteria:{metric:"accepted-first-pass-rate",operator:"below",threshold:0.8}}'
}

record_candidate_observation() {
  local home=$1 task=$2 model=$3 result=$4 reruns=$5 failure=$6
  FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" \
    run_intake "$home" "$task" "$(intake_payload "$model")" >/dev/null || fail "$task intake failed"
  FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task "$task" \
    --payload "$(terminal_facts_payload "$result" "$reruns" null null "$failure")" >/dev/null || fail "$task terminal failed"
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
      record_candidate_observation "$home" "candidate-a$n" gpt-5.6-luna green 0 none
    fi
    record_candidate_observation "$home" "comparator-a$n" gpt-5.6-sol green 0 none
    n=$((n + 1))
  done

  root=$(jq -r 'select(.eventType=="attempt-intake" and .intake.taskRootId!=null and .intake.tuple.model=="gpt-5.6-luna") | .intake.taskRootId' "$home/data/routing-outcomes.jsonl" | head -1)
  attempt=$(jq -r --arg root "$root" 'select(.eventType=="attempt-intake" and .intake.taskRootId==$root) | .attemptId' "$home/data/routing-outcomes.jsonl" | head -1)
  FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" run_intake "$home" candidate-retry \
    "$(intake_payload gpt-5.6-luna high "$root" "$attempt")" >/dev/null || fail "same-root retry intake failed"
  FM_MODEL_TELEMETRY_NOW_OVERRIDE="$CANDIDATE_NOW" FM_HOME="$home" "$TELEMETRY" terminal-facts \
    --state "$home/state" --task candidate-retry --payload "$(terminal_facts_payload green 0 null null none)" >/dev/null || fail "same-root retry terminal failed"

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
  record_candidate_observation "$home" prior-candidate gpt-5.6-luna green 0 none
  record_candidate_observation "$home" prior-comparator gpt-5.6-sol green 0 none
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
    record_candidate_observation "$home" "cancelled-candidate-$n" gpt-5.6-luna cancelled null external-wait
    record_candidate_observation "$home" "cancelled-comparator-$n" gpt-5.6-sol cancelled null external-wait
    n=$((n + 1))
  done
  rc=0
  FM_HOME="$home" "$TELEMETRY" candidate-verdict --comparison "$comparison" --verdict adopted \
    --rollback-evidence documented:rollback-note >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "cancelled attempts satisfied the quality-evidence minimum"

  n=1
  while [ "$n" -le 6 ]; do
    record_candidate_terminal_observation "$home" "quality-candidate-$n" gpt-5.6-luna refused refusal 2026-08-02T13:00:00+02:00
    record_candidate_observation "$home" "quality-comparator-$n" gpt-5.6-sol green 0 none
    n=$((n + 1))
  done
  rc=0
  FM_HOME="$home" "$TELEMETRY" candidate-verdict --comparison "$comparison" --verdict discarded \
    --rollback-evidence documented:rollback-note >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "outcomes that ended before registration were backfilled into the frozen sample"
  n=1
  while [ "$n" -le 6 ]; do
    record_candidate_observation "$home" "current-candidate-$n" gpt-5.6-luna failed null capability
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

test_intake_accepts_routing_provenance_additive_fields() {
  local home payload result row
  home=$(make_home routing-provenance)
  # The base five-key selection still validates (backward compatibility).
  run_intake "$home" base-sel "$(intake_payload)" >/dev/null \
    || fail "the base five-key selection was refused after the additive extension"

  # Each additive routing-provenance field is accepted independently and in any
  # subset, because fm-spawn threads only the facts it actually has.
  payload=$(intake_payload | jq -c '.selection.routingSource="profile"')
  run_intake "$home" routing-source-only "$payload" >/dev/null \
    || fail "a selection carrying only routingSource was refused"

  payload=$(intake_payload | jq -c '.selection.dispatchModelFamily="gpt-5"')
  run_intake "$home" model-family-only "$payload" >/dev/null \
    || fail "a selection carrying only dispatchModelFamily was refused"

  payload=$(intake_payload | jq -c '.selection.dispatchAttestation={kind:"resolved"}')
  run_intake "$home" resolved-only "$payload" >/dev/null \
    || fail "a resolved dispatchAttestation was refused"

  payload=$(intake_payload | jq -c '.selection.dispatchAttestation={kind:"override",reason:"captain raised the spend limit"}')
  run_intake "$home" override-with-reason "$payload" >/dev/null \
    || fail "an override dispatchAttestation with a reason was refused"

  payload=$(intake_payload | jq -c '.selection.routingSource="fallback" | .selection.dispatchModelFamily="glm" | .selection.dispatchAttestation={kind:"resolved"}')
  result=$(run_intake "$home" all-three "$payload") || fail "a selection carrying all three additive fields was refused"
  row=$(jq -es --arg a "$(printf '%s' "$result" | jq -r .attemptId)" 'map(select(.eventType=="attempt-intake" and .attemptId==$a)) | .[0].intake.selection' "$home/data/routing-outcomes.jsonl")
  printf '%s' "$row" | jq -e '.routingSource=="fallback" and .dispatchModelFamily=="glm" and .dispatchAttestation.kind=="resolved"' >/dev/null \
    || fail "the joined intake row did not preserve all three routing-provenance facts"

  # Unknown routingSource, override without a reason, and foreign keys are refused.
  payload=$(intake_payload | jq -c '.selection.routingSource="vibes"')
  if run_intake "$home" bad-routing-source "$payload" >/dev/null 2>&1; then
    fail "an unknown routingSource was accepted"
  fi
  payload=$(intake_payload | jq -c '.selection.dispatchAttestation={kind:"override"}')
  if run_intake "$home" override-no-reason "$payload" >/dev/null 2>&1; then
    fail "an override dispatchAttestation without a reason was accepted"
  fi
  payload=$(intake_payload | jq -c '.selection.foreignField="x"')
  if run_intake "$home" foreign-key "$payload" >/dev/null 2>&1; then
    fail "a foreign selection key was accepted"
  fi
  pass "intake accepts routing-provenance additive fields in any subset and rejects unknown values and foreign keys"
}

test_terminal_records_explicit_usage_source() {
  local home attempt facts row empty_worktree empty_sessions usage session_file
  home=$(make_home usage-source)
  attempt=$(run_intake "$home" usage-attempt "$(intake_payload)") || fail "usage-source intake failed"
  attempt=$(printf '%s' "$attempt" | jq -r .attemptId)

  # A recorded terminal usage carries usageSource=recorded.
  facts=$(jq -cn '{gate:{source:"no-mistakes",result:"green",stepReruns:0},outcomeLink:{kind:"commit",id:"0123456789abcdef"},usage:{inputTokens:1200,outputTokens:300,cost:null,currency:null},wallSeconds:60,usageSource:"recorded",primaryFailureClass:"none"}')
  FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task usage-attempt --attempt "$attempt" --payload "$facts" >/dev/null \
    || fail "terminal-facts with a recorded usageSource was refused"
  row=$(jq -es --arg a "$attempt" 'map(select(.eventType=="attempt-terminal" and .attemptId==$a)) | .[0].terminal' "$home/data/routing-outcomes.jsonl")
  printf '%s' "$row" | jq -e '.usage.inputTokens==1200 and .usageSource=="recorded"' >/dev/null \
    || fail "the sealed terminal did not carry the recorded usage and usageSource"

  # An unavailable usage is explicitly named rather than silently null.
  attempt=$(run_intake "$home" no-source-attempt "$(intake_payload)") || fail "no-source intake failed"
  attempt=$(printf '%s' "$attempt" | jq -r .attemptId)
  facts=$(jq -cn '{gate:{source:"delivery",result:"incomplete",stepReruns:null},outcomeLink:{kind:"none",id:null},usage:{inputTokens:null,outputTokens:null,cost:null,currency:null},wallSeconds:null,usageSource:"no-verified-source",primaryFailureClass:"external-wait"}')
  FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task no-source-attempt --attempt "$attempt" --payload "$facts" >/dev/null \
    || fail "terminal-facts with a no-verified-source usageSource was refused"
  row=$(jq -es --arg a "$attempt" 'map(select(.eventType=="attempt-terminal" and .attemptId==$a)) | .[0].terminal' "$home/data/routing-outcomes.jsonl")
  printf '%s' "$row" | jq -e '.usage.inputTokens==null and .usageSource=="no-verified-source"' >/dev/null \
    || fail "the sealed terminal did not explicitly name the unavailable usage source"

  # A session that was read but exposed no token totals is its own reason, so
  # the join can tell a harness-capability gap from a missing session.
  attempt=$(run_intake "$home" no-tokens-attempt "$(intake_payload)") || fail "no-tokens intake failed"
  attempt=$(printf '%s' "$attempt" | jq -r .attemptId)
  facts=$(jq -cn '{gate:{source:"delivery",result:"incomplete",stepReruns:null},outcomeLink:{kind:"none",id:null},usage:{inputTokens:null,outputTokens:null,cost:null,currency:null},wallSeconds:120,usageSource:"session-matched-no-tokens",primaryFailureClass:"external-wait"}')
  FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task no-tokens-attempt --attempt "$attempt" --payload "$facts" >/dev/null \
    || fail "terminal-facts with a session-matched-no-tokens usageSource was refused"
  row=$(jq -es --arg a "$attempt" 'map(select(.eventType=="attempt-terminal" and .attemptId==$a)) | .[0].terminal' "$home/data/routing-outcomes.jsonl")
  printf '%s' "$row" | jq -e '.usage.inputTokens==null and .wallSeconds==120 and .usageSource=="session-matched-no-tokens"' >/dev/null \
    || fail "a row measuring a session's duration still claimed no session was found: $row"

  # A terminal without usageSource (legacy callers) still validates.
  attempt=$(run_intake "$home" legacy-attempt "$(intake_payload)") || fail "legacy intake failed"
  attempt=$(printf '%s' "$attempt" | jq -r .attemptId)
  facts=$(jq -cn '{gate:{source:"delivery",result:"incomplete",stepReruns:null},outcomeLink:{kind:"none",id:null},usage:{inputTokens:null,outputTokens:null,cost:null,currency:null},wallSeconds:null,primaryFailureClass:"external-wait"}')
  FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task legacy-attempt --attempt "$attempt" --payload "$facts" >/dev/null \
    || fail "a terminal-facts payload without usageSource was refused"
  row=$(jq -es --arg a "$attempt" 'map(select(.eventType=="attempt-terminal" and .attemptId==$a)) | .[0].terminal' "$home/data/routing-outcomes.jsonl")
  printf '%s' "$row" | jq -e 'has("usageSource")|not' >/dev/null \
    || fail "a terminal without usageSource gained a usageSource field"

  empty_worktree="$home/empty-worktree"
  empty_sessions="$home/empty-sessions"
  mkdir -p "$empty_worktree" "$empty_sessions"
  attempt=$(run_intake "$home" session-not-found "$(intake_payload)") || fail "session-not-found intake failed"
  attempt=$(printf '%s' "$attempt" | jq -r .attemptId)
  usage=$(FM_CODEX_SESSIONS_OVERRIDE="$empty_sessions" FM_HOME="$home" "$TELEMETRY" usage --attempt "$attempt" --worktree "$empty_worktree") || fail "usage with an empty session directory was refused"
  printf '%s' "$usage" | jq -e '.usageSource=="session-not-found"' >/dev/null || fail "usage with an empty session directory did not name session-not-found"
  session_file="$empty_sessions/readable.jsonl"
  printf '%s\n' '{"timestamp":"2026-08-02T00:00:05Z","type":"session_meta","payload":{"id":"readable-session","timestamp":"2026-08-02T00:00:05Z","cwd":"'"$empty_worktree"'"}}' > "$session_file"
  printf '%s\n' '{"timestamp":"2026-08-02T00:00:25Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3210,"output_tokens":98}}}}' >> "$session_file"
  usage=$(FM_CODEX_SESSIONS_OVERRIDE="$empty_sessions" FM_HOME="$home" "$TELEMETRY" usage --attempt "$attempt" --worktree "$empty_worktree") || fail "usage with a readable session was refused"
  printf '%s' "$usage" | jq -e '.usageSource=="recorded" and .usage.inputTokens==3210 and .usage.outputTokens==98 and (.wallSeconds|type=="number" and .>0)' >/dev/null || fail "usage with a readable session did not retain tokens and active duration"
  pass "terminal records explicit usageSource for recorded and unavailable usage and stays absent for legacy callers"
}

# Proof that the existing telemetry join answers a subscription-renewal
# question: a representative week is joined into a per-subscription table with
# attempts, acceptance, cost, tokens, task classes served, quota utilization,
# and the usageSource breakdown. This is the deliverable; no dashboard is built.
test_subscription_sheet_joins_a_representative_week() {
  local home a json n cw cp ct gl ow day md cw_md cw_usage ct_md ct_usage err="$TMP_ROOT/subscription-sheet-err"
  home=$(make_home subscription-sheet)
  sub_intake() {
    local harness=$1 provider=$2 model=$3 account=$4 family=$5 routing=$6 rule=$7 task=$8 started=$9 decision=${10} headroom=${11}
    jq -cn --arg h "$harness" --arg p "$provider" --arg m "$model" --arg a "$account" --arg f "$family" --arg r "$routing" --arg rule "$rule" --arg t "$task" --arg s "$started" --arg d "$decision" --arg hm "$headroom" \
    'def tuple: {harness:$h,provider:$p,model:$m,effort:"high",modelVersion:$m,cliVersion:"cli 1.0"} + (if $h=="claude" then {accountProfile:$a} else {} end);
     {attemptClass:"real",source:"firstmate",taskRootId:null,parentAttemptId:null,projectRef:"project_0123456789abcdef",taskClass:$t,tuple:tuple,selection:{matchedRule:$rule,configSha256:null,fitReasons:["task-class"],candidateAssessments:[{tuple:tuple,eligibility:"selected",reasons:["class-fit"]}],quota:{decision:$d,headroom:$hm,runway:"sufficient",observedAt:null},routingSource:$r,dispatchModelFamily:$f},neutralExecution:{correlation:null,capabilityProfile:"not-applicable",owner:"not-applicable",phase:null,behavioralResult:"not-applicable"},evaluation:{kind:"none",fixtureId:null,fixtureManifestSha256:null,oracleId:null,oracleSha256:null,sourceCommit:null},startedAt:$s,privacy:{classification:"operational-minimized",contentPolicy:"ids-codes-hashes-bounded-evidence-only"}}'
  }
  sub_seal() {
    local task=$1 attempt=$2 classification=$3 intok=$4 outtok=$5 usageSource=$6 facts
    facts=$(jq -cn --arg c "$classification" --argjson it "$intok" --argjson ot "$outtok" --arg us "$usageSource" \
      '{gate:{source:"no-mistakes",result:(if $c=="accepted" then "green" else "failed" end),stepReruns:0},outcomeLink:{kind:"commit",id:"0123456789abcdef"},usage:{inputTokens:$it,outputTokens:$ot,cost:null,currency:null},wallSeconds:60,usageSource:($us|if .=="" then null else . end),primaryFailureClass:(if $c=="accepted" then "none" else "capability" end)}')
    FM_HOME="$home" "$TELEMETRY" terminal-facts --state "$home/state" --task "$task" --attempt "$attempt" --payload "$facts" >/dev/null
  }

  # Claude/work: 2 accepted (recorded), 1 failed (recorded).
  a=$(run_intake "$home" cw1 "$(sub_intake claude anthropic claude-opus work claude profile rule-1 bounded-implementation-proven-root-fix 2026-09-08T10:00:00Z selected sufficient)" | jq -r .attemptId); sub_seal cw1 "$a" accepted 1000 2000 recorded
  a=$(run_intake "$home" cw2 "$(sub_intake claude anthropic claude-opus work claude profile rule-1 bounded-implementation-proven-root-fix 2026-09-09T10:00:00Z selected sufficient)" | jq -r .attemptId); sub_seal cw2 "$a" accepted 1500 2500 recorded
  a=$(run_intake "$home" cw3 "$(sub_intake claude anthropic claude-opus work claude profile rule-1 adversarial-review-security-review 2026-09-10T10:00:00Z selected tight)" | jq -r .attemptId); sub_seal cw3 "$a" failed 800 400 recorded
  # Claude/personal: 1 accepted (recorded), 1 open.
  a=$(run_intake "$home" cp1 "$(sub_intake claude anthropic claude-opus personal claude profile rule-2 evidence-heavy-research 2026-09-11T10:00:00Z selected sufficient)" | jq -r .attemptId); sub_seal cp1 "$a" accepted 2000 3000 recorded
  run_intake "$home" cp2 "$(sub_intake claude anthropic claude-opus personal claude profile rule-2 documentation-specification-decision-extraction 2026-09-12T10:00:00Z selected sufficient)" >/dev/null
  # Codex/team (model gpt-5): 1 accepted (recorded), 1 failed with no-verified-source.
  a=$(run_intake "$home" ct1 "$(sub_intake codex openai gpt-5 team gpt-5 profile rule-3 bounded-implementation-proven-root-fix 2026-09-09T11:00:00Z selected sufficient)" | jq -r .attemptId); sub_seal ct1 "$a" accepted 500 800 recorded
  a=$(run_intake "$home" ct2 "$(sub_intake codex openai gpt-5 team gpt-5 profile rule-3 rote-reversible-edit 2026-09-13T11:00:00Z stopped exhausted)" | jq -r .attemptId); sub_seal ct2 "$a" failed null null no-verified-source
  # Codex/solo (distinct model gpt-5.6-sol): 1 accepted (recorded).
  a=$(run_intake "$home" cs1 "$(sub_intake codex openai gpt-5.6-sol solo gpt-5 profile rule-4 long-horizon-repository-work 2026-09-10T12:00:00Z selected sufficient)" | jq -r .attemptId); sub_seal cs1 "$a" accepted 600 900 recorded
  # Cursor GLM exploration candidate: 1 accepted, no-verified-source.
  a=$(run_intake "$home" gl1 "$(sub_intake cursor-agent cursor glm-4.5 "" glm fallback default bounded-implementation-proven-root-fix 2026-09-12T12:00:00Z selected unmeasurable)" | jq -r .attemptId); sub_seal gl1 "$a" accepted null null no-verified-source
  # Claude/work again: a session that was read but reported no token totals.
  a=$(run_intake "$home" cw4 "$(sub_intake claude anthropic claude-opus work claude profile rule-1 rote-reversible-edit 2026-09-09T12:00:00Z selected sufficient)" | jq -r .attemptId); sub_seal cw4 "$a" accepted null null session-matched-no-tokens
  # Out-of-window attempt that must be excluded by --from.
  run_intake "$home" old1 "$(sub_intake claude anthropic claude-opus work claude profile rule-1 bounded-implementation-proven-root-fix 2026-08-30T10:00:00Z selected sufficient)" >/dev/null

  json=$(FM_HOME="$home" "$TELEMETRY" subscription-sheet --from 2026-09-08T00:00:00Z --to 2026-09-14T23:59:59Z --format json)
  n=$(printf '%s' "$json" | jq 'length')
  [ "$n" = 5 ] || fail "expected 5 subscriptions for the representative week, got $n"
  cw=$(printf '%s' "$json" | jq -c '.[] | select(.accountProfile=="work" and .harness=="claude")')
  printf '%s' "$cw" | jq -e '.attempts==4 and .accepted==3 and .rejectedOrFailed==1 and .open==0 and .inputTokens==3300 and .outputTokens==4900 and .usageRecorded==3 and .usageSessionMatchedNoTokens==1 and (.taskClasses|index("bounded-implementation-proven-root-fix")>=0) and (.taskClasses|index("adversarial-review-security-review")>=0) and .quotaSelected==4 and .headroomTight==1' >/dev/null \
    || fail "claude/work subscription row was wrong: $cw"
  cp=$(printf '%s' "$json" | jq -c '.[] | select(.accountProfile=="personal" and .harness=="claude")')
  printf '%s' "$cp" | jq -e '.attempts==2 and .accepted==1 and .open==1' >/dev/null || fail "claude/personal subscription row was wrong: $cp"
  ct=$(printf '%s' "$json" | jq -c '.[] | select(.harness=="codex" and .model=="gpt-5")')
  printf '%s' "$ct" | jq -e '.attempts==2 and .accepted==1 and .rejectedOrFailed==1 and .quotaStopped==1 and .headroomExhausted==1 and .usageNoVerifiedSource==1' >/dev/null \
    || fail "codex/team subscription row was wrong: $ct"
  # A session read with no token totals gets its own bucket rather than falling
  # out of the breakdown that is supposed to explain the missing tokens.
  printf '%s' "$ct" | jq -e '.usageSessionMatchedNoTokens==0' >/dev/null \
    || fail "codex/team wrongly counted a session-matched-no-tokens row: $ct"
  printf '%s' "$json" | jq -e '[.[]|.usageSessionMatchedNoTokens]|add==1' >/dev/null \
    || fail "the usageSource breakdown lost the session-matched-no-tokens row: $json"
  gl=$(printf '%s' "$json" | jq -c '.[] | select(.harness=="cursor-agent")')
  printf '%s' "$gl" | jq -e '.attempts==1 and .accepted==1 and .usageNoVerifiedSource==1 and .dispatchModelFamily=="glm" and .headroomUnmeasurable==1' >/dev/null \
    || fail "cursor/glm subscription row was wrong: $gl"
  ow=$(printf '%s' "$json" | jq '[.[] | select(.subscription|test("2026-08"))] | length')
  [ "$ow" = 0 ] || fail "an out-of-window attempt leaked into the representative week"
  # A bare calendar date bound covers that whole day, so the natural spelling of
  # the window does not silently drop the attempts recorded on its last day.
  day=$(FM_HOME="$home" "$TELEMETRY" subscription-sheet --from 2026-09-08 --to 2026-09-13 --format json | jq -c '.[] | select(.harness=="codex" and .model=="gpt-5")')
  printf '%s' "$day" | jq -e '.attempts==2' >/dev/null \
    || fail "a bare --to date dropped the attempts recorded on that day: $day"
  # A bound that is not a UTC RFC3339 timestamp or a bare date is refused rather
  # than lexically compared into a wrong window.
  FM_HOME="$home" "$TELEMETRY" subscription-sheet --to 09/14/2026 >"$err" 2>&1 && fail "subscription-sheet accepted a non-RFC3339 --to bound"
  grep -q "must be a UTC RFC3339 timestamp or a bare YYYY-MM-DD date" "$err" || fail "missing window-bound error for a non-RFC3339 --to: $(cat "$err")"
  FM_HOME="$home" "$TELEMETRY" subscription-sheet --from 2026-09-08T00:00:00+02:00 >"$err" 2>&1 && fail "subscription-sheet accepted an offset-bearing --from bound"
  grep -q "must be a UTC RFC3339 timestamp or a bare YYYY-MM-DD date" "$err" || fail "missing window-bound error for an offset-bearing --from: $(cat "$err")"
  FM_HOME="$home" "$TELEMETRY" subscription-sheet --from 2026-09-14 --to 2026-09-08 >"$err" 2>&1 && fail "subscription-sheet accepted an inverted window"
  grep -q "must not be later than" "$err" || fail "missing inverted-window error: $(cat "$err")"
  FM_HOME="$home" "$TELEMETRY" subscription-sheet --from 2026-09-14T12:00:00Z --to 2026-09-14T06:00:00Z >"$err" 2>&1 && fail "subscription-sheet accepted a window inverted within one day"
  grep -q "must not be later than" "$err" || fail "missing inverted-window error for an intra-day inversion: $(cat "$err")"
  # A bare --to date still covers the whole day, so a same-day timestamped --from
  # is a legitimate window rather than an inversion.
  FM_HOME="$home" "$TELEMETRY" subscription-sheet --from 2026-09-13T00:00:00Z --to 2026-09-13 --format json >/dev/null \
    || fail "a same-day timestamped --from with a bare --to date was refused as inverted"
  # The markdown format renders a table, proving the join is presentable without a dashboard.
  md=$(FM_HOME="$home" "$TELEMETRY" subscription-sheet --from 2026-09-08T00:00:00Z --to 2026-09-14T23:59:59Z --format md)
  printf '%s\n' "$md" | grep -q '^| subscription |' || fail "subscription-sheet markdown header was missing"
  # The rendered usage cell must account for every sealed terminal, so a reader
  # sees the named-absence rows rather than a column that reads zero forever.
  cw_md=$(printf '%s\n' "$md" | grep '^| claude/anthropic/work/')
  [ -n "$cw_md" ] || fail "the markdown table lost the claude/work subscription: $md"
  cw_usage=$(printf '%s\n' "$cw_md" | awk -F'|' '{gsub(/ /,"",$(NF-1)); print $(NF-1)}')
  [ "$cw_usage" = "3/1/0" ] \
    || fail "the markdown usage cell hid the named-absence rows (want recorded/unavailable/absent 3/1/0): $cw_md"
  ct_md=$(printf '%s\n' "$md" | grep -F '| codex/openai/default/gpt-5/gpt-5 |')
  ct_usage=$(printf '%s\n' "$ct_md" | awk -F'|' '{gsub(/ /,"",$(NF-1)); print $(NF-1)}')
  [ -n "$ct_md" ] || fail "the markdown table lost the codex/team subscription: $md"
  [ "$ct_usage" = "1/1/0" ] \
    || fail "the markdown usage cell did not count the codex/team unavailable row: $ct_md"
  pass "subscription-sheet joins a representative week into a per-subscription renewal table"
}

# A spawn failure is a pre-launch refusal: it carries no attemptId and never
# conflates with a model-run attempt. The ledger must accept every documented
# failureKind and reject an unknown kind, an empty cause, a non-claude
# accountProfile, and foreign keys. Spawn capability and quota-reader
# availability are recorded separately so a quota-read login gap
# (quotaReader=credential-expired) never falsely marks the pool undispatchable
# (capability stays "unknown"/"supported", never "unsupported" for a reader
# gap).
test_spawn_failure_records_pre_launch_refusals() {
  local home tuple attempt gap err="$TMP_ROOT/spawn-failure-err"
  home=$(make_home spawn-failure)
  tuple='{"harness":"claude","provider":"anthropic","model":"claude-opus","effort":"high","modelVersion":"claude-opus","cliVersion":"claude-cli 1.0"}'
  for kind in credential quota quota-reader harness-auth validation catalog harness-missing backend other; do
    FM_HOME="$home" "$TELEMETRY" spawn-failure --state "$home/state" --task "k-$kind" --payload \
      "$(jq -cn --arg k "$kind" --argjson t "$tuple" '{attemptedAt:"2026-08-18T18:00:00Z",tuple:$t,taskClass:"unresolved",failureKind:$k,cause:"x",routingSource:null,dispatchAttestation:null,dispatchModelFamily:null,capability:"unknown",quotaReader:"not-applicable"}')" \
      >/dev/null || fail "spawn-failure rejected a valid failureKind: $kind"
  done
  # Unknown failureKind is rejected.
  FM_HOME="$home" "$TELEMETRY" spawn-failure --state "$home/state" --task bad-kind --payload \
    "$(jq -cn --argjson t "$tuple" '{attemptedAt:"2026-08-18T18:00:00Z",tuple:$t,taskClass:"unresolved",failureKind:"vibes",cause:"x",routingSource:null,dispatchAttestation:null,dispatchModelFamily:null,capability:"unknown",quotaReader:"not-applicable"}')" \
    >"$err" 2>&1 && fail "spawn-failure accepted an unknown failureKind"
  grep -q "spawn failure payload violates the whitelist" "$err" || fail "missing whitelist error for unknown kind"
  # Empty cause is rejected.
  FM_HOME="$home" "$TELEMETRY" spawn-failure --state "$home/state" --task bad-cause --payload \
    "$(jq -cn --argjson t "$tuple" '{attemptedAt:"2026-08-18T18:00:00Z",tuple:$t,taskClass:"unresolved",failureKind:"credential",cause:"",routingSource:null,dispatchAttestation:null,dispatchModelFamily:null,capability:"unknown",quotaReader:"not-applicable"}')" \
    >"$err" 2>&1 && fail "spawn-failure accepted an empty cause"
  grep -q "spawn failure payload violates the whitelist" "$err" || fail "missing whitelist error for empty cause"
  # A non-claude accountProfile is rejected (accountProfile is claude-only).
  FM_HOME="$home" "$TELEMETRY" spawn-failure --state "$home/state" --task bad-acct --payload \
    "$(jq -cn '{attemptedAt:"2026-08-18T18:00:00Z",tuple:{harness:"codex",provider:"openai",model:"gpt-5",effort:"high",modelVersion:"gpt-5",cliVersion:"codex",accountProfile:"team"},taskClass:"unresolved",failureKind:"credential",cause:"x",routingSource:null,dispatchAttestation:null,dispatchModelFamily:null,capability:"unknown",quotaReader:"not-applicable"}')" \
    >"$err" 2>&1 && fail "spawn-failure accepted a non-claude accountProfile"
  grep -q "spawn failure payload violates the whitelist" "$err" || fail "missing whitelist error for non-claude accountProfile"
  # A foreign key on the failure object is rejected.
  FM_HOME="$home" "$TELEMETRY" spawn-failure --state "$home/state" --task bad-foreign --payload \
    "$(jq -cn --argjson t "$tuple" '{attemptedAt:"2026-08-18T18:00:00Z",tuple:$t,taskClass:"unresolved",failureKind:"credential",cause:"x",routingSource:null,dispatchAttestation:null,dispatchModelFamily:null,capability:"unknown",quotaReader:"not-applicable",extraKey:1}')" \
    >"$err" 2>&1 && fail "spawn-failure accepted a foreign key"
  grep -q "spawn failure payload violates the whitelist" "$err" || fail "missing whitelist error for foreign key"
  # A payload missing capability is rejected (capability and quotaReader are required).
  FM_HOME="$home" "$TELEMETRY" spawn-failure --state "$home/state" --task bad-nocap --payload \
    "$(jq -cn --argjson t "$tuple" '{attemptedAt:"2026-08-18T18:00:00Z",tuple:$t,taskClass:"unresolved",failureKind:"credential",cause:"x",routingSource:null,dispatchAttestation:null,dispatchModelFamily:null}')" \
    >"$err" 2>&1 && fail "spawn-failure accepted a payload missing capability"
  grep -q "spawn failure payload violates the whitelist" "$err" || fail "missing whitelist error for missing capability"
  # An invalid capability enum is rejected.
  FM_HOME="$home" "$TELEMETRY" spawn-failure --state "$home/state" --task bad-cap --payload \
    "$(jq -cn --argjson t "$tuple" '{attemptedAt:"2026-08-18T18:00:00Z",tuple:$t,taskClass:"unresolved",failureKind:"credential",cause:"x",routingSource:null,dispatchAttestation:null,dispatchModelFamily:null,capability:"maybe",quotaReader:"unknown"}')" \
    >"$err" 2>&1 && fail "spawn-failure accepted an invalid capability enum"
  grep -q "spawn failure payload violates the whitelist" "$err" || fail "missing whitelist error for invalid capability"
  # A quota-read login gap is recorded with capability=unknown (NOT unsupported)
  # and quotaReader=credential-expired, so the pool is never falsely marked
  # undispatchable by a reader gap.
  FM_HOME="$home" "$TELEMETRY" spawn-failure --state "$home/state" --task reader-gap --payload \
    "$(jq -cn '{attemptedAt:"2026-08-18T18:00:00Z",tuple:{harness:"kimi",provider:"moonshot",model:"kimi-k2",effort:"high",modelVersion:"kimi-k2",cliVersion:"kimi-cli"},taskClass:"unresolved",failureKind:"quota-reader",cause:"kimi_code_cli_credential_expired",routingSource:"profile",dispatchAttestation:{kind:"resolved"},dispatchModelFamily:"kimi",capability:"unknown",quotaReader:"credential-expired"}')" \
    >/dev/null || fail "spawn-failure rejected a quota-reader gap payload"
  gap=$(jq -c 'select(.failure.failureKind=="quota-reader" and .failure.quotaReader=="credential-expired")' "$home/data/routing-outcomes.jsonl" | head -n1)
  [ -n "$gap" ] || fail "no quota-reader gap spawn-failure row was recorded"
  printf '%s' "$gap" | jq -e '.failure.capability=="unknown" and .failure.quotaReader=="credential-expired" and .failure.cause=="kimi_code_cli_credential_expired"' >/dev/null \
    || fail "quota-reader gap did not separate capability from quota-reader availability: $gap"
  # The recorded event carries the exact cause and is a spawn-failure, not an attempt.
  attempt=$(jq -c 'select(.eventType=="spawn-failure")' "$home/data/routing-outcomes.jsonl" | head -n1)
  [ -n "$attempt" ] || fail "no spawn-failure row was appended to the ledger"
  printf '%s' "$attempt" | jq -e '.failure.failureKind=="credential" and (.failure.cause|length>=1) and (.attemptId|not)' >/dev/null \
    || fail "spawn-failure row did not carry the cause or wrongly carried an attemptId"
  # The ledger still validates with spawn-failure rows present: a subsequent
  # write runs validate_ledger_for_write over the whole ledger, so it fails
  # if any prior spawn-failure row were malformed.
  FM_HOME="$home" "$TELEMETRY" spawn-failure --state "$home/state" --task revalidate --payload \
    "$(jq -cn --argjson t "$tuple" '{attemptedAt:"2026-08-18T18:00:00Z",tuple:$t,taskClass:"unresolved",failureKind:"other",cause:"revalidate",routingSource:null,dispatchAttestation:null,dispatchModelFamily:null,capability:"unknown",quotaReader:"not-applicable"}')" \
    >/dev/null || fail "ledger with spawn-failure rows failed to validate on a subsequent write"
  pass "spawn-failure records pre-launch refusals with the exact cause"
}

# A recorded spawn refusal never became a model attempt, so the attempt
# projections stay attempt-only. Its own read surface must group the refusals by
# the pool axes the failure payload carries and keep the exact cause, so a
# quota-read credential gap is visible without grepping the raw ledger.
test_spawn_failures_read_surface_groups_refusals_by_pool() {
  local home tuple_kimi tuple_codex json kimi codex md err="$TMP_ROOT/spawn-failures-err"
  home=$(make_home spawn-failures-read)
  tuple_kimi='{"harness":"kimi","provider":"moonshot","model":"kimi-k2","effort":"high","modelVersion":"kimi-k2","cliVersion":"kimi-cli"}'
  tuple_codex='{"harness":"codex","provider":"openai","model":"gpt-5","effort":"high","modelVersion":"gpt-5","cliVersion":"codex-cli"}'
  sf_record() {
    local task=$1 tuple=$2 at=$3 kind=$4 cause=$5 class=$6 family=$7 cap=$8 reader=$9
    FM_HOME="$home" "$TELEMETRY" spawn-failure --state "$home/state" --task "$task" --payload \
      "$(jq -cn --argjson t "$tuple" --arg at "$at" --arg k "$kind" --arg c "$cause" --arg cl "$class" --arg f "$family" --arg cap "$cap" --arg r "$reader" \
        '{attemptedAt:$at,tuple:$t,taskClass:$cl,failureKind:$k,cause:$c,routingSource:"profile",dispatchAttestation:{kind:"resolved"},dispatchModelFamily:$f,capability:$cap,quotaReader:$r}')" >/dev/null \
      || fail "spawn-failure was refused while seeding the read surface: $task"
  }
  sf_record k1 "$tuple_kimi" 2026-09-10T10:00:00Z quota-reader kimi_code_cli_credential_expired unresolved kimi unknown credential-expired
  sf_record k2 "$tuple_kimi" 2026-09-13T10:00:00Z quota-reader "kimi_code_cli_credential_expired on retry" rote-reversible-edit kimi unknown credential-expired
  sf_record k3 "$tuple_kimi" 2026-09-12T10:00:00Z validation "--quota-decision must be one of selected, stopped, not-applicable, unknown" unresolved kimi unknown not-applicable
  sf_record c1 "$tuple_codex" 2026-09-11T10:00:00Z quota "You have hit your usage limit" bounded-implementation-proven-root-fix gpt-5 unknown available

  json=$(FM_HOME="$home" "$TELEMETRY" spawn-failures --format json)
  [ "$(printf '%s' "$json" | jq 'length')" = 2 ] || fail "spawn-failures did not group the refusals into one row per pool: $json"
  kimi=$(printf '%s' "$json" | jq -c '.[] | select(.harness=="kimi")')
  printf '%s' "$kimi" | jq -e '.failures==3 and .failureKinds["quota-reader"]==2 and .failureKinds.validation==1' >/dev/null \
    || fail "the kimi pool did not carry its failureKind breakdown: $kimi"
  # The exact cause of the most recent refusal is what makes credential rot legible.
  printf '%s' "$kimi" | jq -e '.lastCause=="kimi_code_cli_credential_expired on retry" and .lastAt=="2026-09-13T10:00:00Z" and .firstAt=="2026-09-10T10:00:00Z"' >/dev/null \
    || fail "the kimi pool did not keep its most recent exact cause: $kimi"
  # Capability stays separate from quota-reader availability on the read surface too.
  printf '%s' "$kimi" | jq -e '(.capability|index("unsupported"))==null and (.quotaReader|index("credential-expired"))!=null and (.taskClasses|index("rote-reversible-edit"))!=null' >/dev/null \
    || fail "the kimi pool conflated spawn capability with quota-reader availability: $kimi"
  codex=$(printf '%s' "$json" | jq -c '.[] | select(.harness=="codex")')
  printf '%s' "$codex" | jq -e '.failures==1 and .failureKinds.quota==1 and .quotaReader==["available"] and .dispatchModelFamily=="gpt-5"' >/dev/null \
    || fail "the codex pool row was wrong: $codex"

  # The window bounds the attemptedAt axis, with the same bare-date whole-day rule.
  json=$(FM_HOME="$home" "$TELEMETRY" spawn-failures --from 2026-09-11 --to 2026-09-12 --format json)
  printf '%s' "$json" | jq -e 'length==2 and ([.[]|.failures]|add)==2' >/dev/null \
    || fail "spawn-failures did not bound the window on attemptedAt: $json"
  FM_HOME="$home" "$TELEMETRY" spawn-failures --to 09/14/2026 >"$err" 2>&1 && fail "spawn-failures accepted a non-RFC3339 bound"
  grep -q "must be a UTC RFC3339 timestamp or a bare YYYY-MM-DD date" "$err" || fail "missing window-bound error: $(cat "$err")"
  FM_HOME="$home" "$TELEMETRY" spawn-failures --from 2026-09-14T12:00:00Z --to 2026-09-14T06:00:00Z >"$err" 2>&1 && fail "spawn-failures accepted an inverted window"
  grep -q "must not be later than" "$err" || fail "missing inverted-window error: $(cat "$err")"
  FM_HOME="$home" "$TELEMETRY" spawn-failures --format table >"$err" 2>&1 && fail "spawn-failures accepted an unknown format"
  grep -q "spawn-failures format must be json, csv, or md" "$err" || fail "missing format error: $(cat "$err")"

  # The renderings are presentable without a dashboard.
  FM_HOME="$home" "$TELEMETRY" spawn-failures --format csv | grep -q '^pool,harness,provider' || fail "spawn-failures csv header was missing"
  FM_HOME="$home" "$TELEMETRY" spawn-failures --format md | grep -q '^| pool |' || fail "spawn-failures markdown header was missing"
  # The cooldown evidence a cause carries is an unbounded provider quote that may
  # contain a line break; the table must stay one row per pool.
  sf_record k4 "$tuple_kimi" 2026-09-13T12:00:00Z credential "provider refused the session
please log in again" unresolved kimi unknown not-applicable
  md=$(FM_HOME="$home" "$TELEMETRY" spawn-failures --format md)
  # Header, separator, and exactly one line per pool: a cause that kept its line
  # break would emit a fragment that is no longer a table row.
  [ "$(printf '%s\n' "$md" | wc -l | tr -d ' ')" = 4 ] || fail "a multi-line cause split the markdown table: $md"
  [ "$(printf '%s\n' "$md" | grep -c '^|.*|$')" = 4 ] || fail "a multi-line cause left a fragment outside the table: $md"
  FM_HOME="$home" "$TELEMETRY" spawn-failures --format md | grep -q 'please log in again' \
    || fail "the markdown table dropped the multi-line cause instead of folding it onto one row"

  # A spawn refusal never produced an attempt, so the attempt projections must
  # stay blind to it: the refusals above are the only rows in this ledger.
  [ "$(FM_HOME="$home" "$TELEMETRY" sheet --format json | jq 'length')" = 0 ] \
    || fail "a spawn-failure row leaked into the attempt sheet"
  [ "$(FM_HOME="$home" "$TELEMETRY" subscription-sheet --format json | jq 'length')" = 0 ] \
    || fail "a spawn-failure row leaked into the subscription sheet"
  pass "spawn-failures groups recorded refusals per pool with their exact cause"
}

test_intake_records_task_id_on_event_and_sheet() {
  local home result attempt sheet
  home=$(make_home task-id)
  # An intake with no task id slug at all is refused.
  if FM_HOME="$home" "$TELEMETRY" intake --state "$home/state" --payload "$(intake_payload)" >/dev/null 2>&1; then
    fail "an intake with no task id slug was accepted"
  fi
  result=$(run_intake "$home" typed-task "$(intake_payload)") || fail "task-id intake failed"
  attempt=$(printf '%s' "$result" | jq -r .attemptId)
  jq -e --arg a "$attempt" 'select(.eventType=="attempt-intake" and .attemptId==$a and .taskId=="typed-task")' \
    "$home/data/routing-outcomes.jsonl" >/dev/null || fail "the intake event did not persist the task id slug"
  sheet=$(FM_HOME="$home" "$TELEMETRY" sheet --format json) || fail "task-id sheet failed"
  printf '%s' "$sheet" | jq -e --arg a "$attempt" '.[0].recordType=="attempt" and .[0].attemptId==$a and .[0].taskId=="typed-task"' >/dev/null \
    || fail "the JSON sheet does not surface a taskId column"
  FM_HOME="$home" "$TELEMETRY" sheet --format csv | head -n 1 | grep -q ',taskId,' \
    || fail "the CSV sheet header lacks the additive taskId column"
  pass "intake persists the task id slug and the sheet surfaces it as a column"
}

test_intake_requires_a_typed_quota_decision_and_sheet_surfaces_it() {
  local home sheet err rc decision
  home=$(make_home quota-decision)
  err="$TMP_ROOT/quota-decision-err"

  # The untyped placeholder is refused on a new intake with a named reason;
  # unknown stays legal only when reading old rows.
  set +e
  FM_HOME="$home" "$TELEMETRY" intake --state "$home/state" --task quota-unknown \
    --payload "$(intake_payload | jq -c '.selection.quota.decision="unknown"')" >/dev/null 2>"$err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an intake with an untyped quota decision was accepted"
  grep -qi "quota decision" "$err" || fail "the quota-decision refusal did not name the reason: $(cat "$err")"

  # An invented quota decision is refused.
  set +e
  FM_HOME="$home" "$TELEMETRY" intake --state "$home/state" --task quota-invented \
    --payload "$(intake_payload | jq -c '.selection.quota.decision="maybe-so"')" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an invented quota decision was accepted"

  # A missing quota decision is refused.
  set +e
  FM_HOME="$home" "$TELEMETRY" intake --state "$home/state" --task quota-missing \
    --payload "$(intake_payload | jq -c 'del(.selection.quota.decision)')" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an intake with no quota decision was accepted"

  # The three typed decisions record and the sheet surfaces them per attempt.
  for decision in selected stopped not-applicable; do
    run_intake "$home" "quota-$decision" "$(intake_payload | jq -c --arg d "$decision" '.selection.quota.decision=$d')" >/dev/null \
      || fail "$decision intake failed"
  done
  sheet=$(FM_HOME="$home" "$TELEMETRY" sheet --format json) || fail "quota-decision sheet failed"
  printf '%s' "$sheet" | jq -e 'length==3 and ([.[].quotaDecision]|sort)==(["not-applicable","selected","stopped"])' >/dev/null \
    || fail "the JSON sheet does not surface a typed quotaDecision column: $sheet"
  FM_HOME="$home" "$TELEMETRY" sheet --format csv | head -n 1 | grep -q ',quotaDecision$' \
    || fail "the CSV sheet header lacks the additive quotaDecision column"
  pass "intake requires a typed quota decision and the sheet surfaces it as a column"
}

test_blocked_failure_classes_are_typed() {
  local home class rc
  home=$(make_home blocked-classes)
  for class in approval-wait custody-wait lease-conflict state-divergence; do
    run_intake "$home" "blocked-$class" "$(intake_payload)" >/dev/null || fail "$class intake failed"
    FM_HOME="$home" "$TELEMETRY" terminal --state "$home/state" --task "blocked-$class" \
      --payload "$(terminal_payload failed not-applicable "$class")" >/dev/null || fail "$class terminal was refused"
    jq -e --arg class "$class" 'select(.eventType=="attempt-terminal" and .terminal.primaryFailureClass==$class)' \
      "$home/data/routing-outcomes.jsonl" >/dev/null || fail "$class was not recorded on the terminal row"
  done
  run_intake "$home" blocked-invented "$(intake_payload)" >/dev/null || fail "invented-class intake failed"
  set +e
  FM_HOME="$home" "$TELEMETRY" terminal --state "$home/state" --task blocked-invented \
    --payload "$(terminal_payload failed not-applicable blocked-ness)" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an invented failure class was accepted"
  pass "terminals record the observed blocked failure classes and refuse invented ones"
}

test_terminals_and_retry_links
test_intake_records_task_id_on_event_and_sheet
test_intake_requires_a_typed_quota_decision_and_sheet_surfaces_it
test_blocked_failure_classes_are_typed
test_crash_recovery_and_terminal_idempotency
test_relaunch_supersedes_stale_receipt
test_reseal_after_explicit_terminal_never_deadlocks
test_caller_attempt_outranks_a_diverging_receipt
test_missing_intake_requires_ledger_repair
test_validation_privacy_and_private_files
test_mechanical_quality_cost_and_exploration_projection
test_terminal_facts_require_observed_failure_classes
test_routing_candidate_verdict_requires_preregistered_comparable_evidence
test_routing_candidate_guard_rejects_post_outcome_registration_and_missing_plan_fields
test_candidate_sample_excludes_non_quality_outcomes_and_binds_frozen_verdict
test_legacy_lossless_and_read_only_sheets
test_account_profile_evidence_is_bound_only_to_claude
test_intake_accepts_routing_provenance_additive_fields
test_terminal_records_explicit_usage_source
test_subscription_sheet_joins_a_representative_week
test_spawn_failure_records_pre_launch_refusals
test_spawn_failures_read_surface_groups_refusals_by_pool
printf 'All model telemetry tests passed.\n'
