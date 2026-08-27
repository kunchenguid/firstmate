# FirstMate Automatic Subscription Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add safe automatic task routing across native Claude, native Codex, and the Pi subscription model fleet, with bounded parallelism, automatic fallback, circuit breakers, and privacy-safe outcome reporting.

**Architecture:** Extend the existing `crew-dispatch.json` and `fm-spawn.sh` path instead of creating another scheduler.
An agent-only skill owns task classification, decomposition, live catalog evidence, and candidate construction, while deterministic shell code validates policy, ranks normalized candidates lexicographically, reserves capacity, persists circuit state, and records bounded outcome facts.

**Tech Stack:** Bash, jq, existing FirstMate state and lock helpers, quota-axi, CLIProxyAPI-backed Pi model discovery, and shell behavior tests under `tests/`.

## Global Constraints

- Phase 1 supports only the installed Claude, Codex, Pi, and pi-signed runtimes.
- Agy, OpenHands, OpenClaw, and Hermes adapters remain Phase 2 work and must not be introduced here.
- Pi models are subscription-backed and must not be penalized as metered API calls.
- Routing selection order is task fit, usable subscription capacity, current lane load, comparable outcome evidence, then a minor cost tie-break only when cost evidence exists.
- Task fit and reasoning-class requirements always outrank quota conservation.
- Unknown quota, authentication, or runway is disclosed uncertainty and is not fabricated as a healthy value.
- Trivial and standard tasks default to one worker.
- Decomposable tasks may use two to four independent workers.
- Ambiguous tasks may use at most two competing approaches.
- High-risk work uses one implementer plus one independent reviewer from a different provider.
- Canary mode permits at most three active routed workers.
- Automatic mode defaults to six active routed workers.
- Burst mode permits at most eight active routed workers and only for independent work.
- No provider or account lane may hold more than two active routed workers.
- A proven transient failure receives at most one retry.
- Quota, authentication, or model unavailability falls back to the next qualified profile without retrying the unavailable lane.
- Three failures for one lane in fifteen minutes open a thirty-minute circuit breaker.
- Ambiguous writes, unsafe state, and uncertain partial execution stop for captain review without retry.
- Existing authority, repository, worktree, review, merge, destructive-action, and production-change rules remain unchanged.
- Routing state and reports must never contain prompts, source code, credentials, cookies, token values, or raw tool output.
- Native account maps are home-local and are never inherited into another FirstMate or secondmate home.
- An invalid optimization policy returns FirstMate to its configured static profile instead of making dispatch unusable.
- `off`, `simulate`, `canary`, and `automatic` are the only routing modes.
- Phase 1 records comparable outcome evidence but does not invent the deferred Phase 3 statistical estimator.
- Tracked Markdown uses one full sentence per physical line and plain dashes.
- Every shell behavior change is developed red-green and passes the pinned repository lint.

---

## File Structure

### New files

- `bin/fm-dispatch-policy.sh` owns schema-versioned policy validation and normalized policy reads.
- `bin/fm-account-lane.sh` owns the allowlisted mapping from a symbolic native account lane to its existing protected configuration directory.
- `bin/fm-routing-lib.sh` owns pure ranking, capacity, circuit-breaker, ledger validation, rotation, and atomic state helpers.
- `bin/fm-route.sh` is the deterministic public command used by FirstMate to select, reserve, release, record failure, and score routed work.
- `.agents/skills/automatic-dispatch/SKILL.md` owns task classification, decomposition, live model evidence, retry decisions, and explainable use of `fm-route.sh`.
- `tests/fm-dispatch-policy.test.sh` covers backward-compatible and version 2 policy validation.
- `tests/fm-account-lane.test.sh` covers native Claude and Codex account selection without reading credentials.
- `tests/fm-route.test.sh` covers ranking, simulation, caps, reservations, fallback, circuit breakers, privacy, recovery, and rotation.
- `tests/fm-automatic-dispatch-contract.test.sh` covers the conditional skill trigger and its safety contract.
- `docs/verification/automatic-dispatch.md` owns dated non-mutating live verification evidence.
- `docs/examples/crew-accounts.json` provides a copyable account-lane map containing paths but no credential contents.

### Modified files

- `bin/fm-bootstrap.sh` delegates dispatch-policy validation to `fm-dispatch-policy.sh` and reports routing mode diagnostics.
- `bin/fm-spawn.sh` accepts validated route metadata, enforces a reservation for routed launches, records it in task metadata, and releases it on launch failure.
- `bin/fm-teardown.sh` finalizes routed outcomes and releases routed capacity only after safe cleanup succeeds.
- `bin/fm-test-run.sh` maps the new tests into existing test families and changed-file selection.
- `AGENTS.md` replaces the old array-only procedure with a short trigger for `automatic-dispatch` while retaining unconditional safety boundaries.
- `.agents/skills/quota-array-dispatch/SKILL.md` becomes the quota-evidence subprocedure used by `automatic-dispatch` rather than a competing route owner.
- `docs/configuration.md` owns the version 2 policy schema, runtime state layout, mode behavior, and rollback procedure.
- `docs/architecture.md` documents the extension boundary and states that FirstMate remains the only scheduler.
- `docs/examples/crew-dispatch.json` provides a copyable subscription-first policy using models confirmed in the current catalogs.
- `docs/documentation-audiences.json` classifies the new skill, verification document, design specification, and implementation plan.
- `tests/fm-bootstrap.test.sh` covers bootstrap delegation and policy diagnostics.
- `tests/fm-spawn-dispatch-profile.test.sh` covers route reservation and metadata propagation.
- `tests/fm-teardown.test.sh` covers routed terminal scoring and capacity release.
- `tests/fm-documentation-audiences.test.sh` covers the complete maintained-prose inventory.

---

### Task 1: Version and Normalize the Dispatch Policy

**Files:**

- Create: `bin/fm-dispatch-policy.sh`
- Create: `tests/fm-dispatch-policy.test.sh`
- Modify: `bin/fm-bootstrap.sh:992-1095`
- Modify: `tests/fm-bootstrap.test.sh:1070-1150`
- Modify: `bin/fm-test-run.sh`

**Interfaces:**

- Consumes: `FM_CONFIG_OVERRIDE` or `$FM_HOME/config/crew-dispatch.json`.
- Produces: `fm-dispatch-policy.sh validate [FILE]`, `mode [FILE]`, `limits [FILE]`, `profile PROFILE_ID [FILE]`, and `describe [FILE]`.
- Produces: normalized JSON profiles with `id`, `harness`, `model`, optional `effort`, `provider`, `lane`, optional symbolic `account`, `reasoningClass`, and `workTypes`; version 2 requires a concrete non-`default` model while version 1 retains optional model semantics.
- Preserves: the existing unversioned rule and inline profile schema as version 1 compatibility input.

- [ ] **Step 1: Write failing policy contract tests.**

```bash
test_v1_stays_valid() {
  write_policy '{"rules":[{"when":"anything","use":{"harness":"codex"}}]}'
  expect_success "$POLICY" validate "$POLICY_FILE"
  expect_output automatic "$POLICY" mode "$POLICY_FILE"
}

test_v2_normalizes_named_profile() {
  write_policy '{"schemaVersion":2,"routing":{"mode":"simulate","limits":{"canary":3,"automatic":6,"burst":8,"perLane":2}},"profiles":{"pi-grok":{"harness":"pi","model":"cliproxyapi/grok-4.6","provider":"xai","lane":"pi-xai-1","reasoningClass":"strong","workTypes":["architecture"]}},"rules":[{"when":"architecture","use":["pi-grok"]}]}'
  expect_success "$POLICY" validate "$POLICY_FILE"
  expect_output simulate "$POLICY" mode "$POLICY_FILE"
  "$POLICY" profile pi-grok "$POLICY_FILE" | jq -e '.harness == "pi" and .lane == "pi-xai-1"'
}

test_v2_rejects_secret_fields() {
  write_policy '{"schemaVersion":2,"routing":{"mode":"automatic"},"profiles":{"bad":{"harness":"pi","provider":"xai","lane":"pi-xai-1","apiKey":"secret"}}}'
  expect_failure_contains 'forbidden credential field: apiKey' "$POLICY" validate "$POLICY_FILE"
}
```

