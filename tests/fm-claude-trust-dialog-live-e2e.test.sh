#!/usr/bin/env bash
# Opt-in real-Claude guard for the workspace-trust launch path.
# It uses two fresh repositories, two worktrees of the first repository, a private tmux server,
# an isolated Claude config directory, and the real fm-spawn.sh relaunch path.
# The first launch must navigate the cancel-focused dialog without human input
# and execute its brief; the second worktree must execute without another trust navigation.
# An unrelated repository must show its own dialog, proving that acceptance persists per repository.
set -u

# This is an isolated test-harness fleet, not the live Firstmate fleet.
export FM_GATE_REFUSE_BYPASS=1

if [ "${FM_CLAUDE_TRUST_DIALOG_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_TRUST_DIALOG_LIVE=1 to run the Claude trust-dialog regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v claude >/dev/null 2>&1 || fail "claude is not installed"
command -v tmux >/dev/null 2>&1 || fail "tmux is not installed"

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
REAL_TMUX=$(command -v tmux)
SOCKET="fm-claude-trust-$$"
SESSION="claudetrust"
LAB="$ROOT/.claude-trust-live-e2e.$$"
PROJECT="$LAB/project"
PROJECT_OTHER="$LAB/project-other"
WT_ONE="$LAB/worktree-one"
WT_TWO="$LAB/worktree-two"
WT_OTHER="$LAB/worktree-other"
FM_TEST_HOME="$LAB/fm-home"
CLAUDE_TEST_CONFIG="$LAB/claude-config"
SHIM="$LAB/shim"
KEY_LOG="$LAB/keys.log"

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$PROJECT" "$FM_TEST_HOME/state" "$FM_TEST_HOME/data" \
  "$FM_TEST_HOME/config" "$CLAUDE_TEST_CONFIG" "$SHIM"
if ! CLAUDE_CONFIG_DIR="$CLAUDE_TEST_CONFIG" claude auth status --json >/dev/null 2>&1; then
  printf 'skip: EVIDENCE_INCOMPLETE - isolated-profile authentication unavailable; Claude %s repository trust not verified here\n' \
    "$CLAUDE_VERSION"
  exit 0
fi
git -C "$PROJECT" init -q --initial-branch=main
git -C "$PROJECT" config user.name fm-live-test
git -C "$PROJECT" config user.email fm-live-test@example.invalid
printf 'fresh trust repository\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -qm baseline
git -C "$PROJECT" worktree add -q -b trust-one "$WT_ONE"
git -C "$PROJECT" worktree add -q -b trust-two "$WT_TWO"
mkdir -p "$PROJECT_OTHER"
git -C "$PROJECT_OTHER" init -q --initial-branch=main
git -C "$PROJECT_OTHER" config user.name fm-live-test
git -C "$PROJECT_OTHER" config user.email fm-live-test@example.invalid
printf 'unrelated fresh trust repository\n' > "$PROJECT_OTHER/README.md"
git -C "$PROJECT_OTHER" add README.md
git -C "$PROJECT_OTHER" commit -qm baseline
git -C "$PROJECT_OTHER" worktree add -q -b trust-control "$WT_OTHER"

cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = send-keys ]; then
  printf '%s\n' "\$*" >> "$KEY_LOG"
fi
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM/tmux"

PATH="$SHIM:$PATH"
export PATH
touch "$FM_TEST_HOME/state/.last-watcher-beat"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -x 220 -y 50 -c "$ROOT" \
  || fail "could not create the private tmux server"

write_task() {
  local id=$1 project=$2 wt=$3 marker=$4 target="$SESSION:fm-$1"
  mkdir -p "$FM_TEST_HOME/data/$id" "$LAB/tasktmp-$id"
  {
    printf '# Claude trust-dialog live brief\n\n'
    printf 'Delivery contract: mode=local-only yolo=off\n\n'
    printf 'Immediately use Bash to run this exact command, then stop: touch %q\n' "$marker"
  } > "$FM_TEST_HOME/data/$id/brief.md"
  {
    printf 'window=%s\n' "$target"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$wt"
    printf 'project=%s\n' "$project"
    printf 'harness=claude\n'
    printf 'kind=ship\n'
    printf 'mode=local-only\n'
    printf 'yolo=off\n'
    printf 'tasktmp=%s\n' "$LAB/tasktmp-$id"
    printf 'model=default\n'
    printf 'effort=default\n'
  } > "$FM_TEST_HOME/state/$id.meta"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "fm-$id" -c "$wt" \
    || fail "$id: could not create the task window"
}

