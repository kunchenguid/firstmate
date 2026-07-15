#!/usr/bin/env bash
# Tests for bin/fm-pr-screenshots.sh: the helper that uploads UI screenshots as
# GitHub release assets and prints PR-embeddable markdown, plus the `embed` mode
# that appends that markdown to an existing PR body for the no-mistakes path.
#
# Matrix:
#   (a) --dry-run makes zero network calls and prints deterministic URLs
#   (b) upload creates the release when missing, then uploads with --clobber and
#       namespaced asset filenames, and prints matching markdown
#   (c) upload reuses an existing release (no create call)
#   (d) --repo is derived from the cwd git origin remote when omitted
#   (e) --namespace is derived from the current git branch when omitted
#   (f) --no-heading drops the heading but keeps the idempotency marker
#   (g) two images with the same basename fail (asset-name collision)
#   (h) a missing image file fails
#   (i) embed appends the block to the PR body via gh-axi pr edit --body-file
#   (j) embed is idempotent when the marker is already in the body (no edit call)
#   (k) embed --dry-run prints the composed body and makes no edit call
#   (m) embed aborts on a failed body read instead of overwriting the body
#   (l) an unknown option fails with a usage error
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SCRIPT="$ROOT/bin/fm-pr-screenshots.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-screenshots-tests)

# Build a sandbox with a fakebin whose gh/gh-axi mocks log every invocation.
# `release-exists` toggles the gh release view exit code; `pr-body.txt` feeds
# the gh pr view body read; the gh-axi mock captures any --body-file it is given.
make_case() {
  local dir="$TMP_ROOT/$1" fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$FM_TEST_LOG"
case "${1:-} ${2:-}" in
  "release view") [ -f "$FM_TEST_CASE/release-exists" ] && exit 0 || exit 1 ;;
  "pr view")
    [ -f "$FM_TEST_CASE/pr-read-fails" ] && exit 1
    cat "$FM_TEST_CASE/pr-body.txt" 2>/dev/null || true; exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'gh-axi %s\n' "$*" >> "$FM_TEST_LOG"
prev=
for a in "$@"; do
  [ "$prev" = "--body-file" ] && cp "$a" "$FM_TEST_CASE/edited-body.txt"
  prev=$a
done
exit 0
SH
  chmod +x "$fakebin/gh" "$fakebin/gh-axi"
  printf '%s\n' "$dir"
}

# run_case <case-dir> [cwd] -- <helper args...>: run the helper with the mocks on
# PATH, capturing stdout into RUN_OUT and the exit code into RUN_CODE.
run_case() {
  local dir=$1 cwd=$2; shift 2
  [ "$1" = "--" ] && shift
  export FM_TEST_LOG="$dir/calls.log" FM_TEST_CASE="$dir"
  : > "$FM_TEST_LOG"
  RUN_OUT=$(cd "$cwd" && PATH="$dir/fakebin:$PATH" "$SCRIPT" "$@" 2>"$dir/err.txt")
  RUN_CODE=$?
}

# --- (a) dry-run: zero network, deterministic URLs --------------------------
dir=$(make_case dryrun)
printf 'x' > "$dir/login.png"
printf 'x' > "$dir/home screen.png"
run_case "$dir" "$dir" -- --dry-run --repo acme/widget --namespace fm/login-x1 \
  "$dir/login.png" "$dir/home screen.png"
expect_code 0 "$RUN_CODE" "dry-run exits 0"
assert_contains "$RUN_OUT" "## Screenshots" "dry-run emits heading"
assert_contains "$RUN_OUT" "<!-- fm-pr-screenshots -->" "dry-run emits marker"
assert_contains "$RUN_OUT" \
  "![login](https://github.com/acme/widget/releases/download/fm-pr-assets/fm-login-x1-login.png)" \
  "dry-run emits deterministic login URL"
assert_contains "$RUN_OUT" \
  "![home screen](https://github.com/acme/widget/releases/download/fm-pr-assets/fm-login-x1-home-screen.png)" \
  "dry-run sanitizes spaces in the asset name but keeps the alt text"
[ ! -s "$dir/calls.log" ] || fail "dry-run must make no gh/gh-axi calls"$'\n'"$(cat "$dir/calls.log")"
pass "dry-run: no network, deterministic sanitized URLs"

