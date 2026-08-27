#!/usr/bin/env bash
# Behavioral coverage for the pure subscription-routing selector.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAB=$(fm_test_tmproot fm-route-tests)
ROUTE="$ROOT/bin/fm-route.sh"
REQUEST="$LAB/request.json"
CANDIDATES="$LAB/candidates.json"
export FM_STATE_OVERRIDE="$LAB/state"
export FM_HOME="$LAB"
FM_CONFIG_OVERRIDE="$LAB/config"

command -v jq >/dev/null 2>&1 || fail "jq is required for routing tests"

write_request() {
  jq -n \
    --arg task_id task-1 \
    --arg task_class "$1" \
    --arg work_type "$2" \
    --arg risk "$3" \
    --argjson independent "$4" \
    --argjson requested_workers "$5" \
    --arg reasoning "$6" \
    --argjson estimated_seconds "$7" \
    '{taskId:$task_id,taskClass:$task_class,workType:$work_type,risk:$risk,independent:$independent,requestedWorkers:$requested_workers,requiredReasoningClass:$reasoning,estimatedSeconds:$estimated_seconds}' \
    >"$REQUEST"
}

write_candidates() {
  printf '%s\n' "$1" >"$CANDIDATES"
}

candidate() {
  jq -cn \
    --arg profile "$1" \
    --arg lane "$2" \
    --argjson fit "$3" \
    --argjson spend "$4" \
    --argjson active "$5" \
    --argjson successes "$6" \
    --argjson attempts "$7" \
    --argjson cost "$8" \
    '{profile:$profile,harness:"pi",model:("model-"+$profile),provider:"provider",lane:$lane,account:"none",fitTier:$fit,reasoningClass:"strong",catalogSupported:true,authState:"usable",spendPriority:$spend,runwaySeconds:10000,activeLane:$active,historySuccesses:$successes,historyAttempts:$attempts,costTier:$cost}'
}

terminal_outcome() {
  jq -cn --arg profile "$1" --arg task "$2" --arg terminal "$3" \
    '{kind:"terminal",timestamp:1000,taskId:$task,generation:("gen-"+$task),profile:$profile,provider:"provider",lane:("lane-"+$task),account:"none",taskClass:"standard",workType:"implementation",risk:"medium",mode:"automatic",elapsedSeconds:10,tests:"unknown",review:"unknown",redundant:"no",terminal:$terminal}'
}

write_candidate_array() {
  printf '%s\n' "$@" | jq -s . >"$CANDIDATES"
}

select_json() {
  "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES" --now 1000
}

seed_v2_policy() {
  mkdir -p "$FM_CONFIG_OVERRIDE"
  jq -n --arg mode "$1" '{
    schemaVersion:2,
    routing:{mode:$mode},
    profiles:{
      "pi-test":{
        harness:"pi",model:"model-only",provider:"provider",lane:"lane-1",
        reasoningClass:"strong",workTypes:["implementation"]
      }
    },
    default:["pi-test"]
  }' >"$FM_CONFIG_OVERRIDE/crew-dispatch.json"
}

test_off_mode_returns_static_without_initializing_routing_state() {
  local out
  rm -rf "$FM_STATE_OVERRIDE/routing"
  seed_v2_policy off
  write_request standard implementation medium false 1 strong 3600
  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null)]"

  out=$(select_json) || fail "off-mode selection failed"
  jq -e '
    . == {
      action:"static",reason:"routing-mode-off",selected:null,ranked:[],
      rejected:[],uncertainty:[],maxWorkers:1
    }
  ' <<<"$out" >/dev/null || fail "off mode did not return the exact static decision"
  [ ! -e "$FM_STATE_OVERRIDE/routing" ] \
    || fail "off-mode selection initialized or mutated routing state"

  rm -f "$FM_CONFIG_OVERRIDE/crew-dispatch.json"
  pass "valid version 2 off mode returns static without routing-state mutation"
}

test_policy_boundaries_are_explicit_and_fail_closed() {
  local out rc
  rm -rf "$FM_STATE_OVERRIDE/routing"
  mkdir -p "$FM_CONFIG_OVERRIDE"
  printf '%s\n' '{"schemaVersion":2,"routing":{"mode":"sideways"}}' \
    >"$FM_CONFIG_OVERRIDE/crew-dispatch.json"
  write_request standard implementation medium false 1 strong 3600
  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null)]"

  set +e
  out=$(select_json 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "invalid active policy did not fail closed"
  [ "$out" = "fm-route: active dispatch policy is invalid" ] \
    || fail "invalid active policy leaked an unstable diagnostic: $out"
  [ ! -e "$FM_STATE_OVERRIDE/routing" ] \
    || fail "invalid active policy initialized or mutated routing state"

  rm -f "$FM_CONFIG_OVERRIDE/crew-dispatch.json"
  out=$(select_json) || fail "missing policy did not retain direct selector compatibility"
  jq -e '.action == "selected" and .selected.profile == "only"' <<<"$out" >/dev/null \
    || fail "missing policy did not retain direct selector compatibility"
  [ -d "$FM_STATE_OVERRIDE/routing/reservations" ] \
    || fail "missing-policy direct selector did not follow its legacy state path"
  pass "invalid active policy fails closed while absent policy keeps legacy selection"
}

test_active_policy_path_is_contained_and_never_symlinked() {
  local case_home outside real_config state out rc label
  write_request standard implementation medium false 1 strong 3600
  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null)]"

  for label in policy-symlink config-symlink home-symlink outside-override; do
    case_home="$LAB/path-$label-home"
    outside="$LAB/path-$label-outside"
    real_config="$LAB/path-$label-real-config"
    state="$LAB/path-$label-state"
    mkdir -p "$case_home" "$outside" "$real_config"
    seed_v2_policy off
    cp "$FM_CONFIG_OVERRIDE/crew-dispatch.json" "$real_config/crew-dispatch.json"
    case "$label" in
      policy-symlink)
        mkdir -p "$case_home/config"
        ln -s "$real_config/crew-dispatch.json" "$case_home/config/crew-dispatch.json"
        ;;
      config-symlink) ln -s "$real_config" "$case_home/config" ;;
      home-symlink)
        rm -rf "$case_home"
        mkdir -p "$outside/config"
        cp "$real_config/crew-dispatch.json" "$outside/config/crew-dispatch.json"
        ln -s "$outside" "$case_home"
        ;;
      outside-override)
        mkdir -p "$case_home/config"
        cp "$real_config/crew-dispatch.json" "$outside/crew-dispatch.json"
        ;;
    esac

    set +e
    if [ "$label" = outside-override ]; then
      out=$(FM_HOME="$case_home" FM_CONFIG_OVERRIDE="$outside" FM_STATE_OVERRIDE="$state" \
        "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES" --now 1000 2>&1)
    else
      out=$(FM_HOME="$case_home" FM_STATE_OVERRIDE="$state" \
        "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES" --now 1000 2>&1)
    fi
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$label active policy path was accepted"
    [ "$out" = "fm-route: active dispatch policy path is unsafe" ] \
      || fail "$label emitted an unstable diagnostic: $out"
    [ ! -e "$state/routing" ] || fail "$label mutated routing state"
  done
  rm -f "$FM_CONFIG_OVERRIDE/crew-dispatch.json"
  pass "active policy rejects symlinked and out-of-home paths before state mutation"
}

test_version_one_policy_retains_selector_compatibility() {
  local out
  rm -rf "$FM_STATE_OVERRIDE/routing"
  mkdir -p "$FM_CONFIG_OVERRIDE"
  jq -n '{
    schemaVersion:1,
    routing:{mode:"off"},
    default:{harness:"pi",model:"model-only"}
  }' >"$FM_CONFIG_OVERRIDE/crew-dispatch.json"
  write_request standard implementation medium false 1 strong 3600
  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null)]"
  out=$(select_json) || fail "version 1 policy broke direct selector compatibility"
  jq -e '.action == "selected" and .selected.profile == "only"' <<<"$out" >/dev/null \
    || fail "version 1 policy was treated as version 2 rollback"
  rm -f "$FM_CONFIG_OVERRIDE/crew-dispatch.json"
  pass "version 1 policy retains legacy direct selector behavior"
}

expect_failure_contains() {
  local expected=$1 out rc
  shift
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected command failure: $*"
  assert_contains "$out" "$expected" "routing validation error"
}

test_fit_beats_quota() {
  write_request standard implementation medium false 1 strong 7200
  write_candidate_array \
    "$(candidate codex-sol codex-primary 3 -1 99 0 0 null)" \
    "$(candidate pi-flash pi-google-1 2 4 0 0 0 null)"
  select_json | jq -e '
    keys == ["action","maxWorkers","ranked","reason","rejected","selected","uncertainty"]
    and .selected.profile == "codex-sol"
    and .reason == "lexicographic-policy"
  ' >/dev/null \
    || fail "task fit did not outrank quota and load"
  pass "task fit is the first lexicographic selector key"
}

test_unknowns_are_disclosed_not_zero() {
  write_request standard implementation low false 1 standard 3600
  write_candidates '[{"profile":"pi-kimi","harness":"pi","model":"cliproxyapi/kimi-k3","provider":"moonshot","lane":"pi-moonshot-1","account":"none","fitTier":3,"reasoningClass":"strong","catalogSupported":true,"authState":null,"spendPriority":null,"runwaySeconds":null,"activeLane":0,"historySuccesses":0,"historyAttempts":0,"costTier":null}]'
  select_json | jq -e '
    .selected.profile == "pi-kimi"
    and (.uncertainty | index("pi-kimi:auth,quota,runway,cost"))
    and .selected.authState == null
    and .selected.spendPriority == null
    and .selected.runwaySeconds == null
    and .selected.costTier == null
  ' >/dev/null || fail "unknown evidence was treated as zero or omitted"
  pass "null auth, quota, runway, and cost stay eligible and disclosed"
}

test_worker_budget_is_bounded() {
  local row out task_class independent requested expected
  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null)]"
  for row in \
    'trivial false 4 1' \
    'standard false 3 1' \
    'decomposable true 7 4' \
    'decomposable true 2 2' \
    'decomposable false 4 1' \
    'ambiguous true 5 2' \
    'high_risk true 8 2'; do
    read -r task_class independent requested expected <<<"$row"
    write_request "$task_class" implementation medium "$independent" "$requested" strong 3600
    out=$(select_json) || fail "worker budget case failed: $row"
    [ "$(jq -r '.maxWorkers' <<<"$out")" = "$expected" ] || fail "worker budget case $row returned $(jq -r '.maxWorkers' <<<"$out")"
  done
  pass "task worker budgets honor class, independence, request, and hard cap"
}

test_every_decision_has_the_complete_output_shape() {
  local out
  write_request standard implementation medium false 1 maximum 3600
  write_candidates "[$(candidate weak lane-1 3 1 0 0 0 null)]"
  out=$(select_json) || fail "no-qualified decision failed"
  jq -e '
    keys == ["action","maxWorkers","ranked","reason","rejected","selected","uncertainty"]
    and .action == "escalate"
    and .reason == "no-qualified-profile"
    and .selected == null
    and (.ranked | type) == "array"
    and (.rejected | type) == "array"
    and (.uncertainty | type) == "array"
    and .maxWorkers == 1
  ' <<<"$out" >/dev/null || fail "escalation omitted required output fields"
  pass "selected and escalated decisions share one complete output schema"
}

test_rejections_account_for_every_ineligible_candidate() {
  local catalog auth reasoning runway out
  write_request standard implementation medium false 1 strong 5000
  catalog=$(candidate catalog lane-a 3 1 0 0 0 null | jq '.catalogSupported=false')
  auth=$(candidate auth lane-b 3 1 0 0 0 null | jq '.authState="unusable"')
  reasoning=$(candidate reasoning lane-c 3 1 0 0 0 null | jq '.reasoningClass="standard"')
  runway=$(candidate runway lane-d 3 1 0 0 0 null | jq '.runwaySeconds=4999')
  write_candidate_array "$catalog" "$auth" "$reasoning" "$runway"
  out=$(select_json) || fail "rejection accounting decision failed"
  jq -e '
    .action == "escalate"
    and (.rejected | length) == 4
    and (.rejected[] | select(.profile == "catalog") | .reasons == ["catalog-unsupported"])
    and (.rejected[] | select(.profile == "auth") | .reasons == ["auth-unusable"])
    and (.rejected[] | select(.profile == "reasoning") | .reasons == ["reasoning-insufficient"])
    and (.rejected[] | select(.profile == "runway") | .reasons == ["runway-insufficient"])
  ' <<<"$out" >/dev/null || fail "ineligible candidates were not fully accounted for"
  pass "rejected candidates carry explicit eligibility reasons"
}

test_load_precedes_history() {
  write_request standard implementation medium false 1 strong 3600
  write_candidate_array \
    "$(candidate idle lane-idle 3 1 50 0 0 null)" \
    "$(candidate busy lane-busy 3 1 0 100 100 null)"
  mkdir -p "$FM_STATE_OVERRIDE/routing/reservations"
  jq -n '{taskId:"other",generation:"gen-other",profile:"profile-other",provider:"provider",lane:"lane-busy",account:"none",taskClass:"standard",workType:"implementation",risk:"medium",mode:"automatic",burst:false,createdAt:1000,score:null}' \
    >"$FM_STATE_OVERRIDE/routing/reservations/other.json"
  select_json | jq -e '.selected.profile == "idle" and .selected.activeLane == 0' >/dev/null \
    || fail "current lane load did not precede caller history"
  pass "selector overwrites caller load and applies it before history"
}

test_history_is_read_from_state_only_for_equal_attempts() {
  local out
  rm -rf "$FM_STATE_OVERRIDE/routing"
  mkdir -p "$FM_STATE_OVERRIDE/routing"
  write_request standard implementation medium false 1 strong 3600
  write_candidate_array \
    "$(candidate proven lane-a 3 1 88 0 99 null)" \
    "$(candidate weak lane-b 3 1 88 99 99 null)"
  printf '%s\n' \
    "$(terminal_outcome proven proven-1 completed)" \
    "$(terminal_outcome proven proven-2 completed)" \
    "$(terminal_outcome weak weak-1 completed)" \
    "$(terminal_outcome weak weak-2 failed_safe)" \
    >"$FM_STATE_OVERRIDE/routing/outcomes.jsonl"
  out=$(select_json) || fail "history-backed selection failed"
  jq -e '.selected.profile == "proven" and .selected.historySuccesses == 2 and .selected.historyAttempts == 2' <<<"$out" >/dev/null \
    || fail "caller history was not replaced with equal-attempt routing history"

  terminal_outcome weak weak-3 failed_safe >>"$FM_STATE_OVERRIDE/routing/outcomes.jsonl"
  out=$(select_json) || fail "unequal-attempt decision failed"
  jq -e '.action == "escalate" and .reason == "evidence-tie" and .selected == null' <<<"$out" >/dev/null \
    || fail "raw successes were compared across unequal attempt counts"
  pass "raw history breaks ties only when attempt counts are equal"
}