- [ ] **Step 2: Run the focused test and confirm the new command is missing.**

Run: `bin/fm-test-run.sh tests/fm-dispatch-policy.test.sh`

Expected: FAIL because `bin/fm-dispatch-policy.sh` does not exist.

- [ ] **Step 3: Implement the smallest versioned policy reader.**

```bash
#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE=${2:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-$ROOT}/config}/crew-dispatch.json}

policy_validate() {
  jq -e '
    def forbidden: ["apiKey","token","secret","password","cookie","authorization"];
    def secret_paths: [paths(scalars) as $p | select(($p[-1] | tostring) as $k | forbidden | index($k)) | $p[-1]];
    if type != "object" then error("top-level value must be an object")
    elif (secret_paths | length) > 0 then error("forbidden credential field: \(secret_paths[0])")
    elif ((.schemaVersion // 1) | IN(1,2) | not) then error("schemaVersion must be 1 or 2")
    elif ((.routing.mode // "automatic") | IN("off","simulate","canary","automatic") | not) then error("invalid routing mode")
    else . end
  ' "$1" >/dev/null
}

case ${1:-} in
  validate) policy_validate "$FILE" ;;
  mode) policy_validate "$FILE" && jq -r '.routing.mode // "automatic"' "$FILE" ;;
  limits) policy_validate "$FILE" && jq -c '.routing.limits // {canary:3,automatic:6,burst:8,perLane:2}' "$FILE" ;;
  profile) ID=$2; FILE=${3:-$FILE}; policy_validate "$FILE"; jq -ce --arg id "$ID" '.profiles[$id] + {id:$id}' "$FILE" ;;
  describe) policy_validate "$FILE" && jq -c '{schemaVersion:(.schemaVersion // 1),mode:(.routing.mode // "automatic")}' "$FILE" ;;
  *) echo 'usage: fm-dispatch-policy.sh validate|mode|limits|profile|describe ...' >&2; exit 2 ;;
esac
```

Move the existing `verified`, `effort_ok`, profile-shape, harness, effort, and selector checks from `crew_dispatch_validate` into `policy_validate` without changing their accepted version 1 behavior.
Add version 2 checks for the four routing modes, positive integer limits `3`, `6`, `8`, and `2`, breaker integers `3`, `900`, and `1800`, one transient retry, unique non-empty profile identifiers, verified harnesses, non-empty provider and lane identifiers, optional account identifiers matching `^[a-z0-9][a-z0-9-]*$`, reasoning classes `basic`, `standard`, `strong`, or `maximum`, non-empty work-type arrays, valid named profile references, and the forbidden secret-field list shown above.
Require a named account for native Claude and Codex profiles and forbid an account field for Pi and pi-signed profiles.

- [ ] **Step 4: Delegate bootstrap validation and rerun focused tests.**

Run: `bin/fm-test-run.sh tests/fm-dispatch-policy.test.sh tests/fm-bootstrap.test.sh`

Expected: PASS with `FM_TEST_SUMMARY total=2 failed=0`.

- [ ] **Step 5: Commit the policy boundary.**

```bash
git add bin/fm-dispatch-policy.sh bin/fm-bootstrap.sh bin/fm-test-run.sh tests/fm-dispatch-policy.test.sh tests/fm-bootstrap.test.sh
git commit -m "feat: validate versioned dispatch policies"
```

---

### Task 2: Bind Native Subscription Account Lanes

**Files:**

- Create: `bin/fm-account-lane.sh`
- Create: `tests/fm-account-lane.test.sh`
- Modify: `bin/fm-bootstrap.sh`
- Modify: `tests/fm-bootstrap.test.sh`
- Modify: `bin/fm-test-run.sh`

**Interfaces:**

- Consumes: local gitignored `config/crew-accounts.json`.
- Produces: `fm-account-lane.sh validate [FILE]`.
- Produces: `fm-account-lane.sh harness ACCOUNT_ID [FILE]`.
- Produces: `fm-account-lane.sh env-name ACCOUNT_ID [FILE]`.
- Produces: `fm-account-lane.sh config-dir ACCOUNT_ID [FILE]`.
- Allows only `CLAUDE_CONFIG_DIR` for `harness=claude` and `CODEX_HOME` for `harness=codex`.
- Never opens, copies, hashes, logs, or serializes a file inside the selected configuration directory.
- Makes bootstrap report `CREW_ACCOUNTS: invalid config/crew-accounts.json - REASON` while leaving static dispatch available.
- Keeps `crew-accounts.json` home-local so a secondmate must declare its own available native accounts.

- [ ] **Step 1: Write failing account-lane tests.**

```bash
test_valid_native_accounts() {
  mkdir -p "$LAB/claude" "$LAB/codex-1" "$LAB/codex-2"
  write_accounts "$(jq -n --arg root "$LAB" '{version:1,accounts:{"claude-primary":{harness:"claude",envName:"CLAUDE_CONFIG_DIR",configDir:($root+"/claude")},"codex-primary":{harness:"codex",envName:"CODEX_HOME",configDir:($root+"/codex-1")},"codex-secondary":{harness:"codex",envName:"CODEX_HOME",configDir:($root+"/codex-2")}}}')"
  "$ACCOUNTS" validate "$ACCOUNTS_FILE"
  [ "$("$ACCOUNTS" env-name codex-secondary "$ACCOUNTS_FILE")" = CODEX_HOME ] || fail 'wrong Codex environment name'
  [ "$("$ACCOUNTS" config-dir codex-secondary "$ACCOUNTS_FILE")" = "$LAB/codex-2" ] || fail 'wrong Codex configuration directory'
}

test_rejects_arbitrary_environment() {
  mkdir -p "$LAB/bad"
  write_accounts "$(jq -n --arg root "$LAB" '{version:1,accounts:{bad:{harness:"codex",envName:"PATH",configDir:($root+"/bad")}}}')"
  expect_failure_contains 'codex accounts require CODEX_HOME' "$ACCOUNTS" validate "$ACCOUNTS_FILE"
}

test_rejects_credential_material() {
  mkdir -p "$LAB/bad"
  write_accounts "$(jq -n --arg root "$LAB" '{version:1,accounts:{bad:{harness:"claude",envName:"CLAUDE_CONFIG_DIR",configDir:($root+"/bad"),token:"secret"}}}')"
  expect_failure_contains 'forbidden credential field: token' "$ACCOUNTS" validate "$ACCOUNTS_FILE"
}
```

- [ ] **Step 2: Run the focused test and confirm the resolver is missing.**

Run: `bin/fm-test-run.sh tests/fm-account-lane.test.sh`

Expected: FAIL because `bin/fm-account-lane.sh` does not exist.

- [ ] **Step 3: Implement the allowlisted resolver.**

