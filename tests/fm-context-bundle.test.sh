#!/usr/bin/env bash
# Behavior tests for bin/fm-context-bundle.sh / bin/fm-context-bundle.py.
#
# fm-context-bundle is a deterministic, read-only, model-free scoped
# workspace context bundle built on top of fm-docs-sweep's scan: every test
# here builds a small fixture tree, runs the real executable against it, and
# asserts on the JSON it prints - never on the Python source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BUNDLE="$ROOT/bin/fm-context-bundle.sh"

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
  mkdir -p "$root/repoA/sub" "$root/repoB"
  git -C "$root/repoA" init -q
  git -C "$root/repoB" init -q

  printf '# A\nhello world foo bar baz qux\n' > "$root/repoA/AGENTS.md"
  printf '# Sub\nnested doc body text\n' > "$root/repoA/sub/NOTES.md"
  printf '# B\nother repo readme text\n' > "$root/repoB/README.md"
}

test_inventory_and_selected_files_cover_the_whole_scope_by_default() {
  local tmp out
  tmp=$(fm_test_tmproot fm-context-bundle)
  build_fixture "$tmp/fixture"

  out=$("$BUNDLE" --root "$tmp/fixture" 2>&1)
  expect_code 0 "$?" "bundle must exit 0 on a clean fixture"

  assert_equals "fm-context-bundle.v1" "$(jget "$out" schema)" "output carries the bundle schema tag"
  assert_equals "3" "$(jget "$out" inventory.files)" "inventory counts every scanned .md file"
  assert_equals "3" "$(jget "$out" selected_files.total_candidates)" "all three files are candidates"
  assert_equals "3" "$(jget "$out" selected_files.selected)" "with no budget/cap, every candidate is selected"
  assert_equals "false" "$(jget "$out" selected_files.truncated)" "unbounded selection is never truncated"
  pass "fm-context-bundle: unbounded run selects and reports the whole scope"
}

test_selection_is_deterministic_across_repeated_runs() {
  local tmp out1 out2
  tmp=$(fm_test_tmproot fm-context-bundle)
  build_fixture "$tmp/fixture"

  out1=$("$BUNDLE" --root "$tmp/fixture" --budget-tokens 10 2>&1)
  out2=$("$BUNDLE" --root "$tmp/fixture" --budget-tokens 10 2>&1)
  local items1 items2
  items1=$(jget "$out1" selected_files.items)
  items2=$(jget "$out2" selected_files.items)
  assert_equals "$items1" "$items2" "the same scope and budget must select the exact same files in the exact same order"
  pass "fm-context-bundle: selection is deterministic across repeated runs"
}

test_budget_tokens_bounds_selection_and_always_keeps_at_least_one_file() {
  local tmp out
  tmp=$(fm_test_tmproot fm-context-bundle)
  build_fixture "$tmp/fixture"

  out=$("$BUNDLE" --root "$tmp/fixture" --budget-tokens 1 2>&1)
  assert_equals "1" "$(jget "$out" selected_files.selected)" "a budget smaller than any single file still keeps exactly one file"
  assert_equals "true" "$(jget "$out" selected_files.truncated)" "a tight budget is reported as truncated"
  assert_equals "repoA/AGENTS.md" "$(jget "$out" selected_files.items.0.path)" "selection is sorted lexicographically by relative path"
  pass "fm-context-bundle: --budget-tokens bounds selection deterministically and never yields an empty bundle"
}

test_max_files_bounds_selection_count() {
  local tmp out
  tmp=$(fm_test_tmproot fm-context-bundle)
  build_fixture "$tmp/fixture"

  out=$("$BUNDLE" --root "$tmp/fixture" --max-files 2 2>&1)
  assert_equals "2" "$(jget "$out" selected_files.selected)" "--max-files caps the selected count"
  assert_equals "true" "$(jget "$out" selected_files.truncated)" "capping below the candidate count reports truncation"
  pass "fm-context-bundle: --max-files bounds the selected file count"
}

