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
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse. This is the direct regression test for
# issue #166: a stray apostrophe in any of the three DOD heredoc bodies
# (no-mistakes/direct-PR/local-only) breaks `bash -n` on the whole file.
# The bug only reproduces on Bash 3.2, which the PATH bash usually is not, so
# /bin/bash is checked too - that gives a macOS developer the same signal the
# stock-Bash CI lane provides instead of a green local run.
test_script_parses() {
  local interp out rc
  for interp in "$(command -v bash)" /bin/bash; do
    [ -x "$interp" ] || continue
    out=$("$interp" -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
    expect_code 0 "$rc" "$interp -n bin/fm-brief.sh must parse cleanly (got: $out)"
    [ -z "$out" ] || fail "$interp -n bin/fm-brief.sh emitted unexpected output: $out"
  done
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
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
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
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_no_grep "no-mistakes' own guidance" "$brief" \
    "no-mistakes DOD regressed to the apostrophe form that breaks bash -n"
  pass "fm-brief.sh: no-mistakes DOD wording avoids the apostrophe regression"
}

# No-mistakes ship briefs own the PR-body contract for the intent statement.
# The concise guidance must stay scoped to no-mistakes because direct-PR and
# scout tasks never invoke `no-mistakes axi run`.
test_no_mistakes_intent_guidance_is_scoped() {
  local home id brief
  home="$TMP_ROOT/intent-guidance-home"
  write_registry "$home"

  id="brief-intent-nm-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" no-registry-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "no-mistakes brief was not scaffolded"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`## What is the problem`' "$brief" \
    "no-mistakes DOD missing the problem heading"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`## What was the fix`' "$brief" \
    "no-mistakes DOD missing the fix heading"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`## Proof of work`' "$brief" \
    "no-mistakes DOD missing the proof heading"
  assert_grep "exactly these three top-level headings, in this order" "$brief" \
    "no-mistakes DOD does not require the exact PR-body heading set"
  assert_grep "latest effective decisions to evidence" "$brief" \
    "no-mistakes DOD does not require decision-to-evidence mapping"
  assert_grep "superseded decisions that were not followed" "$brief" \
    "no-mistakes DOD does not require disclosure of superseded decisions"
  assert_grep "relevant tests" "$brief" \
    "no-mistakes DOD does not require relevant test evidence"
  assert_grep "screenshots for UI work" "$brief" \
    "no-mistakes DOD does not require UI screenshots"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_no_grep '`## Problem`' "$brief" \
    "no-mistakes DOD retained the superseded Problem heading"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_no_grep '`## Fix`' "$brief" \
    "no-mistakes DOD retained the superseded Fix heading"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_no_grep '`## Proof`' "$brief" \
    "no-mistakes DOD retained the superseded Proof heading"
  assert_no_grep "Any other section" "$brief" \
    "no-mistakes DOD permits extra top-level sections"
  assert_grep "No single multi-paragraph run-on" "$brief" \
    "no-mistakes DOD missing the anti-wall-of-text instruction"

  id="brief-intent-dp-c2"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "direct-PR brief was not scaffolded"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_no_grep '`## Problem`' "$brief" \
    "direct-PR brief leaked no-mistakes intent guidance"
  assert_no_grep "No single multi-paragraph run-on" "$brief" \
    "direct-PR brief leaked no-mistakes intent guidance"

  id="brief-intent-scout-c3"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" no-registry-proj --scout >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_no_grep '`## Problem`' "$brief" \
    "scout brief leaked no-mistakes intent guidance"
  assert_no_grep "No single multi-paragraph run-on" "$brief" \
    "scout brief leaked no-mistakes intent guidance"

  pass "fm-brief.sh: concise-intent PR guidance is scoped to the no-mistakes DOD"
}

# The scaffold owns the crew branch-naming convention, keyed off the project's
# +ticket:<prefix> registry flag (bin/fm-project-mode.sh). A ticketless project
# branches <type>/<slug>; a ticket-mandated one branches <prefix>-<ticket-id>-<slug>
# and the tracker auto-links from the branch name, so NO PR-title prefix machinery
# is emitted. The brief states exactly ONE rule so the crewmate never has to guess,
# and never fm/<id> - that prefix stays reserved for the work window.
test_ticketless_branch_naming_convention() {
  local home id brief
  home="$TMP_ROOT/branch-convention-home"
  write_registry "$home"

  # Shared branch step: present in every ship mode, and never fm/<id>.
  for id_proj in "conv-nm:no-registry-proj" "conv-dp:direct-proj" "conv-lo:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    # shellcheck disable=SC2016  # literal backticks must render in the brief
    assert_grep 'create your branch `<type>/<short-slug>`' "$brief" \
      "$id: brief missing the ticketless conventional-commit branch rule"
    assert_grep "conventional-commit type" "$brief" \
      "$id: brief missing the conventional-commit type list"
    assert_no_grep "<ticket-id>" "$brief" \
      "$id: ticketless brief must not emit the ticket-mandated rule"
    assert_no_grep "Shortcut MCP" "$brief" \
      "$id: ticketless brief must not tell the crewmate to create a ticket"
    # shellcheck disable=SC2016  # literal backticks must render in the brief
    assert_grep 'prefix names the work window' "$brief" \
      "$id: brief lost the fm/-is-the-window note"
    # shellcheck disable=SC2016  # literal command text must render verbatim
    assert_no_grep 'git checkout -b fm/' "$brief" \
      "$id: brief still tells the crewmate to create an fm/ branch"
    assert_no_grep "create your branch: " "$brief" \
      "$id: brief kept the old single-line fm/<id> branch step"
    # Crewmate-chosen names share one namespace, so a collision must not stall the task.
    assert_grep "if \`git checkout -b\` reports the name already exists" "$brief" \
      "$id: brief missing the branch-name collision guidance"
    # Shortcut auto-links from the branch name, so no PR-title-prefix machinery.
    assert_no_grep "The PR title must be prefixed" "$brief" \
      "$id: brief still emits a PR-title-prefix rule (branch-name linking makes it unneeded)"
    assert_no_grep "commit with a conventional-commit subject prefixed" "$brief" \
      "$id: brief still carries the commit-subject title-prefix trick"
    assert_no_grep 'gh-axi pr edit' "$brief" \
      "$id: brief still tells the crewmate to edit the PR title"
    assert_no_grep "Set that prefix in the title" "$brief" \
      "$id: brief still tells the crewmate to set a PR-title prefix"
  done

  pass "fm-brief.sh: a ticketless project gets only the <type>/<slug> branch rule, no PR-title machinery"
}

# A project registered with +ticket:<prefix> gets the ticketed branch rule only,
# and the brief names the concrete mechanism for obtaining the ticket id. The
# branch name itself carries the ticket id (that is what the tracker auto-links),
# so no PR-title-prefix machinery is emitted.
test_ticketed_branch_naming_convention() {
  local home id brief
  home="$TMP_ROOT/ticket-convention-home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- ticket-nm-proj [no-mistakes +ticket:sc] - fixture for a ticket-mandated no-mistakes repo (added 2026-07-01)
- ticket-dp-proj [direct-PR +yolo +ticket:sc] - fixture for a ticket-mandated direct-PR repo (added 2026-07-01)
EOF

  for id_proj in "tkt-nm:ticket-nm-proj" "tkt-dp:ticket-dp-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    # shellcheck disable=SC2016  # literal backticks must render in the brief
    assert_grep 'branch `sc-<ticket-id>-<short-slug>`' "$brief" \
      "$id: brief missing the ticket-mandated branch rule"
    assert_grep "in the project's own ticket tracker" "$brief" \
      "$id: ticketed brief must name where the crewmate creates or links the ticket"
    assert_grep "for a Shortcut project, the Shortcut MCP tools" "$brief" \
      "$id: ticketed brief must keep Shortcut as the worked example, not the only tracker"
    assert_grep "auto-links the ticket from this branch name" "$brief" \
      "$id: ticketed brief must state the tracker links from the branch name"
    assert_grep "if \`git checkout -b\` reports the name already exists" "$brief" \
      "$id: brief missing the branch-name collision guidance"
    # shellcheck disable=SC2016  # literal backticks must render in the brief
    assert_no_grep 'create your branch `<type>/<short-slug>`' "$brief" \
      "$id: ticketed brief must not also emit the ticketless branch rule"
    assert_no_grep "conventional-commit type" "$brief" \
      "$id: ticketed brief must not offer the conventional-commit alternative"
    # shellcheck disable=SC2016  # literal backticks must render in the brief
    assert_grep 'prefix names the work window' "$brief" \
      "$id: brief lost the fm/-is-the-window note"
    # Branch-name linking makes any PR-title-prefix machinery unnecessary.
    assert_no_grep "The PR title must be prefixed" "$brief" \
      "$id: ticketed brief still emits a PR-title-prefix rule"
    assert_no_grep "commit with the subject prefixed" "$brief" \
      "$id: ticketed brief still carries the commit-subject title-prefix trick"
    assert_no_grep 'gh-axi pr edit' "$brief" \
      "$id: ticketed brief still tells the crewmate to edit the PR title"
    assert_no_grep "Set that prefix in the title" "$brief" \
      "$id: ticketed brief still tells the crewmate to set a PR-title prefix"
  done

  # The private fleet's own repo names must never leak into this shared template.
  assert_no_grep "apply_pass_backend" "$ROOT/bin/fm-brief.sh" \
    "fm-brief.sh hardcodes a captain-private project name"
  assert_no_grep "ai_backend" "$ROOT/bin/fm-brief.sh" \
    "fm-brief.sh hardcodes a captain-private project name"

  pass "fm-brief.sh: a +ticket project gets only the ticketed branch rule, no PR-title machinery"
}

# The +ticket:<prefix> flag accepts any bare token, so the brief must not claim
# one specific tracker owns a prefix it knows nothing about.
test_non_shortcut_ticket_prefix_keeps_tracker_generic() {
  local home brief
  home="$TMP_ROOT/eng-ticket-home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- eng-proj [direct-PR +ticket:ENG] - fixture for a non-Shortcut ticket-mandated repo (added 2026-07-01)
EOF

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tkt-eng eng-proj >/dev/null 2>&1
  brief="$home/data/tkt-eng/brief.md"
  assert_present "$brief" "tkt-eng: brief was not scaffolded"
  # shellcheck disable=SC2016  # literal backticks must render in the brief
  assert_grep 'branch `ENG-<ticket-id>-<short-slug>`' "$brief" \
    "tkt-eng: brief missing the derived ENG branch rule"
  assert_grep "in the project's own ticket tracker" "$brief" \
    "tkt-eng: brief must point at the project's own tracker"
  assert_no_grep "create or link the ticket FIRST with the Shortcut" "$brief" \
    "tkt-eng: brief names Shortcut as the tracker for a non-Shortcut prefix"

  pass "fm-brief.sh: a non-Shortcut ticket prefix does not claim Shortcut as its tracker"
}

# fm-merge-local.sh and fm-review-diff.sh both point readers at this script's
# --help as the owner of the branch convention, so --help must state it.
test_help_states_branch_convention() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "+ticket:<prefix>" "fm-brief.sh --help omitted the ticket flag that keys the convention"
  assert_contains "$help" "<prefix>-<ticket-id>-<short-slug>" "fm-brief.sh --help omitted the ticketed branch shape"
  assert_contains "$help" "<type>/<short-slug>" "fm-brief.sh --help omitted the ticketless branch shape"
  assert_contains "$help" "names the work window" "fm-brief.sh --help omitted the fm/-window note"
  pass "fm-brief.sh: --help owns the branch convention it is cited for"
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
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
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

test_secondmate_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" marked-request-reporting --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "secondmate charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "secondmate charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "secondmate charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "secondmate charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "secondmate charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "secondmate charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "secondmate charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "secondmate charter lost correlated parent results"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "secondmate charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "secondmate charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "secondmate charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, or work ready for review' "$brief" \
    "secondmate charter lost decisions, blockers, failures, or ready outcomes"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "secondmate charter changed the preserved status vocabulary"
  pass "fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
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

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the unresolved-decision policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`decision-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared decision policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

test_script_parses
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_ticketless_branch_naming_convention
test_ticketed_branch_naming_convention
test_non_shortcut_ticket_prefix_keeps_tracker_generic
test_help_states_branch_convention
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_no_mistakes_intent_guidance_is_scoped
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_secondmate_marked_request_reporting_contract
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_scout_and_secondmate_scaffold
