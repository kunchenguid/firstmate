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
  PATH="$fakebin:$PATH" FM_HOME="$home" XDG_CONFIG_HOME="$home/xdg" "$ROOT/bin/fm-bootstrap.sh"
}

install_bootstrap_tool() {
  local home=$1 fakebin=$2 tool=$3
  PATH="$fakebin:$PATH" FM_HOME="$home" XDG_CONFIG_HOME="$home/xdg" "$ROOT/bin/fm-bootstrap.sh" install "$tool"
}

write_treehouse_hook_config() {
  local home=$1
  mkdir -p "$home/xdg/treehouse"
  printf '[hooks]\npost_create = ["%s/bin/fm-treehouse-post-create.sh"]\n' "$ROOT" >"$home/xdg/treehouse/config.toml"
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
  grep -Fx "post_create = [\"$ROOT/bin/fm-treehouse-post-create.sh\"]" "$expected_config" >/dev/null \
    || fail "bootstrap did not install treehouse post_create hook config"
  out=$(FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_VERSION=v1.8.0 run_bootstrap "$case_dir/home" "$fakebin")
  [ -z "$out" ] || fail "bootstrap reported problems after installing treehouse hook: $out"
  pass "bootstrap installs treehouse post_create hook config"
}

test_bootstrap_accepts_treehouse_lease_and_hook_support
test_bootstrap_reports_treehouse_without_lease_support
test_bootstrap_reports_treehouse_without_post_create_support
test_bootstrap_reports_treehouse_without_post_create_hook_config
test_bootstrap_installs_treehouse_post_create_hook_config
