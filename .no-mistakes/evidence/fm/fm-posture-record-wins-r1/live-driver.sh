#!/usr/bin/env bash
set -euo pipefail
E=~/.no-mistakes/evidence/01M74324NZB2424QRPXX5NARY5
exec > >(tee "$E/live-posture.txt") 2>&1
trap 'rc=$?; echo "DRIVER_EXIT=$rc"; printf "%s\n" "$rc" > "$E/driver-exit.txt"' EXIT
unset FM_TEST_SEAM FM_TEST_HARNESS FM_GATE_REFUSE_BYPASS
: "${FM_HOME:?}"
ROOT=$PWD
export FM_BACKEND=tmux
C="$ROOT/bin/fm-afk-contract.sh"
L="$ROOT/bin/fm-afk-launch.sh"
I="$ROOT/bin/fm-inbox.sh"
echo "Real primary harness: $(bin/fm-harness.sh)"
[ "$(bin/fm-harness.sh)" = claude ]
flag() { bash -c '. "$1/bin/fm-afk-start.sh"; fm_afk_flag_write "$FM_HOME/state" "$2"' _ "$ROOT" "${1:-}"; }
ready() { "$I" ready | jq '{posture:.posture}'; }
echo 'SCENARIO 1: real readiness CLI, synthetic record/flag matrix (oracle: record wins; flag only without record)'
for record in none away quiet; do
 for f in none away quiet; do
  rm -f "$FM_HOME/state/.afk" "$FM_HOME/state/.afk-contract"
  if [ "$record" != none ]; then FM_AFK_MODE="$record" "$C" enter --words "synthetic matrix posture" >/dev/null; fi
  if [ "$f" != none ]; then flag "$f"; fi
  actual=$("$I" ready)
  want=$record
  if [ "$record" = none ]; then want=$f; [ "$f" != none ] || want=present; fi
  echo "record=$record flag=$f expected=$want actual=$(printf '%s' "$actual" | jq -c '.posture')"
  [ "$(printf '%s' "$actual" | jq -r '.posture.state')" = "$want" ]
 done
done
echo 'SCENARIO 2: unspecified flag refresh repairs contradiction using the standing record'
for record in quiet away; do
 FM_AFK_MODE="$record" "$C" enter --words 'refresh posture' >/dev/null
 if [ "$record" = quiet ]; then flag away; else flag quiet; fi
 flag
 echo "record=$record refreshed flag=$(head -1 "$FM_HOME/state/.afk")"; ready
 [ "$(head -1 "$FM_HOME/state/.afk")" = "$record" ]
done
"$L" stop

echo 'SCENARIO 3: real quiet daemon on supervision-host home; rejected entries must not disturb it'
"$L" quiet-check || [ "$?" = 1 ]
FM_AFK_MODE=quiet "$L" enter --words 'quiet lab captain'
"$L" start
pid=''
for n in {1..40}; do
 pid=$(cat "$FM_HOME/state/.supervise-daemon.lock/pid" 2>/dev/null || true)
 if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then break; fi
 sleep .25
done
[ -n "$pid" ]; kill -0 "$pid"
echo "Running daemon:"; ps -p "$pid" -o pid=,command=
cp "$FM_HOME/state/.afk-contract" "$FM_HOME/quiet-record-before"
cp "$FM_HOME/state/.afk-daemon-terminal" "$FM_HOME/terminal-before"
for refusal in missing-words invalid-return; do
 if [ "$refusal" = missing-words ]; then args=(--words-file "$FM_HOME/no-such-file"); else args=(--expected-return yesterday); fi
 set +e
 "$L" enter "${args[@]}"
 rc=$?
 set -e
 echo "$refusal exit=$rc"
 [ "$rc" != 0 ]; kill -0 "$pid"
 cmp "$FM_HOME/quiet-record-before" "$FM_HOME/state/.afk-contract"
 cmp "$FM_HOME/terminal-before" "$FM_HOME/state/.afk-daemon-terminal"
 [ "$(head -1 "$FM_HOME/state/.afk")" = quiet ]; ready
 echo 'Quiet daemon and serialized posture/terminal records unchanged'
done

echo 'SCENARIO 4: published away entry stops real quiet daemon, closes exact tmux session, clears flag, keeps away record'
daemon_session=$(awk -F= '$1=="id" {print $2}' "$FM_HOME/state/.afk-daemon-terminal")
echo "Terminal record before transition:"; cat "$FM_HOME/state/.afk-daemon-terminal"
"$L" enter --words 'merge anything green'
[ "$("$C" mode)" = away ]
[ ! -e "$FM_HOME/state/.afk" ]; [ ! -e "$FM_HOME/state/.afk-daemon-terminal" ]
! kill -0 "$pid" 2>/dev/null
ready
if [ -n "$daemon_session" ]; then ! tmux has-session -t "$daemon_session" 2>/dev/null; fi
echo "daemon pid=$pid terminated; flag and terminal record absent; away record stands"
set +e
"$L" start
rc=$?
set -e
[ "$rc" != 0 ]; echo "Away daemon restart refused: exit=$rc"
"$L" stop
ready
[ "$("$I" ready | jq -r '.posture.state')" = present ]

echo 'SCENARIO 5: supervision-host opt-out preserves daemon across away entry'
touch "$FM_HOME/config/supervision-host-off"
FM_AFK_MODE=quiet "$L" enter --words 'quiet opt-out captain'
"$L" start
pid=''
for n in {1..40}; do
 pid=$(cat "$FM_HOME/state/.supervise-daemon.lock/pid" 2>/dev/null || true)
 if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then break; fi
 sleep .25
done
[ -n "$pid" ]; kill -0 "$pid"
"$L" enter --words 'away without supervision host'
kill -0 "$pid"; [ -e "$FM_HOME/state/.afk-daemon-terminal" ]; [ -e "$FM_HOME/state/.afk" ]
echo "opted-out real daemon pid=$pid survives away entry; readiness follows record despite quiet flag"
ready
[ "$("$I" ready | jq -r '.posture.state')" = away ]
"$L" stop
! kill -0 "$pid" 2>/dev/null
ready
echo 'ALL FIVE LIVE SCENARIOS COMPLETED'
