#!/usr/bin/env bash
# Behavior tests for bin/fm-smell-scan.sh: the read-only smell review queue.
#
# Covers each category's positive and negative case, the stale-comment age
# threshold, scope and exclude selection, JSON shape and byte-for-byte
# determinism, exit codes, and the guarantee that a scan never writes inside the
# scanned tree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-smell-scan.sh"

# build_fixture <dir>: a committed repository holding one instance of every
# category plus deliberate near-misses that must stay unreported.
build_fixture() {
  local dir=$1
  mkdir -p "$dir/src" "$dir/docs"
  cat > "$dir/src/keep.sh" <<'EOF'
#!/usr/bin/env bash
# Shared helper block for every caller in this tree.
# The block is deliberately repeated in two files so the scan can see it.
used() { echo used; }
used
EOF
  cat > "$dir/src/other.sh" <<'EOF'
#!/usr/bin/env bash
# Shared helper block for every caller in this tree.
# The block is deliberately repeated in two files so the scan can see it.
# Copyright 2020 Example Corp. All rights reserved.
# Licensed under the MIT license.
orphan() { echo never-called; }
# TODO: replace the orphan helper with the shared one.
EOF
  cat > "$dir/src/legacy.js" <<'EOF'
// if (ready) {
//   startWorker();
// }
EOF
  cat > "$dir/src/prose.sh" <<'EOF'
#!/usr/bin/env bash
# This helper block documents the contract for every caller.
# The scan must not read prose as commented-out code (see the note).
true
EOF
  cat > "$dir/docs/guide.md" <<'EOF'
# Guide

See [the missing page](missing/absent.md) and [the real one](../src/keep.sh).
EOF
  git -C "$dir" add -A
  GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" \
    git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "old tree"
  cat > "$dir/src/fresh.sh" <<'EOF'
#!/usr/bin/env bash
# TODO: finish this later.
EOF
  git -C "$dir" add -A
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "fresh marker"
}

# json_field <field> <args...>: run the scan and print one dotted field path.
json_field() {
  local field=$1
  shift
  bash "$CHECK" "$@" --json | python3 -c '
import json, sys
value = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    value = value[int(part)] if part.isdigit() else value[part]
print(value)
' "$field"
}

# run_scan <args...>: run the scan, capture stdout, and set SCAN_RC.
run_scan() {
  set +e
  SCAN_OUT=$(bash "$CHECK" "$@" 2>&1)
  SCAN_RC=$?
  set -e
}

# expect_rc <expected> <args...>: assert the scan's exit code.
expect_rc() {
  local expected=$1
  shift
  run_scan "$@"
  expect_code "$expected" "$SCAN_RC" "fm-smell-scan $*"
}

expect_failure() {
  local expected=$1
  shift
  run_scan "$@"
  [ "$SCAN_RC" -ne 0 ] || fail "expected failure containing '$expected'"
  assert_contains "$SCAN_OUT" "$expected" "failure did not explain '$expected'"
}

test_help_lists_every_category() {
  expect_rc 0 --help
  assert_contains "$SCAN_OUT" "usage: fm-smell-scan.sh" "--help must print usage"
  assert_not_contains "$SCAN_OUT" "--include-untracked" "--help must not advertise untracked scans"
  local category
  for category in dead-code stale-doc duplicated-comment commented-out-code stale-comment; do
    assert_contains "$SCAN_OUT" "$category" "--help must name the $category category"
  done
}

test_clean_tree_reports_no_findings() {
  local fix
  fix=$(fm_test_tmproot fm-smell-clean) || fail "tmproot"
  fm_git_init_commit "$fix"
  printf '#!/usr/bin/env bash\nset -eu\necho ok\n' > "$fix/run.sh"
  git -C "$fix" add -A
  git -C "$fix" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm run

  expect_rc 0 --root "$fix"
  assert_contains "$SCAN_OUT" "No findings for the scanned scope." "clean tree still reported findings"
  expect_rc 0 --root "$fix" --check
  assert_equals 0 "$(json_field summary.total --root "$fix")" "clean tree total"
}

