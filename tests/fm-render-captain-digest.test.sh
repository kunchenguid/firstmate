#!/usr/bin/env bash
# Behavior tests for bin/fm-render-captain-digest.py.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RENDER="$ROOT/bin/fm-render-captain-digest.py"
FIXTURE_UNITS="$ROOT/docs/examples/captain-preference-units/units"
FIXTURE_RELATIONS="$ROOT/docs/examples/captain-preference-units/relations"
FIXTURE_DIGEST="$ROOT/docs/examples/captain-preference-units/digest.md"
TMP_ROOT=$(fm_test_tmproot fm-pref-digest)

test_fixture_digest_is_current() {
  local out
  out=$(python3 "$RENDER" \
    --units-dir "$FIXTURE_UNITS" \
    --relations-dir "$FIXTURE_RELATIONS" \
    --out "$FIXTURE_DIGEST" \
    --check) || fail "fixture digest --check failed: $out"
  assert_contains "$out" "OK " "check did not report OK"
  pass "committed fixture digest matches a fresh render"
}

test_fixture_digest_omits_superseded_unit() {
  local text
  text=$(cat "$FIXTURE_DIGEST")
  assert_contains "$text" "GENERATED FILE - DO NOT EDIT BY HAND" \
    "digest missing generated banner"
  assert_contains "$text" "# GENERATED - DO NOT EDIT" \
    "digest missing visible do-not-edit heading"
  assert_contains "$text" "d-fixture-20260726-001" "active unit 001 missing"
  assert_contains "$text" "d-fixture-20260726-002" "active unit 002 missing"
  assert_contains "$text" "d-fixture-20260726-004" "active unit 004 missing"
  assert_not_contains "$text" "d-fixture-20260726-003" \
    "superseded unit 003 must not appear in the digest body"
  assert_contains "$text" "Report only phase changes a supervisor would act on" \
    "digest did not surface the superseding choice"
  pass "fixture digest is loud-generated and omits superseded units"
}

