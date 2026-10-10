#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
class="$ROOT/bin/fm-authority-class.sh"
hold="$ROOT/bin/fm-captain-hold.sh"
[ "$("$class" capacity-reclaim)" = 'owner=firstmate guard=landed-clean-proof' ] || fail 'clean-copy reclamation lost proof guard'
[ "$("$class" model-routing)" = 'owner=firstmate guard=none' ] || fail 'routing escaped Firstmate ownership'
[ "$("$class" empty-commit-discard)" = 'owner=captain guard=captain-word' ] || fail 'empty-commit discard lost explicit captain authority'
[ "$("$class" security)" = 'owner=captain guard=captain-word' ] || fail 'security decision lost captain ownership'
if "$class" unclassified > /dev/null 2>&1; then fail 'unknown class was accepted'; fi
out=$("$hold" hold authority-fixture --reason 'choose worker' --authority-class worker-routing 2>&1) && {
  fail 'routine routing created a captain hold'
}
printf '%s\n' "$out" | grep -q 'Firstmate-owned' || fail "hold did not refuse on authority class: $out"
printf 'ok - routine operations cannot be classified as captain holds\n'
