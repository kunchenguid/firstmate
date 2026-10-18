#!/usr/bin/env bash
# tests/fm-sentinel-dead-relaunch.test.sh - token-free guard for the dead-lane
# relaunch in bin/fm-sentinel.sh reconcile.
#
# A session-start reconcile must not relaunch a dead ship or scout that is an
# open captain call, that already acted since the restart, or that fm-control
# exit stopped on purpose. Four dead lanes sit in one home: a held lane, a lane
# that acted after the restart, a lane stopped through fm-control exit, and an
# ordinary paused lane that did not act. A herdr stand-in reports the server
# stopped, so every lane reads missing without a live Herdr. Reconcile runs in
# FM_SENTINEL_DRY_RUN=1, which must print the decisions and leave the home
# byte-identical: the held, acted and stopped lanes are skipped, and the paused
# lane is still chosen for relaunch. A lane spawned after its exit is relaunched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-sentinel-dead)
HOME_DIR=$TMP_ROOT/home
STATE=$HOME_DIR/state
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
SESSION=fmdeadtest
NOW=$(date +%s)
RESTART=$((NOW - 600))

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

mkdir -p "$HOME_DIR/data" "$STATE" "$HOME_DIR/config" "$HOME_DIR/projects"
fm_test_tasks_toml "$HOME_DIR/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"

# The herdr stand-in answers only `status`, reporting the server stopped. Every
# other call fails, so each lane's pane reads missing.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" status "*) printf '%s\n' '{"server":{"running":false}}' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

lane() {  # <id> <window-number> <spawn-epoch> <status-line>
  local id=$1 n=$2 spawn=$3
  mkdir -p "$TMP_ROOT/wt-$id"
  cat > "$STATE/$id.meta" <<EOF
window=$SESSION:w$n:p1
endpoint_task_id=$id
worktree=$TMP_ROOT/wt-$id
project=$TMP_ROOT/wt-$id
harness=claude
kind=ship
spawn_gen=s$spawn.1.1
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=w$n
herdr_tab_id=w$n:t1
herdr_pane_id=w$n:p1
EOF
  printf '%s\n' "$4" > "$STATE/$id.status"
}

lane held 1 "$((RESTART - 3600))" "working [at=$((RESTART - 60))]: implementing the brief"
lane acted 2 "$((RESTART - 3600))" "working [at=$((RESTART - 60))]: implementing the brief"
lane paused 3 "$((RESTART - 3600))" "paused [at=$((RESTART - 60))]: waiting on the validation run"
lane stopped 4 "$((RESTART - 3600))" "working [at=$((RESTART - 60))]: implementing the brief"

# The stopped lane is stopped through the real fm-control exit, which needs a
# Herdr server that answers for its pane: the stand-in reports the pane present
# with no agent in it, so the exit proves the agent stopped and records its epoch.
FAKEBIN_STOP=$TMP_ROOT/fakebin-stop
mkdir -p "$FAKEBIN_STOP"
cat > "$FAKEBIN_STOP/herdr" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" status "*) printf '%s\n' '{"server":{"running":true,"socket":"/nonexistent.sock"}}' ;;
  *" pane get "*) printf '%s\n' '{"result":{"pane":{"pane_id":"w4:p1"}}}' ;;
  *" agent get "*) printf '%s\n' '{"error":{"code":"agent_not_found"}}' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN_STOP/herdr"
PATH="$FAKEBIN_STOP:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  "$ROOT/bin/fm-control.sh" stopped exit >/dev/null || fail "fm-control exit could not stop the stopped lane"
[ -f "$STATE/stopped.exit" ] || fail "fm-control exit recorded no exit epoch"
# The acted lane posted a busy event after the restart, as a relaunched or
# resumed lane does.
printf 'v1 gen=s%s.1.1 seq=2 state=idle source=claude-hook event=stop ts=%s\n' \
  "$((RESTART - 3600))" "$NOW" > "$STATE/acted.busy-state"

PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$(command -v tasks-axi)" \
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-captain-hold.sh" \
  hold held --title "Captain call for held lane" --reason "captain must decide the held lane" \
  --repo sample >/dev/null || fail "could not hold the lane's captain call"

snapshot() {
  (cd "$HOME_DIR" && find . | sort && find . -type f -exec cksum {} + | sort)
}

reconcile_dry() {
  PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$(command -v tasks-axi)" \
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SENTINEL_HERDR_SESSION="$SESSION" \
    FM_SENTINEL_EPISODE="$SESSION:$RESTART" FM_SENTINEL_DRY_RUN=1 \
    "$ROOT/bin/fm-sentinel.sh" reconcile
}

before=$(snapshot)
OUT=$(reconcile_dry) || fail "dry-run reconcile failed: $OUT"
after=$(snapshot)

printf '%s\n' "$OUT" | grep -q '^held: captain hold open; left alone$' \
  || fail "held dead lane was not skipped as a captain hold: $OUT"
printf '%s\n' "$OUT" | grep -q '^acted: acted since the restart; left alone$' \
  || fail "dead lane that acted since the restart was not skipped: $OUT"
printf '%s\n' "$OUT" | grep -q '^paused: dry run, no action: agent missing; relaunched in ' \
  || fail "unheld paused dead lane was not chosen for relaunch: $OUT"
printf '%s\n' "$OUT" | grep -q '^stopped: stopped on purpose; left alone$' \
  || fail "dead lane stopped through fm-control exit was not skipped: $OUT"
