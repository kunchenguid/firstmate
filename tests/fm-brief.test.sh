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

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
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

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

# --base <branch> shapes the brief and NOTHING ELSE. The durable record of a task's
# base lives in state/<id>.meta, written by fm-spawn.sh --base, so the scaffold owns
# no state a later run could disagree with - and the operator is told to pass the
# same flag to the spawn, because a brief alone leaves the guard unarmed.
test_base_no_mistakes_shapes_brief_and_records_nothing() {
  local home id brief out
  home="$TMP_ROOT/base-nm-home"
  mkdir -p "$home/data"
  id="brief-base-nm1"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --base feature/admin-dashboard 2>&1) \
    || fail "base-nm: fm-brief.sh --base should exit 0 for a no-mistakes ship task"
  brief="$home/data/$id/brief.md"
  assert_grep "**Base branch.** This task targets base branch \`feature/admin-dashboard\`" "$brief" \
    "base-nm: brief missing the Setup base note"
  [ ! -e "$home/data/$id/base" ] \
    || fail "base-nm: the scaffold wrote a second source of truth for the base; meta is the only one"
  assert_contains "$out" "fm-spawn.sh $id <project> --base feature/admin-dashboard" \
    "base-nm: the scaffold did not tell the operator to declare the same base at spawn, where the guard is actually armed"
  pass "fm-brief.sh: --base shapes the brief, records no state, and names the spawn that does"
}

# The worktree starts on the DEFAULT branch, so a based task must be given the
# actual commands to root fm/<id> on the intended base. Forbidding the wrong
# outcome without supplying the command to avoid it is not an instruction.
test_base_roots_branch_on_the_base() {
  local home id brief
  home="$TMP_ROOT/base-root-home"
  mkdir -p "$home/data"
  id="brief-base-root1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --base feature/x >/dev/null 2>&1 \
    || fail "base-root: fm-brief.sh --base should exit 0"
  brief="$home/data/$id/brief.md"
  assert_grep "git fetch origin feature/x" "$brief" \
    "base-root: brief does not tell the crewmate to fetch the intended base"
  assert_grep "git checkout -b fm/$id FETCH_HEAD" "$brief" \
    "base-root: brief does not root the branch on the fetched base"
  assert_no_grep "First action: create your branch" "$brief" \
    "base-root: the default-branch-rooted step is still the first action of a based brief"
  pass "fm-brief.sh: --base roots the crewmate's branch on the intended base, not the default branch"
}

# A crewmate cannot tell "the branch is gone" from "origin is unreachable" by looking at a
# fetch's exit status, and reading either one as "the base must have merged" is a fail-open:
# it would silently turn a based task into an unbased one and hand firstmate a status line
# it believes. The brief must therefore never invite that inference. It does not need to:
# fm-spawn.sh only launches a based task against a LIVE base, so the fetch failing is a real
# problem, and firstmate - which holds the recorded tip and bin/fm-base-lib.sh - is the only
# one that can tell a merged base from an abandoned one.
test_base_setup_never_infers_a_merge_from_a_failed_fetch() {
  local home id brief
  home="$TMP_ROOT/base-gone-home"
  mkdir -p "$home/data"
  id="brief-base-gone1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --base feature/x >/dev/null 2>&1 \
    || fail "base-gone: fm-brief.sh --base should exit 0"
  brief="$home/data/$id/brief.md"
  assert_grep "If that fetch does not succeed, STOP" "$brief" \
    "base-gone: the brief leaves the crewmate to improvise when the base cannot be fetched"
  assert_grep "blocked: intended base feature/x could not be fetched from origin" "$brief" \
    "base-gone: the crewmate is not told to report the unfetchable base, so firstmate never learns of it"
  assert_no_grep "it merged" "$brief" \
    "base-gone: the brief still reads a failed fetch as a merged base - the fail-open this closes"
  assert_no_grep "IGNORE every other base-branch instruction" "$brief" \
    "base-gone: the brief still tells the crewmate to discard its base instructions on a guess"
  pass "fm-brief.sh: --base tells the crewmate to stop, not to guess, when the base cannot be fetched"
}

