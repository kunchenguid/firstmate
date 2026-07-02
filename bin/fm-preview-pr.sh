#!/usr/bin/env bash
# Refresh a reusable preview server pair for a project PR without leaving stale
# worktrees or terminal panes behind.
#
# Usage: fm-preview-pr.sh <project-name-or-path> <pr-number> [--expect <text> ...] [--open-path <path>]
#
# Project names resolve under $FM_HOME/projects (or $FM_PROJECTS_OVERRIDE).
# Project paths are accepted as-is. The script creates a dedicated preview
# worktree under state/preview-worktrees/, records preview metadata under
# state/previews/, stops only the previously recorded owned process group for
# the same project+PR, fetches the latest GitHub PR head, starts backend and
# frontend dev servers on stable available ports, verifies they respond, then
# prints:
#   ready: http://127.0.0.1:<frontend-port> backend=http://127.0.0.1:<backend-port> project=<project> pr=<n> branch=<branch> head=<sha>
#
# Optional environment overrides:
#   FM_PREVIEW_BACKEND_CMD    command to start the backend server
#   FM_PREVIEW_FRONTEND_CMD   command to start the frontend server
#   FM_PREVIEW_BACKEND_DIR    backend subdirectory relative to the preview worktree
#   FM_PREVIEW_FRONTEND_DIR   frontend subdirectory relative to the preview worktree
#   FM_PREVIEW_TIMEOUT        seconds to wait for each server, default 60
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

fm_preview_usage() {
  sed -n '2,28p' "$0" >&2
}

fm_preview_slug() {
  printf '%s' "$1" | tr '/[:space:]' '--' | tr -cd 'A-Za-z0-9._-' | sed 's/^-*//; s/-*$//; s/--*/-/g'
}

fm_preview_path_hash() {
  printf '%s' "$1" | cksum | awk '{printf "%x\n", $1}'
}

fm_preview_pr_refspec() {
  printf '+pull/%s/head:refs/fm-preview-pr/%s\n' "$1" "$1"
}

fm_preview_project_path() {
  local arg=$1
  case "$arg" in
    */*|.*)
      [ -d "$arg" ] || { echo "error: project path not found: $arg" >&2; return 1; }
      (cd "$arg" && pwd)
      ;;
    *)
      [ -d "$PROJECTS/$arg" ] || { echo "error: project '$arg' not found under $PROJECTS" >&2; return 1; }
      (cd "$PROJECTS/$arg" && pwd)
      ;;
  esac
}

fm_preview_meta_get() {
  local file=$1 key=$2
  [ -f "$file" ] || return 0
  grep "^$key=" "$file" | tail -1 | cut -d= -f2- || true
}

fm_preview_port_free() {
  python3 - "$1" <<'PY'
import socket
import sys

port = int(sys.argv[1])
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", port))
    except OSError:
        sys.exit(1)
PY
}

fm_preview_pick_port() {
  local start=$1 port=$1
  while [ "$port" -lt $((start + 200)) ]; do
    if fm_preview_port_free "$port"; then
      printf '%s\n' "$port"
      return 0
    fi
    port=$((port + 1))
  done
  echo "error: no available port in range $start-$((start + 199))" >&2
  return 1
}

fm_preview_stable_ports() {
  local key=$1 sum offset
  sum=$(printf '%s' "$key" | cksum | awk '{print $1}')
  offset=$((sum % 700))
  printf '%s %s\n' "$((4100 + offset))" "$((5100 + offset))"
}

fm_preview_pid_sig() {
  local pid=$1
  ps -p "$pid" -o lstart= -o command= 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

fm_preview_stop_role() {
  local meta=$1 role=$2 pid pgid isolated sig current
  pid=$(fm_preview_meta_get "$meta" "${role}_pid")
  pgid=$(fm_preview_meta_get "$meta" "${role}_pgid")
  isolated=$(fm_preview_meta_get "$meta" "${role}_pgid_isolated")
  sig=$(fm_preview_meta_get "$meta" "${role}_sig")
  [ -n "$pid" ] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  current=$(fm_preview_pid_sig "$pid")
  if [ -z "$sig" ] || [ "$current" != "$sig" ]; then
    echo "skip: recorded $role pid $pid is no longer the owned preview process" >&2
    return 0
  fi
  if [ "$isolated" = 1 ] && [ -n "$pgid" ] && [ "$pgid" != "0" ]; then
    kill -TERM "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
  fi
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    if [ "$isolated" = 1 ] && [ -n "$pgid" ] && [ "$pgid" != "0" ]; then
      kill -KILL "-$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    else
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
}

fm_preview_cleanup_started() {
  local meta=$1 role
  shift
  for role in "$@"; do
    fm_preview_stop_role "$meta" "$role"
  done
}

fm_preview_json_field() {
  python3 -c '
import json
import sys

data = json.load(sys.stdin)
value = data
for part in sys.argv[1].split("."):
    if not part:
        continue
    value = value.get(part, "") if isinstance(value, dict) else ""
print("" if value is None else value)
' "$1"
}

fm_preview_run_gh() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 25s "$@"
  else
    "$@"
  fi
}

fm_preview_pr_json() {
  local repo=$1 pr=$2
  command -v gh-axi >/dev/null 2>&1 || {
    echo "error: gh-axi is required for GitHub PR lookup; ask firstmate/captain to handle tool installation" >&2
    return 1
  }
  command -v gh >/dev/null 2>&1 || {
    echo "error: GitHub CLI 'gh' is required for structured PR data; ask firstmate/captain to handle GitHub auth/tooling" >&2
    return 1
  }
  if ! fm_preview_run_gh gh pr view "$pr" --repo "$repo" --json headRefName,headRefOid,url,headRepositoryOwner,headRepository 2>/dev/null; then
    echo "error: unable to read GitHub PR $repo#$pr; ask firstmate/captain to handle GitHub auth/network" >&2
    return 1
  fi
}

fm_preview_repo_slug() {
  local project=$1 url host path
  url=$(git -C "$project" remote get-url origin 2>/dev/null || true)
  [ -n "$url" ] || { echo "error: project has no origin remote" >&2; return 1; }
  case "$url" in
    git@github.com:*) path=${url#git@github.com:}; path=${path%.git} ;;
    https://github.com/*) path=${url#https://github.com/}; path=${path%.git} ;;
    http://github.com/*) path=${url#http://github.com/}; path=${path%.git} ;;
    ssh://git@github.com/*) path=${url#ssh://git@github.com/}; path=${path%.git} ;;
    *) echo "error: origin is not a GitHub remote: $url" >&2; return 1 ;;
  esac
  host=${path#*/}
  [ "$host" != "$path" ] || { echo "error: could not parse GitHub owner/repo from origin: $url" >&2; return 1; }
  printf '%s\n' "$path"
}

