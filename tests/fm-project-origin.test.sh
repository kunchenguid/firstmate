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

# Forge routing uses origin identity rather than the project name. GitHub is
# recognized by its canonical host, while a self-hosted GitLab host needs glab's
# own exact-host authentication evidence. An unrelated host and a fetch/push
# split are concrete ambiguities, never silent guesses.
ROUTING_HOME="$TMP_ROOT/routing-home"
ROUTING_XDG="$TMP_ROOT/routing-xdg"
mkdir -p "$ROUTING_HOME" "$ROUTING_XDG"
cat > "$FAKEBIN/glab" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' sa.git-labs.com '*) exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/glab"
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' github.enterprise.example '*) exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/gh"
make_routing_repo() {
  local name=$1 origin=$2 repo="$TMP_ROOT/routing-$1"
  git init -q "$repo"
  git -C "$repo" remote add origin "$origin"
  printf '%s\n' "$repo"
}
export HOME="$ROUTING_HOME" XDG_CONFIG_HOME="$ROUTING_XDG"
GITHUB_ROUTE_REPO=$(make_routing_repo github 'git@github.com:echo/firstmate.git')
fm_project_forge_from_repo "$GITHUB_ROUTE_REPO" || fail "GitHub origin was not classified"
[ "$FM_PROJECT_FORGE" = github ] || fail "GitHub origin classified as '$FM_PROJECT_FORGE'"
github_route=$(fm_project_forge_instructions)
assert_contains "$github_route" 'gh-axi' "GitHub route omitted gh-axi"
# shellcheck disable=SC2016 # Backticks are literal route text.
assert_contains "$github_route" 'ordinary `git push`' "GitHub route omitted ordinary git push"

GITHUB_ENTERPRISE_REPO=$(make_routing_repo github-enterprise 'ssh://git@github.enterprise.example/echo/firstmate.git')
PATH="$FAKEBIN:$PATH" fm_project_forge_from_repo "$GITHUB_ENTERPRISE_REPO" \
  || fail "authenticated GitHub Enterprise origin was not classified"
[ "$FM_PROJECT_FORGE" = github ] || fail "GitHub Enterprise origin classified as '$FM_PROJECT_FORGE'"

GITLAB_ROUTE_REPO=$(make_routing_repo gitlab 'git@sa.git-labs.com:echo/ai_operation-master.git')
PATH="$FAKEBIN:$PATH" fm_project_forge_from_repo "$GITLAB_ROUTE_REPO" \
  || fail "self-hosted GitLab origin was not classified through glab"
[ "$FM_PROJECT_FORGE" = gitlab ] || fail "self-hosted GitLab origin classified as '$FM_PROJECT_FORGE'"
gitlab_route=$(PATH="$FAKEBIN:$PATH" fm_project_forge_instructions)
# shellcheck disable=SC2016 # Backticks are literal route text.
assert_contains "$gitlab_route" 'authenticated `glab`' "GitLab route omitted authenticated glab"
# shellcheck disable=SC2016 # Backticks are literal route text.
assert_contains "$gitlab_route" 'ordinary `git push`' "GitLab route omitted ordinary git push"
assert_contains "$gitlab_route" 'never disable TLS certificate verification' "GitLab route weakened TLS guidance"
assert_not_contains "$gitlab_route" 'gh-axi for this project' "GitLab route still directs gh-axi"

UNKNOWN_ROUTE_REPO=$(make_routing_repo unknown 'ssh://git@codeberg.example/team/app.git')
if PATH="$FAKEBIN:$PATH" fm_project_forge_from_repo "$UNKNOWN_ROUTE_REPO"; then
  fail "unknown origin was silently classified as a forge"
fi
assert_contains "$FM_PROJECT_FORGE_ERROR" 'not recognized' "unknown origin did not report a concrete ambiguity"
unknown_route=$(fm_project_forge_instructions ambiguous)
assert_contains "$unknown_route" 'Do not guess a forge CLI' "unknown route did not stop guessing"
AMBIGUOUS_ROUTE_REPO=$(make_routing_repo ambiguous 'git@github.com:echo/firstmate.git')
git -C "$AMBIGUOUS_ROUTE_REPO" remote set-url --add --push origin 'git@sa.git-labs.com:echo/firstmate.git'
if PATH="$FAKEBIN:$PATH" fm_project_forge_from_repo "$AMBIGUOUS_ROUTE_REPO"; then
  fail "conflicting fetch/push origins were silently accepted"
fi
assert_contains "$FM_PROJECT_FORGE_ERROR" 'different forge routes' "conflicting origins did not name the ambiguity"

# Git's effective push URL includes url.*.pushInsteadOf rewrites even when no
# remote.origin.pushurl is configured. Routing must inspect that result rather
# than classifying the fetch URL and sending a branch to the wrong forge.
REWRITTEN_ROUTE_REPO=$(make_routing_repo rewritten 'git@github.com:echo/firstmate.git')
git -C "$REWRITTEN_ROUTE_REPO" config \
  'url.git@sa.git-labs.com:.pushInsteadOf' 'git@github.com:'
if PATH="$FAKEBIN:$PATH" fm_project_forge_from_repo "$REWRITTEN_ROUTE_REPO"; then
  fail "a pushInsteadOf rewrite to GitLab was silently accepted as GitHub"
fi
assert_contains "$FM_PROJECT_FORGE_ERROR" 'different forge routes' \
  "effective push URL rewrite did not name the forge ambiguity"

# Two services on one hostname but different HTTP ports are distinct forge
# endpoints. Preserve those ports in identity and refuse the collision.
PORT_FAKEBIN="$TMP_ROOT/port-fake"
mkdir -p "$PORT_FAKEBIN"
cat > "$PORT_FAKEBIN/glab" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' git.example.com:8443 '*|*' git.example.com:9443 '*) exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$PORT_FAKEBIN/glab"
PORT_ROUTE_REPO=$(make_routing_repo ports 'https://git.example.com:8443/echo/firstmate.git')
git -C "$PORT_ROUTE_REPO" remote set-url --add --push origin \
  'https://git.example.com:9443/echo/firstmate.git'
if PATH="$PORT_FAKEBIN:$PATH" fm_project_forge_from_repo "$PORT_ROUTE_REPO"; then
  fail "different self-hosted forge ports were silently treated as one endpoint"
fi
assert_contains "$FM_PROJECT_FORGE_ERROR" 'ambiguous' \
  "different forge ports did not report an ambiguity"

pass "origin-based forge routing selects GitHub and self-hosted GitLab and refuses unknown or conflicting origins"

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
