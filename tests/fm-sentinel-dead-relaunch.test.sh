#!/usr/bin/env bash
# tests/fm-sentinel-dead-relaunch.test.sh - token-free guard for the dead-lane
# relaunch in bin/fm-sentinel.sh reconcile.
#
# A session-start reconcile must not relaunch a dead ship or scout that is an
# open captain call, nor one that already acted since the restart. Three dead
# lanes sit in one home: a held lane, a lane that acted after the restart, and an
# ordinary paused lane that did not act. A herdr stand-in reports the server
# stopped, so every lane reads missing without a live Herdr. Reconcile runs in
# FM_SENTINEL_DRY_RUN=1, which must print the decisions and leave the home
# byte-identical: the held and acted lanes are skipped, and the paused lane is
# still chosen for relaunch.
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
printf '%s\n' "$OUT" | grep -q 'FAILED' && fail "dry run ran an action: $OUT"
pass "dead lanes: a held lane and an acted lane are skipped, an unheld paused lane is relaunched"

[ "$before" = "$after" ] || fail "dry run changed the home"
pass "dry run prints its decisions and writes nothing to the home"

if FM_HOME="$HOME_DIR" FM_SENTINEL_DRY_RUN=1 FM_SENTINEL_HERDR_SESSION="$SESSION" \
  "$ROOT/bin/fm-sentinel.sh" tick >/dev/null 2>&1; then
  fail "dry run was accepted for tick"
fi
pass "dry run is refused for tick"
