#!/usr/bin/env bash
# bin/backends/orca.sh - the Orca terminal session-provider adapter (daemon-direct).
#
# P4 replacement: this adapter talks to the Orca terminal daemon directly over its
# Unix socket via bin/fmod (a small firstmate-owned Python client) instead of
# shelling out to the `orca` CLI. The CLI could not run while the Orca GUI held
# the single-instance lock; the daemon is the same transport the GUI itself uses
# and is reachable regardless of GUI state. Every function in this file keeps
# its existing signature; only the implementations changed. fm-backend.sh, the
# spawn script, the peek script, the teardown script, and the watcher's busy
# detection all see the same adapter contract they saw before, so they did not
# need to change.
#
# Orca owns both the task worktree and the terminal endpoint. The worktree is
# acquired through `git worktree add` (the daemon has no worktree primitive and
# the broken `orca worktree create` CLI is what drove this rewrite); the
# terminal is acquired through the daemon's `createOrAttach` RPC. Escape key
# support remains unsupported because the daemon's write primitive cannot
# distinguish Escape from any other byte sequence without a key-encoder the
# daemon does not expose.
#
# Target string shape: a stable Orca terminal id of the form `fm-<task-name>`.
# The id is also the daemon session id, so reattach is automatic.

fm_backend_orca_tool_check() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "error: backend=orca selected but 'python3' is not installed" >&2
    return 1
  fi
  if ! command -v fmod >/dev/null 2>&1; then
    # Fall back to firstmate's own bin/fmod if it isn't on PATH. The adapter
    # is sourced from bin/backends/orca.sh, so ../fmod from that location is
    # bin/fmod relative to FM_HOME.
    local here_self="${BASH_SOURCE[0]:-$0}"
    local here_dir
    here_dir=$(cd "$(dirname "$here_self")" && pwd)
    local home_fmod="$here_dir/../fmod"
    if [ -x "$home_fmod" ]; then
      export PATH="$here_dir/..:$PATH"
      hash -r 2>/dev/null || true
    else
      echo "error: backend=orca selected but 'fmod' is not installed (tried PATH and $home_fmod)" >&2
      return 1
    fi
  fi
  command -v fmod >/dev/null 2>&1 || { echo "error: backend=orca selected but 'fmod' is not installed" >&2; return 1; }
}

# fm_backend_orca_runtime_check: verify the orca daemon is reachable and answers
# a ping. Replaces the old `orca status --json` check that died whenever the
# Orca GUI held the single-instance lock.
fm_backend_orca_runtime_check() {
  fm_backend_orca_tool_check || return 1
  local info
  if ! info=$(fmod info 2>/dev/null); then
    echo "error: backend=orca selected but 'fmod info' failed; is the orca daemon running?" >&2
    return 1
  fi
  if ! printf '%s' "$info" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("daemon_reachable") is True else 1)' 2>/dev/null; then
    echo "error: backend=orca selected but the orca daemon is not reachable (fmod info said: $info)" >&2
    return 1
  fi
}

# fm_backend_orca_session_id_of <window-name>: the deterministic session
# id we use for both daemon-side createOrAttach and our later write/snapshot/
# kill calls. fm-spawn always passes the window name in the canonical
# `fm-<id>` form (see fm-spawn.sh line 659: `W="fm-$ID"`); we use it
# verbatim as the session id so the orca GUI shows the same identifier
# firstmate's meta records. Re-prefixing here produced `fm-fm-...` for
# every task and broke the symmetry between meta and fmod list output.
fm_backend_orca_session_id_of() {  # <window-name>
  printf '%s' "$1"
}

fm_backend_orca_worktree_dir() {  # <project-path> <name>
  local project=$1 name=$2 project_parent project_name home_guess
  project_parent=$(dirname "$project")
  project_name=$(basename "$project")
  if [ "$(basename "$project_parent")" = projects ]; then
    home_guess=$(dirname "$project_parent")
  else
    home_guess=$project_parent
  fi
  printf '%s/state/orca-worktrees/%s/%s' "$home_guess" "$project_name" "$name"
}

