#!/usr/bin/env bash
# End-to-end: a pooled-style lane worktree whose shared clone .git/config carries a stray identity
# (t <t@e.c>), launched the way the fork's fm-spawn runs config/launch-env-hook, against a throwaway HOME and home.
# With FM_ROOT set to a firstmate checkout, the lane also gets that checkout's AI-trailer hooks dir layered on top,
# as a real spawn does. Usage: [FM_ROOT=<firstmate>] git-identity/tests/git-identity.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d)
# The fork's trailer hooks dir is read-only by design.
trap 'chmod -R u+w -- "$d"; rm -rf -- "$d"' EXIT
# A lane running this test passes its own GIT_CONFIG_* down; start from none.
for v in $(env | sed -n 's/^\(GIT_CONFIG_[A-Z_0-9]*\)=.*/\1/p'); do unset "$v"; done
unset GIT_CONFIG_PARAMETERS GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_DIR GIT_WORK_TREE
export HOME=$d/home XDG_DATA_HOME=$d/data XDG_CONFIG_HOME=$d/xdg TMPDIR=$d GIT_CONFIG_NOSYSTEM=1
FM=$d/fm
mkdir -p "$HOME" "$FM/config" "$FM/bin" "$XDG_CONFIG_HOME"
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok: $1"; else printf 'FAIL: %s\n  want text: %s\n  got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
ME=you@example.com
YOU=You

# Origin with an existing commit and a forge-made squash commit (committer GitHub <noreply@github.com>) on main.
git init -q --bare -b main "$d/origin.git"
git clone -q "$d/origin.git" "$d/seed" 2>/dev/null
git -C "$d/seed" -c user.name="$YOU" -c user.email=$ME commit -q --allow-empty -m base
GIT_COMMITTER_NAME=GitHub GIT_COMMITTER_EMAIL=noreply@github.com \
  git -C "$d/seed" -c user.name="$YOU" -c user.email=$ME commit -q --allow-empty -m 'feat: squash (#1)'
git -C "$d/seed" push -q origin main
# The project clone the pool shares, with the stray identity in its .git/config, its own pre-push hook that logs
# its stdin, and a pooled lane worktree.
git clone -q "$d/origin.git" "$d/clone"
git -C "$d/clone" config user.email t@e.c
git -C "$d/clone" config user.name t
printf '#!/bin/sh\ncat >>%q\n' "$d/repo-hook.log" >"$d/clone/.git/hooks/pre-push"
chmod +x "$d/clone/.git/hooks/pre-push"
git -C "$d/clone" worktree add -q -b lane "$d/wt" origin/main
WT=$d/wt
ident() { git -C "$WT" log -1 --format='%an <%ae> / %cn <%ce>'; }

# (a) Without the add-on the leak reproduces.
git -C "$WT" commit -q --allow-empty -m 'no add-on'
check "without the add-on a lane commit carries the stray identity" "$(ident)" "t <t@e.c> / t <t@e.c>"
git -C "$WT" reset -q --hard origin/main

# (b) install.sh: --dry-run writes nothing; a real install is idempotent and backs up a different hook once.
echo 'echo old' >"$FM/config/launch-env-hook"
out=$("$SRC/install.sh" --dry-run --email "$ME" --name "$YOU" "$FM")
has "dry run says so" "$out" "dry run: nothing written"
has "dry run names the backup" "$out" "would back up: $FM/config/launch-env-hook"
check "dry run leaves no install" "$(find "$XDG_DATA_HOME" -type f 2>/dev/null | wc -l)" 0
check "dry run leaves the hook" "$(cat "$FM/config/launch-env-hook")" "echo old"
# (b0) With no --email/--name and nothing in git config, install stops instead of a fallback identity.
out=$("$SRC/install.sh" --dry-run "$FM" 2>&1) && rc=0 || rc=$?
check "install without identity stops" "$rc" 1
has "install without identity says why" "$out" "no identity"
out=$("$SRC/install.sh" --email "$ME" --name "$YOU" "$FM")
has "install notes a home without the fork hook" "$out" "does not run config/launch-env-hook yet"
check "install backed up the old hook" "$(cat "$FM"/config/launch-env-hook.bak-git-identity-*)" "echo old"
snap() { (cd "$d" && find data fm -type f -print0 | sort -z | xargs -0 sha256sum); }
before=$(snap)
echo 'launch-env-hook' >"$FM/bin/fm-spawn.sh"
out=$("$SRC/install.sh" "$FM")
rm "$FM/bin/fm-spawn.sh"
check "rerun changes nothing" "$(snap)" "$before"
check "pinned identity" "$(git config -f "$XDG_DATA_HOME/fm-git-identity/identity.gitconfig" user.email)" "$ME"

