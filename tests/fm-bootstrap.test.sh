#!/usr/bin/env bash
# Behavior tests for bootstrap tool detection.
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

write_fake_tool() {
  local path=$1 body=$2
  printf '%s\n' '#!/bin/sh' "$body" > "$path"
  chmod +x "$path"
}

make_fakebin() {
  local dir=$1 fakebin tool
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  write_fake_tool "$fakebin/dirname" 'exec /usr/bin/dirname "$@"'
  write_fake_tool "$fakebin/grep" 'exec /usr/bin/grep "$@"'
  write_fake_tool "$fakebin/gh-axi" 'exit 0'
  for tool in opencode node no-mistakes chrome-devtools-axi lavish-axi; do
    write_fake_tool "$fakebin/$tool" 'exit 0'
  done
  printf '%s\n' "$fakebin"
}

test_opencode_backend_requires_tmux_only_with_secondmates() {
  local fakebin home out
  home="$TMP_ROOT/home"
  mkdir -p "$home/data" "$home/config"
  fakebin=$(make_fakebin "$TMP_ROOT/runtime")

  out=$(PATH="$fakebin" FM_HOME="$home" FM_BACKEND=opencode-server "$BASH" "$ROOT/bin/fm-bootstrap.sh") \
    || fail "bootstrap failed for opencode-server without secondmates"
  printf '%s\n' "$out" | grep -F 'MISSING: tmux' >/dev/null \
    && fail "opencode-server bootstrap required tmux without secondmates"

  printf '%s\n' '- design - charter (home: /tmp/design; scope: design; projects: app; added 2026-06-23)' > "$home/data/secondmates.md"
  out=$(PATH="$fakebin" FM_HOME="$home" FM_BACKEND=opencode-server "$BASH" "$ROOT/bin/fm-bootstrap.sh") \
    || fail "bootstrap failed for opencode-server with secondmates"
  printf '%s\n' "$out" | grep -F 'MISSING: tmux' >/dev/null \
    || fail "opencode-server bootstrap did not require tmux with secondmates"

  pass "opencode-server bootstrap requires tmux only when secondmates are registered"
}

test_opencode_backend_requires_tmux_only_with_secondmates
