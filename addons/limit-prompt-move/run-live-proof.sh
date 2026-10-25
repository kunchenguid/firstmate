#!/usr/bin/env bash
# limit-prompt-move live proof: the INSTALLED limit-prompt-move runs against a real tmux pane that shows a
# captured Claude usage-limit menu (tests/weekly-limit-menu.screen). The pane reads one key like Claude's menu
# does; fm-control is a stub that sends the interrupt as a real Escape key to that pane and records the
# relaunch; the pool tool is a stub that answers a fixed pick. No real account, login or Claude is touched.
# Captures: the pane before, the tool's own output (log, status, the key sent, the pool lib it loaded), the pane after.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
tmp=$(mktemp -d)
sock=lpm-live-$$
trap 'tmux -L "$sock" kill-server 2>/dev/null || true; rm -rf -- "$tmp"' EXIT
home=$tmp/home S=$tmp/home/state
mkdir -p "$S" "$home/config" "$home/bin" "$tmp/pool/pa_most_room"
export TMUX_SOCK=$sock FM_HOME=$home
printf '#!/bin/sh\n' >"$home/bin/fm-check-register.sh"; chmod +x "$home/bin/fm-check-register.sh"
printf 'fm_run_timed() { shift; "$@"; }\n' >"$home/bin/fm-timeout-lib.sh"
cat >"$home/bin/fm-backend.sh" <<'LIB'
fm_meta_get() { [ -f "$1" ] || return 0; sed -n "s|^$2=||p" "$1" | tail -n 1; }
fm_backend_of_meta() { echo tmux; }; fm_backend_target_of_meta() { fm_meta_get "$1" endpoint_task_id; }
fm_backend_visible_capture() { tmux -L "$TMUX_SOCK" capture-pane -p -t "$2"; }
LIB
cat >"$home/bin/fm-control.sh" <<'CTL'
#!/usr/bin/env bash
case $2 in
  interrupt) tmux -L "$TMUX_SOCK" send-keys -t lead Escape; echo "fm-control $1 interrupt: sent key Escape to the pane" >>"$FM_HOME/state/control.log" ;;
  relaunch) echo "fm-control $1 relaunch --account $4" >>"$FM_HOME/state/control.log"; cp "$6" "$FM_HOME/state/note"; echo "$4" >"$FM_HOME/state/relaunched"; printf "account=%s\nspawn_gen=s2\n" "$4" >>"$FM_HOME/state/$1.meta" ;;
esac
CTL
chmod +x "$home/bin/fm-control.sh"
cat >"$tmp/byokit-accounts" <<EOF2
#!/usr/bin/env bash
printf '{"ok":true,"id":"pa_most_room","set":{"CLAUDE_CONFIG_DIR":"$tmp/pool/pa_most_room"},"unset":[]}\n'
EOF2
chmod +x "$tmp/byokit-accounts"
printf 'state=%s\ncommand=%s\n' "$tmp/pool" "$tmp/byokit-accounts" >"$home/config/account-pool"
printf 'endpoint_task_id=lead\nkind=secondmate\nharness=claude\nspawn_gen=s1\n' >"$S/muxr-lead.meta"
cat >"$tmp/pane.sh" <<PANE
#!/usr/bin/env bash
cat '$repo/limit-prompt-move/tests/weekly-limit-menu.screen'
IFS= read -rsn1 k
[ "\$k" = \$'\e' ] && echo '[pane] Escape received: menu cancelled, no option chosen'
while [ ! -f '$S/relaunched' ]; do sleep 0.2; done
clear
echo ' ▐▛███▛█▄╱✦  Claude Code v2.1.310 (relaunched)'
echo "▝▜██████▘    Haiku 5.5 · now on account \$(cat '$S/relaunched') (pool pick)"
echo ' ▝▝   ▝▝     ~/work/notes'
echo
echo '  Previous session: usage-limit menu cancelled with Esc; no menu option was chosen.'
echo "❯ \$(cat '$S/note')"
sleep 30
PANE
tmux -L "$sock" new-session -d -s lead -x 100 -y 50 "bash $tmp/pane.sh"
sleep 1
{ echo "BEFORE: a Claude lead pane sitting on the usage-limit menu; options 1, 2 and 3 are visible and option 1 is highlighted"
  tmux -L "$sock" capture-pane -p -t lead | cat -s; } >"$evidence/1-limit-screen-before.txt"

