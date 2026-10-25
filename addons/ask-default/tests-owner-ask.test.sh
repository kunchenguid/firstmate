#!/usr/bin/env bash
# Real authoring and sign-off commands in an isolated home and board; no live state.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /var/tmp/owner-ask.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
export HOME="$work/home" FM_HOME="$work/home" SIGN_OFF_HOME="$work/board"
export XDG_DATA_HOME="$work/xdg" XDG_CONFIG_HOME="$work/config" TMPDIR="$work/tmp"
mkdir -p "$HOME/config" "$SIGN_OFF_HOME" "$TMPDIR"
ask() { python3 "$root/ask-default/bin/fm-captain-ask.py" "$@"; }
author() {
  ask add device-check "${ASK_QUESTION:-Can you test the new phone connection?}" '' --owner-must own-device-test \
    --about 'The phone connection is ready to try.' --why 'Your phone is needed before we release it.' \
    --already 'The automated connection checks passed.' --option 'Yes=We release after your connection test passes.' \
    --option 'No=The release waits for a phone test.' --recommend Yes --reason 'The automated checks passed.' --default No "$@"
}
refused() { if "$@" >"$work/refusal" 2>&1; then echo "unexpected acceptance: $*"; exit 1; fi; }
refused ask post missing card "done"
author --default No
before=$(ask list)
for bad in '[captain-ask] Can you test it?' 'Main42: Can you test it?' 'Open data/proof.md?' 'Resume task-device-check?' 'Can the worker continue?'; do
  ASK_QUESTION="$bad" refused author
done
for field in about why already reason; do refused author "--$field" 'Open data/proof.md'; done
refused author --owner-must scheduling
refused author --already ''
refused author --option 'Later=The release waits for a phone test.'
[ "$(ask list)" = "$before" ] || { echo 'refused asks changed the list'; exit 1; }
python3 - "$FM_HOME/data/captain-ask-cards/device-check.json" <<'PYCODE'
import json, sys
p = sys.argv[1]
card = json.load(open(p))
card['owner_must'] = 'scheduling'
open(p, 'w').write(json.dumps(card))
PYCODE
refused ask post device-check tampered release
author --default No
ask post device-check owner-test release
sign-off-axi list --json > "$work/board.json"
python3 - "$work/board.json" <<'PY'
import json, sys
card = json.load(open(sys.argv[1]))['decisions'][0]
assert card['title'] == 'Can you test the new phone connection?'
assert card['ask_ref'] == 'device-check' and card['close'] == 'release'
assert len(card['about'].splitlines()) == 3 and len(card['why'].splitlines()) == 3
assert len({o['outcome'] for o in card['options']}) == 2
print('PASS: real board has the authored owner question, three context lines and distinct outcomes')
PY
ask install "$HOME"
FM_HOME="$HOME" "$HOME/config/fm-captain-ask.sh" list > "$work/installed-list"
[ "$(cat "$work/installed-list")" = "$before" ]
ask "done" device-check
[ -z "$(ask list)" ]
refused ask post device-check after-removal release
printf 'PASS: owner-only refusal, invalid text, distinct choices, install, list and done\n'
