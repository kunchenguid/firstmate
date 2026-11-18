#!/usr/bin/env bash
# Behavior tests for bin/fm-quality-profile.sh, the single reader of the
# optional config/quality-profile and config/verifier-harness settings
# (docs/configuration.md "Quality profile"), plus the one-owner property of the
# pstack verifier risk class.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-quality-profile)
READER="$ROOT/bin/fm-quality-profile.sh"

# Run the reader against one config directory; capture stdout, stderr, rc.
run_reader() {  # <config-dir> [args...]
  local config=$1
  shift
  OUT=$(FM_CONFIG_OVERRIDE="$config" "$READER" "$@" 2>"$TMP_ROOT/stderr"); RC=$?
  ERR=$(cat "$TMP_ROOT/stderr")
}

new_config() {  # <name> -> echoes a fresh config dir
  local dir="$TMP_ROOT/$1/config"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

test_absent_setting_means_default() {
  local config
  config=$(new_config absent)
  run_reader "$config"
  expect_code 0 "$RC" "absent config/quality-profile must read cleanly (stderr: $ERR)"
  assert_equals default "$OUT" "absent config/quality-profile must read as default"
  run_reader "$config" profile
  assert_equals default "$OUT" "the explicit profile verb must read an absent file as default"
  pass "fm-quality-profile: an absent setting reads as default"
}

test_known_values_read_back() {
  local config value
  for value in default pstack; do
    config=$(new_config "known-$value")
    printf '%s\n' "$value" > "$config/quality-profile"
    run_reader "$config"
    expect_code 0 "$RC" "value $value must read cleanly (stderr: $ERR)"
    assert_equals "$value" "$OUT" "value $value must read back unchanged"
  done
  config=$(new_config known-padded)
  printf '# chosen 2026-11-18\n\n  pstack  \n\n' > "$config/quality-profile"
  run_reader "$config"
  expect_code 0 "$RC" "a commented, padded value must read cleanly (stderr: $ERR)"
  assert_equals pstack "$OUT" "comments, blank lines, and padding must not change the value"
  pass "fm-quality-profile: default and pstack read back exactly"
}

test_unknown_value_refuses() {
  local config
  config=$(new_config unknown)
  printf 'fancy\n' > "$config/quality-profile"
  run_reader "$config"
  expect_code 2 "$RC" "an unknown value must stop the reader"
  assert_equals "" "$OUT" "a refused read must print no profile for a caller to act on"
  assert_contains "$ERR" "fancy" "the refusal must name the unknown value"
  assert_contains "$ERR" "default" "the refusal must name the accepted value default"
  assert_contains "$ERR" "pstack" "the refusal must name the accepted value pstack"
  assert_contains "$ERR" "quality-profile" "the refusal must name the setting file"

  config=$(new_config empty)
  : > "$config/quality-profile"
  run_reader "$config"
  expect_code 2 "$RC" "a present but empty file must refuse rather than guess default"
  assert_equals "" "$OUT" "an empty file must print no profile"

  config=$(new_config two-values)
  printf 'default\npstack\n' > "$config/quality-profile"
  run_reader "$config"
  expect_code 2 "$RC" "two value lines must refuse rather than pick one"

  config=$(new_config not-a-file)
  mkdir -p "$config/quality-profile"
  run_reader "$config"
  expect_code 2 "$RC" "a directory in place of the file must refuse"

  config=$(new_config bad-verb)
  run_reader "$config" nonsense
  expect_code 2 "$RC" "an unknown verb must refuse"
  pass "fm-quality-profile: an unknown, empty, doubled, or unreadable value refuses"
}

test_verifier_default_is_codex() {
  local config
  config=$(new_config verifier-absent)
  run_reader "$config" verifier
  expect_code 0 "$RC" "an absent verifier setting must resolve the documented default (stderr: $ERR)"
  assert_equals "$(printf 'harness=codex\nmodel=\neffort=')" "$OUT" \
    "an absent config/verifier-harness must resolve to codex with its own model and effort defaults"
  pass "fm-quality-profile: the verifier defaults to codex"
}

test_verifier_setting_reads_back() {
  local config
  config=$(new_config verifier-codex)
  printf '# verifier\ncodex gpt-5.6 high\n' > "$config/verifier-harness"
  run_reader "$config" verifier
  expect_code 0 "$RC" "a codex model and effort must read cleanly (stderr: $ERR)"
  assert_equals "$(printf 'harness=codex\nmodel=gpt-5.6\neffort=high')" "$OUT" \
    "harness, model, and effort must read back from config/verifier-harness"

  config=$(new_config verifier-pi)
  printf 'pi openai/gpt-5.6\n' > "$config/verifier-harness"
  run_reader "$config" verifier
  expect_code 0 "$RC" "a multi-provider harness with a non-Claude model must read cleanly (stderr: $ERR)"
  assert_equals "$(printf 'harness=pi\nmodel=openai/gpt-5.6\neffort=')" "$OUT" \
    "a multi-provider harness must keep its named model"
  pass "fm-quality-profile: a configured verifier reads back"
}

test_verifier_claude_with_named_model_reads_back() {
  local config
  config=$(new_config verifier-claude-sonnet)
  printf 'claude sonnet\n' > "$config/verifier-harness"
  run_reader "$config" verifier
  expect_code 0 "$RC" "claude with a named model must read cleanly (stderr: $ERR)"
  assert_equals "$(printf 'harness=claude\nmodel=sonnet\neffort=')" "$OUT" \
    "claude with a named model must print that harness and model"

  config=$(new_config verifier-claude-opus-high)
  printf 'claude opus high\n' > "$config/verifier-harness"
  run_reader "$config" verifier
  expect_code 0 "$RC" "claude with a model and effort must read cleanly (stderr: $ERR)"
  assert_equals "$(printf 'harness=claude\nmodel=opus\neffort=high')" "$OUT" \
    "claude with a model and effort must print all three"

  config=$(new_config verifier-pi-claude)
  printf 'pi anthropic/claude-sonnet-5-5\n' > "$config/verifier-harness"
  run_reader "$config" verifier
  expect_code 0 "$RC" "a multi-provider harness with a named Claude model must read cleanly (stderr: $ERR)"
  assert_equals "$(printf 'harness=pi\nmodel=anthropic/claude-sonnet-5-5\neffort=')" "$OUT" \
    "a multi-provider harness must keep its named Claude model"
  pass "fm-quality-profile: a claude verifier with a named model reads back"
}

test_verifier_claude_without_model_refuses() {
  local config
  config=$(new_config verifier-claude-bare)
  printf 'claude\n' > "$config/verifier-harness"
  run_reader "$config" verifier
  expect_code 2 "$RC" "claude with no model must refuse"
  assert_equals "" "$OUT" "a refused claude setting must print nothing to spawn on"
  assert_contains "$ERR" "verifier-harness" "the refusal must name the setting file"
  assert_contains "$ERR" "claude" "the refusal must name the claude adapter"
  assert_contains "$ERR" "model" "the refusal must say that a model is required"
  pass "fm-quality-profile: a claude verifier with no model refuses"
}

test_verifier_refuses_unverified_or_unnamed_model() {
  local config line
  for line in 'pi' 'opencode' 'cursor' 'omp' 'nosuch' 'nosuch gpt-5.6' 'codex gpt-5.6 high extra'; do
    config=$(new_config "verifier-refuse-$(printf '%s' "$line" | tr -c 'a-zA-Z0-9' '-')")
    printf '%s\n' "$line" > "$config/verifier-harness"
    run_reader "$config" verifier
    expect_code 2 "$RC" "verifier setting '$line' must refuse"
    assert_equals "" "$OUT" "a refused verifier setting '$line' must print nothing to spawn on"
    assert_contains "$ERR" "verifier-harness" "the refusal for '$line' must name the setting file"
  done
  config=$(new_config verifier-empty)
  : > "$config/verifier-harness"
  run_reader "$config" verifier
  expect_code 2 "$RC" "a present but empty verifier setting must refuse rather than guess"
  pass "fm-quality-profile: an unverified adapter or a multi-provider harness with no model refuses"
}

# The reader resolves only what the setting names. Run it with a PATH that has
# neither the codex nor the claude command, so the configured runtime is not
# usable on this host, and check that it never turns to claude by itself.
test_unusable_runtime_never_selects_claude() {
  local config stub tool line expected
  stub="$TMP_ROOT/no-runtime-bin"
  mkdir -p "$stub"
  for tool in bash cat sed grep tr dirname awk; do
    ln -sf "$(command -v "$tool")" "$stub/$tool"
  done
  PATH="$stub" command -v codex >/dev/null 2>&1 && fail "the stub PATH still finds codex"
  PATH="$stub" command -v claude >/dev/null 2>&1 && fail "the stub PATH still finds claude"

  for line in '' 'codex gpt-5.6' 'grok' 'claude' 'nosuch gpt-5.6'; do
    config=$(new_config "verifier-unusable-$(printf 'x%s' "$line" | tr -c 'a-zA-Z0-9' '-')")
    [ -z "$line" ] || printf '%s\n' "$line" > "$config/verifier-harness"
    OUT=$(PATH="$stub" FM_CONFIG_OVERRIDE="$config" "$stub/bash" "$READER" verifier 2>"$TMP_ROOT/stderr"); RC=$?
    ERR=$(cat "$TMP_ROOT/stderr")
    assert_not_contains "$OUT" "harness=claude" "setting '$line' with no usable runtime must not resolve to claude"
    case "$line" in
      '') expected=$(printf 'harness=codex\nmodel=\neffort=') ;;
      'codex gpt-5.6') expected=$(printf 'harness=codex\nmodel=gpt-5.6\neffort=') ;;
      grok) expected=$(printf 'harness=grok\nmodel=\neffort=') ;;
      *) expected="" ;;
    esac
    if [ -n "$expected" ]; then
      expect_code 0 "$RC" "setting '$line' must still resolve to the named runtime (stderr: $ERR)"
    else
      expect_code 2 "$RC" "setting '$line' must refuse rather than fall back"
    fi
    assert_equals "$expected" "$OUT" "setting '$line' must resolve only to what it names"
  done
  pass "fm-quality-profile: an unusable verifier runtime never resolves to claude on its own"
}

