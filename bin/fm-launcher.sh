#!/usr/bin/env bash
# firstmate launcher — `firstmate [harness|command] [extra args...]`
# Canonical copy of ~/.local/bin/firstmate. Starts the primary session from the
# firstmate home. Does not auto-register projects and does not launch from
# reserved container directories under the home.
#
#   firstmate           -> firstmate opencode (or default)
#   firstmate codex     -> FM_BACKEND=herdr codex
#   firstmate doctor    -> system, daemon & network health diagnostics
#   firstmate repair    -> dead-PID session lock GC and conservative state cleanup
#   firstmate hygiene   -> worktree & branch hygiene check (report-only)
#   firstmate prune     -> conservative prune; never deletes worktrees
# Env overrides: FM_HOME_DIR (default ~/firstmate), FM_BACKEND (default herdr).
set -euo pipefail

FM_HOME_DIR="${FM_HOME_DIR:-$HOME/firstmate}"
BACKEND="${FM_BACKEND:-herdr}"
HARNESS="${1:-opencode}"
if [ $# -gt 0 ]; then shift; fi

case "$HARNESS" in
  -h|--help|help)
    echo "usage: firstmate [harness|command] [args...]"
    echo ""
    echo "harnesses: opencode (default), codex, pi, claude, grok, cursor-agent, omp"
    echo "commands:"
    echo "  doctor          Run system, daemon & environment health diagnostics"
    echo "  repair          Repair dead-PID session locks and leftover temp/lease files"
    echo "  hygiene         Check worktree hygiene, unmerged branches, and stale sessions"
    echo "  prune           Conservative state cleanup; never deletes worktrees or Treehouse"
    echo "  merge <task-id> Merge local-only ship task to main and trigger clean teardown"
    echo ""
    echo "Launch the primary from $FM_HOME_DIR or a specific project checkout."
    echo "Rejected launch directories: \$HOME, /, ~/Desktop, ~/Desktop/projects."
    echo "env: FM_HOME_DIR (default ~/firstmate), FM_BACKEND (default herdr)"
    exit 0 ;;
esac

case "$HARNESS" in
  doctor)
    exec "$FM_HOME_DIR/bin/fm-hygiene.sh" --doctor "$@"
    ;;
  repair)
    exec "$FM_HOME_DIR/bin/fm-hygiene.sh" --repair "$@"
    ;;
  hygiene)
    exec "$FM_HOME_DIR/bin/fm-hygiene.sh" --check "$@"
    ;;
  prune)
    exec "$FM_HOME_DIR/bin/fm-hygiene.sh" --prune "$@"
    ;;
  merge)
    exec "$FM_HOME_DIR/bin/fm-merge-local.sh" "$@"
    ;;
esac

CURRENT_DIR="$(pwd)"
PHYSICAL_DIR="$(pwd -P 2>/dev/null || echo "$CURRENT_DIR")"

is_forbidden_launch_dir() {
  local dir="$1"
  [ "$dir" = "$FM_HOME_DIR" ] && return 1
  case "$dir" in
    "$HOME"|"/"|"$HOME/Desktop"|"$HOME/Desktop/projects"|"$HOME/projects"|"$HOME/workspace")
      return 0 ;;
  esac
  return 1
}

if is_forbidden_launch_dir "$CURRENT_DIR" || is_forbidden_launch_dir "$PHYSICAL_DIR"; then
  echo "firstmate: refusing to launch a primary session from $CURRENT_DIR" >&2
  echo "Start from the firstmate home:" >&2
  echo "  cd $FM_HOME_DIR && firstmate ${HARNESS}" >&2
  echo "Or from a specific project checkout (not ~/Desktop/projects itself)." >&2
  exit 1
fi

DETECTED_PROJECT=""
is_git_or_project_dir() {
  local dir="$1"
  [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || [ -f "$dir/package.json" ] || [ -f "$dir/pyproject.toml" ] || [ -f "$dir/Cargo.toml" ] || [ -f "$dir/go.mod" ]
}

if [ "$CURRENT_DIR" != "$FM_HOME_DIR" ] && is_git_or_project_dir "$CURRENT_DIR"; then
  DETECTED_PROJECT="$(basename "$CURRENT_DIR")"
elif [ "$PHYSICAL_DIR" != "$FM_HOME_DIR" ] && is_git_or_project_dir "$PHYSICAL_DIR"; then
  DETECTED_PROJECT="$(basename "$PHYSICAL_DIR")"
fi

if [ -n "$DETECTED_PROJECT" ] && [ "$CURRENT_DIR" != "$FM_HOME_DIR" ]; then
  echo "firstmate: detected project '$DETECTED_PROJECT' at $CURRENT_DIR (not auto-registered)"
  echo "firstmate: primary still starts in $FM_HOME_DIR; spawn a worker to edit this repo."
fi

case "$HARNESS" in
  claude|grok|pi|pi-signed|codex|opencode|omp) BIN="$HARNESS" ;;
  cursor|cursor-agent) BIN="cursor-agent" ;;
  *)
    echo "firstmate: unknown harness or command '$HARNESS'" >&2
    echo "try: firstmate opencode | codex | pi | claude | grok | cursor-agent | doctor | repair | hygiene | prune" >&2
    exit 1 ;;
esac

if [ ! -f "$FM_HOME_DIR/AGENTS.md" ]; then
  echo "firstmate: no firstmate home at $FM_HOME_DIR (expected AGENTS.md there)" >&2
  exit 1
fi
if ! command -v "$BIN" >/dev/null 2>&1; then
  echo "firstmate: harness binary '$BIN' not on PATH" >&2
  exit 1
fi

if [ -f "$FM_HOME_DIR/bin/fm-session-lock-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$FM_HOME_DIR/bin/fm-session-lock-lib.sh"
  fm_session_lock_gc "$FM_HOME_DIR/state" || true
fi

echo "==================================================================="
echo " Firstmate launcher"
echo " Harness: $BIN"
echo " Backend: $BACKEND"
echo " Home:    $FM_HOME_DIR"
if [ -n "$DETECTED_PROJECT" ]; then
  echo " Cwd:     $DETECTED_PROJECT ($CURRENT_DIR) — informational only"
else
  echo " Cwd:     $CURRENT_DIR"
fi
echo "==================================================================="

cd "$FM_HOME_DIR"

if [ "$BIN" = "cursor-agent" ]; then
  case " $* " in
    *" --trust "*) ;;
    *) set -- --trust "$@" ;;
  esac
fi

exec env FM_BACKEND="$BACKEND" "$BIN" "$@"
