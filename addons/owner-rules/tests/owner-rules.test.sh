#!/usr/bin/env bash
# owner-rules e2e: the real fm-brief.sh of a firstmate checkout that carries the brief-inherit seam.
# Usage: owner-rules/tests/owner-rules.test.sh <firstmate-checkout>
# Proves a no-owner-ask refusal, a no-risk-reason refusal and a clean pass (brief written), plus the
# exemptions and the no-op when the add-on is not installed.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
addons=$(cd "$here/../.." && pwd) || exit 1
FM=${1:-}
[ -n "$FM" ] && [ -x "$FM/bin/fm-brief.sh" ] && grep -q fm_brief_inherit_shared "$FM/bin/fm-brief.sh" \
  || { echo "usage: $0 <firstmate-checkout with the brief-inherit seam>" >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/owner-rules-e2e.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
export HOME=$work/user XDG_DATA_HOME=$work/data
fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }

home=$work/home; mkdir -p "$home/config" "$home/data" "$home/state"
cat > "$home/data/backlog.md" <<'BL'
# Backlog

## In flight
- [ ] with-ask - [captain-ask] Ship a thing (repo: sample) (kind: ship)
  A body line.
- [ ] with-main - Plain title (repo: sample) (kind: ship)
  type: Main7 asked for this.
  parent: with-ask
- [ ] orphan - Plain title (repo: sample) (kind: ship)
  Main11 asked for this.
- [ ] bad-parent - Plain title (repo: sample) (kind: ship)
  Main12 asked for this.
  parent: nowhere
- [ ] upkeep - Routine cleanup (repo: sample) (kind: ship)
  Main14 asked for this.
  parent: upkeep
- [ ] cycle-a - Ticket A (repo: sample) (kind: ship)
  parent: cycle-b
- [ ] cycle-b - Ticket B (repo: sample) (kind: ship)
  parent: cycle-a
- [ ] scout-parentless - Plain title (repo: sample) (kind: ship)
  Main13 asked for this.
- [ ] no-ask - Plain title (repo: sample) (kind: ship)
  Nothing names an owner.
- [ ] risky - [captain-ask] Rotate keys (repo: sample) (kind: ship)
  risk: security
- [ ] two-risks - [captain-ask] Both (repo: sample) (kind: ship)
  risk: security
  risk: release
- [ ] bad-risk - [captain-ask] Not listed (repo: sample) (kind: ship)
  risk: because
- [ ] fork-pr - [captain-ask] A fork change (repo: sample) (kind: ship)
  risk: fork-repo
## Done
- [x] with-ask-longer - Main9 something
BL
# brief <id> <args...>: stderr, then rc= on the last line.
brief() {
  local id=$1 out rc; shift
  out=$(FM_HOME=$home FM_ADDONS_DIR=$addons bash "$FM/bin/fm-brief.sh" "$id" sample "$@" 2>&1 >/dev/null); rc=$?
  printf '%s%src=%s\n' "$out" "${out:+$'\n'}" "$rc"
}
ASK='owner-rules: no owner ask: name the [captain-ask] item or the MainNNN order this lane serves (add it to the backlog item for no-ask)'
RISK='owner-rules: mode no-mistakes needs one listed risk reason (release, security, migration, large-change, shared-protocol, fork-repo) in the backlog item for with-ask; use direct-PR plus a done-done check'
PARENT='owner-rules: no valid parent: add parent: <backlog item id> or parent: upkeep to the backlog item for orphan'

# not installed: no check, even for an entry with no owner ask
is "not installed: no-ask lane is briefed" "$(brief no-ask --mode direct-PR | tail -1)" "rc=0"
rm -rf -- "$home/data/no-ask"

