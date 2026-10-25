#!/usr/bin/env bash
# Real tasks-axi -> installed watcher check -> real sign-off-axi, in isolated homes.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${FM_TICKETS_TEST_ROOT:-${TMPDIR:-/tmp}}/tickets-sync.XXXXXX")
trap 'echo "retained fixture and normalized archives: $work"' EXIT
fork=${FM_TEST_FORK:-$HOME/firstmate}
export HOME=$work/user XDG_DATA_HOME=$work/xdg SIGN_OFF_HOME=$work/signoff
export FM_HOME=$work/main
mkdir -p "$HOME" "$FM_HOME"/{data,config,state} "$work/parked/data"
ln -s "$fork/bin" "$FM_HOME/bin"
printf '{"schema":2,"items":[]}\n' > "$work/board.json"
printf '%s\n' "$work/board.json" > "$FM_HOME/config/fleet-board"
printf '%s\n' "- parked - Umer project (home: $work/parked; scope: demo)" > "$FM_HOME/data/secondmates.md"
printf 'parked\n' > "$FM_HOME/config/parked-homes"
printf '[markdown]\npath="data/backlog.md"\narchive="data/done-archive.md"\ndone_keep=0\n' > "$FM_HOME/.tasks.toml"
cp "$FM_HOME/.tasks.toml" "$work/parked/.tasks.toml"
(cd "$FM_HOME"; tasks-axi add parent '[captain-ask] P1 Parent: Umer release' --repo alpha --priority 1 --body 'type: captain-ask: "Umer telescope focus should be simple"' >/dev/null
 tasks-axi 'done' parent --no-prune >/dev/null
 tasks-axi add long "Umer 🚢 $(printf 'long title %.0s' {1..30})" --repo alpha --priority 1 --body $'release: next\nhttps://github.com/example/alpha/pull/123\nhttps://github.com/example/alpha/pull/456' >/dev/null
 tasks-axi start long >/dev/null
 tasks-axi add upkeep 'Umer maintenance' --repo alpha --priority 2 --body 'parent: upkeep' >/dev/null
 tasks-axi add held 'Umer paused item' --repo alpha --priority 1 --body 'parent: missing' >/dev/null
 tasks-axi hold held --reason 'Umer parked this item' --kind parked >/dev/null
 tasks-axi add voice 'Umer voice practice' --repo ownvoice --priority 2 >/dev/null
 tasks-axi add take 'Umer takes' --repo takeone --priority 2 >/dev/null
 tasks-axi add inferred 'Umer telescope focus regression' --repo alpha --priority 1 >/dev/null
 tasks-axi add internal 'Umer internal maintenance' --repo herdr --priority 2 --body 'parent: upkeep' >/dev/null
 tasks-axi add child '[captain-ask] P0 Umer settings' --repo alpha --priority 0 --body "$(printf 'Umer notes %.0s' {1..80})"$'\nrelease: next\nparent: parent' >/dev/null)
