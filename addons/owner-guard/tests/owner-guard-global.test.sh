#!/usr/bin/env bash
# Fixture proof for the machine-wide guard: a throwaway HOME/XDG and temp
# global gitconfig plus a home holding only made-up patterns. A plain-shell
# leak commit is refused with file:line, a lane-env leak is refused, a
# plain-shell leak push is refused, clean commits and pushes pass, the
# repo's own hooks and a previous global hooks dir still run, install twice
# is a no-op, and uninstall restores the previous global hooksPath.
# Usage: owner-guard/tests/owner-guard-global.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
GISRC=$(cd "$SRC/../git-identity" && pwd -P)
d=$(mktemp -d)
trap 'chmod -R u+w -- "$d"; rm -rf -- "$d"' EXIT
for v in $(env | sed -n 's/^\(GIT_CONFIG_[A-Z_0-9]*\)=.*/\1/p'); do unset "$v"; done
unset GIT_CONFIG_PARAMETERS GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_DIR GIT_WORK_TREE
export HOME=$d/home XDG_DATA_HOME=$d/data XDG_CONFIG_HOME=$d/xdg TMPDIR=$d GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$d/global.gitconfig
FM=$d/fm
mkdir -p "$HOME" "$FM/config" "$XDG_CONFIG_HOME"
: >"$d/global.gitconfig"
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok: $1"; else printf 'FAIL: %s\n  want text: %s\n  got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
ME=you@example.com
printf '%s\n' '# fixture-only patterns' '' 'testguard-fake-surname' 'guardtest[0-9]{3}@example\.test' >"$FM/config/owner-details-patterns"
export FM_HOME=$FM
GH=$d/data/fm-owner-guard/hooks
plain() (cd "$d/plain" && env -u FM_HOME "$@")

# A previous global hooks dir, to prove chaining and restore.
mkdir -p "$d/prevhooks"
printf '#!/bin/sh\necho prev-commit >>%q\n' "$d/hook.log" >"$d/prevhooks/pre-commit"
printf '#!/bin/sh\necho prev-push >>%q\n' "$d/hook.log" >"$d/prevhooks/pre-push"
chmod +x "$d/prevhooks/pre-commit" "$d/prevhooks/pre-push"
git config --global core.hooksPath "$d/prevhooks"

git init -q --bare -b main "$d/origin.git"
git init -q -b main "$d/plain"
git -C "$d/plain" remote add origin "$d/origin.git"
git -C "$d/plain" -c user.name=You -c user.email=$ME commit -q --allow-empty -m base
git -C "$d/plain" push -q origin main
printf '#!/bin/sh\necho repo-commit >>%q\n' "$d/hook.log" >"$d/plain/.git/hooks/pre-commit"
printf '#!/bin/sh\necho repo-push >>%q\n' "$d/hook.log" >"$d/plain/.git/hooks/pre-push"
chmod +x "$d/plain/.git/hooks/pre-commit" "$d/plain/.git/hooks/pre-push"

out=$("$SRC/install.sh" "$FM")
check "global hooksPath points at the guard" "$(git config --global --get core.hooksPath)" "$GH"
check "previous global hooksPath recorded" "$(cat "$d/data/fm-owner-guard/prev-hooks-path")" "$d/prevhooks"

printf 'reach testguard-fake-surname here\n' >"$d/plain/details.txt"
git -C "$d/plain" add details.txt
out=$(plain git -c user.name=You -c user.email=$ME commit -m 'bad commit' 2>&1) && rc=0 || rc=$?
check "plain-shell leak commit refused" "$rc" 1
has "refusal prints file:line" "$out" "details.txt:1"
check "refused commit kept nothing" "$(git -C "$d/plain" rev-list --count HEAD)" 1
git -C "$d/plain" rm -q --cached details.txt && rm -f "$d/plain/details.txt"

printf 'hello\n' >"$d/plain/clean.txt"
git -C "$d/plain" add clean.txt
plain git -c user.name=You -c user.email=$ME commit -q -m 'clean commit'
check "clean commit passes" "$?" 0
has "repo pre-commit still chained" "$(cat "$d/hook.log")" "repo-commit"
has "previous global pre-commit still chained" "$(cat "$d/hook.log")" "prev-commit"
plain git push origin main
check "clean push passes" "$?" 0
has "repo pre-push still chained" "$(cat "$d/hook.log")" "repo-push"
has "previous global pre-push still chained" "$(cat "$d/hook.log")" "prev-push"