fm_preview_package_script() {
  local dir=$1 candidates=$2
  [ -f "$dir/package.json" ] || return 1
  python3 - "$dir/package.json" "$candidates" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    scripts = json.load(f).get("scripts", {})
for name in sys.argv[2].split(","):
    if name in scripts:
        print(name)
        sys.exit(0)
sys.exit(1)
PY
}

fm_preview_install_deps() {
  local dir=$1
  [ -f "$dir/package.json" ] || return 0
  [ -d "$dir/node_modules" ] && return 0
  if [ -f "$dir/pnpm-lock.yaml" ] && command -v pnpm >/dev/null 2>&1; then
    (cd "$dir" && pnpm install --frozen-lockfile)
  elif [ -f "$dir/yarn.lock" ] && command -v yarn >/dev/null 2>&1; then
    (cd "$dir" && yarn install --frozen-lockfile)
  elif [ -f "$dir/package-lock.json" ]; then
    (cd "$dir" && npm ci)
  else
    (cd "$dir" && npm install)
  fi
}

fm_preview_subdir_with_package() {
  local wt=$1 override=$2 candidates=$3 cmd_override=${4:-} part
  if [ -n "$override" ]; then
    [ -d "$wt/$override" ] || { echo "error: preview directory not found: $wt/$override" >&2; return 1; }
    [ -n "$cmd_override" ] || [ -f "$wt/$override/package.json" ] || { echo "error: package.json not found in $wt/$override" >&2; return 1; }
    printf '%s\n' "$wt/$override"
    return 0
  fi
  IFS=,
  for part in $candidates; do
    if { [ -n "$cmd_override" ] && [ -d "$wt/$part" ]; } || { [ -z "$cmd_override" ] && [ -f "$wt/$part/package.json" ]; }; then
      printf '%s\n' "$wt/$part"
      unset IFS
      return 0
    fi
  done
  unset IFS
  if [ -n "$cmd_override" ]; then
    printf '%s\n' "$wt"
    return 0
  fi
  [ -f "$wt/package.json" ] || { echo "error: package.json not found in preview worktree; set FM_PREVIEW_BACKEND_DIR/FM_PREVIEW_FRONTEND_DIR or command overrides" >&2; return 1; }
  printf '%s\n' "$wt"
}

fm_preview_wait_url() {
  local url=$1 label=$2 timeout_s=${3:-60} start now
  start=$(date +%s)
  while :; do
    if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
      return 0
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout_s" ]; then
      echo "error: $label did not respond at $url within ${timeout_s}s" >&2
      return 1
    fi
    sleep 1
  done
}