```bash
#!/usr/bin/env bash
set -eu

CONFIG=${FM_CONFIG_OVERRIDE:-${FM_HOME:-$(pwd)}/config}
COMMAND=${1:-}
ACCOUNT=${2:-}
FILE=${3:-$CONFIG/crew-accounts.json}

validate() {
  jq -e '
    def forbidden: ["apiKey","token","secret","password","cookie","authorization"];
    def forbidden_key: [paths(scalars) as $p | ($p[-1]|tostring) as $key | select(forbidden|index($key)) | $key][0] // null;
    if type != "object" or .version != 1 or (.accounts|type) != "object" then error("invalid account-lane schema")
    elif forbidden_key != null then error("forbidden credential field: \(forbidden_key)")
    elif [.accounts|to_entries[]|select(.key|test("^[a-z0-9][a-z0-9-]*$")|not)]|length > 0 then error("invalid account id")
    elif [.accounts[]|select(.harness != "claude" and .harness != "codex")]|length > 0 then error("account harness must be claude or codex")
    elif [.accounts[]|select(.harness == "claude" and .envName != "CLAUDE_CONFIG_DIR")]|length > 0 then error("claude accounts require CLAUDE_CONFIG_DIR")
    elif [.accounts[]|select(.harness == "codex" and .envName != "CODEX_HOME")]|length > 0 then error("codex accounts require CODEX_HOME")
    elif [.accounts[]|select((.configDir|type) != "string" or (.configDir|startswith("/")|not))]|length > 0 then error("configDir must be absolute")
    else . end
  ' "$1" >/dev/null
}

case "$COMMAND" in
  validate) FILE=${2:-$FILE}; validate "$FILE" ;;
  harness|env-name|config-dir)
    validate "$FILE"
    KEY=$(case "$COMMAND" in harness) echo harness ;; env-name) echo envName ;; config-dir) echo configDir ;; esac)
    jq -er --arg id "$ACCOUNT" --arg key "$KEY" '.accounts[$id][$key]' "$FILE"
    ;;
  *) echo 'usage: fm-account-lane.sh validate|harness|env-name|config-dir ...' >&2; exit 2 ;;
esac
```

After schema validation, reject a selected account when `configDir` is not an existing readable directory.
Return only the allowlisted environment variable name and absolute directory path so `fm-spawn.sh` remains the sole owner of shell quoting and process launch construction.

- [ ] **Step 4: Delegate optional account-map validation from bootstrap and run focused tests.**

Run: `bin/fm-test-run.sh tests/fm-account-lane.test.sh tests/fm-bootstrap.test.sh tests/fm-test-run.test.sh`

Expected: PASS with three scripts and zero failures.

- [ ] **Step 5: Commit native account binding.**

```bash
git add bin/fm-account-lane.sh bin/fm-bootstrap.sh bin/fm-test-run.sh tests/fm-account-lane.test.sh tests/fm-bootstrap.test.sh tests/fm-test-run.test.sh
git commit -m "feat: bind native subscription account lanes"
```

---

### Task 3: Build the Pure Routing Selector

**Files:**

- Create: `bin/fm-routing-lib.sh`
- Create: `bin/fm-route.sh`
- Create: `tests/fm-route.test.sh`
- Modify: `bin/fm-test-run.sh`

**Interfaces:**

- Consumes: `fm-route.sh select --request REQUEST.json --candidates CANDIDATES.json [--now EPOCH]`.
- Produces: one JSON object with `action`, `reason`, `selected`, `ranked`, `rejected`, `uncertainty`, and `maxWorkers`.
- Requires request fields: `taskId`, `taskClass`, `workType`, `risk`, `independent`, `requestedWorkers`, `requiredReasoningClass`, and `estimatedSeconds`.
- Requires candidate fields: `profile`, `harness`, `model`, `provider`, `lane`, `account`, `fitTier`, `reasoningClass`, `catalogSupported`, `authState`, `spendPriority`, `runwaySeconds`, `activeLane`, `historySuccesses`, `historyAttempts`, and `costTier`.
- Treats JSON `null` quota, runway, and cost values as disclosed unknowns rather than zero.
- Replaces caller-supplied `activeLane`, `historySuccesses`, and `historyAttempts` with facts read under the routing-state lock before final selection.

- [ ] **Step 1: Write failing ranking and task-budget tests.**

```bash
test_fit_beats_quota() {
  write_request standard implementation medium false 1 strong 7200
  write_candidates '[
    {"profile":"codex-sol","harness":"codex","model":"gpt-5.6-sol","provider":"openai","lane":"codex-primary","account":"codex-primary","fitTier":3,"reasoningClass":"strong","catalogSupported":true,"authState":"usable","spendPriority":-1.0,"runwaySeconds":20000,"activeLane":1,"historySuccesses":0,"historyAttempts":0,"costTier":null},
    {"profile":"pi-flash","harness":"pi","model":"cliproxyapi/gemini-3.7-flash-high","provider":"google","lane":"pi-google-1","account":"none","fitTier":2,"reasoningClass":"standard","catalogSupported":true,"authState":"usable","spendPriority":4.0,"runwaySeconds":50000,"activeLane":0,"historySuccesses":0,"historyAttempts":0,"costTier":null}
  ]'
  "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES" | jq -e '.selected.profile == "codex-sol"'
}

test_unknown_is_disclosed_not_zero() {
  write_request standard implementation low false 1 standard 3600
  write_candidates '[{"profile":"pi-kimi","harness":"pi","model":"cliproxyapi/kimi-k3","provider":"moonshot","lane":"pi-moonshot-1","account":"none","fitTier":3,"reasoningClass":"strong","catalogSupported":true,"authState":"unknown","spendPriority":null,"runwaySeconds":null,"activeLane":0,"historySuccesses":0,"historyAttempts":0,"costTier":null}]'
  "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES" | jq -e '.selected.profile == "pi-kimi" and (.uncertainty | index("pi-kimi:auth,quota,runway"))'
}

test_worker_budget_is_bounded() {
  for row in 'trivial false 4 1' 'standard false 3 1' 'decomposable true 7 4' 'ambiguous true 5 2' 'high_risk true 8 2'; do
    set -- $row
    write_request "$1" implementation medium "$2" "$3" strong 3600
    assert_json_number "$4" "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"
  done
}
```

- [ ] **Step 2: Run the selector tests and confirm they fail at the missing command.**

Run: `bin/fm-test-run.sh tests/fm-route.test.sh`

Expected: FAIL because `bin/fm-route.sh` does not exist.

- [ ] **Step 3: Implement schema validation and lexicographic selection.**

```bash
fm_route_worker_budget() {
  case "$1:$2" in
    trivial:*|standard:*) echo 1 ;;
    decomposable:true) echo 4 ;;
    ambiguous:true|high_risk:true) echo 2 ;;
    *) echo 1 ;;
  esac
}

fm_route_select() {
  local request=$1 candidates=$2
  jq -n --slurpfile req "$request" --slurpfile pool "$candidates" '
    def reason_rank: {basic:1,standard:2,strong:3,maximum:4}[.] // 0;
    def primary_key: [.fitTier, (.spendPriority // -1e100), (-.activeLane)];
    def uncertainty:
      [if .authState == "unknown" then "auth" else empty end,
       if .spendPriority == null then "quota" else empty end,
       if .runwaySeconds == null then "runway" else empty end]
      | if length == 0 then empty else "\(.profile):\(join(","))" end;
    ($req[0]) as $r
    | ($pool[0]
       | map(. + {reasonRank:(.reasoningClass|reason_rank)})
       | map(select(.catalogSupported == true))
       | map(select(.authState != "unusable"))
       | map(select(.reasonRank >= ($r.requiredReasoningClass|reason_rank)))
       | map(select(.runwaySeconds == null or .runwaySeconds >= $r.estimatedSeconds))) as $eligible
    | if ($eligible|length) == 0 then {action:"escalate",reason:"no-qualified-profile"}
      else ($eligible|max_by(primary_key)|primary_key) as $best
      | ($eligible|map(select(primary_key == $best))) as $primary
      | (if ($primary|length) > 1 and ($primary|map(.historyAttempts)|unique|length) == 1
            then ($primary|max_by(.historySuccesses)|.historySuccesses) as $wins
            | $primary|map(select(.historySuccesses == $wins))
          else $primary end) as $history
      | (if ($history|length) > 1 and ($history|all(.costTier != null))
            then ($history|min_by(.costTier)|.costTier) as $cost
            | $history|map(select(.costTier == $cost))
          else $history end) as $finalists
      | if ($finalists|length) != 1
          then {action:"escalate",reason:"evidence-tie",selected:null,ranked:$eligible,rejected:[],uncertainty:[$eligible[]|uncertainty]}
        else {action:"selected",reason:"lexicographic-policy",selected:$finalists[0],ranked:$eligible,rejected:[],uncertainty:[$eligible[]|uncertainty]}
        end
      end
  '
}
```

