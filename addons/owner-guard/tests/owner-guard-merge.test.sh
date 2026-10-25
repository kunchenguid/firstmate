#!/usr/bin/env bash
# Fixture proof for the merge-gate scan: a throwaway HOME/XDG and global
# gitconfig, a home holding only made-up patterns and an existing merge
# gate, a local bare repo standing in for the GitHub remote (url insteadOf)
# and a stub gh. A PR whose later commit adds a leak (committed and pushed
# with hooks skipped, as the pipeline does) is refused at file:line; a clean
# PR passes; the previous gate still runs and its refusal still refuses; a
# forge failure refuses; install twice is a no-op; uninstall restores.
# Usage: owner-guard/tests/owner-guard-merge.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d)
trap 'chmod -R u+w -- "$d"; rm -rf -- "$d"' EXIT
for v in $(env | sed -n 's/^\(GIT_CONFIG_[A-Z_0-9]*\)=.*/\1/p'); do unset "$v"; done
unset GIT_CONFIG_PARAMETERS GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_DIR GIT_WORK_TREE
export HOME=$d/home XDG_DATA_HOME=$d/data XDG_CONFIG_HOME=$d/xdg TMPDIR=$d GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$d/global.gitconfig
FM=$d/fm
mkdir -p "$HOME" "$FM/config" "$XDG_CONFIG_HOME" "$d/bin" "$d/forge/acme"
: >"$d/global.gitconfig"
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok: $1"; else printf 'FAIL: %s\n  want text: %s\n  got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
printf '%s\n' '# fixture-only patterns' 'testguard-fake-surname' >"$FM/config/owner-details-patterns"
URL=https://github.com/acme/widget/pull/7

# The "forge": GitHub URLs resolve to a local bare repo that serves fetch-by-sha like GitHub.
git config --global url."$d/forge/".insteadOf https://github.com/
git init -q --bare -b main "$d/forge/acme/widget.git"
git -C "$d/forge/acme/widget.git" config uploadpack.allowAnySHA1InWant true
printf '#!/bin/sh\n[ ! -e %q ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }\necho main\n' "$d/gh-fail" >"$d/bin/gh"
chmod +x "$d/bin/gh"
export PATH=$d/bin:$PATH

# The home's existing merge gate: logs its args, exits with the code in prev-rc.
cat >"$FM/config/merge-gate" <<EOF
#!/bin/sh
echo "prev-gate \$*" >>'$d/gate.log'
exit "\$(cat '$d/prev-rc' 2>/dev/null || echo 0)"
EOF
chmod +x "$FM/config/merge-gate"
cp "$FM/config/merge-gate" "$d/orig-gate"

out=$("$SRC/install.sh" --dry-run "$FM")
has "dry run lists the gate move" "$out" "would move: $FM/config/merge-gate"
check "dry run left the gate alone" "$(cmp -s "$FM/config/merge-gate" "$d/orig-gate" && echo same)" same
out=$("$SRC/install.sh" "$FM")
has "install chains the previous gate" "$out" "kept: previous merge gate chained"
check "previous gate kept aside" "$(cmp -s "$FM/config/merge-gate.pre-owner-guard" "$d/orig-gate" && echo same)" same
cp "$FM/config/merge-gate" "$d/our-gate"
out=$("$SRC/install.sh" "$FM")
has "second install keeps the gate" "$out" "kept: $FM/config/merge-gate already runs"
check "second install changed nothing" "$(cmp -s "$FM/config/merge-gate" "$d/our-gate" && cmp -s "$FM/config/merge-gate.pre-owner-guard" "$d/orig-gate" && echo same)" same
cp "$d/orig-gate" "$FM/config/merge-gate" # a shim rewritten over ours, then install rerun
"$SRC/install.sh" "$FM" >/dev/null
check "re-chain after the gate is rewritten over ours" "$(cmp -s "$FM/config/merge-gate" "$d/our-gate" && cmp -s "$FM/config/merge-gate.pre-owner-guard" "$d/orig-gate" && echo same)" same

git init -q -b main "$d/work"
git -C "$d/work" remote add origin https://github.com/acme/widget.git
wcommit() { git -C "$d/work" -c core.hooksPath=/dev/null -c user.name=You -c user.email=you@example.com commit -q "$@"; }
printf 'one\n' >"$d/work/notes.txt"
git -C "$d/work" add notes.txt && wcommit -m base
git -C "$d/work" push -q --no-verify origin main
gate() { env FM_HOME="$FM" "$FM/config/merge-gate" "$@" 2>&1; }
# The standalone doctor catches both missing guard files and missing global wiring.
out=$("$SRC/doctor.sh" "$FM" 2>&1)
has "doctor confirms installed guard" "$out" "$FM is installed"
mv "$XDG_DATA_HOME/fm-owner-guard/owner-guard" "$d/guard.off"
git config --global --unset core.hooksPath
out=$("$SRC/doctor.sh" "$FM" 2>&1) && rc=0 || rc=$?
check "doctor fails when guard and global hook path are missing" "$rc" 1
has "doctor names home and missing executable" "$out" "$FM is missing executable $XDG_DATA_HOME/fm-owner-guard/owner-guard"
has "doctor names unset global hook path" "$out" "$FM has unset global core.hooksPath"
has "doctor prints recovery command" "$out" "owner-guard/install.sh $FM"
out=$(gate missing - HEAD -) && rc=0 || rc=$?
check "missing guard merge gate refuses explicitly" "$rc" 1
has "missing guard merge gate names recovery" "$out" "owner-guard is missing from this home; reinstall"
mv "$d/guard.off" "$XDG_DATA_HOME/fm-owner-guard/owner-guard"
"$SRC/install.sh" "$FM" >/dev/null

