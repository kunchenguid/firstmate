#!/usr/bin/env bash
# tests/fm-remote-home-seed.test.sh - public remote-home seed coverage at the
# oldest supported Bash semantics, including project-less and project-bearing
# manifests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-home-seed)
PARENT="$TMP_ROOT/parent"
FAKE_SSH="$TMP_ROOT/fake-ssh"
MANIFEST="$TMP_ROOT/manifest"
BASH_BIN=${FM_TEST_BASH_BIN:-/bin/bash}
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects"

cat > "$FAKE_SSH" <<'SH'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  shift
done
payload=$(cat)
if [ -n "$payload" ]; then
  printf '%s\n' "$payload" > "$FM_TEST_MANIFEST"
fi
exit 0
SH
chmod +x "$FAKE_SSH"

run_seed() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_SSH_BIN="$FAKE_SSH" \
  FM_TEST_MANIFEST="$MANIFEST" \
  "$BASH_BIN" "$ROOT/bin/fm-remote-home-seed.sh" "$@"
}

[ -x "$BASH_BIN" ] || { echo "skip: test Bash interpreter not found: $BASH_BIN"; exit 0; }

out=$(FM_SECONDMATE_CHARTER='Project-less Bash compatibility seed' \
  FM_SECONDMATE_SCOPE='Project-less Bash compatibility path' \
  run_seed project-less remote-mac /tmp/remote-root /tmp/project-less-home --no-projects) \
  || fail "--no-projects public seed interface failed under $BASH_BIN"
assert_contains "$out" 'home=remote-mac:/tmp/project-less-home' \
  "--no-projects seed did not report the remote home"
assert_grep 'project_count=0' "$MANIFEST" \
  "--no-projects seed did not publish a zero-project manifest"
assert_no_grep 'project=' "$MANIFEST" \
  "--no-projects seed published a project record"
pass "remote home seed accepts --no-projects under $BASH_BIN"

printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-08-13)' \
  > "$PARENT/data/projects.md"
out=$(FM_SECONDMATE_CHARTER='Project-bearing Bash compatibility seed' \
  FM_SECONDMATE_SCOPE='Project-bearing Bash compatibility path' \
  run_seed project-bearing remote-mac /tmp/remote-root /tmp/project-bearing-home \
  alpha=https://example.com/alpha.git) \
  || fail "project-bearing public seed interface failed under $BASH_BIN"
assert_contains "$out" 'home=remote-mac:/tmp/project-bearing-home' \
  "project-bearing seed did not report the remote home"
assert_grep 'project_count=1' "$MANIFEST" \
  "project-bearing seed did not publish a one-project manifest"
assert_grep 'project=' "$MANIFEST" \
  "project-bearing seed did not publish its project record"
pass "remote home seed preserves project-bearing behavior under $BASH_BIN"
