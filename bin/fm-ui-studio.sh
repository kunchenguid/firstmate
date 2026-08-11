#!/usr/bin/env bash
# fm-ui-studio.sh - infrastructure helper for the /ui-studio skill.
#
# Manages the persistent ui/studio git worktree, the Storybook dev server,
# the Vibe annotation server health check, and the land pipeline.
# The /ui-studio skill (SKILL.md) drives this script; firstmate handles the
# agent-pane launch and merge steps that require harness or LLM judgment.
#
# Usage:
#   fm-ui-studio.sh start  <project>   set up worktree + storybook + vibe; print KEY=VALUE
#   fm-ui-studio.sh land   <project>   rebase + test + push + open PR; print KEY=VALUE
#   fm-ui-studio.sh status <project>   print studio health as KEY=VALUE
#
# Exit codes:
#   0  success (including "nothing to land" for land; check studio_ahead=0)
#   1  operational error (worktree conflict, test failure, etc.)
#   2  usage error
#
# Output: KEY=VALUE lines on stdout; human-readable errors on stderr.
# Callers must read stderr and relay it; stdout is for structured parsing.
#
# Ownership: this script is the sole owner of state/ui-studio/<project>/ worktrees
# and state/ui-studio/<project>.{service,pane,last-land} state files.
# The worktree is deliberately unsupervised (no state/<id>.meta, no watcher entry).
# Writing to the linked project clone's .git/worktrees/ is an explicitly approved
# exception scoped to the ui/studio branch only (see SKILL.md "Ownership exception").
#
# Service state file format (state/ui-studio/<project>.service):
#   worktree=<path>
#   storybook_pid=<pid>
#   storybook_url=<url>
#   storybook_log=<path>
#   started_at=<ISO8601>

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

STUDIO_DIR="$STATE/ui-studio"
# Default storybook port used when log parsing times out
DEFAULT_STORYBOOK_PORT=6006
# Seconds to poll for storybook URL before falling back to default
STORYBOOK_START_TIMEOUT=${FM_UI_STUDIO_SB_TIMEOUT:-90}
# Seconds to wait for vibe-annotations start before reporting down
VIBE_START_TIMEOUT=${FM_UI_STUDIO_VIBE_TIMEOUT:-15}
# Vibe HTTP endpoint
VIBE_URL="http://127.0.0.1:3846/api/annotations"

