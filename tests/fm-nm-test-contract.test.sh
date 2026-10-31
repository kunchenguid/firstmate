#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_has_no_deterministic_test_command() {
  fm_require_yq "parse .no-mistakes.yaml for this contract"
  local json val
  json=$(yq -o=json '.' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  val=$(jq -r '
(. // {}) as $doc
| (if $doc | type == "object" then $doc.commands else error("not a mapping") end) // {}
| (if type == "object" then .test else null end) as $val
| if $val == null or $val == false or $val == "" then "" else $val | tojson end
' <<<"$json") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$val" ]; then
    fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

test_nm_has_no_deterministic_test_command