test_cost_breaks_ties_only_when_every_cost_is_known() {
  local out
  rm -rf "$FM_STATE_OVERRIDE/routing"
  write_request standard implementation medium false 1 strong 3600
  write_candidate_array \
    "$(candidate unknown lane-a 3 1 0 0 0 null)" \
    "$(candidate known lane-b 3 1 0 0 0 1)"
  out=$(select_json) || fail "unknown-cost decision failed"
  jq -e '.action == "escalate" and .reason == "evidence-tie"' <<<"$out" >/dev/null \
    || fail "known cost was used when another finalist cost was unknown"

  write_candidate_array \
    "$(candidate expensive lane-a 3 1 0 0 0 3)" \
    "$(candidate cheap lane-b 3 1 0 0 0 1)"
  out=$(select_json) || fail "known-cost decision failed"
  jq -e '.selected.profile == "cheap"' <<<"$out" >/dev/null || fail "lower known cost did not break the final tie"
  pass "cost is a tie-break only when every finalist cost is known"
}

test_request_schema_is_strict() {
  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null)]"
  write_request standard implementation medium false 1 strong 3600
  jq 'del(.risk)' "$REQUEST" >"$REQUEST.next" && mv "$REQUEST.next" "$REQUEST"
  expect_failure_contains 'invalid request schema: missing risk' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"

  write_request standard implementation medium false 1 strong 3600
  jq '.unexpected=true' "$REQUEST" >"$REQUEST.next" && mv "$REQUEST.next" "$REQUEST"
  expect_failure_contains 'invalid request schema: unexpected field unexpected' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"

  write_request standard implementation medium false 0 strong 3600
  expect_failure_contains 'invalid request schema: requestedWorkers' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"

  write_request standard implementation medium false 9 strong 3600
  expect_failure_contains 'invalid request schema: requestedWorkers' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"
  pass "request validation requires exactly the typed routing contract"
}

test_candidate_schema_is_strict() {
  write_request standard implementation medium false 1 strong 3600
  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null | jq 'del(.provider)')]"
  expect_failure_contains 'invalid candidate schema: at index 0: missing provider' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"

  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null | jq '.prompt="secret"')]"
  expect_failure_contains 'invalid candidate schema: at index 0: unexpected field prompt' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"

  write_candidates "[$(candidate only lane-1 3 1 0 2 1 null)]"
  expect_failure_contains 'invalid candidate schema: at index 0: historySuccesses' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"

  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null | jq '.harness="opencode"')]"
  expect_failure_contains 'invalid candidate schema: at index 0: harness' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"

  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null | jq '.account="pi-secret-lane"')]"
  expect_failure_contains 'invalid candidate schema: at index 0: account' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"

  write_candidate_array \
    "$(candidate duplicate lane-1 3 1 0 0 0 null)" \
    "$(candidate duplicate lane-2 3 1 0 0 0 null)"
  expect_failure_contains 'invalid candidate schema: duplicate profile duplicate' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"
  pass "candidate validation requires exactly the typed routing contract"
}

test_input_and_now_validation_are_sanitized() {
  write_request standard implementation medium false 1 strong 3600
  printf '{bad json\n' >"$CANDIDATES"
  expect_failure_contains 'invalid candidates JSON' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"
  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null)]"
  expect_failure_contains 'invalid --now: expected non-negative epoch' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES" --now tomorrow
  pass "malformed input reports stable diagnostics without raw jq output"
}

reset_route_state() {
  rm -rf "$FM_STATE_OVERRIDE/routing"
}

reservation_path() {
  printf '%s/routing/reservations/%s/%s.json\n' "$FM_STATE_OVERRIDE" "$1" "$2"
}

claim_path() {
  printf '%s/routing/claims/%s/%s.cap\n' "$FM_STATE_OVERRIDE" "$1" "$2"
}

cleanup_ready() {
  local task=$1 generation=$2 work_type=${3:-implementation}
  "$ROUTE" cleanup-ready --task "$task" --generation "$generation" \
    --profile profile-1 --provider openai --lane codex-primary \
    --account codex-primary --class standard --work-type "$work_type" --risk medium --mode automatic
}

cleanup_finalize() {
  local task=$1 generation=$2 terminal=${3:-completed} work_type=${4:-implementation}
  "$ROUTE" cleanup-finalize --task "$task" --generation "$generation" \
    --profile profile-1 --provider openai --lane codex-primary \
    --account codex-primary --class standard --work-type "$work_type" --risk medium --mode automatic \
    --terminal "$terminal"
}

begin_fresh_admission() {
  local task=$1 generation=$2 metadata=$3 work_type=${4:-implementation}
  "$ROUTE" begin-admission --task "$task" --generation "$generation" \
    --profile profile-1 --provider openai --lane codex-primary \
    --account codex-primary --class standard --work-type "$work_type" --risk medium --mode automatic \
    --launch-harness codex --launch-model model-profile-1 --launch-effort none \
    --transition fresh --metadata-file "$metadata" \
    --claim-file "$(claim_path "$task" "$generation")"
}

write_route_metadata() {
  local file=$1 generation=$2 profile=${3:-profile-1} lane=${4:-codex-primary} account=${5:-codex-primary} work_type=${6:-implementation}
  {
    printf 'task=task-1\n'
    printf 'harness=codex\n'
    printf 'model=model-%s\n' "$profile"
    printf 'effort=default\n'
    printf 'route_generation=%s\n' "$generation"
    printf 'route_profile=%s\n' "$profile"
    printf 'route_provider=openai\n'
    printf 'route_lane=%s\n' "$lane"
    printf 'route_account=%s\n' "$account"
    printf 'route_class=standard\n'
    printf 'route_work_type=%s\n' "$work_type"
    printf 'route_risk=medium\n'
    printf 'route_mode=automatic\n'
  } >"$file"
}

activate_fresh_admission() {
  local task=$1 generation=$2 metadata=$3 work_type=${4:-implementation} candidate capability
  candidate="$metadata.candidate"
  capability=$(claim_path "$task" "$generation")
  begin_fresh_admission "$task" "$generation" "$metadata" "$work_type" >/dev/null
  write_route_metadata "$candidate" "$generation" profile-1 codex-primary codex-primary "$work_type"
  "$ROUTE" prepare-admission --task "$task" --candidate "$candidate" --claim-file "$capability" >/dev/null
  mv "$candidate" "$metadata"
  "$ROUTE" commit-admission --task "$task" --claim-file "$capability" >/dev/null
}

begin_inherited_admission() {
  local task=$1 generation=$2 metadata=$3 work_type=${4:-implementation}
  "$ROUTE" begin-admission --task "$task" --generation "$generation" \
    --profile profile-1 --provider openai --lane codex-primary \
    --account codex-primary --class standard --work-type "$work_type" --risk medium --mode automatic \
    --launch-harness codex --launch-model model-profile-1 --launch-effort none \
    --transition inherit --metadata-file "$metadata" \
    --claim-file "$(claim_path "$task" "$generation")"
}

begin_off_admission() {
  local task=$1 generation=$2 metadata=$3 profile=${4:-profile-1} lane=${5:-codex-primary} account=${6:-codex-primary} work_type=${7:-implementation}
  "$ROUTE" begin-admission --task "$task" --generation "$generation" \
    --profile "$profile" --provider openai --lane "$lane" \
    --account "$account" --class standard --work-type "$work_type" --risk medium --mode automatic \
    --transition off --metadata-file "$metadata" \
    --claim-file "$(claim_path "$task" "$generation")"
}

begin_replacement_admission() {
  local task=$1 generation=$2 prior_generation=$3 metadata=$4 work_type=${5:-implementation}
  "$ROUTE" begin-admission --task "$task" --generation "$generation" \
    --profile profile-2 --provider openai --lane codex-secondary \
    --account codex-secondary --class standard --work-type "$work_type" --risk medium --mode automatic \
    --launch-harness codex --launch-model model-profile-2 --launch-effort none \
    --transition replacement --prior-generation "$prior_generation" \
    --metadata-file "$metadata" --claim-file "$(claim_path "$task" "$generation")" \
    --prior-claim-file "$(claim_path "$task" "$prior_generation")"
}

age_admission() {
  local task=$1 generation=${2:-} now old journal reservation temporary
  now=$(date +%s)
  old=$((now - 301))
  journal="$FM_STATE_OVERRIDE/routing/admissions/$task.json"
  temporary="$journal.tmp"
  jq --argjson old "$old" '.createdAt=$old' "$journal" >"$temporary"
  mv "$temporary" "$journal"
  if [ -n "$generation" ]; then
    reservation=$(reservation_path "$task" "$generation")
    if [ -s "$reservation" ] && [ "$(jq -r '.admissionState // "reserved"' "$reservation")" = claimed ]; then
      temporary="$reservation.tmp"
      jq --argjson old "$old" '.claimedAt=$old' "$reservation" >"$temporary"
      mv "$temporary" "$reservation"
    fi
  fi
}

reserve_route() {
  local task=$1 generation=$2 profile=$3 provider=$4 lane=$5 account=$6 class=$7 risk=$8 mode=$9
  local work_type=${WORK_TYPE_OVERRIDE:-implementation} harness=pi now=${RESERVE_NOW_OVERRIDE:-1000}
  shift 9
  [ "$account" = none ] || harness=codex
  fm_test_reserve_bound "$ROOT" "$LAB" "$FM_STATE_OVERRIDE" "$task" "$generation" "$profile" \
    "$provider" "$lane" "$account" "$class" "$work_type" "$risk" "$mode" "$harness" \
    "model-$profile" none "$now" "$@"
}

test_reserve_requires_a_bounded_work_type() {
  reset_route_state
  expect_failure_contains 'work-type is required' "$ROUTE" reserve --task task-1 --generation gen-1 --profile profile-1 --provider openai --lane codex-primary --account codex-primary --class standard --risk low --mode automatic --now 1000
  expect_failure_contains 'invalid work type' "$ROUTE" reserve --task task-1 --generation gen-1 --profile profile-1 --provider openai --lane codex-primary --account codex-primary --class standard --work-type 'implementation notes' --risk low --mode automatic --now 1000
  write_request standard 'implementation notes' low false 1 strong 60
  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null)]"
  expect_failure_contains 'invalid request schema: workType' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"
  pass "reservations and requests share one bounded work-type contract"
}

test_reserve_is_bound_to_authoritative_policy_and_selection_evidence() {
  local before
  reset_route_state
  seed_v2_policy automatic
  write_request standard implementation low false 1 strong 60
  write_candidates "[$(candidate pi-test lane-1 3 1 0 0 0 null | jq -c '.model="model-only"')]"
  select_json >"$LAB/decision.json" || fail "could not capture authoritative decision"

  before=$(find "$FM_STATE_OVERRIDE" -type f 2>/dev/null | sort)
  expect_failure_contains 'selection evidence is required' "$ROUTE" reserve \
    --task task-1 --generation gen-1 --profile pi-test --provider provider \
    --lane lane-1 --account none --class standard --work-type implementation \
    --risk low --mode automatic --now 1000
  [ "$(find "$FM_STATE_OVERRIDE" -type f 2>/dev/null | sort)" = "$before" ] \
    || fail "evidence-free reserve mutated routing state"

  jq '.selected.profile="attacker"' "$LAB/decision.json" >"$LAB/tampered-decision.json"
  expect_failure_contains 'selection-decision-mismatch' "$ROUTE" reserve \
    --task task-1 --generation gen-1 --profile pi-test --provider provider \
    --lane lane-1 --account none --class standard --work-type implementation \
    --risk low --mode automatic --request "$REQUEST" --candidates "$CANDIDATES" \
    --decision "$LAB/tampered-decision.json" --now 1000
  [ ! -e "$FM_STATE_OVERRIDE/routing/reservations/task-1/gen-1.json" ] \
    || fail "tampered decision created a reservation"

  "$ROUTE" reserve --task task-1 --generation gen-1 --profile pi-test \
    --provider provider --lane lane-1 --account none --class standard \
    --work-type implementation --risk low --mode automatic --request "$REQUEST" \
    --candidates "$CANDIDATES" --decision "$LAB/decision.json" --now 1000 \
    | jq -e '.launchHarness == "pi" and .launchModel == "model-only" and .launchEffort == null and .bindingVersion == 1' >/dev/null \
    || fail "valid selection did not persist the policy-derived launch binding"

  for policy_mode in off simulate; do
    reset_route_state
    seed_v2_policy "$policy_mode"
    before=$(find "$FM_STATE_OVERRIDE" -type f 2>/dev/null | sort)
    expect_failure_contains "mode-does-not-reserve:$policy_mode" "$ROUTE" reserve \
      --task task-1 --generation gen-denied --profile pi-test --provider provider \
      --lane lane-1 --account none --class standard --work-type implementation \
      --risk low --mode "$policy_mode" --request "$REQUEST" --candidates "$CANDIDATES" \
      --decision "$LAB/decision.json" --now 1000
    [ "$(find "$FM_STATE_OVERRIDE" -type f 2>/dev/null | sort)" = "$before" ] \
      || fail "$policy_mode reserve refusal mutated routing state"
  done

  reset_route_state
  seed_v2_policy automatic
  expect_failure_contains 'selected route does not match active policy' "$ROUTE" reserve \
    --task task-1 --generation gen-fake --profile pi-test --provider attacker \
    --lane lane-1 --account none --class standard --work-type implementation \
    --risk low --mode automatic --request "$REQUEST" --candidates "$CANDIDATES" \
    --decision "$LAB/decision.json" --now 1000
  [ ! -e "$FM_STATE_OVERRIDE/routing/reservations/task-1/gen-fake.json" ] \
    || fail "caller-selected provider bypassed policy binding"
  expect_failure_contains 'selected route does not match active policy' "$ROUTE" reserve \
    --task task-1 --generation gen-fake-lane --profile pi-test --provider provider \
    --lane attacker --account none --class standard --work-type implementation \
    --risk low --mode automatic --request "$REQUEST" --candidates "$CANDIDATES" \
    --decision "$LAB/decision.json" --now 1000
  expect_failure_contains 'selected route does not match active policy' "$ROUTE" reserve \
    --task task-1 --generation gen-fake-account --profile pi-test --provider provider \
    --lane lane-1 --account attacker --class standard --work-type implementation \
    --risk low --mode automatic --request "$REQUEST" --candidates "$CANDIDATES" \
    --decision "$LAB/decision.json" --now 1000
  expect_failure_contains 'selected profile does not match reservation' "$ROUTE" reserve \
    --task task-1 --generation gen-unselected --profile pi-other --provider provider \
    --lane lane-2 --account none --class standard --work-type implementation \
    --risk low --mode automatic --request "$REQUEST" --candidates "$CANDIDATES" \
    --decision "$LAB/decision.json" --now 1000

  jq '.[0].harness="pi-signed"' "$CANDIDATES" >"$LAB/fake-harness-candidates.json"
  "$ROUTE" select --request "$REQUEST" --candidates "$LAB/fake-harness-candidates.json" --now 1000 >"$LAB/fake-harness-decision.json"
  expect_failure_contains 'selected route does not match active policy' "$ROUTE" reserve \
    --task task-1 --generation gen-fake-harness --profile pi-test --provider provider \
    --lane lane-1 --account none --class standard --work-type implementation --risk low \
    --mode automatic --request "$REQUEST" --candidates "$LAB/fake-harness-candidates.json" \
    --decision "$LAB/fake-harness-decision.json" --now 1000
  jq '.[0].model="attacker/model"' "$CANDIDATES" >"$LAB/fake-model-candidates.json"
  "$ROUTE" select --request "$REQUEST" --candidates "$LAB/fake-model-candidates.json" --now 1000 >"$LAB/fake-model-decision.json"
  expect_failure_contains 'selected route does not match active policy' "$ROUTE" reserve \
    --task task-1 --generation gen-fake-model --profile pi-test --provider provider \
    --lane lane-1 --account none --class standard --work-type implementation --risk low \
    --mode automatic --request "$REQUEST" --candidates "$LAB/fake-model-candidates.json" \
    --decision "$LAB/fake-model-decision.json" --now 1000

  jq '.profiles["pi-test"].model="default"' "$FM_CONFIG_OVERRIDE/crew-dispatch.json" >"$LAB/default-policy.json"
  mv "$LAB/default-policy.json" "$FM_CONFIG_OVERRIDE/crew-dispatch.json"
  jq '.[0].model="default"' "$CANDIDATES" >"$LAB/default-model-candidates.json"
  expect_failure_contains 'active dispatch policy is invalid' "$ROUTE" select \
    --request "$REQUEST" --candidates "$LAB/default-model-candidates.json" --now 1000

  seed_v2_policy automatic
  ln -s "$REQUEST" "$LAB/request-link.json"
  expect_failure_contains 'request file is unsafe or unreadable' "$ROUTE" reserve \
    --task task-1 --generation gen-symlink --profile pi-test --provider provider \
    --lane lane-1 --account none --class standard --work-type implementation --risk low \
    --mode automatic --request "$LAB/request-link.json" --candidates "$CANDIDATES" \
    --decision "$LAB/decision.json" --now 1000
  pass "reserve is bound to authoritative policy and selection evidence"
}

