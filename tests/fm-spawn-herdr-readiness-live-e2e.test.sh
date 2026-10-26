#!/usr/bin/env bash
# Default-on live guard for bin/fm-spawn.sh's Herdr `treehouse get` send path
# (header "Treehouse get on Herdr") against the REAL installed herdr and
# treehouse, on a private named lab session only (tests/herdr-test-safety.sh).
#
# The portable suite (tests/fm-spawn-herdr-readiness.test.sh) pins the logic
# against a fake; this guard proves the vendor facts the fix rests on:
#   1. An exhausted pool: a one-slot pool whose slot is held by a durable
#      lease makes the real spawn fail within seconds with treehouse's own
#      "worktrees are in use or dirty" text, and the fresh task tab is closed
#      again, leaving the lab session as it was.
#   2. Typeahead: twenty tabs created back to back, each sent a marker by
#      `pane run` immediately after `tab create`, all echo the marker. This
#      pins the pre-prompt typeahead behaviour the readiness gate exists to
#      stop relying on; a change here fails naming the Herdr version.
#   3. The happy path: the gate, the echoed receipt, and the cwd poll land a
#      real spawn inside the lab pool's slot. The worker is a raw `sleep`
#      launch command (fm-spawn's adapter-verification escape hatch), so no
#      harness runs and no prompt is ever submitted to a model, which is why
#      the shared live gate runs this by default wherever its tools exist.
# Run it after every Herdr or treehouse upgrade and before trusting the
# refreshed docs/verification/runtime-backends.md "Spawn readiness and husk
# sweep" entry.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

fm_live_gate default-on FM_LIVE_HERDR_SPAWN herdr treehouse jq

herdr_forget_inherited_pane
SESSION=$("$ROOT/bin/fm-herdr-lab.sh" name fm-spawn-ready)
export HERDR_SESSION="$SESSION"
HERDR_VERSION=$(herdr --version 2>/dev/null | head -1)
TREEHOUSE_VERSION=$(treehouse --version 2>/dev/null | head -1)
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-readiness-live)
SPAWN="$ROOT/bin/fm-spawn.sh"
HOLD_PID=

cleanup_all() {
  local status=$?
  [ -z "$HOLD_PID" ] || kill "$HOLD_PID" 2>/dev/null || true
  herdr_safe_stop_and_delete "$SESSION"
  exit "$status"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session $SESSION"

# A tiny repository with a local bare origin (treehouse fetches origin before
# acquiring) and a one-slot pool rooted inside this test's own temp root.
ORIGIN="$TMP_ROOT/origin.git"
PROJ="$TMP_ROOT/project"
POOL_ROOT="$TMP_ROOT/pool"
mkdir -p "$POOL_ROOT"
fm_git_identity
fm_git_init_commit "$PROJ"
printf 'max_trees = 1\nroot = "%s"\n' "$POOL_ROOT" > "$PROJ/treehouse.toml"
git -C "$PROJ" add treehouse.toml
git -C "$PROJ" commit -qm 'lab pool config'
fm_git_add_origin "$PROJ" "$ORIGIN"

HOME_DIR="$TMP_ROOT/home"
fm_test_spawn_home "$HOME_DIR" codex
printf 'herdr\n' > "$HOME_DIR/config/backend"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"

run_spawn() { # <id> [spawn flags...]
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" "$PROJ" --mode no-mistakes --yolo off "$@" 2>&1
}

task_tabs() { # <label>
  herdr tab list --session "$SESSION" 2>/dev/null \
    | jq -r --arg want "$1" '.result.tabs[]? | select(.label == $want) | .tab_id'
}

# --- 1. exhausted pool: fail fast with treehouse's text, no leftover tab -----
HELD=$(cd "$PROJ" && treehouse get --lease --lease-holder fm-live-hold 2>/dev/null) \
  || fail "treehouse get --lease could not hold the lab pool's only slot ($TREEHOUSE_VERSION)"
[ -d "$HELD" ] || fail "treehouse reported a lease at '$HELD' that is not a directory"
ID=live-pool-full
fm_test_spawn_brief "$HOME_DIR" "$ID" "Exercise the exhausted-pool refusal for $ID."
started=$(date +%s)
out=$(run_spawn "$ID")
status=$?
elapsed=$(( $(date +%s) - started ))
[ "$status" -ne 0 ] || fail "spawn succeeded against a fully leased one-slot pool ($TREEHOUSE_VERSION)"$'\n'"$out"
case "$out" in
  *"worktrees are in use or dirty"*) : ;;
  *) fail "the refusal did not carry treehouse's own pool-full text ($HERDR_VERSION, $TREEHOUSE_VERSION)"$'\n'"$out" ;;