printf 'me guardtest042@example.test\n' >"$d/plain/pushed.txt"
git -C "$d/plain" add pushed.txt
plain git -c user.name=You -c user.email=$ME commit -q --no-verify -m 'bad push'
out=$(plain git push origin main 2>&1) && rc=0 || rc=$?
check "plain-shell leak push refused" "$rc" 1
has "push refusal prints file:line" "$out" "pushed.txt:1"
check "refused push reached nothing" "$(git -C "$d/origin.git" rev-parse refs/heads/main)" "$(git -C "$d/plain" rev-parse HEAD~1)"
git -C "$d/plain" reset -q --hard HEAD~1

# A bare repo's own server-side hooks still run under the global guard.
git init -q --bare -b main "$d/srv.git"
printf '#!/bin/sh\necho srv-pre >>%q\ncat >>%q\n' "$d/hook.log" "$d/hook.log" >"$d/srv.git/hooks/pre-receive"
printf '#!/bin/sh\necho srv-post >>%q\n' "$d/hook.log" >"$d/srv.git/hooks/post-receive"
chmod +x "$d/srv.git/hooks/pre-receive" "$d/srv.git/hooks/post-receive"
plain git push "$d/srv.git" main
srvlog=$(cat "$d/hook.log")
has "bare pre-receive still chained" "$srvlog" "srv-pre"
has "bare pre-receive got its ref lines" "$srvlog" "refs/heads/main"
has "bare post-receive still chained" "$srvlog" "srv-post"
printf '#!/bin/sh\nexit 1\n' >"$d/srv.git/hooks/pre-receive"
out=$(plain git push "$d/srv.git" +HEAD:refuse 2>&1) && rc=0 || rc=$?
check "refusing bare pre-receive still refuses" "$rc" 1

# A push whose ref lines exceed the pipe buffer still succeeds when the
# repo's own pre-receive stops reading after one line: the chained hook's
# verdict decides, not the replay.
git init -q --bare -b main "$d/big.git"
printf '#!/bin/sh\nread first\nexit 0\n' >"$d/big.git/hooks/pre-receive"
chmod +x "$d/big.git/hooks/pre-receive"
i=0; while [ "$i" -lt 1000 ]; do git -C "$d/plain" branch "b$i" >/dev/null; i=$((i+1)); done
plain git push -q "$d/big.git" --all
check "big push to an early-exit pre-receive passes" "$?" 0

# Both chained post-rewrite consumers get git's rewritten-commit lines.
printf '#!/bin/sh\ncat >>%q\n' "$d/rw.log" >"$d/prevhooks/post-rewrite"
printf '#!/bin/sh\ncat >>%q\n' "$d/rw.log" >"$d/plain/.git/hooks/post-rewrite"
chmod +x "$d/prevhooks/post-rewrite" "$d/plain/.git/hooks/post-rewrite"
: >"$d/rw.log"
plain git -C "$d/plain" -c user.name=You -c user.email=$ME commit -q --amend -m 'clean commit'
check "both chained post-rewrite consumers fed" "$(grep -c . "$d/rw.log")" "2"
check "post-rewrite replay identical to both" "$(sort -u "$d/rw.log" | wc -l)" "1"

# proc-receive speaks a NUL-bearing pkt-line protocol: both chained
# consumers must see git's exact bytes (version pkt with NUL caps, command
# pkt, flushes).
printf '#!/bin/sh\ncat >%q\n' "$d/pv-prev.log" >"$d/prevhooks/proc-receive"
printf '#!/bin/sh\ncat >%q\n' "$d/pv-repo.log" >"$d/plain/.git/hooks/proc-receive"
chmod +x "$d/prevhooks/proc-receive" "$d/plain/.git/hooks/proc-receive"
printf '0020version=1\x00push-options atomic00000041aaaa 1111111111111111111111111111111111111111 refs/heads/pv\n0000' >"$d/pv-stream"
(cd "$d/plain" && "$GH/proc-receive" <"$d/pv-stream" >/dev/null)
check "proc-receive replay byte-exact to prev consumer" "$(cmp -s "$d/pv-stream" "$d/pv-prev.log" && echo same || echo diff)" "same"
check "proc-receive replay byte-exact to repo consumer" "$(cmp -s "$d/pv-stream" "$d/pv-repo.log" && echo same || echo diff)" "same"

