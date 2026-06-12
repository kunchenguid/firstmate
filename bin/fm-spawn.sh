#!/usr/bin/env bash
# Spawn a crewmate: tmux window -> treehouse worktree subshell -> agent launched with its brief.
# Usage: fm-spawn.sh <task-id> <project-dir> [harness|launch-command] [--scout]
#   With no harness arg, the harness comes from fm-harness.sh crew (config/crew-harness,
#   falling back to firstmate's own harness). A bare adapter name (claude|codex|
#   opencode|pi) overrides it for this spawn. A non-flag string containing whitespace
#   is treated as a RAW launch command - the escape hatch for verifying new adapters.
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md section 7); the default is kind=ship.
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __BRIEF__    absolute path to data/<task-id>/brief.md
#     __TURNEND__  absolute path to state/<task-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex -c notify=[...])
#     __PIEXT__    absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                  written by this script; outside the worktree to avoid pi's trust gate)
# Per-harness turn-end hooks are installed automatically; some live outside the worktree.
# On success prints: spawned <id> harness=<name> kind=<ship|scout> window=<session:window> worktree=<path>
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIND=ship
POS=()
for a in "$@"; do
  case "$a" in
    --scout) KIND=scout ;;
    *) POS+=("$a") ;;
  esac
done
ID=${POS[0]}
PROJ=${POS[1]}
ARG3=${POS[2]:-}

# The verified launch command per adapter. The knowledge half of each adapter
# (busy signature, exit command, dialogs, quirks) lives in AGENTS.md section 4.
launch_template() {
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$1" in
    claude) printf '%s' 'claude --dangerously-skip-permissions "$(cat __BRIEF__)"' ;;
    codex) printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __BRIEF__)"' ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode --prompt "$(cat __BRIEF__)"' ;;
    pi) printf '%s' 'pi -e __PIEXT__ "$(cat __BRIEF__)"' ;;
    *) return 1 ;;
  esac
}

case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    LAUNCH=$ARG3
    HARNESS=""
    for word in $LAUNCH; do
      case "$word" in [A-Za-z_]*=*) continue ;; *) HARNESS=$(basename "$word"); break ;; esac
    done
    ;;
  '')
    HARNESS=$("$FM_ROOT/bin/fm-harness.sh" crew)
    LAUNCH=$(launch_template "$HARNESS") || { echo "error: no launch template for harness '$HARNESS' (from config/crew-harness or detection); pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
  *)
    HARNESS=$ARG3
    LAUNCH=$(launch_template "$HARNESS") || { echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
esac

BRIEF="$FM_ROOT/data/$ID/brief.md"
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }
PROJ_ABS="$(cd "$PROJ" && pwd)"

# Same session when firstmate already runs inside tmux; dedicated session otherwise.
if [ -n "${TMUX:-}" ]; then
  SES=$(tmux display-message -p '#S')
else
  tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
  SES=firstmate
fi

W="fm-$ID"
T="$SES:$W"
if tmux list-windows -t "$SES" -F '#{window_name}' | grep -qx "$W"; then
  echo "error: window $T already exists" >&2
  exit 1
fi

tmux new-window -d -t "$SES" -n "$W" -c "$PROJ_ABS"
tmux send-keys -t "$T" 'treehouse get' Enter

# Wait for the treehouse subshell: the pane's cwd moves from the project to the worktree.
WT=""
for _ in $(seq 1 60); do
  p=$(tmux display-message -p -t "$T" '#{pane_current_path}' 2>/dev/null || true)
  if [ -n "$p" ] && [ "$p" != "$PROJ_ABS" ]; then
    WT="$p"
    break
  fi
  sleep 1
done
if [ -z "$WT" ]; then
  echo "error: treehouse get did not enter a worktree within 60s; inspect window $T" >&2
  exit 1
fi

# Per-harness turn-end hook: a file that touches state/<id>.turn-ended when the
# agent finishes a turn. Worktree-resident hooks are kept out of git's view so
# they never block teardown's dirty check or leak into a commit.
TURNEND="$FM_ROOT/state/$ID.turn-ended"
exclude_path() {
  local rel=$1 EXCL
  EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}
case "$HARNESS" in
  claude*)
    mkdir -p "$WT/.claude"
    cat > "$WT/.claude/settings.local.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$TURNEND'"}]}]}}
EOF
    exclude_path '.claude/settings.local.json'
    ;;
  opencode*)
    mkdir -p "$WT/.opencode/plugins"
    cat > "$WT/.opencode/plugins/fm-turn-end.js" <<EOF
export const FmTurnEnd = async ({ \$ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") await \$\`touch $TURNEND\`
  },
})
EOF
    exclude_path '.opencode/plugins/fm-turn-end.js'
    ;;
  pi*)
    # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
    # loaded from inside the project (verified live), but an explicit -e path
    # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
    cat > "$FM_ROOT/state/$ID.pi-ext.ts" <<EOF
// Firstmate turn-end signal; written by fm-spawn.
import { execFile } from "node:child_process";
export default function (pi: any) {
  pi.on("agent_end", () => execFile("touch", ["$TURNEND"]));
}
EOF
    ;;
  codex*)
    # codex: turn-end rides the launch command via -c notify=[...] and __TURNEND__.
    ;;
esac

mkdir -p "$FM_ROOT/state"
{
  echo "window=$T"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
} > "$FM_ROOT/state/$ID.meta"

LAUNCH=${LAUNCH//__BRIEF__/$BRIEF}
LAUNCH=${LAUNCH//__TURNEND__/$TURNEND}
LAUNCH=${LAUNCH//__PIEXT__/$FM_ROOT/state/$ID.pi-ext.ts}
tmux send-keys -t "$T" -l "$LAUNCH"
sleep 0.3
tmux send-keys -t "$T" Enter

echo "spawned $ID harness=$HARNESS kind=$KIND window=$T worktree=$WT"
