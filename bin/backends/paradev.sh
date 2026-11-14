#!/usr/bin/env bash
# bin/backends/paradev.sh - the Paradev workspace session-provider adapter.
#
# Paradev (the `superset` CLI) owns both the task worktree and the terminal
# endpoint, like Orca: a spawn creates one Paradev workspace (its own branch
# and git worktree), opens one plain shell terminal in it, and types the
# harness launch into that shell. Treehouse is not used.
#
# Target string shape: `<workspace-id>:<terminal-id>`. Every terminal call
# needs both ids, so the pair is the target, recorded as `terminal=` in task
# metadata beside `paradev_workspace_id=` (the worktree id) and
# `paradev_project_id=`.
#
# Ownership comes only from those recorded ids. Every created workspace carries
# one display-only tag (`firstmate`, or FM_PARADEV_TAG when a smoke test needs
# its own sidebar folder) that files it into one sidebar folder; nothing here
# lists, matches, or acts on workspaces by tag, so a tagged workspace Firstmate
# did not record (the captain's own, or one tagged by hand) is never touched.
#
# Every call passes `--local --json` and parses with jq: inside an agent
# environment the CLI turns --json on by itself, which makes `--field` and the
# human output unreliable. `superset status` is not trusted for readiness; it
# can report a stale daemon while every other call works, so the runtime check
# probes a real cheap call instead.
#
# Native agent state (`agents explain`) is read only for busy_state. It needs
# Paradev's agent hooks to load in the launched harness; without them the state
# stays `starting` and busy_state answers unknown, which every consumer
# already treats as "no native verdict".

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"

fm_backend_paradev_tag() {
  printf '%s' "${FM_PARADEV_TAG:-firstmate}"
}

fm_backend_paradev_tool_check() {
  command -v superset >/dev/null 2>&1 || {
    echo "error: backend=paradev selected but the 'superset' CLI is not installed (it ships with the Paradev desktop app)" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: backend=paradev selected but 'jq' is not installed" >&2
    return 1
  }
}

# The same character class bin/fm-backend.sh's fm_backend_endpoint_atom_valid
# accepts, repeated here so the adapter stays usable without the dispatcher.
fm_backend_paradev_id_valid() {  # <value>
  case "$1" in
    ''|*[!A-Za-z0-9._@%+-]*) return 1 ;;
  esac
}

