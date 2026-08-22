#!/usr/bin/env bash
# Behavior tests for the capture-visual-evidence-mechanism slice: visual brief
# contract, publication-text safety (one owner in bin/fm-pr-body.sh), and the
# executable publish seam that gates every direct-PR PR-body, PR-comment, and
# review-reply publication path before the forge command runs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-pr-body.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-capture-visual-evidence)

mkhome() {
  local dir=$1
  mkdir -p "$dir/home/data/pr-templates" "$dir/repo/.github"
  printf '%s\n' "$dir"
}

test_visual_brief_requires_before_after_and_evidence_section() {
  local home id brief
  home="$TMP_ROOT/visual-brief-home"
  mkdir -p "$home/data"
  id="visual-ship-task"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$BRIEF" "$id" demo --mode direct-PR --visual >/dev/null 2>&1 \
    || fail "fm-brief.sh failed to scaffold a visual direct-PR brief"
  brief="$home/data/$id/brief.md"
  assert_grep "# Visual evidence" "$brief" \
    "visual ship brief must include a Visual evidence section"
  assert_grep "before and after" "$brief" \
    "visual ship brief must require before/after capture"
  assert_grep "PR Evidence" "$brief" \
    "visual ship brief must require a PR Evidence section naming what each artifact proves"
  assert_grep "pending upload" "$brief" \
    "visual ship brief must allow only pending upload plus description when upload is unavailable"
  assert_grep "never publish a local filesystem path" "$brief" \
    "visual ship brief must forbid publishing local paths as reviewer evidence"
  pass "fm-brief.sh: --visual adds the visual evidence contract to a ship brief"
}

test_visual_flag_refused_on_scout() {
  local home rc
  home="$TMP_ROOT/visual-scout-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$BRIEF" scout-visual demo --scout --visual >/dev/null 2>&1
  rc=$?
  expect_code 1 "$rc" "--visual must be refused on scout briefs"
  pass "fm-brief.sh: --visual applies only to ship briefs"
}

test_check_refuses_linux_home_path() {
  local err rc body="$TMP_ROOT/linux-home-body.txt"
  printf 'Evidence: /home/alice/screenshots/before.png\n' > "$body"
  err=$("$TOOL" check --file "$body" 2>&1 >/dev/null)
  rc=$?
  expect_code 1 "$rc" "check must refuse a Linux home path in publication text"
  assert_contains "$err" "local filesystem path" \
    "refusal must name the local-path policy without echoing the sensitive path"
  case "$err" in
    *"/home/alice"*) fail "the refusal must not echo the sensitive path back onto stderr, got: $err" ;;
  esac
  pass "fm-pr-body.sh: check refuses Linux home paths"
}

test_check_refuses_macos_home_path() {
  local err rc body="$TMP_ROOT/macos-home-body.txt"
  printf 'After: /Users/alice/Desktop/after.png\n' > "$body"
  err=$("$TOOL" check --file "$body" 2>&1 >/dev/null)
  rc=$?
  expect_code 1 "$rc" "check must refuse a macOS home path in publication text"
  assert_contains "$err" "local filesystem path" \
    "refusal must name the local-path policy without echoing the sensitive path"
  case "$err" in
    *"/Users/alice"*) fail "the refusal must not echo the sensitive path back onto stderr, got: $err" ;;
  esac
  pass "fm-pr-body.sh: check refuses macOS home paths"
}

test_check_refuses_windows_home_path() {
  local err rc body="$TMP_ROOT/windows-home-body.txt"
  printf 'Evidence: C:\\Users\\alice\\shots\\before.png\n' > "$body"
  err=$("$TOOL" check --file "$body" 2>&1 >/dev/null)
  rc=$?
  expect_code 1 "$rc" "check must refuse a Windows home path in publication text"
  assert_contains "$err" "local filesystem path" \
    "refusal must name the local-path policy without echoing the sensitive path"
  case "$err" in
    *"Users\\alice"*) fail "the refusal must not echo the sensitive path back onto stderr, got: $err" ;;
  esac
  pass "fm-pr-body.sh: check refuses Windows home paths"
}

