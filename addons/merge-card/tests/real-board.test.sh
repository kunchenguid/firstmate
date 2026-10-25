#!/usr/bin/env bash
# merge-card against the real sign-off-axi on a seeded temp board: a PR's card at one head, then a
# re-post at a new head. The old card must be archived (dismissed, kept) and exactly one card live,
# and another filer's cards for the PR are archived too (one-card-per-pr keeps the newest valid proof).
# The screen-free path needs no done-done, only a sealed run record; gh is a stub. Skips (exit 0)
# when sign-off-axi is not on PATH. Never touches a real board: SIGN_OFF_HOME is a temp folder.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
command -v sign-off-axi >/dev/null || { echo "skip - sign-off-axi is not on PATH"; exit 0; }
work=$(mktemp -d /var/tmp/merge-card-real.XXXXXX) || exit 1
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/home/data/t" "$work/board"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
case " $* " in *" --jq .headRefOid "*) printf '%s\n' "$GH_HEAD"; exit 0 ;; esac
printf 'outcome: a user sees one card\nevidence: x.png\nscreen: none\n'
STUB
chmod +x "$work/bin/gh"
export SIGN_OFF_HOME=$work/board FM_HOME=$work/home PATH="$work/bin:$PATH"
board=$work/board/decisions.json
(cd "$work/board" && sign-off-axi init >/dev/null 2>&1)
pr=https://github.com/o/r/pull/12
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }
post_at() { # post_at <run-id> <head>: a sealed clean run at the head, then the real post
  mkdir -p "$work/home/data/t/.done-done/runs"
  jq -n --arg id "$1" --arg c "$2" '{schema:1,run_id:$id,commit:$c,dirty:false,exit:0,files:[{path:"a.log"}]}' > "$work/home/data/t/.done-done/runs/$1.json"
  jq -n '{verdict:"pass",check:{claim:"a user sees one card",evidence:["x.png"]}}' > "$work/home/data/t/merge-card.json"
  "$here/../merge-card" post --board "$board" t - "$2" "$pr" 2>&1
}
h1=$(printf 'a%.0s' $(seq 40)) h2=$(printf 'b%.0s' $(seq 40))
live() { sign-off-axi list "$board" --json --full | jq -r '[.decisions[] | select(.dismissed != true) | .evidence.run_id] | join(",")'; }
# Another filer's evidence card for the same PR (a lane's own proof, no passed-test receipt).
printf '\x89PNG\r\n\x1a\n' > "$work/shot.png"
lane_post() { sign-off-axi post "$board" --type evidence --title "$1" --about "Umer sees one card" --media "$work/shot.png" --link "$pr" --filer other-lane >/dev/null; }
live_keys() { sign-off-axi list "$board" --json --full | jq -r '[.decisions[] | select(.dismissed != true) | .key] | join(",")'; }
lane_post "Lane proof before the merge" || fails=$((fails + 1))
post_at 20261022T000000Z-first0001 "$h1" >/dev/null || fails=$((fails + 1))
is "first head: one live card" "$(live)" 20261022T000000Z-first0001
is "first head: the other filer's older card is archived" "$(live_keys)" merge-o-r-pull-12
out=$(post_at 20261022T000000Z-second0001 "$h2") || { echo "$out"; fails=$((fails + 1)); }
is "new head: exactly one live card, the newest" "$(live)" 20261022T000000Z-second0001
is "new head: old card archived, history kept" "$(sign-off-axi list "$board" --json --full | jq -r '[.decisions[] | select(.dismissed == true and .filer == "firstmate-merge") | .evidence.run_id] | join(",")')" 20261022T000000Z-first0001
is "new head: first card keeps the PR key" "$(sign-off-axi list "$board" --json --full | jq -r '.decisions[] | select(.dismissed == true and .filer == "firstmate-merge") | .key')" merge-o-r-pull-12
out=$(post_at 20261022T000000Z-second0001 "$h2")
case $out in *"already on the board"*) echo "ok - repeat post adds nothing" ;; *) echo "not ok - repeat post: [$out]"; fails=$((fails + 1)) ;; esac
# A newer card from another filer without a receipt: the sweep keeps the valid proof and archives it.
lane_post "Lane proof after the merge" || fails=$((fails + 1))
lane_key=$(sign-off-axi list "$board" --json --full | jq -r '.decisions[] | select(.dismissed != true and .filer == "other-lane") | .key')
out=$("$here/../one-card-per-pr" "$board")
is "sweep dry run: names the card and changes nothing" "$out|$(live_keys)" "archive $lane_key (other-lane, o/r#12) keep merge-o-r-pull-12-$(printf '%s' "$h2" | sha1sum | cut -c1-12)
one-card-per-pr: would archive 1 card(s)|$(live_keys)"
"$here/../one-card-per-pr" --apply "$board" >/dev/null || fails=$((fails + 1))
is "sweep: the newest valid proof stays across filers" "$(live)" 20261022T000000Z-second0001
is "sweep: the other filer's card is archived, not deleted" "$(sign-off-axi list "$board" --json --full | jq -r --arg k "$lane_key" '.decisions[] | select(.key == $k) | .dismissed')" true
is "sweep: a rerun archives nothing" "$("$here/../one-card-per-pr" --apply "$board")" "one-card-per-pr: archived 0 card(s)"
# A merge hook passes head `-` for a PR: the screen: none card still finds the run sealed at the PR head.
h3=$(printf 'c%.0s' $(seq 40))
pr=https://github.com/o/r/pull/13
mkdir -p "$work/home/data/t/.done-done/runs"
jq -n --arg c "$h3" '{schema:1,run_id:"20261022T000000Z-hookdash01",commit:$c,dirty:false,exit:0,files:[{path:"a.log"}]}' > "$work/home/data/t/.done-done/runs/20261022T000000Z-hookdash01.json"
out=$(GH_HEAD=$h3 "$here/../merge-card" post --board "$board" t - - "$pr" 2>&1) || { echo "$out"; fails=$((fails + 1)); }
is "hook head dash: the PR's card carries the run sealed at its head" "$(sign-off-axi list "$board" --json --full | jq -r '.decisions[] | select(.key == "merge-o-r-pull-13") | .evidence.run_id')" 20261022T000000Z-hookdash01
[ "$fails" -eq 0 ] && echo "real-board: all assertions held" || { echo "real-board: $fails failed"; exit 1; }
