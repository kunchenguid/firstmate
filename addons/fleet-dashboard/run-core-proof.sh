#!/usr/bin/env bash
# Core journey: the fleet dashboard shows live fleet state in a real browser at a phone width.
# Seeds a throwaway Firstmate home (agent lanes, a landed task, queued and held tasks), serves this
# checkout's dashboard against that seed, opens it in headless Chrome at 390px, and writes the Board
# (lanes) and Insights (queue reasons) as text and screenshots to $DONE_DONE_EVIDENCE_ROOT.
# The seed is the only home read: no real fleet, no credentials, no live writes.
# FM_BIN names the Firstmate bin/ whose helper scripts the build runs (default: ~/firstmate/bin); the
# queue reasons come from this checkout's fleet-flow reader, which the build reaches through FM_ADDONS_DIR.
set -Eeuo pipefail
# A browser step that times out stops the run under set -e; name it so a failed run says where.
trap 'echo "run-core-proof: stopped at line $LINENO: $BASH_COMMAND" >&2' ERR
: "${DONE_DONE_EVIDENCE_ROOT:?}"
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
FM_BIN=${FM_BIN:-$HOME/firstmate/bin}
[ -f "$FM_BIN/fm-tasks-axi.sh" ] || { echo "run-core-proof: FM_BIN has no fm-tasks-axi.sh: $FM_BIN" >&2; exit 1; }
home=$(mktemp -d)
bin=$home/bin
session=core-journey-$$
srv_pid=
cleanup() {
  CHROME_DEVTOOLS_AXI_SESSION=$session chrome-devtools-axi stop >/dev/null 2>&1 || true
  env -u TMUX TMUX_TMPDIR="$home/tmux" tmux kill-server 2>/dev/null || true
  [ -z "$srv_pid" ] || { pkill -P "$srv_pid"; kill "$srv_pid"; } 2>/dev/null || true  # the server is the backgrounded shell's child
  rm -rf -- "$home"
}
trap cleanup EXIT

# One agent lane: state/<task>.meta, and a .status whose last line sets the lane's state.
lane() {  # <task> <kind> <status line>...
  local task=$1 kind=$2
  shift 2
  printf 'kind=%s\nproject=alpha\nharness=claude\nmodel=model-a\nherdr_pane_id=pane-%s\n' "$kind" "$task" > "$home/state/$task.meta"
  printf '%s\n' "$@" > "$home/state/$task.status"
}

seed() {
  local now today held_day ask_title
  ask_title="Choose the layout for the new screen"
  [ "${README_HERO_ONLY:-0}" != 1 ] || ask_title="Choose phone layout"
  now=$(date +%s) today=$(date +%F) held_day=$(date -d '7 days ago' +%F)
  mkdir -p "$home"/{data,state,config,stubs,locks,proc/pressure} "$bin"
  printf '3\n' > "$home/config/lane-target"
  printf 'main 3\n' > "$home/config/lane-caps"  # four open Main lanes against a cap of three: over the cap
  printf 'Umer\n' > "$home/config/owner-name"  # the board's reader, named in the sidebar's foot
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] m-build - Build the main thing (repo: alpha) (kind: ship) (since $today)
  release: v0.2.0
- [ ] m-ci - Get the layout pull request through CI (repo: alpha) (kind: ship) (since $today)
- [ ] m-stuck - Publish the release from the build server (repo: alpha) (kind: ship) (since $today)
- [ ] m-ask - [captain-ask] $ask_title (Main42) (repo: alpha) (kind: ship) (priority: 0) (since $today)
  Captain hold set: 2026-10-20T08:00:00Z
  type: captain-ask: "Show the new screen in the layout a phone reads first" (22 Oct, Main42). Two layouts are drawn; the lead picks one.

## Queued
- [ ] m-ready - Start the ready thing (repo: beta) (kind: ship) (priority: 1) (since $today)
  release: next
- [ ] m-held - Wait for the captain's call (repo: alpha) (kind: ship) (since $held_day) (hold: needs his call) (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
  Decision digest: 0f0f
  Resolution mode: released
  Captain decision:
  Captain 22 Oct chat: "keep the old layout until the new one is proven". Main decides: wait for the new layout.
- [ ] m-after - After the ready thing blocked-by: m-ready (repo: alpha) (kind: ship) (since $today)
  release: v0.3.0

## Done
- [x] m-shipped - Ship the main thing (repo: alpha) (kind: ship) (merged $today)
- [x] m-long - Keep every ticket name whole on the board so a long name that runs past eighty characters still reads to its very end (repo: alpha) (kind: ship) (merged $today)
  The captain asked on 23 Oct for "ticket names that are never cut short on the fleet board" (23 Oct, Main77). Names and descriptions come from the whole backlog item, not the cut list view. More words follow here so that the list view cuts this body. More words follow here so that the list view cuts this body. More words follow here so that the list view cuts this body. The description ends here.
EOF
  printf 'npm-2fa\t%s\tLink the alpha npm package to GitHub?\thttps://www.npmjs.com/package/alpha/access\n' "$((now - 900))" > "$home/data/captain-asks.tsv"
  # two more as Main writes them now: ...<TAB>url<TAB>options<TAB>default<TAB>why
  printf 'pick-home\t%s\tPick the home screen layout: A Cards or B List?\t\tA|B|Later\tA\tBoth layouts are drawn; the lead waits on your pick.\n' "$((now - 1800))" >> "$home/data/captain-asks.tsv"
  printf 'ok-release\t%s\tApprove the alpha 0.2.0 release?\thttps://example.invalid/alpha/0.2.0\tYes|No\tYes\tCI is green and the notes are written.\n' "$((now - 7200))" >> "$home/data/captain-asks.tsv"
  lane m-build ship "working [at=$((now - 600))]: building the main thing"
  # m-ci's completion receipt and the done-done verdict on its merge card: the ticket page's Proof.
  printf '{"schema":1,"task":"m-ci","head":"abc1234def5678","verdict":"PASS","at":%s}\n' "$((now - 300))" > "$home/state/m-ci.run-receipt.json"
  mkdir -p "$home/data/m-ci" && printf '{"head":"abc1234def5678","verdict":"pass"}\n' > "$home/data/m-ci/merge-card.json"
  mkdir -p "$home/projects/beta/.git" && printf '[remote "origin"]\n\turl = git@github.com:acme/beta-app.git\n' > "$home/projects/beta/.git/config"  # its clone's origin names the project
  lane m-ci ship "paused [at=$((now - 1200))]: waiting for CI checks https://github.com/acme/alpha/pull/9"
  lane m-stuck ship "blocked [at=$((now - 7200))]: cannot reach the build server"
  lane m-ask ship "needs-decision [at=$((now - 3600))] [key=scope]: which layout"
  printf '{"ts":%s,"event":"ledger.started"}\n{"ts":%s,"event":"task.merged","task":"m-shipped","pr":"https://github.com/acme/alpha/pull/4"}\n' \
    "$((now - 172800))" "$((now - 60))" > "$home/state/fleet-ledger.jsonl"
  # What herdr reports for each lane's pane.
  cat > "$home/herdr.json" <<EOF
{"result":{"agents":[
 {"agent":"claude","agent_status":"working","cwd":"/wt/1","pane_id":"pane-m-build","name":"m-build"},
 {"agent":"claude","agent_status":"idle","cwd":"/wt/2","pane_id":"pane-m-ci","name":"m-ci"},
 {"agent":"claude","agent_status":"blocked","cwd":"/wt/3","pane_id":"pane-m-stuck","name":"m-stuck"},
 {"agent":"claude","agent_status":"idle","cwd":"/wt/4","pane_id":"pane-m-ask","name":"m-ask"}]}}