test_every_category_detects_its_finding() {
  local fix
  fix=$(fm_test_tmproot fm-smell-fixture) || fail "tmproot"
  fm_git_init_commit "$fix"
  build_fixture "$fix"

  local json
  json=$(bash "$CHECK" --root "$fix" --json)
  assert_equals 1 "$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(sum(1 for f in d["findings"] if f["category"] == "dead-code" and f["evidence"] == "orphan()"))
')" "unreferenced function must be the only dead-code finding"
  assert_equals 1 "$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(sum(1 for f in d["findings"] if f["category"] == "duplicated-comment"))
')" "duplicated comment block must be reported once for the group"
  assert_equals "src/keep.sh:2" "$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print([f["path"] + ":" + str(f["line"]) for f in d["findings"] if f["category"] == "duplicated-comment"][0])
')" "duplicated comment must anchor at the first location"
  assert_equals 1 "$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(sum(1 for f in d["findings"] if f["category"] == "stale-doc"))
')" "stale documentation link must be reported"
  assert_equals 1 "$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(sum(1 for f in d["findings"] if f["category"] == "commented-out-code"))
')" "commented-out code must be reported once, and prose must stay unreported"
  assert_equals 1 "$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(sum(1 for f in d["findings"] if f["category"] == "stale-comment"))
')" "only the old marker may be reported as a stale comment"
  assert_contains "$json" '"confidence": "needs-review"' "needs-review confidence must appear"
  assert_contains "$json" '"follow_up"' "every finding must carry a follow-up lane"
  assert_not_contains "$json" "$fix" "output must never carry a machine path"
}

test_stale_days_threshold_gates_markers() {
  local fix
  fix=$(fm_test_tmproot fm-smell-stale) || fail "tmproot"
  fm_git_init_commit "$fix"
  build_fixture "$fix"
  local count
  count=$(bash "$CHECK" --root "$fix" --json --category stale-comment \
    --stale-days 100000 | python3 -c 'import json,sys; print(json.load(sys.stdin)["summary"]["total"])')
  assert_equals 0 "$count" "a marker inside a huge threshold window must not be stale"
}

test_scope_and_excludes_bound_the_scan() {
  local fix
  fix=$(fm_test_tmproot fm-smell-scope) || fail "tmproot"
  fm_git_init_commit "$fix"
  build_fixture "$fix"

  local scoped
  cat > "$fix/src/private.sh" <<'EOF'
#!/usr/bin/env bash
# TODO: this untracked marker must stay outside scan evidence.
private_orphan() { echo no; }
EOF
  scoped=$(bash "$CHECK" --root "$fix" --json --paths docs)
  assert_equals "docs/guide.md" "$(printf '%s' "$scoped" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(",".join(sorted({f["path"] for f in d["findings"]})))
')" "--paths must bound the scan to the named subtree"
  assert_equals 0 "$(bash "$CHECK" --root "$fix" --json --category stale-comment --stale-days 1 | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(sum(1 for f in d["findings"] if f["path"] == "src/private.sh"))
')" "untracked files must stay outside scan evidence"

  local excluded
  excluded=$(bash "$CHECK" --root "$fix" --json --exclude 'src')
  assert_equals "docs/guide.md" "$(printf '%s' "$excluded" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(",".join(sorted({f["path"] for f in d["findings"]})))
')" "--exclude must drop the excluded subtree"
}

test_paths_and_symlinks_stay_inside_root() {
  local fix outside json
  fix=$(fm_test_tmproot fm-smell-root-bound) || fail "tmproot"
  outside=$(fm_test_tmproot fm-smell-outside) || fail "tmproot"
  fm_git_init_commit "$fix"
  build_fixture "$fix"
  mkdir -p "$outside"
  cat > "$outside/private.sh" <<'EOF'
#!/usr/bin/env bash
# TODO: external marker must never become scan evidence.
EOF
  ln -s "$outside/private.sh" "$fix/src/external.sh"
  git -C "$fix" add src/external.sh
  git -C "$fix" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "tracked external symlink"

  expect_failure "--paths entry resolves outside --root" --root "$fix" --paths ..
  expect_failure "--paths entry resolves outside --root" --root "$fix" --paths "$outside/private.sh"
  json=$(bash "$CHECK" --root "$fix" --json --category stale-comment --stale-days 1)
  assert_not_contains "$json" "src/external.sh" "tracked symlinks outside the root must be skipped"
  assert_not_contains "$json" "external marker" "external symlink contents must not become evidence"
}

test_stale_comment_detects_inline_comments_without_quoted_markers() {
  local fix json
  fix=$(fm_test_tmproot fm-smell-inline-comments) || fail "tmproot"
  fm_git_init_commit "$fix"
  mkdir -p "$fix/src"
  cat > "$fix/src/hash.sh" <<'EOF'
#!/usr/bin/env bash
echo ok # TODO: hash inline old marker.
echo "# TODO: quoted hash marker is code text."
EOF
  cat > "$fix/src/slash.js" <<'EOF'
const text = "// TODO: quoted slash marker is code text.";
run(); // FIXME: slash inline old marker.
EOF
  cat > "$fix/src/dash.sql" <<'EOF'
select '-- HACK: quoted dash marker is code text';
select 1; -- HACK: dash inline old marker.
EOF
  cat > "$fix/src/semi.clj" <<'EOF'
(println "; XXX: quoted semi marker is code text")
(println :ok) ; XXX: semi inline old marker.
EOF
  git -C "$fix" add -A
  GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" \
    git -C "$fix" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "old inline markers"

  json=$(bash "$CHECK" --root "$fix" --json --category stale-comment --stale-days 1)
  assert_equals 4 "$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["summary"]["total"])
')" "inline comment markers must be detected for supported comment syntaxes"
  assert_not_contains "$json" "quoted hash marker" "quoted hash markers must not be reported"
  assert_not_contains "$json" "quoted slash marker" "quoted slash markers must not be reported"
  assert_not_contains "$json" "quoted dash marker" "quoted dash markers must not be reported"
  assert_not_contains "$json" "quoted semi marker" "quoted semi markers must not be reported"
}

