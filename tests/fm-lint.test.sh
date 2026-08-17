#!/usr/bin/env bash
# Parity guard for firstmate's shell-lint definition.
#
# bin/fm-lint.sh must be the single owner that BOTH CI
# (.github/workflows/ci.yml) and the pre-push gate (.no-mistakes.yaml
# commands.lint) invoke, so the local lint can never diverge from CI again.
# Regression origin: with no commands.lint configured, the local no-mistakes
# lint step never ran the deterministic
# `shellcheck bin/*.sh bin/backends/*.sh tests/*.sh`, so PRs passed local
# validation yet failed that exact check in CI on info/warning findings such as
# SC2015, SC1007, and SC2034. A second axis was tool-version skew: CI's
# ShellCheck floated with the runner image and still emitted SC2015, which
# ShellCheck retired in 0.11.0. fm-lint.sh now pins one exact version and both
# gates resolve it, so command, file set, config, AND version all match.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-lint.sh"
INSTALLER="$ROOT/bin/fm-install-shellcheck.sh"
# The pinned version, read from the single source (the one owner itself).
REQUIRED=$("$LINT" --required-version)

# Official GitHub release asset sha256 values for shellcheck v0.11.0 .tar.xz
# archives (https://github.com/koalaman/shellcheck/releases/tag/v0.11.0). Tests
# compare installer behavior against these published digests, not script source.
SHELLCHECK_SHA_LINUX_X86_64=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
SHELLCHECK_SHA_LINUX_AARCH64=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
SHELLCHECK_SHA_DARWIN_X86_64=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6
SHELLCHECK_SHA_DARWIN_AARCH64=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79

# fm_install_stub_uname <fakebin>: uname -s / uname -m from FM_TEST_UNAME_S/M.
fm_install_stub_uname() {
  local fakebin=$1
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "${FM_TEST_UNAME_S:-Linux}" ;;
  -m) printf '%s\n' "${FM_TEST_UNAME_M:-x86_64}" ;;
  *) printf '%s\n' "${FM_TEST_UNAME_S:-Linux}" ;;
esac
SH
  chmod +x "$fakebin/uname"
}

# fm_install_stub_curl <fakebin>: log the URL, fail CURL_FAIL_UNTIL times, then
# write an empty file at -o. CURL_COUNT and CURL_URL_LOG are paths the stub
# updates when invoked.
fm_install_stub_curl() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "${CURL_COUNT:-}" ] || count=$(cat "$CURL_COUNT")
count=$((count + 1))
[ -z "${CURL_COUNT:-}" ] || printf '%s\n' "$count" > "$CURL_COUNT"
url=
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out=$2
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url=$1
      shift
      ;;
  esac
done
[ -z "${CURL_URL_LOG:-}" ] || printf '%s\n' "$url" >> "$CURL_URL_LOG"
fail_until=${CURL_FAIL_UNTIL:-0}
[ "$count" -gt "$fail_until" ] || exit 22
: > "$out"
exit 0
SH
  chmod +x "$fakebin/curl"
}

# fm_install_stub_hasher <fakebin> <name>: sha256sum or shasum stub that prints
# SHA256_STUB_HASH and records the invocation on HASHER_LOG. shasum requires -a 256.
fm_install_stub_hasher() {
  local fakebin=$1 name=$2
  cat > "$fakebin/$name" <<'SH'
#!/usr/bin/env bash
self=${0##*/}
if [ -n "${HASHER_LOG:-}" ]; then
  printf '%s\n' "$self $*" >> "$HASHER_LOG"
fi
file=$1
if [ "$self" = shasum ]; then
  algo=
  file=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -a)
        algo=$2
        shift 2
        ;;
      *)
        file=$1
        shift
        ;;
    esac
  done
  [ "$algo" = 256 ] || exit 1
fi
printf '%s  %s\n' "${SHA256_STUB_HASH:?}" "$file"
SH
  chmod +x "$fakebin/$name"
}

fm_install_stub_tar_shellcheck() {
  local fakebin=$1
  cat > "$fakebin/tar" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-C" ]; then
    mkdir -p "$2/shellcheck-v0.11.0"
    cat > "$2/shellcheck-v0.11.0/shellcheck" <<'EOF'
#!/usr/bin/env bash
printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
EOF
    chmod +x "$2/shellcheck-v0.11.0/shellcheck"
    exit 0
  fi
  shift
done
exit 2
SH
  chmod +x "$fakebin/tar"
}

fm_install_stub_sleep() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
}

# True only when the resolved shellcheck is exactly the pinned version, so the
# lint-running tests below match what CI enforces instead of a runner default.
pinned_ready() {
  command -v shellcheck >/dev/null 2>&1 || return 1
  [ "$(shellcheck --version | awk '/^version:/ {print $2; exit}')" = "$REQUIRED" ]
}

test_list_files_reports_the_shell_inventory() {
  local listed expected
  # CI=true forces the full canonical set regardless of the ambient branch or
  # working-tree diff a local test run happens to have, so this stays a pure
  # inventory check independent of fm-lint.sh's own changed-file mode below.
  listed=$(CI=true "$LINT" --list-files)
  expected=$(find bin bin/backends tests -maxdepth 1 -type f -name '*.sh' -print | LC_ALL=C sort)
  [ "$(printf '%s\n' "$listed" | LC_ALL=C sort)" = "$expected" ] \
    || fail "fm-lint.sh --list-files did not return the complete shell inventory"
  pass "fm-lint.sh --list-files reports the complete shell inventory"
}

# fm_lint_stub_git <fakebin-dir>: install a git stub for the changed-file mode
# tests below. Its answers are driven by env vars the caller sets before
# invoking fm-lint.sh, so those tests can steer git state without depending on
# this worktree's actual branch, remotes, or history:
#   FM_TEST_GIT_INSIDE_WORKTREE  1 (default) or 0
#   FM_TEST_GIT_BRANCH           branch name for `rev-parse --abbrev-ref HEAD`
#   FM_TEST_GIT_HAS_ORIGIN_MAIN  1 (default) or 0
#   FM_TEST_GIT_HAS_MAIN         1 (default) or 0
#   FM_TEST_GIT_MERGE_BASE_OK    1 (default) or 0
#   FM_TEST_GIT_MERGE_BASE       merge-base value to print when OK
#   FM_TEST_GIT_DIFF_FILE        path to a file of NUL-separated changed paths
#   FM_TEST_GIT_DIFF_RECHECK_OK  1 (default) or 0, for the non-NUL diff form
#                                fm-lint.sh re-asks to verify its selection
fm_lint_stub_git() {
  local fakebin=$1
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "rev-parse --is-inside-work-tree")
    [ "${FM_TEST_GIT_INSIDE_WORKTREE:-1}" = 1 ] || exit 1
    printf 'true\n'
    exit 0
    ;;
  "rev-parse --abbrev-ref HEAD")
    printf '%s\n' "${FM_TEST_GIT_BRANCH:-feature}"
    exit 0
    ;;
  "rev-parse --verify -q origin/main")
    [ "${FM_TEST_GIT_HAS_ORIGIN_MAIN:-1}" = 1 ] && exit 0 || exit 1
    ;;
  "rev-parse --verify -q main")
    [ "${FM_TEST_GIT_HAS_MAIN:-1}" = 1 ] && exit 0 || exit 1
    ;;
  "merge-base "*)
    if [ "${FM_TEST_GIT_MERGE_BASE_OK:-1}" = 1 ]; then
      printf '%s\n' "${FM_TEST_GIT_MERGE_BASE:-fakebase123}"
      exit 0
    fi
    exit 1
    ;;
  *"diff --name-only --diff-filter=ACMR -z "*)
    if [ -n "${FM_TEST_GIT_DIFF_FILE:-}" ] && [ -f "$FM_TEST_GIT_DIFF_FILE" ]; then
      cat "$FM_TEST_GIT_DIFF_FILE"
    fi
    exit 0
    ;;
  *"diff --name-only --diff-filter=ACMR "*)
    [ "${FM_TEST_GIT_DIFF_RECHECK_OK:-1}" = 1 ] || {
      printf 'fatal: simulated git failure\n' >&2
      exit 128
    }
    if [ -n "${FM_TEST_GIT_DIFF_FILE:-}" ] && [ -f "$FM_TEST_GIT_DIFF_FILE" ]; then
      tr '\0' '\n' < "$FM_TEST_GIT_DIFF_FILE"
    fi
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/git"
}

