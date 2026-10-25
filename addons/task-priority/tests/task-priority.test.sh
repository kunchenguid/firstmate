#!/usr/bin/env bash
# Drives the real check and the real installer in a throwaway XDG_DATA_HOME: nothing real is touched.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

XDG_DATA_HOME=$T/xdg bash "$ROOT/install.sh" >/dev/null || fail "install"
CHECK=$T/xdg/fm-task-priority/check.sh
[ -x "$CHECK" ] || fail "installed check is not executable at a known path"
XDG_DATA_HOME=$T/xdg bash "$ROOT/install.sh" --dry-run | grep -q 'nothing written' || fail "dry run"

out=$("$CHECK" add t1 "a title" --kind ship 2>"$T/err"); rc=$?
[ "$rc" -eq 1 ] || fail "no priority must be refused (rc=$rc)"
grep -q -- '--priority 0|1|2|3' "$T/err" || fail "refusal must name the flag: $(cat "$T/err")"
[ -z "$out" ] || fail "a refusal prints nothing on stdout"

"$CHECK" add t1 "a title" --priority 7 2>"$T/err" >/dev/null && fail "priority 7 must be refused"
grep -q "not 0-3" "$T/err" || fail "out-of-range message"

out=$("$CHECK" add t1 "a title" --priority 2 --body "just text") || fail "priority 2 must pass"
[ "$out" = "release: later" ] || fail "release must default to later, got: $out"

out=$("$CHECK" create t1 "a title" --priority=0 --body "release: v2.1") || fail "explicit release must pass"
[ "$out" = "release: v2.1" ] || fail "explicit release in body, got: $out"

printf 'notes\nrelease: v3\n' > "$T/body.md"
out=$("$CHECK" add t1 "a title" --priority 1 --body-file "$T/body.md") || fail "body-file release must pass"
[ "$out" = "release: v3" ] || fail "release from body file, got: $out"

"$CHECK" "done" t1 >/dev/null 2>&1 || fail "non-add commands must be a no-op"

[ "$fails" -eq 0 ] && echo "task-priority: all checks passed"
exit "$fails"
