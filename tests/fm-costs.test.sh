#!/usr/bin/env bash
# Behavior tests for the local, read-only Pi AI usage report.
# Covers the clean baseline; direct and subagent usage; responseModel preference;
# structured origin/index fork deduplication; reused-path and first-user-only task
# attribution; the separate primary and unattributed buckets; omitted other-home
# subtotals; malformed final lines; missing headers; missing/corrupt model stores;
# known stored cost without model metadata; unknown cost propagation; the exact
# list-price caveat; default $HOME scanning; TOON/JSON key-value parity; transcript
# non-disclosure; and no-write/no-network behavior. Every transcript is synthetic.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COSTS="$ROOT/bin/fm-costs.sh"
TMP_ROOT=$(fm_test_tmproot fm-costs)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

new_fixture() {  # <name>
  local base="$TMP_ROOT/$1"
  mkdir -p "$base/home" "$base/sessions/slot" "$base/pi"
  printf '%s\n' "$base"
}

write_models() {  # <file>
  cat > "$1" <<'JSON'
{
  "github-copilot": {
    "models": [
      {"id":"preferred"},
      {"id":"beta"},
      {"id":"primary"},
      {"id":"ambiguous"},
      {"id":"other"},
      {"id":"unknown-cost"}
    ]
  },
  "openai-codex": {"models":[{"id":"sub"}]}
}
JSON
}

run_json() {  # <base> [extra args]
  local base=$1
  shift
  "$COSTS" --json --home "$base/home" --session-dir "$base/sessions" \
    --models-store "$base/pi/models-store.json" --now 2026-08-10T12:00:00Z "$@"
}

run_toon() {  # <base> [extra args]
  local base=$1
  shift
  "$COSTS" --home "$base/home" --session-dir "$base/sessions" \
    --models-store "$base/pi/models-store.json" --now 2026-08-10T12:00:00Z "$@"
}

write_baseline() {  # <base>
  local base=$1
  write_models "$base/pi/models-store.json"
  cat > "$base/sessions/slot/one.jsonl" <<EOF
{"type":"session","version":3,"id":"session-one","timestamp":"2026-08-10T10:00:00Z","cwd":"$base/pool/reused"}
{"type":"message","id":"user-one","timestamp":"2026-08-10T10:00:01Z","message":{"role":"user","content":"synthetic SECRET-TRANSCRIPT-TEXT; append to '$base/home/state/task-one.status'"}}
{"type":"message","id":"direct-one","timestamp":"2026-08-10T10:00:02Z","message":{"role":"assistant","provider":"github-copilot","model":"obsolete","responseModel":"preferred","usage":{"input":10,"output":20,"cacheRead":30,"cacheWrite":40,"reasoning":5,"cacheWrite1h":6,"cost":{"total":1.25}}}}
EOF
}

