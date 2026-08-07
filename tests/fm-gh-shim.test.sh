#!/usr/bin/env bash
# Behavioral regressions for the gh shim that routes pull-request mutations through
# fm-gh.sh, and for fm-gh.sh's credential-prefix contract.
#
# The routed invocation under test is the exact argument vector the no-mistakes PR
# step builds for GitHub: `pr create --head <ref> --base <base> --repo <slug> --title
# <title> --body-file -`. Nothing here touches the real gh, the real daemon, or any
# network: a fake gh records how it was called, and a fake credential runner stands in
# for whatever the home configures.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHIM="$ROOT/bin/fm-gh-shim.sh"
WRAPPER="$ROOT/bin/fm-gh.sh"
INSTALLER="$ROOT/bin/fm-gh-shim-install.sh"
TMP_ROOT=$(fm_test_tmproot fm-gh-shim)
# Create before normalizing, then normalize: $TMPDIR often carries a trailing slash and
# these cases compare fixture paths against the installer's own `cd`-normalized output,
# so the path must be resolved rather than compared raw. The mkdir is not redundant,
# because a cleanup trap registered inside the command substitution above can remove the
# directory before it is ever used, which would make the normalizing `cd` fail.
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# make_fake_gh <dir>: a stand-in real gh that appends its argv and the credential the
# environment handed it to <dir>/gh.calls.
make_fake_gh() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/gh" << 'EOF'
#!/usr/bin/env bash
printf 'argv:%s\n' "$*" >> "$FAKE_GH_LOG"
printf 'token:%s\n' "${GITHUB_TOKEN:-<none>}" >> "$FAKE_GH_LOG"
printf 'gh-token:%s\n' "${GH_TOKEN:-<none>}" >> "$FAKE_GH_LOG"
printf 'effective-token:%s\n' "${GH_TOKEN:-${GITHUB_TOKEN:-<none>}}" >> "$FAKE_GH_LOG"
echo "https://github.com/o/r/pull/1"
EOF
  chmod +x "$dir/gh"
}

# make_home <home> <prefix-line>: a home whose config/gh-credential holds <prefix-line>.
make_home() {
  local home=$1 line=$2
  mkdir -p "$home/config"
  printf '%s\n' "$line" > "$home/config/gh-credential"
}

# make_fake_cred <dir>: a credential runner that injects a known token then execs the
# rest of its arguments, which is the shape config/gh-credential must satisfy.
make_fake_cred() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/fakecred" << 'EOF'
#!/usr/bin/env bash
# usage: fakecred <TOKEN_VALUE> -- <command> [args...]
token=$1
shift
[ "${1:-}" = "--" ] && shift
GITHUB_TOKEN="$token" exec "$@"
EOF
  chmod +x "$dir/fakecred"
}

test_pr_create_routes_through_wrapper() {
  local case_dir real_dir shim_dir home
  case_dir="$TMP_ROOT/route"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  home="$case_dir/home"
  make_fake_gh "$real_dir"
  make_fake_cred "$case_dir/tools"
  make_home "$home" "$case_dir/tools/fakecred pr-capable-token --"
  mkdir -p "$shim_dir"
  ln -sf "$SHIM" "$shim_dir/gh"

  local out
  out=$(
    FAKE_GH_LOG="$case_dir/gh.calls" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      PATH="$shim_dir:$real_dir:$PATH" \
      gh pr create --head feature --base main --repo o/r --title T --body-file - \
      < /dev/null 2>&1
  )

  assert_contains "$out" "https://github.com/o/r/pull/1" \
    "routed pr create did not return the real gh's output"
  assert_grep 'argv:pr create --head feature --base main --repo o/r --title T --body-file -' \
    "$case_dir/gh.calls" \
    "routed pr create did not reach the real gh with an unmodified argument vector"
  assert_grep 'token:pr-capable-token' "$case_dir/gh.calls" \
    "routed pr create did not receive the credential injected by config/gh-credential"
  pass "gh pr create routes through fm-gh.sh and reaches the real gh with the configured credential"
}