# The no-mistakes pipeline cannot be told a base: it always rebases onto the repo
# default and opens the PR there. The brief must not ask for the impossible; it
# must name the recovery that actually works (retarget the PR, pipeline re-rebases).
test_base_no_mistakes_brief_documents_the_real_recovery() {
  local home id brief
  home="$TMP_ROOT/base-recovery-home"
  mkdir -p "$home/data"
  id="brief-base-rec1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --base feature/x >/dev/null 2>&1 \
    || fail "base-recovery: fm-brief.sh --base should exit 0"
  brief="$home/data/$id/brief.md"
  assert_no_grep "tell the run its base" "$brief" \
    "base-recovery: brief still asks the crewmate to declare a base to the pipeline, which it cannot do"
  assert_grep "gh-axi pr edit {n} --base feature/x" "$brief" \
    "base-recovery: brief missing the PR retarget command"
  assert_grep "re-rebases your branch onto \`feature/x\`" "$brief" \
    "base-recovery: brief does not explain that the pipeline self-heals after the retarget"
  pass "fm-brief.sh: the no-mistakes base brief documents the retarget recovery, not an impossible base flag"
}

# The stock no-mistakes definition of done ends with "and stop. You are finished."
# An extra gate appended AFTER that terminator is one the crewmate stops before
# reaching, so the base retarget has to sit BEFORE it - otherwise the crewmate
# reports done on a still-default-based PR, the pre-merge guard refuses it, and
# the task stalls on a supervision round-trip that the brief was supposed to avoid.
test_base_gate_precedes_the_done_terminator() {
  local home id brief gate_line done_line
  home="$TMP_ROOT/base-order-home"
  mkdir -p "$home/data"
  id="brief-base-order1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --base feature/x >/dev/null 2>&1 \
    || fail "base-order: fm-brief.sh --base should exit 0"
  brief="$home/data/$id/brief.md"

  gate_line=$(grep -n 'gh-axi pr edit {n} --base feature/x' "$brief" | head -1 | cut -d: -f1)
  done_line=$(grep -n 'You are finished\.' "$brief" | head -1 | cut -d: -f1)
  [ -n "$gate_line" ] || fail "base-order: the brief has no base retarget gate at all"
  [ -n "$done_line" ] || fail "base-order: the brief has no 'You are finished.' terminator"
  [ "$gate_line" -lt "$done_line" ] \
    || fail "base-order: the base gate (line $gate_line) sits AFTER 'You are finished.' (line $done_line), so the crewmate stops before reading it"

  # And the terminator itself must carry the base condition, so a crewmate that
  # reads only the done line still cannot call a default-based PR done.
  assert_grep "gh-axi pr view {n} --json baseRefName\` reports \`feature/x\`" "$brief" \
    "base-order: the done condition does not require the PR's base label to report the intended base"
  pass "fm-brief.sh: the base gate is read before the definition of done's terminator"
}

# The --base=<branch> form is accepted too.
test_base_equals_form() {
  local home id brief
  home="$TMP_ROOT/base-equals-home"
  mkdir -p "$home/data"
  id="brief-base-eq1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --base=feature/x >/dev/null 2>&1 \
    || fail "base-equals: --base=<branch> form should be accepted"
  brief="$home/data/$id/brief.md"
  assert_grep "git checkout -b fm/$id FETCH_HEAD" "$brief" \
    "base-equals: --base=<branch> did not root the branch step on the base"
  pass "fm-brief.sh: --base=<branch> form shapes the brief exactly as the two-token form"
}

# For a direct-PR project, --base tells the crewmate to open the PR against it.
test_base_direct_pr_targets_base() {
  local home id brief
  home="$TMP_ROOT/base-dpr-home"
  write_registry "$home"
  id="brief-base-dpr1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --base feature/x >/dev/null 2>&1 \
    || fail "base-dpr: fm-brief.sh --base should exit 0 for a direct-PR ship task"
  brief="$home/data/$id/brief.md"
  assert_grep "gh-axi pr create --base feature/x" "$brief" \
    "base-dpr: direct-PR brief missing the --base PR-open instruction"
  pass "fm-brief.sh: --base makes a direct-PR brief open the PR against the base"
}