Do not turn the tuple into a weighted composite score.
Compare raw outcome counts only when the candidates have the same attempt count, which avoids selecting a deferred statistical estimator.
Treat a cost tier as a tie-break only when every remaining candidate has a known cost tier.

- [ ] **Step 4: Run selector tests and the test-runner contract.**

Run: `bin/fm-test-run.sh tests/fm-route.test.sh tests/fm-test-run.test.sh`

Expected: PASS with both scripts reported and zero failures.

- [ ] **Step 5: Commit the pure selector.**

```bash
git add bin/fm-route.sh bin/fm-routing-lib.sh bin/fm-test-run.sh tests/fm-route.test.sh tests/fm-test-run.test.sh
git commit -m "feat: select subscription routing profiles"
```

---

### Task 4: Add Capacity Reservations, Circuit Breakers, and the Outcome Ledger

**Files:**

- Modify: `bin/fm-routing-lib.sh`
- Modify: `bin/fm-route.sh`
- Modify: `tests/fm-route.test.sh`

**Interfaces:**

- Produces: `fm-route.sh reserve --task ID --generation GENERATION --profile ID --provider NAME --lane NAME --account ACCOUNT_ID|none --class CLASS --work-type TYPE --risk RISK --mode MODE --request REQUEST.json --candidates CANDIDATES.json --decision DECISION.json [--burst]`; reservation re-runs the captured selection against authoritative load and the active version 2 policy under the routing lock and persists the policy-derived launch harness/model/effort binding.
- Produces: `fm-route.sh verify-reservation --task ID --generation GENERATION --profile ID --provider NAME --lane NAME --account ACCOUNT_ID|none --class CLASS --work-type TYPE --risk RISK --mode MODE`.
- Produces: migration-only `fm-route.sh reservation-work-type` for an exact legacy eight-field tuple; returns the authoritative type from its strict reservation or exact terminal outcome.
- Produces: `fm-route.sh release --task ID --generation GENERATION`.
- Produces: `fm-route.sh failure --task ID --generation GENERATION --provider NAME --lane NAME --kind transient|quota|auth|model|unsafe --now EPOCH`.
- Produces: `fm-route.sh score --task ID --generation GENERATION --terminal completed|failed_safe|escalated|cancelled|superseded --tests pass|fail|unknown --review pass|fail|unknown --redundant yes|no --now EPOCH`.
- Produces: `fm-route.sh finalize --task ID --generation GENERATION --terminal completed|failed_safe|escalated|cancelled|superseded`.
- Produces: `fm-route.sh observe --request REQUEST.json --decision DECISION.json --now EPOCH` for a simulation record that launches and reserves nothing.
- Produces: `fm-route.sh evidence --work-type TYPE` with raw per-profile success and attempt counts only.
- Produces: `fm-route.sh status` with mode, caps, active totals, and open circuits.
- Produces: `fm-route.sh report --stage simulation|canary --minimum COUNT` with deterministic gate counts and median elapsed time.
- Owns: `$FM_STATE_OVERRIDE/routing/reservations/`, `circuits.json`, `outcomes.jsonl`, and `.lock`.
- Returns failure action JSON as `retry`, `fallback`, `circuit-open`, or `escalate`.

- [ ] **Step 1: Write failing state-machine tests.**

```bash
test_canary_cap_is_atomic() {
  seed_policy_mode canary
  reserve_ok task-1 codex-1
  reserve_ok task-2 claude-1
  reserve_ok task-3 pi-google-1
  expect_failure_contains 'global-cap:3' "$ROUTE" reserve --task task-4 --generation gen-4 --profile pi-glm --provider zai --lane pi-zai-1 --account none --class decomposable --work-type implementation --risk low --mode canary
}

test_lane_cap_is_two() {
  reserve_ok task-1 pi-xai-1
  reserve_ok task-2 pi-xai-1
  expect_failure_contains 'lane-cap:2' "$ROUTE" reserve --task task-3 --generation gen-3 --profile pi-grok --provider xai --lane pi-xai-1 --account none --class standard --work-type implementation --risk low --mode automatic
}

test_third_failure_opens_breaker() {
  for task in fail-1 fail-2; do record_failure "$task" quota 1000; done
  "$ROUTE" failure --task fail-3 --generation gen-3 --provider xai --lane pi-xai-1 --kind quota --now 1000 | jq -e '.action == "circuit-open" and .until == 2800'
  expect_failure_contains 'circuit-open' "$ROUTE" reserve --task task-4 --generation gen-4 --profile pi-grok --provider xai --lane pi-xai-1 --account none --class standard --work-type implementation --risk low --mode automatic --now 1001
}

test_ledger_rejects_private_payload_fields() {
  expect_failure_contains 'forbidden outcome field: prompt' "$ROUTE" score --task task-1 --generation gen-1 --terminal completed --tests pass --review pass --redundant no --extra-json '{"prompt":"secret"}'
}
```

- [ ] **Step 2: Run the focused tests and confirm the missing state behavior fails.**

Run: `bin/fm-test-run.sh tests/fm-route.test.sh`

Expected: FAIL on the first missing `reserve` behavior.

- [ ] **Step 3: Implement locked reservations and bounded JSONL outcomes.**

```bash
fm_routing_with_lock() {
  local lock="$FM_ROUTE_STATE/.lock"
  fm_lock_acquire_wait "$lock"
  local rc
  if "$@"; then rc=0; else rc=$?; fi
  fm_lock_release "$lock"
  return "$rc"
}

fm_routing_failure_action() {
  case "$1" in
    transient) [ "$2" -lt 1 ] && echo retry || echo fallback ;;
    quota|auth|model) echo fallback ;;
    unsafe) echo escalate ;;
  esac
}

fm_routing_rotate_ledger() {
  local file=$1 max_lines=2000 keep_lines=1500
  rm -f -- "$file.next"
  [ "$(wc -l < "$file")" -le "$max_lines" ] || tail -n "$keep_lines" "$file" > "$file.next"
  [ ! -f "$file.next" ] || mv -f "$file.next" "$file"
}
```

Source `fm-wake-lib.sh` and use its existing `fm_lock_acquire_wait` and `fm_lock_release` functions rather than creating another lock implementation.
Publish reservation and circuit files through same-directory temporary files followed by `mv`.
Make duplicate `reserve`, `release`, and `score` calls idempotent for the same task and route generation.
Hydrate active-lane and raw history facts while holding the same lock used for reservations so a stale caller value cannot influence ranking.
Write simulation observations through `observe` without creating a reservation or active-task record.

- [ ] **Step 4: Run state tests twice to prove idempotence.**

Run: `bin/fm-test-run.sh tests/fm-route.test.sh && bin/fm-test-run.sh tests/fm-route.test.sh`

Expected: both runs PASS with no leftover reservation changing the second run.