XDG_DATA_HOME=$tmp/share "$repo/limit-prompt-move/install.sh" "$home" >/dev/null
tool=$tmp/share/fm-limit-prompt-move/limit-prompt-move/limit-prompt-move
bash -x "$tool" "$home" 2>"$tmp/trace" || true
sleep 1
{
  echo "TOOL OUTPUT: limit-prompt-move detected that menu, interrupted the lead with Escape and relaunched it on pool account pa_most_room"
  echo "pool library loaded from the account-pool add-on, not the Firstmate bin/:"
  grep -m1 -E '^\++ \. .*account-pool/bin/fm-account-pool-lib\.sh' "$tmp/trace" | sed 's/^+* \. //'
  echo "the installed tool: $tool"
  echo "# state/limit-prompt-move.log:"; cat "$S/limit-prompt-move.log"
  echo "# state/muxr-lead.status:"; cat "$S/muxr-lead.status"
  echo "# keys and calls sent through fm-control:"; cat "$S/control.log"
} >"$evidence/2-tool-output.txt"
{ echo "AFTER: the same lead relaunched on pa_most_room, the menu gone"
  tmux -L "$sock" capture-pane -p -t lead | grep .; } >"$evidence/3-pane-after.txt"
grep -q 'moved off its unrecorded account to account pa_most_room' "$evidence/2-tool-output.txt" \
  && grep -q 'account-pool/bin/fm-account-pool-lib.sh' "$evidence/2-tool-output.txt" \
  && grep -q 'now on account pa_most_room' "$evidence/3-pane-after.txt" || { echo "FAIL limit-prompt-move live" >&2; exit 1; }
{ echo "JOURNEY: a lead sitting on the Claude usage-limit menu is interrupted and relaunched on another pool account by limit-prompt-move, with the pool library loaded from the add-on"
  echo; echo "== 1. POOL LIBRARY LOADED FROM THE ADD-ON (not the Firstmate bin/) =="
  grep -A1 '^pool library loaded' "$evidence/2-tool-output.txt" | tail -n 1
  echo; echo "== 2. $(head -n 1 "$evidence/1-limit-screen-before.txt") =="; tail -n +2 "$evidence/1-limit-screen-before.txt"
  echo; echo "== 3. $(head -n 1 "$evidence/2-tool-output.txt") =="; tail -n +2 "$evidence/2-tool-output.txt"
  echo; echo "== 4. $(head -n 1 "$evidence/3-pane-after.txt") =="; tail -n +2 "$evidence/3-pane-after.txt"
} >"$evidence/journey.txt"
python3 - "$(git -C "$repo" rev-parse HEAD)" >"$evidence/steps.json" <<'P'
import json, sys
print(json.dumps({'target': {'version': sys.argv[1]}, 'start': 'a tmux pane showing the captured Claude usage-limit menu; a fixture home with a stub pool tool; the tool freshly installed in a temporary folder',
  'steps': ['install limit-prompt-move into a temporary data folder', 'run the installed tool once; it loads the pool library from the account-pool add-on', 'the tool reads the pane, finds the usage-limit menu and sends Escape through fm-control, choosing no option',
            'the tool asks the pool for its pick and relaunches the lead on that account', 'capture the pane before, the tool output and the pane after'],
  'result': 'the lead sitting on the limit menu was interrupted with Escape and relaunched on account pa_most_room, with the pool library loaded from the add-on'}, indent=2))
P
echo "PASS limit-prompt-move live"
