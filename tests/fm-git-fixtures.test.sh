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

RAW_REPO="$TMP_ROOT/raw-repo"
mkdir -p "$RAW_REPO"
GIT_CONFIG_GLOBAL="$HOST_CONFIG" bash -c '
  git -C "$1" init -q -b main &&
    printf "fixture\n" > "$1/fixture" &&
    git -C "$1" add fixture &&
    git -C "$1" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
' _ "$RAW_REPO" || fail "raw fixture commit inherited signing in a subprocess"
[ "$(git -C "$RAW_REPO" rev-list --count HEAD)" = 1 ] || \
  fail "raw fixture subprocess did not create exactly one commit"
pass "raw Git fixture commits inherit signing isolation"