# fm_backend_paradev_split_target: sets FM_PARADEV_WS and FM_PARADEV_TERM from
# a `<workspace>:<terminal>` target, refusing anything else before any CLI call.
fm_backend_paradev_split_target() {  # <target>
  local target=${1:-}
  FM_PARADEV_WS=${target%%:*}
  FM_PARADEV_TERM=${target#*:}
  if [ "$FM_PARADEV_TERM" = "$target" ] \
    || ! fm_backend_paradev_id_valid "$FM_PARADEV_WS" \
    || ! fm_backend_paradev_id_valid "$FM_PARADEV_TERM"; then
    echo "error: malformed Paradev target '$target' (expected <workspace-id>:<terminal-id>)" >&2
    return 1
  fi
}

fm_backend_paradev_runtime_check() {
  local out
  fm_backend_paradev_tool_check || return 1
  out=$(superset projects list --local --json) || {
    echo "error: backend=paradev selected but 'superset projects list --local --json' failed; open the Paradev desktop app (or run 'superset start --daemon') and retry" >&2
    return 1
  }
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || {
    echo "error: backend=paradev: 'superset projects list --local --json' did not return a project list" >&2
    return 1
  }
}

# fm_backend_paradev_project_id: the id of the one Paradev project on this host
# whose path is <project-path>. Registering a project is the captain's setup
# step, so an unknown path refuses with the command instead of creating one.
fm_backend_paradev_project_id() {  # <project-path>
  local project=$1 real out ids count
  fm_backend_paradev_tool_check || return 1
  real=$(cd "$project" 2>/dev/null && pwd -P) || {
    echo "error: backend=paradev: project path $project is not a readable directory" >&2
    return 1
  }
  out=$(superset projects list --local --json) || return 1
  ids=$(printf '%s' "$out" | jq -r --arg real "$real" --arg raw "$project" \
    '.[] | select(.path == $real or .path == $raw) | .id | strings') || {
    echo "error: backend=paradev: could not read the Paradev project list" >&2
    return 1
  }
  count=$(printf '%s' "$ids" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    echo "error: backend=paradev: $real is not a Paradev project on this host; register it once with 'superset projects create --import $real --local' and retry" >&2
    return 1
  fi
  if [ "$count" -ne 1 ]; then
    echo "error: backend=paradev: more than one Paradev project is registered at $real; remove the duplicate in Paradev and retry" >&2
    return 1
  fi
  fm_backend_paradev_id_valid "$ids" || {
    echo "error: backend=paradev: Paradev returned an unusable project id for $real" >&2
    return 1
  }
  printf '%s' "$ids"
}

# fm_backend_paradev_worktree_create: create one tagged workspace on <branch>
# and print `<workspace-id>\t<worktree-path>`. Exit 1 means nothing of ours is
# left behind; exit 2 means the workspace was created but its own cleanup
# failed, and stdout carries `<workspace-id>\t` so the caller can record it.
# A workspace Paradev reports as already existing was not created here, so it
# is refused and never archived.
fm_backend_paradev_worktree_create() {  # <project-id> <name> <branch> [base-branch]
  local project_id=$1 name=$2 branch=$3 base=${4:-} out ws path
  local -a args
  fm_backend_paradev_tool_check || return 1
  args=(workspaces create --local --project "$project_id" --name "$name")
  [ -z "$base" ] || args+=(--base-branch "$base")
  args+=(--branch "$branch" --skip-branch-prefix --tag "$(fm_backend_paradev_tag)" --json)
  out=$(superset "${args[@]}") || return 1
  if printf '%s' "$out" | jq -e '.alreadyExists == true' >/dev/null 2>&1; then
    echo "error: backend=paradev: a workspace for branch $branch already exists; Firstmate only uses workspaces it creates, so remove or rename that one and retry" >&2
    return 1
  fi
  ws=$(printf '%s' "$out" | jq -r '.workspace.id | strings' 2>/dev/null) || ws=
  fm_backend_paradev_id_valid "$ws" || {
    echo "error: paradev workspaces create did not return a workspace id for $name" >&2
    return 1
  }
  path=$(fm_backend_paradev_worktree_path "$ws") || {
    echo "error: paradev workspaces create did not return a worktree path for $name" >&2
    if fm_backend_paradev_remove_worktree "$ws" >/dev/null; then
      return 1
    fi
    printf '%s\t' "$ws"
    return 2
  }
  printf '%s\t%s' "$ws" "$path"
}

# fm_backend_paradev_terminal_create: open one plain shell terminal in the
# workspace (no --command, so it is a shell Firstmate types into) and print the
# composite target.
fm_backend_paradev_terminal_create() {  # <workspace-id> [title]
  local ws=$1 out term
  fm_backend_paradev_tool_check || return 1
  out=$(superset terminals create --local --workspace "$ws" --json) || return 1
  term=$(printf '%s' "$out" | jq -r '.terminalId | strings' 2>/dev/null) || term=
  fm_backend_paradev_id_valid "$term" || {
    echo "error: paradev terminals create did not return a terminal id for workspace $ws" >&2
    return 1
  }
  printf '%s:%s' "$ws" "$term"
}

# fm_backend_paradev_run_json: run one `superset` call and require a JSON reply.
fm_backend_paradev_run_json() {
  local out
  out=$(superset "$@") || return 1
  printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1 || {
    echo "error: paradev $1 $2 did not return JSON" >&2
    return 1
  }
}

# Text rides in `--text=<value>`: the CLI reads a separate value that starts
# with a dash as the next option and refuses ("Option --text requires a value").
fm_backend_paradev_send_text_line() {  # <target> <text>
  fm_backend_paradev_split_target "$1" || return 1
  fm_backend_paradev_tool_check || return 1
  fm_backend_paradev_run_json terminals send --local --workspace "$FM_PARADEV_WS" \
    --terminal "$FM_PARADEV_TERM" "--text=$2" --json
}

fm_backend_paradev_send_literal() {  # <target> <text>
  fm_backend_paradev_split_target "$1" || return 1
  fm_backend_paradev_tool_check || return 1
  fm_backend_paradev_run_json terminals send --local --workspace "$FM_PARADEV_WS" \
    --terminal "$FM_PARADEV_TERM" "--text=$2" --no-submit --json
}

fm_backend_paradev_send_key() {  # <target> <key>
  local key
  case "$2" in
    Enter|enter) key=enter ;;
    Escape|escape|Esc|esc) key=esc ;;
    C-c|ctrl+c|Ctrl-c|Ctrl-C) key=ctrl+c ;;
    C-u|ctrl+u|Ctrl-u|Ctrl-U) key=ctrl+u ;;
    *)
      echo "error: unsupported Paradev key '$2'" >&2
      return 1
      ;;
  esac
  fm_backend_paradev_split_target "$1" || return 1
  fm_backend_paradev_tool_check || return 1
  fm_backend_paradev_run_json terminals send --local --workspace "$FM_PARADEV_WS" \
    --terminal "$FM_PARADEV_TERM" --keys "$key" --json
}