test_baseline_and_toon_json_equivalence() {
  local base json toon
  base=$(new_fixture baseline)
  write_baseline "$base"
  json=$(run_json "$base") || fail "baseline JSON invocation failed"
  toon=$(run_toon "$base") || fail "baseline TOON invocation failed"

  printf '%s\n' "$json" | jq -e --arg home "$base/home" '
    .contract == "fm-costs.v1"
      and .caveat == "Dollar values are list-price valuations, not invoices."
      and .home == $home
      and .generated_at == "2026-08-10T12:00:00Z"
      and .scan.files == 1 and .scan.sessions == 1 and .scan.parse_errors == 0
      and .primary.sessions == 0
      and (.tasks | length) == 1
      and (.tasks[0].task == "task-one" and .tasks[0].sessions == 1
        and .tasks[0].est_cost_usd == 1.25)
      and (.tasks[0].models[0]
        | .model == "github-copilot/preferred"
          and .origin == "direct" and .calls == 1 and .turns == 1
          and .tokens == {input:10,output:20,cacheRead:30,cacheWrite:40,reasoning:5,cacheWrite1h:6}
          and .billing_basis == "subscription"
          and .cost_source == "pi-stored"
          and .est_cost_usd == 1.25)
      and .totals.est_cost_usd == 1.25
      and .totals.subagent.est_cost_usd == 0
      and .totals.by_billing_basis.subscription.est_cost_usd == 1.25
      and (.gaps | length) == 0
  ' >/dev/null || fail "baseline JSON contract or totals were wrong: $json"

  assert_contains "$toon" 'contract: fm-costs.v1' "TOON must carry the same contract"
  assert_contains "$toon" 'caveat: Dollar values are list-price valuations, not invoices.' "TOON must carry the exact caveat"
  assert_contains "$toon" 'task-one: sessions=1 est_cost_usd=1.25' "TOON task cost must equal JSON"
  assert_contains "$toon" 'direct github-copilot/preferred: calls=1 turns=1 input=10 output=20 cacheRead=30 cacheWrite=40 reasoning=5 cacheWrite1h=6 est_cost_usd=1.25' "TOON model values must equal JSON"
  assert_contains "$toon" 'totals: est_cost_usd=1.25 known_cost_usd=1.25 unknown_cost_events=0 subagent_est_cost_usd=0' "TOON total values must equal JSON"
  assert_not_contains "$json$toon" 'SECRET-TRANSCRIPT-TEXT' "neither output may emit transcript content"
  pass "baseline JSON and TOON carry equivalent stable values without transcript content"
}

