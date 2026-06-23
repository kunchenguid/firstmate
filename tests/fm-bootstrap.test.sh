#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}

trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-bootstrap-tests.XXXXXX")

make_fake_toolchain() {
  local dir=$1 fakebin tool
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  for tool in tmux node no-mistakes gh-axi chrome-devtools-axi lavish-axi; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  if [ "${FM_FAKE_TREEHOUSE_LEASE_HELP:-}" = 1 ]; then
    printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  else
    printf '%s\n' 'Usage: treehouse get'
  fi
  exit 0
fi
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_TREEHOUSE_VERSION:-v1.8.0}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

run_bootstrap() {
  local home=$1 fakebin=$2
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-}" FM_HOME="$home" XDG_CONFIG_HOME="$home/xdg" "$ROOT/bin/fm-bootstrap.sh"
}

install_bootstrap_tool() {
  local home=$1 fakebin=$2 tool=$3
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-}" FM_HOME="$home" XDG_CONFIG_HOME="$home/xdg" "$ROOT/bin/fm-bootstrap.sh" install "$tool"
}

write_treehouse_hook_config() {
  local home=$1 root=${2:-$ROOT}
  mkdir -p "$home/xdg/treehouse"
  printf '[hooks]\npost_create = ["%s/bin/fm-treehouse-post-create.sh"]\n' "$root" >"$home/xdg/treehouse/config.toml"
}

write_treehouse_quoted_hook_config() {
  local home=$1 root=${2:-$ROOT}
  mkdir -p "$home/xdg/treehouse"
  printf '[hooks]\npost_create = ["'\''%s/bin/fm-treehouse-post-create.sh'\''"]\n' "$root" >"$home/xdg/treehouse/config.toml"
}

test_bootstrap_accepts_treehouse_lease_and_hook_support() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/lease-supported"
  mkdir -p "$case_dir/home"
  fakebin=$(make_fake_toolchain "$case_dir")
  write_treehouse_hook_config "$case_dir/home"

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_VERSION=v1.8.0 run_bootstrap "$case_dir/home" "$fakebin")
  [ -z "$out" ] || fail "bootstrap reported problems despite treehouse lease, post_create, and hook support: $out"
  pass "bootstrap accepts treehouse get --lease, post_create, and configured hook support"
}

test_bootstrap_accepts_treehouse_hook_from_another_firstmate_root() {
  local case_dir fakebin out other_root
  case_dir="$TMP_ROOT/other-root-hook"
  other_root="$case_dir/other-firstmate"
  mkdir -p "$case_dir/home" "$other_root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$other_root/bin/fm-treehouse-post-create.sh"
  chmod +x "$other_root/bin/fm-treehouse-post-create.sh"
  fakebin=$(make_fake_toolchain "$case_dir")
  write_treehouse_hook_config "$case_dir/home" "$other_root"

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_VERSION=v1.8.0 run_bootstrap "$case_dir/home" "$fakebin")
  [ -z "$out" ] || fail "bootstrap rejected configured treehouse hook from another firstmate root: $out"
  pass "bootstrap accepts treehouse hook from another firstmate root"
}

test_bootstrap_accepts_treehouse_hook_path_with_spaces() {
  local case_dir fakebin out other_root
  case_dir="$TMP_ROOT/spaced-hook"
  other_root="$case_dir/other firstmate"
  mkdir -p "$case_dir/home" "$other_root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$other_root/bin/fm-treehouse-post-create.sh"
  chmod +x "$other_root/bin/fm-treehouse-post-create.sh"
  fakebin=$(make_fake_toolchain "$case_dir")
  write_treehouse_quoted_hook_config "$case_dir/home" "$other_root"

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_VERSION=v1.8.0 run_bootstrap "$case_dir/home" "$fakebin")
  [ -z "$out" ] || fail "bootstrap rejected configured treehouse hook path with spaces: $out"
  pass "bootstrap accepts treehouse hook path with spaces"
}

test_bootstrap_rejects_unquoted_treehouse_hook_path_with_spaces() {
  local case_dir fakebin out other_root expected
  case_dir="$TMP_ROOT/unquoted-spaced-hook"
  other_root="$case_dir/other firstmate"
  mkdir -p "$case_dir/home" "$other_root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$other_root/bin/fm-treehouse-post-create.sh"
  chmod +x "$other_root/bin/fm-treehouse-post-create.sh"
  fakebin=$(make_fake_toolchain "$case_dir")
  write_treehouse_hook_config "$case_dir/home" "$other_root"

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_VERSION=v1.8.0 run_bootstrap "$case_dir/home" "$fakebin")
  expected="MISSING: treehouse-post-create-hook (install: $ROOT/bin/fm-bootstrap.sh install treehouse-post-create-hook)"
  printf '%s\n' "$out" | grep -Fx "$expected" >/dev/null \
    || fail "bootstrap accepted unquoted treehouse hook path with spaces: $out"
  pass "bootstrap rejects unquoted treehouse hook path with spaces"
}

