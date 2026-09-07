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

wait_for_file() {
  local path=$1 i=0
  while [ "$i" -lt 500 ]; do
    [ -e "$path" ] && return 0
    sleep 0.01
    i=$((i + 1))
  done
  return 1
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
test_keyed_publication_attempts_once_and_preserves_wire_identity() {
  local root first_output second_output wire key expected_wire
  # Use one persistent fixture so the owner slot survives the second call.
  root="$TMP_ROOT/publication-happy-persistent"
  mkdir -p "$root/home" "$root/state" "$root/fakebin"
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  printf 'hello\n\n' > "$root/body.md"
  cat > "$root/fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = pr ]; then cp -- "$7" "$FAKE_LAST_BODY"; printf '%s\n' post >> "$FAKE_LOG"; printf 'commented: number/status: ok\n'; exit 0; fi
printf '%s\n' api >> "$FAKE_LOG"; printf '[2]: 1,77\n'
EOF
  chmod +x "$root/fakebin/gh-axi"
  first_output=$(FAKE_LOG="$root/log" FAKE_LAST_BODY="$root/last-body" PATH="$root/fakebin:$PATH" \
    FM_HOME="$root/home" FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task --file "$root/body.md" -- \
    gh-axi pr comment 7 -R o/r --body-file "$root/body.md") \
    || fail "keyed publication failed on first invocation: $first_output"
  [ "$first_output" = 'delivered 77' ] || fail "first invocation returned: $first_output"
  second_output=$(FAKE_LOG="$root/log" FAKE_LAST_BODY="$root/last-body" PATH="$root/fakebin:$PATH" \
    FM_HOME="$root/home" FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task --file "$root/body.md" -- \
    gh-axi pr comment 7 -R o/r --body-file "$root/body.md") \
    || fail "keyed publication failed on replay: $second_output"
  [ "$second_output" = 'delivered 77' ] || fail "replay returned: $second_output"
  [ "$(rg -c '^post$' "$root/log")" -eq 1 ] || fail "keyed publication posted more than once"
  [ "$(rg -c '^api$' "$root/log")" -eq 1 ] || fail "delivered replay unexpectedly read back"
  wire=$(find "$root/state" -name 'task.effect-*' -type f -print -quit)
  key=${wire##*-}
  assert_contains "$(cat "$root/body.md")" hello "source body was changed"
  assert_contains "$(cat "$root/last-body")" 'hello' "publisher lost the source body"
  assert_contains "$(cat "$root/last-body")" "<!-- fm-effect:$key -->" \
    "publisher did not receive the keyed wire marker"
  expected_wire=$(printf 'hello\n<!-- fm-effect:%s -->' "$key")
  [ "$(cat "$root/last-body")" = "$expected_wire" ] || fail "wire body did not normalize trailing newlines"
  assert_contains "$(cat "$wire")" "state=delivered receipt=77" "happy path did not deliver its slot"
  pass "fm-pr-body.sh: keyed publication attempts once and records a readback receipt"
}

test_keyed_publication_response_loss_is_confirmed_without_retry() {
  local root output rc
  root="$TMP_ROOT/publication-loss"
  mkdir -p "$root/home" "$root/state" "$root/fakebin"
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  printf 'lost' > "$root/body.md"
  cat > "$root/fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
if [ "$1" = pr ]; then
  if [ -e "$FAKE_OWNER_LOCK" ]; then printf '%s\n' lock-held > "$FAKE_VIOLATION"; fi
  printf '%s\n' post >> "$FAKE_LOG"; exit 1
fi
if [ -e "$FAKE_OWNER_LOCK" ]; then printf '%s\n' lock-held > "$FAKE_VIOLATION"; fi
printf '%s\n' api >> "$FAKE_LOG"; printf '[2]: 1,88\n'
EOF
  chmod +x "$root/fakebin/gh-axi"
  rc=0
  output=$(FAKE_LOG="$root/log" FAKE_OWNER_LOCK="$root/state/pipeline-events.log.lock" \
    FAKE_VIOLATION="$root/lock-violation" PATH="$root/fakebin:$PATH" FM_HOME="$root/home" \
    FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task --file "$root/body.md" -- \
    gh-axi pr comment 7 -R o/r --body-file "$root/body.md") || rc=$?
  expect_code 0 "$rc" "response loss with a matching readback should deliver"
  [ ! -e "$root/lock-violation" ] || fail "publisher ran while the owner lock was held"
  [ "$(rg -c '^post$' "$root/log")" -eq 1 ] || fail "response loss retried publication"
  [ "$(rg -c '^api$' "$root/log")" -eq 1 ] || fail "response loss did not read back once"
  assert_contains "$output" 'delivered 88' "response loss did not report its receipt"
  pass "fm-pr-body.sh: a failed publisher is confirmed by one bounded readback"
}

test_keyed_publication_snapshots_before_body_and_generation_changes() {
  local root output rc=0 real_cp real_shasum slot payload candidate
  root="$TMP_ROOT/publication-races"
  mkdir -p "$root/home" "$root/state" "$root/fakebin"
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  printf 'original' > "$root/body.md"
  printf 'original' > "$root/body.original"
  real_cp=$(command -v cp)
  cat > "$root/fakebin/cp" <<'EOF'
#!/usr/bin/env bash
"$FAKE_REAL_CP" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$FAKE_CP_MARKER" ] && [ "${2:-}" = "$FAKE_SOURCE" ]; then
  printf 'changed' > "$FAKE_SOURCE"
  : > "$FAKE_CP_MARKER"
fi
exit "$rc"
EOF
  cat > "$root/fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = pr ]; then
  cp -- "$7" "$FAKE_LAST_BODY"
  printf '%s\n' post >> "$FAKE_LOG"
  exit 0
fi
printf '%s\n' api >> "$FAKE_LOG"
printf '[2]: 1,77\n'
EOF
  chmod +x "$root/fakebin/cp" "$root/fakebin/gh-axi"
  output=$(FAKE_REAL_CP="$real_cp" FAKE_CP_MARKER="$root/cp-once" FAKE_LAST_BODY="$root/last-body" \
    FAKE_SOURCE="$root/body.md" FAKE_LOG="$root/log" PATH="$root/fakebin:$PATH" \
    FM_HOME="$root/home" FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task \
      --file "$root/body.md" -- gh-axi pr comment 7 -R o/r --body-file "$root/body.md") || rc=$?
  expect_code 0 "$rc" "a body mutation between snapshot and wire read must not change the wire body"
  assert_contains "$(cat "$root/last-body")" original "publisher did not receive the snapshot"
  [ "$(cat "$root/body.md")" = changed ] || fail "snapshot race fixture did not mutate the source body"
  slot=$(find "$root/state" -name 'task.effect-*' -type f -print -quit)
  payload=$(shasum -a 256 "$root/body.original" | awk '{print $1}')
  assert_contains "$(cat "$slot")" "payload=$payload" "effect slot did not retain the original snapshot payload"
  rm -f "$root/fakebin/cp"

  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  printf 'generation' > "$root/body.md"
  rm -f "$root/log" "$root/last-body"
  real_shasum=$(command -v shasum)
  cat > "$root/fakebin/shasum" <<'EOF'
#!/usr/bin/env bash
n=0
[ -f "$FAKE_HASH_COUNT" ] && n=$(cat "$FAKE_HASH_COUNT")
n=$((n + 1))
printf '%s\n' "$n" > "$FAKE_HASH_COUNT"
"$FAKE_REAL_SHASUM" "$@"
rc=$?
if [ "$n" -eq 1 ]; then
  printf 'kind=ship\nspawn_gen=gen-2\n' > "$FAKE_META"
fi
exit "$rc"
EOF
  cat > "$root/fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = pr ]; then printf '%s\n' post >> "$FAKE_LOG"; exit 0; fi
printf '%s\n' api >> "$FAKE_LOG"
printf '[2]: 1,78\n'
EOF
  chmod +x "$root/fakebin/shasum" "$root/fakebin/gh-axi"
  rc=0
  output=$(FAKE_META="$root/state/task.meta" FAKE_HASH_COUNT="$root/hash-count" FAKE_REAL_SHASUM="$real_shasum" \
    FAKE_LOG="$root/log" PATH="$root/fakebin:$PATH" FM_HOME="$root/home" FM_STATE_OVERRIDE="$root/state" \
    "$TOOL" publish --task task --file "$root/body.md" -- gh-axi pr comment 7 -R o/r \
      --body-file "$root/body.md" 2>&1) || rc=$?
  expect_code 1 "$rc" "a generation change before claim must refuse"
  assert_contains "$output" 'refused:foreign-gen' "generation race refusal was hidden"
  [ ! -e "$root/log" ] || fail "generation race reached publication"

  rm -f "$root/fakebin/shasum"
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  printf 'before-delivery' > "$root/body.md"
  rm -f "$root/log" "$root/last-body"
  cat > "$root/fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = pr ]; then
  printf 'kind=ship\nspawn_gen=gen-2\n' > "$FAKE_META"
  printf '%s\n' post >> "$FAKE_LOG"
  exit 0
fi
printf '%s\n' api >> "$FAKE_LOG"
printf '[2]: 1,79\n'
EOF
  chmod +x "$root/fakebin/gh-axi"
  rc=0
  output=$(FAKE_META="$root/state/task.meta" FAKE_LOG="$root/log" PATH="$root/fakebin:$PATH" \
    FM_HOME="$root/home" FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task \
      --file "$root/body.md" -- gh-axi pr comment 7 -R o/r --body-file "$root/body.md" 2>&1) || rc=$?
  expect_code 1 "$rc" "a generation change before delivery must refuse"
  assert_contains "$output" 'refused:foreign-gen' "before-delivery generation refusal was hidden"
  [ "$(rg -c '^post$' "$root/log")" -eq 1 ] || fail "before-delivery generation race retried publication"
  [ "$(rg -c '^api$' "$root/log")" -eq 1 ] || fail "before-delivery generation race skipped readback"
  slot=
  for candidate in "$root/state"/task.effect-*; do
    [ -f "$candidate" ] || continue
    if rg -q ' state=requested ' "$candidate"; then slot=$candidate; break; fi
  done
  [ -n "$slot" ] || fail "before-delivery generation race did not retain the claimed slot"
  assert_contains "$(cat "$slot")" 'receipt=-' "before-delivery refusal changed the slot receipt"
  pass "fm-pr-body.sh: publication snapshots bytes and fences both generation boundaries"
}

test_keyed_publication_full_seam_races_are_once_only() {
  local root pid1 pid2 pid3 rc1 rc2 rc3 slot key slot_bytes_file output1 output2 output3

  root="$TMP_ROOT/publication-full-seam"
  mkdir -p "$root/home" "$root/state" "$root/fakebin"
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  printf 'competing' > "$root/body.md"
  cat > "$root/fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = pr ]; then
  printf '%s\n' publisher-entry >> "$FAKE_LOG"
  if [ ! -e "$FAKE_PUBLISHER_START" ]; then
    : > "$FAKE_PUBLISHER_START"
    i=0
    while [ ! -e "$FAKE_LOSER_READY" ] && [ "$i" -lt 500 ]; do sleep 0.01; i=$((i + 1)); done
    [ -e "$FAKE_LOSER_READY" ] || exit 98
    printf '%s\n' post >> "$FAKE_LOG"
    : > "$FAKE_POST_DONE"
    exit 0
  fi
  exit 97
fi
printf '%s\n' api >> "$FAKE_LOG"
if [ ! -e "$FAKE_POST_DONE" ]; then
  : > "$FAKE_LOSER_READY"
  printf '[2]: 0,0\n'
else
  printf '[2]: 1,101\n'
fi
EOF
  chmod +x "$root/fakebin/gh-axi"
  (
    FAKE_PUBLISHER_START="$root/publisher-start" FAKE_LOSER_READY="$root/loser-ready" \
      FAKE_POST_DONE="$root/post-done" FAKE_LOG="$root/log" PATH="$root/fakebin:$PATH" \
      FM_HOME="$root/home" FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task \
      --file "$root/body.md" -- gh-axi pr comment 7 -R o/r --body-file "$root/body.md"
    rc=$?
    printf '%s\n' "$rc" > "$root/one.rc"
    exit "$rc"
  ) > "$root/one.out" 2>&1 &
  pid1=$!
  wait_for_file "$root/publisher-start" || { kill "$pid1" 2>/dev/null || true; wait "$pid1" 2>/dev/null || true; fail "winner did not reach the publisher"; }
  (
    FAKE_PUBLISHER_START="$root/publisher-start" FAKE_LOSER_READY="$root/loser-ready" \
      FAKE_POST_DONE="$root/post-done" FAKE_LOG="$root/log" PATH="$root/fakebin:$PATH" \
      FM_HOME="$root/home" FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task \
      --file "$root/body.md" -- gh-axi pr comment 7 -R o/r --body-file "$root/body.md"
    rc=$?
    printf '%s\n' "$rc" > "$root/two.rc"
    exit "$rc"
  ) > "$root/two.out" 2>&1 &
  pid2=$!
  wait "$pid1" || true
  wait "$pid2" || true
  rc1=$(cat "$root/one.rc")
  rc2=$(cat "$root/two.rc")
  output1=$(cat "$root/one.out")
  output2=$(cat "$root/two.out")
  expect_code 0 "$rc1" "the winning full-seam publication must deliver"
  expect_code 1 "$rc2" "the losing full-seam readback must remain unresolved before visibility"
  [ "$output1" = 'delivered 101' ] || fail "winning full-seam publication returned: $output1"
  assert_contains "$output2" 'publication unresolved' "early losing readback was not unresolved"
  slot=$(find "$root/state" -name 'task.effect-*' -type f -print -quit)
  key=${slot##*-}
  output3=$(FAKE_PUBLISHER_START="$root/publisher-start" FAKE_LOSER_READY="$root/loser-ready" \
    FAKE_POST_DONE="$root/post-done" FAKE_LOG="$root/log" PATH="$root/fakebin:$PATH" FM_HOME="$root/home" \
    FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task --expect-key "$key" \
    --file "$root/body.md" -- gh-axi pr comment 7 -R o/r --body-file "$root/body.md") \
    || fail "the later same-key readback refused"
  [ "$output3" = 'delivered 101' ] || fail "later same-key readback returned: $output3"
  [ "$(rg -c '^publisher-entry$' "$root/log")" -eq 1 ] || fail "an injected double claim reached the publisher more than once"
  [ "$(rg -c '^post$' "$root/log")" -eq 1 ] || fail "competing publications posted more than once"
  [ "$(rg -c '^api$' "$root/log")" -eq 3 ] || fail "full-seam race/readback used the wrong confirmation count"
  pass "fm-pr-body.sh: loser-before-visibility and later same-key readback publish once"

  root="$TMP_ROOT/publication-repair-race"
  mkdir -p "$root/home" "$root/state" "$root/fakebin" "$root/api-markers"
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  printf 'repair-race' > "$root/body.md"
  cat > "$root/fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = pr ]; then
  printf '%s\n' publisher-entry >> "$FAKE_LOG"
  : > "$FAKE_PUBLISHER_START"
  i=0
  while [ ! -e "$FAKE_REPAIRS_COMPLETE" ] && [ "$i" -lt 500 ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$FAKE_REPAIRS_COMPLETE" ] || exit 98
  exit 1
fi
printf '%s\n' api >> "$FAKE_LOG"
if [ ! -e "$FAKE_REPAIRS_COMPLETE" ]; then
  : > "$FAKE_API_MARKERS/$BASHPID"
  i=0
  while [ "$(find "$FAKE_API_MARKERS" -type f | wc -l | tr -d ' ')" -lt 2 ] && [ "$i" -lt 500 ]; do sleep 0.01; i=$((i + 1)); done
  [ "$(find "$FAKE_API_MARKERS" -type f | wc -l | tr -d ' ')" -ge 2 ] || exit 98
  : > "$FAKE_REPAIRS_READY"
  printf '[2]: 1,102\n'
else
  printf '[2]: 0,0\n'
fi
EOF
  chmod +x "$root/fakebin/gh-axi"
  (
    FAKE_PUBLISHER_START="$root/publisher-start" FAKE_REPAIRS_READY="$root/repairs-ready" \
      FAKE_REPAIRS_COMPLETE="$root/repairs-complete" FAKE_API_MARKERS="$root/api-markers" \
      FAKE_LOG="$root/log" PATH="$root/fakebin:$PATH" FM_HOME="$root/home" \
      FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task --file "$root/body.md" -- \
      gh-axi pr comment 7 -R o/r --body-file "$root/body.md"
    rc=$?
    printf '%s\n' "$rc" > "$root/one.rc"
    exit "$rc"
  ) > "$root/one.out" 2>&1 &
  pid1=$!
  wait_for_file "$root/publisher-start" || { kill "$pid1" 2>/dev/null || true; wait "$pid1" 2>/dev/null || true; fail "late publisher did not enter"; }
  slot=$(find "$root/state" -name 'task.effect-*' -type f -print -quit)
  [ -n "$slot" ] || fail "late publisher did not create an effect slot"
  key=${slot##*-}
  (
    FAKE_PUBLISHER_START="$root/publisher-start" FAKE_REPAIRS_READY="$root/repairs-ready" \
      FAKE_REPAIRS_COMPLETE="$root/repairs-complete" FAKE_API_MARKERS="$root/api-markers" \
      FAKE_LOG="$root/log" PATH="$root/fakebin:$PATH" FM_HOME="$root/home" \
      FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task --expect-key "$key" \
      --file "$root/body.md" -- gh-axi pr comment 7 -R o/r --body-file "$root/body.md"
    rc=$?
    printf '%s\n' "$rc" > "$root/two.rc"
    exit "$rc"
  ) > "$root/two.out" 2>&1 &
  pid2=$!
  (
    FAKE_PUBLISHER_START="$root/publisher-start" FAKE_REPAIRS_READY="$root/repairs-ready" \
      FAKE_REPAIRS_COMPLETE="$root/repairs-complete" FAKE_API_MARKERS="$root/api-markers" \
      FAKE_LOG="$root/log" PATH="$root/fakebin:$PATH" FM_HOME="$root/home" \
      FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task --expect-key "$key" \
      --file "$root/body.md" -- gh-axi pr comment 7 -R o/r --body-file "$root/body.md"
    rc=$?
    printf '%s\n' "$rc" > "$root/three.rc"
    exit "$rc"
  ) > "$root/three.out" 2>&1 &
  pid3=$!
  wait "$pid2" || true
  wait "$pid3" || true
  rc2=$(cat "$root/two.rc")
  rc3=$(cat "$root/three.rc")
  output2=$(cat "$root/two.out")
  output3=$(cat "$root/three.out")
  expect_code 0 "$rc2" "the first concurrent repair must deliver"
  expect_code 0 "$rc3" "the second concurrent repair must deliver"
  [ "$output2" = 'delivered 102' ] || fail "first repair returned: $output2"
  [ "$output3" = 'delivered 102' ] || fail "second repair returned: $output3"
  slot_bytes_file="$root/delivered.slot"
  cp -- "$slot" "$slot_bytes_file"
  : > "$root/repairs-complete"
  wait "$pid1" || true
  rc1=$(cat "$root/one.rc")
  output1=$(cat "$root/one.out")
  expect_code 1 "$rc1" "the late ambiguous publication must remain unresolved"
  assert_contains "$output1" 'publication unresolved' "late ambiguous publication was not unresolved"
  cmp -s "$slot" "$slot_bytes_file" || fail "late ambiguous changed delivered slot bytes"
  [ "$(rg -c '^publisher-entry$' "$root/log")" -eq 1 ] || fail "late publication entry count changed"
  [ "$(rg -c '^api$' "$root/log")" -eq 3 ] || fail "repair confirmation/readback count was wrong"
  pass "fm-pr-body.sh: concurrent repair confirmations survive a late ambiguous attempt"
}

test_keyed_publication_repair_reads_without_publishing() {
  local root output rc wire key saved_slot
  root="$TMP_ROOT/publication-repair"
  mkdir -p "$root/home" "$root/state" "$root/fakebin"
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  printf 'repair' > "$root/body.md"
  cat > "$root/fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
if [ "$1" = pr ]; then printf '%s\n' post >> "$FAKE_LOG"; exit 99; fi
printf '%s\n' api >> "$FAKE_LOG"; printf '%s\n' "${FAKE_API_OUTPUT:-[2]: 0,0}"
EOF
  chmod +x "$root/fakebin/gh-axi"
  rc=0
  output=$(FAKE_LOG="$root/log" PATH="$root/fakebin:$PATH" FM_HOME="$root/home" \
    FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task --file "$root/body.md" -- \
    gh-axi pr comment 7 -R o/r --body-file "$root/body.md") || rc=$?
  expect_code 1 "$rc" "a missing readback must leave an unresolved publication"
  wire=$(find "$root/state" -name 'task.effect-*' -type f -print -quit)
  key=${wire##*-}
  printf 'changed' > "$root/changed.md"
  rc=0
  output=$(FAKE_LOG="$root/log" PATH="$root/fakebin:$PATH" FM_HOME="$root/home" \
    FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task --expect-key "$key" \
      --file "$root/changed.md" -- gh-axi pr comment 7 -R o/r --body-file "$root/changed.md" 2>&1) || rc=$?
  expect_code 1 "$rc" "repair with a changed body must refuse"
  assert_contains "$output" 'refused:repair-key-mismatch' "changed-body repair refusal was not named"
  printf 'kind=ship\nspawn_gen=gen-2\n' > "$root/state/task.meta"
  rc=0
  output=$(FAKE_LOG="$root/log" PATH="$root/fakebin:$PATH" FM_HOME="$root/home" \
    FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task --expect-key "$key" \
      --file "$root/body.md" -- gh-axi pr comment 7 -R o/r --body-file "$root/body.md" 2>&1) || rc=$?
  expect_code 1 "$rc" "repair with a changed generation must refuse"
  assert_contains "$output" 'refused:repair-key-mismatch' "changed-generation repair refusal was not named"
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  saved_slot=$(cat "$wire")
  rm -f "$wire"
  rc=0
  output=$(FAKE_LOG="$root/log" PATH="$root/fakebin:$PATH" FM_HOME="$root/home" \
    FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task --expect-key "$key" \
      --file "$root/body.md" -- gh-axi pr comment 7 -R o/r --body-file "$root/body.md" 2>&1) || rc=$?
  expect_code 1 "$rc" "repair with a missing slot must refuse"
  assert_contains "$output" 'refused:repair-slot-missing' "missing-slot repair refusal was not named"
  printf '%s\n' "$saved_slot" > "$wire"
  chmod 600 "$wire"
  rc=0
  output=$(FAKE_LOG="$root/log" FAKE_API_OUTPUT='[2]: 1,91' PATH="$root/fakebin:$PATH" \
    FM_HOME="$root/home" FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task \
      --expect-key "$key" --file "$root/body.md" -- gh-axi pr comment 7 -R o/r \
      --body-file "$root/body.md") || rc=$?
  expect_code 0 "$rc" "repair mode should deliver a matching existing comment"
  assert_contains "$output" 'delivered 91' "repair mode did not report its receipt"
  [ "$(rg -c '^post$' "$root/log")" -eq 1 ] || fail "repair mode published a second comment"
  pass "fm-pr-body.sh: --expect-key rejects changed or missing slots and reads only"
}

test_unkeyed_publication_remains_unchanged_baseline() {
  local root output
  root="$TMP_ROOT/publication-unkeyed-baseline"
  mkdir -p "$root/home" "$root/state" "$root/fakebin"
  printf 'plain body' > "$root/body.md"
  cat > "$root/fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
EOF
  chmod +x "$root/fakebin/gh-axi"
  output=$(FAKE_LOG="$root/log" PATH="$root/fakebin:$PATH" FM_HOME="$root/home" \
    FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --file "$root/body.md" -- \
    gh-axi pr comment 7 -R o/r --body-file "$root/body.md") \
    || fail "unkeyed baseline publication failed: $output"
  output=$(FAKE_LOG="$root/log" PATH="$root/fakebin:$PATH" FM_HOME="$root/home" \
    FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --file "$root/body.md" -- \
    gh-axi pr comment 7 -R o/r --body-file "$root/body.md") \
    || fail "unkeyed baseline replay failed: $output"
  [ "$(wc -l < "$root/log" | tr -d ' ')" -eq 2 ] || fail "unkeyed publication did not run twice"
  [ "$(cat "$root/body.md")" = 'plain body' ] || fail "unkeyed publication changed the source body"
  [ ! -e "$root/state/task.effect" ] || fail "unkeyed publication created an effect slot"
  pass "fm-pr-body.sh: unkeyed publication remains a two-post baseline"
}

test_keyed_publication_rejects_empty_selectors() {
  local root output rc label
  root="$TMP_ROOT/publication-empty-selectors"
  mkdir -p "$root/home" "$root/state" "$root/fakebin"
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  printf 'empty' > "$root/body.md"
  cat > "$root/fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' called >> "$FAKE_LOG"
EOF
  chmod +x "$root/fakebin/gh-axi"
  run_usage() {
    label=$1
    shift
    rc=0
    output=$(FAKE_LOG="$root/log" PATH="$root/fakebin:$PATH" FM_HOME="$root/home" \
      FM_STATE_OVERRIDE="$root/state" "$TOOL" publish "$@" --file "$root/body.md" -- \
      gh-axi pr comment 7 -R o/r --body-file "$root/body.md" 2>&1) || rc=$?
    expect_code 2 "$rc" "$label"
    [ ! -e "$root/log" ] || fail "$label reached the forge: $(cat "$root/log")"
  }
  run_usage 'empty --task= must refuse' --task=
  run_usage 'empty --task value must refuse' --task ''
  run_usage 'empty --expect-key= without task must refuse' --expect-key=
  run_usage 'empty --expect-key value without task must refuse' --expect-key ''
  run_usage 'empty --expect-key= with task must refuse' --task task --expect-key=
  run_usage 'empty --expect-key value with task must refuse' --task task --expect-key ''
  pass "fm-pr-body.sh: keyed selectors reject present-but-empty values"
}

test_keyed_publication_forwards_lock_refusal() {
  local root output rc=0 holder
  root="$TMP_ROOT/publication-lock-refusal"
  mkdir -p "$root/home" "$root/state" "$root/fakebin"
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  printf 'locked' > "$root/body.md"
  : > "$root/forge-calls"
  cat > "$root/fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
exit 99
EOF
  chmod +x "$root/fakebin/gh-axi"
  (while [ -d "$root" ] && [ ! -e "$root/release-holder" ]; do sleep 0.05; done) &
  holder=$!
  kill -0 "$holder" 2>/dev/null || fail "lock holder exited before the refusal probe"
  mkdir "$root/state/pipeline-events.log.lock"
  printf '%s\n' "$holder" > "$root/state/pipeline-events.log.lock/pid"
  output=$(FAKE_LOG="$root/forge-calls" FM_PIPELINE_LOCK_TIMEOUT=1 PATH="$root/fakebin:$PATH" \
    FM_HOME="$root/home" FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task \
    --file "$root/body.md" -- gh-axi pr comment 7 -R o/r --body-file "$root/body.md" 2>&1) || rc=$?
  kill -0 "$holder" 2>/dev/null || fail "lock holder expired during the refusal probe"
  : > "$root/release-holder"
  wait "$holder" 2>/dev/null || true
  expect_code 3 "$rc" "a live owner lock refusal must preserve its retryable exit"
  assert_contains "$output" 'refused:lock-held' "owner lock refusal was not forwarded"
  assert_not_contains "$output" 'refused:effect-claim-failed' "owner lock refusal became a generic claim failure"
  [ ! -s "$root/forge-calls" ] || fail "lock refusal reached the local forge fake"
  for slot in "$root/state/task.effect-"*; do
    [ -e "$slot" ] || [ -L "$slot" ] || continue
    fail "lock refusal created an effect slot: $slot"
  done
  pass "fm-pr-body.sh: keyed publication forwards retryable owner lock refusals"
}

test_keyed_publication_repair_forwards_lock_refusal() {
  local root output rc=0 holder payload key slot
  root="$TMP_ROOT/publication-repair-lock-refusal"
  mkdir -p "$root/home" "$root/state" "$root/fakebin"
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  printf 'repair-lock' > "$root/body.md"
  payload=$(shasum -a 256 "$root/body.md" | awk '{print $1}')
  output=$(FM_HOME="$root/home" FM_STATE_OVERRIDE="$root/state" "$ROOT/bin/fm-pipeline.sh" effect claim task \
    --gen gen-1 --target github.com/o/r#7 --payload "$payload") || fail "repair lock fixture claim refused"
  key=${output#claimed }
  slot="$root/state/task.effect-$key"
  [ -f "$slot" ] || fail "repair lock fixture did not create its effect slot"
  : > "$root/forge-calls"
  cat > "$root/fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
exit 99
EOF
  chmod +x "$root/fakebin/gh-axi"
  (while [ -d "$root" ] && [ ! -e "$root/release-holder" ]; do sleep 0.05; done) &
  holder=$!
  kill -0 "$holder" 2>/dev/null || fail "repair lock holder exited before the refusal probe"
  mkdir "$root/state/pipeline-events.log.lock"
  printf '%s\n' "$holder" > "$root/state/pipeline-events.log.lock/pid"
  output=$(FAKE_LOG="$root/forge-calls" FM_PIPELINE_LOCK_TIMEOUT=1 PATH="$root/fakebin:$PATH" \
    FM_HOME="$root/home" FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task \
    --expect-key "$key" --file "$root/body.md" -- gh-axi pr comment 7 -R o/r \
    --body-file "$root/body.md" 2>&1) || rc=$?
  kill -0 "$holder" 2>/dev/null || fail "repair lock holder expired during the refusal probe"
  : > "$root/release-holder"
  wait "$holder" 2>/dev/null || true
  expect_code 3 "$rc" "a repair owner lock refusal must preserve its retryable exit"
  assert_contains "$output" 'refused:lock-held' "repair owner lock refusal was not forwarded"
  [ ! -s "$root/forge-calls" ] || fail "repair lock refusal reached the local forge fake"
  [ -f "$slot" ] || fail "repair lock refusal removed the effect slot"
  pass "fm-pr-body.sh: repair publication forwards retryable owner lock refusals"
}

test_keyed_publication_deliver_forwards_lock_refusal() {
  local root output rc=0 payload key slot holder pr_calls
  root="$TMP_ROOT/publication-deliver-lock-refusal"
  mkdir -p "$root/home" "$root/state" "$root/fakebin"
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  printf 'deliver-lock' > "$root/body.md"
  payload=$(shasum -a 256 "$root/body.md" | awk '{print $1}')
  output=$(FM_HOME="$root/home" FM_STATE_OVERRIDE="$root/state" "$ROOT/bin/fm-pipeline.sh" effect claim task \
    --gen gen-1 --target github.com/o/r#7 --payload "$payload") || fail "deliver lock fixture claim refused"
  key=${output#claimed }
  slot="$root/state/task.effect-$key"
  [ -f "$slot" ] || fail "deliver lock fixture did not create its effect slot"
  (while [ -d "$root" ] && [ ! -e "$root/deliver-trigger" ]; do sleep 0.05; done
    if [ -e "$root/deliver-trigger" ]; then
      mkdir "$root/state/pipeline-events.log.lock"
      while [ ! -e "$root/holder-pid-written" ]; do sleep 0.05; done
      cat "$root/holder-pid" > "$root/state/pipeline-events.log.lock/pid"
      : > "$root/deliver-holder-ready"
      while [ -d "$root" ] && [ ! -e "$root/release-holder" ]; do sleep 0.05; done
    fi
  ) >/dev/null 2>&1 &
  holder=$!
  printf '%s\n' "$holder" > "$root/holder-pid"
  : > "$root/holder-pid-written"
  kill -0 "$holder" 2>/dev/null || fail "deliver lock holder exited before the readback"
  cat > "$root/fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
if [ "$1" = api ]; then
  : > "$FAKE_TRIGGER"
  i=0
  while [ ! -e "$FAKE_HOLDER_READY" ] && [ "$i" -lt 500 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -e "$FAKE_HOLDER_READY" ] || exit 98
  printf '[2]: 1,77\n'
  exit 0
fi
printf 'unexpected forge publish\n' >&2
exit 99
EOF
  chmod +x "$root/fakebin/gh-axi"
  : > "$root/forge-calls"
  output=$(FAKE_LOG="$root/forge-calls" FAKE_TRIGGER="$root/deliver-trigger" \
    FAKE_HOLDER_READY="$root/deliver-holder-ready" PATH="$root/fakebin:$PATH" FM_HOME="$root/home" \
    FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task --expect-key "$key" \
    --file "$root/body.md" -- gh-axi pr comment 7 -R o/r --body-file "$root/body.md" 2>&1) || rc=$?
  wait_for_file "$root/deliver-holder-ready" || fail "deliver lock fake did not hold the owner lock"
  kill -0 "$holder" 2>/dev/null || fail "deliver lock holder exited before the refusal assertion"
  : > "$root/release-holder"
  wait "$holder" 2>/dev/null || true
  expect_code 3 "$rc" "a deliver owner lock refusal must preserve its retryable exit"
  assert_contains "$output" 'refused:lock-held' "deliver owner lock refusal was not forwarded"
  [ "$(rg -c '^api ' "$root/forge-calls")" -eq 1 ] || fail "deliver lock fixture did not read back once"
  pr_calls=$(rg -c '^pr ' "$root/forge-calls" 2>/dev/null || true)
  [ "${pr_calls:-0}" -eq 0 ] || fail "deliver lock fixture reached the forge publisher"
  assert_contains "$(cat "$slot")" 'state=requested' "deliver lock refusal changed the effect slot"
  pass "fm-pr-body.sh: deliver publication forwards retryable owner lock refusals"
}

test_keyed_publication_reports_owner_refusal() {
  local root output rc=0 payload key slot
  root="$TMP_ROOT/publication-owner-refusal"
  mkdir -p "$root/home" "$root/state" "$root/fakebin"
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  printf 'corrupt' > "$root/body.md"
  payload=$(shasum -a 256 "$root/body.md" | awk '{print $1}')
  key=$(FM_HOME="$root/home" FM_STATE_OVERRIDE="$root/state" "$ROOT/bin/fm-pipeline.sh" effect claim task \
    --gen gen-1 --target github.com/o/r#7 --payload "$payload") \
    || fail "owner refusal fixture claim refused"
  key=${key#claimed }
  slot="$root/state/task.effect-$key"
  sed 's/state=requested receipt=-/state=delivered receipt=-/' "$slot" > "$slot.tmp"
  chmod 600 "$slot.tmp"
  mv "$slot.tmp" "$slot"
  cat > "$root/fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' called >> "$FAKE_LOG"
EOF
  chmod +x "$root/fakebin/gh-axi"
  output=$(FAKE_LOG="$root/log" PATH="$root/fakebin:$PATH" FM_HOME="$root/home" \
    FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task --file "$root/body.md" -- \
    gh-axi pr comment 7 -R o/r --body-file "$root/body.md" 2>&1) || rc=$?
  expect_code 1 "$rc" "a corrupt owner slot must refuse the keyed publication"
  assert_contains "$output" 'refused:corrupt-slot' "owner refusal was swallowed by the publication seam"
  [ ! -e "$root/log" ] || fail "owner refusal reached the forge"
  pass "fm-pr-body.sh: keyed owner refusals remain named at the publication boundary"
}

test_real_gh_axi_toon_readback_boundary() {
  local root output rc
  root="$TMP_ROOT/publication-real-axi"
  mkdir -p "$root/home" "$root/state" "$root/fakebin"
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  printf '%02500d' 0 | tr '0' x > "$root/body.md"
  cat > "$root/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
if [ "${1:-}" = pr ] && [ "${2:-}" = comment ]; then
  body=
  previous=
  for arg in "$@"; do
    if [ "$previous" = --body ]; then body=$arg; break; fi
    previous=$arg
  done
  jq -n --arg body "$body" '[{id:303, body:$body}, {id:404, body:$body}]' > "$FAKE_COMMENTS"
  exit 0
fi
if [ "${1:-}" = api ]; then
  jq_program=
  previous=
  for arg in "$@"; do
    if [ "$previous" = --jq ]; then jq_program=$arg; break; fi
    previous=$arg
  done
  jq "$jq_program" "$FAKE_COMMENTS"
  exit 0
fi
exit 2
EOF
  chmod +x "$root/fakebin/gh"
  rc=0
  output=$(FAKE_GH_LOG="$root/gh-log" FAKE_COMMENTS="$root/comments.json" \
    PATH="$root/fakebin:$PATH" FM_HOME="$root/home" FM_STATE_OVERRIDE="$root/state" \
    "$TOOL" publish --task task --file "$root/body.md" -- \
      gh-axi pr comment 7 -R o/r --body-file "$root/body.md") || rc=$?
  expect_code 0 "$rc" "real gh-axi boundary should parse its TOON readback"
  assert_contains "$output" 'delivered 303' "real gh-axi boundary lost the comment receipt"
  assert_contains "$(cat "$root/gh-log")" 'api /repos/o/r/issues/7/comments' \
    "real gh-axi boundary did not query the comments endpoint"
  FAKE_GH_LOG="$root/gh-log-direct" FAKE_COMMENTS="$root/comments.json" \
    PATH="$root/fakebin:$PATH" gh-axi api /repos/o/r/issues/7/comments --jq '[length, .[0].id]' > "$root/toon.out" \
    || fail "real gh-axi direct TOON control failed"
  [ "$(tail -c 1 "$root/toon.out" | od -An -tx1 | tr -d '[:space:]')" = 0a ] \
    || fail "real gh-axi TOON control did not return a trailing newline"
  assert_contains "$(cat "$root/toon.out")" '[2]:' \
    "real gh-axi TOON control did not return its frozen array shape"
  [ "$(wc -c < "$root/body.md" | tr -d ' ')" -eq 2500 ] \
    || fail "real boundary fixture was not exactly 2,500 bytes"
  pass "fm-pr-body.sh: real gh-axi TOON output parses a 2,500-byte first matching result"
}

test_keyed_publication_malformed_short_and_bounded_readback() {
  local mode root output rc api_count expected
  for mode in malformed short bounded; do
    root="$TMP_ROOT/publication-readback-$mode"
    mkdir -p "$root/home" "$root/state" "$root/fakebin"
    printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
    printf 'readback' > "$root/body.md"
    case "$mode" in
      malformed) expected=not-toon ;;
      short) expected='[2]: 1,0' ;;
      bounded) expected='[2]: 100,0' ;;
    esac
    cat > "$root/fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = pr ]; then printf '%s\n' post >> "$FAKE_LOG"; exit 0; fi
printf '%s\n' api >> "$FAKE_LOG"
printf '%s\n' "$FAKE_API_OUTPUT"
EOF
    chmod +x "$root/fakebin/gh-axi"
    rc=0
    output=$(FAKE_LOG="$root/log" FAKE_API_OUTPUT="$expected" PATH="$root/fakebin:$PATH" \
      FM_HOME="$root/home" FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task --file "$root/body.md" -- \
      gh-axi pr comment 7 -R o/r --body-file "$root/body.md" 2>&1) || rc=$?
    expect_code 1 "$rc" "$mode readback must remain unresolved"
    assert_contains "$output" 'publication unresolved' "$mode readback refusal was not named"
    [ "$(rg -c '^post$' "$root/log")" -eq 1 ] || fail "$mode readback retried publication"
    api_count=$(rg -c '^api$' "$root/log")
    case "$mode" in
      bounded) [ "$api_count" -eq 10 ] || fail "bounded readback used $api_count pages" ;;
      *) [ "$api_count" -eq 1 ] || fail "$mode readback used $api_count pages" ;;
    esac
  done
  pass "fm-pr-body.sh: malformed, short, and ten-page readback walks stay unresolved"
}

test_keyed_publication_rejects_unsupported_shape() {
  local root output rc
  root="$TMP_ROOT/publication-shape"
  mkdir -p "$root/home" "$root/state" "$root/fakebin"
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  printf 'shape' > "$root/body.md"
  cat > "$root/fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' called >> "$FAKE_LOG"
EOF
  chmod +x "$root/fakebin/gh-axi"
  rc=0
  output=$(FAKE_LOG="$root/log" PATH="$root/fakebin:$PATH" FM_HOME="$root/home" \
    FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task --file "$root/body.md" -- \
    gh-axi pr comment 7 -R o/r --body 'inline' 2>&1) || rc=$?
  expect_code 2 "$rc" "an inline keyed publication must be refused"
  assert_contains "$output" 'unsupported argv shape' "keyed shape refusal was not named"
  [ ! -e "$root/log" ] || fail "unsupported keyed publication reached the forge"
  printf 'different' > "$root/other.md"
  for label in url-operand edit-subcommand different-body-file; do
    rm -f "$root/log"
    case "$label" in
      url-operand)
        set -- gh-axi pr comment https://github.com/o/r/pull/7 -R o/r --body-file "$root/body.md"
        ;;
      edit-subcommand)
        set -- gh-axi pr edit 7 -R o/r --body-file "$root/body.md"
        ;;
      different-body-file)
        set -- gh-axi pr comment 7 -R o/r --body-file "$root/other.md"
        ;;
    esac
    rc=0
    output=$(FAKE_LOG="$root/log" PATH="$root/fakebin:$PATH" FM_HOME="$root/home" \
      FM_STATE_OVERRIDE="$root/state" "$TOOL" publish --task task --file "$root/body.md" -- "$@" 2>&1) || rc=$?
    expect_code 2 "$rc" "$label keyed publication must be refused"
    assert_contains "$output" 'unsupported argv shape' "$label refusal was not named"
    [ ! -e "$root/log" ] || fail "$label keyed publication reached the forge"
  done
  pass "fm-pr-body.sh: keyed publication refuses all unsupported forge shapes"
}

test_render_allows_repo_relative_paths_and_urls
 test_keyed_publication_attempts_once_and_preserves_wire_identity
 test_keyed_publication_response_loss_is_confirmed_without_retry
 test_keyed_publication_snapshots_before_body_and_generation_changes
 test_keyed_publication_full_seam_races_are_once_only
 test_keyed_publication_repair_reads_without_publishing
 test_unkeyed_publication_remains_unchanged_baseline
 test_keyed_publication_rejects_empty_selectors
 test_keyed_publication_forwards_lock_refusal
 test_keyed_publication_repair_forwards_lock_refusal
 test_keyed_publication_deliver_forwards_lock_refusal
 test_keyed_publication_reports_owner_refusal
 test_real_gh_axi_toon_readback_boundary
 test_keyed_publication_malformed_short_and_bounded_readback
 test_keyed_publication_rejects_unsupported_shape
test_check_refuses_local_path
