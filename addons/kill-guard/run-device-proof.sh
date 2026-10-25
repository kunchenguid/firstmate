#!/usr/bin/env bash
# Live proof on a real Android device: this checkout's kill guard, copied to a temporary path, records a device process
# with own start, allows the task's own kill and refuses device PID 1 and a name kill; the kill runs only once allowed.
# Only the sleep this proof starts is signalled. Needs FM_DEVICE_SERIAL; FM_DEVICE_LOCK (a lock command taking
# <serial> <command...>, such as fm-device-lock.sh) holds the device for the whole journey.
set -euo pipefail
S=${FM_DEVICE_SERIAL:?set FM_DEVICE_SERIAL to the test device}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}/kill-guard-device; T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$OUT" "$T/repo"; git -C "$T/repo" init -q; cp "$ROOT/kill-guard/guard.mjs" "$T/guard.mjs"
cat > "$T/journey.sh" <<'EOF'
set -u; cd "$1"; G=$2; S=$3
verdict() { jq -n --arg c "$1" '{tool_input:{command:$c}}' | node "$G" --caller $$ 2>&1; }
echo "\$ own start $S -- sleep 120"; start=$(date +%s); node "$G" own start "$S" -- sleep 120 || exit 4; echo "returned in $(( $(date +%s) - start ))s"
P=$(jq -r '.[-1].pid' .fm-kill-guard-device-pids.json); echo "recorded device pid $P"
echo "\$ ps -p $P"; adb -s "$S" shell ps -o PID,NAME -p "$P" || exit 5
echo "--- guard on: adb shell kill $P"; verdict "adb -s $S shell kill $P" && echo "allowed" || exit 6
echo "--- guard on: adb shell kill 1"; ! verdict "adb -s $S shell kill 1" || exit 7
echo "--- guard on: adb shell pkill sleep"; ! verdict "adb -s $S shell pkill sleep" || exit 8
echo "\$ adb shell kill $P"; adb -s "$S" shell kill "$P"; sleep 1
echo "\$ ps -p $P"; ! adb -s "$S" shell ps -o PID,NAME -p "$P" && echo "gone"
EOF
lock=(); [ -z "${FM_DEVICE_LOCK:-}" ] || lock=("$FM_DEVICE_LOCK" "$S")
rc=0; "${lock[@]}" bash "$T/journey.sh" "$T/repo" "$T/guard.mjs" "$S" > "$OUT/journey.txt" 2>&1 || rc=$?
sed "s/$S/<serial>/g" "$OUT/journey.txt" > "$OUT/journey.tmp" && mv "$OUT/journey.tmp" "$OUT/journey.txt"
cat "$OUT/journey.txt"
jq -n --arg r "$(tail -n 1 "$OUT/journey.txt")" '{target: {version: "kill-guard/guard.mjs from this checkout on a real Android phone"}, start: "a fresh git worktree root with no device record",
  steps: ["record a device sleep with own start", "ask the guard about killing it, device PID 1 and pkill sleep", "kill the recorded process", "list it on the device"], result: $r}' > "$DONE_DONE_EVIDENCE_ROOT/steps.json"
[ "$rc" -eq 0 ] && [ "$(tail -n 1 "$OUT/journey.txt")" = gone ]