EOF
  # Stubs keep the dashboard off the real herdr, quota, device and service state.
  printf '#!/bin/sh\ncat "%s/herdr.json"\n' "$home" > "$home/stubs/herdr"
  printf '#!/bin/sh\nexit 1\n' > "$home/stubs/quota-axi"
  # GitHub, read-only: the alpha repository the fleet recorded a merge in answers with two merges today and three yesterday.
  python3 - "$home/gh-alpha.json" <<'PY'
import json, sys, datetime as D
now = D.datetime.now().astimezone(); noon = now.replace(hour=12, minute=0, second=0, microsecond=0) - D.timedelta(days=1)
ts = [now - D.timedelta(seconds=40), now - D.timedelta(seconds=70)] + [noon - D.timedelta(hours=h) for h in (0, 1, 2)]
json.dump([{'mergedAt': t.astimezone(D.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} for t in ts], open(sys.argv[1], 'w'))
PY
  # shellcheck disable=SC2016 # the single-quoted stub expands when it runs
  printf '#!/bin/sh\n[ "$4" = acme/alpha ] && exec cat "%s/gh-alpha.json"\necho "HTTP 404: Could not resolve to a Repository" >&2; exit 1\n' "$home" > "$home/stubs/gh"
  printf '#!/bin/sh\nprintf "List of devices attached\\n\\n"\n' > "$home/stubs/adb"
  # shellcheck disable=SC2016 # the single-quoted stub expands when it runs
  printf '#!/bin/sh\n[ "$1" = "-cf" ] && { echo 0; exit 0; }\nexit 1\n' > "$home/stubs/pgrep"
  printf '#!/bin/sh\nprintf "MemoryCurrent=0\\nMemoryHigh=34359738368\\nMemoryMax=40802189312\\n"\n' > "$home/stubs/systemctl"
  chmod +x "$home"/stubs/*
  printf 'MemTotal: 67108864 kB\nMemAvailable: 33554432 kB\n' > "$home/proc/meminfo"
  printf 'some avg10=45.00 avg60=8.00 avg300=3.00 total=0\n' > "$home/proc/pressure/memory"  # a 10 s spike the gate lets pass
  : > "$home/proc/locks"
  # The Firstmate helpers the build runs, linked in.
  for f in "$FM_BIN"/*; do ln -s "$f" "$bin/${f##*/}"; done
  # The owner's sign-off board token, and a lead home, alpha, whose steering endpoint is a window on a private tmux server.
  mkdir -p "$home/board" "$home/alpha/data" "$home/alpha/state" "$home/tmux"
  printf 'core-owner-token-%s\n' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')" > "$home/board/board.token"
  printf 'board/board.json\n' > "$home/config/owner-board"
  ln -s "$bin" "$home/alpha/bin"
  printf 'alpha\n' > "$home/alpha/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$home" > "$home/alpha/.fm-secondmate-parent"
  printf -- '- alpha - Owns the alpha screens. (home: %s/alpha; scope: alpha)\n' "$home" > "$home/data/secondmates.md"
  printf 'kind=secondmate\nwindow=core:alpha\nbackend=tmux\n' > "$home/state/alpha.meta"
  printf '## In flight\n- [ ] t-lead - Keep the ask list on top (repo: alpha) (kind: ship) (priority: 1) (since %s)\n' "$today" > "$home/alpha/data/backlog.md"
  env -u TMUX TMUX_TMPDIR="$home/tmux" tmux new-session -d -s core -n alpha cat
}

dash() {  # <build|serve> [args]: the dashboard against the seed home, with the stubs first on PATH
  env -u TMUX PATH="$home/stubs:$PATH" HOME="$home" FM_HOME="$home" FM_BIN="$bin" FM_ADDONS_DIR="$root" TMUX_TMPDIR="$home/tmux" \
    FM_DEVICE_LOCK_DIR="$home/locks" FM_DASHBOARD_PROC="$home/proc" FM_MAC_HOST= \
    bash "$here/fm-dashboard.sh" "$@"
}

seed
dash build >/dev/null
dash serve --port 0 >"$home/serve.log" 2>&1 &
srv_pid=$!
url=
for _ in $(seq 100); do
  url=$(sed -n 's/^serving //p' "$home/serve.log" 2>/dev/null || true)
  [ -z "$url" ] || break
  kill -0 "$srv_pid" 2>/dev/null || { cat "$home/serve.log" >&2; exit 1; }
  sleep 0.2
done
[ -n "$url" ] || { cat "$home/serve.log" >&2; exit 1; }

export CHROME_DEVTOOLS_AXI_SESSION=$session
# a new session can start with its one blank tab unselected, and open then has no page to drive
chrome-devtools-axi selectpage 1 >/dev/null 2>&1 || true
if [ "${README_HERO_ONLY:-0}" != 1 ]; then
chrome-devtools-axi open "$url#/board" >/dev/null
chrome-devtools-axi resize 390 844 >/dev/null
chrome-devtools-axi wait "m-stuck" >/dev/null
chrome-devtools-axi eval 'JSON.stringify({ viewport: innerWidth, text: document.body.innerText })' >"$DONE_DONE_EVIDENCE_ROOT/board.txt"
chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/board-390.png" >/dev/null
fi
# A README capture uses this same seeded real dashboard, without the unrelated interaction suite.
if [ "${README_HERO_ONLY:-0}" = 1 ]; then
  chrome-devtools-axi open "$url#/tickets" >/dev/null
  for theme in light dark; do
    chrome-devtools-axi eval "localStorage.setItem('fm-theme', '$theme')" >/dev/null
    for width in 390 1280; do
      chrome-devtools-axi resize "$width" 844 >/dev/null
      chrome-devtools-axi open "$url?readme-$theme-$width#/tickets" >/dev/null
      chrome-devtools-axi wait 'Your asks done' >/dev/null
      chrome-devtools-axi eval 'JSON.stringify({width:innerWidth,text:document.body.innerText,theme:localStorage.getItem("fm-theme")})' >"$DONE_DONE_EVIDENCE_ROOT/hero-$width-$theme.txt"
      chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/hero-$width-$theme.png" >/dev/null
    done
  done
  python3 - "$DONE_DONE_EVIDENCE_ROOT/steps.json" "$(git -C "$root" rev-parse HEAD)" <<'PYHERO'