# --- (b) upload creates release when missing, uploads namespaced + clobber ---
dir=$(make_case upload_create)
printf 'x' > "$dir/login.png"
run_case "$dir" "$dir" -- --repo acme/widget --namespace fm/login-x1 "$dir/login.png"
expect_code 0 "$RUN_CODE" "upload exits 0"
assert_grep "release view fm-pr-assets --repo acme/widget" "$dir/calls.log" "checks for the release"
assert_grep "release create fm-pr-assets" "$dir/calls.log" "creates the release when missing"
assert_grep "--prerelease" "$dir/calls.log" "creates a prerelease"
assert_grep "release upload fm-pr-assets --repo acme/widget --clobber" "$dir/calls.log" "uploads with --clobber"
assert_grep "fm-login-x1-login.png" "$dir/calls.log" "uploads under the namespaced asset name"
assert_contains "$RUN_OUT" \
  "https://github.com/acme/widget/releases/download/fm-pr-assets/fm-login-x1-login.png" \
  "prints the matching URL"
pass "upload: creates release then uploads namespaced asset with --clobber"

# --- (c) upload reuses an existing release ----------------------------------
dir=$(make_case upload_reuse)
touch "$dir/release-exists"
printf 'x' > "$dir/a.png"
run_case "$dir" "$dir" -- --repo acme/widget --namespace fm/x2 "$dir/a.png"
expect_code 0 "$RUN_CODE" "upload (reuse) exits 0"
assert_no_grep "release create" "$dir/calls.log" "does not create a release that already exists"
assert_grep "release upload fm-pr-assets" "$dir/calls.log" "still uploads to the existing release"
pass "upload: reuses an existing release without recreating it"

# --- (d) repo derived from the cwd git origin remote ------------------------
dir=$(make_case derive_repo)
repo="$dir/repo"
fm_git_init_commit "$repo"
git -C "$repo" remote add origin git@github.com:derived/proj.git
printf 'x' > "$repo/shot.png"
run_case "$dir" "$repo" -- --dry-run --namespace fm/z1 "$repo/shot.png"
expect_code 0 "$RUN_CODE" "derive-repo exits 0"
assert_contains "$RUN_OUT" \
  "https://github.com/derived/proj/releases/download/fm-pr-assets/fm-z1-shot.png" \
  "derives owner/repo from the ssh origin remote"
pass "repo derivation: owner/repo parsed from the git origin remote"

# --- (e) namespace derived from the current git branch ----------------------
dir=$(make_case derive_ns)
repo="$dir/repo"
fm_git_init_commit "$repo"
git -C "$repo" checkout -q -b fm/feature-9
printf 'x' > "$repo/shot.png"
run_case "$dir" "$repo" -- --dry-run --repo acme/widget "$repo/shot.png"
expect_code 0 "$RUN_CODE" "derive-namespace exits 0"
assert_contains "$RUN_OUT" \
  "releases/download/fm-pr-assets/fm-feature-9-shot.png" \
  "derives the asset namespace from the fm/<id> branch"
pass "namespace derivation: prefix taken from the current git branch"

# --- (f) --no-heading drops the heading, keeps the marker -------------------
dir=$(make_case no_heading)
printf 'x' > "$dir/a.png"
run_case "$dir" "$dir" -- --dry-run --no-heading --repo acme/widget --namespace fm/x "$dir/a.png"
expect_code 0 "$RUN_CODE" "--no-heading exits 0"
assert_not_contains "$RUN_OUT" "## Screenshots" "--no-heading drops the heading"
assert_contains "$RUN_OUT" "<!-- fm-pr-screenshots -->" "--no-heading keeps the idempotency marker"
pass "--no-heading: heading omitted, marker kept"

# --- (g) duplicate asset names fail -----------------------------------------
dir=$(make_case dup_names)
mkdir -p "$dir/one" "$dir/two"
printf 'x' > "$dir/one/shot.png"
printf 'x' > "$dir/two/shot.png"
run_case "$dir" "$dir" -- --dry-run --repo acme/widget --namespace fm/x "$dir/one/shot.png" "$dir/two/shot.png"
expect_code 1 "$RUN_CODE" "duplicate asset names fail"
assert_grep "same asset name" "$dir/err.txt" "explains the collision"
pass "duplicate basenames: rejected as an asset-name collision"