esac
case "$out" in
  *"did not enter an isolated worktree within 60s"*) fail "the refusal waited for the 60s deadline instead of failing fast ($HERDR_VERSION)"$'\n'"$out" ;;
esac
[ "$elapsed" -le 20 ] || fail "the exhausted-pool refusal took ${elapsed}s; expected seconds ($HERDR_VERSION, $TREEHOUSE_VERSION)"
[ -z "$(task_tabs "fm-$ID")" ] || fail "the refused spawn left tab fm-$ID open in the lab session ($HERDR_VERSION)"$'\n'"$out"
[ ! -e "$HOME_DIR/state/$ID.meta" ] || fail "the refused spawn published task metadata"
pass "real herdr+treehouse: an exhausted pool fails in ${elapsed}s with treehouse's message and the fresh tab is closed"
(cd "$PROJ" && treehouse return "$HELD" >/dev/null 2>&1) || fail "could not release the held lab slot $HELD"

# --- 2. typeahead pin: twenty back-to-back tabs all echo an immediate run ----
WSID=$(herdr tab list --session "$SESSION" 2>/dev/null | jq -r '.result.tabs[0].workspace_id // empty')
if [ -z "$WSID" ]; then
  WSID=$(herdr workspace create --label fm-typeahead --cwd "$PROJ" --no-focus --session "$SESSION" 2>/dev/null \
    | jq -r '.result.workspace.workspace_id // empty')
fi
[ -n "$WSID" ] || fail "could not resolve a lab workspace for the typeahead pin ($HERDR_VERSION)"
PANES=()
for n in $(seq 1 20); do
  pane=$(herdr tab create --workspace "$WSID" --cwd "$PROJ" --label "fm-typeahead-$n" --no-focus --session "$SESSION" 2>/dev/null \
    | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$pane" ] || fail "tab create $n returned no pane ($HERDR_VERSION)"
  herdr pane run "$pane" "echo fm-typeahead-marker-$n" --session "$SESSION" >/dev/null 2>&1 \
    || fail "pane run into fresh pane $pane failed ($HERDR_VERSION)"
  PANES+=("$pane")
done
missed=0
for n in $(seq 1 20); do
  pane=${PANES[$((n - 1))]}
  herdr pane wait-output "$pane" --match "fm-typeahead-marker-$n" --source recent --timeout 10000 --session "$SESSION" >/dev/null 2>&1 \
    || missed=$((missed + 1))
done
[ "$missed" -eq 0 ] || fail "typeahead pin: $missed of 20 panes never echoed a marker typed immediately after tab create on $HERDR_VERSION; the readiness gate's assumptions changed"
pass "real herdr: 20 back-to-back tabs all echoed a marker typed before their first prompt ($HERDR_VERSION)"

# --- 3. happy path with a model-free raw launch command --------------------
ID=live-pool-free
fm_test_spawn_brief "$HOME_DIR" "$ID" "Exercise the gated treehouse get for $ID."
out=$(run_spawn "$ID" --harness 'sleep 600')
status=$?
[ "$status" -eq 0 ] || fail "spawn into the free one-slot lab pool failed ($HERDR_VERSION, $TREEHOUSE_VERSION)"$'\n'"$out"
recorded=$(grep '^worktree=' "$HOME_DIR/state/$ID.meta" 2>/dev/null | head -1 | cut -d= -f2-)
case "$recorded" in
  "$POOL_ROOT"/*) : ;;
  *) fail "the spawn recorded worktree '$recorded', not a slot under the lab pool $POOL_ROOT"$'\n'"$out" ;;
esac
pane=$(grep '^window=' "$HOME_DIR/state/$ID.meta" 2>/dev/null | head -1 | cut -d= -f2-)
foreground=$(herdr pane get "${pane#*:}" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.foreground_cwd // empty')
[ "$(cd "$foreground" 2>/dev/null && pwd -P)" = "$(cd "$recorded" && pwd -P)" ] \
  || fail "the task pane's foreground cwd is '$foreground', not the recorded slot $recorded ($HERDR_VERSION)"
pass "real herdr+treehouse: the gated treehouse get landed the spawn in $recorded"

echo "evidence: herdr=$HERDR_VERSION treehouse=$TREEHOUSE_VERSION pool-full-elapsed=${elapsed}s typeahead-missed=$missed default-session-tripwire=armed"
