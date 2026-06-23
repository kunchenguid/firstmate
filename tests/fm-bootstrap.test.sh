#!/usr/bin/env bash
# Behavior tests for bootstrap tool detection.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
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

make_fakebin_without_tmux() {
  local dir=$1 fakebin utilbin tool util
  fakebin="$dir/fakebin"
  utilbin="$dir/utilbin"
  mkdir -p "$fakebin" "$utilbin"
  for tool in opencode node no-mistakes chrome-devtools-axi lavish-axi; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ] && [ "${2:-}" = user ]; then
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/gh-axi"
  for util in dirname grep tail tr pwd; do
    ln -s "$(command -v "$util")" "$utilbin/$util"
  done
  printf '%s:%s\n' "$fakebin" "$utilbin"
}

test_opencode_server_requires_tmux_when_secondmates_registered() {
  local home fakebin out
  home="$TMP_ROOT/home"
  mkdir -p "$home/data" "$home/config"
  printf '%s\n' '- domain - domain supervisor (home: /tmp/domain; scope: domain; projects: alpha; added 2026-06-23)' > "$home/data/secondmates.md"
  fakebin=$(make_fakebin_without_tmux "$TMP_ROOT/runtime")

  out=$(PATH="$fakebin" FM_HOME="$home" FM_BACKEND=opencode-server /bin/bash "$BOOTSTRAP") \
    || fail "bootstrap detection failed"
  printf '%s\n' "$out" | grep -F 'MISSING: tmux ' >/dev/null \
    || fail "opencode-server bootstrap did not require tmux for registered secondmates: $out"
  printf '%s\n' "$out" | grep -F 'MISSING: treehouse ' >/dev/null \
    && fail "opencode-server bootstrap required treehouse for secondmate-only tmux path"

  pass "opencode-server bootstrap requires tmux when secondmates are registered"
}

test_opencode_server_omits_tmux_without_secondmates() {
  local home fakebin out
  home="$TMP_ROOT/home-no-secondmates"
  mkdir -p "$home/data" "$home/config"
  fakebin=$(make_fakebin_without_tmux "$TMP_ROOT/runtime-no-secondmates")

  out=$(PATH="$fakebin" FM_HOME="$home" FM_BACKEND=opencode-server /bin/bash "$BOOTSTRAP") \
    || fail "bootstrap detection failed without secondmates"
  printf '%s\n' "$out" | grep -F 'MISSING: tmux ' >/dev/null \
    && fail "opencode-server bootstrap required tmux without secondmates: $out"

  pass "opencode-server bootstrap omits tmux without secondmates"
}

test_opencode_server_requires_tmux_when_secondmates_registered
test_opencode_server_omits_tmux_without_secondmates
