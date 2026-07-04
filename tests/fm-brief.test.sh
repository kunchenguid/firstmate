#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issue
# #166): the ship-mode branches used to build their Definition-of-done text
# with `VAR=$(cat <<EOF ... EOF)`. Bash 3.2 (macOS /bin/bash) tracks quote
# state through the heredoc body while it scans for the matching `)` of the
# command substitution, so a single unescaped apostrophe anywhere in that body
# breaks parsing of the *entire rest of the script* - `bash -n` fails, not
# just the generated brief. Modern bash (4+) parses it fine, so Linux CI never
# sees the failure. The branches now assign via `read -r -d '' VAR <<EOF`,
# which is immune; the structural test below keeps the fragile construct from
# coming back, since `bash -n` alone only catches it on a bash-3.2 machine.
# A plain `cat > file <<EOF ... EOF` (not wrapped in `$(...)`) is unaffected,
# so the secondmate charter block does not need this guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)

# The script itself must always parse. This is the direct regression test for
# issue #166; on macOS it runs under the affected /bin/bash 3.2 itself.
test_script_parses() {
  bash -n "$ROOT/bin/fm-brief.sh" 2>&1 || fail "bin/fm-brief.sh fails bash -n (heredoc/quote regression)"
  if [ -x /bin/bash ]; then
    /bin/bash -n "$ROOT/bin/fm-brief.sh" 2>&1 || fail "bin/fm-brief.sh fails /bin/bash -n (bash 3.2 heredoc/quote regression)"
  fi
  pass "fm-brief.sh: bash -n succeeds"
}

# Structural guard for issue #166: heredocs nested inside \$(cat <<...) are a
# bash-3.2 parse trap that Linux CI's modern bash cannot detect via `bash -n`,
# so refuse the construct itself anywhere in fm-brief.sh.
test_no_heredoc_in_command_substitution() {
  if grep -n '^[^#]*\$(cat <<' "$ROOT/bin/fm-brief.sh"; then
    fail "fm-brief.sh reintroduced \$(cat <<...) - breaks bash 3.2 parsing if the body ever gains an apostrophe; assign with read -r -d '' instead"
  fi
  pass "fm-brief.sh: no heredoc-in-command-substitution construct"
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

test_script_parses
test_no_heredoc_in_command_substitution
test_ship_modes_generate_clean_briefs
test_no_mistakes_dod_wording