test_non_pr_invocations_pass_through_untouched() {
  local case_dir real_dir shim_dir home
  case_dir="$TMP_ROOT/passthrough"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  home="$case_dir/home"
  make_fake_gh "$real_dir"
  make_fake_cred "$case_dir/tools"
  make_home "$home" "$case_dir/tools/fakecred pr-capable-token --"
  mkdir -p "$shim_dir"
  ln -sf "$SHIM" "$shim_dir/gh"

  # `pr list` and `pr view` are the pipeline's read calls; the ambient credential is
  # sufficient for them, so the shim must not spend the privileged credential there.
  local invocation
  for invocation in "pr list --head feature" "pr view 1" "api user"; do
    # shellcheck disable=SC2086 # Deliberate word splitting of the fixture argv.
    FAKE_GH_LOG="$case_dir/gh.calls" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      PATH="$shim_dir:$real_dir:$PATH" \
      gh $invocation < /dev/null > /dev/null 2>&1
  done

  assert_grep 'argv:pr list --head feature' "$case_dir/gh.calls" \
    "pr list did not reach the real gh"
  assert_grep 'argv:pr view 1' "$case_dir/gh.calls" \
    "pr view did not reach the real gh"
  assert_no_grep 'token:pr-capable-token' "$case_dir/gh.calls" \
    "a non-mutating invocation was routed through the privileged credential"
  pass "pr list, pr view, and api pass through the shim without the privileged credential"
}

test_wrapper_without_config_is_transparent() {
  local case_dir real_dir home out
  case_dir="$TMP_ROOT/transparent"
  real_dir="$case_dir/real"
  home="$case_dir/home"
  make_fake_gh "$real_dir"
  mkdir -p "$home/config"

  out=$(
    FAKE_GH_LOG="$case_dir/gh.calls" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      GH_TOKEN="ambient-gh-token" GITHUB_TOKEN="ambient-github-token" \
      "$WRAPPER" "$real_dir/gh" pr create --title T < /dev/null 2>&1
  )

  assert_contains "$out" "https://github.com/o/r/pull/1" \
    "unconfigured wrapper did not exec the command"
  assert_grep 'argv:pr create --title T' "$case_dir/gh.calls" \
    "unconfigured wrapper altered the argument vector"
  assert_grep 'gh-token:ambient-gh-token' "$case_dir/gh.calls" \
    "unconfigured wrapper cleared the ambient GH_TOKEN"
  assert_grep 'token:ambient-github-token' "$case_dir/gh.calls" \
    "unconfigured wrapper cleared the ambient GITHUB_TOKEN"
  pass "fm-gh.sh with no config/gh-credential execs the command unchanged"
}

test_configured_wrapper_replaces_ambient_tokens() {
  local case_dir real_dir home
  case_dir="$TMP_ROOT/token-precedence"
  real_dir="$case_dir/real"
  home="$case_dir/home"
  make_fake_gh "$real_dir"
  make_fake_cred "$case_dir/tools"
  make_home "$home" "$case_dir/tools/fakecred prefix-token --"

  FAKE_GH_LOG="$case_dir/gh.calls" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    GH_TOKEN="hostile-gh-token" GITHUB_TOKEN="hostile-github-token" \
    "$WRAPPER" "$real_dir/gh" pr create < /dev/null > /dev/null 2>&1

  assert_grep 'gh-token:<none>' "$case_dir/gh.calls" \
    "configured wrapper left the higher-precedence ambient GH_TOKEN in place"
  assert_grep 'token:prefix-token' "$case_dir/gh.calls" \
    "configured wrapper did not replace the ambient GITHUB_TOKEN"
  assert_grep 'effective-token:prefix-token' "$case_dir/gh.calls" \
    "prefix-injected credential did not win gh token precedence"
  pass "configured fm-gh.sh exposes only the prefix-injected GitHub token"
}

test_wrapper_ignores_comments_and_blank_lines() {
  local case_dir real_dir home
  case_dir="$TMP_ROOT/comments"
  real_dir="$case_dir/real"
  home="$case_dir/home"
  make_fake_gh "$real_dir"
  make_fake_cred "$case_dir/tools"
  mkdir -p "$home/config"
  {
    printf '# a comment line\n'
    printf '\n'
    printf '   \n'
    printf '  %s second-line-token --  \n' "$case_dir/tools/fakecred"
    printf '%s ignored-token --\n' "$case_dir/tools/fakecred"
  } > "$home/config/gh-credential"

  FAKE_GH_LOG="$case_dir/gh.calls" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$WRAPPER" "$real_dir/gh" pr create < /dev/null > /dev/null 2>&1

  assert_grep 'token:second-line-token' "$case_dir/gh.calls" \
    "wrapper did not use the first non-comment, whitespace-trimmed prefix line"
  assert_no_grep 'token:ignored-token' "$case_dir/gh.calls" \
    "wrapper consumed a prefix line after the first usable one"
  pass "fm-gh.sh reads only the first non-empty, non-comment, trimmed prefix line"
}