test_output_is_deterministic_json() {
  local fix
  fix=$(fm_test_tmproot fm-smell-determinism) || fail "tmproot"
  fm_git_init_commit "$fix"
  build_fixture "$fix"
  local first second
  first=$(bash "$CHECK" --root "$fix" --json --category dead-code)
  second=$(bash "$CHECK" --root "$fix" --json --category dead-code)
  assert_equals "$first" "$second" "two scans of an unchanged tree must be byte identical"
  assert_contains "$first" '"schema": "fm-smell-scan.v1"' "JSON must carry the schema id"
}

test_scan_is_read_only_and_guards_out_path() {
  local fix out
  fix=$(fm_test_tmproot fm-smell-readonly) || fail "tmproot"
  fm_git_init_commit "$fix"
  build_fixture "$fix"
  out=$(fm_test_tmproot fm-smell-out) || fail "tmproot"

  expect_rc 0 --root "$fix"
  assert_equals "" "$(git -C "$fix" status --porcelain)" "scanning must not change the scanned tree"

  expect_rc 0 --root "$fix" --out "$out/report.md"
  assert_present "$out/report.md" "--out outside the tree must be written"
  assert_contains "$(cat "$out/report.md")" "## Repair queue" "report must carry the repair queue"

  expect_failure "--out must resolve outside --root" --root "$fix" --out "$fix/report.md"
  set +e
  [ ! -e "$fix/report.md" ] || fail "a refused --out must not create a file"
  set -e
}

test_exit_codes_and_usage_refusals() {
  local fix bad
  fix=$(fm_test_tmproot fm-smell-codes) || fail "tmproot"
  fm_git_init_commit "$fix"
  build_fixture "$fix"
  bad=${fix}-missing

  expect_rc 1 --root "$fix" --check
  expect_rc 1 --root "$fix" --check --category stale-doc
  expect_rc 0 --root "$fix" --category stale-doc --json
  expect_failure "unknown --category" --root "$fix" --category nonexistent
  expect_failure "--root is not a directory" --root "$bad"
  mkdir -p "$bad"
  expect_failure "--root must be a git work tree" --root "$bad"
  expect_failure "--stale-days must be a positive integer" --root "$fix" --stale-days 0
  run_scan --root "$fix" --include-untracked
  expect_code 2 "$SCAN_RC" "the removed untracked scan flag must be a usage error"
  run_scan --root "$fix" --not-a-flag
  expect_code 2 "$SCAN_RC" "an unknown flag must be a usage error"
}

test_markers_without_git_are_needs_review() {
  local fix json
  fix=$(fm_test_tmproot fm-smell-nogit) || fail "tmproot"
  fm_git_init_commit "$fix"
  build_fixture "$fix"
  json=$(bash "$CHECK" --root "$fix" --json --category stale-comment --no-git)
  assert_equals 2 "$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(sum(1 for f in d["findings"] if f["confidence"] == "needs-review"))
')" "without ages both markers must be reported as needs-review"
}

test_shebang_and_prose_are_not_code() {
  local fix json
  fix=$(fm_test_tmproot fm-smell-prose) || fail "tmproot"
  fm_git_init_commit "$fix"
  build_fixture "$fix"
  json=$(bash "$CHECK" --root "$fix" --json --category commented-out-code)
  assert_not_contains "$json" "src/prose.sh" "prose and a shebang must never read as commented-out code"
  assert_contains "$json" "src/legacy.js" "genuine commented-out code must still be reported"
}

test_help_lists_every_category
test_clean_tree_reports_no_findings
test_every_category_detects_its_finding
test_stale_days_threshold_gates_markers
test_scope_and_excludes_bound_the_scan
test_paths_and_symlinks_stay_inside_root
test_stale_comment_detects_inline_comments_without_quoted_markers
test_output_is_deterministic_json
test_scan_is_read_only_and_guards_out_path
test_exit_codes_and_usage_refusals
test_markers_without_git_are_needs_review
test_shebang_and_prose_are_not_code