test_bootstrap_rejects_unquoted_treehouse_hook_path_with_shell_metachar() {
  local case_dir fakebin out other_root expected
  case_dir="$TMP_ROOT/unquoted-metachar-hook"
  other_root="$case_dir/other;firstmate"
  mkdir -p "$case_dir/home" "$other_root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$other_root/bin/fm-treehouse-post-create.sh"
  chmod +x "$other_root/bin/fm-treehouse-post-create.sh"
  fakebin=$(make_fake_toolchain "$case_dir")
  write_treehouse_hook_config "$case_dir/home" "$other_root"

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_VERSION=v1.8.0 run_bootstrap "$case_dir/home" "$fakebin")
  expected="MISSING: treehouse-post-create-hook (install: $ROOT/bin/fm-bootstrap.sh install treehouse-post-create-hook)"
  printf '%s\n' "$out" | grep -Fx "$expected" >/dev/null \
    || fail "bootstrap accepted unquoted treehouse hook path with shell metacharacter: $out"
  pass "bootstrap rejects unquoted treehouse hook path with shell metacharacter"
}

test_bootstrap_accepts_hooks_section_inline_comment() {
  local case_dir fakebin out expected_config
  case_dir="$TMP_ROOT/hooks-inline-comment"
  mkdir -p "$case_dir/home/xdg/treehouse"
  fakebin=$(make_fake_toolchain "$case_dir")
  expected_config="$case_dir/home/xdg/treehouse/config.toml"
  printf '[hooks] # local hooks\npost_create = ["%s/bin/fm-treehouse-post-create.sh"]\n' "$ROOT" >"$expected_config"

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_VERSION=v1.8.0 run_bootstrap "$case_dir/home" "$fakebin")
  [ -z "$out" ] || fail "bootstrap rejected treehouse hook under inline-commented hooks section: $out"
  pass "bootstrap accepts inline-commented hooks section"
}

test_bootstrap_ignores_commented_treehouse_hook_config() {
  local case_dir fakebin out expected_config expected
  case_dir="$TMP_ROOT/commented-hook"
  mkdir -p "$case_dir/home/xdg/treehouse"
  fakebin=$(make_fake_toolchain "$case_dir")
  expected_config="$case_dir/home/xdg/treehouse/config.toml"
  printf '[hooks]\n# post_create = ["%s/bin/fm-treehouse-post-create.sh"]\n' "$ROOT" >"$expected_config"

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_VERSION=v1.8.0 run_bootstrap "$case_dir/home" "$fakebin")
  expected="MISSING: treehouse-post-create-hook (install: $ROOT/bin/fm-bootstrap.sh install treehouse-post-create-hook)"
  printf '%s\n' "$out" | grep -Fx "$expected" >/dev/null \
    || fail "bootstrap accepted commented treehouse hook config: $out"
  pass "bootstrap ignores commented treehouse hook config"
}

test_bootstrap_ignores_stale_treehouse_hook_config() {
  local case_dir fakebin out expected_config expected
  case_dir="$TMP_ROOT/stale-hook"
  mkdir -p "$case_dir/home/xdg/treehouse"
  fakebin=$(make_fake_toolchain "$case_dir")
  expected_config="$case_dir/home/xdg/treehouse/config.toml"
  printf '[hooks]\npost_create = ["%s/missing/bin/fm-treehouse-post-create.sh"]\n' "$case_dir" >"$expected_config"

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_VERSION=v1.8.0 run_bootstrap "$case_dir/home" "$fakebin")
  expected="MISSING: treehouse-post-create-hook (install: $ROOT/bin/fm-bootstrap.sh install treehouse-post-create-hook)"
  printf '%s\n' "$out" | grep -Fx "$expected" >/dev/null \
    || fail "bootstrap accepted stale treehouse hook config: $out"
  pass "bootstrap ignores stale treehouse hook config"
}

test_bootstrap_does_not_match_other_hook_commands() {
  local case_dir fakebin out expected_config expected
  case_dir="$TMP_ROOT/other-hook-command"
  mkdir -p "$case_dir/home/xdg/treehouse"
  fakebin=$(make_fake_toolchain "$case_dir")
  expected_config="$case_dir/home/xdg/treehouse/config.toml"
  printf '[hooks]\npost_create = ["existing-hook"]\npre_create = ["%s/bin/fm-treehouse-post-create.sh"]\n' "$ROOT" >"$expected_config"

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_VERSION=v1.8.0 run_bootstrap "$case_dir/home" "$fakebin")
  expected="MISSING: treehouse-post-create-hook (install: $ROOT/bin/fm-bootstrap.sh install treehouse-post-create-hook)"
  printf '%s\n' "$out" | grep -Fx "$expected" >/dev/null \
    || fail "bootstrap matched a non-post_create treehouse hook command: $out"
  pass "bootstrap does not match other hook commands"
}