- [ ] **Step 5: Commit routing state.**

```bash
git add bin/fm-route.sh bin/fm-routing-lib.sh tests/fm-route.test.sh
git commit -m "feat: bound routing capacity and failures"
```

---

### Task 5: Enforce Routed Launch Admission and Account Binding

**Files:**

- Modify: `bin/fm-spawn.sh:130-175,820-930,2624-2695`
- Modify: `tests/fm-spawn-dispatch-profile.test.sh`
- Modify: `bin/fm-routing-lib.sh`
- Modify: `tests/fm-route.test.sh`

**Interfaces:**

- Consumes new spawn flags: `--route-generation`, `--route-profile`, `--route-provider`, `--route-lane`, `--route-account`, `--route-class`, `--route-work-type`, `--route-risk`, and `--route-mode`.
- Requires a matching reservation before a routed launch can publish task metadata.
- Adds task metadata fields: `route_generation`, `route_profile`, `route_provider`, `route_lane`, `route_account`, `route_class`, `route_work_type`, `route_risk`, and `route_mode`.
- Resolves native account IDs through `fm-account-lane.sh` and binds only the allowlisted configuration environment variable for that launch.
- Leaves static launches byte-compatible when no route flags are supplied or routing mode is `off`.
- Upgrades legacy eight-field routed metadata only by resolving the missing work type from the exact strictly validated reservation; never default or guess it.

- [ ] **Step 1: Write failing spawn admission tests.**

```bash
test_routed_spawn_requires_matching_reservation() {
  enable_dispatch_profile "$HOME_DIR"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR" --harness pi --model cliproxyapi/kimi-k3 --route-generation gen-1 --route-profile pi-kimi --route-provider moonshot --route-lane pi-moonshot-1 --route-account none --route-class standard --route-work-type implementation --route-risk medium --route-mode automatic)
  expect_code 1 "$?" 'unreserved routed spawn must fail'
  assert_contains "$out" 'matching routing reservation is required' 'spawn bypassed route admission'
}

test_routed_spawn_records_exact_route() {
  reserve_route "$HOME_DIR" "$ID" gen-1 pi-kimi moonshot pi-moonshot-1 standard medium automatic
  run_routed_spawn
  assert_grep 'route_generation=gen-1' "$HOME_DIR/state/$ID.meta" 'missing route generation'
  assert_grep 'route_lane=pi-moonshot-1' "$HOME_DIR/state/$ID.meta" 'missing route lane'
}

test_launch_failure_releases_reservation() {
  reserve_route "$HOME_DIR" "$ID" gen-1 pi-kimi moonshot pi-moonshot-1 standard medium automatic
  FM_FAKE_TMUX_FAIL=1 run_routed_spawn || true
  [ ! -e "$HOME_DIR/state/routing/reservations/$ID.json" ] || fail 'failed launch leaked capacity'
}

test_codex_secondary_binds_only_codex_home() {
  make_account_map "$HOME_DIR" codex-secondary CODEX_HOME "$HOME_DIR/codex-2"
  reserve_native_route "$HOME_DIR" "$ID" gen-1 codex-sol openai codex-secondary codex-secondary standard medium automatic
  run_routed_codex_spawn
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "env CODEX_HOME='$HOME_DIR/codex-2'" 'Codex secondary account was not selected'
  assert_not_contains "$launch" 'CLAUDE_CONFIG_DIR=' 'Codex launch received a Claude credential path'
}
```

- [ ] **Step 2: Run the focused spawn tests and confirm admission is not enforced.**

Run: `bin/fm-test-run.sh tests/fm-spawn-dispatch-profile.test.sh`

Expected: FAIL because route flags are not recognized.

- [ ] **Step 3: Add route flag parsing and reservation validation.**

```bash
route_args_complete() {
  [ -n "$ROUTE_GENERATION" ] && [ -n "$ROUTE_PROFILE" ] && [ -n "$ROUTE_PROVIDER" ] \
    && [ -n "$ROUTE_LANE" ] && [ -n "$ROUTE_ACCOUNT" ] && [ -n "$ROUTE_CLASS" ] && [ -n "$ROUTE_WORK_TYPE" ] && [ -n "$ROUTE_RISK" ] && [ -n "$ROUTE_MODE" ]
}

route_args_present() {
  [ -n "$ROUTE_GENERATION$ROUTE_PROFILE$ROUTE_PROVIDER$ROUTE_LANE$ROUTE_ACCOUNT$ROUTE_CLASS$ROUTE_WORK_TYPE$ROUTE_RISK$ROUTE_MODE" ]
}

if route_args_complete; then
  "$SCRIPT_DIR/fm-route.sh" verify-reservation \
    --task "$ID" --generation "$ROUTE_GENERATION" --profile "$ROUTE_PROFILE" \
    --provider "$ROUTE_PROVIDER" --lane "$ROUTE_LANE" --class "$ROUTE_CLASS" \
    --account "$ROUTE_ACCOUNT" --work-type "$ROUTE_WORK_TYPE" --risk "$ROUTE_RISK" --mode "$ROUTE_MODE"
elif route_args_present; then
  echo 'error: routed spawn requires the complete route metadata tuple' >&2
  exit 2
fi
```

Add the route fields to `preserve_relaunch_meta` so a relaunch keeps the original route generation unless the caller provides a newly reserved generation.
Call `fm-route.sh release` from `spawn_abort_cleanup` only for a reservation owned by this exact route generation.
For native Claude and Codex routes, resolve the account's harness, environment name, and configuration directory and refuse a harness mismatch before constructing the launch command.
For Pi and pi-signed routes, require `route_account=none` because provider subscriptions remain owned by the existing Pi and CLIProxyAPI configuration.

- [ ] **Step 4: Run spawn, routing, and relaunch tests.**

Run: `bin/fm-test-run.sh tests/fm-spawn-dispatch-profile.test.sh tests/fm-route.test.sh tests/fm-control-relaunch.test.sh`

Expected: PASS with three scripts and zero failures.

- [ ] **Step 5: Commit launch admission.**

```bash
git add bin/fm-spawn.sh bin/fm-account-lane.sh bin/fm-routing-lib.sh tests/fm-spawn-dispatch-profile.test.sh tests/fm-route.test.sh tests/fm-account-lane.test.sh
git commit -m "feat: enforce routed launch accounts"
```

---

### Task 6: Finalize Outcomes During Safe Cleanup

**Files:**

- Modify: `bin/fm-teardown.sh:218-450,1880-end`
- Modify: `tests/fm-teardown.test.sh`
- Modify: `bin/fm-route.sh`
- Modify: `bin/fm-routing-lib.sh`
- Modify: `tests/fm-route.test.sh`

**Interfaces:**

- Consumes the complete route fields already recorded in task metadata, including authoritative `route_work_type`.
- Consumes an optional prior `fm-route.sh score` record for tests, review, and redundant-output facts.
- Produces exactly one terminal outcome and releases exactly one reservation after cleanup is confirmed.
- Preserves the reservation when teardown refuses or exits before durable task cleanup.
- Accepts legacy eight-field routed metadata only when its exact reservation authoritatively supplies the missing work type.

- [ ] **Step 1: Write failing cleanup and scoring tests.**

```bash
test_refused_teardown_keeps_route_reservation() {
  make_routed_task routed-dirty
  dirty_worktree routed-dirty
  expect_failure "$TEARDOWN" routed-dirty
  [ -f "$STATE/routing/reservations/routed-dirty.json" ] || fail 'refused cleanup released live capacity'
}

test_successful_teardown_records_once_and_releases() {
  make_landed_routed_task routed-done
  "$ROUTE" score --task routed-done --generation gen-routed-done --terminal completed --tests pass --review pass --redundant no --now 1000
  "$TEARDOWN" routed-done
  [ ! -e "$STATE/routing/reservations/routed-done.json" ] || fail 'cleanup leaked reservation'
  [ "$(jq -s '[.[] | select(.taskId == "routed-done")] | length' "$STATE/routing/outcomes.jsonl")" -eq 1 ] || fail 'cleanup duplicated outcome'
}
```