usage() {
  printf 'usage: fm-ui-studio.sh <start|land|status> <project>\n' >&2
  exit 2
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

# resolve_clone <project>: print the absolute path to the project clone.
# Exits 1 when the clone is absent.
resolve_clone() {
  local project=$1 clone
  clone="$PROJECTS/$project"
  if [ ! -d "$clone/.git" ] && [ ! -f "$clone/.git" ]; then
    die "project clone not found at $clone - add the project with /project-management first"
  fi
  printf '%s\n' "$clone"
}

# worktree_path <project>: print the studio worktree path.
worktree_path() {
  printf '%s/%s\n' "$STUDIO_DIR" "$1"
}

# service_file <project>: print the service state file path.
service_file() {
  printf '%s/%s.service\n' "$STUDIO_DIR" "$1"
}

# pane_file <project>: print the pane-id state file path.
pane_file() {
  printf '%s/%s.pane\n' "$STUDIO_DIR" "$1"
}

# last_land_file <project>: print the last-land timestamp file path.
last_land_file() {
  printf '%s/%s.last-land\n' "$STUDIO_DIR" "$1"
}

# read_service <file> <key>: print the value for KEY from a KEY=VALUE service file.
read_service() {
  local file=$1 key=$2
  grep -m1 "^${key}=" "$file" 2>/dev/null | sed "s/^${key}=//"
}

# detect_pm <dir>: print the package manager command (pnpm|yarn|npm).
detect_pm() {
  local dir=$1
  if [ -f "$dir/pnpm-lock.yaml" ]; then
    printf 'pnpm\n'
  elif [ -f "$dir/yarn.lock" ]; then
    printf 'yarn\n'
  else
    printf 'npm\n'
  fi
}

# has_script <dir> <name>: return 0 when package.json contains a "name" script.
has_script() {
  local dir=$1 name=$2
  [ -f "$dir/package.json" ] && grep -q "\"${name}\"" "$dir/package.json"
}

# pid_alive <pid>: return 0 when the process exists.
pid_alive() {
  local pid=$1
  case "$pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

# vibe_up: return 0 when the Vibe annotation server is reachable.
vibe_up() {
  curl -sf --max-time 3 "$VIBE_URL" >/dev/null 2>&1
}

# start_vibe: ensure the Vibe annotation server is up.
# Prints "up", "down", or "unavailable" on stdout.
start_vibe() {
  if vibe_up; then
    printf 'up\n'
    return 0
  fi
  if ! command -v vibe-annotations >/dev/null 2>&1; then
    printf 'unavailable\n'
    return 0
  fi
  vibe-annotations start >/dev/null 2>&1 &
  local elapsed=0
  while [ "$elapsed" -lt "$VIBE_START_TIMEOUT" ]; do
    sleep 1
    elapsed=$((elapsed + 1))
    if vibe_up; then
      printf 'up\n'
      return 0
    fi
  done
  printf 'down\n'
}

# poll_storybook_url <log> <port>: poll log for the Local URL; print it when found.
# Prints the fallback default URL and returns 1 on timeout.
poll_storybook_url() {
  local log=$1 port=$2 elapsed=0 url
  while [ "$elapsed" -lt "$STORYBOOK_START_TIMEOUT" ]; do
    if grep -q "Local:" "$log" 2>/dev/null; then
      url=$(grep -m1 "Local:" "$log" | sed 's/.*Local:[[:space:]]*//' | tr -d '[:space:]')
      if [ -n "$url" ]; then
        printf '%s\n' "$url"
        return 0
      fi
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  printf 'http://localhost:%s/\n' "$port"
  return 1
}

# ensure_worktree <clone> <worktree_dir>: create or validate the ui/studio worktree.
# Prints "fresh" when newly created, "reused" when already current.
# Exits 1 with a diagnostic when un-landed commits exist or the tree is dirty.
ensure_worktree() {
  local clone=$1 wt=$2 ahead branch

  # Fetch before any branch check so origin/main is current
  git -C "$clone" fetch origin --quiet 2>/dev/null || \
    die "git fetch failed for clone at $clone - check network and origin"

  if [ -d "$wt" ] && git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    # Worktree already exists
    branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')
    if [ "$branch" != "ui/studio" ]; then
      die "worktree at $wt is on branch '$branch', not ui/studio - inspect and clean up manually"
    fi
    if ! git -C "$wt" diff --quiet HEAD -- 2>/dev/null; then
      die "worktree has uncommitted changes - commit or discard them before starting"
    fi
    ahead=$(git -C "$wt" rev-list --count origin/main..HEAD 2>/dev/null || printf '0')
    if [ "$ahead" -gt 0 ]; then
      die "ui/studio has $ahead un-landed commit(s) ahead of origin/main - run /ui-studio land first"
    fi
    git -C "$wt" reset --hard origin/main --quiet 2>/dev/null || \
      die "failed to reset worktree to origin/main"
    printf 'reused\n'
  else
    mkdir -p "$(dirname "$wt")"
    if git -C "$clone" worktree add -B ui/studio "$wt" origin/main --quiet 2>/dev/null; then
      printf 'fresh\n'
    else
      # Branch may already exist from an earlier worktree that was pruned
      git -C "$clone" worktree add "$wt" ui/studio --quiet 2>/dev/null || \
        die "failed to create worktree at $wt - ensure 'ui/studio' is not checked out elsewhere"
      git -C "$wt" reset --hard origin/main --quiet 2>/dev/null || \
        die "failed to reset recovered worktree to origin/main"
      printf 'fresh\n'
    fi
  fi
}

# cmd_start <project>
cmd_start() {
  local project=$1 clone wt svc log pm pid url vibe_status studio_state storybook_status

  clone=$(resolve_clone "$project")
  wt=$(worktree_path "$project")
  svc=$(service_file "$project")
  log="$STUDIO_DIR/$project.storybook.log"

  mkdir -p "$STUDIO_DIR"

  # Reuse a running storybook when its PID is still alive
  if [ -f "$svc" ]; then
    pid=$(read_service "$svc" storybook_pid)
    if pid_alive "$pid"; then
      studio_state=$(ensure_worktree "$clone" "$wt")
      url=$(read_service "$svc" storybook_url)
      vibe_status=$(start_vibe)
      printf 'worktree=%s\n' "$wt"
      printf 'storybook_pid=%s\n' "$pid"
      printf 'storybook_url=%s\n' "$url"
      printf 'storybook_log=%s\n' "$log"
      printf 'storybook_status=running\n'
      printf 'vibe_status=%s\n' "$vibe_status"
      printf 'studio_state=%s\n' "$studio_state"
      return 0
    fi
  fi

  studio_state=$(ensure_worktree "$clone" "$wt")
  pm=$(detect_pm "$wt")

  # Start storybook in the background
  : > "$log"
  (cd "$wt" && "$pm" storybook) >> "$log" 2>&1 &
  pid=$!

  # Poll for the URL; accept the default on timeout
  storybook_status=starting
  if url=$(poll_storybook_url "$log" "$DEFAULT_STORYBOOK_PORT"); then
    storybook_status=running
  else
    url="http://localhost:${DEFAULT_STORYBOOK_PORT}/"
  fi

  # Record service state
  {
    printf 'worktree=%s\n' "$wt"
    printf 'storybook_pid=%s\n' "$pid"
    printf 'storybook_url=%s\n' "$url"
    printf 'storybook_log=%s\n' "$log"
    printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$svc"

  vibe_status=$(start_vibe)

  printf 'worktree=%s\n' "$wt"
  printf 'storybook_pid=%s\n' "$pid"
  printf 'storybook_url=%s\n' "$url"
  printf 'storybook_log=%s\n' "$log"
  printf 'storybook_status=%s\n' "$storybook_status"
  printf 'vibe_status=%s\n' "$vibe_status"
  printf 'studio_state=%s\n' "$studio_state"
}

# cmd_land <project>
cmd_land() {
  local project=$1 clone wt pm ahead pr_url pr_number

  clone=$(resolve_clone "$project")
  wt=$(worktree_path "$project")

  if [ ! -d "$wt" ] || ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    die "studio worktree not found at $wt - run /ui-studio start first"
  fi

  git -C "$wt" fetch origin --quiet 2>/dev/null || \
    die "git fetch failed - check network and origin"

  ahead=$(git -C "$wt" rev-list --count origin/main..HEAD 2>/dev/null || printf '0')
  if [ "$ahead" -eq 0 ]; then
    printf 'studio_ahead=0\n'
    printf 'message=nothing to land\n'
    return 0
  fi

  git -C "$wt" rebase origin/main --quiet 2>/dev/null || \
    die "rebase onto origin/main failed - resolve conflicts in $wt then re-run /ui-studio land"

  pm=$(detect_pm "$wt")

  # Lint, test, build - stop on first failure
  printf 'step=lint\n'
  (cd "$wt" && "$pm" lint) || die "lint failed - fix issues in $wt before landing"

  printf 'step=test\n'
  if has_script "$wt" "test:ci"; then
    (cd "$wt" && "$pm" "test:ci") || die "tests failed - fix failing tests in $wt before landing"
  else
    (cd "$wt" && "$pm" test --run) || die "tests failed - fix failing tests in $wt before landing"
  fi

  printf 'step=build-storybook\n'
  (cd "$wt" && "$pm" build-storybook) || \
    die "Storybook build failed - fix build errors in $wt before landing"

  git -C "$wt" push -u origin ui/studio 2>/dev/null || \
    die "git push failed - check remote permissions"

  # gh-axi pr create uses the worktree's git remote to detect the repo
  pr_url=$(cd "$wt" && gh-axi pr create \
    --title "ui/studio: batch land from UI Studio" \
    --body "Auto-created by /ui-studio land. Review diff and merge to ship." \
    --head ui/studio --base main 2>/dev/null) || \
    die "gh-axi pr create failed - check GitHub auth and that the branch was pushed"

  pr_number=$(printf '%s\n' "$pr_url" | sed 's|.*/pull/||' | tr -d '[:space:]')

  printf 'studio_ahead=%s\n' "$ahead"
  printf 'pr_url=%s\n' "$pr_url"
  printf 'pr_number=%s\n' "$pr_number"
}

# cmd_status <project>
cmd_status() {
  local project=$1 wt svc pid url ahead pane_id lf pf storybook_status vibe_status last_land_ts

  wt=$(worktree_path "$project")
  svc=$(service_file "$project")

  storybook_status=down
  pid=
  url=
  if [ -f "$svc" ]; then
    pid=$(read_service "$svc" storybook_pid)
    url=$(read_service "$svc" storybook_url)
    if pid_alive "$pid"; then
      storybook_status=running
    fi
  fi

  if vibe_up; then
    vibe_status=up
  else
    vibe_status=down
  fi

  ahead=unknown
  if [ -d "$wt" ] && git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$wt" fetch origin --quiet 2>/dev/null || true
    ahead=$(git -C "$wt" rev-list --count origin/main..HEAD 2>/dev/null || printf 'unknown')
  fi

  last_land_ts=never
  lf=$(last_land_file "$project")
  if [ -f "$lf" ]; then
    last_land_ts=$(cat "$lf" 2>/dev/null || printf 'unknown')
  fi

  pane_id=
  pf=$(pane_file "$project")
  if [ -f "$pf" ]; then
    pane_id=$(cat "$pf" 2>/dev/null || true)
  fi

  printf 'storybook_status=%s\n' "$storybook_status"
  printf 'storybook_pid=%s\n' "${pid:-}"
  printf 'storybook_url=%s\n' "${url:-}"
  printf 'vibe_status=%s\n' "$vibe_status"
  printf 'studio_ahead=%s\n' "$ahead"
  printf 'last_land=%s\n' "$last_land_ts"
  printf 'pane_id=%s\n' "${pane_id:-}"
  printf 'worktree=%s\n' "$wt"
}

# --- main ---

[ $# -ge 1 ] || usage

SUBCMD=$1
shift

case "$SUBCMD" in
  --help|-h)
    usage
    ;;
  start|land|status)
    [ $# -ge 1 ] || usage
    PROJECT=$1
    case "$PROJECT" in
      '' | -*)
        usage
        ;;
    esac
    case "$SUBCMD" in
      start)  cmd_start  "$PROJECT" ;;
      land)   cmd_land   "$PROJECT" ;;
      status) cmd_status "$PROJECT" ;;
    esac
    ;;
  *)
    printf 'unknown subcommand: %s\n' "$SUBCMD" >&2
    usage
    ;;
esac
