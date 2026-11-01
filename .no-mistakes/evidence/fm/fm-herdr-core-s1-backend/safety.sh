#!/usr/bin/env bash
set -eu
export FM_HC_BIN="$PWD/.live-hc/bin/herdr-core"
export FM_HC_LAB_DIR="$PWD/.live-hc/labs" FM_HC_LAB_SOCK_DIR=.s
export XDG_STATE_HOME="$PWD/.live-hc/operator-state" XDG_CONFIG_HOME="$PWD/.live-hc/operator-config" XDG_DATA_HOME="$PWD/.live-hc/operator-data"
lab=bin/fm-hc-lab.sh
active=''
cleanup() {
 rc=$?; trap - EXIT
 for s in $active; do
  if [ -d "$FM_HC_LAB_DIR/$s" ]; then "$lab" teardown "$s" || rc=1; fi
 done
 exit "$rc"
}
trap cleanup EXIT
refuse() {
 printf '\nAttempting guarded command: %s\n' "$*"
 if "$@"; then echo 'UNEXPECTED SUCCESS'; exit 1; fi
}
refuse "$lab" provision default
refuse "$lab" teardown default
# Two pre-existing sessions prove multi-directory snapshot inventory behavior.
for s in fm-hclab-a fm-hclab-b; do
 active="$active $s"
 "$lab" provision "$s"
done
bin/fm-hc-ci-cleanup.sh snapshot "$PWD/.live-hc/baseline"
printf 'Owned baseline inventory:\n'; cat .live-hc/baseline
[ "$(wc -l < .live-hc/baseline | tr -d ' ')" = 2 ]
s=fm-hclab-c
active="$active $s"
"$lab" provision "$s"
refuse "$lab" provision "$s"
refuse "$lab" run "$s" --json server stop
refuse "$lab" run "$s" server stop
refuse "$lab" run "$s" connect
refuse "$lab" run "$s" ls --session default
refuse "$lab" run "$s" ls --socket other.sock
printf 'Actual isolated server after refused escape attempts:\n'
"$lab" run "$s" ls --json
printf 'Simulated external-state change detected by metadata tripwire:\n'
touch "$XDG_STATE_HOME/herdr-core/unexpected"
refuse "$lab" teardown "$s"
[ -d "$FM_HC_LAB_DIR/$s" ]
rm "$XDG_STATE_HOME/herdr-core/unexpected"
"$lab" teardown "$s"
printf 'Restored fixture tripwire permits cleanup\n'
# Job-end cleaner removes ONLY a new real lab, leaving both baseline sessions.
"$lab" provision "$s"
"$lab" run "$s" run --bg --json -- /bin/sleep 300
bin/fm-hc-ci-cleanup.sh teardown "$PWD/.live-hc/baseline"
[ ! -e "$FM_HC_LAB_DIR/$s" ]
for s in fm-hclab-a fm-hclab-b; do
 [ -d "$FM_HC_LAB_DIR/$s" ]
 printf 'Preserved baseline session %s: ' "$s"
 "$lab" run "$s" ls --json
done
printf 'Job-owned new lab removed; baseline labs preserved; guarded teardown follows\n'
