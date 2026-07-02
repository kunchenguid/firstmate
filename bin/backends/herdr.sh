#!/usr/bin/env bash
# bin/backends/herdr.sh - the herdr session-provider adapter (EXPERIMENTAL).
#
# Design: data/fm-backend-design-d7/herdr-addendum.md ("Interface mapping",
# decisions D1-D6) and the empirical verification recorded in
# data/fm-backend-design-d7/herdr-verification-p2.md (real herdr v0.7.1,
# protocol 14, macOS aarch64). Herdr is a session provider ONLY (D3): the
# worktree provider stays treehouse, exactly like tmux. Sourced only through
# bin/fm-backend.sh's fm_backend_source, never directly.
#
# Container shape (D4, decided empirically - see herdr-verification-p2.md
# "Task container shape"): ONE herdr workspace labeled "firstmate", ONE herdr
# TAB per task inside it. This mirrors tmux's "one session, one window per
# task" model exactly, so target resolution and the human-watch story both
# stay parallel to the tmux adapter.
#
# Target string shape: "<herdr-session>:<pane-id>", e.g. "default:w1:p2" (the
# pane id itself contains a colon; the session is always the FIRST field, the
# remainder is the whole pane id - fm_backend_herdr_parse_target splits on the
# first colon only). This is the value stored in a herdr task's meta window=
# field and is what fm_backend_resolve_selector already returns unchanged for
# both the fm-<id> and explicit backend-target forms (that function has no
# herdr-specific logic; it just returns meta's window= verbatim).
#
# Recovery/orphan discovery (ids may not deterministically match live state
# after a server restart in a differently-configured session; see the
# verification doc) uses LABEL matching (fm-<id> tab labels), never trusts a
# stored pane id blindly: fm_backend_herdr_list_live.
#
# Requires: herdr (CLI + socket), jq (JSON parsing). Both are gated behind
# selecting this backend; bin/fm-bootstrap.sh's core tool list is unaffected.

FM_BACKEND_HERDR_MIN_PROTOCOL=14
FM_BACKEND_HERDR_WORKSPACE_LABEL="firstmate"

