#!/usr/bin/env bash
# Contracts for Firstmate's parsed no-mistakes repository configuration.
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
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts (val.nil? || val == false || val == "") ? "" : val.inspect
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$val" ]; then
    fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

test_nm_selects_pipeline_agent_dynamically() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
puts doc["agent"]
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  [ "$val" = auto ] \
    || fail "agent must be auto so Firstmate does not inherit a machine-global fixed pipeline agent; got: $val"
  pass "no-mistakes resolves Firstmate's pipeline agent dynamically"
}

test_nm_has_no_deterministic_test_command
test_nm_selects_pipeline_agent_dynamically