git -C "$d/work" checkout -q -b clean
printf 'two\n' >>"$d/work/notes.txt" && wcommit -am clean
git -C "$d/work" push -q --no-verify origin clean
head=$(git -C "$d/work" rev-parse HEAD)
: >"$d/gate.log"
out=$(gate t1 "$d/work" "$head" "$URL") && rc=0 || rc=$?
check "clean PR passes" "$rc" 0
has "clean PR says scanned" "$out" "merge scan clean"
check "clean scan leaves no scratch repo or error" "$(ls -d "$d"/tmp.*/r.git 2>/dev/null; printf '%s' "$out" | grep -c 'unbound')" 0
check "previous gate ran with the same args" "$(cat "$d/gate.log")" "prev-gate t1 $d/work $head $URL"
echo 3 >"$d/prev-rc"
out=$(gate t1 "$d/work" "$head" "$URL") && rc=0 || rc=$?
check "previous gate refusal still refuses" "$rc" 3
rm -f "$d/prev-rc"

# A leak added by a middle commit (hooks skipped, as a pipeline fix round
# commits and pushes), then a clean commit on top.
git -C "$d/work" checkout -q -b leak main
printf 'two\nreach testguard-fake-surname here\n' >>"$d/work/notes.txt" && git -C "$d/work" add notes.txt && wcommit -m 'fix round'
printf 'tidy\n' >"$d/work/other.txt" && git -C "$d/work" add other.txt && wcommit -m tidy
git -C "$d/work" push -q --no-verify origin leak
head=$(git -C "$d/work" rev-parse HEAD)
: >"$d/gate.log"
out=$(gate t2 - "$head" "$URL") && rc=0 || rc=$?
check "leak PR merge refused" "$rc" 1
has "refusal prints file:line" "$out" "notes.txt:3"
has "refusal is the guard's text" "$out" "owner-guard: merge refused: 1 added line(s) match protected owner details"
check "previous gate not run after a refusal" "$(cat "$d/gate.log")" ""
out=$(gate t2 "$d/work" "$head" "$URL") && rc=0 || rc=$?
check "leak PR refused with a worktree too" "$rc" 1

# Forge and fetch failures refuse: never merge unscanned.
touch "$d/gh-fail"
out=$(gate t3 - "$head" "$URL") && rc=0 || rc=$?
check "forge failure refuses" "$rc" 1
has "forge failure names the cause" "$out" "HTTP 502: Bad Gateway"
rm -f "$d/gh-fail"
printf 'unpushed\n' >"$d/work/u.txt" && git -C "$d/work" add u.txt && wcommit -m unpushed
out=$(gate t3 - "$(git -C "$d/work" rev-parse HEAD)" "$URL") && rc=0 || rc=$?
check "unfetchable head refuses" "$rc" 1
has "fetch failure says unscanned" "$out" "nothing merges unscanned"

# A missing patterns file allows with one note (unchanged behavior), and the previous gate still runs.
mv "$FM/config/owner-details-patterns" "$d/patterns.off"
: >"$d/gate.log"
out=$(gate t4 - "$head" "$URL") && rc=0 || rc=$?
check "missing patterns allows" "$rc" 0
has "missing patterns notes it" "$out" "no owner-details patterns configured"
check "previous gate ran without patterns" "$(cat "$d/gate.log")" "prev-gate t4 - $head $URL"
mv "$d/patterns.off" "$FM/config/owner-details-patterns"

"$SRC/install.sh" --uninstall "$FM" >/dev/null
check "uninstall restores the previous gate" "$(cmp -s "$FM/config/merge-gate" "$d/orig-gate" && echo same)" same
check "uninstall drops the aside copy" "$([ -e "$FM/config/merge-gate.pre-owner-guard" ] && echo there || echo gone)" gone
rm -f "$FM/config/merge-gate"
"$SRC/install.sh" "$FM" >/dev/null
"$SRC/install.sh" --uninstall "$FM" >/dev/null
check "uninstall removes a gate that had no predecessor" "$([ -e "$FM/config/merge-gate" ] && echo there || echo gone)" gone

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all owner-guard merge-gate checks passed"