fm_preview_start_process() {
  local id=$1 role=$2 dir=$3 cmd=$4 port=$5 backend_port=$6 frontend_port=$7 log=$8 pid pgid isolated sig
  mkdir -p "$(dirname "$log")"
  isolated=0
  if command -v setsid >/dev/null 2>&1; then
    isolated=1
    setsid sh -c 'cd "$1" || exit 1; shift; exec "$@"' sh "$dir" \
      env FM_PREVIEW_ID="$id" PORT="$port" BACKEND_PORT="$backend_port" FRONTEND_PORT="$frontend_port" \
      VITE_BACKEND_URL="http://127.0.0.1:$backend_port" VITE_API_URL="http://127.0.0.1:$backend_port" API_URL="http://127.0.0.1:$backend_port" \
      sh -c "$cmd" >"$log" 2>&1 &
  else
    sh -c 'cd "$1" || exit 1; shift; exec "$@"' sh "$dir" \
      env FM_PREVIEW_ID="$id" PORT="$port" BACKEND_PORT="$backend_port" FRONTEND_PORT="$frontend_port" \
      VITE_BACKEND_URL="http://127.0.0.1:$backend_port" VITE_API_URL="http://127.0.0.1:$backend_port" API_URL="http://127.0.0.1:$backend_port" \
      sh -c "$cmd" >"$log" 2>&1 &
  fi
  pid=$!
  sleep 1
  kill -0 "$pid" 2>/dev/null || { echo "error: $role process exited early; see $log" >&2; return 1; }
  pgid=$(ps -p "$pid" -o pgid= 2>/dev/null | awk '{print $1}' || true)
  sig=$(fm_preview_pid_sig "$pid")
  printf '%s_pid=%s\n%s_pgid=%s\n%s_pgid_isolated=%s\n%s_sig=%s\n%s_log=%s\n' "$role" "$pid" "$role" "${pgid:-}" "$role" "$isolated" "$role" "$sig" "$role" "$log"
}