# fm_backend_orca_create_terminal <session-id> <cwd> <title>: createOrAttach
# via fmod. Returns 0 on success; non-zero on any daemon-side error. Always
# passes --shell-ready so the daemon's shell-ready barrier (bash/zsh rcfile
# load) blocks until the prompt is actually visible, which keeps the post-
# create `treehouse get` race out of the harness path. Note: the orca backend
# does NOT run `treehouse get` — the worktree IS the project — so this only
# protects against a `command` injected at create time (currently unused).
fm_backend_orca_create_terminal() {  # <session-id> <cwd> <title>
  local session_id=$1 cwd=$2 title=$3 actual_cwd
  fm_backend_orca_tool_check || return 1
  fmod create "$session_id" --cwd "$cwd" --cols 200 --rows 50 --shell-ready >/dev/null || return 1
  actual_cwd=$(fmod get-cwd "$session_id") || return 1
  if [ "$actual_cwd" != "$cwd" ]; then
    echo "error: orca session $session_id attached at $actual_cwd, expected $cwd" >&2
    return 1
  fi
}

# fm_backend_orca_worktree_create: see header. Returns TAB-separated
#   <wt-id>\t<wt-path>[\t<terminal>]
# where wt-id and wt-path are the same string (git's worktree identity IS its
# path). Exit 0 on success; exit 1 on any failure after which the caller
# bails; never exit 2 (the old CLI returned 2 to signal "worktree failed but
# terminal created, please clean up" - that path is gone because the daemon
# createOrAttach is atomic).
fm_backend_orca_worktree_create() {  # <project-path> <name>
  local project=$1 name=$2 wt_path session_id create_out actual_cwd branch start_head current_head add_err

  fm_backend_orca_tool_check || return 1

  if ! git -C "$project" rev-parse --git-dir >/dev/null 2>&1; then
    echo "error: backend=orca requires $project to be a git repo (orca owns worktrees)" >&2
    return 1
  fi

  wt_path=$(fm_backend_orca_worktree_dir "$project" "$name")
  branch="fm/$name"
  if [ -e "$wt_path" ]; then
    echo "error: orca backend refused to create $wt_path: already exists" >&2
    return 1
  fi
  mkdir -p "$(dirname "$wt_path")" || { echo "error: cannot create $(dirname "$wt_path")" >&2; return 1; }

  # git worktree add with a fresh fm/<name> branch off the project's HEAD.
  # --detach would leave the branch in place without checking it out; we want
  # the branch so the crewmate commits land on something addressable.
  # stdout is silenced - git prints "HEAD is now at ..." to stdout on success,
  # which would corrupt the TAB-separated adapter contract on stdout.
  start_head=$(git -C "$project" rev-parse HEAD) || { echo "error: cannot resolve HEAD for $project" >&2; return 1; }
  add_err=$(mktemp "${TMPDIR:-/tmp}/fm-orca-wt.XXXXXX") || { echo "error: cannot create temporary file for git worktree diagnostics" >&2; return 1; }
  if ! git -C "$project" worktree add -b "$branch" "$wt_path" HEAD >/dev/null 2>"$add_err"; then
    echo "error: git worktree add failed for $wt_path:" >&2
    cat "$add_err" >&2
    rm -f "$add_err"
    return 1
  fi
  rm -f "$add_err"

  session_id=$(fm_backend_orca_session_id_of "$name")
  if ! create_out=$(fmod create "$session_id" --cwd "$wt_path" --cols 200 --rows 50 --shell-ready 2>&1); then
    echo "error: fmod create failed for $session_id at $wt_path:" >&2
    printf '%s\n' "$create_out" >&2
    git -C "$project" worktree remove --force "$wt_path" 2>/dev/null || true
    current_head=$(git -C "$project" rev-parse --verify "$branch" 2>/dev/null || true)
    if [ "$current_head" = "$start_head" ]; then
      git -C "$project" branch -D "$branch" >/dev/null 2>&1 || true
    fi
    return 1
  fi
  if ! actual_cwd=$(fmod get-cwd "$session_id" 2>&1); then
    echo "error: fmod get-cwd failed for $session_id after create:" >&2
    printf '%s\n' "$actual_cwd" >&2
    git -C "$project" worktree remove --force "$wt_path" 2>/dev/null || true
    current_head=$(git -C "$project" rev-parse --verify "$branch" 2>/dev/null || true)
    if [ "$current_head" = "$start_head" ]; then
      git -C "$project" branch -D "$branch" >/dev/null 2>&1 || true
    fi
    return 1
  fi
  if [ "$actual_cwd" != "$wt_path" ]; then
    fmod kill "$session_id" --immediate >/dev/null 2>&1 || true
    if ! create_out=$(fmod create "$session_id" --cwd "$wt_path" --cols 200 --rows 50 --shell-ready 2>&1); then
      echo "error: fmod recreate failed for $session_id at $wt_path after stale attach at $actual_cwd:" >&2
      printf '%s\n' "$create_out" >&2
      git -C "$project" worktree remove --force "$wt_path" 2>/dev/null || true
      current_head=$(git -C "$project" rev-parse --verify "$branch" 2>/dev/null || true)
      if [ "$current_head" = "$start_head" ]; then
        git -C "$project" branch -D "$branch" >/dev/null 2>&1 || true
      fi
      return 1
    fi
    if ! actual_cwd=$(fmod get-cwd "$session_id" 2>&1); then
      echo "error: fmod get-cwd failed for $session_id after recreate:" >&2
      printf '%s\n' "$actual_cwd" >&2
      git -C "$project" worktree remove --force "$wt_path" 2>/dev/null || true
      current_head=$(git -C "$project" rev-parse --verify "$branch" 2>/dev/null || true)
      if [ "$current_head" = "$start_head" ]; then
        git -C "$project" branch -D "$branch" >/dev/null 2>&1 || true
      fi
      return 1
    fi
    if [ "$actual_cwd" != "$wt_path" ]; then
      echo "error: orca session $session_id attached at $actual_cwd, expected $wt_path" >&2
      fmod kill "$session_id" --immediate >/dev/null 2>&1 || true
      git -C "$project" worktree remove --force "$wt_path" 2>/dev/null || true
      current_head=$(git -C "$project" rev-parse --verify "$branch" 2>/dev/null || true)
      if [ "$current_head" = "$start_head" ]; then
        git -C "$project" branch -D "$branch" >/dev/null 2>&1 || true
      fi
      return 1
    fi
  fi

  # Stash the session id in the worktree so remove can find the terminal.
  printf '%s\n' "$session_id" > "$wt_path/.fm-orca-session"

  # Adapter contract: TAB-separated wt_id \t wt_path [\t terminal].
  printf '%s\t%s\t%s' "$wt_path" "$wt_path" "$session_id"
}