write_complex_fixture() {  # <base>
  local base=$1 body
  write_models "$base/pi/models-store.json"
  mkdir -p "$base/sessions/reused" "$base/sessions/second-slot" "$base/sessions/gaps"

  body="$base/alpha-body"
  cat > "$body" <<EOF
{"type":"message","id":"alpha-user","timestamp":"2026-08-10T09:00:01Z","message":{"role":"user","content":"append to '$base/home/state/alpha.status'"}}
{"type":"message","id":"alpha-direct","timestamp":"2026-08-10T09:00:02Z","message":{"role":"assistant","provider":"github-copilot","model":"preferred","usage":{"input":10,"output":2,"cacheRead":3,"cacheWrite":4,"reasoning":1,"cacheWrite1h":0,"cost":{"total":0.5}}}}
{"type":"message","id":"alpha-subagents","timestamp":"2026-08-10T09:00:03Z","message":{"role":"toolResult","toolName":"subagent","details":{"results":[{"model":"openai-codex/sub","usage":{"input":100,"output":10,"cacheRead":20,"cacheWrite":1,"reasoning":2,"cacheWrite1h":3,"turns":2,"cost":1}},{"model":"openai-codex/sub","usage":{"input":200,"output":20,"cacheRead":40,"cacheWrite":2,"reasoning":4,"cacheWrite1h":6,"turns":3,"cost":2}}]}}}
EOF
  {
    printf '%s\n' "{\"type\":\"session\",\"version\":3,\"id\":\"alpha-original\",\"timestamp\":\"2026-08-10T09:00:00Z\",\"cwd\":\"$base/pool/reused\"}"
    cat "$body"
  } > "$base/sessions/reused/alpha-original.jsonl"
  {
    printf '%s\n' "{\"type\":\"session\",\"version\":3,\"id\":\"alpha-fork\",\"timestamp\":\"2026-08-10T09:10:00Z\",\"cwd\":\"$base/pool/second-slot\",\"parentSession\":\"alpha-original.jsonl\"}"
    cat "$body"
  } > "$base/sessions/second-slot/alpha-fork.jsonl"

  cat > "$base/sessions/reused/beta.jsonl" <<EOF
{"type":"session","version":3,"id":"beta-session","timestamp":"2026-08-10T09:20:00Z","cwd":"$base/pool/reused"}
{"type":"message","id":"beta-user","timestamp":"2026-08-10T09:20:01Z","message":{"role":"user","content":"append to '$base/home/state/beta.status'"}}
{"type":"message","id":"beta-direct","timestamp":"2026-08-10T09:20:02Z","message":{"role":"assistant","provider":"github-copilot","model":"beta","usage":{"input":4,"output":5,"cacheRead":6,"cacheWrite":7,"reasoning":2,"cacheWrite1h":0,"cost":{"total":0.4}}}}
{"type":"message","id":"beta-later-user","timestamp":"2026-08-10T09:20:03Z","message":{"role":"user","content":"later mention $base/home/state/not-beta.status must not alter attribution"}}
EOF
  printf '%s' '{"type":"message","broken":' >> "$base/sessions/reused/beta.jsonl"

  cat > "$base/sessions/gaps/primary.jsonl" <<EOF
{"type":"session","version":3,"id":"primary-session","timestamp":"2026-08-10T09:30:00Z","cwd":"$base/home"}
{"type":"message","id":"primary-user","timestamp":"2026-08-10T09:30:01Z","message":{"role":"user","content":"ordinary primary request"}}
{"type":"message","id":"primary-direct","timestamp":"2026-08-10T09:30:02Z","message":{"role":"assistant","provider":"github-copilot","model":"primary","usage":{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"cost":{"total":0.6}}}}
{"type":"message","id":"primary-later-user","timestamp":"2026-08-10T09:30:03Z","message":{"role":"user","content":"later read $base/home/state/alpha.status and $base/home/state/beta.status"}}
EOF

  cat > "$base/sessions/gaps/unattributed.jsonl" <<EOF
{"type":"session","version":3,"id":"ambiguous-session","timestamp":"2026-08-10T09:40:00Z","cwd":"$base/pool/ambiguous"}
{"type":"message","id":"ambiguous-user","timestamp":"2026-08-10T09:40:01Z","message":{"role":"user","content":"both $base/home/state/one.status and $base/home/state/two.status"}}
{"type":"message","id":"ambiguous-direct","timestamp":"2026-08-10T09:40:02Z","message":{"role":"assistant","provider":"github-copilot","model":"ambiguous","usage":{"input":7,"output":8,"cacheRead":9,"cacheWrite":10,"cost":{"total":0.7}}}}
EOF

  cat > "$base/sessions/gaps/other-home.jsonl" <<EOF
{"type":"session","version":3,"id":"other-session","timestamp":"2026-08-10T09:50:00Z","cwd":"$base/other-pool"}
{"type":"message","id":"other-user","timestamp":"2026-08-10T09:50:01Z","message":{"role":"user","content":"append to '$base/other-home/state/remote-task.status'"}}
{"type":"message","id":"other-direct","timestamp":"2026-08-10T09:50:02Z","message":{"role":"assistant","provider":"github-copilot","model":"other","usage":{"input":11,"output":12,"cacheRead":13,"cacheWrite":14,"cost":{"total":2.5}}}}
EOF

  cat > "$base/sessions/gaps/unknown-cost.jsonl" <<EOF
{"type":"session","version":3,"id":"unknown-session","timestamp":"2026-08-10T10:00:00Z","cwd":"$base/pool/unknown"}
{"type":"message","id":"unknown-user","timestamp":"2026-08-10T10:00:01Z","message":{"role":"user","content":"append to '$base/home/state/gamma.status'"}}
{"type":"message","id":"unknown-direct","timestamp":"2026-08-10T10:00:02Z","message":{"role":"assistant","provider":"github-copilot","model":"unknown-cost","usage":{"input":15,"output":16,"cacheRead":17,"cacheWrite":18,"cost":{"total":"not-known"}}}}
EOF

  cat > "$base/sessions/gaps/no-header.jsonl" <<EOF
{"type":"message","id":"ignored-user","timestamp":"2026-08-10T10:10:01Z","message":{"role":"user","content":"$base/home/state/ignored.status"}}
{"type":"message","id":"ignored-cost","timestamp":"2026-08-10T10:10:02Z","message":{"role":"assistant","provider":"github-copilot","model":"preferred","usage":{"input":999,"cost":{"total":99}}}}
EOF
}