import json, sys
with open(sys.argv[1], 'w') as out:
    json.dump({'target': {'version': sys.argv[2]},
               'start': 'A disposable synthetic fleet served by this checkout of the real dashboard.',
               'steps': ['Open the Tickets page.', 'Select light and dark themes at 390 and 1280 widths.', 'Capture the real dashboard and its text.'],
               'result': 'The dashboard shows the demo fleet ticket queue in both themes and widths; no personal fleet data was read.'}, out, indent=2)
PYHERO
  exit 0
fi
# The Ship tab is gone: no link, dock button or palette entry leads to it.
for w in 390 1280; do
  chrome-devtools-axi resize "$w" 900 >/dev/null
  n=$(chrome-devtools-axi eval 'document.querySelectorAll("a[href=\"#/ship\"], [aria-label=Ship]").length' | sed -n 's/^result: //p' | tr -d '"')
  [ "$n" = 0 ] || { echo "run-core-proof: a Ship entry remains at $w: $n" >&2; exit 1; }
done
# The board at a desktop width, then the one-tap Stuck and Waiting tabs and the lane cap beside a home's count.
# BOARD_SHOTS_ONLY=1 captures the same shots without judging them (for a build that lacks the tabs).
shot() {  # <name> <route> <width> <wait text>
  chrome-devtools-axi open "$url$2" >/dev/null
  chrome-devtools-axi resize "$3" 900 >/dev/null
  chrome-devtools-axi wait "$4" >/dev/null
  chrome-devtools-axi eval 'JSON.stringify({ viewport: innerWidth, text: document.body.innerText })' >"$DONE_DONE_EVIDENCE_ROOT/$1.txt"
  chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/$1.png" >/dev/null
}
for w in 390 1280; do
  shot "board-active-$w" '#/board' "$w" m-stuck
  shot "board-stuck-$w" '#/board?tab=stuck' "$w" m-stuck
  shot "board-waiting-$w" '#/board?tab=waiting' "$w" m-ci
  shot "board-homes-$w" '#/board?rows=home' "$w" m-stuck
  shot "tickets-$w" '#/tickets' "$w" 'Your asks done'
  shot "needs-$w" '#/needs' "$w" 'Link the alpha npm package'
done
# A phone opens on the hero and the Moving list; the hero's legend switches the list, here to To do.
shot tickets-390 '#/tickets' 390 'Your asks done'
# The hero counts open tickets nothing has updated for a day. This seed files m-held seven
# days ago, held and untouched since, while today's lanes and ready items are fresh.
stale=$(sed -n 's/.*\([0-9][0-9]* stale\).*/\1/p' "$DONE_DONE_EVIDENCE_ROOT/tickets-390.txt" | head -n1)
[ -n "$stale" ] || { echo 'run-core-proof: the Tickets hero does not count stale open tickets' >&2; exit 1; }
echo "stale tickets on the seeded board: $stale"
chrome-devtools-axi eval '[...document.querySelectorAll(".legend button")].find(b => b.textContent.startsWith("To do")).click()' >/dev/null
sleep 1
chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/tickets-todo-390.png" >/dev/null
# Overview names the records behind every figure; at 390 the end of each page clears the floating tab bar.
for w in 390 1280; do shot "overview-$w" '#/overview' "$w" 'Lifecycle'; done
for want in "Source: Needs you: Main's ask list" "Source: each home's lane records" "each home's backlog and its done archive" "Source: quota-axi cache, read-only"; do
  grep -qF -- "$want" "$DONE_DONE_EVIDENCE_ROOT/overview-390.txt" || { echo "run-core-proof: Overview lacks '$want'" >&2; exit 1; }