# --base is rejected where it has no meaning: scout, secondmate, and local-only.
test_base_rejected_for_scout() {
  local home id status err
  home="$TMP_ROOT/base-scout-home"
  mkdir -p "$home/data"
  id="brief-base-scout1"
  err=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout --base feature/x 2>&1); status=$?
  expect_code 1 "$status" "base-scout: --base with --scout should be rejected"
  assert_contains "$err" "applies only to ship tasks" "base-scout: refusal did not explain scope"
  assert_absent "$home/data/$id/brief.md" "base-scout: a rejected --base must not leave a brief"
  pass "fm-brief.sh: --base is rejected for scout tasks"
}

test_base_rejected_for_local_only() {
  local home id status err
  home="$TMP_ROOT/base-local-home"
  write_registry "$home"
  id="brief-base-local1"
  err=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --base feature/x 2>&1); status=$?
  expect_code 1 "$status" "base-local: --base with local-only mode should be rejected"
  assert_contains "$err" "does not apply to local-only" "base-local: refusal did not explain local-only"
  pass "fm-brief.sh: --base is rejected for local-only projects"
}

# `--base` must not swallow the next flag as its value: `--base --scout` used to
# record the branch name as "--scout" and silently drop the scout flag.
test_base_rejects_a_flag_as_its_value() {
  local home id status err
  home="$TMP_ROOT/base-flagvalue-home"
  mkdir -p "$home/data"
  id="brief-base-flagvalue1"
  err=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --base --scout 2>&1); status=$?
  expect_code 1 "$status" "base-flagvalue: --base followed by a flag should be rejected, not consumed as the branch name"
  assert_contains "$err" "requires a branch name" "base-flagvalue: refusal did not explain the missing value"
  assert_absent "$home/data/$id/brief.md" "base-flagvalue: a rejected --base must not leave a brief"
  pass "fm-brief.sh: --base refuses to consume a following flag as its branch name"
}

# The base flows into `git fetch origin <base>` downstream, where a leading dash
# would be parsed as an option rather than a refspec.
test_base_rejects_dash_leading_and_invalid_names() {
  local home status err
  home="$TMP_ROOT/base-badname-home"
  mkdir -p "$home/data"

  err=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-base-dash1 some-proj --base=--upload-pack=touch 2>&1); status=$?
  expect_code 1 "$status" "base-badname: a dash-leading base must be rejected"
  assert_contains "$err" "must not begin with '-'" "base-badname: refusal did not explain the leading dash"
  assert_absent "$home/data/brief-base-dash1/brief.md" "base-badname: a rejected --base must not leave a brief"

  err=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-base-bad2 some-proj --base='feature/..x' 2>&1); status=$?
  expect_code 1 "$status" "base-badname: an invalid git branch name must be rejected"
  assert_contains "$err" "not a valid git branch name" "base-badname: refusal did not explain the invalid ref name"
  assert_absent "$home/data/brief-base-bad2/brief.md" "base-badname: a rejected --base must not leave a brief"

  err=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-base-empty3 some-proj --base= 2>&1); status=$?
  expect_code 1 "$status" "base-badname: an empty base must be rejected"
  assert_contains "$err" "non-empty branch name" "base-badname: refusal did not explain the empty value"
  assert_absent "$home/data/brief-base-empty3/brief.md" "base-badname: a rejected --base must not leave a brief"

  pass "fm-brief.sh: --base rejects empty, dash-leading, and malformed branch names"
}

