#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-body.sh: template precedence, safe named fills,
# deterministic rendering, missing-template compatibility, and the
# unresolved-placeholder refusal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-pr-body.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-body)

mkhome() {
  local dir=$1
  mkdir -p "$dir/home/data/pr-templates" "$dir/repo/.github"
  printf '%s\n' "$dir"
}

test_script_parses() {
  local out rc
  out=$(bash -n "$TOOL" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-pr-body.sh must parse cleanly (got: $out)"
  pass "fm-pr-body.sh: bash -n succeeds"
}

test_private_template_takes_precedence() {
  local dir; dir=$(mkhome "$TMP_ROOT/precedence")
  printf 'Private: {{SUMMARY}}\n' > "$dir/home/data/pr-templates/demo.md"
  printf 'Repo: {{SUMMARY}}\n' > "$dir/repo/.github/PULL_REQUEST_TEMPLATE.md"
  local out
  out=$(FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" --set SUMMARY=x 2>/dev/null) \
    || fail "render exited non-zero with both templates present"
  assert_contains "$out" "Private: x" "private per-project template must win over the repository template"
  pass "fm-pr-body.sh: private template takes precedence over the repository template"
}

test_repository_template_fallback() {
  local dir; dir=$(mkhome "$TMP_ROOT/fallback")
  printf 'Repo: {{SUMMARY}}\n' > "$dir/repo/.github/PULL_REQUEST_TEMPLATE.md"
  local out
  out=$(FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" --set SUMMARY=x 2>/dev/null) \
    || fail "render exited non-zero falling back to the repository template"
  assert_contains "$out" "Repo: x" "must fall back to the repository's own .github template when no private template exists"
  pass "fm-pr-body.sh: falls back to the repository's own .github pull-request template"
}

test_missing_template_steps_aside() {
  local dir; dir=$(mkhome "$TMP_ROOT/missing")
  local rc
  FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" --set SUMMARY=x >/dev/null 2>/dev/null
  rc=$?
  expect_code 3 "$rc" "render must exit 3 (step-aside signal) when neither template exists"
  FM_HOME="$dir/home" "$TOOL" has-template --project demo --repo-dir "$dir/repo" >/dev/null 2>/dev/null
  rc=$?
  expect_code 1 "$rc" "has-template must reserve exit 1 for true template absence"
  pass "fm-pr-body.sh: render steps aside with a distinct exit code when no template exists (missing-template compatibility)"
}

test_unreadable_template_fails_inspection() {
  local dir rc
  dir=$(mkhome "$TMP_ROOT/unreadable-template")
  printf 'Repo: {{SUMMARY}}\n' > "$dir/repo/.github/PULL_REQUEST_TEMPLATE.md"
  chmod 000 "$dir/repo/.github/PULL_REQUEST_TEMPLATE.md"
  FM_HOME="$dir/home" "$TOOL" has-template --project demo --repo-dir "$dir/repo" >/dev/null 2>/dev/null
  rc=$?
  chmod 600 "$dir/repo/.github/PULL_REQUEST_TEMPLATE.md"
  expect_code 4 "$rc" "has-template must distinguish unreadable templates from true absence"

  dir=$(mkhome "$TMP_ROOT/unsearchable-private-root")
  chmod 000 "$dir/home/data/pr-templates"
  FM_HOME="$dir/home" "$TOOL" has-template --project demo --repo-dir "$dir/repo" >/dev/null 2>/dev/null
  rc=$?
  chmod 700 "$dir/home/data/pr-templates"
  expect_code 4 "$rc" "has-template must distinguish an unsearchable private template root from true absence"

  dir=$(mkhome "$TMP_ROOT/unsearchable-repository-root")
  chmod 000 "$dir/repo/.github"
  FM_HOME="$dir/home" "$TOOL" has-template --project demo --repo-dir "$dir/repo" >/dev/null 2>/dev/null
  rc=$?
  chmod 700 "$dir/repo/.github"
  expect_code 4 "$rc" "has-template must distinguish an unsearchable repository template root from true absence"
  pass "fm-pr-body.sh: inaccessible templates and roots fail inspection instead of appearing absent"
}

test_known_template_under_searchable_nonlistable_root() {
  local dir out rc
  dir=$(mkhome "$TMP_ROOT/nonlistable-root")
  printf 'Repo: {{SUMMARY}}\n' > "$dir/repo/.github/PULL_REQUEST_TEMPLATE.md"
  chmod 0111 "$dir/repo/.github"
  out=$(FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" \
    --set SUMMARY=x 2>/dev/null) && rc=0 || rc=$?
  chmod 0700 "$dir/repo/.github"
  expect_code 0 "$rc" "a known template must remain usable when its searchable parent cannot be listed"
  assert_contains "$out" "Repo: x" "known template probing incorrectly required directory enumeration"
  pass "fm-pr-body.sh: known templates need search permission without directory listing permission"
}

test_enumeration_uses_validated_directory_descriptor() {
  local dir perl_bin template_dir marker out rc
  dir=$(mkhome "$TMP_ROOT/enumeration-race")
  perl_bin=$(command -v perl) || fail "perl is required for bound template-directory enumeration"
  template_dir="$dir/repo/.github/PULL_REQUEST_TEMPLATE"
  marker="$dir/swapped"
  mkdir -p "$template_dir" "$dir/bin"
  printf 'Repo: safe\n' > "$template_dir/default.md"
  cat > "$dir/bin/perl" <<'SH'
#!/usr/bin/env bash
"${FM_TEST_PERL:?}" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "${FM_RACE_MARKER:?}" ]; then
  : > "$FM_RACE_MARKER"
  mv "${FM_RACE_DIR:?}" "$FM_RACE_DIR.bound"
  mkdir "$FM_RACE_DIR"
  printf 'Repo: replacement\n' > "$FM_RACE_DIR/default.md"
fi
exit "$rc"
SH
  chmod +x "$dir/bin/perl"
  out=$(FM_TEST_PERL="$perl_bin" FM_RACE_DIR="$template_dir" FM_RACE_MARKER="$marker" \
    PATH="$dir/bin:$PATH" FM_HOME="$dir/home" \
    "$TOOL" has-template --project demo --repo-dir "$dir/repo" 2>&1) && rc=0 || rc=$?
  expect_code 4 "$rc" "replacing an enumerated template directory with the same selected filename must fail closed"
  assert_present "$marker" "the post-validation directory race fixture did not run"
  case "$out" in
    *'no-template'*) fail "a replaced template directory was reported as truly empty" ;;
  esac
  pass "fm-pr-body.sh: directory enumeration stays bound to its validated descriptor"
}

test_darwin_realpath_and_option_like_repo_path() {
  local dir realpath_bin out
  dir="$TMP_ROOT/darwin-realpath"
  realpath_bin=$(command -v realpath) || fail "realpath is required for template containment"
  mkdir -p "$dir/home/data/pr-templates" "$dir/-repo/.github" "$dir/bin"
  printf 'Repo: {{SUMMARY}}\n' > "$dir/-repo/.github/PULL_REQUEST_TEMPLATE.md"
  cat > "$dir/bin/realpath" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -e|--) exit 64 ;;
esac
[ -e "${1:-}" ] || [ -L "${1:-}" ] || exit 1
exec "${FM_TEST_REALPATH:?}" "$@"
SH
  chmod +x "$dir/bin/realpath"
  (
    cd "$dir" || exit 1
    FM_TEST_REALPATH="$realpath_bin" PATH="$dir/bin:$PATH" FM_HOME="$dir/home" \
      "$TOOL" has-template --project demo --repo-dir=-repo
  ) || fail "Darwin-compatible template discovery rejected an option-like relative repository path"
  out=$(
    cd "$dir" || exit 1
    FM_TEST_REALPATH="$realpath_bin" PATH="$dir/bin:$PATH" FM_HOME="$dir/home" \
      "$TOOL" render --project demo --repo-dir=-repo --set SUMMARY=x 2>/dev/null
  ) || fail "Darwin-compatible canonicalization failed to render the discovered template"
  assert_contains "$out" "Repo: x" "Darwin-compatible canonicalization must preserve repository template rendering"
  pass "fm-pr-body.sh: Darwin-compatible canonicalization safely handles option-like repository paths"
}

test_missing_candidate_during_canonicalization_is_refused() {
  local dir realpath_bin target escape out rc
  dir=$(mkhome "$TMP_ROOT/canonicalization-race")
  realpath_bin=$(command -v realpath) || fail "realpath is required for template containment"
  target="$dir/repo/.github/PULL_REQUEST_TEMPLATE.md"
  escape="$dir/escaped-template.md"
  printf 'Repo: safe\n' > "$target"
  printf 'Repo: escaped\n' > "$escape"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/realpath" <<'SH'
#!/usr/bin/env bash
target=${!#}
if [ "$target" = "${FM_RACE_TARGET:?}" ]; then
  rm -f "$target"
  resolved=$("${FM_TEST_REALPATH:?}" "$@") || exit $?
  ln -s "${FM_RACE_ESCAPE:?}" "$target"
  printf '%s\n' "$resolved"
  exit 0
fi
exec "${FM_TEST_REALPATH:?}" "$@"
SH
  chmod +x "$dir/bin/realpath"
  out=$(FM_RACE_TARGET="$target" FM_RACE_ESCAPE="$escape" FM_TEST_REALPATH="$realpath_bin" \
    PATH="$dir/bin:$PATH" FM_HOME="$dir/home" \
    "$TOOL" render --project demo --repo-dir "$dir/repo" 2>/dev/null) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a template removed during canonicalization must be refused"
  case "$out" in
    *escaped*) fail "canonicalization race escaped the template root" ;;
  esac
  pass "fm-pr-body.sh: missing canonicalization targets fail closed"
}

test_post_resolution_symlink_swap_is_refused() {
  local dir realpath_bin target escape out rc
  dir=$(mkhome "$TMP_ROOT/post-resolution-race")
  realpath_bin=$(command -v realpath) || fail "realpath is required for template containment"
  target="$dir/repo/.github/PULL_REQUEST_TEMPLATE.md"
  escape="$dir/escaped-template.md"
  printf 'Repo: safe\n' > "$target"
  printf 'Repo: escaped\n' > "$escape"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/realpath" <<'SH'
#!/usr/bin/env bash
target=${!#}
if [ "$target" = "${FM_RACE_TARGET:?}" ]; then
  resolved=$("${FM_TEST_REALPATH:?}" "$@") || exit $?
  rm -f "$target"
  ln -s "${FM_RACE_ESCAPE:?}" "$target"
  printf '%s\n' "$resolved"
  exit 0
fi
exec "${FM_TEST_REALPATH:?}" "$@"
SH
  chmod +x "$dir/bin/realpath"
  out=$(FM_RACE_TARGET="$target" FM_RACE_ESCAPE="$escape" FM_TEST_REALPATH="$realpath_bin" \
    PATH="$dir/bin:$PATH" FM_HOME="$dir/home" \
    "$TOOL" render --project demo --repo-dir "$dir/repo" 2>/dev/null) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a template replaced after canonicalization must be refused"
  case "$out" in
    *escaped*) fail "post-resolution symlink swap escaped the template root" ;;
  esac
  pass "fm-pr-body.sh: template identity changes after resolution are refused"
}

test_post_identity_symlink_swap_reads_bound_descriptor() {
  local dir perl_bin target escape marker out rc
  dir=$(mkhome "$TMP_ROOT/post-identity-race")
  perl_bin=$(command -v perl) || fail "perl is required for template identity checks"
  target="$dir/repo/.github/PULL_REQUEST_TEMPLATE.md"
  escape="$dir/escaped-template.md"
  marker="$dir/swapped"
  printf 'Repo: safe\n' > "$target"
  printf 'Repo: escaped\n' > "$escape"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/perl" <<'SH'
#!/usr/bin/env bash
"${FM_TEST_PERL:?}" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "${FM_RACE_MARKER:?}" ]; then
  : > "$FM_RACE_MARKER"
  rm -f "${FM_RACE_TARGET:?}"
  ln -s "${FM_RACE_ESCAPE:?}" "$FM_RACE_TARGET"
fi
exit "$rc"
SH
  chmod +x "$dir/bin/perl"
  out=$(FM_TEST_PERL="$perl_bin" FM_RACE_TARGET="$target" FM_RACE_ESCAPE="$escape" \
    FM_RACE_MARKER="$marker" PATH="$dir/bin:$PATH" FM_HOME="$dir/home" \
    "$TOOL" render --project demo --repo-dir "$dir/repo" 2>/dev/null) && rc=0 || rc=$?
  expect_code 0 "$rc" "render must keep reading the descriptor after the validated path is replaced"
  assert_present "$marker" "the post-identity race fixture did not replace the template path"
  [ -L "$target" ] || fail "the post-identity race fixture did not leave a replacement symlink"
  assert_contains "$out" "Repo: safe" "render reopened the replaced template path instead of reading its bound descriptor"
  case "$out" in
    *escaped*) fail "post-identity symlink swap escaped the bound template descriptor" ;;
  esac
  pass "fm-pr-body.sh: rendering reads the bound descriptor after a post-identity path swap"
}

