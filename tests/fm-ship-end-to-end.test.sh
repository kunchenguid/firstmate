#!/usr/bin/env bash
# Behavior tests for the two-phase ship preflight record and private dashboard.
set -u
umask 022

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PREFLIGHT="$ROOT/bin/fm-ship-end-to-end.sh"
BRIDGE="$ROOT/bin/fm-agent-bridge-ship-preflight.sh"
DASHBOARD="$ROOT/bin/fm-dashboard.sh"
TMP_ROOT=$(fm_test_tmproot fm-ship-end-to-end)

make_contract() {
  local path=$1 complete=${2:-false} boundary=${3:-pr-only}
  printf '%s\n' '{"recommendation":"Build it","outcome":"A tested PR","scope":"One change","non_goals":"No deploy","delivery_boundary":"'"$boundary"'","external_boundaries":"No production write","questions":[],"complete_plan_approved":'"$complete"'}' > "$path"
}

preflight_env() {
  local home=$1 now=${2:-100}
  shift 2
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_SHIP_PREFLIGHT_NOW="$now" "$PREFLIGHT" "$@"
}

bridge_env() {
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" "$BRIDGE" "$@"
}

write_bridge_handoff() {
  local home=$1 id=$2 contract=$3 origin=$4 state=$5 now=$6 revision=${7:-1} contract_json bound fp handoff tmp bypass
  chmod 755 "$home/data"
  handoff="$home/state/agent-bridge/ship-preflight/$id.json"
  mkdir -p "${handoff%/*}"
  chmod 700 "$home/state/agent-bridge" "${handoff%/*}"
  contract_json=$(jq -cS . "$contract") || fail "could not canonicalize bridge contract"
  bound=$(jq -cn --arg id "$id" --argjson contract "$contract_json" '{task_id:$id,contract:$contract}' | jq -cS .) || fail "could not bind bridge preflight"
  if command -v sha256sum >/dev/null 2>&1; then
    fp=$(printf '%s' "$bound" | sha256sum | awk '{print $1}')
  else
    fp=$(printf '%s' "$bound" | shasum -a 256 | awk '{print $1}')
  fi
  bypass=$(jq -c '.complete_plan_approved == true' "$contract") || fail "could not read bypass state"
  tmp=$(umask 077; mktemp "${handoff%/*}/.ship-preflight.XXXXXX") || fail "could not prepare bridge record"
  jq -n --arg id "$id" --argjson contract "$contract_json" --arg fp "$fp" --arg origin "$origin" --arg state "$state" --argjson now "$now" --argjson bypass "$bypass" --argjson revision "$revision" '
    {schema_version:1,workflow:"ship-end-to-end",task_id:$id,fingerprint:$fp,origin:$origin,state:$state,contract:$contract,producer_revision:$revision}
    + (if $state == "approved" then {approval:{authority:(if $origin == "bridge" then "agent-bridge" else "direct-captain" end),evidence:(if $origin == "bridge" then "bridge-submission" else "direct-captain" end),approved_at:$now,complete_plan_bypass:$bypass}} else {created_at:$now} end)
  ' > "$tmp" || { rm -f -- "$tmp"; fail "could not write bridge record"; }
  if ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$handoff"; then
    rm -f -- "$tmp"
    fail "could not prepare bridge handoff"
  fi
  printf '%s' "$fp"
}

publish_preflight_record() {
  local home=$1 id=$2 contract=$3 origin=$4 state=$5 now=$6 revision=${7:-1} fp
  fp=$(write_bridge_handoff "$home" "$id" "$contract" "$origin" "$state" "$now" "$revision") || return 1
  bridge_env "$home" publish "$id" >/dev/null || fail "could not publish bridge record"
  printf '%s' "$fp"
}

