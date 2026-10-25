#!/usr/bin/env bash
# Sync a stuck leaf onto a task-owned sign-off board and capture stage + stuck Nh on Tickets.
set -euo pipefail
: "${DONE_DONE_EVIDENCE_ROOT:?done-done must provide its run evidence folder}"
command -v sign-off-axi >/dev/null || { echo 'sign-off-axi is required' >&2; exit 1; }
command -v chrome-devtools-axi >/dev/null || { echo 'chrome-devtools-axi is required' >&2; exit 1; }
ver=$(sign-off-axi --version | head -n1)
case $ver in 0.6.9|0.6.[1-9][0-9]*|0.[7-9]*|[1-9]*) ;; *)
  echo "sign-off-axi $ver is older than 0.6.9 (needs --stage and --last-event-at)" >&2; exit 1 ;;
esac
real_home=${HOME:-/home/you}
repo=$(cd "$(dirname "$0")/.." && pwd -P)
# The add-on lives under <fork>/addons here, so the fork that owns bin/ is one level up.
fork=${FM_TEST_FORK:-${FM_MAIN_HOME:-$(cd "$repo/.." && pwd -P)}}
evidence=$DONE_DONE_EVIDENCE_ROOT
work=$(mktemp -d "$evidence/stage-board.XXXXXX")
export HOME=$work/user XDG_DATA_HOME=$work/xdg SIGN_OFF_HOME=$work/signoff
export FM_HOME=$work/main TMPDIR=$work/tmp
mkdir -p "$HOME" "$FM_HOME"/{data,config,state,projects/alpha} "$TMPDIR"
ln -s "$fork/bin" "$FM_HOME/bin"
printf '{"schema":2,"items":[]}\n' > "$work/board.json"
printf '%s\n' "$work/board.json" > "$FM_HOME/config/fleet-board"
printf '[markdown]\npath="data/backlog.md"\narchive="data/done-archive.md"\ndone_keep=0\n' > "$FM_HOME/.tasks.toml"
(cd "$FM_HOME"; tasks-axi add stuck 'Umer stuck telescope focus' --repo alpha --priority 1 --body $'release: next\nparent: upkeep' >/dev/null
 tasks-axi start stuck >/dev/null)
git init -q "$FM_HOME/projects/alpha"
git -C "$FM_HOME/projects/alpha" remote add origin https://github.com/example/ownvoice.git
# More than six hours ago so the board draws stuck Nh.
old=$(( $(date +%s) - 8 * 3600 ))
printf 'working [at=%s]: building Umer stuck telescope focus\n' "$old" > "$FM_HOME/state/stuck.status"
bash "$repo/tickets-sync/install.sh"
"$FM_HOME/state/tickets-sync.check.sh" | tee "$evidence/sync.out"
tid=$(printf 'fm-%s' "$(printf '%s' main/stuck | sha256sum | cut -c1-32)")
sign-off-axi ticket "$work/board.json" --id "$tid" --json | tee "$evidence/ticket.json" | jq -e --argjson old "$old" \
  '.ticket.stage == "building" and .ticket.last_event_at == $old and .ticket.progress == 30' >/dev/null
# serve stays in the foreground; run it in the background and stop by board path.
sign-off-axi serve "$work/board.json" --port 0 --bind 127.0.0.1 >"$work/serve.log" 2>&1 &
cleanup() {
  SIGN_OFF_HOME=$work/signoff sign-off-axi stop "$work/board.json" >/dev/null 2>&1 || true
  HOME=$real_home CHROME_DEVTOOLS_AXI_SESSION=${CHROME_DEVTOOLS_AXI_SESSION:-} chrome-devtools-axi stop >/dev/null 2>&1 || true
}
trap cleanup EXIT
for _ in $(seq 1 50); do
  if grep -Eoq 'http://127\.0\.0\.1:[0-9]+' "$work/serve.log"; then break; fi
  sleep 0.1
done
url=$(grep -Eo 'http://127\.0\.0\.1:[0-9]+' "$work/serve.log" | head -n1)
[ -n "$url" ] || { echo "serve did not print a URL: $(cat "$work/serve.log")" >&2; exit 1; }
printf '%s\n' "$url" > "$work/port"
export HOME=$real_home CHROME_DEVTOOLS_AXI_SESSION=tickets-stage-$$
unset XDG_DATA_HOME TMPDIR || true
# a new session can start with its blank tab unselected
chrome-devtools-axi selectpage 1 >/dev/null 2>&1 || true
for theme in light dark; do
  chrome-devtools-axi emulate --viewport 390x844x1 --color-scheme "$theme" >/dev/null
  # Phone list shows only the epic row; open the leaf ticket page for stage + stuck.
  chrome-devtools-axi open "$url#ticket/$tid" >/dev/null
  chrome-devtools-axi wait 'Umer stuck telescope focus' >/dev/null
  chrome-devtools-axi eval 'JSON.stringify({ text: document.body.innerText })' | tee "$evidence/tickets-390-$theme.txt" >/dev/null
  chrome-devtools-axi screenshot "$evidence/tickets-390-$theme.png" >/dev/null
  grep -q building "$evidence/tickets-390-$theme.txt" || { echo "missing stage word building in $theme capture" >&2; exit 1; }
  grep -Eq 'stuck [0-9]+h' "$evidence/tickets-390-$theme.txt" || { echo "missing stuck Nh in $theme capture" >&2; cat "$evidence/tickets-390-$theme.txt" >&2; exit 1; }
done
stat -c '%n %s' "$evidence"/tickets-390-*.png | tee "$evidence/shots.ls"
jq -n --arg version "$ver" --arg url "$url" --argjson old "$old" \
  '{target:{version:$version,board:$url},start:"A disposable Firstmate home has one in-flight leaf whose status stamp is eight hours old.",steps:["Install this checkout'\''s tickets-sync into a throwaway XDG and run the watcher check.","Confirm the ticket JSON carries stage building and last_event_at equal to the status stamp.","Serve the board with sign-off-axi and open the leaf ticket at 390px in light and dark."],result:"Each ticket capture shows the stage word building and a stuck Nh note for the Umer stuck telescope focus leaf."}' \
  > "$evidence/steps.json"
printf 'PASS: tickets stage publish shows building and stuck on the real sign-off Tickets tab\n'