test_include_glob_filters_candidates() {
  local tmp out
  tmp=$(fm_test_tmproot fm-context-bundle)
  build_fixture "$tmp/fixture"

  out=$("$BUNDLE" --root "$tmp/fixture" --include 'repoA/*' 2>&1)
  assert_equals "2" "$(jget "$out" selected_files.total_candidates)" "--include narrows candidates to repoA only"
  assert_not_contains "$out" "repoB/README.md" "an excluded-by-glob file never appears in the bundle"
  pass "fm-context-bundle: --include filters candidates by glob before selection"
}

test_tree_is_nested_sorted_and_bounded() {
  local tmp out
  tmp=$(fm_test_tmproot fm-context-bundle)
  build_fixture "$tmp/fixture"

  out=$("$BUNDLE" --root "$tmp/fixture" 2>&1)
  assert_equals "repoA" "$(jget "$out" tree.children.0.name)" "the tree lists repoA before repoB (sorted)"
  assert_equals "dir" "$(jget "$out" tree.children.0.type)" "repoA is reported as a directory"
  assert_equals "false" "$(jget "$out" tree_truncated)" "the default tree cap is not hit by this small fixture"

  out=$("$BUNDLE" --root "$tmp/fixture" --max-tree-items 1 2>&1)
  assert_equals "true" "$(jget "$out" tree_truncated)" "a tree item cap smaller than the fixture reports truncation"
  pass "fm-context-bundle: tree output is nested, sorted, and honors --max-tree-items"
}

test_no_network_no_model_no_mutation() {
  local tmp before after
  tmp=$(fm_test_tmproot fm-context-bundle)
  build_fixture "$tmp/fixture"

  before=$(find "$tmp/fixture" -type f -exec sha256sum {} \; | sort)
  "$BUNDLE" --root "$tmp/fixture" >/dev/null 2>&1
  after=$(find "$tmp/fixture" -type f -exec sha256sum {} \; | sort)
  assert_equals "$before" "$after" "running the bundle must never change any file under the scanned scope"
  pass "fm-context-bundle: read-only - the scanned scope is byte-identical before and after"
}

test_out_flag_writes_file_instead_of_stdout() {
  local tmp stdout_out
  tmp=$(fm_test_tmproot fm-context-bundle)
  build_fixture "$tmp/fixture"

  stdout_out=$("$BUNDLE" --root "$tmp/fixture" --out "$tmp/bundle.json" 2>/dev/null)
  assert_equals "" "$stdout_out" "with --out, nothing is printed to stdout"
  assert_present "$tmp/bundle.json" "--out writes the JSON bundle to the named path"
  assert_contains "$(cat "$tmp/bundle.json")" '"schema": "fm-context-bundle.v1"' "the written bundle carries the schema tag"
  pass "fm-context-bundle: --out redirects the JSON bundle to a file instead of stdout"
}

test_help_exits_zero_and_documents_read_only_contract() {
  local out rc
  out=$("$BUNDLE" --help 2>&1)
  rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "read-only" "help text states the read-only contract"
  assert_contains "$out" "--root" "help text documents --root"
  assert_contains "$out" "--budget-tokens" "help text documents --budget-tokens"
  pass "fm-context-bundle: --help exits 0 and documents the read-only contract and flags"
}

test_invalid_root_fails_cleanly() {
  local out rc
  out=$("$BUNDLE" --root "/no/such/path/fm-context-bundle-test" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a missing --root must fail rather than scan the wrong tree"
  assert_contains "$out" "not a directory" "the error names the problem"
  pass "fm-context-bundle: a nonexistent --root fails cleanly instead of silently scanning elsewhere"
}

test_inventory_and_selected_files_cover_the_whole_scope_by_default
test_selection_is_deterministic_across_repeated_runs
test_budget_tokens_bounds_selection_and_always_keeps_at_least_one_file
test_max_files_bounds_selection_count
test_include_glob_filters_candidates
test_tree_is_nested_sorted_and_bounded
test_no_network_no_model_no_mutation
test_out_flag_writes_file_instead_of_stdout
test_help_exits_zero_and_documents_read_only_contract
test_invalid_root_fails_cleanly