test_check_refuses_platform_temp_paths() {
  local err rc body="$TMP_ROOT/temp-body.txt"
  printf '/tmp/fm-evidence/before.png\n' > "$body"
  err=$("$TOOL" check --file "$body" 2>&1 >/dev/null)
  rc=$?
  expect_code 1 "$rc" "check must refuse /tmp paths"
  assert_contains "$err" "local filesystem path" \
    "refusal must name the local-path policy without echoing the sensitive path"
  case "$err" in
    *"/tmp/"*) fail "the refusal must not echo the sensitive path back onto stderr, got: $err" ;;
  esac
  printf 'scratch under /private/var/folders/zz/zz/T/evidence.png\n' > "$body"
  err=$("$TOOL" check --file "$body" 2>&1 >/dev/null)
  rc=$?
  expect_code 1 "$rc" "check must refuse macOS platform temp paths"
  assert_contains "$err" "local filesystem path" \
    "refusal must name the local-path policy without echoing the sensitive path"
  case "$err" in
    *"/private/var/folders/"*) fail "the refusal must not echo the sensitive path back onto stderr, got: $err" ;;
  esac
  pass "fm-pr-body.sh: check refuses Linux and macOS temporary-directory paths"
}

test_check_accepts_uploaded_url_and_pending_upload_form() {
  local rc body="$TMP_ROOT/pending-upload-body.txt"
  cat > "$body" <<'EOF'
## PR Evidence
- Before: pending upload - dark-mode regression screenshot; crewmate uploads after merge
- After: https://example.test/uploads/after-fix.png — proves the hover state matches design
EOF
  "$TOOL" check --file "$body" >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "check must accept uploaded URLs and pending-upload markers"
  pass "fm-pr-body.sh: check accepts uploaded URLs and pending-upload descriptions"
}

test_check_accepts_repo_relative_paths_and_ordinary_prose() {
  local rc body="$TMP_ROOT/safe-body.txt"
  cat > "$body" <<'EOF'
Validated with `npm test -- docs/visual-regression.test.ts`.
The fix touches src/components/Button.tsx only; no local path is published here.
See https://github.com/example/repo/pull/1 for the uploaded screenshots.
EOF
  "$TOOL" check --file "$body" >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "check must not refuse repository-relative paths, commands, URLs, or prose"
  pass "fm-pr-body.sh: check avoids false positives for repo-relative paths, commands, URLs, and prose"
}

test_direct_pr_brief_routes_publication_through_publish_seam() {
  local home id brief
  home="$TMP_ROOT/publication-wire-home"
  mkdir -p "$home/data"
  id="wire-publication-check"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$BRIEF" "$id" demo --mode direct-PR >/dev/null 2>&1 \
    || fail "fm-brief.sh failed to scaffold a direct-PR brief"
  brief="$home/data/$id/brief.md"
  assert_grep "fm-pr-body.sh' publish --file" "$brief" \
    "direct-PR brief must route publication through the helper's executable publish seam"
  assert_grep 'gh-axi pr comment' "$brief" \
    "direct-PR brief must wire the publish seam into PR comment publication"
  assert_grep 'review reply' "$brief" \
    "direct-PR brief must wire the publish seam into review-reply publication"
  assert_grep 'never invoke' "$brief" \
    "direct-PR brief must forbid invoking forge publication commands directly, bypassing the seam"
  pass "fm-brief.sh: direct-PR brief routes body, comment, and review-reply publication through the publish seam"
}

test_templated_direct_pr_brief_chains_render_publish_and_create() {
  local home id brief
  home="$TMP_ROOT/templated-wire-home"
  mkdir -p "$home/data/pr-templates"
  printf '{{SUMMARY}}\n' > "$home/data/pr-templates/demo.md"
  id="wire-render-check"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$BRIEF" "$id" demo --mode direct-PR >/dev/null 2>&1 \
    || fail "fm-brief.sh failed to scaffold a templated direct-PR brief"
  brief="$home/data/$id/brief.md"
  assert_grep "publish --file" "$brief" \
    "templated direct-PR brief must publish through the seam, not a manual check chain"
  assert_grep "-- gh-axi pr create --body-file" "$brief" \
    "templated direct-PR brief must pass gh-axi pr create to the seam as the forge command"
  assert_grep "fm-pr-body.sh' render" "$brief" \
    "templated direct-PR brief must still require rendering through the helper"
  pass "fm-brief.sh: templated direct-PR brief chains render, publish seam, and create"
}

