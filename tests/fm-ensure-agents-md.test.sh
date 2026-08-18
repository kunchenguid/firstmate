#!/usr/bin/env bash
# Behavior tests for bin/fm-ensure-agents-md.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ensure-agents-md)

# Public contract: CLAUDE.md is this exact two-line pointer, never a symlink.
assert_claude_pointer() {
  local path=$1
  [ -e "$path" ] || fail "CLAUDE.md is missing"
  [ ! -L "$path" ] || fail "CLAUDE.md is a symlink; expected a real @AGENTS.md pointer file"
  [ -f "$path" ] || fail "CLAUDE.md is not a regular file"
  cmp -s "$path" - <<'EOF' || fail "CLAUDE.md is not the canonical @AGENTS.md pointer"
<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->
@AGENTS.md
EOF
}

write_fixture_claude_pointer() {
  cat > "$1/CLAUDE.md" <<'EOF'
<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->
@AGENTS.md
EOF
}

test_created_agents_md_includes_self_governance() {
  local repo agents
  repo="$TMP_ROOT/new-project"
  mkdir -p "$repo"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 || fail "fm-ensure-agents-md.sh failed for empty project"
  agents="$repo/AGENTS.md"
  assert_present "$agents" "AGENTS.md was not created"
  assert_claude_pointer "$repo/CLAUDE.md"
  assert_grep "## Maintaining this file" "$agents" "self-governance section heading missing"
  assert_grep "Keep this file for knowledge useful to almost every future agent session in this project." "$agents" \
    "self-governance section lost the future-session bar"
  assert_grep "Do not repeat what the codebase already shows; point to the authoritative file or command instead." "$agents" \
    "self-governance section lost pointer-over-copy guidance"
  assert_grep "Prefer rewriting or pruning existing entries over appending new ones." "$agents" \
    "self-governance section lost rewrite-or-prune guidance"
  assert_grep "When updating this file, preserve this bar for all agents and keep entries concise." "$agents" \
    "self-governance section lost all-agents maintenance guidance"
  pass "fm-ensure-agents-md.sh: created AGENTS.md includes self-governance section"
}

test_fresh_setup_writes_real_claude_pointer() {
  local repo out
  repo="$TMP_ROOT/fresh-pointer-project"
  mkdir -p "$repo"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed creating a fresh pointer"
  assert_contains "$out" "created:" "fresh setup did not report created"
  assert_claude_pointer "$repo/CLAUDE.md"
  [ ! -L "$repo/CLAUDE.md" ] || fail "fresh setup created a CLAUDE.md symlink"
  pass "fm-ensure-agents-md.sh: fresh setup writes a real @AGENTS.md pointer"
}

test_promoted_claude_md_includes_self_governance() {
  local repo agents count
  repo="$TMP_ROOT/claude-project"
  mkdir -p "$repo"
  cat > "$repo/CLAUDE.md" <<'EOF'
# Existing agent memory

Run tests with `make test`.
EOF
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 || fail "fm-ensure-agents-md.sh failed for CLAUDE.md promotion"
  agents="$repo/AGENTS.md"
  assert_present "$agents" "AGENTS.md was not created during promotion"
  assert_claude_pointer "$repo/CLAUDE.md"
  assert_grep "Run tests with \`make test\`." "$agents" \
    "promotion lost existing CLAUDE.md content"
  count=$(grep -Fc "## Maintaining this file" "$agents")
  [ "$count" -eq 1 ] || fail "promotion wrote $count self-governance sections"
  assert_grep "Keep this file for knowledge useful to almost every future agent session in this project." "$agents" \
    "promoted AGENTS.md missing self-governance wording"
  pass "fm-ensure-agents-md.sh: promoted CLAUDE.md includes self-governance section"
}