done
# Time in stage: each open lane at its time in its current stage; Building holds the most lane-hours (m-stuck blocked
# two hours, m-build ten minutes), so it is the bottleneck, and its row opens the Board filtered to Building.
for w in 390 1280; do
  shot "aging-$w" '#/overview' "$w" 'Bottleneck now'
  chrome-devtools-axi eval '(() => { const h = [...document.querySelectorAll(".ov-card h3")].find(e => e.textContent === "Time in stage"); h.scrollIntoView({ block: "start" }); return h.parentElement.innerText })()' >"$DONE_DONE_EVIDENCE_ROOT/aging-card-$w.txt"
  chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/aging-$w.png" >/dev/null
  grep -qF 'Bottleneck now: Building' "$DONE_DONE_EVIDENCE_ROOT/aging-card-$w.txt" || { echo "run-core-proof: Time in stage at $w names no Building bottleneck: $(cat "$DONE_DONE_EVIDENCE_ROOT/aging-card-$w.txt")" >&2; exit 1; }
  [ "$(chrome-devtools-axi eval 'document.querySelectorAll(".ov-atrack i").length' | sed -n 's/^result: //p' | tr -d '"')" = 4 ] || { echo "run-core-proof: Time in stage at $w does not draw the four open lanes" >&2; exit 1; }
done
chrome-devtools-axi eval 'document.querySelector(".ov-abn").click()' >/dev/null
sleep 1
chrome-devtools-axi eval 'location.hash' | grep -qF '#/board?stage=building' || { echo "run-core-proof: the bottleneck row did not open the Building Board" >&2; exit 1; }
# Metrics puts GitHub's merges in the fleet's repositories beside the recorded ones: today, the average before today and
# how many of GitHub's merges the records hold (one recorded today, none on earlier days: 1 of 3 before today is 0).
for w in 390 1280; do
  shot "forge-$w" '#/overview' "$w" 'records hold'
  chrome-devtools-axi eval '(() => { const h = [...document.querySelectorAll(".ov-card h3")].find(e => e.textContent === "Flow"); h.scrollIntoView({ block: "start" }); return h.parentElement.innerText })()' >"$DONE_DONE_EVIDENCE_ROOT/forge-card-$w.txt"
  chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/forge-$w.png" >/dev/null
  grep -qF 'GitHub 2 today' "$DONE_DONE_EVIDENCE_ROOT/forge-card-$w.txt" && grep -qF '(0 of 3) in 1 repository' "$DONE_DONE_EVIDENCE_ROOT/forge-card-$w.txt" \
    || { echo "run-core-proof: the Flow card at $w lacks GitHub's count beside the records: $(cat "$DONE_DONE_EVIDENCE_ROOT/forge-card-$w.txt")" >&2; exit 1; }
done
[ "$(chrome-devtools-axi eval 'document.querySelectorAll(".ov-days rect.ref").length' | sed -n 's/^result: //p' | tr -d '"')" = 2 ] || { echo "run-core-proof: the Landed chart does not mark GitHub's two merge days (today and yesterday)" >&2; exit 1; }
# Metrics shows memory as the memory gate reads it: the 10 s spike of 45% is not the pressure, the sustained 8% is.
shot memory-390 '#/overview' 390 'as the memory gate reads it'
chrome-devtools-axi eval '(() => { const h = [...document.querySelectorAll(".ov-card h3")].find(e => e.textContent === "Memory"); h.scrollIntoView({ block: "center" }); return h.parentElement.innerText })()' >"$DONE_DONE_EVIDENCE_ROOT/memory-card.txt"
chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/memory-390.png" >/dev/null
grep -qF '8.0%' "$DONE_DONE_EVIDENCE_ROOT/memory-card.txt" && grep -qF 'Free of 64 GB' "$DONE_DONE_EVIDENCE_ROOT/memory-card.txt" && ! grep -qF '45%' "$DONE_DONE_EVIDENCE_ROOT/memory-card.txt" \
  || { echo "run-core-proof: the Metrics memory card is not the gate's reading: $(cat "$DONE_DONE_EVIDENCE_ROOT/memory-card.txt")" >&2; exit 1; }
for v in overview insights tickets; do
  shot "end-$v-390" "#/$v" 390 "$( case $v in insights) echo 'Why work waits' ;; tickets) echo 'Your asks done' ;; *) echo Live ;; esac )"
  chrome-devtools-axi eval '(() => { scrollTo(0, 1e6); document.querySelectorAll(".ins, .mcols > .tkc").forEach(e => e.scrollTop = 1e6); return 1 })()' >/dev/null
  sleep 1
  chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/end-$v-390.png" >/dev/null
done
# The new Tickets screen in the dark theme too: the stored theme applies on the next full load (a new query string).
chrome-devtools-axi eval 'localStorage.setItem("fm-theme", "dark")' >/dev/null
for w in 390 1280; do
  shot "tickets-dark-$w" "?dark-$w#/tickets" "$w" 'Your asks done'
  shot "ticket-page-dark-$w" "?dark-page-$w#/tickets?ticket=main/m-ask" "$w" 'Your words'
done
chrome-devtools-axi eval 'localStorage.removeItem("fm-theme")' >/dev/null
# The app opens on Tickets, and the phone's pill nav has one button per view, each named; the current one shows its name.
shot landing-390 '?landing' 390 'Your asks done'
chrome-devtools-axi eval 'JSON.stringify([...document.querySelectorAll(".dock a")].map(a => a.getAttribute("aria-label") + (a.getAttribute("aria-current") ? " (current)" : "")))' >"$DONE_DONE_EVIDENCE_ROOT/landing-dock.txt"
for want in 'Tickets (current)' 'Needs you' Board Metrics Insights; do grep -qF -- "$want" "$DONE_DONE_EVIDENCE_ROOT/landing-dock.txt" || { echo "run-core-proof: the phone pill nav lacks '$want'" >&2; exit 1; }; done
grep -qF 'Fleet dashboard' "$DONE_DONE_EVIDENCE_ROOT/landing-390.txt" || { echo "run-core-proof: the landing page lacks the Fleet dashboard label" >&2; exit 1; }
# Tickets: the backlog mapped to board columns, and only the ask list waits on the captain; a Board card drops tags and Main refs too.
jq -e '([.tickets[] | {(.task): .state}] | add) as $s | ([.tickets[] | {(.task): .}] | add) as $t
  | $s["m-build"] == "progress" and $s["m-ci"] == "review" and $s["m-held"] == "hold" and $s["m-ready"] == "todo" and $s["m-shipped"] == "done"
  and $t["m-ready"].priority == 1 and $t["m-ready"].release == "next" and $t["m-ready"].project == "beta-app" and $t["m-build"].release == "v0.2.0" and $t["m-ci"].release == "later"
  and $t["m-ask"].asked and $t["m-ask"].title == "Choose the layout for the new screen" and $t["m-ask"].priority == 0
  and ([.cards[] | select(.task == "m-ask")][0].title == "Choose the layout for the new screen")
  and $t["m-shipped"].pr == "https://github.com/acme/alpha/pull/4" and all(.tickets[]; .state != "captain") and (.asks | length) == 3 and all(.asks[]; .age != null)
  and ([.asks[] | select(.id == "pick-home")][0] | .options == ["A", "B", "Later"] and .default == "A" and (.why | startswith("Both layouts")))' \
  "$home/state/dashboard/board.json" >/dev/null || { echo "run-core-proof: tickets mapping wrong: $(jq -c '.tickets' "$home/state/dashboard/board.json")" >&2; exit 1; }
# tasks-axi list cuts a long name and body; the ticket carries the whole of both (from show --full, then cached), the
# ask's Main message, and a lane's proof: its completion receipt and the done-done verdict on its merge card.
jq -e '(.tickets[] | select(.task == "m-long")) as $t
  | $t.title == "Keep every ticket name whole on the board so a long name that runs past eighty characters still reads to its very end"
  and ($t.desc | startswith("Names and descriptions come from") and endswith("The description ends here.")) and $t.ask.ref == "Main77" and $t.ask.day == "23 Oct"
  and ([.tickets[] | select(.task == "m-ask")][0].ask.ref == "Main42")
  and ([.tickets[] | select(.task == "m-ci")][0].proof == {"receipt": "PASS", "head": "abc1234", "at": '"$(jq '.at' "$home/state/m-ci.run-receipt.json")"', "check": "pass"})' \
  "$home/state/dashboard/board.json" >/dev/null || { echo "run-core-proof: whole names, ask refs or proof wrong: $(jq -c '[.tickets[] | select(.task == "m-long" or .task == "m-ci") | {title, desc, ask, proof}]' "$home/state/dashboard/board.json")" >&2; exit 1; }
[ "$(jq length "$home/state/dashboard/full-text.json")" = 1 ] || { echo "run-core-proof: full-text cache does not hold exactly the one cut item" >&2; exit 1; }
for w in 390 1280; do shot "ticket-long-$w" "#/tickets?ticket=main/m-long" "$w" 'reads to its very end'; done
shot ticket-proof-1280 '#/tickets?ticket=main/m-ci' 1280 'Receipt PASS'  # the fields card is the computer's; a phone has the three tiles
grep -qF 'Receipt PASS · done-done pass · abc1234' "$DONE_DONE_EVIDENCE_ROOT/ticket-proof-1280.txt" && grep -qF 'Main77' "$DONE_DONE_EVIDENCE_ROOT/ticket-long-390.txt" \
  || { echo "run-core-proof: the ticket page lacks the proof line or the ask's Main message" >&2; exit 1; }
# The ticket page: the description without bookkeeping, the captain's words it serves, and the lane's status lines.
for w in 390 1280; do shot "ticket-page-$w" '#/tickets?ticket=main/m-ask' "$w" 'Your words'; done
shot ticket-held-390 '#/tickets?ticket=main/m-held' 390 'Main decides: wait for the new layout.'
# A comment needs the owner's sign-off board token, which the board's sign-off-<port> cookie carries: none, a wrong one
# or a form post is refused, an unknown ticket too. With the board's cookie in the browser, as opening the board's link
# at this address leaves it, the captain's comment goes from the page with no pasted secret, reaches Main as a note,
# and Main's pickup and reply show under it in the thread.
tok=$(cat "$home/board/board.token")
post() { curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: $1" -H "Cookie: $2" --data "$3" "${url}comment"; }
[ "$(post application/json '' '{"ticket":"main/m-ask","text":"hi"}')" = 401 ] && [ "$(post application/json sign-off-4420=wrong '{"ticket":"main/m-ask","text":"hi"}')" = 401 ] \
  && [ "$(post application/json "sign-off-4420=$tok" '{"ticket":"main/nope","text":"hi"}')" = 404 ] \
  && [ "$(post application/x-www-form-urlencoded "sign-off-4420=$tok" '{"ticket":"main/m-ask","text":"hi"}')" = 415 ] \
  || { echo "run-core-proof: the comment endpoint took a bad request" >&2; exit 1; }
say() {  # <ticket> <text>: send a comment from the ticket page
  shot "ticket-comment-$1" "?c-$1#/tickets?ticket=$2" 390 'Activity'
  chrome-devtools-axi eval "(() => { const t = document.querySelector('.tk-say textarea'); t.value = '$3'; t.dispatchEvent(new Event('input', { bubbles: true })); setTimeout(() => document.querySelector('.tk-say').requestSubmit(), 50); return 1 })()" >/dev/null
}
chrome-devtools-axi eval "document.cookie = 'sign-off-4420=$tok; path=/'" >/dev/null  # what the board's link leaves
say main main/m-ask 'Pick the layout that keeps the ask list on top.'
chrome-devtools-axi wait 'Sent to Main' >/dev/null  # the comment shows in the thread at once
chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/ticket-comment-sent-390.png" >/dev/null
inbox() { env PATH="$home/stubs:$PATH" HOME="$home" FM_HOME="$home" bash "$bin/fm-inbox.sh" "$@"; }
note=$(jq -r 'select(.ticket == "main/m-ask") | .note' "$home/state/dashboard/comments.jsonl")
grep -qF 'Answer the captain in the ticket thread: bin/fm-inbox.sh reply' "$home/state/inbox/$note.note" || { echo "run-core-proof: the comment did not reach Main's inbox with how to answer" >&2; exit 1; }
inbox drain --ack "$note" >/dev/null
inbox reply "$note" "Agreed: the ask list stays on top in both layouts." >/dev/null
# The lead: the comment goes through fm-send to its endpoint, which rings; the lead picks the steer up (moves it to
# handled/) and runs the answer command it carries, unchanged, with its own FM_HOME.
say alpha alpha/t-lead 'Keep the ask list above the fold on a phone.'
chrome-devtools-axi wait 'Sent to the alpha lead as a steer' >/dev/null
steer=$(grep -lF 'Keep the ask list above the fold on a phone.' "$home"/state/alpha.inbox/*.msg)
env -u TMUX TMUX_TMPDIR="$home/tmux" tmux capture-pane -p -t core:alpha | grep -qF 'instruction waiting' || { echo "run-core-proof: the lead's endpoint was not rung" >&2; exit 1; }
mv "$steer" "$home/state/alpha.inbox/handled/"
answer=$(sed -n 's/.*(your FM_HOME already names your own home): //p' "$home/state/alpha.inbox/handled/${steer##*/}" | sed 's/<your answer in plain words>/Read: the ask list stays above the fold./')
(cd "$home/alpha" && env PATH="$home/stubs:$PATH" HOME="$home" FM_HOME="$home/alpha" bash -c "$answer") >/dev/null
dash build >/dev/null
for w in 390 1280; do
  shot "ticket-thread-$w" "?thread-$w#/tickets?ticket=main/m-ask" "$w" 'Agreed: the ask list stays on top'
  shot "lead-thread-$w" "?lead-$w#/tickets?ticket=alpha/t-lead" "$w" 'Read: the ask list stays above the fold.'
done
grep -qF 'Sent to Main' "$DONE_DONE_EVIDENCE_ROOT/ticket-thread-390.txt" && grep -qF 'Picked up your comment' "$DONE_DONE_EVIDENCE_ROOT/lead-thread-390.txt" \
  || { echo "run-core-proof: a thread lacks the sent comment or its pickup" >&2; exit 1; }
jq -e '[.tickets[] | .comments[] | select(.picked > 0) | .replies[] | select(.at > 0) | [.by, .text]] | sort
  == [["alpha", "Read: the ask list stays above the fold."], ["main", "Agreed: the ask list stays on top in both layouts."]]' \
  "$home/state/dashboard/board.json" >/dev/null || { echo "run-core-proof: a pickup or answer is not on its ticket thread: $(jq -c '[.tickets[] | .comments[]]' "$home/state/dashboard/board.json")" >&2; exit 1; }
jq -e '(.tickets[] | select(.task == "m-ask")) as $t | $t.ask == {"words": "Show the new screen in the layout a phone reads first", "day": "22 Oct", "ref": "Main42"}
  and $t.desc == "Two layouts are drawn; the lead picks one."
  and ([.tickets[] | select(.task == "m-held")][0] | .desc == "Main decides: wait for the new layout." and .ask.day == "22 Oct")' \
  "$home/state/dashboard/board.json" >/dev/null || { echo "run-core-proof: ticket page fields wrong: $(jq -c '.tickets[] | select(.task == "m-ask")' "$home/state/dashboard/board.json")" >&2; exit 1; }
for w in 390 1280; do
  for want in "Your words · 22 Oct · Main42" "Two layouts are drawn" "Main decides" $([ "$w" = 390 ] || echo Lead); do
    grep -qF -- "$want" "$DONE_DONE_EVIDENCE_ROOT/ticket-page-$w.txt" || { echo "run-core-proof: ticket page at $w lacks '$want'" >&2; exit 1; }
  done
done
for w in 390 1280; do
  for want in "Waiting on you" "Your asks" "Choose the layout for the new screen" P0; do
    grep -qF -- "$want" "$DONE_DONE_EVIDENCE_ROOT/tickets-$w.txt" || { echo "run-core-proof: Tickets at $w lacks '$want'" >&2; exit 1; }
  done
  grep -qF -- "Link the alpha npm package to GitHub?" "$DONE_DONE_EVIDENCE_ROOT/needs-$w.txt" || { echo "run-core-proof: Needs you at $w lacks the ask" >&2; exit 1; }
done
# The computer's sidebar foot names the board's reader (config/owner-name) and when the board was read, in UTC.
grep -qF 'Umer' "$DONE_DONE_EVIDENCE_ROOT/tickets-1280.txt" && grep -qE 'Board read [0-9]{2}:[0-9]{2} UTC' "$DONE_DONE_EVIDENCE_ROOT/tickets-1280.txt" \
  || { echo "run-core-proof: the sidebar foot lacks the reader or the board's read time" >&2; exit 1; }
# Needs you leads with how many questions wait. Search (/) groups what matches: the ask's ticket and its lane by title.
for w in 390 1280; do
  grep -qF 'Questions waiting on you' "$DONE_DONE_EVIDENCE_ROOT/needs-$w.txt" || { echo "run-core-proof: Needs you at $w lacks its hero" >&2; exit 1; }
  shot "search-$w" "?search-$w#/tickets" "$w" 'Your asks done'
  chrome-devtools-axi eval "(() => { dispatchEvent(new KeyboardEvent('keydown', { key: '/' })); setTimeout(() => { const i = document.querySelector('.pal input'); i.value = 'layout'; i.dispatchEvent(new Event('input', { bubbles: true })) }, 200); return 1 })()" >/dev/null
  sleep 1
  chrome-devtools-axi eval 'document.querySelector(".pal").innerText' >"$DONE_DONE_EVIDENCE_ROOT/search-$w.txt"
  chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/search-$w.png" >/dev/null
  for want in Tickets Lanes 'Choose the layout for the new screen'; do
    grep -qF -- "$want" "$DONE_DONE_EVIDENCE_ROOT/search-$w.txt" || { echo "run-core-proof: search at $w lacks '$want': $(cat "$DONE_DONE_EVIDENCE_ROOT/search-$w.txt")" >&2; exit 1; }
  done
done
# A question opens on its own page; J, the right arrow and a swipe move through the list in its order and type filter,
# the position reads "n of N", and the ends stop: the next arrow is off on the last question.
pos() { chrome-devtools-axi eval 'document.querySelector(".ask .pos").textContent + "|" + document.querySelector(".ask h2").textContent + "|" + document.querySelector("[aria-label=\"Next question\"]").disabled' | sed -n 's/^result: //p' | tr -d '\042\134'; }  # drop the quotes and escapes around the result
key() { chrome-devtools-axi eval "dispatchEvent(new KeyboardEvent('keydown', { key: '$1' }))" >/dev/null; sleep 0.4; }
for w in 390 1280; do
  shot "ask-$w" "?ask-$w#/needs" "$w" 'Questions waiting on you'
  chrome-devtools-axi eval 'document.querySelector(".trow[role=button]").click()' >/dev/null; sleep 0.5
  [ "$(pos)" = '1 of 3|Link the alpha npm package to GitHub?|false' ] || { echo "run-core-proof: the first question at $w reads $(pos)" >&2; exit 1; }
  key j; [ "$(pos)" = '2 of 3|Pick the home screen layout: A Cards or B List?|false' ] || { echo "run-core-proof: J at $w reads $(pos)" >&2; exit 1; }
  if [ "$w" = 390 ]; then  # a swipe left on a phone
    chrome-devtools-axi eval '(() => { const a = document.querySelector(".ask"), t = x => [new Touch({ identifier: 1, target: a, clientX: x, clientY: 400 })]
      a.dispatchEvent(new TouchEvent("touchstart", { changedTouches: t(300), bubbles: true })); a.dispatchEvent(new TouchEvent("touchend", { changedTouches: t(120), bubbles: true })); return 1 })()' >/dev/null; sleep 0.4
  else key ArrowRight; fi
  [ "$(pos)" = '3 of 3|Approve the alpha 0.2.0 release?|true' ] || { echo "run-core-proof: the last question at $w reads $(pos)" >&2; exit 1; }
  chrome-devtools-axi eval 'document.querySelector(".ask").innerText' >"$DONE_DONE_EVIDENCE_ROOT/ask-$w.txt"
  chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/ask-$w.png" >/dev/null
  key j; [ "$(pos)" = '3 of 3|Approve the alpha 0.2.0 release?|true' ] || { echo "run-core-proof: J past the end at $w reads $(pos)" >&2; exit 1; }
  for want in 'Why it is asked' 'CI is green' 'Yes · suggested' 'Answer where it was asked' 'Asked 2h'; do
    grep -qF -- "$want" "$DONE_DONE_EVIDENCE_ROOT/ask-$w.txt" || { echo "run-core-proof: the question page at $w lacks '$want'" >&2; exit 1; }
  done
done
shot ask-filter-1280 '?ask-f#/needs?atype=pick&ask=pick-home' 1280 'Pick the home screen layout'
[ "$(pos)" = '1 of 1|Pick the home screen layout: A Cards or B List?|true' ] || { echo "run-core-proof: the type filter's question reads $(pos)" >&2; exit 1; }
# Release lanes: a project's lowest named release is its Next release (alpha v0.2.0), a literal next stays Next
# (beta), a later named release is After, and no release line is Later; done work is not in a lane.
cols() { chrome-devtools-axi eval '(() => { document.querySelectorAll(".lane .all").forEach(b => b.textContent === "See all" && b.click()); return 1 })()' >/dev/null; sleep 0.5
  chrome-devtools-axi eval 'JSON.stringify([...document.querySelectorAll(".lane")].map(c => [c.querySelector("h2").textContent, ...[...c.querySelectorAll("h3")].map(h => h.textContent).sort()]))' \
  | sed -n 's/^result: //p' | jq -c 'fromjson | if type == "string" then fromjson else . end'; }
# Your asks and System split the tickets; the ask m-ask is the one ticket under Your asks.
for w in 390 1280; do shot "tickets-release-$w" '#/tickets?by=release&kind=system' "$w" 'Next release'
  want='[["Next release","Build the main thing","Start the ready thing"],["After","After the ready thing"],["Later","Get the layout pull request through CI","Keep the ask list on top","Publish the release from the build server","Wait for the captain'"'"'s call"]]'
  [ "$(cols)" = "$want" ] || { echo "run-core-proof: release lanes at $w wrong: $(cols)" >&2; exit 1; }
  shot "tickets-release-asks-$w" '#/tickets?by=release' "$w" 'Next release'
  [ "$(cols)" = '[["Next release"],["After"],["Later","Choose the layout for the new screen"]]' ] || { echo "run-core-proof: the ask's release lane at $w wrong: $(cols)" >&2; exit 1; }
done
shot tickets-release-filter-1280 '#/tickets?release=v0.2.0&kind=system' 1280 'Build the main thing'
[ "$(cols | jq -c '[.[] | .[1:][]]')" = '["Build the main thing"]' ] || { echo "run-core-proof: the v0.2.0 filter shows $(cols)" >&2; exit 1; }
# The Metrics lifecycle rail opens the Board filtered to that stage, and To land to To merge.
for w in 390 1280; do
  shot "rail-$w" '#/overview' "$w" Lifecycle
  chrome-devtools-axi eval '[...document.querySelectorAll(".ov-stage")].find(b => b.textContent.includes("PR + CI")).click()' >/dev/null
  chrome-devtools-axi wait m-ci >/dev/null
  chrome-devtools-axi eval 'JSON.stringify({ viewport: innerWidth, hash: location.hash, text: document.body.innerText })' >"$DONE_DONE_EVIDENCE_ROOT/board-stage-$w.txt"
  chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/board-stage-$w.png" >/dev/null
  grep -qF '#/board?stage=ci' "$DONE_DONE_EVIDENCE_ROOT/board-stage-$w.txt" && grep -qF 'Stage is' "$DONE_DONE_EVIDENCE_ROOT/board-stage-$w.txt" \
    && ! grep -qF m-build "$DONE_DONE_EVIDENCE_ROOT/board-stage-$w.txt" || { echo "run-core-proof: the PR + CI stage at $w did not open the filtered Board" >&2; exit 1; }
done
shot to-land-1280 '#/overview' 1280 Lifecycle
chrome-devtools-axi eval '[...document.querySelectorAll(".ov-kpi")].find(b => b.textContent.includes("To land")).click()' >/dev/null
sleep 1
chrome-devtools-axi eval 'location.hash' | grep -qF '#/board?stage=merge' || { echo "run-core-proof: To land did not open the To merge Board" >&2; exit 1; }
chrome-devtools-axi resize 390 844 >/dev/null
chrome-devtools-axi open "${url}#/insights" >/dev/null
chrome-devtools-axi wait "Why work waits" >/dev/null
sleep 2
chrome-devtools-axi eval 'JSON.stringify({ viewport: innerWidth, text: document.body.innerText })' >"$DONE_DONE_EVIDENCE_ROOT/queue.txt"
chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/queue-390.png" >/dev/null

# The page must show each seeded lane and each queue reason, not just render.
for want in m-stuck m-ask m-ci m-build "Main decides"; do
  grep -qF -- "$want" "$DONE_DONE_EVIDENCE_ROOT/board.txt" || { echo "run-core-proof: Board lacks '$want'" >&2; exit 1; }
done
for want in "Why work waits now" "Blocked · own note" "Lead reply" "Held"; do
  grep -qF -- "$want" "$DONE_DONE_EVIDENCE_ROOT/queue.txt" || { echo "run-core-proof: Insights lacks '$want'" >&2; exit 1; }
done

if [ -z "${BOARD_SHOTS_ONLY:-}" ]; then
  e=$DONE_DONE_EVIDENCE_ROOT
  for w in 390 1280; do
    grep -qF 'm-ci' "$e/board-waiting-$w.txt" && ! grep -qF 'm-stuck' "$e/board-waiting-$w.txt" || { echo "run-core-proof: Waiting tab at $w is not just the waiting lane" >&2; exit 1; }
    grep -qF 'm-stuck' "$e/board-stuck-$w.txt" && ! grep -qF 'm-build' "$e/board-stuck-$w.txt" || { echo "run-core-proof: Stuck tab at $w is not just the stuck lanes" >&2; exit 1; }
  done
  grep -qF '4 / 3' "$e/board-homes-1280.txt" || { echo "run-core-proof: home band lacks the count against the lane cap" >&2; exit 1; }
  grep -qF '4 / 3' "$e/board-homes-390.txt" || { echo "run-core-proof: phone home column lacks the count against the lane cap" >&2; exit 1; }
fi

# A failing flow reader names its cause on Insights instead of a bare "unavailable".
mkdir "$home/badbin" && for f in "$bin"/*; do ln -s "$(readlink "$f")" "$home/badbin/${f##*/}"; done
rm -- "$home/badbin/fm-flow.sh" && printf '#!/bin/sh\necho "fm-flow: lane records unreadable" >&2\nexit 3\n' > "$home/badbin/fm-flow.sh"
bin=$home/badbin dash build >/dev/null
jq -e '.flow == null and .flow_error == "Flow reader unavailable: fm-flow: lane records unreadable"' "$home/state/dashboard/board.json" >/dev/null \
  || { echo "run-core-proof: flow_error lacks the reader's cause: $(jq -c .flow_error "$home/state/dashboard/board.json")" >&2; exit 1; }