# forge_case <name>: a scratch dir with a fake forge command that records every
# invocation, so a test proves whether the real forge-command seam ran.
forge_case() {
  local name=$1 dir
  dir="$TMP_ROOT/publish-$name"
  mkdir -p "$dir"
  : > "$dir/forge.log"
  cat > "$dir/fake-forge" <<SH
#!/usr/bin/env bash
printf 'forged: %s\n' "\$*" >> "$dir/forge.log"
SH
  chmod +x "$dir/fake-forge"
  printf '%s\n' "$dir"
}

test_publish_refuses_unresolved_placeholder_before_forge() {
  local dir rc err
  dir=$(forge_case unresolved)
  printf 'Summary: {{SUMMARY}}\n' > "$dir/body.md"
  err=$("$TOOL" publish --file "$dir/body.md" -- "$dir/fake-forge" pr create --body-file "$dir/body.md" 2>&1 >/dev/null)
  rc=$?
  expect_code 1 "$rc" "publish must refuse an unresolved placeholder before invoking the forge command"
  assert_contains "$err" "unresolved" \
    "the refusal must name the unresolved placeholders"
  [ ! -s "$dir/forge.log" ] || fail "the forge command must never run when publish refuses an unresolved placeholder"
  pass "fm-pr-body.sh: publish refuses an unresolved-placeholder body before the forge command"
}

test_publish_refuses_local_paths_before_forge() {
  local dir rc err
  dir=$(forge_case local-paths)
  printf 'Evidence: /home/alice/shots/before.png\n' > "$dir/body.md"
  err=$("$TOOL" publish --file "$dir/body.md" -- "$dir/fake-forge" pr create --body-file "$dir/body.md" 2>&1 >/dev/null)
  rc=$?
  expect_code 1 "$rc" "publish must refuse a Linux home path before invoking the forge command"
  assert_contains "$err" "local filesystem path" \
    "the refusal must name the local-path policy"
  printf 'Reply capture: /tmp/fm-evidence/reply.png\n' > "$dir/body.md"
  err=$("$TOOL" publish --file "$dir/body.md" -- "$dir/fake-forge" pr comment 7 --body-file "$dir/body.md" 2>&1 >/dev/null)
  rc=$?
  expect_code 1 "$rc" "publish must refuse a temp path before invoking the forge command"
  assert_contains "$err" "local filesystem path" \
    "the refusal must name the local-path policy"
  [ ! -s "$dir/forge.log" ] || fail "the forge command must never run when publish refuses a local path"
  pass "fm-pr-body.sh: publish refuses local-path bodies and comments before the forge command"
}

test_publish_refuses_windows_home_path_before_forge() {
  local dir rc err
  dir=$(forge_case windows-home)
  printf 'Evidence: C:\\Users\\alice\\shots\\before.png\n' > "$dir/body.md"
  err=$("$TOOL" publish --file "$dir/body.md" -- "$dir/fake-forge" pr create --body-file "$dir/body.md" 2>&1 >/dev/null)
  rc=$?
  expect_code 1 "$rc" "publish must refuse a Windows home path before invoking the forge command"
  assert_contains "$err" "local filesystem path" \
    "the refusal must name the local-path policy"
  [ ! -s "$dir/forge.log" ] || fail "the forge command must never run when publish refuses a Windows home path"
  pass "fm-pr-body.sh: publish refuses a Windows home path before the forge command"
}

test_publish_invokes_forge_once_with_verbatim_args_on_safe_content() {
  local dir rc
  dir=$(forge_case safe)
  cat > "$dir/body.md" <<'EOF'
## PR Evidence
- Before: pending upload - hover-state regression screenshot; crewmate uploads after merge
- After: https://example.test/uploads/after.png - proves the hover state matches design
The fix touches src/components/Button.tsx only.
EOF
  "$TOOL" publish --file "$dir/body.md" -- "$dir/fake-forge" pr create --body-file "$dir/body.md" >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "publish must invoke the forge command on safe text (uploaded URL, pending upload, repo-relative path)"
  assert_grep "forged: pr create --body-file $dir/body.md" "$dir/forge.log" \
    "the forge command must be invoked exactly once with its arguments passed through verbatim"
  pass "fm-pr-body.sh: publish invokes the forge command once on safe text"
}