- [ ] **Step 2: Run teardown tests and confirm routed cleanup behavior is missing.**

Run: `bin/fm-test-run.sh tests/fm-teardown.test.sh`

Expected: FAIL on the retained or released reservation assertion.

- [ ] **Step 3: Add a terminal finalization call after all existing safety checks.**

```bash
finalize_routed_task() {
  local meta=$1 id=$2 generation
  generation=$(fm_meta_get "$meta" route_generation)
  [ -n "$generation" ] || return 0
  "$SCRIPT_DIR/fm-route.sh" finalize --task "$id" --generation "$generation" --terminal completed
}
```

Call this function immediately before task metadata removal and only after endpoint closure and worktree return are confirmed.
Make `finalize` atomically append any pending score fields, mark the generation finalized, and release its reservation.
Do not infer `tests=pass` or `review=pass` from teardown success.

- [ ] **Step 4: Run cleanup, routing, and metadata tests.**

Run: `bin/fm-test-run.sh tests/fm-teardown.test.sh tests/fm-route.test.sh tests/fm-spawn-dispatch-profile.test.sh`

Expected: PASS with all terminal outcomes appearing once.

- [ ] **Step 5: Commit terminal accounting.**

```bash
git add bin/fm-teardown.sh bin/fm-route.sh bin/fm-routing-lib.sh tests/fm-teardown.test.sh tests/fm-route.test.sh
git commit -m "feat: finalize routed task outcomes"
```

---

### Task 7: Add the Automatic Dispatch Agent Procedure

**Files:**

- Create: `.agents/skills/automatic-dispatch/SKILL.md`
- Modify: `.agents/skills/quota-array-dispatch/SKILL.md`
- Modify: `AGENTS.md:Harness and runtime dispatch,Agent-only reference skills`
- Create: `tests/fm-automatic-dispatch-contract.test.sh`
- Modify: `bin/fm-test-run.sh`

**Interfaces:**

- Consumes: one authorized task, `config/crew-dispatch.json`, current installed catalogs, one quota-axi snapshot, active route state, and the repository delivery posture.
- Produces: the normalized request and candidate JSON accepted by `fm-route.sh select`.
- Produces: one or more existing `fm-spawn.sh` calls only after successful reservations, carrying `--route-work-type` in every complete routed tuple.
- Preserves: `quota-array-dispatch` as the single owner of quota evidence interpretation.

- [ ] **Step 1: Write failing contract checks for the new skill trigger and safety text.**

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_grep 'automatic-dispatch' "$ROOT/AGENTS.md" 'AGENTS does not load the routing procedure'
assert_grep 'taskClass' "$ROOT/.agents/skills/automatic-dispatch/SKILL.md" 'skill does not define classification output'
assert_grep 'independent reviewer from a different provider' "$ROOT/.agents/skills/automatic-dispatch/SKILL.md" 'high-risk review rule is missing'
assert_grep 'never include prompts, source code, credentials' "$ROOT/.agents/skills/automatic-dispatch/SKILL.md" 'privacy boundary is missing'
```

- [ ] **Step 2: Run the documentation contract and confirm the missing skill fails.**

Run: `bin/fm-test-run.sh tests/fm-automatic-dispatch-contract.test.sh`

Expected: FAIL because the new skill and trigger do not exist.

- [ ] **Step 3: Write the conditional procedure with one owner per decision.**

```markdown
## Intake sequence

1. Confirm the task's existing authority and delivery posture before routing.
2. Classify it as `trivial`, `standard`, `decomposable`, `ambiguous`, or `high_risk`.
3. Name only subtasks that can progress independently without conflicting writes.
4. Resolve the matching policy rule and every candidate profile.
5. Resolve every native profile's symbolic account through `fm-account-lane.sh` without inspecting credential contents.
6. Use each runtime's authoritative catalog to establish model support and provider family.
7. Load `quota-array-dispatch` once to interpret the single quota-axi snapshot.
8. Build normalized request and candidate files without prompt, code, credential, or raw-output fields.
9. Run `fm-route.sh select` and show the exact fit, capacity, load, uncertainty, and tie evidence.
10. In simulation mode, call `fm-route.sh observe` for the proposed route and launch nothing.
11. In canary or automatic mode, reserve each approved independent slot before calling `fm-spawn.sh` with the complete route tuple.
12. Retry one proven transient once, fall back on quota, authentication, or model unavailability, and stop immediately on unsafe or uncertain writes.
13. Stop spawning when acceptance criteria are covered or remaining work is dependent, redundant, quota-bound, or host-bound.