test_reserve_rejects_a_decision_staled_by_authoritative_load() {
  reset_route_state
  mkdir -p "$FM_CONFIG_OVERRIDE"
  jq -n '{schemaVersion:2,routing:{mode:"automatic"},profiles:{
    a:{harness:"pi",model:"model-a",provider:"provider",lane:"lane-a",reasoningClass:"strong",workTypes:["review"]},
    b:{harness:"pi",model:"model-b",provider:"provider",lane:"lane-b",reasoningClass:"strong",workTypes:["review"]}
  },default:["a","b"]}' >"$FM_CONFIG_OVERRIDE/crew-dispatch.json"
  jq -n '{taskId:"stale-task",taskClass:"standard",workType:"review",risk:"medium",independent:false,requestedWorkers:1,requiredReasoningClass:"strong",estimatedSeconds:60}' >"$LAB/stale-request.json"
  jq -n '[
    {profile:"a",harness:"pi",model:"model-a",provider:"provider",lane:"lane-a",account:"none",fitTier:3,reasoningClass:"strong",catalogSupported:true,authState:"usable",spendPriority:1,runwaySeconds:1000,activeLane:0,historySuccesses:0,historyAttempts:0,costTier:0},
    {profile:"b",harness:"pi",model:"model-b",provider:"provider",lane:"lane-b",account:"none",fitTier:3,reasoningClass:"strong",catalogSupported:true,authState:"usable",spendPriority:1,runwaySeconds:1000,activeLane:0,historySuccesses:0,historyAttempts:0,costTier:1}
  ]' >"$LAB/stale-candidates.json"
  "$ROUTE" select --request "$LAB/stale-request.json" --candidates "$LAB/stale-candidates.json" --now 1000 >"$LAB/stale-decision.json"
  jq -e '.selected.profile == "a"' "$LAB/stale-decision.json" >/dev/null || fail "stale-load fixture did not initially select a"
  mkdir -p "$FM_STATE_OVERRIDE/routing/reservations/occupant"
  jq -n '{taskId:"occupant",generation:"gen-old",profile:"legacy",provider:"provider",lane:"lane-a",account:"none",taskClass:"standard",workType:"review",risk:"medium",mode:"automatic",burst:false,createdAt:900,score:null,admissionState:"active",claimHash:("a"*64)}' \
    >"$FM_STATE_OVERRIDE/routing/reservations/occupant/gen-old.json"
  expect_failure_contains 'selection-decision-mismatch' "$ROUTE" reserve \
    --task stale-task --generation gen-new --profile a --provider provider --lane lane-a \
    --account none --class standard --work-type review --risk medium --mode automatic \
    --request "$LAB/stale-request.json" --candidates "$LAB/stale-candidates.json" \
    --decision "$LAB/stale-decision.json" --now 1000
  [ ! -e "$FM_STATE_OVERRIDE/routing/reservations/stale-task/gen-new.json" ] \
    || fail "stale load decision created a reservation"
  pass "reserve re-evaluates selection under lock and rejects stale load decisions"
}

test_legacy_unbound_reservations_are_cleanup_only() {
  local metadata="$FM_STATE_OVERRIDE/legacy.meta" reservation capability
  reset_route_state
  mkdir -p "$FM_STATE_OVERRIDE/routing/reservations/legacy"
  reservation="$FM_STATE_OVERRIDE/routing/reservations/legacy/gen-1.json"
  jq -n '{taskId:"legacy",generation:"gen-1",profile:"profile-1",provider:"openai",lane:"codex-primary",account:"codex-primary",taskClass:"standard",workType:"implementation",risk:"medium",mode:"automatic",burst:false,createdAt:1000,score:null,admissionState:"reserved"}' >"$reservation"
  expect_failure_contains 'reservation-binding-required' "$ROUTE" begin-admission \
    --task legacy --generation gen-1 --profile profile-1 --provider openai --lane codex-primary \
    --account codex-primary --class standard --work-type implementation --risk medium --mode automatic \
    --launch-harness codex --launch-model legacy-model --launch-effort none \
    --transition fresh --metadata-file "$metadata" --claim-file "$(claim_path legacy gen-1)"
  [ ! -e "$FM_STATE_OVERRIDE/routing/claims/legacy" ] \
    || fail "refused unbound reservation created a claim directory"
  jq -e '.admissionState == "reserved" and (has("bindingVersion") | not)' "$reservation" >/dev/null \
    || fail "refused legacy reservation was mutated"

  reset_route_state
  reserve_route legacy gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  activate_fresh_admission legacy gen-1 "$metadata" >/dev/null
  capability=$(claim_path legacy gen-1)
  jq 'del(.bindingVersion,.launchHarness,.launchModel,.launchEffort,.requestDigest,.candidatesDigest,.decisionDigest,.policyDigest)' "$reservation" >"$reservation.next"
  mv "$reservation.next" "$reservation"
  expect_failure_contains 'legacy active reservation cannot be relaunched without an authoritative binding' "$ROUTE" begin-admission --task legacy --generation gen-1 --profile profile-1 --provider openai \
    --lane codex-primary --account codex-primary --class standard --work-type implementation \
    --risk medium --mode automatic --launch-harness codex --launch-model ignored-legacy \
    --launch-effort none --transition inherit --metadata-file "$metadata" --claim-file "$capability"
  jq -e '.admissionState == "active" and (has("bindingVersion") | not)' "$reservation" >/dev/null \
    || fail "legacy inherited refusal mutated active capacity"
  [ ! -e "$FM_STATE_OVERRIDE/routing/admissions/legacy.json" ] \
    || fail "legacy inherited refusal published an admission journal"
  "$ROUTE" release --task legacy --generation gen-1 --claim-file "$capability" >/dev/null \
    || fail "legacy active reservation could not still converge through cleanup"
  reset_route_state
  rm -f "$metadata"
  reserve_route legacy gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  activate_fresh_admission legacy gen-1 "$metadata" >/dev/null
  capability=$(claim_path legacy gen-1)
  reservation=$(reservation_path legacy gen-1)
  jq 'del(.bindingVersion,.launchHarness,.launchModel,.launchEffort,.requestDigest,.candidatesDigest,.decisionDigest,.policyDigest)' "$reservation" >"$reservation.next"
  mv "$reservation.next" "$reservation"
  "$ROUTE" finalize --task legacy --generation gen-1 --terminal completed --claim-file "$capability" >/dev/null \
    || fail "legacy active reservation could not converge through finalize"
  [ ! -e "$reservation" ] || fail "legacy finalize retained reservation"

  reset_route_state
  rm -f "$metadata"
  reserve_route legacy gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  activate_fresh_admission legacy gen-1 "$metadata" >/dev/null
  reservation=$(reservation_path legacy gen-1)
  jq 'del(.bindingVersion,.launchHarness,.launchModel,.launchEffort,.requestDigest,.candidatesDigest,.decisionDigest,.policyDigest)' "$reservation" >"$reservation.next"
  mv "$reservation.next" "$reservation"
  cleanup_finalize legacy gen-1 completed implementation >/dev/null \
    || fail "legacy active reservation could not converge through cleanup-finalize"
  [ ! -e "$reservation" ] || fail "legacy cleanup-finalize retained reservation"
  pass "legacy unbound routes are cleanup-only and cannot choose arbitrary relaunch identity"
}

test_begin_admission_revalidates_the_active_policy_before_mutation() {
  local metadata="$FM_STATE_OVERRIDE/policy-race.meta" reservation capability before mode variant outside
  for variant in off changed deleted symlink; do
    reset_route_state
    reserve_route policy-race gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
    reservation=$(reservation_path policy-race gen-1)
    capability=$(claim_path policy-race gen-1)
    before=$(sha256sum "$reservation" | awk '{print $1}')
    case "$variant" in
      off) jq '.routing.mode="off"' "$FM_CONFIG_OVERRIDE/crew-dispatch.json" >"$LAB/policy.next"; mv "$LAB/policy.next" "$FM_CONFIG_OVERRIDE/crew-dispatch.json" ;;
      changed) jq '.profiles["profile-1"].model="changed-model"' "$FM_CONFIG_OVERRIDE/crew-dispatch.json" >"$LAB/policy.next"; mv "$LAB/policy.next" "$FM_CONFIG_OVERRIDE/crew-dispatch.json" ;;
      deleted) rm -f "$FM_CONFIG_OVERRIDE/crew-dispatch.json" ;;
      symlink) outside="$LAB/outside-policy.json"; cp "$FM_CONFIG_OVERRIDE/crew-dispatch.json" "$outside"; rm -f "$FM_CONFIG_OVERRIDE/crew-dispatch.json"; ln -s "$outside" "$FM_CONFIG_OVERRIDE/crew-dispatch.json" ;;
    esac
    expect_failure_contains 'active dispatch policy' "$ROUTE" begin-admission --task policy-race --generation gen-1 --profile profile-1 --provider openai \
      --lane codex-primary --account codex-primary --class standard --work-type implementation \
      --risk medium --mode automatic --launch-harness codex --launch-model model-profile-1 \
      --launch-effort none --transition fresh --metadata-file "$metadata" --claim-file "$capability"
    [ "$(sha256sum "$reservation" | awk '{print $1}')" = "$before" ] || fail "$variant policy race mutated reservation"
    [ ! -e "$capability" ] && [ ! -e "$FM_STATE_OVERRIDE/routing/admissions/policy-race.json" ] \
      && [ ! -e "$metadata" ] || fail "$variant policy race published an admission artifact"
  done
  rm -f "$FM_CONFIG_OVERRIDE/crew-dispatch.json"
  seed_v2_policy automatic
  pass "begin admission revalidates active policy before any route mutation"
}

test_bound_admission_rejects_published_launch_identity_tamper() {
  local metadata="$FM_STATE_OVERRIDE/task-1.meta" candidate capability rc
  reset_route_state
  reserve_route task-1 gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  begin_fresh_admission task-1 gen-1 "$metadata" >/dev/null
  capability=$(claim_path task-1 gen-1)
  candidate="$metadata.candidate"
  write_route_metadata "$candidate" gen-1
  sed 's/^model=model-profile-1$/model=attacker-model/' "$candidate" >"$candidate.tampered"
  mv "$candidate.tampered" "$candidate"
  set +e
  "$ROUTE" prepare-admission --task task-1 --candidate "$candidate" --claim-file "$capability" \
    >"$LAB/tampered-admission.out" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "tampered admission candidate unexpectedly prepared"
  assert_grep 'admission candidate launch mismatch' "$LAB/tampered-admission.out" \
    "tampered admission candidate was not diagnosed"
  [ ! -e "$metadata" ] || fail "tampered launch identity published metadata"
  "$ROUTE" abort-admission --task task-1 --claim-file "$capability" >/dev/null \
    || fail "tampered admission did not roll back"
  pass "admission binds published harness, model, and effort to the reservation"
}

