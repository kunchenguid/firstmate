#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCOPE="$ROOT/bin/fm-azure-service-test-scope.py"
CI="$ROOT/.github/workflows/ci.yml"

focused_inventory_contract() {
  local listed count path
  listed=$($SCOPE list) || fail "focused Azure service inventory was unreadable"
  count=$(printf '%s\n' "$listed" | grep -c .)
  [ "$count" -eq 10 ] || fail "focused Azure service inventory did not contain 10 tests"
  [ "$(printf '%s\n' "$listed" | sort -u | grep -c .)" -eq "$count" ] \
    || fail "focused Azure service inventory contains duplicates"
  while IFS= read -r path; do
    [ -x "$ROOT/$path" ] || fail "focused Azure service test is absent or not executable: $path"
    grep -Fqx "${path#tests/}"$'\t''hermetic' "$ROOT/tests/test-capabilities.tsv" \
      || fail "focused Azure service test is not hermetic: $path"
  done <<EOF
$listed
EOF
  pass "focused Azure service inventory contains only ten executable hermetic contracts"
}

mode_falls_back_contract() {
  local tmp repo base focused shell_head broad out rc
  fm_test_tmproot_into tmp fm-azure-service-test-scope
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$SCOPE" "$repo/bin/fm-azure-service-test-scope.py"
  chmod +x "$repo/bin/fm-azure-service-test-scope.py"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name fixture
  git -C "$repo" config user.email fixture@example.invalid
  printf 'base\n' > "$repo/bin/fm-no-mistakes-worker"
  git -C "$repo" add bin/fm-no-mistakes-worker
  git -C "$repo" commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
  printf 'focused\n' >> "$repo/bin/fm-no-mistakes-worker"
  git -C "$repo" commit -qam focused
  focused=$(git -C "$repo" rev-parse HEAD)
  out=$($repo/bin/fm-azure-service-test-scope.py mode "$base" "$focused") \
    || fail "an owned Azure service change could not select focused mode"
  [ "$out" = focused ] || fail "an owned Azure service change selected $out"
  [ -z "$($repo/bin/fm-azure-service-test-scope.py shell "$base" "$focused")" ] \
    || fail "a focused non-shell change invented a lint target"
  printf '#!/bin/sh\n' > "$repo/bin/fm-worker-lifecycle.sh"
  git -C "$repo" add bin/fm-worker-lifecycle.sh
  git -C "$repo" commit -qm focused-shell
  shell_head=$(git -C "$repo" rev-parse HEAD)
  [ "$($repo/bin/fm-azure-service-test-scope.py mode "$base" "$shell_head")" = focused ] \
    || fail "an owned shell change did not preserve focused mode"
  [ "$($repo/bin/fm-azure-service-test-scope.py shell "$base" "$shell_head")" = bin/fm-worker-lifecycle.sh ] \
    || fail "focused lint did not select the exact changed shell file"
  printf 'broad\n' > "$repo/bin/fm-spawn.sh"
  git -C "$repo" add bin/fm-spawn.sh
  git -C "$repo" commit -qm broad
  broad=$(git -C "$repo" rev-parse HEAD)
  out=$($repo/bin/fm-azure-service-test-scope.py mode "$base" "$broad") \
    || fail "a mixed change could not select full mode"
  [ "$out" = full ] || fail "a mixed change escaped full behavior coverage"
  [ "$($repo/bin/fm-azure-service-test-scope.py mode "$base" "$base")" = full ] \
    || fail "an empty diff selected focused behavior coverage"
  rc=0
  $repo/bin/fm-azure-service-test-scope.py mode not-a-sha "$broad" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed comparison identity selected a test mode"
  pass "only an exact owned Azure service diff selects focused mode; everything else runs full"
}

workflow_contract() {
  assert_grep 'python3 bin/fm-azure-service-test-scope.py mode' "$CI" \
    "CI does not derive behavior mode from the reviewed selector"
  assert_grep "if: needs.behavior-test-plan.outputs.mode == 'focused'" "$CI" \
    "CI does not admit the focused behavior job exclusively"
  assert_grep 'FM_TEST_SKIP_HERDR=1 tests/run.sh' "$CI" \
    "focused CI does not run the exact hermetic inventory"
  assert_grep 'needs: [behavior-test-plan, behavior-tests, behavior-tests-focused]' "$CI" \
    "the stable behavior check does not reconcile both execution paths"
  # shellcheck disable=SC2016 # The assertion requires the literal workflow expansion.
  assert_grep 'FOCUSED_RESULT: ${{ needs.behavior-tests-focused.result }}' "$CI" \
    "the stable behavior check does not verify focused execution success"
  # shellcheck disable=SC2016 # The assertion requires the literal workflow expansion.
  assert_grep '*) echo "invalid behavior mode: $BEHAVIOR_MODE" >&2; exit 1 ;;' "$CI" \
    "the stable behavior check can pass without a valid selected mode"
  assert_grep "name: Lint changed Azure service shell files" "$CI" \
    "focused CI does not lint changed service shell files"
  # shellcheck disable=SC2016 # The assertion requires the literal workflow expansion.
  assert_grep 'bin/fm-lint.sh "${files[@]}"' "$CI" \
    "focused CI does not delegate its changed shell files to the canonical lint owner"
  python3 - "$CI" <<'PY' || fail "focused CI still runs the unrelated Agent Fleet package job"
from pathlib import Path
import sys
body = Path(sys.argv[1]).read_text()
block = body.split("\n  agent-fleet:\n", 1)[1].split("\n  invariants:\n", 1)[0]
assert "needs: behavior-test-plan" in block
assert "if: needs.behavior-test-plan.outputs.mode == 'full'" in block
PY
  pass "CI runs focused test and lint paths behind stable required checks and preserves full fallback"
}

focused_inventory_contract
mode_falls_back_contract
workflow_contract
fm_assert_no_cloud_reach "Azure service test scoping reached real cloud tooling"
