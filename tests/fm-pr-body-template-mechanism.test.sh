#!/usr/bin/env bash
# Behavior tests for the pr-body-template-mechanism's integration points:
# bin/fm-brief.sh's scaffold requirement (emitted only for a templated
# direct-PR ship - the one mode where the worker itself opens the PR - and
# never for no-mistakes, local-only, scout, or an untemplated project) and
# the structural pre-open refusal itself, proven against a fake PR opener
# using the exact `&&`-gated sequence the brief requires. bin/fm-pr-body.sh's
# own render/check/strip behavior is covered by tests/fm-pr-body.test.sh.
#
# fm-pr-check.sh is deliberately not exercised here: it registers a PR
# *after* it is already open (arms the merge-watch poll), so it cannot own a
# before-open refusal and this mechanism does not touch it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-pr-body.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-body-template-mechanism)

# --- bin/fm-brief.sh scaffold requirement -----------------------------------

brief_home_with_template() {
  local dir=$1 project=$2
  mkdir -p "$dir/data/pr-templates"
  printf 'Summary\n{{SUMMARY}}\n' > "$dir/data/pr-templates/$project.md"
}

test_brief_requires_helper_for_templated_direct_pr() {
  local home id brief
  home="$TMP_ROOT/direct-pr-home"
  mkdir -p "$home/data"
  brief_home_with_template "$home" templated-proj
  id="brief-tpl-direct-pr"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" "$id" templated-proj --mode direct-PR >/dev/null 2>&1 \
    || fail "fm-brief.sh exited non-zero scaffolding a templated direct-PR brief"
  brief="$home/data/$id/brief.md"
  assert_grep "data/pr-templates/templated-proj.md" "$brief" \
    "templated direct-PR brief must name the private template it must use"
  assert_grep "fm-pr-body.sh' render" "$brief" \
    "templated direct-PR brief must require rendering through the helper"
  assert_grep "&& gh-axi pr create" "$brief" \
    "templated direct-PR brief must gate its own gh-axi PR-open call (the repository's own tool contract, not bare gh) on render's exit code, not on a remembered separate check"
  pass "fm-brief.sh: a templated direct-PR ship brief requires a render-gated gh-axi pr create"
}

repo_with_github_template() {
  local dir=$1 project=$2
  mkdir -p "$dir/projects/$project/.github"
  printf '## Summary\n{{SUMMARY}}\n' > "$dir/projects/$project/.github/PULL_REQUEST_TEMPLATE.md"
}

test_brief_requires_helper_for_repository_only_template() {
  local home id brief
  home="$TMP_ROOT/repo-template-home"
  mkdir -p "$home/data"
  repo_with_github_template "$home" repo-only-proj
  id="brief-repo-only"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" "$id" repo-only-proj --mode direct-PR >/dev/null 2>&1 \
    || fail "fm-brief.sh exited non-zero scaffolding a direct-PR brief for a project with only a repository-owned template"
  brief="$home/data/$id/brief.md"
  assert_grep "fm-pr-body.sh' render" "$brief" \
    "a project with only a repository-owned .github PR template must still require rendering through the helper (closing the repository-template activation gap)"
  assert_grep "&& gh-axi pr create" "$brief" \
    "a repository-only templated direct-PR brief must gate gh-axi pr create on render's exit code exactly like the private-template case"
  assert_no_grep "data/pr-templates/repo-only-proj.md" "$brief" \
    "no private template exists here, so the brief must not claim one at data/pr-templates/repo-only-proj.md"
  pass "fm-brief.sh: a direct-PR brief for a project with only a repository-owned .github PR template still requires the render-gated scaffold"
}