The normalized routing files and ledger must never include prompts, source code, credentials, cookies, token values, or raw tool output.
```

Move conditional routing detail out of `AGENTS.md` and leave only the trigger plus unconditional safety facts.
Remove any old instruction that requires an agent to perform arbitrary tie-breaking outside `fm-route.sh`.
Keep catalog and quota interpretation in their current authoritative skills through cross-references rather than copying them.
Require one visible policy diagnostic followed by static dispatch when version 2 validation fails, with no optimization state mutation.
Treat a native profile whose symbolic account is absent from this home as ineligible, and continue evaluating qualified Pi or other local profiles before static fallback.

- [ ] **Step 4: Run the focused contract and diff checks.**

Run: `bin/fm-test-run.sh tests/fm-automatic-dispatch-contract.test.sh && git diff --check`

Expected: both commands PASS before the complete prose inventory is updated in Task 8.

- [ ] **Step 5: Commit the routing procedure.**

```bash
git add AGENTS.md .agents/skills/automatic-dispatch/SKILL.md .agents/skills/quota-array-dispatch/SKILL.md bin/fm-test-run.sh tests/fm-automatic-dispatch-contract.test.sh
git commit -m "docs: define automatic dispatch procedure"
```

---

### Task 8: Document and Ship the Version 2 Subscription Policy

**Files:**

- Modify: `docs/configuration.md:250-315`
- Modify: `docs/architecture.md`
- Modify: `docs/examples/crew-dispatch.json`
- Create: `docs/examples/crew-accounts.json`
- Create: `docs/verification/automatic-dispatch.md`
- Modify: `docs/documentation-audiences.json`
- Modify: `tests/fm-documentation-audiences.test.sh`

**Interfaces:**

- Owns the complete version 2 operator schema and rollback command.
- Provides profile identifiers consumed by Task 1 and the private coding-server policy in Task 10.
- Classifies the new design, plan, skill, and verification surfaces in one inventory.

- [ ] **Step 1: Write the exact version 2 example and make the audience test fail on it.**

```json
{
  "schemaVersion": 2,
  "routing": {
    "mode": "simulate",
    "limits": { "canary": 3, "automatic": 6, "burst": 8, "perLane": 2 },
    "circuitBreaker": { "failures": 3, "windowSeconds": 900, "cooldownSeconds": 1800 },
    "transientRetries": 1
  },
  "profiles": {
    "codex-sol": { "harness": "codex", "model": "gpt-5.6-sol", "effort": "high", "provider": "openai", "lane": "codex-primary", "account": "codex-primary", "reasoningClass": "strong", "workTypes": ["implementation", "architecture", "debugging", "security"] },
    "codex-sol-secondary": { "harness": "codex", "model": "gpt-5.6-sol", "effort": "high", "provider": "openai", "lane": "codex-secondary", "account": "codex-secondary", "reasoningClass": "strong", "workTypes": ["implementation", "architecture", "debugging", "security"] },
    "codex-luna": { "harness": "codex", "model": "gpt-5.6-luna", "effort": "low", "provider": "openai", "lane": "codex-primary", "account": "codex-primary", "reasoningClass": "standard", "workTypes": ["mechanical", "implementation"] },
    "claude-strong": { "harness": "claude", "model": "sonnet", "effort": "high", "provider": "anthropic", "lane": "claude-primary", "account": "claude-primary", "reasoningClass": "strong", "workTypes": ["implementation", "architecture", "debugging", "security"] },
    "pi-gemini-fast": { "harness": "pi", "model": "cliproxyapi/gemini-3.7-flash-high", "effort": "low", "provider": "google", "lane": "pi-google", "reasoningClass": "standard", "workTypes": ["mechanical", "implementation"] },
    "pi-glm": { "harness": "pi", "model": "zai/glm-5.3", "effort": "medium", "provider": "zai", "lane": "pi-zai", "reasoningClass": "strong", "workTypes": ["mechanical", "implementation", "debugging"] },
    "pi-kimi": { "harness": "pi", "model": "cliproxyapi/kimi-k3", "effort": "high", "provider": "moonshot", "lane": "pi-moonshot", "reasoningClass": "strong", "workTypes": ["implementation", "architecture", "debugging"] },
    "pi-grok": { "harness": "pi", "model": "cliproxyapi/grok-4.6", "effort": "high", "provider": "xai", "lane": "pi-xai", "reasoningClass": "strong", "workTypes": ["architecture", "debugging", "review"] }
  },
  "rules": [
    { "when": "trivial mechanical work", "use": ["pi-gemini-fast", "pi-glm", "codex-luna"] },
    { "when": "general implementation", "use": ["codex-sol", "codex-sol-secondary", "pi-kimi", "pi-glm", "claude-strong"] },
    { "when": "architecture or difficult debugging", "use": ["claude-strong", "codex-sol", "codex-sol-secondary", "pi-grok", "pi-kimi"] },
    { "when": "security or production work", "use": ["claude-strong", "codex-sol", "codex-sol-secondary", "pi-grok"] }
  ],
  "default": ["codex-sol", "codex-sol-secondary", "pi-kimi", "pi-glm", "claude-strong"]
}
```

Write `docs/examples/crew-accounts.json` with the following path-only mapping.

```json
{
  "version": 1,
  "accounts": {
    "claude-primary": { "harness": "claude", "envName": "CLAUDE_CONFIG_DIR", "configDir": "/home/yaro/.claude" },
    "codex-primary": { "harness": "codex", "envName": "CODEX_HOME", "configDir": "/home/yaro/.codex" },
    "codex-secondary": { "harness": "codex", "envName": "CODEX_HOME", "configDir": "/home/yaro/.codex2" }
  }
}
```

- [ ] **Step 2: Run policy, documentation, and local-link checks and confirm the incomplete docs fail.**

Run: `bin/fm-test-run.sh tests/fm-dispatch-policy.test.sh tests/fm-documentation-audiences.test.sh && bin/fm-doc-audience-check.sh`

Expected: FAIL until the schema owner, new surfaces, and inventory entries are complete.

- [ ] **Step 3: Document current behavior, state, and rollback.**

```markdown
### Immediate rollback

Set `.routing.mode` to `off` in `config/crew-dispatch.json` and run `bin/fm-bootstrap.sh`.
New work then uses the existing static dispatch fallback.
Active workers keep their recorded route and are not interrupted.
No outcome or reservation file grants write, merge, destructive, or production authority.
```

Document the exact schema once in `docs/configuration.md`.
Document `crew-accounts.json` as home-local and non-inherited because account paths and authentication stores are host-specific.
Use one-line cross-references from `docs/architecture.md`, the skill, and script headers.
Classify `.agents/skills/automatic-dispatch/SKILL.md` as `agent-runtime` and `docs/verification/automatic-dispatch.md` as `maintainer-verification`.
Classify both `docs/superpowers` documents as `maintainer-architecture` unless the repository adopts a separate task-evidence exclusion before this task lands.
Also classify the four older currently unclassified `docs/superpowers` documents so the complete inventory check returns clean.

- [ ] **Step 4: Run all documentation and policy checks.**

Run: `bin/fm-doc-audience-check.sh && bin/fm-test-run.sh tests/fm-dispatch-policy.test.sh tests/fm-documentation-audiences.test.sh`

Expected: PASS with no unclassified prose and zero failed tests.

- [ ] **Step 5: Commit the operator contract.**

```bash
git add docs/configuration.md docs/architecture.md docs/examples/crew-dispatch.json docs/examples/crew-accounts.json docs/verification/automatic-dispatch.md docs/documentation-audiences.json tests/fm-documentation-audiences.test.sh
git commit -m "docs: configure subscription-first dispatch"
```

---

### Task 9: Verify Failure Recovery and Rollback End to End

**Files:**

- Modify: `tests/fm-route.test.sh`
- Modify: `tests/fm-spawn-dispatch-profile.test.sh`
- Modify: `tests/fm-teardown.test.sh`
- Create: `tests/fm-automatic-dispatch-live-e2e.test.sh`
- Modify: `bin/fm-test-run.sh`
- Modify: `docs/verification/automatic-dispatch.md`

**Interfaces:**

- Adds `FM_AUTOMATIC_DISPATCH_LIVE_E2E=1` as the explicit opt-in for non-mutating real catalog and quota verification.
- Produces a live report that names every installed runtime, exact version, catalog result, quota-axi version, and route decision without launching a worker.
- Proves rollback by selecting static behavior when mode is `off`.

- [ ] **Step 1: Add failing recovery and live-guard cases.**

```bash
test_restart_does_not_duplicate_reservation() {
  reserve_generation task-1 gen-1
  reserve_generation task-1 gen-1
  assert_reservation_count 1
}

test_stale_generation_cannot_release_new_capacity() {
  reserve_generation task-1 gen-2
  expect_failure "$ROUTE" release --task task-1 --generation gen-1
  assert_generation task-1 gen-2
}

test_off_mode_uses_static_dispatch() {
  seed_policy_mode off
  expect_json '.action == "static"' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"
}
```

- [ ] **Step 2: Run the recovery tests and confirm the new cases fail.**

Run: `bin/fm-test-run.sh tests/fm-route.test.sh tests/fm-spawn-dispatch-profile.test.sh tests/fm-teardown.test.sh`

Expected: FAIL on restart, stale-generation, or off-mode behavior before the fixes.

- [ ] **Step 3: Implement only the recovery behavior required by the failing tests.**

```bash
fm_route_generation_matches() {
  local reservation=$1 generation=$2
  [ -f "$reservation" ] && [ "$(jq -r '.generation' "$reservation")" = "$generation" ]
}