# The risk class is a contract: it is stated in full exactly once. A second
# copy anywhere in the tracked material would drift. Each category phrase must
# appear in exactly one tracked file outside tests/, and every phrase must be in
# the same file, which must be the pstack-verifier skill.
test_risk_class_has_one_owner() {
  local phrase files owner=""
  for phrase in 'auth, permissions, or security' 'database schema or data migration' \
    'payments, billing, prices, or balances' 'clinical or legal logic' 'deletion of user data'; do
    files=$(git -C "$ROOT" grep --untracked -l -F -i "$phrase" -- . ':(exclude)tests/' 2>/dev/null)
    [ -n "$files" ] || fail "risk-class phrase '$phrase' appears in no tracked file"
    [ "$(printf '%s\n' "$files" | wc -l | tr -d ' ')" = 1 ] \
      || fail "risk-class phrase '$phrase' appears in more than one tracked file: $(printf '%s' "$files" | tr '\n' ' ')"
    if [ -z "$owner" ]; then
      owner=$files
    else
      assert_equals "$owner" "$files" "risk-class phrase '$phrase' lives outside the owner $owner"
    fi
  done
  assert_equals ".agents/skills/pstack-verifier/SKILL.md" "$owner" \
    "the risk class must be owned by the pstack-verifier skill"
  pass "fm-quality-profile: the verifier risk class has exactly one owner"
}

test_help_prints_usage() {
  local out rc
  out=$("$READER" --help 2>&1); rc=$?
  expect_code 0 "$rc" "--help must succeed"
  assert_contains "$out" "quality-profile" "--help must describe the setting it reads"
  assert_contains "$out" "verifier" "--help must describe the verifier verb"
  pass "fm-quality-profile: --help prints the usage header"
}

test_absent_setting_means_default
test_known_values_read_back
test_unknown_value_refuses
test_verifier_default_is_codex
test_verifier_setting_reads_back
test_verifier_claude_with_named_model_reads_back
test_verifier_claude_without_model_refuses
test_verifier_refuses_unverified_or_unnamed_model
test_unusable_runtime_never_selects_claude
test_risk_class_has_one_owner
test_help_prints_usage
