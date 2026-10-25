#!/usr/bin/env bash
# Fixture proof: a pooled-style lane worktree against a throwaway HOME, home
# and patterns file holding only made-up values. A matching commit is refused
# with file:line, a clean commit passes, a matching push is refused, a
# removal-only commit passes, and the repo's own pre-commit still chains.
# Usage: owner-guard/tests/owner-guard.test.sh
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
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok: $1"; else printf 'FAIL: %s\n  want text: %s\n  got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
ME=you@example.com
printf '%s\n' '# fixture-only patterns' '' 'testguard-fake-surname' 'guardtest[0-9]{3}@example\.test' >"$FM/config/owner-details-patterns"
export FM_HOME=$FM

git init -q --bare -b main "$d/origin.git"
git clone -q "$d/origin.git" "$d/clone"
git -C "$d/clone" -c user.name=You -c user.email=$ME commit -q --allow-empty -m base
git -C "$d/clone" push -q origin main
printf '#!/bin/sh\necho repo-hook >>%q\n' "$d/repo-hook.log" >"$d/clone/.git/hooks/pre-commit"
chmod +x "$d/clone/.git/hooks/pre-commit"
git -C "$d/clone" worktree add -q -b lane "$d/wt" origin/main
WT=$d/wt
"$GISRC/install.sh" --email "$ME" --name You "$FM" >/dev/null
out=$("$SRC/install.sh" "$FM")
has "install chains the hooks dir" "$out" "hooks.d"
# shellcheck source=/dev/null
lane() (cd "$WT" && "$FM/config/launch-env-hook" "$d/env.sh" && . "$d/env.sh" && "$@")
# shellcheck source=/dev/null
lanein() (cd "$1" && shift && "$FM/config/launch-env-hook" "$d/env.sh" && . "$d/env.sh" && "$@")

printf 'reach testguard-fake-surname here\n' >"$WT/details.txt"
git -C "$WT" add details.txt
out=$(lane git commit -m 'bad commit' 2>&1) && rc=0 || rc=$?
check "matching commit refused" "$rc" 1
has "refusal prints file:line" "$out" "details.txt:1"
has "refusal hints placeholders" "$out" "you@example.com"
check "refused commit kept nothing" "$(git -C "$WT" rev-list --count HEAD)" 1
printf 'hello\n' >"$WT/clean.txt"
git -C "$WT" add clean.txt
git -C "$WT" rm -q --cached details.txt && rm -f "$WT/details.txt"
out=$(lane git commit -q -m 'clean commit' 2>&1) && rc=0 || rc=$?
check "clean commit passes" "$rc" 0
has "repo pre-commit still chained" "$(cat "$d/repo-hook.log")" "repo-hook"
printf 'me guardtest042@example.test\n' >"$WT/pushed.txt"
git -C "$WT" add pushed.txt
lane git commit -q --no-verify -m 'bad push'
out=$(lane git push origin lane 2>&1) && rc=0 || rc=$?
check "matching push refused" "$rc" 1
has "push refusal prints file:line" "$out" "pushed.txt:1"
check "refused push reached nothing" "$(git -C "$d/origin.git" branch --list lane)" ""
git -C "$WT" reset -q --hard HEAD~1
printf 'reach testguard-fake-surname here\n' >"$WT/gone.txt"
git -C "$WT" add gone.txt
lane git commit -q --no-verify -m 'seeded'
printf 'scrubbed\n' >"$WT/gone.txt"
git -C "$WT" add gone.txt
out=$(lane git commit -q -m 'removal only' 2>&1) && rc=0 || rc=$?
check "removal-only commit passes" "$rc" 0
printf 'reach testguard-fake-surname here\n' >"$WT/fallback.txt"
git -C "$WT" add fallback.txt
out=$(FM_HOME=$d/empty lane git commit -m 'fallback' 2>&1) && rc=0 || rc=$?
check "lane home without patterns falls back to install home" "$rc" 1
has "fallback refusal prints file:line" "$out" "fallback.txt:1"
git -C "$WT" rm -q --cached fallback.txt && rm -f "$WT/fallback.txt"
# Missing patterns file allows with one note line.
mv "$FM/config/owner-details-patterns" "$d/patterns.off"
out=$(FM_HOME=$d/empty lane git commit -q --allow-empty -m 'no patterns' 2>&1) && rc=0 || rc=$?
check "missing patterns allows" "$rc" 0
has "missing patterns prints one note" "$out" "nothing to protect"
mv "$d/patterns.off" "$FM/config/owner-details-patterns"

