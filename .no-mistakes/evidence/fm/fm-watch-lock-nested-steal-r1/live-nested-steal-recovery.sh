#!/usr/bin/env bash
# Live repro/verify: a lab home whose .watch.lock has a dead owner plus the
# dead .watch.lock.steal and nested .watch.lock.steal.steal chain from the
# 2026-09-25 overload. Arms a real watcher via bin/fm-watch-arm.sh.
# Usage: live-nested-steal-recovery.sh <repo-root>
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
rmdir "$LAB"; "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
S="$LAB/state"
export FM_HOME="$LAB"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
# dead owner of the primary lock
sleep 0 & dead=$!; wait $dead
mkdir "$S/.watch.lock"; echo "$dead" > "$S/.watch.lock/pid"
# dead holder of the steal mutex AND the nested steal-steal marker
bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_create "$2.steal" && fm_lock_try_create "$2.steal.steal"; exec sleep 30' _ "$ROOT" "$S/.watch.lock" &
h=$!; for i in $(seq 50); do [ -s "$S/.watch.lock.steal.steal/pid" ] && break; sleep 0.05; done
kill -KILL $h; wait $h 2>/dev/null
echo "== residue before arm (holder pid $h killed, primary owner pid $dead dead)"
ls -la "$S" | grep -E 'watch\.lock' | sed "s#$LAB#\$LAB#g"
echo "== running bin/fm-watch-arm.sh in the lab home (FM_GATE_REFUSE_BYPASS=1 only lifts the disposable-checkout refusal, as tests/lib.sh does)"
FM_GATE_REFUSE_BYPASS=1 FM_ARM_CONFIRM_TIMEOUT=8 "$ROOT/bin/fm-watch-arm.sh" > "$LAB/arm.out" 2>&1 &
arm=$!
for i in $(seq 120); do grep -q '^watcher:' "$LAB/arm.out" && break; kill -0 $arm 2>/dev/null || break; sleep 0.1; done
echo "== arm status line"; grep '^watcher:' "$LAB/arm.out" || { echo "(none)"; cat "$LAB/arm.out"; }
sleep 1
echo "== lock state after arm"
spid=$(grep -o "started pid=[0-9]*" "$LAB/arm.out" | cut -d= -f2)
echo "started watcher pid=$spid alive=$(kill -0 "$spid" 2>/dev/null && echo yes || echo no)"
ls -la "$S" | grep -E 'watch\.lock' | sed "s#$LAB#\$LAB#g"
wpid=$(cat "$S/.watch.lock/pid" 2>/dev/null)
echo "lock pid=$wpid alive=$(kill -0 "$wpid" 2>/dev/null && echo yes || echo no)"
echo "nested .steal.steal present: $([ -e "$S/.watch.lock.steal.steal" ] || [ -L "$S/.watch.lock.steal.steal" ] && echo YES || echo no)"
echo "steal present: $([ -e "$S/.watch.lock.steal" ] || [ -L "$S/.watch.lock.steal" ] && echo YES || echo no)"
echo "== full arm output so far"; sed "s#$LAB#\$LAB#g" "$LAB/arm.out"
echo "== teardown: TERM the arm"
kill -TERM $arm 2>/dev/null; for i in $(seq 100); do kill -0 $arm 2>/dev/null || break; sleep 0.1; done
wait $arm 2>/dev/null; echo "arm exit=$?"
[ -n "$wpid" ] && { kill -0 "$wpid" 2>/dev/null && { echo "watcher still alive, killing"; kill -TERM "$wpid"; sleep 1; } || echo "watcher $wpid exited"; }
ls -la "$S" | grep -E 'watch\.lock' | sed "s#$LAB#\$LAB#g" || echo "(no lock files left)"
rm -rf "$LAB"
