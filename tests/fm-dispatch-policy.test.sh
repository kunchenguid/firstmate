#!/usr/bin/env bash
# Behavioral coverage for the versioned crew-dispatch policy contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dispatch-policy)
POLICY="$ROOT/bin/fm-dispatch-policy.sh"
POLICY_FILE="$TMP_ROOT/crew-dispatch.json"

write_policy() {
  printf '%s\n' "$1" > "$POLICY_FILE"
}

expect_success() {
  "$@" >/dev/null 2>&1 || fail "expected success: $*"
}

expect_output() {
  local expected=$1 out
  shift
  out=$("$@") || fail "expected success: $*"
  [ "$out" = "$expected" ] || fail "expected '$expected', got '$out'"
}

expect_failure_contains() {
  local expected=$1 out rc
  shift
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected failure: $*"
  assert_contains "$out" "$expected" "failure output"
}

expect_sanitized_failure() {
  local expected_reason=$1 marker=$2 stdout_file stderr_file rc lines bytes
  shift 2
  stdout_file="$TMP_ROOT/stdout"
  stderr_file="$TMP_ROOT/stderr"
  set +e
  "$@" >"$stdout_file" 2>"$stderr_file"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "expected stable validation failure exit 1, got $rc: $*"
  [ ! -s "$stdout_file" ] || fail "invalid policy emitted partial stdout: $*"
  lines=$(wc -l <"$stderr_file" | tr -d ' ')
  bytes=$(wc -c <"$stderr_file" | tr -d ' ')
  [ "$lines" -eq 1 ] || fail "invalid policy emitted $lines diagnostic lines: $*"
  [ "$bytes" -le 128 ] || fail "invalid policy emitted an unbounded $bytes-byte diagnostic: $*"
  [ "$(cat "$stderr_file")" = "invalid dispatch policy: $expected_reason" ] \
    || fail "unexpected sanitized diagnostic: $(cat "$stderr_file")"
  assert_not_contains "$(cat "$stderr_file")" "$marker" "diagnostic exposed caller-controlled policy bytes"
}

test_v1_stays_valid() {
  write_policy '{"rules":[{"when":"anything","use":{"harness":"codex"}}]}'
  expect_success "$POLICY" validate "$POLICY_FILE"
  expect_output automatic "$POLICY" mode "$POLICY_FILE"
  pass "unversioned inline rules remain valid version 1 input"
}

test_v2_normalizes_named_profile() {
  write_policy '{"schemaVersion":2,"routing":{"mode":"simulate","limits":{"canary":3,"automatic":6,"burst":8,"perLane":2},"circuitBreaker":{"failures":3,"windowSeconds":900,"cooldownSeconds":1800},"transientRetries":1},"profiles":{"pi-grok":{"harness":"pi","model":"cliproxyapi/grok-4.6","provider":"xai","lane":"pi-xai-1","reasoningClass":"strong","workTypes":["architecture"]}},"rules":[{"when":"architecture","use":["pi-grok"]}]}'
  expect_success "$POLICY" validate "$POLICY_FILE"
  expect_output simulate "$POLICY" mode "$POLICY_FILE"
  "$POLICY" profile pi-grok "$POLICY_FILE" | jq -e '.id == "pi-grok" and .harness == "pi" and .lane == "pi-xai-1"' >/dev/null || fail "named version 2 profile was not normalized"
  pass "version 2 named profiles normalize through the public reader"
}

test_v2_rejects_secret_fields() {
  write_policy '{"schemaVersion":2,"routing":{"mode":"automatic"},"profiles":{"bad":{"harness":"pi","provider":"xai","lane":"pi-xai-1","apiKey":"secret"}}}'
  expect_failure_contains 'invalid dispatch policy: forbidden-field' "$POLICY" validate "$POLICY_FILE"
  write_policy '{"schemaVersion":2,"profiles":{"bad":{"harness":"pi","provider":"xai","lane":"pi-xai-1","apiKey":{}}}}'
  expect_failure_contains 'invalid dispatch policy: forbidden-field' "$POLICY" validate "$POLICY_FILE"
  pass "credential-shaped fields are refused before dispatch"
}

