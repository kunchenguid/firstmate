#!/usr/bin/env bash
# m0: the gate harness itself loads, and it fails loudly on a broken ledger.
#
# Two assertions, in this order:
#
#   A. This repo's REAL gates/ledger.json conforms to the shape the installed
#      `ledger` CLI requires: top-level `gates` is a JSON ARRAY. Commit fa04182
#      reshaped it to an object keyed by id, which makes every `ledger`
#      subcommand abort in validateLedger() before doing any work - so no gate
#      in this repo could be verified at all. This assertion is a pure READ of
#      the checked-in file; it never invokes `ledger` against the real gates/
#      dir, so it cannot recurse and cannot rewrite tracked ledger state.
#
#   B. The harness fails LOUDLY, not silently, when a ledger is broken - proved
#      against ISOLATED FIXTURE dirs under a temp root, never against this
#      repo's gates/. A fixture whose `gates` is an object must make
#      `ledger verify --dir <fixture>` exit non-zero AND say so on stderr; the
#      well-formed twin must not produce that schema abort.
#
# Why B is deliberately NOT "run gates/verify.sh and check the exit code":
# `ledger verify` is not a read-only checker. It execSync's every gate's
# test_ref, then saveLedger() + writeView() rewrite gates/ledger.json and
# gates/LEDGER.md. A gate whose test_ref re-entered gates/verify.sh would
# re-run all 20 suites, recurse into itself unboundedly, and rewrite tracked
# ledger state mid-test. Fixture dirs are the whole point.
#
# Mutation (LEDGER_MUTATE=1): assertion A is inverted to demand the BROKEN
# object shape - a repaired ledger then fails it, proving the assertion is
# keyed to the real file and not vacuously true.
#
# spec: docs/specs/2026-08-27-n-concurrent-firstmates.md
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEDGER_JSON="$ROOT/gates/ledger.json"
assert_present "$LEDGER_JSON" "gates/ledger.json must exist"

# --- A. the real ledger's shape (pure read; no `ledger` invocation) ----------
shape=$(python3 - "$LEDGER_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(type(d.get("gates")).__name__)
PY
) || fail "gates/ledger.json must be parseable JSON"

if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  [ "$shape" = dict ] \
    || fail "MUTATION: expected the broken object shape, got '$shape'"
else
  [ "$shape" = list ] \
    || fail "gates/ledger.json 'gates' must be a JSON array (got '$shape') - the installed ledger CLI aborts in validateLedger() on any other shape, so no gate in this repo can be verified"
fi

# Every entry must still carry its own id, and the array must hold them all.
python3 - "$LEDGER_JSON" <<'PY' || fail "every gate entry must carry a non-empty string id"
import json, sys
d = json.load(open(sys.argv[1]))
g = d["gates"]
entries = g if isinstance(g, list) else list(g.values())
assert entries, "ledger holds no gates"
for e in entries:
    assert isinstance(e.get("id"), str) and e["id"], e
ids = [e["id"] for e in entries]
assert len(ids) == len(set(ids)), "duplicate gate ids"
PY

# --- B. loud failure on a broken ledger, against isolated fixtures -----------
command -v ledger >/dev/null 2>&1 || {
  # The marker is what makes this a SKIP rather than a failure. tests/run-all.sh
  # will not infer a skip from the exit code alone, because bash also exits 2 on
  # a syntax error and a broken test must never be laundered into a green build.
  echo "PREREQUISITE MISSING: ledger CLI not on PATH - install via claude-pm-system/scripts/install-global.sh" >&2
  exit 2
}

TMP=$(fm_test_tmproot fm-boot-m0)
GOOD="$TMP/good"; BROKEN="$TMP/broken"
mkdir -p "$GOOD" "$BROKEN"

# One trivially-passing gate. `true` as test_ref keeps the fixture from
# executing anything of this repo's, so verify stays fast and side-effect-free
# outside the temp root.
cat > "$GOOD/ledger.json" <<'JSON'
{
  "version": 1,
  "gates": [
    {
      "id": "fixture-1",
      "title": "fixture",
      "observable": "fixture gate used only to exercise ledger's schema validator",
      "origin_mode": "build",
      "spec_ref": "docs/specs/2026-08-27-n-concurrent-firstmates.md",
      "blocked_by": [],
      "test_ref": "true",
      "baseline_ref": null,
      "first_observed_red": null,
      "mutation_verified": null,
      "status": "unproven",
      "vacuous": false,
      "regression": false,
      "created": "2026-08-27T00:00:00Z",
      "last_verified": null
    }
  ]
}
JSON

# The broken twin: identical content, `gates` reshaped to an object keyed by id
# - exactly the regression this gate exists to catch.
python3 - "$GOOD/ledger.json" "$BROKEN/ledger.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["gates"] = {g["id"]: g for g in d["gates"]}
open(sys.argv[2], "w").write(json.dumps(d, indent=2) + "\n")
PY

SCHEMA_ERR="gates must be an array"

# Hash this repo's tracked gate files so we can prove the fixture runs never
# touched them. Compared by content, not by git status, so the assertion holds
# whether or not the working tree is otherwise clean.
before=$(shasum "$ROOT/gates/ledger.json" "$ROOT/gates/LEDGER.md" | awk '{print $1}')

broken_out=$(ledger verify --dir "$BROKEN" 2>&1); broken_code=$?
[ "$broken_code" -ne 0 ] \
  || fail "a broken ledger must make 'ledger verify' exit non-zero (got 0)"
assert_contains "$broken_out" "$SCHEMA_ERR" \
  "a broken ledger must fail LOUDLY, naming the schema violation on stderr"

good_out=$(ledger verify --dir "$GOOD" 2>&1) || true
assert_not_contains "$good_out" "$SCHEMA_ERR" \
  "a well-formed ledger must not trip the array-shape validator"

# The fixture runs must not have reached outside their own temp dirs.
assert_present "$GOOD/ledger.json" "fixture ledger survives its own verify"
after=$(shasum "$ROOT/gates/ledger.json" "$ROOT/gates/LEDGER.md" | awk '{print $1}')
[ "$before" = "$after" ] \
  || fail "fixture verify must not have modified this repo's gates/ledger.json or gates/LEDGER.md"

pass "m0 ledger shape + loud failure on a broken ledger"