# fm_backend_orca_terminal_create: spawn a terminal at an EXISTING worktree.
# Used when the worktree was created by some other path (e.g. a manual `git
# worktree add`) and the caller wants an orca endpoint there. Keeps the old
# signature so fm-spawn's fallback path keeps working unchanged.
fm_backend_orca_terminal_create() {  # <wt-id> <title>
  local wt_id=$1 title=$2 cwd session_id
  cwd=$wt_id
  session_id=$(fm_backend_orca_session_id_of "$title")
  if ! fm_backend_orca_create_terminal "$session_id" "$cwd" "$title"; then
    echo "error: orca backend failed to create terminal $session_id at $cwd" >&2
    return 1
  fi
  printf '%s' "$session_id"
}

# fm_backend_orca_send_text_line <terminal> <text>: type <text> and submit.
# The terminal is the orca session id (`fm-<name>`); we resolve it through
# fmod's write RPC with a trailing newline (the daemon's createOrAttach
# doesn't add a final \n to injected commands, so we own that boundary).
# NOTE: $'\n' is bash ANSI-C quoting; "$2\n" is the literal 2-char sequence
# `\` + `n`, which is the bug we just fixed. Do not "simplify" this back.
fm_backend_orca_send_text_line() {  # <terminal> <text>
  fm_backend_orca_tool_check || return 1
  fmod write "$1" --data "$2"$'\n' >/dev/null
}

