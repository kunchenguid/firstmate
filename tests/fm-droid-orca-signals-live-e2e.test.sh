#!/usr/bin/env bash
# Opt-in real Orca/Droid scout guard. Orca owns the disposable worktree and
# terminal; Firstmate owns task metadata, hooks, steering, and teardown.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_DROID_ORCA_SIGNALS droid orca jq node

ID="droid-orca-live-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-droid-orca-signals.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
# Orca's CLI can add but not remove a registered repository, so reuse one
# neutral scratch repository in the temp root across live guard runs.
PROJECT="${TMPDIR:-/tmp}/fm-droid-orca-scratch-repo-$(id -u)"
HOME_DIR="$LAB/home"
REPORT="$HOME_DIR/data/$ID/report.md"
export FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
cleanup() {
  if [ "${FM_DROID_ORCA_LIVE_KEEP:-0}" = 1 ] || [ "${FM_DROID_ORCA_LIVE_DONE:-0}" != 1 ]; then
    printf '# preserved Orca lab %s task %s for evidence or guarded recovery\n' "$LAB" "$ID" >&2
    return
  fi
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$PROJECT" "$HOME_DIR/data/$ID" "$HOME_DIR/state" "$HOME_DIR/config"
PROJECT=$(cd "$PROJECT" && pwd -P)
if [ ! -e "$PROJECT/.git" ]; then
  git -C "$PROJECT" init -qb main || fail "could not initialize private Orca smoke repository"
  git -C "$PROJECT" -c user.name='Droid Smoke' -c user.email='smoke@example.invalid' \
    commit --allow-empty -qm 'Initialize private Orca smoke repository' \
    || fail "could not commit private Orca smoke repository"
fi
cat >"$HOME_DIR/data/$ID/brief.md" <<EOF
# Current worker role contract
You are a crewmate worker managed by Firstmate, not a supervisor.
Do this bounded smoke task yourself and report through the task report only.

# Task
## Captain's intent
Prove that an Orca-backed Droid worker receives its brief and later steers.

## Firstmate spec
Write BRIEF_RECEIVED and your current working directory to $REPORT.
Finish the turn and wait for a steering message in $HOME_DIR/state/$ID.inbox; Firstmate will ring you, so do not start a background poller.
For each numbered .msg, append STEER_RECEIVED and its body to the report, move it to handled/, then follow the instruction.
Do not commit, push, or publish anything.
EOF

FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" --scout \
  --harness droid --model "${FM_DROID_LIVE_MODEL:-gpt-5.6-luna}" --effort low --backend orca \
  >"$LAB/spawn.out" 2>&1 || fail "Orca Droid scout spawn failed: $(tail -4 "$LAB/spawn.out")"

META="$HOME_DIR/state/$ID.meta"
grep -Fqx 'backend=orca' "$META" || fail "spawn did not record backend=orca"
TERMINAL=$(sed -n 's/^terminal=//p' "$META")
WORKTREE=$(sed -n 's/^worktree=//p' "$META")
ORCA_ID=$(sed -n 's/^orca_worktree_id=//p' "$META")
[ -n "$TERMINAL" ] && [ -n "$ORCA_ID" ] && [ -d "$WORKTREE" ] \
  || fail "spawn did not preserve Orca terminal/worktree identity"
[ "$WORKTREE" != "$PROJECT" ] || fail "Orca worker reused its project checkout"

wait_for() {  # <description> <shell command> [polls]
  local label=$1 command=$2 max=${3:-120} count=0
  while [ "$count" -lt "$max" ]; do
    bash -c "$command" && return 0
    count=$((count + 1))
    sleep 0.5
  done
  fail "$label did not appear within $((max / 2)) seconds"
}

orca_screen() {  # current rendered frame only
  orca terminal read --terminal "$TERMINAL" --screen --json | jq -r '
    if .result.terminal.source == "screen" then .result.terminal.tail[]? else error("Orca screen unavailable") end'
}

wait_for 'brief report' "test -f '$REPORT' && grep -Fq BRIEF_RECEIVED '$REPORT'"
wait_for 'initial turn end' "grep -q 'state=idle source=droid-hook' '$HOME_DIR/state/$ID.busy-state'"
orca_screen >"$LAB/idle-screen.txt" || fail "Orca did not return source=screen"
grep -Fq 'IDE ◌' "$LAB/idle-screen.txt" || fail "Orca Droid footer changed"
pass "Orca Droid received its brief and settled its turn"

"$ROOT/bin/fm-send.sh" "$ID" 'Append STEER_RECEIVED live-orca-steer to the report and acknowledge this inbox message.' \
  >"$LAB/inbox-send.out" 2>&1 || fail "Orca Droid inbox steer could not be recorded"
wait_for 'handled steer' "test -f '$HOME_DIR/state/$ID.inbox/handled/001.msg'"
wait_for 'steer report' "grep -Fq live-orca-steer '$REPORT'"
wait_for 'settled steer' "grep -q 'state=idle source=droid-hook' '$HOME_DIR/state/$ID.busy-state'"
"$ROOT/bin/fm-send.sh" "$TERMINAL" "Append TYPED_RECEIVED to '$REPORT' and reply ORCA_TYPED_OK." >"$LAB/typed-send.out" 2>&1 \
  || fail "Orca Droid typed steer was not confirmed: $(tail -2 "$LAB/typed-send.out")"
wait_for 'typed steer effect' "grep -Fq TYPED_RECEIVED '$REPORT'"
wait_for 'typed reply' "orca terminal read --terminal '$TERMINAL' --screen --json | jq -r '.result.terminal.tail[]?' | grep -Fq ORCA_TYPED_OK"
pass "Orca Droid acknowledged inbox and typed fm-send steers"

"$ROOT/bin/fm-send.sh" "$TERMINAL" \
  "Execute the shell command sleep 45; printf finished > '$HOME_DIR/state/$ID.sleep-finished' now and do not reply until it finishes." \
  >"$LAB/sleep-send.out" 2>&1 || fail "Orca Droid interrupt-test steer could not be confirmed"
wait_for 'running sleep tool' "orca terminal read --terminal '$TERMINAL' --screen --json | jq -r '.result.terminal.tail[]?' | grep -Fq 'Executing...  (Press ESC to stop)'"
started=$(date +%s)
"$ROOT/bin/fm-control.sh" "$ID" interrupt >"$LAB/interrupt.out" 2>&1 \
  || fail "Orca Droid interrupt failed: $(tail -2 "$LAB/interrupt.out")"
wait_for 'settled interrupt' "grep -q 'state=idle source=droid-hook' '$HOME_DIR/state/$ID.busy-state'" 20
[ $(( $(date +%s) - started )) -lt 30 ] || fail "Orca Droid interrupt was indistinguishable from normal sleep completion"
[ ! -e "$HOME_DIR/state/$ID.sleep-finished" ] || fail "Droid interrupted sleep reached its completion marker"
pass "Orca Droid interrupted a running tool before normal completion"

old_gen=$(sed -n 's/^busy_gen=//p' "$META")
"$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'Continue from the existing report; do not reprocess handled messages or rerun the earlier sleep. Wait for a new steer.' \
  >"$LAB/relaunch.out" 2>&1 || fail "Orca Droid relaunch failed: $(tail -3 "$LAB/relaunch.out")"
new_gen=$(sed -n 's/^busy_gen=//p' "$META")
[ -n "$new_gen" ] && [ "$new_gen" != "$old_gen" ] || fail "relaunch did not mint a fresh busy generation"
[ "$(sed -n 's/^terminal=//p' "$META")" = "$TERMINAL" ] || fail "relaunch lost its Orca terminal"
[ "$(sed -n 's/^orca_worktree_id=//p' "$META")" = "$ORCA_ID" ] || fail "relaunch lost its Orca worktree id"
grep -Fqx "model=${FM_DROID_LIVE_MODEL:-gpt-5.6-luna}" "$META" || fail "relaunch lost its model"
grep -Fqx 'effort=low' "$META" || fail "relaunch lost its effort"
wait_for 'relaunch turn end' "grep -q 'state=idle source=droid-hook' '$HOME_DIR/state/$ID.busy-state'" 360
DROID_LABEL=$(FACTORY_DROID_AUTO_UPDATE_ENABLED=false droid exec --help </dev/null 2>/dev/null | awk -v id="${FM_DROID_LIVE_MODEL:-gpt-5.6-luna}" '
  /^Available Models:/ { on=1; next } /^$/ { on=0 }
  on && $1 == id { sub(/^  [^ ]+ +/, ""); sub(/ [(]default[)]$/, ""); print; exit }')
[ -n "$DROID_LABEL" ] || fail "Droid's catalog does not name model ${FM_DROID_LIVE_MODEL:-gpt-5.6-luna}"
orca_screen | grep -Fq "$DROID_LABEL (Low)" \
  || fail "Droid's own header does not show '$DROID_LABEL (Low)' after relaunch"
pass "Orca Droid relaunch preserved endpoint and profile with a fresh generation"

if [ -n "${FM_DROID_ORCA_EVIDENCE_DIR:-}" ]; then
  mkdir -p "$FM_DROID_ORCA_EVIDENCE_DIR"
  orca terminal read --terminal "$TERMINAL" --limit 10000 --json \
    >"$FM_DROID_ORCA_EVIDENCE_DIR/terminal-stream.json" \
    || fail "Orca Droid terminal transcript could not be captured"
  orca_screen >"$FM_DROID_ORCA_EVIDENCE_DIR/idle-screen.txt" \
    || fail "Orca Droid final rendered screen could not be captured"
fi

"$ROOT/bin/fm-control.sh" "$ID" exit >"$LAB/exit.out" 2>&1 \
  || fail "Orca Droid exit failed: $(tail -2 "$LAB/exit.out")"
[ "$(cat "$HOME_DIR/state/$ID.droid-session-end")" = "$new_gen" ] \
  || fail "Droid SessionEnd did not prove the current Orca incarnation stopped"
"$ROOT/bin/fm-captain-hold.sh" complete "$ID" --none >/dev/null \
  || fail "Orca scout captain-call inventory failed"
# Preserve files from an optional operator plugin before guarded scout teardown.
if [ -d "$WORKTREE/.omd" ]; then
  mv "$WORKTREE/.omd" "$LAB/omd-preserved"
fi
"$ROOT/bin/fm-teardown.sh" "$ID" >"$LAB/teardown.out" 2>&1 \
  || fail "Orca scout teardown failed: $(tail -3 "$LAB/teardown.out")"
[ ! -e "$META" ] && [ ! -e "$HOME_DIR/state/$ID.droid-settings.json" ] \
  && [ ! -e "$HOME_DIR/state/$ID.droid-session-end" ] \
  || fail "Orca teardown left task metadata or Droid wiring"
[ ! -d "$WORKTREE" ] || fail "Orca teardown left the isolated worktree"
if [ -n "${FM_DROID_ORCA_EVIDENCE_DIR:-}" ]; then
  cp "$LAB"/*.out "$REPORT" "$FM_DROID_ORCA_EVIDENCE_DIR/" \
    || fail "Orca Droid lifecycle evidence could not be saved"
fi
FM_DROID_ORCA_LIVE_DONE=1
pass "Orca Droid exit and teardown retired the terminal, worktree, and task wiring"
