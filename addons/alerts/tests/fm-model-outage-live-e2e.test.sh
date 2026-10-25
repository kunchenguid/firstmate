#!/usr/bin/env bash
# Real hosted OpenCode failures, grouped automatic wake, and second-mate
# watcher continuity in a named Herdr lab. No user credentials or settings.
# FM_MODEL_OUTAGE_LIVE=1 bin/fm-test-run.sh tests/fm-model-outage-live-e2e.test.sh
# FM_MODEL_OUTAGE_EVIDENCE selects a retained private evidence directory.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_MODEL_OUTAGE_LIVE opencode herdr jq
mkdir -p "$ROOT/data"
E=${FM_MODEL_OUTAGE_EVIDENCE:-$(mktemp -d "$ROOT/data/model-outage-live.XXXXXX")}
mkdir -p "$E"
export FM_HERDR_LAB_STATE_DIR="$E/labstate"
(umask 077; mkdir -p "$FM_HERDR_LAB_STATE_DIR")
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name model-outage)
ORIGINAL_PATH=$PATH
export FM_HOME="$E/home" FM_ROOT_OVERRIDE="$E/home"
export FM_STATE_OVERRIDE="$FM_HOME/state" FM_CONFIG_OVERRIDE="$FM_HOME/config" FM_DATA_OVERRIDE="$FM_HOME/data"
unset STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK FM_TASK_INBOX
PANES=()
cleanup() {
  local rc=$? p pid cmd watcher arm
  trap - EXIT
  if [ "$rc" != 0 ]; then
    for p in "${PANES[@]}"; do
      echo "OpenCode proof failed at $p (version $VERSION)"
      PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" pane read "$p" --source visible || true
    done
  fi
  watcher=$(cat "$FM_HOME/state/.watch.lock/pid" 2>/dev/null) || watcher=
  arm=$(ps -o ppid= -p "$watcher" 2>/dev/null | tr -d ' ') || arm=
  rm -f "$FM_HOME/state/.lock"
  for pid in "$arm" "$watcher"; do
    [ -n "$pid" ] || continue
    cmd=$(ps -o args= -p "$pid" 2>/dev/null) || continue
    case "$cmd" in *"$FM_HOME/bin/fm-watch"*) kill -TERM "$pid" 2>/dev/null || true ;; esac
  done
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" || rc=1
  echo "lab cleanup: $rc"; exit "$rc"
}
trap cleanup EXIT
VERSION=$(opencode --version | tail -1)
"$LAB_HELPER" provision "$SESSION"
lab() { PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
mkdir -p "$E/bin" "$FM_HOME/state" "$FM_HOME/config" "$FM_HOME/data" "$FM_HOME/.opencode/plugins/lib"
cat > "$E/bin/herdr" <<EOF
#!/usr/bin/env bash
set -eu
args=("\$@")
n=\${#args[@]}
[ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$SESSION" ] || exit 97
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]:0:\$((n-2))}"
EOF
chmod +x "$E/bin/herdr"
export PATH="$E/bin:$ORIGINAL_PATH" FM_BACKEND_HERDR_BIN="$E/bin/herdr" FM_BACKEND_HERDR_CLIENT_SESSION="$SESSION"
cp -a "$ROOT/bin" "$FM_HOME/"
cp "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$FM_HOME/.opencode/plugins/"
cp "$ROOT/.opencode/plugins/lib/fm-operational-input.js" "$FM_HOME/.opencode/plugins/lib/"
printf '{"type":"module"}\n' > "$FM_HOME/.opencode/plugins/package.json"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'lead\n' > "$FM_HOME/.fm-secondmate-home"
printf '# Isolated verification agent\nNo real fleet work. Only after an actual WATCHER FIRED message: run bin/fm-wake-drain.sh | tee -a data/drain.txt, execute its printed WAKE_ACK_REQUIRED command, then cp state/.wake-queue.seq state/lead-handled. Never manually arm monitoring. Reply briefly.\n' > "$FM_HOME/AGENTS.md"
git -C "$FM_HOME" init -q
for id in lanea laneb; do
  project="$E/$id"
  mkdir -p "$project/.opencode/plugins"
  git -C "$project" init -q
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$FM_HOME/state" "$id")
  printf '%s\n' "$gen" > "$E/$id.gen"
  cat > "$project/.opencode/plugins/busy.js" <<EOF
import { execFileSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';
export const Busy = async () => ({event: async ({event}) => {
  if (/session\\.(error|idle|status)/.test(event.type)) appendFileSync('$E/$id.events.jsonl', JSON.stringify(event)+'\\n');
  if(event.type === 'session.status') execFileSync('$ROOT/bin/fm-busy-event.sh', ['apply','$FM_HOME/state','$id',event.properties.status.type==='idle'?'idle':'busy','--gen','$gen','--source','opencode-plugin','--event','session-'+event.properties.status.type]);
}});
EOF
  jq -n --arg plugin "file://$project/.opencode/plugins/busy.js" '{plugin:[$plugin],provider:{opencode:{models:{"outage-unavailable":{id:"outage-unavailable",name:"Outage unavailable",limit:{context:4096,output:128}}}}}}' > "$project/config.json"
  pane=$(lab workspace create --cwd "$project" --label "$id" --no-focus | jq -er '.result.root_pane.pane_id')
  PANES+=("$pane")
  printf 'backend=herdr\nwindow=%s:%s\nharness=opencode\nworktree=%s\nkind=ship\n' "$SESSION" "$pane" "$project" > "$FM_HOME/state/$id.meta"
  lab pane run "$pane" "OPENCODE_DISABLE_PROJECT_CONFIG=1 OPENCODE_CONFIG='$project/config.json' OPENCODE_DISABLE_AUTOUPDATE=1 opencode --model opencode/outage-unavailable --prompt 'Reply briefly.'" >/dev/null
  printf '%s\n' "$pane" > "$E/$id.pane"
done
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
for id in lanea laneb; do
  for ((i=0;i<120;i++)); do lab pane read "$(<"$E/$id.pane")" --source visible | grep -q 'Model outage-unavailable is not supported' && break; sleep 1; done
  [ "$i" -lt 120 ] || fail "OpenCode $VERSION: no hosted failure for $id"
done
failure_at=$(date +%s)
printf '{"plugin":["file://%s/.opencode/plugins/fm-primary-watch-arm.js"]}\n' "$FM_HOME" > "$FM_HOME/opencode.json"
pane=$(lab workspace create --cwd "$FM_HOME" --label lead --no-focus | jq -er '.result.root_pane.pane_id')
PANES+=("$pane")
# shellcheck disable=SC2016 # The real model expands its own isolated environment.
prompt='For this initial turn only: run printf ready > state/lead-ready, then respond READY. Do not drain or handle any notification until a later WATCHER FIRED message arrives.'
printf 'printf "%%s\\n" "$$" > %q; FM_POLL=2 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=99999 OPENCODE_DISABLE_PROJECT_CONFIG=1 OPENCODE_CONFIG=%q OPENCODE_DISABLE_AUTOUPDATE=1 exec opencode --model opencode/big-pickle --prompt %q\n' "$FM_HOME/state/.lock" "$FM_HOME/opencode.json" "$prompt" > "$FM_HOME/launch.sh"
lab pane run "$pane" "bash '$FM_HOME/launch.sh'" >/dev/null
for ((i=0;i<180;i++)); do [ -s "$FM_HOME/state/lead-handled" ] && break; sleep 1; done
[ "$i" -lt 180 ] || fail "OpenCode $VERSION: second mate did not receive the automatic outage wake"
elapsed=$(( $(date +%s) - failure_at ))
[ "$elapsed" -lt 300 ] || fail "outage delivery took ${elapsed}s"
printf 'outage delivered and handled in %ss\n' "$elapsed" > "$E/latency.txt"
cp "$FM_HOME/state/.last-watcher-beat" "$E/first-beacon"
sleep 4
[ "$FM_HOME/state/.last-watcher-beat" -nt "$E/first-beacon" ] || fail 'second-mate beacon stopped'
# Delivery ledger records successful automatic delivery, not just queued text.
cp "$FM_HOME/state/.watch-deliveries.log" "$E/grouped-wake.txt"
grep -q 'affected=\[lanea,laneb\]: Model outage-unavailable is not supported' "$E/grouped-wake.txt"
[ "$(grep -c 'check: model outage' "$E/grouped-wake.txt")" = 1 ] || fail 'outage duplicated or not grouped'
mv "$FM_HOME/state/lead-handled" "$E/outage-handled"
before=$(cat "$E/outage-handled")
printf 'working [at=%s]: isolated worker notification\n' "$(date +%s)" >> "$FM_HOME/state/lanea.status"
for ((i=0;i<180;i++)); do
  after=$(cat "$FM_HOME/state/lead-handled" 2>/dev/null) || after=0
  [[ "$after" =~ ^[0-9]+$ ]] && [ "$after" -gt "$before" ] && grep -q 'lanea.status' "$FM_HOME/state/.watch-deliveries.log" && break
  sleep 1
done
[ "$i" -lt 180 ] || fail 'second mate did not wake for its own worker'
cp "$FM_HOME/state/.last-watcher-beat" "$E/second-beacon"
sleep 4
[ "$FM_HOME/state/.last-watcher-beat" -nt "$E/second-beacon" ] || fail 'beacon stopped after the second turn'
lab pane read "$pane" --source visible > "$E/lead-final.txt"
echo "PASS OpenCode $VERSION: grouped hosted outage delivered automatically; second mate keeps monitoring across turns"
