#!/usr/bin/env bash
# owner-rules design flag: the backlog "design: required|none" line, the brief record, the typo guard and the nudge.
# Usage: owner-rules/tests/design-flag.test.sh [<firstmate-checkout>]
# Sources the real lib against a fixture backlog. With a checkout that carries the brief-inherit seam, it also
# drives the real fm-brief.sh and reads data/<id>/brief.md.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
addons=$(cd "$here/../.." && pwd) || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/owner-rules-design.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }

home=$work/home; mkdir -p "$home/config" "$home/data" "$home/state"
cat > "$home/data/backlog.md" <<'BL'
# Backlog

## In flight
- [ ] req - [captain-ask] Rebuild the dashboard (repo: sample) (kind: ship)
  design: required
- [ ] none - [captain-ask] Fix a spacing bug (repo: sample) (kind: ship)
  design: none
- [ ] absent - [captain-ask] Bump a dependency (repo: sample) (kind: ship)
- [ ] typo - [captain-ask] Fix a thing (repo: sample) (kind: ship)
  desing: required
- [ ] vague - [captain-ask] Fix a thing (repo: sample) (kind: ship)
  design: maybe
- [ ] twice - [captain-ask] Fix a thing (repo: sample) (kind: ship)
  design: required
  design: none
- [ ] nudge - [captain-ask] Redesign the landing page (repo: sample) (kind: ship)
- [ ] nudge-body - [captain-ask] Fix a thing (repo: sample) (kind: ship)
  Needs a new screen for settings.
- [ ] flagged-words - [captain-ask] Redesign the landing page (repo: sample) (kind: ship)
  design: none
BL
# check <id> [include]: stderr, BRIEF_INCLUDE_BODY, then rc= (run in a subshell, as the exit paths end it).
check() {
  local out
  out=$(
    BRIEF_INCLUDE_BODY=${2:-}
    # shellcheck disable=SC1091 # the lib is in this checkout
    . "$addons/owner-rules/bin/fm-owner-rules-lib.sh"
    # the exit paths end the shell, so print the body from a trap
    rc=0
    trap 'rc=$?; printf "err=%s\nbody=%s\nrc=%s\n" "$(cat "$work/err")" "$BRIEF_INCLUDE_BODY" "$rc"' EXIT
    fm_owner_rules_check "$home/data" "$1" direct-PR ship 2>"$work/err"
  )
  printf '%s\n' "$out"
}
BAD() { echo "owner-rules: design: must be required or none (backlog item for $1)"; }

is "required adds the brief line" "$(check req)" "err=
body=Design discovery: required
rc=0"
is "required keeps the existing include after it" "$(check req 'Home text')" "err=
body=Design discovery: required
Home text
rc=0"
is "none adds nothing" "$(check none)" "err=
body=
rc=0"
is "absent adds nothing" "$(check absent)" "err=
body=
rc=0"
is "D2: a typo is refused" "$(check typo)" "err=$(BAD typo)
body=
rc=1"
is "D2: a value that is not required or none is refused" "$(check vague | head -1)" "err=$(BAD vague)"
is "D2: two design lines are refused" "$(check twice | head -1)" "err=$(BAD twice)"
is "D4: design words in the title only nudge" "$(check nudge)" "err=owner-rules: note: this reads like design work; add \"design: required\" or \"design: none\" to the backlog item for nudge
body=
rc=0"
is "D4: design words in the body only nudge" "$(check nudge-body | tail -1)" "rc=0"
is "D4: a design line silences the nudge" "$(check flagged-words)" "err=
body=
rc=0"

# with the fork: the real fm-brief.sh writes the line, and a typo writes no brief
FM=${1:-}
if [ -n "$FM" ] && [ -x "$FM/bin/fm-brief.sh" ] && grep -q fm_brief_inherit_shared "$FM/bin/fm-brief.sh"; then
  export HOME=$work/user XDG_DATA_HOME=$work/data
  "$addons/owner-rules/install.sh" "$home" >/dev/null
  brief() { FM_HOME=$home FM_ADDONS_DIR=$addons bash "$FM/bin/fm-brief.sh" "$1" sample --mode direct-PR >/dev/null 2>&1; }
  brief req; grep -qx 'Design discovery: required' "$home/data/req/brief.md" && ok "brief.md carries the line when required" || no "brief.md lacks the line"
  brief none; [ -s "$home/data/none/brief.md" ] && ! grep -q 'Design discovery' "$home/data/none/brief.md" && ok "brief.md has no line for none" || no "brief.md for none"
  brief typo && no "typo briefed" || { [ ! -e "$home/data/typo" ] && ok "typo writes no brief" || no "typo left data/typo"; }
else
  echo "skip - fm-brief.sh journey (no firstmate checkout given)"
fi

[ "$fails" -eq 0 ] && echo "PASS design-flag" || { echo "FAIL design-flag: $fails"; exit 1; }
