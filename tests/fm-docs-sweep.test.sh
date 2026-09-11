#!/usr/bin/env bash
# Behavior tests for bin/fm-docs-sweep.sh / bin/fm-docs-sweep.py.
#
# fm-docs-sweep is a read-only, model-free documentation hygiene scan: every
# test here builds a small fixture tree, runs the real executable against it,
# and asserts on the JSON it prints - never on the Python source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/fm-docs-sweep.sh"

# jget <json-text> <dotted.path>: pull one field out of the tool's JSON
# output via a tiny stdlib json walk, so assertions read structured values
# instead of grepping raw text.
jget() {
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
path = sys.argv[2].split(".")
for p in path:
    if isinstance(d, list):
        d = d[int(p)]
    else:
        d = d[p]
print(d if isinstance(d, str) else json.dumps(d))
' "$1" "$2"
}

build_fixture() {
  local root=$1
  mkdir -p "$root/repoA" "$root/repoB"
  git -C "$root/repoA" init -q
  git -C "$root/repoB" init -q

  cat > "$root/repoA/AGENTS.md" <<'EOF'
# Agent Rules

## Merge Authority
Always merge with yolo enabled and never wait for approval.
Ship fast and trust the pipeline.

## Delivery Mode
Use direct-PR for everything.
EOF

  cat > "$root/repoB/AGENTS.md" <<'EOF'
# Agent Rules

## Merge Authority
Never merge without explicit captain approval on every single pull request.
Wait for the human every time before landing anything.

## Delivery Mode
Use no-mistakes for everything, always.
EOF

  cp "$root/repoA/AGENTS.md" "$root/repoA/AGENTS_copy.md"

  cat > "$root/repoA/notes.md" <<'EOF'
# Notes

See [missing](./missing-target.md) and check `bin/does-not-exist.sh`.

- [ ] open task one
TODO: fix this later
Build a todo app with one small hack and a 555-xxx placeholder.
EOF
}

test_inventory_counts_files_bytes_and_buckets() {
  local tmp out
  tmp=$(fm_test_tmproot fm-docs-sweep)
  build_fixture "$tmp/fixture"

  out=$("$SWEEP" --root "$tmp/fixture" 2>&1)
  expect_code 0 "$?" "sweep must exit 0 on a clean fixture"

  assert_equals "4" "$(jget "$out" inventory.files)" "inventory counts every scanned .md file"
  assert_equals "repoA" "$(jget "$out" inventory.buckets.0.bucket)" "the larger bucket (repoA) sorts first"
  pass "fm-docs-sweep: inventory reports file count and per-bucket breakdown"
}

test_exact_duplicate_detected_by_hash() {
  local tmp out
  tmp=$(fm_test_tmproot fm-docs-sweep)
  build_fixture "$tmp/fixture"

  out=$("$SWEEP" --root "$tmp/fixture" 2>&1)
  assert_equals "1" "$(jget "$out" exact_duplicates.groups)" "AGENTS.md and its byte-identical copy form one exact-duplicate group"
  assert_contains "$out" "AGENTS_copy.md" "the exact-duplicate group names the copy"
  pass "fm-docs-sweep: exact duplicates are grouped by sha256"
}

test_conflict_candidate_needs_same_heading_different_repos_diverging_body() {
  local tmp out
  tmp=$(fm_test_tmproot fm-docs-sweep)
  build_fixture "$tmp/fixture"

  out=$("$SWEEP" --root "$tmp/fixture" 2>&1)
  local total
  total=$(jget "$out" conflict_candidates.total)
  assert_equals "2" "$total" "repoA and repoB AGENTS.md share two headings with diverging bodies"
  assert_contains "$out" '"heading": "merge authority"' "conflict candidate names the shared heading"
  assert_contains "$out" '"file_a": "repoA/AGENTS.md"' "conflict candidate names the first file"
  assert_contains "$out" '"file_b": "repoB/AGENTS.md"' "conflict candidate names the second file"
  pass "fm-docs-sweep: a shared heading with a diverging body is a conflict candidate, never full section text"
}

test_conflict_candidates_never_carry_section_body_text() {
  local tmp out
  tmp=$(fm_test_tmproot fm-docs-sweep)
  build_fixture "$tmp/fixture"

  out=$("$SWEEP" --root "$tmp/fixture" 2>&1)
  assert_not_contains "$out" "yolo enabled" "conflict candidates must never leak repoA's section body text"
  assert_not_contains "$out" "captain approval on every single" "conflict candidates must never leak repoB's section body text"
  pass "fm-docs-sweep: conflict candidates stay small - file pair and heading only, never body text"
}

