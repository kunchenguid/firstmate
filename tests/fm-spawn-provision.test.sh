#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Behavior tests for worktree dependency provisioning (bin/fm-provision-lib.sh)
# and its fm-spawn.sh hook.
#
# The installers are stubbed. These tests own the provisioning CONTRACT - what
# is detected, when an install is skipped, and what happens when it fails - not
# whether uv or npm work, which is their business and would make the suite need
# a network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-provision-lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-provision)

# --- fixtures ---------------------------------------------------------------

# Stub installers that record every invocation to $FM_TEST_INSTALL_LOG and
# produce exactly the artifacts the real ones do, so the readiness probes are
# exercised for real. FM_TEST_UV_FAIL / FM_TEST_NPM_FAIL / FM_TEST_NPM_SLEEP /
# FM_TEST_NPM_SIGNAL steer the failure, hang, and signal-death cases, and
# FM_TEST_UV_CHECK_FAIL / FM_TEST_UV_BREAK_PYTHON steer the two ways a finished
# install can be unhappy: metadata a consistency check dislikes, and no working
# interpreter at all.
make_installer_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/uv" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_TEST_INSTALL_LOG:-}" ] || printf 'uv %s\n' "$*" >> "$FM_TEST_INSTALL_LOG"
case "${1:-}" in
  --version) printf 'uv 1.2.3 (testfake)\n'; exit 0 ;;
  venv)
    [ "${FM_TEST_UV_FAIL:-0}" != 1 ] || exit 3
    rm -rf .venv
    mkdir -p .venv/bin .venv/lib/python3.11/site-packages
    [ "${FM_TEST_UV_BREAK_PYTHON:-0}" != 1 ] || exit 0
    cat > .venv/bin/python <<'PY'
#!/usr/bin/env bash
case "${2:-}" in
  *sys.version_info*) printf '%s' "${FM_TEST_PYTHON_VERSION:-3.11.9}" ;;
  *) exec python3 "$@" ;;
esac
PY
    chmod +x .venv/bin/python
    exit 0
    ;;
  sync)
    [ "${FM_TEST_UV_FAIL:-0}" != 1 ] || exit 3
    if [ "${FM_TEST_REQUIRE_UV_DEFAULT_GROUPS:-0}" = 1 ]; then
      [ -z "${UV_NO_DEV:-}${UV_ONLY_DEV:-}${UV_NO_DEFAULT_GROUPS:-}${UV_NO_GROUP:-}${UV_ONLY_GROUP:-}" ] \
        || exit 9
    fi
    mkdir -p .venv/bin .venv/lib/python3.11/site-packages
    printf 'fake uv project\n' > .venv/lib/python3.11/site-packages/fake_uv_project.pth
    cat > .venv/bin/python <<'PY'
#!/usr/bin/env bash
case "${2:-}" in
  *sys.version_info*) printf '%s' "${FM_TEST_PYTHON_VERSION:-3.11.9}" ;;
  *) exec python3 "$@" ;;
esac
PY
    chmod +x .venv/bin/python
    exit 0
    ;;
  pip)
    case "${2:-}" in
      install)
        [ "${FM_TEST_UV_FAIL:-0}" != 1 ] || exit 3
        mkdir -p .venv/lib/python3.11/site-packages/pytest \
          .venv/lib/python3.11/site-packages/six-1.16.0.dist-info \
          .venv/lib/python3.11/site-packages/pytest-8.3.4.dist-info
        printf 'six module\n' > .venv/lib/python3.11/site-packages/six.py
        printf 'pytest package\n' > .venv/lib/python3.11/site-packages/pytest/__init__.py
        printf 'Name: six\nVersion: 1.16.0\n' > .venv/lib/python3.11/site-packages/six-1.16.0.dist-info/METADATA
        printf 'Name: pytest\nVersion: 8.3.4\n' > .venv/lib/python3.11/site-packages/pytest-8.3.4.dist-info/METADATA
        printf '#!/usr/bin/env bash\nexit 0\n' > .venv/bin/pytest
        chmod +x .venv/bin/pytest
        # A real editable install records where it points through PEP 610's
        # direct_url.json, which is the artifact the readiness check reads back.
        prev=
        for arg in "$@"; do
          if [ "$prev" = -r ] && [ -f "$arg" ]; then
            while IFS= read -r line; do
              case "$line" in
                '-e '*)
                  target=$(cd "${line#-e }" 2>/dev/null && pwd) || continue
                  dist=.venv/lib/python3.11/site-packages/editable_local-0.1.0.dist-info
                  mkdir -p "$dist"
                  printf 'Name: editable-local\nVersion: 0.1.0\n' > "$dist/METADATA"
                  printf '{"url": "file://%s", "dir_info": {"editable": true}}\n' "$target" \
                    > "$dist/direct_url.json"
                  ;;
              esac
            done < "$arg"
          fi
          prev=$arg
        done
        exit 0
        ;;
      check)
        [ -x .venv/bin/python ] || exit 1
        [ "${FM_TEST_UV_CHECK_FAIL:-0}" != 1 ] || {
          printf 'six 1.16.0 requires attrs>=25, but you have attrs 24.2.0.\n' >&2
          exit 1
        }
        exit 0
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/npm" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_TEST_INSTALL_LOG:-}" ] || printf 'npm %s\n' "$*" >> "$FM_TEST_INSTALL_LOG"
case "${1:-}" in
  --version) printf '10.9.2\n'; exit 0 ;;
  ci)
    [ -z "${FM_TEST_NPM_SIGNAL:-}" ] || kill -"$FM_TEST_NPM_SIGNAL" "$$"
    [ "${FM_TEST_NPM_SLEEP:-0}" = 0 ] || sleep "$FM_TEST_NPM_SLEEP"
    [ "${FM_TEST_NPM_FAIL:-0}" != 1 ] || {
      mkdir -p node_modules/partial-package
      printf 'partial\n' > node_modules/partial-package/partial.txt
      printf 'npm ci exploded\n' >&2
      exit 7
    }
    mkdir -p node_modules/is-number
    printf '{"name":"is-number","version":"7.0.0"}\n' > node_modules/is-number/package.json
    printf 'module.exports = true\n' > node_modules/is-number/index.js
    case " $* " in
      *' --include=dev '*)
        mkdir -p node_modules/test-runner
        printf '{"name":"test-runner","version":"1.0.0"}\n' > node_modules/test-runner/package.json
        ;;
    esac
    printf '{}\n' > node_modules/.package-lock.json
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/pnpm" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_TEST_INSTALL_LOG:-}" ] || printf 'pnpm %s\n' "$*" >> "$FM_TEST_INSTALL_LOG"
case "${1:-}" in
  --version) printf '9.0.0\n'; exit 0 ;;
  install)
    mkdir -p node_modules/is-number
    printf '{"name":"is-number","version":"7.0.0"}\n' > node_modules/is-number/package.json
    printf 'module.exports = true\n' > node_modules/is-number/index.js
    case " $* " in
      *' --prod=false '*)
        mkdir -p node_modules/test-runner
        printf '{"name":"test-runner","version":"1.0.0"}\n' > node_modules/test-runner/package.json
        ;;
    esac
    printf 'hoistPattern:\n' > node_modules/.modules.yaml
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  -p|--print) printf '%s' "${FM_TEST_NODE_VERSION:-20.20.2}" ;;
esac
exit 0
SH
  chmod +x "$fakebin/uv" "$fakebin/npm" "$fakebin/pnpm" "$fakebin/node"
  printf '%s\n' "$fakebin"
}

# A python worktree, a js worktree, or both, with no git repo needed: the
# library operates on a directory.
make_worktree() {
  local dir=$1 shape=$2
  mkdir -p "$dir"
  case "$shape" in
    python|both)
      mkdir -p "$dir/svc"
      printf 'six==1.16.0\n' > "$dir/svc/requirements.txt"
      printf 'pytest==8.3.4\n' > "$dir/svc/requirements-test.txt"
      ;;
  esac
  case "$shape" in
    js|both)
      mkdir -p "$dir/web"
      printf '{"name":"web","private":true,"dependencies":{"is-number":"7.0.0"},"devDependencies":{"test-runner":"1.0.0"}}\n' > "$dir/web/package.json"
      printf '{"lockfileVersion":3}\n' > "$dir/web/package-lock.json"
      ;;
  esac
  case "$shape" in
    none)
      mkdir -p "$dir/docs" "$dir/src"
      printf '# docs\n' > "$dir/docs/README.md"
      printf 'int main(void) { return 0; }\n' > "$dir/src/main.c"
      ;;
  esac
}

# Run one library entry point in a subshell with the stub installers on PATH,
# printing "<rc> <summary>" plus whatever the library wrote to stderr.
run_provision() {
  local case_dir=$1 worktree=$2 fakebin=$3
  shift 3
  # shellcheck disable=SC2016  # the bash -c body expands its own positionals
  env FM_TEST_INSTALL_LOG="$case_dir/install.log" \
    PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$@" \
    bash -c '
      set -u
      . "$1"
      [ -z "${FM_TEST_PROVISION_BOUND_KIND:-}" ] \
        || FM_PROVISION_BOUND_KIND=$FM_TEST_PROVISION_BOUND_KIND
      if fm_provision_worktree "$2" "$3" "$4" "${FM_TEST_NEEDS:-}"; then
        printf "rc=0 summary=%s\n" "$FM_PROVISION_SUMMARY"
      else
        printf "rc=%s summary=%s\n" "$?" "$FM_PROVISION_SUMMARY"
      fi
    ' _ "$LIB" "$worktree" "$case_dir/cache" "$case_dir/provision.log" 2>&1
}

new_case() {
  local name=$1 shape=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  make_worktree "$case_dir/wt" "$shape"
  make_installer_fakebin "$case_dir/fake" > "$case_dir/fakebin.path"
  : > "$case_dir/install.log"
  printf '%s\n' "$case_dir"
}

case_fakebin() { cat "$1/fakebin.path"; }

# Run one library helper directly, for contracts that fm_provision_worktree
# reaches only through a component install.
run_lib() {
  # shellcheck disable=SC2016  # the bash -c body expands its own positionals
  env PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$@" \
    bash -c '
      set -u
      . "$1"
      eval "$FM_TEST_SNIPPET"
    ' _ "$LIB" 2>&1
}

# A PATH carrying everything provisioning needs before its pre-flight tool
# checks, minus python3, so the "no python3" refusal can be exercised for real.
make_python3_free_path() {
  local dir=$1 tool
  mkdir -p "$dir"
  for tool in bash find sort dirname basename perl mkdir rm cat date tr awk sed \
    grep head mktemp mv chmod ls shasum; do
    [ -e "$dir/$tool" ] || ln -s "$(command -v "$tool")" "$dir/$tool" 2>/dev/null || true
  done
  printf '%s\n' "$dir"
}

# --- library: no-op ---------------------------------------------------------

test_worktree_declaring_nothing_is_a_clean_noop() {
  local case_dir out
  case_dir=$(new_case noop none)
  out=$(run_provision "$case_dir" "$case_dir/wt" "$(case_fakebin "$case_dir")")
  assert_contains "$out" 'rc=0 summary=none' "a worktree with no recognized manifest should be a clean no-op: $out"
  [ ! -s "$case_dir/install.log" ] || fail "no-op provisioning still invoked an installer: $(cat "$case_dir/install.log")"
  [ ! -d "$case_dir/cache" ] || [ -z "$(ls -A "$case_dir/cache")" ] \
    || fail "no-op provisioning wrote a cache record"
  pass "a worktree declaring no recognized manifest provisions nothing and succeeds"
}

# --- library: install, then cache hit ---------------------------------------

test_first_spawn_installs_and_second_reuses_the_cache() {
  local case_dir out fakebin
  case_dir=$(new_case cache both)
  fakebin=$(case_fakebin "$case_dir")

  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" NODE_ENV=production NPM_CONFIG_OMIT=dev)
  assert_contains "$out" 'rc=0' "cold provisioning failed: $out"
  assert_contains "$out" 'pip:svc=installed' "cold provisioning did not install the python component: $out"
  assert_contains "$out" 'npm:web=installed' "cold provisioning did not install the js component: $out"
  assert_grep 'uv venv --clear .venv' "$case_dir/install.log" "python provisioning did not create a uv virtualenv"
  assert_grep 'uv pip install' "$case_dir/install.log" "python provisioning did not install requirements"
  assert_grep 'npm ci' "$case_dir/install.log" "js provisioning did not run npm ci"
  assert_grep 'npm ci --include=dev' "$case_dir/install.log" "npm provisioning inherited an ambient development-dependency omission"
  [ -f "$case_dir/wt/web/node_modules/test-runner/package.json" ] \
    || fail "npm provisioning omitted a declared validation dependency"
  assert_grep 'requirements-test.txt' "$case_dir/install.log" \
    "python provisioning ignored the companion test requirements"

  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'rc=0' "cache-hit provisioning failed: $out"
  assert_contains "$out" 'pip:svc=cached' "an unchanged python component was reinstalled: $out"
  assert_contains "$out" 'npm:web=cached' "an unchanged js component was reinstalled: $out"
  assert_no_grep 'npm ci' "$case_dir/install.log" "a cache hit still paid npm install cost"
  assert_no_grep 'uv pip install' "$case_dir/install.log" "a cache hit still paid uv install cost"
  pass "provisioning installs once and reuses an unchanged worktree without install cost"
}