test_canary_cap_is_atomic_and_duplicate_reserve_is_idempotent() {
  local job rc successes=0
  reset_route_state
  mkdir -p "$FM_CONFIG_OVERRIDE"
  jq -n '{schemaVersion:2,routing:{mode:"canary"},profiles:([range(1;5) as $n | {
    key:("profile-"+($n|tostring)),value:{harness:"pi",model:("model-profile-"+($n|tostring)),
    provider:("provider-"+($n|tostring)),lane:("lane-"+($n|tostring)),reasoningClass:"strong",workTypes:["implementation"]}
  }] | from_entries),default:["profile-1","profile-2","profile-3","profile-4"]}' >"$FM_CONFIG_OVERRIDE/crew-dispatch.json"
  for job in 1 2 3 4; do
    reserve_route "task-$job" "gen-$job" "profile-$job" "provider-$job" "lane-$job" none decomposable low canary >"$LAB/reserve-$job.out" 2>&1 &
    eval "pid_$job=$!"
  done
  for job in 1 2 3 4; do
    set +e
    eval "wait \$pid_$job"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || successes=$((successes + 1))
  done
  [ "$successes" -eq 3 ] || fail "atomic canary cap admitted $successes workers"
  [ "$(find "$FM_STATE_OVERRIDE/routing/reservations" -type f -name '*.json' | wc -l)" -eq 3 ] || fail "canary cap persisted the wrong active total"

  reset_route_state
  reserve_route task-1 gen-1 profile-1 provider-1 lane-1 none standard low automatic >/dev/null || fail "initial reservation failed"
  reserve_route task-1 gen-1 profile-1 provider-1 lane-1 none standard low automatic >/dev/null || fail "duplicate reservation was not idempotent"
  [ "$(find "$FM_STATE_OVERRIDE/routing/reservations" -type f -name '*.json' | wc -l)" -eq 1 ] || fail "duplicate reservation changed capacity"
  expect_failure_contains 'reservation-conflict' reserve_route task-1 gen-2 profile-1 provider-1 lane-1 none standard low automatic
  pass "canary admission is atomic and route generations are idempotent"
}

test_lane_account_and_burst_caps_are_enforced() {
  reset_route_state
  reserve_route task-1 gen-1 profile-1 xai pi-xai-1 none standard low automatic >/dev/null
  reserve_route task-2 gen-2 profile-2 xai pi-xai-1 none standard low automatic >/dev/null
  expect_failure_contains 'lane-cap:2' reserve_route task-3 gen-3 profile-3 xai pi-xai-1 none standard low automatic

  reset_route_state
  reserve_route task-1 gen-1 profile-1 openai codex-lane-1 codex-primary standard low automatic >/dev/null
  reserve_route task-2 gen-2 profile-2 openai codex-lane-2 codex-primary standard low automatic >/dev/null
  expect_failure_contains 'account-cap:2' reserve_route task-3 gen-3 profile-3 openai codex-lane-3 codex-primary standard low automatic

  reset_route_state
  for job in 1 2 3 4 5 6; do
    reserve_route "task-$job" "gen-$job" "profile-$job" "provider-$job" "lane-$job" none decomposable low automatic >/dev/null
  done
  expect_failure_contains 'global-cap:6' reserve_route task-7 gen-7 profile-7 provider-7 lane-7 none decomposable low automatic
  reserve_route task-7 gen-7 profile-7 provider-7 lane-7 none decomposable low automatic --burst >/dev/null || fail "qualified burst did not extend the automatic cap"
  expect_failure_contains 'burst-requires-decomposable-low-risk' reserve_route task-8 gen-8 profile-8 provider-8 lane-8 none standard low automatic --burst
  pass "lane, account, automatic, and burst caps are bounded"
}

test_reservation_verification_and_generation_release_are_exact() {
  reset_route_state
  reserve_route task-1 gen-1 profile-1 openai codex-primary codex-primary high_risk high automatic >/dev/null
  "$ROUTE" verify-reservation --task task-1 --generation gen-1 --profile profile-1 --provider openai --lane codex-primary --account codex-primary --class high_risk --work-type implementation --risk high --mode automatic >/dev/null \
    || fail "exact reservation did not verify"
  [ "$("$ROUTE" reservation-work-type --task task-1 --generation gen-1 \
    --profile profile-1 --provider openai --lane codex-primary \
    --account codex-primary --class high_risk --risk high --mode automatic)" = implementation ] \
    || fail "legacy metadata compatibility did not resolve authoritative work type"
  expect_failure_contains 'reservation-mismatch' "$ROUTE" reservation-work-type \
    --task task-1 --generation gen-1 --profile wrong --provider openai \
    --lane codex-primary --account codex-primary --class high_risk --risk high --mode automatic
  expect_failure_contains 'reservation-mismatch' "$ROUTE" verify-reservation --task task-1 --generation gen-1 --profile wrong --provider openai --lane codex-primary --account codex-primary --class high_risk --work-type implementation --risk high --mode automatic
  expect_failure_contains 'reservation-generation-mismatch' "$ROUTE" release --task task-1 --generation wrong
  [ -f "$(reservation_path task-1 gen-1)" ] || fail "wrong generation released a live reservation"
  "$ROUTE" release --task task-1 --generation gen-1 >/dev/null || fail "reservation release failed"
  "$ROUTE" release --task task-1 --generation gen-1 >/dev/null || fail "duplicate release was not idempotent"
  pass "reservation verification and release bind the complete route generation"
}

test_reservation_claim_blocks_concurrent_lifecycle_until_activation() {
  local release_pid finalize_pid release_rc finalize_rc capability metadata="$FM_STATE_OVERRIDE/task-1.meta"
  reset_route_state
  reserve_route task-1 gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  begin_fresh_admission task-1 gen-1 "$metadata" >/dev/null
  capability=$(claim_path task-1 gen-1)

  "$ROUTE" release --task task-1 --generation gen-1 >"$LAB/claimed-release.out" 2>&1 &
  release_pid=$!
  "$ROUTE" finalize --task task-1 --generation gen-1 --terminal cancelled \
    --claim-file "$capability" >"$LAB/claimed-finalize.out" 2>&1 &
  finalize_pid=$!
  set +e
  wait "$release_pid"; release_rc=$?
  wait "$finalize_pid"; finalize_rc=$?
  [ "$release_rc" -ne 0 ] \
    || fail "ordinary release unexpectedly removed a pending admission claim"
  assert_grep 'reservation-claim-required' "$LAB/claimed-release.out" \
    "ordinary release did not respect pending admission ownership"
  [ "$finalize_rc" -ne 0 ] \
    || fail "ordinary finalize unexpectedly consumed a pending admission claim"
  assert_grep 'admission recovery required' "$LAB/claimed-finalize.out" \
    "ordinary finalize did not respect pending admission ownership"
  assert_present "$(reservation_path task-1 gen-1)" \
    "concurrent lifecycle command stole claimed capacity"
  "$ROUTE" abort-admission --task task-1 --claim-file "$capability" >/dev/null \
    || fail "owned admission could not roll back after concurrent lifecycle refusal"
  assert_absent "$(reservation_path task-1 gen-1)" "admission rollback leaked claimed capacity"
  pass "claimed reservations block concurrent release and finalization until convergence"
}

test_claim_release_is_exact_and_stale_claims_are_recoverable() {
  local capability backup metadata="$FM_STATE_OVERRIDE/task-1.meta" rc
  reset_route_state
  reserve_route task-1 gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  begin_fresh_admission task-1 gen-1 "$metadata" >/dev/null
  capability=$(claim_path task-1 gen-1)
  backup="$LAB/task-1.cap"
  cp "$capability" "$backup"
  printf '%s\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb >"$capability"
  set +e
  "$ROUTE" abort-admission --task task-1 --claim-file "$capability" >"$LAB/wrong-cap.out" 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "wrong capability unexpectedly rolled back admission"
  assert_grep 'admission capability mismatch' "$LAB/wrong-cap.out" \
    "wrong capability was not diagnosed"
  assert_present "$(reservation_path task-1 gen-1)" "wrong capability changed claimed capacity"
  cp "$backup" "$capability"
  chmod 644 "$capability"
  set +e
  "$ROUTE" abort-admission --task task-1 --claim-file "$capability" >"$LAB/wrong-mode.out" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "wrong capability mode unexpectedly rolled back admission"
  assert_grep 'invalid claim file' "$LAB/wrong-mode.out" "wrong capability mode was not diagnosed"
  assert_present "$(reservation_path task-1 gen-1)" "wrong capability mode changed claimed capacity"
  cp "$backup" "$capability"
  chmod 600 "$capability"
  "$ROUTE" abort-admission --task task-1 --claim-file "$capability" >/dev/null \
    || fail "exact capability could not roll back its admission"
  pass "admission rollback requires the exact protected capability"
}

test_spawn_claim_requires_the_authoritative_reservation_work_type() {
  local metadata="$FM_STATE_OVERRIDE/task-1.meta" outcome
  reset_route_state
  WORK_TYPE_OVERRIDE=review \
    reserve_route task-1 gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  expect_failure_contains 'reservation-mismatch' \
    begin_fresh_admission task-1 gen-1 "$metadata" implementation
  expect_failure_contains 'reservation-mismatch' "$ROUTE" verify-reservation \
    --task task-1 --generation gen-1 --profile profile-1 --provider openai \
    --lane codex-primary --account codex-primary --class standard \
    --work-type implementation --risk medium --mode automatic --now 1000
  "$ROUTE" verify-reservation --task task-1 --generation gen-1 \
    --profile profile-1 --provider openai --lane codex-primary \
    --account codex-primary --class standard --work-type review --risk medium \
    --mode automatic --now 1000 >/dev/null \
    || fail "review reservation could not be verified with its authoritative work type"
  activate_fresh_admission task-1 gen-1 "$metadata" review
  jq -e '.workType == "review" and .admissionState == "active"' \
    "$(reservation_path task-1 gen-1)" >/dev/null \
    || fail "review admission did not preserve work type"
  cleanup_ready task-1 gen-1 review >/dev/null
  outcome=$(cleanup_finalize task-1 gen-1 completed review)
  jq -e '.workType == "review" and .terminal == "completed"' <<<"$outcome" >/dev/null \
    || fail "review finalization did not preserve work type"
  [ "$("$ROUTE" reservation-work-type --task task-1 --generation gen-1 \
    --profile profile-1 --provider openai --lane codex-primary \
    --account codex-primary --class standard --risk medium --mode automatic)" = review ] \
    || fail "finalized legacy compatibility did not resolve work type from terminal outcome"
  pass "routed lifecycle validates and preserves the authoritative work type"
}

test_active_generation_can_hold_one_distinct_pending_replacement() {
  local metadata="$FM_STATE_OVERRIDE/task-1.meta"
  reset_route_state
  reserve_route task-1 gen-old profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  activate_fresh_admission task-1 gen-old "$metadata"

  reserve_route task-1 gen-new profile-2 openai codex-secondary codex-secondary standard medium automatic >/dev/null \
    || fail "active generation prevented one distinct pending replacement"
  [ -s "$FM_STATE_OVERRIDE/routing/reservations/task-1/gen-old.json" ] \
    || fail "active generation was not retained in generation-scoped storage"
  [ -s "$FM_STATE_OVERRIDE/routing/reservations/task-1/gen-new.json" ] \
    || fail "pending replacement was not written beside the active generation"
  expect_failure_contains 'reservation-conflict' \
    reserve_route task-1 gen-third profile-3 openai codex-third codex-third standard medium automatic
  pass "one active generation can coexist with one pending replacement"
}

test_fresh_admission_uses_only_a_protected_capability_file() {
  local output capability reservation metadata="$FM_STATE_OVERRIDE/task-1.meta" outside="$LAB/outside-claims"
  reset_route_state
  reserve_route task-1 gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  capability=$(claim_path task-1 gen-1)
  reservation=$(reservation_path task-1 gen-1)

  output=$(begin_fresh_admission task-1 gen-1 "$metadata") \
    || fail "fresh capability-file admission failed"
  [ -f "$capability" ] && [ ! -L "$capability" ] \
    || fail "fresh admission did not create a regular capability file"
  [ "$(stat -c '%a' "$capability" 2>/dev/null || stat -f '%Lp' "$capability")" = 600 ] \
    || fail "fresh admission capability was not mode 0600"
  [ "$(wc -c <"$capability" | tr -d ' ')" -eq 65 ] \
    || fail "fresh admission capability did not contain one bounded token"
  ! grep -Fq "$(tr -d '\n' <"$capability")" <<<"$output" \
    || fail "fresh admission exposed its capability in output"
  jq -e '.admissionState == "claimed" and (.ownerPid | type) == "number" and (.ownerStart | test("^[a-f0-9]{64}$")) and .claimPriorState == "reserved"' "$reservation" >/dev/null \
    || fail "fresh admission did not persist bounded owner identity"

  reset_route_state
  mkdir -p "$outside" "$FM_STATE_OVERRIDE/routing"
  ln -s "$outside" "$FM_STATE_OVERRIDE/routing/claims"
  reserve_route symlinked gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  expect_failure_contains 'invalid routing state' \
    begin_fresh_admission symlinked gen-1 "$FM_STATE_OVERRIDE/symlinked.meta"
  [ -z "$(find "$outside" -mindepth 1 -print -quit)" ] \
    || fail "claim-directory symlink caused an external filesystem side effect"
  pass "fresh admission keeps its capability in one protected file"
}

test_raw_claim_and_unauthenticated_active_reclaim_flags_are_removed() {
  local raw=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  reset_route_state
  reserve_route task-2 gen-2 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  expect_failure_contains 'usage:' "$ROUTE" claim-reservation --task task-2 --generation gen-2 \
    --profile profile-1 --provider openai --lane codex-primary --account codex-primary \
    --class standard --risk medium --mode automatic --claim "$raw" --now 1001
  expect_failure_contains 'usage:' "$ROUTE" release --task task-2 --generation gen-2 --stale-before 1000
  pass "raw claim, from-active, and caller-selected staleness are not public interfaces"
}

test_fresh_admission_journal_commits_only_the_published_metadata() {
  local metadata="$FM_STATE_OVERRIDE/task-1.meta" capability reservation
  reset_route_state
  reserve_route task-1 gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  capability=$(claim_path task-1 gen-1)
  reservation=$(reservation_path task-1 gen-1)
  activate_fresh_admission task-1 gen-1 "$metadata" \
    || fail "fresh admission journal did not commit published metadata"
  jq -e '.admissionState == "active" and has("claimHash") and (has("ownerPid") | not) and (has("claimedAt") | not)' "$reservation" >/dev/null \
    || fail "fresh admission did not converge to the exact active schema"
  assert_absent "$FM_STATE_OVERRIDE/routing/admissions/task-1.json" \
    "fresh admission left its completed journal behind"
  assert_present "$capability" "active admission did not retain its capability"
  pass "fresh admission journal activates only after exact metadata publication"
}