# fm_backend_paradev_capture: the bottom <lines> rows of the terminal's screen.
# `terminals read` returns the visible screen (bottom-padded), not scrollback.
fm_backend_paradev_capture() {  # <target> <lines>
  local lines=${2:-40} out
  fm_backend_paradev_split_target "$1" || return 1
  fm_backend_paradev_tool_check || return 1
  out=$(superset terminals read --local --workspace "$FM_PARADEV_WS" \
    --terminal "$FM_PARADEV_TERM" --max-lines "$lines" --json) || return 1
  printf '%s' "$out" | jq -je '.text | strings' 2>/dev/null || {
    echo "error: paradev terminals read did not return screen text for $1" >&2
    return 1
  }
}

fm_backend_paradev_composer_capture() {  # <target> [expected-label]
  fm_backend_paradev_capture "$1" "$FM_COMPOSER_CAPTURE_LINES"
}

# Static capability facts, not logic (bin/fm-composer-lib.sh owns the model):
# `terminals read` returns plain text with no style, cursor, or pane identity.
fm_backend_paradev_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

fm_backend_paradev_composer_state() {  # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_paradev_composer_capture "$1" 2>/dev/null) || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_paradev_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

# Type <text> once without submitting, then drive the shared verify-and-retry
# Enter loop against the shared composer verdict.
fm_backend_paradev_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  fm_backend_paradev_tool_check || { printf 'send-failed'; return 0; }
  fm_backend_paradev_send_literal "$target" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_paradev_send_key fm_backend_paradev_composer_state \
    "$target" "$retries" "$sleep_s"
}

# fm_backend_paradev_terminal_listed: 0 when the terminal is listed and not
# exited, 1 when the readable inventory omits it (or marks it exited), 2 when
# the workspace is gone, 3 when the inventory cannot be read.
fm_backend_paradev_terminal_listed() {  # <workspace-id> <terminal-id>
  local ws=$1 term=$2 out err errf
  errf=$(mktemp "${TMPDIR:-/tmp}/fm-paradev-list.XXXXXX") || return 3
  if out=$(superset terminals list --local --workspace "$ws" --json 2>"$errf"); then
    rm -f "$errf"
    printf '%s' "$out" | jq -e '.sessions | type == "array"' >/dev/null 2>&1 || return 3
    printf '%s' "$out" | jq -e --arg t "$term" \
      'any(.sessions[]; .terminalId == $t and .exited != true)' >/dev/null 2>&1 && return 0
    return 1
  fi
  err=$(cat "$errf" 2>/dev/null || true)
  rm -f "$errf"
  case "$err" in
    *"Workspace not found"*|*"is not on this host"*) return 2 ;;
  esac
  return 3
}