run_spawn() {
  local id=$1 out="$LAB/$1.spawn.out" rc=0
  FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 \
    CLAUDE_CONFIG_DIR="$CLAUDE_TEST_CONFIG" \
    FM_CLAUDE_TRUST_POLLS=80 FM_CLAUDE_TRUST_POLL_INTERVAL=0.5 \
    "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --harness claude > "$out" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$id: visible pane at failure:" >&2
    "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:fm-$id" -S -60 >&2 || true
    fail "$id: fm-spawn failed under Claude $CLAUDE_VERSION: $(tail -1 "$out")"
  fi
}

wait_for_marker() {
  local marker=$1 id=$2 i=0
  while [ "$i" -lt 120 ] && [ ! -e "$marker" ]; do
    i=$((i + 1))
    sleep 1
  done
  [ -e "$marker" ] || fail "$id: Claude $CLAUDE_VERSION never executed the launch brief"
}

FIRST_ID="claude-trust-one-$$"
FIRST_MARKER="$LAB/first-brief-processed"
write_task "$FIRST_ID" "$PROJECT" "$WT_ONE" "$FIRST_MARKER"
run_spawn "$FIRST_ID"
wait_for_marker "$FIRST_MARKER" "$FIRST_ID"
FIRST_KEY_END=$(wc -l < "$KEY_LOG" | tr -d ' ')
FIRST_KEYS=$(sed -n "1,${FIRST_KEY_END}p" "$KEY_LOG")
FIRST_DOWN_COUNT=$(printf '%s\n' "$FIRST_KEYS" | awk '$1 == "send-keys" && NF == 4 && $4 == "Down" { count++ } END { print count + 0 }')
FIRST_ENTER_COUNT=$(printf '%s\n' "$FIRST_KEYS" | awk '$1 == "send-keys" && NF == 4 && $4 == "Enter" { count++ } END { print count + 0 }')
[ "$FIRST_DOWN_COUNT" -ge 1 ] \
  || fail "first fresh-repository spawn never navigated the cancel-focused trust dialog"

SECOND_ID="claude-trust-two-$$"
SECOND_MARKER="$LAB/second-brief-processed"
write_task "$SECOND_ID" "$PROJECT" "$WT_TWO" "$SECOND_MARKER"
run_spawn "$SECOND_ID"
wait_for_marker "$SECOND_MARKER" "$SECOND_ID"
SECOND_KEY_END=$(wc -l < "$KEY_LOG" | tr -d ' ')
SECOND_KEYS=$(sed -n "$((FIRST_KEY_END + 1)),${SECOND_KEY_END}p" "$KEY_LOG")
SECOND_DOWN_COUNT=$(printf '%s\n' "$SECOND_KEYS" | awk '$1 == "send-keys" && NF == 4 && $4 == "Down" { count++ } END { print count + 0 }')
SECOND_ENTER_COUNT=$(printf '%s\n' "$SECOND_KEYS" | awk '$1 == "send-keys" && NF == 4 && $4 == "Enter" { count++ } END { print count + 0 }')
[ "$SECOND_DOWN_COUNT" -eq 0 ] \
  || fail "the second worktree of one trusted repository received a dialog-navigation key"
[ "$SECOND_ENTER_COUNT" -eq "$((FIRST_ENTER_COUNT - 1))" ] \
  || fail "the second worktree received a dialog-accept key despite repository trust"

CONTROL_ID="claude-trust-control-$$"
CONTROL_MARKER="$LAB/control-brief-processed"
write_task "$CONTROL_ID" "$PROJECT_OTHER" "$WT_OTHER" "$CONTROL_MARKER"
run_spawn "$CONTROL_ID"
wait_for_marker "$CONTROL_MARKER" "$CONTROL_ID"
CONTROL_KEY_END=$(wc -l < "$KEY_LOG" | tr -d ' ')
CONTROL_KEYS=$(sed -n "$((SECOND_KEY_END + 1)),${CONTROL_KEY_END}p" "$KEY_LOG")
CONTROL_DOWN_COUNT=$(printf '%s\n' "$CONTROL_KEYS" | awk '$1 == "send-keys" && NF == 4 && $4 == "Down" { count++ } END { print count + 0 }')
[ "$CONTROL_DOWN_COUNT" -ge 1 ] \
  || fail "an unrelated fresh repository did not receive its own trust-dialog navigation"

printf 'ok - Claude %s: fresh trust was accepted and both worktree briefs were processed without human input\n' "$CLAUDE_VERSION"
printf 'ok - Claude %s: the same repository skipped trust while an unrelated repository required it\n' "$CLAUDE_VERSION"