test_bootstrap_reports_treehouse_without_lease_support() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/lease-missing"
  mkdir -p "$case_dir/home"
  fakebin=$(make_fake_toolchain "$case_dir")

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=0 run_bootstrap "$case_dir/home" "$fakebin")
  printf '%s\n' "$out" | grep -Fx 'MISSING: treehouse (install: curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh)' >/dev/null \
    || fail "bootstrap did not report treehouse upgrade instruction"
  printf '%s\n' "$out" | grep -F 'NEEDS_GH_AUTH' >/dev/null && fail "bootstrap reported gh auth despite fake authenticated gh"
  pass "bootstrap reports treehouse without get --lease support"
}

test_bootstrap_reports_treehouse_without_post_create_support() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/post-create-missing"
  mkdir -p "$case_dir/home"
  fakebin=$(make_fake_toolchain "$case_dir")

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_VERSION=v1.7.9 run_bootstrap "$case_dir/home" "$fakebin")
  printf '%s\n' "$out" | grep -Fx 'MISSING: treehouse (install: curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh)' >/dev/null \
    || fail "bootstrap did not report treehouse upgrade instruction for missing post_create support"
  pass "bootstrap reports treehouse without post_create support"
}

test_bootstrap_reports_treehouse_without_post_create_hook_config() {
  local case_dir fakebin out expected
  case_dir="$TMP_ROOT/hook-missing"
  mkdir -p "$case_dir/home"
  fakebin=$(make_fake_toolchain "$case_dir")

  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_VERSION=v1.8.0 run_bootstrap "$case_dir/home" "$fakebin")
  expected="MISSING: treehouse-post-create-hook (install: $ROOT/bin/fm-bootstrap.sh install treehouse-post-create-hook)"
  printf '%s\n' "$out" | grep -Fx "$expected" >/dev/null \
    || fail "bootstrap did not report missing treehouse post_create hook config: $out"
  pass "bootstrap reports treehouse without post_create hook config"
}

test_bootstrap_installs_treehouse_post_create_hook_config() {
  local case_dir fakebin out expected_config
  case_dir="$TMP_ROOT/hook-install"
  mkdir -p "$case_dir/home"
  fakebin=$(make_fake_toolchain "$case_dir")

  install_bootstrap_tool "$case_dir/home" "$fakebin" treehouse-post-create-hook >/dev/null \
    || fail "bootstrap install treehouse-post-create-hook failed"
  expected_config="$case_dir/home/xdg/treehouse/config.toml"
  grep -Fx "post_create = [\"'$ROOT/bin/fm-treehouse-post-create.sh'\"]" "$expected_config" >/dev/null \
    || fail "bootstrap did not install treehouse post_create hook config"
  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_VERSION=v1.8.0 run_bootstrap "$case_dir/home" "$fakebin")
  [ -z "$out" ] || fail "bootstrap reported problems after installing treehouse hook: $out"
  pass "bootstrap installs treehouse post_create hook config"
}

test_bootstrap_appends_treehouse_post_create_hook_config() {
  local case_dir fakebin expected_config out
  case_dir="$TMP_ROOT/hook-append"
  mkdir -p "$case_dir/home/xdg/treehouse"
  fakebin=$(make_fake_toolchain "$case_dir")
  expected_config="$case_dir/home/xdg/treehouse/config.toml"
  printf '[hooks]\npost_create = ["existing-hook"]\n' >"$expected_config"

  install_bootstrap_tool "$case_dir/home" "$fakebin" treehouse-post-create-hook >/dev/null \
    || fail "bootstrap install treehouse-post-create-hook failed with existing post_create"
  grep -Fx "post_create = [\"existing-hook\", \"'$ROOT/bin/fm-treehouse-post-create.sh'\"]" "$expected_config" >/dev/null \
    || fail "bootstrap did not append treehouse post_create hook config"
  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_VERSION=v1.8.0 run_bootstrap "$case_dir/home" "$fakebin")
  [ -z "$out" ] || fail "bootstrap reported problems after appending treehouse hook: $out"
  pass "bootstrap appends treehouse post_create hook config"
}