# (c) The lane launch: the hook runs in the pane at the worktree, then the launch sources its export.
lane() {
  (
    cd "$WT"
    "$FM/config/launch-env-hook" "$d/env.sh"
    # shellcheck source=/dev/null
    . "$d/env.sh"
    if [ -n "${FM_ROOT:-}" ]; then
      "$FM_ROOT/bin/fm-git-strip-ai-trailers.sh" install "$d/fm-hooks" "$WT"
      "$FM_ROOT/bin/fm-git-strip-ai-trailers.sh" env-file "$d/fm-hooks" "$d/fm-env.sh"
      # shellcheck source=/dev/null
      . "$d/fm-env.sh"
    fi
    "$@"
  )
}
lane git commit -q --allow-empty -m 'lane work'
check "with the add-on a lane commit carries the pinned identity" "$(ident)" "$YOU <$ME> / $YOU <$ME>"
lane git -c user.name=t -c user.email=t@e.c commit -q --allow-empty -m 'hand-made t commit'
bad=$(git -C "$WT" rev-parse --short HEAD)
out=$(lane git push origin lane 2>&1) && rc=0 || rc=$?
check "push of a t@e.c commit is refused" "$rc" 1
has "refusal names the bad commit" "$out" "$bad  author=t <t@e.c>  committer=t <t@e.c>  hand-made t commit"
has "refusal prints the fix" "$out" "git rebase -r --exec 'git commit --amend --no-edit --reset-author' $bad~1"
check "refused push reached nothing" "$(git -C "$d/origin.git" branch --list lane)" ""
check "refused push skipped the repo's own hook" "$(cat "$d/repo-hook.log" 2>/dev/null)" ""
git -C "$WT" reset -q --hard HEAD~1
out=$(lane git push -q origin lane 2>&1) && rc=0 || rc=$?
check "push of existing commits on a forge-made base passes" "$rc" 0
check "forge-made commit is in the pushed history" "$(git -C "$d/origin.git" log -1 --format=%ce lane~1)" noreply@github.com
has "repo's own pre-push hook ran with git's stdin" "$(cat "$d/repo-hook.log" 2>/dev/null)" "refs/heads/lane $(git -C "$WT" rev-parse HEAD) refs/heads/lane"

# (d) A pushed commit whose inspection fails (its object is gone, as when gc prunes it mid-walk) refuses the push
# instead of letting it through unchecked. The hook interface is driven directly: git rewrites PATH for hooks, so
# the failure is produced with a real missing object rather than a shimmed git.
git -C "$WT" -c user.name=t -c user.email=t@e.c commit -q --allow-empty -m uninspectable
missing=$(printf x | git hash-object --stdin)
out=$(lane "$XDG_DATA_HOME/fm-git-identity/git-identity" hook pre-push \
  <<<"refs/heads/lane $missing refs/heads/lane $(git -C "$d/origin.git" rev-parse refs/heads/lane)" 2>&1) && rc=0 || rc=$?
check "an inspection failure refuses the push" "$rc" 1
has "refusal names the uninspectable push" "$out" "cannot inspect pushed commits"
git -C "$WT" reset -q --hard HEAD~1

# (e) A repository outside the lane's clone (a test fixture) keeps its identity and pushes freely.
git init -q --bare "$d/fx.git"
git init -q "$d/fx"
git -C "$d/fx" config user.email t@t
git -C "$d/fx" config user.name t
lane git -C "$d/fx" commit -q --allow-empty -m fixture
check "fixture repo keeps its own identity" "$(git -C "$d/fx" log -1 --format=%ae)" t@t
lane git -C "$d/fx" push -q "$d/fx.git" HEAD:refs/heads/main && rc=0 || rc=$?
check "fixture push is not checked" "$rc" 0

# (f) The allowed identity is settable: an older commit is refused under another configured email.
"$SRC/install.sh" --email other@example.com "$FM" >/dev/null
lane git commit -q --allow-empty -m 'after email change'
check "--email changes the pinned identity" "$(git -C "$WT" log -1 --format=%ae)" other@example.com
lane git -c user.email=$ME commit -q --allow-empty -m 'old identity'
out=$(lane git push origin lane 2>&1) && rc=0 || rc=$?
check "push under a changed email refuses the old one" "$rc" 1
has "refusal names the configured email" "$out" "not made as other@example.com"

if [ "$fails" -eq 0 ]; then echo "PASS"; else echo "FAILED: $fails"; exit 1; fi