# fm_backend_herdr_tool_check: refuse loudly if herdr or jq is missing.
fm_backend_herdr_tool_check() {
  command -v herdr >/dev/null 2>&1 || { echo "error: backend=herdr selected but the 'herdr' CLI is not installed (https://herdr.dev)" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=herdr selected but 'jq' is not installed (required to parse herdr's JSON output)" >&2; return 1; }
  return 0
}

# fm_backend_herdr_version_check: refuse loudly on a missing/incompatible
# herdr client. Verified locally: v0.7.1, protocol 14 (herdr status --json's
# .client.protocol; client info is session-independent, unlike .server).
fm_backend_herdr_version_check() {
  fm_backend_herdr_tool_check || return 1
  local status protocol version
  status=$(herdr status --json 2>/dev/null) || { echo "error: 'herdr status --json' failed; is herdr installed correctly?" >&2; return 1; }
  protocol=$(printf '%s' "$status" | jq -r '.client.protocol // empty' 2>/dev/null)
  version=$(printf '%s' "$status" | jq -r '.client.version // empty' 2>/dev/null)
  case "$protocol" in
    ''|*[!0-9]*)
      echo "error: could not read herdr client protocol from 'herdr status --json'; refusing to use an unverified herdr build" >&2
      return 1
      ;;
  esac
  if [ "$protocol" -lt "$FM_BACKEND_HERDR_MIN_PROTOCOL" ]; then
    echo "error: herdr protocol $protocol (version ${version:-unknown}) is older than the verified minimum $FM_BACKEND_HERDR_MIN_PROTOCOL; update herdr (herdr update) before using backend=herdr" >&2
    return 1
  fi
  return 0
}

# fm_backend_herdr_session: resolve which named herdr session this spawn/op
# uses. HERDR_SESSION mirrors tmux's $TMUX ambient-selection: an operator (or
# firstmate's own isolated test harness) sets it explicitly; absent means
# herdr's own "default" session.
fm_backend_herdr_session() {
  printf '%s' "${HERDR_SESSION:-default}"
}

# fm_backend_herdr_server_ensure: start the herdr server for <session>
# headless (no TUI client) if not already running, mirroring tmux's `tmux
# has-session || tmux new-session -d`. Verified: a bare socket CLI call does
# NOT auto-start the server, so this must run before any workspace/tab/pane
# call. Bounded poll for the server to report running.
fm_backend_herdr_server_ensure() {  # <session>
  local session=$1 running out i
  running=$(HERDR_SESSION="$session" herdr status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
  [ "$running" = "true" ] && return 0
  ( HERDR_SESSION="$session" herdr server >/dev/null 2>&1 & ) || return 1
  for i in $(seq 1 20); do
    running=$(HERDR_SESSION="$session" herdr status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
    [ "$running" = "true" ] && return 0
    sleep 0.5
  done
  echo "error: herdr server for session '$session' did not report running within 10s" >&2
  return 1
}

# fm_backend_herdr_workspace_find: the "firstmate" workspace's id inside
# <session>, or empty (never creates). Read-only, safe for recovery/list paths.
fm_backend_herdr_workspace_find() {  # <session>
  local session=$1 list
  list=$(HERDR_SESSION="$session" herdr workspace list 2>/dev/null) || return 0
  printf '%s' "$list" | jq -r --arg label "$FM_BACKEND_HERDR_WORKSPACE_LABEL" \
    '.result.workspaces[]? | select(.label == $label) | .workspace_id' 2>/dev/null | head -1
}

# fm_backend_herdr_workspace_ensure: the persistent "firstmate" workspace
# inside <session>, creating it in <cwd> if absent. Echoes its workspace_id.
fm_backend_herdr_workspace_ensure() {  # <session> <cwd>
  local session=$1 cwd=$2 wsid out
  wsid=$(fm_backend_herdr_workspace_find "$session")
  if [ -n "$wsid" ]; then
    printf '%s' "$wsid"
    return 0
  fi
  out=$(HERDR_SESSION="$session" herdr workspace create --cwd "$cwd" --label "$FM_BACKEND_HERDR_WORKSPACE_LABEL" 2>/dev/null) || return 1
  wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  [ -n "$wsid" ] || return 1
  printf '%s' "$wsid"
}

# fm_backend_herdr_container_ensure: the full spawn-time container-ensure
# sequence (version gate, server, workspace). Echoes "<session>:<workspace_id>"
# for fm_backend_herdr_create_task.
fm_backend_herdr_container_ensure() {  # <cwd-for-a-fresh-workspace>
  local cwd=${1:-$PWD} session wsid
  fm_backend_herdr_version_check || return 1
  session=$(fm_backend_herdr_session)
  fm_backend_herdr_server_ensure "$session" || return 1
  wsid=$(fm_backend_herdr_workspace_ensure "$session" "$cwd") || { echo "error: failed to ensure herdr workspace '$FM_BACKEND_HERDR_WORKSPACE_LABEL' in session '$session'" >&2; return 1; }
  printf '%s:%s' "$session" "$wsid"
}

# fm_backend_herdr_create_task: create the task's tab (one pane) in
# <container> ("session:workspace_id"), refusing an existing <label>. Herdr
# does NOT enforce label uniqueness itself (verified: two tabs can share a
# label), so the duplicate check is ours, mirroring tmux's manual check.
# Echoes "<tab_id> <pane_id>" on success.
fm_backend_herdr_create_task() {  # <container> <label> <cwd>
  local container=$1 label=$2 cwd=$3 session wsid list dup out tab_id pane_id
  session=${container%%:*}
  wsid=${container#*:}
  list=$(HERDR_SESSION="$session" herdr tab list --workspace "$wsid" 2>/dev/null) || return 1
  dup=$(printf '%s' "$list" | jq -r --arg label "$label" '.result.tabs[]? | select(.label == $label) | .tab_id' 2>/dev/null | head -1)
  if [ -n "$dup" ]; then
    echo "error: herdr tab '$label' already exists in workspace $wsid (session $session)" >&2
    return 1
  fi
  out=$(HERDR_SESSION="$session" herdr tab create --workspace "$wsid" --cwd "$cwd" --label "$label" 2>/dev/null) || return 1
  tab_id=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  pane_id=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$tab_id" ] || [ -z "$pane_id" ]; then
    echo "error: could not parse tab/pane id from herdr tab create output" >&2
    return 1
  fi
  printf '%s %s' "$tab_id" "$pane_id"
}

# fm_backend_herdr_parse_target: split "<session>:<pane_id>" (pane_id itself
# contains a colon, e.g. "w1:p2") on the FIRST colon only. Sets
# FM_BACKEND_HERDR_SESSION and FM_BACKEND_HERDR_PANE for the caller.
fm_backend_herdr_parse_target() {  # <target>
  local target=$1
  FM_BACKEND_HERDR_SESSION=${target%%:*}
  FM_BACKEND_HERDR_PANE=${target#*:}
  [ -n "$FM_BACKEND_HERDR_SESSION" ] && [ -n "$FM_BACKEND_HERDR_PANE" ] && [ "$FM_BACKEND_HERDR_PANE" != "$target" ]
}

fm_backend_herdr_target_ready() {  # <target>
  fm_backend_herdr_parse_target "$1" || return 1
  fm_backend_herdr_server_ensure "$FM_BACKEND_HERDR_SESSION" || return 1
}

# fm_backend_herdr_current_path: the live FOREGROUND process's cwd, or empty on
# any error. Mirrors tmux's pane_current_path poll used for worktree-path
# discovery after `treehouse get`.
#
# Verified pitfall: `pane get`'s `.result.pane.cwd` is the pane's cwd AT
# CREATION TIME - the top-level shell's cwd - and does NOT update when that
# shell `cd`s or enters a subshell (as `treehouse get` does). Reading it here
# would make fm-spawn.sh's worktree-discovery poll never see the pane "leave"
# the project directory, since `cwd` stays frozen at the original path forever.
# `.result.pane.foreground_cwd` tracks the ACTUALLY RUNNING foreground
# process's cwd instead, which is what changes when `treehouse get` enters its
# worktree subshell - confirmed live against a real treehouse acquisition.
fm_backend_herdr_current_path() {  # <target>
  fm_backend_herdr_target_ready "$1" || return 0
  HERDR_SESSION="$FM_BACKEND_HERDR_SESSION" herdr pane get "$FM_BACKEND_HERDR_PANE" 2>/dev/null \
    | jq -r '.result.pane.foreground_cwd // empty' 2>/dev/null
}

# fm_backend_herdr_send_text_line: send one line of TEXT then submit,
# ATOMICALLY - mirrors tmux's `send-keys -t T text Enter`. Used for the fixed
# spawn-time commands (treehouse get, the GOTMPDIR export). `pane run` types
# the command and submits it in one call (verified).
fm_backend_herdr_send_text_line() {  # <target> <text>
  fm_backend_herdr_target_ready "$1" || return 1
  HERDR_SESSION="$FM_BACKEND_HERDR_SESSION" herdr pane run "$FM_BACKEND_HERDR_PANE" "$2" >/dev/null 2>&1
}

# fm_backend_herdr_send_literal: send TEXT as literal, UNSUBMITTED input - the
# caller sends Enter separately. Mirrors tmux's `send-keys -t T -l text`.
# Verified: `pane send-text` does NOT auto-submit (contrary to the addendum's
# original guess); it behaves exactly like tmux's `-l` literal send.
fm_backend_herdr_send_literal() {  # <target> <text>
  fm_backend_herdr_target_ready "$1" || return 1
  HERDR_SESSION="$FM_BACKEND_HERDR_SESSION" herdr pane send-text "$FM_BACKEND_HERDR_PANE" "$2" >/dev/null 2>&1
}

# fm_backend_herdr_normalize_key: map firstmate's key vocabulary (Enter,
# Escape, C-c, as used by fm-send.sh --key and stuck-crewmate-recovery) onto
# herdr's `pane send-keys` names. Verified empirically: enter, escape/esc, and
# both ctrl+c/C-c all work (case-insensitive on herdr's side, but normalize
# explicitly rather than relying on that).
fm_backend_herdr_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'escape' ;;
    C-c|c-c|ctrl+c|Ctrl+C) printf 'ctrl+c' ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_backend_herdr_send_key: one named special key. Mirrors fm-send.sh's --key
# path (tmux's `send-keys -t T key`).
fm_backend_herdr_send_key() {  # <target> <key>
  fm_backend_herdr_target_ready "$1" || return 1
  local key
  key=$(fm_backend_herdr_normalize_key "$2")
  HERDR_SESSION="$FM_BACKEND_HERDR_SESSION" herdr pane send-keys "$FM_BACKEND_HERDR_PANE" "$key" >/dev/null 2>&1
}

# fm_backend_herdr_capture: bounded plain-text pane capture. Mirrors
# fm-peek.sh's/fm-watch.sh's `tmux capture-pane -p -t T -S -N`. --source recent
# is the closest herdr analogue to tmux's scrollback-bounded capture.
#
# Verified CLI quirk (herdr-verification-p2.md "pane read --lines bug", v0.7.1):
# `pane read --source recent --lines N` returns COMPLETELY EMPTY output when N
# is smaller than the pane's current viewport height (observed threshold ~23
# rows for a default-sized pane), instead of clamping to the last N lines - it
# does not merely ignore the bound, it drops the read entirely. This silently
# broke exactly the small bounded reads this adapter relies on most (a 6-line
# composer-verification read in send_text_submit). Workaround: always request
# a generous fetch far above any realistic viewport height, then trim to the
# caller's requested bound ourselves with `tail`.
fm_backend_herdr_capture() {  # <target> <lines>
  fm_backend_herdr_target_ready "$1" || return 1
  local lines=${2:-200} fetch out
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  fetch=$lines
  case "$fetch" in ''|*[!0-9]*) fetch=200 ;; *) [ "$fetch" -ge 200 ] || fetch=200 ;; esac
  out=$(HERDR_SESSION="$FM_BACKEND_HERDR_SESSION" herdr pane read "$FM_BACKEND_HERDR_PANE" --source recent --lines "$fetch" 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

# fm_backend_herdr_send_text_submit: type <text> into <target> once (raw,
# unsubmitted, via send_literal), then submit with a named Enter key, retried
# (Enter only, never retyped) until the pane visibly changes. Verified hazard
# (herdr-verification-p2.md "slash/$ autocomplete popup"): a `/`- or
# `$`-prefixed send opens a completion popup within ~0.1s, exactly like tmux's
# claude/codex popups, so the caller's <settle> before the first Enter matters
# here the same way it does for tmux.
#
# Verification strategy differs from tmux's ANSI-ghost-aware composer read
# (herdr's CLI has no cursor-row/ANSI capture primitive exposed): capture the
# pane right after typing (before any Enter) as the TYPED baseline, then after
# each Enter attempt capture again - if the capture is UNCHANGED from the typed
# baseline, nothing happened (Enter was swallowed) and we retry; the moment the
# capture changes (output appeared, prompt cleared, a popup closed and text
# resolved), the send is considered submitted. Echoes empty|pending|unknown|
# send-failed, the SAME vocabulary fm-send.sh already branches on for tmux.
fm_backend_herdr_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 typed after i=0
  fm_backend_herdr_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_herdr_send_literal "$target" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  typed=$(fm_backend_herdr_capture "$target" 6) || { printf 'unknown'; return 0; }
  while :; do
    fm_backend_herdr_send_key "$target" Enter || true
    sleep "$sleep_s"
    after=$(fm_backend_herdr_capture "$target" 6) || { printf 'unknown'; return 0; }
    if [ "$after" != "$typed" ]; then
      printf 'empty'
      return 0
    fi
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

# fm_backend_herdr_kill: remove the task's pane, best-effort (mirrors
# tmux-kill-window's `|| true` contract). Verified: closing a tab's only pane
# closes the tab too, so a separate tab close is unnecessary.
fm_backend_herdr_kill() {  # <target>
  fm_backend_herdr_target_ready "$1" || return 0
  HERDR_SESSION="$FM_BACKEND_HERDR_SESSION" herdr pane close "$FM_BACKEND_HERDR_PANE" >/dev/null 2>&1 || true
}

# fm_backend_herdr_busy_state: semantic busy state from herdr's native
# agent-state detection (agent.get), the "first backend where fm_session_busy_state
# gets real semantics" per the design report. working -> busy (actively
# generating); idle/done -> idle; blocked -> idle (a blocked agent is stuck
# waiting on the human, not grinding - the watcher should treat it like a
# stale pane needing attention, not suppress it as busy); unknown/unparseable
# -> unknown, the caller's cue to fall back to pane-regex detection.
fm_backend_herdr_busy_state() {  # <target>
  fm_backend_herdr_target_ready "$1" || { printf 'unknown'; return 0; }
  local out status
  out=$(HERDR_SESSION="$FM_BACKEND_HERDR_SESSION" herdr agent get "$FM_BACKEND_HERDR_PANE" 2>/dev/null) || { printf 'unknown'; return 0; }
  status=$(printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  case "$status" in
    working) printf 'busy' ;;
    idle|done) printf 'idle' ;;
    blocked) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_herdr_pane_for_tab: the root pane id for <tab_id> in <workspace_id>
# of <session>, via one pane list call filtered by tab_id (never assumes a
# tab-number/pane-number correspondence - herdr numbers them independently).
fm_backend_herdr_pane_for_tab() {  # <session> <workspace_id> <tab_id>
  local session=$1 wsid=$2 tab_id=$3 panes
  panes=$(HERDR_SESSION="$session" herdr pane list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -r --arg tab "$tab_id" \
    '.result.panes[]? | select(.tab_id == $tab) | .pane_id' 2>/dev/null | head -1
}

# fm_backend_herdr_resolve_bare_selector: the live-tab-listing fallback for an
# ad hoc selector with no meta (mirrors tmux's list-windows grep). Searches
# every RUNNING named herdr session (herdr session list) for a tab whose label
# matches <name>, since herdr sessions are not addressed by one ambient
# server the way a single tmux server is. Rare path in practice (herdr tasks
# normally carry meta), best-effort.
fm_backend_herdr_resolve_bare_selector() {  # <name>
  local name=$1 sessions session tabs tab_id wsid pane_id
  sessions=$(herdr session list --json 2>/dev/null | jq -r '.sessions[]? | select(.running == true) | .name' 2>/dev/null)
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    tabs=$(HERDR_SESSION="$session" herdr tab list 2>/dev/null) || continue
    tab_id=$(printf '%s' "$tabs" | jq -r --arg label "$name" \
      '.result.tabs[]? | select(.label == $label) | .tab_id' 2>/dev/null | head -1)
    [ -n "$tab_id" ] || continue
    wsid=$(printf '%s' "$tabs" | jq -r --arg tab "$tab_id" '.result.tabs[]? | select(.tab_id == $tab) | .workspace_id' 2>/dev/null | head -1)
    [ -n "$wsid" ] || continue
    pane_id=$(fm_backend_herdr_pane_for_tab "$session" "$wsid" "$tab_id") || continue
    [ -n "$pane_id" ] || continue
    printf '%s:%s' "$session" "$pane_id"
    return 0
  done <<EOF
$sessions
EOF
  echo "error: no herdr tab named $name in any running session" >&2
  return 1
}

# fm_backend_herdr_list_live: recovery/orphan discovery. Lists every tab whose
# label looks like a firstmate task window (fm-<id>) in <session>'s
# "firstmate" workspace, by LABEL - never by trusting a stored pane id, since
# ids are not guaranteed stable across every server lifecycle (see
# herdr-verification-p2.md "ID stability"). Read-only: a session/workspace
# that does not exist yet simply lists nothing. One
# "<session>:<pane_id>\t<label>" line per live task tab.
fm_backend_herdr_list_live() {  # <session>
  local session=$1 wsid tabs tab_id label pane_id
  wsid=$(fm_backend_herdr_workspace_find "$session") || return 0
  [ -n "$wsid" ] || return 0
  tabs=$(HERDR_SESSION="$session" herdr tab list --workspace "$wsid" 2>/dev/null) || return 0
  while IFS=$'\t' read -r tab_id label; do
    [ -n "$tab_id" ] || continue
    pane_id=$(fm_backend_herdr_pane_for_tab "$session" "$wsid" "$tab_id") || continue
    [ -n "$pane_id" ] || continue
    printf '%s:%s\t%s\n' "$session" "$pane_id" "$label"
  done < <(printf '%s' "$tabs" | jq -r '.result.tabs[]? | select(.label | startswith("fm-")) | "\(.tab_id)\t\(.label)"' 2>/dev/null)
}