sed -i "/^- \[x\] parent /s/$(date +%F)/2000-01-01/g" "$FM_HOME/data/backlog.md"
(cd "$work/parked"; tasks-axi add parent 'Umer paused project' --repo beta --priority 2 >/dev/null)
printf '\n## Done\n- [x] recent - Umer shipped feature (repo: alpha) (done %s)\n- [x] old - Umer historical work (repo: alpha) (done 2000-01-01)\n' "$(date +%F)" >> "$FM_HOME/data/backlog.md"
git init -q "$FM_HOME/projects/alpha"
git -C "$FM_HOME/projects/alpha" remote add origin https://github.com/example/alpha-app.git
printf 'working [at=1700000000]: building Umer release\n' > "$FM_HOME/state/long.status"
sign-off-axi ticket "$work/board.json" --id fm-legacy-fixture --title 'Needs a parent · alpha' --progress 17 --asked yes >/dev/null
sign-off-axi ticket "$work/board.json" --id fm-history-fixture --title 'Umer historical maintenance' --project main --progress 100 --asked no >/dev/null
source_before=$(sha256sum "$FM_HOME/data/backlog.md" "$work/parked/data/backlog.md")
bash "$root/tickets-sync/install.sh" --dry-run
test ! -d "$XDG_DATA_HOME/fm-tickets-sync"
bash "$root/tickets-sync/install.sh"
printf 'not an image' > "$XDG_DATA_HOME/fm-tickets-sync/fleet-dashboard/fm-dashboard/icons/takeone.png"
env -u FM_HOME "$FM_HOME/state/tickets-sync.check.sh" | tee "$work/first.out"
# Missing/broken icons are recorded quietly; check stdout would wake Main.
jq -e '.["alpha-app"] == "no local image" and .takeone == "not a readable png image"' "$FM_HOME/state/tickets-sync/icons-skipped.json"
grep -q 'icon skipped' "$work/first.out" && { echo 'FAIL: icon skip must not print to check stdout'; exit 1; }
# Finished backfill wakes once with a summary; mid-pass continue does not.
grep -qE '^tickets-sync: [0-9]+ homes read; [0-9]+ tickets changed$' "$work/first.out"
grep -q continuing "$work/first.out" && { echo 'FAIL: backfill continue must not print to check stdout'; exit 1; }
rm -f "$FM_HOME/state/tickets-sync/cursor.json" "$FM_HOME/state/tickets-sync/progress.log"
FM_TICKETS_SYNC_BUDGET_SECS=0 FM_HOME="$FM_HOME" python3 "$XDG_DATA_HOME/fm-tickets-sync/tickets-sync/sync.py" > "$work/continue.out"
grep -q continuing "$work/continue.out" && { echo 'FAIL: backfill continue must stay off stdout'; exit 1; }
grep -q continuing "$FM_HOME/state/tickets-sync/progress.log"
test -s "$FM_HOME/state/tickets-sync/cursor.json"
printf 'working [at=1700000050]: still building Umer release\n' >> "$FM_HOME/state/long.status"
"$FM_HOME/state/tickets-sync.check.sh" > "$work/resume.out"
grep -q continuing "$work/resume.out" && { echo 'FAIL: resumed backfill continue must stay off stdout'; exit 1; }
grep -qE '^tickets-sync: [0-9]+ homes read; [0-9]+ tickets changed$' "$work/resume.out"
echo 'PASS: backfill continue is quiet; finished pass wakes once with a summary'
ticket_id() { printf 'fm-%s\n' "$(printf '%s' "$1" | sha256sum | cut -c1-32)"; }
child=$(ticket_id main/child) parent=$(ticket_id main/parent) parked=$(ticket_id parked/parent)
sign-off-axi ticket "$work/board.json" --json > "$work/first.json" || { cat "$work/first.json"; exit 1; }
jq -e '.tickets | all(.[]; (.title | length) <= 160) and all(.[]; (.title | startswith("Needs a parent")) | not)'  "$work/first.json"
jq -e --arg id "$child" --arg parent "$parent" '.tickets[] | select(.id == $id) | .parent == $parent and .priority == "P0" and .asked == false and .title == "Umer settings" and .release == "next"' "$work/first.json"
jq -e --arg id "$parked" '.tickets[] | select(.id == $id) | .hold == true' "$work/first.json"
jq -e --arg id "$(ticket_id main/held)" '[.tickets[] | select(.id == $id and .hold == true)] | length == 1' "$work/first.json"
upkeep=$(ticket_id fleet/:upkeep)
jq -e --arg root "$parent" --arg upkeep "$upkeep" '.tickets as $ts | all($ts[]; ((.parent // "") != "") or .id == $root or .id == $upkeep) and any($ts[]; .id == $root and .title == "Umer telescope focus should be simple") and any($ts[]; .id == $upkeep and .asked == false and .title == "Not from your asks (fleet upkeep)")' "$work/first.json"
jq -e --arg upkeep "$upkeep" '.tickets[] | select(.id == "fm-legacy-fixture") | .parent == $upkeep and .asked == false and .progress == 0' "$work/first.json"
jq -e --arg upkeep "$upkeep" '.tickets[] | select(.id == "fm-history-fixture") | .parent == $upkeep and (.project // "") == ""' "$work/first.json"
jq -e --arg inferred "$(ticket_id main/inferred)" --arg parent "$parent" '.tickets[] | select(.id == $inferred) | .parent == $parent' "$work/first.json"
# herdr is an internal home: no ticket project label and no icon wake line.
jq -e --arg internal "$(ticket_id main/internal)" '.tickets[] | select(.id == $internal) | (.project // "") == ""' "$work/first.json"
# Board wins over a drifted ledger that already recorded project cleared.
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/internal)" --project herdr >/dev/null
python3 - <<PY
import json, hashlib
from pathlib import Path
state = Path("$FM_HOME/state/tickets-sync")
ledger_path = next(state.glob("published-*.json"))
ledger = json.loads(ledger_path.read_text())
tid = "$(ticket_id main/internal)"
desired = {"project": "", "parent": "$upkeep"}
ledger[tid] = hashlib.sha256(json.dumps(desired, sort_keys=True).encode()).hexdigest()
ledger_path.write_text(json.dumps(ledger))
PY
"$FM_HOME/state/tickets-sync.check.sh" >/dev/null
jq -e --arg internal "$(ticket_id main/internal)" '.tickets[] | select(.id == $internal) | (.project // "") == ""' <(sign-off-axi ticket "$work/board.json" --json)
grep -qiE 'herdr( |$)' "$work/first.out" && { echo 'FAIL: herdr must not appear on check stdout'; exit 1; }
sign-off-axi project "$work/board.json" --json | jq -e '[.projects[] | .name | ascii_downcase] | (index("herdr") == null) and (index("herdr-runtime") == null)'
sign-off-axi project "$work/board.json" --json | jq -e '[.projects[] | .name] == ["ownvoice"] and .projects[0].icon.sha256 == "'"$(sha256sum "$root/fleet-dashboard/fm-dashboard/icons/ownvoice.png" | cut -d" " -f1)"'"'
cmp "$root/fleet-dashboard/fm-dashboard/icons/ownvoice.png" "$work/icons/ownvoice.png"
test ! -e "$work/icons/takeone.png"
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/long)" --json | jq -e '.ticket.progress == 30 and .ticket.state == "in progress"'
printf 'working [key=nm-umer-ci] [at=1700000100]: checking CI\n' >> "$FM_HOME/state/long.status"
"$FM_HOME/state/tickets-sync.check.sh"
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/long)" --json | jq -e '.ticket.progress == 65'
printf 'done [at=1700000200]: ready to merge\n' >> "$FM_HOME/state/long.status"
"$FM_HOME/state/tickets-sync.check.sh"
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/long)" --json | jq -e '.ticket.progress == 90'
printf 'cancelled [at=1700000300]: Umer cancelled this task\n' >> "$FM_HOME/state/long.status"
"$FM_HOME/state/tickets-sync.check.sh"
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/long)" --json | jq -e '.ticket.progress == 100 and .ticket.state == "done"'
FM_HOME="$FM_HOME" python3 "$XDG_DATA_HOME/fm-tickets-sync/tickets-sync/sync.py" --close main/held --reason superseded --reconcile
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/held)" --json | jq -e '.ticket.progress == 100 and .ticket.hold == false'
before=$(sha256sum "$work/board.tickets.jsonl" "$work/board.projects.jsonl")
rm "$FM_HOME/state/tickets-sync/closures.json"
mv "$FM_HOME/state/tickets-sync"/published-*.json "$FM_HOME/state/tickets-sync/ledger-before-restart"
"$FM_HOME/state/tickets-sync.check.sh"
test "$before" = "$(sha256sum "$work/board.tickets.jsonl" "$work/board.projects.jsonl")"
test "$source_before" = "$(sha256sum "$FM_HOME/data/backlog.md" "$work/parked/data/backlog.md")"
(cd "$FM_HOME"; tasks-axi 'done' child --pr https://github.com/example/alpha/pull/1 >/dev/null; tasks-axi 'done' inferred >/dev/null)
"$FM_HOME/state/tickets-sync.check.sh"
sign-off-axi ticket "$work/board.json" --id "$child" --json > "$work/closed.json"
jq -e '.ticket | .progress == 100 and .hold == false and (.prs | index("https://github.com/example/alpha/pull/1") != null)' "$work/closed.json"
before=$(sha256sum "$work/board.tickets.jsonl")
"$FM_HOME/state/tickets-sync.check.sh"
test "$before" = "$(sha256sum "$work/board.tickets.jsonl")"
sign-off-axi ticket "$work/board.json" --id "$parent" --json | jq -e '.ticket.progress == 100'
echo 'PASS: completed sync stays idempotent; epic progress rolls up from its child'

if command -v gh-axi >/dev/null && [ -n "${FM_TEST_MERGED_PR:-}" ]; then
  (cd "$FM_HOME"; tasks-axi add merged 'Umer shipped PR' --repo alpha --priority 1 --body "pr: $FM_TEST_MERGED_PR" >/dev/null; tasks-axi start merged >/dev/null)
  "$FM_HOME/state/tickets-sync.check.sh"
  sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/merged)" --json | jq -e '.ticket.progress == 100 and .ticket.state == "done"'
  echo 'PASS: merged GitHub PR closes an in-flight backlog item'