shot flow-error-390 '?flow-error#/insights' 390 'lane records unreadable'

# The steps and result the check judges the captures against.
# Breakpoints on touch screens: a phone up to 759 px gets the phone design (the dock, no sidebar, 14 px row
# titles), a touch tablet the computer layout with 44 px sidebar rows; on both every visible control takes a 44 px tap
# (a point 21 px off its centre on each side still lands on it). A mouse at 1280 px keeps the 36 px rows.
taps='(() => { const bad = []; for (const e of document.querySelectorAll("a, button, [role=button], textarea")) { const r = e.getBoundingClientRect(); if (!r.width || !r.height || r.bottom < 0 || r.top > innerHeight) continue
  const x = r.left + r.width / 2, y = r.top + r.height / 2, on = (px, py) => { const h = document.elementFromPoint(px, py); return !h || e.contains(h) || h.contains(e) }
  if (!e.contains(document.elementFromPoint(x, y))) continue
  if (![[x, y - 21], [x, y + 21], [x - 21, y], [x + 21, y]].every(([px, py]) => px < 0 || py < 0 || px >= innerWidth || py >= innerHeight || on(px, py))) bad.push((e.getAttribute("aria-label") || e.textContent).trim().slice(0, 30) + " " + Math.round(r.width) + "x" + Math.round(r.height)) }
  return JSON.stringify({ dock: !!document.querySelector(".dock"), h3: getComputedStyle(document.querySelector(".rx h3")).fontSize, nav: document.querySelector(".nav") ? Math.round(document.querySelector(".nav").getBoundingClientRect().height) : 0, bad }) })()'