test_safe_named_fills_no_eval() {
  local dir; dir=$(mkhome "$TMP_ROOT/safe-fill")
  printf 'Summary: {{SUMMARY}}\nTicket: {{TICKET}}\n' > "$dir/home/data/pr-templates/demo.md"
  local out
  # shellcheck disable=SC2016  # the single quotes are deliberate: this value must
  # reach fm-pr-body.sh as literal, unexpanded shell metacharacters. Deliberately
  # path-free (echo, not touch, and no embedded canary path) so the proof of no
  # eval/re-parsing never collides with the separate local-filesystem-path refusal.
  out=$(FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" \
    --set 'SUMMARY=$(echo INJECTED); `echo BACKTICK_INJECTED`; a && b' \
    --set 'TICKET=https://example.test/T-1' 2>/dev/null) \
    || fail "render exited non-zero on shell-metacharacter-laden values"
  # shellcheck disable=SC2016  # same deliberate literal match as above.
  assert_contains "$out" '$(echo INJECTED); `echo BACKTICK_INJECTED`; a && b' \
    "the literal metacharacter value must appear unexecuted in the rendered body (real eval would collapse it to just INJECTED/BACKTICK_INJECTED)"
  assert_contains "$out" "Ticket: https://example.test/T-1" "an ordinary named fill must still substitute correctly"
  pass "fm-pr-body.sh: named fills substitute literally with no eval or shell re-parsing"
}

test_literal_fill_is_not_reparsed_as_template() {
  local dir out
  dir=$(mkhome "$TMP_ROOT/literal-placeholder-fill")
  printf 'Summary: {{SUMMARY}}\nTicket: {{TICKET}}\n' > "$dir/home/data/pr-templates/demo.md"
  out=$(FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" \
    --set 'SUMMARY=literal {{TICKET}} text' --set TICKET=real 2>/dev/null) \
    || fail "a literal placeholder-looking fill must render successfully"
  assert_contains "$out" 'Summary: literal {{TICKET}} text' \
    "placeholder-shaped text inside a fill must survive as literal content"
  assert_contains "$out" "Ticket: real" \
    "the original template's separate placeholder must still be filled"
  pass "fm-pr-body.sh: filled values are substituted literally and never reparsed as template syntax"
}

test_set_file_reads_value_from_file() {
  local dir; dir=$(mkhome "$TMP_ROOT/set-file")
  printf 'Evidence:\n{{EVIDENCE}}\n' > "$dir/home/data/pr-templates/demo.md"
  printf 'line one\nline two\n' > "$dir/evidence.txt"
  local out
  out=$(FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" \
    --set-file EVIDENCE="$dir/evidence.txt" 2>/dev/null) \
    || fail "render exited non-zero with --set-file"
  assert_contains "$out" "line one" "--set-file must carry the file's content into the placeholder"
  assert_contains "$out" "line two" "--set-file must preserve multi-line content"
  pass "fm-pr-body.sh: --set-file fills a placeholder from file content"
}

test_rejects_lowercase_or_malformed_keys() {
  local dir; dir=$(mkhome "$TMP_ROOT/bad-key")
  printf '{{SUMMARY}}\n' > "$dir/home/data/pr-templates/demo.md"
  local rc
  FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" --set summary=x >/dev/null 2>/dev/null
  rc=$?
  expect_code 2 "$rc" "a lowercase --set key must be refused as a usage error"
  pass "fm-pr-body.sh: refuses a --set key that is not SCREAMING_SNAKE_CASE"
}

test_rejects_set_argument_missing_equals() {
  local dir; dir=$(mkhome "$TMP_ROOT/missing-equals")
  printf '{{SUMMARY}}\n' > "$dir/home/data/pr-templates/demo.md"
  local rc err
  # split form: --set FOO (no '=' at all)
  err=$(FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" --set FOO 2>&1 >/dev/null)
  rc=$?
  expect_code 2 "$rc" "--set FOO with no '=' must be refused, not silently become key=FOO val=FOO"
  assert_contains "$err" "FOO" "the refusal must name the malformed argument"
  # --flag=VALUE form: --set=FOO (no '=' after the flag's own '=')
  FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" --set=FOO >/dev/null 2>/dev/null
  rc=$?
  expect_code 2 "$rc" "--set=FOO with no second '=' must be refused the same way"
  # --set-file, both forms
  FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" --set-file FOO >/dev/null 2>/dev/null
  rc=$?
  expect_code 2 "$rc" "--set-file FOO with no '=' must be refused, not silently become key=FOO path=FOO"
  FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" --set-file=FOO >/dev/null 2>/dev/null
  rc=$?
  expect_code 2 "$rc" "--set-file=FOO with no second '=' must be refused the same way"
  pass "fm-pr-body.sh: refuses a --set/--set-file argument with no '=' in every accepted form, instead of silently treating it as key=value=that-same-token"
}

test_set_file_does_not_claim_trailing_newline_verbatim() {
  local dir; dir=$(mkhome "$TMP_ROOT/set-file-trailing-newline")
  printf '{{BODY}}\n' > "$dir/home/data/pr-templates/demo.md"
  printf 'line one\nline two\n\n\n' > "$dir/evidence.txt"
  local out
  out=$(FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" \
    --set-file BODY="$dir/evidence.txt" 2>/dev/null) \
    || fail "render exited non-zero with a --set-file source ending in blank lines"
  assert_contains "$out" "line one" "internal content must survive --set-file"
  assert_contains "$out" "line two" "internal newlines must survive --set-file"
  pass "fm-pr-body.sh: --set-file preserves internal content and newlines (its header no longer claims trailing-newline-exact verbatim capture)"
}

test_render_is_deterministic() {
  local dir; dir=$(mkhome "$TMP_ROOT/deterministic")
  printf 'Summary: {{SUMMARY}}\nTicket: {{TICKET}}\nHead: {{HEAD}}\n' > "$dir/home/data/pr-templates/demo.md"
  local out1 out2
  out1=$(FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" \
    --set SUMMARY=fixed --set TICKET=T-1 --set HEAD=abc123 2>/dev/null)
  out2=$(FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" \
    --set SUMMARY=fixed --set TICKET=T-1 --set HEAD=abc123 2>/dev/null)
  [ "$out1" = "$out2" ] || fail "identical inputs must render byte-identical output"
  pass "fm-pr-body.sh: rendering is deterministic for identical inputs"
}

test_check_refuses_unresolved_placeholders() {
  local dir; dir=$(mkhome "$TMP_ROOT/check-refuse")
  printf 'Summary: filled\nTicket: {{TICKET}}\nHead: {{HEAD}}\n' > "$dir/body.md"
  local err rc
  err=$("$TOOL" check --file "$dir/body.md" 2>&1 >/dev/null); rc=$?
  expect_code 1 "$rc" "check must refuse (exit 1) when unresolved placeholders remain"
  assert_contains "$err" "TICKET" "the refusal message must name the unresolved TICKET key"
  assert_contains "$err" "HEAD" "the refusal message must name the unresolved HEAD key"
  [ "$(printf '%s\n' "$err" | grep -c .)" -le 1 ] \
    || fail "the refusal must be one concise line, got: $err"
  pass "fm-pr-body.sh: check refuses a body with unresolved placeholders, naming the keys in one concise line"
}

test_check_passes_fully_resolved_body() {
  local dir; dir=$(mkhome "$TMP_ROOT/check-pass")
  printf 'Summary: filled\nTicket: T-1\n' > "$dir/body.md"
  local rc
  "$TOOL" check --file "$dir/body.md" >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "check must pass (exit 0) once every placeholder is filled"
  pass "fm-pr-body.sh: check exits 0 on a fully-resolved body"
}

test_check_reads_stdin_when_no_file_given() {
  local rc
  printf 'no placeholders here\n' | "$TOOL" check >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "check with no --file must read the body from stdin"
  pass "fm-pr-body.sh: check reads the body from stdin when --file is omitted"
}

test_render_refuses_unresolved_placeholders_and_writes_nothing() {
  local dir err rc
  dir=$(mkhome "$TMP_ROOT/render-refuse")
  printf 'Summary: {{SUMMARY}}\nTicket: {{TICKET}}\n' > "$dir/home/data/pr-templates/demo.md"
  err=$(FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" \
    --set SUMMARY=x --out "$dir/out.md" 2>&1 >/dev/null)
  rc=$?
  expect_code 1 "$rc" "render must refuse (exit 1) by itself when a placeholder is unresolved, with no separate check step"
  assert_contains "$err" "TICKET" "render's own refusal must name the unresolved TICKET key"
  assert_absent "$dir/out.md" "render must never publish --out on a refused (incomplete) body"
  pass "fm-pr-body.sh: render refuses unresolved placeholders itself and publishes nothing to --out"
}

test_render_strips_private_template_title_and_comments() {
  local dir out first_line
  dir=$(mkhome "$TMP_ROOT/strip-guidance")
  cat > "$dir/home/data/pr-templates/demo.md" <<'TPL'
# Demo PR-body template - internal authoring guidance only

<!--
Rendering contract:
- Remove this template title and all guidance comments from the rendered PR body.
- Preserve the section order.
-->

## Summary

<!--
Use 1-5 concise bullets.
Spans
multiple
lines.
-->

- {{OUTCOME}}

## Validation

- `{{CMD}}` — {{RESULT}}
TPL
  out=$(FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" \
    --set OUTCOME=fixed --set CMD="go test ./..." --set RESULT="ok" 2>/dev/null) \
    || fail "render exited non-zero stripping a private template's title and guidance comments"
  case "$out" in
    *"Demo PR-body template"*) fail "the H1 template-title line must be stripped from the rendered body" ;;
  esac
  case "$out" in
    *"Rendering contract"*|*"<!--"*|*"-->"*|*"Spans"*|*"multiple"*) fail "every guidance HTML comment, including multi-line ones, must be stripped" ;;
  esac
  assert_contains "$out" "## Summary" "the Summary section heading must survive stripping"
  assert_contains "$out" "## Validation" "the Validation section heading must survive stripping"
  [ "$(printf '%s\n' "$out" | grep -n '## Summary' | head -1 | cut -d: -f1)" -lt \
    "$(printf '%s\n' "$out" | grep -n '## Validation' | head -1 | cut -d: -f1)" ] \
    || fail "section order (Summary before Validation) must be preserved"
  first_line=$(printf '%s\n' "$out" | sed -n '1p')
  [ "$first_line" = "## Summary" ] \
    || fail "the first rendered line must be real content (## Summary), not a stripped title or comment remnant, got: $first_line"
  pass "fm-pr-body.sh: a private template's H1 title and every guidance HTML comment are stripped generically before fill"
}

test_render_refuses_local_home_path() {
  local dir rc err
  dir=$(mkhome "$TMP_ROOT/local-home-path")
  printf 'Summary: {{SUMMARY}}\n' > "$dir/home/data/pr-templates/demo.md"
  err=$(FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" \
    --set 'SUMMARY=see /home/captain/secret-project/report.md for the full log' \
    --out "$dir/out.md" 2>&1 >/dev/null)
  rc=$?
  expect_code 1 "$rc" "render must refuse (exit 1) a rendered body containing a local home-directory path"
  assert_absent "$dir/out.md" "a refused body must never be published to --out"
  case "$err" in
    *"/home/captain/secret-project"*) fail "the refusal must not echo the sensitive path back onto stderr, got: $err" ;;
  esac
  [ -n "$err" ] || fail "the refusal must name the problem concisely on stderr"
  pass "fm-pr-body.sh: render refuses a rendered body containing a local home-directory path, without echoing it"
}

test_render_refuses_local_temp_path() {
  local dir rc
  dir=$(mkhome "$TMP_ROOT/local-temp-path")
  printf 'Evidence: {{EVIDENCE}}\n' > "$dir/home/data/pr-templates/demo.md"
  FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" \
    --set 'EVIDENCE=captured at /tmp/scratch-run-42/output.log' \
    --out "$dir/out.md" >/dev/null 2>/dev/null
  rc=$?
  expect_code 1 "$rc" "render must refuse (exit 1) a rendered body containing a local temp-directory path"
  assert_absent "$dir/out.md" "a refused body must never be published to --out"
  pass "fm-pr-body.sh: render refuses a rendered body containing a local temp-directory path"
}

test_template_symlink_escape_is_refused_and_in_root_symlink_is_allowed() {
  local dir escape rc err out
  dir=$(mkhome "$TMP_ROOT/template-symlink-boundary")
  escape="$dir/escaped-template.md"
  printf 'Summary: escaped\n' > "$escape"
  ln -s "$escape" "$dir/home/data/pr-templates/demo.md"
  err=$(FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" \
    2>&1 >/dev/null); rc=$?
  expect_code 1 "$rc" "a private template symlink escaping its allowed root must be refused"
  case "$err" in
    *"$escape"*) fail "the symlink-boundary refusal must not echo the escaped path" ;;
  esac
  rm "$dir/home/data/pr-templates/demo.md"
  printf 'Summary: inside\n' > "$dir/home/data/pr-templates/in-root.md"
  ln -s "$dir/home/data/pr-templates/in-root.md" "$dir/home/data/pr-templates/demo.md"
  out=$(FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" 2>/dev/null) \
    || fail "an in-root private template symlink must remain valid"
  assert_contains "$out" "Summary: inside" "an in-root symlink target must render normally"
  pass "fm-pr-body.sh: template symlinks are bound to the allowed root before reading"
}

test_render_allows_repo_relative_paths_and_urls() {
  local dir out
  dir=$(mkhome "$TMP_ROOT/safe-paths")
  printf 'Summary: {{SUMMARY}}\n' > "$dir/home/data/pr-templates/demo.md"
  out=$(FM_HOME="$dir/home" "$TOOL" render --project demo --repo-dir "$dir/repo" \
    --set 'SUMMARY=see bin/fm-pr-body.sh, data/pr-templates/demo.md, and https://example.test/home/report for context' \
    2>/dev/null) \
    || fail "render must not refuse repo-relative paths and URLs that merely contain the word home"
  assert_contains "$out" "bin/fm-pr-body.sh" "a repo-relative path must survive unrefused"
  assert_contains "$out" "https://example.test/home/report" "a URL must survive unrefused even when a later path segment reads 'home'"
  pass "fm-pr-body.sh: render never refuses repo-relative paths or URLs, only local absolute home/temp path shapes"
}

test_check_refuses_local_path() {
  local dir err rc
  dir=$(mkhome "$TMP_ROOT/check-local-path")
  printf 'Summary: filled\nLog: /Users/captain/Downloads/trace.log\n' > "$dir/body.md"
  err=$("$TOOL" check --file "$dir/body.md" 2>&1 >/dev/null); rc=$?
  expect_code 1 "$rc" "check must refuse (exit 1) a body containing a local filesystem path"
  case "$err" in
    *"/Users/captain/Downloads"*) fail "check's refusal must not echo the sensitive path back onto stderr, got: $err" ;;
  esac
  pass "fm-pr-body.sh: check refuses a body containing a local filesystem path, without echoing it"
}

test_render_rejects_project_path_traversal() {
  local dir rc
  dir=$(mkhome "$TMP_ROOT/traversal")
  printf 'placeholder\n' > "$dir/home/data/pr-templates/demo.md"
  FM_HOME="$dir/home" "$TOOL" render --project "../escape" --repo-dir "$dir/repo" --set X=y >/dev/null 2>/dev/null
  rc=$?
  expect_code 2 "$rc" "a --project value containing '/' must be refused as a usage error"
  FM_HOME="$dir/home" "$TOOL" render --project ".." --repo-dir "$dir/repo" --set X=y >/dev/null 2>/dev/null
  rc=$?
  expect_code 2 "$rc" "a --project value of '..' must be refused as a usage error"
  pass "fm-pr-body.sh: --project is validated as one safe path segment and cannot traverse outside data/pr-templates"
}

test_script_parses
test_private_template_takes_precedence
test_repository_template_fallback
test_missing_template_steps_aside
test_unreadable_template_fails_inspection
test_known_template_under_searchable_nonlistable_root
test_enumeration_uses_validated_directory_descriptor
test_darwin_realpath_and_option_like_repo_path
test_missing_candidate_during_canonicalization_is_refused
test_post_resolution_symlink_swap_is_refused
test_post_identity_symlink_swap_reads_bound_descriptor
test_safe_named_fills_no_eval
test_literal_fill_is_not_reparsed_as_template
test_set_file_reads_value_from_file
test_rejects_lowercase_or_malformed_keys
test_rejects_set_argument_missing_equals
test_set_file_does_not_claim_trailing_newline_verbatim
test_render_is_deterministic
test_check_refuses_unresolved_placeholders
test_check_passes_fully_resolved_body
test_check_reads_stdin_when_no_file_given
test_render_refuses_unresolved_placeholders_and_writes_nothing
test_render_strips_private_template_title_and_comments
test_render_rejects_project_path_traversal
test_render_refuses_local_home_path
test_render_refuses_local_temp_path
test_template_symlink_escape_is_refused_and_in_root_symlink_is_allowed
test_render_allows_repo_relative_paths_and_urls
test_check_refuses_local_path
