#!/usr/bin/env bash
# Real-Herdr regression: the full fm-spawn pane-shell path gives every
# auto-detected supported worker a stable task-derived Agents-sidebar name.
# The Pi launch is prompt-free and submits no model request.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane
fm_live_gate default-on FM_HERDR_AGENT_NAME_E2E herdr jq pi treehouse

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: live: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(fm_test_tmproot fm-herdr-agent-name-e2e)
FAKEBIN="$TMP_ROOT/fakebin"
HOME_ROOT="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/firstmate"
mkdir -p "$FAKEBIN" "$HOME_ROOT/state" "$HOME_ROOT/data/worker-label" "$HOME_ROOT/config" "$PROJECT"
printf 'off\n' > "$HOME_ROOT/config/herdr-presentation-spaces"
cat > "$HOME_ROOT/data/worker-label/brief.md" <<'EOF'
# Task
## Captain's intent
Remain idle for an isolated identity regression.

## Firstmate spec
Expose the worker's Herdr identity without performing project work.
EOF

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-agent-name)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH

cleanup() {
  local status=$? cleanup_status=0
  if [ -f "$HOME_ROOT/state/worker-label.meta" ]; then
    env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
      PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" HERDR_SESSION="$HERDR_LAB_SESSION" \
      FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_ROOT/state" \
      FM_DATA_OVERRIDE="$HOME_ROOT/data" FM_CONFIG_OVERRIDE="$HOME_ROOT/config" \
      "$ROOT/bin/fm-teardown.sh" worker-label >/dev/null 2>&1 || cleanup_status=1
  fi
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || cleanup_status=1
  fm_test_cleanup
  [ "$cleanup_status" -eq 0 ] || status=1
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

# Route every fm-spawn/fm-teardown Herdr call through the guarded lab helper.
# The adapter already appends the exact session flag, so strip only that final
# pair before the helper appends it again.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
if [ "${#args[@]}" -ge 2 ]; then
  last=$((${#args[@]} - 1))
  flag=$((last - 1))
  if [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
    unset 'args[$last]' 'args[$flag]'
  fi
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

git -C "$PROJECT" init -q
git -C "$PROJECT" config user.name 'Firstmate Tests'
git -C "$PROJECT" config user.email tests@example.invalid
printf '# identity regression\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -qm initial
git clone --quiet --bare "$PROJECT" "$TMP_ROOT/firstmate.origin.git"
git -C "$PROJECT" remote add origin "file://$TMP_ROOT/firstmate.origin.git"

SPAWN_OUT=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" HERDR_SESSION="$HERDR_LAB_SESSION" \
  FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_ROOT" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" worker-label "$PROJECT" 'pi --no-context-files --no-session' \
  --mode no-mistakes --yolo off --backend herdr 2>&1) || fail "full Herdr worker spawn failed:$NL$SPAWN_OUT"
assert_contains "$SPAWN_OUT" "spawned worker-label harness=pi" "full spawn did not report its Pi worker"

META="$HOME_ROOT/state/worker-label.meta"
[ -f "$META" ] || fail "full spawn did not publish worker metadata"
PANE=$(grep '^herdr_pane_id=' "$META" | cut -d= -f2-)
TAB=$(grep '^herdr_tab_id=' "$META" | cut -d= -f2-)
[ -n "$PANE" ] && [ -n "$TAB" ] || fail "full spawn did not record exact Herdr pane and tab ids"

AGENT=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent get "$PANE") \
  || fail "the spawned Pi was not visible through Herdr's agent interface"
NAME=$(printf '%s' "$AGENT" | jq -r '.result.agent.name // empty')
[[ "$NAME" =~ ^crew-worker-label-[0-9a-f]{10}$ ]] \
  || fail "the spawned worker kept a generic or empty Herdr agent name: '$NAME'"
printf '%s' "$AGENT" | jq -e --arg pane "$PANE" --arg name "$NAME" \
  '.result.agent.pane_id == $pane and .result.agent.name == $name' >/dev/null \
  || fail "the task-derived name was not bound to the exact spawned pane"

TAB_LABEL=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab get "$TAB" | jq -r '.result.tab.label // empty')
[ "$TAB_LABEL" = fm-worker-label ] \
  || fail "the public task tab no longer exposes the same task identity: '$TAB_LABEL'"
LIST_NAME=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent list | jq -r --arg pane "$PANE" \
  '.result.agents[]? | select(.pane_id == $pane) | .name')
[ "$LIST_NAME" = "$NAME" ] \
  || fail "the Agents list did not expose the exact verified task-derived name: '$LIST_NAME'"

pass "full fm-spawn gives a shell-launched Pi worker a stable task-derived Herdr agent name"
pass "Herdr's agent get and Agents list agree on the exact named worker pane"