test_a_changed_manifest_invalidates_the_cache() {
  local case_dir out fakebin
  case_dir=$(new_case manifest-change python)
  fakebin=$(case_fakebin "$case_dir")
  run_provision "$case_dir" "$case_dir/wt" "$fakebin" >/dev/null

  printf 'six==1.16.0\nattrs==24.2.0\n' > "$case_dir/wt/svc/requirements.txt"
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'pip:svc=installed' "a changed requirements file did not invalidate the cache: $out"
  assert_grep 'uv pip install' "$case_dir/install.log" "a changed manifest did not trigger a reinstall"
  pass "a changed dependency manifest invalidates the cache"
}

# The installer's own configuration decides what the install produces - .npmrc
# carries the registry, omissions, and pnpm's node-linker; uv.toml carries uv
# configuration pyproject.toml does not - and neither is a lockfile. A project
# that commits such a change with no lockfile change would otherwise re-lease
# the same pool slot, match the old fingerprint, pass the readiness probe
# against a byte-identical tree, and hand the lane an environment built under
# the superseded configuration: a confidently wrong cache HIT.
test_changed_installer_configuration_invalidates_the_cache() {
  local case_dir out fakebin
  case_dir=$(new_case installer-config both)
  fakebin=$(case_fakebin "$case_dir")
  printf 'registry=https://registry.npmjs.org/\n' > "$case_dir/wt/web/.npmrc"
  printf 'concurrent-builds = 4\n' > "$case_dir/wt/svc/uv.toml"
  run_provision "$case_dir" "$case_dir/wt" "$fakebin" >/dev/null

  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'npm:web=cached' "unchanged installer configuration was not a cache hit: $out"
  assert_contains "$out" 'pip:svc=cached' "unchanged installer configuration was not a cache hit: $out"

  printf 'registry=https://registry.example.com/\n' > "$case_dir/wt/web/.npmrc"
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'npm:web=installed' "a changed .npmrc did not invalidate the cache: $out"
  assert_grep 'npm ci' "$case_dir/install.log" "a changed .npmrc did not trigger a reinstall"
  assert_contains "$out" 'pip:svc=cached' "a changed .npmrc reinstalled an untouched python component: $out"

  printf 'concurrent-builds = 1\n' > "$case_dir/wt/svc/uv.toml"
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'pip:svc=installed' "a changed uv.toml did not invalidate the cache: $out"
  assert_grep 'uv pip install' "$case_dir/install.log" "a changed uv.toml did not trigger a reinstall"

  rm -f "$case_dir/wt/web/.npmrc"
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'npm:web=installed' "a removed .npmrc did not invalidate the cache: $out"
  pass "installer configuration that changes what is installed invalidates the cache"
}

test_a_removed_environment_invalidates_a_matching_fingerprint() {
  local case_dir out fakebin
  case_dir=$(new_case env-removed both)
  fakebin=$(case_fakebin "$case_dir")
  run_provision "$case_dir" "$case_dir/wt" "$fakebin" >/dev/null

  rm -rf "$case_dir/wt/web/node_modules/is-number"
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'npm:web=installed' "a deleted declared Node package was reported as cached: $out"
  assert_contains "$out" 'pip:svc=cached' "an untouched python component was needlessly reinstalled: $out"

  rm -f "$case_dir/wt/svc/.venv/lib/python3.11/site-packages/six.py"
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'pip:svc=installed' "a deleted declared Python package was reported as cached: $out"
  assert_contains "$out" 'npm:web=cached' "an untouched Node component was needlessly reinstalled: $out"

  rm -f "$case_dir/wt/svc/.venv/bin/pytest" "$case_dir/wt/web/node_modules/is-number/index.js"
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'pip:svc=installed' "a deleted Python validation executable was reported as cached: $out"
  assert_contains "$out" 'npm:web=installed' "a changed declared Node package was reported as cached: $out"
  pass "a fingerprint match with a broken environment is a miss, not a hit"
}

test_node_installs_include_validation_dependencies() {
  local case_dir out fakebin
  case_dir=$(new_case node-validation-deps none)
  fakebin=$(case_fakebin "$case_dir")
  mkdir -p "$case_dir/wt/tools"
  printf 'lockfileVersion: 9\n' > "$case_dir/wt/tools/pnpm-lock.yaml"
  printf '{"name":"tools","dependencies":{"is-number":"7.0.0"},"devDependencies":{"test-runner":"1.0.0"}}\n' \
    > "$case_dir/wt/tools/package.json"

  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" NODE_ENV=production)
  assert_contains "$out" 'pnpm:tools=installed' "pnpm provisioning failed under a production environment: $out"
  assert_grep 'pnpm install --frozen-lockfile --prod=false' "$case_dir/install.log" \
    "pnpm provisioning inherited an ambient development-dependency omission"
  [ -f "$case_dir/wt/tools/node_modules/test-runner/package.json" ] \
    || fail "pnpm provisioning omitted a declared validation dependency"
  pass "Node installs include declared validation dependencies deterministically"
}

test_a_replaced_interpreter_invalidates_the_cache() {
  local case_dir out fakebin
  case_dir=$(new_case interpreter-change python)
  fakebin=$(case_fakebin "$case_dir")
  run_provision "$case_dir" "$case_dir/wt" "$fakebin" >/dev/null

  # Same manifests, but the virtualenv now reports a different interpreter than
  # the one recorded at install time.
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" FM_TEST_PYTHON_VERSION=3.9.6)
  assert_contains "$out" 'pip:svc=installed' "a virtualenv whose interpreter changed was reported as cached: $out"
  pass "an environment whose recorded runtime no longer matches is reprovisioned"
}

# Regression: the readiness check must accept the real requirements.txt grammar.
# It runs only in the cache phase, so a line it cannot parse is not a refusal -
# it is a permanent cache miss that reinstalls on EVERY spawn into a pool slot,
# silently defeating the caching this exists for.
test_pip_requirement_directives_do_not_force_a_reinstall_every_spawn() {
  local case_dir out fakebin
  case_dir=$(new_case pip-directives none)
  fakebin=$(case_fakebin "$case_dir")
  mkdir -p "$case_dir/wt/svc"
  cat > "$case_dir/wt/svc/requirements.txt" <<'REQ'
--index-url https://example.invalid/simple
# the real declaration lives in an included file
-r base.txt
six==1.16.0 \
    --hash=sha256:0000000000000000000000000000000000000000000000000000000000000000
REQ
  printf 'pytest[testing]==8.3.4 ; python_version >= "3.9"\n' > "$case_dir/wt/svc/base.txt"

  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'pip:svc=installed' "cold provisioning failed: $out"

  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'pip:svc=cached' \
    "ordinary pip directives forced a reinstall on an unchanged component: $out"
  assert_no_grep 'uv pip install' "$case_dir/install.log" \
    "an unchanged component with pip directives still paid install cost"

  # An included file is part of what the component declares, so editing it must
  # be a cache MISS - reusing the environment there would be a false hit.
  printf 'pytest[testing]==8.3.4 ; python_version >= "3.10"\n' > "$case_dir/wt/svc/base.txt"
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'pip:svc=installed' \
    "a changed included requirements file was a false cache hit: $out"

  # A local editable install is about as common as a requirements.txt line gets.
  # Its identity is not in the line, but the installer records where it points,
  # so it is verified from that artifact - otherwise the component could never
  # cache and would pay a full `uv venv --clear` plus reinstall on every lease.
  printf -- '-e .\n' >> "$case_dir/wt/svc/requirements.txt"
  run_provision "$case_dir" "$case_dir/wt" "$fakebin" >/dev/null
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'pip:svc=cached' \
    "an editable install the installer recorded was not verified from its own artifacts: $out"
  assert_no_grep 'uv pip install' "$case_dir/install.log" \
    "a verifiable editable requirement still paid install cost on every lease"

  # A requirement whose package identity still cannot be determined cheaply is a
  # miss, never a hit - and the miss says so instead of looping silently.
  printf -- '-e git+https://example.invalid/pkg.git#egg=pkg\n' >> "$case_dir/wt/svc/requirements.txt"
  run_provision "$case_dir" "$case_dir/wt" "$fakebin" >/dev/null
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'pip:svc=installed' \
    "an unverifiable requirement was reported as cached: $out"
  assert_contains "$out" 'could not be verified' \
    "an unverifiable requirement reinstalled without saying why: $out"
  pass "pip directives and includes are parsed, so an unchanged component stays cached"
}

# Regression: ordinary lane activity must not look like a changed environment.
# webpack, vite, eslint, and babel all write node_modules/.cache, and adding one
# entry to a directory moves its mtime, ctime, and size - so hashing those for
# the node_modules root made the very next spawn into a healthy, untouched
# worktree pay a full reinstall, which is the one thing the cache exists to
# prevent.
test_lane_build_output_in_node_modules_is_not_a_cache_miss() {
  local case_dir out fakebin
  case_dir=$(new_case env-build-output both)
  fakebin=$(case_fakebin "$case_dir")
  run_provision "$case_dir" "$case_dir/wt" "$fakebin" >/dev/null

  mkdir -p "$case_dir/wt/web/node_modules/.cache"
  printf 'compiled\n' > "$case_dir/wt/web/node_modules/.cache/webpack.bin"
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'npm:web=cached' \
    "a build tool's own cache file inside node_modules invalidated a healthy environment: $out"
  assert_contains "$out" 'pip:svc=cached' \
    "an untouched python component was reinstalled: $out"
  assert_no_grep 'npm ci' "$case_dir/install.log" \
    "a lane's build output made an unchanged worktree pay npm install cost"
  assert_no_grep 'uv pip install' "$case_dir/install.log" \
    "a lane's build output made an unchanged worktree pay uv install cost"
  pass "build output written inside node_modules does not invalidate a healthy cache"
}

