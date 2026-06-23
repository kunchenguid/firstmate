#!/usr/bin/env bash
# Spawn a crewmate or prepare a visible Codex App thread handoff.
# Usage: fm-spawn.sh <task-id> <project-dir> [harness|launch-command] [--scout]
#   With no harness arg, the harness comes from fm-harness.sh crew (config/crew-harness,
#   falling back to firstmate's own harness). A bare adapter name (claude|codex|
#   opencode|pi) overrides it for this spawn. On the tmux backend only, a
#   non-flag string containing whitespace is treated as a RAW launch command -
#   the escape hatch for verifying new adapters.
#   FM_BACKEND=codex-app supports only the codex harness and prepares app-owned
#   visible thread metadata; the firstmate must create/fork/send through Codex
#   Desktop host tools, then record the returned thread id.
#   FM_BACKEND=opencode-server supports only the opencode harness and starts one
#   headless OpenCode server per task worktree.
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md section 7); the default is kind=ship.
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __BRIEF__    absolute path to data/<task-id>/brief.md
#     __TURNEND__  absolute path to state/<task-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex -c notify=[...])
#     __PIEXT__    absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                  written by this script; outside the worktree to avoid pi's trust gate)
# Per-harness turn-end hooks are installed automatically; some live outside the worktree.
# On success prints either spawned <id> ... worktree=<path>, or prepared <id> ...
# with the Codex App host-tool action needed to create/fork the visible thread.
# mode/yolo are resolved per-project from data/projects.md via fm-project-mode.sh.
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$FM_ROOT/bin/fm-backend.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
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
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate shell, not here
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
BACKEND=$(fm_backend_name)

W="fm-$ID"
T=""
WT=""
ORCA_WORKTREE_ID=""
ORCA_TERMINAL=""
CODEX_APP_THREAD_ID=""
CODEX_APP_TURN_ID=""
CODEX_APP_PENDING_ACTION=""
OPENCODE_SERVER_URL=""
OPENCODE_SERVER_PID=""
OPENCODE_SERVER_LOG=""
OPENCODE_SESSION_ID=""
OPENCODE_SESSION_TITLE=""
OPENCODE_SESSION_STATE=""
TURNEND="$FM_ROOT/state/$ID.turn-ended"
PIEXT="$FM_ROOT/state/$ID.pi-ext.ts"

git_worktree_base() {
  local repo=$1 ref branch
  ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "$ref"
    return 0
  fi
  for branch in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      echo "origin/$branch"
      return 0
    fi
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  git -C "$repo" rev-parse --verify HEAD 2>/dev/null
}

case "$BACKEND" in
  tmux)
    # Same session when firstmate already runs inside tmux; dedicated session otherwise.
    if [ -n "${TMUX:-}" ]; then
      SES=$(tmux display-message -p '#S')
    else
      tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
      SES=firstmate
    fi

    T="$SES:$W"
    if tmux list-windows -t "$SES" -F '#{window_name}' | grep -qx "$W"; then
      echo "error: window $T already exists" >&2
      exit 1
    fi

    tmux new-window -d -t "$SES" -n "$W" -c "$PROJ_ABS"
    tmux send-keys -t "$T" 'treehouse get' Enter

    # Wait for the treehouse subshell: the pane's cwd moves from the project to the worktree.
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
    ;;
  orca)
    command -v orca >/dev/null || { echo "error: FM_BACKEND=orca but orca is not installed" >&2; exit 1; }
    case "$ARG3" in
      *' '*) echo "error: FM_BACKEND=orca does not support raw launch commands yet; use a verified harness name" >&2; exit 1 ;;
    esac
    orca repo add --path "$PROJ_ABS" --json >/dev/null 2>&1 || true
    create_json=$(mktemp "${TMPDIR:-/tmp}/fm-orca-create.XXXXXX")
    if ! orca worktree create --repo "path:$PROJ_ABS" --name "$W" --setup skip --no-parent --json > "$create_json"; then
      cat "$create_json" >&2
      rm -f "$create_json"
      exit 1
    fi
    IFS=$(printf '\t') read -r ORCA_WORKTREE_ID WT ORCA_TERMINAL <<EOF