test_relaunch_abort_restores_or_preserves_only_the_owned_generations() {
  local metadata="$FM_STATE_OVERRIDE/task-1.meta" old_cap new_cap old_res new_res
  reset_route_state
  rm -f "$metadata"
  reserve_route task-1 gen-old profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  activate_fresh_admission task-1 gen-old "$metadata"
  old_cap=$(claim_path task-1 gen-old)
  old_res=$(reservation_path task-1 gen-old)

  begin_inherited_admission task-1 gen-old "$metadata" >/dev/null
  "$ROUTE" abort-admission --task task-1 --claim-file "$old_cap" >/dev/null \
    || fail "inherited prepublication abort did not restore the active route"
  jq -e '.admissionState == "active"' "$old_res" >/dev/null \
    || fail "inherited abort deleted or left claimed the old active route"

  begin_off_admission task-1 gen-old "$metadata" >/dev/null
  "$ROUTE" abort-admission --task task-1 --claim-file "$old_cap" >/dev/null \
    || fail "explicit-off prepublication abort did not preserve the old active route"
  jq -e '.admissionState == "active"' "$old_res" >/dev/null \
    || fail "explicit-off abort changed the old active route"

  reserve_route task-1 gen-new profile-2 openai codex-secondary codex-secondary standard medium automatic >/dev/null
  new_cap=$(claim_path task-1 gen-new)
  new_res=$(reservation_path task-1 gen-new)
  begin_replacement_admission task-1 gen-new gen-old "$metadata" >/dev/null
  "$ROUTE" abort-admission --task task-1 --claim-file "$new_cap" --prior-claim-file "$old_cap" >/dev/null \
    || fail "replacement prepublication abort failed"
  jq -e '.admissionState == "active"' "$old_res" >/dev/null \
    || fail "replacement abort changed the old active route"
  assert_absent "$new_res" "replacement abort leaked the new reservation"
  assert_absent "$new_cap" "replacement abort leaked the new capability"
  pass "relaunch abort preserves old active capacity and removes only a new claim"
}

test_relaunch_commit_retires_old_capacity_only_after_publication() {
  local metadata="$FM_STATE_OVERRIDE/task-1.meta" candidate old_cap new_cap old_res new_res
  reset_route_state
  rm -f "$metadata"
  reserve_route task-1 gen-old profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  activate_fresh_admission task-1 gen-old "$metadata"
  old_cap=$(claim_path task-1 gen-old)
  old_res=$(reservation_path task-1 gen-old)

  begin_inherited_admission task-1 gen-old "$metadata" >/dev/null
  candidate="$metadata.inherit"
  write_route_metadata "$candidate" gen-old
  printf 'launch_nonce=inherited\n' >>"$candidate"
  "$ROUTE" prepare-admission --task task-1 --candidate "$candidate" --claim-file "$old_cap" >/dev/null
  mv "$candidate" "$metadata"
  "$ROUTE" commit-admission --task task-1 --claim-file "$old_cap" >/dev/null
  jq -e '.admissionState == "active"' "$old_res" >/dev/null \
    || fail "published inherited relaunch did not reactivate its route"

  reserve_route task-1 gen-new profile-2 openai codex-secondary codex-secondary standard medium automatic >/dev/null
  new_cap=$(claim_path task-1 gen-new)
  new_res=$(reservation_path task-1 gen-new)
  begin_replacement_admission task-1 gen-new gen-old "$metadata" >/dev/null
  candidate="$metadata.replacement"
  write_route_metadata "$candidate" gen-new profile-2 codex-secondary codex-secondary
  "$ROUTE" prepare-admission --task task-1 --candidate "$candidate" \
    --claim-file "$new_cap" --prior-claim-file "$old_cap" >/dev/null
  mv "$candidate" "$metadata"
  "$ROUTE" commit-admission --task task-1 --claim-file "$new_cap" --prior-claim-file "$old_cap" >/dev/null
  jq -e '.admissionState == "active"' "$new_res" >/dev/null \
    || fail "published replacement did not activate the new generation"
  assert_absent "$old_res" "published replacement retained old active capacity"
  assert_absent "$old_cap" "published replacement retained the old capability"

  begin_off_admission task-1 gen-new "$metadata" profile-2 codex-secondary codex-secondary >/dev/null
  candidate="$metadata.off"
  printf 'task=task-1\nlaunch_nonce=static\n' >"$candidate"
  "$ROUTE" prepare-admission --task task-1 --candidate "$candidate" --claim-file "$new_cap" >/dev/null
  mv "$candidate" "$metadata"
  "$ROUTE" commit-admission --task task-1 --claim-file "$new_cap" >/dev/null
  assert_absent "$new_res" "published explicit-off relaunch retained routed capacity"
  assert_absent "$new_cap" "published explicit-off relaunch retained its capability"
  pass "published inherited, replacement, and off relaunches converge exact capacity"
}

test_stale_recovery_requires_timeout_and_a_dead_matching_owner() {
  local metadata="$FM_STATE_OVERRIDE/task-1.meta" capability live_cap live_meta="$FM_STATE_OVERRIDE/live-owner.meta" out rc
  reset_route_state
  rm -f "$metadata"
  reserve_route live-owner gen-live profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  begin_fresh_admission live-owner gen-live "$live_meta" >/dev/null
  live_cap=$(claim_path live-owner gen-live)
  age_admission live-owner gen-live
  if out=$("$ROUTE" recover-admission --task live-owner --claim-file "$live_cap" 2>&1); then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ] || fail "recovery reclaimed an admission owned by this live process"
  assert_contains "$out" "admission owner is still live" \
    "recovery did not verify the stale owner's process identity"
  "$ROUTE" abort-admission --task live-owner --claim-file "$live_cap" >/dev/null \
    || fail "live admission owner could not roll back its claim"

  reserve_route task-1 gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  capability=$(claim_path task-1 gen-1)
  (begin_fresh_admission task-1 gen-1 "$metadata" >/dev/null) &
  wait "$!" || fail "dead-owner admission setup failed"

  if out=$("$ROUTE" recover-admission --task task-1 --claim-file "$capability" 2>&1); then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ] || fail "recovery ignored the fixed timeout"
  assert_contains "$out" "admission owner is not stale" \
    "recovery did not enforce the fixed timeout"
  age_admission task-1 gen-1
  "$ROUTE" recover-admission --task task-1 --claim-file "$capability" >/dev/null \
    || fail "stale dead-owner admission did not roll back"
  assert_absent "$(reservation_path task-1 gen-1)" "stale rollback leaked its reservation"
  "$ROUTE" recover-admission --task task-1 --claim-file "$capability" >/dev/null \
    || fail "repeated recovery was not idempotent"
  pass "stale recovery requires the fixed timeout and a dead process identity"
}

test_corrupt_reservation_state_is_rejected_without_mutation() {
  local reservation before after
  reset_route_state
  reserve_route corrupt gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  reservation=$(reservation_path corrupt gen-1)
  jq '.unexpected="private detail"' "$reservation" >"$reservation.next"
  mv "$reservation.next" "$reservation"
  before=$(od -An -v -tx1 "$reservation")
  expect_failure_contains 'invalid routing state' "$ROUTE" status
  expect_failure_contains 'invalid routing state' "$ROUTE" release --task corrupt --generation gen-1
  expect_failure_contains 'invalid routing state' "$ROUTE" finalize --task corrupt --generation gen-1 \
    --terminal cancelled --claim-file "$(claim_path corrupt gen-1)"
  after=$(od -An -v -tx1 "$reservation")
  [ "$after" = "$before" ] || fail "corrupt reservation read mutated its source"

  reset_route_state
  reserve_route journal-corrupt gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  begin_fresh_admission journal-corrupt gen-1 "$FM_STATE_OVERRIDE/journal-corrupt.meta" >/dev/null
  reservation="$FM_STATE_OVERRIDE/routing/admissions/journal-corrupt.json"
  jq '.metadataFile="/tmp/attacker-controlled.meta"' "$reservation" >"$reservation.next"
  mv "$reservation.next" "$reservation"
  before=$(od -An -v -tx1 "$reservation")
  expect_failure_contains 'invalid admission state' "$ROUTE" abort-admission --task journal-corrupt \
    --claim-file "$(claim_path journal-corrupt gen-1)"
  after=$(od -An -v -tx1 "$reservation")
  [ "$after" = "$before" ] || fail "corrupt admission journal was mutated"

  reset_route_state
  reserve_route fractional gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  reservation=$(reservation_path fractional gen-1)
  jq '.createdAt=1000.5' "$reservation" >"$reservation.next"
  mv "$reservation.next" "$reservation"
  expect_failure_contains 'invalid routing state' "$ROUTE" status

  reset_route_state
  reserve_route invalid-effort gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  reservation=$(reservation_path invalid-effort gen-1)
  jq '.launchEffort="max"' "$reservation" >"$reservation.next"
  mv "$reservation.next" "$reservation"
  expect_failure_contains 'invalid routing state' "$ROUTE" status
  pass "every reservation read rejects non-exact state without mutation"
}

test_routing_storage_rejects_symlinked_parent_directories() {
  local outside="$LAB/outside-routing" reservation
  reset_route_state
  rm -rf "$outside"
  mkdir -p "$outside" "$FM_STATE_OVERRIDE/routing"
  ln -s "$outside" "$FM_STATE_OVERRIDE/routing/reservations"
  expect_failure_contains 'invalid routing state' \
    reserve_route escaped gen-1 profile-1 openai codex-primary codex-primary standard medium automatic
  [ -z "$(find "$outside" -mindepth 1 -print -quit)" ] \
    || fail "symlinked reservations root received an external write"

  reset_route_state
  rm -rf "$outside"
  mkdir -p "$outside" "$FM_STATE_OVERRIDE/routing/reservations"
  ln -s "$outside" "$FM_STATE_OVERRIDE/routing/reservations/escaped"
  expect_failure_contains 'invalid routing state' \
    reserve_route escaped gen-1 profile-1 openai codex-primary codex-primary standard medium automatic
  [ -z "$(find "$outside" -mindepth 1 -print -quit)" ] \
    || fail "symlinked reservation task directory received an external write"

  reset_route_state
  rm -rf "$outside"
  reserve_route escaped gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  mkdir -p "$outside"
  ln -s "$outside" "$FM_STATE_OVERRIDE/routing/admissions"
  expect_failure_contains 'invalid routing state' \
    begin_fresh_admission escaped gen-1 "$FM_STATE_OVERRIDE/escaped.meta"
  reservation=$(reservation_path escaped gen-1)
  jq -e '.admissionState == "reserved"' "$reservation" >/dev/null \
    || fail "symlinked admissions root changed the reservation"
  [ -z "$(find "$outside" -mindepth 1 -print -quit)" ] \
    || fail "symlinked admissions root received an external write"
  pass "routing storage refuses symlinked roots and task directories"
}

test_cleanup_crashes_converge_without_orphaning_capabilities() {
  local metadata capability reservation journal candidate
  reset_route_state
  metadata="$FM_STATE_OVERRIDE/release-cleanup.meta"
  reserve_route release-cleanup gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  activate_fresh_admission release-cleanup gen-1 "$metadata" >/dev/null
  capability=$(claim_path release-cleanup gen-1)
  reservation=$(reservation_path release-cleanup gen-1)
  rm -f "$reservation"
  "$ROUTE" release --task release-cleanup --generation gen-1 --claim-file "$capability" >/dev/null \
    || fail "release could not clean its post-reservation orphan capability"
  assert_absent "$capability" "release recovery leaked its orphan capability"

  metadata="$FM_STATE_OVERRIDE/rollback-cleanup.meta"
  reserve_route rollback-cleanup gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  (begin_fresh_admission rollback-cleanup gen-1 "$metadata" >/dev/null) &
  wait "$!" || fail "rollback cleanup setup failed"
  capability=$(claim_path rollback-cleanup gen-1)
  reservation=$(reservation_path rollback-cleanup gen-1)
  journal="$FM_STATE_OVERRIDE/routing/admissions/rollback-cleanup.json"
  jq '.phase="rollingBack"' "$journal" >"$journal.next"
  mv "$journal.next" "$journal"
  rm -f "$reservation"
  age_admission rollback-cleanup
  "$ROUTE" recover-admission --task rollback-cleanup --claim-file "$capability" >/dev/null \
    || fail "rollback cleanup did not converge after reservation deletion"
  assert_absent "$capability" "rollback cleanup leaked its capability"
  assert_absent "$journal" "rollback cleanup leaked its journal"

  metadata="$FM_STATE_OVERRIDE/off-cleanup.meta"
  reserve_route off-cleanup gen-old profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  activate_fresh_admission off-cleanup gen-old "$metadata" >/dev/null
  capability=$(claim_path off-cleanup gen-old)
  reservation=$(reservation_path off-cleanup gen-old)
  candidate="$metadata.candidate"
  (
    begin_off_admission off-cleanup gen-old "$metadata" >/dev/null
    printf 'task=off-cleanup\n' >"$candidate"
    "$ROUTE" prepare-admission --task off-cleanup --candidate "$candidate" --claim-file "$capability" >/dev/null
    mv "$candidate" "$metadata"
  ) &
  wait "$!" || fail "off cleanup setup failed"
  journal="$FM_STATE_OVERRIDE/routing/admissions/off-cleanup.json"
  jq '.phase="committing"' "$journal" >"$journal.next"
  mv "$journal.next" "$journal"
  rm -f "$reservation" "$capability"
  age_admission off-cleanup
  "$ROUTE" recover-admission --task off-cleanup --claim-file "$capability" >/dev/null \
    || fail "commit cleanup could not converge after capability deletion"
  assert_absent "$journal" "commit cleanup leaked its journal"
  pass "release, rollback, and commit cleanup crashes converge idempotently"
}

