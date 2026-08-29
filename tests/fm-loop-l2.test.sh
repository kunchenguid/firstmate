#!/usr/bin/env bash
# L2: loop-audit readiness gate. The globally installed loop-audit CLI must
# score this repo at level L2 or better (score >= 58). The level is earned by
# the loop docs + verifier legibility (spec: docs/specs/2026-07-03-loop-conformance.md);
# we pin >= L2, not L3 - the tool's activity heuristics are lenient and L3 is
# only claimed when real run-log entries accumulate.
# Mutation (LEDGER_MUTATE=1): the SAME assertion runs against a stripped copy
# (AGENTS.md only - no STATE.md/LOOP.md/loop docs/agents) - a correct audit
# scores it far below 58, failing the assertion.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v loop-audit >/dev/null 2>&1 || {
  # See tests/run-all.sh: exit 2 is only treated as a skip when the test says so.
  echo "PREREQUISITE MISSING: loop-audit CLI not on PATH - install: npm i -g @cobusgreyling/loop-audit" >&2
  exit 2
}

TARGET="$ROOT"
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  TMP=$(fm_test_tmproot fm-loop-l2)
  TARGET="$TMP/stripped"
  mkdir -p "$TARGET"
  cp "$ROOT/AGENTS.md" "$TARGET/AGENTS.md"
fi

# loop-audit itself exits 2 when score < 40, so tolerate the exit code and
# judge purely on the parsed JSON (an empty capture also fails the parse).
out=$(loop-audit "$TARGET" --json 2>/dev/null || true)
JSON_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-loop-l2.XXXXXX")
printf '%s' "$out" > "$JSON_TMP"
python3 - "$JSON_TMP" <<'PY' || { rm -f "$JSON_TMP"; fail "loop-audit must report level L2 or better (score >= 58)"; }
import json, sys
d = json.load(open(sys.argv[1]))
assert d["score"] >= 58, (d["score"], d["level"])
assert d["level"] in ("L2", "L3"), d["level"]
PY
rm -f "$JSON_TMP"

pass "L2 loop-audit level"