test_promoted_claude_md_without_trailing_newline_keeps_blank_separator() {
  local repo agents before
  repo="$TMP_ROOT/no-trailing-newline-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\nRun tests with make test.' > "$repo/CLAUDE.md"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 || fail "fm-ensure-agents-md.sh failed for newline-less CLAUDE.md promotion"
  agents="$repo/AGENTS.md"
  assert_grep "Run tests with make test." "$agents" \
    "newline-less promotion lost or mangled the last content line"
  assert_grep "## Maintaining this file" "$agents" \
    "newline-less promotion did not append the self-governance section"
  before=$(grep -B1 -Fx '## Maintaining this file' "$agents" | head -n 1)
  [ -z "$before" ] || fail "self-governance heading not preceded by a blank line (got: $before)"
  assert_claude_pointer "$repo/CLAUDE.md"
  pass "fm-ensure-agents-md.sh: newline-less promotion keeps a blank separator line"
}

test_existing_agents_md_with_symlink_gains_self_governance() {
  local repo agents out count
  repo="$TMP_ROOT/existing-symlinked-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\nBuild with make.\n' > "$repo/AGENTS.md"
  ln -s AGENTS.md "$repo/CLAUDE.md"
  agents="$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for existing AGENTS.md with symlink"
  assert_contains "$out" "updated:" "injection into existing AGENTS.md did not report an update"
  assert_grep "Build with make." "$agents" "injection dropped existing AGENTS.md content"
  assert_grep "## Maintaining this file" "$agents" "existing AGENTS.md did not gain the self-governance section"
  count=$(grep -Fc "## Maintaining this file" "$agents")
  [ "$count" -eq 1 ] || fail "injection wrote $count self-governance sections"
  assert_claude_pointer "$repo/CLAUDE.md"
  # Re-run must be a byte-exact no-op reporting unchanged.
  cp "$agents" "$repo/.after-first"
  cp "$repo/CLAUDE.md" "$repo/.claude-after-first"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on idempotent re-run"
  assert_contains "$out" "unchanged:" "idempotent re-run did not report unchanged"
  diff "$repo/.after-first" "$agents" >/dev/null \
    || fail "idempotent re-run modified AGENTS.md"
  cmp -s "$repo/.claude-after-first" "$repo/CLAUDE.md" \
    || fail "idempotent re-run modified CLAUDE.md"
  pass "fm-ensure-agents-md.sh: existing symlinked AGENTS.md gains the section idempotently"
}

test_correct_symlink_migrates_to_pointer_without_clobbering_agents() {
  local repo agents out
  repo="$TMP_ROOT/symlink-migrate-project"
  mkdir -p "$repo"
  printf '# Unique agent memory\n\nDo not clobber this payload.\n\n## Maintaining this file\n\nKeep this file for knowledge useful to almost every future agent session in this project.\nDo not repeat what the codebase already shows; point to the authoritative file or command instead.\nPrefer rewriting or pruning existing entries over appending new ones.\nWhen updating this file, preserve this bar for all agents and keep entries concise.\n' > "$repo/AGENTS.md"
  ln -s AGENTS.md "$repo/CLAUDE.md"
  agents="$repo/AGENTS.md"
  cp "$agents" "$repo/.before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed migrating a correct CLAUDE.md symlink"
  assert_contains "$out" "updated:" "symlink migration did not report an update"
  assert_claude_pointer "$repo/CLAUDE.md"
  cmp -s "$repo/.before" "$agents" \
    || fail "symlink migration clobbered AGENTS.md"
  assert_grep "Do not clobber this payload." "$agents" \
    "symlink migration lost unique AGENTS.md content"
  cp "$agents" "$repo/.after-first"
  cp "$repo/CLAUDE.md" "$repo/.claude-after-first"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on post-migration re-run"
  assert_contains "$out" "unchanged:" "post-migration re-run did not report unchanged"
  cmp -s "$repo/.after-first" "$agents" \
    || fail "post-migration re-run modified AGENTS.md"
  cmp -s "$repo/.claude-after-first" "$repo/CLAUDE.md" \
    || fail "post-migration re-run modified CLAUDE.md"
  pass "fm-ensure-agents-md.sh: correct symlink migrates to pointer without clobbering AGENTS.md"
}

