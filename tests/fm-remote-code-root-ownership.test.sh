#!/usr/bin/env bash
# Host-local remote lifecycle reads of a code root this account does not own.
#
# A remote home is provisioned from a code root the host often keeps under
# another account, so every later leg that reads that root - the sync fetch of
# the parent's commit and the code-root HEAD read that /updatefirstmate's sync
# targets - has to carry the same exception the clone did, or the home can
# never follow its parent again. The refusal here is git's real one
# (GIT_TEST_ASSUME_DIFFERENT_OWNER, git's own knob) and the fixture authorizes
# only the repositories this account really owns, so nothing but a genuine
# safe.directory exception in a scope git honors can make these pass.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-code-root-ownership)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
cleanup() { rm -rf -- "$TMP_ROOT"; }
trap cleanup EXIT

CODE_ROOT="$TMP_ROOT/unowned-code-root"
CODE_ROOT_ORIGIN="$TMP_ROOT/code-root-origin.git"
REMOTE_HOME="$TMP_ROOT/remote-home"
OWNED_CONFIG="$TMP_ROOT/owned.gitconfig"
ID=route

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
FIRST_COMMIT=$(git -C "$CODE_ROOT" rev-parse HEAD)

git clone --quiet -- "$CODE_ROOT" "$REMOTE_HOME" || fail "cannot stage the remote home fixture"
mkdir -p "$REMOTE_HOME/data" "$REMOTE_HOME/state" "$REMOTE_HOME/config" "$REMOTE_HOME/projects"
printf '%s\n' "$ID" > "$REMOTE_HOME/.fm-secondmate-home"
{
  printf 'schema=fm-secondmate-parent.v1\n'
  printf 'route=remote\n'
} > "$REMOTE_HOME/.fm-secondmate-parent"

# The code root then advances past the commit the home holds, which is the only
# thing a later sync can import.
printf 'second revision\n' >> "$CODE_ROOT/AGENTS.md"
git -C "$CODE_ROOT" commit -qam 'code root advance'
SECOND_COMMIT=$(git -C "$CODE_ROOT" rev-parse HEAD)

# Everything the agent account owns on this host, and nothing else: the code
# root is deliberately absent. The home and the code root's own origin mirror
# are the account's, standing in for the real remote where origin is a URL no
# ownership check applies to. An ambient setting is included to prove the
# guarded invocation still reads the account's real global config.
{
  printf '[fm]\n\tcoderootfixture = inherited\n'
  printf '[safe]\n\tdirectory = %s\n\tdirectory = %s\n\tdirectory = %s\n' \
    "$REMOTE_HOME" "$REMOTE_HOME/.git" "$CODE_ROOT_ORIGIN"
} > "$OWNED_CONFIG"

as_foreign_root() {
  env GIT_TEST_ASSUME_DIFFERENT_OWNER=1 \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_CONFIG_GLOBAL="$OWNED_CONFIG" \
    "$@"
}

control() {
  as_foreign_root env FM_ROOT_OVERRIDE="$CODE_ROOT" FM_HOME="$REMOTE_HOME" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" "$@"
}

if as_foreign_root git -C "$CODE_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  echo "skip: this git does not simulate a differently-owned repository"
  exit 0
fi
as_foreign_root git -C "$REMOTE_HOME" rev-parse HEAD >/dev/null 2>&1 \
  || fail "the fixture wrongly refuses the home this account owns"

# sync <id> <parent-commit>: the commit exists only in the unowned code root,
# so import_home_commit has to fetch it from there.
SYNC_OUT=$(control sync "$ID" "$SECOND_COMMIT" 2>&1) \
  || fail "sync could not import the parent's commit from an unowned code root: $SYNC_OUT"
assert_contains "$SYNC_OUT" "synced: $SECOND_COMMIT" \
  "sync did not fast-forward the home to the parent's commit"
assert_equals "$SECOND_COMMIT" "$(as_foreign_root git -C "$REMOTE_HOME" rev-parse HEAD)" \
  "the home did not actually advance to the parent's commit"

# sync <id> with no target: the target is the unowned code root's own HEAD, so
# the read that resolves it has to carry the exception too.
git -C "$REMOTE_HOME" reset --quiet --hard "$FIRST_COMMIT" \
  || fail "cannot rewind the home fixture"
printf 'third revision\n' >> "$CODE_ROOT/AGENTS.md"
git -C "$CODE_ROOT" commit -qam 'code root advance again'
THIRD_COMMIT=$(git -C "$CODE_ROOT" rev-parse HEAD)

HEAD_SYNC_OUT=$(control sync "$ID" 2>&1) \
  || fail "sync could not read the unowned code root's HEAD: $HEAD_SYNC_OUT"
assert_contains "$HEAD_SYNC_OUT" "synced: $THIRD_COMMIT" \
  "sync did not follow this host's code-root HEAD"
assert_equals "$THIRD_COMMIT" "$(as_foreign_root git -C "$REMOTE_HOME" rev-parse HEAD)" \
  "the home did not actually advance to the code root's HEAD"