test_v2_requires_safe_routing_bounds() {
  write_policy '{"schemaVersion":2,"routing":{"mode":"automatic","limits":{"canary":3,"automatic":6,"burst":8,"perLane":0}},"profiles":{}}'
  expect_failure_contains 'invalid dispatch policy: routing' "$POLICY" validate "$POLICY_FILE"
  write_policy '{"schemaVersion":2,"routing":{"mode":"automatic","circuitBreaker":{"failures":3,"windowSeconds":900,"cooldownSeconds":1800},"transientRetries":2},"profiles":{}}'
  expect_failure_contains 'invalid dispatch policy: routing' "$POLICY" validate "$POLICY_FILE"
  pass "version 2 rejects routing bounds outside the fixed safe policy"
}

test_v2_requires_complete_safe_profiles() {
  write_policy '{"schemaVersion":2,"profiles":{"native":{"harness":"codex","model":"gpt-test","provider":"openai","lane":"codex-primary","reasoningClass":"strong","workTypes":["implementation"]}}}'
  expect_failure_contains 'invalid dispatch policy: profile' "$POLICY" validate "$POLICY_FILE"
  write_policy '{"schemaVersion":2,"profiles":{"pi":{"harness":"pi","model":"grok-test","provider":"xai","lane":"pi-xai-1","account":"pi-xai-1","reasoningClass":"strong","workTypes":["architecture"]}}}'
  expect_failure_contains 'invalid dispatch policy: profile' "$POLICY" validate "$POLICY_FILE"
  write_policy '{"schemaVersion":2,"profiles":{"pi":{"harness":"pi","model":"grok-test","provider":"xai","lane":"pi-xai-1","reasoningClass":"strong","workTypes":["architecture"]}},"rules":[{"when":"architecture","use":["missing"]}]}'
  expect_failure_contains 'invalid dispatch policy: reference' "$POLICY" validate "$POLICY_FILE"
  pass "version 2 requires safe accounts and existing named profile references"
}

test_v2_requires_a_concrete_model_but_v1_keeps_optional_model() {
  write_policy '{"schemaVersion":2,"profiles":{"pi":{"harness":"pi","provider":"xai","lane":"pi-xai-1","reasoningClass":"strong","workTypes":["architecture"]}}}'
  expect_failure_contains 'invalid dispatch policy: profile' "$POLICY" validate "$POLICY_FILE"
  write_policy '{"schemaVersion":2,"profiles":{"pi":{"harness":"pi","model":"default","provider":"xai","lane":"pi-xai-1","reasoningClass":"strong","workTypes":["architecture"]}}}'
  expect_failure_contains 'invalid dispatch policy: profile' "$POLICY" validate "$POLICY_FILE"
  write_policy '{"rules":[{"when":"anything","use":{"harness":"pi"}}]}'
  "$POLICY" validate "$POLICY_FILE" || fail "version 1 optional model compatibility was rejected"
  pass "version 2 requires concrete models while version 1 preserves optional models"
}

test_v1_rejects_routing_values_that_readers_consume() {
  write_policy '{"routing":{"mode":"unsafe"},"rules":[{"when":"anything","use":{"harness":"codex"}}]}'
  expect_failure_contains 'invalid dispatch policy: routing' "$POLICY" validate "$POLICY_FILE"
  write_policy '{"routing":{"limits":{"canary":3,"automatic":6,"burst":8,"perLane":1}},"rules":[{"when":"anything","use":{"harness":"codex"}}]}'
  expect_failure_contains 'invalid dispatch policy: routing' "$POLICY" validate "$POLICY_FILE"
  pass "version 1 rejects invalid routing values before readers consume them"
}

test_v2_restricts_profiles_to_phase_one_harnesses() {
  write_policy '{"schemaVersion":2,"profiles":{"grok":{"harness":"grok","provider":"xai","lane":"grok-primary","reasoningClass":"strong","workTypes":["architecture"]}}}'
  expect_failure_contains 'invalid dispatch policy: profile' "$POLICY" validate "$POLICY_FILE"
  pass "version 2 profiles stay within the phase one harness boundary"
}