test_direct_subagent_dedup_and_attribution() {
  local base json
  base=$(new_fixture complex)
  write_complex_fixture "$base"
  json=$(run_json "$base") || fail "complex JSON invocation failed"

  printf '%s\n' "$json" | jq -e '
    .scan.files == 8 and .scan.sessions == 7 and .scan.included_sessions == 6
      and .scan.parse_errors == 1
      and .scan.deduplicated_entries == 3
      and .scan.deduplicated_known_cost_usd == 3.5
      and .scan.deduplicated_unknown_cost_events == 0
      and (.tasks[] | select(.task == "alpha")
        | .sessions == 2 and (has("files") | not)
          and .est_cost_usd == 3.5
          and (.models | length) == 2
          and (.models[] | select(.origin == "direct")
            | .calls == 1 and .turns == 1 and .est_cost_usd == 0.5)
          and (.models[] | select(.origin == "subagent")
            | .model == "openai-codex/sub"
              and .calls == 2 and .turns == 5
              and .tokens == {input:300,output:30,cacheRead:60,cacheWrite:3,reasoning:6,cacheWrite1h:9}
              and .est_cost_usd == 3)
          and .by_origin.direct.calls == 1
          and .by_origin.subagent.calls == 2 and .by_origin.subagent.turns == 5
          and .by_origin.subagent.tokens.input == 300
          and .by_billing_basis.subscription.est_cost_usd == 3.5
          and .cost_source == "pi-stored")
      and (.tasks[] | select(.task == "beta")
        | .sessions == 1 and .est_cost_usd == 0.4)
      and ([.tasks[].task] | index("not-beta") == null)
      and .primary.sessions == 1 and .primary.est_cost_usd == 0.6
      and .unattributed.sessions == 1 and .unattributed.est_cost_usd == 0.7
      and (.unattributed.files | length) == 1 and (.unattributed.models | length) == 1
      and (.other_homes | length) == 1
      and (.other_homes[0].home | endswith("/other-home"))
      and .other_homes[0].omitted == true
      and .other_homes[0].sessions == 1 and .other_homes[0].est_cost_usd == 2.5
      and (.other_homes[0] | has("models") | not)
      and .totals.est_cost_usd == null
      and .totals.known_cost_usd == 5.2
      and .totals.unknown_cost_events == 1
      and .totals.subagent.est_cost_usd == 3
      and .totals.by_billing_basis.subscription.est_cost_usd == null
      and .totals.by_billing_basis.subscription.known_cost_usd == 5.2
      and (.gaps | any(.kind == "malformed-lines" and .count == 1))
      and (.gaps | any(.kind == "no-session-header"))
      and (.gaps | any(.kind == "unknown-cost" and .model == "github-copilot/unknown-cost" and .count == 1))
      and (.gaps | any(.kind == "unattributed" and .sessions == 1 and .known_cost_usd == 0.7))
      and (.gaps | any(.kind == "other-home-omitted" and .sessions == 1 and .known_cost_usd == 2.5))
  ' >/dev/null || fail "direct/subagent dedup, path reuse, first-user attribution, or gap totals were wrong: $json"
  pass "direct and subagent calls dedupe by structured origin/index and attribute from only the first user message"
}