# fm_lint_write_diff_file <file> <path>...: writes NUL-separated changed paths
# in the shape `git diff --name-only -z` produces, for FM_TEST_GIT_DIFF_FILE.
fm_lint_write_diff_file() {
  local file=$1
  shift
  printf '%s\0' "$@" > "$file"
}

# fm_lint_stub_shellcheck <fakebin-dir> <log-file>: install a ShellCheck stub
# that answers --version with the pinned version and otherwise logs the file
# roots it was asked to check (one per line) instead of actually analyzing
# them, so changed-file mode tests can assert exactly which files fm-lint.sh
# selected without depending on real ShellCheck findings.
fm_lint_stub_shellcheck() {
  local fakebin=$1 log=$2
  : > "$log"
  cat > "$fakebin/shellcheck" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
shift 3
printf '%s\n' "\$@" >> "$log"
exit 0
SH
  chmod +x "$fakebin/shellcheck"
}

# fm_lint_isolated_bin <tmp> <command>...: build a directory of symlinks to the
# named real commands and report it in FM_TEST_ISOLATED_BIN, for use as a
# COMPLETE replacement PATH.
#
# The missing-tool tests need a PATH with provably no shellcheck on it. Trimming
# the ambient PATH cannot promise that (a contributor may have shellcheck in
# /usr/bin), and a test that silently stops exercising the missing-tool path is
# worse than no test. An allowlisted PATH inverts that: shellcheck is absent
# because nothing was linked, on every host. A command that cannot be resolved
# fails the test rather than leaving the run to fail later for the wrong reason.
#
# It answers through a variable instead of stdout precisely so that promise
# holds: called as `dir=$(fm_lint_isolated_bin ...)` its own `fail` would exit
# only the command-substitution subshell, and the caller would keep going with an
# empty PATH - turning a host-setup problem into a bogus refusal diagnosis, and
# writing stubs to filesystem-root paths like /shellcheck along the way.
fm_lint_isolated_bin() {
  local tmp=$1 dir resolved cmd
  shift
  FM_TEST_ISOLATED_BIN=
  dir="$tmp/isolated-bin"
  mkdir -p "$dir" || fail "could not create an isolated bin directory"
  for cmd in "$@"; do
    resolved=$(command -v "$cmd") \
      || fail "fm_lint_isolated_bin needs $cmd on the ambient PATH to build an isolated PATH"
    ln -sf "$resolved" "$dir/$cmd" || fail "could not link $cmd into the isolated PATH"
  done
  PATH="$dir" command -v shellcheck >/dev/null 2>&1 \
    && fail "the isolated PATH resolved a shellcheck, so the missing-tool path would go untested"
  FM_TEST_ISOLATED_BIN=$dir
}

# The commands fm-lint.sh itself needs before it can resolve ShellCheck at all.
# Its shebang resolves bash through PATH, so env and bash must be present.
FM_LINT_REFUSAL_PATH_COMMANDS="env bash dirname"
# Additionally needed to complete a real lint run once ShellCheck is available.
FM_LINT_RUN_PATH_COMMANDS="env bash dirname mktemp wc tr sort cat mkdir rm mv perl awk"

# The status fm-lint.sh exits when it could not run and checked nothing. Pinned
# here on purpose: the whole point is that it is neither 0 (clean), nor 1
# (findings), nor 2 (usage), nor 127 (the shell's own command-not-found, which a
# caller cannot tell apart from fm-lint.sh being absent).
FM_LINT_REFUSED_EXIT=3

# fm_lint_assert_refusal <output> <rc> <what>: assert the shared "could not run"
# contract - an unmissable marker, a non-passing and non-ambiguous status, and a
# remedy naming the tool, the exact version, and how to get it.
fm_lint_assert_refusal() {
  local out=$1 rc=$2 what=$3
  [ "$rc" -ne 0 ] || fail "$what reported success while checking nothing"$'\n'"$out"
  [ "$rc" -ne 127 ] \
    || fail "$what exited 127, which a caller cannot tell apart from fm-lint.sh being missing"$'\n'"$out"
  [ "$rc" -eq "$FM_LINT_REFUSED_EXIT" ] \
    || fail "$what exited $rc, not the dedicated could-not-run status $FM_LINT_REFUSED_EXIT"$'\n'"$out"
  assert_contains "$out" "LINT NOT RUN" "$what did not visibly mark the lint as not run"
  assert_contains "$out" "ShellCheck" "$what did not name the required tool"
  assert_contains "$out" "$REQUIRED" "$what did not name the exact required version"
  assert_contains "$out" "bin/fm-install-shellcheck.sh" "$what did not name how to install the pin"
  assert_contains "$out" "--provision-shellcheck" "$what did not name the opt-in provisioning path"
}

test_missing_shellcheck_refuses_instead_of_passing() {
  # The regression this test exists for: with no ShellCheck resolvable, the lint
  # gate reported a clean step while having checked nothing, so a real finding
  # (an SC2016 caught only by running the canonical set by hand) shipped through
  # local validation. A gate that cannot run must say so, not pass.
  local tmp isolated out rc
  tmp=$(fm_test_tmproot fm-lint-missing-tool)
  # shellcheck disable=SC2086 # Deliberate word splitting of the command list.
  fm_lint_isolated_bin "$tmp" $FM_LINT_REFUSAL_PATH_COMMANDS
  isolated=$FM_TEST_ISOLATED_BIN

  rc=0
  # CI=true selects the full canonical set, so this reaches the tool check
  # without needing git on the isolated PATH.
  out=$(PATH="$isolated" CI=true "$LINT" 2>&1) || rc=$?
  fm_lint_assert_refusal "$out" "$rc" "a lint with no ShellCheck on PATH"
  pass "fm-lint.sh refuses out loud when no ShellCheck is present instead of passing"
}

test_wrong_version_and_unversioned_tool_share_the_refusal() {
  # Both skews are the same class as a missing tool: the pinned rule set was not
  # applied, so nothing trustworthy was checked.
  local tmp isolated out rc
  tmp=$(fm_test_tmproot fm-lint-skew)
  # The full run set: version resolution happens after the other tool checks, so
  # a thinner PATH would refuse for the wrong reason and prove nothing.
  # shellcheck disable=SC2086 # Deliberate word splitting of the command list.
  fm_lint_isolated_bin "$tmp" $FM_LINT_RUN_PATH_COMMANDS
  isolated=$FM_TEST_ISOLATED_BIN

  cat > "$isolated/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.9.9\n'
  exit 0
fi
exit 0
SH
  chmod +x "$isolated/shellcheck"
  rc=0
  out=$(PATH="$isolated" CI=true "$LINT" 2>&1) || rc=$?
  fm_lint_assert_refusal "$out" "$rc" "a lint under a non-pinned ShellCheck"
  assert_contains "$out" "0.9.9" "the refusal did not report the version actually resolved"

  # A tool that answers nothing must not be read as a matching version.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$isolated/shellcheck"
  chmod +x "$isolated/shellcheck"
  rc=0
  out=$(PATH="$isolated" CI=true "$LINT" 2>&1) || rc=$?
  fm_lint_assert_refusal "$out" "$rc" "a lint under a ShellCheck that reports no version"
  pass "fm-lint.sh refuses a version-skewed or unversioned ShellCheck on the same contract"
}

