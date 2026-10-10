#!/usr/bin/env bash
# Opt-in live Droid worker guard: model, hooks, trust, steering, and control.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_DROID_SIGNALS droid tmux treehouse jq

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-droid-signals-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-droid-signals.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
ID=droid-live
HOME_DIR="$LAB/home"
PROJECT="$HOME_DIR/projects/scratch"
REPORT="$HOME_DIR/data/$ID/report.md"
export FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" TREEHOUSE_ROOT="$LAB/pool"

cleanup() {
  if [ "${FM_DROID_LIVE_KEEP:-0}" = 1 ] || [ "${FM_DROID_LIVE_DONE:-0}" != 1 ]; then
    printf '# kept live lab at %s\n' "$LAB" >&2
    return
  fi
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  chmod -R u+w "$LAB" 2>/dev/null || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB/shim" "$PROJECT" "$HOME_DIR/data/$ID" "$HOME_DIR/state" "$HOME_DIR/config" "$LAB/pool"
cat >"$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

git -C "$PROJECT" init -q || fail "could not initialize Droid smoke repository"
git -C "$PROJECT" -c user.name='Droid Smoke' -c user.email='smoke@example.invalid' \
  commit --allow-empty -qm 'Initialize disposable scout repository' \
  || fail "could not commit Droid smoke repository"
cat >"$HOME_DIR/data/$ID/brief.md" <<EOF
# Current worker role contract
You are a crewmate worker managed by Firstmate, not a supervisor.
Do this bounded smoke task yourself and report through the task report only.

# Task
## Captain's intent
Prove that the Droid worker receives the launch brief and a later steer.

## Firstmate spec
Create a report at the absolute path $REPORT with one line beginning BRIEF_RECEIVED and your current working directory, unless the existing report already contains that line.
Then finish your turn and wait for a steering message in $HOME_DIR/state/$ID.inbox; Firstmate will ring you when one arrives, so do not start a background poller.
For each message, append STEER_RECEIVED and the message body to $REPORT, move its .msg file to the handled directory, then follow its instruction.
Do not commit, push, or publish anything.
EOF

# Default to gpt-5.6-terra; FM_DROID_LIVE_MODEL overrides it. The prior gpt-5.6-luna
# default skipped a steered instruction even though Firstmate delivered the steer;
# gpt-5.6-terra passed every step.
FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" --scout \
  --harness droid --model "${FM_DROID_LIVE_MODEL:-gpt-5.6-terra}" --effort low --backend tmux \
  || fail "Droid scout spawn failed"

wait_for() {  # <description> <shell command> [polls]
  local label=$1 command=$2 max=${3:-120} count=0
  while [ "$count" -lt "$max" ]; do
    bash -c "$command" && return 0
    count=$((count + 1))
    sleep 0.5
  done
  fail "$label did not appear within $((max / 2)) seconds"
}

wait_for 'brief report' "test -f '$REPORT' && grep -Fq BRIEF_RECEIVED '$REPORT'"
wait_for 'initial turn end' "test -e '$HOME_DIR/state/$ID.turn-ended'"
pass "Droid received its brief and signalled turn end"

"$ROOT/bin/fm-send.sh" "$ID" 'Append STEER_RECEIVED live-steer to the report, then acknowledge this inbox message.' \
  || fail "Droid inbox steer could not be recorded"
wait_for 'handled steer' "test -f '$HOME_DIR/state/$ID.inbox/handled/001.msg'"
wait_for 'steer report' "grep -Fq live-steer '$REPORT'"
wait_for 'settled steer' "grep -q 'state=idle source=droid-hook' '$HOME_DIR/state/$ID.busy-state'" 360
TARGET=$(sed -n 's/^window=//p' "$HOME_DIR/state/$ID.meta")
"$ROOT/bin/fm-send.sh" "$TARGET" "Append TYPED_RECEIVED to '$REPORT' and reply TMUX_TYPED_OK." \
  || fail "Droid typed steer could not be confirmed"
wait_for 'typed steer effect' "grep -Fq TYPED_RECEIVED '$REPORT'"
pass "Droid acknowledged inbox and typed fm-send steers"

"$ROOT/bin/fm-send.sh" "$ID" \
  "Execute the shell command sleep 45; printf finished > '$HOME_DIR/state/$ID.sleep-finished' now and wait for it to finish before replying." \
  || fail "Droid interrupt-test steer could not be recorded"
wait_for 'busy hook' "grep -q 'state=busy source=droid-hook' '$HOME_DIR/state/$ID.busy-state'"
wait_for 'running sleep tool' "tmux capture-pane -p -t '$TARGET' -S -0 | grep -Fq 'Executing...  (Press ESC to stop)'"
started=$(date +%s)
"$ROOT/bin/fm-control.sh" "$ID" interrupt || fail "Droid interrupt failed"
wait_for 'settled interrupt' "grep -q 'state=idle source=droid-hook' '$HOME_DIR/state/$ID.busy-state'" 20
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 30 ] || fail "Droid interruption took ${elapsed}s, indistinguishable from a normal sleep completion"
[ ! -e "$HOME_DIR/state/$ID.sleep-finished" ] || fail "Droid interrupted sleep reached its completion marker"
pass "Droid settled its interrupted turn before the 45-second command completed"