# Regression: the digest of nothing is a well-formed digest. A manifest that
# exists but cannot be read must refuse, because recording `manifest=<name>:`
# gives the component a perfectly stable fingerprint that does not depend on
# that file's content at all - and the NEXT lease recomputes the same value
# after the file changes and calls it a hit.
test_an_unreadable_manifest_refuses_instead_of_hashing_nothing() {
  local case_dir out fakebin record
  case_dir=$(new_case unreadable-manifest python)
  fakebin=$(case_fakebin "$case_dir")
  printf 'attrs<25\n' > "$case_dir/wt/svc/constraints.txt"
  chmod 000 "$case_dir/wt/svc/constraints.txt"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  chmod 600 "$case_dir/wt/svc/constraints.txt"
  assert_contains "$out" 'rc=1' "an unreadable declared manifest did not refuse: $out"
  assert_contains "$out" 'cannot resolve the declared manifests for the pip component in svc' \
    "the refusal did not name the component whose declaration could not be read: $out"
  assert_no_grep 'uv pip install' "$case_dir/install.log" \
    "a component whose declaration could not be hashed was installed anyway"
  for record in "$case_dir"/cache/*.record; do
    [ -e "$record" ] || continue
    fail "a component that could not be fingerprinted still recorded one: $record"
  done
  pass "a declared manifest that cannot be read refuses instead of hashing to nothing"
}

# Regression: every other bound in this library reports what it did not do. A
# component nested past the depth limit was the one that reported nowhere - not
# in the summary, the log, the metadata, or the lane's report - so a monorepo
# spawned a lane whose report named only the shallower components and read as
# complete.
test_a_component_below_the_scan_depth_is_reported_not_dropped() {
  local case_dir out fakebin report deep
  case_dir=$(new_case scan-depth python)
  fakebin=$(case_fakebin "$case_dir")
  deep=platform/services/billing/api
  mkdir -p "$case_dir/wt/$deep"
  printf 'six==1.16.0\n' > "$case_dir/wt/$deep/requirements.txt"

  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'rc=0' "a component past the depth limit refused instead of launching: $out"
  assert_contains "$out" "unscanned:$deep=skipped:below-scan-depth" \
    "a component past the depth limit was not recorded in the summary: $out"
  assert_contains "$out" "UNPROVISIONED: $deep" \
    "a component past the depth limit was not named on stderr: $out"
  assert_contains "$out" 'pip:svc=installed' \
    "a component past the depth limit stopped the ones within it: $out"
  assert_grep 'below-scan-depth' "$case_dir/provision.log" \
    "a component past the depth limit was named on stderr but not in the provisioning log"
  report="$case_dir/wt/.fm-provisioning.md"
  assert_grep "unscanned in $deep - NOT provisioned: below-scan-depth" "$report" \
    "the lane's report does not name the component the depth limit left it without"
  [ ! -d "$case_dir/wt/$deep/.venv" ] \
    || fail "a component past the depth limit was installed anyway"

  # The traversal is bounded, and the bound is real: it descends exactly one
  # level past the limit so the first component beyond it can be NAMED, and no
  # further. This pins that boundary rather than leaving it to prose.
  mkdir -p "$case_dir/wt/$deep/internal"
  printf 'six==1.16.0\n' > "$case_dir/wt/$deep/internal/requirements.txt"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" "unscanned:$deep=skipped:below-scan-depth" \
    "the first component past the depth limit stopped being reported: $out"
  assert_not_contains "$out" "$deep/internal" \
    "the traversal reached past its own bound: $out"
  pass "a component nested past the scan depth is reported everywhere, not dropped"
}

# A manifest scan that outlives its bound is work provisioning could not do
# here, not an attempt that failed: it warns, records the whole worktree as
# unavailable, and still launches - and because nothing was enumerated, the
# lane's report has to say so rather than carry a header that would read like a
# worktree that needed nothing.
test_a_scan_that_outlives_its_bound_launches_unprovisioned() {
  local case_dir out fakebin report slow_find
  case_dir=$(new_case scan-bound both)
  fakebin=$(case_fakebin "$case_dir")
  slow_find="$case_dir/slow"
  mkdir -p "$slow_find"
  cat > "$slow_find/find" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  chmod +x "$slow_find/find"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$slow_find:$fakebin" \
    FM_PROVISION_PROBE_TIMEOUT=2)
  assert_contains "$out" 'rc=0' "a scan that outlived its bound refused the spawn: $out"
  assert_contains "$out" 'summary=unavailable:scan-too-large' \
    "a scan that outlived its bound was not recorded as a whole-worktree gap: $out"
  [ ! -s "$case_dir/install.log" ] \
    || fail "a scan that never finished still invoked an installer: $(cat "$case_dir/install.log")"
  report="$case_dir/wt/.fm-provisioning.md"
  [ -f "$report" ] || fail "a scan that outlived its bound left the lane no report: $out"
  assert_grep 'NOT provisioned: scan-too-large' "$report" \
    "the lane's report does not say the scan is why it got nothing"
  pass "a dependency scan that outlives its bound warns, reports, and launches unprovisioned"
}

# Regression: a note is a verdict, and a verdict requires a check that ran.
# fm_provision_run_bounded reserves 124/125/126/127 for a check that did NOT
# run, and reporting one of those as "uv pip check reports ..." tells the lane a
# fact about its own environment that was never established - the same
# something-from-nothing shape as an empty digest or an empty signature.
test_a_check_that_could_not_run_is_never_reported_as_a_verdict() {
  local case_dir dir code out note
  case_dir=$(new_case probe-check-codes none)
  dir="$case_dir/wt/svc"
  mkdir -p "$dir/.venv/bin" "$case_dir/probe-bin"
  cat > "$dir/.venv/bin/python" <<'PY'
#!/usr/bin/env bash
printf '3.11.9'
PY
  chmod +x "$dir/.venv/bin/python"
  : > "$case_dir/probe.log"

  # 124/125/126/127 are the bounded runner's reserved codes. 2 is uv's OWN CLI
  # exit for a usage error - a real code from a real invocation that still
  # answered nothing about the environment - and 3 stands for any future exit uv
  # grows. Only 1 is uv pip check's "I ran and found an inconsistency".
  for code in 124 125 126 127 2 3 1; do
    printf '#!/usr/bin/env bash\nexit %s\n' "$code" > "$case_dir/probe-bin/uv"
    chmod +x "$case_dir/probe-bin/uv"
    # shellcheck disable=SC2016  # the snippet is evaluated inside run_lib's own shell
    out=$(FM_TEST_SNIPPET='
      FM_PROVISION_BOUND_KIND=perl
      if fm_provision_probe "$FM_TEST_WT" pip svc "$FM_TEST_LOG" 3.11.9 sig installed; then
        printf "rc=0 note=%s\n" "$FM_PROVISION_PROBE_NOTE"
      else
        printf "rc=%s note=%s\n" "$?" "$FM_PROVISION_PROBE_NOTE"
      fi
    ' run_lib PATH="$case_dir/probe-bin:/usr/bin:/bin" \
      FM_TEST_WT="$case_dir/wt" FM_TEST_LOG="$case_dir/probe.log")
    assert_contains "$out" 'rc=0' \
      "a uv pip check exiting $code turned a usable environment into a probe failure: $out"
    note=${out##*note=}
    note=${note%%$'\n'*}
    if [ "$code" = 1 ]; then
      [ "$note" = inconsistent-dependency-metadata ] \
        || fail "a real uv pip check verdict was not recorded as one (got '$note')"
    else
      [ "$note" != inconsistent-dependency-metadata ] \
        || fail "exit $code means uv pip check never ran, but it was recorded as a verdict about the environment"
      [ "$note" = unverified-dependency-metadata ] \
        || fail "exit $code did not record that the check could not be run (got '$note')"
    fi
  done
  pass "a uv pip check that could not run is recorded as unverified, never as a verdict"
}

# The same silence, one directory shape over: a project declaring only a
# pyproject.toml is not something this library installs from, but a lane that
# needs it must still be told so. Choosing an installer for a lockless project
# stays a separate decision; only the silence is fixed here.
test_a_lockless_python_project_is_named_rather_than_invisible() {
  local case_dir out fakebin report
  case_dir=$(new_case pyproject-only none)
  fakebin=$(case_fakebin "$case_dir")
  mkdir -p "$case_dir/wt/svc"
  printf '[project]\nname = "svc"\nversion = "0.1.0"\n' > "$case_dir/wt/svc/pyproject.toml"

  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'rc=0' "a lockless python project refused instead of launching: $out"
  assert_contains "$out" 'python:svc=skipped:no-python-lockfile' \
    "a python project declaring no lock or requirements file was not recorded: $out"
  assert_no_grep 'uv venv' "$case_dir/install.log" \
    "a lockless python project was installed from a guessed installer"
  report="$case_dir/wt/.fm-provisioning.md"
  assert_grep 'python in svc - NOT provisioned: no-python-lockfile' "$report" \
    "the lane's report does not name the python component it is not getting"

  # A uv workspace member declares exactly the same shape and IS installed, by
  # its root's --all-packages sync, so reporting it would bury the real gaps.
  mkdir -p "$case_dir/wt/mono/packages/alpha"
  printf 'version = 1\n' > "$case_dir/wt/mono/uv.lock"
  printf '[project]\nname = "mono"\n\n  [tool.uv.workspace]\nmembers = ["packages/*"]\n' \
    > "$case_dir/wt/mono/pyproject.toml"
  printf '[project]\nname = "alpha"\nversion = "1.0.0"\n' \
    > "$case_dir/wt/mono/packages/alpha/pyproject.toml"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'uv:mono=installed' "the uv workspace root was not provisioned: $out"
  assert_not_contains "$out" 'python:mono/packages/alpha' \
    "a uv workspace member its root already installs was reported as an unprovisioned gap: $out"
  pass "a python project with no committed lock or requirements file is named, not silently skipped"
}

# The lockless-Python decision reads a PROJECT-CONTROLLED file, so like every
# other such read in this library it runs under the bound. Without one, a
# pathological pyproject.toml could hold a spawn open indefinitely - and this
# check was added in the same round that bounded every sibling traversal, so it
# is exactly the gap that round was closing.
test_the_pyproject_declaration_read_is_bounded() {
  local case_dir out
  case_dir=$(new_case pyproject-bound none)
  mkdir -p "$case_dir/wt/svc" "$case_dir/bound-bin"
  printf '[project]\nname = "svc"\n' > "$case_dir/wt/svc/pyproject.toml"

  # A grep that never returns. If the read is bounded, the tri-state resolves to
  # "could not be determined" (2) and provisioning still answers; if it is not,
  # this case hangs and the suite's own timeout is the failure.
  printf '#!/usr/bin/env bash\nsleep 600\n' > "$case_dir/bound-bin/grep"
  chmod +x "$case_dir/bound-bin/grep"

  # shellcheck disable=SC2016  # the snippet is evaluated inside run_lib's own shell
  out=$(FM_TEST_SNIPPET='
    FM_PROVISION_BOUND_KIND=perl
    FM_PROVISION_PROBE_TIMEOUT=2
    fm_provision_python_project_declared "$FM_TEST_WT/svc"
    printf "rc=%s\n" "$?"
  ' run_lib PATH="$case_dir/bound-bin:/usr/bin:/bin" \
    FM_TEST_WT="$case_dir/wt")
  assert_contains "$out" 'rc=2' \
    "an unreadable-within-bound pyproject.toml did not resolve to the undetermined state: $out"
  pass "the pyproject declaration read is bounded and degrades to undetermined"
}

# The other side of that gap: a pyproject.toml carrying only tool configuration
# declares nothing to provision, so naming it would put a false line on the one
# surface this feature built for signal - and make a worktree that is in fact
# complete announce that it left a component UNPROVISIONED.
test_a_tool_configuration_pyproject_is_a_clean_noop() {
  local case_dir out fakebin
  case_dir=$(new_case pyproject-tool-config python)
  fakebin=$(case_fakebin "$case_dir")
  cat > "$case_dir/wt/pyproject.toml" <<'TOML'
[tool.ruff]
line-length = 100

[tool.black]
line-length = 100

[tool.pytest.ini_options]
addopts = "-ra"
TOML

  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'rc=0' "a tool-configuration pyproject.toml refused: $out"
  assert_contains "$out" 'pip:svc=installed' "the real python component was not provisioned: $out"
  assert_not_contains "$out" 'python:.=' \
    "a pyproject.toml holding only tool configuration was reported as a component: $out"
  assert_not_contains "$out" 'UNPROVISIONED' \
    "a fully provisioned worktree announced that it left something unprovisioned: $out"
  assert_no_grep '## not provisioned' "$case_dir/wt/.fm-provisioning.md" \
    "the lane's report opens a gap section for a directory with nothing to provision"

  # And the distinction holds: adding real packaging metadata to that same file
  # makes it a component again.
  printf '\n[project]\nname = "root"\nversion = "0.1.0"\n' >> "$case_dir/wt/pyproject.toml"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'python:.=skipped:no-python-lockfile' \
    "a pyproject.toml that declares a project was not reported as a lockless component: $out"
  pass "a pyproject.toml holding only tool configuration provisions nothing and reports nothing"
}

# `uv pip check` verifies that installed metadata is mutually consistent, which
# is not the same thing as usable: a project pinning through uv's
# override-dependencies or constraint-dependencies makes it inconsistent ON
# PURPOSE. Refusing there blocked every spawn into an environment that installs
# and runs fine, so it is reported instead - loudly, and where the lane reads.
test_an_inconsistent_environment_is_reported_rather_than_refused() {
  local case_dir out fakebin report
  case_dir=$(new_case pip-check-conflict python)
  fakebin=$(case_fakebin "$case_dir")
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" FM_TEST_UV_CHECK_FAIL=1)
  assert_contains "$out" 'rc=0' \
    "an environment uv pip check disagrees with refused the spawn: $out"
  assert_contains "$out" 'pip:svc=installed+inconsistent-dependency-metadata' \
    "what uv pip check reported was not recorded beside the component's state: $out"
  assert_contains "$out" 'uv pip check reports' \
    "the operator was not told what was reported about the environment: $out"
  [ -x "$case_dir/wt/svc/.venv/bin/python" ] \
    || fail "the environment was not provisioned: $out"
  assert_grep 'uv pip check reports' "$case_dir/provision.log" \
    "the reported inconsistency reached stderr but not the provisioning log"
  report="$case_dir/wt/.fm-provisioning.md"
  assert_grep 'pip in svc - installed, with one thing reported about it: inconsistent-dependency-metadata' \
    "$report" "the lane's report does not carry what was reported about its own environment"

  # A missing interpreter still means unusable, and still refuses.
  rm -f "$case_dir/wt/svc/.venv/bin/python"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" FM_TEST_UV_BREAK_PYTHON=1)
  assert_contains "$out" 'rc=1' "an install leaving no working interpreter did not refuse: $out"
  pass "a reported metadata inconsistency is recorded and launches; an unusable environment still refuses"
}

# --- library: the failure contract ------------------------------------------

test_a_failing_install_refuses_the_spawn() {
  local case_dir out fakebin
  case_dir=$(new_case install-fail js)
  fakebin=$(case_fakebin "$case_dir")
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" FM_TEST_NPM_FAIL=1)
  assert_contains "$out" 'rc=1' "a failing install did not refuse: $out"
  assert_contains "$out" 'the npm install in web exited 7' "the refusal did not name the component and exit code: $out"
  assert_contains "$out" 'could not run this project'"'"'s own checks' "the refusal did not state the consequence: $out"
  assert_contains "$out" '--no-provision' "the refusal did not name the opt-out: $out"
  [ ! -d "$case_dir/cache" ] || [ -z "$(ls -A "$case_dir/cache")" ] \
    || fail "a failed install still recorded a provisioning fingerprint"
  pass "a failing install refuses the spawn and records no fingerprint"
}

test_a_hung_install_is_bounded() {
  local case_dir out fakebin started elapsed
  case_dir=$(new_case install-hang js)
  fakebin=$(case_fakebin "$case_dir")
  started=$(date +%s)
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" \
    FM_TEST_NPM_SLEEP=60 FM_PROVISION_INSTALL_TIMEOUT=2)
  elapsed=$(( $(date +%s) - started ))
  assert_contains "$out" 'rc=1' "a hung install did not refuse: $out"
  assert_contains "$out" 'exceeded its 2s bound' "the refusal did not report the expired bound: $out"
  [ "$elapsed" -lt 30 ] || fail "a hung install was not bounded (took ${elapsed}s)"
  pass "an install that hangs is bounded and refuses instead of wedging the spawn"
}

test_a_signal_killed_install_refuses_the_spawn() {
  local case_dir out fakebin
  case_dir=$(new_case install-signal js)
  fakebin=$(case_fakebin "$case_dir")
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" \
    FM_TEST_PROVISION_BOUND_KIND=perl FM_TEST_NPM_SIGNAL=TERM)
  assert_contains "$out" 'rc=1' "a signal-killed install did not refuse: $out"
  assert_contains "$out" 'the npm install in web exited 143' \
    "a signal-killed install did not preserve its signal-derived status: $out"
  [ ! -d "$case_dir/cache" ] || [ -z "$(ls -A "$case_dir/cache")" ] \
    || fail "a signal-killed install still recorded a provisioning fingerprint"
  pass "a signal-killed bounded install is reported as a failure"
}

test_invalid_provisioning_tunables_refuse_before_detection() {
  local case_dir out fakebin setting name value
  case_dir=$(new_case invalid-tunables none)
  fakebin=$(case_fakebin "$case_dir")
  for setting in \
    FM_PROVISION_SCAN_DEPTH=0 \
    FM_PROVISION_MAX_COMPONENTS=invalid \
    FM_PROVISION_INSTALL_TIMEOUT=0 \
    FM_PROVISION_INSTALL_TIMEOUT= \
    FM_PROVISION_PROBE_TIMEOUT=invalid; do
    name=${setting%%=*}
    value=${setting#*=}
    out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" "$setting")
    assert_contains "$out" 'rc=1' "$name=$value did not refuse: $out"
    assert_contains "$out" "$name must be a positive integer, got '$value'" \
      "$name=$value refusal did not name the offending setting: $out"
  done
  [ ! -s "$case_dir/install.log" ] \
    || fail "invalid tunables still invoked an installer: $(cat "$case_dir/install.log")"
  pass "empty, zero, and nonnumeric provisioning tunables refuse before detection"
}

test_an_unreadable_subtree_refuses_instead_of_becoming_a_noop() {
  local case_dir out fakebin
  case_dir=$(new_case scan-failure none)
  fakebin=$(case_fakebin "$case_dir")
  mkdir -p "$case_dir/wt/private/component"
  printf 'six==1.16.0\n' > "$case_dir/wt/private/component/requirements.txt"
  chmod 000 "$case_dir/wt/private"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  chmod 700 "$case_dir/wt/private"
  assert_contains "$out" 'rc=1' "an unreadable subtree did not refuse: $out"
  assert_contains "$out" "cannot scan $case_dir/wt for dependency manifests" \
    "a traversal failure was mistaken for an undeclared-worktree no-op: $out"
  [ ! -s "$case_dir/install.log" ] \
    || fail "a traversal failure still invoked an installer: $(cat "$case_dir/install.log")"
  pass "a traversal failure is distinct from a successful undeclared-worktree no-op"
}

# Regression: dedup by exact element, never by pattern-matching a joined list.
# "app" is a substring token of "my app", so a substring dedup silently drops
# the "app" component while still reporting success.
test_a_directory_name_containing_another_is_not_deduped_away() {
  local case_dir out fakebin
  case_dir=$(new_case dedup-substring none)
  fakebin=$(case_fakebin "$case_dir")
  mkdir -p "$case_dir/wt/app" "$case_dir/wt/my app"
  printf 'six==1.16.0\n' > "$case_dir/wt/app/requirements.txt"
  printf '{"name":"myapp","private":true,"dependencies":{"is-number":"7.0.0"}}\n' \
    > "$case_dir/wt/my app/package.json"
  printf '{"lockfileVersion":3}\n' > "$case_dir/wt/my app/package-lock.json"

  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'rc=0' "provisioning two similarly named directories failed: $out"
  assert_contains "$out" 'pip:app=installed' \
    "the app component was deduped away by a directory whose name contains it: $out"
  assert_contains "$out" 'npm:my app=installed' \
    "the space-containing component was not provisioned: $out"
  [ -d "$case_dir/wt/app/.venv" ] \
    || fail "the app component was reported but never actually provisioned"
  [ -d "$case_dir/wt/my app/node_modules" ] \
    || fail "the space-containing component was reported but never actually provisioned"
  pass "a directory name containing another as a token is not deduped away"
}

# Regression: the perl child must exit when exec fails instead of falling
# through into the parent's tail, where a failed waitpid could report success.
test_a_bounded_call_to_a_missing_command_is_a_failure() {
  local out
  # shellcheck disable=SC2016  # the snippet is evaluated inside run_lib's own shell
  out=$(FM_TEST_SNIPPET='
    FM_PROVISION_BOUND_KIND=perl
    if captured=$(fm_provision_run_bounded 5 "$PWD" /nonexistent/fm-provision-probe arg); then
      printf "rc=0 out=[%s]\n" "$captured"
    else
      printf "rc=%s out=[%s]\n" "$?" "${captured:-}"
    fi
  ' run_lib)
  case "$out" in
    rc=0*) fail "a bounded call to a missing command reported success: $out" ;;
  esac
  assert_contains "$out" 'rc=127' \
    "a bounded call to a missing command did not report a command-not-found status: $out"
  assert_contains "$out" 'out=[]' \
    "a bounded call to a missing command produced output: $out"
  pass "a bounded call to a command that cannot be executed is a failure"
}

# Regression: a helper that exits 0 having captured nothing must refuse, not
# hand back the digest of the empty string as though it were a real signature.
test_an_environment_signature_that_captures_nothing_refuses() {
  local case_dir out fakebin empty_digest
  case_dir=$(new_case empty-signature js)
  fakebin=$(case_fakebin "$case_dir")
  mkdir -p "$case_dir/wt/web/node_modules"
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/python3"
  empty_digest=$(printf '' | shasum -a 256 | awk '{ print $1 }')
  # shellcheck disable=SC2016  # the snippet is evaluated inside run_lib's own shell
  out=$(FM_TEST_SNIPPET='
    FM_PROVISION_BOUND_KIND=perl
    if captured=$(fm_provision_environment_signature "$FM_TEST_WT" npm web); then
      printf "rc=0 sig=[%s]\n" "$captured"
    else
      printf "rc=%s sig=[%s]\n" "$?" "${captured:-}"
    fi
  ' run_lib PATH="$fakebin:/usr/bin:/bin" FM_TEST_WT="$case_dir/wt")
  case "$out" in
    rc=0*) fail "a signature that captured nothing reported success: $out" ;;
  esac
  case "$out" in
    *"$empty_digest"*)
      fail "a signature that captured nothing returned the empty-string digest: $out" ;;
  esac
  pass "an environment signature that captures nothing refuses instead of hashing nothing"
}

# --- library: capability gaps warn, record, and still launch ------------------
#
# A CAPABILITY GAP is work provisioning was never able to do here. Refusing one
# would be strictly worse than the behavior this library replaced, which
# launched every lane unprovisioned; it would also brick a spawn on the very
# monorepos this feature exists to serve. Each of these asserts the same three
# things: the spawn still succeeds, the gap is warned about, and it is recorded.

test_a_host_without_python3_launches_unprovisioned() {
  local case_dir out fakebin lean_path
  case_dir=$(new_case no-python3 both)
  fakebin=$(case_fakebin "$case_dir")
  lean_path=$(make_python3_free_path "$case_dir/nopy")
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" PATH="$fakebin:$lean_path")
  assert_contains "$out" 'rc=0' "a host without python3 refused instead of launching: $out"
  assert_contains "$out" 'summary=unavailable:no-python3' \
    "a host without python3 did not record the unprovisioned outcome: $out"
  assert_contains "$out" 'python3 is not installed' \
    "a host without python3 did not name the missing interpreter: $out"
  [ ! -s "$case_dir/install.log" ] \
    || fail "a host without python3 still invoked an installer: $(cat "$case_dir/install.log")"
  pass "a host without python3 warns and launches unprovisioned rather than refusing"
}

test_a_host_without_a_bounded_execution_mechanism_launches_unprovisioned() {
  local case_dir out fakebin
  case_dir=$(new_case no-bound both)
  fakebin=$(case_fakebin "$case_dir")
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" FM_TEST_PROVISION_BOUND_KIND=none)
  assert_contains "$out" 'rc=0' "a host that cannot bound an install refused instead of launching: $out"
  assert_contains "$out" 'summary=unavailable:no-bounded-execution' \
    "a host that cannot bound an install did not record the unprovisioned outcome: $out"
  [ ! -s "$case_dir/install.log" ] \
    || fail "a host that cannot bound an install still invoked one: $(cat "$case_dir/install.log")"
  pass "a host with no bounding mechanism runs nothing and launches unprovisioned"
}

test_a_missing_installer_leaves_that_component_unprovisioned() {
  local case_dir out empty_bin
  case_dir=$(new_case installer-missing python)
  empty_bin="$case_dir/empty-bin"
  mkdir -p "$empty_bin"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$empty_bin")
  assert_contains "$out" 'rc=0' "a missing installer refused instead of launching: $out"
  assert_contains "$out" 'pip:svc=skipped:missing-installer' \
    "a missing installer was not recorded against the component: $out"
  assert_contains "$out" 'never pip or venv' "the warning did not restate the uv-only python convention: $out"
  pass "a python project with no uv is left unprovisioned and reported, not refused"
}

test_an_unsupported_package_manager_leaves_that_component_unprovisioned() {
  local case_dir out fakebin
  case_dir=$(new_case unsupported none)
  fakebin=$(case_fakebin "$case_dir")
  mkdir -p "$case_dir/wt/app" "$case_dir/wt/svc"
  printf '# yarn lockfile v1\n' > "$case_dir/wt/app/yarn.lock"
  printf 'six==1.16.0\n' > "$case_dir/wt/svc/requirements.txt"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'rc=0' "an unsupported lockfile refused instead of launching: $out"
  assert_contains "$out" 'yarn:app=skipped:unsupported-manager' \
    "the unsupported manager was not recorded against the component: $out"
  assert_contains "$out" 'pip:svc=installed' \
    "one unsupported component stopped the components that could be provisioned: $out"
  assert_no_grep 'yarn' "$case_dir/install.log" "an unsupported package manager was invoked anyway"
  pass "a recognized but unsupported package manager is a recorded gap, not a refusal"
}

test_over_the_component_budget_provisions_what_it_can_and_reports_the_rest() {
  local case_dir out fakebin i
  case_dir=$(new_case too-many none)
  fakebin=$(case_fakebin "$case_dir")
  for i in 1 2 3; do
    mkdir -p "$case_dir/wt/pkg$i"
    printf 'six==1.16.0\n' > "$case_dir/wt/pkg$i/requirements.txt"
  done
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" FM_PROVISION_MAX_COMPONENTS=2)
  assert_contains "$out" 'rc=0' "an oversized component set refused instead of launching: $out"
  assert_contains "$out" 'pip:pkg1=installed' "the first in-budget component was not provisioned: $out"
  assert_contains "$out" 'pip:pkg2=installed' "the second in-budget component was not provisioned: $out"
  assert_contains "$out" 'pip:pkg3=skipped:over-budget' \
    "the over-budget component was not recorded: $out"
  assert_contains "$out" 'left 1 of 3 components UNPROVISIONED: pkg3' \
    "a partial provisioning did not NAME what it skipped: $out"
  assert_grep 'UNPROVISIONED: pkg3' "$case_dir/provision.log" \
    "the skipped component was named on stderr but not in the provisioning log"
  [ -d "$case_dir/wt/pkg1/.venv" ] && [ -d "$case_dir/wt/pkg2/.venv" ] \
    || fail "the in-budget components were reported but never actually provisioned"
  [ ! -d "$case_dir/wt/pkg3/.venv" ] || fail "the over-budget component was installed anyway"
  pass "a worktree over the component budget provisions what it can and reports what it skipped"
}

# The three firstmate-side surfaces (stderr, the provisioning log, provision=
# metadata) all live in the firstmate home, which the crewmate cannot read. The
# skip list has to reach the LANE, so provisioning writes it into the worktree
# the lane actually works in - and it must not dirty that checkout.
test_the_lane_can_read_what_provisioning_skipped() {
  local record id out status report dirty
  id=provision-spawn-p10
  record=$(make_spawn_case spawn-lane-report both "$id")
  read_spawn_case "$record"
  out=$(FM_PROVISION_MAX_COMPONENTS=1 run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "a partially provisioned spawn should launch: $out"
  report="$WORKTREE_DIR/.fm-provisioning.md"
  [ -f "$report" ] || fail "the lane got no in-worktree provisioning report: $out"
  assert_grep 'NOT provisioned' "$report" "the report does not tell the lane anything was skipped"
  assert_grep 'npm in web - NOT provisioned: over-budget' "$report" \
    "the report does not name the skipped component and its reason"
  assert_grep 'pip in svc - installed' "$report" \
    "the report does not tell the lane which component it DID get"
  dirty=$(git -C "$WORKTREE_DIR" status --porcelain --untracked-files=all)
  [ -z "$dirty" ] || fail "the lane-readable report dirtied the leased worktree: $dirty"
  pass "the crewmate can read, inside its own worktree, what provisioning skipped and why"
}

# A host capability gap provisions nothing at all, so the lane's only clue that
# every environment is missing by decision rather than by breakage is the report.
test_the_lane_can_read_an_unavailable_host_gap() {
  local case_dir out fakebin report
  case_dir=$(new_case lane-report-unavailable both)
  fakebin=$(case_fakebin "$case_dir")
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" FM_TEST_PROVISION_BOUND_KIND=none)
  assert_contains "$out" 'rc=0' "a host gap refused instead of launching: $out"
  report="$case_dir/wt/.fm-provisioning.md"
  [ -f "$report" ] || fail "a host capability gap left the lane no report: $out"
  assert_grep 'NOT provisioned: no-bounded-execution' "$report" \
    "the report does not name the host gap that left every component unprovisioned"
  assert_grep 'pip in svc' "$report" "the report does not name every component it skipped"
  assert_grep 'npm in web' "$report" "the report does not name every component it skipped"
  pass "a host capability gap is reported to the lane, not only to the operator"
}

# Whoever held the pool slot before had write access to the worktree, and the
# report path is git-excluded, so nothing in the cleanliness proof would notice
# a symlink planted there. Writing the report must replace that path, never
# follow it into a file outside the worktree.
test_a_symlinked_report_path_is_replaced_not_followed() {
  local case_dir out fakebin report victim
  case_dir=$(new_case lane-report-symlink both)
  fakebin=$(case_fakebin "$case_dir")
  victim="$case_dir/victim.txt"
  printf 'precious\n' > "$victim"
  report="$case_dir/wt/.fm-provisioning.md"
  ln -s "$victim" "$report"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" FM_TEST_PROVISION_BOUND_KIND=none)
  assert_contains "$out" 'rc=0' "a host gap refused instead of launching: $out"
  [ ! -L "$report" ] || fail "the report path is still a symlink, so the next write follows it too"
  [ -f "$report" ] || fail "no report was written in place of the symlink: $out"
  assert_grep 'NOT provisioned: no-bounded-execution' "$report" \
    "the replacement report does not carry this run's outcome"
  [ "$(cat "$victim")" = precious ] \
    || fail "the report was written THROUGH the symlink, truncating its target"
  pass "a symlink planted at the report path is replaced rather than written through"
}

# The budget must not be spent alphabetically. The task's own brief is the one
# path signal a spawn actually has, so a component the brief names is provisioned
# even when detection order would have pushed it past the budget.
test_the_component_budget_prefers_what_the_task_brief_names() {
  local case_dir out fakebin i
  case_dir=$(new_case budget-need none)
  fakebin=$(case_fakebin "$case_dir")
  for i in 1 2 3; do
    mkdir -p "$case_dir/wt/pkg$i"
    printf 'six==1.16.0\n' > "$case_dir/wt/pkg$i/requirements.txt"
  done
  printf 'Fix the flaky collection failure in pkg3 before shipping.\n' > "$case_dir/brief.md"

  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" \
    FM_PROVISION_MAX_COMPONENTS=1 FM_TEST_NEEDS="$case_dir/brief.md")
  assert_contains "$out" 'rc=0' "a needs-directed budget refused instead of launching: $out"
  assert_contains "$out" 'pip:pkg3=installed' \
    "the component the brief names was not the one provisioned: $out"
  assert_contains "$out" 'pip:pkg1=skipped:over-budget' \
    "an unmentioned component consumed the budget: $out"
  assert_contains "$out" 'pip:pkg2=skipped:over-budget' \
    "an unmentioned component consumed the budget: $out"
  [ -d "$case_dir/wt/pkg3/.venv" ] || fail "the needed component was reported but never provisioned"
  [ ! -d "$case_dir/wt/pkg1/.venv" ] || fail "an unmentioned component was installed over the budget"
  pass "the component budget is spent on what the task names before detection order"
}

# A fingerprint the library cannot stand behind must never become a cache hit: a
# declaration reaching past the traversal cap is left unprovisioned rather than
# fingerprinted over the prefix it managed to read.
test_a_requirements_graph_too_large_to_traverse_is_not_fingerprinted() {
  local case_dir out fakebin i next record
  case_dir=$(new_case pip-truncated none)
  fakebin=$(case_fakebin "$case_dir")
  mkdir -p "$case_dir/wt/svc"
  printf -- '-r req-1.txt\n' > "$case_dir/wt/svc/requirements.txt"
  i=1
  while [ "$i" -le 70 ]; do
    next=$((i + 1))
    if [ "$i" -eq 70 ]; then
      printf 'six==1.16.0\n' > "$case_dir/wt/svc/req-$i.txt"
    else
      printf -- '-r req-%s.txt\n' "$next" > "$case_dir/wt/svc/req-$i.txt"
    fi
    i=$next
  done

  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'rc=0' "an untraversable declaration refused instead of launching: $out"
  assert_contains "$out" 'pip:svc=skipped:unresolved-manifests' \
    "an untraversable declaration was not recorded as a capability gap: $out"
  assert_no_grep 'uv pip install' "$case_dir/install.log" \
    "a component whose declaration could not be traversed was installed anyway"
  for record in "$case_dir"/cache/*.record; do
    [ -e "$record" ] || continue
    fail "a component that could not be fingerprinted still recorded one: $record"
  done
  pass "a requirements graph past the traversal cap is a gap, never a fingerprint over a prefix"
}

test_a_js_package_manager_is_read_from_what_the_project_declares() {
  local case_dir out fakebin
  case_dir=$(new_case js-manager none)
  fakebin=$(case_fakebin "$case_dir")
  mkdir -p "$case_dir/wt/web"
  printf '{"name":"web","private":true,"dependencies":{"is-number":"7.0.0"}}\n' \
    > "$case_dir/wt/web/package.json"
  printf '{"lockfileVersion":3}\n' > "$case_dir/wt/web/package-lock.json"
  printf 'lockfileVersion: 9\n' > "$case_dir/wt/web/pnpm-lock.yaml"

  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'rc=0' "an undecidable JS component refused instead of launching: $out"
  assert_contains "$out" 'js:web=skipped:ambiguous-manager' \
    "a component carrying two lockfiles and declaring nothing was not recorded as a gap: $out"
  assert_no_grep 'pnpm install' "$case_dir/install.log" \
    "two committed lockfiles were resolved by filename precedence instead of by evidence"
  assert_no_grep 'npm ci' "$case_dir/install.log" \
    "two committed lockfiles were resolved by filename precedence instead of by evidence"

  # The declarative signal decides, and it is not the lockfile this library
  # would have preferred: package.json names npm while pnpm-lock.yaml is also
  # committed, exactly the shape that would install the wrong tree.
  printf '{"name":"web","private":true,"packageManager":"npm@10.9.2","dependencies":{"is-number":"7.0.0"}}\n' \
    > "$case_dir/wt/web/package.json"
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'npm:web=installed' "the declared package manager was not used: $out"
  assert_grep 'npm ci' "$case_dir/install.log" "the declared package manager did not install"
  assert_no_grep 'pnpm install' "$case_dir/install.log" \
    "a lockfile outvoted the package manager the project declares"
  pass "the JS package manager comes from what the project declares, not from lockfile precedence"
}

# --- library: detection is per-project, not hardcoded ------------------------

test_detection_is_declaration_driven_and_prunes_installed_trees() {
  local case_dir out
  case_dir=$(new_case detect both)
  # Nested already-installed trees must never be mistaken for components.
  mkdir -p "$case_dir/wt/web/node_modules/dep" "$case_dir/wt/svc/.venv/lib"
  printf '{"lockfileVersion":3}\n' > "$case_dir/wt/web/node_modules/dep/package-lock.json"
  printf 'six\n' > "$case_dir/wt/svc/.venv/lib/requirements.txt"
  # Two more declared stacks, one of them at the worktree root.
  mkdir -p "$case_dir/wt/tools"
  printf 'lockfileVersion: 9\n' > "$case_dir/wt/tools/pnpm-lock.yaml"
  printf '{"name":"tools"}\n' > "$case_dir/wt/tools/package.json"
  printf 'version = 1\n' > "$case_dir/wt/uv.lock"
  printf '[project]\nname = "root"\n' > "$case_dir/wt/pyproject.toml"

  out=$(PATH="/usr/bin:/bin" bash -c '
    set -u
    . "$1"
    fm_provision_detect "$2"
  ' _ "$LIB" "$case_dir/wt" | LC_ALL=C sort | tr '\n' '|')
  expect_code 0 $? "detection failed"
  assert_contains "$out" 'npm web|' "a package-lock.json component was not detected: $out"
  assert_contains "$out" 'pip svc|' "a requirements.txt component was not detected: $out"
  assert_contains "$out" 'pnpm tools|' "a pnpm-lock.yaml component was not detected: $out"
  assert_contains "$out" 'uv .|' "a uv.lock component at the worktree root was not detected: $out"
  assert_not_contains "$out" 'node_modules' "detection descended into an installed node_modules tree: $out"
  assert_not_contains "$out" '.venv' "detection descended into an installed virtualenv: $out"
  pass "detection is driven by what the worktree declares and skips installed trees"
}

test_a_uv_workspace_syncs_every_member() {
  local case_dir fakebin out
  case_dir=$(new_case uv-workspace none)
  fakebin=$(case_fakebin "$case_dir")
  mkdir -p "$case_dir/wt/mono/packages/alpha" "$case_dir/wt/solo"
  printf 'version = 1\n' > "$case_dir/wt/mono/uv.lock"
  printf '[project]\nname = "mono"\n\n  [tool.uv.workspace]\nmembers = ["packages/*"]\n' \
    > "$case_dir/wt/mono/pyproject.toml"
  printf 'version = 1\n' > "$case_dir/wt/solo/uv.lock"
  printf '[project]\nname = "solo"\n' > "$case_dir/wt/solo/pyproject.toml"

  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" \
    FM_TEST_REQUIRE_UV_DEFAULT_GROUPS=1 UV_NO_DEV=1 UV_ONLY_DEV=1 \
    UV_NO_DEFAULT_GROUPS=1 UV_NO_GROUP=dev UV_ONLY_GROUP=runtime)
  assert_contains "$out" 'rc=0' "uv provisioning failed: $out"
  # A workspace has one uv.lock and one .venv at its root, so a plain sync
  # would install only the root package and leave a member's checks unrunnable.
  assert_grep 'uv sync --frozen --all-packages' "$case_dir/install.log" \
    "a declared uv workspace was synced without its members"
  grep -qxF 'uv sync --frozen' "$case_dir/install.log" \
    || fail "a non-workspace uv project did not use the plain sync form"
  assert_no_grep ' --dev' "$case_dir/install.log" \
    "uv provisioning depended on the undocumented --dev alias"
  pass "a uv workspace syncs every member while a single project keeps the plain sync"
}

test_a_uv_workspace_member_manifest_invalidates_the_cache() {
  local case_dir fakebin out
  case_dir=$(new_case uv-workspace-manifest none)
  fakebin=$(case_fakebin "$case_dir")
  mkdir -p "$case_dir/wt/mono/packages/alpha"
  printf 'version = 1\n' > "$case_dir/wt/mono/uv.lock"
  printf '[project]\nname = "mono"\n\n  [tool.uv.workspace]\nmembers = ["packages/*"]\n' \
    > "$case_dir/wt/mono/pyproject.toml"
  printf '[project]\nname = "alpha"\nversion = "1.0.0"\n' \
    > "$case_dir/wt/mono/packages/alpha/pyproject.toml"
  printf '3.11\n' > "$case_dir/wt/mono/packages/alpha/.python-version"
  run_provision "$case_dir" "$case_dir/wt" "$fakebin" >/dev/null

  printf '[project]\nname = "alpha"\nversion = "1.0.1"\n' \
    > "$case_dir/wt/mono/packages/alpha/pyproject.toml"
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'uv:mono=installed' "a changed uv member manifest did not invalidate the cache: $out"
  assert_grep 'uv sync --frozen --all-packages' "$case_dir/install.log" \
    "a changed uv member manifest did not trigger a workspace reinstall"

  printf '3.12\n' > "$case_dir/wt/mono/packages/alpha/.python-version"
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'uv:mono=installed' "a changed uv member Python declaration did not invalidate the cache: $out"
  assert_grep 'uv sync --frozen --all-packages' "$case_dir/install.log" \
    "a changed uv member Python declaration did not trigger a workspace reinstall"
  pass "uv workspace member manifests participate in the cache fingerprint"
}

test_declared_node_version_is_read_only_when_unambiguous() {
  local case_dir probe
  case_dir=$(new_case node-declaration none)
  # shellcheck disable=SC2016  # the bash -c body expands its own positionals
  probe='
    set -u
    . "$1"
    printf "%s\n" "$(fm_provision_declared_node_major "$2")"
  '
  mkdir -p "$case_dir/nvmrc" "$case_dir/engines" "$case_dir/range" "$case_dir/silent"
  printf '20\n' > "$case_dir/nvmrc/.nvmrc"
  printf '{"engines":{"node":"^18.17.0"}}\n' > "$case_dir/engines/package.json"
  printf '{"engines":{"node":">=18 <21"}}\n' > "$case_dir/range/package.json"
  printf '{"name":"silent"}\n' > "$case_dir/silent/package.json"

  expect_equal() {
    local got want label
    got=$(PATH="/usr/bin:/bin" bash -c "$probe" _ "$LIB" "$1")
    want=$2
    label=$3
    [ "$got" = "$want" ] || fail "$label (got '$got', want '$want')"
  }
  expect_equal "$case_dir/nvmrc" 20 ".nvmrc was not read as an exact pin"
  expect_equal "$case_dir/engines" 18 "a caret engines pin was not reduced to its major"
  expect_equal "$case_dir/range" '' "a real engines range was treated as a pin"
  expect_equal "$case_dir/silent" '' "a package.json declaring no engine produced a pin"
  pass "a Node pin is read from what the project declares, and only when unambiguous"
}

test_a_declared_but_absent_node_runtime_leaves_js_unprovisioned() {
  local case_dir out fakebin
  case_dir=$(new_case node-absent both)
  fakebin=$(case_fakebin "$case_dir")
  printf '99\n' > "$case_dir/wt/web/.nvmrc"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" NVM_DIR="$case_dir/no-nvm" \
    FNM_DIR="$case_dir/no-fnm" VOLTA_HOME="$case_dir/no-volta" HOME="$case_dir/no-home")
  assert_contains "$out" 'rc=0' "an unsatisfiable Node pin refused instead of launching: $out"
  assert_contains "$out" 'npm:web=skipped:node-not-found' \
    "an unsatisfiable Node pin was not recorded against the component: $out"
  assert_contains "$out" 'pip:svc=installed' \
    "an unsatisfiable Node pin stopped the Python component that could be provisioned: $out"
  assert_no_grep 'npm ci' "$case_dir/install.log" \
    "an unsatisfiable Node pin still installed against the wrong runtime"
  pass "a declared Node runtime that cannot be found leaves the JS components unprovisioned"
}

test_a_declared_node_runtime_is_resolved_and_exported() {
  local case_dir out fakebin nvm_bin prefix
  case_dir=$(new_case node-pinned js)
  fakebin=$(case_fakebin "$case_dir")
  printf '20\n' > "$case_dir/wt/web/.nvmrc"
  # Two installed majors; the highest matching one must win, and the ambient
  # node (which reports 23) must lose to the declared pin.
  nvm_bin="$case_dir/nvm/versions/node/v20.20.2/bin"
  mkdir -p "$nvm_bin" "$case_dir/nvm/versions/node/v20.19.0/bin" "$case_dir/nvm/versions/node/v18.20.6/bin"
  cat > "$nvm_bin/node" <<'SH'
#!/usr/bin/env bash
printf '20.20.2'
SH
  chmod +x "$nvm_bin/node"
  cp "$nvm_bin/node" "$case_dir/nvm/versions/node/v20.19.0/bin/node"
  cp "$nvm_bin/node" "$case_dir/nvm/versions/node/v18.20.6/bin/node"

  # shellcheck disable=SC2016  # the bash -c body expands its own positionals
  out=$(env FM_TEST_INSTALL_LOG="$case_dir/install.log" FM_TEST_NODE_VERSION=23.8.0 \
    NVM_DIR="$case_dir/nvm" FNM_DIR="$case_dir/no-fnm" VOLTA_HOME="$case_dir/no-volta" \
    PATH="$fakebin:/usr/bin:/bin" \
    bash -c '
      set -u
      . "$1"
      fm_provision_worktree "$2" "$3" "$4" || exit 1
      printf "prefix=%s\n" "$FM_PROVISION_PATH_PREFIX"
    ' _ "$LIB" "$case_dir/wt" "$case_dir/cache" "$case_dir/provision.log" 2>&1)
  assert_contains "$out" 'pinning Node 20' "the pinned runtime was not surfaced: $out"
  prefix=${out##*prefix=}
  prefix=${prefix%%$'\n'*}
  [ -n "$prefix" ] || fail "the declared Node runtime was not exported for the lane: $out"
  [ "$(readlink "$prefix/node")" = "$nvm_bin/node" ] \
    || fail "the exported prefix does not resolve node to the highest installed match: $out"
  pass "a declared Node runtime is resolved to its highest installed match and exported for the lane"
}

# The PATH prefix must pin the Node toolchain WITHOUT reordering resolution for
# anything else. A version-manager bin directory also holds every globally
# npm-installed CLI for that Node version, and the harnesses this repo launches
# are commonly installed exactly that way, so leading with that directory would
# silently repoint the command the spawn is about to launch - a failure that
# would look like anything except a PATH bug.
test_a_node_pin_does_not_shadow_harness_binaries() {
  local case_dir fakebin nvm_bin host_bin prefix tool before after base_path
  case_dir=$(new_case node-pin-shadow js)
  fakebin=$(case_fakebin "$case_dir")
  printf '20\n' > "$case_dir/wt/web/.nvmrc"
  nvm_bin="$case_dir/nvm/versions/node/v20.20.2/bin"
  host_bin="$case_dir/host-bin"
  mkdir -p "$nvm_bin" "$host_bin"
  cat > "$nvm_bin/node" <<'SH'
#!/usr/bin/env bash
printf '20.20.2'
SH
  chmod +x "$nvm_bin/node"
  cp "$fakebin/npm" "$nvm_bin/npm"
  for tool in claude codex opencode pi grok; do
    printf '#!/usr/bin/env bash\nprintf pinned\n' > "$nvm_bin/$tool"
    printf '#!/usr/bin/env bash\nprintf host\n' > "$host_bin/$tool"
    chmod +x "$nvm_bin/$tool" "$host_bin/$tool"
  done
  base_path="$fakebin:$host_bin:/usr/bin:/bin"

  # shellcheck disable=SC2016  # the bash -c body expands its own positionals
  prefix=$(env FM_TEST_INSTALL_LOG="$case_dir/install.log" FM_TEST_NODE_VERSION=23.8.0 \
    NVM_DIR="$case_dir/nvm" FNM_DIR="$case_dir/no-fnm" VOLTA_HOME="$case_dir/no-volta" \
    PATH="$base_path" \
    bash -c '
      set -u
      . "$1"
      fm_provision_worktree "$2" "$3" "$4" >/dev/null 2>&1 || exit 1
      printf "%s" "$FM_PROVISION_PATH_PREFIX"
    ' _ "$LIB" "$case_dir/wt" "$case_dir/cache" "$case_dir/provision.log")
  [ -n "$prefix" ] || fail "provisioning did not export a pinned Node prefix"

  for tool in claude codex opencode pi grok; do
    # shellcheck disable=SC2016  # the bash -c body expands its own positionals
    before=$(env PATH="$base_path" bash -c 'command -v "$1"' _ "$tool")
    # shellcheck disable=SC2016  # the bash -c body expands its own positionals
    after=$(env PATH="$prefix:$base_path" bash -c 'command -v "$1"' _ "$tool")
    [ "$before" = "$after" ] \
      || fail "the Node pin repointed $tool from $before to $after"
    [ ! -e "$prefix/$tool" ] \
      || fail "the pinned-runtime PATH prefix carries the harness binary $tool"
  done

  # shellcheck disable=SC2016  # the bash -c body expands its own positionals
  for tool in node npm; do
    after=$(env PATH="$prefix:$base_path" bash -c 'command -v "$1"' _ "$tool")
    [ "$after" = "$prefix/$tool" ] \
      || fail "the Node pin did not win for $tool (resolved $after)"
    [ "$(readlink "$prefix/$tool")" = "$nvm_bin/$tool" ] \
      || fail "$tool in the pinned prefix does not point at the pinned runtime"
  done
  pass "a Node pin wins for the Node toolchain and changes resolution for nothing else"
}

# The pinned prefix is SHARED - one directory per pinned runtime per home - and a
# launched lane keeps it first on its PATH for the lane's whole life. A spawn
# that rebuilt it in place would unlink a running crewmate's `node` mid-run,
# which surfaces as `command not found` with nothing pointing at provisioning.
# This holds lane A's resolved prefix and watches it CONTINUOUSLY while a second
# spawn provisions the same pin, so the assertion covers the window rather than
# only the end state.
test_a_pinned_node_prefix_is_never_rebuilt_under_a_running_lane() {
  local case_dir fakebin nvm_bin prefix_a link_before link_after ident_before ident_after
  local watcher_pid base_path out leftover
  case_dir=$(new_case node-pin-race js)
  fakebin=$(case_fakebin "$case_dir")
  make_worktree "$case_dir/wt-b" js
  printf '20\n' > "$case_dir/wt/web/.nvmrc"
  printf '20\n' > "$case_dir/wt-b/web/.nvmrc"
  nvm_bin="$case_dir/nvm/versions/node/v20.20.2/bin"
  mkdir -p "$nvm_bin"
  cat > "$nvm_bin/node" <<'SH'
#!/usr/bin/env bash
printf '20.20.2'
SH
  chmod +x "$nvm_bin/node"
  cp "$fakebin/npm" "$nvm_bin/npm"
  base_path="$fakebin:/usr/bin:/bin"

  # shellcheck disable=SC2016  # the bash -c body expands its own positionals
  prefix_a=$(env FM_TEST_INSTALL_LOG="$case_dir/install.log" FM_TEST_NODE_VERSION=23.8.0 \
    NVM_DIR="$case_dir/nvm" FNM_DIR="$case_dir/no-fnm" VOLTA_HOME="$case_dir/no-volta" \
    PATH="$base_path" \
    bash -c '
      set -u
      . "$1"
      fm_provision_worktree "$2" "$3" "$4" >/dev/null 2>&1 || exit 1
      printf "%s" "$FM_PROVISION_PATH_PREFIX"
    ' _ "$LIB" "$case_dir/wt" "$case_dir/cache" "$case_dir/provision.log")
  [ -n "$prefix_a" ] || fail "the first spawn did not publish a pinned Node prefix"
  link_before=$(readlink "$prefix_a/node")
  ident_before=$(python3 -c 'import os,sys; s=os.lstat(sys.argv[1]); print("%d:%d" % (s.st_dev, s.st_ino))' "$prefix_a/node")

  : > "$case_dir/misses"
  rm -f "$case_dir/watcher.stop"
  (
    while [ ! -f "$case_dir/watcher.stop" ]; do
      if [ ! -x "$prefix_a/node" ]; then
        printf 'the pinned prefix had no executable node\n' >> "$case_dir/misses"
      fi
      # shellcheck disable=SC2016  # the bash -c body expands its own positionals
      resolved=$(env PATH="$prefix_a:$base_path" bash -c 'command -v node' 2>/dev/null) || resolved=
      if [ "$resolved" != "$prefix_a/node" ]; then
        printf 'node resolved to %s\n' "${resolved:-<nothing>}" >> "$case_dir/misses"
      fi
    done
  ) &
  watcher_pid=$!

  # shellcheck disable=SC2016  # the bash -c body expands its own positionals
  out=$(env FM_TEST_INSTALL_LOG="$case_dir/install.log" FM_TEST_NODE_VERSION=23.8.0 \
    NVM_DIR="$case_dir/nvm" FNM_DIR="$case_dir/no-fnm" VOLTA_HOME="$case_dir/no-volta" \
    PATH="$base_path" \
    bash -c '
      set -u
      . "$1"
      fm_provision_worktree "$2" "$3" "$4" || exit 1
      printf "prefix=%s\n" "$FM_PROVISION_PATH_PREFIX"
    ' _ "$LIB" "$case_dir/wt-b" "$case_dir/cache" "$case_dir/provision-b.log" 2>&1)
  : > "$case_dir/watcher.stop"
  wait "$watcher_pid"

  assert_contains "$out" "prefix=$prefix_a" \
    "the second spawn did not resolve to the same shared pinned prefix: $out"
  [ ! -s "$case_dir/misses" ] \
    || fail "a running lane observed its pinned node disappear while a second spawn provisioned: $(cat "$case_dir/misses")"
  link_after=$(readlink "$prefix_a/node")
  ident_after=$(python3 -c 'import os,sys; s=os.lstat(sys.argv[1]); print("%d:%d" % (s.st_dev, s.st_ino))' "$prefix_a/node")
  [ "$link_after" = "$link_before" ] \
    || fail "the shared pinned prefix was repointed under a running lane ($link_before -> $link_after)"
  [ "$ident_after" = "$ident_before" ] \
    || fail "the shared pinned prefix's node was unlinked and recreated under a running lane"
  for leftover in "$prefix_a"/*; do
    [ -e "$leftover" ] || continue
    case "${leftover##*/}" in
      node|npm|npx|corepack) ;;
      *) fail "a losing spawn nested its own build inside the published prefix: $leftover" ;;
    esac
  done
  pass "a shared pinned Node prefix is published once and never rebuilt under a running lane"
}