test_brief_omits_helper_requirement_for_no_mistakes_even_when_templated() {
  local home id brief
  home="$TMP_ROOT/no-mistakes-home"
  mkdir -p "$home/data"
  brief_home_with_template "$home" templated-proj
  id="brief-tpl-no-mistakes"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" "$id" templated-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "fm-brief.sh exited non-zero scaffolding a templated no-mistakes brief"
  brief="$home/data/$id/brief.md"
  assert_no_grep "fm-pr-body.sh" "$brief" \
    "no-mistakes owns the PR it opens and has no body-input seam in this slice, so its brief must carry no helper requirement even when a template exists"
  assert_grep "# PR requirements" "$brief" \
    "the no-mistakes brief must still carry the existing generic PR requirements section"
  pass "fm-brief.sh: a templated no-mistakes ship brief carries no helper requirement (no real integration seam in this slice)"
}

test_brief_omits_helper_requirement_without_template() {
  local home id brief
  home="$TMP_ROOT/no-template-home"
  mkdir -p "$home/data"
  id="brief-no-tpl"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" "$id" untemplated-proj --mode direct-PR >/dev/null 2>&1 \
    || fail "fm-brief.sh exited non-zero scaffolding an untemplated direct-PR brief"
  brief="$home/data/$id/brief.md"
  assert_no_grep "fm-pr-body.sh" "$brief" \
    "an untemplated project's brief must not reference the helper (missing-template compatibility: existing PR-rules path unchanged)"
  assert_grep "# PR requirements" "$brief" \
    "an untemplated project's brief must still carry the existing generic PR requirements section"
  pass "fm-brief.sh: a ship brief with no configured template carries no helper requirement"
}

test_brief_omits_helper_requirement_for_local_only() {
  local home id brief
  home="$TMP_ROOT/local-only-home"
  mkdir -p "$home/data"
  brief_home_with_template "$home" templated-proj
  id="brief-tpl-local-only"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" "$id" templated-proj --mode local-only >/dev/null 2>&1 \
    || fail "fm-brief.sh exited non-zero scaffolding a templated local-only brief"
  brief="$home/data/$id/brief.md"
  assert_no_grep "fm-pr-body.sh" "$brief" \
    "local-only never opens a PR, so its brief must carry no PR-body-template requirement even when a template exists"
  pass "fm-brief.sh: local-only stays clean of the PR-body-template requirement even when a template exists"
}

test_brief_omits_helper_requirement_for_scout() {
  local home report_id brief
  home="$TMP_ROOT/scout-home"
  mkdir -p "$home/data"
  brief_home_with_template "$home" templated-proj
  report_id="brief-tpl-scout"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" "$report_id" templated-proj --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh exited non-zero scaffolding a scout brief"
  brief="$home/data/$report_id/brief.md"
  assert_no_grep "fm-pr-body.sh" "$brief" \
    "a scout never opens a PR, so its brief must carry no PR-body-template requirement"
  pass "fm-brief.sh: scout scaffolds stay clean of the PR-body-template requirement"
}

test_brief_project_traversal_never_reaches_helper_requirement() {
  local home id brief
  home="$TMP_ROOT/traversal-home"
  mkdir -p "$home/data"
  id="brief-tpl-traversal"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" "$id" "../escape" --mode direct-PR >/dev/null 2>&1 \
    || fail "fm-brief.sh exited non-zero scaffolding a brief for a path-shaped repo name"
  brief="$home/data/$id/brief.md"
  assert_no_grep "fm-pr-body.sh" "$brief" \
    "a repo name shaped like a path must never be used to probe outside data/pr-templates"
  pass "fm-brief.sh: a path-shaped repo name is never used to look outside data/pr-templates"
}

# --- structural pre-open refusal, proven against a fake PR opener ----------
#
# This proves the mechanism itself, not brief prose: the exact `&&`-gated
# shell sequence bin/fm-brief.sh's direct-PR addendum requires (render --out
# <path> && <open>) really does keep a fake opener from ever running when the
# rendered body is incomplete, and really does invoke it once the body is
# complete. No fm-pr-check.sh or gh-axi involvement: this is a plain shell
# proof of the render-gates-open contract.