$(fm_backend_parse_worktree_create < "$create_json")
EOF
    rm -f "$create_json"
    [ -n "$ORCA_WORKTREE_ID" ] || { echo "error: Orca did not return a worktree id" >&2; exit 1; }
    if [ -z "$WT" ]; then
      WT=$(orca worktree show --worktree "id:$ORCA_WORKTREE_ID" --json | fm_backend_json_get result.worktree.path)
    fi
    [ -n "$WT" ] || { echo "error: Orca did not return a worktree path" >&2; exit 1; }
    T="$W"
    ;;
  codex-app)
    case "$ARG3" in
      *' '*) echo "error: FM_BACKEND=codex-app does not support raw launch commands; use the codex harness" >&2; exit 1 ;;
    esac
    case "$HARNESS" in
      codex*) ;;
      *) echo "error: FM_BACKEND=codex-app supports only the codex harness (got '$HARNESS')" >&2; exit 1 ;;
    esac
    T="$W"
    WT=""
    CODEX_APP_PENDING_ACTION=create_thread_or_fork_thread
    ;;
  opencode-server)
    command -v opencode >/dev/null || { echo "error: FM_BACKEND=opencode-server but opencode is not installed" >&2; exit 1; }
    case "$ARG3" in
      *' '*) echo "error: FM_BACKEND=opencode-server does not support raw launch commands; use the opencode harness" >&2; exit 1 ;;
    esac
    case "$HARNESS" in
      opencode*) ;;
      *) echo "error: FM_BACKEND=opencode-server supports only the opencode harness (got '$HARNESS')" >&2; exit 1 ;;
    esac
    mkdir -p "$FM_ROOT/state/opencode-server-worktrees"
    WT="$FM_ROOT/state/opencode-server-worktrees/$ID"
    [ ! -e "$WT" ] || { echo "error: OpenCode server worktree already exists: $WT" >&2; exit 1; }
    BASE=$(git_worktree_base "$PROJ_ABS")
    git -C "$PROJ_ABS" worktree add --detach "$WT" "$BASE" >/dev/null
    T="$W"
    ;;
  *) echo "error: unknown FM_BACKEND '$BACKEND' (expected tmux, orca, codex-app, or opencode-server)" >&2; exit 1 ;;
esac

# Per-harness turn-end hook: a file that touches state/<id>.turn-ended when the
# agent finishes a turn. Worktree-resident hooks are kept out of git's view so
# they never block teardown's dirty check or leak into a commit.
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
    if [ "$BACKEND" != opencode-server ]; then
      mkdir -p "$WT/.opencode/plugins"
      cat > "$WT/.opencode/plugins/fm-turn-end.js" <<EOF
export const FmTurnEnd = async ({ \$ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") await \$\`touch $TURNEND\`
  },
})
EOF
      exclude_path '.opencode/plugins/fm-turn-end.js'
    fi
    ;;
  pi*)
    # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
    # loaded from inside the project (verified live), but an explicit -e path
    # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
    cat > "$PIEXT" <<EOF
// Firstmate turn-end signal; written by fm-spawn.
// Use "turn_end" (fires after each turn the agent finishes), not "agent_end"
// (fires once, only when the whole run exits): the watcher needs a signal at
// every turn boundary so an idle crewmate is surfaced, not just at shutdown.
import { execFile } from "node:child_process";
export default function (pi: any) {
  pi.on("turn_end", () => execFile("touch", ["$TURNEND"]));
}
EOF
    ;;
  codex*)
    # codex: turn-end rides the launch command via -c notify=[...] and __TURNEND__.
    ;;
esac

