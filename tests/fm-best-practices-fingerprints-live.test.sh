#!/usr/bin/env bash
# Live guard: every carried adapter's fingerprints agree with the real release
# of each tag it supports.
#
# For each adapter, bin/fm-best-practices.sh fingerprints regenerates the
# hashes from a fresh shallow clone of every supported tag of the pack's
# repository, checking each tag's commit against the manifest, and this fails
# when they differ from what the manifest records, so a hand edit, a moved tag,
# or a reference that starts naming another skill cannot ship unnoticed.
# It spends no model tokens, so it runs by default wherever git and jq are
# installed. FM_LIVE_BP_FINGERPRINTS=0 (or FM_LIVE=0) turns it off, and =1 (or
# FM_LIVE=1) makes an unreachable GitHub a failure instead of a skip.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_LIVE_BP_FINGERPRINTS git jq

BP="$ROOT/bin/fm-best-practices.sh"

test_fingerprints_match_each_supported_release() {
  local repo manifest recorded generated
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    manifest="$ROOT/.agents/skills/best-practices-adapters/references/$repo/manifest.json"
    recorded=$(jq -cS '.fingerprints' "$manifest")
    generated=$("$BP" fingerprints "$repo" | jq -cS .) ||
      fail "could not regenerate the fingerprints of $repo from its tagged releases"
    [ "$recorded" = "$generated" ] ||
      fail "the fingerprints recorded for $repo disagree with its tagged releases; regenerate them with bin/fm-best-practices.sh fingerprints $repo --write"
  done < <("$BP" adapters)
  pass "every carried adapter's fingerprints match the real release of each supported tag"
}

if ! git ls-remote --exit-code "https://github.com/$("$BP" adapters | head -n 1).git" HEAD >/dev/null 2>&1; then
  if [ "${FM_LIVE_BP_FINGERPRINTS:-${FM_LIVE:-}}" = 1 ]; then
    fail "FM_LIVE_BP_FINGERPRINTS was requested but github.com is unreachable"
  fi
  printf 'skip: live: github.com unreachable\n'
  exit 0
fi

fm_test_run test_fingerprints_match_each_supported_release