opener_case() {
  local name=$1 dir
  dir="$TMP_ROOT/opener-$name"
  mkdir -p "$dir/home/data/pr-templates" "$dir/repo"
  : > "$dir/opener.log"
  cat > "$dir/fake-open" <<SH
#!/usr/bin/env bash
printf 'opened: %s\n' "\$*" >> "$dir/opener.log"
SH
  chmod +x "$dir/fake-open"
  printf '%s\n' "$dir"
}

test_render_gated_open_never_runs_on_unresolved_body() {
  local dir rc
  dir=$(opener_case incomplete)
  printf 'Summary: {{SUMMARY}}\nTicket: {{TICKET}}\n' > "$dir/home/data/pr-templates/demo.md"
  FM_HOME="$dir/home" bash -c \
    '"$1" render --project demo --repo-dir "$2" --set SUMMARY=x --out "$3/out.md" && "$3/fake-open" --body-file "$3/out.md"' \
    _ "$TOOL" "$dir/repo" "$dir" >/dev/null 2>&1
  rc=$?
  expect_code 1 "$rc" "the gated sequence must exit non-zero when the rendered body is incomplete"
  assert_absent "$dir/out.md" "an incomplete render must never publish the body file the opener would read"
  [ -s "$dir/opener.log" ] && fail "the fake PR opener must never run when render leaves an unresolved placeholder"
  pass "fm-pr-body.sh: the render-gated open sequence never invokes the opener on an unresolved rendered body"
}

test_render_gated_open_runs_on_resolved_body() {
  local dir rc
  dir=$(opener_case complete)
  printf 'Summary: {{SUMMARY}}\nTicket: {{TICKET}}\n' > "$dir/home/data/pr-templates/demo.md"
  FM_HOME="$dir/home" bash -c \
    '"$1" render --project demo --repo-dir "$2" --set SUMMARY=x --set TICKET=T-1 --out "$3/out.md" && "$3/fake-open" --body-file "$3/out.md"' \
    _ "$TOOL" "$dir/repo" "$dir" >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "the gated sequence must succeed once the rendered body is complete"
  assert_present "$dir/out.md" "a complete render must publish the body file"
  assert_grep "opened: --body-file" "$dir/opener.log" \
    "the fake PR opener must run exactly once the rendered body is complete"
  pass "fm-pr-body.sh: the render-gated open sequence invokes the opener once the rendered body is complete"
}

test_render_gated_open_never_runs_on_local_path_leak() {
  local dir rc
  dir=$(opener_case local-path-leak)
  printf 'Summary: {{SUMMARY}}\n' > "$dir/home/data/pr-templates/demo.md"
  FM_HOME="$dir/home" bash -c \
    '"$1" render --project demo --repo-dir "$2" --set "SUMMARY=see /home/captain/notes/report.md" --out "$3/out.md" && "$3/fake-open" --body-file "$3/out.md"' \
    _ "$TOOL" "$dir/repo" "$dir" >/dev/null 2>&1
  rc=$?
  expect_code 1 "$rc" "the gated sequence must exit non-zero when the rendered body leaks a local filesystem path"
  assert_absent "$dir/out.md" "a body that leaks a local path must never be published to --out"
  [ -s "$dir/opener.log" ] && fail "the fake PR opener must never run when the rendered body leaks a local filesystem path"
  pass "fm-pr-body.sh: the render-gated open sequence never invokes the opener when the rendered body leaks a local filesystem path"
}

test_brief_requires_helper_for_templated_direct_pr
test_brief_requires_helper_for_repository_only_template
test_brief_omits_helper_requirement_for_no_mistakes_even_when_templated
test_brief_omits_helper_requirement_without_template
test_brief_omits_helper_requirement_for_local_only
test_brief_omits_helper_requirement_for_scout
test_brief_project_traversal_never_reaches_helper_requirement
test_render_gated_open_never_runs_on_unresolved_body
test_render_gated_open_runs_on_resolved_body
test_render_gated_open_never_runs_on_local_path_leak