# Lane env still refuses: the command-scope hooksPath wins over global, one verdict.
git clone -q "$d/origin.git" "$d/clone"
git -C "$d/clone" worktree add -q -b lane "$d/wt" origin/main
"$GISRC/install.sh" --email "$ME" --name You "$FM" >/dev/null
# shellcheck source=/dev/null
lane() (cd "$d/wt" && "$FM/config/launch-env-hook" "$d/env.sh" && . "$d/env.sh" && "$@")
printf 'reach testguard-fake-surname here\n' >"$d/wt/details.txt"
git -C "$d/wt" add details.txt
out=$(lane git commit -m 'lane leak' 2>&1) && rc=0 || rc=$?
check "lane leak refused" "$rc" 1
has "lane refusal prints file:line" "$out" "details.txt:1"

# A PATH holding only git (the ledger case: no bash, no coreutils): a ref
# update still runs the chained hooks, and a commit is refused by name, never
# allowed because a missing grep read as "no match".
gitonly=$d/gitonly
mkdir -p "$gitonly"
ln -s "$(command -v git)" "$gitonly/git"
gitonly_run() { (cd "$d/plain" && env PATH="$gitonly" "$@"); }
out=$(gitonly_run git branch probe-stripped 2>&1) && rc=0 || rc=$?
check "git branch with a git-only PATH passes" "$rc" 0
check "branch made under a git-only PATH" "$(git -C "$d/plain" rev-parse --verify -q refs/heads/probe-stripped >/dev/null && echo yes || echo no)" yes
gitonly_run git branch -D probe-stripped >/dev/null 2>&1 || true
out=$(gitonly_run git -c user.name=You -c user.email=$ME commit -q --allow-empty -m 'no tools' 2>&1) && rc=0 || rc=$?
check "commit with a git-only PATH is refused" "$rc" 1
has "refusal names the missing tool" "$out" "is not on PATH"

# Missing patterns file allows with one note line, outside lanes too.
mv "$FM/config/owner-details-patterns" "$d/patterns.off"
out=$(plain git -c user.name=You -c user.email=$ME commit -q --allow-empty -m 'no patterns' 2>&1) && rc=0 || rc=$?
check "missing patterns allows" "$rc" 0
has "missing patterns prints one note" "$out" "nothing to protect"
mv "$d/patterns.off" "$FM/config/owner-details-patterns"

# Install twice is a no-op.
before=$(git config --global --get core.hooksPath; cat "$d/data/fm-owner-guard/prev-hooks-path"; sha256sum "$GH"/pre-commit "$GH"/pre-push "$GH"/pre-receive "$GH"/post-receive)
out=$("$SRC/install.sh" "$FM")
after=$(git config --global --get core.hooksPath; cat "$d/data/fm-owner-guard/prev-hooks-path"; sha256sum "$GH"/pre-commit "$GH"/pre-push "$GH"/pre-receive "$GH"/post-receive)
check "second install changes nothing" "$after" "$before"

# Uninstall restores the previous global hooksPath; the guard stops firing.
out=$("$SRC/install.sh" --uninstall)
check "uninstall restores previous global hooksPath" "$(git config --global --get core.hooksPath)" "$d/prevhooks"
check "uninstall removes the wrappers" "$(ls "$GH" 2>/dev/null || echo gone)" "gone"
printf 'reach testguard-fake-surname here\n' >"$d/plain/after.txt"
git -C "$d/plain" add after.txt
plain git -c user.name=You -c user.email=$ME commit -q -m 'after uninstall'
check "leak passes once uninstalled" "$?" 0
REALHK_AFTER=$(git config --global --get core.hooksPath 2>/dev/null || true)
check "fixture global hooksPath restored" "$REALHK_AFTER" "$d/prevhooks"

if [ "$fails" -eq 0 ]; then echo "PASS"; else echo "FAILED: $fails"; exit 1; fi