test_recovery_rolls_back_each_fresh_beginning_crash_window() {
  local metadata="$FM_STATE_OVERRIDE/task-1.meta" capability reservation journal temp
  reset_route_state
  rm -f "$metadata"
  reserve_route task-1 gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  capability=$(claim_path task-1 gen-1)
  reservation=$(reservation_path task-1 gen-1)
  journal="$FM_STATE_OVERRIDE/routing/admissions/task-1.json"
  (begin_fresh_admission task-1 gen-1 "$metadata" >/dev/null) &
  wait "$!" || fail "beginning-crash claimed setup failed"
  temp="$journal.tmp"
  jq '.phase="beginning" | .targetClaimHash=null' "$journal" >"$temp"
  mv "$temp" "$journal"
  age_admission task-1 gen-1
  "$ROUTE" recover-admission --task task-1 --claim-file "$capability" >/dev/null \
    || fail "recovery could not authenticate a beginning journal after claim persistence"
  assert_absent "$reservation" "beginning recovery leaked the fresh reservation"
  assert_absent "$capability" "beginning recovery leaked the fresh capability"

  reserve_route task-2 gen-2 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  capability=$(claim_path task-2 gen-2)
  reservation=$(reservation_path task-2 gen-2)
  journal="$FM_STATE_OVERRIDE/routing/admissions/task-2.json"
  temp="$journal.tmp"
  (begin_fresh_admission task-2 gen-2 "$FM_STATE_OVERRIDE/task-2.meta" >/dev/null) &
  wait "$!" || fail "beginning-crash reservation setup failed"
  jq '.phase="beginning" | .targetClaimHash=null' "$journal" >"$temp"
  mv "$temp" "$journal"
  jq 'del(.claimHash,.claimedAt,.ownerPid,.ownerStart,.claimPriorState) | .admissionState="reserved"' \
    "$reservation" >"$reservation.next"
  mv "$reservation.next" "$reservation"
  rm -f "$capability"
  age_admission task-2
  "$ROUTE" recover-admission --task task-2 --claim-file "$capability" >/dev/null \
    || fail "recovery could not roll back a beginning journal before capability persistence"
  assert_absent "$reservation" "pre-capability beginning recovery leaked capacity"
  assert_absent "$journal" "pre-capability beginning recovery leaked its journal"
  pass "fresh beginning journals recover before and after capability persistence"
}

test_dead_owner_recovery_rolls_back_every_prepublication_relaunch() {
  local metadata="$FM_STATE_OVERRIDE/task-1.meta" old_cap new_cap old_res new_res
  reset_route_state
  rm -f "$metadata"
  reserve_route task-1 gen-old profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  activate_fresh_admission task-1 gen-old "$metadata"
  old_cap=$(claim_path task-1 gen-old)
  old_res=$(reservation_path task-1 gen-old)

  (begin_inherited_admission task-1 gen-old "$metadata" >/dev/null) &
  wait "$!" || fail "dead inherited owner setup failed"
  age_admission task-1 gen-old
  "$ROUTE" recover-admission --task task-1 --claim-file "$old_cap" >/dev/null \
    || fail "dead inherited owner did not roll back"
  jq -e '.admissionState == "active"' "$old_res" >/dev/null \
    || fail "inherited crash recovery did not restore active"

  (begin_off_admission task-1 gen-old "$metadata" >/dev/null) &
  wait "$!" || fail "dead off owner setup failed"
  age_admission task-1
  "$ROUTE" recover-admission --task task-1 --claim-file "$old_cap" >/dev/null \
    || fail "dead off owner did not roll back"
  jq -e '.admissionState == "active"' "$old_res" >/dev/null \
    || fail "off crash recovery changed old active capacity"

  reserve_route task-1 gen-new profile-2 openai codex-secondary codex-secondary standard medium automatic >/dev/null
  new_cap=$(claim_path task-1 gen-new)
  new_res=$(reservation_path task-1 gen-new)
  (begin_replacement_admission task-1 gen-new gen-old "$metadata" >/dev/null) &
  wait "$!" || fail "dead replacement owner setup failed"
  age_admission task-1 gen-new
  "$ROUTE" recover-admission --task task-1 --claim-file "$new_cap" --prior-claim-file "$old_cap" >/dev/null \
    || fail "dead replacement owner did not roll back"
  jq -e '.admissionState == "active"' "$old_res" >/dev/null \
    || fail "replacement crash recovery changed old active capacity"
  assert_absent "$new_res" "replacement crash recovery retained new pending capacity"
  pass "dead-owner recovery rolls back inherited, off, and replacement before publication"
}

test_dead_owner_recovery_finishes_every_published_transition() {
  local metadata="$FM_STATE_OVERRIDE/task-1.meta" candidate old_cap new_cap old_res new_res
  reset_route_state
  rm -f "$metadata"
  reserve_route task-1 gen-old profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  candidate="$metadata.fresh"
  write_route_metadata "$candidate" gen-old
  old_cap=$(claim_path task-1 gen-old)
  old_res=$(reservation_path task-1 gen-old)
  (
    begin_fresh_admission task-1 gen-old "$metadata" >/dev/null
    "$ROUTE" prepare-admission --task task-1 --candidate "$candidate" --claim-file "$old_cap" >/dev/null
  ) &
  wait "$!" || fail "published fresh crash setup failed"
  mv "$candidate" "$metadata"
  age_admission task-1 gen-old
  "$ROUTE" recover-admission --task task-1 --claim-file "$old_cap" >/dev/null \
    || fail "published fresh transition did not recover"
  jq -e '.admissionState == "active"' "$old_res" >/dev/null \
    || fail "published fresh recovery did not activate"

  candidate="$metadata.inherit"
  write_route_metadata "$candidate" gen-old
  printf 'launch_nonce=crash-inherit\n' >>"$candidate"
  (
    begin_inherited_admission task-1 gen-old "$metadata" >/dev/null
    "$ROUTE" prepare-admission --task task-1 --candidate "$candidate" --claim-file "$old_cap" >/dev/null
  ) &
  wait "$!" || fail "published inherit crash setup failed"
  mv "$candidate" "$metadata"
  age_admission task-1 gen-old
  "$ROUTE" recover-admission --task task-1 --claim-file "$old_cap" >/dev/null \
    || fail "published inherited transition did not recover"
  jq -e '.admissionState == "active"' "$old_res" >/dev/null \
    || fail "published inherited recovery did not reactivate"

  reserve_route task-1 gen-new profile-2 openai codex-secondary codex-secondary standard medium automatic >/dev/null
  candidate="$metadata.replacement"
  write_route_metadata "$candidate" gen-new profile-2 codex-secondary codex-secondary
  new_cap=$(claim_path task-1 gen-new)
  new_res=$(reservation_path task-1 gen-new)
  (
    begin_replacement_admission task-1 gen-new gen-old "$metadata" >/dev/null
    "$ROUTE" prepare-admission --task task-1 --candidate "$candidate" \
      --claim-file "$new_cap" --prior-claim-file "$old_cap" >/dev/null
  ) &
  wait "$!" || fail "published replacement crash setup failed"
  mv "$candidate" "$metadata"
  age_admission task-1 gen-new
  "$ROUTE" recover-admission --task task-1 --claim-file "$new_cap" --prior-claim-file "$old_cap" >/dev/null \
    || fail "published replacement transition did not recover"
  jq -e '.admissionState == "active"' "$new_res" >/dev/null \
    || fail "published replacement recovery did not activate new"
  assert_absent "$old_res" "published replacement recovery retained old capacity"

  candidate="$metadata.off"
  printf 'task=task-1\nlaunch_nonce=crash-off\n' >"$candidate"
  (
    begin_off_admission task-1 gen-new "$metadata" profile-2 codex-secondary codex-secondary >/dev/null
    "$ROUTE" prepare-admission --task task-1 --candidate "$candidate" --claim-file "$new_cap" >/dev/null
  ) &
  wait "$!" || fail "published off crash setup failed"
  mv "$candidate" "$metadata"
  age_admission task-1
  "$ROUTE" recover-admission --task task-1 --claim-file "$new_cap" >/dev/null \
    || fail "published off transition did not recover"
  assert_absent "$new_res" "published off recovery retained routed capacity"
  pass "dead-owner recovery finishes fresh, inherited, replacement, and off publication"
}

test_failure_policy_and_circuit_breaker_are_bounded() {
  local out
  reset_route_state
  out=$("$ROUTE" failure --task transient-1 --generation gen-1 --provider xai --lane pi-xai-1 --kind transient --now 1000) || fail "first transient failure failed"
  jq -e '.action == "retry"' <<<"$out" >/dev/null || fail "first transient failure did not return retry"
  out=$("$ROUTE" failure --task transient-1 --generation gen-2 --provider xai --lane pi-xai-1 --kind transient --now 1001) || fail "second transient failure failed"
  jq -e '.action == "fallback"' <<<"$out" >/dev/null || fail "second transient failure did not return fallback"
  "$ROUTE" failure --task quota-fallback --generation gen-1 --provider google --lane pi-google-1 --kind quota --now 1000 | jq -e '.action == "fallback"' >/dev/null \
    || fail "quota failure did not fall back"
  "$ROUTE" failure --task quota-1 --generation gen-1 --provider moonshot --lane pi-moonshot-1 --kind quota --now 1100 >/dev/null
  "$ROUTE" failure --task quota-2 --generation gen-2 --provider moonshot --lane pi-moonshot-1 --kind quota --now 1100 >/dev/null
  out=$("$ROUTE" failure --task quota-3 --generation gen-3 --provider moonshot --lane pi-moonshot-1 --kind quota --now 1100) || fail "third lane failure failed"
  jq -e '.action == "circuit-open" and .until == 2900' <<<"$out" >/dev/null || fail "third recent failure did not open a thirty-minute circuit"
  out=$("$ROUTE" failure --task quota-3 --generation gen-3 --provider moonshot --lane pi-moonshot-1 --kind quota --now 1100) || fail "duplicate failure was not idempotent"
  jq -e '.action == "circuit-open" and .until == 2900' <<<"$out" >/dev/null || fail "duplicate failure changed the circuit"
  out=$("$ROUTE" failure --task quota-4 --generation gen-4 --provider moonshot --lane pi-moonshot-1 --kind quota --now 1200) || fail "open circuit failure check failed"
  jq -e '.action == "circuit-open" and .until == 2900' <<<"$out" >/dev/null || fail "failure during cooldown extended the circuit"
  expect_failure_contains 'failure-conflict' "$ROUTE" failure --task quota-4 --generation gen-4 --provider moonshot --lane different-lane --kind unsafe --now 1200
  expect_failure_contains 'circuit-open' reserve_route blocked gen-1 profile-x moonshot pi-moonshot-1 none standard low automatic
  RESERVE_NOW_OVERRIDE=2901 reserve_route recovered gen-1 profile-x moonshot pi-moonshot-1 none standard low automatic >/dev/null \
    || fail "cooled-down circuit did not admit new work"
  out=$("$ROUTE" failure --task quota-4 --generation gen-4 --provider moonshot --lane pi-moonshot-1 --kind quota --now 4000) || fail "durable failure replay failed after cooldown"
  jq -e '.action == "circuit-open" and .until == 2900' <<<"$out" >/dev/null || fail "failure replay changed after cooldown"
  "$ROUTE" failure --task unsafe-cache --generation gen-1 --provider zai --lane pi-zai-2 --kind transient --now 1000 >/dev/null
  expect_failure_contains 'failure-conflict' "$ROUTE" failure --task unsafe-cache --generation gen-1 --provider zai --lane pi-zai-2 --kind unsafe --now 1001
  "$ROUTE" failure --task unsafe --generation gen-1 --provider zai --lane pi-zai-1 --kind unsafe --now 1000 | jq -e '.action == "escalate"' >/dev/null \
    || fail "unsafe failure did not escalate"
  pass "failure actions retry once, open deterministic circuits, and escalate unsafe work"
}

test_unsafe_failure_always_escalates_without_corrupting_breakers() {
  local out replay
  reset_route_state
  "$ROUTE" failure --task quota-1 --generation gen-1 --provider xai --lane unsafe-third --kind quota --now 1000 >/dev/null
  "$ROUTE" failure --task quota-2 --generation gen-2 --provider xai --lane unsafe-third --kind quota --now 1000 >/dev/null
  out=$("$ROUTE" failure --task unsafe-3 --generation gen-3 --provider xai --lane unsafe-third --kind unsafe --now 1000) || fail "unsafe third failure command failed"
  jq -e '.action == "escalate" and .until == 2800' <<<"$out" >/dev/null || fail "unsafe third failure lost escalation precedence or breaker deadline"
  jq -e '.lanes["unsafe-third"].openUntil == 2800' "$FM_STATE_OVERRIDE/routing/circuits.json" >/dev/null || fail "unsafe third failure did not preserve the opened breaker"
  replay=$("$ROUTE" failure --task unsafe-3 --generation gen-3 --provider xai --lane unsafe-third --kind unsafe --now 4000) || fail "unsafe third failure replay failed"
  [ "$replay" = "$out" ] || fail "unsafe third failure replay changed after cooldown"

  "$ROUTE" failure --task quota-a --generation gen-a --provider moonshot --lane already-open --kind quota --now 1100 >/dev/null
  "$ROUTE" failure --task quota-b --generation gen-b --provider moonshot --lane already-open --kind quota --now 1100 >/dev/null
  "$ROUTE" failure --task quota-c --generation gen-c --provider moonshot --lane already-open --kind quota --now 1100 >/dev/null
  out=$("$ROUTE" failure --task unsafe-open --generation gen-open --provider moonshot --lane already-open --kind unsafe --now 1200) || fail "unsafe open-circuit failure command failed"
  jq -e '.action == "escalate" and .until == 2900' <<<"$out" >/dev/null || fail "open circuit masked unsafe escalation"
  jq -e '.lanes["already-open"].openUntil == 2900' "$FM_STATE_OVERRIDE/routing/circuits.json" >/dev/null || fail "unsafe open-circuit failure changed the breaker deadline"
  replay=$("$ROUTE" failure --task unsafe-open --generation gen-open --provider moonshot --lane already-open --kind unsafe --now 5000) || fail "unsafe open-circuit replay failed"
  [ "$replay" = "$out" ] || fail "unsafe open-circuit replay changed after cooldown"
  pass "unsafe failures escalate durably while breaker timing remains authoritative"
}

