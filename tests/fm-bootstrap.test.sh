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

write_fake_tool() {
  local path=$1 body=$2
  printf '%s\n' '#!/bin/sh' "$body" > "$path"
  chmod +x "$path"
}

make_fakebin_without_tmux() {
  local dir=$1 fakebin tool util
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"

  for util in dirname grep tail tr pwd; do
    write_fake_tool "$fakebin/$util" "exec /usr/bin/$util \"\$@\""
  done
  write_fake_tool "$fakebin/gh-axi" 'if [ "${1:-}" = api ] && [ "${2:-}" = user ]; then exit 0; fi; exit 1'
  for tool in opencode node no-mistakes chrome-devtools-axi lavish-axi; do
    write_fake_tool "$fakebin/$tool" 'exit 0'
  done

  printf '%s\n' "$fakebin"
}

test_opencode_server_requires_tmux_when_secondmates_registered() {
  local fakebin home out
  home="$TMP_ROOT/home"
  mkdir -p "$home/data" "$home/config"
  printf '%s\n' '- domain - domain supervisor (home: /tmp/domain; scope: domain; projects: alpha; added 2026-06-23)' > "$home/data/secondmates.md"
  fakebin=$(make_fakebin_without_tmux "$TMP_ROOT/runtime")

  out=$(PATH="$fakebin" FM_HOME="$home" FM_BACKEND=opencode-server "$BASH" "$BOOTSTRAP") \
    || fail "bootstrap detection failed"
  printf '%s\n' "$out" | grep -F 'MISSING: tmux ' >/dev/null \
    || fail "opencode-server bootstrap did not require tmux for registered secondmates: $out"
  printf '%s\n' "$out" | grep -F 'MISSING: treehouse ' >/dev/null \
    && fail "opencode-server bootstrap required treehouse for secondmate-only tmux path"

  pass "opencode-server bootstrap requires tmux when secondmates are registered"
}

test_opencode_server_omits_tmux_without_secondmates() {
  local fakebin home out
  home="$TMP_ROOT/home-no-secondmates"
  mkdir -p "$home/data" "$home/config"
  fakebin=$(make_fakebin_without_tmux "$TMP_ROOT/runtime-no-secondmates")

  out=$(PATH="$fakebin" FM_HOME="$home" FM_BACKEND=opencode-server "$BASH" "$BOOTSTRAP") \
    || fail "bootstrap detection failed without secondmates"
  printf '%s\n' "$out" | grep -F 'MISSING: tmux ' >/dev/null \
    && fail "opencode-server bootstrap required tmux without secondmates: $out"

  pass "opencode-server bootstrap omits tmux without secondmates"
}

test_opencode_server_requires_tmux_when_secondmates_registered
test_opencode_server_omits_tmux_without_secondmates