for spec in 360x780x3,mobile,touch 412x915x2.6,mobile,touch 445x900x2.6,mobile,touch 600x960x2,mobile,touch 768x1024x2,mobile,touch 1024x768x2,mobile,touch 1280x900x1; do
  w=${spec%%x*}
  chrome-devtools-axi emulate --viewport "$spec" >/dev/null
  for v in tickets needs; do
    chrome-devtools-axi open "$url?bp-$w-$v#/$v" >/dev/null; chrome-devtools-axi wait "$( [ $v = tickets ] && echo 'Your asks done' || echo 'Questions waiting on you' )" >/dev/null
    got=$(chrome-devtools-axi eval "$taps" | sed -n 's/^result: //p' | tr -d '\042\134')
    echo "$spec $v $got" >>"$DONE_DONE_EVIDENCE_ROOT/breakpoints.txt"
    case "$w:$got" in
      360:*|412:*|445:*|600:*) want='dock:true' nav='' ;;
      768:*|1024:*) want='dock:false' nav='nav:44' ;;
      *) want='dock:false' nav='nav:36' ;;
    esac
    case "$got" in *"$want"*) ;; *) echo "run-core-proof: $v at $spec is not the expected layout ($want): $got" >&2; exit 1 ;; esac
    [ -z "$nav" ] || case "$got" in *"$nav"*) ;; *) echo "run-core-proof: $v at $spec sidebar rows are not $nav: $got" >&2; exit 1 ;; esac
    case "$w:$got" in 360:*|412:*|445:*|600:*) case "$got" in *h3:14px*) ;; *) echo "run-core-proof: $v at $spec row titles are not 14 px: $got" >&2; exit 1 ;; esac ;; esac
    case "$w:$got" in 1280:*|*'bad:[]'*) ;; *) echo "run-core-proof: $v at $spec has controls under a 44 px tap: $got" >&2; exit 1 ;; esac
  done
  case $w in 445|1024) chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/breakpoint-$w.png" >/dev/null ;; esac
