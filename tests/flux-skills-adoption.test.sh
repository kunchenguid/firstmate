#!/usr/bin/env bash
# Behavior tests for adopted fluxcd/agent-skills vendor verification.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=${ROOT:?}
VERIFY="$ROOT/bin/fm-flux-skills-verify.sh"
VENDOR_ROOT="$ROOT/skills/vendor/fluxcd-agent-skills"

test_verify_passes_on_committed_vendor_tree() {
  local out rc
  out=$("$VERIFY" 2>&1) || {
    rc=$?
    fail "fm-flux-skills-verify failed ($rc): $out"
  }
  assert_contains "$out" 'gitops-knowledge' "verify output names adopted skills"
  assert_contains "$out" 'v0.2.0' "verify output names pinned tag"
  pass 'fm-flux-skills-verify accepts the committed vendor tree'
}

test_checksum_tamper_is_rejected() {
  local tamper="$VENDOR_ROOT/gitops-knowledge/SKILL.md"
  local backup
  backup=$(mktemp)
  cp "$tamper" "$backup"
  printf '\n# tamper\n' >>"$tamper"
  if "$VERIFY" >/dev/null 2>&1; then
    cp "$backup" "$tamper"
    fail 'verify must reject a checksum mismatch'
  fi
  cp "$backup" "$tamper"
  rm -f "$backup"
  pass 'fm-flux-skills-verify rejects checksum tampering'
}

test_unlisted_file_is_rejected() {
  local extra="$VENDOR_ROOT/gitops-knowledge/unlisted-file"
  : >"$extra"
  if "$VERIFY" >/dev/null 2>&1; then
    rm -f "$extra"
    fail 'verify must reject files omitted from the checksum inventory'
  fi
  rm -f "$extra"
  pass 'fm-flux-skills-verify rejects unlisted adopted files'
}

test_symlink_is_rejected() {
  local link="$VENDOR_ROOT/gitops-knowledge/unlisted-link"
  ln -s SKILL.md "$link"
  if "$VERIFY" >/dev/null 2>&1; then
    rm -f "$link"
    fail 'verify must reject symbolic links in adopted skills'
  fi
  rm -f "$link"
  pass 'fm-flux-skills-verify rejects adopted skill symlinks'
}

test_unexpected_top_level_symlink_is_rejected() {
  local link="$VENDOR_ROOT/extra-skill"
  ln -s gitops-knowledge "$link"
  if "$VERIFY" >/dev/null 2>&1; then
    rm -f "$link"
    fail 'verify must reject unexpected top-level symbolic links'
  fi
  rm -f "$link"
  pass 'fm-flux-skills-verify rejects top-level symlinks'
}

test_manifest_is_parsed_without_execution() {
  local manifest="$VENDOR_ROOT/MANIFEST" backup marker
  backup=$(mktemp)
  marker=$(mktemp)
  rm -f "$marker"
  cp "$manifest" "$backup"
  sed "s|^source_repo=.*|source_repo=\$(touch '$marker')|" "$backup" >"$manifest"
  "$VERIFY" >/dev/null 2>&1 && {
    cp "$backup" "$manifest"
    fail 'verify must reject a malformed source identity'
  }
  cp "$backup" "$manifest"
  [ ! -e "$marker" ] || fail 'verify executed manifest data'
  rm -f "$backup"
  pass 'fm-flux-skills-verify treats manifest values as data'
}

test_verify_passes_on_committed_vendor_tree
test_checksum_tamper_is_rejected
test_unlisted_file_is_rejected
test_symlink_is_rejected
test_unexpected_top_level_symlink_is_rejected
test_manifest_is_parsed_without_execution