test_wrapper_ignores_indented_comments() {
  local case_dir real_dir home
  case_dir="$TMP_ROOT/indented-comments"
  real_dir="$case_dir/real"
  home="$case_dir/home"
  make_fake_gh "$real_dir"
  make_fake_cred "$case_dir/tools"
  mkdir -p "$home/config"
  {
    printf '  # an indented comment line  \n'
    printf '%s indented-comment-token --\n' "$case_dir/tools/fakecred"
  } > "$home/config/gh-credential"

  FAKE_GH_LOG="$case_dir/gh.calls" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$WRAPPER" "$real_dir/gh" pr create < /dev/null > /dev/null 2>&1

  assert_grep 'token:indented-comment-token' "$case_dir/gh.calls" \
    "wrapper classified an indented comment as a credential prefix"
  pass "fm-gh.sh ignores credential comments after trimming whitespace"
}

test_shim_does_not_recurse_when_credential_resolves_gh_through_it() {
  local case_dir real_dir shim_dir home out
  case_dir="$TMP_ROOT/recursion"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  home="$case_dir/home"
  make_fake_gh "$real_dir"
  mkdir -p "$shim_dir" "$case_dir/tools"
  ln -sf "$SHIM" "$shim_dir/gh"
  # A credential runner that resolves `gh` from PATH again. Without the recursion
  # stop this re-enters the shim forever instead of reaching the real gh.
  cat > "$case_dir/tools/loopcred" << 'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--" ] && shift
shift             # drop the resolved real gh path the shim passed
exec gh "$@"      # resolve gh from PATH again, hitting the shim a second time
EOF
  chmod +x "$case_dir/tools/loopcred"
  make_home "$home" "$case_dir/tools/loopcred --"

  out=$(
    FAKE_GH_LOG="$case_dir/gh.calls" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      PATH="$shim_dir:$real_dir:$PATH" \
      gh pr create --title T < /dev/null 2>&1
  )

  assert_contains "$out" "https://github.com/o/r/pull/1" \
    "recursive credential resolution did not terminate at the real gh"
  local calls
  calls=$(grep -c '^argv:' "$case_dir/gh.calls")
  [ "$calls" = "1" ] || fail "expected exactly one real gh invocation, got $calls"
  pass "the shim routes at most once even when the credential re-resolves gh from PATH"
}

# find_bash32: echo the path of an available bash 3.2, or nothing. macOS still ships
# 3.2 as the system bash, and firstmate scripts must keep working under it.
find_bash32() {
  local candidate
  for candidate in /bin/bash /usr/bin/bash; do
    [ -x "$candidate" ] || continue
    case "$("$candidate" --version 2> /dev/null | head -1)" in
      *'version 3.'*)
        printf '%s\n' "$candidate"
        return 0
        ;;
    esac
  done
  return 1
}

test_bash32_runs_both_credential_paths() {
  local bash32 case_dir real_dir home out
  bash32=$(find_bash32) || {
    echo "skip: no bash 3.2 available for the legacy-shell regression"
    return 0
  }
  case_dir="$TMP_ROOT/bash32"
  real_dir="$case_dir/real"
  home="$case_dir/home"
  make_fake_gh "$real_dir"
  make_fake_cred "$case_dir/tools"
  mkdir -p "$home/config"

  # The unconfigured path is the one every home without config/gh-credential takes, and
  # under `set -u` bash 3.2 rejects an empty array's "${arr[@]}" expansion as unbound.
  out=$(
    FAKE_GH_LOG="$case_dir/gh.calls" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      "$bash32" "$WRAPPER" "$real_dir/gh" pr create --title T < /dev/null 2>&1
  )
  assert_not_contains "$out" "unbound variable" \
    "unconfigured wrapper hit an unbound-variable error on bash 3.2"
  assert_contains "$out" "https://github.com/o/r/pull/1" \
    "unconfigured wrapper did not exec the command on bash 3.2"

  make_home "$home" "$case_dir/tools/fakecred legacy-shell-token --"
  FAKE_GH_LOG="$case_dir/gh.calls" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$bash32" "$WRAPPER" "$real_dir/gh" pr create --title T < /dev/null > /dev/null 2>&1
  assert_grep 'token:legacy-shell-token' "$case_dir/gh.calls" \
    "configured wrapper did not inject the credential on bash 3.2"
  pass "fm-gh.sh runs both the unconfigured and configured paths under bash 3.2"
}

