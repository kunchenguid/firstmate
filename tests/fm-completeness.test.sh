#!/usr/bin/env bash
# Tests for bin/fm-completeness-check.sh (the formal completeness gate).
#
# Two tiers:
#   - Tooling-agnostic (always run): the off-switch, fail-open behavior, strict
#     enforcement, argument parsing. These must hold even where z3 is not
#     installed (e.g. CI), because the gate is designed to FAIL OPEN and never
#     wedge the lifecycle.
#   - Solver-dependent (run only when z3 imports): the actual SAT/UNSAT verdicts
#     for the invariant matrix.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/bin/fm-completeness-check.sh"
TMP_ROOT=

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
skip() { printf 'ok - %s # SKIP\n' "$1"; }

cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-completeness-tests.XXXXXX")

# rc_of runs the gate with the given args and echoes its exit code (never aborts).
rc_of() {
  set +e
  "$GATE" "$@" >/dev/null 2>&1
  local rc=$?
  set -e
  printf '%s' "$rc"
}

# --- Shipped defaults --------------------------------------------------------

# Every verdict below that does not override FM_COMPLETENESS_RULES is decided by
# the shipped rules file and engine, so their absence would silently turn this
# whole suite into a fail-open no-op that still prints ok.
[ -f "$ROOT/bin/fm-completeness.rules.json" ] \
  || fail "the shipped rules file bin/fm-completeness.rules.json is missing"
[ -x "$ROOT/bin/fm-completeness.py" ] \
  || fail "the shipped engine bin/fm-completeness.py is missing or not executable"
pass "the gate ships its default rules file and engine"

# --- Tooling-agnostic tier ---------------------------------------------------

# Off-switch always yields 0 regardless of facts.
if [ "$(FM_COMPLETENESS_GATE=0 "$GATE" --kind scout --report absent >/dev/null 2>&1; echo $?)" = "0" ]; then
  pass "off-switch FM_COMPLETENESS_GATE=0 exits 0"
else
  fail "off-switch did not exit 0"
fi

# Fail-open: a broken rules path is non-fatal by default.
if [ "$(FM_COMPLETENESS_RULES=/no/such.json "$GATE" --kind scout --report present >/dev/null 2>&1; echo $?)" = "0" ]; then
  pass "fail-open on missing rules file exits 0"
else
  fail "missing rules file did not fail open"
fi

# Strict mode turns the same breakage into a hard error (exit 3).
if [ "$(FM_COMPLETENESS_STRICT=1 FM_COMPLETENESS_RULES=/no/such.json "$GATE" --kind scout --report present >/dev/null 2>&1; echo $?)" = "3" ]; then
  pass "FM_COMPLETENESS_STRICT=1 enforces (exit 3) on tooling breakage"
else
  fail "strict mode did not enforce on tooling breakage"
fi

# A corrupt (unparseable) rules file is tooling breakage too: fail-open by
# default, hard error under strict - never a wedged lifecycle.
printf '{ not json' > "$TMP_ROOT/corrupt.json"
if [ "$(FM_COMPLETENESS_RULES="$TMP_ROOT/corrupt.json" "$GATE" --kind scout --report present >/dev/null 2>&1; echo $?)" = "0" ]; then
  pass "fail-open on corrupt rules file exits 0"
else
  fail "corrupt rules file did not fail open"
fi
if [ "$(FM_COMPLETENESS_STRICT=1 FM_COMPLETENESS_RULES="$TMP_ROOT/corrupt.json" "$GATE" --kind scout --report present >/dev/null 2>&1; echo $?)" = "3" ]; then
  pass "strict mode enforces (exit 3) on corrupt rules file"
else
  fail "strict mode did not enforce on corrupt rules file"
fi

# Unknown argument is a usage error.
if [ "$(rc_of --bogus x)" = "64" ]; then
  pass "unknown argument exits 64"
else
  fail "unknown argument did not exit 64"
fi

# An undeclared axis value is a typo, not a pass: blocking usage error, never
# fail-open, even where the solver is absent.
if [ "$(rc_of --kind ship --landed nonne)" = "64" ]; then
  pass "undeclared axis value exits 64 (blocking, not fail-open)"
else
  fail "undeclared axis value did not exit 64"
fi
if [ "$(rc_of --kind ship --landed pushed --meta 'bad key')" = "64" ]; then
  pass "malformed --meta key exits 64"
else
  fail "malformed --meta key did not exit 64"
fi

# The rules file is the single owner of the axis vocabulary: a value it declares
# must be accepted even though the shipped file has never heard of it, or a
# rules-file edit would wedge teardown and the local merge (both treat 64 as
# blocking) instead of routing through the fail-open path.
python3 - "$ROOT/bin/fm-completeness.rules.json" "$TMP_ROOT/extra-kind.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    rules = json.load(handle)
rules["axes"]["kind"] = list(rules["axes"]["kind"]) + ["surveyor"]
with open(sys.argv[2], "w") as handle:
    json.dump(rules, handle)