test_publish_propagates_forge_exit_code() {
  local dir rc
  dir="$TMP_ROOT/publish-exit-code"
  mkdir -p "$dir"
  cat > "$dir/failing-forge" <<'SH'
#!/usr/bin/env bash
exit 7
SH
  chmod +x "$dir/failing-forge"
  printf 'safe body\n' > "$dir/body.md"
  "$TOOL" publish --file "$dir/body.md" -- "$dir/failing-forge" >/dev/null 2>&1
  rc=$?
  expect_code 7 "$rc" "publish must propagate the forge command's own exit code"
  pass "fm-pr-body.sh: publish propagates the forge command's exit code"
}

test_publish_requires_a_forge_command() {
  local dir rc
  dir="$TMP_ROOT/publish-usage"
  mkdir -p "$dir"
  printf 'safe body\n' > "$dir/body.md"
  "$TOOL" publish --file "$dir/body.md" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "publish without a forge command must be a usage error"
  "$TOOL" publish --file "$dir/body.md" -- >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "publish with an empty forge command must be a usage error"
  pass "fm-pr-body.sh: publish refuses to guess a forge command"
}

test_render_gated_body_refuses_local_path_before_fake_open() {
  local dir rc
  dir=$(mkhome "$TMP_ROOT/body-local-path")
  cat > "$dir/fake-open" <<SH
#!/usr/bin/env bash
printf 'opened: %s\n' "\$*" >> "$dir/opener.log"
SH
  chmod +x "$dir/fake-open"
  : > "$dir/opener.log"
  cat > "$dir/home/data/pr-templates/demo.md" <<'TPL'
## PR Evidence
Before: {{BEFORE}}
After: {{AFTER}}
TPL
  FM_HOME="$dir/home" FM_DATA_OVERRIDE="$dir/home/data" bash -c \
    '"$1" render --project demo --repo-dir "$2" \
      --set BEFORE=/home/alice/before.png \
      --set AFTER=https://example.test/after.png \
      --out "$3/out.md" && "$1" publish --file "$3/out.md" -- "$3/fake-open" --body-file "$3/out.md"' \
    _ "$TOOL" "$dir/repo" "$dir" >/dev/null 2>&1
  rc=$?
  expect_code 1 "$rc" "render must refuse publication text containing a local home path"
  assert_absent "$dir/out.md" "a refused body must never reach --out"
  [ ! -s "$dir/opener.log" ] || fail "fake PR opener must not run when publication text is refused"
  pass "fm-pr-body.sh: render refuses local paths before the publish seam opens a gated PR body"
}

test_comment_publish_refuses_local_path_before_fake_comment() {
  local dir rc comment_body="$TMP_ROOT/comment-body.txt"
  dir="$TMP_ROOT/comment-local-path"
  mkdir -p "$dir"
  cat > "$dir/fake-comment" <<SH
#!/usr/bin/env bash
printf 'commented: %s\n' "\$*" >> "$dir/comment.log"
SH
  chmod +x "$dir/fake-comment"
  : > "$dir/comment.log"
  printf 'See /tmp/evidence/reply.png\n' > "$comment_body"
  "$TOOL" publish --file "$comment_body" -- "$dir/fake-comment" --body-file "$comment_body" >/dev/null 2>&1
  rc=$?
  expect_code 1 "$rc" "publish must refuse a PR comment containing a temp path"
  [ ! -s "$dir/comment.log" ] || fail "fake PR comment must not run when publish refuses a local path"
  pass "fm-pr-body.sh: the publish seam gates PR comment publication on safe text"
}

test_visual_brief_requires_before_after_and_evidence_section
test_visual_flag_refused_on_scout
test_check_refuses_linux_home_path
test_check_refuses_macos_home_path
test_check_refuses_windows_home_path
test_check_refuses_platform_temp_paths
test_check_accepts_uploaded_url_and_pending_upload_form
test_check_accepts_repo_relative_paths_and_ordinary_prose
test_direct_pr_brief_routes_publication_through_publish_seam
test_templated_direct_pr_brief_chains_render_publish_and_create
test_publish_refuses_unresolved_placeholder_before_forge
test_publish_refuses_local_paths_before_forge
test_publish_refuses_windows_home_path_before_forge
test_publish_invokes_forge_once_with_verbatim_args_on_safe_content
test_publish_propagates_forge_exit_code
test_publish_requires_a_forge_command
test_render_gated_body_refuses_local_path_before_fake_open
test_comment_publish_refuses_local_path_before_fake_comment