# fm_backend_orca_send_literal <terminal> <text>: same path, no Enter. Used for
# the literal launch-command send; the caller sends Enter separately.
fm_backend_orca_send_literal() {  # <terminal> <text>
  fm_backend_orca_tool_check || return 1
  fmod write "$1" --data "$2" >/dev/null
}

# fm_backend_orca_remove_worktree <wt-id>: tear down both the worktree and its
# terminal. Worktree-first is intentional: removing the worktree fails fast if
# the path doesn't exist or has unique commits, so we can no-op the terminal
# kill cleanly. Terminal kill is best-effort.
fm_backend_orca_remove_worktree() {  # <wt-id>
  local wt_path=${1:-} session_id main_repo gitdir_line git_common_dir branch project_name bucket state_dir home_guess
  [ -n "$wt_path" ] || { echo "error: missing Orca worktree id; cannot remove worktree" >&2; return 1; }
  fm_backend_orca_tool_check || return 1

  branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [ -z "$branch" ] || [ "$branch" = HEAD ]; then
    branch="fm/$(basename "$wt_path")"
  fi
  if [ -f "$wt_path/.fm-orca-session" ]; then
    session_id=$(cat "$wt_path/.fm-orca-session")
  else
    # Fall back to deriving the session id from basename. fm-spawn always
    # names worktrees `fm-<id>`, so basename yields the canonical session id
    # directly. Used only when the marker file is missing (legacy CLI
    # worktree, or a marker delete race).
    session_id="$(basename "$wt_path")"
  fi
  # git worktrees carry their main-repo pointer in `<wt>/.git` (a file, not
  # a directory). Parse it; without that file we cannot find the main repo
  # from the worktree path alone.
  main_repo=
  if [ -f "$wt_path/.git" ]; then
    gitdir_line=$(cat "$wt_path/.git" 2>/dev/null || true)
    main_repo=$(printf '%s\n' "$gitdir_line" | sed -n 's|^gitdir: \(.*\)/.git/worktrees/[^/]*$|\1|p' | head -1)
  fi
  if [ -z "$main_repo" ]; then
    git_common_dir=$(git -C "$wt_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    if [ -n "$git_common_dir" ]; then
      main_repo=$(dirname "$git_common_dir")
    fi
  fi
  if [ -z "$main_repo" ]; then
    project_name=$(basename "$(dirname "$wt_path")")
    bucket=$(dirname "$(dirname "$wt_path")")
    state_dir=$(dirname "$bucket")
    home_guess=$(dirname "$state_dir")
    if git -C "$home_guess/projects/$project_name" rev-parse --git-dir >/dev/null 2>&1; then
      main_repo="$home_guess/projects/$project_name"
    elif git -C "$home_guess/$project_name" rev-parse --git-dir >/dev/null 2>&1; then
      main_repo="$home_guess/$project_name"
    fi
  fi
  if [ -n "$main_repo" ] && [ -d "$main_repo" ]; then
    git -C "$main_repo" worktree remove --force "$wt_path" || return 1
    case "$branch" in
      fm/*) git -C "$main_repo" branch -D -- "$branch" >/dev/null 2>&1 || true ;;
    esac
    fmod kill "$session_id" >/dev/null 2>&1 || true
    return 0
  fi
  git -C "$wt_path" worktree remove --force "$wt_path" || return 1
  fmod kill "$session_id" >/dev/null 2>&1 || true
}

# fm_backend_orca_worktree_path <wt-id>: the worktree IS its path. Kept for
# parity with the old CLI's resolver.
fm_backend_orca_worktree_path() {
  local wt_id=${1:-}
  [ -n "$wt_id" ] || { echo "error: missing Orca worktree id; cannot resolve worktree path" >&2; return 1; }
  printf '%s' "$wt_id"
}

# fm_backend_orca_kill <terminal>: best-effort terminal kill; teardown already
# removes the worktree, so this is for cases where the worktree stays but the
# terminal should be torn down (currently unused but kept for parity).
fm_backend_orca_kill() {  # <terminal-id>
  fm_backend_orca_tool_check || return 0
  fmod kill "$1" >/dev/null 2>&1 || true
}

# fm_backend_orca_current_path <terminal>: live cwd via the daemon's getCwd
# RPC. Mirrors fm-tmux's pane-current-path read.
fm_backend_orca_current_path() {  # <terminal>
  fm_backend_orca_tool_check || return 1
  fmod get-cwd "$1"
}

# fm_backend_orca_capture <terminal> <lines>: peek the latest snapshot, ANSI
# stripped, truncated to last N non-empty lines. Mirrors tmux's
# `capture-pane -p -S -N`.
fm_backend_orca_capture() {  # <terminal-id> <lines>
  local terminal=$1 lines=${2:-40}
  fm_backend_orca_tool_check || return 1
  fmod snapshot "$terminal" --strip-ansi --lines "$lines"
}

# fm_backend_orca_send_key <terminal> <key>: Enter or C-c only (the only keys
# firstmate's harness layer actually uses).
# NOTE: $'\n' and $'\003' are bash ANSI-C escapes. $(printf '\n') would
# strip the trailing newline (bash command-substitution rule); do not switch
# to printf in a subshell here.
fm_backend_orca_send_key() {  # <terminal-id> <key>
  fm_backend_orca_tool_check || return 1
  case "$2" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fmod write "$1" --data $'\003' >/dev/null
      ;;
    Enter|enter)
      fmod write "$1" --data $'\n' >/dev/null
      ;;
    *)
      echo "error: unsupported Orca key '$2'" >&2
      return 1
      ;;
  esac
}

FM_BACKEND_ORCA_COMPOSER_LINES=${FM_BACKEND_ORCA_COMPOSER_LINES:-200}
FM_BACKEND_ORCA_IDLE_RE=${FM_BACKEND_ORCA_IDLE_RE:-'^(Type a message\.\.\.|Ask anything\.\.\..*|Type a message….*)$'}

# fm_backend_orca_composer_state <terminal>: classify the composer's bordered
# row as empty|pending|unknown. Mirrors the old CLI version: read the last
# FM_BACKEND_ORCA_COMPOSER_LINES lines, find the bordered row, strip borders,
# decide.
#
# Two bordered-row shapes are supported:
#   1. Full box (claude/codex/pi style): both leading AND trailing vertical,
#      e.g. "│ > hello cap │", "┃ > hi ┃", "| > hi |".
#   2. Left-only border (opencode style): just a leading vertical, e.g.
#      "┃  hello world", "┃  Ask anything...". The matching bottom border
#      renders as "╹▀▀▀..." rather than a closing vertical.
# We accept either; rows starting with the horizontal-border markers "╹",
# "▀", "═", "─", "╼", "╾" are explicitly skipped so the bottom of the
# opencode composer is never mistaken for a content row.
fm_backend_orca_composer_state() {  # <terminal-id> -> empty|pending|unknown
  local terminal=$1 cap line trimmed stripped="" found=0 empty_bordered="__fm_orca_empty_bordered__"
  fm_backend_orca_tool_check || { printf 'unknown'; return 0; }
  cap=$(fmod snapshot "$terminal" --strip-ansi --lines "$FM_BACKEND_ORCA_COMPOSER_LINES" 2>/dev/null) || { printf 'unknown'; return 0; }
  # Pass 1: collect bordered content rows so we can pick the right one.
  # In opencode's TUI, the bottom region contains TWO bordered content rows:
  # the actual composer ("┃  hello world") and a footer line ("┃  Build ·
  # ...") sitting above the ╹▀▀▀... underline. The composer is the bordered
  # content row whose IMMEDIATE NEXT LINE is also bordered (i.e. not the
  # horizontal underline that follows the footer). The legacy claude/codex
  # shape has only one bordered content row, which trivially satisfies
  # this rule.
  local -a bordered=()
  local inside=""
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] || { bordered+=(""); continue; }
    case "${trimmed:0:1}" in
      '╹'|'▀'|'═'|'─'|'╼'|'╾'|'╭'|'╮'|'╰'|'╯') bordered+=(""); continue ;;
    esac
    case "$trimmed" in
      '│'*'│'|'┃'*'┃'|'|'*'|')
        inside=$trimmed
        inside=${inside//│/}; inside=${inside//┃/}; inside=${inside//|/}
        inside="${inside#"${inside%%[![:space:]]*}"}"
        inside="${inside%"${inside##*[![:space:]]}"}"
        if [ -n "$inside" ]; then bordered+=("$trimmed"); else bordered+=("$empty_bordered"); fi
        ;;
      '│'*|'┃'*)
        inside=$trimmed
        inside=${inside//│/}; inside=${inside//┃/}; inside=${inside//|/}
        inside="${inside#"${inside%%[![:space:]]*}"}"
        inside="${inside%"${inside##*[![:space:]]}"}"
        if [ -n "$inside" ]; then bordered+=("$trimmed"); else bordered+=("$empty_bordered"); fi
        ;;
      *) bordered+=("") ;;
    esac
  done <<< "$cap"
  local i n=${#bordered[@]}
  for ((i = n - 1; i >= 0; i--)); do
    [ -n "${bordered[$i]:-}" ] || continue
    [ "${bordered[$i]}" != "$empty_bordered" ] || continue
    # Does the NEXT line also have a bordered content row? If yes, this
    # is the composer (the line above is also bordered because the box
    # has decorative empty ┃ rows around the content). If no, the next
    # line is the underline and this is the footer, so step up.
    if (( i + 1 < n )) && [ -n "${bordered[$((i + 1))]:-}" ]; then
      stripped=${bordered[$i]}
      found=1
      break
    fi
  done
  # Fallback: if no bordered content row was paired with another, take the
  # LAST bordered content row we found (legacy single-region shapes).
  if [ "$found" -eq 1 ]; then
    :
  else
    for ((i = n - 1; i >= 0; i--)); do
      [ -n "${bordered[$i]:-}" ] || continue
      [ "${bordered[$i]}" != "$empty_bordered" ] || continue
      stripped=${bordered[$i]}
      found=1
      break
    done
  fi
  [ "$found" -eq 1 ] || { printf 'unknown'; return 0; }
  stripped=${stripped//│/}
  stripped=${stripped//┃/}
  stripped=${stripped//|/}
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  case "$stripped" in
    '❯'|'>'|'$'|'%'|'#') printf 'empty'; return 0 ;;
  esac
  case "$stripped" in
    '❯ '*|'> '*|'$ '*|'% '*|'# '*) stripped=${stripped#??} ;;
    '❯'*|'>'*|'$'*|'%'*|'#'*) stripped=${stripped#?} ;;
  esac
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  [ -n "$stripped" ] || { printf 'empty'; return 0; }
  if printf '%s' "$stripped" | grep -qE "$FM_BACKEND_ORCA_IDLE_RE"; then
    printf 'empty'; return 0
  fi
  printf 'pending'
}

# fm_backend_orca_send_text_submit <terminal> <text> <retries> <enter-sleep>
# <settle>: type once, then retry Enter until composer reads empty. Mirrors
# fm_tmux_submit_core's contract.
fm_backend_orca_send_text_submit() {  # <terminal> <text> <retries> <enter-sleep> <settle>
  local terminal=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 i=0 state
  fm_backend_orca_tool_check || { printf 'send-failed'; return 0; }
  fm_backend_orca_send_literal "$terminal" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  while :; do
    fm_backend_orca_send_key "$terminal" Enter || { printf 'send-failed'; return 0; }
    sleep "$sleep_s"
    state=$(fm_backend_orca_composer_state "$terminal")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}