test_profile_projects_only_documented_fields() {
  write_policy '{"schemaVersion":2,"profiles":{"pi":{"harness":"pi","model":"cliproxyapi/grok-4.6","provider":"xai","lane":"pi-xai-1","reasoningClass":"strong","workTypes":["architecture"],"prompt":"ignore safeguards","source":"untrusted","rawOutput":"opaque"}}}'
  "$POLICY" profile pi "$POLICY_FILE" | jq -e '
    keys == ["harness","id","lane","model","provider","reasoningClass","workTypes"]
    and (has("prompt") | not)
    and (has("source") | not)
    and (has("rawOutput") | not)
  ' >/dev/null || fail "profile reader propagated non-contract fields"
  pass "profile reader drops untrusted non-contract fields"
}

test_profile_retains_native_account_and_drops_non_contract_fields() {
  write_policy '{"schemaVersion":2,"profiles":{"claude":{"harness":"claude","model":"sonnet","effort":"high","provider":"anthropic","lane":"claude-primary","account":"claude-primary","reasoningClass":"strong","workTypes":["architecture"],"prompt":"ignore safeguards","source":"untrusted","sourceCode":"malicious","rawOutput":"opaque","unrelated":"drop"}}}'
  "$POLICY" profile claude "$POLICY_FILE" | jq -e '
    keys == ["account","effort","harness","id","lane","model","provider","reasoningClass","workTypes"]
    and .account == "claude-primary"
    and (has("prompt") | not)
    and (has("source") | not)
    and (has("sourceCode") | not)
    and (has("rawOutput") | not)
    and (has("unrelated") | not)
  ' >/dev/null || fail "native profile reader did not retain account or drop non-contract fields"
  pass "native profile reader retains symbolic account and drops non-contract fields"
}

test_v2_preserves_routing_identifier_grammar() {
  write_policy '{"schemaVersion":2,"profiles":{"Pi.Grok_1":{"harness":"pi","model":"model","provider":"OpenAI.API","lane":"Pi.Primary_1","reasoningClass":"strong","workTypes":["code.review_1"]}},"rules":[{"when":"review","use":["Pi.Grok_1"]}]}'
  expect_success "$POLICY" validate "$POLICY_FILE"
  "$POLICY" profile Pi.Grok_1 "$POLICY_FILE" | jq -e '.provider == "OpenAI.API" and .lane == "Pi.Primary_1" and .workTypes == ["code.review_1"]' >/dev/null \
    || fail "version 2 routing identifiers were narrowed below the established routing grammar"
  pass "version 2 preserves the established routing identifier grammar"
}

