#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a treehouse worktree or OpenCode server
# worktree, or a secondmate in its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> [harness|launch-command] [--scout]
#        fm-spawn.sh <task-id> [<firstmate-home>] [harness|launch-command] --secondmate
#   With no harness arg, opencode-server uses opencode; otherwise the harness comes
#   from fm-harness.sh crew (config/crew-harness, falling back to firstmate's own
#   harness). A bare adapter name (claude|codex|opencode|pi) overrides it for this
#   spawn. On the tmux backend, a non-flag string containing whitespace is
#   treated as a RAW launch command - the escape hatch for verifying new adapters.
#   Set FM_BACKEND=opencode-server (or config/backend(.env)) to run ordinary
#   opencode tasks through an API-backed OpenCode server instead of a tmux pane.
#   The default backend is tmux, and secondmates always use tmux.
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md section 7); --secondmate records kind=secondmate and launches in a
#   provisioned firstmate home; the default is kind=ship.
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     fm-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; a shared --scout applies to every pair. The loop lives here, in bash,
#   so callers never hand-write a multi-task shell loop (the tool shell is zsh, which does
#   not word-split unquoted $vars and silently breaks ad-hoc `for ... in $pairs` loops).
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __BRIEF__    absolute path to data/<task-id>/brief.md
#     __TURNEND__  absolute path to state/<task-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex -c notify=[...])
#     __PIEXT__    absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                  written by this script; outside the worktree to avoid pi's trust gate)
# Per-harness turn-end hooks are installed automatically; some live outside the worktree.
# On success prints: spawned <id> [backend=<backend>] harness=<name> kind=<ship|scout|secondmate> mode=<mode> yolo=<on|off> window=<session:window|session-title> worktree=<path> [session=<opencode-session-id> server=<url>]
# mode/yolo are resolved per-project from data/projects.md for ship/scout tasks;
# secondmate spawns record mode=secondmate, yolo=off, home=, and projects=.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SUB_HOME_MARKER=".fm-secondmate-home"
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
POS=()
for a in "$@"; do
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    *) POS+=("$a") ;;
  esac
done