assert_invalid_circuits_unchanged() {
  local label=$1 file="$FM_STATE_OVERRIDE/routing/circuits.json" before after out rc
  before=$(od -An -v -tx1 "$file")
  set +e
  out=$("$ROUTE" status --now 1200 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$label: invalid circuits state was accepted by status"
  [ "$out" = 'fm-route: invalid routing state' ] || fail "$label: status leaked a non-sanitized circuit diagnostic: $out"
  set +e
  out=$("$ROUTE" failure --task probe --generation gen-probe --provider xai --lane lane-1 --kind quota --now 1200 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$label: invalid circuits state was accepted by mutation"
  [ "$out" = 'fm-route: invalid routing state' ] || fail "$label: mutation leaked a non-sanitized circuit diagnostic: $out"
  after=$(od -An -v -tx1 "$file")
  [ "$after" = "$before" ] || fail "$label: rejected circuit state was mutated"
}

test_circuit_state_schema_is_exact_private_and_transactional() {
  local file="$FM_STATE_OVERRIDE/routing/circuits.json" base="$LAB/circuits-valid.json" row label filter
  reset_route_state
  "$ROUTE" failure --task base --generation gen-1 --provider xai --lane lane-1 --kind quota --now 1000 >/dev/null
  cp "$file" "$base"
  "$ROUTE" status --now 1000 | jq -e '.openCircuits == []' >/dev/null || fail "valid closed circuit state was rejected"

  while IFS='|' read -r label filter; do
    [ -n "$label" ] || continue
    jq "$filter" "$base" >"$file"
    assert_invalid_circuits_unchanged "$label"
  done <<'CASES'
top-level token|.token="secret"
nested cookie|.events["base|gen-1"].details={cookie:"secret"}
unknown lane prompt|.lanes["lane-1"].prompt="secret"
unknown event source|.events["base|gen-1"].source="secret"
unknown event raw output|.events["base|gen-1"].rawOutput="secret"
negative timestamp|.events["base|gen-1"].timestamp=-1
fractional deadline|.lanes["lane-1"].openUntil=1.5
malformed event key|.events["wrong|key"]=.events["base|gen-1"] | del(.events["base|gen-1"])
malformed task identifier|.events["base|gen-1"].taskId="bad/id"
open action without deadline|.events["base|gen-1"].action="circuit-open"
retry action for quota|.events["base|gen-1"].action="retry"
unbacked lane deadline|.lanes["lane-1"].openUntil=2800
conflicting duplicate identity|.events["other|gen-2"]=.events["base|gen-1"]
provider mismatch|.lanes["lane-1"].provider="other"
CASES

  printf '%s\n' '{"lanes":{},"events":{},"events":{}}' >"$file"
  assert_invalid_circuits_unchanged 'duplicate events key'
  printf '' >"$file"
  assert_invalid_circuits_unchanged 'empty circuit file'
  printf '{bad json\n' >"$file"
  assert_invalid_circuits_unchanged 'malformed circuit JSON'
  pass "circuit state rejects private, malformed, duplicate, and inconsistent records without mutation"
}

test_score_finalize_and_outcome_privacy_are_strict() {
  local outcome capability metadata="$FM_STATE_OVERRIDE/task-1.meta"
  reset_route_state
  reserve_route task-1 gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  capability=$(claim_path task-1 gen-1)
  expect_failure_contains 'reservation-not-active' "$ROUTE" finalize --task task-1 --generation gen-1 \
    --terminal completed --claim-file "$capability"
  activate_fresh_admission task-1 gen-1 "$metadata" >/dev/null
  expect_failure_contains 'forbidden outcome field: prompt' "$ROUTE" score --task task-1 --generation gen-1 --terminal completed --tests pass --review pass --redundant no --now 1010 --extra-json '{"prompt":"secret"}'
  expect_failure_contains 'unexpected outcome field: harmless' "$ROUTE" score --task task-1 --generation gen-1 --terminal completed --tests pass --review pass --redundant no --now 1010 --extra-json '{"harmless":true}'
  "$ROUTE" score --task task-1 --generation gen-1 --terminal completed --tests pass --review pass --redundant no --now 1010 >/dev/null || fail "score failed"
  "$ROUTE" score --task task-1 --generation gen-1 --terminal completed --tests pass --review pass --redundant no --now 1011 >/dev/null || fail "duplicate score was not idempotent"
  [ ! -e "$FM_STATE_OVERRIDE/routing/outcomes.jsonl" ] || fail "score finalized before safe cleanup"
  "$ROUTE" finalize --task task-1 --generation gen-1 --terminal completed \
    --claim-file "$capability" >/dev/null || fail "finalize failed"
  "$ROUTE" finalize --task task-1 --generation gen-1 --terminal completed \
    --claim-file "$capability" >/dev/null || fail "duplicate finalize was not idempotent"
  [ ! -e "$(reservation_path task-1 gen-1)" ] || fail "finalize leaked active capacity"
  [ "$(wc -l < "$FM_STATE_OVERRIDE/routing/outcomes.jsonl")" -eq 1 ] || fail "finalize duplicated the outcome"
  outcome=$(cat "$FM_STATE_OVERRIDE/routing/outcomes.jsonl")
  jq -e 'keys == ["account","elapsedSeconds","generation","kind","lane","mode","profile","provider","redundant","review","risk","taskClass","taskId","terminal","tests","timestamp","workType"] and .elapsedSeconds == 10 and .workType == "implementation"' <<<"$outcome" >/dev/null \
    || fail "outcome schema was not bounded"
  "$ROUTE" evidence --work-type implementation | jq -e '. == [{"profile":"profile-1","successes":1,"attempts":1}]' >/dev/null \
    || fail "finalized live work did not contribute work-type evidence"
  ! grep -qiE 'prompt|source|secret|token|cookie|authorization|password' "$FM_STATE_OVERRIDE/routing/outcomes.jsonl" \
    || fail "private payload marker reached the outcome ledger"
  pass "score and finalization are idempotent and privacy-safe"
}

test_cleanup_finalization_uses_canonical_capability_and_unknown_scores() {
  local capability metadata="$FM_STATE_OVERRIDE/cleanup.meta" outcome
  reset_route_state
  rm -f "$metadata"
  reserve_route cleanup gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  activate_fresh_admission cleanup gen-1 "$metadata" >/dev/null
  capability=$(claim_path cleanup gen-1)

  [ "$(cleanup_ready cleanup gen-1)" = '{"terminal":"completed"}' ] \
    || fail "cleanup preflight did not resolve the no-score completed default"
  [ -f "$capability" ] || fail "cleanup preflight consumed its capability"
  outcome=$(cleanup_finalize cleanup gen-1 completed) || fail "cleanup finalization failed"
  jq -e '.terminal == "completed" and .tests == "unknown" and .review == "unknown" and .redundant == "no"' <<<"$outcome" >/dev/null \
    || fail "cleanup inferred test or review success"
  [ ! -e "$(reservation_path cleanup gen-1)" ] || fail "cleanup finalization leaked capacity"
  [ ! -e "$capability" ] || fail "cleanup finalization leaked its capability"
  cleanup_finalize cleanup gen-1 completed >/dev/null || fail "cleanup finalization replay was not idempotent"
  expect_failure_contains 'terminal-outcome-conflict' cleanup_finalize cleanup gen-1 failed_safe
  [ "$(jq -s '[.[] | select(.taskId == "cleanup" and .generation == "gen-1")] | length' "$FM_STATE_OVERRIDE/routing/outcomes.jsonl")" -eq 1 ] \
    || fail "cleanup finalization replay duplicated its outcome"
  pass "cleanup finalization derives the canonical capability and preserves unknown scores"
}

test_cleanup_resolution_preserves_every_terminal_exactly_once() {
  local terminal metadata capability outcome ready count
  for terminal in completed failed_safe escalated cancelled superseded; do
    reset_route_state
    metadata="$FM_STATE_OVERRIDE/cleanup.meta"
    rm -f "$metadata"
    reserve_route cleanup gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
    activate_fresh_admission cleanup gen-1 "$metadata" >/dev/null
    capability=$(claim_path cleanup gen-1)
    "$ROUTE" score --task cleanup --generation gen-1 --terminal "$terminal" \
      --tests unknown --review unknown --redundant no --now 1010 >/dev/null

    ready=$(cleanup_ready cleanup gen-1) || fail "cleanup preflight rejected terminal $terminal"
    [ "$ready" = "{\"terminal\":\"$terminal\"}" ] \
      || fail "cleanup preflight did not return the strict $terminal resolution: $ready"
    outcome=$(cleanup_finalize cleanup gen-1 "$terminal") \
      || fail "cleanup finalization rejected resolved terminal $terminal"
    jq -e --arg terminal "$terminal" \
      '.terminal == $terminal and .tests == "unknown" and .review == "unknown" and .redundant == "no"' \
      <<<"$outcome" >/dev/null || fail "cleanup changed score fields for terminal $terminal"
    [ ! -e "$(reservation_path cleanup gen-1)" ] || fail "$terminal cleanup leaked its reservation"
    [ ! -e "$capability" ] || fail "$terminal cleanup leaked its capability"

    ready=$(cleanup_ready cleanup gen-1) || fail "$terminal terminal outcome replay was not cleanup-ready"
    [ "$ready" = "{\"terminal\":\"$terminal\"}" ] \
      || fail "$terminal outcome replay resolved a different terminal"
    cleanup_finalize cleanup gen-1 "$terminal" >/dev/null \
      || fail "$terminal cleanup finalization replay was not idempotent"
    count=$(jq -s '[.[] | select(.taskId == "cleanup" and .generation == "gen-1")] | length' \
      "$FM_STATE_OVERRIDE/routing/outcomes.jsonl")
    [ "$count" -eq 1 ] || fail "$terminal cleanup wrote $count terminal outcomes"
  done
  pass "cleanup resolution finalizes every terminal enum exactly once and releases one reservation and capability"
}

test_cleanup_resolution_rejects_terminal_score_conflict_without_mutation() {
  local metadata reservation capability outcomes before_res before_cap before_out out
  reset_route_state
  metadata="$FM_STATE_OVERRIDE/cleanup.meta"
  rm -f "$metadata"
  reserve_route cleanup gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  activate_fresh_admission cleanup gen-1 "$metadata" >/dev/null
  "$ROUTE" score --task cleanup --generation gen-1 --terminal failed_safe \
    --tests fail --review unknown --redundant no --now 1010 >/dev/null
  reservation=$(reservation_path cleanup gen-1)
  capability=$(claim_path cleanup gen-1)
  outcomes="$FM_STATE_OVERRIDE/routing/outcomes.jsonl"
  jq -cn --argjson reservation "$(cat "$reservation")" '
    {kind:"terminal",timestamp:1010,taskId:$reservation.taskId,generation:$reservation.generation,
     profile:$reservation.profile,provider:$reservation.provider,lane:$reservation.lane,account:$reservation.account,
     taskClass:$reservation.taskClass,workType:$reservation.workType,risk:$reservation.risk,mode:$reservation.mode,
     elapsedSeconds:10,tests:"unknown",review:"unknown",redundant:"no",terminal:"completed"}
  ' >"$outcomes"
  before_res=$(od -An -v -tx1 "$reservation")
  before_cap=$(od -An -v -tx1 "$capability")
  before_out=$(od -An -v -tx1 "$outcomes")

  out=$(cleanup_ready cleanup gen-1 2>&1) && fail "terminal outcome/score conflict unexpectedly became cleanup-ready"
  assert_contains "$out" 'terminal-score-conflict' "terminal conflict diagnostic was not stable"
  [ "$(od -An -v -tx1 "$reservation")" = "$before_res" ] || fail "terminal conflict mutated reservation bytes"
  [ "$(od -An -v -tx1 "$capability")" = "$before_cap" ] || fail "terminal conflict mutated capability bytes"
  [ "$(od -An -v -tx1 "$outcomes")" = "$before_out" ] || fail "terminal conflict mutated outcome bytes"
  pass "cleanup resolution refuses terminal/score conflict without mutation"
}

test_cleanup_resolution_rejects_corrupt_private_state_without_leaking_it() {
  local metadata reservation out before
  reset_route_state
  metadata="$FM_STATE_OVERRIDE/cleanup.meta"
  rm -f "$metadata"
  reserve_route cleanup gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  activate_fresh_admission cleanup gen-1 "$metadata" >/dev/null
  reservation=$(reservation_path cleanup gen-1)
  jq '.score={terminal:"failed_safe",tests:"fail",review:"unknown",redundant:"no",timestamp:1010,prompt:"secret-value"}' \
    "$reservation" >"$reservation.next"
  mv "$reservation.next" "$reservation"
  before=$(od -An -v -tx1 "$reservation")

  out=$(cleanup_ready cleanup gen-1 2>&1) && fail "private corrupt score unexpectedly became cleanup-ready"
  assert_not_contains "$out" 'secret-value' "cleanup preflight leaked private corrupt state"
  assert_not_contains "$out" 'prompt' "cleanup preflight disclosed a forbidden private field"
  [ "$(od -An -v -tx1 "$reservation")" = "$before" ] || fail "private corrupt state was mutated during refusal"
  pass "cleanup resolution rejects corrupt private score state with bounded diagnostics"
}

test_cleanup_outcome_replay_still_validates_admission_state() {
  local metadata outcomes before out
  reset_route_state
  metadata="$FM_STATE_OVERRIDE/cleanup.meta"
  rm -f "$metadata"
  reserve_route cleanup gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  activate_fresh_admission cleanup gen-1 "$metadata" >/dev/null
  cleanup_finalize cleanup gen-1 completed >/dev/null || fail "outcome replay setup did not finalize"
  outcomes="$FM_STATE_OVERRIDE/routing/outcomes.jsonl"
  before=$(od -An -v -tx1 "$outcomes")
  printf '{corrupt admission\n' >"$FM_STATE_OVERRIDE/routing/admissions/cleanup.json"

  out=$(cleanup_ready cleanup gen-1 2>&1) && fail "terminal outcome replay ignored a corrupt admission journal"
  assert_contains "$out" 'invalid admission state' "corrupt replay admission did not return a bounded diagnostic"
  [ "$(od -An -v -tx1 "$outcomes")" = "$before" ] || fail "corrupt replay admission mutated outcome bytes"
  [ ! -e "$(reservation_path cleanup gen-1)" ] || fail "corrupt replay admission recreated a reservation"
  pass "terminal outcome replay validates admission state before authorizing cleanup"
}

test_cleanup_preflight_rejects_missing_capability_and_corrupt_journal() {
  local metadata="$FM_STATE_OVERRIDE/cleanup.meta" capability reservation before
  reset_route_state
  rm -f "$metadata"
  reserve_route cleanup gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  activate_fresh_admission cleanup gen-1 "$metadata" >/dev/null
  capability=$(claim_path cleanup gen-1)
  reservation=$(reservation_path cleanup gen-1)
  before=$(od -An -v -tx1 "$reservation")
  rm -f "$capability"
  expect_failure_contains 'invalid claim file' cleanup_ready cleanup gen-1
  [ "$(od -An -v -tx1 "$reservation")" = "$before" ] || fail "missing capability mutated the reservation"
  [ ! -e "$FM_STATE_OVERRIDE/routing/outcomes.jsonl" ] || fail "missing capability wrote an outcome"

  printf '{bad json\n' >"$FM_STATE_OVERRIDE/routing/admissions/cleanup.json"
  expect_failure_contains 'invalid admission state' cleanup_ready cleanup gen-1
  [ "$(od -An -v -tx1 "$reservation")" = "$before" ] || fail "corrupt journal mutated the reservation"
  [ ! -e "$FM_STATE_OVERRIDE/routing/outcomes.jsonl" ] || fail "corrupt journal wrote an outcome"
  pass "cleanup preflight rejects missing capabilities and corrupt journals without mutation"
}

test_cleanup_preflight_recovers_stale_admission_before_finalizing() {
  local metadata="$FM_STATE_OVERRIDE/cleanup.meta" capability journal
  reset_route_state
  rm -f "$metadata"
  reserve_route cleanup gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  activate_fresh_admission cleanup gen-1 "$metadata" >/dev/null
  capability=$(claim_path cleanup gen-1)
  ("$ROUTE" begin-admission --task cleanup --generation gen-1 \
    --profile profile-1 --provider openai --lane codex-primary \
    --account codex-primary --class standard --work-type implementation --risk medium --mode automatic \
    --launch-harness codex --launch-model model-profile-1 --launch-effort none \
    --transition inherit --metadata-file "$metadata" --claim-file "$capability" >/dev/null) &
  wait "$!" || fail "stale cleanup admission setup failed"
  age_admission cleanup gen-1
  journal="$FM_STATE_OVERRIDE/routing/admissions/cleanup.json"
  jq '.ownerPid=99999999 | .ownerStart=("a" * 64)' "$journal" >"$journal.next"
  mv "$journal.next" "$journal"

  cleanup_ready cleanup gen-1 >/dev/null || fail "cleanup preflight did not validate stale admission"
  [ -e "$FM_STATE_OVERRIDE/routing/admissions/cleanup.json" ] || fail "cleanup preflight mutated its journal"
  jq -e '.admissionState == "claimed"' "$(reservation_path cleanup gen-1)" >/dev/null \
    || fail "cleanup preflight mutated the claimed generation"
  cleanup_finalize cleanup gen-1 completed >/dev/null || fail "recovered cleanup did not finalize"
  [ ! -e "$FM_STATE_OVERRIDE/routing/admissions/cleanup.json" ] || fail "cleanup finalization retained its journal"
  pass "cleanup preflight recovers stale admission before terminal finalization"
}

test_observation_evidence_status_and_report_are_non_mutating() {
  local decision status report
  reset_route_state
  write_request standard implementation low false 1 strong 120
  write_candidates "[$(candidate observed lane-1 3 1 0 0 0 null)]"
  decision=$(select_json) || fail "simulation decision failed"
  printf '%s\n' "$decision" >"$LAB/decision.json"
  "$ROUTE" observe --request "$REQUEST" --decision "$LAB/decision.json" --now 1000 >/dev/null || fail "simulation observation failed"
  [ ! -d "$FM_STATE_OVERRIDE/routing/reservations" ] || [ -z "$(find "$FM_STATE_OVERRIDE/routing/reservations" -type f -name '*.json' -print -quit)" ] \
    || fail "simulation observation created active capacity"
  "$ROUTE" evidence --work-type implementation | jq -e '. == []' >/dev/null \
    || fail "simulation observation polluted live selector evidence"
  select_json | jq -e '.selected.historyAttempts == 0 and .selected.historySuccesses == 0' >/dev/null \
    || fail "simulation observation polluted selector history hydration"

  reserve_route live gen-live active openai codex-primary codex-primary standard low automatic >/dev/null
  status=$("$ROUTE" status) || fail "routing status failed"
  jq -e '.caps == {"canary":3,"automatic":6,"burst":8,"perLane":2,"perAccount":2} and .active.total == 1 and .openCircuits == []' <<<"$status" >/dev/null \
    || fail "status omitted caps or active totals"

  "$ROUTE" release --task live --generation gen-live >/dev/null
  report=$("$ROUTE" report --stage simulation --minimum 1) || fail "simulation report failed"
  jq -e '.stage == "simulation" and .minimum == 1 and .count == 1 and .meetsMinimum == true and .medianElapsedSeconds == 120' <<<"$report" >/dev/null \
    || fail "simulation report gates or median were not deterministic"
  pass "observations do not reserve capacity and reports expose bounded aggregate facts"
}

test_finalize_recovers_between_ledger_publish_and_reservation_delete() {
  local reservation capability snapshot="$LAB/recovery-reservation.json" cap_snapshot="$LAB/recovery-capability"
  reservation=$(reservation_path recovery gen-1)
  capability=$(claim_path recovery gen-1)
  reset_route_state
  reserve_route recovery gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  activate_fresh_admission recovery gen-1 "$FM_STATE_OVERRIDE/recovery.meta" >/dev/null
  "$ROUTE" score --task recovery --generation gen-1 --terminal completed --tests pass --review pass --redundant no --now 1010 >/dev/null
  cp "$reservation" "$snapshot"
  cp "$capability" "$cap_snapshot"
  "$ROUTE" finalize --task recovery --generation gen-1 --terminal completed --claim-file "$capability" >/dev/null
  mkdir -p "$(dirname "$reservation")"
  cp "$snapshot" "$reservation"
  cp "$cap_snapshot" "$capability"
  chmod 600 "$capability"
  expect_failure_contains 'terminal-outcome-conflict' "$ROUTE" finalize --task recovery --generation gen-1 --terminal failed_safe --claim-file "$capability"
  [ -f "$reservation" ] || fail "conflicting recovery removed the reservation"
  "$ROUTE" finalize --task recovery --generation gen-1 --terminal completed --claim-file "$capability" >/dev/null || fail "matching recovery did not reconcile"
  [ ! -e "$reservation" ] || fail "matching recovery left the reservation active"
  cp "$cap_snapshot" "$capability"
  chmod 600 "$capability"
  "$ROUTE" finalize --task recovery --generation gen-1 --terminal completed --claim-file "$capability" >/dev/null \
    || fail "matching recovery did not clean an orphaned finalization capability"
  [ ! -e "$capability" ] || fail "matching recovery left an orphaned finalization capability"
  [ "$(jq -s '[.[] | select(.taskId == "recovery")] | length' "$FM_STATE_OVERRIDE/routing/outcomes.jsonl")" -eq 1 ] || fail "recovery duplicated the terminal ledger row"
  pass "finalize reconciles the ledger-published reservation-delete crash window"
}

test_observe_and_ledger_schemas_are_exact_and_sanitized() {
  local decision before after
  reset_route_state
  write_request standard implementation low false 1 strong 120
  write_candidates "[$(candidate observed lane-1 3 1 0 0 0 null)]"
  decision=$(select_json) || fail "strict observation decision failed"
  jq '.selected.notes="arbitrary"' <<<"$decision" >"$LAB/decision-invalid.json"
  expect_failure_contains 'invalid selected route schema: unexpected field notes' "$ROUTE" observe --request "$REQUEST" --decision "$LAB/decision-invalid.json" --now 1000
  jq '.selected.provider=42' <<<"$decision" >"$LAB/decision-invalid.json"
  expect_failure_contains 'invalid selected route schema: provider' "$ROUTE" observe --request "$REQUEST" --decision "$LAB/decision-invalid.json" --now 1000
  jq '.selected.model="arbitrary private text"' <<<"$decision" >"$LAB/decision-invalid.json"
  expect_failure_contains 'invalid selected route schema: model' "$ROUTE" observe --request "$REQUEST" --decision "$LAB/decision-invalid.json" --now 1000
  mkdir -p "$FM_STATE_OVERRIDE/routing"
  printf '%s\n' '{"prompt":"secret"}' >"$FM_STATE_OVERRIDE/routing/outcomes.jsonl"
  expect_failure_contains 'invalid routing state' "$ROUTE" evidence --work-type implementation
  printf '%s\n' "$decision" >"$LAB/decision-valid.json"
  before=$(od -An -v -tx1 "$FM_STATE_OVERRIDE/routing/outcomes.jsonl")
  expect_failure_contains 'invalid routing state' "$ROUTE" observe --request "$REQUEST" --decision "$LAB/decision-valid.json" --now 1000
  after=$(od -An -v -tx1 "$FM_STATE_OVERRIDE/routing/outcomes.jsonl")
  [ "$after" = "$before" ] || fail "failed observation mutated the invalid ledger"
  pass "observe and persisted ledger reads reject unbounded or private state"
}

test_status_exposes_complete_capacity_and_breaker_policy() {
  reset_route_state
  "$ROUTE" status --now 1000 | jq -e '
    .caps == {"canary":3,"automatic":6,"burst":8,"perLane":2,"perAccount":2}
    and .circuitBreaker == {"failures":3,"windowSeconds":900,"cooldownSeconds":1800}
  ' >/dev/null || fail "status omitted account or circuit-breaker bounds"
  pass "status exposes the complete fixed admission policy"
}

test_every_single_value_option_rejects_duplicates() {
  write_request standard implementation low false 1 strong 120
  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null)]"
  printf '%s\n' '{"action":"selected","maxWorkers":1,"ranked":[],"reason":"test","rejected":[],"selected":{},"uncertainty":[]}' >"$LAB/duplicate-decision.json"
  expect_failure_contains 'usage:' "$ROUTE" select --request "$REQUEST" --request "$REQUEST" --candidates "$CANDIDATES"
  expect_failure_contains 'usage:' "$ROUTE" reserve --task one --task two
  expect_failure_contains 'usage:' "$ROUTE" reserve --request "$REQUEST" --request "$REQUEST"
  expect_failure_contains 'usage:' "$ROUTE" verify-reservation --profile one --profile two
  expect_failure_contains 'usage:' "$ROUTE" reservation-work-type --task one --task two
  expect_failure_contains 'usage:' "$ROUTE" claim-reservation --claim aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --claim bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  expect_failure_contains 'usage:' "$ROUTE" activate-reservation --task one --task two
  expect_failure_contains 'usage:' "$ROUTE" release --generation one --generation two
  expect_failure_contains 'usage:' "$ROUTE" failure --kind quota --kind auth
  expect_failure_contains 'usage:' "$ROUTE" score --tests pass --tests fail
  expect_failure_contains 'usage:' "$ROUTE" finalize --terminal completed --terminal cancelled
  expect_failure_contains 'usage:' "$ROUTE" cleanup-ready --task one --task two
  expect_failure_contains 'usage:' "$ROUTE" cleanup-ready --terminal completed
  expect_failure_contains 'usage:' "$ROUTE" cleanup-finalize --terminal completed --terminal cancelled
  expect_failure_contains 'usage:' "$ROUTE" observe --decision "$LAB/duplicate-decision.json" --decision "$LAB/duplicate-decision.json"
  expect_failure_contains 'usage:' "$ROUTE" evidence --work-type implementation --work-type debugging
  expect_failure_contains 'usage:' "$ROUTE" status --now 1 --now 2
  expect_failure_contains 'usage:' "$ROUTE" report --minimum 1 --minimum 2
  pass "all public commands reject repeated single-valued options"
}