test_invalid_policy_diagnostics_are_bounded_and_payload_free() {
  local command payload marker
  payload=$(jq -n --arg hostile $'bad\nTOKEN=exposed\r\033[31m' '{schemaVersion:2,profiles:{safe:{harness:$hostile,model:"model",provider:"provider",lane:"lane",reasoningClass:"strong",workTypes:["implementation"],prompt:"PROMPT_MARKER",rawOutput:"RAW_MARKER"}}}')
  write_policy "$payload"
  for command in validate mode limits describe; do
    expect_sanitized_failure profile TOKEN=exposed "$POLICY" "$command" "$POLICY_FILE"
  done
  expect_sanitized_failure profile TOKEN=exposed "$POLICY" profile safe "$POLICY_FILE"

  for marker in \
    HARNESS_MARKER MODEL_MARKER PROVIDER_MARKER LANE_MARKER ACCOUNT_MARKER \
    EFFORT_MARKER WORKTYPE_MARKER RULE_MARKER DEFAULT_MARKER PROMPT_MARKER \
    TOKEN_MARKER RAW_MARKER; do
    payload=$(jq -n --arg marker "$marker" '{schemaVersion:2,routing:{mode:"automatic"},profiles:{safe:{harness:"pi",model:"model",provider:"provider",lane:"lane",reasoningClass:"strong",workTypes:["implementation"]}}} | if $marker == "HARNESS_MARKER" then .profiles.safe.harness=$marker elif $marker == "MODEL_MARKER" then .profiles.safe.model=$marker+"\nTOKEN=exposed" elif $marker == "PROVIDER_MARKER" then .profiles.safe.provider=$marker+"\r" elif $marker == "LANE_MARKER" then .profiles.safe.lane=$marker+"\u001b" elif $marker == "ACCOUNT_MARKER" then .profiles.safe.harness="codex" | .profiles.safe.account=$marker elif $marker == "EFFORT_MARKER" then .profiles.safe.effort=$marker elif $marker == "WORKTYPE_MARKER" then .profiles.safe.workTypes=[$marker, 7] elif $marker == "RULE_MARKER" then .rules=[{when:$marker,use:["missing"]}] elif $marker == "DEFAULT_MARKER" then .default=[$marker] elif $marker == "PROMPT_MARKER" then .profiles.safe.prompt=$marker | .profiles.safe.effort="invalid" elif $marker == "TOKEN_MARKER" then .profiles.safe.token=$marker elif $marker == "RAW_MARKER" then .profiles.safe.rawOutput=$marker | .profiles.safe.effort="invalid" else . end')
    write_policy "$payload"
    expect_sanitized_failure "$(case "$marker" in TOKEN_MARKER) printf forbidden-field ;; RULE_MARKER|DEFAULT_MARKER) printf reference ;; *) printf profile ;; esac)" "$marker" "$POLICY" validate "$POLICY_FILE"
  done

  payload=$(jq -n --arg id "$(printf 'x%.0s' $(seq 1 300))" '{schemaVersion:2,profiles:{($id):{harness:"pi",model:"model",provider:"provider",lane:"lane",reasoningClass:"strong",workTypes:["implementation"]}}}')
  write_policy "$payload"
  expect_sanitized_failure profile xxxxxxxxxx "$POLICY" validate "$POLICY_FILE"
  pass "invalid policy diagnostics are one bounded payload-free line for every reader"
}

test_policy_readers_bind_one_safe_snapshot() {
  local fifo writer watchdog rc stdout_file stderr_file
  fifo="$TMP_ROOT/policy-fifo"
  stdout_file="$TMP_ROOT/fifo-stdout"
  stderr_file="$TMP_ROOT/fifo-stderr"
  mkfifo "$fifo"
  (
    printf '%s\n' '{"schemaVersion":2,"routing":{"mode":"automatic"},"profiles":{}}' > "$fifo"
    printf '%s\n' '{"schemaVersion":2,"routing":{"mode":"automatic"},"profiles":{}}' > "$fifo"
    printf '%s\n' '{"schemaVersion":2,"routing":{"mode":"automatic"},"profiles":{}}' > "$fifo"
    printf '%s\n' $'{"schemaVersion":2,"routing":{"mode":"bad\\nTOKEN=exposed\\u001b[31m"},"profiles":{}}' > "$fifo"
  ) &
  writer=$!
  set +e
  "$POLICY" mode "$fifo" >"$stdout_file" 2>"$stderr_file"
  rc=$?
  set -e
  kill "$writer" >/dev/null 2>&1 || true
  wait "$writer" >/dev/null 2>&1 || true
  [ "$rc" -eq 1 ] || fail "mutable non-regular policy source bypassed validation"
  [ ! -s "$stdout_file" ] || fail "mutable policy source emitted unvalidated stdout"
  [ "$(cat "$stderr_file")" = 'invalid dispatch policy: source' ] \
    || fail "mutable policy source emitted an unstable diagnostic: $(cat "$stderr_file")"
  assert_not_contains "$(cat "$stderr_file")" TOKEN=exposed "mutable policy source exposed payload bytes"

  rm -f "$fifo"
  mkfifo "$fifo"
  "$POLICY" validate "$fifo" >"$stdout_file" 2>"$stderr_file" &
  writer=$!
  (sleep 2; kill "$writer" >/dev/null 2>&1 || true) &
  watchdog=$!
  set +e
  wait "$writer"
  rc=$?
  set -e
  kill "$watchdog" >/dev/null 2>&1 || true
  wait "$watchdog" >/dev/null 2>&1 || true
  [ "$rc" -eq 1 ] || fail "no-writer FIFO did not fail promptly with exit 1 (got $rc)"
  [ ! -s "$stdout_file" ] || fail "no-writer FIFO emitted stdout"
  [ "$(cat "$stderr_file")" = 'invalid dispatch policy: source' ] \
    || fail "no-writer FIFO emitted an unstable diagnostic: $(cat "$stderr_file")"

  printf '%s\n' '{"schemaVersion":2,"schemaVersion":1,"rules":[]}' > "$TMP_ROOT/--help"
  # The inner sh expands its positional parameters.
  # shellcheck disable=SC2016
  expect_sanitized_failure duplicate-key 'jq - commandline' sh -c 'cd "$1" && exec "$2" validate --help' sh "$TMP_ROOT" "$POLICY"
  pass "policy readers reject mutable and option-shaped sources before parsing"
}

