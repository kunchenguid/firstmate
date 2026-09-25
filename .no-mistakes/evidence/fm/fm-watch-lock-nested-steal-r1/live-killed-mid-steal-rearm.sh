#!/usr/bin/env bash
# Live adversarial: KILL the watcher child itself while it holds the steal
# mutex (a dead steal owner, as in the overload), then re-arm the same lab home
# while tracing every lock link the watcher creates.
# Usage: live-killed-mid-steal-rearm.sh <repo-root>
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
case "$last" in *.lock*) echo "ln -> ${last##*/}" >> "$FM_HOME/ln-trace";; esac
case "$last" in *.watch.lock.steal) if [ -e "$FM_HOME/stall" ]; then echo "$PPID" > "$FM_HOME/in-steal"; sleep 5; fi;; esac
exec /bin/ln "$@"
SH
chmod +x "$LAB/shim/ln"
sleep 0 & dead=$!; wait $dead
mkdir "$S/.watch.lock"; echo "$dead" > "$S/.watch.lock/pid"
touch "$LAB/stall"
PATH="$LAB/shim:$PATH" FM_ARM_CONFIRM_TIMEOUT=3 "$ROOT/bin/fm-watch-arm.sh" > "$LAB/arm1.out" 2>&1 &
arm=$!
for i in $(seq 200); do [ -s "$LAB/in-steal" ] && break; sleep 0.02; done
sleep 5.2   # the stalled ln has now published .watch.lock.steal for the child
child=$(pgrep -P $arm -f fm-watch.sh | head -1)
echo "== SIGKILL watcher child ${child:-?} while it holds .watch.lock.steal"
[ -n "$child" ] && kill -KILL "$child"
wait $arm 2>/dev/null; echo "arm1 exit=$?"; sed "s#$LAB#\$LAB#g" "$LAB/arm1.out"
rm -f "$LAB/stall"
echo "== residue left by killed child"
for f in .watch.lock .watch.lock.steal .watch.lock.steal.steal; do
  p=$(cat "$S/$f/pid" 2>/dev/null); { [ -e "$S/$f" ] || [ -L "$S/$f" ]; } && echo "$f pid=${p:-none} alive=$(kill -0 "${p:-0}" 2>/dev/null && echo yes || echo no)"
done
: > "$LAB/ln-trace"
echo "== re-arm same home with ln trace"
PATH="$LAB/shim:$PATH" FM_ARM_CONFIRM_TIMEOUT=8 "$ROOT/bin/fm-watch-arm.sh" > "$LAB/arm2.out" 2>&1 &
arm2=$!
for i in $(seq 150); do grep -q '^watcher:' "$LAB/arm2.out" && break; kill -0 $arm2 2>/dev/null || break; sleep 0.1; done
sleep 1; sed "s#$LAB#\$LAB#g" "$LAB/arm2.out"
echo "-- lock links created during re-arm:"; sort "$LAB/ln-trace" | uniq -c
grep -q 'steal\.steal' "$LAB/ln-trace" && echo "NESTED .steal.steal CREATED" || echo "no nested .steal.steal created"
echo "-- residue after re-arm:"; ls "$S" | grep -E 'watch\.lock' || echo "(none)"
kill -TERM $arm2 2>/dev/null; wait $arm2 2>/dev/null
w=$(cat "$S/.watch.lock/pid" 2>/dev/null); [ -n "$w" ] && kill -0 "$w" 2>/dev/null && { kill -TERM "$w"; sleep 1; }
rm -rf "$LAB"