test_near_identical_section_is_not_a_conflict_candidate() {
  local tmp out
  tmp=$(fm_test_tmproot fm-docs-sweep)
  mkdir -p "$tmp/fixture/repoA" "$tmp/fixture/repoB"
  git -C "$tmp/fixture/repoA" init -q
  git -C "$tmp/fixture/repoB" init -q
  cat > "$tmp/fixture/repoA/AGENTS.md" <<'EOF'
# Rules

## Merge Authority
Never merge without explicit captain approval on every pull request opened here.
EOF
  cat > "$tmp/fixture/repoB/AGENTS.md" <<'EOF'
# Rules

## Merge Authority
Never merge without explicit captain approval on every pull request opened there.
EOF

  out=$("$SWEEP" --root "$tmp/fixture" 2>&1)
  assert_equals "0" "$(jget "$out" conflict_candidates.total)" "a near-identical restated section is a duplicate, not a conflict"
  pass "fm-docs-sweep: near-identical section bodies under a shared heading are excluded from conflict candidates"
}

test_broken_link_and_stale_reference_detected() {
  local tmp out
  tmp=$(fm_test_tmproot fm-docs-sweep)
  build_fixture "$tmp/fixture"

  out=$("$SWEEP" --root "$tmp/fixture" 2>&1)
  assert_equals "1" "$(jget "$out" broken_links.total)" "the one dangling relative link is found"
  assert_contains "$out" "missing-target.md" "broken link names the missing target"
  assert_equals "1" "$(jget "$out" stale_references.total)" "the one nonexistent backtick path reference is found"
  assert_contains "$out" "does-not-exist.sh" "stale reference names the missing path"
  pass "fm-docs-sweep: broken relative links and stale inline path references are both surfaced"
}

test_todo_and_checklist_extraction() {
  local tmp out
  tmp=$(fm_test_tmproot fm-docs-sweep)
  build_fixture "$tmp/fixture"

  out=$("$SWEEP" --root "$tmp/fixture" 2>&1)
  assert_equals "2" "$(jget "$out" todos.total)" "one open checklist item and one TODO marker are counted; lowercase prose 'todo'/'hack'/'xxx' is not"
  assert_contains "$out" "open task one" "checklist item text is extracted"
  assert_contains "$out" "fix this later" "TODO marker text is extracted"
  pass "fm-docs-sweep: open checklist items and TODO/FIXME markers are extracted with file:line"
}

test_max_items_bounds_output_and_reports_truncation() {
  local tmp out
  tmp=$(fm_test_tmproot fm-docs-sweep)
  mkdir -p "$tmp/fixture/repo"
  git -C "$tmp/fixture/repo" init -q
  for i in 1 2 3 4 5; do
    printf 'TODO: item %s\n' "$i" > "$tmp/fixture/repo/f$i.md"
  done

  out=$("$SWEEP" --root "$tmp/fixture" --max-items 2 2>&1)
  assert_equals "5" "$(jget "$out" todos.total)" "total count reflects every match regardless of the cap"
  assert_equals "true" "$(jget "$out" todos.truncated)" "truncated is set once total exceeds max-items"
  local listed
  listed=$(jget "$out" todos.items)
  assert_equals "2" "$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$listed")" "listed items are capped at max-items"
  pass "fm-docs-sweep: --max-items bounds listed items per category and reports truncation separately from total"
}

test_default_sweep_creates_or_deletes_no_file_under_root() {
  local tmp before after
  tmp=$(fm_test_tmproot fm-docs-sweep)
  build_fixture "$tmp/fixture"
  before=$(find "$tmp/fixture" -type f | sort)

  "$SWEEP" --root "$tmp/fixture" >/dev/null 2>&1
  expect_code 0 "$?" "default sweep must succeed"
  after=$(find "$tmp/fixture" -type f | sort)
  assert_equals "$before" "$after" "the default sweep must not create, delete, or move any file in scope"
  pass "fm-docs-sweep: the default operation creates or deletes no file under --root"
}

test_github_dir_docs_are_scanned() {
  local tmp out
  tmp=$(fm_test_tmproot fm-docs-sweep)
  mkdir -p "$tmp/fixture/repo/.github"
  git -C "$tmp/fixture/repo" init -q
  printf '# Contributing\n' > "$tmp/fixture/repo/.github/CONTRIBUTING.md"

  out=$("$SWEEP" --root "$tmp/fixture" 2>&1)
  assert_equals "1" "$(jget "$out" inventory.files)" "a doc under .github/ is part of the inventory"
  pass "fm-docs-sweep: .github/ docs are scanned while .git/ stays excluded"
}

