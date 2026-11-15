#!/usr/bin/env bash
# tests/fm-project-origin.test.sh - which project origins seeding accepts.
#
# Firstmate supplies a project's origin instead of discovering it from a local
# clone, and the receiving host re-validates whatever reached it, so this
# validator is the boundary that keeps a supplied value from reaching git as an
# executable transport or as a stray option. The ext:: case is exercised against
# real git first, so the refusal is pinned to a demonstrated hazard rather than
# to a string someone once worried about.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-project-origin-lib.sh
. "$ROOT/bin/fm-project-origin-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-origin)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")

accepts() {
  fm_project_origin_safe "$1" || fail "refused an ordinary clone URL: $1"
}
refuses() {
  ! fm_project_origin_safe "$1" || fail "accepted an origin git must never be handed: $1"
}

fm_git_init_commit "$TMP_ROOT/source"
git clone --quiet --bare "$TMP_ROOT/source" "$TMP_ROOT/source.git"

# Firstmate is a shared template, so acceptance is decided by structure alone.
# No host, domain, or forge is privileged: this matrix deliberately leads with
# non-GitHub forges and hosts nobody else has heard of, and every one of them
# must pass for the same structural reason GitHub does.
accepts 'https://bitbucket.org/team/app.git'
accepts 'https://git.example.com/org/app.git'
accepts 'https://git.example.com:8443/org/app.git'
accepts 'https://gitlab.self.hosted/group/subgroup/app.git'
accepts 'ssh://git@gitlab.self.hosted:2222/group/subgroup/app.git'
accepts 'https://codeberg.org/user/app.git'
accepts 'git://git.sr.ht/~user/app'
accepts 'http://gitea.lan:3000/user/app.git'
accepts 'https://user:token@git.example.com/org/app.git'
accepts 'git@host.internal:group/app.git'
accepts 'build-mac.local:/srv/git/app.git'
accepts 'git@my_host:app.git'
accepts 'git@192.168.1.10:/srv/git/app.git'
accepts 'ssh://git@[2001:db8::1]:22/srv/git/app.git'
accepts '[2001:db8::1]:/srv/git/app.git'
accepts 'git@[2001:db8::1]:/srv/git/app.git'
accepts 'https://github.com/kunchenguid/firstmate.git'
accepts 'git@github.com:kunchenguid/firstmate.git'
accepts "file://$TMP_ROOT/source.git"
accepts "$TMP_ROOT/source.git"

# The accepted forms are not just spellings: the two a fixture can reach really
# do clone with the same plain command the remote host runs.
git clone --quiet -- "file://$TMP_ROOT/source.git" "$TMP_ROOT/via-file-url" \
  || fail "an accepted file:// origin did not clone"
git clone --quiet -- "$TMP_ROOT/source.git" "$TMP_ROOT/via-path" \
  || fail "an accepted absolute-path origin did not clone"
assert_present "$TMP_ROOT/via-file-url/README.md" "the file:// clone produced no worktree"
assert_present "$TMP_ROOT/via-path/README.md" "the absolute-path clone produced no worktree"
pass "ordinary clone URLs are accepted and clone with the command the remote host runs"

# A remote-helper transport is a command git runs whenever the cloning host's own
# configuration permits that protocol, and the parent cannot see that host's
# configuration. Prove the hazard is real before pinning the refusal that closes
# it, rather than trusting the cloning host's default to stay strict.
cat > "$FAKEBIN/fm-origin-probe" <<SH
#!/usr/bin/env bash
touch '$TMP_ROOT/helper-ran'
exit 1
SH
chmod +x "$FAKEBIN/fm-origin-probe"
PATH="$FAKEBIN:$PATH" git -c protocol.ext.allow=always clone --quiet -- \
  'ext::fm-origin-probe' "$TMP_ROOT/via-helper" >/dev/null 2>&1 || true
assert_present "$TMP_ROOT/helper-ran" \
  "the fixture could not demonstrate that git executes an ext:: origin"

refuses 'ext::fm-origin-probe'
refuses 'ext::sh -c whoami'
refuses 'transport::address'
refuses '--upload-pack=/usr/bin/touch'
refuses '-oProxyCommand=touch /tmp/pwned'
refuses 'javascript://example.com/app.git'
refuses 'unknown://example.com/app.git'
refuses 'https:///repo.git'
refuses 'ssh://:2222/repo.git'
refuses 'ssh://-oProxyCommand=touch@host/repo.git'
refuses 'https://@/repo.git'
refuses 'https://[notipv6/repo.git'
refuses 'https://host:notaport/repo.git'
refuses 'ssh://-host/repo.git'
refuses 'git@-host:path'
refuses 'https://example.com/app.git
https://evil.example.com/app.git'
refuses 'https://example.com/a pp.git'
refuses ''
refuses 'relative/path.git'
refuses 'file://relative.git'
refuses '[notanaddress]:/srv/git/app.git'

# A local or file: origin names a path on the cloning host's own filesystem, so
# traversal out of the named directory is refused rather than transported.
refuses '/srv/git/../../etc/app.git'
refuses 'file:///srv/git/../../etc/app.git'
refuses '/srv/git/..'
pass "executable transports, option-shaped values, and unusable spellings are refused"

echo "ALL TESTS PASSED"