printf '%s\n' "$OUT" | grep -q 'FAILED' && fail "dry run ran an action: $OUT"
pass "dead lanes: held, acted and stopped-on-purpose lanes are skipped, an unheld paused lane is relaunched"

[ "$before" = "$after" ] || fail "dry run changed the home"
pass "dry run prints its decisions and writes nothing to the home"

# A stop and a later relaunch both before the restart: the relaunch moves
# spawn_gen past the exit epoch, which makes the lane eligible again. Rewrite the
# two epochs the way fm-control exit and fm-spawn --relaunch record them.
printf '%s\n' "$((RESTART - 1800))" > "$STATE/stopped.exit"
sed -i "s/^spawn_gen=s[0-9]*\./spawn_gen=s$((RESTART - 1200))./" "$STATE/stopped.meta"
OUT=$(reconcile_dry) || fail "dry-run reconcile after a relaunch failed: $OUT"
printf '%s\n' "$OUT" | grep -q '^stopped: dry run, no action: agent missing; relaunched in ' \
  || fail "a lane spawned after its exit was not eligible for relaunch: $OUT"
pass "a lane spawned after its exit is relaunched again"

if FM_HOME="$HOME_DIR" FM_SENTINEL_DRY_RUN=1 FM_SENTINEL_HERDR_SESSION="$SESSION" \
  "$ROOT/bin/fm-sentinel.sh" tick >/dev/null 2>&1; then
  fail "dry run was accepted for tick"
fi
pass "dry run is refused for tick"

# One-shot episode record. A herdr stand-in that reports the server running
# leaves a lane unreadable, so the lane is unsettled and no action runs.
EPISODE="$SESSION:$RESTART"
IDFILE=$STATE/.sentinel-herdr-identity
FAKEBIN_UP=$TMP_ROOT/fakebin-up
mkdir -p "$FAKEBIN_UP"
cat > "$FAKEBIN_UP/herdr" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" status "*) printf '%s\n' '{"server":{"running":true}}' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN_UP/herdr"

oneshot() {  # <home> <path-prefix> <dry-run 0|1>
  PATH="$2:$PATH" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    FM_CONFIG_OVERRIDE="$1/config" FM_SENTINEL_HERDR_SESSION="$SESSION" \
    FM_SENTINEL_EPISODE="$EPISODE" FM_SENTINEL_DRY_RUN="$3" \
    "$ROOT/bin/fm-sentinel.sh" reconcile
}

new_home() {  # <home>
  mkdir -p "$1/state" "$1/data" "$1/config" "$1/projects"
}

printf '%s\n' "$EPISODE" > "$IDFILE"
OUT=$(reconcile_dry) || fail "one-shot reconcile failed for a recorded episode: $OUT"
[ "$(printf '%s\n' "$OUT" | wc -l)" -eq 1 ] || fail "a recorded episode did more than report: $OUT"
printf '%s\n' "$OUT" | grep -qx "herdr episode $EPISODE already reconciled; nothing to do" \
  || fail "recorded episode was not reported as reconciled: $OUT"
[ "$(cat "$IDFILE")" = "$EPISODE" ] || fail "recorded episode identity changed"
pass "a recorded episode is reported as reconciled and nothing else runs"
rm -f "$IDFILE"

HOME_SETTLED=$TMP_ROOT/settled
new_home "$HOME_SETTLED"
oneshot "$HOME_SETTLED" "$FAKEBIN" 0 >/dev/null || fail "settled one-shot reconcile failed"
[ "$(cat "$HOME_SETTLED/state/.sentinel-herdr-identity" 2>/dev/null)" = "$EPISODE" ] \
  || fail "settled one-shot reconcile did not record its episode"
pass "a settled one-shot reconcile records its episode"

HOME_UNSETTLED=$TMP_ROOT/unsettled
new_home "$HOME_UNSETTLED"
cat > "$HOME_UNSETTLED/state/unsettled.meta" <<EOF
window=$SESSION:w9:p1
endpoint_task_id=unsettled
worktree=$TMP_ROOT/wt-unsettled
project=$TMP_ROOT/wt-unsettled
harness=claude
kind=ship
spawn_gen=s$((RESTART - 3600)).1.1
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=w9
herdr_tab_id=w9:t1
herdr_pane_id=w9:p1
EOF
printf '%s\n' "working [at=$((RESTART - 60))]: implementing the brief" > "$HOME_UNSETTLED/state/unsettled.status"
OUT=$(oneshot "$HOME_UNSETTLED" "$FAKEBIN_UP" 0) || fail "unsettled one-shot reconcile failed: $OUT"
printf '%s\n' "$OUT" | grep -q 'not settled, left for the next pass' \
  || fail "lane was not left unsettled: $OUT"
[ ! -e "$HOME_UNSETTLED/state/.sentinel-herdr-identity" ] || fail "unsettled episode was recorded"
pass "an unsettled one-shot reconcile records nothing"

HOME_DRY=$TMP_ROOT/dry
new_home "$HOME_DRY"
oneshot "$HOME_DRY" "$FAKEBIN" 1 >/dev/null || fail "dry-run one-shot reconcile failed"
[ ! -e "$HOME_DRY/state/.sentinel-herdr-identity" ] || fail "dry run recorded its episode"
pass "a dry-run one-shot reconcile records nothing"
