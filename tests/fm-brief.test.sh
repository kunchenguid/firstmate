#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issue
# #166): each ship-mode branch builds its Definition-of-done text with
# `VAR=$(cat <<EOF ... EOF)`. Bash's lexer tracks quote state through the
# heredoc body while it scans for the matching `)` of the command
# substitution, so a single unescaped apostrophe anywhere in that body breaks
# parsing of the *entire rest of the script* - `bash -n` fails, not just the
# generated brief. A plain `cat > file <<EOF ... EOF` (not wrapped in `$(...)`)
# is unaffected, so the secondmate charter block does not need this guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)

# The script itself must always parse. This is the direct regression test for
# issue #166: a stray apostrophe in any of the three DOD heredoc bodies
# (no-mistakes/direct-PR/local-only) breaks `bash -n` on the whole file.
test_script_parses() {
  bash -n "$ROOT/bin/fm-brief.sh" 2>&1 || fail "bin/fm-brief.sh fails bash -n (heredoc/quote regression)"
  pass "fm-brief.sh: bash -n succeeds"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

write_json_local_registry() {
  local home=$1 repo=$2 repo_real
  repo_real=$(cd "$repo" && pwd -P)
  mkdir -p "$home/data"
  cat > "$home/data/projects.json" <<EOF
{
  "schemaVersion": 1,
  "projects": [
    {
      "projectId": "local-dev-proj",
      "canonicalPath": "$repo_real",
      "gitCommonDir": "$repo_real/.git",
      "defaultBranch": "dev",
      "baseRef": "refs/heads/dev",
      "mode": "local-only",
      "yolo": false
    }
  ]
}
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  assert_no_grep "no-mistakes' own guidance" "$brief" \
    "no-mistakes DOD regressed to the apostrophe form that breaks bash -n"
  pass "fm-brief.sh: no-mistakes DOD wording avoids the apostrophe regression"
}

test_local_only_brief_uses_registry_default_branch() {
  local home repo id brief
  home="$TMP_ROOT/local-default-home"
  repo="$TMP_ROOT/local-default-repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" symbolic-ref HEAD refs/heads/dev
  write_json_local_registry "$home" "$repo"

  id="brief-local-dev-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-dev-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"

  assert_grep "firstmate handles the merge into local \`dev\`" "$brief" \
    "local-only brief did not name the registry default branch in Rule 1"
  assert_grep "if \`dev\` has advanced" "$brief" \
    "local-only DOD did not name the registry default branch in rebase guidance"
  assert_no_grep "local \`main\`" "$brief" \
    "local-only brief should not hardcode main for registry defaultBranch=dev"
  pass "fm-brief.sh: local-only briefs honor registry defaultBranch"
}

test_ship_and_scout_briefs_reference_native_first_browser_policy() {
  local home ship_id scout_id ship_brief scout_brief
  home="$TMP_ROOT/browser-policy-home"
  mkdir -p "$home/data"
  ship_id="browser-ship-d1"
  scout_id="browser-scout-d2"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$ship_id" some-proj >/dev/null 2>&1
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$scout_id" some-proj --scout >/dev/null 2>&1
  ship_brief="$home/data/$ship_id/brief.md"
  scout_brief="$home/data/$scout_id/brief.md"

  for brief in "$ship_brief" "$scout_brief"; do
    assert_grep "$ROOT/.agents/skills/browser-tool-policy/SKILL.md" "$brief" \
      "generated brief did not direct the crewmate to the browser policy skill"
    assert_grep "prefers the active harness native browser capability" "$brief" \
      "generated brief did not summarize the native-first browser policy"
    assert_grep "chrome-devtools-axi as an isolated fallback" "$brief" \
      "generated brief did not preserve AXI as an isolated fallback"
    assert_no_grep "chrome-devtools-axi for browser operations" "$brief" \
      "generated brief retained the unconditional AXI-first browser rule"
  done
  pass "fm-brief.sh: ship and scout briefs reference the native-first browser policy"
}

test_script_parses
test_ship_modes_generate_clean_briefs
test_no_mistakes_dod_wording
test_local_only_brief_uses_registry_default_branch
test_ship_and_scout_briefs_reference_native_first_browser_policy
