#!/usr/bin/env bash
# Behavior tests for adopted fluxcd/agent-skills vendor verification.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=${ROOT:?}
VERIFY="$ROOT/bin/fm-flux-skills-verify.sh"
VENDOR_ROOT="$ROOT/skills/vendor/fluxcd-agent-skills"
MANIFEST="$VENDOR_ROOT/MANIFEST"

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

test_manifest_records_upstream_identity() {
  assert_grep 'source_repo=fluxcd/agent-skills' "$MANIFEST" 'manifest records source repo'
  assert_grep 'license=Apache-2.0' "$MANIFEST" 'manifest records license'
  assert_grep 'upstream_tag=v0.2.0' "$MANIFEST" 'manifest records pinned tag'
  assert_grep 'upstream_commit=9b05787530a3e200a9ac031fc8a477566e0b7adc' "$MANIFEST" 'manifest records pinned commit'
  assert_grep 'adopted_skills=gitops-knowledge gitops-repo-audit' "$MANIFEST" 'manifest records adopted skills'
  assert_grep 'excluded_skills=gitops-cluster-debug' "$MANIFEST" 'manifest records excluded skills'
  pass 'MANIFEST records upstream identity and selection'
}

test_excluded_skill_is_not_vendored_or_exposed() {
  [ ! -e "$VENDOR_ROOT/gitops-cluster-debug" ] \
    || fail 'gitops-cluster-debug must not exist in the vendor tree'
  [ ! -e "$ROOT/.agents/skills/gitops-cluster-debug" ] \
    || fail 'gitops-cluster-debug must not be exposed under .agents/skills'
  pass 'gitops-cluster-debug is absent from vendor and agent skill surfaces'
}

test_adopted_skills_have_upstream_skill_md() {
  assert_present "$VENDOR_ROOT/gitops-knowledge/SKILL.md" 'gitops-knowledge SKILL.md'
  assert_present "$VENDOR_ROOT/gitops-repo-audit/SKILL.md" 'gitops-repo-audit SKILL.md'
  pass 'adopted skills ship upstream SKILL.md files'
}

test_internal_stubs_point_at_vendor_and_amendment() {
  assert_grep 'skills/vendor/fluxcd-agent-skills/gitops-knowledge/SKILL.md' \
    "$ROOT/.agents/skills/gitops-knowledge/SKILL.md" \
    'gitops-knowledge stub points at vendor skill'
  assert_grep 'skills/vendor/fluxcd-agent-skills/gitops-repo-audit/SKILL.md' \
    "$ROOT/.agents/skills/gitops-repo-audit/SKILL.md" \
    'gitops-repo-audit stub points at vendor skill'
  assert_grep 'flux-classic-gitops' \
    "$ROOT/.agents/skills/gitops-knowledge/SKILL.md" \
    'gitops-knowledge stub names classic amendment'
  assert_present "$ROOT/.agents/skills/flux-classic-gitops/SKILL.md" \
    'flux-classic-gitops amendment exists'
  pass 'internal stubs route to vendor skills and the classic amendment'
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

test_verify_passes_on_committed_vendor_tree
test_manifest_records_upstream_identity
test_excluded_skill_is_not_vendored_or_exposed
test_adopted_skills_have_upstream_skill_md
test_internal_stubs_point_at_vendor_and_amendment
test_checksum_tamper_is_rejected