PY
if [ "$(FM_COMPLETENESS_RULES="$TMP_ROOT/extra-kind.json" "$GATE" --kind surveyor --landed pushed --worktree clean >/dev/null 2>&1; echo $?)" = "0" ]; then
  pass "an axis value the active rules file declares is accepted, not rejected as invalid facts"
else
  fail "a value declared by the active rules file was not accepted"
fi
if [ "$(FM_COMPLETENESS_RULES="$TMP_ROOT/extra-kind.json" "$GATE" --kind surveyorr --landed pushed >/dev/null 2>&1; echo $?)" = "64" ]; then
  pass "a value the active rules file does not declare still exits 64"
else
  fail "a value undeclared by the active rules file did not exit 64"
fi

# A rules file with no axes at all is rules breakage, not invalid facts.
printf '{"hard_rules": [], "soft_rules": []}' > "$TMP_ROOT/no-axes.json"
if [ "$(FM_COMPLETENESS_RULES="$TMP_ROOT/no-axes.json" "$GATE" --kind ship --landed pushed >/dev/null 2>&1; echo $?)" = "0" ]; then
  pass "a rules file without an axes object fails open"
else
  fail "a rules file without an axes object did not fail open"
fi
if [ "$(FM_COMPLETENESS_STRICT=1 FM_COMPLETENESS_RULES="$TMP_ROOT/no-axes.json" "$GATE" --kind ship --landed pushed >/dev/null 2>&1; echo $?)" = "3" ]; then
  pass "strict mode enforces on a rules file without an axes object"
else
  fail "strict mode did not enforce on a rules file without an axes object"
fi

# A blocked claim must name the invariant it violated from the engine's own
# result, not from whichever key happens to be serialized next to it. This stub
# engine emits a BLOCKED verdict with no "counterexample" key at all: the naming
# has to survive that field being pruned.
STUB_DIR="$TMP_ROOT/stub-engine"
mkdir -p "$STUB_DIR"
cp "$GATE" "$STUB_DIR/fm-completeness-check.sh"
# Only the engine is stubbed: the wrapper reads its axis vocabulary from the
# rules file beside it, exactly as the engine resolves it.
cp "$ROOT/bin/fm-completeness.rules.json" "$STUB_DIR/fm-completeness.rules.json"
cat > "$STUB_DIR/fm-completeness.py" <<'PY'
import json
import sys

sys.stdin.read()
print(json.dumps({
    "sat": False,
    "reason": "[SHIP_REQUIRES_LANDED] a ship task must be landed",
    "violated_rules": ["SHIP_REQUIRES_LANDED"],
    "compliance": 1.0,
    "unmet_soft": [],
    "mode": "strict",
}))
sys.exit(2)
PY
set +e
stub_err=$("$STUB_DIR/fm-completeness-check.sh" --kind ship --landed none --worktree holds_unlanded_work 2>&1 >/dev/null)
stub_rc=$?
set -e
if [ "$stub_rc" = "2" ]; then
  pass "a blocked verdict from an engine result without a counterexample key still exits 2"
else
  fail "blocked verdict without a counterexample key did not exit 2 (rc=$stub_rc)"
fi
case "$stub_err" in
  *"violated: SHIP_REQUIRES_LANDED"*) pass "a blocked verdict names its violated rule without the dead counterexample key" ;;
  *) fail "blocked verdict lost its violated-rule naming: $stub_err" ;;
esac
case "$stub_err" in
  *"reason: [SHIP_REQUIRES_LANDED] a ship task must be landed"*) pass "a blocked verdict still cites the engine's reason" ;;
  *) fail "blocked verdict lost its reason: $stub_err" ;;
esac

# Exit 0 is the gate's only proceed signal, so a caller must block on any other
# rc - including the ones the gate itself never issues. A wrapper that is missing
# or has lost its exec bit after a partial update yields 127/126, and reading
# that as approval would step aside from a check that never ran.
BROKEN_ROOT="$TMP_ROOT/broken-root"
MERGE_HOME="$TMP_ROOT/merge-home"
mkdir -p "$BROKEN_ROOT/bin" "$MERGE_HOME/state"
printf 'kind=ship\nmode=local-only\nworktree=%s\nproject=%s\n' "$TMP_ROOT/wt-b" "$TMP_ROOT/proj-b" \
  > "$MERGE_HOME/state/ship-b.meta"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BROKEN_ROOT/bin/fm-completeness-check.sh"
