#!/usr/bin/env bash
# Behavior tests for host-independent Git fixtures from tests/lib.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-git-fixtures)
trap fm_test_cleanup EXIT

HOST_CONFIG="$TMP_ROOT/host.gitconfig"
cat > "$HOST_CONFIG" <<'EOF'
[user]
	name = Host User
	email = host@example.invalid
	signingkey = fixture-key-that-does-not-exist
[commit]
	gpgsign = true
[tag]
	gpgsign = true
EOF

REPO="$TMP_ROOT/repo"
GIT_CONFIG_GLOBAL="$HOST_CONFIG" GIT_CONFIG_SYSTEM=/dev/null \
  fm_git_init_commit "$REPO" || fail "fixture commit inherited signing from the host configuration"

[ "$(fm_git -C "$REPO" rev-list --count HEAD)" = 1 ] || \
  fail "fixture helper did not create exactly one commit"
pass "Git fixtures ignore inherited signing configuration"