test_pin_and_inventory_answer_without_any_shellcheck() {
  # bin/fm-install-shellcheck.sh asks fm-lint.sh which version to fetch, so
  # --required-version must keep working when ShellCheck is exactly what is
  # missing, or the refusal above would break the installer that repairs it.
  # .github/workflows/ci.yml's stock-macOS-Bash job likewise calls --list-files
  # on a runner where ShellCheck is never installed.
  local tmp isolated version listed rc
  tmp=$(fm_test_tmproot fm-lint-no-tool-queries)
  # shellcheck disable=SC2086 # Deliberate word splitting of the command list.
  fm_lint_isolated_bin "$tmp" $FM_LINT_REFUSAL_PATH_COMMANDS
  isolated=$FM_TEST_ISOLATED_BIN

  rc=0
  version=$(PATH="$isolated" "$LINT" --required-version 2>&1) || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "--required-version failed with no ShellCheck present, breaking the installer"$'\n'"$version"
  [ "$version" = "$REQUIRED" ] \
    || fail "--required-version printed '$version', not the pin '$REQUIRED', with no ShellCheck present"

  rc=0
  listed=$(PATH="$isolated" CI=true "$LINT" --list-files 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "--list-files failed with no ShellCheck present"$'\n'"$listed"
  printf '%s\n' "$listed" | grep -Fqx 'bin/fm-lint.sh' \
    || fail "--list-files did not report the inventory with no ShellCheck present"$'\n'"$listed"
  pass "fm-lint.sh answers --required-version and --list-files with no ShellCheck present"
}

test_installer_learns_the_pin_with_no_shellcheck_present() {
  # End-to-end proof of the same dependency: the installer must be able to run in
  # exactly the state it exists to repair. Network and archive handling are
  # stubbed; the pin lookup is the real one.
  local tmp isolated destination out rc installed
  tmp=$(fm_test_tmproot fm-shellcheck-install-no-tool)
  # shellcheck disable=SC2086 # Deliberate word splitting of the command list.
  fm_lint_isolated_bin "$tmp" $FM_LINT_RUN_PATH_COMMANDS install
  isolated=$FM_TEST_ISOLATED_BIN
  destination="$tmp/provisioned"
  fm_lint_stub_download "$isolated"

  rc=0
  out=$(PATH="$isolated" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "the ShellCheck installer could not run with no ShellCheck present"$'\n'"$out"
  [ -x "$destination/shellcheck" ] || fail "the installer produced no executable"$'\n'"$out"
  installed=$(PATH="$isolated" "$destination/shellcheck" --version | awk '/^version:/ {print $2; exit}')
  [ "$installed" = "$REQUIRED" ] \
    || fail "the installer fetched version '$installed' instead of the pin '$REQUIRED'"
  pass "the ShellCheck installer still learns the pin when ShellCheck is what is missing"
}

test_ci_provisioned_shape_never_refuses() {
  # CI installs the pin in its own step and then runs the lint owner, so the
  # refusal must be unreachable there. Proven by reproducing that shape rather
  # than assuming it.
  local tmp isolated log out rc
  tmp=$(fm_test_tmproot fm-lint-ci-shape)
  # shellcheck disable=SC2086 # Deliberate word splitting of the command list.
  fm_lint_isolated_bin "$tmp" $FM_LINT_RUN_PATH_COMMANDS
  isolated=$FM_TEST_ISOLATED_BIN
  log="$tmp/shellcheck.log"
  fm_lint_stub_shellcheck "$isolated" "$log"

  rc=0
  out=$(PATH="$isolated" CI=true FM_LINT_JOBS=1 "$LINT" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the CI shape (pin provisioned, then lint) did not pass"$'\n'"$out"
  assert_not_contains "$out" "LINT NOT RUN" "the CI shape reached the refusal path"
  [ -s "$log" ] || fail "the CI shape passed without asking ShellCheck to check anything"
  pass "fm-lint.sh never refuses in CI's provision-then-lint shape"
}

test_provisioning_is_opt_in_and_never_degrades_to_a_pass() {
  # Default behavior is refuse, not fetch: a gate that reaches the network as a
  # side effect of validating is harder to trust and breaks offline. Opting in
  # provisions the pin; an opt-in that FAILS still refuses rather than passing.
  local tmp isolated target out rc repaired
  tmp=$(fm_test_tmproot fm-lint-provision)
  # shellcheck disable=SC2086 # Deliberate word splitting of the command list.
  fm_lint_isolated_bin "$tmp" $FM_LINT_RUN_PATH_COMMANDS install
  isolated=$FM_TEST_ISOLATED_BIN
  target="$tmp/good.sh"
  printf '#!/usr/bin/env bash\nset -eu\nprintf "ok\\n"\n' > "$target"

  # Without opting in, the same environment must refuse and fetch nothing.
  fm_lint_stub_download "$isolated"
  rc=0
  out=$(PATH="$isolated" CI=true "$LINT" "$target" 2>&1) || rc=$?
  fm_lint_assert_refusal "$out" "$rc" "a default lint with ShellCheck absent but installable"
  [ ! -e "$tmp/provisioned" ] \
    || fail "a default lint provisioned ShellCheck without being asked to"$'\n'"$out"

  # Opting in provisions the pin and completes the lint.
  rc=0
  out=$(PATH="$isolated" CI=true FM_LINT_JOBS=1 \
    "$LINT" --provision-shellcheck "$tmp/provisioned" "$target" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "opt-in provisioning did not produce a working lint"$'\n'"$out"
  assert_not_contains "$out" "LINT NOT RUN" "opt-in provisioning still refused"
  [ -x "$tmp/provisioned/shellcheck" ] || fail "opt-in provisioning installed no ShellCheck"$'\n'"$out"

  # The environment variable is the same opt-in.
  rc=0
  out=$(PATH="$isolated" CI=true FM_LINT_JOBS=1 \
    FM_LINT_PROVISION_SHELLCHECK="$tmp/provisioned-env" "$LINT" "$target" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "FM_LINT_PROVISION_SHELLCHECK did not provision the pin"$'\n'"$out"
  [ -x "$tmp/provisioned-env/shellcheck" ] || fail "FM_LINT_PROVISION_SHELLCHECK installed no ShellCheck"

  # "Ensure the pin" means a directory holding some OTHER build is repaired, not
  # accepted and not refused: with the download working, a wrong-version binary
  # already in the opt-in directory must be reinstalled and the lint must pass.
  # This is the half of the skip decision that a guard keying only on "some build
  # is already present here" would silently get wrong.
  fm_lint_write_stale_shellcheck "$tmp/stale-repaired"
  rc=0
  out=$(PATH="$isolated" CI=true FM_LINT_JOBS=1 \
    "$LINT" --provision-shellcheck "$tmp/stale-repaired" "$target" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "an opt-in directory holding an older build was not repaired"$'\n'"$out"
  assert_not_contains "$out" "LINT NOT RUN" "repairing an older build in the opt-in directory refused instead"
  repaired=$(PATH="$isolated" "$tmp/stale-repaired/shellcheck" --version \
    | awk '/^version:/ {print $2; exit}')
  [ "$repaired" = "$REQUIRED" ] \
    || fail "the repaired opt-in directory reports '$repaired', not the pin '$REQUIRED'"

  # From here the network is unreachable, exactly as on an offline host.
  printf '#!/usr/bin/env bash\nexit 22\n' > "$isolated/curl"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$isolated/sleep"
  chmod +x "$isolated/curl" "$isolated/sleep"

  # The opt-in ENSURES the pin rather than always fetching it: a directory that
  # already holds the pinned build must lint without reaching the network, or the
  # documented env-var form would refetch on every validation run and refuse
  # offline while the correct binary sits on disk. With the network down, a pass
  # here can only mean the download was skipped.
  rc=0
  out=$(PATH="$isolated" CI=true FM_LINT_JOBS=1 \
    "$LINT" --provision-shellcheck "$tmp/provisioned" "$target" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "an already-provisioned pin refused with the network unreachable"$'\n'"$out"
  assert_not_contains "$out" "LINT NOT RUN" "reusing an already-provisioned pin still refused"

  # A build that is not the pin is never simply used: when it cannot be repaired
  # either, that is a refusal, not a pass on whatever was sitting there.
  fm_lint_write_stale_shellcheck "$tmp/stale-offline"
  rc=0
  out=$(PATH="$isolated" CI=true \
    "$LINT" --provision-shellcheck "$tmp/stale-offline" "$target" 2>&1) || rc=$?
  fm_lint_assert_refusal "$out" "$rc" "an unrepairable older build in the opt-in directory"

  # A failed opt-in must refuse, never quietly lint with nothing or pass.
  rc=0
  out=$(PATH="$isolated" CI=true \
    "$LINT" --provision-shellcheck "$tmp/failed" "$target" 2>&1) || rc=$?
  fm_lint_assert_refusal "$out" "$rc" "a failed opt-in provisioning"
  pass "fm-lint.sh provisions only on request, reuses a present pin, repairs another build, and refuses on failure"
}

# fm_lint_write_stale_shellcheck <dir>: put an executable in <dir> that answers
# --version with a version other than the pin, for the ensure-semantics cases
# above: the opt-in must repair it when it can and refuse when it cannot, and
# must never put it on PATH as though it were the pin.
fm_lint_write_stale_shellcheck() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.9.9\n'
fi
exit 0
SH
  chmod +x "$dir/shellcheck"
}

test_unusable_temp_directory_refuses_on_the_could_not_run_status() {
  # A host that cannot hand the gate a temp directory (a TMPDIR that does not
  # exist, a full disk) checked nothing, so it must land on the declared
  # could-not-run status rather than on 1, which the same contract defines as
  # "ShellCheck reported findings". The status is the load-bearing signal: a
  # consumer capturing neither stream still has to fail the gate on it.
  local tmp isolated log target out rc
  tmp=$(fm_test_tmproot fm-lint-no-tmpdir)
  # shellcheck disable=SC2086 # Deliberate word splitting of the command list.
  fm_lint_isolated_bin "$tmp" $FM_LINT_RUN_PATH_COMMANDS
  isolated=$FM_TEST_ISOLATED_BIN
  log="$tmp/shellcheck.log"
  fm_lint_stub_shellcheck "$isolated" "$log"
  target="$tmp/good.sh"
  printf '#!/usr/bin/env bash\nset -eu\nprintf "ok\\n"\n' > "$target"

  rc=0
  out=$(PATH="$isolated" CI=true FM_LINT_JOBS=1 TMPDIR="$tmp/absent" \
    "$LINT" "$target" 2>&1) || rc=$?
  [ "$rc" -eq "$FM_LINT_REFUSED_EXIT" ] \
    || fail "an unusable TMPDIR exited $rc, not the could-not-run status $FM_LINT_REFUSED_EXIT"$'\n'"$out"
  assert_contains "$out" "LINT NOT RUN" "an unusable TMPDIR did not visibly mark the lint as not run"
  [ ! -s "$log" ] \
    || fail "a run that could not create its temp directory still claimed to check files"$'\n'"$(cat "$log")"
  pass "fm-lint.sh refuses on the could-not-run status when it cannot create a temp directory"
}

test_lost_worker_result_refuses_on_the_could_not_run_status() {
  # A bounded worker that dies before recording its result leaves its shard
  # unverified. Reporting that as a findings status (1) or a usage status (2)
  # would describe a run that never happened, so it refuses on the same
  # could-not-run status as a missing tool.
  local tmp isolated target out rc
  tmp=$(fm_test_tmproot fm-lint-lost-worker)
  # shellcheck disable=SC2086 # Deliberate word splitting of the command list.
  fm_lint_isolated_bin "$tmp" $FM_LINT_RUN_PATH_COMMANDS
  isolated=$FM_TEST_ISOLATED_BIN
  # Reproduce the worker dying mid-shard (an out-of-memory kill, a hard host
  # timeout): this stub kills the worker shell that is waiting on it, so no
  # shard result is ever written.
  cat > "$isolated/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
kill -KILL "$PPID"
exit 0
SH
  chmod +x "$isolated/shellcheck"
  target="$tmp/good.sh"
  printf '#!/usr/bin/env bash\nset -eu\nprintf "ok\\n"\n' > "$target"

  rc=0
  out=$(PATH="$isolated" CI=true FM_LINT_JOBS=1 "$LINT" "$target" 2>&1) || rc=$?
  [ "$rc" -eq "$FM_LINT_REFUSED_EXIT" ] \
    || fail "a lost worker result exited $rc, not the could-not-run status $FM_LINT_REFUSED_EXIT"$'\n'"$out"
  assert_contains "$out" "LINT NOT RUN" "a lost worker result did not visibly mark the lint as not run"
  pass "fm-lint.sh refuses on the could-not-run status when a worker result never arrives"
}

# fm_lint_run_path_without <command>: the run-path command list with <command>
# left out, so a test can drive "one required tool is missing" without
# hardcoding - and later drifting from - the rest of the list.
fm_lint_run_path_without() {
  local drop=$1 cmd list=
  # shellcheck disable=SC2086 # Deliberate word splitting of the command list.
  for cmd in $FM_LINT_RUN_PATH_COMMANDS; do
    [ "$cmd" = "$drop" ] || list="${list:+$list }$cmd"
  done
  printf '%s\n' "$list"
}

test_roots_lost_before_shellcheck_refuse_instead_of_passing_clean() {
  # Execution integrity, end to end: whatever selected the files, every one of them
  # must reach ShellCheck or the run refuses. The regression: with `sort` missing
  # the shard manifests came out empty, each worker took its no-roots branch and
  # recorded a clean result, and the gate exited 0 having asked ShellCheck to check
  # nothing. A truncated sort and a failed mv lose roots at the same place. Both
  # worker modes are covered, because the serial and parallel paths count alike.
  local tmp isolated log target out rc jobs
  tmp=$(fm_test_tmproot fm-lint-lost-roots)
  # shellcheck disable=SC2046 # Deliberate word splitting of the command list.
  fm_lint_isolated_bin "$tmp" $(fm_lint_run_path_without sort)
  isolated=$FM_TEST_ISOLATED_BIN
  log="$tmp/shellcheck.log"
  fm_lint_stub_shellcheck "$isolated" "$log"
  target="$tmp/good.sh"
  printf '#!/usr/bin/env bash\nset -eu\nprintf "ok\\n"\n' > "$target"

  for jobs in 1 2; do
    : > "$log"
    rc=0
    out=$(PATH="$isolated" CI=true FM_LINT_JOBS="$jobs" "$LINT" "$target" 2>&1) || rc=$?
    [ "$rc" -eq "$FM_LINT_REFUSED_EXIT" ] \
      || fail "jobs=$jobs lost every root and exited $rc, not $FM_LINT_REFUSED_EXIT"$'\n'"$out"
    assert_contains "$out" "LINT NOT RUN" "jobs=$jobs did not mark a lint that lost its roots as not run"
    [ ! -s "$log" ] \
      || fail "jobs=$jobs refused only after ShellCheck had checked files"$'\n'"$(cat "$log")"
  done
  pass "fm-lint.sh refuses when selected files never reach ShellCheck, serially and in parallel"
}

# fm_lint_stub_truncating_sort <dir>: install a `sort` that mangles only the -z
# form, emitting its first NUL record and dropping the rest - the shape a sort
# killed mid-write by an OOM kill or ENOSPC leaves in the changed-file read
# pipeline - and delegating every other invocation to the real sort. Built from
# shell builtins alone so it works on an isolated PATH with no sort of its own.
fm_lint_stub_truncating_sort() {
  local dir=$1 real
  real=$(command -v sort) || fail "fm_lint_stub_truncating_sort needs a real sort on the ambient PATH"
  rm -f "$dir/sort"
  cat > "$dir/sort" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" = -z ] || continue
  IFS= read -r -d '' first || first=
  while IFS= read -r -d '' rest; do :; done
  [ -z "\$first" ] || printf '%s\\0' "\$first"
  exit 0
done
exec "$real" "\$@"
SH
  chmod +x "$dir/sort"
}

test_changed_mode_verifies_its_selection_before_acting_on_it() {
  # The changed-file read cannot report its own failure: it runs in a process
  # substitution, so a git or a sort that died or was truncated there is
  # indistinguishable from a smaller diff - whether that leaves no targets or
  # merely fewer. That is this gate's own production mode - .no-mistakes.yaml pins
  # `lint: bin/fm-lint.sh` with no arguments, which on a feature branch outside CI
  # selects changed files - and CI can never exercise it, because CI forces a full
  # lint. So every direction of that verification is covered here.
  local tmp isolated log diff_file partial_diff empty_diff out rc
  tmp=$(fm_test_tmproot fm-lint-changed-zero)
  # shellcheck disable=SC2046 # Deliberate word splitting of the command list.
  fm_lint_isolated_bin "$tmp" $(fm_lint_run_path_without sort)
  isolated=$FM_TEST_ISOLATED_BIN
  fm_lint_stub_git "$isolated"
  log="$tmp/shellcheck.log"
  fm_lint_stub_shellcheck "$isolated" "$log"
  diff_file="$tmp/diff.nul"
  partial_diff="$tmp/partial.nul"
  empty_diff="$tmp/empty.nul"
  : > "$empty_diff"
  # A real canonical target plus a non-canonical file: with the read path broken,
  # zero roots reach the lint even though bin/fm-lint.sh changed.
  fm_lint_write_diff_file "$diff_file" "bin/fm-lint.sh" "README.md"
  # Three real canonical targets, for the partial-drop case below.
  fm_lint_write_diff_file "$partial_diff" \
    "bin/fm-lint.sh" "bin/fm-install-shellcheck.sh" "tests/fm-lint.test.sh"

  # Clear CI/GITHUB_ACTIONS so changed-file mode is live; a CI run forces a full
  # lint and cannot reach this branch at all.
  rc=0
  out=$(PATH="$isolated" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_BRANCH=feature FM_TEST_GIT_DIFF_FILE="$diff_file" "$LINT" 2>&1) || rc=$?
  [ "$rc" -eq "$FM_LINT_REFUSED_EXIT" ] \
    || fail "a changed-file read that dropped every target exited $rc, not $FM_LINT_REFUSED_EXIT"$'\n'"$out"
  assert_contains "$out" "LINT NOT RUN" "a dropped changed-file read did not mark the lint as not run"
  assert_not_contains "$out" "no changed lint targets" \
    "a dropped changed-file read still reported an empty target set as clean"
  [ ! -s "$log" ] || fail "the refusal fired after ShellCheck had checked files"$'\n'"$(cat "$log")"

  # A read that drops SOME of the changed targets is the same defect: linting a
  # subset while reporting on the whole is exactly the silent pass this gate exists
  # to prevent, and a count of what reached ShellCheck cannot see it - the subset is
  # internally consistent. Only comparing the selection against git catches it.
  fm_lint_stub_truncating_sort "$isolated"
  rc=0
  out=$(PATH="$isolated" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_BRANCH=feature FM_TEST_GIT_DIFF_FILE="$partial_diff" "$LINT" 2>&1) || rc=$?
  [ "$rc" -eq "$FM_LINT_REFUSED_EXIT" ] \
    || fail "a changed-file read that dropped 2 of 3 targets exited $rc, not $FM_LINT_REFUSED_EXIT"$'\n'"$out"
  assert_contains "$out" "LINT NOT RUN" "a partially dropped changed-file read did not mark the lint as not run"
  [ ! -s "$log" ] \
    || fail "a partially dropped selection was linted anyway"$'\n'"$(cat "$log")"

  # git failing while answering that question must refuse too, rather than being
  # discarded into an unexplained empty set.
  rm -f "$isolated/sort"
  ln -sf "$(command -v sort)" "$isolated/sort" || fail "could not restore sort on the isolated PATH"
  rc=0
  out=$(PATH="$isolated" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_BRANCH=feature FM_TEST_GIT_DIFF_FILE="$empty_diff" \
    FM_TEST_GIT_DIFF_RECHECK_OK=0 "$LINT" 2>&1) || rc=$?
  [ "$rc" -eq "$FM_LINT_REFUSED_EXIT" ] \
    || fail "git failing to confirm an empty target set exited $rc, not $FM_LINT_REFUSED_EXIT"$'\n'"$out"
  assert_contains "$out" "LINT NOT RUN" "an unconfirmable empty target set did not mark the lint as not run"

  # ...and a branch that genuinely changed no lint target must still pass with its
  # existing note, so verifying the selection never turns an empty diff into a
  # failure. The healthy non-empty selection is covered by the changed-mode lint
  # test below, which must keep passing for the same reason.
  rc=0
  out=$(PATH="$isolated" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_BRANCH=feature FM_TEST_GIT_DIFF_FILE="$empty_diff" "$LINT" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a genuinely empty changed set no longer exits 0, got $rc"$'\n'"$out"
  assert_contains "$out" "no changed lint targets" "a genuinely empty changed set lost its note"
  pass "fm-lint.sh verifies its changed-file selection against git before acting on it"
}

test_unresolvable_repository_root_refuses_on_the_could_not_run_status() {
  # `cd ""` is a successful no-op in bash, so a root that failed to resolve would
  # otherwise leave the run pointed at whatever directory the caller happened to be
  # in, reporting on a file set that is not this repository's. With dirname
  # answering a directory that does not exist, the script cannot locate itself and
  # must refuse on the could-not-run status instead of proceeding.
  local tmp isolated out rc
  tmp=$(fm_test_tmproot fm-lint-no-root)
  # shellcheck disable=SC2086 # Deliberate word splitting of the command list.
  fm_lint_isolated_bin "$tmp" $FM_LINT_REFUSAL_PATH_COMMANDS
  isolated=$FM_TEST_ISOLATED_BIN
  rm -f "$isolated/dirname"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s/absent"\n' "$tmp" > "$isolated/dirname"
  chmod +x "$isolated/dirname"

  rc=0
  out=$(PATH="$isolated" CI=true "$LINT" 2>&1) || rc=$?
  [ "$rc" -eq "$FM_LINT_REFUSED_EXIT" ] \
    || fail "an unresolvable repository root exited $rc, not $FM_LINT_REFUSED_EXIT"$'\n'"$out"
  assert_contains "$out" "LINT NOT RUN" "an unresolvable repository root did not mark the lint as not run"
  pass "fm-lint.sh refuses when it cannot resolve the repository root that holds it"
}

# fm_lint_stub_download <dir>: stub the network and archive tools
# bin/fm-install-shellcheck.sh uses, so provisioning can be exercised without
# reaching the network. The checksum the installer verifies is the real pinned
# one, and the extracted binary answers --version with the pinned version, so a
# provisioning path that installed the wrong thing would still be caught.
#
# The installer selects its archive and pinned digest from uname, so the platform
# is fixed here rather than read from the environment: the digest below must be
# the one the installer expects for the archive it chooses, on every host. Unlike
# the shared tar stub, the extracted binary stays silent unless asked for its
# version, because these tests then use it to lint real files.
fm_lint_stub_download() {
  local dir=$1
  fm_install_stub_curl "$dir"
  fm_install_stub_sleep "$dir"
  cat > "$dir/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -m) printf 'x86_64\n' ;;
  *) printf 'Linux\n' ;;
esac
SH
  cat > "$dir/sha256sum" <<SH
#!/usr/bin/env bash
printf '%s  %s\n' "$SHELLCHECK_SHA_LINUX_X86_64" "\$1"
SH
  cat > "$dir/tar" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-C" ]; then
    mkdir -p "$2/shellcheck-v0.11.0"
    cat > "$2/shellcheck-v0.11.0/shellcheck" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
fi
exit 0
EOF
    chmod +x "$2/shellcheck-v0.11.0/shellcheck"
    exit 0
  fi
  shift
done
exit 2
SH
  chmod +x "$dir/uname" "$dir/sha256sum" "$dir/tar"
}

test_changed_mode_lints_only_the_changed_file() {
  local tmp fakebin log diff_file out target
  tmp=$(fm_test_tmproot fm-lint-changed)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  log="$tmp/shellcheck.log"
  fm_lint_stub_shellcheck "$fakebin" "$log"
  diff_file="$tmp/diff.nul"
  target="bin/fm-install-shellcheck.sh"
  fm_lint_write_diff_file "$diff_file" "$target" "README.md"

  # Clear the ambient CI/GITHUB_ACTIONS signals so changed-file mode is actually
  # exercised: a CI run sets them and would otherwise force the full lint here.
  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_BRANCH=feature \
    FM_TEST_GIT_DIFF_FILE="$diff_file" "$LINT" 2>&1) \
    || fail "changed-mode lint run failed"$'\n'"$out"
  [ "$(cat "$log")" = "$target" ] \
    || fail "changed-mode lint did not run ShellCheck on exactly the changed file"$'\n'"logged: $(cat "$log")"
  pass "fm-lint.sh changed mode lints only the changed canonical file"
}

test_ci_forces_full_lint_even_with_empty_diff() {
  local listed expected
  # No git stub: CI=true must short-circuit fm-lint.sh's mode selection before
  # it ever consults git, so this proves CI wins regardless of local diff state.
  listed=$(CI=true "$LINT" --list-files)
  expected=$(find bin bin/backends tests -maxdepth 1 -type f -name '*.sh' -print | LC_ALL=C sort)
  [ "$(printf '%s\n' "$listed" | LC_ALL=C sort)" = "$expected" ] \
    || fail "CI=true did not force the full canonical file set"
  pass "fm-lint.sh forces a full lint in CI even when the local diff would be empty"
}

test_main_branch_forces_full_lint() {
  local tmp fakebin listed expected
  tmp=$(fm_test_tmproot fm-lint-main-full)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"

  # Clear CI/GITHUB_ACTIONS so the on-main branch is what forces the full lint,
  # not the ambient CI signal a real CI run would otherwise supply.
  listed=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' \
    FM_TEST_GIT_BRANCH=main "$LINT" --list-files)
  expected=$(find bin bin/backends tests -maxdepth 1 -type f -name '*.sh' -print | LC_ALL=C sort)
  [ "$(printf '%s\n' "$listed" | LC_ALL=C sort)" = "$expected" ] \
    || fail "fm-lint.sh did not force a full lint when HEAD is on main"
  pass "fm-lint.sh forces a full lint when HEAD is on main"
}

test_explicit_path_bypasses_changed_logic() {
  local tmp fakebin log out target
  tmp=$(fm_test_tmproot fm-lint-explicit-override)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  log="$tmp/shellcheck.log"
  fm_lint_stub_shellcheck "$fakebin" "$log"
  target="bin/fm-install-shellcheck.sh"

  # The git stub reports a broken merge-base, which would force a full lint
  # under the no-args default. Clearing CI/GITHUB_ACTIONS keeps changed-file
  # selection live so this proves the explicit path bypasses it, not that CI
  # already forced full mode. An explicit path must never even consult git.
  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_MERGE_BASE_OK=0 \
    "$LINT" "$target" 2>&1) || fail "explicit-path lint failed"$'\n'"$out"
  [ "$(cat "$log")" = "$target" ] \
    || fail "explicit path lint did not run on exactly the requested file"$'\n'"logged: $(cat "$log")"
  pass "fm-lint.sh explicit paths bypass changed-file mode selection"
}

test_zero_changed_files_exits_clean() {
  local tmp fakebin diff_file out rc
  tmp=$(fm_test_tmproot fm-lint-zero-changed)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  diff_file="$tmp/diff.nul"
  : > "$diff_file"

  rc=0
  # Clear CI/GITHUB_ACTIONS so changed-file mode runs and can reach the empty
  # target set; a CI run would otherwise force a full lint instead.
  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_TEST_GIT_BRANCH=feature \
    FM_TEST_GIT_DIFF_FILE="$diff_file" "$LINT" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "zero changed lint targets must exit 0, got $rc"$'\n'"$out"
  assert_contains "$out" "ShellCheck 0.11.0" "zero-changed run did not print the ShellCheck version line"
  assert_contains "$out" "no changed lint targets" "zero-changed run did not note the empty target set"
  assert_contains "$out" "workflow files valid" \
    "zero-changed run skipped workflow YAML validation"
  pass "fm-lint.sh exits 0 with a note when the local branch has no changed lint targets"
}

test_list_files_respects_changed_mode() {
  local tmp fakebin diff_file listed
  tmp=$(fm_test_tmproot fm-lint-list-changed)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  diff_file="$tmp/diff.nul"
  # A real canonical file, a non-canonical file, and a canonical-looking path
  # that does not exist: only the first should survive into the listed set.
  fm_lint_write_diff_file "$diff_file" \
    "tests/fm-lint.test.sh" "docs/README.md" "bin/definitely-not-real-file.sh"

  # Clear CI/GITHUB_ACTIONS so --list-files reflects the changed set rather than
  # the full canonical set a CI run's ambient signals would otherwise force.
  listed=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_TEST_GIT_BRANCH=feature \
    FM_TEST_GIT_DIFF_FILE="$diff_file" "$LINT" --list-files)
  [ "$listed" = "tests/fm-lint.test.sh" ] \
    || fail "--list-files did not report the would-be changed set in changed mode"$'\n'"got: $listed"
  pass "fm-lint.sh --list-files reports the would-be changed set in changed mode"
}

test_pins_an_explicit_version() {
  [ -n "$REQUIRED" ] || fail "fm-lint.sh --required-version printed nothing"
  # The captain-agreed pin: adopt ShellCheck 0.11.0's rule set consistently,
  # which is also what drops the upstream-retired, false-positive-prone SC2015.
  assert_contains "$REQUIRED" "0.11.0" "fm-lint.sh must pin ShellCheck 0.11.0"
  pass "fm-lint.sh pins an explicit ShellCheck version ($REQUIRED)"
}

test_installer_retries_transient_download_failure() {
  local tmp fakebin destination out
  tmp=$(fm_test_tmproot fm-shellcheck-download)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum
  fm_install_stub_tar_shellcheck "$fakebin"
  fm_install_stub_sleep "$fakebin"

  # Reproduce the CI incident: the release endpoint returned 503 for all three
  # formerly configured attempts before recovering. Force linux/x86_64 so the
  # retry path stays the CI archive even when this suite runs on macOS.
  out=$(CURL_COUNT="$tmp/curl-count" CURL_FAIL_UNTIL=3 \
    SHA256_STUB_HASH="$SHELLCHECK_SHA_LINUX_X86_64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer did not recover from a transient download failure"$'\n'"$out"
  [ "$(cat "$tmp/curl-count")" -eq 4 ] || fail "installer did not recover after three failed downloads"
  assert_contains "$out" "download attempt 3 failed; retrying" "installer did not disclose its third retry"
  [ -x "$destination/shellcheck" ] || fail "installer did not install ShellCheck after retrying"
  pass "ShellCheck installer retries a transient download failure"
}

test_installer_selects_platform_archive_url_and_checksum() {
  local tmp fakebin destination out url_log uname_s uname_m archive sha
  tmp=$(fm_test_tmproot fm-shellcheck-platform)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  url_log="$tmp/curl-url.log"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum
  fm_install_stub_tar_shellcheck "$fakebin"
  fm_install_stub_sleep "$fakebin"

  while IFS=$'\t' read -r uname_s uname_m archive sha; do
    [ -n "$uname_s" ] || continue
    rm -rf "$destination"
    : > "$url_log"
    out=$(CURL_URL_LOG="$url_log" SHA256_STUB_HASH="$sha" \
      FM_TEST_UNAME_S="$uname_s" FM_TEST_UNAME_M="$uname_m" \
      PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
      || fail "installer failed for ${uname_s}/${uname_m}"$'\n'"$out"
    assert_contains "$(cat "$url_log")" "$archive" \
      "installer did not download $archive for ${uname_s}/${uname_m}"
    assert_contains "$(cat "$url_log")" \
      "https://github.com/koalaman/shellcheck/releases/download/v${REQUIRED}/${archive}" \
      "installer used the wrong URL for ${uname_s}/${uname_m}"
    [ -x "$destination/shellcheck" ] || fail "installer did not install ShellCheck for ${uname_s}/${uname_m}"
  done <<EOF
Linux	x86_64	shellcheck-v${REQUIRED}.linux.x86_64.tar.xz	$SHELLCHECK_SHA_LINUX_X86_64
Linux	amd64	shellcheck-v${REQUIRED}.linux.x86_64.tar.xz	$SHELLCHECK_SHA_LINUX_X86_64
Linux	aarch64	shellcheck-v${REQUIRED}.linux.aarch64.tar.xz	$SHELLCHECK_SHA_LINUX_AARCH64
Linux	arm64	shellcheck-v${REQUIRED}.linux.aarch64.tar.xz	$SHELLCHECK_SHA_LINUX_AARCH64
Darwin	x86_64	shellcheck-v${REQUIRED}.darwin.x86_64.tar.xz	$SHELLCHECK_SHA_DARWIN_X86_64
Darwin	amd64	shellcheck-v${REQUIRED}.darwin.x86_64.tar.xz	$SHELLCHECK_SHA_DARWIN_X86_64
Darwin	arm64	shellcheck-v${REQUIRED}.darwin.aarch64.tar.xz	$SHELLCHECK_SHA_DARWIN_AARCH64
Darwin	aarch64	shellcheck-v${REQUIRED}.darwin.aarch64.tar.xz	$SHELLCHECK_SHA_DARWIN_AARCH64
EOF
  pass "ShellCheck installer selects the official archive, URL, and checksum per OS/arch"
}

test_installer_rejects_wrong_checksum() {
  local tmp fakebin destination out rc
  tmp=$(fm_test_tmproot fm-shellcheck-badsum)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum
  fm_install_stub_tar_shellcheck "$fakebin"
  fm_install_stub_sleep "$fakebin"

  rc=0
  out=$(SHA256_STUB_HASH=0000000000000000000000000000000000000000000000000000000000000000 \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted a wrong checksum"$'\n'"$out"
  assert_contains "$out" "checksum mismatch" "installer did not report a checksum mismatch"
  assert_contains "$out" "shellcheck-v${REQUIRED}.linux.x86_64.tar.xz" \
    "mismatch did not name the selected archive"
  assert_contains "$out" "$SHELLCHECK_SHA_LINUX_X86_64" \
    "mismatch did not name the pinned linux/x86_64 checksum"
  [ ! -e "$destination/shellcheck" ] || fail "installer installed ShellCheck after a checksum mismatch"
  pass "ShellCheck installer rejects a wrong checksum"
}

test_installer_falls_back_to_shasum() {
  local tmp fakebin destination out hasher_log tool
  tmp=$(fm_test_tmproot fm-shellcheck-shasum)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  hasher_log="$tmp/hasher.log"

  for tool in bash dirname mktemp rm awk mkdir install cat chmod; do
    ln -s "$(command -v "$tool")" "$fakebin/$tool"
  done
  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" shasum
  fm_install_stub_tar_shellcheck "$fakebin"
  fm_install_stub_sleep "$fakebin"

  # Restricted PATH: shasum is present, sha256sum is not.
  : > "$hasher_log"
  out=$(CURL_URL_LOG="$tmp/curl-url.log" HASHER_LOG="$hasher_log" \
    SHA256_STUB_HASH="$SHELLCHECK_SHA_LINUX_X86_64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer did not fall back to shasum -a 256"$'\n'"$out"
  assert_grep 'shasum -a 256' "$hasher_log" "installer did not invoke shasum -a 256"
  [ -x "$destination/shellcheck" ] || fail "installer did not install ShellCheck via shasum"
  pass "ShellCheck installer falls back to shasum -a 256 when sha256sum is absent"
}

test_installer_prefers_sha256sum_over_shasum() {
  local tmp fakebin destination hasher_log
  tmp=$(fm_test_tmproot fm-shellcheck-sha256sum-pref)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  hasher_log="$tmp/hasher.log"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum
  fm_install_stub_hasher "$fakebin" shasum
  fm_install_stub_tar_shellcheck "$fakebin"
  fm_install_stub_sleep "$fakebin"

  : > "$hasher_log"
  PATH="$fakebin:$PATH" HASHER_LOG="$hasher_log" \
    SHA256_STUB_HASH="$SHELLCHECK_SHA_LINUX_X86_64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    "$INSTALLER" "$destination" >/dev/null \
    || fail "installer failed when both hashers were present"
  assert_grep 'sha256sum' "$hasher_log" "installer did not prefer sha256sum"
  if grep -q 'shasum' "$hasher_log"; then
    fail "installer invoked shasum even though sha256sum was present"$'\n'"$(cat "$hasher_log")"
  fi
  pass "ShellCheck installer prefers sha256sum when both hashers are present"
}

test_installer_rejects_unsupported_platform() {
  local tmp fakebin destination out rc
  tmp=$(fm_test_tmproot fm-shellcheck-unsupported)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"

  rc=0
  out=$(FM_TEST_UNAME_S=FreeBSD FM_TEST_UNAME_M=amd64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted an unsupported OS"$'\n'"$out"
  assert_contains "$out" "unsupported platform" "installer did not name the unsupported platform"
  assert_contains "$out" "FreeBSD-amd64" "installer did not report the detected OS/arch"

  rc=0
  out=$(FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=ppc64le \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted an unsupported architecture"$'\n'"$out"
  assert_contains "$out" "unsupported platform" "installer did not reject linux/ppc64le"
  pass "ShellCheck installer rejects an unsupported OS or architecture"
}

test_catches_a_real_lint_defect() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): lint-defect regression check"
    return
  fi
  # A script with a genuine ShellCheck finding must make the one owner exit
  # non-zero, proving local now runs real shellcheck instead of the old no-op
  # lint step. We deliberately do NOT assert SC2015 (PR 475's actual failure):
  # ShellCheck removed SC2015 in the pinned 0.11.0, so asserting it would make
  # this test itself version-fragile - the very trap being fixed. SC1007 is a
  # warning present at default severity (and is itself one of the recurring
  # classes that slipped through, PR 474).
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-bad)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$("$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh passed a known-bad fixture"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not report the expected ShellCheck finding"
  pass "fm-lint.sh catches a real lint defect the old no-op gate passed"
}

test_ignores_ambient_shellcheck_opts() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): ambient options regression check"
    return
  fi
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-opts)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$(SHELLCHECK_OPTS='--exclude=SC1007' "$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh allowed ambient SHELLCHECK_OPTS to hide a finding"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not neutralize ambient SHELLCHECK_OPTS"
  pass "fm-lint.sh ignores ambient ShellCheck options"
}

test_clean_fixture_passes() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): clean fixture check"
    return
  fi
  local tmp good rc
  tmp=$(fm_test_tmproot fm-lint-good)
  mkdir -p "$tmp"
  good="$tmp/good.sh"
  cat > "$good" <<'SH'
#!/usr/bin/env bash
set -eu
if [ -n "${1:-}" ] && [ -d "$1" ]; then
  printf 'ok\n'
fi
SH
  rc=0
  "$LINT" "$good" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lint.sh flagged a clean fixture (exit $rc)"
  pass "fm-lint.sh passes a clean fixture"
}

test_jobs_are_deterministic_and_complete() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): deterministic bounded jobs check"
    return
  fi
  local tmp good bad_a bad_b out_clean_1 out_clean_2 out_fail_1 out_fail_2 out_fail_2b
  local telemetry telemetry_out cleanup_tmp cleanup_out rc_clean_1 rc_clean_2 rc_fail_1 rc_fail_2 rc_fail_2b rc_bad_jobs
  tmp=$(fm_test_tmproot fm-lint-jobs)
  mkdir -p "$tmp"
  good="$tmp/good.sh"
  bad_a="$tmp/bad-a.sh"
  bad_b="$tmp/bad-b.sh"
  telemetry="$tmp/telemetry.tsv"
  cat > "$good" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  cat > "$bad_a" <<'SH'
#!/usr/bin/env bash
bad_a() {
  local a= b=
  printf '%s\n' "$a$b"
}
SH
  cat > "$bad_b" <<'SH'
#!/usr/bin/env bash
bad_b() {
  printf '%s\n' $1
}
SH

  rc_clean_1=0
  out_clean_1=$(FM_LINT_JOBS=1 "$LINT" "$good" 2>&1) || rc_clean_1=$?
  rc_clean_2=0
  out_clean_2=$(FM_LINT_JOBS=2 "$LINT" "$good" 2>&1) || rc_clean_2=$?
  [ "$rc_clean_1" -eq 0 ] && [ "$rc_clean_2" -eq 0 ] || fail "clean jobs=1/jobs=2 paths must both pass"
  [ "$out_clean_1" = "$out_clean_2" ] || fail "clean jobs=1/jobs=2 output differs"

  rc_fail_1=0
  out_fail_1=$(FM_LINT_JOBS=1 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_1=$?
  rc_fail_2=0
  out_fail_2=$(FM_LINT_JOBS=2 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_2=$?
  rc_fail_2b=0
  out_fail_2b=$(FM_LINT_JOBS=2 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_2b=$?
  [ "$rc_fail_1" -ne 0 ] && [ "$rc_fail_1" -eq "$rc_fail_2" ] && [ "$rc_fail_2" -eq "$rc_fail_2b" ] \
    || fail "failing jobs=1/jobs=2 exit results differ: $rc_fail_1/$rc_fail_2/$rc_fail_2b"
  [ "$out_fail_1" = "$out_fail_2" ] && [ "$out_fail_2" = "$out_fail_2b" ] \
    || fail "failing diagnostics are not byte-identical and deterministic across jobs"
  assert_contains "$out_fail_1" "SC1007" "the first failing root diagnostic was lost"
  assert_contains "$out_fail_1" "SC2086" "the later failing root diagnostic was lost"
  rc_bad_jobs=0
  FM_LINT_JOBS=3 "$LINT" "$good" >/dev/null 2>&1 || rc_bad_jobs=$?
  [ "$rc_bad_jobs" -eq 2 ] || fail "the lint owner must reject unbounded worker counts"

  telemetry_out=$(FM_LINT_JOBS=2 FM_LINT_TELEMETRY="$telemetry" "$LINT" "$good" 2>&1) \
    || fail "telemetry-enabled clean lint failed"
  [ "$telemetry_out" = "$out_clean_2" ] || fail "quiet telemetry changed routine lint output"
  assert_grep $'format\tfm-lint-telemetry-v1' "$telemetry" "telemetry format marker is missing"
  assert_grep $'jobs\t2' "$telemetry" "telemetry did not record bounded jobs"
  assert_grep $'root_count\t1' "$telemetry" "telemetry did not record root count"
  assert_grep $'wall_seconds\t' "$telemetry" "telemetry did not record wall time"
  assert_grep $'user_seconds\t' "$telemetry" "telemetry did not record user CPU"
  assert_grep $'system_seconds\t' "$telemetry" "telemetry did not record system CPU"
  assert_grep $'max_worker_rss_kib\t' "$telemetry" "telemetry did not record maximum RSS"
  assert_grep $'source_boundary_directives\t' "$telemetry" "telemetry did not record source-graph boundaries"
  assert_grep $'shellcheck_processes_start\t' "$telemetry" "telemetry did not record competing ShellCheck conditions"

  cleanup_tmp="$tmp/lint-tmp"
  mkdir -p "$cleanup_tmp"
  cleanup_out=$(TMPDIR="$cleanup_tmp" FM_LINT_JOBS=2 "$LINT" "$good" 2>&1) \
    || fail "cleanup fixture lint failed"
  [ "$cleanup_out" = "$out_clean_2" ] || fail "cleanup fixture changed routine diagnostics"
  [ -z "$(find "$cleanup_tmp" -mindepth 1 -maxdepth 1 -name 'fm-lint.*' -print -quit)" ] \
    || fail "bounded lint left temporary worker state behind"
  pass "jobs=1 and jobs=2 preserve deterministic diagnostics, failures, cleanup bounds, and quiet telemetry"
}

test_worker_trees_stop_on_signal() {
  local tmp fakebin fixture jobs telemetry lint_tmp pid_file out_file telemetry_file
  local parent_pid shellcheck_pid i parent_rc survivor
  tmp=$(fm_test_tmproot fm-lint-signal)
  mkdir -p "$tmp"
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/good.sh"
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
printf '%s\n' "$$" > "$FM_TEST_SHELLCHECK_PID"
trap 'exit 143' HUP INT TERM
while :; do
  sleep 1
done
SH
  chmod +x "$fakebin/shellcheck"

  for jobs in 1 2; do
    for telemetry in off on; do
      lint_tmp="$tmp/lint-$jobs-$telemetry"
      pid_file="$tmp/shellcheck-$jobs-$telemetry.pid"
      out_file="$tmp/output-$jobs-$telemetry"
      telemetry_file=
      mkdir -p "$lint_tmp"
      if [ "$telemetry" = on ]; then
        telemetry_file="$tmp/telemetry-$jobs.tsv"
      fi
      PATH="$fakebin:$PATH" TMPDIR="$lint_tmp" FM_LINT_JOBS="$jobs" \
        FM_LINT_TELEMETRY="$telemetry_file" FM_TEST_SHELLCHECK_PID="$pid_file" \
        "$LINT" "$fixture" > "$out_file" 2>&1 &
      parent_pid=$!
      i=0
      while [ "$i" -lt 500 ] && [ ! -s "$pid_file" ]; do
        kill -0 "$parent_pid" 2>/dev/null || break
        sleep 0.01
        i=$((i + 1))
      done
      [ -s "$pid_file" ] || {
        kill -TERM "$parent_pid" 2>/dev/null || true
        wait "$parent_pid" 2>/dev/null || true
        fail "jobs=$jobs telemetry=$telemetry did not start ShellCheck"
      }
      shellcheck_pid=$(cat "$pid_file")
      kill -TERM "$parent_pid" 2>/dev/null \
        || fail "jobs=$jobs telemetry=$telemetry parent could not be interrupted"
      parent_rc=0
      wait "$parent_pid" 2>/dev/null || parent_rc=$?
      survivor=0
      i=0
      while [ "$i" -lt 100 ] && kill -0 "$shellcheck_pid" 2>/dev/null; do
        sleep 0.01
        i=$((i + 1))
      done
      if kill -0 "$shellcheck_pid" 2>/dev/null; then
        survivor=1
        kill -KILL "$shellcheck_pid" 2>/dev/null || true
      fi
      [ "$parent_rc" -eq 143 ] \
        || fail "jobs=$jobs telemetry=$telemetry signal exit was $parent_rc, expected 143"
      [ "$survivor" -eq 0 ] \
        || fail "jobs=$jobs telemetry=$telemetry left ShellCheck running"
      [ -z "$(find "$lint_tmp" -mindepth 1 -maxdepth 1 -name 'fm-lint.*' -print -quit)" ] \
        || fail "jobs=$jobs telemetry=$telemetry left temporary worker state"
    done
  done
  pass "jobs=1 and jobs=2 stop complete worker trees with and without telemetry"
}

test_seeded_module_boundary_parity() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): seeded source-boundary parity check"
    return
  fi
  local tmp rel adapter dispatcher dep owner test_root out rc
  tmp=$(mktemp -d "$ROOT/.fm-lint-parity.XXXXXX")
  if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then
    trap fm_test_cleanup EXIT
  fi
  FM_TEST_CLEANUP_DIRS+=("$tmp")
  rel=${tmp#"$ROOT/"}
  adapter="$tmp/adapter.sh"
  dispatcher="$tmp/dispatcher.sh"
  dep="$tmp/owner-dep.sh"
  owner="$tmp/owner.sh"
  test_root="$tmp/test-local.sh"

  cat > "$adapter" <<'SH'
#!/usr/bin/env bash
adapter_bad() {
  rm $1
}
SH
  cat > "$dispatcher" <<SH
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$adapter"
dispatcher_bad() {
  local a= b=
  printf '%s\n' "\$a\$b"
}
SH
  cat > "$dep" <<'SH'
#!/usr/bin/env bash
owner_dependency_value=ok
SH
  cat > "$owner" <<SH
#!/usr/bin/env bash
# shellcheck source=$rel/owner-dep.sh
. "$dep"
owner_bad() {
  printf '%s\n' "\$owner_dependency_value"
  cd "\$1"
}
SH
  cat > "$test_root" <<SH
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$owner"
test_local_bad() {
  local output=\$(printf ok)
  printf '%s\n' "\$output"
}
SH

  rc=0
  out=$(FM_LINT_JOBS=2 "$LINT" "$dispatcher" "$adapter" "$owner" "$test_root" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "seeded module-boundary defects unexpectedly passed"
  assert_contains "$out" "SC1007" "representative dispatcher defect was hidden"
  assert_contains "$out" "SC2086" "representative canonical adapter defect was hidden"
  assert_contains "$out" "SC2164" "representative production-owner defect was hidden"
  assert_contains "$out" "SC2155" "representative test-local defect was hidden"
  assert_not_contains "$out" "SC2154" "the production owner lost source-aware dependency context"
  [ "$(printf '%s\n' "$out" | grep -Fc 'SC2086 (info)')" -eq 1 ] \
    || fail "the dispatcher boundary re-imported the adapter diagnostic"
  [ "$(printf '%s\n' "$out" | grep -Fc 'SC2164 (warning)')" -eq 1 ] \
    || fail "the test boundary re-imported the production-owner diagnostic"
  pass "seeded dispatcher, adapter, production-owner, and test-local diagnostics preserve parity"
}

test_list_files_reports_the_shell_inventory
test_pins_an_explicit_version
test_installer_retries_transient_download_failure
test_installer_selects_platform_archive_url_and_checksum
test_installer_rejects_wrong_checksum
test_installer_falls_back_to_shasum
test_installer_prefers_sha256sum_over_shasum
test_installer_rejects_unsupported_platform
test_missing_shellcheck_refuses_instead_of_passing
test_wrong_version_and_unversioned_tool_share_the_refusal
test_pin_and_inventory_answer_without_any_shellcheck
test_installer_learns_the_pin_with_no_shellcheck_present
test_ci_provisioned_shape_never_refuses
test_provisioning_is_opt_in_and_never_degrades_to_a_pass
test_unusable_temp_directory_refuses_on_the_could_not_run_status
test_lost_worker_result_refuses_on_the_could_not_run_status
test_roots_lost_before_shellcheck_refuse_instead_of_passing_clean
test_changed_mode_verifies_its_selection_before_acting_on_it
test_unresolvable_repository_root_refuses_on_the_could_not_run_status
test_catches_a_real_lint_defect
test_ignores_ambient_shellcheck_opts
test_clean_fixture_passes
test_jobs_are_deterministic_and_complete
test_worker_trees_stop_on_signal
test_seeded_module_boundary_parity
test_changed_mode_lints_only_the_changed_file
test_ci_forces_full_lint_even_with_empty_diff
test_main_branch_forces_full_lint
test_explicit_path_bypasses_changed_logic
test_zero_changed_files_exits_clean
test_list_files_respects_changed_mode