"$addons/owner-rules/install.sh" "$home" >/dev/null
is "refusal 1: no owner ask" "$(brief no-ask --mode direct-PR)" "$ASK
rc=1"
[ ! -e "$home/data/no-ask" ] && ok "refusal 1 wrote no brief" || no "refusal 1 left data/no-ask"
is "refusal 1: missing entry is also no owner ask" "$(brief ghost --mode direct-PR | tail -2 | head -1 | cut -c1-27)" "owner-rules: no owner ask: "
is "refusal 1: a scout still needs an owner ask" "$(brief no-ask --scout | tail -1)" "rc=1"
is "refusal: no valid parent" "$(brief orphan --mode direct-PR)" "$PARENT
rc=1"
is "refusal: missing parent id" "$(brief bad-parent --mode direct-PR | tail -1)" "rc=1"
[ ! -e "$home/data/orphan" ] && ok "parent refusal wrote no brief" || no "parent refusal left data/orphan"
is "refusal 2: no-mistakes without a risk reason" "$(brief with-ask --mode no-mistakes)" "$RISK
rc=1"
[ ! -e "$home/data/with-ask" ] && ok "refusal 2 wrote no brief" || no "refusal 2 left data/with-ask"
is "refusal 2: two risk lines" "$(brief two-risks --mode no-mistakes | tail -1)" "rc=1"
is "refusal 2: unlisted reason" "$(brief bad-risk --mode no-mistakes | tail -1)" "rc=1"

is "pass: [captain-ask] title, direct-PR" "$(brief with-ask --mode direct-PR)" "rc=0"
[ -s "$home/data/with-ask/brief.md" ] && ok "pass wrote the brief" || no "pass wrote no brief"
is "pass: MainNNN body with existing parent id" "$(brief with-main --mode direct-PR)" "rc=0"
is "pass: upkeep parent" "$(brief upkeep --mode direct-PR)" "rc=0"
is "pass: scouts keep parent exemption" "$(brief scout-parentless --scout)" "rc=0"
is "pass: no-mistakes with one listed risk" "$(brief risky --mode no-mistakes)" "rc=0"
is "pass: no-mistakes with risk: fork-repo" "$(brief fork-pr --mode no-mistakes)" "rc=0"
[ -s "$home/data/fork-pr/brief.md" ] && ok "fork-repo pass wrote the brief" || no "fork-repo pass wrote no brief"
is "pass: scout is exempt from the risk rule" "$(brief with-ask-longer --scout)" "rc=0"
is "pass: prefix id does not match a longer id" "$(brief with-ask --scout | tail -1)" "rc=1"
FM_HOME=$home FM_ADDONS_DIR=$addons FM_SECONDMATE_CHARTER=x bash "$FM/bin/fm-brief.sh" sm --secondmate --no-projects >/dev/null 2>&1 \
  && ok "pass: secondmate charter is exempt" || no "secondmate charter refused"

tree=$(bash "$addons/owner-rules/bin/fm-owner-rules-tree.sh" "$home/data/backlog.md")
printf '%s\n' "$tree" | grep -qF 'with-main: with-main -> with-ask -> [epic root]' && ok "tree: prints epic parent chain" || no "tree: epic parent chain missing"
printf '%s\n' "$tree" | grep -qF 'bad-parent: bad-parent -> [missing: nowhere]' && ok "tree: reports missing parent id" || no "tree: missing parent id unreported"
printf '%s\n' "$tree" | grep -qF 'cycle-a: cycle-a -> cycle-b -> cycle-a -> [cycle: cycle-a]' && ok "tree: reports cycle" || no "tree: cycle unreported"
printf '%s\n' "$tree" | grep -A8 '^Items with no valid parent:' | grep -qF '  cycle-a' && ok "tree: lists invalid items" || no "tree: invalid items list missing cycle"

"$addons/owner-rules/uninstall.sh" "$home" >/dev/null
is "uninstalled: check is off again" "$(brief no-ask --mode direct-PR | tail -1)" "rc=0"

# the leads skill quotes each real refusal line (with $id / $what in place of the runtime value)
n=0
while IFS= read -r q; do
  n=$((n + 1))
  refusal=${q%%; run *}
  grep -qF -- "${refusal#owner-rules: }" "$addons/owner-rules/bin/fm-owner-rules-lib.sh" "$addons/owner-rules/bin/fm-owner-rules-gate.sh" \
    && ok "skill quote matches the code: ${q:0:40}" || no "skill quote not in lib or gate: $q"
done < <(grep '^owner-rules: ' "$addons/owner-rules/skill/SKILL.md")
is "skill quotes all six refusals" "$n" "6"

[ "$fails" -eq 0 ] && echo "PASS owner-rules" || { echo "FAIL owner-rules: $fails"; exit 1; }