# The Setup note and the definition of done must not disagree about the pipeline's
# rebase. A no-mistakes crewmate reads Setup first; if Setup forbids the branch ever
# ending up on the default branch, the pipeline's own (unavoidable, expected) rebase
# reads as the forbidden outcome, and the crewmate blocks instead of retargeting.
test_base_setup_note_agrees_with_the_pipeline() {
  local home id brief
  home="$TMP_ROOT/base-coherent-home"
  write_registry "$home"

  id="brief-base-coherent-nm1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --base feature/x >/dev/null 2>&1 \
    || fail "base-coherent: fm-brief.sh --base should exit 0 for a no-mistakes ship task"
  brief="$home/data/$id/brief.md"
  assert_grep "The no-mistakes pipeline WILL rebase it onto the default branch" "$brief" \
    "base-coherent: the no-mistakes Setup note does not admit the pipeline's rebase is expected"
  assert_no_grep "Firstmate refuses to record or merge a PR whose head is not rooted" "$brief" \
    "base-coherent: the no-mistakes Setup note still states a refusal the pipeline's own rebase would trip"

  # direct-PR has no pipeline, so the crewmate owns the branch end to end and the
  # absolute IS the truth there.
  id="brief-base-coherent-dpr1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --base feature/x >/dev/null 2>&1 \
    || fail "base-coherent: fm-brief.sh --base should exit 0 for a direct-PR ship task"
  brief="$home/data/$id/brief.md"
  assert_grep "keep it there and never rebase it onto the default branch" "$brief" \
    "base-coherent: the direct-PR Setup note should keep the branch on its base"
  assert_no_grep "The no-mistakes pipeline WILL rebase it" "$brief" \
    "base-coherent: a direct-PR brief must not talk about the pipeline it never runs"
  pass "fm-brief.sh: the base Setup note agrees with the delivery mode's definition of done"
}

# A scaffold owns no state, so re-scaffolding an id WITHOUT --base (AGENTS.md section
# 11 explicitly instructs a regenerate flow) cannot leave a stale base behind for the
# spawn to pick up: the brief it writes is the whole of its output, and the base lives
# only where the spawn is told to put it.
test_rescaffold_without_base_inherits_nothing() {
  local home id brief
  home="$TMP_ROOT/base-rescaffold-home"
  write_registry "$home"
  id="brief-base-rescaffold1"
  brief="$home/data/$id/brief.md"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --base feature/x >/dev/null 2>&1 \
    || fail "base-rescaffold: the first --base scaffold should exit 0"
  assert_grep "Base branch." "$brief" "base-rescaffold: the first scaffold should carry the base note"

  rm -f "$brief"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1 \
    || fail "base-rescaffold: re-scaffolding without --base should exit 0"

  assert_no_grep "Base branch." "$brief" \
    "base-rescaffold: the re-scaffolded brief must not carry the base note"
  [ ! -e "$home/data/$id/base" ] \
    || fail "base-rescaffold: a scaffold left base state behind for a later spawn to inherit"
  pass "fm-brief.sh: re-scaffolding without --base inherits nothing from the based run before it"
}

# Without --base the brief is unchanged: no base note, and no state either way.
test_no_base_leaves_brief_unchanged() {
  local home id brief
  home="$TMP_ROOT/no-base-home"
  mkdir -p "$home/data"
  id="brief-no-base1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_no_grep "Base branch." "$brief" "no-base: default brief must not carry the base note"
  pass "fm-brief.sh: a ship task without --base is unchanged (no base note)"
}

test_script_parses
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_no_mistakes_dod_wording
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_pause_verb_override_renders_all_brief_scaffolds
test_base_no_mistakes_shapes_brief_and_records_nothing
test_base_roots_branch_on_the_base
test_base_setup_never_infers_a_merge_from_a_failed_fetch
test_base_no_mistakes_brief_documents_the_real_recovery
test_base_gate_precedes_the_done_terminator
test_base_equals_form
test_base_direct_pr_targets_base
test_base_setup_note_agrees_with_the_pipeline
test_rescaffold_without_base_inherits_nothing
test_base_rejected_for_scout
test_base_rejects_a_flag_as_its_value
test_base_rejects_dash_leading_and_invalid_names
test_base_rejected_for_local_only
test_no_base_leaves_brief_unchanged