fi

(cd "$FM_HOME"; tasks-axi add other '[captain-ask] P1 Umer telescope focus second request' --repo alpha --priority 1 >/dev/null
 tasks-axi add ambiguous 'Umer telescope focus diagnostic' --repo alpha --priority 1 >/dev/null)
"$FM_HOME/state/tickets-sync.check.sh"
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/ambiguous)" --json | jq -e --arg upkeep "$upkeep" '.ticket.parent == $upkeep'
echo 'PASS: confirmed tagged children, specific orphan match, ambiguous upkeep, plain/quoted asks and internal-project clearing'

sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/other)" --json | jq -e '.ticket.title == "Umer telescope focus second request"'
(cd "$FM_HOME"; tasks-axi add refresh 'Umer active refresh check' --repo alpha --priority 2 --body "$(printf 'Umer notes %.0s' {1..80})"$'\nparent: parent')
"$FM_HOME/state/tickets-sync.check.sh"
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/refresh)" --json | jq -e --arg parent "$parent" '.ticket.parent == $parent'
(cd "$FM_HOME"; tasks-axi update refresh --body "$(printf 'Umer notes %.0s' {1..80})"$'\nparent: other')
"$FM_HOME/state/tickets-sync.check.sh"
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/refresh)" --json | jq -e --arg parent "$(ticket_id main/other)" '.ticket.parent == $parent'
echo 'PASS: full-body parent beyond list truncation and source revision refresh'