test_existing_agents_md_without_claude_gains_section_and_pointer() {
  local repo agents out count
  repo="$TMP_ROOT/existing-bare-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\nDeploy with kubectl.\n' > "$repo/AGENTS.md"
  agents="$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for existing AGENTS.md without CLAUDE.md"
  assert_contains "$out" "updated:" "injection without CLAUDE.md did not report an update"
  assert_claude_pointer "$repo/CLAUDE.md"
  assert_grep "Deploy with kubectl." "$agents" "injection dropped existing AGENTS.md content"
  count=$(grep -Fc "## Maintaining this file" "$agents")
  [ "$count" -eq 1 ] || fail "injection wrote $count self-governance sections"
  pass "fm-ensure-agents-md.sh: existing AGENTS.md without CLAUDE.md gains section and pointer"
}

test_existing_agents_md_with_section_reports_unchanged() {
  local repo agents out
  repo="$TMP_ROOT/fully-formed-project"
  mkdir -p "$repo"
  # Build a fully-formed project (AGENTS.md with the section + canonical pointer).
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 \
    || fail "fm-ensure-agents-md.sh failed building the fully-formed fixture"
  agents="$repo/AGENTS.md"
  assert_claude_pointer "$repo/CLAUDE.md"
  cp "$agents" "$repo/.before"
  cp "$repo/CLAUDE.md" "$repo/.claude-before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on already-formed project"
  assert_contains "$out" "unchanged:" "already-formed project was not reported unchanged"
  diff "$repo/.before" "$agents" >/dev/null \
    || fail "already-formed AGENTS.md was modified"
  cmp -s "$repo/.claude-before" "$repo/CLAUDE.md" \
    || fail "already-formed CLAUDE.md was modified"
  pass "fm-ensure-agents-md.sh: AGENTS.md that already has the section stays unchanged"
}

test_existing_crlf_agents_md_with_section_stays_unchanged() {
  local repo agents out count
  repo="$TMP_ROOT/crlf-formed-project"
  mkdir -p "$repo"
  printf '%s\r\n' \
    '# Existing agent memory' \
    '' \
    '## Maintaining this file' \
    '' \
    'Keep this file for knowledge useful to almost every future agent session in this project.' \
    'Do not repeat what the codebase already shows; point to the authoritative file or command instead.' \
    'Prefer rewriting or pruning existing entries over appending new ones.' \
    'When updating this file, preserve this bar for all agents and keep entries concise.' > "$repo/AGENTS.md"
  write_fixture_claude_pointer "$repo"
  agents="$repo/AGENTS.md"
  cp "$agents" "$repo/.before"
  cp "$repo/CLAUDE.md" "$repo/.claude-before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on CRLF AGENTS.md with the section"
  assert_contains "$out" "unchanged:" "complete CRLF AGENTS.md was not reported unchanged"
  cmp -s "$repo/.before" "$agents" \
    || fail "complete CRLF AGENTS.md was modified"
  cmp -s "$repo/.claude-before" "$repo/CLAUDE.md" \
    || fail "complete CRLF project's CLAUDE.md was modified"
  count=$(LC_ALL=C grep -a -c '## Maintaining this file' "$agents")
  [ "$count" -eq 1 ] || fail "complete CRLF AGENTS.md has $count self-governance sections"
  pass "fm-ensure-agents-md.sh: CRLF AGENTS.md with the section stays unchanged"
}