chmod 0644 "$BROKEN_ROOT/bin/fm-completeness-check.sh"
assert_merge_local_blocks() {
  local desc=$1 out rc
  set +e
  out=$(FM_ROOT_OVERRIDE="$BROKEN_ROOT" FM_HOME="$MERGE_HOME" FM_CAPTAIN_APPROVED=granted \
    "$ROOT/bin/fm-merge-local.sh" ship-b 2>&1)
  rc=$?
  set -e
  [ "$rc" != "0" ] || fail "$desc: fm-merge-local.sh proceeded past a gate that could not run"
  case "$out" in
    *"REFUSED: completeness gate blocked the local merge"*) pass "$desc" ;;
    *) fail "$desc: the refusal did not come from the completeness gate: $out" ;;
  esac
}
assert_merge_local_blocks "fm-merge-local.sh blocks when the gate script is not executable"
rm -f "$BROKEN_ROOT/bin/fm-completeness-check.sh"
assert_merge_local_blocks "fm-merge-local.sh blocks when the gate script is missing"

# --- Solver-dependent tier ---------------------------------------------------

if ! python3 -c "import z3" >/dev/null 2>&1; then
  skip "solver matrix (z3 not importable)"
  skip "solver --id derivation (z3 not importable)"
  exit 0
fi

assert_rc() {
  local want=$1 desc=$2; shift 2
  local got; got=$(rc_of "$@")
  if [ "$got" = "$want" ]; then pass "$desc"; else fail "$desc (rc=$got want=$want)"; fi
}

# Hard invariants gate (exit 2 = UNSAT/blocked, 0 = SAT/clear).
assert_rc 2 "scout without report is blocked"          --kind scout --report absent
assert_rc 0 "scout with report clears"                 --kind scout --report present
assert_rc 2 "ship not landed is blocked"               --kind ship --landed none --worktree holds_unlanded_work
assert_rc 0 "ship pushed + clean clears"               --kind ship --landed pushed --worktree clean
assert_rc 2 "merge without approval is blocked"        --gate merge --kind ship --landed merged --captain-approval pending
assert_rc 0 "merge with approval clears"               --gate merge --kind ship --landed merged --captain-approval granted

# Merge gate reads approval from the environment (directive #2 explicit assert).
if [ "$(FM_CAPTAIN_APPROVED=granted "$GATE" --gate merge --kind ship --landed merged >/dev/null 2>&1; echo $?)" = "0" ]; then
  pass "merge gate honors FM_CAPTAIN_APPROVED=granted"
else
  fail "merge gate did not honor FM_CAPTAIN_APPROVED=granted"
fi
if [ "$("$GATE" --gate merge --kind ship --landed merged >/dev/null 2>&1; echo $?)" = "2" ]; then
  pass "merge gate blocks when approval unset (defaults pending)"
else
  fail "merge gate did not block with approval unset"
fi

# Graded mode never blocks on a soft-only miss, but reports it.
assert_rc 0 "graded ship is SAT despite unmet soft rules" \
  --mode graded --kind ship --landed merged --captain-approval granted --worktree clean

# --id derivation from a synthetic meta + report.
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/scout-x"
printf 'kind=scout\nmode=no-mistakes\nworktree=%s\nproject=%s\n' "$TMP_ROOT/wt" "$TMP_ROOT/proj" > "$HOME_DIR/state/scout-x.meta"
# No report yet -> blocked.
if [ "$(FM_HOME="$HOME_DIR" "$GATE" --gate teardown --id scout-x >/dev/null 2>&1; echo $?)" = "2" ]; then
  pass "--id scout derivation blocks with no report"
else
  fail "--id scout derivation did not block without report"
fi
# Write the report -> clears.
printf '# report\n' > "$HOME_DIR/data/scout-x/report.md"
if [ "$(FM_HOME="$HOME_DIR" "$GATE" --gate teardown --id scout-x >/dev/null 2>&1; echo $?)" = "0" ]; then
  pass "--id scout derivation clears once report exists"
else
  fail "--id scout derivation did not clear with report present"
fi

# A self-contradictory rules file is a bug in the directives: prove_consistency
# rejects it and the gate fails open rather than issuing verdicts from nonsense.
cat > "$TMP_ROOT/contradictory.json" <<'JSON'
{
  "axes": {"kind": ["ship", "scout", "secondmate"], "landed": ["merged", "pushed", "local_merged", "none"], "report": ["present", "absent"], "worktree": ["clean", "holds_unlanded_work"], "captain_approval": ["granted", "not_required", "pending"]},
  "hard_rules": [
    {"name": "A", "require": {"worktree": "clean"}, "reason": "x"},
    {"name": "B", "forbid": {"worktree": "clean"}, "reason": "y"}
  ],
  "soft_rules": []
}
JSON
if [ "$(FM_COMPLETENESS_RULES="$TMP_ROOT/contradictory.json" "$GATE" --kind scout --report present >/dev/null 2>&1; echo $?)" = "0" ]; then
  pass "contradictory rules file fails open"
