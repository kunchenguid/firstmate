#!/usr/bin/env bash
# Real-Herdr regression for deterministic Firstmate agent names.
#
# A token-free Claude stand-in registers through Herdr's documented agent
# registry, so the real spawn path must rename the exact response-derived pane
# and prove the alias by reading that pane back. A second spawn meets a real
# session-global name collision and must stop visibly, close its exact pane so
# the launched agent cannot outlive task control, and keep its Treehouse copy.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane
fm_live_gate default-on FM_HERDR_AGENT_NAME_LIVE_E2E herdr jq treehouse

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] \
  || { echo "skip: live: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(fm_test_tmproot fm-herdr-agent-name-live-e2e)
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$PROJECT"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name herdr-agent-names)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH

WORKTREES=()
cleanup() {
  local status=$? wt
  for wt in ${WORKTREES[@]+"${WORKTREES[@]}"}; do
    [ -n "$wt" ] && treehouse return --force "$wt" >/dev/null 2>&1
  done
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT

# This process spends no model tokens. It supplies the same registered-agent
# shape a supported Claude launch supplies, then remains in the pane so the
# spawn-time rename/readback gate sees a live occupant.
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
set -u
env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" \
  pane report-agent "$HERDR_PANE_ID" \
  --source fm-agent-name-live-e2e --agent claude --state idle >/dev/null || exit 91
trap 'exit 0' INT TERM HUP
while :; do sleep 1; done
SH
chmod +x "$FAKEBIN/claude"

env PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

# Production code still exercises its normal explicit-session CLI helper, but
# this lab shim makes every resulting Herdr call pass through the generated
# non-default lab contract before it reaches the real binary.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() {
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}

git -C "$PROJECT" init -q
printf '# scratch\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJECT" "$PROJECT.origin.git"
git -C "$PROJECT" remote add origin "file://$PROJECT.origin.git"

write_brief() {  # <task-id>
  mkdir -p "$HOME_DIR/data/$1"
  cat > "$HOME_DIR/data/$1/brief.md" <<EOF
# Task
## Captain's intent
Exercise the Herdr agent-name contract for $1.

## Firstmate spec
Use the token-free test harness and verify the exact task pane.

# Definition of done
Delivery contract: mode=local-only
EOF
}

derive_name() {  # <task-id>
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_task_agent_name "$1"
  ' "$ROOT" "$1"
}

spawn_task() {  # <task-id> <polls> <out> <err>
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH \
    PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HERDR_AGENT_NAME_POLLS="$2" FM_HERDR_AGENT_NAME_INTERVAL=0.1 \
    "$ROOT/bin/fm-spawn.sh" "$1" "$PROJECT" --harness claude \
      --mode local-only --yolo off --backend herdr >"$3" 2>"$4"
}

write_brief named-agent
SUCCESS_OUT="$TMP_ROOT/success.out"; SUCCESS_ERR="$TMP_ROOT/success.err"
spawn_task named-agent 120 "$SUCCESS_OUT" "$SUCCESS_ERR" \
  || fail "supported-harness spawn failed before its name could verify"$'\n'"$(cat "$SUCCESS_ERR")"

SUCCESS_META="$HOME_DIR/state/named-agent.meta"
SUCCESS_WT=$(grep '^worktree=' "$SUCCESS_META" | cut -d= -f2-)
SUCCESS_PANE=$(grep '^herdr_pane_id=' "$SUCCESS_META" | cut -d= -f2-)
SUCCESS_NAME=$(derive_name named-agent)
[ -n "$SUCCESS_WT" ] && WORKTREES+=("$SUCCESS_WT")
[ -n "$SUCCESS_PANE" ] || fail 'successful spawn metadata omitted the exact Herdr pane id'
SUCCESS_AGENT=$(lab agent get "$SUCCESS_PANE") \
  || fail 'could not read the successfully named agent from its exact pane'
[ "$(printf '%s' "$SUCCESS_AGENT" | jq -r '.result.agent.pane_id // empty')" = "$SUCCESS_PANE" ] \
  || fail 'the successful name readback described another pane'
[ "$(printf '%s' "$SUCCESS_AGENT" | jq -r '.result.agent.name // empty')" = "$SUCCESS_NAME" ] \
  || fail "the supported-harness spawn did not receive its deterministic name '$SUCCESS_NAME'"
pass 'real Herdr: a supported-harness spawn receives its deterministic name on the exact new pane'

# Occupy the next task's deterministic alias in another exact pane. Herdr's
# real uniqueness check must make the next spawn fail its verified name gate.
write_brief collision-agent
COLLISION_NAME=$(derive_name collision-agent)
DECOY_CREATE=$(lab workspace create --cwd "$PROJECT" --label agent-name-decoy --no-focus) \
  || fail 'could not create the collision decoy workspace'
DECOY_PANE=$(printf '%s' "$DECOY_CREATE" | jq -er '.result.root_pane.pane_id') \
  || fail 'could not read the collision decoy pane id'
lab pane report-agent "$DECOY_PANE" --source fm-agent-name-live-e2e \
  --agent codex --state idle >/dev/null \
  || fail 'could not register the collision decoy agent'
lab agent rename "$DECOY_PANE" "$COLLISION_NAME" >/dev/null \
  || fail 'could not reserve the deterministic name for the collision case'

FAIL_OUT="$TMP_ROOT/fail.out"; FAIL_ERR="$TMP_ROOT/fail.err"
if spawn_task collision-agent 2 "$FAIL_OUT" "$FAIL_ERR"; then
  fail 'a session-global name collision must stop the spawn instead of leaving a generic alias'
fi
assert_contains "$(cat "$FAIL_ERR")" 'spawn stopped because herdr agent naming did not verify' \
  'the failed spawn did not report the verified naming gate'
assert_contains "$(cat "$HOME_DIR/state/collision-agent.status")" \
  "failed: herdr agent naming did not verify for $COLLISION_NAME in exact pane" \
  'the failed spawn did not preserve an inspectable status event'
[ ! -e "$HOME_DIR/state/collision-agent.meta" ] \
  || fail 'a naming failure must not publish authoritative task metadata'

FAIL_TARGET=$(sed -n 's/.*closing window \([^ ]*\) and keeping local copy .*/\1/p' "$FAIL_ERR" | tail -1)
FAIL_PANE=${FAIL_TARGET#*:}
FAIL_WT=$(sed -n 's/.*and keeping local copy \(.*\)$/\1/p' "$FAIL_ERR" | tail -1)
[ -n "$FAIL_TARGET" ] && [ "$FAIL_PANE" != "$FAIL_TARGET" ] \
  || fail 'the naming failure did not identify its exact pane'
[ -n "$FAIL_WT" ] && WORKTREES+=("$FAIL_WT")
FAIL_PANE_READ=$(lab pane get "$FAIL_PANE" 2>&1) \
  && fail 'the naming failure left the launched agent running in its exact pane outside task control'
assert_contains "$FAIL_PANE_READ" 'pane_not_found' \
  'the naming failure pane read did not prove that exact pane closed'
[ -d "$FAIL_WT" ] \
  || fail 'the naming failure removed the task copy instead of preserving it for inspection'
pass 'real Herdr: an unresolvable name collision stops visibly, closes the exact pane, and keeps the task copy'

# The failed target never receives the decoy's name, and the already-named
# sibling stays unchanged. This proves the gate neither selects nor verifies
# through a mutable name.
[ "$(lab agent get "$DECOY_PANE" | jq -r '.result.agent.name // empty')" = "$COLLISION_NAME" ] \
  || fail 'the exact-pane failure path renamed or displaced the decoy agent'
[ "$(lab agent get "$SUCCESS_PANE" | jq -r '.result.agent.name // empty')" = "$SUCCESS_NAME" ] \
  || fail 'the collision path changed the previously named sibling agent'
pass 'real Herdr: mutable names never select the rename target or disturb a sibling pane'