fm_backend_paradev_target_ready() {  # <target> [expected-label]
  fm_backend_paradev_split_target "$1" 2>/dev/null || return 1
  fm_backend_paradev_tool_check 2>/dev/null || return 1
  fm_backend_paradev_terminal_listed "$FM_PARADEV_WS" "$FM_PARADEV_TERM"
}

# fm_backend_paradev_kill: close the recorded terminal, then PROVE it gone by
# re-reading the workspace's terminal inventory. `terminals close` reports
# `disposed` for an already-closed terminal too, so its reply proves nothing.
# An already-gone terminal or workspace is a quiet success; a terminal still
# listed, an unreadable inventory, or a missing CLI is a failed close.
fm_backend_paradev_kill() {  # <target>
  local rc=0
  fm_backend_paradev_split_target "$1" || return 1
  fm_backend_paradev_tool_check || return 1
  superset terminals close --local --workspace "$FM_PARADEV_WS" \
    --terminal "$FM_PARADEV_TERM" --json >/dev/null 2>&1 || true
  fm_backend_paradev_terminal_listed "$FM_PARADEV_WS" "$FM_PARADEV_TERM" || rc=$?
  case "$rc" in
    1|2) return 0 ;;
    0) echo "error: Paradev terminal $1 is still open after close" >&2 ;;
    *) echo "error: cannot read Paradev terminal inventory to confirm $1 closed" >&2 ;;
  esac
  return 1
}

# fm_backend_paradev_remove_worktree: archive the exact recorded workspace.
# Archive deletes the worktree folder, uncommitted files included, so the
# caller runs Firstmate's landing checks and the recorded id/path match first.
# An id Paradev already forgot (notFound) is gone; any failure refuses.
fm_backend_paradev_remove_worktree() {  # <workspace-id>
  local ws=${1:-} out
  fm_backend_paradev_id_valid "$ws" || { echo "error: missing or malformed Paradev workspace id; cannot archive workspace" >&2; return 1; }
  fm_backend_paradev_tool_check || return 1
  out=$(superset workspaces archive "$ws" --local --json) || return 1
  printf '%s' "$out" | jq -e --arg w "$ws" \
    '((.failed // []) | length == 0) and (((.deleted // []) | index($w)) != null or ((.notFound // []) | index($w)) != null)' \
    >/dev/null 2>&1 || {
      echo "error: paradev workspaces archive did not archive workspace $ws" >&2
      return 1
    }
}

# fm_backend_paradev_worktree_path: the worktree path of the exact, unarchived
# workspace <workspace-id>.
fm_backend_paradev_worktree_path() {  # <workspace-id>
  local ws=${1:-} out path
  fm_backend_paradev_id_valid "$ws" || { echo "error: missing or malformed Paradev workspace id; cannot resolve worktree path" >&2; return 1; }
  fm_backend_paradev_tool_check || return 1
  out=$(superset workspaces get "$ws" --local --json) || return 1
  path=$(printf '%s' "$out" | jq -r --arg w "$ws" \
    'select(.id == $w and .archivedAt == null) | .worktreePath | strings' 2>/dev/null) || path=
  [ -n "$path" ] || {
    echo "error: paradev workspaces get did not return a live worktree path for $ws" >&2
    return 1
  }
  printf '%s' "$path"
}

# fm_backend_paradev_busy_state: Paradev's native agent state, from the
# harness hooks Paradev installs: working is busy; idle and blocked pass
# through; starting (hooks never loaded), exited, none, or a failed read is
# unknown.
fm_backend_paradev_busy_state() {  # <target>
  local out state
  fm_backend_paradev_split_target "$1" 2>/dev/null || { printf 'unknown'; return 0; }
  if ! command -v superset >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    printf 'unknown'
    return 0
  fi
  out=$(superset agents explain --local --workspace "$FM_PARADEV_WS" \
    --terminal "$FM_PARADEV_TERM" --json 2>/dev/null) || { printf 'unknown'; return 0; }
  state=$(printf '%s' "$out" | jq -r '.state | strings' 2>/dev/null) || state=
  case "$state" in
    working) printf 'busy' ;;
    idle|blocked) printf '%s' "$state" ;;
    *) printf 'unknown' ;;
  esac
}