old_gen=$(sed -n 's/^busy_gen=//p' "$HOME_DIR/state/$ID.meta")
"$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'Continue from the existing report; do not reprocess handled messages or rerun the earlier sleep. Wait for a new steer.' \
  || fail "Droid relaunch failed"
new_gen=$(sed -n 's/^busy_gen=//p' "$HOME_DIR/state/$ID.meta")
[ -n "$new_gen" ] && [ "$new_gen" != "$old_gen" ] || fail "Droid relaunch did not mint a fresh busy generation"
grep -Fqx "model=${FM_DROID_LIVE_MODEL:-gpt-5.6-terra}" "$HOME_DIR/state/$ID.meta" || fail "Droid relaunch lost the model"
grep -Fqx 'effort=low' "$HOME_DIR/state/$ID.meta" || fail "Droid relaunch lost the effort"
wait_for 'relaunch turn end' "grep -q 'state=idle source=droid-hook' '$HOME_DIR/state/$ID.busy-state'" 360
DROID_LABEL=$(FACTORY_DROID_AUTO_UPDATE_ENABLED=false droid exec --help </dev/null 2>/dev/null | awk -v id="${FM_DROID_LIVE_MODEL:-gpt-5.6-terra}" '
  /^Available Models:/ { on=1; next } /^$/ { on=0 }
  on && $1 == id { sub(/^  [^ ]+ +/, ""); sub(/ [(]default[)]$/, ""); print; exit }')
[ -n "$DROID_LABEL" ] || fail "Droid's catalog does not name model ${FM_DROID_LIVE_MODEL:-gpt-5.6-terra}"
tmux capture-pane -p -t "$TARGET" | grep -Fq "$DROID_LABEL (Low)" \
  || fail "Droid's own header does not show '$DROID_LABEL (Low)' after relaunch"
pass "Droid relaunch preserved its profile and replaced its busy generation"

if [ -n "${FM_DROID_TMUX_EVIDENCE_DIR:-}" ]; then
  mkdir -p "$FM_DROID_TMUX_EVIDENCE_DIR"
  tmux capture-pane -p -t "$TARGET" -S -2000 >"$FM_DROID_TMUX_EVIDENCE_DIR/terminal.txt" \
    || fail "Droid terminal transcript could not be captured"
  cp "$REPORT" "$FM_DROID_TMUX_EVIDENCE_DIR/report.md" \
    || fail "Droid scout report could not be captured"
fi

"$ROOT/bin/fm-control.sh" "$ID" exit || fail "Droid exit failed"
"$ROOT/bin/fm-captain-hold.sh" complete "$ID" --none \
  || fail "Droid scout completion inventory failed"
"$ROOT/bin/fm-teardown.sh" "$ID" || fail "Droid scout teardown failed"
[ ! -e "$HOME_DIR/state/$ID.meta" ] || fail "Droid task metadata survived teardown"
[ ! -e "$HOME_DIR/state/$ID.droid-settings.json" ] || fail "Droid runtime settings survived teardown"
FM_DROID_LIVE_DONE=1
pass "Droid exit and teardown retired the task and settings"