test_missing_metadata_keeps_known_cost_and_unknown_cost_is_not_zero() {
  local base json
  base=$(new_fixture cost-gaps)
  cat > "$base/pi/models-store.json" <<'JSON'
{"github-copilot":{"models":[{"id":"unknown-cost"}]}}
JSON
  cat > "$base/sessions/slot/known-no-metadata.jsonl" <<EOF
{"type":"session","version":3,"id":"known-session","timestamp":"2026-08-10T11:00:00Z","cwd":"$base/pool"}
{"type":"message","id":"known-user","timestamp":"2026-08-10T11:00:01Z","message":{"role":"user","content":"$base/home/state/known.status"}}
{"type":"message","id":"known-call","timestamp":"2026-08-10T11:00:02Z","message":{"role":"assistant","provider":"retired-provider","model":"retired-model","usage":{"input":3,"output":4,"cacheRead":5,"cacheWrite":6,"cost":{"total":4.75}}}}
EOF
  cat > "$base/sessions/slot/unknown.jsonl" <<EOF
{"type":"session","version":3,"id":"unknown-session","timestamp":"2026-08-10T11:10:00Z","cwd":"$base/pool"}
{"type":"message","id":"unknown-user","timestamp":"2026-08-10T11:10:01Z","message":{"role":"user","content":"$base/home/state/unknown.status"}}
{"type":"message","id":"unknown-call","timestamp":"2026-08-10T11:10:02Z","message":{"role":"assistant","provider":"github-copilot","model":"unknown-cost","usage":{"input":7,"output":8,"cacheRead":9,"cacheWrite":10,"cost":{"total":null}}}}
EOF
  json=$(run_json "$base") || fail "cost-gap JSON invocation failed"
  printf '%s\n' "$json" | jq -e '
    (.tasks[] | select(.task == "known")
      | .est_cost_usd == 4.75 and .known_cost_usd == 4.75 and .unknown_cost_events == 0
        and .models[0].est_cost_usd == 4.75
        and .models[0].cost_source == "pi-stored")
      and (.gaps | any(.kind == "missing-model-metadata"
        and .model == "retired-provider/retired-model"))
      and (.tasks[] | select(.task == "unknown")
        | .est_cost_usd == null and .known_cost_usd == 0 and .unknown_cost_events == 1
          and .models[0].est_cost_usd == null
          and .models[0].known_cost_usd == 0
          and .models[0].unknown_cost_events == 1)
      and .totals.est_cost_usd == null
      and .totals.known_cost_usd == 4.75
      and .totals.unknown_cost_events == 1
  ' >/dev/null || fail "known stored cost or unknown-cost null propagation was wrong: $json"
  pass "stored cost survives missing model metadata and unknown cost propagates as null, never zero"
}

test_models_store_missing_and_corrupt_are_labelled() {
  local base missing corrupt
  base=$(new_fixture model-store-state)
  cat > "$base/sessions/slot/one.jsonl" <<EOF
{"type":"session","version":3,"id":"one","timestamp":"2026-08-10T11:20:00Z","cwd":"$base/home"}
{"type":"message","id":"user","timestamp":"2026-08-10T11:20:01Z","message":{"role":"user","content":"primary"}}
{"type":"message","id":"call","timestamp":"2026-08-10T11:20:02Z","message":{"role":"assistant","provider":"github-copilot","model":"preferred","usage":{"input":1,"cost":{"total":0.25}}}}
EOF
  missing=$(run_json "$base") || fail "missing models-store run failed"
  printf '%s\n' "$missing" | jq -e '
    .inputs.models_store_state == "missing"
      and .totals.est_cost_usd == 0.25
      and (.gaps | any(.kind == "models-store-missing"))
      and (.gaps | any(.kind == "missing-model-metadata"))
  ' >/dev/null || fail "missing models store was not a labelled non-cost gap: $missing"
  printf '{broken' > "$base/pi/models-store.json"
  corrupt=$(run_json "$base") || fail "corrupt models-store run failed"
  printf '%s\n' "$corrupt" | jq -e '
    .inputs.models_store_state == "corrupt"
      and .totals.est_cost_usd == 0.25
      and (.gaps | any(.kind == "models-store-corrupt"))
  ' >/dev/null || fail "corrupt models store was not a labelled non-cost gap: $corrupt"
  pass "missing and corrupt models stores remain labelled while stored costs stay authoritative"
}