test_fenced_code_comments_are_not_headings() {
  local tmp out
  tmp=$(fm_test_tmproot fm-docs-sweep)
  mkdir -p "$tmp/fixture/repoA" "$tmp/fixture/repoB"
  git -C "$tmp/fixture/repoA" init -q
  git -C "$tmp/fixture/repoB" init -q
  cat > "$tmp/fixture/repoA/README.md" <<'EOF'
# Setup

```bash
# run the installer now
./install.sh --fast --skip-checks
```
EOF
  cat > "$tmp/fixture/repoB/README.md" <<'EOF'
# Setup

~~~sh
# run the installer now
make bootstrap && make verify-everything
~~~
EOF

  out=$("$SWEEP" --root "$tmp/fixture" 2>&1)
  assert_equals "0" "$(jget "$out" conflict_candidates.total)" "a shell comment inside a code fence is not a shared section heading"
  pass "fm-docs-sweep: comment lines inside fenced code blocks never become conflict headings"
}

test_scoped_subdir_root_resolves_refs_against_enclosing_repo() {
  local tmp out
  tmp=$(fm_test_tmproot fm-docs-sweep)
  mkdir -p "$tmp/repo/bin" "$tmp/repo/docs"
  git -C "$tmp/repo" init -q
  : > "$tmp/repo/bin/real.sh"
  printf 'Run `bin/real.sh`, not `bin/gone.sh`.\n' > "$tmp/repo/docs/guide.md"

  out=$("$SWEEP" --root "$tmp/repo/docs" 2>&1)
  assert_equals "1" "$(jget "$out" stale_references.total)" "only the missing path is stale when --root is a folder inside the repo"
  assert_equals "bin/gone.sh" "$(jget "$out" stale_references.items.0.ref)" "the stale reference is the one that does not exist in the enclosing repo"
  pass "fm-docs-sweep: a --root inside a repo resolves inline path refs against that repo's root"
}

test_out_flag_writes_file_instead_of_stdout() {
  local tmp stdout_out
  tmp=$(fm_test_tmproot fm-docs-sweep)
  build_fixture "$tmp/fixture"

  stdout_out=$("$SWEEP" --root "$tmp/fixture" --out "$tmp/report.json" 2>/dev/null)
  assert_equals "" "$stdout_out" "with --out, nothing is printed to stdout"
  assert_present "$tmp/report.json" "--out writes the JSON report to the named path"
  assert_contains "$(cat "$tmp/report.json")" '"schema": "fm-docs-sweep.v1"' "the written report carries the schema tag"
  pass "fm-docs-sweep: --out redirects the JSON report to a file instead of stdout"
}

test_help_exits_zero_and_documents_read_only_contract() {
  local out rc
  out=$("$SWEEP" --help 2>&1)
  rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "Read-only" "help text states the read-only contract"
  assert_contains "$out" "--root" "help text documents --root"
  assert_contains "$out" "--max-items" "help text documents --max-items"
  pass "fm-docs-sweep: --help exits 0 and documents the read-only contract and flags"
}

test_invalid_root_fails_cleanly() {
  local out rc
  out=$("$SWEEP" --root "/no/such/path/fm-docs-sweep-test" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a missing --root must fail rather than scan the wrong tree"
  assert_contains "$out" "not a directory" "the error names the problem"
  pass "fm-docs-sweep: a nonexistent --root fails cleanly instead of silently scanning elsewhere"
}

test_inventory_counts_files_bytes_and_buckets
test_exact_duplicate_detected_by_hash
test_conflict_candidate_needs_same_heading_different_repos_diverging_body
test_conflict_candidates_never_carry_section_body_text
test_near_identical_section_is_not_a_conflict_candidate
test_broken_link_and_stale_reference_detected
test_todo_and_checklist_extraction
test_max_items_bounds_output_and_reports_truncation
test_default_sweep_creates_or_deletes_no_file_under_root
test_github_dir_docs_are_scanned
test_fenced_code_comments_are_not_headings
test_scoped_subdir_root_resolves_refs_against_enclosing_repo
test_out_flag_writes_file_instead_of_stdout
test_help_exits_zero_and_documents_read_only_contract
test_invalid_root_fails_cleanly
