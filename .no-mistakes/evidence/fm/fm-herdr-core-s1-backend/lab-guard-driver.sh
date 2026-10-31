#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
export FM_HC_BIN="$ROOT/.live-hc/bin/herdr-core"
export FM_HC_LAB_DIR="$ROOT/.live-hc/labs" FM_HC_LAB_SOCK_DIR=.s
LAB="$ROOT/bin/fm-hc-lab.sh"
CI="$ROOT/bin/fm-hc-ci-cleanup.sh"
. "$ROOT/tests/hc-test-safety.sh"
# Real Core runs privately; the tripwire's putative fleet is synthetic file metadata.
export XDG_STATE_HOME="$ROOT/.live-hc/synthetic-fleet"
mkdir -p "$XDG_STATE_HOME/herdr-core"
SENTINEL="$XDG_STATE_HOME/herdr-core/owned-sentinel"
printf 'untouched\n' > "$SENTINEL"
python3 - "$SENTINEL" "$ROOT/.live-hc/sentinel-meta.json" <<'PY'
import os,json,sys
s=os.stat(sys.argv[1]); json.dump([s.st_atime_ns,s.st_mtime_ns],open(sys.argv[2],'w'))
PY
restore() {
 python3 - "$SENTINEL" "$ROOT/.live-hc/sentinel-meta.json" <<'PY'
import os,json,sys
open(sys.argv[1],'w').write('untouched\n'); os.utime(sys.argv[1],ns=tuple(json.load(open(sys.argv[2]))))
PY
}
cleanup() {
 rc=$?; trap - EXIT
 restore
 for name in fm-hclab-a fm-hclab-a2 fm-hclab-b fm-hclab-trip; do
  if [ -f "$FM_HC_LAB_DIR/$name/fleet-state.txt" ]; then hc_test_safe_teardown "$ROOT" "$name" || rc=1; fi
 done
 echo "lab guard cleanup exit=$rc"; exit "$rc"
}
trap cleanup EXIT
reject() { if "$@"; then echo "ERROR accepted forbidden request: $*"; exit 1; fi; }
reject "$LAB" provision default
reject "$LAB" teardown default
reject "$LAB" provision not-a-lab
"$LAB" provision fm-hclab-a
"$LAB" provision fm-hclab-a2
for name in fm-hclab-a fm-hclab-a2; do
 "$LAB" run "$name" run --bg --json --no-parent --outlive-parent --no-notify -- /bin/sleep 600
 done
reject "$LAB" provision fm-hclab-a
reject "$LAB" run fm-hclab-a --json server stop
reject "$LAB" run fm-hclab-a server stop
reject "$LAB" run fm-hclab-a connect
reject "$LAB" run fm-hclab-a ls --socket=/not-owned.sock
reject "$LAB" run fm-hclab-a ls --session default
hc_test_safe_teardown "$ROOT" fm-hclab-a
[ ! -d "$FM_HC_LAB_DIR/fm-hclab-a" ]
survivor=$("$LAB" run fm-hclab-a2 get --json t1)
printf 'prefix sibling after first teardown: %s\n' "$survivor"
[ "$(printf '%s' "$survivor" | jq -r '.state')" = live ]
kill -0 "$(printf '%s' "$survivor" | jq -r '.pid')"
echo 'exact-session teardown left the longer-prefix Core and its sleep process alive'
"$CI" snapshot "$ROOT/.live-hc/before.txt"
"$LAB" provision fm-hclab-a
"$LAB" provision fm-hclab-b
for name in fm-hclab-a fm-hclab-b; do
 "$LAB" run "$name" run --bg --json --no-parent --outlive-parent --no-notify -- /bin/sleep 600
 done
"$CI" teardown "$ROOT/.live-hc/before.txt"
[ ! -d "$FM_HC_LAB_DIR/fm-hclab-a" ] && [ ! -d "$FM_HC_LAB_DIR/fm-hclab-b" ]
survivor=$("$LAB" run fm-hclab-a2 get --json t1)
printf 'snapshot-owned sibling after CI cleanup: %s\n' "$survivor"
[ "$(printf '%s' "$survivor" | jq -r '.state')" = live ]
kill -0 "$(printf '%s' "$survivor" | jq -r '.pid')"
echo 'CI cleanup removed both post-snapshot sessions, preserved snapshot session'
hc_test_safe_teardown "$ROOT" fm-hclab-a2
"$LAB" provision fm-hclab-trip
printf 'changed\n' > "$SENTINEL"
reject hc_test_safe_teardown "$ROOT" fm-hclab-trip
[ -f "$FM_HC_LAB_DIR/fm-hclab-trip/fleet-state.txt" ]
echo 'safety wrapper propagated changed-fleet tripwire failure and retained the lab record'
restore
hc_test_safe_teardown "$ROOT" fm-hclab-trip
[ ! -d "$FM_HC_LAB_DIR/fm-hclab-trip" ]
echo 'restored synthetic fleet; verified teardown succeeds and all lab records removed'