test_existing_crlf_agents_md_without_section_preserves_crlf() {
  local repo agents out
  repo="$TMP_ROOT/crlf-injected-project"
  mkdir -p "$repo"
  printf '%s\r\n' \
    '# Existing agent memory' \
    '' \
    'Run tests with make test.' > "$repo/AGENTS.md"
  ln -s AGENTS.md "$repo/CLAUDE.md"
  agents="$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed injecting into CRLF AGENTS.md"
  assert_contains "$out" "updated:" "CRLF AGENTS.md injection did not report an update"
  printf '%s\r\n' \
    '# Existing agent memory' \
    '' \
    'Run tests with make test.' \
    '' \
    '## Maintaining this file' \
    '' \
    'Keep this file for knowledge useful to almost every future agent session in this project.' \
    'Do not repeat what the codebase already shows; point to the authoritative file or command instead.' \
    'Prefer rewriting or pruning existing entries over appending new ones.' \
    'When updating this file, preserve this bar for all agents and keep entries concise.' > "$repo/.expected"
  cmp -s "$repo/.expected" "$agents" \
    || fail "CRLF AGENTS.md injection did not preserve CRLF line endings"
  assert_claude_pointer "$repo/CLAUDE.md"
  cp "$agents" "$repo/.after-first"
  cp "$repo/CLAUDE.md" "$repo/.claude-after-first"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 \
    || fail "fm-ensure-agents-md.sh failed on idempotent CRLF re-run"
  cmp -s "$repo/.after-first" "$agents" \
    || fail "idempotent CRLF re-run modified AGENTS.md"
  cmp -s "$repo/.claude-after-first" "$repo/CLAUDE.md" \
    || fail "idempotent CRLF re-run modified CLAUDE.md"
  pass "fm-ensure-agents-md.sh: CRLF injection preserves line endings idempotently"
}

test_canonical_pointer_is_accepted_when_both_are_real_files() {
  local repo out
  repo="$TMP_ROOT/both-real-pointer-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\n## Maintaining this file\n\nKeep this file for knowledge useful to almost every future agent session in this project.\nDo not repeat what the codebase already shows; point to the authoritative file or command instead.\nPrefer rewriting or pruning existing entries over appending new ones.\nWhen updating this file, preserve this bar for all agents and keep entries concise.\n' > "$repo/AGENTS.md"
  write_fixture_claude_pointer "$repo"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh refused a canonical real CLAUDE.md pointer"
  assert_contains "$out" "unchanged:" "canonical pointer plus AGENTS.md was not reported unchanged"
  assert_claude_pointer "$repo/CLAUDE.md"
  pass "fm-ensure-agents-md.sh: canonical real CLAUDE.md pointer is not a conflict"
}

test_distinct_real_files_are_refused() {
  local repo out rc
  repo="$TMP_ROOT/distinct-real-files-project"
  mkdir -p "$repo"
  printf '# Agents memory\n' > "$repo/AGENTS.md"
  printf '# Claude memory\n' > "$repo/CLAUDE.md"
  cp "$repo/AGENTS.md" "$repo/.agents-before"
  cp "$repo/CLAUDE.md" "$repo/.claude-before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for distinct real AGENTS.md and CLAUDE.md"
  assert_contains "$out" "conflict:" "distinct real files did not report a conflict"
  cmp -s "$repo/.agents-before" "$repo/AGENTS.md" \
    || fail "distinct-real-files refusal modified AGENTS.md"
  cmp -s "$repo/.claude-before" "$repo/CLAUDE.md" \
    || fail "distinct-real-files refusal modified CLAUDE.md"
  [ ! -L "$repo/CLAUDE.md" ] || fail "distinct-real-files refusal turned CLAUDE.md into a symlink"
  pass "fm-ensure-agents-md.sh: refuses distinct real AGENTS.md and CLAUDE.md"
}