test_installer_reports_and_enforces_precedence() {
  local case_dir real_dir shim_dir out status
  case_dir="$TMP_ROOT/installer"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  make_fake_gh "$real_dir"
  mkdir -p "$shim_dir"

  status=0
  out=$("$INSTALLER" --check --dir "$shim_dir" --path "$shim_dir:$real_dir" 2>&1) || status=$?
  assert_contains "$out" "shim: not installed" "check did not report an absent shim"
  expect_code 1 "$status" "check on an absent shim"

  out=$("$INSTALLER" --install --dir "$shim_dir" --path "$shim_dir:$real_dir" 2>&1)
  assert_contains "$out" "installed:" "install did not report the created link"
  assert_contains "$out" "delegates to: $real_dir/gh" "install did not report the real gh"
  [ -L "$shim_dir/gh" ] || fail "install did not create a symlink named gh"

  status=0
  out=$("$INSTALLER" --check --dir "$shim_dir" --path "$shim_dir:$real_dir" 2>&1) || status=$?
  expect_code 0 "$status" "check on a winning installed shim"
  assert_contains "$out" "precedence: $shim_dir wins" "check did not confirm precedence"

  # Losing precedence must be reported, because a shim the daemon never resolves is
  # indistinguishable from no shim at all.
  status=0
  out=$("$INSTALLER" --check --dir "$shim_dir" --path "$real_dir:$shim_dir" 2>&1) || status=$?
  expect_code 1 "$status" "check on a shim that loses precedence"
  assert_contains "$out" "does NOT win" "check did not report lost precedence"

  out=$("$INSTALLER" --uninstall --dir "$shim_dir" 2>&1)
  assert_contains "$out" "removed:" "uninstall did not report removal"
  assert_absent "$shim_dir/gh" "uninstall left the shim in place"
  pass "the installer creates, verifies, reports precedence for, and removes the shim"
}

test_installer_refuses_to_replace_a_foreign_gh() {
  local case_dir real_dir shim_dir status out
  case_dir="$TMP_ROOT/foreign"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  make_fake_gh "$real_dir"
  make_fake_gh "$shim_dir"

  status=0
  out=$("$INSTALLER" --install --dir "$shim_dir" --path "$shim_dir:$real_dir" 2>&1) || status=$?
  expect_code 1 "$status" "install over a real file"
  assert_contains "$out" "this installer does not own it; remove it yourself first" \
    "installer did not refuse to overwrite an existing gh binary"

  # An unrelated gh symlink is equally not ours to delete.
  rm -f "$shim_dir/gh"
  ln -sf "$real_dir/gh" "$shim_dir/gh"
  status=0
  out=$("$INSTALLER" --uninstall --dir "$shim_dir" 2>&1) || status=$?
  expect_code 1 "$status" "uninstall of a foreign symlink"
  assert_present "$shim_dir/gh" "uninstall removed a symlink it does not own"
  pass "the installer refuses to overwrite or remove a gh it does not own"
}

test_installer_refuses_to_replace_a_foreign_symlink() {
  local case_dir real_dir shim_dir status out target
  case_dir="$TMP_ROOT/foreign-symlink"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  make_fake_gh "$real_dir"
  mkdir -p "$shim_dir"
  ln -s "$real_dir/gh" "$shim_dir/gh"
  target=$(readlink "$shim_dir/gh")

  status=0
  out=$("$INSTALLER" --install --dir "$shim_dir" --path "$shim_dir:$real_dir" 2>&1) || status=$?
  expect_code 1 "$status" "install over a foreign symlink"
  assert_contains "$out" "this installer does not own it; remove it yourself first" \
    "installer did not refuse to overwrite a foreign gh symlink"
  [ -L "$shim_dir/gh" ] || fail "installer removed a foreign gh symlink"
  [ "$(readlink "$shim_dir/gh")" = "$target" ] || \
    fail "installer changed the target of a foreign gh symlink"
  pass "the installer refuses a foreign gh symlink and leaves it intact"
}

test_pr_create_routes_through_wrapper
test_non_pr_invocations_pass_through_untouched
test_wrapper_without_config_is_transparent
test_configured_wrapper_replaces_ambient_tokens
test_wrapper_ignores_comments_and_blank_lines
test_wrapper_ignores_indented_comments
test_shim_does_not_recurse_when_credential_resolves_gh_through_it
test_bash32_runs_both_credential_paths
test_installer_reports_and_enforces_precedence
test_installer_refuses_to_replace_a_foreign_gh
test_installer_refuses_to_replace_a_foreign_symlink