test_direct_and_bridge_owned_preflight_authority() {
  local home="$TMP_ROOT/preflight" contract fp out status
  mkdir -p "$home/data" "$home/state"
  contract="$home/contract.json"
  make_contract "$contract"
  fp=$(publish_preflight_record "$home" direct-a1 "$contract" direct awaiting_approval 100) || fail "direct preflight should create a record"
  assert_grep '"state": "awaiting_approval"' "$home/data/direct-a1/ship-preflight.json" "direct preflight did not await approval"
  out=$(preflight_env "$home" 101 verify direct-a1 --fingerprint "$fp" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unapproved preflight must refuse verification"
  assert_contains "$out" "approval is missing" "unapproved refusal was unclear"
  fp=$(publish_preflight_record "$home" direct-a1 "$contract" direct approved 102 2) || fail "direct approval should work"
  preflight_env "$home" 103 verify direct-a1 --fingerprint "$fp" >/dev/null || fail "approved direct preflight should verify"
  out=$(preflight_env "$home" 103 preflight direct-a1 --contract "$contract" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "direct preflight must reject caller-supplied contract"
  assert_contains "$out" "Usage:" "caller-supplied contract refusal was unclear"

  out=$(preflight_env "$home" 100 preflight slack-a1 --origin slack --contract "$contract" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "public Slack preflight must refuse caller-supplied claims"
  assert_contains "$out" "Usage:" "public Slack preflight refusal was unclear"
  assert_absent "$home/data/slack-a1/ship-preflight.json" "public Slack preflight wrote an approval record"

  fp=$(publish_preflight_record "$home" slack-a1 "$contract" bridge approved 100) || fail "could not prepare bridge-owned preflight"
  preflight_env "$home" 102 verify slack-a1 --fingerprint "$fp" >/dev/null || fail "bridge-owned Slack preflight should verify"

  mkdir -p "$home/state/ship-preflight-submissions"
  printf '%s\n' '{}' > "$home/state/ship-preflight-submissions/generic-a1.json"
  chmod 600 "$home/state/ship-preflight-submissions/generic-a1.json"
  out=$(bridge_env "$home" publish generic-a1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a generic submission path published a preflight"
  assert_contains "$out" "no valid private bridge handoff" "generic submission refusal was unclear"
  assert_absent "$home/data/generic-a1/ship-preflight.json" "generic submission wrote an approval record"
  pass "typed direct and bridge-owned Slack preflights preserve approval authority"
}

test_direct_preflight_publisher_and_approval() {
  local home="$TMP_ROOT/direct-publisher" contract="$TMP_ROOT/direct-publisher-contract.json" corrected="$TMP_ROOT/direct-publisher-corrected.json" fp next_fp out status record
  mkdir -p "$home"
  make_contract "$contract"
  out=$(preflight_env "$home" 100 publish-direct direct-publisher-a1 --contract-file "$contract") || fail "direct publisher should create an awaiting record"
  fp=${out#fingerprint=}
  case "$fp" in
    ????????*) [ "${#fp}" -eq 64 ] && ! printf '%s' "$fp" | grep -q '[^0-9a-f]' ;;
    *) false ;;
  esac || fail "direct publisher did not return a fingerprint"
  record="$home/data/direct-publisher-a1/ship-preflight.json"
  jq -e '.origin == "direct" and .state == "awaiting_approval" and .producer_revision == 1' "$record" >/dev/null || fail "direct publisher did not create an awaiting direct record"

  out=$(preflight_env "$home" 101 approve-direct direct-publisher-a1 --fingerprint "$fp") || fail "direct approval should approve the published record"
  [ "$out" = approved ] || fail "direct approval did not report approval"
  preflight_env "$home" 102 verify direct-publisher-a1 --fingerprint "$fp" >/dev/null || fail "direct approved record should authorize dispatch"
  jq -e '.state == "approved" and .producer_revision == 2 and .approval.authority == "direct-captain" and .approval.evidence == "direct-captain"' "$record" >/dev/null || fail "direct approval did not retain typed captain evidence"

  out=$(preflight_env "$home" 103 approve-direct direct-publisher-a1 --fingerprint "$fp" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a direct record accepted duplicate approval"
  assert_contains "$out" "not awaiting approval" "duplicate direct approval refusal was unclear"

  jq '.scope = "Corrected change"' "$contract" > "$corrected" || fail "could not create corrected direct contract"
  out=$(preflight_env "$home" 104 publish-direct direct-publisher-a1 --contract-file "$corrected") || fail "corrected direct contract should republish"
  next_fp=${out#fingerprint=}
  [ "$next_fp" != "$fp" ] || fail "corrected direct contract retained its old fingerprint"
  jq -e '.state == "awaiting_approval" and .producer_revision == 3' "$record" >/dev/null || fail "corrected direct contract did not require fresh approval"
  pass "direct publisher creates typed records and requires fresh approval"
}

test_delivery_boundary_is_pr_only() {
  local home="$TMP_ROOT/pr-only-boundary" contract="$TMP_ROOT/pr-only-boundary-contract.json" boundary out status n=0
  mkdir -p "$home/data" "$home/state"

  make_contract "$contract"
  out=$(preflight_env "$home" 100 publish-direct pr-only-a1 --contract-file "$contract") || fail "the pr-only delivery boundary should publish"
  [ "${out#fingerprint=}" != "$out" ] || fail "the pr-only delivery boundary did not return a fingerprint"
  jq -e '.contract.delivery_boundary == "pr-only"' "$home/data/pr-only-a1/ship-preflight.json" >/dev/null \
    || fail "the pr-only delivery boundary was not retained"

  for boundary in merge deploy merge+deploy pr-only+merge arbitrary-boundary; do
    n=$((n + 1))
    make_contract "$contract" false "$boundary"
    out=$(preflight_env "$home" 100 publish-direct "direct-boundary-$n" --contract-file "$contract" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "direct preflight accepted rejected delivery boundary: $boundary"
    assert_contains "$out" "delivery boundary must be pr-only" "direct delivery-boundary refusal was unclear: $boundary"
    assert_absent "$home/data/direct-boundary-$n/ship-preflight.json" "direct preflight published rejected delivery boundary: $boundary"

    write_bridge_handoff "$home" "bridge-boundary-$n" "$contract" bridge approved 100 >/dev/null || fail "could not prepare rejected bridge boundary: $boundary"
    out=$(bridge_env "$home" publish "bridge-boundary-$n" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "bridge preflight accepted rejected delivery boundary: $boundary"
    assert_contains "$out" "invalid typed private bridge handoff" "bridge delivery-boundary refusal was unclear: $boundary"
    assert_absent "$home/data/bridge-boundary-$n/ship-preflight.json" "bridge preflight published rejected delivery boundary: $boundary"
  done
  pass "ship preflights accept only the pr-only delivery boundary"
}

test_direct_complete_plan_publisher_bypasses_duplicate_approval() {
  local home="$TMP_ROOT/direct-complete-plan" contract="$TMP_ROOT/direct-complete-plan-contract.json" questions="$TMP_ROOT/direct-complete-plan-questions.json" fp question_fp out status record
  mkdir -p "$home"
  make_contract "$contract" true
  out=$(preflight_env "$home" 100 publish-direct direct-complete-plan-a1 --contract-file "$contract") || fail "approved direct plan should publish"
  fp=${out#fingerprint=}
  record="$home/data/direct-complete-plan-a1/ship-preflight.json"
  jq -e '.origin == "direct" and .state == "approved" and .producer_revision == 1 and .approval.authority == "direct-captain" and .approval.evidence == "direct-captain" and .approval.complete_plan_bypass == true' "$record" >/dev/null \
    || fail "approved direct plan did not preserve its trusted bypass"
  preflight_env "$home" 101 verify direct-complete-plan-a1 --fingerprint "$fp" >/dev/null \
    || fail "approved direct plan should authorize dispatch without another approval"
  out=$(preflight_env "$home" 102 approve-direct direct-complete-plan-a1 --fingerprint "$fp" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "approved complete plan accepted duplicate approval"
  assert_contains "$out" "not awaiting approval" "complete plan duplicate approval refusal was unclear"

  jq '.questions = ["Choose a deployment window"]' "$contract" > "$questions" || fail "could not create complete plan with open questions"
  out=$(preflight_env "$home" 103 publish-direct direct-complete-plan-a1 --contract-file "$questions") || fail "complete plan with open questions should publish for approval"
  question_fp=${out#fingerprint=}
  jq -e '.state == "awaiting_approval" and .approval == null' "$record" >/dev/null \
    || fail "complete plan with open questions bypassed approval"
  preflight_env "$home" 104 approve-direct direct-complete-plan-a1 --fingerprint "$question_fp" >/dev/null \
    || fail "captain approval should resolve open complete-plan questions"
  jq -e '.state == "approved" and .approval.complete_plan_bypass == false' "$record" >/dev/null \
    || fail "explicit approval of open questions retained the bypass"
  preflight_env "$home" 105 verify direct-complete-plan-a1 --fingerprint "$question_fp" >/dev/null \
    || fail "explicitly approved complete plan with questions should authorize dispatch"
  pass "approved direct plans bypass only duplicate preflight approval"
}

test_direct_record_size_refusal_preserves_prior_record() {
  local home="$TMP_ROOT/direct-record-size" contract="$TMP_ROOT/direct-record-size-contract.json" oversized="$TMP_ROOT/direct-record-size-oversized.json" padding fp out status record
  mkdir -p "$home"
  make_contract "$contract"
  out=$(FM_SHIP_PREFLIGHT_MAX_BYTES=800 preflight_env "$home" 100 publish-direct direct-record-size-a1 --contract-file "$contract") || fail "could not publish initial bounded record"
  fp=${out#fingerprint=}
  record="$home/data/direct-record-size-a1/ship-preflight.json"
  FM_SHIP_PREFLIGHT_MAX_BYTES=800 preflight_env "$home" 100 approve-direct direct-record-size-a1 --fingerprint "$fp" >/dev/null \
    || fail "could not approve initial bounded record"
  padding=$(printf '%*s' 450 '' | tr ' ' x)
  jq --arg padding "$padding" '.scope = $padding' "$contract" > "$oversized" || fail "could not create near-limit contract"
  [ "$(wc -c < "$oversized")" -le 800 ] || fail "near-limit contract was not within the input bound"
  out=$(FM_SHIP_PREFLIGHT_MAX_BYTES=800 preflight_env "$home" 101 publish-direct direct-record-size-a1 --contract-file "$oversized" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "oversized serialized record replaced a valid record"
  assert_contains "$out" "direct preflight record exceeds the bounded size" "oversized serialized record refusal was unclear"
  FM_SHIP_PREFLIGHT_MAX_BYTES=800 preflight_env "$home" 102 verify direct-record-size-a1 --fingerprint "$fp" >/dev/null \
    || fail "oversized record rejection invalidated the prior approval"
  jq -e '.producer_revision == 2 and .fingerprint == $fp' --arg fp "$fp" "$record" >/dev/null \
    || fail "oversized record rejection replaced the prior record"
  pass "direct records reject oversized envelopes before replacement"
}

test_direct_preflight_snapshots_contract_before_parse() {
  local home="$TMP_ROOT/direct-contract-snapshot" contract="$TMP_ROOT/direct-contract-snapshot.json" replacement="$TMP_ROOT/direct-contract-replacement.json" fakebin="$TMP_ROOT/direct-contract-snapshot-bin" real_jq out record
  mkdir -p "$home" "$fakebin"
  make_contract "$contract"
  jq '.scope = "Replacement scope"' "$contract" > "$replacement" || fail "could not create replacement contract"
  printf '%2048s' '' >> "$replacement"
  real_jq=$(command -v jq) || fail "could not find jq"
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
set -eu
if [ ! -e "$FM_DIRECT_CONTRACT_SWAPPED" ]; then
  for arg in "$@"; do
    if [ "$arg" = -cS ]; then
      mv -f -- "$FM_DIRECT_CONTRACT_REPLACEMENT" "$FM_DIRECT_CONTRACT_PATH"
      : > "$FM_DIRECT_CONTRACT_SWAPPED"
      break
    fi
  done
fi
exec "$FM_DIRECT_REAL_JQ" "$@"
SH
  chmod +x "$fakebin/jq"
  out=$(PATH="$fakebin:$PATH" FM_SHIP_PREFLIGHT_MAX_BYTES=1024 FM_DIRECT_CONTRACT_PATH="$contract" FM_DIRECT_CONTRACT_REPLACEMENT="$replacement" FM_DIRECT_CONTRACT_SWAPPED="$home/contract-swapped" FM_DIRECT_REAL_JQ="$real_jq" preflight_env "$home" 100 publish-direct direct-contract-snapshot-a1 --contract-file "$contract") \
    || fail "direct preflight did not publish its bounded snapshot"
  [ -e "$home/contract-swapped" ] || fail "direct contract mutation did not run"
  record="$home/data/direct-contract-snapshot-a1/ship-preflight.json"
  jq -e '.contract.scope == "One change"' "$record" >/dev/null \
    || fail "direct preflight parsed the replaced contract instead of its snapshot"
  [ "${out#fingerprint=}" != "$out" ] || fail "direct snapshot publication did not return a fingerprint"
  pass "direct preflight parses only its private bounded snapshot"
}

test_preflight_rejects_oversized_inputs_before_publication() {
  local home="$TMP_ROOT/preflight-size" contract="$TMP_ROOT/preflight-size-contract.json" handoff out status
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"
  printf '%064d\n' 0 >> "$contract"
  out=$(FM_SHIP_PREFLIGHT_MAX_BYTES=64 preflight_env "$home" 100 publish-direct direct-size-a1 --contract-file "$contract" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "oversized direct contract published a preflight"
  assert_contains "$out" "preflight input exceeds the bounded size" "oversized direct contract refusal was unclear"
  assert_absent "$home/data/direct-size-a1/ship-preflight.json" "oversized direct contract wrote a record"

  handoff="$home/state/agent-bridge/ship-preflight/bridge-size-a1.json"
  mkdir -p "${handoff%/*}"
  chmod 700 "$home/state/agent-bridge" "${handoff%/*}"
  printf '%065d\n' 0 > "$handoff"
  chmod 600 "$handoff"
  out=$(FM_SHIP_PREFLIGHT_MAX_BYTES=64 bridge_env "$home" publish bridge-size-a1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "oversized bridge handoff published a preflight"
  assert_contains "$out" "preflight input exceeds the bounded size" "oversized bridge handoff refusal was unclear"
  [ -f "$handoff" ] || fail "oversized bridge handoff was consumed"
  assert_absent "$home/data/bridge-size-a1/ship-preflight.json" "oversized bridge handoff wrote a record"
  pass "preflight bounds direct and bridge inputs before publication"
}

test_direct_preflight_serializes_corrections() {
  local home="$TMP_ROOT/direct-publisher-lock" contract="$TMP_ROOT/direct-publisher-lock-contract.json" corrected="$TMP_ROOT/direct-publisher-lock-corrected.json" fp holder_pid publisher_pid attempts status out
  mkdir -p "$home"
  make_contract "$contract"
  jq '.scope = "Corrected locked change"' "$contract" > "$corrected" || fail "could not create locked corrected contract"
  out=$(preflight_env "$home" 100 publish-direct direct-lock-a1 --contract-file "$contract") || fail "could not create lock test preflight"
  fp=${out#fingerprint=}
  preflight_env "$home" 101 approve-direct direct-lock-a1 --fingerprint "$fp" >/dev/null || fail "could not approve lock test preflight"
  (
    STATE="$home/data/direct-lock-a1"
    FM_STATE_OVERRIDE="$STATE" . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$STATE/.ship-preflight.lock"
    : > "$home/holder-ready"
    while [ ! -e "$home/holder-release" ]; do sleep 0.01; done
    fm_lock_release "$STATE/.ship-preflight.lock"
  ) &
  holder_pid=$!
  attempts=0
  while [ ! -e "$home/holder-ready" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$home/holder-ready" ]; then
    wait "$holder_pid" || true
    fail "direct preflight lock holder did not start"
  fi
  (
    if preflight_env "$home" 102 publish-direct direct-lock-a1 --contract-file "$corrected" > "$home/publish.out" 2>&1; then
      printf '%s\n' 0 > "$home/publish.status"
    else
      printf '%s\n' 1 > "$home/publish.status"
    fi
  ) &
  publisher_pid=$!
  attempts=0
  while [ ! -e "$home/publish.status" ] && [ "$attempts" -lt 20 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ -e "$home/publish.status" ]; then
    : > "$home/holder-release"
    wait "$holder_pid" || true
    wait "$publisher_pid" || true
    fail "direct correction published while the shared preflight lock was held"
  fi
  : > "$home/holder-release"
  wait "$holder_pid" || fail "could not release direct preflight lock"
  wait "$publisher_pid"
  status=$?
  [ "$status" -eq 0 ] && [ "$(cat "$home/publish.status")" = 0 ] || fail "direct correction did not publish after the lock released"
  out=$(preflight_env "$home" 103 verify direct-lock-a1 --fingerprint "$fp" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "corrected direct contract retained the prior approval"
  assert_contains "$out" "approval is missing" "corrected direct contract did not require approval"
  pass "direct corrections wait for the shared preflight lock"
}

test_preflight_requires_typed_authority_evidence() {
  local home="$TMP_ROOT/preflight-authority" contract="$TMP_ROOT/preflight-authority-contract.json" fp out status record tmp
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"
  fp=$(publish_preflight_record "$home" authority-a1 "$contract" bridge approved 100) || fail "could not publish approved bridge preflight"
  record="$home/data/authority-a1/ship-preflight.json"
  tmp=$(mktemp "$home/data/authority-a1/.approval.XXXXXX") || fail "could not prepare malformed approval"
  if ! jq 'del(.approval.authority)' "$record" > "$tmp" || ! mv -f -- "$tmp" "$record"; then
    fail "could not remove approval authority"
  fi
  chmod 600 "$record"
  out=$(preflight_env "$home" 101 verify authority-a1 --fingerprint "$fp" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "approval without typed authority must be refused"
  assert_contains "$out" "typed approval authority evidence" "missing authority refusal was unclear"

  fp=$(publish_preflight_record "$home" evidence-a1 "$contract" direct approved 100) || fail "could not publish approved direct preflight"
  record="$home/data/evidence-a1/ship-preflight.json"
  tmp=$(mktemp "$home/data/evidence-a1/.approval.XXXXXX") || fail "could not prepare malformed evidence"
  if ! jq '.approval.evidence = "unverified"' "$record" > "$tmp" || ! mv -f -- "$tmp" "$record"; then
    fail "could not alter approval evidence"
  fi
  chmod 600 "$record"
  out=$(preflight_env "$home" 101 verify evidence-a1 --fingerprint "$fp" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "approval without typed evidence must be refused"
  assert_contains "$out" "typed approval authority evidence" "missing evidence refusal was unclear"
  pass "preflight requires typed authority and bridge evidence"
}

test_preflight_requires_a_bounded_producer_revision() {
  local home="$TMP_ROOT/preflight-producer-revision" contract="$TMP_ROOT/preflight-producer-revision-contract.json" out status record valid tmp transform
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"
  publish_preflight_record "$home" producer-revision-a1 "$contract" direct approved 100 >/dev/null || fail "could not publish approved preflight"
  record="$home/data/producer-revision-a1/ship-preflight.json"
  valid="$home/valid-preflight.json"
  cp "$record" "$valid" || fail "could not preserve valid preflight"
  for transform in 'del(.producer_revision)' '.producer_revision = 0' '.producer_revision = 2.5' '.producer_revision = 9007199254740992'; do
    tmp=$(mktemp "$home/data/producer-revision-a1/.producer-revision.XXXXXX") || fail "could not prepare malformed preflight"
    if ! jq "$transform" "$valid" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$record"; then
      fail "could not publish malformed producer revision"
    fi
    out=$(preflight_env "$home" 101 verify-current producer-revision-a1 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "a malformed producer revision authorized fresh dispatch"
    assert_contains "$out" "malformed preflight record" "malformed producer revision refusal was unclear"
  done
  pass "preflight requires a bounded producer revision"
}

test_grouped_questions_and_bounded_contract() {
  local home="$TMP_ROOT/grouped" contract="$TMP_ROOT/grouped-contract.json" out status
  mkdir -p "$home/data"
  printf '%s\n' '{"recommendation":"Build it","outcome":"A tested PR","scope":"One change","non_goals":"No deploy","delivery_boundary":"pr-only","external_boundaries":"No production write","questions":["Choose A or B","Confirm rollout"]}' > "$contract"
  publish_preflight_record "$home" grouped-a1 "$contract" direct awaiting_approval 100 >/dev/null || fail "grouped questions must be accepted in one contract"
  jq -e '.contract.questions == ["Choose A or B","Confirm rollout"] and .state == "awaiting_approval"' "$home/data/grouped-a1/ship-preflight.json" >/dev/null \
    || fail "preflight did not preserve grouped questions"
  pass "preflight keeps one grouped question set"
}

test_correction_bypass_and_stale_refusal() {
  local home="$TMP_ROOT/correction" contract changed fp out status
  mkdir -p "$home/data"
  contract="$home/contract.json"; changed="$home/changed.json"
  make_contract "$contract"
  fp=$(publish_preflight_record "$home" correction-a1 "$contract" direct awaiting_approval 100) || fail "preflight create failed"
  make_contract "$changed"
  printf '%s\n' '{"recommendation":"Build it","outcome":"Changed tested PR","scope":"One change","non_goals":"No deploy","delivery_boundary":"pr-only","external_boundaries":"No production write","questions":[]}' > "$changed"
  fp2=$(publish_preflight_record "$home" correction-a1 "$changed" direct awaiting_approval 101 2) || fail "correction should replace unapproved contract"
  [ "$fp" != "$fp2" ] || fail "correction should change the fingerprint"
  fp2=$(publish_preflight_record "$home" correction-a1 "$changed" direct approved 102 3) || fail "current approval failed"
  out=$(preflight_env "$home" 102 verify correction-a1 --fingerprint "$fp" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "mismatched approval must refuse"
  out=$(FM_SHIP_PREFLIGHT_MAX_AGE=5 preflight_env "$home" 108 verify correction-a1 --fingerprint "$fp2" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "stale approval must refuse"
  assert_contains "$out" "stale" "stale refusal was unclear"
  out=$(FM_SHIP_PREFLIGHT_MAX_AGE=5 preflight_env "$home" 108 verify-dispatched correction-a1 --fingerprint "$fp2" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a stale approval must stop dispatched work"
  assert_contains "$out" "stale" "dispatched stale refusal was unclear"
  out=$(FM_SHIP_PREFLIGHT_MAX_AGE=5 preflight_env "$home" 108 verify-recovery correction-a1 --fingerprint "$fp2" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a stale approval must stop recovery work"
  assert_contains "$out" "stale" "recovery stale refusal was unclear"
  out=$(preflight_env "$home" 108 verify-recovery correction-a1 --fingerprint "$fp" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "recovery must refuse a replaced approved contract"
  assert_contains "$out" "fingerprint does not match" "recovery did not preserve its original contract binding"
  preflight_env "$home" 108 verify-recovery correction-a1 --fingerprint "$fp2" >/dev/null \
    || fail "recovery must accept its original approved contract"

  make_contract "$contract" true
  fp=$(publish_preflight_record "$home" bypass-a1 "$contract" direct approved 200) || fail "approved complete plan should bypass duplicate preflight"
  preflight_env "$home" 201 verify bypass-a1 --fingerprint "$fp" >/dev/null || fail "approved complete plan did not verify"
  pass "corrections, stale approvals, and approved complete plans fail closed"
}

test_preflight_rejects_tampering_and_future_approvals() {
  local home="$TMP_ROOT/tamper" contract="$TMP_ROOT/tamper-contract.json" out fp status
  mkdir -p "$home/data"
  make_contract "$contract"
  fp=$(publish_preflight_record "$home" tamper-a1 "$contract" direct approved 100) || fail "tamper preflight create failed"
  out=$(preflight_env "$home" 99 verify tamper-a1 --fingerprint "$fp" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "future approvals must refuse verification"
  assert_contains "$out" "in the future" "future approval refusal was unclear"
  jq '.contract.outcome = "changed after approval"' "$home/data/tamper-a1/ship-preflight.json" > "$home/tampered.json"
  chmod 600 "$home/tampered.json"
  mv "$home/tampered.json" "$home/data/tamper-a1/ship-preflight.json"
  out=$(preflight_env "$home" 101 verify tamper-a1 --fingerprint "$fp" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a record whose contract changed after approval must refuse"
  assert_contains "$out" "fingerprint does not match" "tampered contract refusal was unclear"
  pass "preflight verifies its approved contract and approval clock"
}

test_preflight_rejects_cross_task_records() {
  local home="$TMP_ROOT/cross-task" contract="$TMP_ROOT/cross-task-contract.json" out fp status unsafe_mode
  mkdir -p "$home/data"
  make_contract "$contract"
  fp=$(publish_preflight_record "$home" approved-a1 "$contract" direct approved 100) || fail "cross-task preflight approval failed"
  chmod 733 "$home/data"
  out=$(preflight_env "$home" 101 verify-current approved-a1 2>&1)
  status=$?
  chmod 755 "$home/data"
  [ "$status" -ne 0 ] || fail "a preflight under a writable data directory must refuse"
  assert_contains "$out" "unsafe task record directory" "writable data directory refusal was unclear"

  for unsafe_mode in 733 740 704; do
    chmod "$unsafe_mode" "$home/data/approved-a1"
    out=$(preflight_env "$home" 101 verify-current approved-a1 2>&1)
    status=$?
    chmod 700 "$home/data/approved-a1"
    [ "$status" -ne 0 ] || fail "a preflight under a nonprivate task directory must refuse: $unsafe_mode"
    assert_contains "$out" "unsafe task record directory" "nonprivate task directory refusal was unclear: $unsafe_mode"
  done

  ln -s "$home/data" "$home/linked-data"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/linked-data" FM_STATE_OVERRIDE="$home/state" FM_SHIP_PREFLIGHT_NOW=101 "$PREFLIGHT" verify-current approved-a1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a preflight under a linked data directory must refuse"
  assert_contains "$out" "unsafe task record directory" "linked data directory refusal was unclear"

  ln -s "$home/data/approved-a1" "$home/data/aliased-a1"
  out=$(preflight_env "$home" 101 verify-current aliased-a1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a task directory symlink reused another task's approved preflight"
  assert_contains "$out" "unsafe task record directory" "cross-task preflight refusal was unclear"

  mkdir -p "$home/data/copied-a1"
  chmod 700 "$home/data/copied-a1"
  cp "$home/data/approved-a1/ship-preflight.json" "$home/data/copied-a1/ship-preflight.json"
  chmod 600 "$home/data/copied-a1/ship-preflight.json"
  out=$(preflight_env "$home" 101 verify-current copied-a1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a copied preflight record authorized a different task"
  assert_contains "$out" "malformed preflight record" "copied preflight refusal was unclear"

  mkdir -p "$home/data/linked-a1"
  chmod 700 "$home/data/linked-a1"
  ln "$home/data/approved-a1/ship-preflight.json" "$home/data/linked-a1/ship-preflight.json"
  out=$(preflight_env "$home" 101 verify-current linked-a1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a hard-linked preflight record authorized a different task"
  assert_contains "$out" "no valid private preflight record" "hard-linked preflight refusal was unclear"

  mkdir -p "$home/data/empty-a1"
  chmod 700 "$home/data/empty-a1"
  jq -n --arg id empty-a1 \
    '{schema_version:1,workflow:"ship-end-to-end",task_id:$id,fingerprint:"0000000000000000000000000000000000000000000000000000000000000000",origin:"bridge",state:"approved",contract:{},producer_revision:1,approval:{authority:"agent-bridge",evidence:"bridge-submission",approved_at:100,complete_plan_bypass:false}}' > "$home/data/empty-a1/ship-preflight.json"
  chmod 600 "$home/data/empty-a1/ship-preflight.json"
  out=$(preflight_env "$home" 101 verify-current empty-a1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an empty bridge contract authorized a task"
  assert_contains "$out" "malformed preflight contract" "empty bridge contract refusal was unclear"
  pass "preflight refuses cross-task records and empty bridge contracts"
}

test_bridge_preserves_handoff_when_record_directories_are_unsafe() {
  local home="$TMP_ROOT/bridge-unsafe-directories" contract="$TMP_ROOT/bridge-unsafe-directories-contract.json" out status unsafe_mode
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"

  write_bridge_handoff "$home" data-unsafe-a1 "$contract" bridge approved 100 >/dev/null || fail "could not write data-directory handoff"
  chmod 733 "$home/data"
  out=$(bridge_env "$home" publish data-unsafe-a1 2>&1)
  status=$?
  chmod 755 "$home/data"
  [ "$status" -ne 0 ] || fail "bridge published through a writable data directory"
  assert_contains "$out" "unsafe task record directory" "unsafe data directory refusal was unclear"
  [ -f "$home/state/agent-bridge/ship-preflight/data-unsafe-a1.json" ] \
    || fail "unsafe data directory publication consumed its handoff"
  assert_absent "$home/data/data-unsafe-a1/ship-preflight.json" "unsafe data directory publication wrote a record"

  for unsafe_mode in 733 740 704; do
    write_bridge_handoff "$home" "task-unsafe-$unsafe_mode" "$contract" bridge approved 100 >/dev/null || fail "could not write task-directory handoff"
    mkdir "$home/data/task-unsafe-$unsafe_mode"
    chmod "$unsafe_mode" "$home/data/task-unsafe-$unsafe_mode"
    out=$(bridge_env "$home" publish "task-unsafe-$unsafe_mode" 2>&1)
    status=$?
    chmod 700 "$home/data/task-unsafe-$unsafe_mode"
    [ "$status" -ne 0 ] || fail "bridge published through a nonprivate task directory: $unsafe_mode"
    assert_contains "$out" "unsafe task record directory" "unsafe task directory refusal was unclear: $unsafe_mode"
    [ -f "$home/state/agent-bridge/ship-preflight/task-unsafe-$unsafe_mode.json" ] \
      || fail "unsafe task directory publication consumed its handoff: $unsafe_mode"
    assert_absent "$home/data/task-unsafe-$unsafe_mode/ship-preflight.json" "unsafe task directory publication wrote a record: $unsafe_mode"
  done
  pass "bridge preserves handoffs when record directories are unsafe"
}

test_bridge_claims_a_handoff_before_reading_it() {
  local home="$TMP_ROOT/bridge-claim" id=claim-a1 original="$TMP_ROOT/bridge-claim-original.json" corrected="$TMP_ROOT/bridge-claim-corrected.json" handoff producer fakebin real_dd
  mkdir -p "$home/data" "$home/state"
  make_contract "$original"
  printf '%s\n' '{"recommendation":"Build it","outcome":"Corrected tested PR","scope":"One change","non_goals":"No deploy","delivery_boundary":"pr-only","external_boundaries":"No production write","questions":[]}' > "$corrected"
  handoff="$home/state/agent-bridge/ship-preflight/$id.json"

  write_bridge_handoff "$home" "$id" "$corrected" direct awaiting_approval 101 2 >/dev/null || fail "could not prepare corrected producer handoff"
  producer=$(umask 077; mktemp "${handoff%/*}/.producer.XXXXXX") || fail "could not reserve corrected producer handoff"
  mv -f -- "$handoff" "$producer" || fail "could not stage corrected producer handoff"
  write_bridge_handoff "$home" "$id" "$original" direct approved 100 >/dev/null || fail "could not prepare original consumer handoff"

  fakebin="$TMP_ROOT/bridge-claim-bin"
  mkdir -p "$fakebin"
  real_dd=$(command -v dd)
  cat > "$fakebin/dd" <<'SH'
#!/usr/bin/env bash
set -eu
for arg in "$@"; do
  case "$arg" in
    if="$FM_BRIDGE_RACE_DIR"/*) mv -f -- "$FM_BRIDGE_RACE_REPLACEMENT" "$FM_BRIDGE_RACE_HANDOFF" ;;
  esac
done
exec "$FM_BRIDGE_REAL_DD" "$@"
SH
  chmod +x "$fakebin/dd"
  PATH="$fakebin:$PATH" FM_BRIDGE_RACE_DIR="${handoff%/*}" FM_BRIDGE_RACE_REPLACEMENT="$producer" FM_BRIDGE_RACE_HANDOFF="$handoff" FM_BRIDGE_REAL_DD="$real_dd" \
    bridge_env "$home" publish "$id" >/dev/null || fail "bridge did not publish its claimed handoff"
  jq -e '.state == "approved" and .contract.outcome == "A tested PR"' "$home/data/$id/ship-preflight.json" >/dev/null \
    || fail "bridge did not publish the handoff it claimed"
  jq -e '.state == "awaiting_approval" and .contract.outcome == "Corrected tested PR"' "$handoff" >/dev/null \
    || fail "bridge consumed a newer producer handoff"
  pass "bridge preserves a newer handoff published during record creation"
}

test_bridge_recovers_a_claim_after_interruption() {
  local home="$TMP_ROOT/bridge-claim-recovery" id=claim-recovery-a1 contract="$TMP_ROOT/bridge-claim-recovery-contract.json" handoff claim
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"
  write_bridge_handoff "$home" "$id" "$contract" direct approved 100 >/dev/null || fail "could not prepare interrupted bridge handoff"
  handoff="$home/state/agent-bridge/ship-preflight/$id.json"
  claim="${handoff%/*}/.${id}.claim.interrupted"
  mv -f -- "$handoff" "$claim" || fail "could not stage interrupted bridge claim"
  assert_absent "$home/data/$id/ship-preflight.json" "interruption published a preflight record"
  bridge_env "$home" publish "$id" >/dev/null || fail "bridge did not recover its interrupted claim"
  jq -e '.state == "approved" and .contract.outcome == "A tested PR"' "$home/data/$id/ship-preflight.json" >/dev/null \
    || fail "recovered bridge handoff did not publish its original record"
  assert_absent "$home/state/agent-bridge/ship-preflight/$id.json" "recovered bridge handoff remained pending"
  assert_absent "$claim" "recovered bridge claim remained stranded"
  pass "bridge recovers a claimed handoff after interruption"
}

test_bridge_restores_a_claim_interrupted_after_rename() {
  local home="$TMP_ROOT/bridge-rename-interruption" id=rename-interruption-a1 contract="$TMP_ROOT/bridge-rename-interruption-contract.json" handoff fakebin real_mv ready release target_pid publisher attempts status
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"
  write_bridge_handoff "$home" "$id" "$contract" direct approved 100 >/dev/null || fail "could not prepare rename-interrupted bridge handoff"
  handoff="$home/state/agent-bridge/ship-preflight/$id.json"
  fakebin="$TMP_ROOT/bridge-rename-interruption-bin"
  mkdir -p "$fakebin"
  real_mv=$(command -v mv)
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -eu
interrupt=0
for arg in "$@"; do
  [ "$arg" != "$FM_BRIDGE_INTERRUPT_HANDOFF" ] || interrupt=1
done
"$FM_BRIDGE_REAL_MV" "$@"
[ "$interrupt" -eq 0 ] || {
  printf '%s\n' "$PPID" > "$FM_BRIDGE_INTERRUPT_PID"
  : > "$FM_BRIDGE_INTERRUPT_READY"
  while [ ! -e "$FM_BRIDGE_INTERRUPT_RELEASE" ]; do sleep 0.01; done
}
SH
  chmod +x "$fakebin/mv"

  ready="$home/rename-ready"
  release="$home/rename-release"
  PATH="$fakebin:$PATH" FM_BRIDGE_INTERRUPT_HANDOFF="$handoff" FM_BRIDGE_REAL_MV="$real_mv" FM_BRIDGE_INTERRUPT_PID="$home/rename-pid" FM_BRIDGE_INTERRUPT_READY="$ready" FM_BRIDGE_INTERRUPT_RELEASE="$release" \
    bridge_env "$home" publish "$id" > "$home/rename-publish.out" 2>&1 &
  publisher=$!
  attempts=0
  while [ ! -e "$ready" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$ready" ]; then
    kill "$publisher" 2>/dev/null || true
    : > "$release"
    wait "$publisher" 2>/dev/null || true
    fail "rename interruption did not reach the claimed handoff"
  fi
  target_pid=$(cat "$home/rename-pid")
  kill -TERM "$target_pid" || fail "could not interrupt the claiming bridge process"
  : > "$release"
  wait "$publisher"
  status=$?
  [ "$status" -ne 0 ] || fail "rename interruption did not stop bridge publication"
  [ -f "$handoff" ] || fail "rename interruption lost the bridge handoff"
  jq -e '.state == "approved" and .contract.outcome == "A tested PR"' "$handoff" >/dev/null \
    || fail "rename interruption did not restore the original handoff"
  assert_absent "$home/data/$id/ship-preflight.json" "rename interruption published a preflight record"
  bridge_env "$home" publish "$id" >/dev/null || fail "bridge did not publish the restored rename-interrupted handoff"
  jq -e '.state == "approved" and .contract.outcome == "A tested PR"' "$home/data/$id/ship-preflight.json" >/dev/null \
    || fail "restored rename-interrupted handoff did not publish"
  pass "bridge restores a claim interrupted after rename"
}

test_bridge_preserves_claimed_correction_on_cleanup_conflict() {
  local home="$TMP_ROOT/bridge-cleanup-conflict" id=cleanup-conflict-a1 original="$TMP_ROOT/bridge-cleanup-conflict-original.json" corrected="$TMP_ROOT/bridge-cleanup-conflict-corrected.json" handoff claim fakebin real_dd ready release target_pid publisher attempts out status
  mkdir -p "$home/data" "$home/state"
  make_contract "$original"
  printf '%s\n' '{"recommendation":"Build it","outcome":"Corrected tested PR","scope":"One change","non_goals":"No deploy","delivery_boundary":"pr-only","external_boundaries":"No production write","questions":[]}' > "$corrected"
  write_bridge_handoff "$home" "$id" "$corrected" direct awaiting_approval 101 2 >/dev/null || fail "could not prepare claimed correction"
  handoff="$home/state/agent-bridge/ship-preflight/$id.json"
  claim="${handoff%/*}/.${id}.claim."
  fakebin="$TMP_ROOT/bridge-cleanup-conflict-bin"
  mkdir -p "$fakebin"
  real_dd=$(command -v dd)
  cat > "$fakebin/dd" <<'SH'
#!/usr/bin/env bash
set -eu
for arg in "$@"; do
  if [[ "$arg" == if="$FM_BRIDGE_INTERRUPT_CLAIM"* ]]; then
    printf '%s\n' "$PPID" > "$FM_BRIDGE_INTERRUPT_PID"
    : > "$FM_BRIDGE_INTERRUPT_READY"
    while [ ! -e "$FM_BRIDGE_INTERRUPT_RELEASE" ]; do sleep 0.01; done
  fi
done
exec "$FM_BRIDGE_REAL_DD" "$@"
SH
  chmod +x "$fakebin/dd"
  ready="$home/cleanup-ready"
  release="$home/cleanup-release"
  PATH="$fakebin:$PATH" FM_BRIDGE_INTERRUPT_CLAIM="$claim" FM_BRIDGE_REAL_DD="$real_dd" FM_BRIDGE_INTERRUPT_PID="$home/cleanup-pid" FM_BRIDGE_INTERRUPT_READY="$ready" FM_BRIDGE_INTERRUPT_RELEASE="$release" \
    bridge_env "$home" publish "$id" > "$home/cleanup-publish.out" 2>&1 &
  publisher=$!
  attempts=0
  while [ ! -e "$ready" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$ready" ]; then
    kill "$publisher" 2>/dev/null || true
    : > "$release"
    wait "$publisher" 2>/dev/null || true
    fail "cleanup interruption did not reach the claimed handoff"
  fi
  claim=$(find "${handoff%/*}" -maxdepth 1 -type f -name ".${id}.claim.*" -print -quit)
  [ -n "$claim" ] || fail "cleanup interruption did not create a claimed handoff"
  write_bridge_handoff "$home" "$id" "$original" direct approved 100 1 >/dev/null || fail "could not prepare delayed handoff"
  target_pid=$(cat "$home/cleanup-pid")
  kill -TERM "$target_pid" || fail "could not interrupt the validating bridge process"
  : > "$release"
  wait "$publisher"
  status=$?
  [ "$status" -ne 0 ] || fail "cleanup interruption did not stop bridge publication"
  jq -e '.producer_revision == 2 and .state == "awaiting_approval" and .contract.outcome == "Corrected tested PR"' "$claim" >/dev/null \
    || fail "cleanup conflict changed the claimed correction"
  jq -e '.producer_revision == 1 and .state == "approved" and .contract.outcome == "A tested PR"' "$handoff" >/dev/null \
    || fail "cleanup conflict did not preserve the delayed handoff"
  assert_absent "$home/data/$id/ship-preflight.json" "cleanup conflict published a stale preflight record"
  rm -f -- "$handoff" || fail "could not remove delayed cleanup handoff"
  bridge_env "$home" publish "$id" >/dev/null || fail "bridge did not recover the claimed correction after cleanup-conflict resolution"
  jq -e '.producer_revision == 2 and .state == "awaiting_approval" and .contract.outcome == "Corrected tested PR"' "$home/data/$id/ship-preflight.json" >/dev/null \
    || fail "cleanup-conflict recovery did not preserve the corrected preflight"
  assert_absent "$claim" "cleanup-conflict correction claim remained stranded after recovery"
  pass "bridge preserves claimed corrections on cleanup conflicts"
}

test_bridge_recovers_a_hard_linked_claim_after_interruption() {
  local home="$TMP_ROOT/bridge-hard-link-recovery" id=hard-link-recovery-a1 contract="$TMP_ROOT/bridge-hard-link-recovery-contract.json" handoff claim
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"
  write_bridge_handoff "$home" "$id" "$contract" direct approved 100 >/dev/null || fail "could not prepare hard-linked bridge handoff"
  handoff="$home/state/agent-bridge/ship-preflight/$id.json"
  claim="${handoff%/*}/.${id}.claim.hard-link"
  ln "$handoff" "$claim" || fail "could not stage hard-linked interrupted claim"
  bridge_env "$home" publish "$id" >/dev/null || fail "bridge did not recover its hard-linked claim"
  jq -e '.state == "approved" and .contract.outcome == "A tested PR"' "$home/data/$id/ship-preflight.json" >/dev/null \
    || fail "hard-linked bridge claim did not publish its original record"
  assert_absent "$claim" "recovered hard-linked bridge claim remained stranded"
  assert_absent "$handoff" "recovered hard-linked bridge handoff remained pending"
  pass "bridge recovers a hard-linked claim after interruption"
}

test_bridge_preserves_claimed_correction_against_delayed_handoff() {
  local home="$TMP_ROOT/bridge-claimed-correction" id=claimed-correction-a1 original="$TMP_ROOT/bridge-claimed-correction-original.json" corrected="$TMP_ROOT/bridge-claimed-correction-corrected.json" handoff claim out status
  mkdir -p "$home/data" "$home/state"
  make_contract "$original"
  printf '%s\n' '{"recommendation":"Build it","outcome":"Corrected tested PR","scope":"One change","non_goals":"No deploy","delivery_boundary":"pr-only","external_boundaries":"No production write","questions":[]}' > "$corrected"
  write_bridge_handoff "$home" "$id" "$corrected" direct awaiting_approval 101 2 >/dev/null || fail "could not prepare claimed correction"
  handoff="$home/state/agent-bridge/ship-preflight/$id.json"
  claim="${handoff%/*}/.${id}.claim.interrupted"
  mv -f -- "$handoff" "$claim" || fail "could not stage interrupted correction claim"
  write_bridge_handoff "$home" "$id" "$original" direct approved 100 1 >/dev/null || fail "could not prepare delayed handoff"
  out=$(bridge_env "$home" publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a delayed handoff displaced a claimed correction"
  assert_contains "$out" "competing private bridge handoffs" "competing handoff refusal was unclear"
  jq -e '.producer_revision == 2 and .state == "awaiting_approval" and .contract.outcome == "Corrected tested PR"' "$claim" >/dev/null \
    || fail "delayed handoff changed the claimed correction"
  jq -e '.producer_revision == 1 and .state == "approved" and .contract.outcome == "A tested PR"' "$handoff" >/dev/null \
    || fail "competing handoff was not preserved for resolution"
  assert_absent "$home/data/$id/ship-preflight.json" "competing handoffs published a preflight record"
  rm -f -- "$handoff" || fail "could not remove delayed handoff"
  bridge_env "$home" publish "$id" >/dev/null || fail "bridge did not recover the claimed correction after conflict resolution"
  jq -e '.producer_revision == 2 and .state == "awaiting_approval" and .contract.outcome == "Corrected tested PR"' "$home/data/$id/ship-preflight.json" >/dev/null \
    || fail "recovered claim did not preserve the corrected preflight"
  assert_absent "$claim" "recovered correction claim remained stranded"
  pass "bridge preserves claimed corrections against delayed handoffs"
}

test_bridge_preserves_claimed_correction_on_link_race() {
  local home="$TMP_ROOT/bridge-claim-link-race" id=claim-link-race-a1 original="$TMP_ROOT/bridge-claim-link-race-original.json" corrected="$TMP_ROOT/bridge-claim-link-race-corrected.json" handoff claim delayed fakebin real_ln out status
  mkdir -p "$home/data" "$home/state"
  make_contract "$original"
  printf '%s\n' '{"recommendation":"Build it","outcome":"Corrected tested PR","scope":"One change","non_goals":"No deploy","delivery_boundary":"pr-only","external_boundaries":"No production write","questions":[]}' > "$corrected"
  write_bridge_handoff "$home" "$id" "$corrected" direct awaiting_approval 101 2 >/dev/null || fail "could not prepare claimed correction"
  handoff="$home/state/agent-bridge/ship-preflight/$id.json"
  claim="${handoff%/*}/.${id}.claim.interrupted"
  delayed="${handoff%/*}/.${id}.delayed"
  mv -f -- "$handoff" "$claim" || fail "could not stage interrupted correction claim"
  write_bridge_handoff "$home" "$id" "$original" direct approved 100 1 >/dev/null || fail "could not prepare delayed handoff"
  mv -f -- "$handoff" "$delayed" || fail "could not reserve delayed handoff"
  fakebin="$TMP_ROOT/bridge-claim-link-race-bin"
  mkdir -p "$fakebin"
  real_ln=$(command -v ln)
  cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "$1" = "$FM_BRIDGE_RACE_CLAIM" ] && [ "$2" = "$FM_BRIDGE_RACE_HANDOFF" ]; then
  mv -f -- "$FM_BRIDGE_RACE_DELAYED" "$FM_BRIDGE_RACE_HANDOFF"
fi
exec "$FM_BRIDGE_REAL_LN" "$@"
SH
  chmod +x "$fakebin/ln"
  out=$(PATH="$fakebin:$PATH" FM_BRIDGE_RACE_CLAIM="$claim" FM_BRIDGE_RACE_HANDOFF="$handoff" FM_BRIDGE_RACE_DELAYED="$delayed" FM_BRIDGE_REAL_LN="$real_ln" bridge_env "$home" publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a delayed link-race handoff displaced a claimed correction"
  assert_contains "$out" "competing private bridge handoffs" "link-race refusal was unclear"
  jq -e '.producer_revision == 2 and .state == "awaiting_approval" and .contract.outcome == "Corrected tested PR"' "$claim" >/dev/null \
    || fail "link race changed the claimed correction"
  jq -e '.producer_revision == 1 and .state == "approved" and .contract.outcome == "A tested PR"' "$handoff" >/dev/null \
    || fail "link race did not preserve the delayed handoff"
  assert_absent "$home/data/$id/ship-preflight.json" "link race published a stale preflight record"
  rm -f -- "$handoff" || fail "could not remove delayed link-race handoff"
  bridge_env "$home" publish "$id" >/dev/null || fail "bridge did not recover the claimed correction after link-race resolution"
  jq -e '.producer_revision == 2 and .state == "awaiting_approval" and .contract.outcome == "Corrected tested PR"' "$home/data/$id/ship-preflight.json" >/dev/null \
    || fail "link-race recovery did not preserve the corrected preflight"
  assert_absent "$claim" "link-race correction claim remained stranded after recovery"
  pass "bridge preserves claimed corrections on link races"
}

test_bridge_serializes_concurrent_publish_claims() {
  local home="$TMP_ROOT/bridge-concurrent" id=concurrent-a1 contract="$TMP_ROOT/bridge-concurrent-contract.json" fakebin real_mktemp first second attempts first_status second_status
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"
  write_bridge_handoff "$home" "$id" "$contract" direct approved 100 >/dev/null || fail "could not prepare concurrent bridge handoff"
  fakebin="$TMP_ROOT/bridge-concurrent-bin"
  mkdir -p "$fakebin"
  real_mktemp=$(command -v mktemp)
  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1" in
  "$FM_BRIDGE_CONCURRENT_DIR"/.*.claim.*)
    if [ ! -e "$FM_BRIDGE_CONCURRENT_READY" ]; then
      : > "$FM_BRIDGE_CONCURRENT_READY"
      while [ ! -e "$FM_BRIDGE_CONCURRENT_RELEASE" ]; do sleep 0.01; done
    fi
    ;;
esac
exec "$FM_BRIDGE_REAL_MKTEMP" "$@"
SH
  chmod +x "$fakebin/mktemp"
  PATH="$fakebin:$PATH" FM_BRIDGE_CONCURRENT_DIR="$home/state/agent-bridge/ship-preflight" FM_BRIDGE_CONCURRENT_READY="$home/first-ready" FM_BRIDGE_CONCURRENT_RELEASE="$home/release-first" FM_BRIDGE_REAL_MKTEMP="$real_mktemp" \
    bridge_env "$home" publish "$id" > "$home/first.out" 2>&1 &
  first=$!
  attempts=0
  while [ ! -e "$home/first-ready" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$home/first-ready" ]; then
    kill "$first" 2>/dev/null || true
    wait "$first" 2>/dev/null || true
    fail "first bridge publish did not hold its claim path"
  fi
  bridge_env "$home" publish "$id" > "$home/second.out" 2>&1 &
  second=$!
  sleep 0.1
  if ! kill -0 "$second" 2>/dev/null; then
    : > "$home/release-first"
    wait "$first" 2>/dev/null || true
    wait "$second" 2>/dev/null || true
    fail "second bridge publish bypassed the task lock"
  fi
  : > "$home/release-first"
  wait "$first"; first_status=$?
  wait "$second"; second_status=$?
  expect_code 0 "$first_status" "first bridge publish should complete"
  [ "$second_status" -ne 0 ] || fail "second bridge publish should refuse its consumed handoff"
  jq -e '.state == "approved" and .contract.outcome == "A tested PR"' "$home/data/$id/ship-preflight.json" >/dev/null \
    || fail "concurrent bridge publication corrupted the durable preflight"
  assert_absent "$home/state/agent-bridge/ship-preflight/$id.json" "concurrent bridge publication recreated an empty handoff"
  pass "bridge serializes concurrent publish claims without an empty handoff"
}

test_bridge_preserves_approved_record_on_invalid_handoff() {
  local home="$TMP_ROOT/bridge-invalid" id=invalid-bridge-a1 contract="$TMP_ROOT/bridge-invalid-contract.json" fp handoff out status
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"
  fp=$(publish_preflight_record "$home" "$id" "$contract" bridge approved 100) || fail "could not publish approved baseline"
  write_bridge_handoff "$home" "$id" "$contract" bridge approved 101 >/dev/null || fail "could not prepare malformed handoff"
  handoff="$home/state/agent-bridge/ship-preflight/$id.json"
  jq 'del(.contract.outcome)' "$handoff" > "$home/malformed.json" || fail "could not corrupt handoff fixture"
  chmod 600 "$home/malformed.json" && mv -f "$home/malformed.json" "$handoff" || fail "could not publish malformed handoff fixture"
  out=$(bridge_env "$home" publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "malformed bridge handoff replaced an approved record"
  assert_contains "$out" "invalid typed private bridge handoff" "malformed handoff refusal was unclear"
  preflight_env "$home" 101 verify "$id" --fingerprint "$fp" >/dev/null || fail "malformed handoff changed the approved record"
  [ -f "$handoff" ] || fail "malformed handoff was not restored"
  pass "bridge preserves approved records when a handoff is malformed"
}

test_bridge_rejects_stale_producer_revisions() {
  local home="$TMP_ROOT/bridge-producer-revision" id=producer-revision-a1 original="$TMP_ROOT/bridge-producer-revision-original.json" corrected="$TMP_ROOT/bridge-producer-revision-corrected.json" original_fp corrected_fp handoff out status
  mkdir -p "$home/data" "$home/state"
  make_contract "$original"
  printf '%s\n' '{"recommendation":"Build it","outcome":"Corrected tested PR","scope":"One change","non_goals":"No deploy","delivery_boundary":"pr-only","external_boundaries":"No production write","questions":[]}' > "$corrected"
  original_fp=$(publish_preflight_record "$home" "$id" "$original" direct approved 100 1) || fail "could not publish initial producer revision"
  corrected_fp=$(publish_preflight_record "$home" "$id" "$corrected" direct awaiting_approval 101 2) || fail "could not publish corrected producer revision"
  write_bridge_handoff "$home" "$id" "$original" direct approved 100 1 >/dev/null || fail "could not stage delayed producer handoff"
  out=$(bridge_env "$home" publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a delayed producer handoff replaced a correction"
  assert_contains "$out" "does not advance" "stale producer handoff refusal was unclear"
  jq -e --arg fp "$corrected_fp" '.producer_revision == 2 and .state == "awaiting_approval" and .fingerprint == $fp' "$home/data/$id/ship-preflight.json" >/dev/null \
    || fail "stale producer handoff changed the durable preflight"
  find "$home/data/$id" -maxdepth 1 -type f -name '.ship-preflight.*' | grep -q . \
    && fail "stale producer handoff left an unpublished preflight record"
  out=$(preflight_env "$home" 101 verify-recovery "$id" --fingerprint "$original_fp" 2>&1)
  status=$?
  expect_code 4 "$status" "recovery accepted the delayed producer approval"
  handoff="$home/state/agent-bridge/ship-preflight/$id.json"
  jq '.producer_revision = 2.5' "$handoff" > "$home/non-integer-revision.json" || fail "could not corrupt producer revision"
  chmod 600 "$home/non-integer-revision.json" && mv -f "$home/non-integer-revision.json" "$handoff" || fail "could not stage a malformed producer revision"
  out=$(bridge_env "$home" publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a non-integer producer revision was accepted"
  assert_contains "$out" "invalid typed private bridge handoff" "malformed producer revision refusal was unclear"
  jq -e --arg fp "$corrected_fp" '.producer_revision == 2 and .state == "awaiting_approval" and .fingerprint == $fp' "$home/data/$id/ship-preflight.json" >/dev/null \
    || fail "malformed producer revision changed the durable preflight"
  find "$home/data/$id" -maxdepth 1 -type f -name '.ship-preflight.*' | grep -q . \
    && fail "malformed producer revision left an unpublished preflight record"
  pass "bridge preserves corrections against stale producer revisions"
}

test_bridge_rejects_unversioned_current_records() {
  local home="$TMP_ROOT/bridge-unversioned-record" id=unversioned-record-a1 original="$TMP_ROOT/bridge-unversioned-record-original.json" corrected="$TMP_ROOT/bridge-unversioned-record-corrected.json" original_fp corrected_fp handoff out status
  mkdir -p "$home/data" "$home/state"
  make_contract "$original"
  printf '%s\n' '{"recommendation":"Build it","outcome":"Corrected tested PR","scope":"One change","non_goals":"No deploy","delivery_boundary":"pr-only","external_boundaries":"No production write","questions":[]}' > "$corrected"
  original_fp=$(publish_preflight_record "$home" "$id" "$original" direct approved 100 1) || fail "could not publish initial preflight"
  corrected_fp=$(publish_preflight_record "$home" "$id" "$corrected" direct awaiting_approval 101 2) || fail "could not publish corrected preflight"
  jq 'del(.producer_revision)' "$home/data/$id/ship-preflight.json" > "$home/unversioned.json" || fail "could not prepare unversioned preflight"
  chmod 600 "$home/unversioned.json" && mv -f "$home/unversioned.json" "$home/data/$id/ship-preflight.json" || fail "could not publish unversioned preflight"
  write_bridge_handoff "$home" "$id" "$original" direct approved 100 1 >/dev/null || fail "could not stage delayed preflight handoff"
  out=$(bridge_env "$home" publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an unversioned correction accepted a delayed approval"
  assert_contains "$out" "existing preflight producer revision is malformed" "unversioned preflight refusal was unclear"
  jq -e --arg fp "$corrected_fp" '(has("producer_revision") | not) and .state == "awaiting_approval" and .fingerprint == $fp' "$home/data/$id/ship-preflight.json" >/dev/null \
    || fail "delayed approval changed the unversioned correction"
  out=$(preflight_env "$home" 101 verify-recovery "$id" --fingerprint "$original_fp" 2>&1)
  status=$?
  expect_code 1 "$status" "recovery accepted an unversioned preflight"
  assert_contains "$out" "malformed preflight record" "unversioned recovery refusal was unclear"
  handoff="$home/state/agent-bridge/ship-preflight/$id.json"
  [ -f "$handoff" ] || fail "unversioned preflight refusal consumed the delayed handoff"
  find "$home/data/$id" -maxdepth 1 -type f -name '.ship-preflight.*' | grep -q . \
    && fail "unversioned preflight refusal left an unpublished record"
  pass "bridge rejects unversioned current preflight records"
}

test_spawn_enforces_the_durable_preflight() {
  local home="$TMP_ROOT/spawn" project="$TMP_ROOT/spawn-project" contract="$TMP_ROOT/spawn-contract.json" corrected="$TMP_ROOT/spawn-corrected.json" racebin="$TMP_ROOT/spawn-race-bin" submitbin="$TMP_ROOT/spawn-submit-bin" submit_remote="$TMP_ROOT/spawn-submit-remote.git" submit_worktree="$TMP_ROOT/spawn-submit-worktree" submit_events="$TMP_ROOT/spawn-submit-events" submit_out="$TMP_ROOT/spawn-submit-publish.out" submit_status="$TMP_ROOT/spawn-submit-publish-status" submit_launch="$TMP_ROOT/spawn-submit-launch-literal" out fp status attempts submitted_line published_line
  mkdir -p "$home/data" "$home/state" "$home/config" "$project"
  make_contract "$contract"
  mkdir -p "$home/data/missing-a1"
  printf '%s\n' 'Delivery contract: mode=no-mistakes' > "$home/data/missing-a1/brief.md"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux "$ROOT/bin/fm-spawn.sh" missing-a1 "$project" --mode no-mistakes --yolo off --harness codex 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a missing durable preflight must refuse spawn"
  assert_contains "$out" "preflight record for missing-a1 is missing" "missing preflight refusal was unclear"
  assert_absent "$home/state/missing-a1.meta" "missing preflight refusal wrote task metadata"
  fp=$(publish_preflight_record "$home" spawn-a1 "$contract" direct awaiting_approval 100) || fail "spawn preflight create failed"
  mkdir -p "$home/data/spawn-a1"
  printf '%s\n' 'Delivery contract: mode=no-mistakes' > "$home/data/spawn-a1/brief.md"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux "$ROOT/bin/fm-spawn.sh" spawn-a1 "$project" --mode no-mistakes --yolo off --harness codex 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unapproved durable preflight must refuse spawn"
  assert_contains "$out" "preflight approval is missing" "spawn did not verify the durable preflight"
  assert_absent "$home/state/spawn-a1.meta" "preflight refusal wrote task metadata"

  make_contract "$corrected"
  printf '%s\n' '{"recommendation":"Build it","outcome":"Corrected tested PR","scope":"One change","non_goals":"No deploy","delivery_boundary":"pr-only","external_boundaries":"No production write","questions":[]}' > "$corrected"
  fp=$(publish_preflight_record "$home" race-a1 "$contract" direct approved 100) || fail "race preflight create failed"
  printf '%s\n' 'Delivery contract: mode=no-mistakes' > "$home/data/race-a1/brief.md"
  write_bridge_handoff "$home" race-a1 "$corrected" direct awaiting_approval 101 2 >/dev/null || fail "race correction handoff could not be prepared"
  mkdir -p "$racebin"
  cat > "$racebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_RACE_TMUX_LOG"
exit 1
SH
  chmod +x "$racebin/tmux"
  out=$(bridge_env "$home" publish race-a1 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "publisher-first correction did not finish"
  assert_contains "$out" "published" "publisher-first correction did not complete"
  out=$(PATH="$racebin:$PATH" FM_RACE_TMUX_LOG="$home/race-tmux.log" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_SHIP_PREFLIGHT_NOW=101 "$ROOT/bin/fm-spawn.sh" race-a1 "$project" --mode no-mistakes --yolo off --harness codex 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a corrected preflight must refuse spawn"
  assert_contains "$out" "preflight approval is missing" "corrected preflight refusal was unclear"
  jq -e '.state == "awaiting_approval" and .contract.outcome == "Corrected tested PR"' "$home/data/race-a1/ship-preflight.json" >/dev/null \
    || fail "publisher-first correction did not replace the preflight record"
  assert_absent "$home/state/race-a1.meta" "corrected preflight spawn wrote task metadata"
  [ ! -s "$home/race-tmux.log" ] || fail "corrected preflight created an endpoint"

  git init --bare -q "$submit_remote" || fail "could not create submit test remote"
  git -C "$project" init -q || fail "could not create submit test project"
  git -C "$project" config user.email test@example.invalid || fail "could not configure submit test author"
  git -C "$project" config user.name Test || fail "could not configure submit test author"
  printf '%s\n' 'submit test' > "$project/README.md"
  git -C "$project" add README.md || fail "could not stage submit test project"
  git -C "$project" commit -qm initial || fail "could not commit submit test project"
  git -C "$project" branch -M main || fail "could not name submit test branch"
  git -C "$project" remote add origin "$submit_remote" || fail "could not configure submit test remote"
  git -C "$project" push -qu origin main || fail "could not publish submit test base"
  git --git-dir="$submit_remote" symbolic-ref HEAD refs/heads/main || fail "could not set submit test default branch"
  git clone -q "$submit_remote" "$submit_worktree" || fail "could not create submit test worktree"
  fp=$(publish_preflight_record "$home" race-submit-a1 "$contract" direct approved 100) || fail "submit race preflight create failed"
  printf '%s\n' 'Delivery contract: mode=no-mistakes' > "$home/data/race-submit-a1/brief.md"
  write_bridge_handoff "$home" race-submit-a1 "$corrected" direct awaiting_approval 101 2 >/dev/null || fail "submit race correction handoff could not be prepared"
  mkdir -p "$submitbin"
  cat > "$submitbin/tmux" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_RACE_TMUX_LOG"
case "$1" in
  new-window) printf '%s\n' '@1' ;;
  display-message)
    case "$*" in
      *'#{pane_current_path}'*) printf '%s\n' "$FM_RACE_WORKTREE" ;;
      *) printf '%s\n' '%1' ;;
    esac
    ;;
  send-keys)
    case " $* " in
      *" -l "*)
        : > "$FM_RACE_LAUNCH_LITERAL"
        (
          if "$FM_RACE_BRIDGE" publish "$FM_RACE_ID" > "$FM_RACE_PUBLISH_OUT" 2>&1; then
            printf '%s\n' published >> "$FM_RACE_EVENTS"
            printf '%s\n' 0 > "$FM_RACE_PUBLISH_STATUS"
          else
            printf '%s\n' publisher-failed >> "$FM_RACE_EVENTS"
            printf '%s\n' 1 > "$FM_RACE_PUBLISH_STATUS"
          fi
        ) &
        ;;
      *" Enter "*)
        [ ! -e "$FM_RACE_LAUNCH_LITERAL" ] || printf '%s\n' submitted >> "$FM_RACE_EVENTS"
        ;;
    esac
    ;;
esac
SH
  chmod +x "$submitbin/tmux"
  out=$(PATH="$submitbin:$PATH" FM_RACE_BRIDGE="$BRIDGE" FM_RACE_ID=race-submit-a1 FM_RACE_WORKTREE="$submit_worktree" FM_RACE_TMUX_LOG="$home/race-submit-tmux.log" FM_RACE_LAUNCH_LITERAL="$submit_launch" FM_RACE_EVENTS="$submit_events" FM_RACE_PUBLISH_OUT="$submit_out" FM_RACE_PUBLISH_STATUS="$submit_status" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_SHIP_PREFLIGHT_NOW=101 "$ROOT/bin/fm-spawn.sh" race-submit-a1 "$project" --mode no-mistakes --yolo off --harness codex 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "spawn-first correction did not dispatch"
  attempts=0
  while [ ! -e "$submit_status" ] && [ "$attempts" -lt 50 ]; do
    sleep 0.1
    attempts=$((attempts + 1))
  done
  [ "$(cat "$submit_status")" = 0 ] || fail "spawn-first correction did not finish"
  assert_contains "$(cat "$submit_out")" "published" "spawn-first correction did not complete"
  submitted_line=$(grep -n '^submitted$' "$submit_events" | head -n 1 | cut -d: -f1)
  published_line=$(grep -n '^published$' "$submit_events" | head -n 1 | cut -d: -f1)
  [ -n "$submitted_line" ] && [ -n "$published_line" ] && [ "$submitted_line" -lt "$published_line" ] \
    || fail "spawn-first correction published before launch submission"
  pass "spawn verifies the durable preflight without a brief marker"
}

test_recovery_submission_serializes_preflight_corrections() {
  local home="$TMP_ROOT/recovery-serialization" project="$TMP_ROOT/recovery-serialization-project" worktree="$TMP_ROOT/recovery-serialization-worktree" remote="$TMP_ROOT/recovery-serialization-remote.git" contract="$TMP_ROOT/recovery-serialization-contract.json" corrected="$TMP_ROOT/recovery-serialization-corrected.json" fakebin="$TMP_ROOT/recovery-serialization-bin" id=recovery-serialization-a1 fp status attempts submitted_line published_line spawn_pid publisher_pid real_mktemp holder_pid holder_owner tmp
  mkdir -p "$home/data" "$home/state" "$home/config" "$project" "$fakebin"
  real_mktemp=$(command -v mktemp) || fail "could not find mktemp"
  make_contract "$contract"
  printf '%s\n' '{"recommendation":"Build it","outcome":"Corrected tested PR","scope":"One change","non_goals":"No deploy","delivery_boundary":"pr-only","external_boundaries":"No production write","questions":[]}' > "$corrected"
  git init --bare -q "$remote" || fail "could not create recovery serialization remote"
  git -C "$project" init -q || fail "could not create recovery serialization project"
  git -C "$project" config user.email test@example.invalid || fail "could not configure recovery serialization author"
  git -C "$project" config user.name Test || fail "could not configure recovery serialization author"
  printf '%s\n' 'recovery serialization test' > "$project/README.md"
  git -C "$project" add README.md || fail "could not stage recovery serialization project"
  git -C "$project" commit -qm initial || fail "could not commit recovery serialization project"
  git -C "$project" branch -M main || fail "could not name recovery serialization branch"
  git -C "$project" remote add origin "$remote" || fail "could not configure recovery serialization remote"
  git -C "$project" push -qu origin main || fail "could not publish recovery serialization base"
  git --git-dir="$remote" symbolic-ref HEAD refs/heads/main || fail "could not set recovery serialization default branch"
  git clone -q "$remote" "$worktree" || fail "could not create recovery serialization worktree"
  fp=$(publish_preflight_record "$home" "$id" "$contract" direct approved 100) || fail "could not create recovery preflight"
  printf '%s\n' 'Delivery contract: mode=no-mistakes' > "$home/data/$id/brief.md"
  write_bridge_handoff "$home" "$id" "$corrected" direct awaiting_approval 101 2 >/dev/null || fail "could not stage recovery correction"
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$worktree"
    printf 'project=%s\n' "$project"
    printf '%s\n' 'harness=codex' 'kind=ship' 'mode=no-mistakes' 'yolo=off' 'tasktmp=/tmp/fm-recovery-serialization-a1' 'model=default' 'effort=default'
    printf 'preflight_fingerprint=%s\n' "$fp"
  } > "$home/state/$id.meta"
  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
set -eu
for arg in "$@"; do
  case "$arg" in
    "$FM_RACE_PREFLIGHT_LOCK".owner.*)
      [ "${FM_RACE_BRIDGE_PROCESS:-}" != 1 ] || : > "$FM_RACE_LOCK_ATTEMPT"
      ;;
  esac
done
exec "$FM_RACE_REAL_MKTEMP" "$@"
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1" in
  list-windows) printf 'fm-%s\n' "$FM_RACE_ID" ;;
  display-message)
    case "$*" in
      *'#{pane_current_path}'*) printf '%s\n' "$FM_RACE_WORKTREE" ;;
      *'#{pane_current_command}'*) printf '%s\n' bash ;;
    esac
    ;;
  send-keys)
    literal=0
    for arg in "$@"; do
      [ "$arg" != -l ] || literal=1
    done
    if [ "$literal" -eq 1 ]; then
      : > "$FM_RACE_LAUNCH_LITERAL"
      while [ ! -e "$FM_RACE_RELEASE_LITERAL" ]; do
        sleep 0.01
      done
    elif [ "${!#}" = Enter ]; then
      [ ! -e "$FM_RACE_LAUNCH_LITERAL" ] || printf '%s\n' submitted >> "$FM_RACE_EVENTS"
    fi
    ;;
esac
SH
  chmod +x "$fakebin/mktemp" "$fakebin/tmux"
  PATH="$fakebin:$PATH" FM_RACE_REAL_MKTEMP="$real_mktemp" FM_RACE_ID="$id" FM_RACE_WORKTREE="$worktree" FM_RACE_PREFLIGHT_LOCK="$home/data/$id/.ship-preflight.lock" FM_RACE_LAUNCH_LITERAL="$home/launch-literal" FM_RACE_RELEASE_LITERAL="$home/release-literal" FM_RACE_EVENTS="$home/events" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_SHIP_PREFLIGHT_NOW=101 FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" --relaunch > "$home/spawn.out" 2>&1 &
  spawn_pid=$!
  attempts=0
  while [ ! -e "$home/launch-literal" ] && [ "$attempts" -lt 500 ]; do
    if ! kill -0 "$spawn_pid" 2>/dev/null; then
      break
    fi
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$home/launch-literal" ]; then
    : > "$home/release-literal"
    wait "$spawn_pid" || true
    fail "recovery relaunch did not reach replacement command submission"
  fi
  (
    if PATH="$fakebin:$PATH" FM_RACE_REAL_MKTEMP="$real_mktemp" FM_RACE_BRIDGE_PROCESS=1 FM_RACE_PREFLIGHT_LOCK="$home/data/$id/.ship-preflight.lock" FM_RACE_LOCK_ATTEMPT="$home/lock-attempt" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" "$BRIDGE" publish "$id" > "$home/publish.out" 2>&1; then
      printf '%s\n' 0 > "$home/publish.status"
    else
      printf '%s\n' 1 > "$home/publish.status"
    fi
  ) &
  publisher_pid=$!
  attempts=0
  while [ ! -e "$home/lock-attempt" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$home/lock-attempt" ]; then
    : > "$home/release-literal"
    wait "$spawn_pid" || true
    wait "$publisher_pid" || true
    fail "recovery correction did not attempt preflight publication"
  fi
  attempts=0
  while [ ! -e "$home/publish.status" ] && [ "$attempts" -lt 20 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ -e "$home/publish.status" ]; then
    : > "$home/release-literal"
    wait "$spawn_pid" || true
    wait "$publisher_pid" || true
    fail "recovery correction published before replacement command submission"
  fi
  jq -e '.state == "approved"' "$home/data/$id/ship-preflight.json" >/dev/null \
    || { : > "$home/release-literal"; wait "$spawn_pid" || true; wait "$publisher_pid" || true; fail "recovery correction replaced approval before submission"; }
  : > "$home/release-literal"
  wait "$spawn_pid"
  status=$?
  [ "$status" -eq 0 ] || fail "recovery relaunch did not submit the approved replacement: $(cat "$home/spawn.out")"
  wait "$publisher_pid"
  status=$?
  [ "$status" -eq 0 ] && [ "$(cat "$home/publish.status")" = 0 ] || fail "recovery correction did not publish"
  printf '%s\n' published >> "$home/events"
  submitted_line=$(grep -n '^submitted$' "$home/events" | head -n 1 | cut -d: -f1)
  published_line=$(grep -n '^published$' "$home/events" | head -n 1 | cut -d: -f1)
  [ -n "$submitted_line" ] && [ -n "$published_line" ] && [ "$submitted_line" -lt "$published_line" ] \
    || fail "recovery correction published before replacement command submission"
  jq -e '.state == "awaiting_approval" and .contract.outcome == "Corrected tested PR"' "$home/data/$id/ship-preflight.json" >/dev/null \
    || fail "recovery correction did not replace the consumed approval after submission"
  fp=$(publish_preflight_record "$home" "$id" "$contract" direct approved 102 3) || fail "could not restore recovery preflight"
  tmp=$(mktemp "$home/state/.${id}.meta.XXXXXX") || fail "could not prepare restored recovery metadata"
  if ! awk -F= -v fp="$fp" '$1 != "preflight_fingerprint" { print } END { print "preflight_fingerprint=" fp }' "$home/state/$id.meta" > "$tmp" \
    || ! mv -f -- "$tmp" "$home/state/$id.meta"; then
    rm -f -- "$tmp"
    fail "could not restore recovery preflight metadata"
  fi
  rm -f -- "$home/launch-literal" "$home/release-literal"
  (
    STATE="$home/data/$id"
    FM_STATE_OVERRIDE="$STATE" . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$home/data/$id/.ship-preflight.lock"
    : > "$home/holder-ready"
    while [ ! -e "$home/holder-release" ]; do sleep 0.01; done
    fm_lock_release "$home/data/$id/.ship-preflight.lock"
  ) &
  holder_pid=$!
  attempts=0
  while [ ! -e "$home/holder-ready" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$home/holder-ready" ]; then
    : > "$home/holder-release"
    wait "$holder_pid" || true
    fail "independent preflight lock holder did not start"
  fi
  holder_owner=$(cat "$home/data/$id/.ship-preflight.lock/pid")
  PATH="$fakebin:$PATH" FM_RACE_REAL_MKTEMP="$real_mktemp" FM_RACE_ID="$id" FM_RACE_WORKTREE="$worktree" FM_RACE_PREFLIGHT_LOCK="$home/data/$id/.ship-preflight.lock" FM_RACE_LAUNCH_LITERAL="$home/launch-literal" FM_RACE_RELEASE_LITERAL="$home/release-literal" FM_RACE_EVENTS="$home/events" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_SHIP_PREFLIGHT_NOW=103 FM_SPAWN_NO_GUARD=1 FM_DASHBOARD_RECOVERY_PREFLIGHT_LOCK="$home/data/$id/.ship-preflight.lock" FM_DASHBOARD_RECOVERY_PREFLIGHT_LOCK_OWNER="$holder_owner" "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --dashboard-recovery > "$home/spoof-spawn.out" 2>&1 &
  spawn_pid=$!
  attempts=0
  while kill -0 "$spawn_pid" 2>/dev/null && [ "$attempts" -lt 30 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ -e "$home/launch-literal" ] || ! kill -0 "$spawn_pid" 2>/dev/null; then
    : > "$home/holder-release"
    wait "$holder_pid" || true
    : > "$home/release-literal"
    wait "$spawn_pid" || true
    fail "an unrelated preflight lock holder bypassed recovery serialization"
  fi
  : > "$home/holder-release"
  wait "$holder_pid" || fail "could not release independent preflight lock"
  attempts=0
  while [ ! -e "$home/launch-literal" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$home/launch-literal" ]; then
    : > "$home/release-literal"
    wait "$spawn_pid" || true
    fail "recovery did not continue after the independent lock released"
  fi
  : > "$home/release-literal"
  wait "$spawn_pid"
  status=$?
  [ "$status" -eq 0 ] || fail "serialized recovery did not complete: $(cat "$home/spoof-spawn.out")"
  pass "recovery holds preflight approval through replacement command submission"
}

write_snapshot() {
  local file=$1 state=$2 decision=${3:-null} url=${4:-} source=${5:-pane} detail=${6:-} transition=${7:-100} checkpoint=${8:-0} recovery=${9:-'{"state":"none"}'} activity json
  activity=${10:-$state}
  json=$(printf '{"schema":"fm-fleet-snapshot.v1","tasks":[{"id":"dash-a1","kind":"ship","backlog":{"title":"Build dashboard"},"x_request":"r1","x_thread_url":"%s","current_state":{"state":"%s","activity_state":"%s","source":"%s","detail":"%s","transition_at":%s,"active_seconds":%s},"recovery":%s,"hints":{"open_decisions":%s}}]}' "$url" "$state" "$activity" "$source" "$detail" "$transition" "$checkpoint" "$recovery" "$decision")
  printf '%s\n' '#!/usr/bin/env bash' > "$file"
  printf "printf '%%s\\n' '%s'\n" "$json" >> "$file"
  chmod +x "$file"
}

test_dashboard_projection_and_active_time() {
  local home="$TMP_ROOT/dashboard" mock="$TMP_ROOT/dashboard-snapshot" record
  mkdir -p "$home/data" "$home/state"
  chmod 700 "$home/data"
  write_snapshot "$mock" working '[]' 'https://slack.example/thread/1' pane '' 100 0
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=100 "$DASHBOARD" refresh >/dev/null || fail "initial dashboard refresh failed"
  write_snapshot "$mock" working '[]' 'https://slack.example/thread/1' pane '' 120 10
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=130 "$DASHBOARD" refresh >/dev/null || fail "active dashboard refresh failed"
  write_snapshot "$mock" paused '[]' 'https://slack.example/thread/1' pane '' 132 22
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=140 "$DASHBOARD" refresh >/dev/null || fail "pause dashboard refresh failed"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=170 "$DASHBOARD" refresh >/dev/null || fail "continued pause dashboard refresh failed"
  jq -e '.technical.tasks[0].active_seconds == 22 and .technical.tasks[0].state_transition_at == 132' "$home/data/dashboard.json" >/dev/null || fail "dashboard must exclude a full paused interval between refreshes"
  write_snapshot "$mock" parked '[{"key":"ask","verb":"needs-decision","summary":"Choose"}]' 'https://slack.example/thread/1' pane '' 175 22
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=175 "$DASHBOARD" refresh >/dev/null || fail "decision dashboard refresh failed"
  record="$home/data/dashboard.json"
  jq -e '(.projection.needs_you | length) == 1 and .projection.needs_you[0].slack_thread_url == "https://slack.example/thread/1"' "$record" >/dev/null || fail "dashboard did not preserve the Slack decision link"
  write_snapshot "$mock" working '[]' 'https://slack.example/thread/1' pane '' 180 22
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=200 "$DASHBOARD" refresh >/dev/null || fail "resume dashboard refresh failed"
  record="$home/data/dashboard.json"
  [ "$(stat -c %a "$record")" = 600 ] || fail "dashboard record must be mode 0600"
  jq -e '.schema_version == 1 and .projection.in_progress[0].phase == "Building" and .projection.in_progress[0].active_seconds == 42 and (.projection.needs_you | length) == 0 and .projection.empty_text == "Nothing needs you."' "$record" >/dev/null || fail "dashboard projection or timing was wrong"
  find "$home/data" -maxdepth 1 -name '.dashboard.*' | grep -q . && fail "dashboard refresh left a non-atomic temporary file"
  pass "dashboard uses one private atomic projection with paused time excluded"
}

test_dashboard_omits_uncheckpointed_active_work() {
  local home="$TMP_ROOT/dashboard-uncheckpointed" mock="$TMP_ROOT/dashboard-uncheckpointed-snapshot" record
  mkdir -p "$home/data" "$home/state"
  chmod 700 "$home/data"
  write_snapshot "$mock" working '[]' '' pane 'harness busy (grok-regex)' null null
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=150 "$DASHBOARD" refresh >/dev/null || fail "uncheckpointed Grok dashboard refresh failed"
  record="$home/data/dashboard.json"
  jq -e '.projection.in_progress == [] and .technical.tasks[0].timing_exact == false and .technical.tasks[0].active_seconds == 0' "$record" >/dev/null \
    || fail "dashboard derived Grok active time without a producer checkpoint"
  write_snapshot "$mock" working '[]' '' pane 'harness busy (muse-session-log)' null null
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=200 "$DASHBOARD" refresh >/dev/null || fail "uncheckpointed Muse dashboard refresh failed"
  jq -e '.projection.in_progress == [] and .technical.tasks[0].timing_exact == false and .technical.tasks[0].active_seconds == 0' "$record" >/dev/null \
    || fail "dashboard derived Muse active time from refresh cadence"
  write_snapshot "$mock" working '[]' '' pane 'harness busy (muse-session-log)' 210 4
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=220 "$DASHBOARD" refresh >/dev/null || fail "checkpointed Muse dashboard refresh failed"
  jq -e '.projection.in_progress == [{id:"dash-a1",name:"Build dashboard",phase:"Building",active_seconds:14}] and .technical.tasks[0].timing_exact == true' "$record" >/dev/null \
    || fail "dashboard did not resume exact timing from the producer checkpoint"
  pass "dashboard omits active work until its producer provides exact timing"
}

test_dashboard_projects_unknown_launch_work() {
  local home="$TMP_ROOT/dashboard-unknown-launch" mock="$TMP_ROOT/dashboard-unknown-launch-snapshot" record
  mkdir -p "$home/data" "$home/state"
  chmod 700 "$home/data"
  write_snapshot "$mock" unknown '[]' '' pane 'harness state unavailable (unknown codex-unverified)' 100 0 '{"state":"none"}' working
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=100 "$DASHBOARD" refresh >/dev/null || fail "unknown launch dashboard refresh failed"
  record="$home/data/dashboard.json"
  jq -e '.projection.in_progress == [{id:"dash-a1",name:"Build dashboard",phase:"Building",active_seconds:0}] and .technical.tasks[0].state == "unknown" and .technical.tasks[0].activity_state == "working"' "$record" >/dev/null \
    || fail "dashboard did not project unknown launch work"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=110 "$DASHBOARD" refresh >/dev/null || fail "unknown launch timing refresh failed"
  jq -e '.projection.in_progress[0].active_seconds == 10' "$record" >/dev/null || fail "dashboard did not accumulate unknown launch time"
  write_snapshot "$mock" unknown '[]' '' pane 'harness state unavailable (unknown codex-unverified)' 110 10 '{"state":"none"}' parked
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=120 "$DASHBOARD" refresh >/dev/null || fail "unknown launch pause refresh failed"
  jq -e '.projection.in_progress == [] and .technical.tasks[0].active_seconds == 10' "$record" >/dev/null || fail "dashboard did not preserve unknown launch pause time"
  write_snapshot "$mock" unknown '[]' '' pane 'harness state unavailable (unknown codex-unverified)' 130 10 '{"state":"none"}' working
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=140 "$DASHBOARD" refresh >/dev/null || fail "unknown launch resume refresh failed"
  jq -e '.projection.in_progress == [{id:"dash-a1",name:"Build dashboard",phase:"Building",active_seconds:20}]' "$record" >/dev/null || fail "dashboard did not resume unknown launch timing"
  pass "dashboard projects unknown launch work with exact timing"
}

test_dashboard_recovers_stale_publication_lock() {
  local home="$TMP_ROOT/dashboard-stale-lock" mock="$TMP_ROOT/dashboard-stale-lock-snapshot" lock record
  mkdir -p "$home/data" "$home/state"
  chmod 700 "$home/data"
  write_snapshot "$mock" working '[]' '' pane '' 100 0
  lock="$home/data/.dashboard.lock"
  mkdir "$lock"
  printf '%s\n' 999999 > "$lock/pid"
  touch -t 200001010000 "$lock"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=100 "$DASHBOARD" refresh >/dev/null || fail "dashboard refresh did not recover its stale lock"
  record="$home/data/dashboard.json"
  jq -e '.schema_version == 1 and .projection.in_progress[0].id == "dash-a1"' "$record" >/dev/null || fail "dashboard did not publish after stale-lock recovery"
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || fail "dashboard left its recovered lock behind"
  pass "dashboard recovers stale publication locks"
}

test_dashboard_filters_and_checking_phase() {
  local home="$TMP_ROOT/dashboard-filter" mock="$TMP_ROOT/dashboard-filter-snapshot" record
  mkdir -p "$home/data" "$home/state"
  chmod 700 "$home/data"
  write_snapshot "$mock" working '[{"key":"d1","verb":"needs-decision","summary":"Choose"},{"key":"b1","verb":"blocked","summary":"Ignore duplicate"}]' '' run-step 'ci running'
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=100 "$DASHBOARD" refresh >/dev/null || fail "checking dashboard refresh failed"
  record="$home/data/dashboard.json"
  jq -e '.projection.in_progress == [{id:"dash-a1",name:"Build dashboard",phase:"Checking",active_seconds:0}] and .projection.needs_you == []' "$record" >/dev/null \
    || fail "dashboard must not duplicate a stale decision while checking"
  write_snapshot "$mock" parked '[{"key":"d1","verb":"needs-decision","summary":"Choose"},{"key":"b1","verb":"blocked","summary":"Ignore duplicate"}]' '' run-step 'parked at authority gate' 103 3
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=105 "$DASHBOARD" refresh >/dev/null || fail "decision dashboard refresh failed"
  jq -e '.projection.in_progress == [] and (.projection.needs_you | length) == 1 and .projection.needs_you[0].kind == "needs-decision" and .technical.tasks[0].active_seconds == 3' "$record" >/dev/null \
    || fail "dashboard must show one genuine decision"
  write_snapshot "$mock" unknown '[]' '' pane 'endpoint unavailable'
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=110 "$DASHBOARD" refresh >/dev/null || fail "unknown dashboard refresh failed"
  jq -e '.projection.in_progress == [] and .projection.needs_you == [] and .technical.tasks[0].recovery == "automatic-recovery-pending"' "$record" >/dev/null \
    || fail "dashboard must keep recoverable endpoint loss out of Needs you"
  write_snapshot "$mock" failed '[]' '' run-step 'run failed'
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=115 "$DASHBOARD" refresh >/dev/null || fail "failed dashboard refresh failed"
  jq -e '.projection.in_progress == [] and .projection.needs_you == []' "$record" >/dev/null \
    || fail "dashboard must keep ordinary worker failures out of Needs you: $(jq -c . "$record")"
  pass "dashboard maps checking work and filters duplicate or stale alerts"
}

test_dashboard_transition_ledger_tracks_canonical_edges() {
  local home="$TMP_ROOT/dashboard-ledger" state_file="$TMP_ROOT/dashboard-ledger-state" state_bin="$TMP_ROOT/dashboard-ledger-bin" record
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' 'kind=ship' > "$home/state/ledger-a1.meta"
  # shellcheck disable=SC2016 # Variables expand in the generated state fixture.
  printf '%s\n' '#!/usr/bin/env bash' 'IFS= read -r state < "$FM_DASHBOARD_TEST_STATE"' 'IFS= read -r timestamp < "$FM_DASHBOARD_TEST_TIMESTAMP"' 'printf "state: %s · source: run-step · transition_at: %s\\n" "$state" "$timestamp"' > "$state_bin"
  chmod +x "$state_bin"
  printf '%s\n' working > "$state_file"
  printf '%s\n' 100 > "$TMP_ROOT/dashboard-ledger-timestamp"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" FM_DASHBOARD_RUN_STATE_BIN="$state_bin" FM_DASHBOARD_TEST_STATE="$state_file" FM_DASHBOARD_TEST_TIMESTAMP="$TMP_ROOT/dashboard-ledger-timestamp" "$ROOT/bin/fm-dashboard-run-state.sh" reconcile ledger-a1 \
    || fail "initial run-state event failed"
  printf '%s\n' parked > "$state_file"
  printf '%s\n' 110 > "$TMP_ROOT/dashboard-ledger-timestamp"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" FM_DASHBOARD_RUN_STATE_BIN="$state_bin" FM_DASHBOARD_TEST_STATE="$state_file" FM_DASHBOARD_TEST_TIMESTAMP="$TMP_ROOT/dashboard-ledger-timestamp" "$ROOT/bin/fm-dashboard-run-state.sh" reconcile ledger-a1 \
    || fail "parked run-state event failed"
  printf '%s\n' working > "$state_file"
  printf '%s\n' 120 > "$TMP_ROOT/dashboard-ledger-timestamp"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" FM_DASHBOARD_RUN_STATE_BIN="$state_bin" FM_DASHBOARD_TEST_STATE="$state_file" FM_DASHBOARD_TEST_TIMESTAMP="$TMP_ROOT/dashboard-ledger-timestamp" "$ROOT/bin/fm-dashboard-run-state.sh" reconcile ledger-a1 \
    || fail "resumed run-state event failed"
  record="$home/state/dashboard-transitions/ledger-a1.json"
  jq -e '.schema_version == 1 and .state == "working" and .transition_at == 120 and .active_seconds == 10' "$record" >/dev/null \
    || fail "canonical transition ledger did not preserve the producer checkpoint"
  printf '%s\n' parked > "$state_file"
  printf '%s\n' '' > "$TMP_ROOT/dashboard-ledger-timestamp"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" FM_DASHBOARD_RUN_STATE_BIN="$state_bin" FM_DASHBOARD_TEST_STATE="$state_file" FM_DASHBOARD_TEST_TIMESTAMP="$TMP_ROOT/dashboard-ledger-timestamp" "$ROOT/bin/fm-dashboard-run-state.sh" reconcile ledger-a1 \
    || fail "untimed parked run-state event failed"
  jq -e '.state == "parked" and .transition_at == null and .active_seconds == 10' "$record" >/dev/null \
    || fail "untimed run-state event did not invalidate the exact checkpoint"
  printf '%s\n' working > "$state_file"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" FM_DASHBOARD_RUN_STATE_BIN="$state_bin" FM_DASHBOARD_TEST_STATE="$state_file" FM_DASHBOARD_TEST_TIMESTAMP="$TMP_ROOT/dashboard-ledger-timestamp" "$ROOT/bin/fm-dashboard-run-state.sh" reconcile ledger-a1 \
    || fail "untimed resumed run-state event failed"
  jq -e '.state == "working" and .transition_at == null and .active_seconds == 10' "$record" >/dev/null \
    || fail "untimed resume revived a stale exact checkpoint"
  printf '%s\n' 140 > "$TMP_ROOT/dashboard-ledger-timestamp"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" FM_DASHBOARD_RUN_STATE_BIN="$state_bin" FM_DASHBOARD_TEST_STATE="$state_file" FM_DASHBOARD_TEST_TIMESTAMP="$TMP_ROOT/dashboard-ledger-timestamp" "$ROOT/bin/fm-dashboard-run-state.sh" reconcile ledger-a1 \
    || fail "fresh exact run-state event failed"
  jq -e '.state == "working" and .transition_at == 140 and .active_seconds == 10' "$record" >/dev/null \
    || fail "fresh exact run-state event reused an invalidated checkpoint"
  pass "run-state producer persists a compact canonical dashboard checkpoint"
}

test_status_event_persists_transition_before_status() {
  local home="$TMP_ROOT/status-event" fake_date record terminal_record
  mkdir -p "$home/data" "$home/state" "$TMP_ROOT/status-event-bin"
  printf '%s\n' 'kind=ship' > "$home/state/status-a1.meta"
  fake_date="$TMP_ROOT/status-event-bin/date"
  # shellcheck disable=SC2016 # Variables expand in the generated date fixture.
  printf '%s\n' '#!/usr/bin/env bash' 'if [ "$1" = +%s ]; then printf "%s\\n" "$FM_FAKE_NOW"; else command date "$@"; fi' > "$fake_date"
  chmod +x "$fake_date"
  PATH="$TMP_ROOT/status-event-bin:$PATH" FM_FAKE_NOW=100 "$ROOT/bin/fm-status-event.sh" append "$home/state" status-a1 'working: implementation started' || fail "working status event failed"
  PATH="$TMP_ROOT/status-event-bin:$PATH" FM_FAKE_NOW=110 "$ROOT/bin/fm-status-event.sh" append "$home/state" status-a1 'needs-decision [key=implementation]: captain input required' || fail "decision status event failed"
  PATH="$TMP_ROOT/status-event-bin:$PATH" FM_FAKE_NOW=120 "$ROOT/bin/fm-status-event.sh" resolve "$home/state" status-a1 'resolved [key=implementation]: captain answered' || fail "resolution status event failed"
  record="$home/state/dashboard-transitions/status-a1.json"
  jq -e '.state == "working" and .transition_at == 120 and .active_seconds == 10' "$record" >/dev/null \
    || fail "status event did not persist canonical transition timing"
  [ "$(wc -l < "$home/state/status-a1.status")" -eq 3 ] || fail "status event did not append all status lines"
  printf '%s\n' 'kind=ship' > "$home/state/status-terminal-a1.meta"
  PATH="$TMP_ROOT/status-event-bin:$PATH" FM_FAKE_NOW=200 "$ROOT/bin/fm-status-event.sh" append "$home/state" status-terminal-a1 'done: implementation finished' || fail "terminal status event failed"
  PATH="$TMP_ROOT/status-event-bin:$PATH" FM_FAKE_NOW=210 "$ROOT/bin/fm-status-event.sh" resolve "$home/state" status-terminal-a1 'resolved [key=late]: captain answered' || fail "late resolution status event failed"
  terminal_record="$home/state/dashboard-transitions/status-terminal-a1.json"
  jq -e '.state == "done" and .transition_at == 200 and .terminal_receipt == {state:"done",recorded_at:200}' "$terminal_record" >/dev/null \
    || fail "late resolution reactivated a terminal task"
  pass "status events persist canonical transitions with status output"
}

test_dashboard_busy_events_preserve_hidden_transitions() {
  local home="$TMP_ROOT/dashboard-busy-events" fake_date gen record
  mkdir -p "$home/data" "$home/state" "$TMP_ROOT/dashboard-busy-bin"
  printf '%s\n' 'kind=ship' > "$home/state/busy-a1.meta"
  fake_date="$TMP_ROOT/dashboard-busy-bin/date"
  # shellcheck disable=SC2016 # Variables expand in the generated date fixture.
  printf '%s\n' '#!/usr/bin/env bash' 'if [ "$1" = +%s ]; then printf "%s\\n" "$FM_FAKE_NOW"; else command date "$@"; fi' > "$fake_date"
  chmod +x "$fake_date"
  gen=$(PATH="$TMP_ROOT/dashboard-busy-bin:$PATH" FM_FAKE_NOW=100 "$ROOT/bin/fm-busy-event.sh" arm "$home/state" busy-a1) || fail "busy event arm failed"
  PATH="$TMP_ROOT/dashboard-busy-bin:$PATH" FM_FAKE_NOW=110 "$ROOT/bin/fm-busy-event.sh" apply "$home/state" busy-a1 idle --gen "$gen" --source claude-hook --event stop \
    || fail "busy event pause failed"
  PATH="$TMP_ROOT/dashboard-busy-bin:$PATH" FM_FAKE_NOW=120 "$ROOT/bin/fm-busy-event.sh" apply "$home/state" busy-a1 busy --gen "$gen" --source claude-hook --event user-prompt-submit \
    || fail "busy event resume failed"
  record="$home/state/dashboard-transitions/busy-a1.json"
  jq -e '.state == "working" and .transition_at == 120 and .active_seconds == 10' "$record" >/dev/null \
    || fail "busy event producer did not preserve the hidden pause interval"
  pass "busy events persist exact active-time transitions"
}

test_dashboard_busy_events_replay_interrupted_transitions() {
  local home="$TMP_ROOT/dashboard-busy-replay" fake_date gen record out status
  mkdir -p "$home/data" "$home/state" "$TMP_ROOT/dashboard-busy-replay-bin"
  printf '%s\n' 'kind=ship' > "$home/state/busy-replay-a1.meta"
  fake_date="$TMP_ROOT/dashboard-busy-replay-bin/date"
  # shellcheck disable=SC2016 # Variables expand in the generated date fixture.
  printf '%s\n' '#!/usr/bin/env bash' 'if [ "$1" = +%s ]; then printf "%s\\n" "$FM_FAKE_NOW"; else command date "$@"; fi' > "$fake_date"
  chmod +x "$fake_date"
  gen=$(PATH="$TMP_ROOT/dashboard-busy-replay-bin:$PATH" FM_FAKE_NOW=100 "$ROOT/bin/fm-busy-event.sh" arm "$home/state" busy-replay-a1) || fail "busy replay arm failed"
  out=$(PATH="$TMP_ROOT/dashboard-busy-replay-bin:$PATH" FM_FAKE_NOW=110 FM_BUSY_EVENT_TESTING=1 FM_BUSY_EVENT_TEST_INTERRUPT_AFTER_TRANSITION=1 "$ROOT/bin/fm-busy-event.sh" apply "$home/state" busy-replay-a1 idle --gen "$gen" --source claude-hook --event stop 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "interrupted busy transition unexpectedly completed"
  PATH="$TMP_ROOT/dashboard-busy-replay-bin:$PATH" FM_FAKE_NOW=120 "$ROOT/bin/fm-busy-event.sh" apply "$home/state" busy-replay-a1 busy --gen "$gen" --source claude-hook --event user-prompt-submit \
    || fail "later busy event did not replay the interrupted pause"
  record="$home/state/dashboard-transitions/busy-replay-a1.json"
  jq -e '.state == "working" and .transition_at == 120 and .active_seconds == 10' "$record" >/dev/null \
    || fail "replayed busy transition included the interrupted pause"
  pass "busy events replay an interrupted transition before later writes"
}

test_dashboard_replays_spawn_busy_event_across_metadata_updates() {
  local home="$TMP_ROOT/dashboard-spawn-replay" fake_date gen record
  mkdir -p "$home/data" "$home/state" "$TMP_ROOT/dashboard-spawn-bin"
  fake_date="$TMP_ROOT/dashboard-spawn-bin/date"
  # shellcheck disable=SC2016 # Variables expand in the generated date fixture.
  printf '%s\n' '#!/usr/bin/env bash' 'if [ "$1" = +%s ]; then printf "%s\\n" "$FM_FAKE_NOW"; else command date "$@"; fi' > "$fake_date"
  chmod +x "$fake_date"
  gen=$(PATH="$TMP_ROOT/dashboard-spawn-bin:$PATH" FM_FAKE_NOW=100 "$ROOT/bin/fm-busy-event.sh" arm "$home/state" replay-a1) || fail "pre-metadata busy event failed"
  [ ! -e "$home/state/dashboard-transitions/replay-a1.json" ] || fail "pre-metadata busy event must wait for task identity"
  printf '%s\n' 'kind=ship' 'dashboard_incarnation=i-replay-a1' > "$home/state/replay-a1.meta"
  "$ROOT/bin/fm-dashboard-transition.sh" replay-busy "$home/state" replay-a1 || fail "spawn replay failed"
  printf '%s\n' 'x_thread_url=https://slack.example/thread/1' >> "$home/state/replay-a1.meta"
  PATH="$TMP_ROOT/dashboard-spawn-bin:$PATH" FM_FAKE_NOW=110 "$ROOT/bin/fm-busy-event.sh" apply "$home/state" replay-a1 idle --gen "$gen" --source claude-hook --event stop \
    || fail "post-metadata pause failed"
  record="$home/state/dashboard-transitions/replay-a1.json"
  jq -e '.incarnation == "i-replay-a1" and .state == "parked" and .active_seconds == 10' "$record" >/dev/null \
    || fail "metadata update reset accumulated active time"
  pass "spawn replay preserves active time across metadata updates"
}

test_dashboard_recovery_surfaces_only_exhausted_loss() {
  local home="$TMP_ROOT/dashboard-recovery" state_bin="$TMP_ROOT/dashboard-recovery-state" agent_bin="$TMP_ROOT/dashboard-recovery-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-spawn" mock="$TMP_ROOT/dashboard-recovery-snapshot" record
  mkdir -p "$home/data" "$home/state"
  chmod 700 "$home/data"
  printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' > "$home/state/dash-a1.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: none · endpoint gone\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf missing' > "$agent_bin"
  # shellcheck disable=SC2016 # Positional parameters expand in the generated spawn fixture.
  printf '%s\n' '#!/usr/bin/env bash' '[ "$2" = --recover-missing ] || exit 2' 'printf "replacement refused\\n" >&2' 'exit 1' > "$spawn_bin"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" FM_DASHBOARD_RECOVERY_MAX_ATTEMPTS=2 "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-a1 || fail "first automatic recovery attempt failed"
  jq -e '.state == "pending" and .attempts == 1' "$home/state/dashboard-recovery/dash-a1.json" >/dev/null || fail "first recovery failure must remain recoverable"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" FM_DASHBOARD_RECOVERY_MAX_ATTEMPTS=2 "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-a1 || fail "exhausted recovery attempt failed"
  record="$home/state/dashboard-recovery/dash-a1.json"
  jq -e '.state == "unrecoverable" and .attempts == 2' "$record" >/dev/null || fail "recovery owner did not persist exhaustion"
  write_snapshot "$mock" unknown '[]' '' pane 'endpoint unavailable' null null '{"state":"unrecoverable"}'
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=120 "$DASHBOARD" refresh >/dev/null || fail "unrecoverable dashboard refresh failed"
  jq -e '.projection.needs_you == [{id:"dash-a1",name:"Build dashboard",kind:"failed",summary:"Worker recovery failed",slack_thread_url:null}] and .technical.tasks[0].recovery == "unrecoverable"' "$home/data/dashboard.json" >/dev/null \
    || fail "dashboard did not surface an exhausted worker recovery"
  pass "dashboard surfaces only exhausted worker recovery"
}

test_dashboard_recovery_defers_preflight_approval() {
  local home="$TMP_ROOT/dashboard-recovery-preflight" state_bin="$TMP_ROOT/dashboard-recovery-preflight-state" agent_bin="$TMP_ROOT/dashboard-recovery-preflight-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-preflight-spawn" spawn_log="$TMP_ROOT/dashboard-recovery-preflight-spawn-log" record contract fp
  mkdir -p "$home/data" "$home/state"
  contract="$home/contract.json"
  make_contract "$contract"
  fp=$(publish_preflight_record "$home" dash-preflight "$contract" direct awaiting_approval 100) || fail "could not prepare awaiting preflight"
  printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' "preflight_fingerprint=$fp" > "$home/state/dash-preflight.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: endpoint · confirmed endpoint loss\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf dead' > "$agent_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf invoked >> "$FM_RECOVERY_SPAWN_LOG"' 'exit 1' > "$spawn_bin"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin"
  record="$home/state/dashboard-recovery/dash-preflight.json"
  FM_RECOVERY_SPAWN_LOG="$spawn_log" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" FM_DASHBOARD_RECOVERY_MAX_ATTEMPTS=2 "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-preflight || fail "awaiting approval recovery must defer"
  [ ! -e "$record" ] || fail "awaiting approval recorded a recovery attempt"
  [ ! -e "$spawn_log" ] || fail "awaiting approval launched a replacement"
  [ ! -e "$home/state/dashboard-transitions/dash-preflight.recovery-claim" ] \
    || fail "awaiting approval created a recovery claim"
  fp=$(publish_preflight_record "$home" dash-preflight "$contract" direct approved 101 2) || fail "could not approve preflight"
  printf '%s\n' '#!/usr/bin/env bash' 'printf invoked >> "$FM_RECOVERY_SPAWN_LOG"' 'exit 0' > "$spawn_bin"
  chmod +x "$spawn_bin"
  FM_RECOVERY_SPAWN_LOG="$spawn_log" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" FM_DASHBOARD_RECOVERY_MAX_ATTEMPTS=2 "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-preflight || fail "approved preflight did not resume recovery"
  [ "$(cat "$spawn_log")" = invoked ] || fail "approved preflight did not launch recovery"
  [ ! -e "$record" ] || fail "successful recovery left a failure record"
  pass "dashboard defers awaiting preflight recovery without consuming attempts"
}

test_dashboard_recovery_refuses_missing_preflight() {
  local home state_bin agent_bin spawn_bin case_name recovery_pid attempts status out
  for case_name in missing-directory missing-record; do
    home="$TMP_ROOT/dashboard-recovery-$case_name"
    state_bin="$TMP_ROOT/dashboard-recovery-$case_name-state"
    agent_bin="$TMP_ROOT/dashboard-recovery-$case_name-agent"
    spawn_bin="$TMP_ROOT/dashboard-recovery-$case_name-spawn"
    mkdir -p "$home/data" "$home/state"
    chmod 700 "$home/data"
    if [ "$case_name" = missing-record ]; then
      mkdir "$home/data/dash-missing"
      chmod 700 "$home/data/dash-missing"
    fi
    printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' 'preflight_fingerprint=0000000000000000000000000000000000000000000000000000000000000000' > "$home/state/dash-missing.meta"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: endpoint · confirmed endpoint loss\\n"' > "$state_bin"
    printf '%s\n' '#!/usr/bin/env bash' 'printf dead' > "$agent_bin"
    printf '%s\n' '#!/usr/bin/env bash' 'printf invoked >> "$FM_RECOVERY_SPAWN_LOG"' 'exit 0' > "$spawn_bin"
    chmod +x "$state_bin" "$agent_bin" "$spawn_bin"
    FM_RECOVERY_SPAWN_LOG="$home/spawn.log" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-missing > "$home/recovery.out" 2>&1 &
    recovery_pid=$!
    attempts=0
    while kill -0 "$recovery_pid" 2>/dev/null && [ "$attempts" -lt 100 ]; do
      sleep 0.01
      attempts=$((attempts + 1))
    done
    if kill -0 "$recovery_pid" 2>/dev/null; then
      kill -TERM "$recovery_pid" 2>/dev/null || true
      wait "$recovery_pid" || true
      fail "$case_name recovery waited for a preflight lock that cannot exist"
    fi
    if wait "$recovery_pid"; then status=0; else status=$?; fi
    out=$(< "$home/recovery.out")
    [ "$status" -ne 0 ] || fail "$case_name recovery accepted a missing preflight"
    assert_contains "$out" "no valid private preflight record" "$case_name recovery did not identify the missing preflight"
    [ ! -e "$home/spawn.log" ] || fail "$case_name recovery launched a replacement"
    [ ! -e "$home/data/dash-missing/.ship-preflight.lock" ] && [ ! -L "$home/data/dash-missing/.ship-preflight.lock" ] \
      || fail "$case_name recovery created a preflight lock"
  done
  pass "dashboard recovery fails closed for missing preflights"
}

test_dashboard_recovery_rechecks_deleted_preflight_while_waiting() {
  local home="$TMP_ROOT/dashboard-recovery-deleted-preflight" state_bin="$TMP_ROOT/dashboard-recovery-deleted-preflight-state" agent_bin="$TMP_ROOT/dashboard-recovery-deleted-preflight-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-deleted-preflight-spawn" fakebin="$TMP_ROOT/dashboard-recovery-deleted-preflight-bin" contract="$TMP_ROOT/dashboard-recovery-deleted-preflight-contract.json" id=dash-deleted-preflight fp holder_pid recovery_pid attempts status out
  mkdir -p "$home/data" "$home/state" "$fakebin"
  make_contract "$contract"
  fp=$(publish_preflight_record "$home" "$id" "$contract" direct approved 100) || fail "could not prepare deleted preflight"
  printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' "preflight_fingerprint=$fp" > "$home/state/$id.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: endpoint · confirmed endpoint loss\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf dead' > "$agent_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf invoked >> "$FM_RECOVERY_SPAWN_LOG"' 'exit 0' > "$spawn_bin"
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "$1" = 0.1 ] && [ ! -e "$FM_RACE_WAIT_READY" ]; then
  : > "$FM_RACE_WAIT_READY"
  while [ ! -e "$FM_RACE_WAIT_CONTINUE" ]; do /bin/sleep 0.01; done
fi
exec /bin/sleep "$@"
SH
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin" "$fakebin/sleep"
  (
    STATE="$home/data/$id"
    FM_STATE_OVERRIDE="$STATE" . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$home/data/$id/.ship-preflight.lock"
    : > "$home/holder-ready"
    while [ ! -e "$home/holder-release" ]; do sleep 0.01; done
    fm_lock_release "$home/data/$id/.ship-preflight.lock"
  ) &
  holder_pid=$!
  attempts=0
  while [ ! -e "$home/holder-ready" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$home/holder-ready" ]; then
    : > "$home/holder-release"
    wait "$holder_pid" || true
    fail "deleted-preflight lock holder did not start"
  fi
  PATH="$fakebin:$PATH" FM_RACE_WAIT_READY="$home/wait-ready" FM_RACE_WAIT_CONTINUE="$home/wait-continue" FM_RECOVERY_SPAWN_LOG="$home/spawn.log" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" "$ROOT/bin/fm-dashboard-recovery.sh" observe "$id" > "$home/recovery.out" 2>&1 &
  recovery_pid=$!
  attempts=0
  while [ ! -e "$home/wait-ready" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$home/wait-ready" ]; then
    : > "$home/holder-release"
    : > "$home/wait-continue"
    wait "$holder_pid" || true
    wait "$recovery_pid" || true
    fail "recovery did not wait for the held preflight lock"
  fi
  rm -rf -- "$home/data/$id"
  : > "$home/holder-release"
  : > "$home/wait-continue"
  wait "$holder_pid" || true
  attempts=0
  while kill -0 "$recovery_pid" 2>/dev/null && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if kill -0 "$recovery_pid" 2>/dev/null; then
    kill -TERM "$recovery_pid" 2>/dev/null || true
    wait "$recovery_pid" || true
    fail "recovery waited after its preflight was deleted"
  fi
  if wait "$recovery_pid"; then status=0; else status=$?; fi
  out=$(< "$home/recovery.out")
  [ "$status" -ne 0 ] || fail "recovery accepted a deleted preflight"
  assert_contains "$out" "no valid private preflight record" "deleted preflight refusal was unclear"
  [ ! -e "$home/spawn.log" ] || fail "deleted preflight launched a replacement"
  pass "dashboard recovery rechecks preflight while waiting for its lock"
}

test_dashboard_recovery_serializes_preflight_publication() {
  local home="$TMP_ROOT/dashboard-recovery-preflight-race" state_bin="$TMP_ROOT/dashboard-recovery-preflight-race-state" agent_bin="$TMP_ROOT/dashboard-recovery-preflight-race-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-preflight-race-spawn" fakebin="$TMP_ROOT/dashboard-recovery-preflight-race-bin" contract="$TMP_ROOT/dashboard-recovery-preflight-race-contract.json" id=dash-preflight-race fp real_mktemp spawn_pid publisher_pid attempts status
  mkdir -p "$home/data" "$home/state" "$fakebin"
  real_mktemp=$(command -v mktemp) || fail "could not find mktemp"
  make_contract "$contract"
  fp=$(publish_preflight_record "$home" "$id" "$contract" direct approved 100) || fail "could not prepare approved preflight"
  write_bridge_handoff "$home" "$id" "$contract" direct awaiting_approval 101 2 >/dev/null || fail "could not stage corrected preflight"
  printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' "preflight_fingerprint=$fp" > "$home/state/$id.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: endpoint · confirmed endpoint loss\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf dead' > "$agent_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf started >> "$FM_RACE_SPAWN_LOG"' 'while [ ! -e "$FM_RACE_RELEASE" ]; do sleep 0.01; done' 'exit 0' > "$spawn_bin"
  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
set -eu
for arg in "$@"; do
  case "$arg" in
    "$FM_RACE_PREFLIGHT_LOCK".owner.*)
      [ "${FM_RACE_BRIDGE_PROCESS:-}" != 1 ] || : > "$FM_RACE_LOCK_ATTEMPT"
      ;;
  esac
done
exec "$FM_RACE_REAL_MKTEMP" "$@"
SH
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin" "$fakebin/mktemp"
  PATH="$fakebin:$PATH" FM_RACE_REAL_MKTEMP="$real_mktemp" FM_RACE_PREFLIGHT_LOCK="$home/data/$id/.ship-preflight.lock" FM_RACE_SPAWN_LOG="$home/spawn.log" FM_RACE_RELEASE="$home/release" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" "$ROOT/bin/fm-dashboard-recovery.sh" observe "$id" > "$home/recovery.out" 2>&1 &
  spawn_pid=$!
  attempts=0
  while [ ! -e "$home/spawn.log" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$home/spawn.log" ]; then
    : > "$home/release"
    wait "$spawn_pid" || true
    fail "recovery did not reach the locked replacement handoff"
  fi
  (
    if PATH="$fakebin:$PATH" FM_RACE_REAL_MKTEMP="$real_mktemp" FM_RACE_PREFLIGHT_LOCK="$home/data/$id/.ship-preflight.lock" FM_RACE_BRIDGE_PROCESS=1 FM_RACE_LOCK_ATTEMPT="$home/lock-attempt" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" "$BRIDGE" publish "$id" > "$home/publish.out" 2>&1; then
      printf '%s\n' 0 > "$home/publish.status"
    else
      printf '%s\n' 1 > "$home/publish.status"
    fi
  ) &
  publisher_pid=$!
  attempts=0
  while [ ! -e "$home/lock-attempt" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$home/lock-attempt" ]; then
    : > "$home/release"
    wait "$spawn_pid" || true
    wait "$publisher_pid" || true
    fail "preflight publisher did not attempt the shared lock"
  fi
  attempts=0
  while [ ! -e "$home/publish.status" ] && [ "$attempts" -lt 20 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ -e "$home/publish.status" ]; then
    : > "$home/release"
    wait "$spawn_pid" || true
    wait "$publisher_pid" || true
    fail "preflight correction published before recovery handoff completed"
  fi
  : > "$home/release"
  wait "$spawn_pid"
  status=$?
  [ "$status" -eq 0 ] || fail "locked recovery did not complete: $(cat "$home/recovery.out")"
  wait "$publisher_pid"
  status=$?
  [ "$status" -eq 0 ] && [ "$(cat "$home/publish.status")" = 0 ] || fail "preflight correction did not publish: $(cat "$home/publish.out")"
  jq -e '.state == "awaiting_approval" and .producer_revision == 2' "$home/data/$id/ship-preflight.json" >/dev/null \
    || fail "preflight correction did not publish after recovery handoff"
  pass "dashboard recovery holds preflight approval through replacement handoff"
}

test_dashboard_recovery_signal_exits_without_recording_attempts() {
  local home="$TMP_ROOT/dashboard-recovery-signal" state_bin="$TMP_ROOT/dashboard-recovery-signal-state" agent_bin="$TMP_ROOT/dashboard-recovery-signal-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-signal-spawn" recovery_bin="$TMP_ROOT/dashboard-recovery-signal-runner" contract="$TMP_ROOT/dashboard-recovery-signal-contract.json" signal id fp recovery_pid child_pid attempts status expected release replacement
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: endpoint · confirmed endpoint loss\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf dead' > "$agent_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'trap "exit 0" HUP INT TERM' 'printf started > "$FM_RECOVERY_SIGNAL_STARTED"' 'printf "%s\\n" "$$" > "$FM_RECOVERY_SIGNAL_CHILD_PID"' 'while [ ! -e "$FM_RECOVERY_SIGNAL_RELEASE" ]; do sleep 0.01; done' 'printf replacement > "$FM_RECOVERY_SIGNAL_REPLACEMENT"' 'exit 1' > "$spawn_bin"
  printf '%s\n' 'import os' 'import signal' 'import sys' 'for value in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):' '    signal.signal(value, signal.SIG_DFL)' 'command = os.environ["FM_RECOVERY_SIGNAL_BIN"]' 'os.execvpe(command, [command, *sys.argv[1:]], os.environ)' > "$recovery_bin"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin"
  for signal in HUP INT TERM; do
    id="dash-signal-${signal,,}"
    fp=$(publish_preflight_record "$home" "$id" "$contract" direct approved 100) || fail "could not prepare signal preflight"
    printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' "preflight_fingerprint=$fp" > "$home/state/$id.meta"
    release="$home/release-$signal"
    replacement="$home/replacement-$signal"
    FM_RECOVERY_SIGNAL_BIN="$ROOT/bin/fm-dashboard-recovery.sh" FM_RECOVERY_SIGNAL_STARTED="$home/started-$signal" FM_RECOVERY_SIGNAL_CHILD_PID="$home/child-$signal.pid" FM_RECOVERY_SIGNAL_RELEASE="$release" FM_RECOVERY_SIGNAL_REPLACEMENT="$replacement" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" python3 "$recovery_bin" observe "$id" > "$home/recovery-$signal.out" 2>&1 &
    recovery_pid=$!
    attempts=0
    while [ ! -e "$home/started-$signal" ] && [ "$attempts" -lt 100 ]; do
      sleep 0.01
      attempts=$((attempts + 1))
    done
    if [ ! -e "$home/started-$signal" ]; then
      : > "$release"
      wait "$recovery_pid" || true
      fail "recovery did not reach the signal handoff for $signal"
    fi
    case "$signal" in
      HUP) expected=129 ;;
      INT) expected=130 ;;
      TERM) expected=143 ;;
    esac
    kill -s "$signal" "$recovery_pid" || fail "could not signal recovery for $signal"
    if wait "$recovery_pid"; then status=0; else status=$?; fi
    [ "$status" -eq "$expected" ] || fail "$signal recovery continued after cleanup ($status): $(cat "$home/recovery-$signal.out")"
    [ ! -e "$home/state/dashboard-recovery/$id.json" ] || fail "$signal recovery recorded an attempt"
    [ ! -e "$home/data/$id/.ship-preflight.lock" ] && [ ! -L "$home/data/$id/.ship-preflight.lock" ] \
      || fail "$signal recovery retained the preflight lock"
    child_pid=$(cat "$home/child-$signal.pid")
    if kill -0 "$child_pid" 2>/dev/null; then
      : > "$release"
      sleep 0.05
      fail "$signal recovery left its spawn child running"
    fi
    : > "$release"
    sleep 0.05
    [ ! -e "$replacement" ] || fail "$signal recovery allowed a replacement after cancellation"
  done
  pass "dashboard recovery signals stop blocked replacement spawns"
}

test_dashboard_recovery_cancels_unregistered_spawn() {
  local home="$TMP_ROOT/dashboard-recovery-unregistered" state_bin="$TMP_ROOT/dashboard-recovery-unregistered-state" agent_bin="$TMP_ROOT/dashboard-recovery-unregistered-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-unregistered-spawn" recovery_bin="$TMP_ROOT/dashboard-recovery-unregistered-runner" ready="$TMP_ROOT/dashboard-recovery-unregistered-ready" continue="$TMP_ROOT/dashboard-recovery-unregistered-continue" replacement="$TMP_ROOT/dashboard-recovery-unregistered-replacement" consumed="$TMP_ROOT/dashboard-recovery-unregistered-consumed" contract="$TMP_ROOT/dashboard-recovery-unregistered-contract.json" fp recovery_pid status attempts
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"
  fp=$(publish_preflight_record "$home" dash-unregistered "$contract" direct approved 100) || fail "could not prepare unregistered recovery preflight"
  printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' "preflight_fingerprint=$fp" > "$home/state/dash-unregistered.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: endpoint · confirmed endpoint loss\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf dead' > "$agent_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'for _ in $(seq 1 100); do' '  if [ -e "$FM_DASHBOARD_RECOVERY_CANCEL_GUARD" ]; then' '    rm -f "$FM_DASHBOARD_RECOVERY_CANCEL_GUARD"' '    rmdir "${FM_DASHBOARD_RECOVERY_CANCEL_GUARD%/cancelled}"' '    : > "$FM_RECOVERY_UNREGISTERED_CONSUMED"' '    exit 4' '  fi' '  sleep 0.01' 'done' 'printf replacement > "$FM_RECOVERY_UNREGISTERED_REPLACEMENT"' 'exit 1' > "$spawn_bin"
  printf '%s\n' 'import os' 'import signal' 'import sys' 'for value in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):' '    signal.signal(value, signal.SIG_DFL)' 'command = os.environ["FM_RECOVERY_UNREGISTERED_BIN"]' 'os.execvpe(command, [command, *sys.argv[1:]], os.environ)' > "$recovery_bin"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin"
  FM_DASHBOARD_RECOVERY_TESTING=1 FM_DASHBOARD_RECOVERY_TEST_PID_READY="$ready" FM_DASHBOARD_RECOVERY_TEST_PID_CONTINUE="$continue" FM_RECOVERY_UNREGISTERED_BIN="$ROOT/bin/fm-dashboard-recovery.sh" FM_RECOVERY_UNREGISTERED_CONSUMED="$consumed" FM_RECOVERY_UNREGISTERED_REPLACEMENT="$replacement" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" python3 "$recovery_bin" observe dash-unregistered > "$home/recovery.out" 2>&1 &
  recovery_pid=$!
  attempts=0
  while [ ! -e "$ready" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$ready" ]; then
    : > "$continue"
    wait "$recovery_pid" || true
    fail "recovery did not stop before child registration"
  fi
  kill -TERM "$recovery_pid" || fail "could not signal unregistered recovery"
  : > "$continue"
  if wait "$recovery_pid"; then status=0; else status=$?; fi
  [ "$status" -eq 143 ] || fail "unregistered recovery did not stop on TERM ($status): $(cat "$home/recovery.out")"
  attempts=0
  while [ ! -e "$consumed" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  [ -e "$consumed" ] || fail "unregistered recovery did not deliver its cancellation guard"
  [ ! -e "$replacement" ] || fail "unregistered recovery launched a replacement after cancellation"
  [ ! -e "$home/data/dash-unregistered/.ship-preflight.lock" ] && [ ! -L "$home/data/dash-unregistered/.ship-preflight.lock" ] \
    || fail "unregistered recovery retained the preflight lock"
  pass "dashboard recovery cancels an unregistered spawn"
}

test_dashboard_recovery_relaunches_dead_endpoint() {
  local home="$TMP_ROOT/dashboard-recovery-dead" state_bin="$TMP_ROOT/dashboard-recovery-dead-state" agent_bin="$TMP_ROOT/dashboard-recovery-dead-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-dead-spawn"
  mkdir -p "$home/data" "$home/state/dashboard-transitions"
  printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' 'dashboard_incarnation=i-current' > "$home/state/dash-dead.meta"
  printf '%s\n' '{"schema_version":1,"id":"dash-dead","incarnation":"i-prior","state":"done","transition_at":100,"active_seconds":1}' > "$home/state/dashboard-transitions/dash-dead.json"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: endpoint · confirmed endpoint loss\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf dead' > "$agent_bin"
  # shellcheck disable=SC2016 # Positional parameters expand in the generated spawn fixture.
  printf '%s\n' '#!/usr/bin/env bash' '[ "$2" = --relaunch ] && [ "$3" = --dashboard-recovery ] || exit 2' 'exit 0' > "$spawn_bin"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-dead \
    || fail "dead endpoint recovery did not relaunch"
  [ ! -e "$home/state/dashboard-recovery/dash-dead.json" ] || fail "successful dead-endpoint relaunch left a recovery failure"
  pass "dashboard relaunches a confirmed dead endpoint"
}

test_dashboard_recovery_preserves_terminal_transition() {
  local home="$TMP_ROOT/dashboard-recovery-terminal" state_bin="$TMP_ROOT/dashboard-recovery-terminal-state" agent_bin="$TMP_ROOT/dashboard-recovery-terminal-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-terminal-spawn" spawn_log="$TMP_ROOT/dashboard-recovery-terminal-spawn-log" record
  mkdir -p "$home/data" "$home/state/dashboard-transitions"
  printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' 'dashboard_incarnation=i-terminal' > "$home/state/dash-terminal.meta"
  record="$home/state/dashboard-transitions/dash-terminal.json"
  printf '%s\n' '{"schema_version":1,"id":"dash-terminal","incarnation":"i-terminal","state":"done","transition_at":100,"active_seconds":1}' > "$record"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: endpoint · confirmed endpoint loss\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf dead' > "$agent_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf invoked >> "$FM_RECOVERY_SPAWN_LOG"' 'exit 0' > "$spawn_bin"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin"
  FM_RECOVERY_SPAWN_LOG="$spawn_log" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-terminal \
    || fail "terminal recovery check failed"
  [ ! -e "$spawn_log" ] || fail "terminal dashboard transition launched a replacement"
  jq -e '.state == "done" and .incarnation == "i-terminal" and .transition_at == 100' "$record" >/dev/null \
    || fail "terminal dashboard transition was overwritten"
  [ ! -e "$home/state/dashboard-recovery/dash-terminal.json" ] || fail "terminal dashboard transition recorded a recovery failure"
  pass "dashboard preserves a terminal task instead of relaunching it"
}

test_dashboard_recovery_preserves_legacy_terminal_receipt() {
  local home="$TMP_ROOT/dashboard-recovery-legacy-terminal" state_bin="$TMP_ROOT/dashboard-recovery-legacy-terminal-state" agent_bin="$TMP_ROOT/dashboard-recovery-legacy-terminal-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-legacy-terminal-spawn" spawn_log="$TMP_ROOT/dashboard-recovery-legacy-terminal-spawn-log"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' > "$home/state/dash-legacy-terminal.meta"
  printf '%s\n' 'done: legacy task completed' > "$home/state/dash-legacy-terminal.status"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: endpoint · confirmed endpoint loss\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf dead' > "$agent_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf invoked >> "$FM_RECOVERY_SPAWN_LOG"' 'exit 0' > "$spawn_bin"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin"
  FM_RECOVERY_SPAWN_LOG="$spawn_log" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-legacy-terminal \
    || fail "legacy terminal recovery check failed"
  [ ! -e "$spawn_log" ] || fail "legacy terminal receipt launched a replacement"
  [ ! -e "$home/state/dashboard-transitions/dash-legacy-terminal.json" ] \
    || fail "legacy terminal receipt was overwritten with unknown"
  [ ! -e "$home/state/dashboard-recovery/dash-legacy-terminal.json" ] \
    || fail "legacy terminal receipt recorded a recovery failure"
  pass "dashboard preserves a legacy terminal receipt instead of relaunching it"
}

test_dashboard_recovery_preserves_resolved_legacy_terminal_receipt() {
  local home="$TMP_ROOT/dashboard-recovery-legacy-terminal-resolved" state_bin="$TMP_ROOT/dashboard-recovery-legacy-terminal-resolved-state" agent_bin="$TMP_ROOT/dashboard-recovery-legacy-terminal-resolved-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-legacy-terminal-resolved-spawn" spawn_log="$TMP_ROOT/dashboard-recovery-legacy-terminal-resolved-spawn-log" i
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' > "$home/state/dash-legacy-terminal-resolved.meta"
  printf '%s\n' 'done: legacy task completed' > "$home/state/dash-legacy-terminal-resolved.status"
  i=0
  while [ "$i" -lt 65 ]; do
    printf 'resolved [key=review]: captain acknowledged completion %s\n' "$i" >> "$home/state/dash-legacy-terminal-resolved.status"
    i=$((i + 1))
  done
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: endpoint · confirmed endpoint loss\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf dead' > "$agent_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf invoked >> "$FM_RECOVERY_SPAWN_LOG"' 'exit 0' > "$spawn_bin"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin"
  FM_RECOVERY_SPAWN_LOG="$spawn_log" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-legacy-terminal-resolved \
    || fail "resolved legacy terminal recovery check failed"
  [ ! -e "$spawn_log" ] || fail "resolved legacy terminal receipt launched a replacement"
  [ ! -e "$home/state/dashboard-transitions/dash-legacy-terminal-resolved.json" ] \
    || fail "resolved legacy terminal receipt was overwritten with unknown"
  [ ! -e "$home/state/dashboard-recovery/dash-legacy-terminal-resolved.json" ] \
    || fail "resolved legacy terminal receipt recorded a recovery failure"
  pass "dashboard preserves a resolved legacy terminal receipt instead of relaunching it"
}

test_dashboard_recovery_preserves_persisted_terminal_receipt() {
  local home="$TMP_ROOT/dashboard-recovery-persisted-terminal" state_bin="$TMP_ROOT/dashboard-recovery-persisted-terminal-state" agent_bin="$TMP_ROOT/dashboard-recovery-persisted-terminal-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-persisted-terminal-spawn" spawn_log="$TMP_ROOT/dashboard-recovery-persisted-terminal-spawn-log" record i
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' 'dashboard_incarnation=i-persisted-terminal' > "$home/state/dash-persisted-terminal.meta"
  "$ROOT/bin/fm-dashboard-transition.sh" append "$home/state" dash-persisted-terminal done 100 'done: task completed' \
    || fail "terminal status append failed"
  "$ROOT/bin/fm-dashboard-transition.sh" record "$home/state" dash-persisted-terminal unknown 101 \
    || fail "later state transition failed"
  i=0
  while [ "$i" -lt 65 ]; do
    "$ROOT/bin/fm-dashboard-transition.sh" append "$home/state" dash-persisted-terminal '' "$((102 + i))" "resolved [key=review]: captain acknowledged completion $i" \
      || fail "later status append failed"
    i=$((i + 1))
  done
  record="$home/state/dashboard-transitions/dash-persisted-terminal.json"
  jq -e '.state == "unknown" and .incarnation == "i-persisted-terminal" and .terminal_receipt == {state:"done",recorded_at:100}' "$record" >/dev/null \
    || fail "later state transition lost the terminal receipt"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: endpoint · confirmed endpoint loss\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf dead' > "$agent_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf invoked >> "$FM_RECOVERY_SPAWN_LOG"' 'exit 0' > "$spawn_bin"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin"
  FM_RECOVERY_SPAWN_LOG="$spawn_log" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-persisted-terminal \
    || fail "persisted terminal recovery check failed"
  [ ! -e "$spawn_log" ] || fail "persisted terminal receipt launched a replacement"
  pass "dashboard preserves a terminal receipt after later transitions"
}

test_terminal_status_cancels_recovery_claim() {
  local home="$TMP_ROOT/dashboard-recovery-claim" claim status
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' 'kind=ship' 'dashboard_incarnation=i-claim' > "$home/state/dash-claim.meta"
  claim=$("$ROOT/bin/fm-dashboard-transition.sh" recovery-claim "$home/state" dash-claim 100) \
    || fail "recovery claim was not created"
  [ -n "$claim" ] || fail "recovery claim did not return an identity"
  [ -f "$home/state/dashboard-transitions/dash-claim.recovery-claim" ] \
    || fail "recovery claim was not persisted"
  "$ROOT/bin/fm-status-event.sh" append "$home/state" dash-claim 'done: terminal writer won' \
    || fail "terminal status event failed"
  [ ! -e "$home/state/dashboard-transitions/dash-claim.recovery-claim" ] \
    || fail "terminal status event did not cancel the recovery claim"
  jq -e '.state == "done"' "$home/state/dashboard-transitions/dash-claim.json" >/dev/null \
    || fail "terminal status event did not persist its transition"
  status=0
  "$ROOT/bin/fm-dashboard-transition.sh" recovery-working "$home/state" dash-claim 101 "$claim" || status=$?
  [ "$status" -eq 3 ] || fail "terminal status event did not defeat the recovery launch claim"
  jq -e '.state == "done"' "$home/state/dashboard-transitions/dash-claim.json" >/dev/null \
    || fail "recovery launch state overwrote the terminal transition"
  pass "terminal status writer cancels a pending recovery launch"
}

test_dashboard_recovery_defers_control_lock_contention() {
  local home="$TMP_ROOT/dashboard-recovery-contention" state_bin="$TMP_ROOT/dashboard-recovery-contention-state" agent_bin="$TMP_ROOT/dashboard-recovery-contention-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-contention-spawn" record
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' > "$home/state/dash-a4.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: none · endpoint gone\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf missing' > "$agent_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "replacement refused\\n" >&2' 'exit 1' > "$spawn_bin"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" FM_DASHBOARD_RECOVERY_MAX_ATTEMPTS=2 "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-a4 || fail "initial recovery attempt failed"
  record="$home/state/dashboard-recovery/dash-a4.json"
  jq -e '.state == "pending" and .attempts == 1' "$record" >/dev/null || fail "initial recovery failure must be recorded"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "another lifecycle action is already running\\n" >&2' 'exit 4' > "$spawn_bin"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" FM_DASHBOARD_RECOVERY_MAX_ATTEMPTS=2 "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-a4 || fail "contention recovery must defer"
  jq -e '.state == "pending" and .attempts == 1' "$record" >/dev/null || fail "control-lock contention must not exhaust recovery"
  pass "dashboard defers recovery while task control is busy"
}

test_dashboard_recovery_rechecks_eligibility_under_lock() {
  local home="$TMP_ROOT/dashboard-recovery-stale" state_bin="$TMP_ROOT/dashboard-recovery-stale-state" agent_bin="$TMP_ROOT/dashboard-recovery-stale-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-stale-spawn" state_file="$TMP_ROOT/dashboard-recovery-stale-state-file" spawn_log="$TMP_ROOT/dashboard-recovery-stale-spawn-log" release="$TMP_ROOT/dashboard-recovery-stale-release" first second tries
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' > "$home/state/dash-stale.meta"
  printf '%s\n' unknown > "$state_file"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: %s · source: endpoint\n" "$(cat "$FM_RECOVERY_STATE_FILE")"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf dead' > "$agent_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "started\n" >> "$FM_RECOVERY_SPAWN_LOG"' 'while [ ! -e "$FM_RECOVERY_RELEASE" ]; do sleep 0.01; done' 'printf "working\n" > "$FM_RECOVERY_STATE_FILE"' > "$spawn_bin"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin"
  FM_RECOVERY_STATE_FILE="$state_file" FM_RECOVERY_SPAWN_LOG="$spawn_log" FM_RECOVERY_RELEASE="$release" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-stale &
  first=$!
  tries=0
  while [ ! -s "$spawn_log" ] && [ "$tries" -lt 50 ]; do
    sleep 0.02
    tries=$((tries + 1))
  done
  [ -s "$spawn_log" ] || fail "first recovery did not submit a replacement"
  FM_RECOVERY_STATE_FILE="$state_file" FM_RECOVERY_SPAWN_LOG="$spawn_log" FM_RECOVERY_RELEASE="$release" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-stale &
  second=$!
  sleep 0.2
  : > "$release"
  wait "$first" || fail "first recovery did not finish"
  wait "$second" || fail "second recovery did not finish"
  [ "$(wc -l < "$spawn_log")" -eq 1 ] || fail "stale recovery eligibility submitted a duplicate replacement"
  pass "dashboard rechecks recovery eligibility after locking the task"
}

test_missing_recovery_control_lock_is_retryable() {
  local home="$TMP_ROOT/recovery-control-lock" out status lock
  mkdir -p "$home/data" "$home/state" "$home/config"
  lock="$home/state/.control-recovery-lock-a1.lock"
  mkdir "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" recovery-lock-a1 --recover-missing 2>&1)
  status=$?
  [ "$status" -eq 4 ] || fail "missing-endpoint control contention must return retry-later"
  assert_contains "$out" "another lifecycle action" "retry-later refusal was unclear"
  pass "missing-endpoint control contention is retryable"
}

test_dashboard_recovery_surfaces_unsupported_replacement() {
  local home="$TMP_ROOT/dashboard-recovery-unsupported" state_bin="$TMP_ROOT/dashboard-recovery-unsupported-state" agent_bin="$TMP_ROOT/dashboard-recovery-unsupported-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-unsupported-spawn" mock="$TMP_ROOT/dashboard-recovery-unsupported-snapshot" record
  mkdir -p "$home/data" "$home/state"
  chmod 700 "$home/data"
  printf '%s\n' 'kind=ship' 'backend=zellij' 'window=main:worker' > "$home/state/dash-a2.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: none · endpoint gone\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf missing' > "$agent_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "replacement unavailable\\n" >&2' 'exit 3' > "$spawn_bin"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-a2 || fail "unsupported recovery record failed"
  record="$home/state/dashboard-recovery/dash-a2.json"
  jq -e '.state == "unrecoverable" and .attempts == 0 and .reason == "replacement unavailable"' "$record" >/dev/null \
    || fail "unsupported recovery did not become terminal"
  write_snapshot "$mock" unknown '[]' '' pane 'endpoint unavailable' null null '{"state":"unrecoverable"}'
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=120 "$DASHBOARD" refresh >/dev/null || fail "unsupported dashboard refresh failed"
  jq -e '.projection.needs_you == [{id:"dash-a1",name:"Build dashboard",kind:"failed",summary:"Worker recovery failed",slack_thread_url:null}]' "$home/data/dashboard.json" >/dev/null \
    || fail "dashboard did not surface unsupported recovery"
  pass "dashboard surfaces unsupported worker replacement"
}

test_dashboard_recovery_excludes_endpoint_outage() {
  local home="$TMP_ROOT/dashboard-recovery-timing" state_bin="$TMP_ROOT/dashboard-recovery-timing-state" agent_bin="$TMP_ROOT/dashboard-recovery-timing-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-timing-spawn" fake_date="$TMP_ROOT/dashboard-recovery-timing-bin/date" gen record
  mkdir -p "$home/data" "$home/state" "$TMP_ROOT/dashboard-recovery-timing-bin"
  printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' 'dashboard_incarnation=i-recovery-timing' > "$home/state/dash-a3.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: none · endpoint gone\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf missing' > "$agent_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$spawn_bin"
  # shellcheck disable=SC2016 # Variables expand in the generated date fixture.
  printf '%s\n' '#!/usr/bin/env bash' 'if [ "$1" = +%s ]; then printf "%s\\n" "$FM_FAKE_NOW"; else command date "$@"; fi' > "$fake_date"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin" "$fake_date"
  gen=$(PATH="$TMP_ROOT/dashboard-recovery-timing-bin:$PATH" FM_FAKE_NOW=100 "$ROOT/bin/fm-busy-event.sh" arm "$home/state" dash-a3) || fail "initial busy event failed"
  PATH="$TMP_ROOT/dashboard-recovery-timing-bin:$PATH" FM_FAKE_NOW=110 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-a3 || fail "recovery confirmation failed"
  PATH="$TMP_ROOT/dashboard-recovery-timing-bin:$PATH" FM_FAKE_NOW=120 "$ROOT/bin/fm-busy-event.sh" arm "$home/state" dash-a3 >/dev/null || fail "replacement busy event failed"
  record="$home/state/dashboard-transitions/dash-a3.json"
  jq -e '.state == "working" and .transition_at == 120 and .active_seconds == 10' "$record" >/dev/null \
    || fail "endpoint outage was counted as active time"
  pass "dashboard excludes confirmed endpoint outage time"
}

test_dashboard_keeps_only_active_tasks() {
  local home="$TMP_ROOT/dashboard-active" mock="$TMP_ROOT/dashboard-active-snapshot" record
  mkdir -p "$home/data" "$home/state"
  chmod 700 "$home/data"
  write_snapshot "$mock" working '[]'
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=100 "$DASHBOARD" refresh >/dev/null || fail "active dashboard refresh failed"
  write_snapshot "$mock" "done" '[]'
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=110 "$DASHBOARD" refresh >/dev/null || fail "completed dashboard refresh failed"
  record="$home/data/dashboard.json"
  jq -e '.projection.in_progress == [] and .projection.needs_you == [] and .technical.tasks == []' "$record" >/dev/null \
    || fail "dashboard must not retain completed tasks as active work"
  write_snapshot "$mock" failed '[]'
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=120 "$DASHBOARD" refresh >/dev/null || fail "failed dashboard refresh failed"
  jq -e '.projection.in_progress == [] and .projection.needs_you == [] and .technical.tasks == []' "$record" >/dev/null \
    || fail "dashboard must not retain failed tasks as active work"
  pass "dashboard retains only active task records"
}

test_preflight_is_private_and_does_not_touch_lifecycle() {
  local home="$TMP_ROOT/private" contract="$TMP_ROOT/private-contract.json"
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"
  publish_preflight_record "$home" private-a1 "$contract" direct awaiting_approval 100 >/dev/null || fail "private preflight create failed"
  [ -f "$home/data/private-a1/ship-preflight.json" ] || fail "preflight did not write its private record"
  [ ! -e "$home/state/private-a1.meta" ] || fail "preflight must not create a worker lifecycle record"
  [ ! -e "$home/projects" ] || fail "preflight must not create or modify a project copy"
  jq -e '.state == "awaiting_approval" and .origin == "direct"' "$home/data/private-a1/ship-preflight.json" >/dev/null \
    || fail "private preflight record did not preserve its approval boundary"
  pass "preflight remains private and separate from worker and production lifecycle"
}

test_dashboard_rejects_unsafe_or_oversized_inputs() {
  local home="$TMP_ROOT/dashboard-safety" mock="$TMP_ROOT/dashboard-safety-snapshot" record out status
  mkdir -p "$home/data" "$home/state"
  write_snapshot "$mock" working '[]'
  record="$home/data/dashboard.json"
  chmod 733 "$home/data"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" "$DASHBOARD" show 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "dashboard must reject a writable data directory when reading"
  assert_contains "$out" "unsafe data directory" "unsafe dashboard read refusal was unclear"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=100 "$DASHBOARD" refresh 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "dashboard must reject a writable data directory when publishing"
  assert_contains "$out" "unsafe data directory" "unsafe dashboard publication refusal was unclear"
  assert_absent "$record" "unsafe dashboard directory received a private record"
  chmod 700 "$home/data"
  printf '%s\n' '{"schema_version":1,"technical":{"tasks":[]}}' > "$record"
  chmod 644 "$record"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=100 "$DASHBOARD" refresh 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "dashboard must reject an unsafe existing record"
  assert_contains "$out" "existing dashboard record is unsafe" "unsafe record refusal was unclear"
  chmod 600 "$record"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_MAX_SNAPSHOT_BYTES=8 FM_DASHBOARD_NOW=100 "$DASHBOARD" refresh 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "dashboard must bound its canonical snapshot input"
  assert_contains "$out" "snapshot exceeds the bounded size" "bounded snapshot refusal was unclear"
  pass "dashboard rejects unsafe records and bounds canonical input"
}

test_direct_and_bridge_owned_preflight_authority
test_direct_preflight_publisher_and_approval
test_delivery_boundary_is_pr_only
test_direct_complete_plan_publisher_bypasses_duplicate_approval
test_direct_record_size_refusal_preserves_prior_record
test_direct_preflight_snapshots_contract_before_parse
test_preflight_rejects_oversized_inputs_before_publication
test_direct_preflight_serializes_corrections
test_preflight_requires_typed_authority_evidence
test_preflight_requires_a_bounded_producer_revision
test_grouped_questions_and_bounded_contract
test_correction_bypass_and_stale_refusal
test_preflight_rejects_tampering_and_future_approvals
test_preflight_rejects_cross_task_records
test_bridge_preserves_handoff_when_record_directories_are_unsafe
test_bridge_claims_a_handoff_before_reading_it
test_bridge_recovers_a_claim_after_interruption
test_bridge_restores_a_claim_interrupted_after_rename
test_bridge_preserves_claimed_correction_on_cleanup_conflict
test_bridge_recovers_a_hard_linked_claim_after_interruption
test_bridge_preserves_claimed_correction_against_delayed_handoff
test_bridge_preserves_claimed_correction_on_link_race
test_bridge_serializes_concurrent_publish_claims
test_bridge_preserves_approved_record_on_invalid_handoff
test_bridge_rejects_stale_producer_revisions
test_bridge_rejects_unversioned_current_records
test_spawn_enforces_the_durable_preflight
test_recovery_submission_serializes_preflight_corrections
test_dashboard_projection_and_active_time
test_dashboard_omits_uncheckpointed_active_work
test_dashboard_projects_unknown_launch_work
test_dashboard_recovers_stale_publication_lock
test_dashboard_filters_and_checking_phase
test_dashboard_transition_ledger_tracks_canonical_edges
test_status_event_persists_transition_before_status
test_dashboard_busy_events_preserve_hidden_transitions
test_dashboard_busy_events_replay_interrupted_transitions
test_dashboard_replays_spawn_busy_event_across_metadata_updates
test_dashboard_recovery_surfaces_only_exhausted_loss
test_dashboard_recovery_defers_preflight_approval
test_dashboard_recovery_refuses_missing_preflight
test_dashboard_recovery_rechecks_deleted_preflight_while_waiting
test_dashboard_recovery_serializes_preflight_publication
test_dashboard_recovery_signal_exits_without_recording_attempts
test_dashboard_recovery_cancels_unregistered_spawn
test_dashboard_recovery_relaunches_dead_endpoint
test_dashboard_recovery_preserves_terminal_transition
test_dashboard_recovery_preserves_legacy_terminal_receipt
test_dashboard_recovery_preserves_resolved_legacy_terminal_receipt
test_dashboard_recovery_preserves_persisted_terminal_receipt
test_terminal_status_cancels_recovery_claim
test_dashboard_recovery_defers_control_lock_contention
test_dashboard_recovery_rechecks_eligibility_under_lock
test_missing_recovery_control_lock_is_retryable
test_dashboard_recovery_surfaces_unsupported_replacement
test_dashboard_recovery_excludes_endpoint_outage
test_dashboard_keeps_only_active_tasks
test_preflight_is_private_and_does_not_touch_lifecycle
test_dashboard_rejects_unsafe_or_oversized_inputs
echo "# all fm-ship-end-to-end tests passed"