test_fit_beats_quota
test_off_mode_returns_static_without_initializing_routing_state
test_policy_boundaries_are_explicit_and_fail_closed
test_active_policy_path_is_contained_and_never_symlinked
test_version_one_policy_retains_selector_compatibility
test_unknowns_are_disclosed_not_zero
test_worker_budget_is_bounded
test_every_decision_has_the_complete_output_shape
test_rejections_account_for_every_ineligible_candidate
test_load_precedes_history
test_history_is_read_from_state_only_for_equal_attempts
test_cost_breaks_ties_only_when_every_cost_is_known
test_request_schema_is_strict
test_candidate_schema_is_strict
test_input_and_now_validation_are_sanitized
test_reserve_requires_a_bounded_work_type
test_reserve_is_bound_to_authoritative_policy_and_selection_evidence
test_reserve_rejects_a_decision_staled_by_authoritative_load
test_legacy_unbound_reservations_are_cleanup_only
test_begin_admission_revalidates_the_active_policy_before_mutation
test_bound_admission_rejects_published_launch_identity_tamper
test_canary_cap_is_atomic_and_duplicate_reserve_is_idempotent
test_lane_account_and_burst_caps_are_enforced
test_reservation_verification_and_generation_release_are_exact
test_reservation_claim_blocks_concurrent_lifecycle_until_activation
test_claim_release_is_exact_and_stale_claims_are_recoverable
test_spawn_claim_requires_the_authoritative_reservation_work_type
test_active_generation_can_hold_one_distinct_pending_replacement
test_fresh_admission_uses_only_a_protected_capability_file
test_fresh_admission_journal_commits_only_the_published_metadata
test_relaunch_abort_restores_or_preserves_only_the_owned_generations
test_relaunch_commit_retires_old_capacity_only_after_publication
test_stale_recovery_requires_timeout_and_a_dead_matching_owner
test_corrupt_reservation_state_is_rejected_without_mutation
test_routing_storage_rejects_symlinked_parent_directories
test_cleanup_crashes_converge_without_orphaning_capabilities
test_recovery_rolls_back_each_fresh_beginning_crash_window
test_dead_owner_recovery_rolls_back_every_prepublication_relaunch
test_dead_owner_recovery_finishes_every_published_transition
test_raw_claim_and_unauthenticated_active_reclaim_flags_are_removed
test_failure_policy_and_circuit_breaker_are_bounded
test_unsafe_failure_always_escalates_without_corrupting_breakers
test_circuit_state_schema_is_exact_private_and_transactional
test_score_finalize_and_outcome_privacy_are_strict
test_cleanup_finalization_uses_canonical_capability_and_unknown_scores
test_cleanup_resolution_preserves_every_terminal_exactly_once
test_cleanup_resolution_rejects_terminal_score_conflict_without_mutation
test_cleanup_resolution_rejects_corrupt_private_state_without_leaking_it
test_cleanup_outcome_replay_still_validates_admission_state
test_cleanup_preflight_rejects_missing_capability_and_corrupt_journal
test_cleanup_preflight_recovers_stale_admission_before_finalizing
test_observation_evidence_status_and_report_are_non_mutating
test_finalize_recovers_between_ledger_publish_and_reservation_delete
test_observe_and_ledger_schemas_are_exact_and_sanitized
test_status_exposes_complete_capacity_and_breaker_policy
test_every_single_value_option_rejects_duplicates