# Batch dispatch (see header): when the first positional is an `id=repo` pair, treat every
# positional as one and spawn each by re-execing this script in single-task mode. We use
# the FM_ROOT path (not $0) so it works whatever cwd or relative path invoked us, and reuse
# the single path verbatim. A failed pair is reported and skipped; the rest still launch;
# exit is non-zero if any pair failed. Single-task invocations never carry an '=' in arg
# one (task ids are bare slugs), so they fall straight through to the logic below.
idpart=${POS[0]:-}
idpart=${idpart%%=*}
if [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ] && case "$idpart" in */*) false ;; *) true ;; esac; then
  rc=0
  for pair in "${POS[@]}"; do
    case "$pair" in
      *=*) : ;;
      *) echo "error: batch dispatch expects every argument as id=repo; got '$pair'" >&2; rc=2; continue ;;
    esac
    if [ "$KIND" = secondmate ]; then
      echo "error: batch dispatch does not support --secondmate; spawn each secondmate explicitly" >&2
      rc=2
      continue
    elif [ "$KIND" = scout ]; then
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" --scout; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    else
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}"; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    fi
  done
  exit "$rc"
fi
ID=${POS[0]}
PROJ=
ARG3=
FIRSTMATE_HOME=

if [ "$KIND" = secondmate ]; then
  case "${POS[1]:-}" in
    ''|claude|codex|opencode|pi)
      ARG3=${POS[1]:-}
      ;;
    *' '*)
      if [ "${#POS[@]}" -gt 2 ] || [ -d "${POS[1]}" ]; then
        FIRSTMATE_HOME=${POS[1]}
        ARG3=${POS[2]:-}
      else
        ARG3=${POS[1]}
      fi
      ;;
    *)
      FIRSTMATE_HOME=${POS[1]}
      ARG3=${POS[2]:-}
      ;;
  esac
else
  PROJ=${POS[1]}
  ARG3=${POS[2]:-}
fi

# The verified launch command per adapter. The knowledge half of each adapter
# (busy signature, exit command, dialogs, quirks) lives in AGENTS.md section 4.
launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$harness" in
    claude) printf '%s' 'claude --dangerously-skip-permissions "$(cat __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox "$(cat __BRIEF__)"'
      else
        printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode --prompt "$(cat __BRIEF__)"' ;;
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'pi "$(cat __BRIEF__)"'
      else
        printf '%s' 'pi -e __PIEXT__ "$(cat __BRIEF__)"'
      fi
      ;;
    *) return 1 ;;
  esac
}

backend_name() {
  local line cfg
  if [ -n "${FM_BACKEND:-}" ]; then
    printf '%s\n' "$FM_BACKEND"
    return 0
  fi
  if [ -f "$CONFIG/backend" ]; then
    cfg=$(tr -d '[:space:]' < "$CONFIG/backend" || true)
    [ -n "$cfg" ] && { printf '%s\n' "$cfg"; return 0; }
  fi
  if [ -f "$CONFIG/backend.env" ]; then
    line=$(grep -E '^[[:space:]]*FM_BACKEND=' "$CONFIG/backend.env" 2>/dev/null | tail -1 || true)
    line=${line#*=}
    line=${line%\"}; line=${line#\"}
    line=${line%\'}; line=${line#\'}
    line=$(printf '%s' "$line" | tr -d '[:space:]')
    [ -n "$line" ] && { printf '%s\n' "$line"; return 0; }
  fi
  printf '%s\n' tmux
}

BACKEND=$(backend_name)
[ "$KIND" = secondmate ] && BACKEND=tmux

case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    LAUNCH=$ARG3
    HARNESS=""
    for word in $LAUNCH; do
      case "$word" in [A-Za-z_]*=*) continue ;; *) HARNESS=$(basename "$word"); break ;; esac
    done
    ;;
  '')
    if [ "$BACKEND" = opencode-server ]; then
      HARNESS=opencode
    else
      HARNESS=$("$FM_ROOT/bin/fm-harness.sh" crew)
    fi
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: no launch template for harness '$HARNESS' (from config/crew-harness or detection); pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
  *)
    HARNESS=$ARG3
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
esac

secondmate_registry_value() {
  local id=$1 key=$2 reg line value
  reg="$DATA/secondmates.md"
  [ -f "$reg" ] || return 1
  line=$(grep -E "^- $id( |$)" "$reg" | tail -1 || true)
  [ -n "$line" ] || return 1
  case "$key" in
    home) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p') ;;
    projects) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: [^;)]*; scope: [^;)]*; projects: \([^;)]*\); added .*/\1/p') ;;
    *) return 1 ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: firstmate home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

