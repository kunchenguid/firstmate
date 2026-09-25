#!/usr/bin/env bash
# Live: arm a real watcher in a lab home whose .watch.lock has a dead owner,
# and TERM the arm while its child is inside the stale-lock steal (an `ln`
# shim on PATH stalls 0.5s when creating .watch.lock.steal, simulating fork
# latency under overload; no load generator). Then re-arm the same home to
# prove it is not left down. Usage: live-arm-term-mid-steal.sh <repo-root>
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null; S="$LAB/state"
unset NO_MISTAKES_GATE FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1
mkdir -p "$LAB/shim"
cat > "$LAB/shim/ln" <<'SH'
#!/usr/bin/env bash
for a do last=$a; done
case "$last" in *.watch.lock.steal) echo "$(date +%T) child $PPID creating .watch.lock.steal (stalled)" >> "$FM_HOME/steal-events"; touch "$FM_HOME/in-steal"; sleep 0.5;; esac
exec /bin/ln "$@"
SH
chmod +x "$LAB/shim/ln"
sleep 0 & dead=$!; wait $dead
mkdir "$S/.watch.lock"; echo "$dead" > "$S/.watch.lock/pid"
echo "== primary .watch.lock owned by dead pid $dead"
PATH="$LAB/shim:$PATH" FM_ARM_CONFIRM_TIMEOUT=8 "$ROOT/bin/fm-watch-arm.sh" > "$LAB/arm1.out" 2>&1 &
arm=$!
for i in $(seq 200); do [ -e "$LAB/in-steal" ] && break; sleep 0.02; done
echo "== child is mid-steal; sending TERM to arm $arm"; kill -TERM $arm
t0=$(date +%s); wait $arm; rc=$?; echo "arm exit=$rc after $(( $(date +%s)-t0 ))s"
cat "$LAB/steal-events"; echo "-- arm1 output:"; sed "s#$LAB#\$LAB#g" "$LAB/arm1.out"
sleep 0.5
echo "== residue after interrupted arm"
ls -la "$S" | grep -E 'watch\.lock' | sed "s#$LAB#\$LAB#g" || echo "(no watch.lock files)"
for f in .watch.lock .watch.lock.steal .watch.lock.steal.steal; do
  p=$(cat "$S/$f/pid" 2>/dev/null); [ -e "$S/$f" ] || [ -L "$S/$f" ] && echo "$f present pid=${p:-none} alive=$(kill -0 "${p:-0}" 2>/dev/null && echo yes || echo no)"
done
echo "== re-arm same home (no shim)"
FM_ARM_CONFIRM_TIMEOUT=8 "$ROOT/bin/fm-watch-arm.sh" > "$LAB/arm2.out" 2>&1 &
arm2=$!
for i in $(seq 150); do grep -q '^watcher:' "$LAB/arm2.out" && break; kill -0 $arm2 2>/dev/null || break; sleep 0.1; done
sleep 1; sed "s#$LAB#\$LAB#g" "$LAB/arm2.out"
echo "nested .steal.steal ever present: $([ -e "$S/.watch.lock.steal.steal" ] || [ -L "$S/.watch.lock.steal.steal" ] && echo YES || echo no)"
kill -TERM $arm2 2>/dev/null; wait $arm2 2>/dev/null; echo "arm2 exit=$?"
w=$(cat "$S/.watch.lock/pid" 2>/dev/null); [ -n "$w" ] && kill -0 "$w" 2>/dev/null && { echo "stopping leftover watcher $w"; kill -TERM "$w"; sleep 1; }
rm -rf "$LAB"