# The publish must be a single atomic claim, not a guard followed by a rename.
# Two spawns that both find the prefix absent must not nest one build inside the
# other's published directory: the loser has to validate and reuse the winner's.
test_a_lost_prefix_publish_race_reuses_the_winner() {
  local case_dir fakebin nvm_bin prefix entry racer
  case_dir=$(new_case node-pin-publish-race js)
  fakebin=$(case_fakebin "$case_dir")
  nvm_bin="$case_dir/nvm/versions/node/v20.20.2/bin"
  mkdir -p "$nvm_bin"
  cat > "$nvm_bin/node" <<'SH'
#!/usr/bin/env bash
printf '20.20.2'
SH
  chmod +x "$nvm_bin/node"
  cp "$fakebin/npm" "$nvm_bin/npm"

  # Both calls start before either has published, so one of them is genuinely the
  # loser of the publish race. Every assertion below holds whichever one wins.
  publish_prefix() {
    # shellcheck disable=SC2016  # the bash -c body expands its own positionals
    env PATH="$fakebin:/usr/bin:/bin" bash -c '
        set -u
        . "$1"
        fm_provision_node_path_prefix "$2" "$3"
      ' _ "$LIB" "$case_dir/cache" "$nvm_bin" > "$1" 2>/dev/null
  }
  publish_prefix "$case_dir/prefix-a" &
  racer=$!
  publish_prefix "$case_dir/prefix-b"
  wait "$racer"

  for prefix in "$(cat "$case_dir/prefix-a")" "$(cat "$case_dir/prefix-b")"; do
    [ -n "$prefix" ] || fail "a racing publish produced no prefix"
    [ "$(readlink "$prefix/node")" = "$nvm_bin/node" ] \
      || fail "a racing publish returned a prefix not pointing at the pinned runtime: $prefix"
    [ "$(readlink "$prefix/npm")" = "$nvm_bin/npm" ] \
      || fail "a racing publish returned an incomplete prefix: $prefix"
  done
  for prefix in "$case_dir"/cache/node-toolchain/*; do
    [ -e "$prefix" ] || continue
    for entry in "$prefix"/*; do
      [ -e "$entry" ] || continue
      [ ! -d "$entry" ] \
        || fail "a losing publish nested its build inside a published prefix: $entry"
    done
  done
  pass "concurrent publishes each return a complete prefix and never nest one inside the other"
}

# Immutability must not become a permanent brick. A published prefix that stops
# validating is stepped over, never rewritten, so a lane still holding the stale
# directory keeps what it has while the next spawn gets a working prefix.
test_a_stale_pinned_prefix_is_stepped_over_not_rewritten() {
  local case_dir fakebin nvm_bin first second stale_link
  case_dir=$(new_case node-pin-stale js)
  fakebin=$(case_fakebin "$case_dir")
  nvm_bin="$case_dir/nvm/versions/node/v20.20.2/bin"
  mkdir -p "$nvm_bin"
  cat > "$nvm_bin/node" <<'SH'
#!/usr/bin/env bash
printf '20.20.2'
SH
  chmod +x "$nvm_bin/node"
  cp "$fakebin/npm" "$nvm_bin/npm"

  # shellcheck disable=SC2016  # the bash -c body expands its own positionals
  first=$(env PATH="$fakebin:/usr/bin:/bin" bash -c '
      set -u
      . "$1"
      fm_provision_node_path_prefix "$2" "$3"
    ' _ "$LIB" "$case_dir/cache" "$nvm_bin")
  [ -n "$first" ] || fail "the first publish produced no prefix"

  # Something outside this code breaks the published prefix.
  rm -f "$first/npm"
  printf 'not-a-symlink\n' > "$first/stale-marker"

  # shellcheck disable=SC2016  # the bash -c body expands its own positionals
  second=$(env PATH="$fakebin:/usr/bin:/bin" bash -c '
      set -u
      . "$1"
      fm_provision_node_path_prefix "$2" "$3"
    ' _ "$LIB" "$case_dir/cache" "$nvm_bin")
  [ -n "$second" ] || fail "a stale published prefix bricked every later spawn"
  [ "$second" != "$first" ] || fail "the stale prefix was rewritten in place instead of stepped over"
  [ -f "$first/stale-marker" ] \
    || fail "the stale prefix was mutated, which a lane still holding it would observe"
  stale_link=$(readlink "$first/node")
  [ "$stale_link" = "$nvm_bin/node" ] \
    || fail "the stale prefix's surviving entries were disturbed"
  [ "$(readlink "$second/node")" = "$nvm_bin/node" ] \
    || fail "the replacement prefix does not point at the pinned runtime"
  [ "$(readlink "$second/npm")" = "$nvm_bin/npm" ] \
    || fail "the replacement prefix is missing the entry the stale one lost"
  pass "a published prefix that stops validating is stepped over, leaving the stale one untouched"
}

# --- fm-spawn.sh integration ------------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(make_installer_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  has-session|display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_TEST_INSTALL_LOG:-}" ]; then
      printf 'LAUNCH %s\n' "$*" >> "$FM_TEST_INSTALL_LOG"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = get ]; then
  printf '%s\n' "${FM_FAKE_TREEHOUSE_WORKTREE:?}"
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# <name> <shape> <id> [ignore-mode]
#
# ignore-mode defaults to "ignored": the project commits a .gitignore covering
# the install directories, which is what a real project does and is now the
# precondition for provisioning at all - firstmate refuses rather than writing an
# exclusion, because the only exclusion that would work is one in the MAIN
# clone's info/exclude. Pass "unignored" for the refusal case.
make_spawn_case() {
  local name=$1 shape=$2 id=$3 ignore_mode=${4:-ignored} case_dir home project worktree fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$home/treehouse-pools"
  printf '%s\n' codex > "$home/config/crew-harness"
  printf '%s\n' manual > "$home/config/backlog-backend"
  # Dependency manifests are TRACKED project files, so they must be committed
  # before the worktree is cut: an acquired worktree carrying uncommitted files
  # fails the cleanliness proof long before provisioning is reached.
  fm_git_init_commit "$project"
  make_worktree "$project" "$shape"
  if [ "$ignore_mode" = ignored ]; then
    printf '.venv/\nnode_modules/\n.fm-provisioning.md\n' > "$project/.gitignore"
  fi
  git -C "$project" add -A
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'project manifests'
  git -C "$project" worktree add --quiet --detach "$worktree"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '# Backlog\n\n## In flight\n- [ ] %s - provisioning test (repo: project)\n\n## Queued\n\n## Done\n' \
    "$id" > "$home/data/backlog.md"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  : > "$case_dir/install.log"
  printf '%s\n' "$case_dir|$home|$project|$worktree|$fakebin"
}

read_spawn_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local case_dir=$1 home=$2 worktree=$3 fakebin=$4
  shift 4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TREEHOUSE_ROOT="$home/treehouse-pools" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$home/checkout-refresh-state" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$worktree" TMUX="fake,1,0" \
    FM_FAKE_TREEHOUSE_WORKTREE="$worktree" \
    FM_TEST_INSTALL_LOG="$case_dir/install.log" \
    PATH="$fakebin:$PATH" "$SPAWN" "$@" 2>&1
}

test_spawn_provisions_the_worktree_before_creating_the_endpoint() {
  local record id out status order
  id=provision-spawn-p1
  record=$(make_spawn_case spawn-ok both "$id")
  read_spawn_case "$record"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "a spawn into a provisionable worktree should succeed: $out"
  assert_contains "$out" "spawned $id" "the spawn did not reach endpoint creation: $out"
  assert_grep 'npm ci' "$CASE_DIR/install.log" "the spawn did not provision the js component"
  assert_grep 'uv pip install' "$CASE_DIR/install.log" "the spawn did not provision the python component"
  assert_grep 'provision=pip:svc=installed,npm:web=installed' "$HOME_DIR/state/$id.meta" \
    "the spawn did not record its provisioning outcome in task metadata"
  # Ordering is the contract: a lane must never be launched into a worktree
  # whose dependencies are still installing.
  order=$(grep -n -m1 -e 'npm ci' -e 'LAUNCH' "$CASE_DIR/install.log" | cut -d: -f2-)
  case "$order" in
    LAUNCH*) fail "the endpoint was launched before provisioning ran" ;;
  esac
  [ -f "$HOME_DIR/state/$id.provision.log" ] || fail "the spawn wrote no provisioning log"
  pass "a spawn provisions its worktree after verification and before endpoint creation"
}

test_spawn_refuses_when_provisioning_fails() {
  local record id out status
  id=provision-spawn-p2
  record=$(make_spawn_case spawn-fail js "$id")
  read_spawn_case "$record"
  out=$(FM_TEST_NPM_FAIL=1 run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "a spawn whose provisioning failed should be refused: $out"
  assert_contains "$out" 'worktree provisioning failed' "the spawn did not report the provisioning failure: $out"
  assert_not_contains "$out" "spawned $id" "a spawn with failed provisioning still reported success: $out"
  assert_no_grep 'LAUNCH' "$CASE_DIR/install.log" "a lane was launched into an unprovisioned worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn wrote task metadata"
  assert_contains "$out" 'npm ci exploded' \
    "the refusal did not surface the installer output it is the only remaining copy of: $out"
  assert_absent "$HOME_DIR/state/$id.provision.log" \
    "a refused spawn left its provisioning log behind in the home's state directory"
  pass "provisioning failure refuses the spawn instead of launching a lane that cannot validate"
}

test_spawn_over_the_component_budget_still_launches() {
  local record id out status
  id=provision-spawn-p9
  record=$(make_spawn_case spawn-over-budget both "$id")
  read_spawn_case "$record"
  out=$(FM_PROVISION_MAX_COMPONENTS=1 run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "a worktree over the component budget should still spawn: $out"
  assert_contains "$out" "spawned $id" "an over-budget worktree did not reach endpoint creation: $out"
  assert_contains "$out" 'unprovisioned' "the over-budget component was not warned about: $out"
  assert_grep 'provision=pip:svc=installed,npm:web=skipped:over-budget' "$HOME_DIR/state/$id.meta" \
    "the partial provisioning outcome was not recorded in task metadata"
  assert_grep 'UNPROVISIONED: web' "$HOME_DIR/state/$id.provision.log" \
    "the skipped component was not named in the provisioning log the lane can read"
  assert_grep 'uv pip install' "$CASE_DIR/install.log" "the in-budget component was not provisioned"
  assert_no_grep 'npm ci' "$CASE_DIR/install.log" "the over-budget component was installed anyway"
  pass "a worktree over the component budget launches, warns, and records what it skipped"
}

# The provisioning log is a per-task state artifact; teardown owns removing it
# alongside the rest of the set, and this asserts the two lists cannot drift.
test_teardown_removes_the_provisioning_log_with_the_task_state() {
  local missing
  missing=$(grep -n 'rm -f .*grok-turnend-token' "$ROOT/bin/fm-teardown.sh" \
    | grep -v 'provision\.log' || true)
  [ -z "$missing" ] \
    || fail "a teardown per-task state removal omits the provisioning log: $missing"
  pass "teardown removes the provisioning log with the rest of the per-task state"
}

test_spawn_failure_excludes_every_mutated_component() {
  local record id out status exclude_file dirty
  id=provision-spawn-p7
  record=$(make_spawn_case spawn-multi-fail both "$id")
  read_spawn_case "$record"
  out=$(FM_TEST_NPM_FAIL=1 run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "a later component failure should refuse the spawn: $out"
  assert_grep 'uv pip install' "$CASE_DIR/install.log" "the earlier Python component did not install before the Node failure"
  assert_grep 'npm ci' "$CASE_DIR/install.log" "the later Node component did not reach its failing installer"
  # The property that matters is the worktree still being returnable, and it now
  # holds because the PROJECT ignores these paths - not because provisioning wrote
  # anything. Assert the outcome, and assert the primary clone was left alone:
  # `--git-path info/exclude` from a linked worktree resolves to the MAIN clone,
  # so a write there would make the path invisible to `git status` in the
  # captain's own checkout, and repeatedly hiding install trees in a shared
  # checkout is how work stops being visible at all.
  dirty=$(git -C "$WORKTREE_DIR" status --porcelain --untracked-files=all)
  [ -z "$dirty" ] || fail "a multi-component provisioning failure left the leased worktree dirty: $dirty"
  exclude_file=$(git -C "$WORKTREE_DIR" rev-parse --git-path info/exclude)
  assert_no_grep '\.venv' "$exclude_file" \
    "provisioning wrote a Python install path into the main clone's info/exclude"
  assert_no_grep 'node_modules' "$exclude_file" \
    "provisioning wrote a Node install path into the main clone's info/exclude"
  pass "a later provisioning failure leaves the worktree clean without writing to the main clone"
}

# Provisioning refuses rather than hiding. It cannot make an unignored install
# directory invisible to only this worktree: git ignores a linked worktree's own
# info/exclude, and `--git-path info/exclude` resolves to the MAIN clone, so the
# only working write is one that changes the captain's primary checkout
# repo-wide. Installing anyway would leave the worktree untracked-dirty, fail its
# returnable check on abort, and strand the pool lease - the condition that
# hard-blocks the fleet once every workspace is held.
test_spawn_refuses_before_install_when_the_project_does_not_ignore_the_install_dir() {
  local record id out status exclude_file
  id=provision-spawn-p8
  record=$(make_spawn_case spawn-exclude-fail both "$id" unignored)
  read_spawn_case "$record"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "an unignored install directory should refuse the spawn: $out"
  assert_contains "$out" 'does not ignore' \
    "the refusal did not identify the unignored install directory: $out"
  assert_contains "$out" '.gitignore' \
    "the refusal did not tell the operator how to fix it: $out"
  [ ! -s "$CASE_DIR/install.log" ] \
    || fail "an installer ran despite an unprotected dependency directory: $(cat "$CASE_DIR/install.log")"
  assert_not_contains "$out" "spawned $id" "a spawn with an unprotected dependency directory still succeeded: $out"
  exclude_file=$(git -C "$WORKTREE_DIR" rev-parse --git-path info/exclude)
  assert_no_grep '\.venv' "$exclude_file" \
    "the refusal still wrote a Python install path into the main clone's info/exclude"
  assert_no_grep 'node_modules' "$exclude_file" \
    "the refusal still wrote a Node install path into the main clone's info/exclude"
  pass "an unignored install directory refuses before any installer runs, and never writes to the main clone"
}

test_provisioning_can_be_opted_out_per_spawn_and_per_home() {
  local record id out status
  id=provision-spawn-p3
  record=$(make_spawn_case spawn-flag-off both "$id")
  read_spawn_case "$record"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" --no-provision)
  status=$?
  expect_code 0 "$status" "--no-provision should still spawn: $out"
  assert_no_grep 'npm ci' "$CASE_DIR/install.log" "--no-provision still installed dependencies"
  assert_grep 'provision=off' "$HOME_DIR/state/$id.meta" "--no-provision was not recorded in task metadata"

  id=provision-spawn-p4
  record=$(make_spawn_case spawn-config-off both "$id")
  read_spawn_case "$record"
  printf 'off\n' > "$HOME_DIR/config/worktree-provision"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "config/worktree-provision=off should still spawn: $out"
  assert_no_grep 'npm ci' "$CASE_DIR/install.log" "config/worktree-provision=off still installed dependencies"
  assert_grep 'provision=off' "$HOME_DIR/state/$id.meta" "the home opt-out was not recorded in task metadata"
  pass "provisioning is opt-out per spawn and per home, and the choice is recorded"
}

# A pool slot outlives the lease that used it: the report is git-excluded, so no
# cleanliness proof sees it and neither teardown nor `treehouse return` removes
# it. The leases that provision nothing - both opt-outs, and a worktree that
# declares nothing - are exactly the ones that would otherwise inherit the
# previous task's report and read it as a description of their own worktree.
test_a_stale_lane_report_never_survives_into_the_next_lease() {
  local record id out status report exclude_file case_dir fakebin
  plant_stale_report() {  # <worktree>
    printf '# firstmate worktree provisioning\n\nfirstmate provisioned this worktree (%s) before launching this lane.\n\n## provisioned\n\n- npm in web - installed\n' \
      "$1" > "$1/.fm-provisioning.md"
  }

  id=provision-spawn-p11
  record=$(make_spawn_case spawn-stale-flag-off both "$id")
  read_spawn_case "$record"
  # Excluded exactly as a previous lease's provisioning would have left it,
  # so the stale report is invisible to the worktree cleanliness proof.
  exclude_file=$(git -C "$WORKTREE_DIR" rev-parse --git-path info/exclude)
  printf '/.fm-provisioning.md\n' >> "$exclude_file"
  plant_stale_report "$WORKTREE_DIR"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" --no-provision)
  status=$?
  expect_code 0 "$status" "--no-provision should still spawn: $out"
  assert_absent "$WORKTREE_DIR/.fm-provisioning.md" \
    "a --no-provision lease inherited the previous task's provisioning report"

  id=provision-spawn-p12
  record=$(make_spawn_case spawn-stale-config-off both "$id")
  read_spawn_case "$record"
  exclude_file=$(git -C "$WORKTREE_DIR" rev-parse --git-path info/exclude)
  printf '/.fm-provisioning.md\n' >> "$exclude_file"
  plant_stale_report "$WORKTREE_DIR"
  printf 'off\n' > "$HOME_DIR/config/worktree-provision"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "config/worktree-provision=off should still spawn: $out"
  assert_absent "$WORKTREE_DIR/.fm-provisioning.md" \
    "a home-level opt-out lease inherited the previous task's provisioning report"

  # The library's own no-op return, reached before any report would be written.
  case_dir=$(new_case stale-report-noop none)
  fakebin=$(case_fakebin "$case_dir")
  report="$case_dir/wt/.fm-provisioning.md"
  plant_stale_report "$case_dir/wt"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'rc=0' "a worktree declaring nothing refused: $out"
  assert_absent "$report" "a worktree declaring nothing kept a previous lease's report"

  unset -f plant_stale_report
  pass "a lease that provisions nothing clears the previous task's report instead of inheriting it"
}

test_an_unreadable_provisioning_setting_refuses_the_spawn() {
  local record id out status
  id=provision-spawn-p5
  record=$(make_spawn_case spawn-config-bad js "$id")
  read_spawn_case "$record"
  printf 'maybe\n' > "$HOME_DIR/config/worktree-provision"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "an invalid provisioning setting should refuse: $out"
  assert_contains "$out" "config/worktree-provision must contain exactly 'on' or 'off'" \
    "the refusal did not name the invalid setting: $out"
  pass "an unparseable provisioning setting refuses rather than silently disabling the gate"
}

test_spawn_into_an_undeclared_project_is_unchanged() {
  local record id out status
  id=provision-spawn-p6
  record=$(make_spawn_case spawn-noop none "$id")
  read_spawn_case "$record"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "a spawn into a project declaring no dependencies should succeed: $out"
  assert_contains "$out" "spawned $id" "the spawn did not reach endpoint creation: $out"
  assert_grep 'provision=none' "$HOME_DIR/state/$id.meta" "a no-op provisioning was not recorded"
  pass "a project declaring no recognized manifest spawns exactly as before"
}

test_worktree_declaring_nothing_is_a_clean_noop
test_first_spawn_installs_and_second_reuses_the_cache
test_a_changed_manifest_invalidates_the_cache
test_changed_installer_configuration_invalidates_the_cache
test_a_removed_environment_invalidates_a_matching_fingerprint
test_node_installs_include_validation_dependencies
test_a_replaced_interpreter_invalidates_the_cache
test_pip_requirement_directives_do_not_force_a_reinstall_every_spawn
test_lane_build_output_in_node_modules_is_not_a_cache_miss
test_an_unreadable_manifest_refuses_instead_of_hashing_nothing
test_a_component_below_the_scan_depth_is_reported_not_dropped
test_a_scan_that_outlives_its_bound_launches_unprovisioned
test_a_check_that_could_not_run_is_never_reported_as_a_verdict
test_a_lockless_python_project_is_named_rather_than_invisible
test_the_pyproject_declaration_read_is_bounded
test_a_tool_configuration_pyproject_is_a_clean_noop
test_an_inconsistent_environment_is_reported_rather_than_refused
test_a_failing_install_refuses_the_spawn
test_a_hung_install_is_bounded
test_a_signal_killed_install_refuses_the_spawn
test_invalid_provisioning_tunables_refuse_before_detection
test_an_unreadable_subtree_refuses_instead_of_becoming_a_noop
test_a_directory_name_containing_another_is_not_deduped_away
test_a_bounded_call_to_a_missing_command_is_a_failure
test_an_environment_signature_that_captures_nothing_refuses
test_a_host_without_python3_launches_unprovisioned
test_a_host_without_a_bounded_execution_mechanism_launches_unprovisioned
test_a_missing_installer_leaves_that_component_unprovisioned
test_an_unsupported_package_manager_leaves_that_component_unprovisioned
test_over_the_component_budget_provisions_what_it_can_and_reports_the_rest
test_the_component_budget_prefers_what_the_task_brief_names
test_the_lane_can_read_an_unavailable_host_gap
test_a_symlinked_report_path_is_replaced_not_followed
test_a_requirements_graph_too_large_to_traverse_is_not_fingerprinted
test_a_js_package_manager_is_read_from_what_the_project_declares
test_detection_is_declaration_driven_and_prunes_installed_trees
test_a_uv_workspace_syncs_every_member
test_a_uv_workspace_member_manifest_invalidates_the_cache
test_declared_node_version_is_read_only_when_unambiguous
test_a_declared_but_absent_node_runtime_leaves_js_unprovisioned
test_a_declared_node_runtime_is_resolved_and_exported
test_a_node_pin_does_not_shadow_harness_binaries
test_a_pinned_node_prefix_is_never_rebuilt_under_a_running_lane
test_a_lost_prefix_publish_race_reuses_the_winner
test_a_stale_pinned_prefix_is_stepped_over_not_rewritten
test_spawn_provisions_the_worktree_before_creating_the_endpoint
test_spawn_refuses_when_provisioning_fails
test_spawn_over_the_component_budget_still_launches
test_the_lane_can_read_what_provisioning_skipped
test_teardown_removes_the_provisioning_log_with_the_task_state
test_spawn_failure_excludes_every_mutated_component
test_spawn_refuses_before_install_when_the_project_does_not_ignore_the_install_dir
test_provisioning_can_be_opted_out_per_spawn_and_per_home
test_a_stale_lane_report_never_survives_into_the_next_lease
test_an_unreadable_provisioning_setting_refuses_the_spawn
test_spawn_into_an_undeclared_project_is_unchanged

echo "# all fm-spawn-provision tests passed"