test_check_detects_stale_digest() {
  local units relations out_file out rc
  units="$TMP_ROOT/stale/units"
  relations="$TMP_ROOT/stale/relations"
  out_file="$TMP_ROOT/stale/digest.md"
  mkdir -p "$units" "$relations"
  cp "$FIXTURE_UNITS"/*.md "$units/"
  cp "$FIXTURE_RELATIONS"/*.md "$relations/"
  python3 "$RENDER" --units-dir "$units" --relations-dir "$relations" --out "$out_file" \
    >/dev/null || fail "initial render failed"
  printf '\n# hand edit that must be detected\n' >> "$out_file"
  set +e
  out=$(python3 "$RENDER" --units-dir "$units" --relations-dir "$relations" --out "$out_file" --check 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "expected --check exit 1 on stale digest, got $rc: $out"
  assert_contains "$out" "STALE " "stale check did not print STALE"
  pass "--check fails closed when the digest was hand-edited"
}

test_rejects_unknown_field_fork() {
  local units out_file out rc
  units="$TMP_ROOT/fork/units"
  out_file="$TMP_ROOT/fork/digest.md"
  mkdir -p "$units"
  cat > "$units/d-fixture-bad-001.md" <<'EOF'
# d-fixture-bad-001

- id: d-fixture-bad-001
- question: Should a preference fork the unit form?
- choice: No.
- rejected: UNKNOWN
- unknown-then: UNKNOWN
- retrigger: On every message.
- provenance: date=2026-07-26; actor=test; basis=test; kind=code
- preference-strength: high
EOF
  set +e
  out=$(python3 "$RENDER" --units-dir "$units" --out "$out_file" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expected exit 2 on unknown field, got $rc: $out"
  assert_contains "$out" "unknown field" "missing unknown-field diagnostic"
  assert_contains "$out" "must not grow a preference fork" \
    "missing fork-refusal diagnostic"
  pass "unknown fields are refused so preferences cannot fork the unit form"
}

test_rejects_filename_id_mismatch() {
  local units out_file out rc
  units="$TMP_ROOT/name/units"
  out_file="$TMP_ROOT/name/digest.md"
  mkdir -p "$units"
  cat > "$units/wrong-name.md" <<'EOF'
# d-fixture-bad-002

- id: d-fixture-bad-002
- question: Does filename equal id?
- choice: Yes it must.
- rejected: UNKNOWN
- unknown-then: UNKNOWN
- retrigger: On every message.
- provenance: date=2026-07-26; actor=test; basis=test; kind=code
EOF
  set +e
  out=$(python3 "$RENDER" --units-dir "$units" --out "$out_file" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expected exit 2 on filename mismatch, got $rc: $out"
  assert_contains "$out" "filename must be" "missing filename diagnostic"
  pass "unit filename must match the id field"
}

test_default_relations_sibling() {
  local tree units out_file text
  tree="$TMP_ROOT/sibling/captain-units"
  units="$tree/units"
  out_file="$tree/digest.md"
  mkdir -p "$units" "$tree/relations"
  cp "$FIXTURE_UNITS"/*.md "$units/"
  cp "$FIXTURE_RELATIONS"/*.md "$tree/relations/"
  python3 "$RENDER" --units-dir "$units" --out "$out_file" >/dev/null \
    || fail "render with default relations sibling failed"
  text=$(cat "$out_file")
  assert_not_contains "$text" "d-fixture-20260726-003" \
    "default relations sibling did not apply supersedes"
  assert_contains "$text" "d-fixture-20260726-004" \
    "default relations sibling lost active unit"
  pass "relations/ sibling of units/ is used when --relations-dir is omitted"
}

test_check_is_cwd_independent() {
  local out
  out=$(cd / && python3 "$RENDER" \
    --units-dir "$FIXTURE_UNITS" \
    --relations-dir "$FIXTURE_RELATIONS" \
    --out "$FIXTURE_DIGEST" \
    --check) || fail "fixture digest --check failed from another cwd: $out"
  assert_contains "$out" "OK " "check from / did not report OK"
  pass "--check verdict does not depend on the working directory"
}

test_explicit_missing_relations_dir_fails() {
  local out_file out rc
  out_file="$TMP_ROOT/norel/digest.md"
  mkdir -p "$TMP_ROOT/norel"
  set +e
  out=$(python3 "$RENDER" \
    --units-dir "$FIXTURE_UNITS" \
    --relations-dir "$FIXTURE_RELATIONS/NOPE" \
    --out "$out_file" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expected exit 2 on missing explicit relations dir, got $rc: $out"
  assert_contains "$out" "relations directory missing" \
    "missing relations-dir diagnostic"
  assert_absent "$out_file" "no digest may be written when the relations dir is bogus"
  pass "an explicitly named relations dir must exist"
}

# write_unit <dir> <id> <question>
write_unit() {
  local dir=$1 id=$2 question=$3
  mkdir -p "$dir"
  cat > "$dir/$id.md" <<EOF
# $id

- id: $id
- question: $question
- choice: A stated choice.
- rejected: UNKNOWN
- unknown-then: UNKNOWN
- retrigger: On every message.
- provenance: date=2026-07-26; actor=test; basis=test; kind=code
EOF
}

# write_relation <dir> <id> <subject> <type> <object>
write_relation() {
  local dir=$1 id=$2 subject=$3 rel_type=$4 object=$5
  mkdir -p "$dir"
  cat > "$dir/$id.md" <<EOF
# $id

- id: $id
- subject: $subject
- type: $rel_type
- object: $object
- provenance: date=2026-07-26; actor=test; basis=test; kind=code
EOF
}

test_rejects_dangling_relation_endpoints() {
  local rel_type endpoint case_dir units relations out_file out rc n=0
  for rel_type in supersedes constrained-by enabled-by; do
    for endpoint in subject object; do
      n=$((n + 1))
      case_dir="$TMP_ROOT/dangling/$n"
      units="$case_dir/units"
      relations="$case_dir/relations"
      out_file="$case_dir/digest.md"
      write_unit "$units" d-fixture-dangle-001 "Does an edge endpoint have to exist?"
      write_unit "$units" d-fixture-dangle-002 "Is a typo'd id caught?"
      if [ "$endpoint" = subject ]; then
        write_relation "$relations" r-fixture-dangle-001 \
          d-fixture-dangle-00X "$rel_type" d-fixture-dangle-002
      else
        write_relation "$relations" r-fixture-dangle-001 \
          d-fixture-dangle-001 "$rel_type" d-fixture-dangle-00X
      fi
      set +e
      out=$(python3 "$RENDER" --units-dir "$units" --relations-dir "$relations" \
        --out "$out_file" 2>&1)
      rc=$?
      set -e
      [ "$rc" -eq 2 ] \
        || fail "expected exit 2 on dangling $endpoint of $rel_type, got $rc: $out"
      assert_contains "$out" "$endpoint 'd-fixture-dangle-00X' does not name an existing unit" \
        "missing dangling-$endpoint diagnostic for $rel_type"
      assert_absent "$out_file" "no digest may be written for a dangling $rel_type edge"
    done
  done
  pass "a dangling subject or object fails closed for every relation type"
}

test_rejects_duplicate_field() {
  local units out_file out rc
  units="$TMP_ROOT/dupe/units"
  out_file="$TMP_ROOT/dupe/digest.md"
  mkdir -p "$units"
  cat > "$units/d-fixture-bad-003.md" <<'EOF'
# d-fixture-bad-003

- id: d-fixture-bad-003
- question: Does a repeated field silently last-win?
- choice: first choice
- choice: second choice
- rejected: UNKNOWN
- unknown-then: UNKNOWN
- retrigger: On every message.
- provenance: date=2026-07-26; actor=test; basis=test; kind=code
EOF
  set +e
  out=$(python3 "$RENDER" --units-dir "$units" --out "$out_file" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expected exit 2 on duplicate field, got $rc: $out"
  assert_contains "$out" "assigned more than once" "missing duplicate-field diagnostic"
  assert_absent "$out_file" "no digest may be written when a field is duplicated"
  pass "a field assigned twice is refused instead of silently last-winning"
}

test_multiline_field_stays_nested() {
  local units out_file text
  units="$TMP_ROOT/multiline/units"
  out_file="$TMP_ROOT/multiline/digest.md"
  mkdir -p "$units"
  cat > "$units/d-fixture-multi-001.md" <<'EOF'
# d-fixture-multi-001

- id: d-fixture-multi-001
- question: Does a nested-bullet value stay nested in the digest?
- choice:
  - part one
  - part two
- rejected: UNKNOWN
- unknown-then: UNKNOWN
- retrigger: On every message.
- provenance: date=2026-07-26; actor=test; basis=test; kind=code
EOF
  python3 "$RENDER" --units-dir "$units" --out "$out_file" >/dev/null \
    || fail "render with a nested-bullet field failed"
  text=$(cat "$out_file")
  assert_contains "$text" "- choice:"$'\n'"  - part one"$'\n'"  - part two" \
    "nested bullets did not stay indented under their field"
  assert_not_contains "$text" $'\n''- part two' \
    "a continuation bullet leaked out as a sibling top-level line"
  pass "a multi-line field value cannot masquerade as extra fields"
}

test_rejects_self_relation() {
  local rel_type case_dir units relations out_file out rc n=0
  for rel_type in supersedes constrained-by enabled-by; do
    n=$((n + 1))
    case_dir="$TMP_ROOT/selfedge/$n"
    units="$case_dir/units"
    relations="$case_dir/relations"
    out_file="$case_dir/digest.md"
    write_unit "$units" d-fixture-self-001 "Can a unit relate to itself?"
    write_relation "$relations" r-fixture-self-001 \
      d-fixture-self-001 "$rel_type" d-fixture-self-001
    set +e
    out=$(python3 "$RENDER" --units-dir "$units" --relations-dir "$relations" \
      --out "$out_file" 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "expected exit 2 on self $rel_type edge, got $rc: $out"
    assert_contains "$out" "a unit cannot relate to itself" \
      "missing self-edge diagnostic for $rel_type"
    assert_absent "$out_file" "no digest may be written for a self $rel_type edge"
  done
  pass "a relation whose subject equals its object is refused"
}

test_rejects_supersedes_cycle() {
  local units relations out_file out rc
  units="$TMP_ROOT/cycle/units"
  relations="$TMP_ROOT/cycle/relations"
  out_file="$TMP_ROOT/cycle/digest.md"
  write_unit "$units" d-fixture-cycle-001 "First unit of a mutual pair."
  write_unit "$units" d-fixture-cycle-002 "Second unit of a mutual pair."
  write_relation "$relations" r-fixture-cycle-001 \
    d-fixture-cycle-001 supersedes d-fixture-cycle-002
  write_relation "$relations" r-fixture-cycle-002 \
    d-fixture-cycle-002 supersedes d-fixture-cycle-001
  set +e
  out=$(python3 "$RENDER" --units-dir "$units" --relations-dir "$relations" \
    --out "$out_file" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expected exit 2 on a mutual supersedes pair, got $rc: $out"
  assert_contains "$out" "supersedes relations form a cycle" \
    "missing cycle diagnostic for a mutual pair"
  assert_absent "$out_file" "no digest may be written for a supersedes cycle"
  pass "a mutual supersedes pair is refused instead of emptying the digest"
}

test_rejects_long_supersedes_cycle() {
  local units relations out_file out rc
  units="$TMP_ROOT/cycle3/units"
  relations="$TMP_ROOT/cycle3/relations"
  out_file="$TMP_ROOT/cycle3/digest.md"
  write_unit "$units" d-fixture-ring-001 "First unit of a three-unit ring."
  write_unit "$units" d-fixture-ring-002 "Second unit of a three-unit ring."
  write_unit "$units" d-fixture-ring-003 "Third unit of a three-unit ring."
  write_unit "$units" d-fixture-ring-004 "A unit outside the ring."
  write_relation "$relations" r-fixture-ring-001 \
    d-fixture-ring-001 supersedes d-fixture-ring-002
  write_relation "$relations" r-fixture-ring-002 \
    d-fixture-ring-002 supersedes d-fixture-ring-003
  write_relation "$relations" r-fixture-ring-003 \
    d-fixture-ring-003 supersedes d-fixture-ring-001
  set +e
  out=$(python3 "$RENDER" --units-dir "$units" --relations-dir "$relations" \
    --out "$out_file" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expected exit 2 on a three-unit supersedes ring, got $rc: $out"
  assert_contains "$out" "supersedes relations form a cycle" \
    "missing cycle diagnostic for a longer ring"
  assert_contains "$out" "d-fixture-ring-001 -> d-fixture-ring-002" \
    "cycle diagnostic did not name the ring path"
  assert_absent "$out_file" "no digest may be written for a longer supersedes cycle"
  pass "a supersedes cycle longer than a mutual pair is refused too"
}

test_supersedes_chain_still_renders() {
  local units relations out_file text
  units="$TMP_ROOT/chain/units"
  relations="$TMP_ROOT/chain/relations"
  out_file="$TMP_ROOT/chain/digest.md"
  write_unit "$units" d-fixture-chain-001 "Oldest unit of a supersedes chain."
  write_unit "$units" d-fixture-chain-002 "Middle unit of a supersedes chain."
  write_unit "$units" d-fixture-chain-003 "Newest unit of a supersedes chain."
  write_relation "$relations" r-fixture-chain-001 \
    d-fixture-chain-002 supersedes d-fixture-chain-001
  write_relation "$relations" r-fixture-chain-002 \
    d-fixture-chain-003 supersedes d-fixture-chain-002
  python3 "$RENDER" --units-dir "$units" --relations-dir "$relations" \
    --out "$out_file" >/dev/null || fail "acyclic supersedes chain failed to render"
  text=$(cat "$out_file")
  assert_contains "$text" "## d-fixture-chain-003" "chain head must stay active"
  assert_not_contains "$text" "## d-fixture-chain-001" "chain tail must be superseded"
  assert_not_contains "$text" "## d-fixture-chain-002" "chain middle must be superseded"
  pass "an acyclic supersedes chain still renders its head"
}

test_empty_unit_tree_renders() {
  local units out_file text
  units="$TMP_ROOT/empty/units"
  out_file="$TMP_ROOT/empty/digest.md"
  mkdir -p "$units"
  python3 "$RENDER" --units-dir "$units" --out "$out_file" >/dev/null \
    || fail "an empty unit tree must still render"
  text=$(cat "$out_file")
  assert_contains "$text" "_No preference units are recorded._" \
    "empty tree did not render the empty marker"
  pass "zero units is a legitimate empty tree, not an error"
}

test_empty_active_set_is_refused() {
  local out rc
  set +e
  out=$(python3 - "$RENDER" <<'PY' 2>&1
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("digest_render", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
# dataclasses resolves __module__ through sys.modules during class creation.
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)

units = {"d-x-001": mod.Unit(path=None, fields={"id": "d-x-001"})}
try:
    mod.refuse_empty_active_set(units, [])
except mod.RenderError as exc:
    print(exc)
    raise SystemExit(2)
raise SystemExit(0)
PY
)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "units present with an empty active set must fail closed, got $rc: $out"
  assert_contains "$out" "would be empty while units exist" \
    "missing empty-active-set diagnostic"
  pass "units present but nothing active is a data error, not a blank digest"
}

test_fixture_digest_is_current
test_check_is_cwd_independent
test_fixture_digest_omits_superseded_unit
test_check_detects_stale_digest
test_rejects_unknown_field_fork
test_rejects_filename_id_mismatch
test_default_relations_sibling
test_explicit_missing_relations_dir_fails
test_rejects_dangling_relation_endpoints
test_rejects_self_relation
test_rejects_supersedes_cycle
test_rejects_long_supersedes_cycle
test_supersedes_chain_still_renders
test_empty_unit_tree_renders
test_empty_active_set_is_refused
test_rejects_duplicate_field
test_multiline_field_stays_nested

echo "# all fm-render-captain-digest tests passed"
