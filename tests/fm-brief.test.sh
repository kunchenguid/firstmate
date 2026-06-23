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

TMP_ROOT=$(mktemp -d "$ROOT/.tmp.fm-brief-tests.XXXXXX")

test_no_mistakes_brief_uses_manual_pr_validation_contract() {
  local home brief
  home="$TMP_ROOT/home"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' '- app [no-mistakes] - test project (added 2026-06-23)' > "$home/data/projects.md"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" ship-test app >/dev/null \
    || fail "brief scaffold failed"
  brief="$home/data/ship-test/brief.md"

  grep -F 'Never push to any remote. Never open or merge a PR.' "$brief" >/dev/null \
    || fail "no-mistakes brief permits push or PR creation"
  grep -F 'no-mistakes validation pipeline with `--skip=push,pr,ci`' "$brief" >/dev/null \
    || fail "no-mistakes brief omits skip flags"
  grep -F 'No-mistakes does not push, open a PR, or monitor CI in this workflow.' "$brief" >/dev/null \
    || fail "no-mistakes brief omits manual workflow boundary"
  grep -F 'done: validated with --skip=push,pr,ci; branch ready for captain/manual push+PR' "$brief" >/dev/null \
    || fail "no-mistakes brief omits manual PR-ready status"

  if grep -F 'validate and ship a PR' "$brief" >/dev/null; then
    fail "no-mistakes brief still says validation ships a PR"
  fi
  if grep -F 'reports CI green' "$brief" >/dev/null; then
    fail "no-mistakes brief still waits for CI green"
  fi
  if grep -F 'done: PR {url} checks green' "$brief" >/dev/null; then
    fail "no-mistakes brief still reports old PR completion"
  fi

  pass "no-mistakes brief uses manual PR validation contract"
}

test_no_mistakes_brief_uses_manual_pr_validation_contract