test_snapshot_boundary_preserves_symlinks_and_sanitizes_setup_failures() {
  local hostile_tmp command
  write_policy '{"schemaVersion":2,"routing":{"mode":"automatic"},"profiles":{}}'
  ln -s "$POLICY_FILE" "$TMP_ROOT/policy-link.json"
  expect_success "$POLICY" validate "$TMP_ROOT/policy-link.json"

  hostile_tmp="$TMP_ROOT/missing/TOKEN=exposed"
  write_policy $'{"schemaVersion":2,"profiles":{"safe":{"harness":"bad\\nPAYLOAD_MARKER","model":"model","provider":"provider","lane":"lane","reasoningClass":"strong","workTypes":["implementation"]}}}'
  for command in validate mode limits describe; do
    expect_sanitized_failure profile PAYLOAD_MARKER env TMPDIR="$hostile_tmp" "$POLICY" "$command" "$POLICY_FILE"
  done
  expect_sanitized_failure profile PAYLOAD_MARKER env TMPDIR="$hostile_tmp" "$POLICY" profile safe "$POLICY_FILE"
  pass "snapshot setup preserves regular-file symlinks and suppresses caller-shaped temp paths"
}

test_malformed_and_duplicate_json_have_stable_diagnostics() {
  local command
  for command in validate mode limits describe; do
    write_policy $'{"schemaVersion":2,"profiles":{"safe":\nTOKEN=exposed'
    expect_sanitized_failure malformed-json TOKEN=exposed "$POLICY" "$command" "$POLICY_FILE"
    write_policy '{"schemaVersion":2,"schemaVersion":1,"rules":[]}'
    expect_sanitized_failure duplicate-key schemaVersion "$POLICY" "$command" "$POLICY_FILE"
  done
  write_policy $'{"schemaVersion":2,"profiles":{"safe":\nTOKEN=exposed'
  expect_sanitized_failure malformed-json TOKEN=exposed "$POLICY" profile safe "$POLICY_FILE"
  write_policy '{"schemaVersion":2,"schemaVersion":1,"rules":[]}'
  expect_sanitized_failure duplicate-key schemaVersion "$POLICY" profile safe "$POLICY_FILE"
  printf '%s' '{"rules":[],"raw":"' > "$POLICY_FILE"
  printf '\377' >> "$POLICY_FILE"
  printf '%s\n' '"}' >> "$POLICY_FILE"
  expect_sanitized_failure malformed-json 'jq:' "$POLICY" validate "$POLICY_FILE"
  pass "malformed JSON and duplicate keys fail without parser output or payload reflection"
}


test_v1_stays_valid
test_v2_normalizes_named_profile
test_v2_rejects_secret_fields
test_v2_requires_safe_routing_bounds
test_v2_requires_complete_safe_profiles
test_v2_requires_a_concrete_model_but_v1_keeps_optional_model
test_v1_rejects_routing_values_that_readers_consume
test_v2_restricts_profiles_to_phase_one_harnesses
test_profile_projects_only_documented_fields
test_profile_retains_native_account_and_drops_non_contract_fields
test_v2_preserves_routing_identifier_grammar
test_policy_readers_bind_one_safe_snapshot
test_snapshot_boundary_preserves_symlinks_and_sanitizes_setup_failures
test_invalid_policy_diagnostics_are_bounded_and_payload_free
test_malformed_and_duplicate_json_have_stable_diagnostics