else
  fail "contradictory rules file did not fail open"
fi
if [ "$(FM_COMPLETENESS_STRICT=1 FM_COMPLETENESS_RULES="$TMP_ROOT/contradictory.json" "$GATE" --kind scout --report present >/dev/null 2>&1; echo $?)" = "3" ]; then
  pass "strict mode enforces on contradictory rules file"
else
  fail "strict mode did not enforce on contradictory rules file"
fi

# A malformed soft-rule weight is a rules-file defect, not invalid facts: it
# fails open like any other broken rules file (exit 64 stays reserved for the
# caller's own facts).
cat > "$TMP_ROOT/badweight.json" <<'JSON'
{
  "axes": {"kind": ["ship", "scout", "secondmate"], "landed": ["merged", "pushed", "local_merged", "none"], "report": ["present", "absent"], "worktree": ["clean", "holds_unlanded_work"], "captain_approval": ["granted", "not_required", "pending"]},
  "hard_rules": [],
  "soft_rules": [
    {"name": "S", "when": {"kind": "scout"}, "weight": "heavy", "require_meta": "backlog_recorded", "reason": "z"}
  ]
}
JSON
if [ "$(FM_COMPLETENESS_RULES="$TMP_ROOT/badweight.json" "$GATE" --mode graded --kind scout --report present >/dev/null 2>&1; echo $?)" = "0" ]; then
  pass "malformed soft-rule weight fails open"
else
  fail "malformed soft-rule weight did not fail open"
fi
if [ "$(FM_COMPLETENESS_STRICT=1 FM_COMPLETENESS_RULES="$TMP_ROOT/badweight.json" "$GATE" --mode graded --kind scout --report present >/dev/null 2>&1; echo $?)" = "3" ]; then
  pass "strict mode enforces on malformed soft-rule weight"
else
  fail "strict mode did not enforce on malformed soft-rule weight"
fi

# Local-only derivation mirrors fm-teardown.sh's main-or-master fallback: a
# repo whose default branch is master must still block on unmerged work.
PROJ="$TMP_ROOT/proj-master"
git -c init.defaultBranch=master init -q "$PROJ"
git -C "$PROJ" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$PROJ" checkout -q -b fm/ship-m
git -C "$PROJ" -c user.email=t@t -c user.name=t commit -q --allow-empty -m unmerged
mkdir -p "$HOME_DIR/data/ship-m"
printf 'kind=ship\nmode=local-only\nworktree=%s\nproject=%s\n' "$PROJ" "$PROJ" > "$HOME_DIR/state/ship-m.meta"
if [ "$(FM_HOME="$HOME_DIR" "$GATE" --gate teardown --id ship-m >/dev/null 2>&1; echo $?)" = "2" ]; then
  pass "local-only master-default repo with unmerged work is blocked"
else
  fail "local-only master-default repo with unmerged work was not blocked"
fi
git -C "$PROJ" checkout -q master
git -C "$PROJ" merge -q --ff-only fm/ship-m
if [ "$(FM_HOME="$HOME_DIR" "$GATE" --gate teardown --id ship-m >/dev/null 2>&1; echo $?)" = "0" ]; then
  pass "local-only master-default repo clears once merged"
else
  fail "local-only master-default repo did not clear after merge"
fi

# Firstmate's own untracked residue is not the crewmate's work: the gate runs
# before fm-teardown.sh's validate_worktree_teardown_safety and rc 2 hard-refuses,
# so both must ignore exactly the same markers or the gate blocks a teardown the
# guarded check would allow.
mkdir -p "$PROJ/.claude"
printf 'x\n' > "$PROJ/.claude/settings.json"
printf 'token=t\n' > "$PROJ/.fm-grok-turnend"
printf 'token=t\n' > "$PROJ/.fm-kimi-turnend"
if [ "$(FM_HOME="$HOME_DIR" "$GATE" --gate teardown --id ship-m >/dev/null 2>&1; echo $?)" = "0" ]; then
  pass "firstmate turn-end markers and .claude/ are not unlanded work"
else
  fail "firstmate turn-end markers blocked a teardown fm-teardown.sh allows"
fi
printf 'real\n' > "$PROJ/uncommitted.txt"
if [ "$(FM_HOME="$HOME_DIR" "$GATE" --gate teardown --id ship-m >/dev/null 2>&1; echo $?)" = "2" ]; then
  pass "a genuinely dirty worktree still blocks"
else
  fail "a genuinely dirty worktree was not blocked"
fi