test_agents_md_symlink_is_refused() {
  local repo out rc
  repo="$TMP_ROOT/agents-symlink-project"
  mkdir -p "$repo"
  printf '# payload\n' > "$repo/payload.md"
  ln -s payload.md "$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when AGENTS.md is a symlink"
  assert_contains "$out" "conflict:" "AGENTS.md symlink did not report a conflict"
  [ -L "$repo/AGENTS.md" ] || fail "AGENTS.md symlink refusal disturbed the symlink"
  assert_absent "$repo/CLAUDE.md" "AGENTS.md symlink refusal created CLAUDE.md"
  pass "fm-ensure-agents-md.sh: refuses AGENTS.md when it is a symlink"
}

test_wrong_target_symlink_is_refused() {
  local repo out rc
  repo="$TMP_ROOT/wrong-target-project"
  mkdir -p "$repo"
  printf '# Agents memory\n' > "$repo/AGENTS.md"
  printf '# other\n' > "$repo/OTHER.md"
  ln -s OTHER.md "$repo/CLAUDE.md"
  cp "$repo/AGENTS.md" "$repo/.agents-before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for a CLAUDE.md symlink that does not point to AGENTS.md"
  assert_contains "$out" "conflict:" "wrong-target CLAUDE.md symlink did not report a conflict"
  [ -L "$repo/CLAUDE.md" ] || fail "wrong-target refusal removed the CLAUDE.md symlink"
  [ "$(readlink "$repo/CLAUDE.md")" = "OTHER.md" ] || fail "wrong-target refusal retargeted CLAUDE.md"
  cmp -s "$repo/.agents-before" "$repo/AGENTS.md" \
    || fail "wrong-target refusal modified AGENTS.md"
  pass "fm-ensure-agents-md.sh: refuses a CLAUDE.md symlink that does not point to AGENTS.md"
}

test_non_regular_claude_md_is_refused() {
  local repo out rc
  repo="$TMP_ROOT/non-regular-claude-project"
  mkdir -p "$repo" "$repo/CLAUDE.md"
  printf '# Agents memory\n' > "$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when CLAUDE.md is a directory"
  assert_contains "$out" "conflict:" "non-regular CLAUDE.md did not report a conflict"
  [ -d "$repo/CLAUDE.md" ] || fail "non-regular CLAUDE.md refusal disturbed the directory"
  pass "fm-ensure-agents-md.sh: refuses a non-regular CLAUDE.md"
}

test_lowercase_agents_md_refuses_case_fragile_pointer() {
  local repo out rc
  repo="$TMP_ROOT/lowercase-project"
  mkdir -p "$repo"
  printf '# project memory\n' > "$repo/agents.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for a lowercase agents.md"
  assert_contains "$out" "conflict:" "lowercase agents.md did not report a conflict"
  assert_contains "$out" "agents.md" "conflict message did not name the offending file"
  assert_absent "$repo/CLAUDE.md" "a case-fragile CLAUDE.md pointer was created for lowercase agents.md"
  [ ! -L "$repo/CLAUDE.md" ] || fail "a case-fragile CLAUDE.md symlink was created for lowercase agents.md"
  assert_present "$repo/agents.md" "the real lowercase agents.md was disturbed"
  pass "fm-ensure-agents-md.sh: refuses a case-variant lowercase agents.md (issue #389)"
}

test_created_agents_md_includes_self_governance
test_fresh_setup_writes_real_claude_pointer
test_promoted_claude_md_includes_self_governance
test_promoted_claude_md_without_trailing_newline_keeps_blank_separator
test_existing_agents_md_with_symlink_gains_self_governance
test_correct_symlink_migrates_to_pointer_without_clobbering_agents
test_existing_agents_md_without_claude_gains_section_and_pointer
test_existing_agents_md_with_section_reports_unchanged
test_existing_crlf_agents_md_with_section_stays_unchanged
test_existing_crlf_agents_md_without_section_preserves_crlf
test_canonical_pointer_is_accepted_when_both_are_real_files
test_distinct_real_files_are_refused
test_agents_md_symlink_is_refused
test_wrong_target_symlink_is_refused
test_non_regular_claude_md_is_refused
test_lowercase_agents_md_refuses_case_fragile_pointer