done
python3 - "$DONE_DONE_EVIDENCE_ROOT/steps.json" "$(git -C "$root" rev-parse --short HEAD)" <<'PY'
import json, sys
steps = {
    "target": {"version": sys.argv[2]},
    "start": "A seeded Firstmate home: four agent lanes, one landed task, three queued tasks, served by this checkout's dashboard",
    "steps": [
        "Open the fleet dashboard in headless Chrome at 390px",
        "Read the Board: each lane with its title and state",
        "Open the Stuck and Waiting tabs and the by-home view at 390px and 1280px",
        "Open Insights: the queue and wait reasons",
        "Look at the sidebar at 1280px and the phone dock at 390px: no Ship tab, only Board, Tickets, Overview, Insights and Needs you",
        "Open Tickets at 390px and 1280px: every backlog item on the board, the ask list as Waiting on captain",
        "Open a ticket at 390px and 1280px: its description, the captain's words it serves, its fields and its activity",
        "Open the held ticket at 390px: its description is the plain decision, with no leftover labels or punctuation",
        "Open Overview at 390px and 1280px: each card names its source; scroll Overview, Insights and Tickets to the end at 390px",
        "With the owner's sign-off board cookie in the browser, write a comment on the ticket and send it to the owning lead (Main here), with no pasted secret",
        "Pick the note up and reply to it as Main with fm-inbox.sh, and open the ticket thread at 390px and 1280px",
        "Comment on the alpha lead's ticket; as the lead, pick the steer up and run the answer command it carries; open that thread at 390px and 1280px",
        "Switch Tickets to By release at 390px and 1280px, then filter it to release v0.2.0",
        "On Metrics at 390px and 1280px, tap the PR + CI stage of the lifecycle rail; tap To land at 1280px",
        "Build with a flow reader that fails and open Insights at 390px",
        "Open the Memory card on Metrics at 390px with a 45% 10 s spike over an 8% 60 s average",
        "Open Time in stage on Metrics at 390px and 1280px, then tap the bottleneck row",
        "Open the ticket with a long name at 390px and 1280px, and the m-ci ticket with its proof",
        "Open the Flow card on Metrics at 390px and 1280px: GitHub's merges beside the recorded ones",
        "Open Needs you on a phone (390px) and a computer (1280px): how many questions wait, then one row per question with its type, age and Open link",
        "Open Search with / on a phone (390px) and a computer (1280px) and type layout",
        "On touch screens 360, 412, 445 and 600px wide and touch tablets 768 and 1024px wide, and with a mouse at 1280px, open Tickets and Needs you and try every control 21px off its centre",
        "Open the first question on Needs you on a phone and a computer, move to the next with J, then with a swipe (phone) or the right arrow (computer), and try past the last; open a question under the Pick type filter",
    ],
    "result": "The Board lists m-stuck, m-ask, m-ci and m-build with their titles and states; the Stuck tab holds only stuck lanes, the Waiting tab only the waiting lane, and a home with four open lanes against a cap of three reads 4 / 3; Insights shows Why work waits now with the Blocked, Lead reply and Held groups; Tickets puts each backlog item in its column with its priority chip and release, the captain-held item On hold, and only the one ask under Waiting on captain; a ticket page shows its description, the captain's words with their day, and the lane's activity; Overview names the source of every figure, and each page's end clears the tab bar at 390px; the sidebar and the phone dock no longer offer a Ship tab; a post without the owner's board token is refused, the board's cookie lets the page send a comment with no pasted secret, the comment reaches Main's inbox and shows in the ticket thread as sent with Main's pickup and reply under it, and a comment on a lead's ticket reaches that lead's endpoint through fm-send and shows the lead's pickup and its own answer; By release puts alpha's v0.2.0 and beta's next item under Next release, the v0.3.0 item under After and items with no release under Later, and the v0.2.0 filter leaves only its item; the PR + CI stage opens the Board filtered to that stage with a removable Stage chip, and To land opens it filtered to To merge; a failing flow reader shows its own error on Insights; the Metrics Memory card reads 32 GB free of 64 GB and 8.0% pressure, not the 45% spike; Time in stage draws the four open lanes, names Building the bottleneck and its row opens the Building Board; a ticket whose name and body the backlog list cuts shows both whole, with its ask's day and Main message, and the m-ci ticket page shows Receipt PASS · done-done pass · abc1234; the Flow card shows GitHub 2 today, the average before today and that the records hold 0 of 3 of GitHub's earlier merges in 1 repository, with GitHub's count marked on each day of the Landed chart; Needs you shows how many questions wait and one row per question with its type, its age and an Open link to answer it where it was asked; Search opens (a full-screen sheet on a phone, a panel over the page on a computer) with a rounded search field above the matching tickets and lanes in their own groups, each row with its icon and priority chip, and finds the ask's ticket and lane by the word layout; a question opens on its own page with its type, when it was asked, why it is asked and its answers with the suggested one, and prev/next moves through the list in its order with the position (1 of 3, 2 of 3, 3 of 3) in the header, the next arrow off on the last question, and under a type filter only that type (1 of 1); touch screens up to 759px get the phone design with the dock and 14px row titles, touch tablets at 768 and 1024px the computer layout with 44px sidebar rows, and every visible control on Tickets and Needs you takes a 44px tap there, while a mouse at 1280px keeps the 36px rows",
}
with open(sys.argv[1], "w") as f:
    json.dump(steps, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
