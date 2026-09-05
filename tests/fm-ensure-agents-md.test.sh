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

init_registered_project() {
  local home=$1 project=$2 annotation=$3 repo
  repo="$home/projects/$project"
  mkdir -p "$home/data" "$home/projects"
  git init -q -b main "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  printf 'fixture\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm init
  printf -- '- %s [%s] - fixture (added 2026-09-01)\n' "$project" "$annotation" > "$home/data/projects.md"
}

# Mutation: remove the pre-write external_contract_project refusal and both
# AGENTS.md and CLAUDE.md are created in the linked task worktree.
test_external_contract_project_refuses_without_creating_agent_files() {
  local home repo worktree out rc
  home="$TMP_ROOT/external-home"
  init_registered_project "$home" contracted-project 'no-mistakes-prod-only +external-contract'
  repo="$home/projects/contracted-project"
  worktree="$TMP_ROOT/external-task-worktree"
  git -C "$repo" worktree add -q --detach "$worktree" HEAD
  out=$(FM_HOME="$home" "$ROOT/bin/fm-ensure-agents-md.sh" "$worktree" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "fm-ensure-agents-md.sh should refuse an externally contracted project"
  assert_contains "$out" "managed outside the repository" "external-contract refusal did not state the policy"
  assert_absent "$worktree/AGENTS.md" "external-contract refusal created AGENTS.md"
  assert_absent "$worktree/CLAUDE.md" "external-contract refusal created CLAUDE.md"
  pass "fm-ensure-agents-md.sh: externally contracted linked worktrees refuse without writing agent files"
}

# The git-common-dir match covers firstmate's own pooled worktrees; a worktree
# provided by another tool is recognized by origin identity instead. Mutation:
# compare origin URLs by raw string equality and this ssh-vs-https pair stops
# matching, so the marked project's agent files get created after all.
test_external_contract_matches_equivalent_origin_spellings() {
  local home repo elsewhere out rc
  home="$TMP_ROOT/external-origin-home"
  init_registered_project "$home" contracted-project 'no-mistakes-prod-only +external-contract'
  repo="$home/projects/contracted-project"
  git -C "$repo" remote add origin 'git@github.com:example-org/contracted-project.git'
  elsewhere="$TMP_ROOT/external-origin-foreign"
  git init -q -b main "$elsewhere"
  git -C "$elsewhere" remote add origin 'https://github.com/example-org/contracted-project'
  out=$(FM_HOME="$home" "$ROOT/bin/fm-ensure-agents-md.sh" "$elsewhere" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an https checkout of an ssh-registered marked project was not refused"
  assert_contains "$out" "managed outside the repository" "origin-matched refusal did not state the policy"
  assert_absent "$elsewhere/AGENTS.md" "origin-matched refusal created AGENTS.md"
  assert_absent "$elsewhere/CLAUDE.md" "origin-matched refusal created CLAUDE.md"
  pass "fm-ensure-agents-md.sh: equivalent ssh and https origin spellings identify the same marked project"
}

# A different repository on the same host must NOT inherit the refusal.
# Mutation: normalize origins down to the host and this unrelated repo refuses.
test_external_contract_does_not_capture_a_different_repository() {
  local home repo elsewhere out
  home="$TMP_ROOT/external-origin-distinct-home"
  init_registered_project "$home" contracted-project 'no-mistakes-prod-only +external-contract'
  repo="$home/projects/contracted-project"
  git -C "$repo" remote add origin 'git@github.com:example-org/contracted-project.git'
  elsewhere="$TMP_ROOT/external-origin-distinct-foreign"
  git init -q -b main "$elsewhere"
  git -C "$elsewhere" remote add origin 'https://github.com/example-org/some-other-repo.git'
  out=$(FM_HOME="$home" "$ROOT/bin/fm-ensure-agents-md.sh" "$elsewhere" 2>&1) \
    || fail "an unrelated repository on the same host was refused: $out"
  assert_present "$elsewhere/AGENTS.md" "unrelated repository did not create AGENTS.md"
  assert_claude_pointer "$elsewhere/CLAUDE.md"
  pass "fm-ensure-agents-md.sh: origin normalization does not capture a different repository on the same host"
}

# This helper runs INSIDE a project worktree on an external forge, and the brief
# for a marked project forbids reproducing the contract or the fact that it
# exists on any published surface. A worker that pastes this refusal into a PR
# comment or an evidence file must publish nothing about the marking: not the
# registry token, not the contract path, not the project's registered posture,
# not which project matched. The specifics stay in firstmate's own home, which
# already holds the registry row and the contract. Mutation: put any of those
# identifiers back into the refusal and the matching assertion fails.
test_external_contract_refusal_identifies_nothing_in_the_worktree() {
  local home repo worktree out
  home="$TMP_ROOT/external-quiet-home"
  init_registered_project "$home" contracted-project 'no-mistakes-prod-only +external-contract'
  repo="$home/projects/contracted-project"
  worktree="$TMP_ROOT/external-quiet-worktree"
  git -C "$repo" worktree add -q --detach "$worktree" HEAD
  out=$(FM_HOME="$home" "$ROOT/bin/fm-ensure-agents-md.sh" "$worktree" 2>&1) \
    && fail "fm-ensure-agents-md.sh should refuse an externally contracted project"
  assert_contains "$out" "managed outside the repository" \
    "the refusal no longer states the policy the worker has to follow"
  assert_not_contains "$out" "external-contract" \
    "the refusal published the registry marker into the project worktree"
  assert_not_contains "$out" "project-contracts" \
    "the refusal published the private contract location into the project worktree"
  assert_not_contains "$out" "no-mistakes-prod-only" \
    "the refusal published the project's registered posture into the project worktree"
  assert_not_contains "$out" "contracted-project" \
    "the refusal published which project is externally contracted into the project worktree"
  assert_not_contains "$out" "$home" \
    "the refusal published an absolute path under the firstmate home into the project worktree"
  assert_absent "$worktree/AGENTS.md" "the refusal created AGENTS.md"
  assert_absent "$worktree/CLAUDE.md" "the refusal created CLAUDE.md"
  pass "fm-ensure-agents-md.sh: the external-contract refusal states the policy and identifies nothing"
}

# Mutation: classify every registered project as external and this ordinary
# registered project stops following the byte-for-byte legacy creation path.
test_ordinary_registered_project_keeps_existing_behavior() {
  local home repo out
  home="$TMP_ROOT/ordinary-registered-home"
  init_registered_project "$home" ordinary-project no-mistakes-prod-only
  repo="$home/projects/ordinary-project"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh changed ordinary registered-project behavior"
  assert_contains "$out" "created: AGENTS.md and CLAUDE.md" \
    "ordinary registered project changed its existing creation result"
  assert_present "$repo/AGENTS.md" "ordinary registered project did not create AGENTS.md"
  assert_claude_pointer "$repo/CLAUDE.md"
  pass "fm-ensure-agents-md.sh: ordinary registered projects retain existing behavior"
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
test_external_contract_project_refuses_without_creating_agent_files
test_external_contract_matches_equivalent_origin_spellings
test_external_contract_does_not_capture_a_different_repository
test_ordinary_registered_project_keeps_existing_behavior
test_external_contract_refusal_identifies_nothing_in_the_worktree
