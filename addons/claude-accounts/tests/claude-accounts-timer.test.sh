#!/usr/bin/env bash
# claude-accounts timer: install, dry run, no-op rerun and uninstall against a throwaway HOME, XDG paths and a
# stub systemctl that only logs its calls. The installed reader copy then runs from the unit's own command line.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
w=$(mktemp -d "${TMPDIR:-/tmp}/claude-accounts-timer-test.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
mkdir -p "$w/home/state" "$w/fm" "$w/bin" "$w/a1"
printf '#!/bin/sh\necho "$*" >> "%s/systemctl.log"\n' "$w" > "$w/bin/systemctl"
printf '#!/bin/sh\necho "{\\"providers\\":[{\\"windows\\":[{\\"id\\":\\"five_hour\\",\\"percentRemaining\\":50},{\\"id\\":\\"seven_day\\",\\"percentRemaining\\":60}]}]}"\n' > "$w/bin/quota-axi"
chmod +x "$w/bin/systemctl" "$w/bin/quota-axi"
printf '{"accounts":[{"id":"a","provider":"claude","name":"A","folder":"%s"}]}\n' "$w/a1" > "$w/registry.json"
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }
t() { env -i PATH="$w/bin:$PATH" HOME="$w/home" XDG_DATA_HOME="$w/data" XDG_CONFIG_HOME="$w/cfg" TMPDIR="$w" "$@" 2>&1; }
units=$w/cfg/systemd/user

t "$here/../install-timer.sh" --dry-run "$w/fm" >/dev/null
is "dry run writes nothing" "$(find "$w/data" "$w/cfg" 2>/dev/null | wc -l)" 0
t "$here/../install-timer.sh" "$w/fm" >/dev/null
is "units and the reader copy are written" "$(ls "$units"; ls "$w/data/fm-claude-accounts")" "fm-claude-accounts-quota.service
fm-claude-accounts-quota.timer
claude-accounts-quota.sh"
is "every 5 minutes, for this home" "$(grep -c 'OnUnitActiveSec=5min' "$units/fm-claude-accounts-quota.timer")|$(grep -c "Environment=FM_HOME=$w/fm" "$units/fm-claude-accounts-quota.service")" "1|1"
is "the timer is enabled now" "$(tail -1 "$w/systemctl.log")" "--user enable --now fm-claude-accounts-quota.timer"
is "the unit's command writes the card file" "$(env -i PATH="$w/bin:$PATH" HOME="$w/home" FM_HOME="$w/home" FM_CLAUDE_ACCOUNTS_REGISTRY="$w/registry.json" "$w/data/fm-claude-accounts/claude-accounts-quota.sh" >/dev/null 2>&1; jq -r '.accounts[0] | "\(.five_hour.left)/\(.seven_day.left)"' "$w/home/state/claude-accounts.json")" "50/60"
: > "$w/systemctl.log"
is "a rerun changes nothing" "$(t "$here/../install-timer.sh" "$w/fm")|$(wc -c < "$w/systemctl.log")" "unchanged: fm-claude-accounts-quota.timer|0"
t "$here/../uninstall-timer.sh" >/dev/null
is "uninstall removes units and copy" "$(find "$units" "$w/data" -type f | wc -l)" 0

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