LAUNCH=${LAUNCH//__BRIEF__/$BRIEF}
LAUNCH=${LAUNCH//__TURNEND__/$TURNEND}
LAUNCH=${LAUNCH//__PIEXT__/$PIEXT}

if [ "$BACKEND" = orca ]; then
  case "$HARNESS" in
    codex*)
      if [ "${FM_ORCA_CODEX_AUTO_TRUST:-0}" = 1 ]; then
        fm_backend_trust_codex_project "$WT"
      fi
      ;;
  esac
  terminal_json=$(mktemp "${TMPDIR:-/tmp}/fm-orca-terminal.XXXXXX")
  if ! orca terminal create --worktree "id:$ORCA_WORKTREE_ID" --title "$W" --json > "$terminal_json"; then
    cat "$terminal_json" >&2
    rm -f "$terminal_json"
    exit 1
  fi
  IFS=$(printf '\t') read -r _unused_id _unused_path ORCA_TERMINAL <<EOF
$(fm_backend_parse_worktree_create < "$terminal_json")
EOF
  rm -f "$terminal_json"
  if [ -z "$ORCA_TERMINAL" ]; then
    for _ in $(seq 1 30); do
      ORCA_TERMINAL=$(orca terminal list --worktree "id:$ORCA_WORKTREE_ID" --json | fm_backend_first_terminal)
      [ -n "$ORCA_TERMINAL" ] && break
      sleep 1
    done
  fi
  [ -n "$ORCA_TERMINAL" ] || { echo "error: Orca did not return a terminal handle" >&2; exit 1; }
fi

if [ "$BACKEND" = opencode-server ]; then
  if ! opencode_start=$("$FM_ROOT/bin/fm-opencode-server" start "$ID" "$W" "$WT" "$BRIEF"); then
    git -C "$PROJ_ABS" worktree remove --force "$WT" >/dev/null 2>&1 || true
    exit 1
  fi
  opencode_value() { printf '%s\n' "$opencode_start" | grep "^$1=" | tail -1 | cut -d= -f2-; }
  OPENCODE_SERVER_URL=$(opencode_value opencode_server_url)
  OPENCODE_SERVER_PID=$(opencode_value opencode_server_pid)
  OPENCODE_SERVER_LOG=$(opencode_value opencode_server_log)
  OPENCODE_SESSION_ID=$(opencode_value opencode_session_id)
  OPENCODE_SESSION_TITLE=$(opencode_value opencode_session_title)
  OPENCODE_SESSION_STATE=$(opencode_value opencode_session_state)
  [ -n "$OPENCODE_SERVER_URL" ] || { echo "error: OpenCode server helper did not return opencode_server_url" >&2; exit 1; }
  [ -n "$OPENCODE_SESSION_ID" ] || { echo "error: OpenCode server helper did not return opencode_session_id" >&2; exit 1; }
fi

# Per-project delivery mode + yolo flag (bin/fm-project-mode.sh; AGENTS.md sections 6-7).
# Recorded in meta so fm-teardown's safety check and the validate/merge stages can
# branch on them. Mode governs ship tasks; a scout's deliverable is a report, not a
# merge, so scout teardown ignores mode.
PROJ_NAME=$(basename "$PROJ_ABS")
read -r MODE YOLO <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$PROJ_NAME")
EOF

mkdir -p "$FM_ROOT/state"
{
  echo "backend=$BACKEND"
  echo "window=$T"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  [ -n "$ORCA_WORKTREE_ID" ] && echo "orca_worktree_id=$ORCA_WORKTREE_ID"
  [ -n "$ORCA_TERMINAL" ] && echo "terminal=$ORCA_TERMINAL"
  [ -n "$CODEX_APP_THREAD_ID" ] && echo "thread_id=$CODEX_APP_THREAD_ID"
  [ -n "$CODEX_APP_TURN_ID" ] && echo "turn_id=$CODEX_APP_TURN_ID"
  [ "$BACKEND" = codex-app ] && echo "codex_app_thread_state=pending"
  [ "$BACKEND" = codex-app ] && echo "codex_app_pending_action=$CODEX_APP_PENDING_ACTION"
  [ "$BACKEND" = codex-app ] && echo "codex_app_transport=visible-thread"
  [ "$BACKEND" = codex-app ] && echo "codex_app_brief=$BRIEF"
  [ -n "$OPENCODE_SERVER_URL" ] && echo "opencode_server_url=$OPENCODE_SERVER_URL"
  [ -n "$OPENCODE_SERVER_PID" ] && echo "opencode_server_pid=$OPENCODE_SERVER_PID"
  [ -n "$OPENCODE_SERVER_LOG" ] && echo "opencode_server_log=$OPENCODE_SERVER_LOG"
  [ -n "$OPENCODE_SESSION_ID" ] && echo "opencode_session_id=$OPENCODE_SESSION_ID"
  [ -n "$OPENCODE_SESSION_TITLE" ] && echo "opencode_session_title=$OPENCODE_SESSION_TITLE"
  [ -n "$OPENCODE_SESSION_STATE" ] && echo "opencode_session_state=$OPENCODE_SESSION_STATE"
} > "$FM_ROOT/state/$ID.meta"

if [ "$BACKEND" = tmux ]; then
  tmux send-keys -t "$T" -l "$LAUNCH"
  sleep 0.3
  tmux send-keys -t "$T" Enter
elif [ "$BACKEND" = orca ]; then
  orca terminal send --terminal "$ORCA_TERMINAL" --text "$LAUNCH" --enter --json >/dev/null
  case "$HARNESS" in
    codex*)
      for _ in $(seq 1 20); do
        tail=$(fm_backend_orca_terminal_text "$ORCA_TERMINAL" 30 || true)
        if printf '%s\n' "$tail" | grep -q 'Hooks need review' \
          && printf '%s\n' "$tail" | grep -q 'Trust.*continue'; then
          orca terminal send --terminal "$ORCA_TERMINAL" --text "2" --enter --json >/dev/null
          break
        fi
        if printf '%s\n' "$tail" | grep -q 'esc to interrupt'; then
          break
        fi
        sleep 1
      done
      ;;
  esac
fi

if [ "$BACKEND" = codex-app ]; then
  "$FM_ROOT/bin/fm-codex-app" prepare "$ID" "$W" "$BRIEF" >/dev/null
  echo "prepared $ID backend=$BACKEND harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO window=$T"
  echo "next: use Codex App create_thread or fork_thread for $W, send the brief at $BRIEF, then run:"
  echo "      bin/fm-codex-app record-thread $ID <thread-id> [--worktree <path>] [--pending-worktree-id <id>]"
elif [ "$BACKEND" = opencode-server ]; then
  echo "spawned $ID backend=$BACKEND harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO window=$T worktree=$WT session=$OPENCODE_SESSION_ID server=$OPENCODE_SERVER_URL"
else
  echo "spawned $ID backend=$BACKEND harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO window=$T worktree=$WT"
fi