# --- (h) a missing image file fails -----------------------------------------
dir=$(make_case missing_img)
run_case "$dir" "$dir" -- --dry-run --repo acme/widget --namespace fm/x "$dir/nope.png"
expect_code 1 "$RUN_CODE" "missing image fails"
assert_grep "image not found" "$dir/err.txt" "reports the missing image"
pass "missing image: rejected before any upload"

# --- (i) embed appends the block to the PR body -----------------------------
dir=$(make_case embed_append)
printf 'Existing body.\n' > "$dir/pr-body.txt"
printf '## Screenshots\n\n<!-- fm-pr-screenshots -->\n![a](https://example/a.png)\n' > "$dir/block.md"
run_case "$dir" "$dir" -- embed https://github.com/acme/widget/pull/7 "$dir/block.md"
expect_code 0 "$RUN_CODE" "embed exits 0"
assert_grep "pr edit 7 --repo acme/widget --body-file" "$dir/calls.log" "edits the PR via gh-axi"
assert_present "$dir/edited-body.txt" "embed writes a body file"
new_body=$(cat "$dir/edited-body.txt")
assert_contains "$new_body" "Existing body." "embed preserves the existing body"
assert_contains "$new_body" "![a](https://example/a.png)" "embed appends the screenshots block"
pass "embed: appends the block to the existing PR body"

# --- (j) embed is idempotent when the marker is present ---------------------
dir=$(make_case embed_idempotent)
printf 'Body with block.\n\n<!-- fm-pr-screenshots -->\n![a](https://example/a.png)\n' > "$dir/pr-body.txt"
printf '<!-- fm-pr-screenshots -->\n![a](https://example/a.png)\n' > "$dir/block.md"
run_case "$dir" "$dir" -- embed https://github.com/acme/widget/pull/7 "$dir/block.md"
expect_code 0 "$RUN_CODE" "idempotent embed exits 0"
assert_no_grep "pr edit" "$dir/calls.log" "does not re-edit a body that already has the block"
assert_grep "already embedded" "$dir/err.txt" "reports the no-op"
pass "embed: idempotent when the marker is already in the body"

# --- (k) embed --dry-run prints the composed body, no edit ------------------
dir=$(make_case embed_dryrun)
printf 'Existing body.\n' > "$dir/pr-body.txt"
printf '<!-- fm-pr-screenshots -->\n![a](https://example/a.png)\n' > "$dir/block.md"
run_case "$dir" "$dir" -- embed --dry-run https://github.com/acme/widget/pull/7 "$dir/block.md"
expect_code 0 "$RUN_CODE" "embed --dry-run exits 0"
assert_contains "$RUN_OUT" "Existing body." "dry-run prints the existing body"
assert_contains "$RUN_OUT" "![a](https://example/a.png)" "dry-run prints the appended block"
assert_no_grep "pr edit" "$dir/calls.log" "dry-run makes no edit call"
pass "embed --dry-run: composes the body without editing"

# --- (m) embed aborts on a failed body read, never overwriting the body -----
dir=$(make_case embed_read_fail)
touch "$dir/pr-read-fails"
printf '<!-- fm-pr-screenshots -->\n![a](https://example/a.png)\n' > "$dir/block.md"
run_case "$dir" "$dir" -- embed https://github.com/acme/widget/pull/7 "$dir/block.md"
expect_code 1 "$RUN_CODE" "embed aborts when the PR body read fails"
assert_no_grep "pr edit" "$dir/calls.log" "must not edit the PR body after a failed read"
assert_grep "refusing to overwrite" "$dir/err.txt" "explains why it aborted"
pass "embed: aborts on a failed body read instead of clobbering the description"

# --- (l) unknown option fails -----------------------------------------------
dir=$(make_case bad_opt)
printf 'x' > "$dir/a.png"
run_case "$dir" "$dir" -- --bogus --repo acme/widget --namespace fm/x "$dir/a.png"
expect_code 2 "$RUN_CODE" "unknown option exits 2"
assert_grep "unknown option" "$dir/err.txt" "reports the unknown option"
pass "unknown option: rejected with a usage error"

printf '\nall fm-pr-screenshots tests passed\n'