# The exception names the code root only, lives for one command, and leaves the
# account's own global config in force while it does.
# shellcheck disable=SC2016 # The inner shell expands these, not this one.
INHERITED=$(as_foreign_root bash -c '
  . "$1/bin/fm-git-code-root-lib.sh"
  fm_git_code_root_run "$2" git config --get fm.coderootfixture
' bash "$ROOT" "$CODE_ROOT" 2>&1) \
  || fail "the guarded invocation dropped the account's global git config: $INHERITED"
assert_equals inherited "$INHERITED" \
  "the guarded invocation did not keep the account's own global git config"

# update <id>: the whole code-root refresh runs against the unowned root - the
# origin fetch and the fast-forward of the root itself - before the home is
# synced to whatever that left behind.
git -C "$CODE_ROOT" remote add origin "$CODE_ROOT_ORIGIN" \
  || fail "cannot give the code-root fixture an origin"
git init -q --bare "$CODE_ROOT_ORIGIN" || fail "cannot stage the code-root origin"
git -C "$CODE_ROOT" push -q origin main || fail "cannot publish the code-root fixture"
git --git-dir="$CODE_ROOT_ORIGIN" symbolic-ref HEAD refs/heads/main

PUBLISHER="$TMP_ROOT/publisher"
git clone --quiet -- "$CODE_ROOT_ORIGIN" "$PUBLISHER" || fail "cannot stage the publisher fixture"
git -C "$PUBLISHER" config user.email test@example.com
git -C "$PUBLISHER" config user.name Test
printf 'origin revision\n' >> "$PUBLISHER/AGENTS.md"
git -C "$PUBLISHER" commit -qam 'origin advance'
git -C "$PUBLISHER" push -q origin main
ORIGIN_TIP=$(git -C "$PUBLISHER" rev-parse HEAD)

UPDATE_OUT=$(control update "$ID" 2>&1) \
  || fail "update could not refresh an unowned code root: $UPDATE_OUT"
assert_equals "$ORIGIN_TIP" "$(git -C "$CODE_ROOT" rev-parse HEAD)" \
  "update did not fast-forward the unowned code root from its origin"
assert_contains "$UPDATE_OUT" "synced: $ORIGIN_TIP" \
  "update did not report the home following the refreshed code root"
assert_equals "$ORIGIN_TIP" "$(as_foreign_root git -C "$REMOTE_HOME" rev-parse HEAD)" \
  "the home did not follow the refreshed code root"

# With no GIT_CONFIG_GLOBAL of its own, the account's global layer is BOTH the
# XDG file and ~/.gitconfig. A guarded command has to resolve every setting the
# unguarded one would - a proxy, a credential helper, an insteadOf rewrite -
# from either file, and keep ~/.gitconfig winning where the two disagree.
AGENT_HOME="$TMP_ROOT/agent-home"
mkdir -p "$AGENT_HOME/.config/git"
printf '[fm]\n\txdgonly = fromxdg\n\tlayered = fromxdg\n' > "$AGENT_HOME/.config/git/config"
printf '[fm]\n\tuseronly = fromuser\n\tlayered = fromuser\n' > "$AGENT_HOME/.gitconfig"

with_agent_home() { # <key> [guarded]
  # shellcheck disable=SC2016 # The inner shell expands these, not this one.
  env -u GIT_CONFIG_GLOBAL -u XDG_CONFIG_HOME \
    HOME="$AGENT_HOME" GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash -c '
      if [ -n "${3:-}" ]; then
        . "$1/bin/fm-git-code-root-lib.sh"
        fm_git_code_root_run "$2" git config --get "$4"
      else
        git config --get "$4"
      fi
    ' bash "$ROOT" "$CODE_ROOT" "${2:-}" "$1" 2>/dev/null
}

for FM_KEY in fm.xdgonly fm.useronly fm.layered; do
  UNGUARDED=$(with_agent_home "$FM_KEY")
  [ -n "$UNGUARDED" ] || fail "the global-config fixture does not resolve $FM_KEY unguarded"
  assert_equals "$UNGUARDED" "$(with_agent_home "$FM_KEY" guarded)" \
    "the guarded invocation resolved $FM_KEY differently than git would have"
done

SIBLING="$TMP_ROOT/sibling-root"
git clone --quiet -- "$CODE_ROOT" "$SIBLING" || fail "cannot stage the sibling repository"
# shellcheck disable=SC2016 # The inner shell expands these, not this one.
as_foreign_root bash -c '
  . "$1/bin/fm-git-code-root-lib.sh"
  fm_git_code_root_run "$2" git -C "$3" rev-parse HEAD
' bash "$ROOT" "$CODE_ROOT" "$SIBLING" >/dev/null 2>&1 \
  && fail "the code-root exception wrongly authorized an unrelated repository"

as_foreign_root git -C "$CODE_ROOT" rev-parse HEAD >/dev/null 2>&1 \
  && fail "the lifecycle left a durable ownership exception for the code root"

pass "remote sync reads and imports from a code root owned by another account"