# A pattern matches added-line content only, never the path or the line number.
printf '%s\n' '2024' >>"$FM/config/owner-details-patterns"
mkdir -p "$WT/docs"
printf 'clean text\n' >"$WT/docs/2024-report.md"
git -C "$WT" add docs/2024-report.md
out=$(lane git commit -m 'path match only' 2>&1) && rc=0 || rc=$?
check "pattern in path with clean content passes" "$rc" 0
printf 'year 2024 in content\n' >"$WT/leak-year.txt"
git -C "$WT" add leak-year.txt
out=$(lane git commit -m 'content match' 2>&1) && rc=0 || rc=$?
check "pattern in content refused" "$rc" 1
has "content match prints file:line" "$out" "leak-year.txt:1"
git -C "$WT" rm -q --cached leak-year.txt && rm -f "$WT/leak-year.txt"

# Added lines that look like diff syntax are still scanned, with correct file:line.
printf '++ testguard-fake-surname\nme guardtest042@example.test\n' >"$WT/café-notes.md"
git -C "$WT" add café-notes.md
out=$(lane git commit -m 'diff-like lines' 2>&1) && rc=0 || rc=$?
check "diff-like added lines refused" "$rc" 1
has "diff-like first line labeled" "$out" "café-notes.md:1"
has "diff-like second line labeled" "$out" "café-notes.md:2"
git -C "$WT" rm -q --cached café-notes.md && rm -f "$WT/café-notes.md"

# A first push to a remote with no refs (no remote default branch exists yet)
# is scanned like any other new branch instead of being deadlocked.
git init -q --bare "$d/empty-origin.git"
git init -q -b main "$d/fresh"
git -C "$d/fresh" remote add origin "$d/empty-origin.git"
printf 'hello\n' >"$d/fresh/readme.md"
git -C "$d/fresh" add readme.md
lanein "$d/fresh" git commit -q -m first
out=$(lanein "$d/fresh" git push -q -u origin main 2>&1) && rc=0 || rc=$?
check "first push to an empty remote passes" "$rc" 0
check "empty remote received the branch" "$(git -C "$d/empty-origin.git" rev-parse -q --verify refs/heads/main)" "$(git -C "$d/fresh" rev-parse HEAD)"
printf 'reach testguard-fake-surname here\n' >"$d/fresh/docs.md"
git -C "$d/fresh" add docs.md
lanein "$d/fresh" git commit -q --no-verify -m docs
out=$(lanein "$d/fresh" git push -q origin main:docs 2>&1) && rc=0 || rc=$?
check "new-branch push with details refused" "$rc" 1
has "new-branch refusal prints file:line" "$out" "docs.md:1"

# A root (orphan-branch) commit is scanned too.
git -C "$WT" checkout -q --orphan fresh-docs
git -C "$WT" rm -rq --cached .
printf 'reach testguard-fake-surname here\n' >"$WT/orphan.txt"
git -C "$WT" add orphan.txt
lane git commit -q --no-verify -m 'orphan leak'
out=$(lane git push origin fresh-docs 2>&1) && rc=0 || rc=$?
check "root-commit push refused" "$rc" 1
has "root-commit refusal prints file:line" "$out" "orphan.txt:1"
git -C "$WT" checkout -qf lane

# A commit whose contents cannot be inspected refuses the push.
git -C "$WT" checkout -qf -b corrupt origin/main
printf 'clean\n' >"$WT/seed.txt"
git -C "$WT" add seed.txt
lane git commit -q --no-verify -m seed
blob=$(git -C "$WT" rev-parse HEAD:seed.txt)
rm -f "$d/clone/.git/objects/${blob:0:2}/${blob:2}"
out=$(lane git push origin corrupt 2>&1) && rc=0 || rc=$?
check "unscannable commit refuses the push" "$rc" 1
check "unscannable push reached nothing" "$(git -C "$d/origin.git" rev-parse -q --verify refs/heads/corrupt)" ""

# A missing trailing newline never hides the following added line.
printf 'old' >"$d/fresh/nonnl.txt"
git -C "$d/fresh" add nonnl.txt
lanein "$d/fresh" git commit -q --no-verify -m 'seed without trailing newline'
printf 'old\nreach testguard-fake-surname here\n' >"$d/fresh/nonnl.txt"
git -C "$d/fresh" add nonnl.txt
out=$(lanein "$d/fresh" git commit -m 'nonewline leak' 2>&1) && rc=0 || rc=$?
check "missing-newline leak refused" "$rc" 1
has "missing-newline refusal prints file:line" "$out" "nonnl.txt:2"

if [ "$fails" -eq 0 ]; then echo "PASS"; else echo "FAILED: $fails"; exit 1; fi