test_default_home_scan_is_read_only_and_network_free() {
  local base agent home_dir fakebin before after json calls
  base=$(new_fixture readonly)
  home_dir="$base/operator-home"
  agent="$home_dir/.pi/agent"
  mkdir -p "$agent/sessions/default-slot" "$base/report-home" "$base/fakebin"
  write_models "$agent/models-store.json"
  cat > "$agent/sessions/default-slot/default.jsonl" <<EOF
{"type":"session","version":3,"id":"default-session","timestamp":"2026-08-10T11:30:00Z","cwd":"$base/report-home"}
{"type":"message","id":"default-user","timestamp":"2026-08-10T11:30:01Z","message":{"role":"user","content":"default scan with PRIVATE-SYNTHETIC-CONTENT"}}
{"type":"message","id":"default-call","timestamp":"2026-08-10T11:30:02Z","message":{"role":"assistant","provider":"github-copilot","model":"primary","usage":{"input":2,"output":3,"cacheRead":4,"cacheWrite":5,"cost":{"total":0.75}}}}
EOF
  calls="$base/network-calls"
  : > "$calls"
  for tool in curl wget gh gh-axi quota-axi; do
    cat > "$base/fakebin/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "$NETWORK_CALLS"
exit 99
SH
    chmod +x "$base/fakebin/$tool"
  done
  before=$(find "$home_dir" -type f -print | LC_ALL=C sort; find "$home_dir" -type f -exec cksum {} \; | LC_ALL=C sort)
  chmod -R a-w "$home_dir"
  json=$(env -u FM_HOME -u FM_COSTS_HOME -u FM_COSTS_SESSION_DIR \
    -u FM_COSTS_MODELS_STORE -u FM_COSTS_NOW \
    HOME="$home_dir" PATH="$base/fakebin:$PATH" NETWORK_CALLS="$calls" \
    "$COSTS" --json --home "$base/report-home" --now 2026-08-10T12:00:00Z) \
    || fail "default read-only invocation failed"
  after=$(find "$home_dir" -type f -print | LC_ALL=C sort; find "$home_dir" -type f -exec cksum {} \; | LC_ALL=C sort)
  chmod -R u+w "$home_dir"
  [ "$before" = "$after" ] || fail "report changed its synthetic Pi input tree"
  [ ! -s "$calls" ] || fail "report invoked a network-capable command: $(cat "$calls")"
  printf '%s\n' "$json" | jq -e --arg home "$base/report-home" '
    .home == $home and .inputs == {models_store_state:"ok"} and .scan.files == 1
      and .primary.sessions == 1 and .totals.est_cost_usd == 0.75
      and .caveat == "Dollar values are list-price valuations, not invoices."
  ' >/dev/null || fail "default HOME scan did not use only the synthetic Pi store: $json"
  assert_not_contains "$json" 'PRIVATE-SYNTHETIC-CONTENT' "JSON must not copy transcript content"
  pass "default HOME scan is hermetic, read-only, network-free, and transcript-safe"
}

test_env_overrides_are_hermetic() {
  local base json
  base=$(new_fixture env-overrides)
  write_baseline "$base"
  json=$(FM_COSTS_HOME="$base/home" \
    FM_COSTS_SESSION_DIR="$base/sessions" \
    FM_COSTS_MODELS_STORE="$base/pi/models-store.json" \
    FM_COSTS_NOW=2026-08-10T12:34:56Z \
    HOME="$base/empty-home" "$COSTS" --json) || fail "environment override run failed"
  printf '%s\n' "$json" | jq -e '
    .contract == "fm-costs.v1"
      and .generated_at == "2026-08-10T12:34:56Z"
      and .scan.files == 1 and .tasks[0].task == "task-one"
  ' >/dev/null || fail "environment overrides did not select the synthetic fixture: $json"
  pass "home, session-dir, models-store, and clock environment overrides are hermetic"
}

test_baseline_and_toon_json_equivalence
test_direct_subagent_dedup_and_attribution
test_missing_metadata_keeps_known_cost_and_unknown_cost_is_not_zero
test_models_store_missing_and_corrupt_are_labelled
test_default_home_scan_is_read_only_and_network_free
test_env_overrides_are_hermetic