test_bootstrap_installs_quoted_treehouse_hook_path_with_spaces() {
  local case_dir fakebin expected_config out other_root expected_root
  case_dir="$TMP_ROOT/hook-install-spaced"
  other_root="$case_dir/first mate"
  mkdir -p "$case_dir/home" "$other_root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$other_root/bin/fm-treehouse-post-create.sh"
  chmod +x "$other_root/bin/fm-treehouse-post-create.sh"
  expected_root=$(cd "$other_root" && pwd -P)
  fakebin=$(make_fake_toolchain "$case_dir")

  FM_ROOT_OVERRIDE="$other_root" install_bootstrap_tool "$case_dir/home" "$fakebin" treehouse-post-create-hook >/dev/null \
    || fail "bootstrap install treehouse-post-create-hook failed with spaced root"
  expected_config="$case_dir/home/xdg/treehouse/config.toml"
  grep -Fx "post_create = [\"'$expected_root/bin/fm-treehouse-post-create.sh'\"]" "$expected_config" >/dev/null \
    || fail "bootstrap did not quote treehouse post_create hook path with spaces"
  out=$(FM_ROOT_OVERRIDE="$other_root" FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_VERSION=v1.8.0 run_bootstrap "$case_dir/home" "$fakebin")
  [ -z "$out" ] || fail "bootstrap reported problems after installing spaced treehouse hook: $out"
  pass "bootstrap installs quoted treehouse hook path with spaces"
}

test_bootstrap_installs_quoted_treehouse_hook_path_with_single_quote() {
  local case_dir fakebin expected_config out other_root
  case_dir="$TMP_ROOT/hook-install-single-quote"
  other_root="$case_dir/first'mate"
  mkdir -p "$case_dir/home" "$other_root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$other_root/bin/fm-treehouse-post-create.sh"
  chmod +x "$other_root/bin/fm-treehouse-post-create.sh"
  fakebin=$(make_fake_toolchain "$case_dir")

  FM_ROOT_OVERRIDE="$other_root" install_bootstrap_tool "$case_dir/home" "$fakebin" treehouse-post-create-hook >/dev/null \
    || fail "bootstrap install treehouse-post-create-hook failed with single-quote root"
  expected_config="$case_dir/home/xdg/treehouse/config.toml"
  grep -F "\\\\''" "$expected_config" >/dev/null \
    || fail "bootstrap did not TOML-escape shell quoting for single-quote path"
  out=$(FM_ROOT_OVERRIDE="$other_root" FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_VERSION=v1.8.0 run_bootstrap "$case_dir/home" "$fakebin")
  [ -z "$out" ] || fail "bootstrap reported problems after installing single-quote treehouse hook: $out"
  pass "bootstrap installs quoted treehouse hook path with single quote"
}

test_bootstrap_installs_into_hooks_section_with_inline_comment() {
  local case_dir fakebin expected_config out hook_count
  case_dir="$TMP_ROOT/hook-install-inline-comment"
  mkdir -p "$case_dir/home/xdg/treehouse"
  fakebin=$(make_fake_toolchain "$case_dir")
  expected_config="$case_dir/home/xdg/treehouse/config.toml"
  printf '[hooks] # local hooks\npre_create = ["existing-hook"]\n' >"$expected_config"

  install_bootstrap_tool "$case_dir/home" "$fakebin" treehouse-post-create-hook >/dev/null \
    || fail "bootstrap install treehouse-post-create-hook failed with inline-commented hooks section"
  hook_count=$(grep -Ec '^[[:space:]]*\[hooks\]' "$expected_config")
  [ "$hook_count" -eq 1 ] || fail "bootstrap duplicated inline-commented hooks section"
  grep -Fx "post_create = [\"'$ROOT/bin/fm-treehouse-post-create.sh'\"]" "$expected_config" >/dev/null \
    || fail "bootstrap did not insert treehouse post_create under inline-commented hooks section"
  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_VERSION=v1.8.0 run_bootstrap "$case_dir/home" "$fakebin")
  [ -z "$out" ] || fail "bootstrap reported problems after inline-commented hooks install: $out"
  pass "bootstrap installs into inline-commented hooks section"
}

test_bootstrap_accepts_treehouse_lease_and_hook_support
test_bootstrap_accepts_treehouse_hook_from_another_firstmate_root
test_bootstrap_accepts_treehouse_hook_path_with_spaces
test_bootstrap_rejects_unquoted_treehouse_hook_path_with_spaces
test_bootstrap_rejects_unquoted_treehouse_hook_path_with_shell_metachar
test_bootstrap_accepts_hooks_section_inline_comment
test_bootstrap_ignores_commented_treehouse_hook_config
test_bootstrap_ignores_stale_treehouse_hook_config
test_bootstrap_does_not_match_other_hook_commands
test_bootstrap_reports_treehouse_without_lease_support
test_bootstrap_reports_treehouse_without_post_create_support
test_bootstrap_reports_treehouse_without_post_create_hook_config
test_bootstrap_installs_treehouse_post_create_hook_config
test_bootstrap_appends_treehouse_post_create_hook_config
test_bootstrap_installs_quoted_treehouse_hook_path_with_spaces
test_bootstrap_installs_quoted_treehouse_hook_path_with_single_quote
test_bootstrap_installs_into_hooks_section_with_inline_comment
