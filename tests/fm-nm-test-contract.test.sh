#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave the commands.test key absent
# and must define a non-empty test.instructions value under the test key.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_has_no_deterministic_test_command() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"]
puts (cmds.is_a?(Hash) && cmds.key?("test")) ? cmds["test"].inspect : ""
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$val" ]; then
    fail "commands.test must be absent so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

test_nm_has_no_deterministic_test_command

test_nm_has_test_instructions() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
test = doc["test"]
instructions = test.is_a?(Hash) ? test["instructions"] : nil
puts (instructions.is_a?(String) && !instructions.empty?) ? "ok" : ""
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ "$val" != "ok" ]; then
    fail "test.instructions must be a non-empty string under the test key"
  fi
  pass "no-mistakes configures non-empty test.instructions"
}

test_nm_has_test_instructions
