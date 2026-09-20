#!/usr/bin/env bash
# fm-remote-home-provision.sh clones a code root this account does not own.
#
# The refusal is git's real one. GIT_TEST_ASSUME_DIFFERENT_OWNER is git's own
# knob for "every repository looks like someone else's" (its t0033 uses it), and
# the fixture hands git a global config that names every fixture repository this
# account really owns EXCEPT the code root. So git accepts the home and refuses
# the code root, exactly as on a host whose Firstmate checkout lives under
# another account, and the only thing that can lift that refusal here is a
# genuine safe.directory exception in a scope git honors.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-home-provision)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
cleanup() { rm -rf -- "$TMP_ROOT"; }
trap cleanup EXIT

encode() { base64 | tr -d '\n'; }

CODE_ROOT="$TMP_ROOT/unowned-code-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
OWNED_CONFIG="$TMP_ROOT/owned.gitconfig"

mkdir -p "$CODE_ROOT/bin"
printf 'remote code root fixture\n' > "$CODE_ROOT/AGENTS.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CODE_ROOT/bin/fm-fixture.sh"
chmod +x "$CODE_ROOT/bin/fm-fixture.sh"
printf 'projects/\nstate/\ndata/\nconfig/\n.fm-secondmate-home\n.fm-secondmate-parent\n' \
  > "$CODE_ROOT/.gitignore"
git -C "$CODE_ROOT" init -q -b main
git -C "$CODE_ROOT" config user.email test@example.com
git -C "$CODE_ROOT" config user.name Test
git -C "$CODE_ROOT" add .
git -C "$CODE_ROOT" commit -qm 'code root fixture'
CODE_ROOT_HEAD=$(git -C "$CODE_ROOT" rev-parse HEAD)

# Everything the agent account owns on this host, and nothing else. The code
# root is deliberately absent.
{
  printf '[safe]\n\tdirectory = %s\n\tdirectory = %s\n' "$REMOTE_HOME" "$REMOTE_HOME/.git"
} > "$OWNED_CONFIG"

# GIT_CONFIG_SYSTEM=/dev/null so a host-wide safe.directory cannot defeat the
# simulation and report a false pass.
as_foreign_root() {
  env GIT_TEST_ASSUME_DIFFERENT_OWNER=1 \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_CONFIG_GLOBAL="$OWNED_CONFIG" \
    "$@"
}

if as_foreign_root git clone --quiet -- "$CODE_ROOT" "$TMP_ROOT/unguarded" 2>/dev/null; then
  echo "skip: this git does not simulate a differently-owned repository"
  exit 0
fi

CHARTER="$TMP_ROOT/charter.md"
printf 'Remote charter\n' > "$CHARTER"
MANIFEST="$TMP_ROOT/manifest"
{
  printf 'schema=fm-remote-home-provision.v1\n'
  printf 'id_b64=%s\n' "$(printf '%s' route | encode)"
  printf 'charter_b64=%s\n' "$(encode < "$CHARTER")"
  printf 'parent_host_b64=%s\n' "$(printf '%s' remote-host | encode)"
  printf 'project_count=0\n'
} > "$MANIFEST"

PROVISION_OUT=$(as_foreign_root \
  env FM_ROOT_OVERRIDE="$CODE_ROOT" FM_HOME="$REMOTE_HOME" \
  "$ROOT/bin/fm-remote-home-provision.sh" < "$MANIFEST" 2>&1) \
  || fail "provisioning could not clone a code root owned by another account: $PROVISION_OUT"

assert_contains "$PROVISION_OUT" "provisioned: $REMOTE_HOME" \
  "provisioning did not report the published home"
assert_present "$REMOTE_HOME/.fm-secondmate-home" \
  "provisioning did not publish the identity marker"
assert_equals route "$(cat "$REMOTE_HOME/.fm-secondmate-home")" \
  "provisioned home carries the wrong secondmate id"
assert_present "$REMOTE_HOME/data/charter.md" \
  "provisioning did not publish the charter into the cloned home"

HOME_HEAD=$(as_foreign_root git -C "$REMOTE_HOME" rev-parse HEAD) \
  || fail "the provisioned home is not a readable clone"
assert_equals "$CODE_ROOT_HEAD" "$HOME_HEAD" \
  "the provisioned home does not carry the code root's commit"

# The exception is spent on that one clone: nothing persistent was written, so
# the code root is still refused afterwards.
as_foreign_root git -C "$CODE_ROOT" rev-parse HEAD >/dev/null 2>&1 \
  && fail "provisioning left a durable ownership exception for the code root"

pass "remote provisioning clones a code root owned by another account without keeping the exception"
