#!/usr/bin/env bash
# Exact observed stops, duration parsing, and conservative negative cases.
set -eu
. "$(dirname "$0")/lib.sh"
. "$ROOT/bin/fm-pane-stop-lib.sh"
[ "$(fm_pane_stop grok 'You hit your weekly limit')" = $'quota-exhausted\tgrok\t-\tunknown' ] || fail 'weekly stop'
[ "$(fm_pane_stop pi 'Error: Quota reached. Please wait 2h29m27s')" = $'quota-exhausted\tgemini\t8967\t2h29m27s' ] || fail 'Gemini reset'
[ "$(fm_pane_stop pi-signed $'\033[31mError: Quota reached. Please wait 09m05s\033[0m')" = $'quota-exhausted\tgemini\t545\t09m05s' ] || fail 'ANSI and leading zero'
[ "$(fm_pane_stop pi 'Error: Quota reached. Please wait 1s')" = $'quota-exhausted\tgemini\t1\t1s' ] || fail 'seconds reset'
for pane in 'idle prompt' 'You hit your weekly limit yesterday' '"You hit your weekly limit"' 'Example: You hit your weekly limit' 'Error: Quota reached. Please wait ' 'Error: Quota reached. Please wait 99m' 'Error: Quota reached. Please wait tomorrow'; do
  ! fm_pane_stop grok "$pane" || fail "false positive: $pane"
  ! fm_pane_stop pi "$pane" || fail "false positive: $pane"
done
! fm_pane_stop claude 'You hit your weekly limit' || fail 'wrong harness'
! fm_pane_stop grok 'Error: Quota reached. Please wait 2h29m27s' || fail 'wrong provider'
old=$(printf 'You hit your weekly limit\n'; printf 'normal line\n%.0s' {1..13})
! fm_pane_stop grok "$old" || fail 'old scrollback'
while IFS='|' read -r harness text label; do
  [ "$(fm_pane_stop "$harness" "$text"$'\nDo not trust')" = "$(printf 'blocked-at-prompt\t%s\t-\t%s' "$harness" "$label")" ] || fail "missed $harness dialog"
  ! fm_pane_stop "$harness" "$text" || fail 'lone heading matched'
  ! fm_pane_stop "$harness" "Example: $text"$'\nDo not trust' || fail 'quoted dialog matched'
done <<'DIALOGS'
pi|Trust project folder?|trust
pi-signed|Trust project folder?|trust
DIALOGS
while IFS='|' read -r harness text label; do
  ! fm_pane_stop "$harness" "$text" || fail "unsupported $harness dialog matched"
done <<'DIALOGS'
gemini|Error: Quota reached. Please wait 1s|quota
claude|Quick safety check: Is this a project you created or one you trust?|trust
codex|Do you trust the contents of this directory?|trust
codex|Hooks need review - 2 hooks are new or changed|hook-review
agy|Do you trust the contents of this project?|trust
gemini|Do you trust the files in this folder?|trust
kimi|Trust this folder?|trust
muse|Do you trust this workspace?|trust
DIALOGS
pass 'observed quota stops and Pi trust dialogs match conservatively'