fm_route_static_result() {
  jq -n '{action:"static",reason:"routing-mode-off",selected:null,ranked:[],rejected:[],uncertainty:[],maxWorkers:1}'
}
```

The live guard must call only `--version`, authoritative model-list commands, quota-axi read commands, and `fm-route.sh select` in simulation mode.
The live guard must never call `fm-spawn.sh`, modify repositories, or print credential details.

- [ ] **Step 4: Run the full portable verification stack.**

Run: `bin/fm-lint.sh`

Expected: PASS with pinned ShellCheck and actionlint versions.

Run: `bin/fm-test-run.sh --check-coverage`

Expected: PASS with every test mapped exactly once to the complete inventory.

Run: `bin/fm-test-run.sh --proven-isolated --jobs 4`

Expected: PASS with zero failed tests.

Run: `bin/fm-test-run.sh --lane portable-serial`

Expected: PASS with zero failed tests.

Run: `FM_AUTOMATIC_DISPATCH_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-automatic-dispatch-live-e2e.test.sh`

Expected: PASS after checking at least native Claude, native Codex, Pi, the configured Pi model aliases, and quota-axi without launching work.

- [ ] **Step 5: Record verification evidence and commit.**

```bash
git add bin/fm-route.sh bin/fm-routing-lib.sh bin/fm-test-run.sh tests/fm-route.test.sh tests/fm-spawn-dispatch-profile.test.sh tests/fm-teardown.test.sh tests/fm-automatic-dispatch-live-e2e.test.sh docs/verification/automatic-dispatch.md
git commit -m "test: verify automatic dispatch recovery"
```

---

### Task 10: Install the Policy and Run the Staged Coding-Server Rollout

**Files:**

- Modify locally after the tracked change lands: `/home/yaro/work/firstmate/config/crew-dispatch.json`
- Create locally after the tracked change lands: `/home/yaro/work/firstmate/config/crew-accounts.json`
- Create locally through the runtime: `/home/yaro/work/firstmate/state/routing/`
- Record evidence in the implementation task report and then refresh `docs/verification/automatic-dispatch.md` through the normal PR path.

**Interfaces:**

- Consumes the exact version 2 example from Task 8 after confirming every model through the live catalog.
- Produces simulation, canary, automatic, and rollback reports from `fm-route.sh`.
- Does not store authentication material in the policy or report.

- [ ] **Step 1: Install and verify the quota dependency without changing dispatch.**

Run: `npm install -g quota-axi`

Run: `quota-axi --version && /home/yaro/work/firstmate/bin/fm-bootstrap.sh`

Expected: quota-axi is at least `0.1.29`, and bootstrap emits no quota compatibility diagnostic.

- [ ] **Step 2: Validate live model identifiers before copying the policy.**

Run: `pi --list-models | grep -E '^(cliproxyapi|zai)[[:space:]]+(gemini-3\.7-flash-high|grok-4\.6|kimi-k3|glm-5\.3)[[:space:]]'`

Expected: four lines proving `cliproxyapi/gemini-3.7-flash-high`, `cliproxyapi/grok-4.6`, `cliproxyapi/kimi-k3`, and `zai/glm-5.3`.

Run: `jq -r '.models[]?.slug // .models[]?.id // empty' /home/yaro/.codex/models_cache.json | grep -E '^gpt-5\.6-(sol|luna)$'`

Expected: `gpt-5.6-sol` and `gpt-5.6-luna`.

- [ ] **Step 3: Install the private account map without reading credential contents.**

Copy the exact Task 8 account map to `/home/yaro/work/firstmate/config/crew-accounts.json`.

Run: `/home/yaro/work/firstmate/bin/fm-account-lane.sh validate /home/yaro/work/firstmate/config/crew-accounts.json`

Expected: exit 0 after confirming `/home/yaro/.claude`, `/home/yaro/.codex`, and `/home/yaro/.codex2` are readable directories.

- [ ] **Step 4: Install the private policy in simulation mode and validate it.**

Copy the exact Task 8 policy to `/home/yaro/work/firstmate/config/crew-dispatch.json` with `.routing.mode` left as `simulate`.

Run: `/home/yaro/work/firstmate/bin/fm-dispatch-policy.sh validate /home/yaro/work/firstmate/config/crew-dispatch.json`

Expected: exit 0 and no credential fields in the file.

- [ ] **Step 5: Complete the twenty-task simulation gate.**

Run after at least twenty completed representative tasks: `/home/yaro/work/firstmate/bin/fm-route.sh report --stage simulation --minimum 20`

Expected: at least twenty observations, zero authority or safety misclassifications, zero needless multiworker trivial routes, and every selected profile resolved in the current catalogs.

- [ ] **Step 6: Complete the ten-task canary gate.**

Change only `.routing.mode` from `simulate` to `canary` and revalidate the policy.

Run after ten eligible low- or medium-risk tasks: `/home/yaro/work/firstmate/bin/fm-route.sh report --stage canary --minimum 10`

Expected: zero lost tasks, zero duplicate or unauthorized writes, no routing regression, correct fallback and circuit events, and improved median eligible-task cycle time.

- [ ] **Step 7: Enable automatic mode at the approved default cap.**

Change only `.routing.mode` from `canary` to `automatic` and revalidate the policy.

Run: `/home/yaro/work/firstmate/bin/fm-route.sh status`

Expected: mode `automatic`, global cap `6`, burst cap `8`, per-lane cap `2`, failure window `900`, and cooldown `1800`.

- [ ] **Step 8: Perform the rollback drill.**

Change only `.routing.mode` from `automatic` to `off` and run one simulation selection.

Expected: `action="static"`, no new reservation, and existing active workers remain untouched.

Restore `.routing.mode` to `automatic` only after the rollback evidence is recorded.

- [ ] **Step 9: Commit the dated rollout evidence through a follow-up PR.**

```bash
git add docs/verification/automatic-dispatch.md
git commit -m "docs: record automatic dispatch rollout"
```

---

## Specification Coverage

- Tasks 1 and 8 cover the versioned local policy, aliases, profile pools, mode switch, validation, static fallback, and operator documentation.
- Tasks 2 and 5 cover actual native account selection without exposing credentials.
- Tasks 3 and 7 cover structured task classification, decomposition, live catalog evidence, explainable lexicographic ranking, and anti-overengineering rules.
- Tasks 4 through 6 cover atomic capacity, per-lane load, bounded retries, fallback, circuit breakers, outcome records, interruption recovery, and terminal cleanup.
- Task 9 covers unit, integration, concurrency, privacy, non-mutating live smoke, rollback, and complete portable regression evidence.
- Task 10 covers the approved twenty-task simulation, ten-task canary, six-worker automatic mode, measured eight-worker burst ceiling, and rollback drill.
- The deferred statistical estimator and all Agy, OpenHands, OpenClaw, and Hermes adapters remain outside Phase 1 exactly as specified.

---

## Final Review Checklist

- [ ] Every version 1 dispatch policy behavior remains covered and passing.
- [ ] Every version 2 schema field has one documented owner and executable validation.
- [ ] Native Claude and Codex profiles bind the selected symbolic account without logging or copying credential contents.
- [ ] Pi provider lanes continue to use Pi and CLIProxyAPI authentication without a fake native account binding.
- [ ] Task classification remains judgment-based and schema-constrained.
- [ ] Deterministic shell performs no model-to-provider or credential inference.
- [ ] Selection is lexicographic and inspectable rather than a hidden weighted score.
- [ ] Genuine ties escalate instead of selecting by array order.
- [ ] Simulation launches nothing.
- [ ] Canary, automatic, burst, and per-lane caps are enforced atomically.
- [ ] High-risk work cannot lose its different-provider review requirement during fallback.
- [ ] Only proven transient failures retry, and only once.
- [ ] Unsafe or uncertain writes never retry automatically.
- [ ] Circuit breakers open at three failures in fifteen minutes and cool down for thirty minutes.
- [ ] Failed launches release only their own reservation generation.
- [ ] Refused cleanup preserves route ownership and successful cleanup finalizes once.
- [ ] Outcome records contain no prompt, source, credential, cookie, token, or raw-output field.
- [ ] Static dispatch works immediately when routing mode is off or the policy is invalid.
- [ ] The full prose inventory, lint, coverage map, portable tests, live non-mutating smoke, and rollback drill pass before automatic mode.
- [ ] Phase 2 specialist adapters are absent from the Phase 1 diff.