resolve_project_dir_arg() {
  local path=$1
  case "$path" in
    projects/*) printf '%s/%s\n' "$PROJECTS" "${path#projects/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

git_worktree_base() {
  local repo=$1 ref branch
  ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "$ref"
    return 0
  fi
  for branch in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      printf 'origin/%s\n' "$branch"
      return 0
    fi
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  git -C "$repo" rev-parse --verify HEAD 2>/dev/null
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

validate_firstmate_home_for_spawn() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_firstmate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_firstmate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

if [ "$KIND" = secondmate ]; then
  if [ -z "$FIRSTMATE_HOME" ] && [ -f "$STATE/$ID.meta" ]; then
    FIRSTMATE_HOME=$(grep '^home=' "$STATE/$ID.meta" | cut -d= -f2- || true)
  fi
  if [ -z "$FIRSTMATE_HOME" ]; then
    FIRSTMATE_HOME=$(secondmate_registry_value "$ID" home || true)
  fi
fi

if [ "$KIND" = secondmate ]; then
  [ -n "$FIRSTMATE_HOME" ] || { echo "error: no firstmate home supplied or registered for $ID" >&2; exit 1; }
  PROJ_ABS=$(validate_firstmate_home_for_spawn "$ID" "$FIRSTMATE_HOME")
  WT="$PROJ_ABS"
  if [ -f "$PROJ_ABS/data/charter.md" ]; then
    BRIEF="$PROJ_ABS/data/charter.md"
  else
    BRIEF="$DATA/$ID/brief.md"
  fi
else
  PROJ_ABS="$(cd "$(resolve_project_dir_arg "$PROJ")" && pwd)"
  WT=""
  BRIEF="$DATA/$ID/brief.md"
fi
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }

case "$BACKEND" in
  tmux|opencode-server) ;;
  *) echo "error: unknown FM_BACKEND '$BACKEND' (expected tmux or opencode-server)" >&2; exit 1 ;;
esac

OPENCODE_SERVER_URL=""
OPENCODE_SERVER_PID=""
OPENCODE_SERVER_LOG=""
OPENCODE_SERVER_USERNAME=""
OPENCODE_SERVER_PASSWORD=""
OPENCODE_SESSION_ID=""
OPENCODE_SESSION_TITLE=""
OPENCODE_SESSION_STATE=""
OPENCODE_VISIBILITY=""
OPENCODE_WEB=""
OPENCODE_WEB_URL=""
OPENCODE_DESKTOP=""
OPENCODE_DESKTOP_DEEPLINK=""
OPENCODE_DESKTOP_APP=""
OPENCODE_DESKTOP_COMMAND=""

W="fm-$ID"
T=""
if [ "$BACKEND" = opencode-server ]; then
  command -v opencode >/dev/null || { echo "error: FM_BACKEND=opencode-server but opencode is not installed" >&2; exit 1; }
  case "$ARG3" in
    *' '*) echo "error: FM_BACKEND=opencode-server does not support raw launch commands; use the opencode harness" >&2; exit 1 ;;
  esac
  case "$HARNESS" in
    opencode*) ;;
    *) echo "error: FM_BACKEND=opencode-server supports only the opencode harness (got '$HARNESS')" >&2; exit 1 ;;
  esac
  mkdir -p "$STATE/opencode-server-worktrees"
  WT="$STATE/opencode-server-worktrees/$ID"
  [ ! -e "$WT" ] || { echo "error: OpenCode server worktree already exists: $WT" >&2; exit 1; }
  BASE=$(git_worktree_base "$PROJ_ABS")
  git -C "$PROJ_ABS" worktree add --detach "$WT" "$BASE" >/dev/null
  T="$W"
else
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
  if [ "$KIND" != secondmate ]; then
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
  fi
fi

# Per-harness turn-end hook: a file that touches state/<id>.turn-ended when the
# agent finishes a turn. Worktree-resident hooks are kept out of git's view so
# they never block teardown's dirty check or leak into a commit.
TURNEND="$STATE/$ID.turn-ended"
exclude_path() {
  local rel=$1 EXCL
  EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}
if [ "$KIND" != secondmate ]; then
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
      cat > "$STATE/$ID.pi-ext.ts" <<EOF
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
fi

# Per-project delivery mode + yolo flag (bin/fm-project-mode.sh; AGENTS.md sections 6-7).
# Recorded in meta so fm-teardown's safety check and the validate/merge stages can
# branch on them. Mode governs ship tasks; a scout's deliverable is a report, not a
# merge, so scout teardown ignores mode.
SECONDMATE_PROJECTS=
if [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
  SECONDMATE_PROJECTS=$(secondmate_registry_value "$ID" projects || true)
else
  PROJ_NAME=$(basename "$PROJ_ABS")
  read -r MODE YOLO <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$PROJ_NAME")
EOF
fi

if [ "$BACKEND" = opencode-server ]; then
  if ! opencode_start=$("$FM_ROOT/bin/fm-opencode-server" start "$ID" "$W" "$WT" "$BRIEF"); then
    git -C "$PROJ_ABS" worktree remove --force "$WT" >/dev/null 2>&1 || true
    exit 1
  fi
  opencode_value() { printf '%s\n' "$opencode_start" | grep "^$1=" | tail -1 | cut -d= -f2- || true; }
  OPENCODE_SERVER_URL=$(opencode_value opencode_server_url)
  OPENCODE_SERVER_PID=$(opencode_value opencode_server_pid)
  OPENCODE_SERVER_LOG=$(opencode_value opencode_server_log)
  OPENCODE_SERVER_USERNAME=$(opencode_value opencode_server_username)
  OPENCODE_SERVER_PASSWORD=$(opencode_value opencode_server_password)
  OPENCODE_SESSION_ID=$(opencode_value opencode_session_id)
  OPENCODE_SESSION_TITLE=$(opencode_value opencode_session_title)
  OPENCODE_SESSION_STATE=$(opencode_value opencode_session_state)
  OPENCODE_VISIBILITY=$(opencode_value opencode_visibility)
  OPENCODE_WEB=$(opencode_value opencode_web)
  OPENCODE_WEB_URL=$(opencode_value opencode_web_url)
  OPENCODE_DESKTOP=$(opencode_value opencode_desktop)
  OPENCODE_DESKTOP_DEEPLINK=$(opencode_value opencode_desktop_deeplink)
  OPENCODE_DESKTOP_APP=$(opencode_value opencode_desktop_app)
  OPENCODE_DESKTOP_COMMAND=$(opencode_value opencode_desktop_command)
  [ -n "$OPENCODE_SERVER_URL" ] || { echo "error: OpenCode server helper did not return opencode_server_url" >&2; exit 1; }
  [ -n "$OPENCODE_SESSION_ID" ] || { echo "error: OpenCode server helper did not return opencode_session_id" >&2; exit 1; }
fi

mkdir -p "$STATE"
{
  echo "backend=$BACKEND"
  echo "window=$T"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  if [ "$KIND" = secondmate ]; then
    echo "home=$PROJ_ABS"
    echo "projects=$SECONDMATE_PROJECTS"
  fi
  [ -n "$OPENCODE_SERVER_URL" ] && echo "opencode_server_url=$OPENCODE_SERVER_URL"
  [ -n "$OPENCODE_SERVER_PID" ] && echo "opencode_server_pid=$OPENCODE_SERVER_PID"
  [ -n "$OPENCODE_SERVER_LOG" ] && echo "opencode_server_log=$OPENCODE_SERVER_LOG"
  [ -n "$OPENCODE_SERVER_USERNAME" ] && echo "opencode_server_username=$OPENCODE_SERVER_USERNAME"
  [ -n "$OPENCODE_SERVER_PASSWORD" ] && echo "opencode_server_password=$OPENCODE_SERVER_PASSWORD"
  [ -n "$OPENCODE_SESSION_ID" ] && echo "opencode_session_id=$OPENCODE_SESSION_ID"
  [ -n "$OPENCODE_SESSION_TITLE" ] && echo "opencode_session_title=$OPENCODE_SESSION_TITLE"
  [ -n "$OPENCODE_SESSION_STATE" ] && echo "opencode_session_state=$OPENCODE_SESSION_STATE"
  [ -n "$OPENCODE_VISIBILITY" ] && echo "opencode_visibility=$OPENCODE_VISIBILITY"
  [ -n "$OPENCODE_WEB" ] && echo "opencode_web=$OPENCODE_WEB"
  [ -n "$OPENCODE_WEB_URL" ] && echo "opencode_web_url=$OPENCODE_WEB_URL"
  [ -n "$OPENCODE_DESKTOP" ] && echo "opencode_desktop=$OPENCODE_DESKTOP"
  [ -n "$OPENCODE_DESKTOP_DEEPLINK" ] && echo "opencode_desktop_deeplink=$OPENCODE_DESKTOP_DEEPLINK"
  [ -n "$OPENCODE_DESKTOP_APP" ] && echo "opencode_desktop_app=$OPENCODE_DESKTOP_APP"
  [ -n "$OPENCODE_DESKTOP_COMMAND" ] && echo "opencode_desktop_command=$OPENCODE_DESKTOP_COMMAND"
} > "$STATE/$ID.meta"

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}
if [ "$KIND" = secondmate ]; then
  sq_home=$(shell_quote "$PROJ_ABS")
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME=$sq_home $LAUNCH"
fi
if [ "$BACKEND" = tmux ]; then
  tmux send-keys -t "$T" -l "$LAUNCH"
  sleep 0.3
  tmux send-keys -t "$T" Enter
fi

if [ "$BACKEND" = opencode-server ]; then
  echo "spawned $ID backend=$BACKEND harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO window=$T worktree=$WT session=$OPENCODE_SESSION_ID server=$OPENCODE_SERVER_URL"
else
  echo "spawned $ID harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO window=$T worktree=$WT"
fi
