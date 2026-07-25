#!/usr/bin/env bash
# Phase 2 self-test suite (local, non-destructive).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export FM_HOME="${FM_HOME_TEST:-$(mktemp -d /tmp/fm-phase2-test.XXXXXX)}"
cleanup() { rm -rf "$FM_HOME"; }
trap cleanup EXIT

mkdir -p "$FM_HOME"/{bin,state,data,docs,phase2,scripts}
cp -a "$ROOT/phase2/." "$FM_HOME/phase2/"
cp -a "$ROOT/bin/fm-phase2-"*.sh "$FM_HOME/bin/"
cp -a "$ROOT/scripts/firstmate-"*.sh "$ROOT/scripts/rollback-firstmate-phase2.sh" "$FM_HOME/scripts/" 2>/dev/null || true
cp -a "$ROOT/scripts/firstmate-resume.sh" "$ROOT/scripts/firstmate-ledger-update.sh" "$FM_HOME/scripts/"
chmod +x "$FM_HOME"/bin/*.sh "$FM_HOME"/scripts/*.sh
# Fix registry path references — scripts already use FM_HOME

pass=0; fail=0
check() {
  local name="$1"; shift
  if "$@"; then echo "PASS $name"; pass=$((pass+1)); else echo "FAIL $name"; fail=$((fail+1)); fi
}

REG="$FM_HOME/bin/fm-phase2-registry.sh"

check "01-init" "$REG" init
check "02-programme" "$REG" create-programme p1 "Test programme" --phase t
"$REG" add-task t1 p1 "Task one" --priority 10 --own 'a/**' >/dev/null
"$REG" add-task t2 p1 "Task two" --priority 20 --dep t1 --own 'b/**' >/dev/null
check "03-deps-not-ready" python3 -c "import json,subprocess,sys; r=json.loads(subprocess.check_output(['$REG','ready','--programme','p1'])); assert not any(x['id']=='t2' for x in r), r"
"$REG" transition t1 ready --reason test >/dev/null
"$REG" transition t1 assigned --reason test >/dev/null
"$REG" transition t1 implementing --reason test >/dev/null
"$REG" transition t1 awaiting_tests --reason test >/dev/null
"$REG" transition t1 awaiting_review --reason test >/dev/null
"$REG" transition t1 awaiting_ci --reason test >/dev/null
"$REG" transition t1 approved --reason test >/dev/null
"$REG" transition t1 merged --reason test >/dev/null
check "04-ready-after-dep" python3 -c "import json,subprocess; r=json.loads(subprocess.check_output(['$REG','ready','--programme','p1'])); assert any(x['id']=='t2' for x in r), r"

# concurrency / ownership via schedule dry-run
"$REG" transition t2 ready --reason test >/dev/null
"$FM_HOME/bin/fm-phase2-packet.sh" t2 --title "t2" >/dev/null
OUT=$("$FM_HOME/bin/fm-phase2-schedule.sh" --programme p1 --dry-run)
check "05-schedule-selects" python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert any(x['id']=='t2' for x in d['selected']), d" "$OUT"

# conflict: add overlapping active
"$REG" add-task t3 p1 "overlap" --priority 5 --own 'b/foo.ts' >/dev/null
"$REG" transition t3 ready --reason x >/dev/null
"$REG" transition t3 assigned --reason x >/dev/null
"$REG" transition t3 implementing --reason x >/dev/null
OUT2=$("$FM_HOME/bin/fm-phase2-schedule.sh" --programme p1 --dry-run)
check "06-file-conflict" python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert not any(x['id']=='t2' for x in d['selected']), d" "$OUT2"

check "07-heartbeat" "$REG" heartbeat t3
check "08-event-idempotent" bash -c "$FM_HOME/bin/fm-phase2-event.sh heartbeat --task t3 --dedupe samekey >/dev/null && $FM_HOME/bin/fm-phase2-event.sh heartbeat --task t3 --dedupe samekey | grep -q duplicate"
check "09-packet" test -f "$FM_HOME/data/t2/packet/TASK.md"
check "10-ledger" "$FM_HOME/scripts/firstmate-ledger-update.sh"
check "11-resume" "$FM_HOME/scripts/firstmate-resume.sh"
check "12-illegal-transition" bash -c "! $REG transition t1 ready --reason no 2>/dev/null"

# stale recovery path (no real worker)
"$REG" add-task t4 p1 "stale" --priority 1 >/dev/null
"$REG" transition t4 ready >/dev/null
"$REG" transition t4 assigned >/dev/null
"$REG" transition t4 implementing >/dev/null
# old heartbeat
python3 -c "import sqlite3,time; c=sqlite3.connect('$FM_HOME/state/programme.db'); c.execute('update tasks set heartbeat_at=? where id=\"t4\"', (time.time()-9999,)); c.commit()"
check "13-stale-detect" python3 -c "import json,subprocess; s=json.loads(subprocess.check_output(['$REG','stale','--grace','60'])); assert any(x['id']=='t4' for x in s), s"

# review check
mkdir -p "$FM_HOME/data/t5/packet"
"$REG" add-task t5 p1 "review" >/dev/null
"$REG" transition t5 ready >/dev/null
"$REG" transition t5 assigned >/dev/null
"$REG" transition t5 implementing >/dev/null
"$REG" transition t5 awaiting_tests >/dev/null
"$FM_HOME/bin/fm-phase2-review.sh" init t5 >/dev/null
# mark all PASS
python3 - <<PY
from pathlib import Path
p=Path("$FM_HOME/data/t5/packet/REVIEW.md")
t=p.read_text().replace("NOT TESTED","PASS")
p.write_text(t)
PY
check "14-review-pass" "$FM_HOME/bin/fm-phase2-review.sh" check t5

# secret redaction: ensure .env not in packet scaffold
check "15-no-env-in-packet" bash -c "! grep -R \"^SECRET=\" $FM_HOME/data/t2/packet"

# rollback script exists and help works
check "16-rollback-help" "$FM_HOME/scripts/rollback-firstmate-phase2.sh" --help

echo "RESULT pass=$pass fail=$fail home=$FM_HOME"
[ "$fail" -eq 0 ]