fm_preview_main() {
  local project_arg pr open_path=/ expects=() want= project project_name project_slug project_hash preview_id state_dir meta wt
  local repo pr_json branch head stable backend_desired frontend_desired backend_port frontend_port
  local backend_dir frontend_dir backend_cmd frontend_cmd backend_script frontend_script frontend_url backend_url ready tmp_meta
  local cleanup_roles=()

  [ "$#" -ge 2 ] || { fm_preview_usage; return 2; }
  project_arg=$1
  pr=$2
  shift 2
  case "$pr" in
    ''|*[!0-9]*) echo "error: pr-number must be numeric" >&2; return 2 ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --expect)
        [ "$#" -ge 2 ] || { echo "error: --expect requires text" >&2; return 2; }
        expects+=("$2")
        shift 2
        ;;
      --open-path)
        [ "$#" -ge 2 ] || { echo "error: --open-path requires a path" >&2; return 2; }
        open_path=$2
        shift 2
        ;;
      -h|--help)
        fm_preview_usage
        return 0
        ;;
      *)
        echo "error: unknown argument: $1" >&2
        fm_preview_usage
        return 2
        ;;
    esac
  done
  case "$open_path" in /*) : ;; *) open_path="/$open_path" ;; esac

  project=$(fm_preview_project_path "$project_arg")
  project_name=$(basename "$project")
  project_slug=$(fm_preview_slug "$project_name")
  project_hash=$(fm_preview_path_hash "$project")
  preview_id="${project_slug}-${project_hash}-pr${pr}"
  state_dir="$STATE/previews"
  meta="$state_dir/$preview_id.meta"
  wt="$STATE/preview-worktrees/$preview_id"
  mkdir -p "$state_dir" "$STATE/preview-worktrees"

  repo=$(fm_preview_repo_slug "$project")
  pr_json=$(fm_preview_pr_json "$repo" "$pr")
  branch=$(printf '%s' "$pr_json" | fm_preview_json_field headRefName)
  head=$(printf '%s' "$pr_json" | fm_preview_json_field headRefOid)
  [ -n "$head" ] || { echo "error: GitHub PR data did not include a head SHA for $repo#$pr" >&2; return 1; }

  if ! git -C "$project" fetch --no-tags origin "$(fm_preview_pr_refspec "$pr")" >/dev/null 2>&1; then
    echo "error: failed to fetch PR $repo#$pr; ask firstmate/captain to handle GitHub auth/network" >&2
    return 1
  fi
  fm_preview_stop_role "$meta" backend
  fm_preview_stop_role "$meta" frontend

  if [ -d "$wt/.git" ] || git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    :
  elif [ -e "$wt" ]; then
    echo "error: preview path exists but is not a git worktree: $wt" >&2
    return 1
  else
    git -C "$project" worktree add --detach "$wt" "$head" >/dev/null
  fi
  git -C "$wt" reset --hard "$head" >/dev/null
  git -C "$wt" clean -fd >/dev/null

  backend_cmd=${FM_PREVIEW_BACKEND_CMD:-}
  frontend_cmd=${FM_PREVIEW_FRONTEND_CMD:-}
  backend_dir=$(fm_preview_subdir_with_package "$wt" "${FM_PREVIEW_BACKEND_DIR:-}" "backend,server,api" "$backend_cmd")
  frontend_dir=$(fm_preview_subdir_with_package "$wt" "${FM_PREVIEW_FRONTEND_DIR:-}" "frontend,client,web,app" "$frontend_cmd")
  if [ -z "$backend_cmd" ]; then
    if [ "$backend_dir" = "$frontend_dir" ]; then
      backend_script=$(fm_preview_package_script "$backend_dir" "dev:backend,backend,server,api" || true)
    else
      backend_script=$(fm_preview_package_script "$backend_dir" "dev:backend,backend,server,api,dev" || true)
    fi
    [ -n "$backend_script" ] || { echo "error: could not identify backend dev script in $backend_dir; set FM_PREVIEW_BACKEND_CMD" >&2; return 1; }
    backend_cmd="npm run $backend_script --"
  fi
  if [ -z "$frontend_cmd" ]; then
    frontend_script=$(fm_preview_package_script "$frontend_dir" "dev:frontend,frontend,client,web,dev" || true)
    [ -n "$frontend_script" ] || { echo "error: could not identify frontend dev script in $frontend_dir; set FM_PREVIEW_FRONTEND_CMD" >&2; return 1; }
    frontend_cmd="npm run $frontend_script --"
  fi

  fm_preview_install_deps "$backend_dir"
  [ "$frontend_dir" = "$backend_dir" ] || fm_preview_install_deps "$frontend_dir"

  stable=$(fm_preview_stable_ports "$preview_id")
  backend_desired=${stable%% *}
  frontend_desired=${stable#* }
  backend_port=$(fm_preview_pick_port "$backend_desired")
  frontend_port=$(fm_preview_pick_port "$frontend_desired")

  tmp_meta="$meta.tmp.$$"
  {
    printf 'project=%s\n' "$project_name"
    printf 'project_path=%s\n' "$project"
    printf 'pr=%s\n' "$pr"
    printf 'branch=%s\n' "$branch"
    printf 'head=%s\n' "$head"
    printf 'worktree=%s\n' "$wt"
    printf 'backend_port=%s\n' "$backend_port"
    printf 'frontend_port=%s\n' "$frontend_port"
    printf 'backend_cmd=%s\n' "$backend_cmd"
    printf 'frontend_cmd=%s\n' "$frontend_cmd"
  } > "$tmp_meta"
  mv "$tmp_meta" "$meta"
  fm_preview_start_process "$preview_id" backend "$backend_dir" "$backend_cmd" "$backend_port" "$backend_port" "$frontend_port" "$state_dir/$preview_id.backend.log" >> "$meta"
  cleanup_roles=(backend)
  fm_preview_start_process "$preview_id" frontend "$frontend_dir" "$frontend_cmd" "$frontend_port" "$backend_port" "$frontend_port" "$state_dir/$preview_id.frontend.log" >> "$meta" || {
    fm_preview_cleanup_started "$meta" "${cleanup_roles[@]}"
    return 1
  }
  cleanup_roles=(frontend backend)

  frontend_url="http://127.0.0.1:$frontend_port$open_path"
  backend_url="http://127.0.0.1:$backend_port"
  fm_preview_wait_url "$backend_url" backend "${FM_PREVIEW_TIMEOUT:-60}" || {
    fm_preview_cleanup_started "$meta" "${cleanup_roles[@]}"
    return 1
  }
  fm_preview_wait_url "$frontend_url" frontend "${FM_PREVIEW_TIMEOUT:-60}" || {
    fm_preview_cleanup_started "$meta" "${cleanup_roles[@]}"
    return 1
  }

  for want in "${expects[@]}"; do
    if ! curl -fsS --max-time 5 "$frontend_url" | grep -F -- "$want" >/dev/null; then
      echo "error: expected text not found at $frontend_url: $want" >&2
      fm_preview_cleanup_started "$meta" "${cleanup_roles[@]}"
      return 1
    fi
  done

  ready="ready: http://127.0.0.1:$frontend_port backend=$backend_url project=$project_name pr=$pr branch=$branch head=$head"
  printf '%s\n' "$ready"
  printf 'ready=%s\n' "$ready" >> "$meta"
}

if [ "${FM_PREVIEW_PR_LIB_ONLY:-0}" != 1 ]; then
  fm_preview_main "$@"
fi
