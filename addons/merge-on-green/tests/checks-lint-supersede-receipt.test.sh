#!/usr/bin/env bash
# E2E: a lane that fixes its evidence list republishes PASS over its own stale FAIL, with nobody hand-posting a
# completion record. Real lint, the real completion-receipt publisher and the merge path's real acceptance, with
# a local report file in place of a PR (no gh, no network). A run that still fails must keep reading FAIL.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) # addons/
LINT=$ROOT/merge-on-green/fm-checks-lint.sh
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home XDG_DATA_HOME=$d/xdg TMPDIR=$d FM_HOME=$d/fm FM_ADDONS_DIR=$ROOT
mkdir -p "$HOME" "$XDG_DATA_HOME" "$d/fm/bin" "$d/fm/state" "$d/fm/data/lane-x/evidence" "$d/wt"
fails=0
bad() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
ok() { printf 'ok - %s\n' "$1"; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2], want [$3]"; fi }

# A lane of this home: its brief requires a receipt, and the fork libraries the publisher and the merge path
# use are this candidate's own, not a copy of another checkout.
cp "$ROOT/../bin/"*.sh "$d/fm/bin/"
git -C "$d/wt" init -q .
git -C "$d/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
head=$(git -C "$d/wt" rev-parse HEAD)
printf 'mode=direct-PR\nspawn_gen=1\nworktree=%s\n' "$d/wt" >"$d/fm/state/lane-x.meta"
printf 'frame one\n' >"$d/fm/data/lane-x/evidence/shot.png"

# report <evidence line>: the lane's local report file, as its done line names it.
report() {
  printf '## Checks\noutcome: the lane proves the new screen\nrepro: n/a: no bug\nproof: no verify skill - bash fixture\nevidence: %s\n' "$1" >"$d/fm/data/lane-x/report.md"
}
lint() { # lint <evidence line>: run the lane's lint, print its output and return its status
  report "$1"
  FM_HOME=$FM_HOME "$LINT" "$d/fm/data/lane-x/report.md" "$d/fm/data/lane-x" 2>&1
}
verdict_of() { jq -r '.verdict // "none"' "$d/fm/state/lane-x.run-receipt.json" 2>/dev/null || echo none; }
merges() { # the merge path's own acceptance of the lane's receipt for this candidate: 0 only for a PASS at this head
  (
    set -u
    # shellcheck source=/dev/null
    . "$d/fm/bin/fm-dod-lib.sh"
    fm_dod_receipt_accept "$d/fm/state" lane-x "$d/fm/state/lane-x.meta" "$head"
  )
}
newest() { awk -F'\t' '{ if ($4 == "pass") p = 1; last = $4 } END { printf "%s/%s", (p ? "pass" : "none"), last }' "$d/fm/data/checks-gate.log"; }

# 1. A real lane slip - the name lacks the evidence/ prefix - fails, names the exact fix, and its FAIL receipt
#    refuses the merge. The other conformance slips name their own line and fix.
set +e
out=$(lint 'shot.png')
rc=$?
set -e
is "a broken evidence list fails" "$rc" 1
case $out in
  *'so write evidence/shot.png'*) ok 'the FAIL names the name to write instead' ;;
  *) bad "the FAIL must name the fix: $out" ;;
esac
is "the FAIL published a FAIL receipt" "$(verdict_of)" FAIL
if merges >/dev/null 2>&1; then bad 'a FAIL receipt must refuse the merge'; else ok 'a FAIL receipt refuses the merge'; fi
set +e
out=$(lint 'evidence/shot.png ,')
set -e
case $out in
  *'has a stray comma; separate the names with one space and no trailing comma'*) ok 'a stray comma names the line and the fix' ;;
  *) bad "a stray comma must name its fix: $out" ;;
esac
set +e
out=$(lint 'evidence/shot.png evidence/shot.png')
set -e
case $out in
  *'names "evidence/shot.png" twice; name each file once'*) ok 'a duplicate name names the line and the fix' ;;
  *) bad "a duplicate name must name its fix: $out" ;;
esac

# 2. The lane fixes its list at the same head. The PASS republishes the receipt over the FAIL, so the merge path
#    reads PASS for this candidate with no hand-posted record, and every earlier row stays in the log.
out=$(lint 'evidence/shot.png') || bad "the fixed list must PASS: $out"
is 'the PASS supersedes the earlier FAIL receipt' "$(verdict_of)" PASS
is 'the receipt binds this candidate head' "$(jq -r .head "$d/fm/state/lane-x.run-receipt.json")" "$head"
if merges >/dev/null 2>&1; then ok 'the PASS receipt is accepted for this candidate'; else bad 'the PASS receipt must be accepted'; fi
case $(jq -r .evidence "$d/fm/state/lane-x.run-receipt.json") in
  *'checks-lint PASS'*) ok "the receipt is the lint's own record" ;;
  *) bad 'the receipt must carry the lint run, not a hand post' ;;
esac
is 'every run is still in the log' "$(wc -l <"$d/fm/data/checks-gate.log")" 4
is 'history kept and the newest row is the verdict' "$(newest)" pass/pass

# 3. Nothing is hidden: the proof goes again, so the newest run fails and that FAIL is the current verdict again.
rm -- "$d/fm/data/lane-x/evidence/shot.png"
set +e
out=$(lint 'evidence/shot.png')
rc=$?
set -e
is 'a run that fails again reads FAIL' "$rc" 1
is 'the current verdict is FAIL again' "$(verdict_of)" FAIL
if merges >/dev/null 2>&1; then bad 'a newer FAIL must refuse the merge again'; else ok 'the newer FAIL refuses the merge again'; fi
is 'the earlier pass row is kept while the newest row fails' "$(newest)" pass/fail

if [ "$fails" -eq 0 ]; then
  echo "PASS: a fixed evidence list supersedes the lane's own stale FAIL"
else
  echo "$fails check(s) failed" >&2
  exit 1
fi
